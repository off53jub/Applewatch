import AVFoundation
import Foundation
import Security

/// 家の Wi-Fi にいるとき、時計から家の PC（LifeLog PC）に区切りを直接送る（2026-11-07）。
///
/// 時計 → iPhone の送り（WatchConnectivity の transferFile）は、iPhone のアプリが止まっていると届くのが遅れる
/// （Apple の決まりで、裏の送りは「急がずに」届き、iPhone のアプリを起こさない）。そこで、家の中の住所に届くときは
/// PC にも同じ区切りを送っておく。PC は区切りの名前（iPhone で付く名前）ごとに仕事を1つにまとめるので、
/// あとから iPhone が同じ区切りを送っても二重には文字にしない。iPhone は音声が届いたら、PC の答えをすぐ使える。
/// iPhone への送りは今までどおり続ける（記録に入れるのは、音声が iPhone に届いてから）。
///
/// - 宛先は家の中の住所（192.168.… など）だけ。合言葉は iPhone から受け取って、時計の Keychain に置く（ログには出さない）。
/// - 低電力モード・電池が20%より少ないとき（充電中を除く）は送らない。届かなかったら10分は試さない。
/// - モバイル通信（セルラーモデルの時計）では送らない。
final class WatchPC: @unchecked Sendable {
    /// 送れた区切り（時計のファイルの名前 → 送れた時刻）。1日で忘れる
    private static let sentKey = "pcSent"
    private static let keepSent: TimeInterval = 86400

    private let lock = NSLock()
    private var lastFailure: Date?
    private var sending: Set<String> = []
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config)
    }

    // MARK: - iPhone から届く設定

    /// 住所と合言葉（transferUserInfo で届く。合言葉が空なら消す）
    static func applyCredentials(_ info: [String: Any]) {
        guard let address = info[WatchDelivery.addressKey] as? String else { return }
        UserDefaults.standard.set(address, forKey: WatchDelivery.addressKey)
        let key = (info[WatchDelivery.secretKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty || address.isEmpty { WatchKeychain.delete() } else { WatchKeychain.save(key) }
    }

    /// 直接送るか・ヒント・重み・iPhone の時間帯（applicationContext で届く）
    static func applyContext(_ context: [String: Any]) {
        let defaults = UserDefaults.standard
        if let on = context[WatchDelivery.directKey] as? Bool { defaults.set(on, forKey: WatchDelivery.directKey) }
        if let hints = context[WatchDelivery.hintsKey] as? String { defaults.set(hints, forKey: WatchDelivery.hintsKey) }
        if let weights = context[WatchDelivery.weightsKey] as? String { defaults.set(weights, forKey: WatchDelivery.weightsKey) }
        if let zone = context[WatchDelivery.phoneZoneKey] as? String { defaults.set(zone, forKey: WatchDelivery.phoneZoneKey) }
    }

    /// 直接送れる設定になっているか（iPhone でオン・家の中の住所・合言葉がある）
    static var isConfigured: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: WatchDelivery.directKey) as? Bool ?? false,
              WatchDelivery.homeBaseURL(defaults.string(forKey: WatchDelivery.addressKey) ?? "") != nil else { return false }
        return WatchKeychain.read() != nil
    }

    // MARK: - 送った区切り

    /// その区切りを PC に送れたか
    static func wasSent(_ fileName: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Double])?[fileName] != nil
    }

    private func noteSent(_ fileName: String) {
        lock.withLock {
            let now = Date.now.timeIntervalSince1970
            var list = UserDefaults.standard.dictionary(forKey: Self.sentKey) as? [String: Double] ?? [:]
            list = list.filter { now - $0.value < Self.keepSent }
            list[fileName] = now
            UserDefaults.standard.set(list, forKey: Self.sentKey)
        }
    }

    // MARK: - 送る

    /// 区切りを PC に送り始めたら true（答えは待たない。答えは iPhone が受け取る）。
    /// 設定が無い・電池の決まりで送らない・もう送った・送っている途中なら false
    func send(_ url: URL, lowPower: Bool, battery: Double?, charging: Bool) -> Bool {
        let fileName = url.lastPathComponent
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: WatchDelivery.directKey) as? Bool ?? false,
              let base = WatchDelivery.homeBaseURL(defaults.string(forKey: WatchDelivery.addressKey) ?? ""),
              !Self.wasSent(fileName) else { return false }
        let now = Date.now
        let allowed = lock.withLock { () -> Bool in
            guard WatchDelivery.directAllowed(lowPower: lowPower, battery: battery, charging: charging,
                                              lastFailure: lastFailure, now: now),
                  !sending.contains(fileName) else { return false }
            sending.insert(fileName)
            return true
        }
        guard allowed else { return false }
        // 送っているあいだに控えに移されても困らないよう、中身を先に読んでおく（1つ 0.5〜1.2MB）
        guard let key = WatchKeychain.read(), let body = try? Data(contentsOf: url), !body.isEmpty else {
            _ = lock.withLock { sending.remove(fileName) }
            return false
        }
        let watchZone = TimeZone.current
        let phoneZone = defaults.string(forKey: WatchDelivery.phoneZoneKey).flatMap(TimeZone.init(identifier:)) ?? watchZone
        let name = WatchDelivery.phoneName(fileName, watchZone: watchZone, phoneZone: phoneZone)
        let start = WatchDelivery.startDate(fileName, zone: watchZone)
        var end: Date?
        if let start, let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            end = start.addingTimeInterval(Double(file.length) / file.fileFormat.sampleRate)
        }
        var components = URLComponents(url: base.appendingPathComponent("jobs"), resolvingAgainstBaseURL: false)
        components?.queryItems = WatchDelivery.jobQuery(name: name, chunkStart: start, chunkEnd: end, sent: now,
                                                        hints: defaults.string(forKey: WatchDelivery.hintsKey),
                                                        weights: defaults.string(forKey: WatchDelivery.weightsKey))
        guard let target = components?.url else {
            _ = lock.withLock { sending.remove(fileName) }
            return false
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, from: body) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self?.finished(fileName, ok: error == nil && status == 200)
        }
        task.resume()
        return true
    }

    private func finished(_ fileName: String, ok: Bool) {
        lock.withLock {
            sending.remove(fileName)
            // 届かなかった（家の外・PC が止まっている・合言葉が違う・PC が混んでいる）ら、しばらく試さない
            if ok { lastFailure = nil } else { lastFailure = .now }
        }
        if ok { noteSent(fileName) }
    }
}

/// 家の PC の合言葉を、時計の Keychain に置く（iPhone の PCKeychain と同じ形。ログやコードには書かない）
enum WatchKeychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.off53jub.lifelog.watchkitapp",
            kSecAttrAccount as String: "home-pc-key",
        ]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        guard read() != value else { return }
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

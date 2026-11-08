import AVFoundation
import Foundation
import Security

/// 時計から家の PC（LifeLog PC）に区切りを直接送る（2026-11-07）。
///
/// 時計 → iPhone の送り（WatchConnectivity の transferFile）は、iPhone のアプリが止まっていると届くのが遅れる
/// （Apple の決まりで、裏の送りは「急がずに」届き、iPhone のアプリを起こさない。数時間かかる日もある）。そこで、PC にも
/// 同じ区切りを送っておく。PC は区切りの名前（iPhone で付く名前）ごとに仕事を1つにまとめるので、
/// あとから iPhone が同じ区切りを送っても二重には文字にしない。iPhone は音声が届いたら、PC の答えをすぐ使える。
/// iPhone への送りは今までどおり続ける（記録に入れるのは、音声が iPhone に届いてから）。
///
/// - 道は2つ。PC の外の道（Tailscale の Funnel・https://〜.ts.net/w/jobs）があればそちら（家の外からも届く。時計用の合言葉）。
///   無ければ家の中の住所（192.168.… など・/jobs。PC の合言葉）。合言葉は iPhone から受け取って、時計の Keychain に置く（ログには出さない）。
/// - 低電力モード・電池が20%より少ないとき（充電中を除く）は送らない。届かなかったら10分は試さない。
///   外の道で合言葉が違うと言われたら、新しい合言葉が届くまで外の道は使わない。「しばらく受け付けない」なら15分待つ。
/// - モバイル通信（セルラーモデルの時計）では送らない。
/// - 送れたとき・区切ったときに、時計に残っていてまだ PC に送っていない古い区切り（24時間より新しいもの）を、
///   古い順に3つまで、1つずつ追いかけて送る（区切ったときに送れなかった分を取り戻す）。
final class WatchPC: @unchecked Sendable {
    /// 送れた区切り（時計のファイルの名前 → 送れた時刻）。1日で忘れる
    private static let sentKey = "pcSent"
    /// そのうち外の道で送れたもの（iPhone の自己点検に数を出す）
    private static let publicSentKey = "pcPublicSent"
    /// 外の道で合言葉が違うと言われた（新しい合言葉が届いたら消す）
    private static let refusedKey = "pcPublicRefused"
    private static let keepSent: TimeInterval = 86400

    private let lock = NSLock()
    private var lastFailure: Date?
    /// 外の道で「しばらく受け付けない」と言われてから15分
    private var publicBusyUntil: Date?
    private var sending: Set<String> = []
    /// PC が受け付けなかった区切り（名前・大きさ）。この起動のあいだは送らない
    private var rejected: Set<String> = []
    /// 追いかけて送る残りの数と、追いかけて送っている区切り
    private var catchUpLeft = 0
    private var catchingUp: String?
    private let session: URLSession

    /// 時計に残っている区切り（まだ iPhone に届いていないもの。書いている途中を除く）。WatchSender が渡す
    var candidates: (@Sendable () -> [URL])?
    /// いまの電池の様子（低電力モード・残り・充電中）。WatchSender が渡す
    var power: (@Sendable () -> (lowPower: Bool, battery: Double?, charging: Bool))?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.waitsForConnectivity = false
        // 家の外では iPhone の Bluetooth を通って送るので遅い（1つ 0.5〜1.2MB）。途切れたら30秒、全部で5分まで待つ
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
    }

    // MARK: - iPhone から届く設定

    /// 住所と合言葉・外の道と時計用の合言葉（transferUserInfo で届く。合言葉が空なら消す）。
    /// 届いた知らせに入っている分だけ変える（ほかの知らせでも呼ばれる）
    static func applyCredentials(_ info: [String: Any]) {
        let defaults = UserDefaults.standard
        if let address = info[WatchDelivery.addressKey] as? String {
            defaults.set(address, forKey: WatchDelivery.addressKey)
            let key = (info[WatchDelivery.secretKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty || address.isEmpty { WatchKeychain.delete() } else { WatchKeychain.save(key) }
        }
        if let text = info[WatchDelivery.publicURLKey] as? String {
            let oldURL = defaults.string(forKey: WatchDelivery.publicURLKey) ?? ""
            let oldKey = WatchKeychain.read(account: WatchKeychain.publicAccount)
            let key = (info[WatchDelivery.publicSecretKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let base = WatchDelivery.publicBaseURL(text), !key.isEmpty {
                defaults.set(base.absoluteString, forKey: WatchDelivery.publicURLKey)
                WatchKeychain.save(key, account: WatchKeychain.publicAccount)
            } else {
                defaults.removeObject(forKey: WatchDelivery.publicURLKey)
                WatchKeychain.delete(account: WatchKeychain.publicAccount)
            }
            // 宛先か合言葉が変わったら、「合言葉が違う」を忘れて、また外の道を試す
            let newURL = defaults.string(forKey: WatchDelivery.publicURLKey) ?? ""
            let newKey = WatchKeychain.read(account: WatchKeychain.publicAccount)
            if oldURL != newURL || oldKey != newKey { defaults.removeObject(forKey: refusedKey) }
        }
    }

    /// 直接送るか・ヒント・重み・iPhone の時間帯（applicationContext で届く）
    static func applyContext(_ context: [String: Any]) {
        let defaults = UserDefaults.standard
        if let on = context[WatchDelivery.directKey] as? Bool { defaults.set(on, forKey: WatchDelivery.directKey) }
        if let hints = context[WatchDelivery.hintsKey] as? String { defaults.set(hints, forKey: WatchDelivery.hintsKey) }
        if let weights = context[WatchDelivery.weightsKey] as? String { defaults.set(weights, forKey: WatchDelivery.weightsKey) }
        if let zone = context[WatchDelivery.phoneZoneKey] as? String { defaults.set(zone, forKey: WatchDelivery.phoneZoneKey) }
    }

    /// 外の道で合言葉が違うと言われたか
    static var publicRefused: Bool { UserDefaults.standard.bool(forKey: refusedKey) }

    /// 外の道の宛先と時計用の合言葉があるか
    static var hasPublicRoute: Bool {
        WatchDelivery.publicBaseURL(UserDefaults.standard.string(forKey: WatchDelivery.publicURLKey) ?? "") != nil
            && WatchKeychain.read(account: WatchKeychain.publicAccount) != nil
    }

    /// 直接送れる設定になっているか（iPhone でオン・外の道か家の中の住所があり、その合言葉がある）
    static var isConfigured: Bool {
        let defaults = UserDefaults.standard
        let route = WatchDelivery.directRoute(
            direct: defaults.object(forKey: WatchDelivery.directKey) as? Bool ?? false,
            publicURL: defaults.string(forKey: WatchDelivery.publicURLKey),
            hasPublicKey: WatchKeychain.read(account: WatchKeychain.publicAccount) != nil, publicUsable: !publicRefused,
            homeAddress: defaults.string(forKey: WatchDelivery.addressKey), hasHomeKey: WatchKeychain.read() != nil)
        return route != nil
    }

    // MARK: - 送った区切り

    /// その区切りを PC に送れたか
    static func wasSent(_ fileName: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Double])?[fileName] != nil
    }

    /// 直近24時間に外の道で送れた数
    static func publicSentCount(now: Date = .now) -> Int {
        let list = UserDefaults.standard.dictionary(forKey: publicSentKey) as? [String: Double] ?? [:]
        let seconds = now.timeIntervalSince1970
        return list.values.filter { seconds - $0 < keepSent }.count
    }

    private static func sentNames() -> Set<String> {
        Set((UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Double] ?? [:]).keys)
    }

    private func noteSent(_ fileName: String, isPublic: Bool) {
        lock.withLock {
            let now = Date.now.timeIntervalSince1970
            var keys = [Self.sentKey]
            if isPublic { keys.append(Self.publicSentKey) }
            for key in keys {
                var list = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
                list = list.filter { now - $0.value < Self.keepSent }
                list[fileName] = now
                UserDefaults.standard.set(list, forKey: key)
            }
        }
    }

    // MARK: - 送る

    /// 区切りを PC に送り始めたら true（答えは待たない。答えは iPhone が受け取る）。
    /// 設定が無い・電池の決まりで送らない・もう送った・送っている途中なら false。
    /// catchUp は、残っている古い区切りを追いかけて送るとき（1つずつ）
    func send(_ url: URL, lowPower: Bool, battery: Double?, charging: Bool, catchUp: Bool = false) -> Bool {
        let fileName = url.lastPathComponent
        let defaults = UserDefaults.standard
        guard !Self.wasSent(fileName) else { return false }
        let now = Date.now
        let publicKey = WatchKeychain.read(account: WatchKeychain.publicAccount)
        let homeKey = WatchKeychain.read()
        let busy = lock.withLock { publicBusyUntil.map { now < $0 } ?? false }
        guard let route = WatchDelivery.directRoute(
            direct: defaults.object(forKey: WatchDelivery.directKey) as? Bool ?? false,
            publicURL: defaults.string(forKey: WatchDelivery.publicURLKey), hasPublicKey: publicKey != nil,
            publicUsable: !busy && !Self.publicRefused,
            homeAddress: defaults.string(forKey: WatchDelivery.addressKey), hasHomeKey: homeKey != nil) else { return false }
        let allowed = lock.withLock { () -> Bool in
            guard WatchDelivery.directAllowed(lowPower: lowPower, battery: battery, charging: charging,
                                              lastFailure: lastFailure, now: now),
                  !sending.contains(fileName), !rejected.contains(fileName) else { return false }
            if catchUp {
                guard catchingUp == nil else { return false }
                catchingUp = fileName
            }
            sending.insert(fileName)
            return true
        }
        guard allowed else { return false }
        // 送っているあいだに控えに移されても困らないよう、中身を先に読んでおく（1つ 0.5〜1.2MB）
        let isPublic = route.isPublic
        let chosenKey = isPublic ? publicKey : homeKey
        // 書き終わっていない区切りは開けない（PC でも読めない）ので送らない（2026-11-08）
        guard let key = chosenKey, let audio = try? AVAudioFile(forReading: url), audio.length > 0,
              let body = try? Data(contentsOf: url), !body.isEmpty,
              !isPublic || body.count <= WatchDelivery.publicMaxBytes else {
            release(fileName)
            return false
        }
        let watchZone = TimeZone.current
        let phoneZone = defaults.string(forKey: WatchDelivery.phoneZoneKey).flatMap(TimeZone.init(identifier:)) ?? watchZone
        let name = WatchDelivery.phoneName(fileName, watchZone: watchZone, phoneZone: phoneZone)
        let start = WatchDelivery.startDate(fileName, zone: watchZone)
        var end: Date?
        if let start, audio.fileFormat.sampleRate > 0 {
            end = start.addingTimeInterval(Double(audio.length) / audio.fileFormat.sampleRate)
        }
        var components = URLComponents(url: route.uploadURL, resolvingAgainstBaseURL: false)
        components?.queryItems = WatchDelivery.jobQuery(name: name, chunkStart: start, chunkEnd: end, sent: now,
                                                        hints: defaults.string(forKey: WatchDelivery.hintsKey),
                                                        weights: defaults.string(forKey: WatchDelivery.weightsKey))
        guard let target = components?.url else {
            release(fileName)
            return false
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, from: body) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self?.finished(fileName, isPublic: isPublic, status: status, networkError: error != nil)
        }
        task.resume()
        return true
    }

    /// 送り始められなかった区切りを、送っている途中から外す
    private func release(_ fileName: String) {
        lock.withLock {
            sending.remove(fileName)
            if catchingUp == fileName { catchingUp = nil }
        }
    }

    private func finished(_ fileName: String, isPublic: Bool, status: Int, networkError: Bool) {
        let outcome = WatchDelivery.directOutcome(status: status, networkError: networkError, isPublic: isPublic)
        let wasCatchUp = lock.withLock { () -> Bool in
            sending.remove(fileName)
            let mine = catchingUp == fileName
            if mine { catchingUp = nil }
            switch outcome {
            case .sent:
                lastFailure = nil
                if mine { catchUpLeft = max(0, catchUpLeft - 1) }
            case .failed:
                // 届かなかった（家の外・PC が止まっている・合言葉が違う・PC が混んでいる）ら、しばらく試さない
                lastFailure = .now
            case .busy:
                publicBusyUntil = Date.now.addingTimeInterval(WatchDelivery.publicBusyWait)
            case .rejected:
                rejected.insert(fileName)
            case .refused:
                break
            }
            if outcome != .sent, mine { catchUpLeft = 0 }
            return mine
        }
        // 合言葉が違う: 新しい合言葉が届くまで外の道は使わない（家の中の住所があれば、そちらで送る）
        if outcome == .refused { UserDefaults.standard.set(true, forKey: Self.refusedKey) }
        guard outcome == .sent else { return }
        noteSent(fileName, isPublic: isPublic)
        // 送れたら、残っている古い区切りを追いかけて送る（追いかけて送れたときは、残りの数のまま続ける）
        catchUp(fresh: !wasCatchUp)
    }

    // MARK: - 残っている古い区切りを追いかけて送る（2026-11-07）

    /// 時計に残っていて、まだ PC に送っていない古い区切りを1つ送る（送れたら次へ。1回に3つまで）。
    /// fresh なら数を3に戻す（区切ったとき・ふつうの区切りが送れたとき）。ほかの区切りを送っている途中なら、それが終わってから
    func catchUp(fresh: Bool = true) {
        let ready = lock.withLock { () -> Bool in
            if fresh { catchUpLeft = WatchDelivery.catchUpLimit }
            return catchUpLeft > 0 && catchingUp == nil && sending.isEmpty
        }
        guard ready, let candidates = self.candidates, let power = self.power else { return }
        let files = candidates()
        guard !files.isEmpty else { return }
        let skip = lock.withLock { rejected }.union(Self.sentNames())
        let zone = TimeZone.current
        let listed = files.map { url -> (name: String, start: Date?) in
            (name: url.lastPathComponent, start: WatchDelivery.startDate(url.lastPathComponent, zone: zone))
        }
        let picked = WatchDelivery.catchUpPick(listed, skip: skip, now: .now)
        let state = power()
        for name in picked {
            guard let url = files.first(where: { $0.lastPathComponent == name }) else { continue }
            if send(url, lowPower: state.lowPower, battery: state.battery, charging: state.charging, catchUp: true) { return }
        }
    }
}

/// 家の PC の合言葉を、時計の Keychain に置く（iPhone の PCKeychain と同じ形。ログやコードには書かない）。
/// 外の道（Funnel）の時計用の合言葉は、別の名前（publicAccount）で置く（2026-11-07）
enum WatchKeychain {
    /// 家の PC の合言葉（家の中の住所で送るとき）
    static let homeAccount = "home-pc-key"
    /// 外の道の時計用の合言葉（送るだけの合言葉。PC の合言葉とは別）
    static let publicAccount = "pc-public-key"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.off53jub.lifelog.watchkitapp",
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String = homeAccount) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String = homeAccount) {
        guard read(account: account) != value else { return }
        delete(account: account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(account: String = homeAccount) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

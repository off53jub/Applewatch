import Foundation

/// 時計で録った区切りを、iPhone と家の PC に届ける決まり（2026-11-07）。時計と iPhone の両方で使う。
///
/// - 区切りに付ける控え（transferFile の metadata。どれも省ける。古い時計のアプリは付けない）:
///   `cut`（時計で区切った時刻）・`sentAt`（時計が送り始めた時刻）・`lowPower`（送ったとき時計が低電力モードだったか）・
///   `pc`（時計から家の PC にも直接送った）。時刻は 1970 年からの秒。iPhone はこれで「時計で待った」と「受け渡し」を分ける。
/// - 時計が低電力モードのときは溜めてまとめて送る。ただし、いちばん古い区切りが15分待ったら、数が溜まっていなくても送る
///   （静かな日は区切りが少なく、数だけで決めると何時間も送らないことがあったため）。
/// - 家の Wi-Fi にいるときは、時計から家の PC にも直接送る（宛先は家の中の住所だけ。iPhone への送りは今までどおり）。
enum WatchDelivery {
    // MARK: - 区切りに付ける控え（時計 → iPhone）

    static let zoneKey = "tz"
    static let cutKey = "cut"
    static let sentKey = "sentAt"
    static let lowPowerKey = "lowPower"
    static let pcKey = "pc"
    static let resendKey = "resend"

    /// iPhone が読み取った控え
    struct Stamp: Equatable, Sendable {
        /// 時計で区切った時刻
        var cut: Date?
        /// 時計が送り始めた時刻（送り直したときは、送り直した時刻）
        var sent: Date?
        /// 送ったとき時計が低電力モードだったか
        var lowPower: Bool?
        /// 時計から家の PC にも直接送った
        var viaPC: Bool = false
    }

    /// 時計が付ける控え
    static func metadata(zone: TimeZone, cut: Date?, sent: Date, lowPower: Bool, viaPC: Bool,
                         resend: Int? = nil) -> [String: Any] {
        var out: [String: Any] = [zoneKey: zone.identifier, sentKey: sent.timeIntervalSince1970, lowPowerKey: lowPower]
        if let cut { out[cutKey] = cut.timeIntervalSince1970 }
        if viaPC { out[pcKey] = true }
        if let resend { out[resendKey] = resend }
        return out
    }

    /// iPhone が控えを読む（無い・読めない項目は nil）
    static func stamp(from metadata: [String: Any]?) -> Stamp {
        func date(_ key: String) -> Date? {
            guard let seconds = metadata?[key] as? Double, seconds > 0, seconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        return Stamp(cut: date(cutKey), sent: date(sentKey), lowPower: metadata?[lowPowerKey] as? Bool,
                     viaPC: metadata?[pcKey] as? Bool ?? false)
    }

    // MARK: - 低電力モードで送るか

    /// 低電力モードでも、いちばん古い区切りがこれだけ待ったら送る
    static let lowPowerMaxWait: TimeInterval = 15 * 60

    /// 低電力モードで、いま送るか（数が溜まったか、いちばん古い区切りが待ちすぎたか）
    static func lowPowerDue(count: Int, batch: Int, oldest: Date?, now: Date) -> Bool {
        guard count > 0 else { return false }
        if count >= batch { return true }
        guard let oldest else { return false }
        return now.timeIntervalSince(oldest) >= lowPowerMaxWait
    }

    // MARK: - 名前（時計の名前 → iPhone で付く名前）

    private static func formatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }

    /// 時計のファイルの名前（時計の時間帯）の時刻
    static func startDate(_ watchName: String, zone: TimeZone) -> Date? {
        formatter(zone).date(from: String((watchName as NSString).deletingPathExtension.prefix(15)))
    }

    /// 時計のファイルの名前から、iPhone で付く名前（iPhone の時間帯に直し、「-w」を付ける）。
    /// iPhone の PhoneReceiver（Storage.convertedName と Storage.watchChunkName）と同じ名前になる。
    /// 家の PC は同じ名前の仕事を1つにまとめるので、時計と iPhone の両方から送っても二重には文字にしない
    static func phoneName(_ watchName: String, watchZone: TimeZone, phoneZone: TimeZone) -> String {
        let stem = (watchName as NSString).deletingPathExtension
        var head = String(stem.prefix(15))
        var tail = String(stem.dropFirst(15))
        if let date = formatter(watchZone).date(from: head) { head = formatter(phoneZone).string(from: date) }
        if !tail.hasSuffix("-w") { tail += "-w" }
        return head + tail + ".m4a"
    }

    // MARK: - 家の PC に直接送る（時計 → 家の PC）

    /// iPhone から時計に送る設定の名前
    /// applicationContext（秘密でないもの）: 直接送るか・聞き取りのヒント・多数決の重み・iPhone の時間帯
    static let directKey = "pcDirect"
    static let hintsKey = "pcHints"
    static let weightsKey = "pcWeights"
    static let phoneZoneKey = "phoneTZ"
    /// transferUserInfo（合言葉を含むので、残る applicationContext には入れない）: 家の中の住所・合言葉
    static let addressKey = "pcHomeAddress"
    static let secretKey = "pcHomeKey"

    static let defaultPort = 47615
    /// 届かなかったら、これだけは試さない
    static let directRetryAfter: TimeInterval = 10 * 60
    /// 電池がこれより少ない（充電中を除く）ときは送らない
    static let directMinBattery = 0.2
    /// ヒントの長さの上限（iPhone の送りと同じ）
    static let hintsLimit = 1500

    /// 家の中の住所か。ATS の NSAllowsLocalNetworking で http が通る範囲だけにする:
    /// 家の中の番号（10.・172.16〜31.・192.168.・169.254.）・「.local」の名前・点の無い名前。
    /// Tailscale の番号（100.…）や「〜.ts.net」は時計からは使えない（時計に Tailscale は無い）ので、家の中ではない
    static func isHomeHost(_ host: String) -> Bool {
        let h = host.lowercased()
        guard !h.isEmpty, !h.contains(" "), !h.contains(":"), !h.contains("/") else { return false }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt8($0) }
        if parts.count == 4, numbers.count == 4 {
            switch (numbers[0], numbers[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, let second): return (16...31).contains(second)
            default: return false
            }
        }
        // 数字だけで4つに分かれないもの（192.168.1 など）は住所として読めない
        if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        if h.hasSuffix(".local") {
            let name = h.dropLast(6)
            return !name.isEmpty && name.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0.allSatisfy(allowed) }
        }
        return h.allSatisfy(allowed)
    }

    /// 家の中の住所（例 192.168.1.20 や 192.168.1.20:47615）から送り先。家の中でなければ nil
    static func homeBaseURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["http://", "https://"] where t.lowercased().hasPrefix(prefix) { t.removeFirst(prefix.count) }
        while t.hasSuffix("/") { t.removeLast() }
        let pieces = t.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return nil }
        let host = String(pieces[0])
        var port = defaultPort
        if pieces.count == 2 {
            guard let p = Int(pieces[1]), (1...65535).contains(p) else { return nil }
            port = p
        }
        guard isHomeHost(host) else { return nil }
        return URL(string: "http://\(host.lowercased()):\(port)")
    }

    /// いま時計から直接送ってよいか（電池を守る決まり）
    static func directAllowed(lowPower: Bool, battery: Double?, charging: Bool, lastFailure: Date?, now: Date) -> Bool {
        guard !lowPower else { return false }
        if let battery, battery < directMinBattery, !charging { return false }
        if let lastFailure, now.timeIntervalSince(lastFailure) < directRetryAfter { return false }
        return true
    }

    /// POST /jobs に付ける query（iPhone の送りと同じ形。待ち合わせ wait=1 は付けない＝答えは iPhone が受け取る）
    static func jobQuery(name: String, chunkStart: Date?, chunkEnd: Date?, sent: Date,
                         hints: String?, weights: String?) -> [URLQueryItem] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var items = [URLQueryItem(name: "name", value: name)]
        if let chunkStart { items.append(URLQueryItem(name: "chunk_start", value: f.string(from: chunkStart))) }
        if let chunkEnd { items.append(URLQueryItem(name: "chunk_end", value: f.string(from: chunkEnd))) }
        items.append(URLQueryItem(name: "sent", value: f.string(from: sent)))
        if let hints, !hints.isEmpty { items.append(URLQueryItem(name: "hints", value: String(hints.prefix(hintsLimit)))) }
        if let weights, !weights.isEmpty { items.append(URLQueryItem(name: "weights", value: weights)) }
        return items
    }
}

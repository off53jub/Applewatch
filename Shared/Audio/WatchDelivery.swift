import Foundation

/// 時計で録った区切りを、iPhone と家の PC に届ける決まり（2026-11-07）。時計と iPhone の両方で使う。
///
/// - 区切りに付ける控え（transferFile の metadata。どれも省ける。古い時計のアプリは付けない）:
///   `cut`（時計で区切った時刻）・`sentAt`（時計が送り始めた時刻）・`lowPower`（送ったとき時計が低電力モードだったか）・
///   `pc`（時計から家の PC にも直接送った）。時刻は 1970 年からの秒。iPhone はこれで「時計で待った」と「受け渡し」を分ける。
/// - 時計が低電力モードのときは溜めてまとめて送る。ただし、いちばん古い区切りが15分待ったら、数が溜まっていなくても送る
///   （静かな日は区切りが少なく、数だけで決めると何時間も送らないことがあったため）。
/// - 家の Wi-Fi にいるときは、時計から家の PC にも直接送る（宛先は家の中の住所だけ。iPhone への送りは今までどおり）。
/// - PC の外の道（Tailscale の Funnel・https://〜.ts.net）があれば、家の外からも時計用の合言葉で直接送る（2026-11-07。docs/v10-watch-route-ios.md）。
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
        /// 声が無いので捨てるはずだった区切りの見本（1 割。家の PC が本当に声が無かったかを数える。2026-11-22。s21 の 精7）
        var sampleNoVoice: Bool = false
        /// 区切りの中の音の大きさの要約（p10・p50・p90・voicedP50。2026-11-22。s22 の 確4。古い時計は付けない）
        var levels: [String: Double]? = nil
        /// その区切りの録り方の実験の組（"32k45" など。2026-11-22。s22 の 確24。入れ替えの日だけ）
        var recExp: String? = nil
    }

    /// 時計が付ける控え
    static func metadata(zone: TimeZone, cut: Date?, sent: Date, lowPower: Bool, viaPC: Bool,
                         resend: Int? = nil, sampleNoVoice: Bool = false) -> [String: Any] {
        var out: [String: Any] = [zoneKey: zone.identifier, sentKey: sent.timeIntervalSince1970, lowPowerKey: lowPower]
        if let cut { out[cutKey] = cut.timeIntervalSince1970 }
        if viaPC { out[pcKey] = true }
        if let resend { out[resendKey] = resend }
        // 精7: 見本の印（無ければ付けない。2026-11-22）
        if sampleNoVoice { out[S21Watch.sampleNoVoiceKey] = true }
        return out
    }

    /// iPhone が控えを読む（無い・読めない項目は nil）
    static func stamp(from metadata: [String: Any]?) -> Stamp {
        func date(_ key: String) -> Date? {
            guard let seconds = metadata?[key] as? Double, seconds > 0, seconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        return Stamp(cut: date(cutKey), sent: date(sentKey), lowPower: metadata?[lowPowerKey] as? Bool,
                     viaPC: metadata?[pcKey] as? Bool ?? false,
                     sampleNoVoice: metadata?[S21Watch.sampleNoVoiceKey] as? Bool ?? false,
                     levels: S22Watch.levels(from: metadata),
                     recExp: (metadata?[S22Watch.recExpKey] as? String).flatMap { S22Watch.isRecExpLabel($0) ? $0 : nil })
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
        directSkipReason(lowPower: lowPower, battery: battery, charging: charging, lastFailure: lastFailure, now: now) == nil
    }

    /// 直接送らない理由（送ってよければ nil）。iPhone の自己点検に出す（2026-11-10。外の道が何時間も使われなかった日に、理由が分からなかった）
    static func directSkipReason(lowPower: Bool, battery: Double?, charging: Bool, lastFailure: Date?, now: Date) -> String? {
        if lowPower { return "低電力モード" }
        if let battery, battery < directMinBattery, !charging { return "電池 \(Int((battery * 100).rounded()))%" }
        if let lastFailure, now.timeIntervalSince(lastFailure) < directRetryAfter { return "届かなかったので10分待ち" }
        return nil
    }

    /// 直接送れなかった理由の短い文（iPhone の自己点検に出す。2026-11-10）。
    /// urlErrorCode は URLError の番号（-1001 時間切れ・-1009 つながっていない など）。届いたなら nil
    static func directFailText(status: Int, urlErrorCode: Int?, isPublic: Bool) -> String? {
        let route = isPublic ? "外の道" : "家の中"
        if let code = urlErrorCode {
            let names = [-1001: "時間切れ", -1009: "ネットにつながっていない", -1003: "宛先が見つからない",
                         -1004: "つなげなかった", -1005: "途中で切れた", -1200: "暗号の確かめに失敗", -1020: "通信が許されていない"]
            return "\(route): \(names[code] ?? "通信の失敗") (\(code))"
        }
        if status == 200 { return nil }
        return status == 0 ? "\(route): 返事が無い" : "\(route): PC の答え \(status)"
    }

    // MARK: - 家の外からの道（Tailscale の Funnel。2026-11-07）

    /// transferUserInfo（合言葉を含む）: PC の外の道の宛先（https://〜.ts.net）と、時計用の合言葉。空なら消す
    static let publicURLKey = "pcPublicURL"
    static let publicSecretKey = "pcPublicKey"
    /// 外の道に送れる大きさの上限（PC が受け取る上限）
    static let publicMaxBytes = 8 * 1024 * 1024
    /// 外の道で「混んでいる・しばらく受け付けない」（429）と言われたら、これだけ待つ
    static let publicBusyWait: TimeInterval = 15 * 60

    /// 時計が受け取っていないとき、iPhone が送り直す間（2026-11-08）
    static let resendGap: TimeInterval = 10 * 60

    /// 時計の様子の知らせ（pcPublic・pcDirect）と iPhone の設定が食い違っていて、送り直したほうがよいか（2026-11-08）。
    /// 古い版の時計（どちらの項目も無い）には送らない（受け取っても使えない）
    static func needsResend(watchHasPublic: Bool?, watchDirectOn: Bool?, phoneHasPublic: Bool, phoneDirectOn: Bool) -> Bool {
        if watchHasPublic == nil && watchDirectOn == nil { return false }
        if let has = watchHasPublic, has != phoneHasPublic { return true }
        if let on = watchDirectOn, on != phoneDirectOn { return true }
        return false
    }

    /// PC の外の道の宛先（例 https://desktop-xxxx.tail1234.ts.net）。
    /// https で、名前が「.ts.net」で終わり、道（/…）・問い（?…）・番号（443 以外）が付いていないものだけ。ほかは nil
    static func publicBaseURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let c = URLComponents(string: t), c.scheme?.lowercased() == "https",
              let host = c.host?.lowercased(), host.hasSuffix(".ts.net"), host.count > ".ts.net".count,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", c.port == nil || c.port == 443 else { return nil }
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(allowed) }) else { return nil }
        return URL(string: "https://\(host)")
    }

    /// 時計から PC に直接送る道
    enum DirectRoute: Equatable, Sendable {
        /// 外の道（Funnel。どこからでも届く。時計用の合言葉で送る）
        case publicRoute(URL)
        /// 家の中の住所（家の Wi-Fi にいるときだけ届く。PC の合言葉で送る）
        case home(URL)

        var isPublic: Bool {
            if case .publicRoute = self { return true }
            return false
        }

        /// 区切りを送る先（外の道は /w/jobs、家の中は /jobs）
        var uploadURL: URL {
            switch self {
            case .publicRoute(let base): base.appendingPathComponent("w").appendingPathComponent("jobs")
            case .home(let base): base.appendingPathComponent("jobs")
            }
        }
    }

    /// どの道で送るか。外の道が使えればそちら（家の中でも外でも届くので、いつもそちら）。
    /// 外の道が無い・合言葉が違うと言われた・しばらく待つあいだは、家の中の住所。どちらも無ければ nil
    static func directRoute(direct: Bool, publicURL: String?, hasPublicKey: Bool, publicUsable: Bool,
                            homeAddress: String?, hasHomeKey: Bool) -> DirectRoute? {
        guard direct else { return nil }
        if publicUsable, hasPublicKey, let base = publicBaseURL(publicURL ?? "") { return .publicRoute(base) }
        if hasHomeKey, let base = homeBaseURL(homeAddress ?? "") { return .home(base) }
        return nil
    }

    /// 送った結果
    enum DirectOutcome: Equatable, Sendable {
        /// 届いた（PC がしまった・もう知っていた）
        case sent
        /// 届かなかった（家の外・PC が止まっている など）。しばらく試さない
        case failed
        /// 外の道で合言葉が違うと言われた。新しい合言葉が届くまで外の道は使わない
        case refused
        /// 外の道で「しばらく受け付けない」と言われた。15分待つ
        case busy
        /// その区切りは受け付けられない（名前・大きさ）。その区切りはもう送らない
        case rejected
    }

    /// 返事から、次にどうするか（家の中の住所は今までどおり、200 以外は「届かなかった」）
    static func directOutcome(status: Int, networkError: Bool, isPublic: Bool) -> DirectOutcome {
        if networkError || status == 0 { return .failed }
        if status == 200 { return .sent }
        guard isPublic else { return .failed }
        switch status {
        case 401: return .refused
        case 429: return .busy
        case 400..<500: return .rejected
        default: return .failed
        }
    }

    // MARK: - 残っている古い区切りを追いかけて送る（2026-11-07）

    /// 1回に追いかける数と、追いかける古さ
    static let catchUpLimit = 3
    static let catchUpMaxAge: TimeInterval = 86400

    /// 時計に残っている区切りから、PC に追いかけて送るもの（まだ PC に送っていない・24時間より新しい・古い順に3つまで）
    static func catchUpPick(_ files: [(name: String, start: Date?)], skip: Set<String>, now: Date) -> [String] {
        let fresh = files.compactMap { file -> (name: String, start: Date)? in
            guard !skip.contains(file.name), let start = file.start else { return nil }
            let age = now.timeIntervalSince(start)
            guard age >= 0, age < catchUpMaxAge else { return nil }
            return (file.name, start)
        }
        return fresh.sorted { ($0.start, $0.name) < ($1.start, $1.name) }.prefix(catchUpLimit).map { $0.name }
    }

    // MARK: - 音声は家の PC から iPhone へ（2026-11-15。強化案 64）
    //
    // 前は、時計が同じ区切りを2回送っていた（家の PC へ直接と、iPhone へ WatchConnectivity で）。iPhone への受け渡しは
    // Apple に絞られて何時間も遅れ、返事待ちの控えが 1000 個を超えて、送り直しが続いていた（2026-11-15 の自己点検で 1327 個）。
    // PC はもう音声を持っているので、iPhone は PC から音声を受け取り（PCRelay.swift）、時計に「受け取った」と返事をする。
    // 時計は、PC に届いた区切りを少しのあいだ iPhone に送らずに待ち、その間に返事が来たら送らない（無線を使うのが1回で済む）。
    // 返事が来なければ、今までどおり iPhone に送る（何も失わない。遅れるのは長くて relayWait）。

    /// applicationContext（iPhone → 時計）: iPhone がいま、時計の音声を家の PC から受け取れる
    /// （PC が "jobaudio" を持ち、設定がオンで、つながり方が合っている）。古い iPhone のアプリは送らない＝時計は待たない
    static let relayKey = "pcRelay"
    /// transferUserInfo（iPhone → 時計）: 家の PC から音声を受け取った区切り（iPhone で付く名前）
    static let relayGotKey = "gotPC"
    /// 時計が、PC に届いた区切りを iPhone に送らずに待つ長さ
    static let relayWait: TimeInterval = 20 * 60

    // 2026-11-18: 20分では足りなかった。iPhone が寝ている夜は PC から 1 時間に 2〜11 個しか受け取らず、待ち切れなかった区切りが
    // Apple に絞られた受け渡しに回って、時計に「iPhone に送っていない録音」が 300 個ほどたまった（家でも外でも）。
    // PC はもう音声を持っていて、文字も PC から先に記録に入っているので、iPhone が「受け取る準備はある」（いまは Wi-Fi でなくても）
    // と言っているあいだは、PC に届いた区切りを長く待つ（iPhone は Wi-Fi に戻ったとき・アプリを開いたときにまとめて受け取る）。

    /// applicationContext（iPhone → 時計）: iPhone が、時計の音声を家の PC から受け取る準備がある（設定がオン・PC が対応）。
    /// いま受け取れるか（relayKey）とは別。古い iPhone のアプリは送らない＝今までどおり 20 分だけ待つ
    static let relayLaterKey = "pcRelayLater"
    /// 準備があるときに待つ長さ（時計が「PC に届いた」を覚えている 24 時間と、iPhone が受け取る 2 日より短く）
    static let relayLongWait: TimeInterval = 20 * 3600
    /// 長く待つ区切りの数の上限（時計の空きを使い切らない。超えた古いものから今までどおり iPhone に送る）
    static let relayHoldMax = 900

    /// 時計が、この区切りを iPhone に送るのを待つか。
    /// relay は iPhone が「PC から受け取れる」と言っているか。sentToPC は PC に届いた時刻。sendingToPC はいま PC に送っている途中か。
    /// PC に送れなかった（sentToPC が無く、送っている途中でもない）区切りは待たない
    /// later は iPhone が「受け取る準備がある」と言っているか（そのときは relayLongWait まで待つ。いま受け取れなくても待つ）
    static func relayHold(relay: Bool, later: Bool = false, sentToPC: Date?, sendingToPC: Bool, now: Date) -> Bool {
        guard relay || later else { return false }
        if sendingToPC { return true }
        guard let sentToPC else { return false }
        let waited = now.timeIntervalSince(sentToPC)
        return waited >= 0 && waited < (later ? relayLongWait : relayWait)
    }

    /// 待つ区切りの名前（relayHold に当たるもののうち、PC に届いたのが新しい順に relayHoldMax 個まで。
    /// 送っている途中のものはいつも待つ）
    static func relayHeld(_ files: [(name: String, sentToPC: Date?, sending: Bool)], relay: Bool, later: Bool,
                          now: Date, max: Int = relayHoldMax) -> Set<String> {
        let hits = files.filter { relayHold(relay: relay, later: later, sentToPC: $0.sentToPC, sendingToPC: $0.sending, now: now) }
        let sending = hits.filter(\.sending).map(\.name)
        let sent = hits.filter { !$0.sending }
            .sorted { ($0.sentToPC ?? .distantPast, $0.name) > ($1.sentToPC ?? .distantPast, $1.name) }
            .prefix(Swift.max(0, max - sending.count)).map(\.name)
        return Set(sending + sent)
    }

    /// iPhone で付く名前から、時計のファイルの名前（phoneName の逆。「-w」を外し、時計の時間帯に直す）。
    /// 時計の区切りの名前でなければ nil
    static func watchName(_ phoneName: String, watchZone: TimeZone, phoneZone: TimeZone) -> String? {
        let stem = (phoneName as NSString).deletingPathExtension
        guard (phoneName as NSString).pathExtension == "m4a", !phoneName.contains("/"),
              stem.hasSuffix("-w"), stem.count >= 17 else { return nil }
        let body = String(stem.dropLast(2))
        let tail = String(body.dropFirst(15))
        guard let date = formatter(phoneZone).date(from: String(body.prefix(15))) else { return nil }
        return formatter(watchZone).string(from: date) + tail + ".m4a"
    }

    // MARK: - 返事待ちの控えを送り直すか（2026-11-16。docs/v20-watch-silence.md）
    //
    // 11/12〜11/16 の自己点検（421 回）では、時計の「送っている途中」（outstandingFileTransfers）がいつも 10 個以上あった。
    // 送り直しは「列が 10 個より少ないときだけ」だったので一度も動かず、iPhone の「全部送り直して」も空振りして、
    // 返事待ちの控え（kept）は 1300 個ほどのまま 4 日減らなかった（300MB の上限に張りついている、と見ている。
    // 時計の区切りは 1 個 220KB ほどなので、300MB でちょうど 1300 個ほど）。
    // 列に残り続けるもの（送り始めてから staleTransferAge より古い）は、列が動いているあいだは混み具合に数えない。

    /// 受け渡しの列のうち、送り始めてからこれより古いものは「止まっている」とみなす
    static let staleTransferAge: TimeInterval = 30 * 60
    /// 最後に受け渡しが終わってからこれだけのあいだは「列は動いている」とみなす
    static let queueMovingWithin: TimeInterval = 10 * 60
    /// これより古い区切りは送り直さない。iPhone が「もう受け取った」と覚えているのは 4 日（Storage.rememberReceived）なので、
    /// それより古いものを送り直すと、受け取り済みでも新しい区切りとして文字にし直してしまう
    static let resendMaxAge: TimeInterval = 3 * 86400

    /// いま返事待ちの控えを送り直してよいか。queued は受け渡しの列にあるものの、送り始めた時刻（控えの sentAt。読めなければ nil）。
    /// limit は列の上限、lastFinished は最後に受け渡しが終わった（成功した）時刻
    static func resendAllowed(queued: [Date?], limit: Int, lastFinished: Date?, now: Date) -> Bool {
        if queued.count < limit { return true }
        // 列が動いていなければ（iPhone が受け取っていない）、送り直しても列が長くなるだけ
        guard let lastFinished, now.timeIntervalSince(lastFinished) < queueMovingWithin else { return false }
        let fresh = queued.filter { sent in
            guard let sent else { return false }
            return now.timeIntervalSince(sent) < staleTransferAge
        }.count
        return fresh < limit
    }

    // MARK: - 終わらない受け渡しを取り消す（2026-11-20。docs/v23-watch-stuck-transfers.md）
    //
    // 11/18 5:49 から 2 日半、時計の「まだ送っていない」が 302 個のまま減らなかった。どれも受け渡しの列
    // （outstandingFileTransfers）に入ったまま終わらず、resendPending は「送っている途中」なので送り直さなかった。
    // 新しい区切りは届いていたので、列が丸ごと止まっていたのではない。止まった受け渡しを取り消して送り直す。

    /// 受け渡しを始めてからこれだけたっても終わらないものは、止まっているとみなして取り消す（仮）
    static let stuckTransferAge: TimeInterval = 6 * 3600
    /// 1 回の見回りで取り消す数の上限（仮。送り直しが新しい区切りの前に並びすぎないように）
    static let unstickPerPass = 30

    /// 取り消す受け渡しの名前（古い順に max 個まで）。started は送り始めた時刻（読めなければ区切った時刻、どちらも無ければ取り消さない）
    static func stuckTransfers(_ queued: [(name: String, sent: Date?, cut: Date?)], now: Date,
                               age: TimeInterval = stuckTransferAge, max: Int = unstickPerPass) -> [String] {
        queued.compactMap { item -> (name: String, started: Date)? in
            guard let started = item.sent ?? item.cut, now.timeIntervalSince(started) >= age else { return nil }
            return (item.name, started)
        }
        .sorted { ($0.started, $0.name) < ($1.started, $1.name) }
        .prefix(Swift.max(0, max))
        .map(\.name)
    }

    /// 取り消したあと、iPhone に送り直さずに控えへ移すか。古すぎて（resendMaxAge より前）iPhone に送ると文字にし直してしまうが、
    /// 家の PC には届いている区切りだけ（PC に無いものは、古くても送り直す。失わないほうを選ぶ）
    static func retireInsteadOfResend(cutAge: TimeInterval?, sentToPC: Bool) -> Bool {
        guard let cutAge else { return false }
        return sentToPC && cutAge > resendMaxAge
    }

    /// この控えを送り直す時か。sentAgo は最後に送って（送り直して）からの秒、count は送り直した回数、
    /// cutAge は区切ってからの秒（分からなければ nil）。決まりは WatchSender の resendAfter・maxResends・slowResendAfter と同じ
    static func resendDue(sentAgo: TimeInterval, count: Int, cutAge: TimeInterval?,
                          resendAfter: TimeInterval, maxResends: Int, slowResendAfter: TimeInterval) -> Bool {
        if let cutAge, cutAge > resendMaxAge { return false }
        return sentAgo >= (count < maxResends ? resendAfter : slowResendAfter)
    }

    /// POST /jobs に付ける query（iPhone の送りと同じ形。待ち合わせ wait=1 は付けない＝答えは iPhone が受け取る）
    /// car: 車につないでいたあいだの区切り（"inCar=1"。会話の記録の inCar・vehicle と同じ印。家の PC はナビ・カーステレオらしい声を本人の発話から外す。無ければ付けない。
    /// 2026-11-21。s19 の 休13。HolidayRules.inCar）
    /// sampleNoVoice: 声が無いので捨てるはずだった区切りの見本（"sampleNoVoice=1"。2026-11-22。s21 の 精7。無ければ付けない）
    static func jobQuery(name: String, chunkStart: Date?, chunkEnd: Date?, sent: Date,
                         hints: String?, weights: String?, car: Bool = false, sampleNoVoice: Bool = false) -> [URLQueryItem] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var items = [URLQueryItem(name: "name", value: name)]
        if let chunkStart { items.append(URLQueryItem(name: "chunk_start", value: f.string(from: chunkStart))) }
        if let chunkEnd { items.append(URLQueryItem(name: "chunk_end", value: f.string(from: chunkEnd))) }
        items.append(URLQueryItem(name: "sent", value: f.string(from: sent)))
        if let hints, !hints.isEmpty { items.append(URLQueryItem(name: "hints", value: String(hints.prefix(hintsLimit)))) }
        if let weights, !weights.isEmpty { items.append(URLQueryItem(name: "weights", value: weights)) }
        if car { items.append(URLQueryItem(name: "inCar", value: "1")) }
        if sampleNoVoice { items.append(URLQueryItem(name: S21Watch.sampleNoVoiceKey, value: "1")) }
        return items
    }
}

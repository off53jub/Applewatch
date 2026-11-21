import AVFoundation
import Foundation
import WatchConnectivity
import WatchKit

/// 録音した区切りを iPhone に送る。
/// iPhone が近くに無いときは WatchConnectivity が溜めておき、つながったときに送る。
/// 時計が低電力モードのときは、無線を起こす回数を減らすため、15分ほど溜まってからまとめて送る
/// （5分の区切りなら3つ、短めの区切りなら12個。2026-11-07）。数が溜まらなくても、いちばん古い区切りが15分待ったら送る
/// （静かな日に何時間も送らないことがあったため。2026-11-07。WatchDelivery）。
/// 区切りには「時計で区切った時刻・送り始めた時刻」を添える（iPhone が時計で待った時間と受け渡しの時間を分けて測る）。
/// 家の Wi-Fi にいるときは、家の PC にも直接送る（WatchPC。iPhone への送りは今までどおり）。
/// PC の外の道（Tailscale の Funnel）があれば、家の外からも送る。送れなかった古い区切りも追いかけて送る（2026-11-07）。
/// 送り終わった区切りは「送った」フォルダに控えとして残し、iPhone が「受け取った」と返事したら消す（2026-11-06）。
/// 30分たっても返事が無ければ送り直す（30分ごとに3回、そのあとは6時間ごと）。控えは7日・300MB まで（2026-11-07）。
/// iPhone から頼まれたとき・iPhone のアプリが入れ直されたときは、残っている区切りを全部送り直す（2026-11-07）。
/// 返事をしない古い iPhone のアプリには、今までどおり送り終わったら消す。
/// iPhone が「音声は家の PC から受け取れる」と言っているあいだは、PC に届いた区切りを iPhone には送らずに20分まで待つ。
/// iPhone が PC から受け取って「受け取った」（gotPC）と返事をすれば、送らずに消す。返事が無ければ今までどおり送る
/// （2026-11-15。強化案 64。docs/v17-watch-relay.md）。
final class WatchSender: NSObject, WCSessionDelegate {
    static let pendingDir: URL = {
        let dir = URL.documentsDirectory.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 送り終わったが、iPhone から「受け取った」の返事がまだの区切り
    static let sentDir: URL = {
        let dir = URL.documentsDirectory.appendingPathComponent("sent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// 返事が無ければ、これだけたってから送り直す
    static let resendAfter: TimeInterval = 30 * 60
    static let maxResends = 3
    /// 3回送り直しても返事が無ければ、そのあとは6時間ごとに送り直す（控えが残っているかぎり。2026-11-07）。
    /// 前は3回で諦めていて、iPhone のアプリが受け取れない時間が長いと、控えが残っていても二度と送らなかった
    static let slowResendAfter: TimeInterval = 6 * 3600
    /// 1回に送り直す数の上限と、送っている途中がこれ以上あれば送り直さない数（2026-11-09）。
    /// 11/9 は返事待ちが1000個を超え、iPhone の「全部送り直して」のたびに全部を送り直して受け渡しの列を埋め、
    /// 新しい区切りが何時間も iPhone に届かなかった（と見ている）。新しい区切りを先に通すため、送り直しは少しずつにする
    static let resendPerPass = 5
    static let resendQueueLimit = 10
    /// 控えを残す長さと大きさ（2026-11-07 に3日から7日へ。iPhone のアプリの入れ替えなどで受け取れない日があっても失わないように）
    static let keepSentFor: TimeInterval = 7 * 86400
    static let keepSentBytes = 300 * 1024 * 1024
    /// 送り終わった時刻と、送り直した回数（ファイル名ごと）
    private static let sentAtKey = "sentAt"
    private static let resentKey = "resent"

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 次の区切りのファイルの場所（名前は録音を始めた時刻）
    static func newChunkURL(at date: Date = .now) -> URL {
        pendingDir.appendingPathComponent(nameFormatter.string(from: date) + ".m4a")
    }

    /// 低電力モードで、これだけ溜まったらまとめて送る（5分の区切りで3つ＝15分ほど。短めの区切りでも同じくらいの時間）
    private static var batch: Int { ChunkCutter.scaled(3) }

    /// 送れた・つながりが変わったときに呼ぶ（画面の数を出し直す）
    var onChange: (@Sendable () -> Void)?

    /// 家の PC に直接送る（2026-11-07）
    let pc = WatchPC()

    /// iPhone から届いた知らせ（こもり・音割れなど）。時計を震わせて画面に出す
    var onAlert: (@Sendable (String) -> Void)?

    /// iPhone から届いた、時計の画面に出す中身（WatchInfo の JSON。2026-11-07）
    var onInfo: (@Sendable (Data) -> Void)?
    /// iPhone から届いた「聞く」の答え（答え, 質問。2026-11-07）
    var onAnswer: (@Sendable (String, String) -> Void)?

    @MainActor
    func activate() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        readBattery()
        // 家の PC に追いかけて送るとき、時計に残っている区切りと電池の様子を見る（2026-11-07。WatchPC.catchUp）
        pc.candidates = { [weak self] in self?.unsentFiles() ?? [] }
        pc.power = { [weak self] in
            let battery = self?.currentBattery()
            return (lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, battery: battery?.level,
                    charging: battery?.charging ?? false)
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var batteryInfo: (level: Double, charging: Bool)?

    /// 最後に読んだ電池の様子（どの糸からでもよい）
    private func currentBattery() -> (level: Double, charging: Bool)? {
        lock.withLock { batteryInfo }
    }

    /// 時計の電池を読み直す（画面の糸から呼ぶ）
    @MainActor
    func readBattery() {
        let device = WKInterfaceDevice.current()
        guard device.batteryLevel >= 0 else { return }
        let info = (level: Double(device.batteryLevel), charging: device.batteryState == .charging || device.batteryState == .full)
        lock.withLock { batteryInfo = info }
    }

    /// iPhone のアプリが「受け取った」と返事をする版か（返事をしない版には、送り終わったら消す）
    private static var phoneAcks: Bool { UserDefaults.standard.bool(forKey: "phoneAcks") }

    private let lock = NSLock()
    private var writing: URL?

    /// 書き込み中の区切り。書き終わるまでは送らない。
    var recording: URL? {
        get { lock.withLock { writing } }
        set { lock.withLock { writing = newValue } }
    }

    private var recordingNow = false
    /// 最後に iPhone を起こした時刻（2026-11-06）
    private var lastWake = Date.distantPast
    private var resting: Date?
    /// 最後に iPhone への受け渡しが終わった時刻（列が動いているかを見る。2026-11-16）
    private var lastFinished: Date?
    /// 受け渡しが終わった知らせ（didFinish）より先に「受け取った」が届いた区切り。
    /// 知らせのあとで控えに移すと、もう返事が来ないまま残るので、移さずに消す（2026-11-16）
    private var ackedEarly = Set<String>()

    /// 静かで書くのを休んでいるなら、休み始めた時刻。iPhone は、それより前の区切りが届いていれば待たない。
    var restingSince: Date? {
        get { lock.withLock { resting } }
        set { lock.withLock { resting = newValue } }
    }

    /// 録音しているかを iPhone に知らせる。iPhone は、時計の区切りが届くのを待ってから
    /// 同じ時間帯の iPhone の録音と聞き比べる。
    var isRecording: Bool {
        get { lock.withLock { recordingNow } }
        set {
            lock.withLock { recordingNow = newValue }
            publish()
            if newValue { wakePhone(force: true) }
        }
    }

    /// iPhone の LifeLog を起こす（2026-11-06）。
    /// 様子の知らせ（updateApplicationContext）や区切りの送り（transferFile）では、止まっている iPhone のアプリは起きない。
    /// sendMessage は、iPhone のアプリが止まっていても裏で起こせるので、録音を始めたときと、区切るたびに（2分に1回まで）送る。
    /// 起きた iPhone は待機モード（無音を流してアプリを起こしておく）に入り、届いた区切りをその場で文字にする。
    /// 時計の画面が消えているあいだは、ふつう「つながっている」（isReachable）にならないので起こせない（Apple の決まり）。
    /// そのため、つながったとき（画面を見た・iPhone が近くに来た）にも、届いていない区切りがあれば起こす（2026-11-07）
    func wakePhone(force: Bool = false, minGap: TimeInterval = 120) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        let now = Date.now
        let due = lock.withLock { () -> Bool in
            guard force || now.timeIntervalSince(lastWake) >= minGap else { return false }
            lastWake = now
            return true
        }
        guard due else { return }
        var message: [String: Any] = ["wake": true, "recording": isRecording, "at": now.timeIntervalSince1970,
                                      "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled]
        for (key, value) in deliveryState() { message[key] = value }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { _ in })
    }

    /// 時計の中に残っている区切りの様子（iPhone に知らせる。2026-11-07）。
    /// - kept: 送り終わって、iPhone の「受け取った」の返事を待っている数（前からある）
    /// - unsent: まだ送り終わっていない数（送っている途中を含む。書いている途中のものは除く）
    /// - outstanding: そのうち、WatchConnectivity が送っている途中の数
    /// - lastCut: 最後に区切った時刻（無音で捨てた区切りも含む。録音が本当に続いているかを iPhone が見分ける）
    /// - held: 時計が「録音を休む場所にいる」と思っているか（iPhone の思っていることと違えば、iPhone が設定を送り直す）
    /// - wanted: 止めるボタンを押さずに録音していた（録音しているつもり）か
    private func deliveryState() -> [String: Any] {
        // 家の PC に届いていて、iPhone が PC から受け取るのを待っている区切りは「まだ送っていない」に数えない
        // （わざと待っているので。別に relayHeld として知らせる。2026-11-15。強化案 64）
        let unsent = unsentFiles().map(\.lastPathComponent)
        let relay = WatchPC.relayOn || WatchPC.relayLater
        let now = Date.now
        let waiting = relay ? heldForRelay(unsent, now: now).count : 0
        var out: [String: Any] = ["kept": sentFiles().count, "unsent": unsent.count - waiting, "held": SilenceGate.held,
                                  "wanted": UserDefaults.standard.bool(forKey: Self.wantedKey)]
        if relay {
            out["relayHeld"] = waiting
            out["relayDone"] = WatchPC.relayDoneCount(now: now)
        }
        if WCSession.default.activationState == .activated {
            out["outstanding"] = WCSession.default.outstandingFileTransfers.count
        }
        let unstuck = UserDefaults.standard.integer(forKey: Self.unstuckKey)
        if unstuck > 0 { out["unstuck"] = unstuck }
        let lastCut = UserDefaults.standard.double(forKey: Self.lastCutKey)
        if lastCut > 0 { out["lastCut"] = lastCut }
        // 声らしい音が無いので捨てた区切りの数（今日。2026-11-16。VoiceGate）
        out["noVoiceDropped"] = VoiceGate.droppedToday()
        // 家の PC の外の道（Funnel。2026-11-07）: 使えるか・直近24時間に外の道で送れた数・合言葉が違うと言われたか
        out["pcPublic"] = WatchPC.hasPublicRoute
        // 直接送るがオンになっているか（iPhone が食い違いを見つけたら送り直す。2026-11-08）
        out["pcDirect"] = UserDefaults.standard.object(forKey: WatchDelivery.directKey) as? Bool ?? false
        out["pcPublicSent"] = WatchPC.publicSentCount()
        // いま直接送らない理由・最後に届かなかった理由（時刻つき。2026-11-10）
        if let skip = WatchPC.skipNote { out["pcSkip"] = skip }
        if let fail = WatchPC.failNote { out["pcFail"] = fail }
        if WatchPC.publicRefused { out["pcPublicRefused"] = true }
        // 最後に家の PC に直接送れた時刻（iPhone の「家の PC と音沙汰なし」の見張り。2026-11-15）
        if let sent = WatchPC.lastSentAt { out["pcSentAt"] = sent }
        // 休日のライフログ（2026-11-21。s19。HolidayRules）: 今日の中断と戻れた回数（休10）・電池の見本と外出モード（休8）・
        // 初めての人が多いモード（休17）。どれも省略できる（古い iPhone のアプリは読み飛ばす）
        let defaults = UserDefaults.standard
        let today = HolidayRules.dayKey(now)
        let counts = defaults.dictionary(forKey: Self.holidayCountsKey) as? [String: Int] ?? [:]
        out[HolidayRules.interruptionsKey] = HolidayRules.count(counts, HolidayRules.interruptionsKey, day: today)
        out[HolidayRules.resumedKey] = HolidayRules.count(counts, HolidayRules.resumedKey, day: today)
        // 止まりかけた回数・自動で戻せた回数・最後の理由・時計の build（2026-11-22。古い iPhone のアプリは読み飛ばす）
        out[HolidayRules.stallsKey] = HolidayRules.count(counts, HolidayRules.stallsKey, day: today)
        out[HolidayRules.autoResumedKey] = HolidayRules.count(counts, HolidayRules.autoResumedKey, day: today)
        if let last = defaults.string(forKey: HolidayRules.lastStallKey) { out[HolidayRules.lastStallKey] = last }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { out[HolidayRules.watchBuildKey] = build }
        if let samples = defaults.array(forKey: Self.batterySamplesKey) as? [[Double]], !samples.isEmpty {
            out[HolidayRules.batteryAtKey] = samples
        }
        if awayHolding { out[HolidayRules.awayHoldingKey] = true }
        if HolidayRules.crowdActive(until: defaults.double(forKey: Self.crowdUntilKey), now: now) { out[HolidayRules.crowdKey] = true }
        // s21（2026-11-22。S21Watch）: 今日録れた秒（使5）・アプリが終わっていた回数と最後のあいだ（守2）・
        // 片付けた返事待ち（速2）・ワークアウト扱いで守っているか（守3）・声の無い区切りの見本の数（精7）。どれも省ける
        out[S21Watch.recordedTodayKey] = Int(recordedToday(now: now).rounded())
        let exits = defaults.array(forKey: Self.exitsListKey) as? [[Double]] ?? []
        out[S21Watch.exitsKey] = S21Watch.exitsOn(exits, day: today)
        if let last = S21Watch.lastExitText(exits) { out[S21Watch.lastExitKey] = last }
        let cleared = defaults.integer(forKey: Self.keptClearedKey)
        if cleared > 0 { out[S21Watch.keptClearedKey] = cleared }
        if guarding { out[S21Watch.guardingKey] = true }
        out[S21Watch.sampledNoVoiceKey] = HolidayRules.count(counts, S21Watch.sampledNoVoiceKey, day: today)
        return out
    }

    // MARK: - s21（2026-11-22。S21Watch・docs/s21-app.md）

    /// いまワークアウト扱いで守っているか（WatchGuard が入れる。守3）
    var guarding: Bool {
        get { lock.withLock { guardingNow } }
        set { lock.withLock { guardingNow = newValue } }
    }
    private var guardingNow = false

    /// 今日録れた秒（"日" → 秒。使5）
    static let recordedKey = "s21.recorded"
    /// 録音しているつもりのまま終わっていたあいだ（[[最後に動いていた秒, 起き直した秒]]。守2）
    static let exitsListKey = "s21.exits"
    /// 最後に動いていた時刻（区切り・休みの知らせのたび。守2）
    static let aliveKey = "s21.alive"
    /// 片付けた返事待ちの数（速2）
    static let keptClearedKey = "s21.keptCleared"
    /// 最後に iPhone への受け渡しが終わった時刻（1970 からの秒。使5）
    static let lastDeliveredKey = "s21.lastDelivered"
    /// 声の無い区切りの見本にした名前（名前 → 時刻。精7）
    static let noVoiceSamplesKey = "s21.noVoiceSamples"

    /// 区切りの録れた秒を今日に足す（WatchRecorder が区切るたびに呼ぶ）
    func noteRecorded(_ seconds: TimeInterval, now: Date = .now) {
        lock.withLock {
            let saved = UserDefaults.standard.dictionary(forKey: Self.recordedKey) as? [String: Double] ?? [:]
            UserDefaults.standard.set(S21Watch.addingSeconds(saved, day: HolidayRules.dayKey(now), seconds: seconds),
                                      forKey: Self.recordedKey)
        }
    }

    /// 今日録れた秒
    func recordedToday(now: Date = .now) -> TimeInterval {
        let saved = UserDefaults.standard.dictionary(forKey: Self.recordedKey) as? [String: Double] ?? [:]
        return saved[HolidayRules.dayKey(now)] ?? 0
    }

    /// 最後に届いた時刻（iPhone への受け渡しが終わった・家の PC に直接届いた、の新しいほう。使5）
    func lastDelivered() -> Date? {
        let phone = UserDefaults.standard.double(forKey: Self.lastDeliveredKey)
        let latest = max(phone, WatchPC.lastSentAt ?? 0)
        return latest > 0 ? Date(timeIntervalSince1970: latest) : nil
    }

    /// 動いていた印（区切り・休みの知らせのたび。守2）
    func noteAlive(now: Date = .now) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.aliveKey)
    }

    /// 起き直したときに呼ぶ（録音しているつもりのまま終わっていたら、そのあいだを残す。守2）
    func noteRelaunch(now: Date = .now) {
        let defaults = UserDefaults.standard
        let alive = defaults.object(forKey: Self.aliveKey) as? Double
        let list = defaults.array(forKey: Self.exitsListKey) as? [[Double]] ?? []
        defaults.set(S21Watch.addingExit(list, alive: alive, relaunch: now.timeIntervalSince1970), forKey: Self.exitsListKey)
        noteAlive(now: now)
    }

    /// 声が無いので捨てるはずだった区切りを、見本として残す（精7）
    static func markNoVoiceSample(_ name: String, now: Date = .now) {
        let saved = UserDefaults.standard.dictionary(forKey: noVoiceSamplesKey) as? [String: Double] ?? [:]
        UserDefaults.standard.set(S21Watch.addingSample(saved, name: name, now: now), forKey: noVoiceSamplesKey)
    }

    /// 見本の区切りか（送り直しでも印を付ける）
    static func isNoVoiceSample(_ name: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: noVoiceSamplesKey) as? [String: Double])?[name] != nil
    }

    /// 最後に返事待ちを片付けた時刻（30 分に 1 回まで）
    private var tidiedAt = Date.distantPast

    /// 1 日を過ぎて家の PC に届いている返事待ち・iPhone が「受け取った」と言った返事待ちを片付ける（速2）。
    /// phoneHas は iPhone が受け取ったと覚えている時計の名前（gotList。無ければ空）
    func tidyKept(phoneHas: Set<String> = [], now: Date = .now, force: Bool = false) {
        let due = lock.withLock { () -> Bool in
            guard force || now.timeIntervalSince(tidiedAt) >= 30 * 60 else { return false }
            tidiedAt = now
            return true
        }
        guard due else { return }
        var cleared = 0
        for url in sentFiles() {
            let name = url.lastPathComponent
            let age = Self.cutTime(url).map { now.timeIntervalSince($0) }
            guard S21Watch.tidyKept(cutAge: age, sentToPC: WatchPC.wasSent(name), phoneHas: phoneHas.contains(name)) else { continue }
            acknowledged(name)
            cleared += 1
        }
        guard cleared > 0 else { return }
        lock.withLock {
            let total = UserDefaults.standard.integer(forKey: Self.keptClearedKey) + cleared
            UserDefaults.standard.set(total, forKey: Self.keptClearedKey)
        }
        onChange?()
    }

    /// iPhone が受け取ったと覚えている名前（iPhone で付く名前）を、時計の名前に直す
    private func watchNames(_ phoneNames: [String]) -> Set<String> {
        let phoneZone = UserDefaults.standard.string(forKey: WatchDelivery.phoneZoneKey)
            .flatMap(TimeZone.init(identifier:)) ?? .current
        return Set(phoneNames.compactMap { WatchDelivery.watchName($0, watchZone: .current, phoneZone: phoneZone) })
    }

    // MARK: - 休日のライフログ（2026-11-21。s19。HolidayRules）

    /// 今日の数（"日|名前" → 回数。中断・戻れた回数）
    static let holidayCountsKey = "holidayCounts"
    /// 電池の見本（[[時刻, 0〜1, 溜めていたら 1]]）
    static let batterySamplesKey = "batterySamples"
    /// 「初めての人が多い」モードが終わる時刻（1970 からの秒。0 なら切れている）
    static let crowdUntilKey = "crowdUntil"

    /// 今日の数を 1 つ足す（中断・戻れた。WatchRecorder が呼ぶ。休10）
    func countToday(_ name: String, now: Date = .now) {
        lock.withLock {
            let saved = UserDefaults.standard.dictionary(forKey: Self.holidayCountsKey) as? [String: Int] ?? [:]
            UserDefaults.standard.set(HolidayRules.bumped(saved, name, day: HolidayRules.dayKey(now)), forKey: Self.holidayCountsKey)
        }
    }

    /// 止まりかけた時刻と理由を残す（次の様子で iPhone → 家の PC へ。2026-11-22）
    func noteStall(_ code: String, now: Date = .now) {
        UserDefaults.standard.set("\(Int(now.timeIntervalSince1970))|\(code)", forKey: HolidayRules.lastStallKey)
    }

    /// 外出モードで区切りを溜めているか（設定がオン・iPhone が「家を出ている」・充電していない。休8）
    var awayHolding: Bool {
        let defaults = UserDefaults.standard
        return HolidayRules.awayHold(mode: defaults.bool(forKey: HolidayRules.awayModeKey),
                                     away: defaults.bool(forKey: HolidayRules.awayKey),
                                     charging: currentBattery()?.charging ?? false)
    }

    /// 1 時間に 1 つ、電池の残りを見本に足す（外出モードの前後の減りを比べられるように。休8）
    private func sampleBattery(now: Date = .now) {
        guard let battery = currentBattery() else { return }
        let holding = awayHolding
        lock.withLock {
            let defaults = UserDefaults.standard
            let samples = defaults.array(forKey: Self.batterySamplesKey) as? [[Double]] ?? []
            guard HolidayRules.batterySampleDue(last: samples.last?.first, now: now) else { return }
            defaults.set(HolidayRules.addingSample(samples, time: now, level: battery.level, holding: holding,
                                                   charging: battery.charging),
                         forKey: Self.batterySamplesKey)
        }
    }

    /// お酒を 1 杯（休30）。iPhone が離れていても、つながったときに届く
    func drink(_ time: Date) { queueInfo(["drink": time.timeIntervalSince1970]) }

    /// WatchRecorder が「録音中だった」を残す名前（WatchRecorder.wasRecordingKey と同じ）
    private static let wantedKey = "wasRecording"
    private static let lastCutKey = "lastCut"

    /// 区切った（無音で捨てたものも含む）。最後に区切った時刻を残す
    func noteCut(at date: Date = .now) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastCutKey)
    }

    private func publish() {
        guard WCSession.default.activationState == .activated else { return }
        var context: [String: Any] = ["recording": isRecording, "at": Date.now.timeIntervalSince1970,
                                      "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled]
        if let since = restingSince { context["resting"] = since.timeIntervalSince1970 }
        // 電池の残りと充電中か（iPhone が抜けの理由と、電池が切れそうな時刻を出すのに使う）
        if let battery = lock.withLock({ batteryInfo }) {
            context["battery"] = battery.level
            context["charging"] = battery.charging
        }
        for (key, value) in deliveryState() { context[key] = value }
        try? WCSession.default.updateApplicationContext(context)
    }

    /// 区切るたびに呼ぶ。iPhone は、しばらく知らせが無いと「止まっているかも」と通知する。
    func heartbeat() {
        sampleBattery()
        noteAlive()
        // 1 日を過ぎた返事待ちを片付ける（30 分に 1 回まで。2026-11-22。s21 の 速2）
        tidyKept()
        publish()
        // 送れずに残っている区切りを送る（つながる前に区切った・低電力モードで溜めた・低電力モードを切った。2026-11-07）
        unstickTransfers()
        flushIfDue()
        resendUnacknowledged()
        // 録音中・まだ届いていない区切りがあるときは、iPhone のアプリを起こしておく
        if isRecording || unsentCount() > 0 || !WCSession.default.outstandingFileTransfers.isEmpty { wakePhone() }
    }

    /// 「初めての人と話している」の印を iPhone に送る（その前後の知らない声を、確かめ待ちに出す）
    func newPerson(_ time: Date) { queueInfo(["newPerson": time.timeIntervalSince1970]) }

    /// 「違う、〇〇さん」（2026-11-19。s18）。iPhone が離れていても、つながったときに届く
    func voiceFix(_ text: String, at time: Date) { queueInfo(["voiceFix": text, "at": time.timeIntervalSince1970]) }

    /// iPhone に「さっき何て言った？」と聞く（iPhone が近くにあるときだけ）
    func askRecent(_ done: @escaping @Sendable (String) -> Void) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            done("iPhone とつながっていません。iPhone を近くに置いてください。")
            return
        }
        WCSession.default.sendMessage(["ask": "recent"], replyHandler: { reply in
            done(reply["answer"] as? String ?? "答えがありませんでした。")
        }, errorHandler: { error in
            done("聞けませんでした: \(error.localizedDescription)")
        })
    }

    // MARK: - 時計のアプリの頼まれごと・聞く（2026-11-07）

    /// 頼まれごとを「済み」にしたと iPhone に送る。iPhone が近くに無ければ、つながったときに送る
    func taskDone(_ id: String) {
        let message: [String: Any] = ["taskDone": id]
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            queueInfo(message)
            return
        }
        WCSession.default.sendMessage(message, replyHandler: { _ in }, errorHandler: { [weak self] _ in
            self?.queueInfo(message)
        })
    }

    /// iPhone の記録に質問する。iPhone はすぐ「調べています」と返し、答えはあとで transferUserInfo で届く（onAnswer）
    func askQuestion(_ question: String, _ done: @escaping @Sendable (String) -> Void) {
        let message: [String: Any] = ["ask": "q:" + question]
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            queueInfo(message)
            done("iPhone とつながっていません。つながったら答えが届きます。")
            return
        }
        WCSession.default.sendMessage(message, replyHandler: { reply in
            done(reply["answer"] as? String ?? "調べています")
        }, errorHandler: { [weak self] _ in
            self?.queueInfo(message)
            done("iPhone にあとで届けます。答えはそのあとで届きます。")
        })
    }

    /// 会議モードを始める・終える（iPhone が予定の参加者と議題をヒントにする）
    func meeting(_ on: Bool) { queueInfo(["meeting": on, "at": Date.now.timeIntervalSince1970]) }

    /// つながっていなければ溜めておき、つながったときに送る
    private func queueInfo(_ info: [String: Any]) {
        guard WCSession.default.activationState == .activated else {
            var list = UserDefaults.standard.array(forKey: "queuedInfo") as? [[String: Any]] ?? []
            list.append(info)
            UserDefaults.standard.set(list, forKey: "queuedInfo")
            return
        }
        WCSession.default.transferUserInfo(info)
    }

    private func flushQueuedInfo() {
        let list = UserDefaults.standard.array(forKey: "queuedInfo") as? [[String: Any]] ?? []
        guard !list.isEmpty, WCSession.default.activationState == .activated else { return }
        UserDefaults.standard.removeObject(forKey: "queuedInfo")
        for info in list { WCSession.default.transferUserInfo(info) }
    }

    // MARK: - 送った区切りの控え（2026-11-06）

    private func sentFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.sentDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }
    }

    private func isInSentDir(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == Self.sentDir.standardizedFileURL.path
    }

    /// 送り終わった区切りを控えに移す（返事をしない古い iPhone のアプリなら消す）
    private func keepSent(_ url: URL) {
        guard Self.phoneAcks else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // 送り直した控えは、もう控えの中にある
        guard !isInSentDir(url) else { return }
        // 「受け取った」が先に届いていれば、控えに移さずに消す（2026-11-16）
        if lock.withLock({ ackedEarly.remove(url.lastPathComponent) != nil }) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let dest = Self.sentDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: url, to: dest)) != nil else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        lock.withLock {
            var sentAt = UserDefaults.standard.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:]
            sentAt[url.lastPathComponent] = Date.now.timeIntervalSince1970
            UserDefaults.standard.set(sentAt, forKey: Self.sentAtKey)
        }
        pruneSent()
    }

    /// iPhone が受け取ったので、控えを消す
    private func acknowledged(_ name: String) {
        let kept = Self.sentDir.appendingPathComponent(name)
        // 控えにまだ無く、送っている途中（まだ「送っていない」フォルダにある）なら、終わった知らせのあとで消す（2026-11-16）
        if !FileManager.default.fileExists(atPath: kept.path),
           FileManager.default.fileExists(atPath: Self.pendingDir.appendingPathComponent(name).path) {
            lock.withLock {
                if ackedEarly.count > 500 { ackedEarly.removeAll() }
                ackedEarly.insert(name)
            }
        }
        try? FileManager.default.removeItem(at: kept)
        lock.withLock {
            var sentAt = UserDefaults.standard.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:]
            var resent = UserDefaults.standard.dictionary(forKey: Self.resentKey) as? [String: Int] ?? [:]
            sentAt[name] = nil
            resent[name] = nil
            UserDefaults.standard.set(sentAt, forKey: Self.sentAtKey)
            UserDefaults.standard.set(resent, forKey: Self.resentKey)
        }
    }

    // MARK: - 音声は家の PC から iPhone へ（2026-11-15。強化案 64。WatchDelivery の同じ見出し）

    /// 家の PC に届いていて（送っている途中で）、iPhone が PC から受け取るのを待っている区切りか。
    /// startedNow は、いま PC に送り始めたところか
    /// iPhone に送らずに待つ区切り（PC に届いたもの・送っている途中のもの。数の上限つき。WatchDelivery.relayHeld）。
    /// started は、いま PC に送り始めた区切り
    private func heldForRelay(_ names: [String], started: String? = nil, now: Date = .now) -> Set<String> {
        let relay = WatchPC.relayOn, later = WatchPC.relayLater
        guard relay || later else { return [] }
        let sent = WatchPC.sentTimes()
        let files = names.map { (name: $0, sentToPC: sent[$0], sending: $0 == started || pc.isSending($0)) }
        return WatchDelivery.relayHeld(files, relay: relay, later: later, now: now)
    }

    /// iPhone が家の PC から音声を受け取ったので、時計の中の同じ区切りを消す（まだ送っていないものも、返事待ちの控えも）。
    /// iPhone に送っている途中なら、取りやめる。名前は iPhone で付く名前で届くので、時計の名前に直して探す
    private func acknowledgedViaPC(_ phoneName: String) {
        let phoneZone = UserDefaults.standard.string(forKey: WatchDelivery.phoneZoneKey)
            .flatMap(TimeZone.init(identifier:)) ?? .current
        guard let name = WatchDelivery.watchName(phoneName, watchZone: .current, phoneZone: phoneZone),
              recording?.lastPathComponent != name else { return }
        if WCSession.isSupported(), WCSession.default.activationState == .activated {
            for transfer in WCSession.default.outstandingFileTransfers
            where transfer.file.fileURL.lastPathComponent == name {
                transfer.cancel()
            }
        }
        let pending = Self.pendingDir.appendingPathComponent(name)
        let had = FileManager.default.fileExists(atPath: pending.path)
            || FileManager.default.fileExists(atPath: Self.sentDir.appendingPathComponent(name).path)
        try? FileManager.default.removeItem(at: pending)
        // 控えと、送り直しの覚えを消す（「受け取った」の返事と同じ）
        acknowledged(name)
        if had { WatchPC.noteRelayDone(name) }
    }

    /// 送ってから30分たっても返事の無い区切りを、送り直す（30分ごとに3回まで。そのあとは6時間ごと。2026-11-07）。
    /// 前は送り直した時刻を残していなかったので、30分たつと3回を数分のうちに使い切り、そのあとは送らなかった
    func resendUnacknowledged() {
        guard Self.phoneAcks, WCSession.isSupported(), WCSession.default.activationState == .activated, !awayHolding else { return }
        let transfers = WCSession.default.outstandingFileTransfers
        // 受け渡しの列が混んでいれば、送り直しは待つ（新しい区切りを先に通す。2026-11-09）。
        // ただし、列に残り続けている古いもの（終わらない受け渡し）は、列が動いているあいだは数えない（2026-11-16。
        // 前は列がいつも 10 個以上で、送り直しが一度も動かなかった。WatchDelivery.resendAllowed）
        let queued = transfers.map { transfer -> Date? in
            (transfer.file.metadata?[WatchDelivery.sentKey] as? Double).map { Date(timeIntervalSince1970: $0) }
        }
        guard WatchDelivery.resendAllowed(queued: queued, limit: Self.resendQueueLimit,
                                          lastFinished: lock.withLock { lastFinished }, now: .now) else { return }
        let outstanding = Set(transfers.map { $0.file.fileURL.lastPathComponent })
        var budget = Self.resendPerPass
        let stored = lock.withLock {
            (sentAt: UserDefaults.standard.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:],
             resent: UserDefaults.standard.dictionary(forKey: Self.resentKey) as? [String: Int] ?? [:])
        }
        var counts = stored.resent
        var sentAt = stored.sentAt
        let now = Date.now
        // 新しい順（名前は区切った時刻）。古い控えは、新しいものが届いたあとで送る
        for url in sentFiles().sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard budget > 0 else { break }
            let name = url.lastPathComponent
            guard !outstanding.contains(name) else { continue }
            let count = counts[name] ?? 0
            let sent = sentAt[name].map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            // 3日より古い控えは送り直さない（iPhone が覚えているのは4日。それより古いと、文字にし直してしまう。2026-11-16）
            guard WatchDelivery.resendDue(sentAgo: now.timeIntervalSince(sent), count: count,
                                          cutAge: Self.cutTime(url).map { now.timeIntervalSince($0) },
                                          resendAfter: Self.resendAfter, maxResends: Self.maxResends,
                                          slowResendAfter: Self.slowResendAfter) else { continue }
            counts[name] = count + 1
            sentAt[name] = now.timeIntervalSince1970
            budget -= 1
            WCSession.default.transferFile(url, metadata: WatchDelivery.metadata(
                zone: .current, cut: Self.cutTime(url), sent: now, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                viaPC: WatchPC.wasSent(name), resend: count + 1, sampleNoVoice: Self.isNoVoiceSample(name)))
        }
        guard counts != stored.resent else { return }
        lock.withLock {
            // 控えの時刻は、ほかの糸（返事の受け取り）も書くので、読み直して足す
            var savedAt = UserDefaults.standard.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:]
            var savedCounts = UserDefaults.standard.dictionary(forKey: Self.resentKey) as? [String: Int] ?? [:]
            for (name, count) in counts where count != stored.resent[name] {
                // 返事が来て消えた区切りは、書き戻さない
                guard FileManager.default.fileExists(atPath: Self.sentDir.appendingPathComponent(name).path) else { continue }
                savedCounts[name] = count
                savedAt[name] = sentAt[name]
            }
            UserDefaults.standard.set(savedAt, forKey: Self.sentAtKey)
            UserDefaults.standard.set(savedCounts, forKey: Self.resentKey)
        }
    }

    /// 返事待ちの控えを、回数にかかわらずすぐ送り直す（iPhone から頼まれた・iPhone のアプリが入れ直された。2026-11-07）。
    /// 送ってから minAge より新しいものは、返事がまだ届いていないだけかもしれないので送らない。
    /// iPhone は、もう受け取った区切りなら返事だけして捨てるので、送り直しても二重にはならない
    func resendKept(minAge: TimeInterval = 300) {
        guard Self.phoneAcks else { return }
        let names = sentFiles().map(\.lastPathComponent)
        guard !names.isEmpty else { return }
        let now = Date.now.timeIntervalSince1970
        lock.withLock {
            var sentAt = UserDefaults.standard.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:]
            var resent = UserDefaults.standard.dictionary(forKey: Self.resentKey) as? [String: Int] ?? [:]
            for name in names where now - (sentAt[name] ?? 0) >= minAge {
                resent[name] = 0
                sentAt[name] = 0
            }
            UserDefaults.standard.set(sentAt, forKey: Self.sentAtKey)
            UserDefaults.standard.set(resent, forKey: Self.resentKey)
        }
        resendUnacknowledged()
    }

    /// 古い控え（7日より前。keepSentFor。2026-11-07 に3日から7日へ）と、300MB を超えた分（古いものから）を消す。
    /// 日付は区切りを書き終えた時刻（控えに移しても変わらない）。送り終わって控えに移すたびに呼ぶ
    private func pruneSent() {
        let files = sentFiles().map { url -> (url: URL, date: Date, size: Int) in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }.sorted { $0.date > $1.date }
        var total = 0
        for file in files {
            total += file.size
            if total > Self.keepSentBytes || Date.now.timeIntervalSince(file.date) > Self.keepSentFor {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    /// 時計の空き（バイト）。分からなければ nil
    static func freeSpace() -> Int64? {
        // watchOS には「大事な用途の空き」が無いので、ふつうの空き
        (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
    }

    /// 「印」を iPhone に送る。つながっていなければ、つながったときに送る。
    func mark(_ time: Date) {
        lock.withLock { marks.append(time.timeIntervalSince1970) }
        flushMarks()
    }

    private var marks: [Double] = UserDefaults.standard.array(forKey: "marks") as? [Double] ?? []

    private func flushMarks() {
        guard WCSession.default.activationState == .activated else {
            UserDefaults.standard.set(lock.withLock { marks }, forKey: "marks")
            return
        }
        let list = lock.withLock {
            defer { marks = [] }
            return marks
        }
        for time in list { WCSession.default.transferUserInfo(["mark": time]) }
        UserDefaults.standard.set([Double](), forKey: "marks")
    }

    /// 書き終わった区切りを送る。低電力モードなら、溜まるか、いちばん古いものが15分待つまで待ってからまとめて送る。
    func deliver(_ url: URL) {
        // 外出モードで溜めているあいだは送らない（2026-11-21。s19 の 休8。家に戻るか充電を始めたら flushIfDue が送る）
        if awayHolding { return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            flushIfDue()
        } else {
            send(url)
            // 時計に残っていて、まだ家の PC に送っていない古い区切りも追いかけて送る（いま送っている区切りが終わってから。2026-11-07）
            pc.catchUp()
        }
    }

    /// まだ送っていない区切りを、送ってよければ送る（区切るたび・静かで休んでいるあいだ5分ごと・つながったとき）。
    /// ふだんはすぐ送る。低電力モードでは、数が溜まったか、いちばん古いものが15分待ったときだけ（2026-11-07）
    func flushIfDue(now: Date = .now) {
        let files = unsentFiles()
        guard !files.isEmpty else { return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            let oldest = files.compactMap { Self.cutTime($0) }.min()
            guard WatchDelivery.lowPowerDue(count: files.count, batch: Self.batch, oldest: oldest, now: now) else { return }
        }
        resendPending()
    }

    /// 区切りを閉じた時刻（ファイルを書き終えた時刻。控えに移しても変わらない）
    static func cutTime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// held は、まとめて送るときに先に数えた「待つ区切り」（無ければここで数える）
    func send(_ url: URL, held: Set<String>? = nil) {
        // 外出モードで溜めているあいだは、iPhone にも家の PC にも送らない（家に戻るか充電を始めたら送る。2026-11-21。s19 の 休8）
        if awayHolding { return }
        let active = WCSession.default.activationState == .activated
        if active, WCSession.default.outstandingFileTransfers.contains(where: { $0.file.fileURL == url }) { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        // 家の Wi-Fi にいるときは、家の PC にも直接送る（電池の決まりは WatchDelivery.directAllowed。2026-11-07）
        let battery = lock.withLock { batteryInfo }
        let direct = pc.send(url, lowPower: lowPower, battery: battery?.level, charging: battery?.charging ?? false)
        guard active else { return }
        // 家の PC に届いた（送っている途中の）区切りは、iPhone が PC から受け取るのを少し待つ（2026-11-15。強化案 64）。
        // 「受け取った」（gotPC）が来れば、iPhone には送らずに済む。来なければ、待つ時間が過ぎたあとの次の見回り
        // （区切るたびの heartbeat → resendPending）で、今までどおり iPhone に送る。PC に送れなかった区切りは待たない
        let name = url.lastPathComponent
        if (WatchPC.relayOn || WatchPC.relayLater) && direct { return }
        if (held ?? heldForRelay(unsentFiles().map(\.lastPathComponent), now: .now)).contains(name) { return }
        // 名前の時刻は時計の時間帯。iPhone が自分の時間帯に直せるよう、時間帯も送る（2026-11-06）。
        // 区切った時刻と送り始めた時刻も添える（iPhone が「時計で待った」と「受け渡し」を分けて測る。2026-11-07）
        WCSession.default.transferFile(url, metadata: WatchDelivery.metadata(
            zone: .current, cut: Self.cutTime(url), sent: .now, lowPower: lowPower,
            viaPC: direct || WatchPC.wasSent(url.lastPathComponent), sampleNoVoice: Self.isNoVoiceSample(name)))
    }

    /// 受け渡しの列に止まったままの区切りを取り消す（2026-11-20。WatchDelivery.stuckTransfers）。
    /// 取り消した区切りは「まだ送っていない」に残るので、次の resendPending が送り直す。
    /// 古すぎて家の PC には届いているものだけは、送り直さずに控えへ移す（控えは 7 日で消える）
    func unstickTransfers(now: Date = .now) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let transfers = WCSession.default.outstandingFileTransfers
        let queued = transfers.map { transfer -> (name: String, sent: Date?, cut: Date?) in
            let name = transfer.file.fileURL.lastPathComponent
            let sent = (transfer.file.metadata?[WatchDelivery.sentKey] as? Double).map { Date(timeIntervalSince1970: $0) }
            return (name, sent, Self.cutTime(transfer.file.fileURL))
        }
        let stuck = Set(WatchDelivery.stuckTransfers(queued, now: now))
        guard !stuck.isEmpty else { return }
        let current = recording?.lastPathComponent
        for transfer in transfers where stuck.contains(transfer.file.fileURL.lastPathComponent) {
            transfer.cancel()
        }
        for name in stuck where name != current {
            let url = Self.pendingDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let cutAge = Self.cutTime(url).map { now.timeIntervalSince($0) }
            if WatchDelivery.retireInsteadOfResend(cutAge: cutAge, sentToPC: WatchPC.wasSent(name)) {
                keepSent(url)
            }
        }
        lock.withLock {
            let total = UserDefaults.standard.integer(forKey: Self.unstuckKey) + stuck.count
            UserDefaults.standard.set(total, forKey: Self.unstuckKey)
        }
        onChange?()
    }

    /// 取り消した受け渡しの数（これまでの合計。様子に出す）
    private static let unstuckKey = "unstuckTransfers"

    /// 前回送れなかった区切りを送り直す。書き込み中のファイルと、送っている途中のファイルは送らない。
    func resendPending() {
        let outstanding: Set<String> = WCSession.default.activationState == .activated
            ? Set(WCSession.default.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent }) : []
        let files = unsentFiles()
        let held = heldForRelay(files.map(\.lastPathComponent))
        for url in files where !outstanding.contains(url.lastPathComponent) {
            // 書いている途中でアプリが終わった区切りは開けない（iPhone でも読めない）ので消す
            guard (try? AVAudioFile(forReading: url)) != nil else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            send(url, held: held)
        }
    }

    /// まだ iPhone に届いていない区切り（書き込み中のものを除く）
    private func unsentFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.pendingDir, includingPropertiesForKeys: nil)) ?? []
        // URL どうしで比べると、同じファイルでも書き方（/private/var と /var など）が違って一致しないことがある。
        // 名前で比べる（2026-11-08。書いている途中の区切りを PC に送ったり、開けないとして消したりしていた）
        let current = recording?.lastPathComponent
        return urls.filter { $0.pathExtension == "m4a" && $0.lastPathComponent != current }
    }

    /// まだ送っていない区切りの数（家の PC に届いていて iPhone が PC から受け取るのを待っているものは除く。2026-11-18）
    func unsentCount() -> Int {
        let names = unsentFiles().map(\.lastPathComponent)
        return names.count - heldForRelay(names).count
    }

    /// 家の PC に届いていて、iPhone が PC から受け取るのを待っている区切りの数（2026-11-18）
    func relayHeldCount() -> Int { heldForRelay(unsentFiles().map(\.lastPathComponent)).count }

    /// iPhone とのつながりを、画面に出せる一文にする。
    func linkText() -> String {
        guard WCSession.isSupported() else { return "iPhone と通信できません" }
        let session = WCSession.default
        guard session.activationState == .activated else { return "iPhone との接続を準備中" }
        guard session.isCompanionAppInstalled else { return "iPhone の LifeLog と組になっていません" }
        return session.isReachable ? "iPhone とつながっています" : "iPhone の LifeLog は入っています"
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated {
            Self.readSettings(session.receivedApplicationContext)
            if let info = session.receivedApplicationContext["watchInfo"] as? Data { onInfo?(info) }
            flushIfDue()
            publish()
            flushMarks()
            flushQueuedInfo()
            resendUnacknowledged()
        }
        onChange?()
    }

    /// iPhone からの返事（受け取った区切り）と知らせ
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let got = userInfo["got"] as? String { acknowledged(got) }
        // iPhone が家の PC から音声を受け取った（時計からは送らなくてよい。2026-11-15。強化案 64）
        if let got = userInfo[WatchDelivery.relayGotKey] as? String { acknowledgedViaPC(got) }
        if let alert = userInfo["alert"] as? String { onAlert?(alert) }
        // 家の PC の家の中の住所と合言葉（合言葉は時計の Keychain に置く。2026-11-07。WatchPC）
        WatchPC.applyCredentials(userInfo)
        // iPhone から「時計に残っている区切りを全部送り直して」（iPhone のアプリが起動したとき・区切りが届かないとき。2026-11-07）
        if userInfo[Self.resendRequestKey] as? Bool == true {
            resendPending()
            resendKept()
            publish()
        }
        if let answer = userInfo["answer"] as? String { onAnswer?(answer, userInfo["question"] as? String ?? "") }
        // iPhone が受け取ったと覚えている名前の一覧（返事が届かなかった控えを片付ける。2026-11-22。s21 の 速2）
        if let list = userInfo[S21Watch.gotListKey] as? [String] { tidyKept(phoneHas: watchNames(list), force: true) }
        onChange?()
    }

    /// iPhone の設定（無音のあいだは書かない、など）を受け取る
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Self.readSettings(applicationContext)
        if let info = applicationContext["watchInfo"] as? Data { onInfo?(info) }
        // 家に戻った・外出モードを切った（2026-11-21。休8）: 溜めていた区切りを送る
        if !awayHolding { flushIfDue() }
        onChange?()
    }

    static func readSettings(_ context: [String: Any]) {
        if let skip = context["skipSilence"] as? Bool { UserDefaults.standard.set(skip, forKey: "skipSilence") }
        if let held = context["held"] as? Bool { SilenceGate.held = held }
        if let acks = context["acks"] as? Bool { UserDefaults.standard.set(acks, forKey: "phoneAcks") }
        // 会議モードのあいだは、録音の音質を上げる（次の区切りから）
        if let meeting = context["meeting"] as? Bool { UserDefaults.standard.set(meeting, forKey: "meetingOn") }
        // 区切りの長さ（短め・ふつう）と「電池が少ないときは5分に」（次の区切りから。2026-11-07）
        ChunkCutter.readSettings(context)
        // 家の PC に直接送るか・聞き取りのヒント・iPhone の時間帯（2026-11-07。WatchPC）
        WatchPC.applyContext(context)
        // 休日のライフログ（2026-11-21。s19）: 今日が休みか・電池の知らせ・外出モード・家を出ているか・車につないだ時刻
        let defaults = UserDefaults.standard
        if let day = context[HolidayRules.holidayDayKey] as? String { defaults.set(day, forKey: HolidayRules.holidayDayKey) }
        for key in [HolidayRules.lowBatteryKey, HolidayRules.awayModeKey, HolidayRules.awayKey] {
            if let on = context[key] as? Bool { defaults.set(on, forKey: key) }
        }
        if let since = context[HolidayRules.carSinceKey] as? Double { defaults.set(since, forKey: HolidayRules.carSinceKey) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil {
            lock.withLock { lastFinished = .now }
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastDeliveredKey)
            keepSent(fileTransfer.file.fileURL)
        }
        onChange?()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        // つながった（時計の画面を見た・iPhone が近くに来た）とき、録音中か届いていない区切りがあれば、
        // iPhone のアプリを起こして、溜まっていた区切りを受け取ってもらう（2026-11-07）
        if session.activationState == .activated, session.isReachable,
           isRecording || unsentCount() > 0 || !session.outstandingFileTransfers.isEmpty {
            wakePhone(minGap: 15)
            flushIfDue()
        }
        onChange?()
    }
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        // iPhone のアプリが入れ直された（TestFlight で入れ替えたなど）。前のアプリが受け取れなかった区切りがあるかもしれないので、
        // まだ送っていないものと返事待ちの控えを、全部送り直す（2026-11-07）
        if session.activationState == .activated, session.isCompanionAppInstalled {
            resendPending()
            resendKept(minAge: 0)
            publish()
        }
        onChange?()
    }

    /// iPhone からの「残っている区切りを送り直して」の名前（PhoneReceiver.askWatchToResend と同じ）
    static let resendRequestKey = "resendKept"
}

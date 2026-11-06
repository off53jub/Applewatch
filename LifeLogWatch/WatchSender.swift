import AVFoundation
import Foundation
import WatchConnectivity
import WatchKit

/// 録音した区切りを iPhone に送る。
/// iPhone が近くに無いときは WatchConnectivity が溜めておき、つながったときに送る。
/// 時計が低電力モードのときは、無線を起こす回数を減らすため、3つ（15分ほど）溜まってからまとめて送る。
/// 送り終わった区切りは「送った」フォルダに控えとして残し、iPhone が「受け取った」と返事したら消す（2026-11-06）。
/// 30分たっても返事が無ければ送り直す（3回まで）。控えは3日・300MB まで。
/// 返事をしない古い iPhone のアプリには、今までどおり送り終わったら消す。
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
    /// 控えを残す長さと大きさ
    static let keepSentFor: TimeInterval = 72 * 3600
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

    /// 低電力モードで、これだけ溜まったらまとめて送る
    private static let batch = 3

    /// 送れた・つながりが変わったときに呼ぶ（画面の数を出し直す）
    var onChange: (@Sendable () -> Void)?

    /// iPhone から届いた知らせ（こもり・音割れなど）。時計を震わせて画面に出す
    var onAlert: (@Sendable (String) -> Void)?

    @MainActor
    func activate() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        readBattery()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var batteryInfo: (level: Double, charging: Bool)?

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
    func wakePhone(force: Bool = false) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        let now = Date.now
        let due = lock.withLock { () -> Bool in
            guard force || now.timeIntervalSince(lastWake) >= 120 else { return false }
            lastWake = now
            return true
        }
        guard due else { return }
        let message: [String: Any] = ["wake": true, "recording": isRecording, "at": now.timeIntervalSince1970,
                                      "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
                                      "kept": sentFiles().count]
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { _ in })
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
        context["kept"] = sentFiles().count
        try? WCSession.default.updateApplicationContext(context)
    }

    /// 区切るたびに呼ぶ。iPhone は、しばらく知らせが無いと「止まっているかも」と通知する。
    func heartbeat() {
        publish()
        resendUnacknowledged()
        // 録音中・まだ届いていない区切りがあるときは、iPhone のアプリを起こしておく
        if isRecording || unsentCount() > 0 || !WCSession.default.outstandingFileTransfers.isEmpty { wakePhone() }
    }

    /// 「初めての人と話している」の印を iPhone に送る（その前後の知らない声を、確かめ待ちに出す）
    func newPerson(_ time: Date) { queueInfo(["newPerson": time.timeIntervalSince1970]) }

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
        try? FileManager.default.removeItem(at: Self.sentDir.appendingPathComponent(name))
        lock.withLock {
            var sentAt = UserDefaults.standard.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:]
            var resent = UserDefaults.standard.dictionary(forKey: Self.resentKey) as? [String: Int] ?? [:]
            sentAt[name] = nil
            resent[name] = nil
            UserDefaults.standard.set(sentAt, forKey: Self.sentAtKey)
            UserDefaults.standard.set(resent, forKey: Self.resentKey)
        }
    }

    /// 送ってから30分たっても返事の無い区切りを、送り直す（3回まで）
    func resendUnacknowledged() {
        guard Self.phoneAcks, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let outstanding = Set(WCSession.default.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        let stored = lock.withLock {
            (sentAt: UserDefaults.standard.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:],
             resent: UserDefaults.standard.dictionary(forKey: Self.resentKey) as? [String: Int] ?? [:])
        }
        var counts = stored.resent
        for url in sentFiles() {
            let name = url.lastPathComponent
            guard !outstanding.contains(name), (counts[name] ?? 0) < Self.maxResends else { continue }
            let sent = stored.sentAt[name].map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            guard Date.now.timeIntervalSince(sent) >= Self.resendAfter else { continue }
            counts[name, default: 0] += 1
            WCSession.default.transferFile(url, metadata: ["resend": counts[name] ?? 1, "tz": TimeZone.current.identifier])
        }
        if counts != stored.resent {
            lock.withLock { UserDefaults.standard.set(counts, forKey: Self.resentKey) }
        }
    }

    /// 古い控え（3日より前）と、300MB を超えた分（古いものから）を消す
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

    /// 書き終わった区切りを送る。低電力モードなら、溜まるまで待ってからまとめて送る。
    func deliver(_ url: URL) {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            if unsentCount() >= Self.batch { resendPending() }
        } else {
            send(url)
        }
    }

    func send(_ url: URL) {
        guard WCSession.default.activationState == .activated else { return }
        let queued = WCSession.default.outstandingFileTransfers.contains { $0.file.fileURL == url }
        // 名前の時刻は時計の時間帯。iPhone が自分の時間帯に直せるよう、時間帯も送る（2026-11-06）
        if !queued { WCSession.default.transferFile(url, metadata: ["tz": TimeZone.current.identifier]) }
    }

    /// 前回送れなかった区切りを送り直す。書き込み中のファイルは送らない。
    func resendPending() {
        for url in unsentFiles() {
            // 書いている途中でアプリが終わった区切りは開けない（iPhone でも読めない）ので消す
            guard (try? AVAudioFile(forReading: url)) != nil else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            send(url)
        }
    }

    /// まだ iPhone に届いていない区切り（書き込み中のものを除く）
    private func unsentFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.pendingDir, includingPropertiesForKeys: nil)) ?? []
        let current = recording
        return urls.filter { $0.pathExtension == "m4a" && $0 != current }
    }

    func unsentCount() -> Int { unsentFiles().count }

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
            if !ProcessInfo.processInfo.isLowPowerModeEnabled || unsentCount() >= Self.batch { resendPending() }
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
        if let alert = userInfo["alert"] as? String { onAlert?(alert) }
        onChange?()
    }

    /// iPhone の設定（無音のあいだは書かない、など）を受け取る
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Self.readSettings(applicationContext)
    }

    static func readSettings(_ context: [String: Any]) {
        if let skip = context["skipSilence"] as? Bool { UserDefaults.standard.set(skip, forKey: "skipSilence") }
        if let held = context["held"] as? Bool { SilenceGate.held = held }
        if let acks = context["acks"] as? Bool { UserDefaults.standard.set(acks, forKey: "phoneAcks") }
        // 会議モードのあいだは、録音の音質を上げる（次の区切りから）
        if let meeting = context["meeting"] as? Bool { UserDefaults.standard.set(meeting, forKey: "meetingOn") }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil { keepSent(fileTransfer.file.fileURL) }
        onChange?()
    }

    func sessionReachabilityDidChange(_ session: WCSession) { onChange?() }
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) { onChange?() }
}

import AVFoundation
import Foundation
import WatchConnectivity

/// 録音した区切りを iPhone に送る。送り終わったら時計側のファイルは消す。
/// iPhone が近くに無いときは WatchConnectivity が溜めておき、つながったときに送る。
/// 時計が低電力モードのときは、無線を起こす回数を減らすため、3つ（15分ほど）溜まってからまとめて送る。
final class WatchSender: NSObject, WCSessionDelegate {
    static let pendingDir: URL = {
        let dir = URL.documentsDirectory.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 次の区切りのファイルの場所（名前は録音を始めた時刻）
    static func newChunkURL() -> URL {
        pendingDir.appendingPathComponent(nameFormatter.string(from: .now) + ".m4a")
    }

    /// 低電力モードで、これだけ溜まったらまとめて送る
    private static let batch = 3

    /// 送れた・つながりが変わったときに呼ぶ（画面の数を出し直す）
    var onChange: (@Sendable () -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private let lock = NSLock()
    private var writing: URL?

    /// 書き込み中の区切り。書き終わるまでは送らない。
    var recording: URL? {
        get { lock.withLock { writing } }
        set { lock.withLock { writing = newValue } }
    }

    private var recordingNow = false

    /// 録音しているかを iPhone に知らせる。iPhone は、時計の区切りが届くのを待ってから
    /// 同じ時間帯の iPhone の録音と聞き比べる。
    var isRecording: Bool {
        get { lock.withLock { recordingNow } }
        set {
            lock.withLock { recordingNow = newValue }
            publish()
        }
    }

    private func publish() {
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(
            ["recording": isRecording, "at": Date.now.timeIntervalSince1970])
    }

    /// 区切るたびに呼ぶ。iPhone は、しばらく知らせが無いと「止まっているかも」と通知する。
    func heartbeat() { publish() }

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
        if !queued { WCSession.default.transferFile(url, metadata: nil) }
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
            if !ProcessInfo.processInfo.isLowPowerModeEnabled || unsentCount() >= Self.batch { resendPending() }
            publish()
            flushMarks()
        }
        onChange?()
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
        onChange?()
    }

    func sessionReachabilityDidChange(_ session: WCSession) { onChange?() }
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) { onChange?() }
}

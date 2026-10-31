import AVFoundation
import Foundation
import WatchConnectivity

/// 録音した区切りを iPhone に送る。送り終わったら時計側のファイルは消す。
/// iPhone が近くに無いときは WatchConnectivity が溜めておき、つながったときに送る。
final class WatchSender: NSObject, WCSessionDelegate {
    static let pendingDir: URL = {
        let dir = URL.documentsDirectory.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

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

    func send(_ url: URL) {
        guard WCSession.default.activationState == .activated else { return }
        let queued = WCSession.default.outstandingFileTransfers.contains { $0.file.fileURL == url }
        if !queued { WCSession.default.transferFile(url, metadata: nil) }
    }

    /// 前回送れなかった区切りを送り直す。書き込み中のファイルは送らない。
    func resendPending() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.pendingDir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "m4a" && url != recording {
            // 書いている途中でアプリが終わった区切りは開けない（iPhone でも読めない）ので消す
            guard (try? AVAudioFile(forReading: url)) != nil else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            send(url)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated {
            resendPending()
            publish()
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
    }
}

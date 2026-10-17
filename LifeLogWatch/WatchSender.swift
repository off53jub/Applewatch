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

    func send(_ url: URL) {
        guard WCSession.default.activationState == .activated else { return }
        let queued = WCSession.default.outstandingFileTransfers.contains { $0.file.fileURL == url }
        if !queued { WCSession.default.transferFile(url, metadata: nil) }
    }

    /// 前回送れなかった区切りを送り直す。`except` は録音中のファイル。
    func resendPending(except current: URL?) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.pendingDir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "m4a" && url != current {
            send(url)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated { resendPending(except: nil) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
    }
}

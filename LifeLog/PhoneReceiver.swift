import Foundation
import WatchConnectivity

/// Apple Watch から届いた録音の区切りを、iPhone の文字起こし待ちフォルダに移す。
final class PhoneReceiver: NSObject, WCSessionDelegate {
    var onFile: (@MainActor () -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // この関数を抜けると一時ファイルが消えるので、その場で移す。
        let dest = Storage.pendingDir.appendingPathComponent(file.fileURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: file.fileURL, to: dest) } catch { return }
        Task { @MainActor in self.onFile?() }
    }
}

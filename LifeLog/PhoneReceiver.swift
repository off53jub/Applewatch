import Foundation
import WatchConnectivity

/// Apple Watch から届いた録音の区切りを、iPhone の文字起こし待ちフォルダに移す。
final class PhoneReceiver: NSObject, WCSessionDelegate {
    var onFile: (@MainActor () -> Void)?
    var onStateChange: (@MainActor (String) -> Void)?

    /// 時計との接続状態を、画面に出せる一文にする。
    static func describe(_ session: WCSession) -> String {
        guard WCSession.isSupported() else { return "この iPhone では使えません" }
        guard session.activationState == .activated else { return "接続を準備中" }
        guard session.isPaired else { return "Apple Watch がペアリングされていません" }
        guard session.isWatchAppInstalled else { return "時計に LifeLog が入っていません" }
        return session.isReachable ? "時計のアプリとつながっています" : "時計に LifeLog が入っています"
    }

    private func report(_ session: WCSession) {
        let text = Self.describe(session)
        Task { @MainActor in self.onStateChange?(text) }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        report(session)
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) { report(session) }
    func sessionReachabilityDidChange(_ session: WCSession) { report(session) }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // この関数を抜けると一時ファイルが消えるので、その場で移す。
        let dest = Storage.pendingDir.appendingPathComponent(file.fileURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: file.fileURL, to: dest) } catch { return }
        Task { @MainActor in self.onFile?() }
    }
}

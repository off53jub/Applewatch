import Foundation
import WatchConnectivity

/// Apple Watch から届いた録音の区切りを、iPhone の文字起こし待ちフォルダに移す。
final class PhoneReceiver: NSObject, WCSessionDelegate {
    var onFile: (@MainActor () -> Void)?
    var onStateChange: (@MainActor (String) -> Void)?
    /// 時計が録音中かどうか（時計のアプリが知らせてくる）
    /// 時計が録音中か（at は時計が知らせた時刻）
    var onWatchRecording: (@MainActor (Bool, Date?) -> Void)?
    /// 時計で「印」が押された
    var onMark: (@MainActor (Date) -> Void)?
    /// 時計が静かで書くのを休んでいるなら、休み始めた時刻（書いていれば nil）
    var onWatchResting: (@MainActor (Date?) -> Void)?

    /// iPhone の設定を時計に送る（時計がつながったときに受け取る）
    func sendSettings(skipSilence: Bool) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["skipSilence": skipSilence])
    }

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
        if state == .activated { sendSettings(skipSilence: SilenceGate.enabled) }
        // 前回知らせてきた状態は、つながる前から読める
        readContext(session.receivedApplicationContext)
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) { report(session) }
    func sessionReachabilityDidChange(_ session: WCSession) { report(session) }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        readContext(applicationContext)
    }

    private func readContext(_ context: [String: Any]) {
        guard let recording = context["recording"] as? Bool else { return }
        let at = (context["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let resting = (context["resting"] as? Double).map { Date(timeIntervalSince1970: $0) }
        Task { @MainActor in
            self.onWatchResting?(recording ? resting : nil)
            self.onWatchRecording?(recording, at)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let time = userInfo["mark"] as? Double else { return }
        Task { @MainActor in self.onMark?(Date(timeIntervalSince1970: time)) }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // この関数を抜けると一時ファイルが消えるので、その場で移す。
        // iPhone で録った区切りと見分けられるよう、名前に「-w」を付ける。
        let name = Storage.watchChunkName(from: file.fileURL.lastPathComponent)
        let dest = Storage.pendingDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: file.fileURL, to: dest) } catch { return }
        Task { @MainActor in self.onFile?() }
    }
}

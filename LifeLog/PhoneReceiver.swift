import Foundation
import WatchConnectivity

/// Apple Watch から届いた録音の区切りを、iPhone の文字起こし待ちフォルダに移す。
final class PhoneReceiver: NSObject, WCSessionDelegate {
    var onFile: (@MainActor () -> Void)?
    /// 区切りを受け取った（移した先と、受け取った時刻）
    var onArrival: (@MainActor (URL, Date) -> Void)?
    /// 時計が低電力モードか
    var onWatchLowPower: (@MainActor (Bool) -> Void)?
    var onStateChange: (@MainActor (String) -> Void)?
    /// 時計が録音中かどうか（時計のアプリが知らせてくる）
    /// 時計が録音中か（at は時計が知らせた時刻）
    var onWatchRecording: (@MainActor (Bool, Date?) -> Void)?
    /// 時計で「印」が押された
    var onMark: (@MainActor (Date) -> Void)?
    /// 時計が静かで書くのを休んでいるなら、休み始めた時刻（書いていれば nil）
    var onWatchResting: (@MainActor (Date?) -> Void)?
    /// 時計の様子（電池・充電中・控えの数など。知らせが来るたび）
    var onWatchState: (@MainActor (WatchState) -> Void)?
    /// 時計で「初めての人」の印が押された
    var onNewPerson: (@MainActor (Date) -> Void)?
    /// 時計で会議モードを始めた・終えた
    var onMeeting: (@MainActor (Bool) -> Void)?

    /// 時計が知らせてきた様子
    struct WatchState {
        let at: Date
        let recording: Bool
        let resting: Bool
        let lowPower: Bool?
        /// 電池の残り（0〜1）
        let battery: Double?
        let charging: Bool?
        /// iPhone の返事を待っている控えの数
        let kept: Int?
    }

    /// 前に送った設定（会議モードだけ変えるときなどに、ほかを残す）
    private var lastSettings: [String: Any] = [:]

    /// iPhone の設定を時計に送る（時計がつながったときに受け取る）。
    /// acks: この版は届いた区切りに「受け取った」と返事をする（時計は返事が来るまで控えを残す）
    func sendSettings(skipSilence: Bool, held: Bool, meeting: Bool? = nil) {
        lastSettings["skipSilence"] = skipSilence
        lastSettings["held"] = held
        lastSettings["acks"] = true
        if let meeting { lastSettings["meeting"] = meeting }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(lastSettings)
    }

    /// 時計に知らせを送る（時計が震えて画面に出す）
    func alertWatch(_ text: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        WCSession.default.transferUserInfo(["alert": text])
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
        if state == .activated { sendSettings(skipSilence: SilenceGate.enabled, held: SilenceGate.held) }
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
        let lowPower = context["lowPower"] as? Bool
        let state = WatchState(at: at ?? .now, recording: recording, resting: recording && resting != nil, lowPower: lowPower,
                               battery: context["battery"] as? Double, charging: context["charging"] as? Bool,
                               kept: context["kept"] as? Int)
        Task { @MainActor in
            if let lowPower { self.onWatchLowPower?(lowPower) }
            self.onWatchResting?(recording ? resting : nil)
            self.onWatchRecording?(recording, at)
            self.onWatchState?(state)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let time = userInfo["mark"] as? Double {
            Task { @MainActor in self.onMark?(Date(timeIntervalSince1970: time)) }
        }
        if let time = userInfo["newPerson"] as? Double {
            Task { @MainActor in self.onNewPerson?(Date(timeIntervalSince1970: time)) }
        }
        if let on = userInfo["meeting"] as? Bool {
            Task { @MainActor in self.onMeeting?(on) }
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // この関数を抜けると一時ファイルが消えるので、その場で移す。
        // iPhone で録った区切りと見分けられるよう、名前に「-w」を付ける。
        let received = Date.now
        let sentName = file.fileURL.lastPathComponent
        let name = Storage.watchChunkName(from: sentName)
        let dest = Storage.pendingDir.appendingPathComponent(name)
        // 送り直されてきた区切り（返事が届かなかった）で、もう受け取っていれば、返事だけして捨てる
        if Storage.alreadyReceived(name) {
            acknowledge(sentName)
            return
        }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: file.fileURL, to: dest) } catch { return }
        Storage.noteReceived(name)
        // 時計に「受け取った」と返事をする（時計は控えを消す）
        acknowledge(sentName)
        Task { @MainActor in
            self.onArrival?(dest, received)
            self.onFile?()
        }
    }

    private func acknowledge(_ name: String) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["got": name])
    }
}

import Foundation
import WatchConnectivity

/// Apple Watch から届いた録音の区切りを、iPhone の文字起こし待ちフォルダに移す。
final class PhoneReceiver: NSObject, WCSessionDelegate {
    var onFile: (@MainActor () -> Void)?
    /// 区切りを受け取った（移した先と、受け取った時刻と、時計が添えた控え。控えは古い時計のアプリなら空。2026-11-07）
    var onArrival: (@MainActor (URL, Date, WatchDelivery.Stamp) -> Void)?
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
    /// 時計の様子を読み終えた（上の知らせをすべて渡したあと。iPhone のウィジェットを出し直す。2026-11-07）
    var onWatchContext: (@MainActor () -> Void)?
    /// 時計で「初めての人」の印が押された
    var onNewPerson: (@MainActor (Date) -> Void)?
    /// 時計で会議モードを始めた・終えた
    var onMeeting: (@MainActor (Bool) -> Void)?
    /// 時計から「さっき何て言った？」と聞かれた（答えの文を返す）
    var onAsk: (@MainActor (String) -> String)?
    /// 時計で頼まれごとの「済み」が押された（頼まれごとの id。2026-11-07）
    var onTaskDone: (@MainActor (String) -> Void)?
    /// 時計の「聞く」で質問された（答えの文を返す。時間がかかるので、答えはあとで transferUserInfo で送る。2026-11-07）
    var onQuestion: (@MainActor (String) async -> String)?

    /// 時計からの問い（返事を待っている）
    /// 時計から「起きて」と言われた（2026-11-06）。アプリが止まっていても、iOS が裏で起こしてここに来る
    var onWake: (@MainActor () -> Void)?
    /// 時計とのやり取りを始められた（起動のたび。2026-11-07）
    var onActivated: (@MainActor () -> Void)?

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if handleWatchRequest(message) { return }
        guard message["wake"] != nil else { return }
        readContext(message)
        Task { @MainActor in self.onWake?() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message["wake"] != nil {
            readContext(message)
            Task { @MainActor in self.onWake?() }
            replyHandler([:])
            return
        }
        if let id = message["taskDone"] as? String {
            Task { @MainActor in self.onTaskDone?(id) }
            replyHandler(["ok": true])
            return
        }
        guard let ask = message["ask"] as? String else {
            replyHandler([:])
            return
        }
        // 「聞く」の質問（"q:" + 質問）は、すぐ「調べています」と返し、答えはあとで送る
        if ask.hasPrefix(Self.questionPrefix) {
            replyHandler(["answer": "調べています", "pending": true])
            answerLater(String(ask.dropFirst(Self.questionPrefix.count)))
            return
        }
        Task { @MainActor in
            replyHandler(["answer": self.onAsk?(ask) ?? "iPhone の LifeLog の準備ができていません。"])
        }
    }

    // MARK: - 時計のアプリ（2026-11-07）

    /// 時計の「聞く」の質問の頭（"q:" + 質問）。"recent" は今までどおり「さっき何て言った？」
    static let questionPrefix = "q:"

    /// 返事の要らない知らせ（sendMessage・transferUserInfo）で届いた「済み」と「聞く」。扱ったら true
    @discardableResult
    private func handleWatchRequest(_ message: [String: Any]) -> Bool {
        var handled = false
        if let id = message["taskDone"] as? String {
            Task { @MainActor in self.onTaskDone?(id) }
            handled = true
        }
        if let ask = message["ask"] as? String, ask.hasPrefix(Self.questionPrefix) {
            answerLater(String(ask.dropFirst(Self.questionPrefix.count)))
            handled = true
        }
        return handled
    }

    /// 質問に答えて、答えを時計に送る（時計は届いたら震えて出す）
    private func answerLater(_ question: String) {
        Task { @MainActor in
            let text: String
            if let onQuestion = self.onQuestion {
                text = await onQuestion(question)
            } else {
                text = "iPhone の LifeLog の準備ができていません。"
            }
            self.sendAnswer(text, question: question)
        }
    }

    /// 「聞く」の答えを時計に送る（時計が離れていても、つながったときに届く）
    func sendAnswer(_ text: String, question: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        WCSession.default.transferUserInfo(["answer": text, "question": question])
    }

    /// 時計の画面に出す中身（WatchInfo の JSON）を、設定と一緒に送る（設定は消さずに足す）
    func sendWatchInfo(_ data: Data) {
        lastSettings[WatchInfo.contextKey] = data
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(lastSettings)
    }

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
        // 区切りの長さ（短め・ふつう。時計は次の区切りから使う。2026-11-07）
        lastSettings[ChunkCutter.lengthKey] = ChunkCutter.length.rawValue
        if let meeting { lastSettings["meeting"] = meeting }
        // iPhone の時間帯（時計が家の PC に直接送るとき、iPhone で付く名前にそろえる。2026-11-07）
        lastSettings[WatchDelivery.phoneZoneKey] = TimeZone.current.identifier
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(lastSettings)
    }

    // MARK: - 時計から家の PC に直接送る（2026-11-07。WatchPC.swift）

    /// 直接送るか・聞き取りのヒント・多数決の重みを、設定と一緒に送る（変わったときだけ）
    func sendWatchPCContext(direct: Bool, hints: String, weights: String?) {
        var next = lastSettings
        next[WatchDelivery.directKey] = direct
        next[WatchDelivery.hintsKey] = hints
        next[WatchDelivery.weightsKey] = weights ?? ""
        next[WatchDelivery.phoneZoneKey] = TimeZone.current.identifier
        let changed = (lastSettings[WatchDelivery.directKey] as? Bool) != direct
            || (lastSettings[WatchDelivery.hintsKey] as? String) != hints
            || (lastSettings[WatchDelivery.weightsKey] as? String) != (weights ?? "")
            || (lastSettings[WatchDelivery.phoneZoneKey] as? String) != TimeZone.current.identifier
        guard changed else { return }
        lastSettings = next
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        try? WCSession.default.updateApplicationContext(lastSettings)
    }

    /// 家の中の住所と合言葉を時計に送る（時計は合言葉を Keychain に置く）。住所が空なら、時計は合言葉を消す。
    /// 合言葉は、時計にずっと残る applicationContext には入れず、届いたら消える transferUserInfo で送る
    func sendWatchPCCredentials(address: String, key: String?) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        WCSession.default.transferUserInfo([WatchDelivery.addressKey: address,
                                            WatchDelivery.secretKey: address.isEmpty ? "" : (key ?? "")])
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
        if state == .activated {
            sendSettings(skipSilence: SilenceGate.enabled, held: SilenceGate.held)
            // 家の PC に直接送る設定も送り直す（2026-11-07）
            Task { @MainActor in self.onActivated?() }
        }
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
            self.onWatchContext?()
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // 時計の「済み」と「聞く」（iPhone が離れていたときに、あとから届いた分）
        handleWatchRequest(userInfo)
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
        // 時計で区切った時刻・送り始めた時刻・家の PC にも送ったか（2026-11-07。WatchDelivery）
        let stamp = WatchDelivery.stamp(from: file.metadata)
        let sentName = file.fileURL.lastPathComponent
        // 時計の時間帯で付けた名前を、iPhone の時間帯の名前に直す（時差があるとき・日本時間で区切るとき）
        let local = Storage.convertedName(sentName, from: (file.metadata?["tz"] as? String).flatMap(TimeZone.init(identifier:)))
        let name = Storage.watchChunkName(from: local)
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
            self.onArrival?(dest, received, stamp)
            self.onFile?()
        }
    }

    private func acknowledge(_ name: String) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["got": name])
    }
}

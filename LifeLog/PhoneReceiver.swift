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
    /// 時計の様子の知らせが届いた（家の PC に直接送る設定が時計に届いているかを見る。2026-11-08。WatchDirect.swift）
    var onWatchPCState: (@MainActor () -> Void)?
    /// 時計で「初めての人」の印が押された
    var onNewPerson: (@MainActor (Date) -> Void)?
    /// 時計で会議モードを始めた・終えた
    var onMeeting: (@MainActor (Bool) -> Void)?
    /// 時計で「違う、〇〇さん」と言った（言った言葉と時刻。2026-11-19。s18。KnowMe.swift）
    var onVoiceFix: (@MainActor (String, Date) -> Void)?
    /// 時計の「お酒 +1」（2026-11-21。s19 の 休30）
    var onDrink: (@MainActor (Date) -> Void)?
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
        // isWatchAppInstalled が入れ直しのあとに false のままのことがあるので、時計からの最近の便りも見る（2026-11-07。WatchPresence.swift）
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WatchPresence.installed(WCSession.default) else { return }
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
        /// 時計の中の、まだ送り終わっていない区切りの数（送っている途中を含む。古い時計のアプリでは nil。2026-11-07）
        var unsent: Int? = nil
        /// そのうち、WatchConnectivity が送っている途中の数
        var outstanding: Int? = nil
        /// 時計が最後に区切った時刻（無音で捨てたものも含む）
        var lastCut: Date? = nil
        /// 時計が「録音を休む場所にいる」と思っているか
        var held: Bool? = nil
        /// 家の PC に届いていて、iPhone が PC から受け取るのを時計が待っている数と、直近1日に iPhone へ送らずに済んだ数
        /// （新しい時計のアプリだけ。2026-11-15。強化案 64。PCRelay.swift）
        var relayHeld: Int? = nil
        var relayDone: Int? = nil
        /// 時計で、止めるボタンを押さずに録音していた（録音しているつもり）か
        var wanted: Bool? = nil
        /// 時計が今日、声らしい音が無いので捨てた区切りの数（新しい時計のアプリだけ。2026-11-16。VoiceGate）
        var noVoiceDropped: Int? = nil
        /// 時計が、受け渡しの列に止まっていた区切りを取り消した数（これまでの合計。新しい時計のアプリだけ。2026-11-20）
        var unstuck: Int? = nil
        /// 休日のライフログ（2026-11-21。s19。新しい時計のアプリだけ。HolidayRules）:
        /// 今日の中断（アラーム・電話・Siri）の回数と、流し直せた回数（休10）
        var interruptions: Int? = nil
        var resumed: Int? = nil
        /// 今日、録音が止まりかけた回数・自動で戻せた回数・最後の「秒|理由」・時計の build（2026-11-22）
        var stalls: Int? = nil
        var autoResumed: Int? = nil
        var lastStall: String? = nil
        var build: String? = nil
        /// 電池の見本（[[時刻, 0〜1, 外出モードで溜めていたら 1]]。休8）と、いま外出モードで溜めているか
        var batteryAt: [[Double]]? = nil
        var awayHolding: Bool? = nil
        /// 「初めての人が多い」モードか（休17）
        var crowd: Bool? = nil
        /// s21（2026-11-22。新しい時計のアプリだけ。S21Watch）: 今日録れた秒（使5）・今日アプリが終わっていた回数と
        /// 最後のあいだ「秒|秒」（守2）・片付けた返事待ちの合計（速2）・ワークアウト扱いで守っているか（守3）・声の無い区切りの見本の数（精7）
        var recordedToday: Int? = nil
        var exits: Int? = nil
        var lastExit: String? = nil
        var keptCleared: Int? = nil
        var guarding: Bool? = nil
        var sampledNoVoice: Int? = nil
        /// s22（2026-11-22。新しい時計のアプリだけ。S22Watch）: 直近 30 分に終わった受け渡し（楽6）・今日こもりで震えた回数（確31）
        var finishedRecent: Int? = nil
        var muffledToday: Int? = nil

        /// 時計の中に残っている区切り（まだ送っていない＋返事待ち）。どちらも分からなければ nil
        var leftOnWatch: Int? {
            guard unsent != nil || kept != nil else { return nil }
            return (unsent ?? 0) + (kept ?? 0)
        }
    }

    /// 時計に「残っている区切りを全部送り直して」と頼む（iPhone のアプリが起動したとき・区切りが届かないとき。2026-11-07）。
    /// 時計はまだ送っていないものと、返事待ちの控えを送り直す。もう受け取った区切りは、返事だけして捨てる（二重にならない）
    func askWatchToResend() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired else { return }
        WCSession.default.transferUserInfo(["resendKept": true])
    }

    /// iPhone が受け取ったと覚えている時計の区切りの名前を、時計に渡す（時計は返事が届かなかった控えを片付ける。
    /// 2026-11-22。s21 の 速2）。渡せたら true
    @discardableResult
    func sendGotList(_ names: [String]) -> Bool {
        guard !names.isEmpty, WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired else { return false }
        WCSession.default.transferUserInfo([S21Watch.gotListKey: names])
        return true
    }

    /// 時計に「いま送り直して」と頼む（止まった受け渡しの取り消し・返事待ちの片付けもする。2026-11-22。s22 の 楽6）。頼めたら true
    @discardableResult
    func askWatchToResendNow() -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired else { return false }
        WCSession.default.transferUserInfo([S22Watch.resendNowKey: true])
        return true
    }

    /// 前に送った設定（会議モードだけ変えるときなどに、ほかを残す）
    private var lastSettings: [String: Any] = [:]

    /// iPhone の設定を時計に送る（時計がつながったときに受け取る）。
    /// acks: この版は届いた区切りに「受け取った」と返事をする（時計は返事が来るまで控えを残す）
    func sendSettings(skipSilence: Bool, held: Bool, meeting: Bool? = nil) {
        lastSettings["skipSilence"] = skipSilence
        lastSettings["held"] = held
        lastSettings["acks"] = true
        // 区切りの長さ（短め・ふつう）と「電池が少ないときは5分に」（時計は次の区切りから使う。2026-11-07）
        ChunkCutter.addSettings(to: &lastSettings)
        if let meeting { lastSettings["meeting"] = meeting }
        // iPhone の時間帯（時計が家の PC に直接送るとき、iPhone で付く名前にそろえる。2026-11-07）
        lastSettings[WatchDelivery.phoneZoneKey] = TimeZone.current.identifier
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(lastSettings)
    }

    // MARK: - 時計から家の PC に直接送る（2026-11-07。WatchPC.swift）

    /// 直接送るか・聞き取りのヒント・多数決の重みを、設定と一緒に送る（変わったときだけ。force なら変わっていなくても送る）
    /// relay は、いま iPhone が時計の音声を家の PC から受け取れるか（時計は、PC に届いた区切りを iPhone に送らずに少し待つ。
    /// 2026-11-15。強化案 64。PCRelay.swift）
    /// later は、いま受け取れなくても受け取る準備がある（設定がオン・PC が対応）か。時計は、そのあいだ PC に届いた区切りを長く待つ（2026-11-18）
    func sendWatchPCContext(direct: Bool, hints: String, weights: String?, relay: Bool = false, later: Bool = false,
                            force: Bool = false) {
        var next = lastSettings
        next[WatchDelivery.directKey] = direct
        next[WatchDelivery.hintsKey] = hints
        next[WatchDelivery.weightsKey] = weights ?? ""
        next[WatchDelivery.phoneZoneKey] = TimeZone.current.identifier
        next[WatchDelivery.relayKey] = relay
        next[WatchDelivery.relayLaterKey] = later
        let changed = (lastSettings[WatchDelivery.directKey] as? Bool) != direct
            || (lastSettings[WatchDelivery.relayKey] as? Bool) != relay
            || (lastSettings[WatchDelivery.relayLaterKey] as? Bool) != later
            || (lastSettings[WatchDelivery.hintsKey] as? String) != hints
            || (lastSettings[WatchDelivery.weightsKey] as? String) != (weights ?? "")
            || (lastSettings[WatchDelivery.phoneZoneKey] as? String) != TimeZone.current.identifier
        guard changed || force else { return }
        lastSettings = next
        // isWatchAppInstalled は TestFlight で入れ直したあと false のままのことがあるので、時計からの最近の便りも見る（2026-11-08）
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WatchPresence.installed(WCSession.default) else { return }
        try? WCSession.default.updateApplicationContext(lastSettings)
    }

    /// 休日のライフログの設定を時計に送る（変わったときだけ。2026-11-21。s19。HolidayRules）。
    /// holidayDay は今日が休みならその日・休みでなければ空、carSince は車につないだ時刻（つないでいなければ 0）
    func sendHolidayContext(holidayDay: String, lowBattery: Bool, awayMode: Bool, away: Bool, carSince: Double) {
        let values: [String: Any] = [HolidayRules.holidayDayKey: holidayDay, HolidayRules.lowBatteryKey: lowBattery,
                                     HolidayRules.awayModeKey: awayMode, HolidayRules.awayKey: away,
                                     HolidayRules.carSinceKey: carSince]
        let changed = (lastSettings[HolidayRules.holidayDayKey] as? String) != holidayDay
            || (lastSettings[HolidayRules.lowBatteryKey] as? Bool) != lowBattery
            || (lastSettings[HolidayRules.awayModeKey] as? Bool) != awayMode
            || (lastSettings[HolidayRules.awayKey] as? Bool) != away
            || (lastSettings[HolidayRules.carSinceKey] as? Double) != carSince
        guard changed else { return }
        for (key, value) in values { lastSettings[key] = value }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WatchPresence.installed(WCSession.default) else { return }
        try? WCSession.default.updateApplicationContext(lastSettings)
    }

    /// 家の中の住所と合言葉を時計に送る（時計は合言葉を Keychain に置く）。住所が空なら、時計は合言葉を消す。
    /// 合言葉は、時計にずっと残る applicationContext には入れず、届いたら消える transferUserInfo で送る
    /// 送れたら true（つながっていない・時計にアプリが無いと思われるときは false。送ったことにしない）
    @discardableResult
    func sendWatchPCCredentials(address: String, key: String?) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WatchPresence.installed(WCSession.default) else { return false }
        WCSession.default.transferUserInfo([WatchDelivery.addressKey: address,
                                            WatchDelivery.secretKey: address.isEmpty ? "" : (key ?? "")])
        return true
    }

    /// 時計に知らせを送る（時計が震えて画面に出す）
    func alertWatch(_ text: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WatchPresence.installed(WCSession.default) else { return }
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
        var state = WatchState(at: at ?? .now, recording: recording, resting: recording && resting != nil, lowPower: lowPower,
                               battery: context["battery"] as? Double, charging: context["charging"] as? Bool,
                               kept: context["kept"] as? Int)
        // 時計の中に残っている区切りの様子（2026-11-07。古い時計のアプリは送らない）
        state.unsent = context["unsent"] as? Int
        state.outstanding = context["outstanding"] as? Int
        state.lastCut = (context["lastCut"] as? Double).map { Date(timeIntervalSince1970: $0) }
        state.held = context["held"] as? Bool
        state.wanted = context["wanted"] as? Bool
        state.relayHeld = context["relayHeld"] as? Int
        state.relayDone = context["relayDone"] as? Int
        state.noVoiceDropped = context["noVoiceDropped"] as? Int
        state.unstuck = context["unstuck"] as? Int
        state.interruptions = context[HolidayRules.interruptionsKey] as? Int
        state.resumed = context[HolidayRules.resumedKey] as? Int
        state.stalls = context[HolidayRules.stallsKey] as? Int
        state.autoResumed = context[HolidayRules.autoResumedKey] as? Int
        state.lastStall = context[HolidayRules.lastStallKey] as? String
        state.build = context[HolidayRules.watchBuildKey] as? String
        state.batteryAt = (context[HolidayRules.batteryAtKey] as? [[Double]])
            ?? (context[HolidayRules.batteryAtKey] as? [[NSNumber]])?.map { $0.map(\.doubleValue) }
        state.awayHolding = context[HolidayRules.awayHoldingKey] as? Bool
        state.crowd = context[HolidayRules.crowdKey] as? Bool
        state.recordedToday = context[S21Watch.recordedTodayKey] as? Int
        state.exits = context[S21Watch.exitsKey] as? Int
        state.lastExit = context[S21Watch.lastExitKey] as? String
        state.keptCleared = context[S21Watch.keptClearedKey] as? Int
        state.guarding = context[S21Watch.guardingKey] as? Bool
        state.sampledNoVoice = context[S21Watch.sampledNoVoiceKey] as? Int
        state.finishedRecent = context[S22Watch.finishedRecentKey] as? Int
        state.muffledToday = context[S22Watch.muffledTodayKey] as? Int
        // 時計の中断から戻るまでの数・止まっていたあいだ・練習の結果（2026-11-23。s23 の 止1・止12・止15。S23Resume.swift）
        S23PhoneBook.noteWatchContext(context)
        let snapshot = state
        Task { @MainActor in
            if let lowPower { self.onWatchLowPower?(lowPower) }
            self.onWatchResting?(recording ? resting : nil)
            self.onWatchRecording?(recording, at)
            self.onWatchState?(snapshot)
            self.onWatchContext?()
            self.onWatchPCState?()
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
        if let text = userInfo["voiceFix"] as? String, let at = userInfo["at"] as? Double {
            Task { @MainActor in self.onVoiceFix?(text, Date(timeIntervalSince1970: at)) }
        }
        // 時計の「お酒 +1」（2026-11-21。s19 の 休30）
        if let at = userInfo["drink"] as? Double {
            Task { @MainActor in self.onDrink?(Date(timeIntervalSince1970: at)) }
        }
        // 時計で確かめ待ちに ○×（2026-11-22。s22 の 楽13。S22Book.swift）
        if let id = userInfo[S22Watch.reviewIDKey] as? String, let value = userInfo[S22Watch.reviewValueKey] as? String {
            Task { @MainActor in S22Book.answerReview(id: id, value: value, from: "watch") }
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

    /// 時計の区切りの音声を家の PC から受け取ったと、時計に知らせる（時計は、その区切りを iPhone に送らずに消す。
    /// 名前は iPhone で付く名前。2026-11-15。強化案 64。PCRelay.swift）。知らせを出せたら true
    @discardableResult
    func acknowledgeViaPC(_ name: String) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        WCSession.default.transferUserInfo([WatchDelivery.relayGotKey: name])
        return true
    }
}

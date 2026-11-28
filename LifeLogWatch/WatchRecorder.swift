import AVFoundation
import Observation
import UserNotifications
import WatchKit

/// 時計で録音し続け、区切ったファイル（短めの設定で長くても2分、ふつうで5分ほど）を iPhone に送る。
/// 画面が消えているあいだは録音を新しく始め直せないので、マイクは止めずに
/// AVAudioEngine で流し続け、書き込むファイルだけを切り替える。ほぼ無音の区切りは捨てる。
/// 1分続けて静かなら書くのを休み、音がしたらその2.5秒前から書き始める（無音を送らない）。
/// 区切りは、決めた長さを過ぎたあとの声の途切れたところで切る（言葉の途中で切らないため。ChunkCutter）。
/// 音は文字起こしに使う 16kHz・1ch にしてから書く（圧縮と送る量が減り、電池が長持ちする）。
@MainActor
@Observable
final class WatchRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var message = ""
    /// iPhone にまだ送れていない区切りの数
    private(set) var unsent = 0
    /// 家の PC に届いていて、iPhone が PC から受け取るのを待っている区切りの数（unsent には入れない。2026-11-18）
    private(set) var relayWaiting = 0
    /// iPhone とのつながり（画面に出す一文）
    private(set) var link = ""
    /// 時計が低電力モードか（送るのを15分ごとにまとめる）
    private(set) var lowPower = false
    /// 電池が少ないので、短めの設定を自動で5分の区切りにしているか（設定「電池が少ないときは5分に」。2026-11-07）
    private(set) var batterySaving = ChunkCutter.batterySaving && ChunkCutter.length == .short
    /// 「さっき何て言った？」の答え（iPhone の記録の直近の行）
    private(set) var recentAnswer: String?
    private(set) var asking = false

    /// iPhone に直近の記録を聞く
    func askRecent() {
        asking = true
        sender.askRecent { [weak self] answer in
            Task { @MainActor in
                self?.asking = false
                self?.recentAnswer = answer
            }
        }
    }

    func clearAnswer() { recentAnswer = nil }

    /// 会議モードか（iPhone と同じ。会議のあいだは録音の音質を上げる）
    private(set) var meetingOn = UserDefaults.standard.bool(forKey: "meetingOn")
    /// 「初めての人が多い」モード（飲み会・イベント。区切りごとに「初めての人」の印を付ける。4 時間で自動で終わる。2026-11-21。s19 の 休17）
    private(set) var crowdOn = HolidayRules.crowdActive(until: UserDefaults.standard.double(forKey: WatchSender.crowdUntilKey), now: .now)
    /// 外出モードで区切りを溜めているか（休8）
    private(set) var awayHolding = false
    /// 今日のお酒の杯数（時計の中の数。iPhone にも 1 杯ずつ送る。2026-11-21。s19 の 休30）
    private(set) var drinksToday = 0
    /// 今日録れた秒と、最後に届いた時刻（画面に出す。2026-11-22。s21 の 使5）
    private(set) var recordedToday: TimeInterval = 0
    private(set) var lastDelivered: Date?
    /// 寝ている時間なので 5 分で区切っているか（s21 の 電3）
    private(set) var sleepSaving = false
    /// 画面が消えているあいだの強い守り（ワークアウト扱い。設定でオンのときだけ。s21 の 守3。WatchGuard.swift）
    @ObservationIgnored private let guardian = WatchGuard()
    /// 中断（アラーム・電話・Siri）のあと、まだ流し直せていない（戻れた回数を数える。休10）
    @ObservationIgnored private var interruptionOpen = false
    /// 時計の空きが少ないと知らせたか（12時間に1回まで）
    @ObservationIgnored private var lowSpaceAlerted = Date.distantPast

    private let sender: WatchSender
    /// s22（2026-11-22。S22WatchSide.swift）から送りの係に触る入口（いま送り直す・溜まった数）
    var s22Sender: WatchSender { sender }
    /// 頼まれごと・次の予定・聞く・朝の読み上げの画面の中身（2026-11-07）
    let board: WatchBoard
    /// マイクを流す部品。中断のあとは作り直す（使い回すと、アラームのあとに流し直せず、アプリを一から起動し直すまで
    /// 録れないことがあった。2026-11-23）
    @ObservationIgnored private var engine = AVAudioEngine()
    private let writer: ChunkWriter

    /// 録音中に時計がアプリを終わらせても気づけるよう、「録音中だった」ことを残しておく。
    private static let wasRecordingKey = "wasRecording"
    private static let watchdogID = "watchdog"
    private static let unsentID = "unsent"
    /// 送れていない区切りがこれだけ溜まったら知らせる（低電力モードでは、まとめて送るぶん多めに待つ）。
    /// 5分の区切りでの数。短めの区切りでは、同じくらいの時間になるよう数を増やす（2026-11-07。ChunkCutter.scaled）
    private static var unsentAlert: Int { ChunkCutter.scaled(4) }
    private static var unsentAlertLowPower: Int { ChunkCutter.scaled(6) }
    @ObservationIgnored private var unsentAlerted = false

    override init() {
        let sender = WatchSender()
        self.sender = sender
        writer = ChunkWriter(sender: sender)
        board = WatchBoard(sender: sender)
        super.init()
        sender.onChange = { [weak self] in
            Task { @MainActor in self?.refreshStatus() }
        }
        // iPhone から中身が届いた・「済み」を押したら、文字盤も出し直す（2026-11-07。WatchWidgets.swift）
        board.onChange = { [weak self] in self?.updateWidgets() }
        // iPhone が音を調べて見つけたこと（マイクが隠れている・音が割れている）を、震わせて知らせる
        sender.onAlert = { [weak self] text in
            Task { @MainActor in self?.alert(text) }
        }
        writer.setOnCut { [weak self] url, peak, voice, error in
            Task { @MainActor in self?.cut(url, peakDB: peak, voiceFrames: voice, error: error) }
        }
        // 静かで休んでいるあいだも、録音が続いていることを iPhone に知らせ、見張りの通知を延ばす
        writer.setOnRestTick { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.sender.readBattery()
                self.sender.heartbeat()
                self.armWatchdog()
            }
        }
        // s39 の 1 の様子を時計の様子に載せる（2026-11-29）
        let quietWriter = writer
        S39WatchPowerSide.quiet = { quietWriter.s39Quiet }
        sender.activate()
        refreshStatus()
        // 録音が止まらない（「録音を戻す」の分類・毎日の見回り・iPhone からの頼み。2026-11-23。s23。S23WatchRec.swift）
        S23WatchRec.setUp(self)
        guardian.onChange = { [weak self] on in self?.sender.guarding = on }
        // 前回、止めるボタンを押さずに終わっていたら、開き直したときに録音を再開する
        if UserDefaults.standard.bool(forKey: Self.wasRecordingKey) {
            // 録音しているつもりのまま時計のアプリが終わっていた（落ちた・止められた）。最後に動いていた時刻からのあいだを残す
            // （watchOS には落ちた記録を読む道が無いので、次の起動で残す。2026-11-22。s21 の 守2）
            sender.noteRelaunch()
            Task { @MainActor in
                await self.start()
                if self.isRecording {
                    self.message = "途中で止まっていた録音を再開しました"
                } else {
                    // 再開できなかった（時計が裏でアプリを起こしたときは、録音を始めさせてもらえないことがある）。
                    // iPhone に「録音していない」と知らせ、時計にも知らせる（2026-11-07）
                    self.sender.isRecording = false
                    self.notifyNotRecording("LifeLog を開くと録音を再開します。")
                }
            }
        }
    }

    /// 録音しているつもりなのに録音できていないことを、通知で知らせる（2026-11-07）
    private func notifyNotRecording(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "時計の LifeLog が録音していません"
        content.body = body
        content.sound = .default
        // 「録音を戻す」（押すと開いてすぐ戻す。2026-11-23。s23 の 止7）
        content.categoryIdentifier = S23Rec.watchResumeCategory
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "not-recording", content: content, trigger: nil))
    }

    // MARK: - マイクの音が本当に届いているか（2026-11-07）

    /// 録音中なのに、マイクの音がこれだけ届かなければ、マイクを流し直す。流し直しても届かなければ止めて知らせる。
    /// 音が届かないと区切りも「録音は続いている」の知らせも作られず、iPhone は時計が録音中だと思ったままになる
    private static let micSilence: TimeInterval = 20
    @ObservationIgnored private var micCheck: Task<Void, Never>?
    /// 電話などでマイクが止められている（そのあいだは確かめない）
    @ObservationIgnored private var interruptedSince: Date?

    private func watchMicrophone() {
        micCheck?.cancel()
        micCheck = Task { @MainActor [weak self] in
            var restarted = false
            // 静かで休んでいるあいだは 30 秒（仮）ごと（止まりは 60 秒ほどまでに見つかる。2026-11-29。s39 の 11）
            var every = Self.micSilence
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(every))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                every = S39WatchPower.micCheckEvery(resting: self.writer.isResting,
                                                    on: S39WatchPower.isOn(S39WatchPower.quietKey))
                // 止まりかけて試し直しているあいだは、試し直しの係に任せる（2026-11-22）
                if self.stalled { continue }
                if let since = self.interruptedSince, Date.now.timeIntervalSince(since) < 120 { continue }
                // 音は届いているのに書く先が無ければ開く（割り込みのあとなど）
                self.reopenIfNeeded()
                let silent = Date.now.timeIntervalSince(self.writer.lastBufferAt)
                guard silent >= Self.micSilence else {
                    restarted = false
                    continue
                }
                if !restarted {
                    restarted = true
                    self.forceRestartEngine()
                    continue
                }
                // 前はここで録音を止め、開き直すまで戻らなかった（2026-11-22）。止めずに試し続ける
                self.stall("mic", "マイクの音が \(Int(silent)) 秒届いていません")
                continue
            }
        }
    }

    /// 録音中なのに書く先（区切りのファイル）が開いていなければ開く（休んでいるときは開かない）
    private func reopenIfNeeded() {
        guard isRecording, !stalled, !writer.isWriting else { return }
        do {
            try openChunk()
        } catch {
            stall("open", "録音のファイルを開けませんでした: \(error.localizedDescription)")
        }
    }

    /// マイクが動いているように見えても、音が来ないときに流し直す
    private func forceRestartEngine() {
        guard isRecording, !stalled else { return }
        do {
            rebuildEngine()
            try startEngine()
        } catch {
            stall("restart", "マイクを流し直せませんでした")
        }
    }

    func toggle() async {
        // 振動の型（始まった・止まった。2026-11-21。s20 の 体21。WatchDesign.swift）
        if isRecording {
            stopByUser()
            LLHaptic.stopped.play()
        } else {
            await start()
            if isRecording { LLHaptic.started.play() }
        }
    }

    /// 始めている途中（起動したときの再開と、画面を開いたときの再開が重なっても1回だけ始める。2026-11-20）
    @ObservationIgnored private var starting = false

    private func start() async {
        guard !isRecording, !starting else { return }
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "マイクが許可されていません"
            return
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try await session.activate()
            NotificationCenter.default.addObserver(
                self, selector: #selector(interrupted(_:)),
                name: AVAudioSession.interruptionNotification, object: session)
            NotificationCenter.default.addObserver(
                self, selector: #selector(configurationChanged(_:)),
                name: .AVAudioEngineConfigurationChange, object: nil)
            // 音の仕組みが作り直された・イヤホンなどをつないだ／外した（iPhone にはあり、時計に無かった。2026-11-23。s23 の 止2・止3）
            NotificationCenter.default.addObserver(
                self, selector: #selector(mediaServicesReset(_:)),
                name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(routeChanged(_:)),
                name: AVAudioSession.routeChangeNotification, object: session)
            try startEngine()
            isRecording = true
            sender.isRecording = true
            UserDefaults.standard.set(true, forKey: Self.wasRecordingKey)
            sender.noteAlive()
            guardian.update(recording: true, away: S39WatchPowerSide.away)
            message = ""
            sender.resendPending()
            watchMicrophone()
            refreshStatus()
        } catch {
            stopEngine()
            message = "録音を始められませんでした: \(error.localizedDescription)"
        }
    }

    /// 止めるボタンで止めたときだけ「録音中だった」を消す（自動再開しない）。
    func stopByUser() {
        UserDefaults.standard.set(false, forKey: Self.wasRecordingKey)
        stop()
    }

    func stop() {
        isRecording = false
        stalled = false
        stallTask?.cancel()
        stallTask = nil
        micCheck?.cancel()
        micCheck = nil
        interruptedSince = nil
        // 中断のあいだに止めたら、その中断は「止めた」で閉じる（2026-11-23。s23 の 止1）
        if interruptionOpen {
            interruptionOpen = false
            S23WatchRec.abandoned()
        }
        coveringForPhone = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.watchdogID])
        stopEngine()
        // 低電力モードで溜めていた区切りも、止めたら送る
        sender.resendPending()
        // 最後の区切りを送ってから知らせる
        sender.isRecording = false
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guardian.update(recording: false)
        refreshStatus()
    }

    /// マイクの音を流し始め、最初の区切りのファイルを開く。
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "WatchRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "マイクが使えません"])
        }
        writer.prepare(from: format)
        try openChunk()
        let writer = self.writer
        input.removeTap(onBus: 0)
        // 大きめの束で受け取る（呼ばれる回数が減る。watchOS が聞かないこともあるので、届いた長さを様子に出す。
        // 書く中身は ChunkWriter が前の大きさに分けて扱うので同じ。2026-11-29。s39 の 2）
        let tapSize = AVAudioFrameCount(S39WatchPower.isOn(S39WatchPower.quietKey) ? S39WatchPower.tapFrames : S39WatchPower.oldTapFrames)
        input.installTap(onBus: 0, bufferSize: tapSize, format: format) { buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finishChunk()
    }

    /// 止めて、マイクを流す部品を新しく作る（中断のあとに流し直すとき。2026-11-23）
    private func rebuildEngine() {
        stopEngine()
        // 設定「前の動きに戻す」のときは作り直さない（版 386 より前の動き。2026-11-23。s23 の 止16）
        guard !S23Rec.isOn(S23Rec.legacyKey) else { return }
        engine = AVAudioEngine()
    }

    private func openChunk() throws {
        try writer.open(WatchSender.newChunkURL())
        armWatchdog()
    }

    /// 次の区切りの少しあとに鳴る通知を予約し、区切るたびに先へ延ばす。
    /// 時計がアプリを終わらせたり止めたりして延ばせなくなると、この通知が鳴って気づける。
    /// 静かで休んでいるあいだは5分ごと（restTick）にしか延ばさないので、区切りが短くても5分より先に鳴らす（2026-11-07）
    private func armWatchdog() {
        let content = UNMutableNotificationContent()
        content.title = "LifeLog の録音が止まっているかもしれません"
        content.body = "LifeLog を開くか「録音を戻す」で、録音を再開します。"
        content.sound = .default
        // 「録音を戻す」（押すと開いてすぐ戻す。2026-11-23。s23 の 止7）
        content.categoryIdentifier = S23Rec.watchResumeCategory
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(ChunkCutter.longest, ChunkWriter.restTick) + 120, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.watchdogID, content: content, trigger: trigger))
    }

    /// 録音を止めるときに、いまの区切りを閉じて送る。
    private func finishChunk() {
        guard let chunk = writer.close() else { return }
        deliver(chunk.url, peakDB: chunk.peakDB, voiceFrames: chunk.voiceFrames)
    }

    /// 書いている糸が、静かなところで区切りを切り替えた。
    private func cut(_ url: URL, peakDB: Float, voiceFrames: Int, error: Error?) {
        deliver(url, peakDB: peakDB, voiceFrames: voiceFrames)
        armWatchdog()
        if let error, isRecording {
            stall("write", "録音を続けられませんでした: \(error.localizedDescription)")
        }
    }

    /// 書き終わった区切りを送る（ほぼ無音なら捨てる）。
    /// 声らしい音が無い区切りも捨てる（設定「声の無い区切りは送らない」。会議モードのあいだは捨てない。2026-11-16。VoiceGate）
    private func deliver(_ url: URL, peakDB: Float, voiceFrames: Int) {
        // 区切った時刻を残す（無音で捨てる区切りも。iPhone が「録音が本当に続いているか」を見分ける。2026-11-07）
        sender.noteCut()
        // 今日録れた時間に足す（ほぼ無音の区切りは数えない。声が無いので捨てる区切りは数える＝マイクで書いた時間。s21 の 使5）
        let now = Date.now
        if peakDB >= -50,
           let seconds = S21Watch.chunkSeconds(start: WatchDelivery.startDate(url.lastPathComponent, zone: .current), cut: now) {
            sender.noteRecorded(seconds, now: now)
        }
        let drop = VoiceGate.shouldDrop(tonalFrames: voiceFrames, enabled: VoiceGate.enabled, meeting: meetingOn)
        if peakDB < -50 {
            try? FileManager.default.removeItem(at: url)
        } else if drop, !S21Watch.shouldSampleNoVoice(name: url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
            VoiceGate.noteDropped()
        } else {
            // 捨てるはずだった区切りのうち 1 割は、印を付けて送る（家の PC が本当に声が無かったかを数える。s21 の 精7）
            if drop {
                WatchSender.markNoVoiceSample(url.lastPathComponent, now: now)
                sender.countToday(S21Watch.sampledNoVoiceKey, now: now)
            }
            sender.deliver(url)
            // 「初めての人が多い」モードのあいだは、区切りごとに「初めての人」の印を付ける（2026-11-21。s19 の 休17）
            if crowdActiveNow() { sender.newPerson(Date.now.addingTimeInterval(-HolidayRules.crowdMarkBack)) }
        }
        // 袖でこもった音が続いたら震える（初めはオフ。2026-11-22。s22 の 確31。S22WatchSide.swift）
        S22WatchSide.afterCut(url.lastPathComponent, peakDB: peakDB, now: now)
        // 無音で捨てた区切りでも、録音が続いていることは知らせる
        if isRecording {
            sender.readBattery()
            sender.heartbeat()
        }
        refreshStatus()
    }

    /// 送れていない区切りの数とつながりを出し直す。溜まりすぎたら知らせる。
    func refreshStatus() {
        // 外出中かを決め直す（2026-11-29。s39）
        sender.s39Refresh()
        unsent = sender.unsentCount()
        relayWaiting = sender.relayHeldCount()
        link = sender.linkText()
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        updateBatterySaver()
        meetingOn = UserDefaults.standard.bool(forKey: "meetingOn")
        _ = crowdActiveNow()
        let holding = sender.awayHolding
        if awayHolding != holding { awayHolding = holding }
        // 今日録れた時間と、最後に届いた時刻（s21 の 使5）
        let recorded = sender.recordedToday()
        if abs(recordedToday - recorded) >= 1 { recordedToday = recorded }
        let delivered = sender.lastDelivered()
        if lastDelivered != delivered { lastDelivered = delivered }
        // 外出中は強い守りを切る（止まったら戻す仕組みはそのまま。2026-11-29。s39 の 4）
        guardian.update(recording: isRecording, away: S39WatchPowerSide.away)
        // 録音を始めた・止めた・送っていない数が変わったら、文字盤も出し直す（変わったときだけ書く。2026-11-07）
        updateWidgets()
        let center = UNUserNotificationCenter.current()
        warnLowBatteryIfNeeded(center)
        // 時計の空きが少なくなったら知らせる（録音と控えが置けなくなる前に）
        if let free = WatchSender.freeSpace(), free < 300 * 1024 * 1024,
           Date.now.timeIntervalSince(lowSpaceAlerted) > 12 * 3600 {
            lowSpaceAlerted = .now
            let content = UNMutableNotificationContent()
            content.title = "時計の空きが少なくなっています"
            content.body = "残り \(free / 1024 / 1024)MB です。iPhone を近くに置いて、iPhone の LifeLog を開いてください（届いた録音の控えが消えて空きます）。"
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "low-space", content: content, trigger: nil))
        }
        // 外出モードでわざと溜めているあいだは、「送れていない」の知らせを出さない（2026-11-21。休8）
        if !sender.awayHolding, unsent >= (lowPower ? Self.unsentAlertLowPower : Self.unsentAlert) {
            guard !unsentAlerted else { return }
            unsentAlerted = true
            let content = UNMutableNotificationContent()
            content.title = "iPhone に送れていない録音が \(unsent) 個あります"
            content.body = "録音は時計の中に残っています。iPhone を近くに置き、iPhone の LifeLog を一度開いてください。（\(link)）"
            content.sound = .default
            center.add(UNNotificationRequest(identifier: Self.unsentID, content: content, trigger: nil))
        } else if unsent == 0, unsentAlerted {
            unsentAlerted = false
            center.removeDeliveredNotifications(withIdentifiers: [Self.unsentID])
        }
    }

    /// 電池が少ない（30% より下・低電力モード）あいだは、短めの設定でも自動で5分の区切りにする。
    /// 電池が 35% まで戻る・充電を始めたら、短めに戻す。次の区切りから効く（ChunkCutter.current）。2026-11-07
    private func updateBatterySaver() {
        let device = WKInterfaceDevice.current()
        let level: Double? = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        let charging = device.batteryState == .charging || device.batteryState == .full
        let saving = ChunkCutter.shouldSave(on: ChunkCutter.batterySaverOn, battery: level, charging: charging,
                                            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                            wasSaving: ChunkCutter.batterySaving)
        if saving != ChunkCutter.batterySaving { ChunkCutter.batterySaving = saving }
        // 画面に出すのは、短めの設定を5分にしているときだけ（ふつうの設定なら、もともと5分）
        let shown = saving && ChunkCutter.length == .short
        if batterySaving != shown { batterySaving = shown }
        // 寝ている時間（1:00〜6:00・充電していない）は 5 分に（設定「寝ている時間は 5 分に」。初めはオン。2026-11-22。s21 の 電3）
        let defaults = UserDefaults.standard
        let sleeping = S21Watch.sleepSaving(enabled: defaults.object(forKey: S21Watch.sleepChunksKey) as? Bool ?? true,
                                            hour: Calendar.current.component(.hour, from: .now), charging: charging)
        if defaults.bool(forKey: S21Watch.sleepSavingKey) != sleeping { defaults.set(sleeping, forKey: S21Watch.sleepSavingKey) }
        let sleepShown = sleeping && !saving && ChunkCutter.length == .short
        if sleepSaving != sleepShown { sleepSaving = sleepShown }
    }

    // MARK: - 休日のライフログ（2026-11-21。s19。HolidayRules）

    private static let lowBatteryDayKey = "lowBatteryWarnedDay"
    private static let lowBatteryID = "holiday-low-battery"

    /// 休日に電池が 20%（仮）を切ったら「PLAUD に任せて」（1 日 1 回。iPhone の設定でオンのときだけ。休9）
    private func warnLowBatteryIfNeeded(_ center: UNUserNotificationCenter) {
        let device = WKInterfaceDevice.current()
        let level: Double? = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        let charging = device.batteryState == .charging || device.batteryState == .full
        let defaults = UserDefaults.standard
        let now = Date.now
        let today = HolidayRules.dayKey(now)
        let enabled = defaults.object(forKey: HolidayRules.lowBatteryKey) as? Bool ?? true
        let holiday = HolidayRules.isHolidayToday(defaults.string(forKey: HolidayRules.holidayDayKey), now: now)
        guard HolidayRules.shouldWarnLowBattery(enabled: enabled, holiday: holiday, level: level, charging: charging,
                                                warnedDay: defaults.string(forKey: Self.lowBatteryDayKey), today: today),
              let level else { return }
        defaults.set(today, forKey: Self.lowBatteryDayKey)
        let content = UNMutableNotificationContent()
        content.title = "時計の電池が \(Int((level * 100).rounded()))% です"
        content.body = "このあとの録音は PLAUD に任せてください。時計の録音を止めると、電池が長く持ちます。"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.lowBatteryID, content: content, trigger: nil))
    }

    /// 「初めての人が多い」モードが続いているか（時間が過ぎたら切る）
    @discardableResult
    private func crowdActiveNow() -> Bool {
        let on = HolidayRules.crowdActive(until: UserDefaults.standard.double(forKey: WatchSender.crowdUntilKey), now: .now)
        if crowdOn != on { crowdOn = on }
        return on
    }

    /// 「初めての人が多い」モードを始める・終える（休17）
    func toggleCrowd() {
        let on = !crowdActiveNow()
        UserDefaults.standard.set(on ? Date.now.addingTimeInterval(HolidayRules.crowdLength).timeIntervalSince1970 : 0,
                                  forKey: WatchSender.crowdUntilKey)
        crowdOn = on
        if on { sender.newPerson(.now) }
        (on ? LLHaptic.started : LLHaptic.stopped).play()
        message = on ? "初めての人が多いモード: 区切りごとに印を付けます（4 時間で終わります）" : "初めての人が多いモードを終えました"
    }

    /// お酒を 1 杯（休30）
    func drink() {
        let now = Date.now
        let key = "drinks|" + HolidayRules.dayKey(now)
        let count = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(count, forKey: key)
        drinksToday = count
        sender.drink(now)
        S39WatchPowerSide.light(.confirm)
        message = "お酒 \(count) 杯目を残しました"
    }

    /// 今日の杯数を読み直す（画面を開いたとき）
    func refreshDrinks() {
        drinksToday = UserDefaults.standard.integer(forKey: "drinks|" + HolidayRules.dayKey(.now))
    }

    /// 大事なところに印を付ける（前後1分の行に★が付く）。
    func mark() {
        sender.mark(.now)
        // 外出中は小さな振動を切る（2026-11-29。s39 の 14）
        S39WatchPowerSide.light(.confirm)
        message = "\(Date.now.formatted(date: .omitted, time: .shortened)) に印を付けました"
    }

    /// 「いま初めての人と話している」の印（その前後の知らない声を、iPhone の確かめ待ちに出す）
    func markNewPerson() {
        sender.newPerson(.now)
        S39WatchPowerSide.light(.confirm)
        message = "\(Date.now.formatted(date: .omitted, time: .shortened)) 初めての人の印を付けました"
    }

    /// 「違う、〇〇さん」（話者や名前の直しを声で。2026-11-19。s18）。言葉はそのまま iPhone へ（解釈は家の PC）
    func voiceFix(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        sender.voiceFix(String(said.prefix(200)), at: .now)
        S39WatchPowerSide.light(.confirm)
        message = "「" + String(said.prefix(20)) + "」を iPhone に送りました"
    }

    /// 会議モードを始める・終える（iPhone が予定の参加者と議題をヒントにし、終わったらすぐまとめる）
    func toggleMeeting() {
        meetingOn.toggle()
        UserDefaults.standard.set(meetingOn, forKey: "meetingOn")
        sender.meeting(meetingOn)
        (meetingOn ? LLHaptic.started : LLHaptic.stopped).play()
        message = meetingOn ? "会議モードを始めました（音質を上げて録ります）" : "会議モードを終えました"
    }

    /// iPhone からの知らせを、震わせて画面に出す
    private func alert(_ text: String) {
        LLHaptic.confirm.play()
        message = text
    }

    /// 流し直しに失敗したとき、あと何回・何秒ごとに試すか（仮。2026-11-20）
    private static let restartRetries = 4
    private static let restartRetryEvery: TimeInterval = 30

    /// 割り込みなどで止まったマイクを流し直す。
    /// 2026-11-20: アラームのあと、音を使う許可（オーディオセッション）を取り直さずにマイクを流そうとして失敗し、
    /// 1回で諦めて録音を止めていた（14:16〜18:23 に止まった）。許可を取り直し、だめなら 30 秒ごとに 4 回まで試す
    private func restartEngine(attempt: Int = 0) {
        interruptedSince = nil
        guard isRecording, !stalled else { return }
        // 割り込みの始まりで区切りを閉じたが、マイクは止まっていなかったとき、前はここで何もせず、
        // 区切りを開かないまま「録音中」が続いていた（音は届くのに書く先が無い。2026-11-07）。書く先を開き直す
        if engine.isRunning {
            reopenIfNeeded()
            noteResumed()
            return
        }
        Task { @MainActor in
            guard self.isRecording, !self.stalled else { return }
            do {
                self.rebuildEngine()
                try await AVAudioSession.sharedInstance().activate()
                try self.startEngine()
                self.noteResumed()
            } catch {
                // だめだった回数（2026-11-23。s23 の 止1）
                if self.interruptionOpen { S23WatchRec.failed() }
                guard attempt < Self.restartRetries else {
                    // 前はここで録音を止めていた（2026-11-22）。止めずに、間を空けて試し続ける
                    self.stall("alarm", "アラームや電話のあとで録音を再開できていません")
                    return
                }
                // 試しているあいだは、マイクの見張りに「止まっている」と数えさせない
                self.interruptedSince = .now
                try? await Task.sleep(for: .seconds(Self.restartRetryEvery))
                self.restartEngine(attempt: attempt + 1)
            }
        }
    }

    /// 中断のあとに流し直せた（今日の数。休10）
    private func noteResumed() {
        guard interruptionOpen else { return }
        interruptionOpen = false
        sender.countToday(HolidayRules.resumedKey)
        // 戻るまでの秒と戻った道を残す（2026-11-23。s23 の 止1。1 分より長ければ 1 回知らせる＝止13）
        S23WatchRec.resumed(way: s23Way)
        s23Way = "ended"
    }

    /// 止めるボタンを押さずに録音が止まっていたら、始め直す（画面を開いたとき。2026-11-20）。
    /// 前はアプリが一から起動したときだけ再開していて、裏に残っていたアプリを開き直しても再開しなかった
    func resumeIfWanted() async {
        // 止まりかけて試し直しているところなら、待たずにすぐ試す（画面を開いたときは戻りやすい。2026-11-22）
        if isRecording, stalled {
            if s23Way == "ended" { s23Way = "open" }
            _ = await recoverStall()
            return
        }
        // アラームなどで止まったまま「終わった」の知らせを待っているところなら、待たずに今すぐ流し直す（2026-11-23。
        // 前は 1 分待つか知らせが来るまで何もせず、開いても録れなかった）
        // 設定「前の動きに戻す」のときは、前と同じく何もしない（2026-11-23。s23 の 止16）
        if isRecording, !stalled, !S23Rec.isOn(S23Rec.legacyKey) {
            if s23Way == "ended", interruptionOpen { s23Way = "open" }
            if engine.isRunning {
                reopenIfNeeded()
            } else {
                restartEngine()
            }
            return
        }
        guard !isRecording, UserDefaults.standard.bool(forKey: Self.wasRecordingKey) else { return }
        await start()
        if isRecording { message = "止まっていた録音を再開しました" }
    }

    // MARK: - 止まりかけても止めない（2026-11-22）

    /// 2026-11-20・21 に、マイクの音が来ない・流し直せないときに 1〜2 回試すだけで録音を止め、時計の LifeLog を開くまで
    /// 戻らなかった（11/20 14:25〜18:24・11/21 15:07〜16:27。時計自身が「録音していない」と言っていた）。
    /// 止めずに「止まりかけ」として残し、間を空けて（15 秒・30 秒・1 分・2 分、そのあと 5 分ごと）ずっと試し直す。
    /// 止めるボタンを押すまで続ける。止まっているあいだは見張りの通知（armWatchdog）が延びないので、数分で本人に届く
    @ObservationIgnored private var stalled = false
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    /// 試し直すまでの間（仮）
    static let stallWaits: [TimeInterval] = [15, 30, 60, 120, 300]

    static func stallWait(_ attempt: Int) -> TimeInterval {
        stallWaits[min(max(attempt, 0), stallWaits.count - 1)]
    }

    private func stall(_ code: String, _ reason: String) {
        guard isRecording, !stalled else { return }
        stalled = true
        interruptedSince = nil
        sender.countToday(HolidayRules.stallsKey)
        sender.noteStall(code)
        message = reason + "（自動で試し直しています）"
        stopEngine()
        // iPhone には「いまは録音していない」と知らせる（「録音しているつもり」は残る）
        sender.isRecording = false
        refreshStatus()
        stallTask?.cancel()
        stallTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.stallWait(attempt)))
                guard let self, self.isRecording, self.stalled, !Task.isCancelled else { return }
                if await self.recoverStall() { return }
                attempt += 1
            }
        }
    }

    /// 止まりかけた録音を戻してみる（音を使う許可を取り直してからマイクを流す）。戻せたら true
    private func recoverStall() async -> Bool {
        guard isRecording, stalled else { return !stalled }
        do {
            rebuildEngine()
            try await AVAudioSession.sharedInstance().activate()
            try startEngine()
        } catch {
            return false
        }
        stalled = false
        stallTask = nil
        sender.isRecording = true
        sender.countToday(HolidayRules.autoResumedKey)
        if s23Way == "ended" { s23Way = "stall" }
        noteResumed()
        message = "止まりかけた録音を自動で戻しました"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.watchdogID, "stopped"])
        sender.heartbeat()
        refreshStatus()
        return true
    }

    /// 録音が止まったことを、手首の振動と通知で知らせる。
    private func stopWithAlert(_ reason: String) {
        stop()
        message = reason
        LLHaptic.failed.play()
        let content = UNMutableNotificationContent()
        content.title = "LifeLog の録音が止まりました"
        content.body = reason
        content.sound = .default
        // 「録音を戻す」（押すと開いてすぐ戻す。2026-11-23。s23 の 止7）
        content.categoryIdentifier = S23Rec.watchResumeCategory
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "stopped", content: content, trigger: nil))
    }

    @objc nonisolated private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // 中断の理由（OS が教える分だけ。2026-11-23。s23 の 止5）
        let why = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
        Task { @MainActor in
            guard self.isRecording else { return }
            switch type {
            case .began:
                self.interruptedSince = .now
                // 中断の回数を数える（今日。家の PC の diag に watchInterruptions として載る。2026-11-21。s19 の 休10）
                if !self.interruptionOpen {
                    self.interruptionOpen = true
                    self.sender.countToday(HolidayRules.interruptionsKey)
                    // 始まりと理由を残す（2026-11-23。s23 の 止1・止5）
                    self.s23Way = "ended"
                    S23WatchRec.began(S23Rec.reasonCode(raw: why, inCall: false, began: .now))
                }
                self.finishChunk()
                // 「終わった」の知らせが来ないこともあるので、1分たっても止まったままなら自分で再開する。
                // そのあいだ 5 秒ごとに「ほかの音がまだ鳴っているか」を見て、止んだらすぐ流し直す
                // （2026-11-23。s23 の 止6。初めはオン・効くかは仮説。だめでも 1 分の戻しはそのまま）
                let began = Date.now
                var kicked = false
                while Date.now.timeIntervalSince(began) < S23Rec.ResumeFlow.firstWait {
                    try? await Task.sleep(for: .seconds(S23Rec.ResumeFlow.probeEvery))
                    guard self.isRecording else { return }
                    let other: Bool = AVAudioSession.sharedInstance().isOtherAudioPlaying
                    if !kicked, self.interruptionOpen,
                       S23Rec.watchKick(elapsed: Date.now.timeIntervalSince(began), otherAudio: other,
                                        probeOn: S23Rec.isOn(S23Rec.probeKey), legacy: S23Rec.isOn(S23Rec.legacyKey)) {
                        kicked = true
                        self.s23Way = "probe"
                        self.restartEngine()
                    }
                }
                if self.interruptionOpen { self.s23Way = "timer" }
                self.restartEngine()
            case .ended:
                if self.interruptionOpen { self.s23Way = "ended" }
                self.restartEngine()
            @unknown default:
                break
            }
        }
    }

    /// 音の経路が変わるとエンジンが止まるので、流し直す。
    @objc nonisolated private func configurationChanged(_ note: Notification) {
        // いま使っている部品の知らせだけを見る（作り直す前の部品の知らせは無視する。2026-11-23）
        let source: ObjectIdentifier? = (note.object as AnyObject?).map { ObjectIdentifier($0) }
        Task { @MainActor in
            guard source == nil || source == ObjectIdentifier(self.engine) else { return }
            self.restartEngine()
        }
    }

    // MARK: - s23 録音が止まらない（2026-11-23。S23WatchRec.swift）

    /// 次に戻ったときの道の名前（ended・timer・probe・open・stall・call・daily。止1）
    @ObservationIgnored private var s23Way = "ended"
    /// iPhone が戻れないので、時計で録り始めた（止10。iPhone が戻ったら止める）
    @ObservationIgnored private var coveringForPhone = false

    /// 音の仕組みが作り直された（止2）: 前の部品は使えないので、止めてから作り直して流す
    @objc nonisolated private func mediaServicesReset(_ note: Notification) {
        Task { @MainActor in
            guard self.isRecording, !S23Rec.isOn(S23Rec.legacyKey) else { return }
            S23WatchRec.count("mediaReset")
            self.stopEngine()
            self.restartEngine()
        }
    }

    /// イヤホンなどをつないだ・外した（止3）: 1 秒待って、マイクが止まっていたら流し直す（動いていれば書く先だけ確かめる）。
    /// 中断のあいだは中断の係に任せる
    @objc nonisolated private func routeChanged(_ note: Notification) {
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        guard S23Rec.routeShouldAct(reason) else { return }
        Task { @MainActor in
            guard self.isRecording, !S23Rec.isOn(S23Rec.legacyKey) else { return }
            S23WatchRec.count("route")
            try? await Task.sleep(for: .seconds(1))
            guard self.isRecording, !self.stalled, self.interruptedSince == nil else { return }
            if self.engine.isRunning {
                self.reopenIfNeeded()
            } else {
                self.restartEngine()
            }
        }
    }

    /// iPhone の電話が終わった（止4）: 時計も中断していれば、待たずに流し直す
    func s23CallEnded() {
        guard isRecording, interruptionOpen, !stalled, !S23Rec.isOn(S23Rec.legacyKey) else { return }
        s23Way = "call"
        restartEngine()
    }

    /// iPhone が戻れない・戻った（止10。iPhone の設定がオンのときだけ届く）。
    /// 本人が録るつもりでなかったときだけ始め、iPhone が戻ったら、ここで始めた分だけ止める。
    /// 時計が裏で録り始められるかは仮説（だめなら何もしない）
    func s23Cover(_ on: Bool) async {
        if on {
            guard !isRecording, !UserDefaults.standard.bool(forKey: Self.wasRecordingKey) else { return }
            await start()
            if isRecording {
                coveringForPhone = true
                message = "iPhone が戻れないあいだ、時計で録っています"
                S23WatchRec.count("cover")
            }
        } else {
            guard coveringForPhone else { return }
            coveringForPhone = false
            if isRecording {
                stopByUser()
                message = "iPhone が戻ったので、時計の録音を止めました"
            }
        }
    }

    /// 毎日同じ時刻に切れるなら、その 1 分後に見回る（止11）。止まっていれば戻す
    func s23DailyCheck() async {
        guard isRecording || UserDefaults.standard.bool(forKey: Self.wasRecordingKey) else { return }
        if interruptionOpen || stalled { s23Way = "daily" }
        await resumeIfWanted()
    }

    /// 中断の練習（止15。iPhone から頼まれる）: マイクをわざと 1 回止め、2 秒後に流し直して、戻るかを見る（戻る道だけを試す）
    func s23Drill() async {
        guard isRecording, !stalled, interruptedSince == nil, !interruptionOpen, engine.isRunning else {
            S23WatchRec.noteDrill(ok: false, seconds: 0)
            return
        }
        let began = Date.now
        S23WatchRec.began("drill", now: began)
        stopEngine()
        try? await Task.sleep(for: .seconds(2))
        restartEngine()
        while !engine.isRunning, isRecording, Date.now.timeIntervalSince(began) < S23Rec.drillLimit {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let ok: Bool = isRecording && engine.isRunning
        let seconds = Date.now.timeIntervalSince(began)
        if ok { S23WatchRec.resumed(way: "drill") } else { S23WatchRec.abandoned() }
        S23WatchRec.noteDrill(ok: ok, seconds: seconds)
        sender.heartbeat()
    }
}

/// マイクの音を 16kHz・1ch にして、今の区切りのファイルに書く。マイクの音は別のスレッドから届くので鍵をかける。
/// 決めた長さを過ぎたあとの静かなところで、自分で次の区切りに切り替える。
/// 1分続けて静かなら区切りを閉じて休み、音がしたらその2.5秒前から次の区切りを書き始める（SilenceGate）。
final class ChunkWriter: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// 会議モードのあいだは 48kbps、ふだんは 32kbps（2026-11-06。次の区切りから変わる）。
    /// 録り方の実験の日は、その日の組の音質（会議モードのあいだは会議モードが優先。2026-11-15。RecordingExperiment）
    static var fileSettings: [String: Any] {
        let rate: Int = RecordingExperiment.watchBitrate()
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: rate,
        ]
    }
    /// 休んでいるあいだ、これだけごとに「録音は続いている」と知らせる
    static let restTick: TimeInterval = 300

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var peak: Float = 0
    private var converter: AVAudioConverter?
    private var cutter = ChunkCutter()
    private var gate = SilenceGate()
    /// 区切りの中の声らしい音を数える（2026-11-16）
    private var voice = VoiceGate()
    /// 1 秒ごとの音の大きさ（区切りの metadata の levels。2026-11-22。s22 の 確4。S22Watch）
    private var levels = S22Watch.LevelMeter(rate: 16_000)
    /// 静かで休んでいるか
    private var resting = false
    private var restingSince: Date?
    private var lastTick = Date.distantPast
    /// 休んでいるあいだの直近の音（書き始めるときに頭に足す）
    private var preRoll: [AVAudioPCMBuffer] = []
    /// 休んでいるあいだの直近の音を、変換せずに元の形のまま（2026-11-29。s39 の 1）
    private var rawRoll = S39WatchPowerAudio.RestRoll()
    /// 静かなところの元の音と 16kHz の音の大きさの差（s39 の 1。差が小さいと分かったときだけ元の音で決める）
    private var levelGap = S39WatchPower.LevelGap()
    /// この休みのあいだ、元の音のまま持つか（休みに入るときに決める）
    private var rawWhileResting = false
    /// 変換しなかった束の数（様子に出す）
    private var rawSkipped = 0
    /// 書いている区切りを知らせる相手（書いている途中のファイルを送らないように）
    private let sender: WatchSender
    /// 区切りを切り替えたら呼ぶ。終わった区切り、その中のいちばん大きな音（dB）、声らしいこまの数（VoiceGate）、
    /// 次を開けなかったときのエラー
    private var onCut: (@Sendable (URL, Float, Int, Error?) -> Void)?
    /// 休んでいるあいだ、ときどき呼ぶ（録音が続いていることを知らせる）
    private var onRestTick: (@Sendable () -> Void)?

    init(sender: WatchSender) {
        self.sender = sender
    }

    func setOnCut(_ onCut: (@Sendable (URL, Float, Int, Error?) -> Void)?) {
        lock.withLock { self.onCut = onCut }
    }

    func setOnRestTick(_ onRestTick: (@Sendable () -> Void)?) {
        lock.withLock { self.onRestTick = onRestTick }
    }

    func prepare(from input: AVAudioFormat) {
        lock.withLock {
            converter = AVAudioConverter(from: input, to: Self.format)
            lastBuffer = .now
            // マイクの形が変わったかもしれないので、大きさの差は数え直す（s39 の 1）
            levelGap.reset()
            rawRoll.removeAll()
        }
    }

    /// 最後にマイクの音が届いた時刻（休んでいるあいだも届く。届かなければマイクが止まっている。2026-11-07）
    private var lastBuffer = Date.distantPast
    var lastBufferAt: Date { lock.withLock { lastBuffer } }
    /// 区切りのファイルに書いているか、静かで休んでいるか（どちらでもなければ、音が来ても捨てている）
    var isWriting: Bool { lock.withLock { file != nil || resting } }
    /// 静かで休んでいるか（マイクの見張りの間を広げる。s39 の 11）
    var isResting: Bool { lock.withLock { resting } }
    /// s39 の 1 の様子（変換しなかった束の数・大きさの差の平均）
    var s39Quiet: (skipped: Int, gap: Float?) { lock.withLock { (rawSkipped, levelGap.mean) } }

    func open(_ url: URL) throws {
        // ファイルができる前に「書いている途中」と知らせておく
        sender.recording = url
        sender.restingSince = nil
        let newFile = try AVAudioFile(forWriting: url, settings: Self.fileSettings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            file = newFile
            self.url = url
            peak = 0
            cutter.reset()
            gate.reset()
            voice.reset()
            levels.reset()
            resting = false
            restingSince = nil
            preRoll.removeAll()
            rawRoll.removeAll()
        }
    }

    /// マイクから届いた束（音の糸から呼ばれる）。
    /// 大きな束で届いたら、前の大きさ（4096）くらいに分けてから 1 つずつ前と同じに扱う（2026-11-29。s39 の 2）
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let frames = Int(buffer.frameLength)
        if frames > 0 {
            lastBuffer = .now
            S39WatchPowerSide.noteTap(frames: frames, rate: buffer.format.sampleRate)
        }
        guard file != nil || resting, converter != nil, frames > 0 else { return }
        let ranges = S39WatchPower.slices(frames: frames)
        if ranges.count <= 1 {
            writeOne(buffer, shared: true)
            return
        }
        for range in ranges {
            guard let piece = S39WatchPowerAudio.copy(buffer, range: range) else { continue }
            writeOne(piece, shared: false)
        }
    }

    /// 前の大きさの束を 1 つ扱う（鍵をかけたまま呼ぶ）。shared は、watchOS が使い回すかもしれない元の束か（持つときは写す）
    private func writeOne(_ buffer: AVAudioPCMBuffer, shared: Bool) {
        guard file != nil || resting, let converter, buffer.frameLength > 0 else { return }
        // 静かで休んでいるあいだは 16kHz に変換せず、元の音のまま直前の 2.5 秒を持つ（2026-11-29。s39 の 1）。
        // 元の音と 16kHz の音の大きさがほぼ同じと分かっているときだけ（差が大きければ前と同じに変換する）
        if resting, rawWhileResting, let samples = buffer.floatChannelData?[0] {
            preRoll.removeAll()
            let frames = Int(buffer.frameLength)
            let step = gate.feed(samples, count: frames, rate: buffer.format.sampleRate, resting: true)
            let piece: AVAudioPCMBuffer? = shared ? S39WatchPowerAudio.copy(buffer) : buffer
            if let piece {
                rawRoll.append(piece, keep: SilenceGate.preRoll)
            }
            rawSkipped += 1
            if step == .wake {
                // 持っていた元の音を変換して、前と同じに書き始める
                preRoll = rawRoll.converted(with: converter, to: Self.format)
                rawRoll.removeAll()
                wake(frames: preRoll.reduce(0) { $0 + Int($1.frameLength) })
            } else if Date.now.timeIntervalSince(lastTick) >= Self.restTick {
                lastTick = .now
                let tick = onRestTick
                DispatchQueue.main.async { tick?() }
            }
            return
        }
        if !rawRoll.isEmpty {
            // 休んでいる途中で元の音を持つのをやめた。変換器の名残を消して、前と同じやり方に戻す
            rawRoll.removeAll()
            converter.reset()
        }
        guard let out = S39WatchPowerAudio.convert(buffer, with: converter, to: Self.format),
              let samples = out.floatChannelData?[0] else { return }
        let frames = Int(out.frameLength)
        let step = gate.feed(samples, count: frames, rate: Self.format.sampleRate, resting: resting)
        if resting {
            preRoll.append(out)
            var total = preRoll.reduce(0) { $0 + Int($1.frameLength) }
            while total > Int(SilenceGate.preRoll * Self.format.sampleRate), preRoll.count > 1 {
                total -= Int(preRoll.removeFirst().frameLength)
            }
            if step == .wake {
                wake(frames: total)
            } else if Date.now.timeIntervalSince(lastTick) >= Self.restTick {
                lastTick = .now
                let tick = onRestTick
                DispatchQueue.main.async { tick?() }
            }
            return
        }
        // 書いているあいだに、静かなところの元の音と 16kHz の音の大きさの差を数える（s39 の 1 の安全の見張り）
        if let raw = S39WatchPowerAudio.level(buffer), let converted = S39WatchPowerAudio.level(out) {
            levelGap.feed(rawDB: raw, convertedDB: converted)
        }
        for i in 0..<frames { peak = max(peak, abs(samples[i])) }
        voice.feed(samples, count: frames)
        levels.feed(samples, count: frames, tonal: voice.tonalFrames)
        try? file?.write(from: out)
        if step == .rest {
            rest()
        } else if cutter.feed(samples, count: frames, rate: Self.format.sampleRate) {
            cutHere()
        }
    }

    /// 休みに入る：いまの区切りを閉じ、次は開かない（鍵をかけたまま呼ぶ）。
    private func rest() {
        guard let finished = url else { return }
        let peakDB = 20 * log10(max(peak, 1e-8))
        let voiced = voice.tonalFrames
        voice.reset()
        S22WatchSide.saveLevels(finished.lastPathComponent, levels.summary())
        levels.reset()
        file = nil
        url = nil
        resting = true
        let since = Date.now
        restingSince = since
        lastTick = since
        preRoll.removeAll()
        rawRoll.removeAll()
        rawWhileResting = S39WatchPower.isOn(S39WatchPower.quietKey) && levelGap.usable
        peak = 0
        cutter.reset()
        sender.recording = nil
        sender.restingSince = since
        let callback = onCut
        DispatchQueue.main.async { callback?(finished, peakDB, voiced, nil) }
    }

    /// 音がしたので、溜めておいた直前の音から次の区切りを書き始める（鍵をかけたまま呼ぶ）。
    private func wake(frames: Int) {
        let next = WatchSender.newChunkURL(at: Date.now.addingTimeInterval(-Double(frames) / Self.format.sampleRate))
        sender.recording = next
        do {
            file = try AVAudioFile(forWriting: next, settings: Self.fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            url = next
        } catch {
            // 開けなければ休んだまま、次の音でまた試す
            sender.recording = nil
            return
        }
        resting = false
        restingSince = nil
        sender.restingSince = nil
        peak = 0
        cutter.reset()
        voice.reset()
        levels.reset()
        for piece in preRoll {
            if let samples = piece.floatChannelData?[0] {
                for i in 0..<Int(piece.frameLength) { peak = max(peak, abs(samples[i])) }
                _ = cutter.feed(samples, count: Int(piece.frameLength), rate: Self.format.sampleRate)
                voice.feed(samples, count: Int(piece.frameLength))
            }
            try? file?.write(from: piece)
        }
        preRoll.removeAll()
        // 書き始めたことを知らせる（iPhone は、この区切りが届くのを待つ）
        let tick = onRestTick
        DispatchQueue.main.async { tick?() }
    }

    /// いまの区切りを閉じ、すぐ次の区切りを開く（鍵をかけたまま呼ぶ）。
    private func cutHere() {
        guard let finished = url else { return }
        let peakDB = 20 * log10(max(peak, 1e-8))
        let voiced = voice.tonalFrames
        voice.reset()
        S22WatchSide.saveLevels(finished.lastPathComponent, levels.summary())
        levels.reset()
        // AVAudioFile は手放したときに書き終わる
        file = nil
        url = nil
        let next = WatchSender.newChunkURL()
        sender.recording = next
        var failure: Error?
        do {
            file = try AVAudioFile(forWriting: next, settings: Self.fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            url = next
        } catch {
            failure = error
            sender.recording = nil
        }
        peak = 0
        cutter.reset()
        let callback = onCut
        let error = failure
        DispatchQueue.main.async { callback?(finished, peakDB, voiced, error) }
    }

    /// 今のファイルを閉じて、その場所と一番大きかった音（dB）と声らしいこまの数を返す。休んでいたら nil。
    func close() -> (url: URL, peakDB: Float, voiceFrames: Int)? {
        lock.lock()
        let closing = url
        let peakDB = 20 * log10(max(peak, 1e-8))
        let voiced = voice.tonalFrames
        voice.reset()
        if let closing { S22WatchSide.saveLevels(closing.lastPathComponent, levels.summary()) }
        levels.reset()
        file = nil
        url = nil
        resting = false
        restingSince = nil
        preRoll.removeAll()
        rawRoll.removeAll()
        lock.unlock()
        sender.recording = nil
        sender.restingSince = nil
        guard let closing else { return nil }
        return (url: closing, peakDB: peakDB, voiceFrames: voiced)
    }
}

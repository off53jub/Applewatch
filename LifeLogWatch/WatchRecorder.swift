import AVFoundation
import Observation
import UserNotifications
import WatchKit

/// 時計で録音し続け、区切ったファイル（短めの設定で長くても2分、ふつうで5分ほど）を iPhone に送る。
/// 画面が消えているあいだは録音を新しく始め直せないので、マイクは止めずに
/// AVAudioEngine で流し続け、書き込むファイルだけを切り替える。ほぼ無音の区切りは捨てる。
/// 1分続けて静かなら書くのを休み、音がしたらその1秒前から書き始める（無音を送らない）。
/// 区切りは、決めた長さを過ぎたあとの声の途切れたところで切る（言葉の途中で切らないため。ChunkCutter）。
/// 音は文字起こしに使う 16kHz・1ch にしてから書く（圧縮と送る量が減り、電池が長持ちする）。
@MainActor
@Observable
final class WatchRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var message = ""
    /// iPhone にまだ送れていない区切りの数
    private(set) var unsent = 0
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
    /// 時計の空きが少ないと知らせたか（12時間に1回まで）
    @ObservationIgnored private var lowSpaceAlerted = Date.distantPast

    private let sender: WatchSender
    /// 頼まれごと・次の予定・聞く・朝の読み上げの画面の中身（2026-11-07）
    let board: WatchBoard
    private let engine = AVAudioEngine()
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
        writer.setOnCut { [weak self] url, peak, error in
            Task { @MainActor in self?.cut(url, peakDB: peak, error: error) }
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
        sender.activate()
        refreshStatus()
        // 前回、止めるボタンを押さずに終わっていたら、開き直したときに録音を再開する
        if UserDefaults.standard.bool(forKey: Self.wasRecordingKey) {
            Task { @MainActor in
                await self.start()
                if self.isRecording { self.message = "途中で止まっていた録音を再開しました" }
            }
        }
    }

    func toggle() async {
        if isRecording { stopByUser() } else { await start() }
    }

    private func start() async {
        guard !isRecording else { return }
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
                name: .AVAudioEngineConfigurationChange, object: engine)
            try startEngine()
            isRecording = true
            sender.isRecording = true
            UserDefaults.standard.set(true, forKey: Self.wasRecordingKey)
            message = ""
            sender.resendPending()
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
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.watchdogID])
        stopEngine()
        // 低電力モードで溜めていた区切りも、止めたら送る
        sender.resendPending()
        // 最後の区切りを送ってから知らせる
        sender.isRecording = false
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
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
        content.body = "LifeLog を開くと録音を再開します。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(ChunkCutter.longest, ChunkWriter.restTick) + 120, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.watchdogID, content: content, trigger: trigger))
    }

    /// 録音を止めるときに、いまの区切りを閉じて送る。
    private func finishChunk() {
        guard let chunk = writer.close() else { return }
        deliver(chunk.url, peakDB: chunk.peakDB)
    }

    /// 書いている糸が、静かなところで区切りを切り替えた。
    private func cut(_ url: URL, peakDB: Float, error: Error?) {
        deliver(url, peakDB: peakDB)
        armWatchdog()
        if let error, isRecording {
            stopWithAlert("録音を続けられませんでした: \(error.localizedDescription)")
        }
    }

    /// 書き終わった区切りを送る（ほぼ無音なら捨てる）。
    private func deliver(_ url: URL, peakDB: Float) {
        if peakDB < -50 {
            try? FileManager.default.removeItem(at: url)
        } else {
            sender.deliver(url)
        }
        // 無音で捨てた区切りでも、録音が続いていることは知らせる
        if isRecording {
            sender.readBattery()
            sender.heartbeat()
        }
        refreshStatus()
    }

    /// 送れていない区切りの数とつながりを出し直す。溜まりすぎたら知らせる。
    func refreshStatus() {
        unsent = sender.unsentCount()
        link = sender.linkText()
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        updateBatterySaver()
        meetingOn = UserDefaults.standard.bool(forKey: "meetingOn")
        // 録音を始めた・止めた・送っていない数が変わったら、文字盤も出し直す（変わったときだけ書く。2026-11-07）
        updateWidgets()
        let center = UNUserNotificationCenter.current()
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
        if unsent >= (lowPower ? Self.unsentAlertLowPower : Self.unsentAlert) {
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
    }

    /// 大事なところに印を付ける（前後1分の行に★が付く）。
    func mark() {
        sender.mark(.now)
        WKInterfaceDevice.current().play(.success)
        message = "\(Date.now.formatted(date: .omitted, time: .shortened)) に印を付けました"
    }

    /// 「いま初めての人と話している」の印（その前後の知らない声を、iPhone の確かめ待ちに出す）
    func markNewPerson() {
        sender.newPerson(.now)
        WKInterfaceDevice.current().play(.success)
        message = "\(Date.now.formatted(date: .omitted, time: .shortened)) 初めての人の印を付けました"
    }

    /// 会議モードを始める・終える（iPhone が予定の参加者と議題をヒントにし、終わったらすぐまとめる）
    func toggleMeeting() {
        meetingOn.toggle()
        UserDefaults.standard.set(meetingOn, forKey: "meetingOn")
        sender.meeting(meetingOn)
        WKInterfaceDevice.current().play(meetingOn ? .start : .stop)
        message = meetingOn ? "会議モードを始めました（音質を上げて録ります）" : "会議モードを終えました"
    }

    /// iPhone からの知らせを、震わせて画面に出す
    private func alert(_ text: String) {
        WKInterfaceDevice.current().play(.notification)
        message = text
    }

    /// 割り込みなどで止まったマイクを流し直す。
    private func restartEngine() {
        guard isRecording, !engine.isRunning else { return }
        do {
            stopEngine()
            try startEngine()
        } catch {
            stopWithAlert("電話や Siri で止まりました。アプリを開いて再開してください。")
        }
    }

    /// 録音が止まったことを、手首の振動と通知で知らせる。
    private func stopWithAlert(_ reason: String) {
        stop()
        message = reason
        WKInterfaceDevice.current().play(.failure)
        let content = UNMutableNotificationContent()
        content.title = "LifeLog の録音が止まりました"
        content.body = reason
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "stopped", content: content, trigger: nil))
    }

    @objc nonisolated private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            guard self.isRecording else { return }
            switch type {
            case .began:
                self.finishChunk()
                // 「終わった」の知らせが来ないこともあるので、1分たっても止まったままなら自分で再開する
                try? await Task.sleep(for: .seconds(60))
                self.restartEngine()
            case .ended:
                self.restartEngine()
            @unknown default:
                break
            }
        }
    }

    /// 音の経路が変わるとエンジンが止まるので、流し直す。
    @objc nonisolated private func configurationChanged(_ note: Notification) {
        Task { @MainActor in self.restartEngine() }
    }
}

/// マイクの音を 16kHz・1ch にして、今の区切りのファイルに書く。マイクの音は別のスレッドから届くので鍵をかける。
/// 決めた長さを過ぎたあとの静かなところで、自分で次の区切りに切り替える。
/// 1分続けて静かなら区切りを閉じて休み、音がしたらその1秒前から次の区切りを書き始める（SilenceGate）。
final class ChunkWriter: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// 会議モードのあいだは 48kbps、ふだんは 32kbps（2026-11-06。次の区切りから変わる）
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: UserDefaults.standard.bool(forKey: "meetingOn") ? 48_000 : 32_000,
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
    /// 静かで休んでいるか
    private var resting = false
    private var restingSince: Date?
    private var lastTick = Date.distantPast
    /// 休んでいるあいだの直近の音（書き始めるときに頭に足す）
    private var preRoll: [AVAudioPCMBuffer] = []
    /// 書いている区切りを知らせる相手（書いている途中のファイルを送らないように）
    private let sender: WatchSender
    /// 区切りを切り替えたら呼ぶ。終わった区切り、その中のいちばん大きな音（dB）、次を開けなかったときのエラー
    private var onCut: (@Sendable (URL, Float, Error?) -> Void)?
    /// 休んでいるあいだ、ときどき呼ぶ（録音が続いていることを知らせる）
    private var onRestTick: (@Sendable () -> Void)?

    init(sender: WatchSender) {
        self.sender = sender
    }

    func setOnCut(_ onCut: (@Sendable (URL, Float, Error?) -> Void)?) {
        lock.withLock { self.onCut = onCut }
    }

    func setOnRestTick(_ onRestTick: (@Sendable () -> Void)?) {
        lock.withLock { self.onRestTick = onRestTick }
    }

    func prepare(from input: AVAudioFormat) {
        lock.withLock { converter = AVAudioConverter(from: input, to: Self.format) }
    }

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
            resting = false
            restingSince = nil
            preRoll.removeAll()
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard file != nil || resting, let converter, buffer.frameLength > 0 else { return }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
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
        for i in 0..<frames { peak = max(peak, abs(samples[i])) }
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
        file = nil
        url = nil
        resting = true
        let since = Date.now
        restingSince = since
        lastTick = since
        preRoll.removeAll()
        peak = 0
        cutter.reset()
        sender.recording = nil
        sender.restingSince = since
        let callback = onCut
        DispatchQueue.main.async { callback?(finished, peakDB, nil) }
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
        for piece in preRoll {
            if let samples = piece.floatChannelData?[0] {
                for i in 0..<Int(piece.frameLength) { peak = max(peak, abs(samples[i])) }
                _ = cutter.feed(samples, count: Int(piece.frameLength), rate: Self.format.sampleRate)
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
        DispatchQueue.main.async { callback?(finished, peakDB, error) }
    }

    /// 今のファイルを閉じて、その場所と一番大きかった音（dB）を返す。休んでいたら nil。
    func close() -> (url: URL, peakDB: Float)? {
        lock.lock()
        let closing = url
        let peakDB = 20 * log10(max(peak, 1e-8))
        file = nil
        url = nil
        resting = false
        restingSince = nil
        preRoll.removeAll()
        lock.unlock()
        sender.recording = nil
        sender.restingSince = nil
        guard let closing else { return nil }
        return (url: closing, peakDB: peakDB)
    }
}

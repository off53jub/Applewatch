import AVFoundation
import Observation
import UserNotifications
import WatchKit

/// 時計で録音し続け、5分ほどで区切ったファイルを iPhone に送る。
/// 画面が消えているあいだは録音を新しく始め直せないので、マイクは止めずに
/// AVAudioEngine で流し続け、書き込むファイルだけを切り替える。ほぼ無音の区切りは捨てる。
/// 1分続けて静かなら書くのを休み、音がしたらその1秒前から書き始める（無音を送らない）。
/// 区切りは、5分たったあとの声の途切れたところで切る（言葉の途中で切らないため。ChunkCutter）。
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

    private let sender: WatchSender
    private let engine = AVAudioEngine()
    private let writer: ChunkWriter

    /// 録音中に時計がアプリを終わらせても気づけるよう、「録音中だった」ことを残しておく。
    private static let wasRecordingKey = "wasRecording"
    private static let watchdogID = "watchdog"
    private static let unsentID = "unsent"
    /// 送れていない区切りがこれだけ溜まったら知らせる（低電力モードでは、まとめて送るぶん多めに待つ）
    private static let unsentAlert = 4
    private static let unsentAlertLowPower = 6
    @ObservationIgnored private var unsentAlerted = false

    override init() {
        let sender = WatchSender()
        self.sender = sender
        writer = ChunkWriter(sender: sender)
        super.init()
        sender.onChange = { [weak self] in
            Task { @MainActor in self?.refreshStatus() }
        }
        writer.setOnCut { [weak self] url, peak, error in
            Task { @MainActor in self?.cut(url, peakDB: peak, error: error) }
        }
        // 静かで休んでいるあいだも、録音が続いていることを iPhone に知らせ、見張りの通知を延ばす
        writer.setOnRestTick { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
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
    private func armWatchdog() {
        let content = UNMutableNotificationContent()
        content.title = "LifeLog の録音が止まっているかもしれません"
        content.body = "LifeLog を開くと録音を再開します。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: ChunkCutter.target + ChunkCutter.maxExtra + 120, repeats: false)
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
        if isRecording { sender.heartbeat() }
        refreshStatus()
    }

    /// 送れていない区切りの数とつながりを出し直す。溜まりすぎたら知らせる。
    func refreshStatus() {
        unsent = sender.unsentCount()
        link = sender.linkText()
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let center = UNUserNotificationCenter.current()
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

    /// 大事なところに印を付ける（前後1分の行に★が付く）。
    func mark() {
        sender.mark(.now)
        WKInterfaceDevice.current().play(.success)
        message = "\(Date.now.formatted(date: .omitted, time: .shortened)) に印を付けました"
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
/// 5分たったあとの静かなところで、自分で次の区切りに切り替える。
/// 1分続けて静かなら区切りを閉じて休み、音がしたらその1秒前から次の区切りを書き始める（SilenceGate）。
final class ChunkWriter: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]
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

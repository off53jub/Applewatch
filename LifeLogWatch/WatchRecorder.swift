import AVFoundation
import Observation
import UserNotifications
import WatchKit

/// 時計で録音し続け、5分ごとに区切ったファイルを iPhone に送る。
/// 画面が消えているあいだは録音を新しく始め直せないので、マイクは止めずに
/// AVAudioEngine で流し続け、書き込むファイルだけを5分ごとに切り替える。ほぼ無音の区切りは捨てる。
@MainActor
@Observable
final class WatchRecorder: NSObject {
    static let chunkSeconds: TimeInterval = 300

    private(set) var isRecording = false
    private(set) var message = ""

    private let sender = WatchSender()
    private let engine = AVAudioEngine()
    private let writer = ChunkWriter()
    private var chunkTimer: Timer?

    private let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 録音中に時計がアプリを終わらせても気づけるよう、「録音中だった」ことを残しておく。
    private static let wasRecordingKey = "wasRecording"
    private static let watchdogID = "watchdog"

    override init() {
        super.init()
        sender.activate()
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
            chunkTimer = Timer.scheduledTimer(withTimeInterval: Self.chunkSeconds, repeats: true) { _ in
                Task { @MainActor in self.rotate() }
            }
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
        chunkTimer?.invalidate()
        chunkTimer = nil
        stopEngine()
        // 最後の区切りを送ってから知らせる
        sender.isRecording = false
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// マイクの音を流し始め、最初の区切りのファイルを開く。
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        try openChunk(format: format)
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

    private func openChunk(format: AVAudioFormat) throws {
        let url = WatchSender.pendingDir.appendingPathComponent(nameFormatter.string(from: .now) + ".m4a")
        sender.recording = url
        try writer.open(url, format: format)
        armWatchdog()
    }

    /// 次の区切りの少しあとに鳴る通知を予約し、区切るたびに先へ延ばす。
    /// 時計がアプリを終わらせたり止めたりして延ばせなくなると、この通知が鳴って気づける。
    private func armWatchdog() {
        let content = UNMutableNotificationContent()
        content.title = "LifeLog の録音が止まっているかもしれません"
        content.body = "LifeLog を開くと録音を再開します。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.chunkSeconds + 120, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.watchdogID, content: content, trigger: trigger))
    }

    private func finishChunk() {
        guard let chunk = writer.close() else { return }
        sender.recording = nil
        if chunk.peakDB < -50 {
            try? FileManager.default.removeItem(at: chunk.url)
        } else {
            sender.send(chunk.url)
        }
        // 無音で捨てた区切りでも、録音が続いていることは知らせる
        if isRecording { sender.heartbeat() }
    }

    /// 大事なところに印を付ける（前後1分の行に★が付く）。
    func mark() {
        sender.mark(.now)
        WKInterfaceDevice.current().play(.success)
        message = "\(Date.now.formatted(date: .omitted, time: .shortened)) に印を付けました"
    }

    /// マイクは流したまま、書き込み先のファイルだけを切り替える。
    private func rotate() {
        guard isRecording else { return }
        finishChunk()
        do {
            try openChunk(format: engine.inputNode.outputFormat(forBus: 0))
        } catch {
            stopWithAlert("録音を続けられませんでした: \(error.localizedDescription)")
        }
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

/// マイクの音を受け取って今の区切りのファイルに書く。マイクの音は別のスレッドから届くので鍵をかける。
final class ChunkWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var peak: Float = 0

    func open(_ url: URL, format: AVAudioFormat) throws {
        // マイクの形式のまま AAC で書く（変換しない）
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        let newFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        lock.lock()
        file = newFile
        peak = 0
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        try? file.write(from: buffer)
        if let samples = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(samples[i]))
            }
        }
    }

    /// 今のファイルを閉じて、その場所と一番大きかった音（dB）を返す。
    func close() -> (url: URL, peakDB: Float)? {
        lock.lock()
        let closing = file
        let peakDB = 20 * log10(max(peak, 1e-8))
        file = nil
        lock.unlock()
        // AVAudioFile は手放したときに書き終わる
        guard let url = closing?.url else { return nil }
        return (url: url, peakDB: peakDB)
    }
}

import AVFoundation
import Observation
import UserNotifications
import WatchKit

/// 時計で5分ごとに区切って録音し、できた区切りを iPhone に送る。
/// 区切り方は iPhone 側の Recorder と同じ（AAC 16kHz モノラル、ほぼ無音は捨てる）。
@MainActor
@Observable
final class WatchRecorder: NSObject {
    static let chunkSeconds: TimeInterval = 300

    private(set) var isRecording = false
    private(set) var message = ""

    private let sender = WatchSender()
    private var recorder: AVAudioRecorder?
    private var chunkTimer: Timer?
    private var meterTimer: Timer?
    private var peakPower: Float = -160

    private let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

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
            isRecording = true
            UserDefaults.standard.set(true, forKey: Self.wasRecordingKey)
            message = ""
            sender.resendPending(except: nil)
            try startChunk()
            chunkTimer = Timer.scheduledTimer(withTimeInterval: Self.chunkSeconds, repeats: true) { _ in
                Task { @MainActor in self.rotate() }
            }
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in
                    guard let r = self.recorder else { return }
                    r.updateMeters()
                    self.peakPower = max(self.peakPower, r.peakPower(forChannel: 0))
                }
            }
        } catch {
            isRecording = false
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
        meterTimer?.invalidate()
        chunkTimer = nil
        meterTimer = nil
        finishChunk()
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startChunk() throws {
        let name = nameFormatter.string(from: .now) + ".m4a"
        let url = WatchSender.pendingDir.appendingPathComponent(name)
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        peakPower = -160
        guard r.record() else { throw NSError(domain: "WatchRecorder", code: 1) }
        recorder = r
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
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        if peakPower < -50 {
            try? FileManager.default.removeItem(at: r.url)
        } else {
            sender.send(r.url)
        }
    }

    private func rotate() {
        guard isRecording else { return }
        finishChunk()
        do { try startChunk() } catch { stopWithAlert("録音を続けられませんでした") }
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
                guard self.isRecording, self.recorder == nil else { return }
                do {
                    try await AVAudioSession.sharedInstance().activate()
                    try self.startChunk()
                } catch {
                    self.stopWithAlert("電話や Siri で止まりました。アプリを開いて再開してください。")
                }
            case .ended:
                // 時計はバックグラウンドでは再開できないことがある。失敗したら知らせる。
                guard self.recorder == nil else { return }
                do {
                    try await AVAudioSession.sharedInstance().activate()
                    try self.startChunk()
                } catch {
                    self.stopWithAlert("電話や Siri で止まりました。アプリを開いて再開してください。")
                }
            @unknown default:
                break
            }
        }
    }
}

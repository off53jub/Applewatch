import AVFoundation

/// 5分ごとに区切って AAC で録音し続ける。区切るたびに onChunk に完成したファイルを渡す。
@MainActor
final class Recorder: NSObject {
    static let chunkSeconds: TimeInterval = 300

    var onChunk: ((URL) -> Void)?
    var onStop: ((String) -> Void)?
    private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var peakPower: Float = -160

    private let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers])
        try session.setActive(true)
        NotificationCenter.default.addObserver(
            self, selector: #selector(interrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: session)
        isRecording = true
        try startChunk()
        timer = Timer.scheduledTimer(withTimeInterval: Self.chunkSeconds, repeats: true) { _ in
            Task { @MainActor in self.rotate() }
        }
        // メーターは無音判定に使う
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            Task { @MainActor in
                guard self.isRecording, let r = self.recorder else { t.invalidate(); return }
                r.updateMeters()
                self.peakPower = max(self.peakPower, r.peakPower(forChannel: 0))
            }
        }
    }

    func stop() {
        isRecording = false
        timer?.invalidate()
        timer = nil
        finishChunk()
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startChunk() throws {
        let url = Storage.pendingDir.appendingPathComponent(Storage.chunkName(for: .now))
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        peakPower = -160
        guard r.record() else { throw NSError(domain: "Recorder", code: 1) }
        recorder = r
    }

    private func finishChunk() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        // ほぼ無音（-50dB 未満）のチャンクは捨てる
        if peakPower < -50 {
            try? FileManager.default.removeItem(at: r.url)
        } else {
            onChunk?(r.url)
        }
    }

    private func rotate() {
        guard isRecording else { return }
        finishChunk()
        do { try startChunk() } catch { stopWithReason("録音を続けられませんでした: \(error.localizedDescription)") }
    }

    private func stopWithReason(_ reason: String) {
        stop()
        onStop?(reason)
    }

    @objc nonisolated private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                self.finishChunk()
            case .ended:
                guard self.isRecording else { return }
                // バックグラウンドでは再開できないことがある。失敗したら通知して止める。
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try self.startChunk()
                } catch {
                    self.stopWithReason("電話などで録音が止まりました。アプリを開いて再開してください。")
                }
            @unknown default:
                break
            }
        }
    }
}

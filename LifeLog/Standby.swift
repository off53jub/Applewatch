import AVFoundation

/// 待機モード。無音を流し続けて、画面を消してもアプリを裏で起こしておく。
/// 電池を使うので、時計が録音しているあいだだけ動かす（Pipeline が start / stop する）。
/// こうすると、時計から届いた区切りを届いたその場で文字起こしできる。
/// iPhone で録音しているあいだや声の登録中は、録音がアプリを起こしておくので無音は止める。
@MainActor
final class Standby {
    private var engine: AVAudioEngine?
    private var routeObserver: NSObjectProtocol?
    /// 設定でオンになっているか
    private var wanted = false
    /// iPhone のマイクを使っているあいだは止めておく
    private var suspended = false

    init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                // 電話などが終わったら流し直す
                if raw.flatMap({ AVAudioSession.InterruptionType(rawValue: $0) }) == .ended { self?.restart() }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    func start() {
        wanted = true
        run()
    }

    func stop() {
        let wasRunning = engine != nil
        wanted = false
        halt()
        // iPhone のマイクを使っているあいだは、録音の音の設定を止めない
        if wasRunning, !suspended {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// iPhone のマイクを使う前に呼ぶ
    func suspend() {
        suspended = true
        halt()
    }

    /// iPhone のマイクを使い終わったら呼ぶ
    func resume() {
        suspended = false
        run()
    }

    private func restart() {
        halt()
        run()
    }

    private func run() {
        guard wanted, !suspended, engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // ほかのアプリの音楽などは止めない
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100),
                  let samples = silence.floatChannelData?[0] else { return }
            silence.frameLength = silence.frameCapacity
            samples.update(repeating: 0, count: Int(silence.frameLength))
            player.scheduleBuffer(silence, at: nil, options: .loops)
            // 経路の変化（イヤホンの抜き差しなど）で止まったら流し直す
            routeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            }
            try engine.start()
            player.play()
            self.engine = engine
        } catch {
            halt()
        }
    }

    private func halt() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        guard let engine else { return }
        engine.stop()
        self.engine = nil
    }
}

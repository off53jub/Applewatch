import AVFoundation

/// 5分ほどで区切って AAC で録音し続ける。区切るたびに onChunk に完成したファイルを渡す。
/// 区切りは、5分たったあとの声の途切れたところで切る（言葉の途中で切らないため。ChunkCutter）。
/// マイクの音は AVAudioEngine で受け、16kHz・1ch にしてファイルに書く。ライブ文字起こしがオンなら、同じ音をそちらにも渡す。
@MainActor
final class Recorder: NSObject {
    static let chunkSeconds: TimeInterval = 300

    var onChunk: ((URL) -> Void)?
    var onStop: ((String) -> Void)?
    private(set) var isRecording = false

    private var engine: AVAudioEngine?
    private let writer = ChunkWriter { Storage.pendingDir.appendingPathComponent(Storage.chunkName(for: .now)) }
    private var observers: [NSObjectProtocol] = []

    /// ライブ文字起こしに音を渡す（録音の裏の糸で呼ばれる）。nil で止める。
    func setListener(_ listener: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        writer.setListener(listener)
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated { self?.interrupted(raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) }) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartEngine() }
            },
        ]
        isRecording = true
        // 書いている糸が静かなところで区切りを切り替えたら、終わった区切りを受け取る
        writer.setOnCut { [weak self] url, peak, error in
            Task { @MainActor in self?.cut(url, peak: peak, error: error) }
        }
        do {
            try writer.open(Self.newChunkURL())
            try startEngine()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        isRecording = false
        stopEngine()
        finishChunk()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func newChunkURL() -> URL {
        Storage.pendingDir.appendingPathComponent(Storage.chunkName(for: .now))
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Recorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "マイクが使えません"])
        }
        writer.prepare(from: format)
        Self.installTap(on: input, format: format, writer: writer)
        // イヤホンの抜き差しなどで止まったら、つなぎ直す
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        })
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// 音を受ける処理は録音の糸で動くので、画面の糸に縛られないところで作る
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, writer: ChunkWriter) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.receive(buffer)
        }
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func restartEngine() {
        guard isRecording else { return }
        stopEngine()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
        } catch {
            stopWithReason("録音を続けられませんでした: \(error.localizedDescription)")
        }
    }

    private func finishChunk() {
        guard let done = writer.close() else { return }
        // ほぼ無音（-50dB 未満）のチャンクは捨てる
        if done.peak < -50 {
            try? FileManager.default.removeItem(at: done.url)
        } else {
            onChunk?(done.url)
        }
    }

    /// 書いている糸が区切りを切り替えた。終わった区切りを渡し、次を開けなかったら止める。
    private func cut(_ url: URL, peak: Float, error: Error?) {
        if peak < -50 {
            try? FileManager.default.removeItem(at: url)
        } else {
            onChunk?(url)
        }
        if let error, isRecording {
            stopWithReason("録音を続けられませんでした: \(error.localizedDescription)")
        }
    }

    private func stopWithReason(_ reason: String) {
        stop()
        onStop?(reason)
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            stopEngine()
            finishChunk()
        case .ended:
            guard isRecording else { return }
            // バックグラウンドでは再開できないことがある。失敗したら通知して止める。
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try writer.open(Self.newChunkURL())
                try startEngine()
            } catch {
                stopWithReason("電話などで録音が止まりました。アプリを開いて再開してください。")
            }
        default:
            break
        }
    }
}

/// マイクの音を 16kHz・1ch にして、いまの区切りのファイルに書く。録音の糸と画面の糸の両方から触るので鍵をかける。
final class ChunkWriter: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    /// いまの区切りでいちばん大きかった音（0〜1）
    private var peak: Float = 0
    private var converter: AVAudioConverter?
    private var listener: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// 区切る位置を決める
    private var cutter = ChunkCutter()
    /// 次の区切りのファイルの場所を作る
    private let makeURL: @Sendable () -> URL
    /// 区切りを切り替えたら呼ぶ（画面の糸で）。終わった区切り、その中のいちばん大きな音（dB）、次を開けなかったときのエラー
    private var onCut: (@Sendable (URL, Float, Error?) -> Void)?

    init(makeURL: @escaping @Sendable () -> URL) {
        self.makeURL = makeURL
    }

    func setOnCut(_ onCut: (@Sendable (URL, Float, Error?) -> Void)?) {
        lock.withLock { self.onCut = onCut }
    }

    func prepare(from input: AVAudioFormat) {
        lock.withLock { converter = AVAudioConverter(from: input, to: Self.format) }
    }

    func setListener(_ listener: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { self.listener = listener }
    }

    func open(_ url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: Self.fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            self.file = file
            self.url = url
            peak = 0
            cutter.reset()
        }
    }

    /// いまの区切りを閉じる（ファイルを手放すと書き終わる）。peak は dB。
    func close() -> (url: URL, peak: Float)? {
        lock.withLock {
            guard let url else { return nil }
            file = nil
            self.url = nil
            return (url, 20 * log10(max(peak, 1e-8)))
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, buffer.frameLength > 0 else { return }
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
        for i in 0..<Int(out.frameLength) { peak = max(peak, abs(samples[i])) }
        try? file?.write(from: out)
        listener?(out)
        if file != nil, cutter.feed(samples, count: Int(out.frameLength), rate: Self.format.sampleRate) {
            cutHere()
        }
    }

    /// いまの区切りを閉じ、すぐ次の区切りを開く（鍵をかけたまま呼ぶ）。
    private func cutHere() {
        guard let finished = url else { return }
        let peakDB = 20 * log10(max(peak, 1e-8))
        // ファイルを手放すと書き終わる
        file = nil
        url = nil
        var failure: Error?
        let next = makeURL()
        do {
            file = try AVAudioFile(forWriting: next, settings: Self.fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            url = next
        } catch {
            failure = error
        }
        peak = 0
        cutter.reset()
        let callback = onCut
        let error = failure
        DispatchQueue.main.async { callback?(finished, peakDB, error) }
    }
}

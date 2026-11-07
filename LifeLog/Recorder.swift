import AVFoundation

/// 区切って AAC で録音し続ける（短めの設定で長くても2分、ふつうで5分ほど）。区切るたびに onChunk に完成したファイルを渡す。
/// 区切りは、決めた長さを過ぎたあとの声の途切れたところで切る（言葉の途中で切らないため。ChunkCutter）。
/// マイクの音は AVAudioEngine で受け、16kHz・1ch にしてファイルに書く。ライブ文字起こしがオンなら、同じ音をそちらにも渡す。
/// 外付けのマイク（USB・受信機など）がつながっていれば、それで録る（2026-11-07。MicInput.swift の MicChoice）。
/// 2チャンネル（左右）のマイクは、左右を平均して1チャンネルにし、左右それぞれの大きさを別に残す（ChannelStore）。
@MainActor
final class Recorder: NSObject {
    /// ふつうの設定の区切りの長さ（今は ChunkCutter が設定から決める。2026-11-07）
    static let chunkSeconds: TimeInterval = 300

    var onChunk: ((URL) -> Void)?
    var onStop: ((String) -> Void)?
    private(set) var isRecording = false

    private var engine: AVAudioEngine?
    private let writer = ChunkWriter { Storage.pendingDir.appendingPathComponent(Storage.chunkName(for: $0)) }

    /// いま書いている区切り（静かで休んでいるときは nil）
    var writingURL: URL? { writer.currentURL }
    private var observers: [NSObjectProtocol] = []

    /// ライブ文字起こしに音を渡す（録音の裏の糸で呼ばれる）。nil で止める。
    func setListener(_ listener: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        writer.setListener(listener)
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Bluetooth のマイクを使う設定のときだけ、Bluetooth を足す（2026-11-07。MicInput.swift）
        try session.setCategory(.playAndRecord, mode: .default,
                                options: MicChoice.categoryOptions(mode: MicChoice.mode, bluetooth: MicChoice.bluetoothOn))
        try session.setActive(true)
        // 外付けのマイク（USB・受信機など）がつながっていれば、それで録る
        MicChoice.apply(session)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated { self?.interrupted(raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) }) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartEngine() }
            },
            // マイクをつないだ・外したら選び直す（音の形が変わったときは、下の AVAudioEngineConfigurationChange でつなぎ直す）
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.routeChanged() }
            },
            // 設定「マイク」が変わった
            center.addObserver(forName: MicChoice.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.choiceChanged() }
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
        MicRoute.shared.update(recording: true, session: session)
    }

    func stop() {
        isRecording = false
        stopEngine()
        finishChunk()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        MicRoute.shared.update(recording: false)
    }

    /// マイクをつないだ・外した（外したときは iOS が iPhone のマイクに戻す。選び直しても同じなら何もしない）
    private func routeChanged() {
        guard isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        MicChoice.apply(session)
        MicRoute.shared.update(recording: true, session: session)
    }

    /// 設定「マイク」が変わったので、録音中なら今から選び直す
    private func choiceChanged() {
        guard isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        let options = MicChoice.categoryOptions(mode: MicChoice.mode, bluetooth: MicChoice.bluetoothOn)
        if session.categoryOptions != options {
            try? session.setCategory(.playAndRecord, mode: .default, options: options)
        }
        MicChoice.apply(session)
        MicRoute.shared.update(recording: true, session: session)
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
            MicRoute.shared.update(recording: true)
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
/// 1分続けて静かなら区切りを閉じて休み、音がしたらその1秒前から次の区切りを書き始める（SilenceGate）。
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
    /// 2チャンネル以上のマイクか（そのときは、左右を自分で平均してから converter にかける。2026-11-07）
    private var stereo = false
    /// 2チャンネルの音が思った形でなかったときに使う、iOS に左右を混ぜてもらう converter
    private var fallback: AVAudioConverter?
    /// いまの区切りの左右の大きさ（2チャンネルのマイクのときだけ）
    private var track: ChannelTrack?
    /// いまの区切りに書いた長さ（16kHz の数）。左右の大きさの時刻に使う
    private var written = 0
    /// 休んでいるあいだの直近の音の、左右の大きさ（preRoll と同じ並び。1チャンネルのマイクなら nil）
    private var preRollPower: [(left: Float, right: Float)?] = []
    private var listener: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// 区切る位置を決める
    private var cutter = ChunkCutter()
    /// 音がしないあいだは書かない
    private var gate = SilenceGate()
    /// 静かで休んでいるか
    private var resting = false
    /// 休んでいるあいだの直近の音（書き始めるときに頭に足す）
    private var preRoll: [AVAudioPCMBuffer] = []
    /// 次の区切りのファイルの場所を作る（引数は区切りの始まりの時刻）
    private let makeURL: @Sendable (Date) -> URL
    /// 区切りを切り替えたら呼ぶ（画面の糸で）。終わった区切り、その中のいちばん大きな音（dB）、次を開けなかったときのエラー
    private var onCut: (@Sendable (URL, Float, Error?) -> Void)?

    init(makeURL: @escaping @Sendable (Date) -> URL) {
        self.makeURL = makeURL
    }

    /// いま書いている区切り（休んでいるときは nil）
    var currentURL: URL? { lock.withLock { url } }

    func setOnCut(_ onCut: (@Sendable (URL, Float, Error?) -> Void)?) {
        lock.withLock { self.onCut = onCut }
    }

    func prepare(from input: AVAudioFormat) {
        lock.withLock {
            // 2チャンネル以上のマイク（受信機など）は、左右を平均してから 16kHz・1ch にする（左右の大きさも残すため）。
            // 前は converter に任せていたので、左のチャンネルしか書いていなかった
            if input.channelCount >= 2,
               let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false) {
                converter = AVAudioConverter(from: mono, to: Self.format)
                let mixer = AVAudioConverter(from: input, to: Self.format)
                mixer?.downmix = true
                fallback = mixer
                stereo = true
            } else {
                converter = AVAudioConverter(from: input, to: Self.format)
                fallback = nil
                stereo = false
            }
        }
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
            gate.reset()
            resting = false
            preRoll.removeAll()
            preRollPower.removeAll()
            track = nil
            written = 0
        }
    }

    /// いまの区切りを閉じる（ファイルを手放すと書き終わる）。peak は dB。休んでいたら nil。
    /// 2チャンネルのマイクで録っていたら、左右の大きさも置く（ChannelStore）
    func close() -> (url: URL, peak: Float)? {
        let done: (url: URL, peak: Float, track: ChannelTrack?)? = lock.withLock {
            resting = false
            preRoll.removeAll()
            preRollPower.removeAll()
            let finishedTrack = track
            track = nil
            written = 0
            guard let url else { return nil }
            file = nil
            self.url = nil
            return (url, 20 * log10(max(peak, 1e-8)), finishedTrack)
        }
        guard let done else { return nil }
        if let finishedTrack = done.track { ChannelStore.save(finishedTrack, for: done.url.lastPathComponent) }
        return (done.url, done.peak)
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.frameLength > 0 else { return }
        // 2チャンネル以上のマイクは、左右を平均した1チャンネルにしてから変える（左右の大きさを覚えておく）
        var source = buffer
        var active = converter
        var power: (left: Float, right: Float)?
        if stereo {
            if let split = StereoSplit.split(buffer) {
                source = split.mono
                power = (split.left, split.right)
            } else {
                active = fallback
            }
        }
        guard let active else { return }
        let input = source
        let ratio = Self.format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        active.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
        let frames = Int(out.frameLength)
        listener?(out)
        let step = gate.feed(samples, count: frames, rate: Self.format.sampleRate, resting: resting)
        if resting {
            preRoll.append(out)
            preRollPower.append(power)
            var total = preRoll.reduce(0) { $0 + Int($1.frameLength) }
            while total > Int(SilenceGate.preRoll * Self.format.sampleRate), preRoll.count > 1 {
                total -= Int(preRoll.removeFirst().frameLength)
                if !preRollPower.isEmpty { preRollPower.removeFirst() }
            }
            if step == .wake { wake(frames: total) }
            return
        }
        for i in 0..<frames { peak = max(peak, abs(samples[i])) }
        record(power, frames: frames)
        try? file?.write(from: out)
        if step == .rest {
            rest()
        } else if file != nil, cutter.feed(samples, count: frames, rate: Self.format.sampleRate) {
            cutHere()
        }
    }

    /// 書く音の左右の大きさを、いまの区切りの時刻で残す（書く前に呼ぶ。鍵をかけたまま呼ぶ）。1チャンネルの音なら長さだけ数える
    private func record(_ power: (left: Float, right: Float)?, frames: Int) {
        if let power {
            if track == nil { track = ChannelTrack(selfChannel: StereoMic.selfChannel) }
            track?.add(at: Double(written) / Self.format.sampleRate, leftPower: power.left, rightPower: power.right)
        }
        written += frames
    }

    /// 終わった区切りの左右の大きさを、録音の糸の外で置く（鍵をかけたまま呼ぶ）
    private func saveTrack(for finished: URL) {
        guard let done = track else { return }
        track = nil
        let name = finished.lastPathComponent
        DispatchQueue.global(qos: .utility).async { ChannelStore.save(done, for: name) }
    }

    /// 休みに入る：いまの区切りを閉じ、次は開かない（鍵をかけたまま呼ぶ）。
    private func rest() {
        guard let finished = url else { return }
        let peakDB = 20 * log10(max(peak, 1e-8))
        file = nil
        url = nil
        resting = true
        preRoll.removeAll()
        preRollPower.removeAll()
        saveTrack(for: finished)
        written = 0
        peak = 0
        cutter.reset()
        let callback = onCut
        DispatchQueue.main.async { callback?(finished, peakDB, nil) }
    }

    /// 音がしたので、溜めておいた直前の音から次の区切りを書き始める（鍵をかけたまま呼ぶ）。
    private func wake(frames: Int) {
        let started = Date.now.addingTimeInterval(-Double(frames) / Self.format.sampleRate)
        let next = makeURL(started)
        do {
            file = try AVAudioFile(forWriting: next, settings: Self.fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            url = next
        } catch {
            // 開けなければ休んだまま、次の音でまた試す
            return
        }
        resting = false
        peak = 0
        cutter.reset()
        track = nil
        written = 0
        for (n, piece) in preRoll.enumerated() {
            if let samples = piece.floatChannelData?[0] {
                for i in 0..<Int(piece.frameLength) { peak = max(peak, abs(samples[i])) }
                _ = cutter.feed(samples, count: Int(piece.frameLength), rate: Self.format.sampleRate)
            }
            record(n < preRollPower.count ? preRollPower[n] : nil, frames: Int(piece.frameLength))
            try? file?.write(from: piece)
        }
        preRoll.removeAll()
        preRollPower.removeAll()
    }

    /// いまの区切りを閉じ、すぐ次の区切りを開く（鍵をかけたまま呼ぶ）。
    private func cutHere() {
        guard let finished = url else { return }
        let peakDB = 20 * log10(max(peak, 1e-8))
        // ファイルを手放すと書き終わる
        file = nil
        url = nil
        saveTrack(for: finished)
        written = 0
        var failure: Error?
        let next = makeURL(.now)
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

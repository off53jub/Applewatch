import AVFoundation
import Observation

/// ライブ文字起こし。話の切れ目ごとに数秒の音を Groq（large-v3-turbo）に送り、返ってきた文を流す。
/// 画面に出すだけで、記録には書かない（記録はいつもの5分ごとの文字起こしで書く）。
@MainActor
@Observable
final class LiveTranscriber {
    struct Line: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }

    private(set) var lines: [Line] = []
    /// いま声が入っている
    private(set) var hearing = false
    /// 文字にしている途中の切れ目の数
    private(set) var waiting = 0
    private(set) var status = ""

    var apiKey: () -> String? = { nil }
    var keywords: () -> [String] = { [] }

    @ObservationIgnored private let segmenter = Segmenter()
    @ObservationIgnored private var queue: [(start: Date, samples: [Float])] = []
    @ObservationIgnored private var sending = false

    /// 録音から音を受け取る関数
    var listener: @Sendable (AVAudioPCMBuffer) -> Void {
        let segmenter = segmenter
        return { segmenter.feed($0) }
    }

    func start() {
        status = apiKey() == nil ? "Groq の API キーを「設定」→「サービスと API キーの設定」で入れてください。" : ""
        segmenter.reset { [weak self] start, samples in
            Task { @MainActor in self?.enqueue(start, samples) }
        } onVoice: { [weak self] voice in
            Task { @MainActor in self?.hearing = voice }
        }
    }

    func stop() {
        segmenter.reset(onSegment: nil, onVoice: nil)
        queue.removeAll()
        hearing = false
    }

    func clear() { lines.removeAll() }

    private func enqueue(_ start: Date, _ samples: [Float]) {
        queue.append((start, samples))
        // 遅れがたまったら古い分から捨てる（ライブなので）
        if queue.count > 4 { queue.removeFirst(queue.count - 4) }
        waiting = queue.count + (sending ? 1 : 0)
        Task { await pump() }
    }

    private func pump() async {
        guard !sending else { return }
        sending = true
        defer {
            sending = false
            waiting = queue.count
        }
        while !queue.isEmpty {
            let (start, samples) = queue.removeFirst()
            waiting = queue.count + 1
            guard let key = apiKey() else {
                status = "Groq の API キーを「設定」→「サービスと API キーの設定」で入れてください。"
                queue.removeAll()
                return
            }
            do {
                let url = try Self.write(samples)
                defer { try? FileManager.default.removeItem(at: url) }
                let previous = lines.suffix(3).map(\.text).joined()
                let heard = try await CloudTranscriber.quick(url, apiKey: key, keywords: keywords(),
                                                             previous: previous.isEmpty ? nil : previous)
                for line in heard where !line.text.isEmpty {
                    lines.append(Line(time: start.addingTimeInterval(line.offset ?? 0), text: line.text))
                }
                if lines.count > 300 { lines.removeFirst(lines.count - 300) }
                status = ""
            } catch CloudTranscriber.Failure.limited(let reason) {
                status = reason + "。少し待って続けます。"
                queue.removeAll()
                try? await Task.sleep(for: .seconds(5))
            } catch {
                status = "文字にできませんでした: \(error.localizedDescription)"
            }
        }
    }

    /// 音を一時ファイル（m4a）に書く。関数を出るとファイルが閉じて書き終わる。
    private static func write(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).m4a")
        let file = try AVAudioFile(forWriting: url, settings: ChunkWriter.fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: ChunkWriter.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return url }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        return url
    }
}

/// 16kHz の音を、話の切れ目（0.7秒の無音）か12秒で区切る。声の無い区間は送らない。
final class Segmenter: @unchecked Sendable {
    private static let rate = 16_000.0
    /// これより大きい音（dB）を声とみなす
    private static let voiceLevel: Float = -45

    private let lock = NSLock()
    private var samples: [Float] = []
    private var start: Date?
    private var voiced = 0.0
    private var silence = 0.0
    private var lastVoice = false
    private var onSegment: (@Sendable (Date, [Float]) -> Void)?
    private var onVoice: (@Sendable (Bool) -> Void)?

    func reset(onSegment: (@Sendable (Date, [Float]) -> Void)?, onVoice: (@Sendable (Bool) -> Void)?) {
        lock.withLock {
            samples = []
            start = nil
            voiced = 0
            silence = 0
            lastVoice = false
            self.onSegment = onSegment
            self.onVoice = onVoice
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let level = 20 * log10(max((sum / Float(count)).squareRoot(), 1e-7))
        let seconds = Double(count) / Self.rate
        let loud = level > Self.voiceLevel

        lock.lock()
        guard let onSegment else {
            lock.unlock()
            return
        }
        if start == nil { start = .now.addingTimeInterval(-seconds) }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
        if loud {
            voiced += seconds
            silence = 0
        } else {
            silence += seconds
        }
        let total = Double(samples.count) / Self.rate
        var segment: (Date, [Float])?
        if voiced < 0.3 && total >= 3 {
            // 声が無いまま。話し始めを切らないよう、最後の0.5秒だけ残す
            samples = Array(samples.suffix(Int(0.5 * Self.rate)))
            start = .now.addingTimeInterval(-0.5)
            voiced = 0
        } else if total >= 12 || (voiced >= 0.8 && silence >= 0.7 && total >= 2.5) {
            segment = (start ?? .now, samples)
            samples = []
            start = nil
            voiced = 0
            silence = 0
        }
        let hearing = voiced >= 0.3
        let changed = hearing != lastVoice
        lastVoice = hearing
        let onVoice = onVoice
        lock.unlock()

        if changed { onVoice?(hearing) }
        if let segment { onSegment(segment.0, segment.1) }
    }
}

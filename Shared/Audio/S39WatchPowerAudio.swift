import AVFoundation

/// s39 の 1・2（2026-11-29）の音の部品（時計の ChunkWriter が使う。テストは LifeLogTests/S39WatchPowerTests.swift）。
/// - 1: 静かで休んでいるあいだは、マイクの音を 16kHz に変換せず、元の形のまま直前の 2.5 秒（SilenceGate.preRoll）を持つ。
///   声がしたら、持っていた音を変換して書く（書く音の形式・長さは前と同じ。変換器はそこで一度まっさらにする）。
/// - 2: 大きな束で届いた音を、前の大きさくらいに分ける（静かかどうか・区切りを前と同じ細かさで決める）。
enum S39WatchPowerAudio {
    /// 束の中の frames の範囲だけを写した新しい束（元の束は watchOS が使い回すことがあるので、持つときは必ず写す）
    static func copy(_ buffer: AVAudioPCMBuffer, range: Range<Int>? = nil) -> AVAudioPCMBuffer? {
        let total = Int(buffer.frameLength)
        let r = range ?? 0..<total
        guard r.lowerBound >= 0, r.upperBound <= total, !r.isEmpty,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(r.count)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        // 交互に並んだ形（interleaved）は 1 本の列にまとめて写す
        if buffer.format.isInterleaved {
            (dst[0]).update(from: src[0].advanced(by: r.lowerBound * stride), count: r.count * stride)
        } else {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch].advanced(by: r.lowerBound), count: r.count)
            }
        }
        out.frameLength = AVAudioFrameCount(r.count)
        return out
    }

    /// 前と同じやり方で 1 つの束を変換する（ChunkWriter.write の前の中身）
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// 1 本目の音の大きさ（dB。SilenceGate と同じ平均の二乗）。読めなければ nil
    static func level(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength)
        let stride = buffer.format.isInterleaved ? buffer.stride : 1
        var sum: Float = 0
        for i in 0..<frames {
            let v = samples[i * stride]
            sum += v * v
        }
        return 10 * log10(max(sum / Float(frames), 1e-12))
    }

    /// 休んでいるあいだの直前の音（元の形のまま）。keep 秒より古い分は前から捨てる（前の preRoll と同じ決まり）
    struct RestRoll {
        private(set) var pieces: [AVAudioPCMBuffer] = []
        private(set) var frames = 0

        var isEmpty: Bool { pieces.isEmpty }

        /// 写しを足す（写せなければ足さない）
        mutating func append(_ piece: AVAudioPCMBuffer, keep seconds: TimeInterval) {
            pieces.append(piece)
            frames += Int(piece.frameLength)
            let limit = Int(seconds * piece.format.sampleRate)
            while frames > limit, pieces.count > 1 {
                frames -= Int(pieces.removeFirst().frameLength)
            }
        }

        mutating func removeAll() {
            pieces.removeAll()
            frames = 0
        }

        /// 持っていた音を変換する（変換器はまっさらにしてから。休んでいるあいだ通していないので、前の音の名残を残さない）
        func converted(with converter: AVAudioConverter, to format: AVAudioFormat) -> [AVAudioPCMBuffer] {
            converter.reset()
            return pieces.compactMap { S39WatchPowerAudio.convert($0, with: converter, to: format) }
        }
    }
}

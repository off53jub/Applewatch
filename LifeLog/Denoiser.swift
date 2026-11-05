import Accelerate
import AVFoundation

/// 聞き直すときの雑音を減らす（スペクトル減算）。録音そのものは変えない。
///
/// 音を短いかたまり（32ms）に分けて周波数ごとの強さを出し、ずっと鳴っている音（空調・ファン・車の走行音など）の強さを
/// 「静かなかたまり」から見積もって、その分を差し引く。最後に聞きやすい大きさにそろえる。
/// 人の話し声のような、変わり続ける周りの雑音はあまり減らない。
enum Denoiser {
    private static let size = 512
    private static let hop = 256
    /// 見積もった雑音より、どれだけ多めに引くか
    private static let overSubtraction: Float = 2.0
    /// 残す最小の割合（引きすぎると「シュワシュワ」した音が出る）
    private static let floorGain: Float = 0.1

    static func process(_ input: [Float]) -> [Float] {
        let n = size, half = n / 2, log2n = vDSP_Length(9)
        guard input.count > n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return input }
        defer { vDSP_destroy_fftsetup(setup) }

        // 平方根ハン窓（分析と合成の両方にかけると、半分ずつ重ねて元に戻る）
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        window = window.map { $0.squareRoot() }

        let padded = [Float](repeating: 0, count: n) + input + [Float](repeating: 0, count: n)
        let frames = (padded.count - n) / hop + 1

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)

        /// 1つのかたまりを周波数に変える（real/imag に入る。real[0] は直流、imag[0] は最高の周波数）
        func forward(_ f: Int) {
            let start = f * hop
            padded.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }

        /// 周波数ごとの強さ（0〜half の half+1 個）
        func power() -> [Float] {
            var p = [Float](repeating: 0, count: half + 1)
            p[0] = real[0] * real[0]
            p[half] = imag[0] * imag[0]
            for k in 1..<half { p[k] = real[k] * real[k] + imag[k] * imag[k] }
            return p
        }

        // 1回目: かたまりごとの強さを集め、周波数ごとに静かなほうから15%の強さを雑音とみなす
        var powers = [[Float]](repeating: [], count: frames)
        for f in 0..<frames {
            forward(f)
            powers[f] = power()
        }
        var noise = [Float](repeating: 0, count: half + 1)
        let rank = max(0, min(frames - 1, frames * 15 / 100))
        var column = [Float](repeating: 0, count: frames)
        for k in 0...half {
            for f in 0..<frames { column[f] = powers[f][k] }
            column.sort()
            noise[k] = column[rank]
        }

        // 2回目: 雑音の分を差し引いて、重ねて戻す
        var output = [Float](repeating: 0, count: padded.count)
        var previous = [Float](repeating: 1, count: half + 1)
        let scale = 1 / Float(2 * n)
        for f in 0..<frames {
            forward(f)
            let p = powers[f]
            var gain = [Float](repeating: 1, count: half + 1)
            for k in 0...half {
                let g = p[k] > 0 ? max(floorGain, 1 - overSubtraction * noise[k] / p[k]) : floorGain
                // 急に変わると耳障りなので、前のかたまりと少し混ぜる
                gain[k] = 0.7 * g.squareRoot() + 0.3 * previous[k]
            }
            previous = gain
            real[0] *= gain[0]
            imag[0] *= gain[half]
            for k in 1..<half {
                real[k] *= gain[k]
                imag[k] *= gain[k]
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            let start = f * hop
            for j in 0..<n { output[start + j] += frame[j] * window[j] * scale }
        }
        var result = Array(output[n..<(n + input.count)])

        // 聞きやすい大きさにそろえる（大きい音の上位0.5%が -6dB 前後になるように。上げすぎない）
        let sorted = result.map(abs).sorted()
        let loud = sorted[min(sorted.count - 1, sorted.count * 995 / 1000)]
        if loud > 1e-4 {
            let target: Float = 0.5
            var factor = min(8, target / loud)
            vDSP_vsmul(result, 1, &factor, &result, 1, vDSP_Length(result.count))
            var low: Float = -1, high: Float = 1
            vDSP_vclip(result, 1, &low, &high, &result, 1, vDSP_Length(result.count))
        }
        return result
    }

    /// 音声ファイルの from〜to 秒を読み、雑音を減らした一時ファイル（caf）にする。
    static func clip(_ url: URL, from: TimeInterval, to: TimeInterval) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, from) * rate)
        let endFrame = min(file.length, AVAudioFramePosition(max(from, to) * rate))
        let count = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: count)
        guard let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let frames = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        // 1つにまとめる
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channelCount {
            for i in 0..<frames { mono[i] += channels[c][i] / Float(channelCount) }
        }
        let cleaned = process(mono)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("clean-\(UUID().uuidString).caf")
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(cleaned.count)),
              let data = outBuffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        cleaned.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: cleaned.count) }
        outBuffer.frameLength = AVAudioFrameCount(cleaned.count)
        let writer = try AVAudioFile(forWriting: out, settings: outFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: outBuffer)
        return out
    }
}

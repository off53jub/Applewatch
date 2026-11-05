import AVFoundation
import Foundation

/// 区切りの騒がしさを測る。
///
/// 50ms ごとの音の大きさ（dBFS）を出し、いちばん静かなほうから2割のところを「周りの音の底」、
/// 声のある区間（VAD）の大きいほうから1割のところを「声の大きさ」とする。
/// 底が高い（ずっと何かが鳴っている）か、声と底の差が小さい（声が雑音に埋もれている）区切りを「騒がしい」とみなす。
/// しきい値は実際の録音ではまだ合わせていない目安。
enum NoiseMeter {
    struct Reading {
        /// 周りの音の底（dBFS）
        let floor: Float
        /// 声の大きさ（dBFS）。声の区間が分からなければ nil
        let speech: Float?

        /// 声と周りの音の差（dB）
        var margin: Float? { speech.map { $0 - floor } }

        var isNoisy: Bool {
            if floor >= NoiseMeter.loudFloor { return true }
            if let margin, floor >= NoiseMeter.quietFloor, margin < NoiseMeter.minimumMargin { return true }
            return false
        }

        var summary: String {
            var text = String(format: "周りの音 %.0f dB", floor)
            if let margin { text += String(format: "・声との差 %.0f dB", margin) }
            return text
        }
    }

    /// 周りの音の底がこれより大きければ、それだけで騒がしい（にぎやかな飲食店・駅・車内など）
    static let loudFloor: Float = -42
    /// 静かな部屋の底より大きく、
    static let quietFloor: Float = -55
    /// 声と周りの音の差がこれより小さければ騒がしい
    static let minimumMargin: Float = 12

    nonisolated static func measure(_ url: URL, voice: [(start: TimeInterval, end: TimeInterval)]?) -> Reading? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData?[0] else { return nil }
        let rate = file.processingFormat.sampleRate
        let count = Int(buffer.frameLength)
        let step = max(1, Int(rate * 0.05))
        guard count >= step * 20 else { return nil }
        var all: [Float] = []
        var voiced: [Float] = []
        var i = 0
        while i + step <= count {
            var sum: Float = 0
            for j in i..<(i + step) { sum += data[j] * data[j] }
            let db = 20 * log10(max((sum / Float(step)).squareRoot(), 1e-7))
            all.append(db)
            let t = Double(i) / rate
            if let voice, voice.contains(where: { t >= $0.start && t < $0.end }) { voiced.append(db) }
            i += step
        }
        all.sort()
        let floor = all[all.count / 5]
        var speech: Float?
        if voiced.count >= 10 {
            voiced.sort()
            speech = voiced[min(voiced.count - 1, voiced.count * 9 / 10)]
        }
        return Reading(floor: floor, speech: speech)
    }
}

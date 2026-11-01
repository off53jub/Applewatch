import FluidAudio
import Foundation

/// 区切りの中で人の声がしているところを、端末内で見つける（Silero VAD。FluidAudio に入っているもの）。
/// 声のあるところだけを Haas-ja に渡して、雑音や音楽から文が作られるのを減らし、処理も軽くする。
/// 声がほとんど無い区切りは、重い文字起こしをしない。モデルは初めて使うときに一度だけ取ってくる。
actor VoiceDetector {
    static let shared = VoiceDetector()

    typealias Span = (start: TimeInterval, end: TimeInterval)

    private var manager: VadManager?
    private var failedAt: Date?

    /// 声のある区間（秒）。モデルが使えないときは nil（そのときは今までどおり全部を見る）。
    func speech(in url: URL) async -> [Span]? {
        guard let manager = await load() else { return nil }
        do {
            let samples = try AudioConverter().resampleAudioFile(url)
            // 小さな声も拾えるよう、しきい値は低めにする（取りこぼすより、少し多めに渡すほうがよい）
            let config = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.5,
                                               maxSpeechDuration: 30, speechPadding: 0.2)
            let segments = try await manager.segmentSpeech(samples, config: config)
            return segments.map { (start: $0.startTime, end: $0.endTime) }
        } catch {
            return nil
        }
    }

    private func load() async -> VadManager? {
        if let manager { return manager }
        // 取ってこられなかったら、1時間は試さない
        if let failedAt, failedAt.timeIntervalSinceNow > -3600 { return nil }
        do {
            let loaded = try await VadManager(config: VadConfig(defaultThreshold: 0.5))
            manager = loaded
            return loaded
        } catch {
            failedAt = .now
            return nil
        }
    }

    /// 声のある時間の合計（秒）
    static func total(_ spans: [Span]) -> TimeInterval {
        spans.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }
}

import AVFoundation
import SoundAnalysis

/// 録音の中の、声以外の背景の音（音楽・電車・拍手や笑い・テレビ）を、iOS に入っている音の聞き分け（SoundAnalysis）で調べる。
/// 端末の中だけで動く。結果は行の「背景の音」として残し、放送やテレビの行を見分ける手がかりにする。
enum SoundScene {
    struct Window: Sendable {
        let start: Double
        let end: Double
        let label: String
    }

    /// 聞き分けの名前を、行に残す短い名前にする。手がかりにならない音は nil。
    private static func label(for identifier: String) -> String? {
        let id = identifier.lowercased()
        if id.contains("train") || id.contains("rail") || id.contains("subway") { return "電車" }
        if id.contains("television") || id.contains("radio") { return "テレビ" }
        if id == "music" || id.contains("singing") || id.contains("musical") || id.contains("jingle") { return "音楽" }
        if id.contains("applause") || id.contains("laughter") || id.contains("cheering") { return "拍手・笑い" }
        return nil
    }

    /// 録音のどこで、どの背景の音がしていたか（約1秒ごと、半分ずつ重ねて）。調べられなければ空。
    static func windows(in url: URL) -> [Window] {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        request.overlapFactor = 0.5
        let observer = Observer()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return [] }
        analyzer.analyze()
        return observer.windows
    }

    /// start〜end 秒の行のあいだ、いちばん長く聞こえていた背景の音（行の3割以上で聞こえていたもの）。
    static func label(from start: Double, to end: Double, in windows: [Window]) -> String? {
        let length = max(end - start, 0.5)
        var cover: [String: Double] = [:]
        for w in windows where w.end > start && w.start < end {
            cover[w.label, default: 0] += min(w.end, end) - max(w.start, start)
        }
        // 窓は半分ずつ重なっているので、ずっと聞こえていれば長さの2倍ほどになる
        guard let best = cover.max(by: { $0.value < $1.value }), best.value >= length * 0.6 else { return nil }
        return best.key
    }

    private final class Observer: NSObject, SNResultsObserving {
        var windows: [Window] = []

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let start = result.timeRange.start.seconds
            let end = start + result.timeRange.duration.seconds
            for c in result.classifications.prefix(5) where c.confidence >= 0.4 {
                if let label = SoundScene.label(for: c.identifier) {
                    windows.append(Window(start: start, end: end, label: label))
                    break
                }
            }
        }
    }
}

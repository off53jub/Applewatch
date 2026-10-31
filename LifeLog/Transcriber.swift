import AVFoundation
import Speech

/// iOS 26 の SpeechAnalyzer で、端末内だけで日本語を文字起こしする。
enum Transcriber {
    struct Line {
        let offset: TimeInterval   // チャンク先頭からの秒数
        var end: TimeInterval = 0  // 言い終わり（チャンク先頭からの秒数）
        let text: String
    }

    static let locale = Locale(identifier: "ja-JP")

    /// 日本語モデルが端末に無ければダウンロードする。
    static func prepare() async throws {
        let transcriber = makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// words は聞き取ってほしい言葉（ヒントとして渡す）
    static func transcribe(_ url: URL, words: [String] = []) async throws -> [Line] {
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !words.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(words.prefix(100))
            try? await analyzer.setContext(context)
        }
        let collector = Task {
            var lines: [Line] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append(Line(offset: result.range.start.seconds, end: result.range.end.seconds, text: text))
            }
            return lines
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    private static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [],
                          attributeOptions: [.audioTimeRange])
    }
}

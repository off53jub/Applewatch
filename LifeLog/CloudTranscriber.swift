import Foundation

/// クラウドの高精度モデルで文字起こしする。
/// - Groq: Whisper large-v3。無料枠は1日 28,800 秒（8時間）まで。区間ごとの時刻も返る。
/// - OpenAI: gpt-transcribe。従量課金で、文ごとの時刻は返らない。
enum CloudTranscriber {
    enum Provider: String, CaseIterable, Identifiable {
        case groq, openai
        var id: String { rawValue }

        var name: String {
            switch self {
            case .groq: "Groq（無料・1日8時間まで）"
            case .openai: "OpenAI（有料・最新モデル）"
            }
        }
        var keyHint: String {
            switch self {
            case .groq: "gsk_…"
            case .openai: "sk-…"
            }
        }
        var consoleURL: URL {
            switch self {
            case .groq: URL(string: "https://console.groq.com/keys")!
            case .openai: URL(string: "https://platform.openai.com/api-keys")!
            }
        }
        /// 1分あたりの料金（ドル）。無料枠で使う Groq は 0。2026-10 時点の公式料金。
        var dollarsPerMinute: Double {
            switch self {
            case .groq: 0
            case .openai: 0.0045
            }
        }
        fileprivate var endpoint: URL {
            switch self {
            case .groq: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
            case .openai: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
            }
        }
    }

    /// offset が nil の行は時刻が分からない（直前の行の続き）。
    struct Line {
        let offset: TimeInterval?
        let text: String
    }

    enum Failure: LocalizedError {
        /// キーが違う・残高が無いなど、待っても直らないもの
        case rejected(String)
        /// 無料枠などの上限に達した。この区切りは端末内の結果を使う
        case limited(String)
        /// 通信や混雑など、あとでやり直せば通るもの
        case temporary(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let s), .limited(let s), .temporary(let s): s
            }
        }
    }

    static let prompt = "日本語の日常会話や仕事の打ち合わせを録音したものです。句読点を付けて書き起こしてください。"

    static func transcribe(_ url: URL, provider: Provider, apiKey: String, keywords: [String]) async throws -> [Line] {
        let boundary = "LifeLog-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        switch provider {
        case .groq:
            field("model", "whisper-large-v3")
            field("language", "ja")
            field("response_format", "verbose_json")
            field("temperature", "0")
            // Whisper のプロンプトは「直前の書き起こし」として読まれるので、指示ではなく
            // 句読点つきの文と、出てくる言葉を並べて表記を寄せる（224 トークンまで）
            let words = keywords.prefix(30).joined(separator: "、")
            field("prompt", "こんにちは。今日もよろしくお願いします。" + (words.isEmpty ? "" : words + "。"))
        case .openai:
            field("model", "gpt-transcribe")
            field("languages[]", "ja")
            field("prompt", prompt)
            for word in keywords {
                field("keywords[]", word)
            }
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: audio/m4a\r\n\r\n")
        body.append(try Data(contentsOf: url))
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw Failure.temporary("\(provider.rawValue) に接続できませんでした")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let text = json?["text"] as? String else {
            let error = json?["error"] as? [String: Any]
            let detail = (error?["message"] as? String) ?? "HTTP \(status)"
            switch (status, error?["code"] as? String) {
            case (401, _):
                throw Failure.rejected("API キーが使えません: \(detail)")
            case (429, "insufficient_quota"):
                throw Failure.rejected("残高が足りません: \(detail)")
            case (429, _):
                throw Failure.limited("無料枠などの上限に達しました")
            case (400, _), (403, _), (404, _), (413, _):
                throw Failure.rejected("断られました: \(detail)")
            default:
                throw Failure.temporary("応答がありませんでした: \(detail)")
            }
        }

        if let segments = json?["segments"] as? [[String: Any]] {
            return segments.compactMap { segment in
                guard let text = (segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, !isHallucination(segment, text: text) else { return nil }
                return Line(offset: segment["start"] as? Double, text: text)
            }
        }
        // 時刻が無いときは文ごとに区切り、チャンクの先頭の時刻だけを付ける
        return sentences(in: text).enumerated().map { i, s in Line(offset: i == 0 ? 0 : nil, text: s) }
    }

    /// Whisper は無音や雑音に、動画の締めの決まり文句などを書いてしまうことがある。
    private static func isHallucination(_ segment: [String: Any], text: String) -> Bool {
        if let noSpeech = segment["no_speech_prob"] as? Double, noSpeech > 0.6,
           let logprob = segment["avg_logprob"] as? Double, logprob < -1 {
            return true
        }
        let phrases = ["ご視聴ありがとうございました", "チャンネル登録", "最後までご視聴", "字幕視聴ありがとう"]
        return phrases.contains { text.contains($0) } && text.count < 30
    }

    /// 「。」「？」「！」で区切って1文ずつにする。
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。？！?!".contains(ch) {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}

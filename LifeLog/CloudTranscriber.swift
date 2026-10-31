import Foundation

/// クラウドの高精度モデルで文字起こしする。
/// - Groq: Whisper large-v3。無料枠は1日 28,800 秒（8時間）まで。区間ごとの時刻も返る。
///   使い切ったら、枠が別にある次点の large-v3-turbo に切り替える（こちらも8時間）。
/// - OpenAI: gpt-transcribe。従量課金で、文ごとの時刻は返らない。
enum CloudTranscriber {
    enum Provider: String, CaseIterable, Identifiable {
        case groq, openai
        var id: String { rawValue }

        var name: String {
            switch self {
            case .groq: "Groq（無料・1日16時間まで）"
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
        /// 精度の高い順。上のモデルが上限に達したら次を使う。
        fileprivate var models: [String] {
            switch self {
            case .groq: ["whisper-large-v3", "whisper-large-v3-turbo"]
            case .openai: ["gpt-transcribe"]
            }
        }
        fileprivate var endpoint: URL {
            switch self {
            case .groq: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
            case .openai: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
            }
        }
    }

    struct Transcript {
        let model: String
        let lines: [Line]
    }

    /// offset が nil の行は時刻が分からない（直前の行の続き）。
    /// score は聞き取りの確からしさ（Whisper の avg_logprob。0 に近いほど確か）。
    struct Line {
        let offset: TimeInterval?
        let text: String
        var score: Double? = nil
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

    /// モデルごとの「この時刻までは上限で使えない」。
    @MainActor private static var limitedUntil: [String: Date] = [:]

    private struct RateLimited: Error {
        let retryAfter: TimeInterval
    }

    /// 精度の高いモデルから順に試し、上限に達したモデルはしばらく飛ばす。
    @MainActor
    static func transcribe(_ url: URL, provider: Provider, apiKey: String, keywords: [String],
                           previous: String? = nil) async throws -> Transcript {
        for model in provider.models where (limitedUntil[model] ?? .distantPast) < .now {
            do {
                let lines = try await send(url, provider: provider, model: model, apiKey: apiKey,
                                           keywords: keywords, previous: previous)
                return Transcript(model: model, lines: lines)
            } catch let limit as RateLimited {
                limitedUntil[model] = .now.addingTimeInterval(limit.retryAfter)
            }
        }
        throw Failure.limited("無料枠の上限に達しました")
    }

    /// previous は直前の区切りの終わりの文。区切りの頭が話の途中から始まっても、つながりが分かる。
    private static func send(_ url: URL, provider: Provider, model: String, apiKey: String,
                             keywords: [String], previous: String?) async throws -> [Line] {
        let boundary = "LifeLog-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        switch provider {
        case .groq:
            field("model", model)
            field("language", "ja")
            field("response_format", "verbose_json")
            field("temperature", "0")
            // Whisper のプロンプトは「直前の書き起こし」として読まれるので、指示ではなく
            // 句読点つきの文と、出てくる言葉を並べて表記を寄せる（224 トークンまで）。
            // 直前の区切りの終わりがあれば、いちばん後ろ（すぐ前の発言の位置）に置く。
            let words = keywords.prefix(30).joined(separator: "、")
            var text = String((words.isEmpty ? "" : words + "。").prefix(100))
            text += previous.map { String($0.suffix(100)) } ?? "こんにちは。今日もよろしくお願いします。"
            field("prompt", text)
        case .openai:
            field("model", model)
            field("languages[]", "ja")
            field("prompt", prompt + (previous.map { "直前の会話：" + $0.suffix(200) } ?? ""))
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
                // retry-after が無ければ1時間待つ（1時間あたりの枠もあるため）
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
                throw RateLimited(retryAfter: header.flatMap(TimeInterval.init) ?? 3600)
            case (400, _), (403, _), (404, _), (413, _):
                throw Failure.rejected("断られました: \(detail)")
            default:
                throw Failure.temporary("応答がありませんでした: \(detail)")
            }
        }

        if let segments = json?["segments"] as? [[String: Any]] {
            let lines = segments.compactMap { segment -> Line? in
                guard let text = (segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, !isHallucination(segment, text: text) else { return nil }
                return Line(offset: segment["start"] as? Double, text: text, score: segment["avg_logprob"] as? Double)
            }
            return dropRepeats(lines)
        }
        // 時刻が無いときは文ごとに区切り、チャンクの先頭の時刻だけを付ける
        let lines = sentences(in: text).filter { !isFiller($0) }
        return dropRepeats(lines.enumerated().map { i, s in Line(offset: i == 0 ? 0 : nil, text: s) })
    }

    /// Whisper は無音や雑音（ゲームや BGM など）に、動画の締めの決まり文句などを書いてしまうことがある。
    private static func isHallucination(_ segment: [String: Any], text: String) -> Bool {
        let noSpeech = segment["no_speech_prob"] as? Double ?? 0
        let logprob = segment["avg_logprob"] as? Double ?? 0
        let compression = segment["compression_ratio"] as? Double ?? 0
        if noSpeech > 0.6 && logprob < -1 { return true }
        if noSpeech > 0.4 && logprob < -0.6 { return true }
        // 同じ言葉の繰り返しばかりの区間
        if compression > 2.4 { return true }
        return isFiller(text)
    }

    /// 声が無いところに Whisper が書きがちな決まり文句か。短い文で、これらを含むものは捨てる。
    static func isFiller(_ text: String) -> Bool {
        let phrases = ["ご清聴ありがとう", "ご視聴ありがとう", "チャンネル登録", "高評価", "最後までご視聴", "最後までご覧",
                       "字幕視聴", "字幕は", "おやすみなさい。また", "次回もお楽しみに", "提供は"]
        return text.count < 40 && phrases.contains { text.contains($0) }
    }

    /// 1つの区切りで同じ文（8文字以上）が3回以上出てきたら、雑音への書き込みとみなして捨てる。
    private static func dropRepeats(_ lines: [Line]) -> [Line] {
        var counts: [String: Int] = [:]
        for line in lines where line.text.count >= 8 { counts[line.text, default: 0] += 1 }
        return lines.filter { (counts[$0.text] ?? 0) < 3 }
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

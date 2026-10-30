import Foundation

/// Groq の無料枠の言語モデルで、会話の見出し・要約と1日のまとめを作る。
/// 無料枠は1分 8,000 トークン・1日 200,000 トークン（モデルごと）なので、
/// 長い会話は小さいモデルで区切りごとにメモにしてから、大きいモデルでまとめる。
enum Summarizer {
    struct Conversation {
        let title: String
        let points: [String]
    }

    struct Day {
        let decisions: [String]
        let todos: [String]
        let topics: [String]
    }

    private static let mainModel = "openai/gpt-oss-120b"
    private static let noteModel = "openai/gpt-oss-20b"
    /// 1回に渡す文字数の上限（1分あたりのトークン上限に収まるように）
    private static let pieceLength = 4_000

    static func conversation(_ transcript: String, timeRange: String, apiKey: String) async throws -> Conversation {
        var material = transcript
        if transcript.count > pieceLength {
            // 長い会話は、区切りごとに要点メモにしてからまとめる
            var notes: [String] = []
            for piece in pieces(of: transcript) {
                let json = try await chat(model: noteModel, apiKey: apiKey, prompt: """
                    次は会話の文字起こしの一部です（[自分] は記録している本人）。
                    要点を5つ以内の短い箇条書きにして、JSON {"notes": ["...", ...]} で返してください。

                    \(piece)
                    """)
                notes += (json["notes"] as? [String]) ?? []
            }
            material = "（長い会話のため、区切りごとの要点メモ）\n" + notes.map { "・" + $0 }.joined(separator: "\n")
        }
        let json = try await chat(model: mainModel, apiKey: apiKey, prompt: """
            次は \(timeRange) の会話の文字起こしです。[自分] は記録している本人、[人物N] や名前は話し相手です。
            文字起こしの誤変換は文脈から補ってかまいません。次の JSON で返してください。
            {"title": "何の話かが一目で分かる20文字以内の見出し", "points": ["要点（決まったこと・約束・大事な情報を優先）", ...最大3つ]}

            \(material)
            """)
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let points = (json["points"] as? [String]) ?? []
        return Conversation(title: title, points: Array(points.prefix(3)))
    }

    static func day(_ conversations: String, apiKey: String) async throws -> Day {
        let json = try await chat(model: mainModel, apiKey: apiKey, prompt: """
            次は、ある人の1日の会話の見出しと要点の一覧です。1日のまとめを次の JSON で返してください。
            なければ空の配列にしてください。
            {"decisions": ["決まったこと"], "todos": ["本人がやること・約束（期限があれば添える）"], "topics": ["話題や気になったこと"]}

            \(conversations)
            """)
        func list(_ key: String) -> [String] { (json[key] as? [String]) ?? [] }
        return Day(decisions: list("decisions"), todos: list("todos"), topics: list("topics"))
    }

    private static func pieces(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > pieceLength, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// JSON で答えさせる。混んでいる（429）ときは指示どおり待って3回まで試す。
    private static func chat(model: String, apiKey: String, prompt: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": "あなたは日本語の会話ログを整理するアシスタントです。必ず日本語で、指定された JSON だけを返します。"],
                ["role": "user", "content": prompt],
            ],
            "response_format": ["type": "json_object"],
            "reasoning_effort": "low",
            "temperature": 0.3,
        ] as [String: Any])

        for attempt in 1...3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 429, attempt < 3 {
                let wait = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 20
                try await Task.sleep(for: .seconds(min(wait, 90)))
                continue
            }
            guard http?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
                  let result = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any]
            else {
                throw CloudTranscriber.Failure.temporary("要約を作れませんでした（HTTP \(http?.statusCode ?? 0)）")
            }
            return result
        }
        throw CloudTranscriber.Failure.limited("要約の無料枠の上限に達しました")
    }
}

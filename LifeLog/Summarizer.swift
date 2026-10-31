import Foundation

/// Groq の無料枠の言語モデルで、会話の見出し・要約と1日のまとめを作る。
/// 無料枠は1分 8,000 トークン・1日 200,000 トークン（モデルごと）なので、
/// 長い会話は小さいモデルで区切りごとにメモにしてから、大きいモデルでまとめる。
enum Summarizer {
    struct Conversation {
        let title: String
        let points: [String]
    }

    struct Day: Codable {
        /// 「9:00〜11:30　会社　企画会議（田中さん）」のような、時間の塊ごとの流れ
        let flow: [String]
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
            次は、ある人の1日の会話の見出しと要点の一覧です（時刻・場所・相手・見出し）。1日のまとめを次の JSON で返してください。
            なければ空の配列にしてください。
            "flow" は1日の流れです。時間の近い会話や、同じ場所・同じ用事の会話をひとまとめにし、
            「9:00〜11:30　会社　企画会議と提案資料づくり（田中さん、佐藤さん）」の形で、時刻順に2〜8個にしてください。
            {"flow": ["..."], "decisions": ["決まったこと"], "todos": ["本人がやること・約束（期限があれば添える）"], "topics": ["話題や気になったこと"]}

            \(conversations)
            """)
        func list(_ key: String) -> [String] { (json[key] as? [String]) ?? [] }
        return Day(flow: list("flow"), decisions: list("decisions"), todos: list("todos"), topics: list("topics"))
    }

    struct Week {
        let flow: [String]
        let people: [String]
        let decisions: [String]
        let todos: [String]
        let topics: [String]
    }

    static func week(_ days: String, apiKey: String) async throws -> Week {
        let json = try await chat(model: mainModel, apiKey: apiKey, prompt: """
            次は、ある人の1週間の記録です（日ごとの流れ・決まったこと・やること・会話の見出し）。1週間のまとめを次の JSON で返してください。
            なければ空の配列にしてください。
            {"flow": ["10/27(月)　会社で企画会議、夜は友人と食事", ...日ごとに1行],
             "people": ["田中さん：提案資料の相談（月・水）", ...よく話した人と何の話か],
             "decisions": ["決まったこと"],
             "todos": ["本人がやること・約束で、まだ残っていそうなもの（期限があれば添える）"],
             "topics": ["今週の主な話題や気になったこと"]}

            \(days)
            """)
        func list(_ key: String) -> [String] { (json[key] as? [String]) ?? [] }
        return Week(flow: list("flow"), people: list("people"), decisions: list("decisions"),
                    todos: list("todos"), topics: list("topics"))
    }

    /// 質問から、記録を探す手がかりを取り出す。
    struct Plan {
        let keywords: [String]
        let people: [String]
        let from: String?
        let to: String?
    }

    static func plan(_ question: String, today: String, people: [String], apiKey: String) async throws -> Plan {
        let json = try await chat(model: noteModel, apiKey: apiKey, maxWait: 30, prompt: """
            今日は \(today) です。次の質問に答えるために、会話の記録を探します。
            記録に出てくる人: \(people.isEmpty ? "（未登録）" : people.joined(separator: "、"))
            探す手がかりを次の JSON で返してください。日付は yyyy-MM-dd。期間が分からなければ null。
            keywords は記録の中に出てきそうな言葉（言い換えや表記ゆれも含めて最大8個）。
            {"keywords": ["..."], "people": ["上の人の中で関係する人"], "from": "yyyy-MM-dd または null", "to": "yyyy-MM-dd または null"}

            質問: \(question)
            """)
        return Plan(keywords: (json["keywords"] as? [String]) ?? [],
                    people: (json["people"] as? [String]) ?? [],
                    from: json["from"] as? String, to: json["to"] as? String)
    }

    /// 探した記録をもとに質問に答える。sources は根拠にした行の「yyyy-MM-dd HH:mm」。
    static func answer(_ question: String, material: String, apiKey: String) async throws -> (text: String, sources: [String]) {
        let prompt = """
            次は、ある人（[自分]）の会話の記録の抜き出しです。これだけをもとに質問に答えてください。
            記録に無いことは推測せず「記録に見つかりませんでした」と答えてください。文字起こしの誤変換は文脈から補ってかまいません。
            次の JSON で返してください。
            {"answer": "質問への答え（簡潔に。いつ・誰と・何を、が分かるように）", "sources": ["根拠にした記録の日時 yyyy-MM-dd HH:mm", ...最大5つ]}

            質問: \(question)

            \(material)
            """
        let json: [String: Any]
        do {
            json = try await chat(model: mainModel, apiKey: apiKey, maxWait: 30, prompt: prompt)
        } catch CloudTranscriber.Failure.limited {
            // 大きいモデルの枠が無ければ小さいモデルで答える
            json = try await chat(model: noteModel, apiKey: apiKey, maxWait: 30, prompt: prompt)
        }
        return ((json["answer"] as? String) ?? "", (json["sources"] as? [String]) ?? [])
    }

    /// 文字起こしの誤変換を、前後の文脈とキーワードから直す。行の数が変わったら使わない（nil）。
    /// 処理の流れを止めないよう、混んでいるときは待たずにあきらめる。
    static func correct(_ lines: [String], keywords: [String], previous: String?, apiKey: String) async throws -> [String]? {
        guard !lines.isEmpty else { return lines }
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["lines": lines]), as: UTF8.self)
        let json = try await chat(model: noteModel, apiKey: apiKey, maxWait: 20, prompt: """
            次の JSON の "lines" は、日本語の会話を音声認識で書き起こした文の配列です（\(lines.count) 個）。
            同音異義語の誤変換（例: 機会→機械）、固有名詞の書き間違い、明らかな聞き間違いだけを、前後の文脈から直してください。
            言い回しや話し言葉はそのまま残し、要約・言い換え・行の結合や分割はしないでください。
            直すところが無い文や、分からない文は、元の文をそのまま入れてください。
            \(keywords.isEmpty ? "" : "よく出る言葉（この表記に寄せる）: " + keywords.joined(separator: "、") + "\n")\
            \(previous.map { "直前の会話（直さない）: " + $0 + "\n" } ?? "")\
            同じ形の JSON（"lines" に \(lines.count) 個の文）で返してください。

            \(input)
            """)
        guard let fixed = json["lines"] as? [String], fixed.count == lines.count else { return nil }
        // 直しすぎ（言い換え・要約・見本の文を返すなど）の行は使わない
        return zip(lines, fixed).map { original, fixed in
            isSmallFix(original, fixed) ? fixed : original
        }
    }

    /// 誤変換の直しとみなせるくらい、元の文に近いか（文字の違いが3割以下）
    static func isSmallFix(_ original: String, _ fixed: String) -> Bool {
        let a = Array(original), b = Array(fixed)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // 編集距離（1文字の挿入・削除・置き換えを1と数える）
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count] <= max(2, a.count * 3 / 10)
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
    private static func chat(model: String, apiKey: String, maxWait: Double = 90, prompt: String) async throws -> [String: Any] {
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
                if wait > maxWait { break }
                try await Task.sleep(for: .seconds(wait))
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

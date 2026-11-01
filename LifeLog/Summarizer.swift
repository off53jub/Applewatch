import Foundation

/// Groq の無料枠の言語モデルで、会話の見出し・要約と1日のまとめを作る。
/// 無料枠は1分 8,000 トークン・1日 200,000 トークン（モデルごと）なので、
/// 長い会話は小さいモデルで区切りごとにメモにしてから、大きいモデルでまとめる。
enum Summarizer {
    struct Conversation {
        let title: String
        let points: [String]
        /// テレビ・動画・ラジオなどを聞いていたなら、その種類（会話なら nil）
        let media: String?
        /// 番組名・動画の題名（分かれば）
        let program: String?
    }

    /// 会話でないと分かったときの種類
    static let mediaKinds = ["テレビ", "動画", "ラジオ・音楽"]

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

    /// selfShare は [自分] の発言の割合（0〜1）。テレビや動画を見ているときは低くなる。
    static func conversation(_ transcript: String, timeRange: String, selfShare: Double,
                             event: String? = nil, apiKey: String) async throws -> Conversation {
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
            次は \(timeRange) の録音の文字起こしです。[自分] は記録している本人、[人物N] や名前は話し相手です。
            [自分] の発言は全体の \(Int(selfShare * 100))% です。
            \(event.map { "この時間のカレンダーの予定: \($0)（会話の中身と合うときだけ見出しの参考にしてください）\n" } ?? "")\
            文字起こしの誤変換は文脈から補ってかまいません。

            まず、これが本人のまわりの実際の会話か、本人がテレビ番組・YouTube などの動画・ラジオや音楽を流していた音かを見分けてください。
            ナレーション、司会や出演者の掛け合い、CM、「チャンネル登録」「ご視聴ありがとう」、本人がほとんど話さない、などは番組や動画の手がかりです。
            番組や動画を見ながら本人が家族と話しているなど、実際の会話が中心なら「会話」にしてください。

            次の JSON で返してください。
            {"kind": "会話・テレビ・動画・ラジオ・音楽 のどれか",
             "program": "テレビ・動画なら番組名や動画の題名・チャンネル名（分からなければ空）",
             "title": "何の話かが一目で分かる20文字以内の見出し（テレビ・動画なら内容）",
             "points": ["要点（決まったこと・約束・大事な情報を優先）", ...最大3つ]}

            \(material)
            """)
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let points = (json["points"] as? [String]) ?? []
        let kind = (json["kind"] as? String) ?? "会話"
        let media: String? = kind.contains("テレビ") ? "テレビ"
            : kind.contains("動画") || kind.lowercased().contains("youtube") ? "動画"
            : kind.contains("ラジオ") || kind.contains("音楽") ? "ラジオ・音楽" : nil
        let program = (json["program"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Conversation(title: title, points: Array(points.prefix(3)), media: media,
                            program: program?.isEmpty == false ? program : nil)
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

    /// 1日の会話の一覧を「何をしていたか」の長い塊に区切る。count は一覧の数。
    /// 返すのは塊ごとの（最初の番号, 最後の番号, 見出し）で、0〜count-1 の番号を隙間なく分けたもの。
    static func activityBlocks(_ list: String, count: Int, events: String, previous: String?,
                               apiKey: String) async throws -> [(from: Int, to: Int, title: String)] {
        let prompt = """
            次は、ある人（本人）の1日の録音を、会話ごとに時刻順に並べた一覧です（番号. 時刻｜場所｜相手｜〔カレンダーの予定〕｜見出し）。
            この人が「何をしていたか」で、1日をいくつかの長い時間の塊に分けてください。
            ・塊は一覧の番号の連続した範囲です。0 番から \(count - 1) 番まで、すべての番号をちょうど1つの塊に入れ、時刻順に並べてください。
            ・同じ用事・同じ場所での活動（たとえばダンスの練習、会社での仕事、家族との夕食、買い物）は、途中に短い休憩・電話・雑談・移動が挟まっても1つの塊にしてください。
              細かく分けすぎないでください（1つの塊は何時間でもかまいません。目安は1日に3〜10個）。
            ・カレンダーの予定と時間が重なるところは、予定名を参考にしてください（会話の中身と合わないときは使わないでください）。
            ・"title" は、何をしていたかが一目で分かる15文字以内の名前にしてください。
            \(events.isEmpty ? "" : "\nこの日のカレンダーの予定:\n\(events)\n")\
            \(previous.map { "\n前にまとめたときの塊（会話が増えたので見直しています。変える理由が無ければ、区切りと名前はなるべくそのままに）:\n\($0)\n" } ?? "")
            次の JSON で返してください。from と to は番号（整数）です。
            {"blocks": [{"from": 整数, "to": 整数, "title": "塊の名前"}, ...]}

            \(list)
            """
        let json: [String: Any]
        do {
            json = try await chat(model: mainModel, apiKey: apiKey, maxWait: 60, prompt: prompt)
        } catch CloudTranscriber.Failure.limited {
            // 大きいモデルの枠が無ければ小さいモデルで
            json = try await chat(model: noteModel, apiKey: apiKey, maxWait: 60, prompt: prompt)
        }
        func number(_ value: Any?) -> Int? {
            (value as? Int) ?? (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) }
        }
        var starts: [(from: Int, title: String)] = []
        for block in (json["blocks"] as? [[String: Any]]) ?? [] {
            guard let from = number(block["from"]), (0..<count).contains(from),
                  !starts.contains(where: { $0.from == from }) else { continue }
            let title = ((block["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            starts.append((from, String(title.prefix(24))))
        }
        guard !starts.isEmpty else { throw CloudTranscriber.Failure.temporary("過ごし方を区切れませんでした") }
        starts.sort { $0.from < $1.from }
        starts[0].from = 0
        return starts.indices.map { i in
            (starts[i].from, i + 1 < starts.count ? starts[i + 1].from - 1 : count - 1, starts[i].title)
        }
    }

    /// 会話の中で、同じ名前や言葉が行によって違う字で書かれているところを見つけ、そろえる書き方を返す。
    /// 返すのは（直す前の書き方, そろえた書き方）の組。読みが合うかは呼ぶ側で確かめる。
    static func unify(_ text: String, title: String?, hints: [String], apiKey: String) async throws -> [(wrong: String, right: String)] {
        let prompt = """
            次は、ある会話の文字起こしです\(title.map { "（話題: \($0)）" } ?? "")。音声認識なので、同じ人の名前や同じ言葉が、行によって違う字で書かれていることがあります。
            会話の中で同じものを指しているのに書き方がばらばらな、人の名前・固有名詞・専門用語を見つけ、どの書き方にそろえるかを決めてください。
            ・そろえる先は、会話の中にある書き方か、下の「正しい書き方の候補」にあるものだけにしてください。
            ・読み（音）が同じか、ほとんど同じものだけにしてください。意味の違う言葉への置き換えや、言い回しの直しはしないでください。
            ・そろえるものが無ければ空の配列にしてください。最大10組です。
            \(hints.isEmpty ? "" : "正しい書き方の候補: " + hints.prefix(40).joined(separator: "、") + "\n")\
            次の JSON で返してください。
            {"pairs": [{"wrong": "直す前の書き方", "right": "そろえた書き方"}, ...]}

            \(text)
            """
        let json: [String: Any]
        do {
            json = try await chat(model: mainModel, apiKey: apiKey, maxWait: 60, prompt: prompt)
        } catch CloudTranscriber.Failure.limited {
            json = try await chat(model: noteModel, apiKey: apiKey, maxWait: 60, prompt: prompt)
        }
        let pairs = ((json["pairs"] as? [[String: Any]]) ?? []).compactMap { pair -> (wrong: String, right: String)? in
            guard let wrong = (pair["wrong"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let right = (pair["right"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  wrong.count >= 2, !right.isEmpty, wrong != right, right.count <= 16 else { return nil }
            return (wrong, right)
        }
        return Array(pairs.prefix(10))
    }

    /// 会話ではない声の種類（行の話した人の名前にもなる）
    static let broadcastKinds = ["テレビ", "CM", "ドラマ・映画", "動画", "ラジオ・音楽", "放送"]

    /// 会話の行のうち、本人のまわりの実際の会話ではなく、テレビ・CM・ドラマ・動画・ラジオ・放送の声だった行を見つける。
    /// 選べるのは judge の行だけ。返すのは 行番号 → 種類（broadcastKinds のどれか）。
    static func broadcast(_ lines: [String], judge: Set<Int>, setting: String?, apiKey: String) async throws -> [Int: String] {
        guard !judge.isEmpty else { return [:] }
        let numbered = lines.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let prompt = """
            次は、本人が1日中身に着けているマイクで録った音声の文字起こしです。行の頭の数字は行番号、[自分] は本人、\
            [人物N] は声で聞き分けた名前の無い人です。（背景: 音楽）などは、その行のあいだ聞こえていた音です。
            \(setting.map { "このときの様子: \($0)（家・友達の家・お店の中ならテレビや YouTube を流していることが多く、電車・駅・お店なら放送が多いです）\n" } ?? "")\
            この中から、本人のまわりの実際の会話ではない声の行を見つけてください。
            ・テレビ番組（ニュース・バラエティなど）、CM、ドラマ・映画・アニメのセリフ、YouTube などの動画、ラジオや音楽、\
            電車・駅・お店・施設の放送（「次は〇〇です」「ドアが閉まります」「本日はご来店」など）。
            ・手がかり: 前後の会話とつながらない、台本やナレーションのような言い回し、商品名・値段・「今なら」、決まり文句の放送、背景の音楽や拍手・笑い。
            ・YouTube などの動画の手がかり: 「どうも〇〇です」のような始まりのあいさつ、「チャンネル登録」「高評価」「概要欄」「コメント欄」、ひとりで長く話し続ける実況や解説、効果音のような言い回し。
            ・本人と言葉を交わしている人の行は選ばないでください。迷ったら選ばないでください。
            ・選べるのは次の行番号だけです: \(judge.sorted().map(String.init).joined(separator: ", "))
            種類は \(broadcastKinds.map { "「\($0)」" }.joined(separator: "")) のどれかです（駅・車内・お店などのアナウンスは「放送」）。
            次の JSON で返してください。無ければ空の配列にしてください。
            {"lines": [{"n": 行番号, "kind": "種類"}]}

            \(numbered)
            """
        let json: [String: Any]
        do {
            json = try await chat(model: mainModel, apiKey: apiKey, maxWait: 60, prompt: prompt)
        } catch CloudTranscriber.Failure.limited {
            json = try await chat(model: noteModel, apiKey: apiKey, maxWait: 60, prompt: prompt)
        }
        var result: [Int: String] = [:]
        for item in (json["lines"] as? [[String: Any]]) ?? [] {
            guard let n = (item["n"] as? Int) ?? (item["n"] as? Double).map({ Int($0) }) ?? (item["n"] as? String).flatMap({ Int($0) }),
                  judge.contains(n) else { continue }
            let kind = (item["kind"] as? String) ?? ""
            result[n] = broadcastKinds.first { kind.contains($0) } ?? "テレビ"
        }
        return result
    }

    /// 過ごし方の塊ごとに、その中でしたことを短い箇条書きにする。塊の数が合わなければ失敗。
    static func activityDetails(_ blocks: [(header: String, body: String)], apiKey: String) async throws -> [[String]] {
        guard !blocks.isEmpty else { return [] }
        let budget = max(300, 6_000 / blocks.count)
        let material = blocks.map { $0.header + "\n" + String($0.body.prefix(budget)) }.joined(separator: "\n\n")
        let prompt = """
            次は、ある人（本人）の1日を「何をしていたか」の塊に分けたものと、塊ごとの会話の見出し・要点です。
            塊ごとに、その中で本人がしたこと・起きたこと・決まったことを、短い箇条書き（1つ30文字以内、1〜4個）にしてください。
            会話の細かい中身より、その時間に何をしていたかが分かるようにまとめてください。材料に無いことは書かないでください。
            塊の数（\(blocks.count) 個）と順番はそのままにして、次の JSON で返してください。
            {"blocks": [{"did": ["したこと", ...]}, ...]}

            \(material)
            """
        let json: [String: Any]
        do {
            json = try await chat(model: mainModel, apiKey: apiKey, maxWait: 60, prompt: prompt)
        } catch CloudTranscriber.Failure.limited {
            json = try await chat(model: noteModel, apiKey: apiKey, maxWait: 60, prompt: prompt)
        }
        guard let raw = json["blocks"] as? [[String: Any]], raw.count == blocks.count else {
            throw CloudTranscriber.Failure.temporary("したことをまとめられませんでした")
        }
        return raw.map { block in
            let items = (block["did"] as? [String]) ?? []
            return Array(items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(4))
        }
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
    /// alternatives は、同じ時間に別の音声認識が聞き取った文（行ごと。無ければ空）。
    /// 2つが食い違う行は、言語モデルに見比べてもらい、実際に話された文として自然なほうを選んでもらう。
    static func correct(_ lines: [String], keywords: [String], previous: String?,
                        alternatives: [String]? = nil, apiKey: String) async throws -> [String]? {
        guard !lines.isEmpty else { return lines }
        let others = alternatives.flatMap { $0.count == lines.count && $0.contains { !$0.isEmpty } ? $0 : nil }
        var body: [String: Any] = ["lines": lines]
        if let others { body["others"] = others }
        let input = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let compare = others == nil ? "" : """
            "others" には、別の音声認識が同じ時間に聞き取った文が、"lines" と同じ順に入っています（空の文字列は「無し」）。
            "lines" の文と "others" の文が食い違うところは、見比べて、実際に話された文として自然なほうに寄せてください。
            両方の正しい部分を合わせてもかまいませんが、どちらにも無い言葉は足さないでください。"others" は返さないでください。

            """
        let json = try await chat(model: noteModel, apiKey: apiKey, maxWait: 20, prompt: """
            次の JSON の "lines" は、日本語の会話を音声認識で書き起こした文の配列です（\(lines.count) 個）。
            同音異義語の誤変換（例: 機会→機械）、固有名詞の書き間違い、明らかな聞き間違いだけを、前後の文脈から直してください。
            言い回しや話し言葉はそのまま残し、要約・言い換え・行の結合や分割はしないでください。
            直すところが無い文や、分からない文は、元の文をそのまま入れてください。
            \(compare)\(keywords.isEmpty ? "" : "よく出る言葉（この表記に寄せる）: " + keywords.joined(separator: "、") + "\n")\
            \(previous.map { "直前の会話（直さない）: " + $0 + "\n" } ?? "")\
            "lines" に \(lines.count) 個の文を入れた JSON で返してください。

            \(input)
            """)
        guard let fixed = json["lines"] as? [String], fixed.count == lines.count else { return nil }
        // 直しすぎ（言い換え・要約・見本の文を返すなど）の行は使わない。
        // もう1つの聞き取りに寄せた行は、そちらに近ければ使う。
        return lines.indices.map { i in
            let original = lines[i], result = fixed[i]
            if isSmallFix(original, result) { return result }
            if let other = others?[i], !other.isEmpty, isSmallFix(other, result) { return result }
            return original
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

import Foundation

/// Google ドライブの記録を読む AI（ChatGPT・Claude など）のための案内と索引。
/// LifeLog フォルダに「00 はじめに読んでください（AI 向けの説明）」と「01 日ごとの索引」を作り、中身が変わったら書き直す。
/// 日ごとのドキュメントには触らない（会話の見出しを差し込む位置がずれるため）。
/// アプリの中の記録（会話・人・言葉の登録）は読むだけで、変えない。
@MainActor
enum DriveGuide {
    static let guideName = "00 はじめに読んでください（AI 向けの説明）"
    static let indexName = "01 日ごとの索引"

    typealias Paragraphs = [(text: String, style: String?)]

    struct Person {
        let name: String
        /// 「職場」「職場以外」。どちらでもなら nil
        let context: String?
        /// その人と話すときによく出る言葉
        let words: [String]
    }

    struct Words {
        /// 「いつも」などの組と、その言葉
        var groups: [(label: String, words: [String])] = []
        /// 話題の名前と、その言葉
        var topics: [(name: String, words: [String])] = []
        /// よくある聞き間違い
        var fixes: [(wrong: String, right: String)] = []
    }

    struct DayEntry {
        let day: String
        /// 何時から何時まで何をしていたか
        let flow: [String]
        let people: [String]
        let places: [String]
        let decisions: [String]
        let todos: [String]
        let conversations: Int
        let marked: Int
    }

    // MARK: - 案内

    static func guide(people: [Person], words: Words, days: [String]) -> Paragraphs {
        var p: Paragraphs = []
        func h1(_ s: String) { p.append((s, "HEADING_1")) }
        func h2(_ s: String) { p.append((s, "HEADING_2")) }
        func text(_ s: String) { p.append((s, nil)) }
        func item(_ s: String) { p.append(("・" + s, nil)) }

        h1("LifeLog の読み方（AI 向けの説明）")
        text("このフォルダは、持ち主が1日中身に着けている iPhone と Apple Watch で録った音声を、自動で文字にした生活の記録です。"
             + "持ち主に記録について聞かれたら、この説明を前提に読んでください。このドキュメントはアプリが自動で書き直します。")
        if let first = days.first, let last = days.last {
            text("記録のある日: \(first)〜\(last)（\(days.count) 日分）")
        }

        h2("このフォルダにあるもの")
        item("「01 日ごとの索引」: 日ごとの過ごし方（何時から何時まで何をしていたか）・会った人・場所・決まったこと・やること。新しい日が上。まずここで日を探してから、その日のドキュメントを読むと速い。")
        item("「YYYY-MM-DD」（例: 2026-10-31）: その日の文字起こし。1日に1つ。")
        item("「人物ノート - 名前」: 名前を付けた人ごとの、その人と話した会話の見出しと要点（新しい順）。どの日のドキュメントにあるかも書いてある。")
        item("「週のまとめ YYYY-MM-DD〜YYYY-MM-DD」: 月曜から日曜までのまとめ。")
        item("「音声」フォルダ: 元の録音（日付ごとのフォルダ）。ファイル名は録り始めの時刻（YYYYMMDD-HHMMSS）で、後ろに -w があるものは時計で録った音声。")
        item("家では iPad も録音している。iPad の会話も同じ日のドキュメントに入っていて、索引やまとめにも含まれる。")
        item("「同期」フォルダ: iPhone と iPad のアプリが記録と登録を合わせるためのデータ（JSON）。読まなくてよい。")
        item("「01 日ごとの索引（iPad）」があれば、以前 iPad が書いていた古い索引。今は「01 日ごとの索引」に iPad の分も入っている。")

        h2("日ごとのドキュメントの形")
        item("いちばん上の「1日のまとめ」（次の日以降に付く）: 1日の流れ／★ 印を付けたところ／会った人／決まったこと／やること／話題。")
        item("そのあと、会話ごとの見出し: 「HH:MM〜HH:MM　場所（移動の様子）　〔カレンダーの予定〕　話した相手と　題名」。"
             + "場所・移動・予定・相手は分かるときだけ入る。「［テレビ］「番組名」」のような角かっこは、会話ではなく流していた番組や動画。")
        item("見出しのすぐ下の「・」の行: その会話の要点（自動の要約）。")
        item("その下が文字起こしの行: 「HH:MM:SS  [話した人] 話した内容」。時刻は日本時間の24時間表記。")
        item("3分以上話が途切れたら、別の会話として見出しが分かれる。")

        h2("行の読み方")
        item("[自分] は、この記録の持ち主。")
        item("[人物3] のような番号は、声で聞き分けたが名前の無い人。同じ番号は同じ声とみなしているが、聞き分けの誤りもある。")
        item("[名前] は、持ち主が声に名前を付けた人（下の「人」を参照）。")
        item("[テレビ] [CM] [ドラマ・映画] [動画] [ラジオ・音楽] [放送] は、会話ではなく、流れていた番組・CM・動画や、駅・車内・お店のアナウンスの声（会話の相手ではない）。自動の見分けなので、まれに間違える。")
        item("話した人の無い行は、聞き分けられなかった行。")
        item("「★ 」が付いた行は、持ち主が時計やアプリで印を付けたところ（前後1分）。持ち主が大事だと思った場面。")
        item("自動の文字起こしなので、聞き間違いや誤変換がある。人の名前や固有名詞は、下の「人」「よく出る言葉」の書き方が正しい。")
        item("音がしないあいだは書かないので、行の無い時間は、静かだったか録音していなかった時間。")
        item("職場では、持ち主と関係ない周りの人の声（持ち主と言葉を交わしていない、名前の無い声）を書かないようにしている。")
        item("あとで聞き直したり持ち主が手で直したりして、行の文字が変わることがある。")

        h2("質問に答えるときのコツ")
        item("「いつ・誰と・何をしたか」は、まず「01 日ごとの索引」で日を探し、その日のドキュメントの見出しで時間を探す。")
        item("人について聞かれたら「人物ノート - 名前」を見る。")
        item("答えには日付と時刻（HH:MM）を添える。持ち主がその行や音声を探せる。")
        item("意味の通らない行は聞き間違いのことが多い。前後の行から推し量ってよいが、推し量ったことは伝える。")

        let named = people.filter { !$0.name.isEmpty }
        if !named.isEmpty {
            h2("人（持ち主が名前を付けた人）")
            for person in named {
                var line = person.name
                if let context = person.context { line += "（\(context)で会う人）" }
                if !person.words.isEmpty { line += "　よく話す言葉: " + person.words.joined(separator: "、") }
                item(line)
            }
        }

        let groups = words.groups.filter { !$0.words.isEmpty }
        let topics = words.topics.filter { !$0.words.isEmpty }
        if !groups.isEmpty || !topics.isEmpty || !words.fixes.isEmpty {
            h2("よく出る言葉（正しい書き方）")
            for group in groups { item(group.label + ": " + group.words.joined(separator: "、")) }
            for topic in topics { item("話題「\(topic.name)」: " + topic.words.joined(separator: "、")) }
            if !words.fixes.isEmpty {
                item("よくある聞き間違い（左のように書かれていたら右の意味）: "
                     + words.fixes.prefix(60).map { "\($0.wrong) → \($0.right)" }.joined(separator: "、"))
            }
        }
        return p
    }

    // MARK: - 索引

    static func index(_ entries: [DayEntry]) -> Paragraphs {
        var p: Paragraphs = []
        p.append(("日ごとの索引（新しい日が上）", "HEADING_1"))
        p.append(("それぞれの日の「流れ」は、何時から何時まで何をしていたか。詳しくはその日のドキュメント「YYYY-MM-DD」を見てください。"
                  + "読み方は「\(guideName)」にあります。", nil))
        for entry in entries.reversed() {
            p.append((label(entry.day), "HEADING_2"))
            for line in entry.flow { p.append(("・" + line, nil)) }
            if !entry.people.isEmpty { p.append(("会った人: " + entry.people.joined(separator: "、"), nil)) }
            if !entry.places.isEmpty { p.append(("場所: " + entry.places.joined(separator: "、"), nil)) }
            if !entry.decisions.isEmpty { p.append(("決まったこと: " + entry.decisions.joined(separator: "／"), nil)) }
            if !entry.todos.isEmpty { p.append(("やること: " + entry.todos.joined(separator: "／"), nil)) }
            var count = "会話 \(entry.conversations) 件"
            if entry.marked > 0 { count += "・★ \(entry.marked) 行" }
            p.append((count + "（ドキュメント「\(entry.day)」）", nil))
        }
        return p
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "E"
        return f
    }()

    /// 「2026-10-31（土）」
    private static func label(_ day: String) -> String {
        guard let date = dayFormatter.date(from: day) else { return day }
        return day + "（" + weekday.string(from: date) + "）"
    }

    // MARK: - 変わったか

    /// 中身の目印（前に書いたものと同じなら書き直さない）。FNV-1a。
    static func stamp(_ paragraphs: Paragraphs) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for p in paragraphs {
            for byte in (p.text + (p.style ?? "") + "\n").utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        return String(hash, radix: 16)
    }
}

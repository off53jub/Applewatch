import Foundation

/// s32（2026-11-27）アプリ担当 S32A の決まり（決まった入力から決まった出力だけ）。「AI の仕事の理解を上げる」。
/// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 21」（知1〜知18）と「追記 20」（解1・3・4・5・6・9・16）。
/// 取り決めは s32 の共通の決まり: K32-1（職場の Claude への頼み方と仕事のまとめの新しい見出し）・K32-2（K2 の新しい鍵）・
/// K32-3（1 押しの「違う」＝ kind work_fix）・K32-4（型の頭は S32A）。
/// 動きは S32ABook.swift、画面は S32AViews.swift、テストは LifeLogTests/S32ATests.swift。しきい値はどれも仮。
/// 新しい問い・知らせは足していない。言語モデルの呼び出しも無い。中身の文は記録（ログ）に書かない。

// MARK: - K32-1 仕事のまとめの新しい見出し

/// 項目 1 つを分けたもの（文・出どころの番号・言った時刻・言った人）
struct S32ADigestItem: Equatable, Sendable {
    var text: String
    var tags: [Int] = []
    /// 「10:30」（項目の終わりの（HH:MM 名前）から。無ければ nil）
    var at: String?
    var who: String?

    /// 画面に出す「10:30・名前」（無ければ空）
    var stamp: String {
        var parts: [String] = []
        if let at { parts.append(at) }
        if let who { parts.append(who) }
        return parts.joined(separator: "・")
    }
}

enum S32ADigest {
    static let meetingTitle = "会議"

    /// 新しい見出しの言い方（長いものを先に。WorkDigestParser.names の後ろに足す）
    static let names: [(part: WorkDigestParser.Part, aliases: [String])] = [
        (.meetings, ["会議と予定", "会議・予定", "今日の会議", "会議"]),
        (.mail, ["Outlookのメール", "メール"]),
        (.tickets, ["チケットの一覧", "チケット一覧", "チケット"]),
        (.cases, ["テストケース", "ケースの一覧", "ケース一覧", "ケース"]),
        // 「用語」だけは入れない（ふつうの文の行と読み違えるので）
        (.terms, ["用語集", "言葉"]),
        (.org, ["体制図", "体制表", "体制"]),
        (.systems, ["仕組みのつながり", "仕組み"]),
        (.numbering, ["番号の決まり", "番号のきまり", "番号の付け方"]),
        (.myrole, ["自分の役割", "じぶんの役割", "わたしの役割", "私の役割"]),
        (.answers, ["質問への答え", "答え"]),
    ]

    /// よくある言葉の見出し。かっこで始まるか見出しだけの行のときだけ見出しにする（「会議：…」のような文の行と見分ける）
    static let strict: Set<String> = ["会議", "メール", "チケット", "ケース", "言葉", "体制", "仕組み", "答え"]

    static func keyPath(_ part: WorkDigestParser.Part) -> WritableKeyPath<WorkDigest.Sections, [String]?>? {
        switch part {
        case .meetings: return \WorkDigest.Sections.meetings
        case .mail: return \WorkDigest.Sections.mail
        case .tickets: return \WorkDigest.Sections.tickets
        case .cases: return \WorkDigest.Sections.cases
        case .terms: return \WorkDigest.Sections.terms
        case .org: return \WorkDigest.Sections.org
        case .systems: return \WorkDigest.Sections.systems
        case .numbering: return \WorkDigest.Sections.numbering
        case .myrole: return \WorkDigest.Sections.myrole
        case .answers: return \WorkDigest.Sections.answers
        default: return nil
        }
    }

    /// 見出しの下の項目を足す（同じ行は 1 つだけ。重なったスクショをつなぐと同じ行が 2 回出るので）
    static func add(_ kept: [String], part: WorkDigestParser.Part, to sections: inout WorkDigest.Sections) {
        guard let path = keyPath(part) else { return }
        var all: [String] = sections[keyPath: path] ?? []
        for item in kept {
            let key: String = WorkDigestParser.compact(item)
            if !all.contains(where: { WorkDigestParser.compact($0) == key }) { all.append(item) }
        }
        if !all.isEmpty { sections[keyPath: path] = all }
    }

    /// 画面とドライブに並べる新しい見出し（会議がいちばん前。空のものも返す・並べる側が外す）
    static func extraLists(_ s: WorkDigest.Sections) -> [(title: String, items: [String])] {
        [
            (meetingTitle, s.meetings ?? []), ("メール", s.mail ?? []), ("チケット", s.tickets ?? []), ("ケース", s.cases ?? []),
            ("言葉", s.terms ?? []), ("体制", s.org ?? []), ("仕組み", s.systems ?? []), ("番号の決まり", s.numbering ?? []),
            ("自分の役割", s.myrole ?? []), ("答え", s.answers ?? []),
        ]
    }

    static func extraEmpty(_ s: WorkDigest.Sections) -> Bool {
        extraLists(s).allSatisfy { $0.items.isEmpty }
    }

    /// 項目 1 つを、文・出どころの番号・（HH:MM 名前）に分ける。番号と（HH:MM 名前）はどちらが先でも外す
    static func split(_ raw: String) -> S32ADigestItem {
        let first = WorkDigestParser.sourceTags(raw)
        let st = stamp(first.text)
        var text: String = st.text
        var tags: [Int] = first.tags
        if tags.isEmpty, st.at != nil {
            let again = WorkDigestParser.sourceTags(text)
            text = again.text
            tags = again.tags
        }
        return S32ADigestItem(text: text, tags: tags, at: st.at, who: st.who)
    }

    private static let stampPattern = try? NSRegularExpression(
        pattern: #"[（(]\s*([0-9０-９]{1,2})\s*[:：]\s*([0-9０-９]{2})(?:\s*[〜~～\-－]\s*[0-9０-９]{1,2}\s*[:：]\s*[0-9０-９]{2})?\s*([^（）()]{0,24}?)\s*[）)]\s*$"#)

    /// 行の終わりの（HH:MM 名前）・（HH:MM）を外す。時刻の無いかっこ・「まで」「から」の入ったかっこ（期限）は外さない
    static func stamp(_ text: String) -> (text: String, at: String?, who: String?) {
        let s: String = text.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = stampPattern?.firstMatch(in: s, range: range),
              let whole = Range(m.range, in: s),
              let hRange = Range(m.range(at: 1), in: s), let mRange = Range(m.range(at: 2), in: s),
              let hour = Int(WorkDigestParser.halfWidth(String(s[hRange]))),
              let minute = Int(WorkDigestParser.halfWidth(String(s[mRange]))),
              (0...23).contains(hour), (0...59).contains(minute) else { return (s, nil, nil) }
        var who: String? = nil
        if let nRange = Range(m.range(at: 3), in: s) {
            let name: String = String(s[nRange]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "・、,")))
            for word in ["まで", "から", "までに", "頃", "ごろ"] where name.contains(word) { return (s, nil, nil) }
            if !name.isEmpty, !WorkDigestParser.isPlaceholder(name), name != "名前" { who = name }
        }
        let rest: String = String(s[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return (s, nil, nil) }
        return (rest, String(format: "%02d:%02d", hour, minute), who)
    }
}

// MARK: - K32-1 週の台帳・土台・AI からの質問の頼み方（職場の Claude に貼る）

/// 職場の Claude に貼る別の頼み方。docs/work-digest.md と同じ中身（直すときは両方）。アプリの中の言語モデルには使わない
enum S32APrompt {
    /// 1 回の質問票に入れる数（知14 の 10 個）
    static let quizLimit = 10

    /// 週 1 回: チケットとケースの台帳（知4）
    static func ledger(day: String) -> String {
        """
        \(day) の時点の、チケットとテストのケースの台帳（一覧と状態）を読んで、下の形だけで答えてください。

        きまり
        ・見出しは下の【 】をそのまま使う。順番も変えない。
        ・表・太字・絵文字・前置き・あとがきは使わない。箇条書きは「・」で、1行に1つ。
        ・聞き返さない。分からない欄は「?」と書く。何も無い見出しは「・なし」と書く。
        ・【チケット】は、1行に1つ「#番号｜題｜状態｜担当」で書く。
        ・【ケース】は、1行に1つ「番号｜何を試すか｜状態｜担当」で書く。
        ・状態は、台帳に書いてある言い方のまま書く。

        【日付】\(day)
        【チケット】
        ・#番号｜題｜状態｜担当
        【ケース】
        ・番号｜何を試すか｜状態｜担当
        """
    }

    /// 1 回だけ: 案件の土台（知5・知6・解16）
    static func base(day: String) -> String {
        """
        いまの案件の土台を、Teams・Outlook・予定・資料から分かる範囲で、下の形だけで答えてください（1 回だけの頼みです）。

        きまり
        ・見出しは下の【 】をそのまま使う。順番も変えない。
        ・表・太字・絵文字・前置き・あとがきは使わない。箇条書きは「・」で、1行に1つ。
        ・聞き返さない。推し量らない。分からないことは書かない。何も無い見出しは「・なし」と書く。
        ・【言葉】は、案件でよく出る略語・固有の言葉を、1行に1つ「言葉｜意味（1〜2 行）｜どのチーム・仕組みの言葉か」で書く。
        ・【体制】は、1行に1人「名前｜チーム｜役割」で書く。
        ・【仕組み】は、どの仕組みからどの仕組みへ何が流れるかを、1行に1つ「A → B｜何が流れるか」で書く。
        ・【番号の決まり】は、チケット番号・ケース番号の付け方（頭の文字・桁・何を表すか）を、1行に1つ書く。
        ・【自分の役割】は、自分が任されていること・どの番号が自分の担当か・だれの指示が自分の宿題になるかを、1行に1つ書く。

        【日付】\(day)
        【言葉】
        ・言葉｜意味｜チーム・仕組み
        【体制】
        ・名前｜チーム｜役割
        【仕組み】
        ・A → B｜何が流れるか
        【番号の決まり】
        ・…
        【自分の役割】
        ・…
        """
    }

    /// AI からの質問（知14。K2 の quiz）。質問が無ければ nil
    static func quiz(day: String, quiz: S32AQuiz?) -> String? {
        let questions: [S32AQuestion] = Array((quiz?.questions ?? []).prefix(quizLimit))
        guard !questions.isEmpty else { return nil }
        // 母艦が頼み方まで書いていれば、それをそのまま（答えの形＝【答え】の「q印｜答え」を母艦の読み方とそろえるため）
        if let written = quiz?.prompt { return written }
        var lines: [String] = []
        for q in questions {
            lines.append("・" + q.id + "｜" + q.q)
        }
        return """
        家の AI が、いまの案件で分からないことを挙げました。Teams・Outlook・予定・資料から分かる範囲で、下の形だけで答えてください。

        きまり
        ・見出しは【日付】と【答え】だけ。表・太字・絵文字・前置き・あとがきは使わない。
        ・【答え】は、1行に1つ「質問の番号｜答え」で書く。箇条書きは「・」。
        ・推し量らない。記録から分からない質問は「質問の番号｜分からない」と書く。

        質問
        \(lines.joined(separator: "\n"))

        【日付】\(day)
        【答え】
        ・質問の番号｜答え
        """
    }
}

// MARK: - K32-2 K2 の新しい鍵（どれも省ける・読めない行は飛ばす）

/// 数・文字・配列のどれで来ても読む（配列なら数）
enum S32ALenient {
    static func count<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return max(0, n) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite, abs(d) < 1e12 { return max(0, Int(d)) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let n = Int(s.trimmingCharacters(in: .whitespaces)) { return max(0, n) }
        if let rows = try? c.decodeIfPresent([LossyRow<String>].self, forKey: key) { return rows.count }
        return nil
    }

    static func strings<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [String] {
        if let one = try? c.decodeIfPresent(String.self, forKey: key) {
            let t = one.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [t]
        }
        let list: [String] = c.s27wList(key)
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func text<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return String(n) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite { return S32ARules.number(d) }
        return nil
    }

    static func number<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            if let d = Double(t), d.isFinite { return d }
        }
        return nil
    }

    static func required<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String {
        guard let t = text(c, key) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "空")
        }
        return t
    }
}

/// glossary の 1 語（解1）
struct S32ATerm: Decodable, Equatable, Sendable, Identifiable {
    var term: String
    var meaning: String?
    var team: String?
    var days: Int?
    var sampleIDs: [String] = []
    var voiceSays: [String] = []
    var firm: Bool?

    var id: String { term }
    /// 職場の Claude の答え（土台）から来たもの。false・無しは「仮」
    var isFirm: Bool { firm == true }

    enum CodingKeys: String, CodingKey {
        case term, meaning, team, days, firm
        case sampleIDs = "sample_ids", voiceSays = "voice_says"
    }

    init(term: String, meaning: String? = nil, team: String? = nil, days: Int? = nil, sampleIDs: [String] = [],
         voiceSays: [String] = [], firm: Bool? = nil) {
        self.term = term
        self.meaning = meaning
        self.team = team
        self.days = days
        self.sampleIDs = sampleIDs
        self.voiceSays = voiceSays
        self.firm = firm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try S32ALenient.required(c, .term)
        meaning = S32ALenient.text(c, .meaning)
        team = S32ALenient.text(c, .team)
        days = S32ALenient.count(c, .days)
        sampleIDs = S32ALenient.strings(c, .sampleIDs)
        voiceSays = S32ALenient.strings(c, .voiceSays)
        firm = c.s27w(.firm)
    }
}

/// org の 1 人（解4）
struct S32AOrgPerson: Decodable, Equatable, Sendable {
    var id: String?
    var name: String
    var team: String?
    var role: String?
    /// "ask"＝自分が頼む・"asked"＝自分が頼まれる・"both"・nil
    var withMe: String?
    var last: String?
    var firm: Bool?

    var isFirm: Bool { firm == true }

    enum CodingKeys: String, CodingKey {
        case id, name, team, role, last, firm
        case withMe = "with_me"
    }

    init(id: String? = nil, name: String, team: String? = nil, role: String? = nil, withMe: String? = nil,
         last: String? = nil, firm: Bool? = nil) {
        self.id = id
        self.name = name
        self.team = team
        self.role = role
        self.withMe = withMe
        self.last = last
        self.firm = firm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try S32ALenient.required(c, .name)
        id = S32ALenient.text(c, .id)
        team = S32ALenient.text(c, .team)
        role = S32ALenient.text(c, .role)
        withMe = S32ALenient.text(c, .withMe)
        last = S32ALenient.text(c, .last)
        firm = c.s27w(.firm)
    }
}

struct S32ANode: Decodable, Equatable, Sendable {
    var id: String
    var name: String
    var team: String?

    enum CodingKeys: String, CodingKey { case id, name, team }

    init(id: String, name: String, team: String? = nil) {
        self.id = id
        self.name = name
        self.team = team
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let i: String? = S32ALenient.text(c, .id)
        let n: String? = S32ALenient.text(c, .name)
        guard let key = i ?? n else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "空")
        }
        id = key
        name = n ?? key
        team = S32ALenient.text(c, .team)
    }
}

struct S32AEdge: Decodable, Equatable, Sendable {
    var from: String
    var to: String
    var what: String?

    enum CodingKeys: String, CodingKey { case from, to, what }

    init(from: String, to: String, what: String? = nil) {
        self.from = from
        self.to = to
        self.what = what
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try S32ALenient.required(c, .from)
        to = try S32ALenient.required(c, .to)
        what = S32ALenient.text(c, .what)
    }
}

/// systems（解5）: 箱と矢印と、詰まっている箱
struct S32ASystems: Decodable, Equatable, Sendable {
    var nodes: [S32ANode] = []
    var edges: [S32AEdge] = []
    var stuck: [String] = []

    enum CodingKeys: String, CodingKey { case nodes, edges, stuck }

    init(nodes: [S32ANode] = [], edges: [S32AEdge] = [], stuck: [String] = []) {
        self.nodes = nodes
        self.edges = edges
        self.stuck = stuck
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = c.s27wList(.nodes)
        edges = c.s27wList(.edges)
        stuck = S32ALenient.strings(c, .stuck)
    }

    var isEmpty: Bool { nodes.isEmpty && edges.isEmpty }
}

/// numbering の 1 つ（解6。番号の早見）
struct S32ANumber: Decodable, Equatable, Sendable {
    var no: String
    var what: String?
    var owner: String?
    var state: String?
    var why: String?
    var days: Int?

    enum CodingKeys: String, CodingKey { case no, what, owner, state, why, days }

    init(no: String, what: String? = nil, owner: String? = nil, state: String? = nil, why: String? = nil, days: Int? = nil) {
        self.no = no
        self.what = what
        self.owner = owner
        self.state = state
        self.why = why
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        no = try S32ALenient.required(c, .no)
        what = S32ALenient.text(c, .what)
        owner = S32ALenient.text(c, .owner)
        state = S32ALenient.text(c, .state)
        why = S32ALenient.text(c, .why)
        days = S32ALenient.count(c, .days)
    }
}

/// decisions の 1 つ（解9。決まったことの台帳）
struct S32ADecision: Decodable, Equatable, Sendable {
    var id: String?
    var day: String?
    var text: String
    var who: String?
    var why: String?
    /// ひっくり返した新しい決定の id（無ければ nil）
    var flippedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, day, text, who, why
        case flippedBy = "flipped_by"
    }

    init(id: String? = nil, day: String? = nil, text: String, who: String? = nil, why: String? = nil, flippedBy: String? = nil) {
        self.id = id
        self.day = day
        self.text = text
        self.who = who
        self.why = why
        self.flippedBy = flippedBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try S32ALenient.required(c, .text)
        id = S32ALenient.text(c, .id)
        day = S32ALenient.text(c, .day)
        who = S32ALenient.text(c, .who)
        why = S32ALenient.text(c, .why)
        flippedBy = S32ALenient.text(c, .flippedBy) ?? S32ALenient.strings(c, .flippedBy).first
    }

    var flipped: Bool { flippedBy != nil }
}

/// threads の 1 本（知11。話題の糸）
struct S32AThread: Decodable, Equatable, Sendable {
    var id: String?
    var title: String
    var keys: [String] = []
    /// 出た日の数（日の並びで来たら、その数）
    var days: Int?
    /// 日の並びで来たときの、いちばん新しい日
    var lastDay: String?
    /// 項目の id（並びで来たとき）
    var items: [String] = []
    /// 項目の数（数で来たときも）
    var itemCount: Int?
    var state: String?

    enum CodingKeys: String, CodingKey { case id, title, keys, days, items, state }

    init(id: String? = nil, title: String, keys: [String] = [], days: Int? = nil, items: [String] = [], state: String? = nil) {
        self.id = id
        self.title = title
        self.keys = keys
        self.days = days
        self.items = items
        self.itemCount = items.isEmpty ? nil : items.count
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try S32ALenient.required(c, .title)
        id = S32ALenient.text(c, .id)
        keys = S32ALenient.strings(c, .keys)
        days = S32ALenient.count(c, .days)
        let dayList: [String] = c.s27wList(.days)
        lastDay = dayList.filter { HomeFeeds.isDay($0) }.max()
        let ids: [String] = c.s27wList(.items)
        items = ids.filter { HomeFeeds.isID($0) }
        itemCount = S32ALenient.count(c, .items)
        state = S32ALenient.text(c, .state)
    }
}

struct S32AQuestion: Decodable, Equatable, Sendable {
    var id: String
    var q: String
    var why: String?
    var about: String?

    enum CodingKeys: String, CodingKey { case id, q, why, about }

    init(id: String, q: String, why: String? = nil, about: String? = nil) {
        self.id = id
        self.q = q
        self.why = why
        self.about = about
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try S32ALenient.required(c, .id)
        q = try S32ALenient.required(c, .q)
        why = S32ALenient.text(c, .why)
        about = S32ALenient.text(c, .about)
    }
}

/// quiz（知14 の質問票）
struct S32AQuiz: Decodable, Equatable, Sendable {
    var week: String?
    var questions: [S32AQuestion] = []
    /// 母艦が書いた職場の Claude への頼み方（省ける。あればアプリの組み立てより先に使う）
    var prompt: String?

    enum CodingKeys: String, CodingKey { case week, questions, prompt }

    init(week: String? = nil, questions: [S32AQuestion] = [], prompt: String? = nil) {
        self.week = week
        self.questions = questions
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = S32ALenient.text(c, .week)
        questions = c.s27wList(.questions)
        prompt = S32ALenient.text(c, .prompt)
    }
}

struct S32AScoreRow: Decodable, Equatable, Sendable {
    /// 母艦の物差しの名前（省ける。見せない）
    var key: String?
    var label: String
    /// 数の中身の説明（「1/56」など。省ける）
    var detail: String?
    var now: Double?
    var prev: Double?
    /// 数でない言い方で来たとき（「1/56」など）
    var nowText: String?
    var prevText: String?
    var unit: String?

    enum CodingKeys: String, CodingKey { case key, label, detail, now, prev, unit }

    init(key: String? = nil, label: String, detail: String? = nil, now: Double? = nil, prev: Double? = nil, unit: String? = nil) {
        self.key = key
        self.label = label
        self.detail = detail
        self.now = now
        self.prev = prev
        self.unit = unit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try S32ALenient.required(c, .label)
        key = S32ALenient.text(c, .key)
        detail = S32ALenient.text(c, .detail)
        now = S32ALenient.number(c, .now)
        prev = S32ALenient.number(c, .prev)
        nowText = now == nil ? S32ALenient.text(c, .now) : nil
        prevText = prev == nil ? S32ALenient.text(c, .prev) : nil
        unit = S32ALenient.text(c, .unit)
    }
}

/// scorecard（知17 の通信簿）
struct S32AScorecard: Decodable, Equatable, Sendable {
    var week: String?
    var rows: [S32AScoreRow] = []

    enum CodingKeys: String, CodingKey { case week, rows }

    init(week: String? = nil, rows: [S32AScoreRow] = []) {
        self.week = week
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = S32ALenient.text(c, .week)
        rows = c.s27wList(.rows)
    }
}

/// guide（知10 の手引きの様子。本文はアプリに来ない）
struct S32AGuide: Decodable, Equatable, Sendable {
    var writtenAt: String?
    /// "subscription"＝定額の枠で作り直した・"rules"＝規則の版
    var by: String?
    var stale: Bool?

    enum CodingKeys: String, CodingKey {
        case by, stale
        case writtenAt = "written_at"
    }

    init(writtenAt: String? = nil, by: String? = nil, stale: Bool? = nil) {
        self.writtenAt = writtenAt
        self.by = by
        self.stale = stale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        writtenAt = S32ALenient.text(c, .writtenAt)
        by = S32ALenient.text(c, .by)
        stale = c.s27w(.stale)
    }
}

/// K2 の新しい鍵をまとめたもの（S27WBoard.know）
struct S32AKnow: Decodable, Equatable, Sendable {
    var glossary: [S32ATerm] = []
    var org: [S32AOrgPerson] = []
    var systems: S32ASystems?
    var numbering: [S32ANumber] = []
    var decisions: [S32ADecision] = []
    var threads: [S32AThread] = []
    var quiz: S32AQuiz?
    var scorecard: S32AScorecard?
    var guide: S32AGuide?

    enum CodingKeys: String, CodingKey { case glossary, org, systems, numbering, decisions, threads, quiz, scorecard, guide }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glossary = c.s27wList(.glossary)
        org = c.s27wList(.org)
        systems = c.s27w(.systems)
        numbering = c.s27wList(.numbering)
        decisions = c.s27wList(.decisions)
        threads = c.s27wList(.threads)
        quiz = c.s27w(.quiz)
        scorecard = c.s27w(.scorecard)
        guide = c.s27w(.guide)
    }

    /// K2 の全体から読む（S27WBoard の init から）。無い・全部空・壊れているときは nil（K2 のほかは読める）
    static func read(_ decoder: Decoder) -> S32AKnow? {
        guard let know = try? S32AKnow(from: decoder), !know.isEmpty else { return nil }
        return know
    }

    var isEmpty: Bool {
        glossary.isEmpty && org.isEmpty && (systems?.isEmpty ?? true) && numbering.isEmpty && decisions.isEmpty
            && threads.isEmpty && (quiz?.questions ?? []).isEmpty && (scorecard?.rows ?? []).isEmpty && guide == nil
    }
}

// MARK: - 知16 本人に聞く 3 つ（今の確かめ待ちの列に、種類 work_self で来る）

enum S32AReview {
    /// 確かめ待ちの列の種類（id は s32s-…・答えは text / pick / yesno。答えは今の kind "review" の道のまま）
    static let kind = "work_self"
    static let label = "仕事の持ち場（あなたしか知らないこと）"

    /// 時計・通知・ウィジェットに出してよいか（仕事の中身なので出さない。守1。確かめ待ちの画面でだけ答える）
    static func offPhoneOK(_ item: ReviewItem) -> Bool { item.kind != kind }
}

// MARK: - K32-3 1 押しの「違う」

enum S32AFixKind: String, CaseIterable, Codable, Sendable {
    case project, person, term, done, notmine

    var label: String {
        switch self {
        case .project: "案件が違う"
        case .person: "人が違う"
        case .term: "言葉が違う"
        case .done: "もう済んだ"
        case .notmine: "自分の番ではない"
        }
    }

    var symbol: String {
        switch self {
        case .project: "folder.badge.questionmark"
        case .person: "person.crop.circle.badge.questionmark"
        case .term: "character.book.closed"
        case .done: "checkmark.circle"
        case .notmine: "arrow.uturn.right.circle"
        }
    }

    /// 開いている件から外して見せる（取り消し線）もの
    var hides: Bool { self == .done || self == .notmine }
}

/// 端末に覚える直し 1 つ
struct S32AFix: Codable, Equatable, Sendable {
    var what: S32AFixKind
    /// 直した値（案件・人の id。無ければ nil）
    var value: String?
    /// 直した値の見せる名前（案件・人の名前）
    var valueName: String?
    var day: String
}

// MARK: - 決まり

enum S32ARules {
    /// 文の中で押せるようにする言葉の数（1 つの文で。仮）
    static let spanLimit = 12
    /// 「違う」の行き先に並べる案件・人の数（仮）
    static let choiceLimit = 8
    /// 端末に覚える直しの数・日数（仮）
    static let fixLimit = 300
    static let fixDays = 30
    static let termScheme = "lifelog-s32a"

    // MARK: K32-3 送る形

    /// `{"kind":"work_fix","id","what","value":<値 or null>,"day"}`。決まった形でなければ nil
    static func fixBody(id: String, what: S32AFixKind, value: String?, day: String) -> Data? {
        guard HomeFeeds.isID(id), HomeFeeds.isDay(day) else { return nil }
        var object: [String: Any] = ["kind": "work_fix", "id": id, "what": what.rawValue, "day": day]
        let v: String = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty {
            object["value"] = NSNull()
        } else {
            guard v.count <= 200 else { return nil }
            object["value"] = v
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 覚えた直しを溜めない（古い日のもの・多すぎる分を捨てる）
    static func keptFixes(_ fixes: [String: S32AFix], today: String) -> [String: S32AFix] {
        let limit: String = dayBefore(today, days: fixDays) ?? ""
        var kept: [String: S32AFix] = fixes.filter { $0.value.day >= limit }
        if kept.count > fixLimit {
            let drop = kept.sorted { $0.value.day < $1.value.day }.prefix(kept.count - fixLimit).map(\.key)
            for key in drop { kept[key] = nil }
        }
        return kept
    }

    static func dayBefore(_ day: String, days: Int) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        return f.string(from: d.addingTimeInterval(-Double(days) * 86400))
    }

    /// 「伝えました: 案件が違う（→ 見本の打鍵）」
    static func fixLine(_ fix: S32AFix) -> String {
        var s = "伝えました: " + fix.what.label
        if let name = fix.valueName, !name.isEmpty { s += "（→ " + name + "）" }
        return s
    }

    // MARK: 言葉を押せるようにする

    /// 文の中の glossary の言葉の場所（長い言葉を先に・重ならない・英字の言葉は英字の続きの中では当てない）
    static func termSpans(_ text: String, terms: [String]) -> [(range: Range<String.Index>, index: Int)] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        let order: [Int] = terms.indices.filter { terms[$0].count >= 2 }.sorted { a, b in
            terms[a].count != terms[b].count ? terms[a].count > terms[b].count : a < b
        }
        var taken: [Range<String.Index>] = []
        var out: [(range: Range<String.Index>, index: Int)] = []
        for i in order {
            let word: String = terms[i]
            var from: String.Index = text.startIndex
            while from < text.endIndex, out.count < spanLimit,
                  let r = text.range(of: word, options: [.caseInsensitive, .widthInsensitive], range: from..<text.endIndex) {
                from = r.upperBound
                guard !r.isEmpty, !taken.contains(where: { $0.overlaps(r) }), boundary(text, r) else { continue }
                taken.append(r)
                out.append((r, i))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// 英字・数字で始まる（終わる）言葉は、前（後ろ）が英字・数字なら当てない（「UAT」を「UATS」の中で当てない）
    private static func boundary(_ text: String, _ r: Range<String.Index>) -> Bool {
        if let first = text[r].first, isWordChar(first), r.lowerBound > text.startIndex,
           isWordChar(text[text.index(before: r.lowerBound)]) { return false }
        if let last = text[r].last, isWordChar(last), r.upperBound < text.endIndex, isWordChar(text[r.upperBound]) { return false }
        return true
    }

    /// 言葉を押せる文（押すと `lifelog-s32a://term/<番号>`）。押せる言葉が無ければ nil
    static func linked(_ text: String, terms: [String]) -> AttributedString? {
        let spans = termSpans(text, terms: terms)
        guard !spans.isEmpty else { return nil }
        var out = AttributedString()
        var cursor: String.Index = text.startIndex
        for span in spans {
            if cursor < span.range.lowerBound { out.append(AttributedString(String(text[cursor..<span.range.lowerBound]))) }
            var piece = AttributedString(String(text[span.range]))
            piece.link = termURL(span.index)
            out.append(piece)
            cursor = span.range.upperBound
        }
        if cursor < text.endIndex { out.append(AttributedString(String(text[cursor...]))) }
        return out
    }

    static func termURL(_ index: Int) -> URL? {
        URL(string: termScheme + "://term/" + String(index))
    }

    /// 押した URL → glossary の番号（違う URL なら nil）
    static func termIndex(_ url: URL) -> Int? {
        guard url.scheme == termScheme, url.host == "term" else { return nil }
        return Int(url.lastPathComponent)
    }

    // MARK: 項目を引く

    /// K2 の項目を id で（案件の items・timeline と副業の items。順は ids の順・重なりなし）
    static func items(_ board: S27WBoard, ids: [String]) -> [S27WItem] {
        guard !ids.isEmpty else { return [] }
        var byID: [String: S27WItem] = [:]
        for p in board.projects {
            for item in p.items + p.timeline where byID[item.id] == nil { byID[item.id] = item }
        }
        for item in board.side?.items ?? [] where byID[item.id] == nil { byID[item.id] = item }
        var seen: Set<String> = []
        var out: [S27WItem] = []
        for id in ids where seen.insert(id).inserted {
            if let item = byID[id] { out.append(item) }
        }
        return out
    }

    // MARK: 人とチームの地図

    static let noTeam = "チームがまだ分からない人"

    /// チームごと（人の多いチームから・チームの分からない人は最後）
    static func orgGroups(_ people: [S32AOrgPerson]) -> [(team: String, people: [S32AOrgPerson])] {
        var order: [String] = []
        var groups: [String: [S32AOrgPerson]] = [:]
        for p in people {
            let t: String = (p.team ?? "").trimmingCharacters(in: .whitespaces)
            let key: String = t.isEmpty ? noTeam : t
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(p)
        }
        let known: [String] = order.filter { $0 != noTeam }.sorted { a, b in
            let x = groups[a]?.count ?? 0, y = groups[b]?.count ?? 0
            return x != y ? x > y : (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        }
        var out: [(team: String, people: [S32AOrgPerson])] = known.map { ($0, groups[$0] ?? []) }
        if let rest = groups[noTeam] { out.append((noTeam, rest)) }
        return out
    }

    static func withMeLabel(_ value: String?) -> String? {
        switch value {
        case "ask": "自分が頼む相手"
        case "asked": "自分に頼んでくる相手"
        case "both": "頼み・頼まれ"
        default: nil
        }
    }

    // MARK: 仕組みの図

    static func nodeName(_ id: String, in systems: S32ASystems) -> String {
        systems.nodes.first { $0.id == id }?.name ?? id
    }

    /// 「A → B（何が流れるか）」
    static func edgeLine(_ edge: S32AEdge, in systems: S32ASystems) -> String {
        var s = nodeName(edge.from, in: systems) + " → " + nodeName(edge.to, in: systems)
        if let what = edge.what, !what.isEmpty { s += "（" + what + "）" }
        return s
    }

    /// 矢印に出てこない箱（つながりの分からない箱）
    static func loneNodes(_ systems: S32ASystems) -> [S32ANode] {
        let used: Set<String> = Set(systems.edges.flatMap { [$0.from, $0.to] })
        return systems.nodes.filter { !used.contains($0.id) }
    }

    // MARK: 番号の早見

    /// 何日またぐ順（日数の多い順・日数の無いものは最後・同じなら番号の順）
    static func numberingSorted(_ list: [S32ANumber]) -> [S32ANumber] {
        list.sorted { a, b in
            switch (a.days, b.days) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.no.localizedStandardCompare(b.no) == .orderedAscending
            }
        }
    }

    // MARK: 決まったことの台帳

    /// 新しい日から（日の無いものは最後）
    static func decisionsSorted(_ list: [S32ADecision]) -> [S32ADecision] {
        list.enumerated().sorted { a, b in
            let x = a.element.day ?? "", y = b.element.day ?? ""
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// ひっくり返した新しい決定の文
    static func flippedText(_ d: S32ADecision, in all: [S32ADecision]) -> String? {
        guard let by = d.flippedBy else { return nil }
        return all.first { $0.id == by }?.text
    }

    /// ほかの決定をひっくり返した決定か
    static func flipsOther(_ d: S32ADecision, in all: [S32ADecision]) -> Bool {
        guard let id = d.id else { return false }
        return all.contains { $0.flippedBy == id }
    }

    static func searchDecisions(_ list: [S32ADecision], query: String) -> [S32ADecision] {
        let words: [String] = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return list }
        return list.filter { d in
            let hay: String = [d.text, d.who ?? "", d.why ?? "", d.day ?? ""].joined(separator: " ")
            return words.allSatisfy { hay.localizedCaseInsensitiveContains($0) }
        }
    }

    // MARK: 通信簿

    static func number(_ x: Double) -> String {
        if x.rounded() == x, abs(x) < 1e12 { return String(Int(x)) }
        return String(format: "%.1f", x)
    }

    static func withUnit(_ n: String, _ unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return n }
        return unit == "%" ? n + "%" : n + " " + unit
    }

    /// 今の値（「43%」「1/56」）
    static func valueText(_ row: S32AScoreRow) -> String {
        if let now = row.now { return withUnit(number(now), row.unit) }
        return row.nowText ?? "?"
    }

    /// 前の週との差（「前の週から +5%」「前の週と同じ」。比べられなければ nil）
    static func diffText(_ row: S32AScoreRow) -> String? {
        guard let now = row.now, let prev = row.prev else {
            if let prev = row.prev { return "前の週は " + withUnit(number(prev), row.unit) }
            if let text = row.prevText { return "前の週は " + text }
            return nil
        }
        let d: Double = now - prev
        if abs(d) < 1e-9 { return "前の週と同じ" }
        return "前の週から " + (d > 0 ? "+" : "−") + withUnit(number(abs(d)), row.unit)
    }

    // MARK: 手引きの様子

    static func byLabel(_ by: String?) -> String {
        switch by {
        case "subscription": "定額の枠で作り直し"
        case "rules": "規則の版"
        default: "作り方は不明"
        }
    }

    /// 「11/27 3:10 に作り直し・定額の枠で作り直し」
    static func guideLine(_ guide: S32AGuide, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let at = guide.writtenAt {
            parts.append(stampText(at, timeZone: timeZone) + " に書いた")
        }
        parts.append(byLabel(guide.by))
        return parts.joined(separator: "・")
    }

    static func stampText(_ iso: String, timeZone: TimeZone = .current) -> String {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = full.date(from: iso) ?? plain.date(from: iso) else {
            return HomeFeeds.isDay(iso) ? AppFeeds.monthDay(iso) : iso
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = timeZone
        f.dateFormat = "M/d H:mm"
        return f.string(from: date)
    }

    // MARK: 段の 1 行

    /// 「言葉 12 語（仮 4）」
    static func glossaryLine(_ glossary: [S32ATerm]) -> String {
        let draft = glossary.filter { !$0.isFirm }.count
        return "\(glossary.count) 語" + (draft > 0 ? "（仮 \(draft)）" : "")
    }
}

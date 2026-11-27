import Foundation

// s34（2026-11-27）アプリ担当 S34A の決まり（決まった入力から決まった出力だけ）。動きは S34ABook.swift、画面は S34AViews.swift。
// 案の全文は母艦の docs/system-proposal-2026-11-13.md の「追記 24」（自1〜自12・円1〜円5）。しきい値はどれも仮。
// 取り決め: K34-1（GET /s34 の中身）・K34-3（円1 写真から仕事のまとめ。送るのは今の POST /work/digest）。形は変えない。
// - K34-1 の読み（S34AFeed）: どの鍵も省ける。1 つの鍵が壊れていても、ほかは読む。数は文字でも読む
// - 自動で直した数（S34AFixed）: self_fixed・auto_switch・tuned・reflow・guide_run・healed を数だけの行にする
// - 円2 頼み方（S34APrompt）: その日の 1 つの文があればそれ、無ければ今の頼み方（WorkDigestPrompt.full）
// - 円5 テストの進み（S34ARules.testsLine）・円4 会議の前の 1 枚（S34APrepRules）・円3 次の一手（S34ANudgeRules）
// - 円1 写真の見分け（S34APhotoRules）: 決まった見出し（【 】で始まる行）が 2 つ以上写っているものだけ。頼み方そのものの写真は外す
// - どこ？に足す画面（S34AWhere）

// MARK: - K34-1 アプリに出すもの（GET /s34）

/// 数でも文字でも、はい・いいえでも読み、見せる文字にする（tuned の old・new・range など、形が決まっていないもの）
struct S34AValue: Decodable, Equatable, Sendable {
    let text: String

    init(_ text: String) { self.text = text }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            if let d = try? c.decode(Double.self), d.isFinite {
                text = S34ARules.numText(d)
                return
            }
            if let s = try? c.decode(String.self) {
                text = s
                return
            }
            if let b = try? c.decode(Bool.self) {
                text = b ? "はい" : "いいえ"
                return
            }
        }
        // [下, 上] の並び（range）
        if var u = try? decoder.unkeyedContainer() {
            var parts: [String] = []
            while !u.isAtEnd, parts.count < 4 {
                if let d = try? u.decode(Double.self), d.isFinite {
                    parts.append(S34ARules.numText(d))
                } else if let s = try? u.decode(String.self) {
                    parts.append(s)
                } else {
                    break
                }
            }
            if !parts.isEmpty {
                text = parts.joined(separator: "〜")
                return
            }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "読めない値"))
    }
}

/// 自1〜自5 機械が自分で解いた数（数だけ）
struct S34ASelfFixed: Decodable, Equatable, Sendable {
    var week: String?
    var speakerFixed: Int?
    var speakerLeft: Int?
    var speakerUndone: Int?
    var reopenedSolved: Int?
    var reopenedLeft: Int?
    var vocabAdopted: Int?
    var vocabDropped: Int?
    var workSolved: Int?
    var workLeft: Int?
    var placeBefore: Double?
    var placeAfter: Double?

    enum CodingKeys: String, CodingKey { case week, speaker, reopened, vocab, work, place }
    enum SpeakerKeys: String, CodingKey { case fixed, left, undone }
    enum SolvedKeys: String, CodingKey { case solved, left }
    enum VocabKeys: String, CodingKey { case adopted, dropped }
    enum PlaceKeys: String, CodingKey { case before, after }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = c.s33a(.week)
        if let k = try? c.nestedContainer(keyedBy: SpeakerKeys.self, forKey: .speaker) {
            speakerFixed = S34ARules.int(k.s33aNum(.fixed))
            speakerLeft = S34ARules.int(k.s33aNum(.left))
            speakerUndone = S34ARules.int(k.s33aNum(.undone))
        }
        if let k = try? c.nestedContainer(keyedBy: SolvedKeys.self, forKey: .reopened) {
            reopenedSolved = S34ARules.int(k.s33aNum(.solved))
            reopenedLeft = S34ARules.int(k.s33aNum(.left))
        }
        if let k = try? c.nestedContainer(keyedBy: VocabKeys.self, forKey: .vocab) {
            vocabAdopted = S34ARules.int(k.s33aNum(.adopted))
            vocabDropped = S34ARules.int(k.s33aNum(.dropped))
        }
        if let k = try? c.nestedContainer(keyedBy: SolvedKeys.self, forKey: .work) {
            workSolved = S34ARules.int(k.s33aNum(.solved))
            workLeft = S34ARules.int(k.s33aNum(.left))
        }
        if let k = try? c.nestedContainer(keyedBy: PlaceKeys.self, forKey: .place) {
            placeBefore = k.s33aNum(.before)
            placeAfter = k.s33aNum(.after)
        }
    }
}

/// 自8 影から本番・本番から戻した切り替え
struct S34ASwitch: Decodable, Equatable, Sendable {
    var name: String
    var state: String?

    enum CodingKeys: String, CodingKey { case name, state }

    init(name: String, state: String?) {
        self.name = name
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        state = c.s33a(.state)
    }
}

/// 自9 合わせ直した仮の数
struct S34ATuned: Decodable, Equatable, Sendable {
    var name: String
    var old: S34AValue?
    var new: S34AValue?

    enum CodingKeys: String, CodingKey { case name, old, new }

    init(name: String, old: S34AValue? = nil, new: S34AValue? = nil) {
        self.name = name
        self.old = old
        self.new = new
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        old = c.s33a(.old)
        new = c.s33a(.new)
    }

    /// 本当に動いたか（同じ値なら合わせ直していない）
    var moved: Bool { old?.text != new?.text }
}

/// 自10 過去の日の流し直し
struct S34AReflow: Decodable, Equatable, Sendable {
    var daysDone: Int?
    var daysLeft: Int?
    var lastDay: String?

    enum CodingKeys: String, CodingKey { case days_done, days_left, last_day }

    init(daysDone: Int? = nil, daysLeft: Int? = nil, lastDay: String? = nil) {
        self.daysDone = daysDone
        self.daysLeft = daysLeft
        self.lastDay = lastDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daysDone = S34ARules.int(c.s33aNum(.days_done))
        daysLeft = S34ARules.int(c.s33aNum(.days_left))
        lastDay = c.s33a(.last_day)
    }
}

/// 自11 週 1 回の強い読み直し
struct S34AGuideRun: Decodable, Equatable, Sendable {
    var lastOK: String?
    var by: String?
    var missesUsed: Int?
    var rulesAdded: Int?

    enum CodingKeys: String, CodingKey { case last_ok, by, misses_used, rules_added }

    init(lastOK: String? = nil, by: String? = nil, missesUsed: Int? = nil, rulesAdded: Int? = nil) {
        self.lastOK = lastOK
        self.by = by
        self.missesUsed = missesUsed
        self.rulesAdded = rulesAdded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastOK = c.s33a(.last_ok)
        by = c.s33a(.by)
        missesUsed = S34ARules.int(c.s33aNum(.misses_used))
        rulesAdded = S34ARules.int(c.s33aNum(.rules_added))
    }
}

/// 自12 自分で直した止まり
struct S34AHealed: Decodable, Equatable, Sendable {
    var source: String
    var ok: Bool?

    enum CodingKeys: String, CodingKey { case source, ok }

    init(source: String, ok: Bool?) {
        self.source = source
        self.ok = ok
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        if let b: Bool = c.s33a(.ok) {
            ok = b
        } else if let n = c.s33aNum(.ok) {
            ok = n != 0
        }
    }
}

/// 円2 職場の Claude に貼る 1 つの文
struct S34APromptFeed: Decodable, Equatable, Sendable {
    var day: String?
    var text: String
    var parts: [String] = []

    enum CodingKeys: String, CodingKey { case day, text, parts }

    init(day: String?, text: String, parts: [String] = []) {
        self.day = day
        self.text = text
        self.parts = parts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = c.s33a(.day)
        text = try c.decode(String.self, forKey: .text)
        parts = c.s33aStrings(.parts)
    }
}

/// 円3 止まっている話の次の一手と下書き
struct S34ANudge: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var topic: String
    var who: String?
    var days: Int?
    var next: String?
    var draft: String?

    enum CodingKeys: String, CodingKey { case id, topic, who, days, next, draft }

    init(id: String, topic: String, who: String? = nil, days: Int? = nil, next: String? = nil, draft: String? = nil) {
        self.id = id
        self.topic = topic
        self.who = who
        self.days = days
        self.next = next
        self.draft = draft
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        topic = try c.decode(String.self, forKey: .topic)
        who = c.s33a(.who)
        days = S34ARules.int(c.s33aNum(.days))
        next = c.s33a(.next)
        draft = c.s33a(.draft)
    }
}

/// 円4 会議の前の 1 枚
struct S34APrep: Decodable, Equatable, Sendable {
    var meeting: String
    var at: String?
    var lastDecided: [String] = []
    var myTasks: [String] = []
    var likelyAsked: [String] = []
    var selfCheck: [String] = []

    enum CodingKeys: String, CodingKey { case meeting, at, last_decided, my_tasks, likely_asked, self_check }

    init(meeting: String, at: String?, lastDecided: [String] = [], myTasks: [String] = [], likelyAsked: [String] = [],
         selfCheck: [String] = []) {
        self.meeting = meeting
        self.at = at
        self.lastDecided = lastDecided
        self.myTasks = myTasks
        self.likelyAsked = likelyAsked
        self.selfCheck = selfCheck
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meeting = try c.decode(String.self, forKey: .meeting)
        at = c.s33a(.at)
        lastDecided = c.s33aStrings(.last_decided)
        myTasks = c.s33aStrings(.my_tasks)
        likelyAsked = c.s33aStrings(.likely_asked)
        selfCheck = c.s33aStrings(.self_check)
    }

    var isEmpty: Bool { lastDecided.isEmpty && myTasks.isEmpty && likelyAsked.isEmpty && selfCheck.isEmpty }
}

/// 円5 テストの進み
struct S34ATestProgress: Decodable, Equatable, Sendable {
    var total: Int?
    var done: Int?
    var ng: Int?
    var waiting: Int?
    var today: Int?
    var finishGuess: String?

    enum CodingKeys: String, CodingKey { case total, done, ng, waiting, today, finish_guess }

    init(total: Int? = nil, done: Int? = nil, ng: Int? = nil, waiting: Int? = nil, today: Int? = nil, finishGuess: String? = nil) {
        self.total = total
        self.done = done
        self.ng = ng
        self.waiting = waiting
        self.today = today
        self.finishGuess = finishGuess
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = S34ARules.int(c.s33aNum(.total))
        done = S34ARules.int(c.s33aNum(.done))
        ng = S34ARules.int(c.s33aNum(.ng))
        waiting = S34ARules.int(c.s33aNum(.waiting))
        today = S34ARules.int(c.s33aNum(.today))
        finishGuess = c.s33a(.finish_guess)
    }
}

/// K34-1 の全部（どの鍵も省ける。1 つの鍵が壊れていても、ほかは読む）
struct S34AFeed: Decodable, Equatable, Sendable {
    var selfFixed: S34ASelfFixed?
    var autoSwitch: [S34ASwitch] = []
    var tuned: [S34ATuned] = []
    var reflow: S34AReflow?
    var guideRun: S34AGuideRun?
    var healed: [S34AHealed] = []
    var prompt: S34APromptFeed?
    var nudges: [S34ANudge] = []
    var prep: [S34APrep] = []
    var tests: S34ATestProgress?

    enum CodingKeys: String, CodingKey {
        case self_fixed, auto_switch, tuned, reflow, guide_run, healed, prompt, nudges, prep, tests
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selfFixed = c.s33a(.self_fixed)
        autoSwitch = c.s33aList(.auto_switch)
        let tunedRows: [S34ATuned] = c.s33aList(.tuned)
        tuned = tunedRows.filter { !$0.name.isEmpty }
        reflow = c.s33a(.reflow)
        guideRun = c.s33a(.guide_run)
        healed = c.s33aList(.healed)
        let p: S34APromptFeed? = c.s33a(.prompt)
        if let p, !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prompt = p }
        let nudgeRows: [S34ANudge] = c.s33aList(.nudges)
        nudges = nudgeRows.filter { HomeFeeds.isID($0.id) && !$0.topic.isEmpty }
        let prepRows: [S34APrep] = c.s33aList(.prep)
        prep = prepRows.filter { !$0.meeting.isEmpty && !$0.isEmpty }
        tests = c.s33a(.tests)
    }

    /// 自動で直した数の 1 枚に出すものがあるか
    var hasFixed: Bool {
        selfFixed != nil || !autoSwitch.isEmpty || !tuned.isEmpty || reflow != nil || guideRun != nil || !healed.isEmpty
    }
}

enum S34AReply: Equatable, Sendable {
    case feed(S34AFeed)
    /// {"available":false}（写しを消して出さない）
    case none
    /// 読めない（前の写しを残す）
    case bad
}

/// 1 行（見出しと数）
struct S34ALine: Equatable, Identifiable, Sendable {
    let title: String
    let value: String
    var id: String { title }
}

enum S34ARules {
    /// 家の PC の features の名前（K34-1）
    static let feature = "s34"

    /// GET /s34 の答えを読む
    static func reply(_ data: Data) -> S34AReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .bad }
        if (object["available"] as? Bool) == false { return .none }
        guard let feed = try? JSONDecoder().decode(S34AFeed.self, from: data) else { return .bad }
        return .feed(feed)
    }

    /// 数（負の数・とても大きい数は読まない）
    static func int(_ v: Double?) -> Int? {
        guard let v, v.isFinite, v >= 0, v < 1e9 else { return nil }
        return Int(v.rounded())
    }

    static func numText(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e12 { return String(Int(d)) }
        return String(format: "%.3g", d)
    }

    /// 0〜1 は割合、1 より大きければもう % とみなす
    static func percentText(_ v: Double?) -> String? {
        guard let v, v.isFinite, v >= 0 else { return nil }
        let p = v <= 1 ? v * 100 : v
        return String(Int(p.rounded())) + "%"
    }

    /// yyyy-MM-dd → M/d（形が違えばそのまま）
    static func dayText(_ day: String) -> String {
        guard HomeFeeds.isDay(day) else { return day }
        return AppFeeds.monthDay(day)
    }

    // MARK: 自動で直した数（数だけ）

    /// 「直した 12・残り 3・戻した 1」のように、ある数だけ並べる（どれも無ければ nil）
    static func pairs(_ list: [(String, Int?)]) -> String? {
        var parts: [String] = []
        for (label, n) in list {
            if let n { parts.append(label + " " + String(n)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// 1 枚に出す行（ある鍵だけ・数だけ）
    static func fixedLines(_ feed: S34AFeed) -> [S34ALine] {
        var out: [S34ALine] = []
        if let s = feed.selfFixed {
            if let v = pairs([("直した", s.speakerFixed), ("残り", s.speakerLeft), ("戻した", s.speakerUndone)]) {
                out.append(S34ALine(title: "話し手（三つの証拠で）", value: v))
            }
            if let v = pairs([("解けた", s.reopenedSolved), ("残り", s.reopenedLeft)]) {
                out.append(S34ALine(title: "期限で閉じた問いの解き直し", value: v))
            }
            if let v = pairs([("入れた", s.vocabAdopted), ("外した", s.vocabDropped)]) {
                out.append(S34ALine(title: "聞き違いの言葉", value: v))
            }
            if let v = pairs([("解けた", s.workSolved), ("残り", s.workLeft)]) {
                out.append(S34ALine(title: "仕事の確かめ", value: v))
            }
            if let v = placeText(before: s.placeBefore, after: s.placeAfter) {
                out.append(S34ALine(title: "場所の当たり", value: v))
            }
        }
        if !feed.autoSwitch.isEmpty {
            let on = feed.autoSwitch.filter { $0.state == "on" }.count
            let shadow = feed.autoSwitch.filter { $0.state == "shadow" }.count
            let back = feed.autoSwitch.filter { $0.state == "rolled_back" }.count
            if let v = pairs([("本番", on), ("影", shadow), ("戻した", back)]) {
                out.append(S34ALine(title: "影から本番への切り替え", value: v))
            }
        }
        let moved = feed.tuned.filter(\.moved).count
        if !feed.tuned.isEmpty {
            out.append(S34ALine(title: "合わせ直した仮の数", value: String(moved) + " 個"))
        }
        if let r = feed.reflow, let v = pairs([("済", r.daysDone), ("残り", r.daysLeft)]) {
            let last: String = r.lastDay.map { "（最後 " + dayText($0) + "）" } ?? ""
            out.append(S34ALine(title: "過去の日の流し直し（日）", value: v + last))
        }
        if let g = feed.guideRun {
            out.append(S34ALine(title: "週 1 回の読み直し", value: guideText(g)))
        }
        if !feed.healed.isEmpty {
            let ok = feed.healed.filter { $0.ok == true }.count
            out.append(S34ALine(title: "自分で直した止まり", value: String(feed.healed.count) + " 回（うまくいった " + String(ok) + "）"))
        }
        return out
    }

    /// 場所の当たり（前 → 後）。0〜1 なら %
    static func placeText(before: Double?, after: Double?) -> String? {
        let both: [Double] = [before, after].compactMap { $0 }
        // どちらかが 0〜1 の小数なら、両方を割合とみなす（0 と 0.5 が「0 → 50%」にならないように）
        let ratio: Bool = both.allSatisfy { $0 >= 0 && $0 <= 1 } && both.contains { $0 != $0.rounded() }
        let b = before.flatMap { placeNum($0, ratio: ratio) }
        let a = after.flatMap { placeNum($0, ratio: ratio) }
        if let b, let a { return b + " → " + a }
        if let a { return "いま " + a }
        if let b { return "前 " + b }
        return nil
    }

    private static func placeNum(_ v: Double, ratio: Bool) -> String? {
        guard v.isFinite, v >= 0 else { return nil }
        return ratio ? percentText(v) : numText(v)
    }

    /// 「11/23 にできた（定額の枠）・先週外した例 3・足した決まり 2」。一度もできていなければ「まだ」
    static func guideText(_ g: S34AGuideRun) -> String {
        var parts: [String] = []
        if let last = g.lastOK, !last.isEmpty {
            let day: String = HomeFeeds.isDay(String(last.prefix(10))) ? dayText(String(last.prefix(10))) : last
            parts.append(day + " にできた" + byText(g.by))
        } else {
            parts.append("まだできていない")
        }
        if let m = g.missesUsed { parts.append("先週外した例 " + String(m)) }
        if let r = g.rulesAdded { parts.append("足した決まり " + String(r)) }
        return parts.joined(separator: "・")
    }

    static func byText(_ by: String?) -> String {
        switch by ?? "" {
        case "subscription": "（定額の枠）"
        case "rules": "（規則の版）"
        case "app_task": "（アプリの予約タスク）"
        default: ""
        }
    }

    /// 1 枚の頭の 1 行（いくつ直したか）
    static func fixedHeadline(_ feed: S34AFeed) -> String? {
        guard feed.hasFixed else { return nil }
        var total = 0
        if let s = feed.selfFixed {
            total += (s.speakerFixed ?? 0) + (s.reopenedSolved ?? 0) + (s.vocabAdopted ?? 0) + (s.workSolved ?? 0)
        }
        total += feed.autoSwitch.filter { $0.state == "on" }.count
        total += feed.tuned.filter(\.moved).count
        total += feed.healed.filter { $0.ok == true }.count
        let week: String = feed.selfFixed?.week.map { dayText($0) + " の週" } ?? "今週"
        return week + "、聞かずに直した・解いた数 " + String(total)
    }

    // MARK: 円5 テストの進み

    /// 「テスト 120/300 済・不可 5・待ち 10・今日 +12・このままだと 12/10 に終わる見込み」
    static func testsLine(_ t: S34ATestProgress?) -> String? {
        guard let t else { return nil }
        var parts: [String] = []
        if let done = t.done, let total = t.total, total > 0 {
            parts.append("テスト " + String(done) + "/" + String(total) + " 済")
        } else if let done = t.done {
            parts.append("テスト " + String(done) + " 済")
        } else if let total = t.total {
            parts.append("テスト 全 " + String(total))
        }
        if let ng = t.ng, ng > 0 { parts.append("不可 " + String(ng)) }
        if let w = t.waiting, w > 0 { parts.append("待ち " + String(w)) }
        if let today = t.today { parts.append("今日 +" + String(today)) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "・")
    }

    /// 終わる見込みの 1 行（無ければ nil）
    static func finishLine(_ t: S34ATestProgress?) -> String? {
        guard let g = t?.finishGuess, !g.isEmpty else { return nil }
        let day: String = HomeFeeds.isDay(g) ? dayText(g) : g
        return "このままだと " + day + " ごろに終わる見込み"
    }

    /// 残りの数（済・不可を引いたもの。分からなければ nil）
    static func left(_ t: S34ATestProgress?) -> Int? {
        guard let t, let total = t.total, let done = t.done else { return nil }
        return max(0, total - done - (t.ng ?? 0))
    }
}

// MARK: - 円2 頼み方を 1 つに

enum S34APrompt {
    /// 写しの文を使ってよい古さ（日が書いていないとき。仮 24 時間）
    static let freshFor: TimeInterval = 86400

    /// その日の頼み方。届いた 1 つの文が同じ日のもの（日が無ければ 24 時間以内に受け取ったもの）ならそれ、ほかは nil
    static func pick(_ feed: S34APromptFeed?, day: String, fetchedAt: Date?, now: Date) -> String? {
        guard let feed else { return nil }
        let text = feed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let d = feed.day, !d.isEmpty { return d == day ? text : nil }
        guard let fetchedAt, now.timeIntervalSince(fetchedAt) < freshFor else { return nil }
        return text
    }
}

// MARK: - 円4 会議の前の 1 枚

enum S34APrepRules {
    /// 出す間（会議の 1 時間あとまで・36 時間先まで。仮）
    static let after: TimeInterval = 3600
    static let ahead: TimeInterval = 36 * 3600

    /// これからの会議（時刻が読めないものは最後に・時刻の順）
    static func upcoming(_ list: [S34APrep], now: Date) -> [S34APrep] {
        var timed: [(prep: S34APrep, at: Date)] = []
        var untimed: [S34APrep] = []
        for p in list {
            if let s = p.at, let d = S27WRules.date(s) {
                let dt = d.timeIntervalSince(now)
                if dt >= -after && dt <= ahead { timed.append((p, d)) }
            } else {
                untimed.append(p)
            }
        }
        timed.sort { $0.at < $1.at }
        let ordered: [S34APrep] = timed.map { $0.prep }
        return ordered + untimed
    }

    /// 「明日 10:00」「今日 15:30」（読めなければそのまま）
    static func whenText(_ at: String?, now: Date, calendar: Calendar = .current) -> String? {
        guard let at, !at.isEmpty else { return nil }
        guard let d = S27WRules.date(at) else { return at }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = calendar.timeZone
        f.dateFormat = "H:mm"
        let time = f.string(from: d)
        if calendar.isDate(d, inSameDayAs: now) { return "今日 " + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: tomorrow) {
            return "明日 " + time
        }
        f.dateFormat = "M/d H:mm"
        return f.string(from: d)
    }
}

// MARK: - 円3 次の一手

enum S34ANudgeRules {
    /// 出す数（仮 5）
    static let limit = 5

    /// 長く止まっているものから（同じなら届いた順）
    static func sorted(_ list: [S34ANudge]) -> [S34ANudge] {
        let indexed: [(n: S34ANudge, i: Int)] = list.enumerated().map { ($0.element, $0.offset) }
        let s = indexed.sorted { a, b in
            let da = a.n.days ?? -1, db = b.n.days ?? -1
            return da != db ? da > db : a.i < b.i
        }
        let out: [S34ANudge] = s.map { $0.n }
        return Array(out.prefix(limit))
    }

    /// 「見本 太郎・4 日」
    static func meta(_ n: S34ANudge) -> String? {
        var parts: [String] = []
        if let w = n.who, !w.isEmpty { parts.append(w) }
        if let d = n.days { parts.append(String(d) + " 日止まっている") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

// MARK: - 円1 写真から仕事のまとめを見つける（K34-3）

/// 1 枚の写真から読んだ文字（端末の中だけ）
struct S34AShot: Equatable, Sendable {
    let id: String
    let at: Date
    let text: String
}

enum S34APhotoRules {
    /// 続けて撮った写真を 1 つのまとめにする間（仮 3 分）
    static let groupGap: TimeInterval = 180
    /// 撮ってから読むまで待つ間（続きの写真がそろうまで。仮 2 分）
    static let settle: TimeInterval = 120
    /// さかのぼる日数（仮 3 日）
    static let lookBack: TimeInterval = 3 * 86400
    /// 1 回に読む写真の数（仮 20）
    static let perRun = 20
    /// 覚えておく写真の数（同じ写真を 2 回読まない）
    static let rememberLimit = 1000

    /// 頼み方そのもの（写真に頼みと答えが両方写っているときは、頼みの最後の行より後ろだけを使う）の印
    static let promptMarks: [String] = [
        "答えてください", "下の形", "HH:MM", "HH：MM", "（誰から／いつまで）", "(誰から/いつまで)", "名前、名前", "チーム名＞チャネル名",
        "見出しは下の", "聞き返さない",
    ]

    /// 【 】などのかっこで始まる見出しの行だけを見出しと数える（ふつうの文の「決まったこと：」は数えない）
    static func strictHeader(_ line: String) -> WorkDigestParser.Part? {
        let compact = WorkDigestParser.compact(WorkDigestParser.tidy(line))
        guard let first = compact.first, WorkDigestParser.openers.contains(first) else { return nil }
        return WorkDigestParser.header(compact)?.part
    }

    /// 文に写っている見出しの種類
    static func heads(_ text: String) -> Set<WorkDigestParser.Part> {
        var out: Set<WorkDigestParser.Part> = []
        for raw in text.components(separatedBy: .newlines) {
            if let p = strictHeader(raw) { out.insert(p) }
        }
        return out
    }

    /// 仕事のまとめらしいか: 日付のほかに見出しが 2 種類以上、または日付と見出しが 1 種類以上
    static func looksLikeDigest(_ heads: Set<WorkDigestParser.Part>) -> Bool {
        let others = heads.subtracting([.date]).count
        return others >= 2 || (heads.contains(.date) && others >= 1)
    }

    /// 箇条書きの行の数（見出しの無い続きの写真を、まとめの続きと見るため）
    static func bulletCount(_ text: String) -> Int {
        var n = 0
        for raw in text.components(separatedBy: .newlines) where WorkDigestParser.bulletBody(raw) != nil { n += 1 }
        return n
    }

    /// 頼み方の行を外す（頼みの印のある最後の行より後ろだけ）。頼みの印が無ければそのまま
    static func dropPrompt(_ text: String) -> String {
        let lines: [String] = text.components(separatedBy: .newlines)
        var last = -1
        for (i, line) in lines.enumerated() where promptMarks.contains(where: { line.contains($0) }) { last = i }
        guard last >= 0 else { return text }
        return lines.dropFirst(last + 1).joined(separator: "\n")
    }

    /// 続けて撮った写真の文をつなぐ（前の写真の終わりと同じ行で始まるところは 1 回だけ）
    static func join(_ texts: [String]) -> String {
        var out: [String] = []
        for text in texts {
            let lines: [String] = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let k = overlap(out, lines)
            out += lines.dropFirst(k)
        }
        return out.joined(separator: "\n")
    }

    /// a の終わりと b の始まりで重なる行の数（空白を除いて比べる・15 行まで）
    static func overlap(_ a: [String], _ b: [String], limit: Int = 15) -> Int {
        let top = min(limit, a.count, b.count)
        guard top > 0 else { return 0 }
        for k in stride(from: top, through: 1, by: -1) {
            var same = true
            for j in 0..<k where WorkDigestParser.compact(a[a.count - k + j]) != WorkDigestParser.compact(b[j]) {
                same = false
                break
            }
            if same { return k }
        }
        return 0
    }

    /// 写真を、まとめごとの組に分ける（古い順に並べてから）。
    /// 見出しのある写真で組を始め、gap 以内に続けて撮った写真は、見出しがあるか箇条書きが 2 行以上あれば同じ組に入れる。
    /// 組の見出しを合わせて looksLikeDigest なら、その組を返す（ほかの写真は捨てる）
    static func groups(_ shots: [S34AShot], gap: TimeInterval = groupGap) -> [[S34AShot]] {
        let sorted = shots.sorted { $0.at < $1.at }
        var out: [[S34AShot]] = []
        var current: [S34AShot] = []

        func close() {
            if !current.isEmpty {
                var all: Set<WorkDigestParser.Part> = []
                for s in current { all.formUnion(heads(dropPrompt(s.text))) }
                if looksLikeDigest(all) { out.append(current) }
            }
            current = []
        }

        for s in sorted {
            let body = dropPrompt(s.text)
            let h = heads(body)
            if let last = current.last, s.at.timeIntervalSince(last.at) <= gap, !h.isEmpty || bulletCount(body) >= 2 {
                current.append(s)
                continue
            }
            close()
            if !h.isEmpty { current = [s] }
        }
        close()
        return out
    }

    /// 1 つの組の文（頼み方の行を外し、重なりを除いてつないだもの）
    static func text(of group: [S34AShot]) -> String {
        join(group.sorted { $0.at < $1.at }.map { dropPrompt($0.text) })
    }

    /// 取り込む日ごとの文。【日付】が 2 つ以上あれば日ごとに分け、1 つなら【日付】の日、無ければ撮った日
    static func days(_ text: String, takenAt: Date, calendar: Calendar = .current) -> [(day: String, text: String)] {
        let cleaned = WorkDigestParser.clean(text)
        guard !cleaned.isEmpty else { return [] }
        let split = WorkDigestParser.splitDays(cleaned, today: takenAt)
        if split.count >= 2 { return split }
        let day: String = WorkDigestParser.parse(cleaned, today: takenAt).day ?? dayKey(takenAt, calendar: calendar)
        return [(day, cleaned)]
    }

    static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 探し始める時刻: 前に見た所・3 日前・スイッチを入れた 1 日前のいちばん遅いもの
    static func since(last: Date?, onAt: Date?, now: Date) -> Date {
        var s = now.addingTimeInterval(-lookBack)
        if let onAt { s = max(s, onAt.addingTimeInterval(-86400)) }
        if let last { s = max(s, last) }
        return s
    }

    /// 1 回に読んだ写真のうち、続きがまだあるかもしれない終わりの組は次の回に回す（読んだ数が上限のときだけ。組が全部なら回さない）
    static func held(_ shots: [S34AShot], full: Bool, gap: TimeInterval = groupGap) -> (now: [S34AShot], later: [S34AShot]) {
        let sorted = shots.sorted { $0.at < $1.at }
        guard full, sorted.count >= 2 else { return (sorted, []) }
        var cut = sorted.count - 1
        while cut > 0, sorted[cut].at.timeIntervalSince(sorted[cut - 1].at) <= gap { cut -= 1 }
        guard cut > 0 else { return (sorted, []) }
        return (Array(sorted[..<cut]), Array(sorted[cut...]))
    }

    /// 覚えた写真の id（新しいほうから limit まで）
    static func remembered(_ old: [String], adding: [String], limit: Int = rememberLimit) -> [String] {
        var out: [String] = old.filter { !adding.contains($0) }
        out.append(contentsOf: adding)
        return Array(out.suffix(limit))
    }
}

// MARK: - どこ？に足す画面（S33AWhere.entries の後ろに足す）

enum S34AWhere {
    static let entries: [S33AWhereEntry] = [
        S33AWhereEntry(id: "s34Fixed", name: "自動で直した数", aliases: ["自動", "直した数", "聞かずに直した", "本番", "影", "戻した", "流し直し",
                                                              "読み直し", "仮の数", "止まりを直した"],
                       place: "設定と点検", target: .view("s34Fixed")),
        S33AWhereEntry(id: "s34WorkPhoto", name: "写真から仕事のまとめを拾う", aliases: ["写真", "撮るだけ", "スクショ", "職場の画面", "自動で取り込む"],
                       place: "仕事", target: .view("s34WorkPhoto")),
        S33AWhereEntry(id: "s34Nudges", name: "止まっている話の次の一手", aliases: ["催促", "下書き", "相手待ち", "次の一手", "止まっている"],
                       place: "仕事", target: .tab(.work)),
        S33AWhereEntry(id: "s34Tests", name: "テストの進み", aliases: ["テスト", "uat", "受入", "残り", "終わる日"], place: "仕事", target: .tab(.work)),
        S33AWhereEntry(id: "s34Prep", name: "会議の前の 1 枚", aliases: ["会議", "明日の会議", "聞かれそう", "自己点検", "宿題"], place: "仕事",
                       target: .tab(.work)),
    ]
}

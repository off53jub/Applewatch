import Foundation
import Observation
import SwiftUI

/// 母艦（家の PC の D:\Lifelog）のやること（2026-11-09）。
/// やることが「アプリのタスク」「母艦の TODO」「Teams」の3か所に分かれていて、どこを見ればよいか分からなかったので、
/// アプリのタスクを見る場所に決め、母艦の TODO もここに出す。母艦の TODO.md を書くのは母艦だけで、
/// アプリは家の PC の GET /todo で読み、「済み」は POST /todo/done で知らせる（母艦が15分ごとに TODO.md に反映する）。
/// 読んだものは `mothership-todo.json`（端末ごと・同期しない・新しいファイル）に覚え、家の PC につながらないときも出す。
struct MothershipTodo: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    var project: String? = nil
    var work: Bool? = nil
    var added: String? = nil
    var due: String? = nil
    /// 母艦の毎朝のまとめが「もう済んだかも」とした理由（2026-11-09。無ければ nil）
    var maybeDone: String? = nil
    /// 返事・結果を待っている相手の名前（2026-11-12。無ければ nil。会う前のおさらいに使う）
    var waitingFor: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, text, project, work, added, due, maybeDone = "maybe_done", waitingFor = "waiting_for"
    }
}

struct MothershipExport: Codable, Equatable, Sendable {
    /// 今日の三つの1つ。2026-11-10 から、解き方（how・minutes・draft）と、どこから来たか（origin）も付く（古い家の PC には無い）
    struct Three: Codable, Equatable, Sendable {
        let id: String
        let text: String
        var why: String? = nil
        /// 解き方の手順（1〜4つ）
        var how: [String]? = nil
        /// だいたいの時間（分）
        var minutes: Int? = nil
        /// 送る文の下書き
        var draft: String? = nil
        /// "todo"（家の PC のやること）・"app"（アプリのタスク）・"decision"・"new"
        var origin: String? = nil
        var work: Bool? = nil
        /// origin が "app" のとき、アプリのタスクの元の文（これで見つける。無ければ text）
        var itemText: String? = nil

        enum CodingKeys: String, CodingKey {
            case id, text, why, how, minutes, draft, origin, work, itemText = "item_text"
        }

        /// アプリのタスクのことか（id は家の PC の印なので、家の PC に「済み」を送らない）
        var isAppTask: Bool { origin == "app" }
    }

    /// 今日の三つをどう選んだか（2026-11-10）。"codex" は今の様子と照らして選んだもの、"machine" は決まった選び方
    struct Plan: Codable, Equatable, Sendable {
        var source: String? = nil
        var generatedAt: String? = nil
        /// どの日の分か（yyyy-MM-dd）
        var day: String? = nil

        enum CodingKeys: String, CodingKey {
            case source, generatedAt = "generated_at", day
        }
    }

    /// 家の PC が作った1日のまとめ（2026-11-10。新しい日から3日分まで）
    struct DaySummary: Codable, Equatable, Sendable {
        struct Part: Codable, Equatable, Sendable {
            var heading: String
            var lines: [String] = []

            enum CodingKeys: String, CodingKey { case heading, lines }
        }

        var day: String
        var generatedAt: String? = nil
        var summary: String = ""
        var sections: [Part] = []

        enum CodingKeys: String, CodingKey {
            case day, generatedAt = "generated_at", summary, sections
        }
    }

    var generatedAt: String? = nil
    var todayThree: [Three] = []
    var items: [MothershipTodo] = []
    var plan: Plan? = nil
    var daySummaries: [DaySummary]? = nil

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at", todayThree = "today_three", items, plan, daySummaries = "day_summaries"
    }

    init(generatedAt: String? = nil, todayThree: [Three] = [], items: [MothershipTodo] = [],
         plan: Plan? = nil, daySummaries: [DaySummary]? = nil) {
        self.generatedAt = generatedAt
        self.todayThree = todayThree
        self.items = items
        self.plan = plan
        self.daySummaries = daySummaries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
        todayThree = (try? c.decodeIfPresent([Three].self, forKey: .todayThree)) ?? []
        items = try c.decode([MothershipTodo].self, forKey: .items)
        // 新しい項目は、形が違っても全体を読めなくしない
        plan = try? c.decodeIfPresent(Plan.self, forKey: .plan)
        daySummaries = try? c.decodeIfPresent([DaySummary].self, forKey: .daySummaries)
    }

    /// 今の様子と照らして選んだ「今日の三つ」か（day の日の分。plan が無い・"machine"・ほかの日の分なら false）
    func chosenFromSituation(day: String) -> Bool {
        guard let plan, plan.source == "codex" else { return false }
        return plan.day == nil || plan.day == day
    }

    /// その日の1日のまとめ（無ければ nil）
    func daySummary(_ day: String) -> DaySummary? {
        (daySummaries ?? []).first { $0.day == day && !$0.isEmpty }
    }

    /// GET /todo の答えを読む。母艦にまだ無い（available が false）・形が違うときは nil
    nonisolated static func parse(_ data: Data) -> MothershipExport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["available"] as? Bool != false,
              let export = try? JSONDecoder().decode(MothershipExport.self, from: data) else { return nil }
        // 空の文・おかしな id は出さない
        var out = export
        out.items = export.items.filter { Self.validID($0.id) && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        out.todayThree = export.todayThree.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map { three in
            var t = three
            let steps = (three.how ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            t.how = steps.isEmpty ? nil : Array(steps.prefix(6))
            if let m = three.minutes, m <= 0 { t.minutes = nil }
            if let d = three.draft, d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { t.draft = nil }
            return t
        }
        if let summaries = export.daySummaries {
            let kept = summaries.filter { TaskBook.dueDate($0.day) != nil && !$0.isEmpty }
            out.daySummaries = kept.isEmpty ? nil : kept
        }
        return out
    }

    nonisolated static func validID(_ id: String) -> Bool {
        id.count == 12 && id.allSatisfy { $0.isHexDigit }
    }

    /// 期限の「yyyy-MM-dd」→ その日の0時
    nonisolated static func dueDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return TaskBook.dueDate(text)
    }
}

// 新しい項目は、形が違っても（数が文字になっている など）その項目だけ捨てて読む
extension MothershipExport.Three {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        why = try? c.decodeIfPresent(String.self, forKey: .why)
        how = try? c.decodeIfPresent([String].self, forKey: .how)
        if let n = try? c.decodeIfPresent(Int.self, forKey: .minutes) {
            minutes = n
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .minutes) {
            minutes = Int(d.rounded())
        }
        draft = try? c.decodeIfPresent(String.self, forKey: .draft)
        origin = try? c.decodeIfPresent(String.self, forKey: .origin)
        work = try? c.decodeIfPresent(Bool.self, forKey: .work)
        itemText = try? c.decodeIfPresent(String.self, forKey: .itemText)
    }
}

extension MothershipExport.DaySummary {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
        let paragraph: String? = try? c.decodeIfPresent(String.self, forKey: .summary)
        summary = paragraph ?? ""
        let parts: [Part]? = try? c.decodeIfPresent([Part].self, forKey: .sections)
        sections = parts ?? []
    }

    /// 中身が無いか
    var isEmpty: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sections.contains { !$0.cleanLines.isEmpty }
    }

    /// ドキュメントの「1日のまとめ」の下に書く本文（まとめの文 → 見出しごとの行）。
    /// 行は「・」で始める（「09:03 …」のままだと、文字起こしの行と見分けられず、あとで消すときに途中で止まる）
    var docBody: String {
        var body = ""
        // まとめの文の行が時刻で始まると、会話の見出しと見分けられないので「・」を付ける
        for line in summary.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            body += (t.first?.isNumber == true ? "・" + t : t) + "\n"
        }
        for part in sections {
            let lines = part.cleanLines
            guard !lines.isEmpty else { continue }
            let heading = part.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            body += (heading.isEmpty ? "そのほか" : heading) + "\n" + lines.map { "・" + $0 + "\n" }.joined()
        }
        body += "（家の PC が作ったまとめです）\n\n"
        return body
    }

    /// 朝の「昨日の流れ」に使う行（「流れ」「出来事」の見出しの行。無ければ最初の見出しの行）
    var flow: [String] {
        let parts = sections.filter { !$0.cleanLines.isEmpty }
        let main = parts.first { $0.heading.contains("流れ") || $0.heading.contains("出来事") }
            ?? parts.first { !$0.heading.contains("決ま") }
        if let main { return main.cleanLines }
        let paragraph = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return paragraph.isEmpty ? [] : [paragraph]
    }

    /// 決まったこと（「決ま」の見出しの行）
    var decisions: [String] {
        sections.first { $0.heading.contains("決ま") }?.cleanLines ?? []
    }
}

extension MothershipExport.DaySummary.Part {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title: String? = try? c.decodeIfPresent(String.self, forKey: .heading)
        heading = title ?? ""
        let rows: [String]? = try? c.decodeIfPresent([String].self, forKey: .lines)
        lines = rows ?? []
    }

    /// 空の行を除き、頭の「・」「-」を外した行
    var cleanLines: [String] {
        lines.map { line in
            var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = t.first, "・-*•".contains(first) { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return t
        }.filter { !$0.isEmpty }
    }
}

/// アプリのタスクと家の PC のやることを1つの一覧にする（2026-11-10）。
/// 同じものらしいときはアプリのタスクだけを出す。迷うときは両方出す（見落とすより、2つ見える方がよい）
enum OneTaskList {
    /// 比べるための形（全角・半角や大文字・小文字をそろえ、空白・句読点・「〜する」の揺れを除く）
    static func normalized(_ text: String) -> String {
        TaskBook.key(text.precomposedStringWithCompatibilityMapping.lowercased())
    }

    /// 同じやることか（TaskBook.similar より厳しめ）。
    /// 形をそろえて同じ／短い方が4文字以上で、長い方の半分以上あり、長い方に含まれる／2文字ずつの重なりが7割以上
    static func same(_ a: String, _ b: String) -> Bool {
        sameKey(normalized(a), normalized(b))
    }

    /// same の、もう形をそろえた文どうし
    static func sameKey(_ x: String, _ y: String) -> Bool {
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let short = min(x.count, y.count), long = max(x.count, y.count)
        if short >= 4, short * 2 >= long, x.contains(y) || y.contains(x) { return true }
        guard short >= 4 else { return false }
        return overlap(x, y) >= 0.7
    }

    /// 2文字ずつに切ったものの重なり（0〜1）
    static func overlap(_ x: String, _ y: String) -> Double {
        func grams(_ s: String) -> Set<String> {
            let c = Array(s)
            guard c.count >= 2 else { return [s] }
            return Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
        }
        let g = grams(x), h = grams(y)
        let union = g.union(h).count
        return union == 0 ? 0 : Double(g.intersection(h).count) / Double(union)
    }

    /// 家の PC のやることに当たるアプリのタスク（無ければ nil）
    static func match(_ text: String, in tasks: [TaskBook.Item]) -> TaskBook.Item? {
        let y = normalized(text)
        return tasks.first { sameKey(normalized($0.what), y) }
    }

    /// アプリのタスクと重ならない、家の PC のやること（並びはそのまま。タスクの形は1回だけそろえる）
    static func extra(_ home: [MothershipTodo], tasks: [TaskBook.Item]) -> [MothershipTodo] {
        let keys = tasks.map { normalized($0.what) }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return home }
        return home.filter { item in
            let y = normalized(item.text)
            return !keys.contains { sameKey($0, y) }
        }
    }

    /// アプリで済みにしたタスクに当たる、家の PC のやること（since より後に済んだものだけ）
    static func doneByApp(_ home: [MothershipTodo], tasks: [TaskBook.Item], since: Date) -> [MothershipTodo] {
        let finished = tasks.filter { $0.state == .done && ($0.doneAt ?? .distantPast) >= since }
        guard !finished.isEmpty else { return [] }
        let open = tasks.filter { $0.state == .open || $0.state == .candidate }
        // まだのタスクにも当たるもの（同じ文のタスクが2つある など）は迷うので送らない
        return home.filter { match($0.text, in: finished) != nil && match($0.text, in: open) == nil }
    }

    /// 期限で分ける（タスクと同じ並び）
    static func bucket(_ item: MothershipTodo, now: Date, calendar: Calendar = .current) -> TaskBook.Bucket {
        guard let due = MothershipExport.dueDate(item.due) else { return .someday }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case ..<0: return .late
        case 0: return .today
        case 1...7: return .week
        default: return .later
        }
    }
}

@MainActor
@Observable
final class MothershipBook {
    struct Saved: Codable {
        var export: MothershipExport?
        var fetchedAt: Date?
        /// アプリで済みにした id と時刻（母艦の一覧から消えるまで出さない。7日で忘れる）
        var done: [String: Date] = [:]
        /// まだ家の PC に知らせていない済み（id → 文）
        var pending: [String: String] = [:]
        /// 知らせる種類（id → "wrong"・"notyet"。無ければ済み。2026-11-09。前の版のファイルには無い）
        var kinds: [String: String]? = nil
        /// 「済みでは？」に「まだ」と答えた id と時刻（母艦が印を外すまで聞かない。2026-11-09）
        var cleared: [String: Date]? = nil
    }

    private(set) var export: MothershipExport?
    private(set) var fetchedAt: Date?
    private(set) var done: [String: Date] = [:]
    private var pending: [String: String] = [:]
    private var kinds: [String: String] = [:]
    private(set) var cleared: [String: Date] = [:]
    /// 読み込めたか（読む前には保存しない）
    private var loaded = false
    private(set) var lastError: String?
    private var fetching = false

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("mothership-todo.json")
    /// 母艦は15分ごとに作り直すので、それより短くは聞かない
    static let refreshEvery: TimeInterval = 10 * 60

    init() {
        load()
        // 1つの一覧にした日を覚える（これより前に済んだタスクでは「済み」を送らない）
        _ = Self.oneListSince
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else {
            loaded = true
            return
        }
        if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            export = saved.export
            fetchedAt = saved.fetchedAt
            done = saved.done
            pending = saved.pending
            kinds = saved.kinds ?? [:]
            cleared = saved.cleared ?? [:]
            loaded = true
        } else {
            // 読めないファイルは上書きせず脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("mothership-todo-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
            loaded = true
        }
    }

    private func save() {
        guard loaded else { return }
        let saved = Saved(export: export, fetchedAt: fetchedAt, done: done, pending: pending, kinds: kinds, cleared: cleared)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// まだ済んでいないもの（scope で仕事・仕事以外に絞る。work の無いものは仕事とみなさない）
    func open(_ scope: TaskBook.Scope) -> [MothershipTodo] {
        let items = (export?.items ?? []).filter { done[$0.id] == nil }
        let filtered: [MothershipTodo]
        switch scope {
        case .all: filtered = items
        case .work: filtered = items.filter { $0.work == true }
        case .life: filtered = items.filter { $0.work != true }
        }
        return Self.sorted(filtered)
    }

    /// アプリのタスクと重ならない、まだのもの（タスクの「やる」に、アプリのタスクと混ぜて出す。2026-11-10）。
    /// 比べるのは、まだのタスクと確かめ待ち（方は問わない。同じものが別の方に見えないように）
    func extra(_ scope: TaskBook.Scope, tasks: [TaskBook.Item]) -> [MothershipTodo] {
        let live = tasks.filter { $0.state == .open || $0.state == .candidate }
        return OneTaskList.extra(open(scope), tasks: live)
    }

    /// 1つの一覧にした日（これより前に済んだタスクでは、家の PC に「済み」を送らない）
    static let oneListSinceKey = "oneTaskListSince"
    static var oneListSince: Date {
        if let date = UserDefaults.standard.object(forKey: oneListSinceKey) as? Date { return date }
        let now = Date.now
        UserDefaults.standard.set(now, forKey: oneListSinceKey)
        return now
    }

    /// アプリのタスクを済みにしたら、同じ家の PC のやることも済みにする（2026-11-10。2日以内に済んだものだけ）
    func followAppDone(_ tasks: [TaskBook.Item], pc: HomePC) async {
        guard export != nil else { return }
        let since = max(Self.oneListSince, Date.now.addingTimeInterval(-2 * 86400))
        let matched = OneTaskList.doneByApp(open(.all), tasks: tasks, since: since)
        guard !matched.isEmpty else { return }
        for item in matched {
            done[item.id] = .now
            pending[item.id] = item.text
        }
        save()
        await flush(pc)
    }

    /// その日の家の PC の1日のまとめ（無ければ nil）
    func daySummary(_ day: String) -> MothershipExport.DaySummary? { export?.daySummary(day) }

    /// 母艦が選んだ「今日の三つ」（済みにしたものは除く）
    var todayThree: [MothershipExport.Three] {
        (export?.todayThree ?? []).filter { done[$0.id] == nil }
    }

    /// 期限のあるものを先に（近い順）、そのあとは足された日が新しい順
    nonisolated static func sorted(_ items: [MothershipTodo]) -> [MothershipTodo] {
        items.sorted { a, b in
            switch (MothershipExport.dueDate(a.due), MothershipExport.dueDate(b.due)) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.added ?? "") > (b.added ?? "")
            }
        }
    }

    /// 家の PC から読み直す（force でなければ10分に1回まで）。母艦の一覧から消えた済みは忘れる
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.features.contains("todo") else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.refreshEvery, pending.isEmpty { return }
        fetching = true
        defer { fetching = false }
        await flush(pc)
        do {
            let data = try await pc.mothershipTodo()
            guard let parsed = MothershipExport.parse(data) else {
                lastError = "家の PC のやることがまだありません"
                return
            }
            export = parsed
            fetchedAt = .now
            lastError = nil
            let ids = Set(parsed.items.map(\.id))
            done = done.filter { ids.contains($0.key) && Date.now.timeIntervalSince($0.value) < 7 * 86400 }
            // 母艦が「済みかも」の印を外したら、「まだ」を忘れる
            let maybe = Set(parsed.items.filter { $0.maybeDone != nil }.map(\.id))
            cleared = cleared.filter { maybe.contains($0.key) && Date.now.timeIntervalSince($0.value) < 14 * 86400 }
            save()
        } catch {
            lastError = "家の PC から読めませんでした"
        }
    }

    /// 済みにする（すぐ一覧から外し、家の PC に知らせる。届かなければ次に読むときにもう一度）
    func markDone(_ item: MothershipTodo, pc: HomePC) async {
        done[item.id] = .now
        pending[item.id] = item.text
        save()
        await flush(pc)
    }

    /// 「タスクではない」にする（一覧から外し、家の PC に知らせる。母艦は TODO.md から外して、同じ趣旨を足さなくなる）
    func markWrong(_ item: MothershipTodo, pc: HomePC) async {
        done[item.id] = .now
        pending[item.id] = item.text
        kinds[item.id] = "wrong"
        save()
        await flush(pc)
    }

    /// 「済みでは？」に「まだ」と答える（一覧には残す。母艦は印を「まだ」に替え、しばらく聞かない）
    func markNotYet(_ item: MothershipTodo, pc: HomePC) async {
        cleared[item.id] = .now
        pending[item.id] = item.text
        kinds[item.id] = "notyet"
        save()
        await flush(pc)
    }

    /// 「済みでは？」と聞くか（印があり、「まだ」と答えていない）
    func asksDone(_ item: MothershipTodo) -> Bool {
        item.maybeDone != nil && cleared[item.id] == nil
    }

    /// 家の PC が「違う」「まだ」を受け付けるか（古い LifeLog PC は済みしか知らない）
    func acceptsKinds(_ pc: HomePC) -> Bool { pc.features.contains("todokind") }

    /// 済みを取り消す（まだ家の PC に知らせていないものだけ）
    func undo(_ id: String) {
        guard pending[id] != nil else { return }
        pending[id] = nil
        done[id] = nil
        kinds[id] = nil
        save()
    }

    private func flush(_ pc: HomePC) async {
        guard !pending.isEmpty, pc.features.contains("todo") else { return }
        for (id, text) in pending.sorted(by: { $0.key < $1.key }) {
            let kind = kinds[id] ?? "done"
            // 古い LifeLog PC は kind を知らず、済みにしてしまうので送らない（新しくなるまで待つ）
            if kind != "done", !pc.features.contains("todokind") { continue }
            do {
                try await pc.mothershipDone(id: id, text: text, kind: kind)
                pending[id] = nil
                kinds[id] = nil
            } catch {
                break
            }
        }
        save()
    }

    var hasPending: Bool { !pending.isEmpty }
}

// MARK: - 画面

/// 家の PC のやること1行（タスクの「やる」に、アプリのタスクと同じ見た目で並べる。2026-11-10）。
/// ○で済み。左へ払うと「済み」「違う」（タスクではない）。押すとくわしく
struct MothershipRow: View {
    @Environment(Pipeline.self) private var pipeline
    let item: MothershipTodo
    @State private var showing = false
    private var book: MothershipBook { pipeline.mothership }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Task { await pipeline.mothership.markDone(item, pc: pipeline.homePC) }
            } label: {
                Image(systemName: "circle").font(.title3)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 3) {
                Button { showing = true } label: {
                    Text(item.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                }
                .buttonStyle(.borderless)
                HStack(spacing: 6) {
                    if let due = MothershipExport.dueDate(item.due) {
                        let text = Pipeline.taskDueText(due)
                        Text(text).foregroundStyle(text.hasSuffix("過ぎ") || text == "今日まで" ? Color.red : Color.orange)
                    }
                    if let project = item.project, !project.isEmpty { Text(project) }
                    if item.work != true {
                        Label("仕事以外", systemImage: "house").labelStyle(.titleAndIcon).foregroundStyle(.green)
                    }
                    if let added = item.added, added.count == 10 {
                        Text(String(added.suffix(5)).replacingOccurrences(of: "-", with: "/") + " に足した")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                // 「もう済んだかも」とされた（2026-11-09）
                if book.asksDone(item), let reason = item.maybeDone {
                    Text("済みでは？ " + reason).font(.caption).foregroundStyle(.orange)
                    HStack(spacing: 16) {
                        Button("済み") { Task { await book.markDone(item, pc: pipeline.homePC) } }
                        if book.acceptsKinds(pipeline.homePC) {
                            Button("まだ") { Task { await book.markNotYet(item, pc: pipeline.homePC) } }
                        }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
        // アプリのタスクと同じく、左へ払うと「済み」。その隣に「違う」（タスクではない。古い LifeLog PC には送れないので出さない）
        .swipeActions(edge: .trailing) {
            Button("済み") { Task { await pipeline.mothership.markDone(item, pc: pipeline.homePC) } }
                .tint(.green)
            if book.acceptsKinds(pipeline.homePC) {
                Button("違う") { Task { await book.markWrong(item, pc: pipeline.homePC) } }
                    .tint(.red)
            }
        }
        .sheet(isPresented: $showing) {
            NavigationStack { MothershipDetailView(item: item) }
                .presentationDetents([.medium, .large])
        }
    }
}

/// 家の PC のやることのくわしい中身（どこから来たかは、ここにだけ小さく出す）
struct MothershipDetailView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let item: MothershipTodo

    var body: some View {
        let book = pipeline.mothership
        Form {
            Section {
                Text(item.text)
                if let due = item.due, !due.isEmpty { LabeledContent("期限", value: due) }
                if let project = item.project, !project.isEmpty { LabeledContent("組", value: project) }
                LabeledContent("種類", value: item.work == true ? "仕事" : "仕事以外")
                if let added = item.added, !added.isEmpty { LabeledContent("足した日", value: added) }
                if let reason = item.maybeDone { LabeledContent("済みかも", value: reason) }
            } footer: {
                Text("家の PC の毎朝のまとめが、会話・LINE・メモから拾ったものです。済みにすると、家の PC のやることも済みになります。")
            }
            Section {
                Button("済みにする", systemImage: "checkmark.circle") {
                    Task { await book.markDone(item, pc: pipeline.homePC) }
                    dismiss()
                }
                if book.acceptsKinds(pipeline.homePC) {
                    Button("違う（タスクではない）", systemImage: "xmark", role: .destructive) {
                        Task { await book.markWrong(item, pc: pipeline.homePC) }
                        dismiss()
                    }
                }
            } footer: {
                Text("「違う」にすると、家の PC は同じようなものを拾わなくなります。")
            }
        }
        .navigationTitle("やること")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
        }
    }
}

/// 期限の無いものの続き（「やる」には新しいものから8件まで出す）
struct MothershipListView: View {
    @Environment(Pipeline.self) private var pipeline
    let scope: TaskBook.Scope

    var body: some View {
        let items = pipeline.mothership.extra(scope, tasks: pipeline.tasks.items)
            .filter { OneTaskList.bucket($0, now: .now) == .someday }
        List {
            ForEach(items) { MothershipRow(item: $0) }
        }
        .navigationTitle("期限なし")
        .refreshable { await pipeline.mothership.refresh(pipeline.homePC, force: true) }
    }
}

// MARK: - 家の PC の1日のまとめ（2026-11-10）

/// 家の PC のまとめをドキュメントに載せた日（`home-day-summaries.json`。日 → 家の PC が作った時刻。端末ごと・新しいファイル）。
/// 1日に1回だけ載せる。載せた日は、アプリの1日のまとめをドキュメントに書かない（中身は週・月のまとめのために作る）
enum HomeSummaryLog {
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("home-day-summaries.json")

    /// 載せた日（読めなければ nil。そのときは書かない）
    static func load() -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    static func isWritten(_ day: String) -> Bool { load()?[day] != nil }

    /// 載せたと覚える（読んでから足す。90日より前は忘れる）
    static func mark(_ day: String, generatedAt: String?) {
        guard var all = load() else { return }
        all[day] = generatedAt ?? ""
        let old = TaskBook.dayFormat.string(from: Date.now.addingTimeInterval(-90 * 86400))
        all = all.filter { $0.key >= old }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 載せる日（終わった日・まだ載せていない・中身がある。古い日から）
    static func toWrite(_ summaries: [MothershipExport.DaySummary], written: [String: String],
                                    today: String) -> [MothershipExport.DaySummary] {
        var seen = Set<String>()
        return summaries.filter { s in
            guard s.day < today, written[s.day] == nil, !s.isEmpty, !seen.contains(s.day) else { return false }
            seen.insert(s.day)
            return true
        }.sorted { $0.day < $1.day }
    }
}

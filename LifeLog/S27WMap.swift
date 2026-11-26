import Foundation

// 仕事の画面の作り直し（2026-11-26）。案件 → トピック → 課題・宿題・未決 の 3 段で、状態を色で見せる。
// 決まりはここ（画面を持たない・試しで確かめる）。画面は S27WMapViews.swift。
// - 案件＝親の案件（K2 の parent・parent_name。母艦の state/work_facts.json＝本人が言った前提から）。
//   親の無い自分の話は 1 つずつの案件。ほかの部署の話は 1 つの箱、まだ分けていないものは別の箱
// - 項目の状態: 急ぎ＝はっきりした期限が明日まで（相手待ちは除く）／自分の番／相手待ち／番が未定
// - トピックの状態: 開いている項目のいちばん悪い状態。開いているものが無ければ「落ち着いた」
// しきい値（明日まで・6 日）はどれも仮。

enum S27WState: Int, CaseIterable, Comparable, Sendable {
    case urgent, mine, theirs, unknown, calm

    static func < (a: S27WState, b: S27WState) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .urgent: "急ぎ"
        case .mine: "自分の番"
        case .theirs: "相手待ち"
        case .unknown: "番が未定"
        case .calm: "落ち着いた"
        }
    }

    /// 色だけに頼らないための形（読み上げと、色の見分けにくい人のため）
    var symbol: String {
        switch self {
        case .urgent: "exclamationmark.circle.fill"
        case .mine: "person.fill"
        case .theirs: "hourglass"
        case .unknown: "questionmark.circle"
        case .calm: "checkmark.circle"
        }
    }
}

struct S27WGroup: Identifiable, Equatable, Sendable {
    enum Section: Int, Comparable, Sendable {
        case mine, other, misc
        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var name: String
    var section: Section
    var client: String?
    /// 親の案件そのもの（その案件全体の話）の id。トピックの並びでは「案件全体の話」と出す
    var topID: String?
    var topics: [S27WProject]
}

struct S27WKindCounts: Equatable, Sendable {
    var issue = 0
    var homework = 0
    var open = 0
    var decided = 0
}

enum S27WMap {
    /// 「急ぎ」にする期限の近さ（日・仮）
    static let soonDays = 1
    /// 「長くそのまま」の印を付ける日数（仮）
    static let oldDays = 6
    /// 仕事の画面の一覧で初めに見せる件数（2026-11-26・仮）
    static let foldLimit = 3

    /// 畳んだ一覧で見せる数と隠す数
    static func fold(_ count: Int, expanded: Bool, limit: Int = foldLimit) -> (shown: Int, hidden: Int) {
        let shown = expanded ? count : min(count, limit)
        return (shown, count - shown)
    }
    static let openKinds: Set<String> = ["homework", "open", "issue"]
    static let miscID = "wc-misc"
    static let otherGroupID = "g:other"
    static let miscGroupID = "g:misc"

    // MARK: 項目・トピック

    static func state(_ item: S27WItem, today: String) -> S27WState {
        if item.ball != "them", item.dueGuess != true, let left = S27WRules.days(from: today, to: item.due), left <= soonDays {
            return .urgent
        }
        switch item.ball {
        case "me": return .mine
        case "them": return .theirs
        default: return .unknown
        }
    }

    /// 済み（写しで済み・端末で済みにした id）
    static func isDone(_ item: S27WItem, _ done: Set<String>) -> Bool { item.isDone || done.contains(item.id) }

    static func isOld(_ item: S27WItem) -> Bool { (item.ageDays ?? 0) >= oldDays }

    /// 開いている課題・宿題・未決（済みにしたものは除く）
    static func openItems(_ p: S27WProject, done: Set<String> = []) -> [S27WItem] {
        p.items.filter { openKinds.contains($0.kind ?? "") && !isDone($0, done) }
    }

    static func topicState(_ p: S27WProject, today: String, done: Set<String> = []) -> S27WState {
        openItems(p, done: done).map { state($0, today: today) }.min() ?? .calm
    }

    static func tally(_ items: [S27WItem], today: String) -> [S27WState: Int] {
        var out: [S27WState: Int] = [:]
        for i in items { out[state(i, today: today), default: 0] += 1 }
        return out
    }

    /// 開いている項目を、悪い状態 → 期限の近い順 → 古い順に
    static func sortedItems(_ items: [S27WItem], today: String) -> [S27WItem] {
        items.sorted { a, b in
            let x = state(a, today: today), y = state(b, today: today)
            if x != y { return x < y }
            let da = a.due ?? "9999", db = b.due ?? "9999"
            if da != db { return da < db }
            return (a.ageDays ?? 0) > (b.ageDays ?? 0)
        }
    }

    /// 決まったこと（新しい順）
    static func decided(_ p: S27WProject) -> [S27WItem] {
        var seen = Set<String>()
        return (p.timeline + p.items).filter { $0.kind == "decided" && seen.insert($0.id).inserted }
            .sorted { ($0.day ?? "", $0.time ?? "") > ($1.day ?? "", $1.time ?? "") }
    }

    // MARK: 案件（親）でまとめる

    static func groups(_ projects: [S27WProject]) -> [S27WGroup] {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var out: [String: S27WGroup] = [:]
        func add(_ gid: String, _ make: () -> S27WGroup, _ p: S27WProject) {
            if out[gid] == nil { out[gid] = make(); order.append(gid) }
            out[gid]?.topics.append(p)
        }
        for p in projects where p.kind != "side" {
            if p.id == miscID {
                add(miscGroupID, { S27WGroup(id: miscGroupID, name: "まだ案件に分けていないもの", section: .misc, topics: []) }, p)
            } else if p.kind == "other" {
                add(otherGroupID, { S27WGroup(id: otherGroupID, name: "ほかの部署・ほかの人の案件", section: .other, topics: []) }, p)
            } else {
                let parent = (p.parent?.isEmpty == false) ? p.parent : nil
                let top = parent ?? p.id
                let name = byID[top]?.name ?? p.parentName ?? p.name
                let client = byID[top]?.client ?? p.client
                add("g:" + top, { S27WGroup(id: "g:" + top, name: name, section: .mine, client: client, topID: top, topics: []) }, p)
            }
        }
        return order.compactMap { out[$0] }
    }

    /// 並び: 自分の案件（悪い状態 → 開いている数の多い順）→ ほかの部署 → まだ分けていない
    static func sortedGroups(_ groups: [S27WGroup], today: String, done: Set<String> = []) -> [S27WGroup] {
        groups.sorted { a, b in
            if a.section != b.section { return a.section < b.section }
            let x = groupState(a, today: today, done: done), y = groupState(b, today: today, done: done)
            if x != y { return x < y }
            return openCount(a, done: done) > openCount(b, done: done)
        }
    }

    static func groupState(_ g: S27WGroup, today: String, done: Set<String> = []) -> S27WState {
        g.topics.map { topicState($0, today: today, done: done) }.min() ?? .calm
    }

    static func openCount(_ g: S27WGroup, done: Set<String> = []) -> Int {
        g.topics.reduce(0) { $0 + openItems($1, done: done).count }
    }

    static func groupOpenItems(_ g: S27WGroup, done: Set<String> = []) -> [S27WItem] {
        g.topics.flatMap { openItems($0, done: done) }
    }

    static func topicTally(_ g: S27WGroup, today: String, done: Set<String> = []) -> [S27WState: Int] {
        var out: [S27WState: Int] = [:]
        for t in g.topics { out[topicState(t, today: today, done: done), default: 0] += 1 }
        return out
    }

    static func kindCounts(_ g: S27WGroup, done: Set<String> = []) -> S27WKindCounts {
        var c = S27WKindCounts()
        for t in g.topics {
            for i in openItems(t, done: done) {
                switch i.kind {
                case "issue": c.issue += 1
                case "homework": c.homework += 1
                default: c.open += 1
                }
            }
            c.decided += decided(t).count
        }
        return c
    }

    /// トピックの並び: 悪い状態 → 最後に動いた日の新しい順
    static func sortedTopics(_ topics: [S27WProject], today: String, done: Set<String> = []) -> [S27WProject] {
        topics.sorted { a, b in
            let x = topicState(a, today: today, done: done), y = topicState(b, today: today, done: done)
            if x != y { return x < y }
            let la = a.lastMoved ?? "", lb = b.lastMoved ?? ""
            if la != lb { return la > lb }
            return a.name < b.name
        }
    }

    /// 案件の節目（今日から先・同じ日は 1 つ・近い順に 3 つまで）
    static func milestones(_ g: S27WGroup, today: String) -> [S27WMilestone] {
        var seen = Set<String>()
        return g.topics.compactMap(\.milestone)
            .filter { (S27WRules.days(from: today, to: $0.day) ?? -1) >= 0 }
            .sorted { $0.day < $1.day }
            .filter { seen.insert($0.day).inserted }
            .prefix(3).map { $0 }
    }

    /// いちばん新しい「決まった」（案件のカードの 1 行）
    static func lastDecided(_ g: S27WGroup) -> S27WItem? {
        g.topics.flatMap { decided($0) }.max { ($0.day ?? "", $0.time ?? "") < ($1.day ?? "", $1.time ?? "") }
    }
}

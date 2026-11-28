import Foundation

// s36（2026-11-28）アプリ担当 S36A の決まり。動きは S36ABook.swift、画面は S36AViews.swift。
// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 26」（大2・大3・大4）と「追記 25 の直し」（細1）。しきい値はどれも仮。
// 取り決め（形を変えない）:
// - K36-1: 家の PC の features に "s36" があるとき GET /s36 が配る（母艦の state/s36_for_app.json）。無いときは今までどおり
// - K36-2: POST /work/photo の体に "kind"（digest・cases・bugs）。features に "workphoto30" があるときだけ付け、count は 30 まで（無ければ 12）
// - K36-3: POST /s36/stop {"id","choice":"stop"|"keep"}（features に "s36stop" があるときだけ）
// - K36-4: POST /ask-mothership に "scope":"work"（features に "askwork" があるときだけ）
// 中身はどれも端末の中だけ（ウィジェット・通知・時計に出さない。Tally は数と種類の名前だけ）。

// MARK: - K36-1 アプリに配るもの（GET /s36）

/// 番号と文（"W-12" と 1 行）
struct S36ARef: Decodable, Equatable, Sendable {
    var ref: String
    var text: String

    enum CodingKeys: String, CodingKey { case ref, text }

    init(ref: String, text: String) {
        self.ref = ref
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = (c.s27w(.ref) as String?) ?? ""
        text = (c.s27w(.text) as String?) ?? ""
    }
}

/// 頼み方（最初に 1 回置く文・毎日の 1 語）
struct S36APrompt: Decodable, Equatable, Sendable {
    var setup: String?
    var setupVersion: String?
    var daily: String?
    var openRefs: [S36ARef]

    enum CodingKeys: String, CodingKey {
        case setup, daily
        case setupVersion = "setup_version", openRefs = "open_refs"
    }

    init(setup: String? = nil, setupVersion: String? = nil, daily: String? = nil, openRefs: [S36ARef] = []) {
        self.setup = setup
        self.setupVersion = setupVersion
        self.daily = daily
        self.openRefs = openRefs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setup = c.s27w(.setup)
        setupVersion = c.s27w(.setupVersion)
        daily = c.s27w(.daily)
        openRefs = c.s27wList(.openRefs)
    }
}

/// 区分ごとの数
struct S36AArea: Decodable, Equatable, Sendable {
    var area: String
    var total: Int?
    var done: Int?

    enum CodingKeys: String, CodingKey { case area, total, done }

    init(area: String, total: Int? = nil, done: Int? = nil) {
        self.area = area
        self.total = total
        self.done = done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        area = (c.s27w(.area) as String?) ?? ""
        total = S36ARules.count(c.s27w(.total))
        done = S36ARules.count(c.s27w(.done))
    }
}

/// テストケースの表から（残り・見込み・エビデンスの抜け・区分ごと）
struct S36ACases: Decodable, Equatable, Sendable {
    var asOf: String?
    var total: Int?
    var done: Int?
    var ng: Int?
    var waiting: Int?
    var left: Int?
    var perDay: Double?
    var eta: String?
    var etaNote: String?
    var evidenceMissing: [S36ARef]
    var byArea: [S36AArea]

    enum CodingKeys: String, CodingKey {
        case total, done, ng, waiting, left, eta
        case asOf = "as_of", perDay = "per_day", etaNote = "eta_note", evidenceMissing = "evidence_missing", byArea = "by_area"
    }

    init(asOf: String? = nil, total: Int? = nil, done: Int? = nil, ng: Int? = nil, waiting: Int? = nil, left: Int? = nil,
         perDay: Double? = nil, eta: String? = nil, etaNote: String? = nil, evidenceMissing: [S36ARef] = [], byArea: [S36AArea] = []) {
        self.asOf = asOf
        self.total = total
        self.done = done
        self.ng = ng
        self.waiting = waiting
        self.left = left
        self.perDay = perDay
        self.eta = eta
        self.etaNote = etaNote
        self.evidenceMissing = evidenceMissing
        self.byArea = byArea
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = c.s27w(.asOf)
        total = S36ARules.count(c.s27w(.total))
        done = S36ARules.count(c.s27w(.done))
        ng = S36ARules.count(c.s27w(.ng))
        waiting = S36ARules.count(c.s27w(.waiting))
        left = S36ARules.count(c.s27w(.left))
        let pd: Double? = c.s27w(.perDay)
        perDay = pd.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        eta = c.s27w(.eta)
        etaNote = c.s27w(.etaNote)
        evidenceMissing = c.s27wList(.evidenceMissing)
        byArea = c.s27wList(.byArea)
    }
}

/// 不具合の一覧の 1 行
struct S36ABug: Decodable, Equatable, Sendable {
    var ref: String
    var text: String
    var state: String?
    var who: String?
    var day: String?

    enum CodingKeys: String, CodingKey { case ref, text, state, who, day }

    init(ref: String, text: String, state: String? = nil, who: String? = nil, day: String? = nil) {
        self.ref = ref
        self.text = text
        self.state = state
        self.who = who
        self.day = day
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = (c.s27w(.ref) as String?) ?? ""
        text = (c.s27w(.text) as String?) ?? ""
        state = c.s27w(.state)
        who = c.s27w(.who)
        day = c.s27w(.day)
    }
}

struct S36ABugs: Decodable, Equatable, Sendable {
    var asOf: String?
    var open: Int?
    var closed: Int?
    var items: [S36ABug]

    enum CodingKeys: String, CodingKey {
        case open, closed, items
        case asOf = "as_of"
    }

    init(asOf: String? = nil, open: Int? = nil, closed: Int? = nil, items: [S36ABug] = []) {
        self.asOf = asOf
        self.open = open
        self.closed = closed
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = c.s27w(.asOf)
        open = S36ARules.count(c.s27w(.open))
        closed = S36ARules.count(c.s27w(.closed))
        items = c.s27wList(.items)
    }
}

/// 仕事の台帳の数
struct S36ALedger: Decodable, Equatable, Sendable {
    var open: Int?
    var closed7d: Int?
    var folded: Int?
    var closedByReply7d: Int?

    enum CodingKeys: String, CodingKey {
        case open, folded
        case closed7d = "closed_7d", closedByReply7d = "closed_by_reply_7d"
    }

    init(open: Int? = nil, closed7d: Int? = nil, folded: Int? = nil, closedByReply7d: Int? = nil) {
        self.open = open
        self.closed7d = closed7d
        self.folded = folded
        self.closedByReply7d = closedByReply7d
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = S36ARules.count(c.s27w(.open))
        closed7d = S36ARules.count(c.s27w(.closed7d))
        folded = S36ARules.count(c.s27w(.folded))
        closedByReply7d = S36ARules.count(c.s27w(.closedByReply7d))
    }
}

/// 止める候補 1 つ（M2 が書く）
struct S36AStopItem: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String?
    var title: String
    var why: String?
    var saves: String?
    var state: String?
    /// おすすめ（止めても困らない見込み。母艦の s36n-Stop-Candidates.py が書く・省ける。2026-11-28。s37 の K37-3）
    var recommend: Bool?

    enum CodingKeys: String, CodingKey { case id, kind, title, why, saves, state, recommend }

    init(id: String, kind: String? = nil, title: String, why: String? = nil, saves: String? = nil, state: String? = nil,
         recommend: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.why = why
        self.saves = saves
        self.state = state
        self.recommend = recommend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (c.s27w(.title) as String?) ?? id
        kind = c.s27w(.kind)
        why = c.s27w(.why)
        saves = c.s27w(.saves)
        state = c.s27w(.state)
        recommend = c.s27w(.recommend)
    }
}

struct S36AStop: Decodable, Equatable, Sendable {
    var items: [S36AStopItem]

    enum CodingKeys: String, CodingKey { case items }

    init(items: [S36AStopItem] = []) { self.items = items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.s27wList(.items)
    }
}

struct S36ANav: Decodable, Equatable, Sendable {
    var settingsTop: [String]

    enum CodingKeys: String, CodingKey { case settingsTop = "settings_top" }

    init(settingsTop: [String] = []) { self.settingsTop = settingsTop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settingsTop = c.s27wList(.settingsTop)
    }
}

/// K36-1 全体（どの欄も省ける）
struct S36AFeed: Decodable, Equatable, Sendable {
    var version: Int?
    var generatedAt: String?
    var prompt: S36APrompt?
    var cases: S36ACases?
    var bugs: S36ABugs?
    var ledger: S36ALedger?
    var stop: S36AStop?
    var nav: S36ANav?

    enum CodingKeys: String, CodingKey {
        case version, prompt, cases, bugs, ledger, stop, nav
        case generatedAt = "generated_at"
    }

    init(version: Int? = 1, generatedAt: String? = nil, prompt: S36APrompt? = nil, cases: S36ACases? = nil, bugs: S36ABugs? = nil,
         ledger: S36ALedger? = nil, stop: S36AStop? = nil, nav: S36ANav? = nil) {
        self.version = version
        self.generatedAt = generatedAt
        self.prompt = prompt
        self.cases = cases
        self.bugs = bugs
        self.ledger = ledger
        self.stop = stop
        self.nav = nav
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.s27w(.version)
        generatedAt = c.s27w(.generatedAt)
        prompt = c.s27w(.prompt)
        cases = c.s27w(.cases)
        bugs = c.s27w(.bugs)
        ledger = c.s27w(.ledger)
        stop = c.s27w(.stop)
        nav = c.s27w(.nav)
    }
}

enum S36AReply: Equatable, Sendable {
    case feed(S36AFeed)
    /// {"available":false}（写しを消して出さない）
    case none
    /// 読めない（前の写しを残す）
    case bad
}

enum S36ARules {
    /// features の名前（K36）
    static let feature = "s36"
    static let featureStop = "s36stop"
    static let featureAskWork = "askwork"
    /// 覚えておく features（hello の前でも前の値で画面を出す）
    static let remembered: [String] = [feature, featureStop, featureAskWork, S36APhotoRules.feature30]

    nonisolated static func reply(_ data: Data) -> S36AReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .bad }
        if (object["available"] as? Bool) == false { return .none }
        guard let feed = try? JSONDecoder().decode(S36AFeed.self, from: data) else { return .bad }
        return .feed(feed)
    }

    /// 数（負の数・とても大きい数は読まない）
    nonisolated static func count(_ v: Double?) -> Int? {
        guard let v, v.isFinite, v >= 0, v < 1e9 else { return nil }
        return Int(v.rounded())
    }

    // MARK: 大2 頼み方

    /// 毎日の 1 語を使ってよい古さ（仮 3 日。古ければ今の頼み方）
    static let dailyFresh: TimeInterval = 3 * 86400

    /// 置く文の帯。前に写した版が無ければ「まず 1 回」、違えば「置き直して」、同じなら出さない
    enum SetupBand: Equatable, Sendable {
        case first
        case changed
    }

    static func setupBand(version: String?, copied: String?) -> SetupBand? {
        guard let version, !version.isEmpty else { return nil }
        guard let copied, !copied.isEmpty else { return .first }
        return copied == version ? nil : .changed
    }

    /// 毎日の 1 語（届いていて・空でなく・置く文を 1 回は写したことがあり・古すぎないとき）。だめなら nil（今の頼み方のまま）。
    /// 置く文をまだ一度も写していないときに 1 語だけを渡すと、職場の Claude は何のことか分からないので、今の長い頼み方のまま（安全な側）
    static func daily(_ prompt: S36APrompt?, copiedVersion: String?, fetchedAt: Date?, now: Date) -> String? {
        guard let prompt, let text = prompt.daily?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let setup = prompt.setup, !setup.isEmpty, let copiedVersion, !copiedVersion.isEmpty else { return nil }
        guard let fetchedAt, now.timeIntervalSince(fetchedAt) <= dailyFresh else { return nil }
        return text
    }

    /// 番号の数の 1 行
    static func refsLine(_ prompt: S36APrompt?) -> String? {
        guard let n = prompt?.openRefs.count, n > 0 else { return nil }
        return "開いている番号 \(n) 件を載せています"
    }

    // MARK: 大2 数

    /// テストケースの 1 行（「残り 118（済 182・不可 5・待ち 11／全 300）」）
    static func casesLine(_ c: S36ACases?) -> String? {
        guard let c else { return nil }
        let left: Int? = c.left ?? {
            guard let t = c.total, let d = c.done else { return nil }
            return max(0, t - d)
        }()
        var parts: [String] = []
        if let d = c.done { parts.append("済 \(d)") }
        if let n = c.ng { parts.append("不可 \(n)") }
        if let w = c.waiting { parts.append("待ち \(w)") }
        var tail: String = parts.joined(separator: "・")
        if let t = c.total { tail += (tail.isEmpty ? "" : "／") + "全 \(t)" }
        guard left != nil || !tail.isEmpty else { return nil }
        let head: String = left.map { "残り \($0)" } ?? "テストケース"
        return tail.isEmpty ? head : head + "（" + tail + "）"
    }

    /// 見込みの 1 行（いつも「仮」と書く）
    static func etaLine(_ c: S36ACases?) -> String? {
        guard let c else { return nil }
        var parts: [String] = []
        if let eta = c.eta, !eta.isEmpty {
            parts.append("終わる見込み " + AppFeeds.monthDay(eta) + "（仮）")
        } else {
            parts.append("終わる見込み まだ出せません（仮）")
        }
        if let pd = c.perDay {
            parts.append("1 日 " + numText(pd) + " 件")
        }
        if let note = c.etaNote, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: "・")
    }

    static func numText(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e9 { return String(Int(d)) }
        return String(format: "%.1f", d)
    }

    /// 区分ごとの 1 行（「見本の区分: 12 / 20」）
    static func areaLine(_ a: S36AArea) -> String {
        let done: String = a.done.map(String.init) ?? "?"
        let total: String = a.total.map(String.init) ?? "?"
        return (a.area.isEmpty ? "（区分なし）" : a.area) + ": " + done + " / " + total
    }

    static func bugsLine(_ b: S36ABugs?) -> String? {
        guard let b, b.open != nil || b.closed != nil || !b.items.isEmpty else { return nil }
        let open: Int = b.open ?? b.items.filter { !isClosed($0.state) }.count
        var s = "開いている \(open)"
        if let c = b.closed { s += "・閉じた \(c)" }
        return s
    }

    static func isClosed(_ state: String?) -> Bool {
        guard let state else { return false }
        return ["closed", "done", "済", "完了", "クローズ"].contains(state.lowercased())
    }

    static func ledgerLine(_ l: S36ALedger?) -> String? {
        guard let l else { return nil }
        var parts: [String] = []
        if let o = l.open { parts.append("開いている \(o)") }
        if let c = l.closed7d {
            var s = "7 日で閉じた \(c)"
            if let r = l.closedByReply7d, r > 0 { s += "（返事で \(r)）" }
            parts.append(s)
        }
        if let f = l.folded, f > 0 { parts.append("奥に畳んだ \(f)") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    // MARK: 大3 止める候補

    /// まだ答えていない候補（state が candidate か無いもの。端末で押したものは除く）
    static func candidates(_ stop: S36AStop?, answered: [String: String]) -> [S36AStopItem] {
        (stop?.items ?? []).filter { ($0.state ?? "candidate") == "candidate" && answered[$0.id] == nil }
    }

    /// 答えたもの・止めたもの・残したもの（見せるだけ）
    static func settled(_ stop: S36AStop?, answered: [String: String]) -> [S36AStopItem] {
        (stop?.items ?? []).filter { ($0.state ?? "candidate") != "candidate" || answered[$0.id] != nil }
    }

    static func kindLabel(_ kind: String?) -> String {
        switch kind ?? "" {
        case "build": "作り直し"
        case "claude": "Claude の頼み"
        case "notice": "知らせ"
        case "screen": "画面"
        case "source": "取り込み"
        default: "そのほか"
        }
    }

    static func stateLabel(_ item: S36AStopItem, answered: [String: String]) -> String {
        if let a = answered[item.id], (item.state ?? "candidate") == "candidate" {
            return a == "stop" ? "止めると伝えました（家の PC が次の回に止めます）" : "残すと伝えました"
        }
        switch item.state ?? "" {
        case "stopped": return "止めています（戻せます）"
        case "kept": return "残しています"
        default: return "候補"
        }
    }

    /// POST /s36/stop の体（K36-3）
    static func stopBody(id: String, choice: String) -> Data? {
        guard !id.isEmpty, choice == "stop" || choice == "keep" else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(["id": id, "choice": choice])
    }

    // MARK: 大3 よく使う設定

    /// 数えた回数の名前（countsOpen の名前）から、どこ？の目次の名前へ（名前が同じものは書かない）
    static let screenAlias: [String: String] = [
        "recordsDays": "recordsDays", "settings": "detailedSettings", "s33aWhere": "detailedSettings",
        "workDigest": "workDigest", "s30w": "work", "taskBook": "tasks",
    ]

    /// nav.settings_top の名前を、どこ？の目次の行にする（id・名前・数えた名前のどれかで当てる。当たらないものは出さない・5 つまで・仮）
    static func settingsTop(_ nav: S36ANav?, in list: [S33AWhereEntry], limit: Int = 5) -> [S33AWhereEntry] {
        guard let names = nav?.settingsTop, !names.isEmpty else { return [] }
        var out: [S33AWhereEntry] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let key: String = screenAlias[name] ?? name
            let norm: String = S33AWhere.normalize(name)
            let hit: S33AWhereEntry? = list.first { $0.id == key }
                ?? list.first { $0.name == name }
                ?? list.first { S33AWhere.normalize($0.name) == norm }
            guard let hit, !out.contains(where: { $0.id == hit.id }) else { continue }
            out.append(hit)
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - K36-2 写真の種類と枚数（細1）

enum S36APhotoKind: String, CaseIterable, Identifiable, Sendable {
    case digest, cases, bugs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .digest: "まとめ"
        case .cases: "テストケースの表"
        case .bugs: "不具合の一覧"
        }
    }

    /// まとめの文として取り込むか（表と一覧は取り込まずに写真だけ送る）
    var isDigest: Bool { self == .digest }
}

enum S36APhotoRules {
    /// 家の PC の features の名前（K36-2）
    static let feature30 = "workphoto30"

    /// 1 回に送る枚数（"workphoto30" があれば 30・無ければ今のまま 12）
    static func limit(_ features: Set<String>) -> Int {
        features.contains(feature30) ? S35PhotoRules.maxLimit : S35PhotoRules.limit
    }

    /// 種類を選べるか（"workphoto30" のときだけ kind を受ける）
    static func kindsOffered(_ features: Set<String>) -> Bool { features.contains(feature30) }

    /// 体に付ける kind（"workphoto30" が無ければ付けない）
    static func kindField(_ kind: S36APhotoKind, _ features: Set<String>) -> String? {
        kindsOffered(features) ? kind.rawValue : nil
    }

    /// 選んだ枚数が上限を超えたときの画面の中の一文（知らせではない）
    static func overflowLine(dropped: Int, limit: Int) -> String? {
        guard dropped > 0, limit > 0 else { return nil }
        return "\(limit) 枚までです。\(limit + 1) 枚目からは送っていません（\(dropped) 枚）。"
    }

    /// 表・一覧の写真を送る 1 つの仕事（まとめとは別の新しい id。POST /work/digest は送らない）
    static func tableJob(id: String, day: String, photos: [Data], kind: S36APhotoKind, features: Set<String>) -> S35PhotoJob? {
        guard !kind.isDigest, kindsOffered(features), S35PhotoRules.isUUID(id) else { return nil }
        let job = S35PhotoJob(id: id, day: day, photos: photos, cap: limit(features), kind: kind.rawValue)
        return job.count > 0 ? job : nil
    }
}

// MARK: - 大3 下の入口（今日・仕事・タスク・人 ＋ 奥）

enum S36ATabs {
    /// 「下の入口を 4 つ＋奥にする」（初めはオン。設定で前の 5 つに戻せる）
    static let onKey = "s36a.tabs.on"

    static var isOn: Bool { (UserDefaults.standard.object(forKey: onKey) as? Bool) ?? true }

    /// 新しい下の入口（左から）
    static let bar: [S30TTabs.Item] = [
        S30TTabs.Item(tab: .today, title: "今日", symbol: "waveform"),
        S30TTabs.Item(tab: .work, title: "仕事", symbol: "briefcase"),
        S30TTabs.Item(tab: .tasks, title: "タスク", symbol: "checklist"),
        S30TTabs.Item(tab: .people, title: "人", symbol: "person.2"),
        S30TTabs.Item(tab: .deep, title: "奥", symbol: "square.grid.2x2"),
    ]

    /// 奥に入れた前の入口（消していない。奥の一覧から今の画面へ行ける）
    static let movedIntoDeep: [AppTab] = [.fix, .records]

    /// 下の入口で選ばれて見えるもの。新しい形では 直す・記録・ふり返り は奥の中。前の形では S30T のまま（人は記録・奥は今日）
    static func shown(_ tab: AppTab, on: Bool) -> AppTab {
        if on {
            switch tab {
            case .fix, .records, .lookBack: return .deep
            default: return tab
            }
        }
        switch tab {
        case .people: return .records
        case .deep: return .today
        default: return S30TTabs.shown(tab)
        }
    }

    static func item(_ tab: AppTab) -> S30TTabs.Item {
        let s = shown(tab, on: true)
        for item in bar where item.tab == s { return item }
        return bar[0]
    }

    /// 奥のタブの中で見せるもの
    enum DeepPage: Equatable, Sendable {
        case list, fix, records
    }

    static func deepPage(_ tab: AppTab) -> DeepPage {
        switch tab {
        case .fix: .fix
        case .records, .lookBack: .records
        default: .list
        }
    }

    /// 下の入口が押されたとき。奥の中で前の画面を見ているときに奥をもう一度押したら、奥の一覧に戻る
    static func selected(_ new: AppTab, current: AppTab, on: Bool) -> AppTab {
        guard on else { return new }
        if new == .deep, shown(current, on: true) == .deep { return .deep }
        return new
    }

    /// PR の文と点検に出す: 前と後の入口（数と並び）
    static let beforeTitles: [String] = S30TTabs.bar.map(\.title)
    static var afterTitles: [String] { bar.map(\.title) }
}

// MARK: - どこ？に足す画面（S36A）

enum S36AWhere {
    static let entries: [S33AWhereEntry] = [
        S33AWhereEntry(id: "s36Prompt", name: "職場の Claude への頼み方（置く文・毎日の 1 語）",
                       aliases: ["頼み方", "置く文", "まとめ", "1 語", "済んだ番号", "プロジェクトの指示"], place: "仕事", target: .view("s36Prompt")),
        S33AWhereEntry(id: "s36Numbers", name: "テストケースと不具合の数", aliases: ["テストケース", "不具合", "残り", "見込み", "エビデンス", "台帳"],
                       place: "仕事", target: .view("s36Numbers")),
        S33AWhereEntry(id: "s36AskWork", name: "仕事のことを聞く", aliases: ["誰待ち", "質問", "決まったこと", "聞く"], place: "仕事",
                       target: .view("s36AskWork")),
        S33AWhereEntry(id: "s36Stop", name: "止める候補（止める・残す）", aliases: ["止める", "残す", "減らす", "やめる", "候補"],
                       place: "設定と点検", target: .view("s36Stop")),
        S33AWhereEntry(id: "s36Tabs", name: "下の入口（4 つ＋奥）", aliases: ["タブ", "入口", "奥", "前の 5 つ"], place: "設定と点検",
                       target: .view("s36Tabs")),
    ]
}

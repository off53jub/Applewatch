import Foundation

// s30（2026-11-27）仕事タブの作り直し — アプリの仕事タブ担当（S30W）の決まり（決まった入力から決まった出力だけ）。
// 画面は S30WViews.swift、動き（家の PC へ送る・作り直しを見る・箱から戻す）は S30WBook.swift、試しは LifeLogTests/S30WTests.swift。
// 取り決め（名前と形を変えない）:
// - K30-1: GET /work（S27WBoard）に省ける `report`（S30WReport）。項目（S27WItem）に省ける `auto`（"done"・"old"）と `auto_why`
// - K30-2: POST /work/digest（体は {"entries":[work-digests.json の 1 件と同じ形]}）・GET /work/run・features の "workpush"
// - K30-3: 入口は S30WTab（S30WViews.swift）
// report が無いとき（前の形）は、今ある K2 のデータから規則で 柱（言葉で割り当て）・今日の一手（急ぎ → 期限 → 古い順）・
// 道のり（milestone）を作り、同じ画面に出す（「機械の並べ方」と小さく書く）。しきい値・言葉はどれも仮。
// 新しい問い・知らせは足していない。言語モデルの呼び出しも無い。中身の文は記録（ログ）に書かない。

// MARK: - K30-1 状況の報告（母艦が作る。どの欄も省ける・読めない行は飛ばす）

/// 数字 1 つ（済・残りなど。heard は聞き取りの数＝「聞こえた数」）
struct S30WNumber: Decodable, Equatable, Sendable {
    var label: String
    var value: Double
    var unit: String?
    var day: String?
    var heard: Bool?

    enum CodingKeys: String, CodingKey { case label, value, unit, day, heard }

    init(label: String, value: Double, unit: String? = nil, day: String? = nil, heard: Bool? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.day = day
        self.heard = heard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        value = try c.decode(Double.self, forKey: .value)
        unit = c.s27w(.unit)
        day = c.s27w(.day)
        heard = c.s27w(.heard)
    }
}

/// 節目 1 つ（firm が false なら、まだ確定していない日＝「?」）
struct S30WRoadPoint: Decodable, Equatable, Sendable {
    var day: String
    var title: String
    var firm: Bool?

    enum CodingKeys: String, CodingKey { case day, title, firm }

    init(day: String, title: String, firm: Bool? = nil) {
        self.day = day
        self.title = title
        self.firm = firm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        title = try c.decode(String.self, forKey: .title)
        firm = c.s27w(.firm)
    }
}

/// 案件ごとの「いまの状況」（state は "ok"・"caution"・"stuck"）
struct S30WReportProject: Decodable, Equatable, Sendable {
    var id: String
    var name: String
    var state: String?
    var now: String?
    var moved: String?
    var snag: String?
    var evidence: [String] = []
    var numbers: [S30WNumber] = []
    var road: [S30WRoadPoint] = []

    enum CodingKeys: String, CodingKey { case id, name, state, now, moved, snag, evidence, numbers, road }

    init(id: String, name: String, state: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.s27w(.name) ?? ""
        state = c.s27w(.state)
        now = c.s27w(.now)
        moved = c.s27w(.moved)
        snag = c.s27w(.snag)
        evidence = c.s27wList(.evidence)
        numbers = c.s27wList(.numbers)
        road = c.s27wList(.road)
    }
}

/// 柱 1 つ（state は "urgent"・"mine"・"theirs"・"calm"）
struct S30WPillar: Decodable, Equatable, Sendable {
    var id: String
    var project: String?
    var name: String
    var state: String?
    var line: String?
    var topicIDs: [String] = []
    var itemIDs: [String] = []

    enum CodingKeys: String, CodingKey { case id, project, name, state, line, topicIDs = "topic_ids", itemIDs = "item_ids" }

    init(id: String, name: String, state: String? = nil, line: String? = nil, topicIDs: [String] = [], itemIDs: [String] = []) {
        self.id = id
        self.name = name
        self.state = state
        self.line = line
        self.topicIDs = topicIDs
        self.itemIDs = itemIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        project = c.s27w(.project)
        state = c.s27w(.state)
        line = c.s27w(.line)
        topicIDs = c.s27wList(.topicIDs)
        itemIDs = c.s27wList(.itemIDs)
    }
}

/// 今日の一手・相手を待っているものの 1 つ
struct S30WPick: Decodable, Equatable, Sendable {
    var itemID: String
    var why: String?

    enum CodingKeys: String, CodingKey { case why, itemID = "item_id" }

    init(itemID: String, why: String? = nil) {
        self.itemID = itemID
        self.why = why
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(String.self, forKey: .itemID)
        why = c.s27w(.why)
    }
}

/// この案件の外に見える話の 1 行
struct S30WOutside: Decodable, Equatable, Sendable {
    var label: String
    var itemIDs: [String] = []

    enum CodingKeys: String, CodingKey { case label, itemIDs = "item_ids" }

    init(label: String, itemIDs: [String] = []) {
        self.label = label
        self.itemIDs = itemIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        itemIDs = c.s27wList(.itemIDs)
    }
}

/// K30-1 の全体（`state/s30_work_status.json` と同じ形。work_for_app.json の `report`）
struct S30WReport: Decodable, Equatable, Sendable {
    var asOf: String?
    var writtenAt: String?
    /// "claude"（Claude が書いた）・"rules"（母艦の規則で書いた）
    var by: String?
    var projects: [S30WReportProject] = []
    var pillars: [S30WPillar] = []
    var next3: [S30WPick] = []
    var waiting3: [S30WPick] = []
    var outside: [S30WOutside] = []

    enum CodingKeys: String, CodingKey {
        case by, projects, pillars, next3, waiting3, outside
        case asOf = "as_of", writtenAt = "written_at"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = c.s27w(.asOf)
        writtenAt = c.s27w(.writtenAt)
        by = c.s27w(.by)
        projects = c.s27wList(.projects)
        pillars = c.s27wList(.pillars)
        next3 = c.s27wList(.next3)
        waiting3 = c.s27wList(.waiting3)
        outside = c.s27wList(.outside)
    }

    var byClaude: Bool { by == "claude" }
}

// MARK: - K30-2 共有したらすぐ作り直す（家の PC の口）

/// POST /work/digest の返事（run は "started"・"already"・"off"）
struct S30WPushReply: Decodable, Equatable, Sendable {
    var accepted: Int?
    var run: String?
    var available: Bool?

    enum CodingKeys: String, CodingKey { case accepted, run, available }

    init(accepted: Int? = nil, run: String? = nil, available: Bool? = nil) {
        self.accepted = accepted
        self.run = run
        self.available = available
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = c.s27w(.accepted)
        run = c.s27w(.run)
        available = c.s27w(.available)
    }
}

/// GET /work/run の返事（state は "idle"・"running"）
struct S30WRun: Decodable, Equatable, Sendable {
    var state: String?
    var startedAt: String?
    var finishedAt: String?
    var ok: Bool?
    var available: Bool?

    enum CodingKeys: String, CodingKey { case state, ok, available, startedAt = "started_at", finishedAt = "finished_at" }

    init(state: String?, startedAt: String? = nil, finishedAt: String? = nil, ok: Bool? = nil, available: Bool? = true) {
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.ok = ok
        self.available = available
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.s27w(.state)
        startedAt = c.s27w(.startedAt)
        finishedAt = c.s27w(.finishedAt)
        ok = c.s27w(.ok)
        available = c.s27w(.available)
    }
}

/// 仕事タブの上の帯（送っている・作り直している・終わった・間に合わなかった・今までどおり）
enum S30WBand: Equatable, Sendable {
    case sending(Date)
    case rebuilding(Date)
    case done(Date, ok: Bool)
    case late(Date)
    /// 送らなかった・送れなかった（わけの文）
    case fallback(Date, String)

    var at: Date {
        switch self {
        case .sending(let d), .rebuilding(let d), .done(let d, _), .late(let d), .fallback(let d, _): d
        }
    }

    /// まだ動いている（帯を閉じられない）
    var working: Bool {
        switch self {
        case .sending, .rebuilding: true
        default: false
        }
    }
}

// MARK: - 画面の形（report からでも、規則からでも同じ形）

enum S30WProjectState: String, Sendable {
    case ok, caution, stuck

    var label: String {
        switch self {
        case .ok: "順調"
        case .caution: "注意"
        case .stuck: "止まっている"
        }
    }
}

/// 状況の 1 枚（今どこ・動いた・引っかかり・根拠）
struct S30WCard: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var client: String?
    var state: S30WProjectState?
    var now: String?
    var moved: String?
    var snag: String?
    var evidence: [S27WItem] = []
}

/// 数字のタイル 1 つ
struct S30WTile: Equatable, Sendable {
    var value: String
    var unit: String?
    var label: String
    /// 色（状態の色を借りる。nil は色なし）
    var tone: S27WState?
    /// 小さな棒（2 つ以上のときだけ出す）
    var spark: [Double] = []
}

/// 道のりの点 1 つ（いちばん左は「今日」）
struct S30WRoadMark: Equatable, Identifiable, Sendable {
    var day: String
    var title: String
    var firm: Bool
    var isToday: Bool
    var daysLeft: Int

    var id: String { day + "|" + title }
}

/// 今日の一手・相手を待っているものの 1 行
struct S30WStep: Equatable, Identifiable, Sendable {
    var item: S27WItem
    var why: String?
    var pillar: String?
    var state: S27WState

    var id: String { item.id }
}

/// 柱 1 つの中身
struct S30WPillarView: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var project: String?
    var state: S27WState
    var line: String?
    /// 開いている件（悪い状態 → 期限 → 古い順。済み・箱のものは入れない）
    var open: [S27WItem] = []
    var counts: [S27WState: Int] = [:]
    /// 6 日（仮）以上そのままの数
    var oldCount = 0
    /// 決まったこと（新しい順）
    var decided: [S27WItem] = []
    /// 「済んだかも」の箱（auto "done"・戻していない）
    var autoDone: [S27WItem] = []
    /// 「古い」の箱（auto "old"・戻していない）
    var autoOld: [S27WItem] = []

    /// 上から 6 つ（仮）のあとに隠れる数
    var hidden: Int { max(0, open.count - S30WRules.pillarTop) }
}

/// この案件の外に見える話の 1 行
struct S30WOutsideRow: Equatable, Identifiable, Sendable {
    var label: String
    var items: [S27WItem]

    var id: String { label }
}

/// 仕事タブ 1 枚ぶん。…Ruled は「機械の並べ方」（report に無いので規則で作った）
struct S30WScreen: Equatable, Sendable {
    var hasReport = false
    var byClaude = false
    var asOf: String?
    var writtenAt: String?
    var cards: [S30WCard] = []
    var cardsRuled = false
    var tiles: [S30WTile] = []
    var road: [S30WRoadMark] = []
    var roadRuled = false
    var next3: [S30WStep] = []
    var next3Ruled = false
    /// 自分の番（急ぎ・自分の番）の数
    var mineCount = 0
    var waiting3: [S30WStep] = []
    var waitingRuled = false
    var waitingCount = 0
    var pillars: [S30WPillarView] = []
    var pillarsRuled = false
    var outside: [S30WOutsideRow] = []
    var outsideRuled = false
    /// 前の一覧の数（開いている件・トピック）
    var openTotal = 0
    var topicCount = 0

    var anyUnfirm: Bool { road.contains { !$0.firm } }
}

/// 規則で使う柱（仮・6 つ）
struct S30WRulePillar: Equatable, Sendable {
    var id: String
    var name: String
    var words: [String]
}

/// 柱に入れる前の袋（report からでも規則からでも）
struct S30WBag: Equatable, Sendable {
    var id: String
    var name: String
    var project: String?
    var state: S27WState?
    var line: String?
    var items: [S27WItem]
}

/// 規則で分けた結果（柱の id → 項目・どの柱にも入らないもの・ほかの部署の話）
struct S30WAssign: Equatable, Sendable {
    var bags: [String: [S27WItem]] = [:]
    var unassigned: [S27WItem] = []
    var other: [S27WItem] = []
}

/// 項目の id で引く表
struct S30WIndex: Sendable {
    var items: [String: S27WItem] = [:]
}

// MARK: - 決まり

enum S30WRules {
    /// 家の PC の features の名前（K30-2）
    static let featurePush = "workpush"
    /// 今日の一手・相手を待っているものの数
    static let pickLimit = 3
    /// 柱を開いたときに見せる数（仮）
    static let pillarTop = 6
    /// 規則で作る状況の 1 枚の数（仮）
    static let cardLimit = 3
    /// 道のりの「今日」のあとの点の数（仮）
    static let roadLimit = 5
    /// 規則で「止まっている」にする、動いていない日数（仮）
    static let stuckDays = 5
    /// 規則で「注意」にする、長くそのままの数（仮）
    static let cautionOld = 3
    /// 「動いた」に入れる決まったことの日数（仮）
    static let movedDays = 3
    /// 自分のタスク（仕事）を初めに見せる数（仮）
    static let taskFold = 5
    /// 保存のあと、送る分とみなす新しさ（秒・仮）
    static let freshWindow: TimeInterval = 120
    /// 1 回に送るまとめの数の上限（仮）
    static let pushLimit = 20
    /// GET /work/run を見る間（秒）と、見る長さの上限（3 分・仮）
    static let pollEvery: TimeInterval = 5
    static let pollLimit: TimeInterval = 180
    /// iPhone と家の PC の時計のずれの許し（秒・仮）
    static let runTolerance: TimeInterval = 60
    /// 終わった帯を見せておく長さ（10 分・仮）
    static let bandShowFor: TimeInterval = 600

    /// 柱（仮・6 つ。並びは画面の順）。言葉は母艦のひな形（build_mock2.py の KEYS）を広げたもの
    static let pillars: [S30WRulePillar] = [
        S30WRulePillar(id: "test", name: "テストの進み（打鍵）", words: ["打鍵", "シナリオ", "エビデンス", "テストケース", "再テスト", "テスト"]),
        S30WRulePillar(id: "bug", name: "不具合とチケット", words: ["不具合", "チケット", "バグ", "文字化け", "障害", "起票"]),
        S30WRulePillar(id: "card", name: "テスト用のカード", words: ["カード"]),
        S30WRulePillar(id: "plan", name: "日程と節目", words: ["日程", "期限", "締め", "リリース", "必達", "判定", "スケジュール",
                                                           "延期", "延ば", "前倒し", "後ろ倒し", "節目"]),
        S30WRulePillar(id: "spec", name: "仕様と画面の決めごと", words: ["仕様", "画面", "表示", "文言", "デザイン", "方針"]),
        S30WRulePillar(id: "talk", name: "報告・会議", words: ["報告", "会議", "定例", "週次", "共有", "資料", "議事録", "打ち合わせ"]),
    ]
    /// 言葉を当てる順（日程 → カード → 不具合 → テスト → 仕様 → 報告。ひな形と同じ順・仮）
    static let matchOrder = ["plan", "card", "bug", "test", "spec", "talk"]

    static let otherLabel = "ほかの部署・社内の話"
    static let unassignedLabel = "まだどの柱にも入らないもの"

    // MARK: 送れなかったときの文（小さく書く）

    static let fallbackNoDoor = "家の PC にまだ「すぐ作り直す口」が無いので、今までどおりドライブの写しから 15 分ごとに作り直します。"
    static let fallbackFailed = "家の PC に送れなかったので、今までどおりドライブの写しから 15 分ごとに作り直します。"
    static let fallbackOff = "家の PC のすぐの作り直しは止めてあります。今までどおり 15 分ごとに作り直します。"

    // MARK: 項目

    static func index(_ board: S27WBoard) -> S30WIndex {
        var idx = S30WIndex()
        for p in board.projects {
            for i in p.items where idx.items[i.id] == nil { idx.items[i.id] = i }
            for i in p.timeline where idx.items[i.id] == nil { idx.items[i.id] = i }
        }
        let lists: [[S27WItem]] = [board.today.homework, board.today.waitingOnMe, board.today.waitingOnOthers, board.today.stuckByMe]
        for list in lists {
            for i in list where idx.items[i.id] == nil { idx.items[i.id] = i }
        }
        return idx
    }

    /// 箱に入っているか（auto が "done"・"old" で、端末で戻していない）。入っていれば箱の名前
    static func boxed(_ item: S27WItem, restored: Set<String>) -> String? {
        guard let a = item.auto, a == "done" || a == "old", !restored.contains(item.id) else { return nil }
        return a
    }

    /// 開いている（課題・宿題・未決で、済みでも箱でもない）
    static func isOpen(_ item: S27WItem, done: Set<String>, restored: Set<String>) -> Bool {
        S27WMap.openKinds.contains(item.kind ?? "") && !S27WMap.isDone(item, done) && boxed(item, restored: restored) == nil
    }

    /// 札の文（今日まで・明日まで・N 日過ぎ・期限 M/D（仮）・N 日そのまま）
    static func why(_ item: S27WItem, today: String) -> String? {
        if let due = item.due, HomeFeeds.isDay(due), let left = S27WRules.days(from: today, to: due) {
            let guess: String = item.dueGuess == true ? "（仮）" : ""
            if left < 0 { return "\(-left) 日過ぎ" + guess }
            if left == 0 { return "今日まで" + guess }
            if left == 1 { return "明日まで" + guess }
            return "期限 " + AppFeeds.monthDay(due) + guess
        }
        if let age = item.ageDays, age >= 2 { return "\(age) 日そのまま" }
        return nil
    }

    /// 相手を待っているものの札（期限があれば期限、無ければ待った日数）
    static func waitWhy(_ item: S27WItem, today: String) -> String? {
        if let due = item.due, HomeFeeds.isDay(due) { return why(item, today: today) }
        if let age = item.ageDays, age >= 1 { return "\(age) 日待ち" }
        return nil
    }

    /// 項目の行の札（期限・長くそのまま・たぶん。番の札は別に出す）
    static func itemTags(_ item: S27WItem) -> [String] {
        var out: [String] = []
        if let due = item.due, HomeFeeds.isDay(due) {
            out.append("期限 " + AppFeeds.monthDay(due) + (item.dueGuess == true ? "（仮）" : ""))
        }
        if let age = item.ageDays, age >= S27WMap.oldDays { out.append("\(age) 日そのまま") }
        if item.isMaybe { out.append("たぶん") }
        return out
    }

    /// 柱と項目の状態の札（ひな形の言葉）
    static func pillarLabel(_ s: S27WState) -> String {
        switch s {
        case .urgent: "急ぎ"
        case .mine: "自分の番"
        case .theirs: "相手待ち"
        case .unknown: "番が分からない"
        case .calm: "落ち着いている"
        }
    }

    static func state(_ raw: String?) -> S27WState? {
        switch raw {
        case "urgent": .urgent
        case "mine": .mine
        case "theirs": .theirs
        case "calm": .calm
        default: nil
        }
    }

    static func sortedDecided(_ items: [S27WItem]) -> [S27WItem] {
        var seen = Set<String>()
        var unique: [S27WItem] = []
        for i in items where seen.insert(i.id).inserted { unique.append(i) }
        return unique.sorted { a, b in
            let x = S27WRules.when(a), y = S27WRules.when(b)
            return x != y ? x > y : a.id < b.id
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: 規則で柱に分ける（言葉で）

    /// 文に当たる柱の id（当てる順に最初の 1 つ。無ければ nil）
    static func rulePillar(_ text: String) -> String? {
        for id in matchOrder {
            guard let p = pillars.first(where: { $0.id == id }) else { continue }
            for w in p.words where text.contains(w) { return id }
        }
        return nil
    }

    /// トピックの名前が柱に当たれば、そのトピックの項目は全部その柱へ。当たらなければ項目の文で。
    /// 案件全体の話（親そのもの）と「まだ案件に分けていないもの」は名前では当てない。ほかの部署の話は別の箱
    static func assign(_ groups: [S27WGroup]) -> S30WAssign {
        var a = S30WAssign()
        var seen = Set<String>()
        for g in groups {
            for topic in g.topics {
                let skipName: Bool = g.section == .other || topic.id == g.topID || topic.id == S27WMap.miscID
                let byName: String? = skipName ? nil : rulePillar(topic.name)
                var list: [S27WItem] = topic.items
                list.append(contentsOf: topic.timeline)
                for item in list where seen.insert(item.id).inserted {
                    if g.section == .other {
                        a.other.append(item)
                    } else if let pid = byName ?? rulePillar(item.text) {
                        a.bags[pid, default: []].append(item)
                    } else {
                        a.unassigned.append(item)
                    }
                }
            }
        }
        return a
    }

    static func ruleBags(_ a: S30WAssign) -> [S30WBag] {
        var out: [S30WBag] = []
        for p in pillars {
            guard let items = a.bags[p.id], !items.isEmpty else { continue }
            out.append(S30WBag(id: p.id, name: p.name, project: nil, state: nil, line: nil, items: items))
        }
        return out
    }

    /// report の柱（トピックの項目と、名指しの項目）
    static func reportBags(_ report: S30WReport, board: S27WBoard, idx: S30WIndex) -> [S30WBag] {
        var out: [S30WBag] = []
        for p in report.pillars {
            var items: [S27WItem] = []
            var seen = Set<String>()
            for tid in p.topicIDs {
                guard let topic = board.project(tid) else { continue }
                for i in topic.items where seen.insert(i.id).inserted { items.append(i) }
                for i in topic.timeline where seen.insert(i.id).inserted { items.append(i) }
            }
            for iid in p.itemIDs {
                guard let i = idx.items[iid], seen.insert(i.id).inserted else { continue }
                items.append(i)
            }
            out.append(S30WBag(id: p.id, name: p.name, project: p.project, state: state(p.state), line: nonEmpty(p.line), items: items))
        }
        return out
    }

    static func pillarView(_ bag: S30WBag, today: String, done: Set<String>, restored: Set<String>) -> S30WPillarView {
        var open: [S27WItem] = []
        var autoDone: [S27WItem] = []
        var autoOld: [S27WItem] = []
        var decided: [S27WItem] = []
        for item in bag.items {
            if item.kind == "decided" {
                decided.append(item)
                continue
            }
            guard S27WMap.openKinds.contains(item.kind ?? ""), !S27WMap.isDone(item, done) else { continue }
            switch boxed(item, restored: restored) {
            case "done": autoDone.append(item)
            case "old": autoOld.append(item)
            default: open.append(item)
            }
        }
        let sorted = S27WMap.sortedItems(open, today: today)
        var v = S30WPillarView(id: bag.id, name: bag.name, project: bag.project, state: .calm, line: bag.line)
        v.open = sorted
        v.counts = S27WMap.tally(sorted, today: today)
        var old = 0
        var worst: S27WState = .calm
        for i in sorted {
            if S27WMap.isOld(i) { old += 1 }
            let s = S27WMap.state(i, today: today)
            if s < worst { worst = s }
        }
        v.oldCount = old
        v.decided = sortedDecided(decided)
        v.autoDone = autoDone
        v.autoOld = autoOld
        v.state = bag.state ?? worst
        if v.line == nil { v.line = ruleLine(v, today: today) }
        return v
    }

    /// 規則の柱の 1 行（数と、近ごろ決まったことがあるか）
    static func ruleLine(_ v: S30WPillarView, today: String) -> String {
        if v.open.isEmpty { return "開いているものはありません。" }
        var inner: [String] = []
        let urgent: Int = v.counts[.urgent] ?? 0
        let mine: Int = v.counts[.mine] ?? 0
        let theirs: Int = v.counts[.theirs] ?? 0
        if urgent > 0 { inner.append("急ぎ \(urgent)") }
        if mine > 0 { inner.append("自分の番 \(mine)") }
        if theirs > 0 { inner.append("相手待ち \(theirs)") }
        var line = "開いている \(v.open.count) 件"
        if !inner.isEmpty { line += "（" + inner.joined(separator: "・") + "）" }
        line += "。"
        if v.oldCount > 0 { line += "\(S27WMap.oldDays) 日以上そのまま \(v.oldCount) 件。" }
        if let d = v.decided.first, let day = d.day, let ago = S27WRules.days(from: day, to: today), ago >= 0, ago <= movedDays {
            line += AppFeeds.monthDay(day) + " に決まったことがあります。"
        }
        return line
    }

    // MARK: 状況の 1 枚

    static func reportCards(_ report: S30WReport, board: S27WBoard, groups: [S27WGroup], idx: S30WIndex) -> [S30WCard] {
        var out: [S30WCard] = []
        for p in report.projects {
            let g = groups.first { $0.topID == p.id || $0.id == "g:" + p.id }
            var name = p.name
            if name.isEmpty { name = g?.name ?? board.project(p.id)?.name ?? "" }
            guard !name.isEmpty, !out.contains(where: { $0.id == p.id }) else { continue }
            var card = S30WCard(id: p.id, name: name, client: g?.client ?? board.project(p.id)?.client,
                                state: S30WProjectState(rawValue: p.state ?? ""))
            card.now = nonEmpty(p.now)
            card.moved = nonEmpty(p.moved)
            card.snag = nonEmpty(p.snag)
            var seen = Set<String>()
            for id in p.evidence where seen.insert(id).inserted {
                if let i = idx.items[id] { card.evidence.append(i) }
            }
            out.append(card)
        }
        return out
    }

    /// 規則の 1 枚（開いている数・近ごろ決まったこと・急ぎ／長くそのまま）。開いているものも近ごろの動きも無い案件は nil
    static func ruleCard(_ g: S27WGroup, today: String, done: Set<String>, restored: Set<String>) -> S30WCard? {
        var open: [S27WItem] = []
        var decided: [S27WItem] = []
        var last = ""
        var seen = Set<String>()
        for t in g.topics {
            if let m = t.lastMoved, m > last { last = m }
            var list: [S27WItem] = t.items
            list.append(contentsOf: t.timeline)
            for i in list where seen.insert(i.id).inserted {
                if i.kind == "decided" {
                    if let d = i.day, let ago = S27WRules.days(from: d, to: today), ago >= 0, ago <= movedDays { decided.append(i) }
                } else if isOpen(i, done: done, restored: restored) {
                    open.append(i)
                }
            }
        }
        if open.isEmpty && decided.isEmpty { return nil }
        let sorted = S27WMap.sortedItems(open, today: today)
        var urgent: [S27WItem] = []
        var old: [S27WItem] = []
        var mine = 0
        var theirs = 0
        for i in sorted {
            let s = S27WMap.state(i, today: today)
            if s == .urgent { urgent.append(i) }
            if s == .urgent || s == .mine { mine += 1 }
            if s == .theirs { theirs += 1 }
            if s != .theirs && S27WMap.isOld(i) { old.append(i) }
        }
        old.sort { a, b in
            let x: Int = a.ageDays ?? 0
            let y: Int = b.ageDays ?? 0
            return x != y ? x > y : a.id < b.id
        }
        let recent = sortedDecided(decided)
        var state: S30WProjectState = .ok
        if let d = S27WRules.days(from: last, to: today), d >= stuckDays, !sorted.isEmpty {
            state = .stuck
        } else if !urgent.isEmpty || old.count >= cautionOld {
            state = .caution
        }
        var card = S30WCard(id: g.id, name: g.name, client: g.client, state: state)
        var now = "開いている \(sorted.count) 件（自分の番 \(mine)・相手待ち \(theirs)）。"
        if let top = g.topics.first(where: { $0.id == g.topID }), let line = nonEmpty(top.statusLine) { now = line + "。" + now }
        card.now = now
        if let d = recent.first {
            var m = AppFeeds.monthDay(d.day ?? "") + " に決まった: " + d.text
            if recent.count > 1 { m += "（ほか \(recent.count - 1) 件）" }
            card.moved = m
        } else if HomeFeeds.isDay(last) {
            card.moved = "この \(movedDays) 日に決まったことは届いていません（最後に動いた日 " + AppFeeds.monthDay(last) + "）。"
        }
        if let u = urgent.first {
            card.snag = "急ぎ: " + u.text + (why(u, today: today).map { "（" + $0 + "）" } ?? "")
        } else if let o = old.first {
            card.snag = "\(o.ageDays ?? 0) 日そのまま: " + o.text
        } else {
            card.snag = "急ぎのもの・長くそのままのものはありません。"
        }
        var ids = Set<String>()
        var evidence: [S27WItem] = []
        for i in recent.prefix(3) where ids.insert(i.id).inserted { evidence.append(i) }
        for i in urgent.prefix(2) where ids.insert(i.id).inserted { evidence.append(i) }
        for i in old.prefix(1) where ids.insert(i.id).inserted { evidence.append(i) }
        card.evidence = evidence
        return card
    }

    static func ruleCards(_ groups: [S27WGroup], today: String, done: Set<String>, restored: Set<String>) -> [S30WCard] {
        var out: [S30WCard] = []
        for g in groups where g.section == .mine {
            guard out.count < cardLimit else { break }
            if let card = ruleCard(g, today: today, done: done, restored: restored) { out.append(card) }
        }
        return out
    }

    // MARK: 道のり

    /// 今日から先の節目（同じ日・同じ名前は 1 つ）。いちばん左に「今日」（今日の節目があればその名前）
    static func road(_ points: [S30WRoadPoint], today: String) -> [S30WRoadMark] {
        let sorted = points.sorted { a, b in a.day != b.day ? a.day < b.day : a.title < b.title }
        var todayTitles: [String] = []
        var todayFirm = true
        var future: [S30WRoadPoint] = []
        var seen = Set<String>()
        for p in sorted where HomeFeeds.isDay(p.day) && p.day >= today {
            guard seen.insert(p.day + "|" + p.title).inserted else { continue }
            if p.day == today {
                todayTitles.append(p.title)
                if p.firm == false { todayFirm = false }
            } else {
                future.append(p)
            }
        }
        if todayTitles.isEmpty && future.isEmpty { return [] }
        var out: [S30WRoadMark] = [S30WRoadMark(day: today, title: todayTitles.joined(separator: "・"), firm: todayFirm, isToday: true, daysLeft: 0)]
        for p in future.prefix(roadLimit) {
            out.append(S30WRoadMark(day: p.day, title: p.title, firm: p.firm != false, isToday: false,
                                    daysLeft: S27WRules.days(from: today, to: p.day) ?? 0))
        }
        return out
    }

    /// 規則の道のり（自分の案件のトピックの節目。確かさは分からないので「?」は付けない）
    static func ruleRoadPoints(_ groups: [S27WGroup]) -> [S30WRoadPoint] {
        var out: [S30WRoadPoint] = []
        for g in groups where g.section == .mine {
            for t in g.topics {
                if let m = t.milestone { out.append(S30WRoadPoint(day: m.day, title: m.title, firm: nil)) }
            }
        }
        return out
    }

    // MARK: 数字のタイル

    static func short(_ v: Double) -> String {
        v.rounded() == v && abs(v) < 1e12 ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// 同じ名前の数のうち、いちばん新しい日のもの
    private static func latest(_ list: [S30WNumber]) -> S30WNumber? {
        var best: S30WNumber?
        for n in list {
            guard let b = best else {
                best = n
                continue
            }
            if (n.day ?? "") >= (b.day ?? "") { best = n }
        }
        return best
    }

    /// 1 つめ: 済・残り（いちばん初めの名前の新しい数。2 つめの名前の数を下に。聞き取りの数は「聞こえた数」）
    static func numberTile(_ numbers: [S30WNumber]) -> S30WTile? {
        var order: [String] = []
        var byLabel: [String: [S30WNumber]] = [:]
        for n in numbers where n.value.isFinite && !n.label.isEmpty {
            if byLabel[n.label] == nil { order.append(n.label) }
            byLabel[n.label, default: []].append(n)
        }
        guard let firstLabel = order.first, let firstList = byLabel[firstLabel], let main = latest(firstList) else { return nil }
        var tile = S30WTile(value: short(main.value), unit: main.unit ?? main.label, label: "", tone: nil)
        var caption: [String] = []
        if main.unit != nil { caption.append(main.label) }
        var heard: Bool = main.heard == true
        var day: String? = main.day
        if order.count > 1, let list = byLabel[order[1]], let second = latest(list) {
            caption.append(second.label + " " + short(second.value) + (second.unit ?? ""))
            if second.heard == true { heard = true }
            if let d = second.day { day = d }
        }
        var text = caption.joined(separator: "・")
        let dayText: String? = day.flatMap { HomeFeeds.isDay($0) ? AppFeeds.monthDay($0) : nil }
        if heard {
            text += "（" + (dayText.map { $0 + " に" } ?? "") + "聞こえた数）"
        } else if let dayText {
            text += "（" + dayText + " の数）"
        }
        tile.label = text
        let points = firstList.sorted { ($0.day ?? "") < ($1.day ?? "") }
        if points.count >= 2 {
            var spark: [Double] = []
            for p in points.suffix(7) { spark.append(p.value) }
            tile.spark = spark
        }
        return tile
    }

    /// 1 つめの代わり（数が届いていないとき）: 開いている数
    static func openTile(open: Int, mine: Int) -> S30WTile {
        S30WTile(value: "\(open)", unit: "件", label: "開いている（自分の番 \(mine)）", tone: nil)
    }

    /// 2 つめ: 開いている不具合の話（柱が無ければ、課題の数）
    static func bugTile(_ pillars: [S30WPillarView], open: [S27WItem]) -> S30WTile {
        if let p = pillars.first(where: { $0.id == "bug" || $0.name.contains("不具合") }) {
            return S30WTile(value: "\(p.open.count)", unit: "件", label: "開いている不具合の話（古い \(p.oldCount)）",
                            tone: p.open.isEmpty ? .calm : .mine)
        }
        var n = 0
        var old = 0
        for i in open where i.kind == "issue" {
            n += 1
            if S27WMap.isOld(i) { old += 1 }
        }
        return S30WTile(value: "\(n)", unit: "件", label: "開いている課題（古い \(old)）", tone: n == 0 ? .calm : .mine)
    }

    /// 3 つめ: 次の節目（今日に名前があれば「今日」）
    static func nextTile(_ road: [S30WRoadMark]) -> S30WTile {
        for m in road where !(m.isToday && m.title.isEmpty) {
            if m.isToday { return S30WTile(value: "今日", unit: nil, label: m.title, tone: .urgent) }
            let label = AppFeeds.monthDay(m.day) + (m.firm ? "" : "?") + " " + m.title
            return S30WTile(value: "\(m.daysLeft)", unit: "日後", label: label, tone: m.daysLeft <= 1 ? .urgent : .theirs)
        }
        return S30WTile(value: "—", unit: nil, label: "次の節目はまだ届いていません", tone: nil)
    }

    // MARK: 今日の一手・相手を待っているもの

    /// report の名指し（届いている・写しで済みでない・箱に入っていないものだけ。端末で済みにしたものは丸を付けて残す）
    static func reportSteps(_ picks: [S30WPick], idx: S30WIndex, pillarOf: [String: String], today: String,
                            restored: Set<String>, waiting: Bool) -> [S30WStep] {
        var out: [S30WStep] = []
        for pick in picks {
            guard let item = idx.items[pick.itemID], !item.isDone, boxed(item, restored: restored) == nil,
                  !out.contains(where: { $0.item.id == item.id }) else { continue }
            let fallback: String? = waiting ? waitWhy(item, today: today) : why(item, today: today)
            out.append(S30WStep(item: item, why: nonEmpty(pick.why) ?? fallback, pillar: pillarOf[item.id],
                                state: S27WMap.state(item, today: today)))
            if out.count >= pickLimit { break }
        }
        return out
    }

    /// 規則: 自分の番は 急ぎ → 期限の近い順 → 古い順、相手待ちは 期限の近い順 → 長く待っている順
    static func ruleSteps(_ items: [S27WItem], waiting: Bool, pillarOf: [String: String], today: String) -> [S30WStep] {
        var picked: [S27WItem] = []
        for i in items {
            let s = S27WMap.state(i, today: today)
            let hit: Bool = waiting ? (s == .theirs) : (s == .urgent || s == .mine)
            if hit { picked.append(i) }
        }
        var out: [S30WStep] = []
        for i in S27WMap.sortedItems(picked, today: today).prefix(pickLimit) {
            let w: String? = waiting ? waitWhy(i, today: today) : why(i, today: today)
            out.append(S30WStep(item: i, why: w, pillar: pillarOf[i.id], state: S27WMap.state(i, today: today)))
        }
        return out
    }

    // MARK: 1 枚にまとめる

    /// 仕事タブ 1 枚ぶん。done は端末で済みにした id、restored は箱から戻した id
    static func screen(_ board: S27WBoard, done: Set<String>, restored: Set<String>, today: String) -> S30WScreen {
        let idx = index(board)
        let groups = S27WMap.sortedGroups(S27WMap.groups(board.projects), today: today, done: done)
        let report = board.report
        var s = S30WScreen()
        s.hasReport = report != nil
        s.byClaude = report?.byClaude ?? false
        s.asOf = report?.asOf ?? board.asOf
        s.writtenAt = report?.writtenAt

        // 柱
        let assigned = assign(groups)
        var bags: [S30WBag] = []
        if let report { bags = reportBags(report, board: board, idx: idx) }
        if bags.isEmpty {
            bags = ruleBags(assigned)
            s.pillarsRuled = true
        }
        var pillarOf: [String: String] = [:]
        for bag in bags {
            for i in bag.items where pillarOf[i.id] == nil { pillarOf[i.id] = bag.name }
        }
        var views: [S30WPillarView] = []
        for bag in bags { views.append(pillarView(bag, today: today, done: done, restored: restored)) }
        s.pillars = views

        // 自分の案件の項目（今日の一手・相手待ち・数）。写しで済みのもの・箱のものは除く（端末で済みにしたものは丸を付けて残す）
        var main: [S27WItem] = []
        var seen = Set<String>()
        for g in groups where g.section == .mine || g.section == .misc {
            for t in g.topics {
                for i in t.items where seen.insert(i.id).inserted {
                    if S27WMap.openKinds.contains(i.kind ?? ""), !i.isDone, boxed(i, restored: restored) == nil { main.append(i) }
                }
            }
        }
        var mainOpen: [S27WItem] = []
        var mine = 0
        var theirs = 0
        for i in main where !done.contains(i.id) {
            mainOpen.append(i)
            let st = S27WMap.state(i, today: today)
            if st == .urgent || st == .mine { mine += 1 }
            if st == .theirs { theirs += 1 }
        }
        s.mineCount = mine
        s.waitingCount = theirs

        if let report, !report.next3.isEmpty {
            s.next3 = reportSteps(report.next3, idx: idx, pillarOf: pillarOf, today: today, restored: restored, waiting: false)
        }
        if s.next3.isEmpty {
            s.next3 = ruleSteps(main, waiting: false, pillarOf: pillarOf, today: today)
            s.next3Ruled = true
        }
        if let report, !report.waiting3.isEmpty {
            s.waiting3 = reportSteps(report.waiting3, idx: idx, pillarOf: pillarOf, today: today, restored: restored, waiting: true)
        }
        if s.waiting3.isEmpty {
            s.waiting3 = ruleSteps(main, waiting: true, pillarOf: pillarOf, today: today)
            s.waitingRuled = true
        }

        // 状況の 1 枚
        if let report { s.cards = reportCards(report, board: board, groups: groups, idx: idx) }
        if s.cards.isEmpty {
            s.cards = ruleCards(groups, today: today, done: done, restored: restored)
            s.cardsRuled = true
        }

        // 道のり
        var points: [S30WRoadPoint] = []
        if let report {
            for p in report.projects { points.append(contentsOf: p.road) }
        }
        s.road = road(points, today: today)
        if s.road.isEmpty {
            s.road = road(ruleRoadPoints(groups), today: today)
            s.roadRuled = true
        }

        // 数字のタイル
        var numbers: [S30WNumber] = []
        if let report {
            for p in report.projects where !p.numbers.isEmpty {
                numbers = p.numbers
                break
            }
        }
        var first = numberTile(numbers)
        if first == nil {
            var progress: [S30WNumber] = []
            for g in groups where g.section == .mine {
                for t in g.topics {
                    for p in t.progress { progress.append(S30WNumber(label: p.label, value: p.value, unit: nil, day: p.day, heard: nil)) }
                }
            }
            first = numberTile(progress)
        }
        s.tiles = [first ?? openTile(open: mainOpen.count, mine: mine), bugTile(views, open: mainOpen), nextTile(s.road)]

        // この案件の外
        if let report {
            for o in report.outside {
                var items: [S27WItem] = []
                var ids = Set<String>()
                for id in o.itemIDs where ids.insert(id).inserted {
                    if let i = idx.items[id], !S27WMap.isDone(i, done) { items.append(i) }
                }
                if !items.isEmpty && !s.outside.contains(where: { $0.label == o.label }) {
                    s.outside.append(S30WOutsideRow(label: o.label, items: items))
                }
            }
        }
        if s.outside.isEmpty && (report?.outside.isEmpty ?? true) {
            var other: [S27WItem] = []
            for i in assigned.other where isOpen(i, done: done, restored: restored) { other.append(i) }
            var rest: [S27WItem] = []
            for i in assigned.unassigned where isOpen(i, done: done, restored: restored) { rest.append(i) }
            if !other.isEmpty { s.outside.append(S30WOutsideRow(label: otherLabel, items: other)) }
            if !rest.isEmpty { s.outside.append(S30WOutsideRow(label: unassignedLabel, items: rest)) }
            s.outsideRuled = true
        }

        // 前の一覧の数
        var total = 0
        var topics = 0
        for p in board.projects where p.kind != "side" {
            topics += 1
            total += S27WMap.openItems(p, done: done).count
        }
        s.openTotal = total
        s.topicCount = topics
        return s
    }

    /// 箱から戻した印のうち、まだ箱の印（auto）が付いている項目の分だけ残す（印が外れたら・項目が無くなったら捨てる）
    static func keptRestored(_ restored: [String: String], board: S27WBoard) -> [String: String] {
        let idx = index(board)
        return restored.filter { idx.items[$0.key]?.auto != nil }
    }

    // MARK: K30-2 送る・作り直しを見る

    /// 保存したばかり（window 秒以内）で、まだ送っていないまとめ（古い順・20 件まで）
    @MainActor
    static func fresh(_ entries: [WorkDigest.Entry], sent: Set<String>, now: Date,
                      window: TimeInterval = freshWindow) -> [WorkDigest.Entry] {
        var out: [WorkDigest.Entry] = []
        for e in entries where !sent.contains(e.id) {
            let age = now.timeIntervalSince(e.addedAt)
            if age >= -5 && age <= window { out.append(e) }
        }
        out.sort { $0.addedAt < $1.addedAt }
        return Array(out.prefix(pushLimit))
    }

    /// POST /work/digest の体（{"entries":[…]}。1 件は端末の work-digests.json の 1 件と同じ形＝同じ JSONEncoder で書く）
    @MainActor
    static func pushBody(_ entries: [WorkDigest.Entry]) -> Data? {
        guard !entries.isEmpty else { return nil }
        struct Body: Encodable {
            let entries: [WorkDigest.Entry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Body(entries: Array(entries.prefix(pushLimit))))
    }

    static func pushReply(_ data: Data) -> S30WPushReply? {
        try? JSONDecoder().decode(S30WPushReply.self, from: data)
    }

    static func run(_ data: Data) -> S30WRun? {
        try? JSONDecoder().decode(S30WRun.self, from: data)
    }

    /// 作り直しが終わったか。idle で、送ったあとに走っていたのを見たか、送ったころより後に終わっていれば終わり。
    /// 送ったときにもう走っていた（"already"）ときは、送ったあとに始まった回が終わるまで待つ（時計のずれは tolerance まで許す）
    static func runFinished(_ run: S30WRun, postedAt: Date, sawRunning: Bool, needStartAfter: Bool,
                            tolerance: TimeInterval = runTolerance) -> Bool {
        guard run.state == "idle" else { return false }
        if needStartAfter {
            guard let started = S27WRules.date(run.startedAt) else { return false }
            return started >= postedAt
        }
        if sawRunning { return true }
        guard let finished = S27WRules.date(run.finishedAt) else { return false }
        return finished >= postedAt.addingTimeInterval(-tolerance)
    }

    /// 送った id を覚える（新しいほうから 200 件まで）
    static func remembered(_ old: [String], adding: [String], limit: Int = 200) -> [String] {
        var out: [String] = old.filter { !adding.contains($0) }
        out.append(contentsOf: adding)
        return Array(out.suffix(limit))
    }

    /// いま見せる帯（動いているものは 4 分まで・終わったものは 10 分まで。仮）
    static func visible(_ band: S30WBand?, now: Date) -> S30WBand? {
        guard let band else { return nil }
        let age = now.timeIntervalSince(band.at)
        if band.working { return age < pollLimit + 60 ? band : nil }
        return age < bandShowFor ? band : nil
    }

    static func bandTitle(_ band: S30WBand) -> String? {
        switch band {
        case .sending: "家の PC に送っています"
        case .rebuilding: "作り直しています"
        case .done(_, let ok): ok ? "作り直しました" : "作り直しで止まったところがありました"
        case .late: "作り直しが 3 分で終わりませんでした"
        case .fallback: nil
        }
    }

    static func bandDetail(_ band: S30WBand, clock: String) -> String {
        switch band {
        case .sending: "取り込んだ仕事のまとめを、家の PC に渡しています。"
        case .rebuilding: "家の PC が、取り込んだまとめで仕事の画面を作り直しています。終わったら取り直します（5 秒ごとに見ます・3 分まで）。"
        case .done(_, let ok): ok ? clock + " に取り直しました。" : "届いている分を取り直しました。続きは次の回（15 分ごと）に入ります。"
        case .late: "次の回（15 分ごと）か、下へ引っぱって取り直すと入ります。"
        case .fallback(_, let why): why
        }
    }
}

import Foundation

/// s27（2026-11-25）の A の決まり（決まった入力から決まった出力だけ）。「仕事が一気に分かる場所」。
/// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 18」（場1〜場8・案3/4/6/9・動7・人2/5/8・他2/3・材8・守1〜守4・守6）。
/// 取り決めは K2（GET /work）・K3（GET /work/confirm）・K4（POST /feedback の work_*）・K5（GET /work/ask）・K6（lifelog://work…）。
/// 動きは S27WBook.swift、画面は S27WViews.swift、テストは LifeLogTests/S27WTests.swift。しきい値はどれも仮。
/// 新しい問い・知らせは足していない（減13）。言語モデルの呼び出しも無い。中身の文は記録（ログ）に書かない。

// MARK: - K2 アプリに配るもの（形は変えない。どの項目も省ける・読めない行は飛ばす）

/// 配列の中の読めない行は飛ばして読む（1 つの壊れた行で全部が読めなくならないように）
extension KeyedDecodingContainer {
    func s27wList<T: Decodable>(_ key: Key) -> [T] {
        guard let rows = (try? decodeIfPresent([LossyRow<T>].self, forKey: key)) ?? nil else { return [] }
        var out: [T] = []
        for row in rows {
            if let value = row.value { out.append(value) }
        }
        return out
    }

    func s27w<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// 項目 1 つ（宿題・未決・指摘・決まったこと）
struct S27WItem: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String?
    var text: String
    var projectID: String?
    var who: String?
    var day: String?
    var time: String?
    var due: String?
    var dueGuess: Bool?
    var ball: String?
    var ageDays: Int?
    var state: String?
    var certainty: String?
    var src: String?
    var link: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, text, who, day, time, due, ball, state, certainty, src, link
        case projectID = "project_id", dueGuess = "due_guess", ageDays = "age_days"
    }

    init(id: String, kind: String? = nil, text: String, projectID: String? = nil, who: String? = nil, day: String? = nil,
         time: String? = nil, due: String? = nil, dueGuess: Bool? = nil, ball: String? = nil, ageDays: Int? = nil,
         state: String? = nil, certainty: String? = nil, src: String? = nil, link: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.projectID = projectID
        self.who = who
        self.day = day
        self.time = time
        self.due = due
        self.dueGuess = dueGuess
        self.ball = ball
        self.ageDays = ageDays
        self.state = state
        self.certainty = certainty
        self.src = src
        self.link = link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        kind = c.s27w(.kind)
        projectID = c.s27w(.projectID)
        who = c.s27w(.who)
        day = c.s27w(.day)
        time = c.s27w(.time)
        due = c.s27w(.due)
        dueGuess = c.s27w(.dueGuess)
        ball = c.s27w(.ball)
        ageDays = c.s27w(.ageDays)
        state = c.s27w(.state)
        certainty = c.s27w(.certainty)
        src = c.s27w(.src)
        link = c.s27w(.link)
    }

    /// 根拠の無い文（守4。「たぶん」を付ける）
    var isMaybe: Bool { certainty == "maybe" }
    var isDone: Bool { state == "done" }
    var isHomework: Bool { kind == "homework" }
}

/// 聞いた話（他2。いつ・だれから・どこで）
struct S27WHeard: Decodable, Equatable, Sendable {
    var text: String
    var day: String?
    var from: String?
    /// talk・notice・chat（K2 の "where"）
    var place: String?
    var old: Bool?

    enum CodingKeys: String, CodingKey { case text, day, from, old, place = "where" }

    init(text: String, day: String? = nil, from: String? = nil, place: String? = nil, old: Bool? = nil) {
        self.text = text
        self.day = day
        self.from = from
        self.place = place
        self.old = old
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        day = c.s27w(.day)
        from = c.s27w(.from)
        place = c.s27w(.place)
        old = c.s27w(.old)
    }
}

struct S27WPrep: Decodable, Equatable, Sendable {
    var lastDecided: [S27WItem] = []
    var open: [S27WItem] = []
    var myHomework: [S27WItem] = []
    var ask: [String] = []

    enum CodingKeys: String, CodingKey { case open, ask, lastDecided = "last_decided", myHomework = "my_homework" }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastDecided = c.s27wList(.lastDecided)
        open = c.s27wList(.open)
        myHomework = c.s27wList(.myHomework)
        ask = c.s27wList(.ask)
    }

    var isEmpty: Bool { lastDecided.isEmpty && open.isEmpty && myHomework.isEmpty && ask.isEmpty }
}

struct S27WMeeting: Decodable, Equatable, Sendable {
    var start: String
    var end: String?
    var title: String
    var projectID: String?
    var prep: S27WPrep?

    enum CodingKeys: String, CodingKey { case start, end, title, prep, projectID = "project_id" }

    init(start: String, end: String? = nil, title: String, projectID: String? = nil, prep: S27WPrep? = nil) {
        self.start = start
        self.end = end
        self.title = title
        self.projectID = projectID
        self.prep = prep
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(String.self, forKey: .start)
        title = try c.decode(String.self, forKey: .title)
        end = c.s27w(.end)
        projectID = c.s27w(.projectID)
        prep = c.s27w(.prep)
    }
}

struct S27WCounts: Decodable, Equatable, Sendable {
    var homeworkToday: Int?
    var openMine: Int?
    var nextMeetingAt: String?

    enum CodingKeys: String, CodingKey {
        case homeworkToday = "homework_today", openMine = "open_mine", nextMeetingAt = "next_meeting_at"
    }

    init(homeworkToday: Int? = nil, openMine: Int? = nil, nextMeetingAt: String? = nil) {
        self.homeworkToday = homeworkToday
        self.openMine = openMine
        self.nextMeetingAt = nextMeetingAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homeworkToday = c.s27w(.homeworkToday)
        openMine = c.s27w(.openMine)
        nextMeetingAt = c.s27w(.nextMeetingAt)
    }
}

struct S27WToday: Decodable, Equatable, Sendable {
    var homework: [S27WItem] = []
    var waitingOnMe: [S27WItem] = []
    var waitingOnOthers: [S27WItem] = []
    var stuckByMe: [S27WItem] = []
    var standup: [String] = []
    var meetings: [S27WMeeting] = []

    enum CodingKeys: String, CodingKey {
        case homework, standup, meetings
        case waitingOnMe = "waiting_on_me", waitingOnOthers = "waiting_on_others", stuckByMe = "stuck_by_me"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homework = c.s27wList(.homework)
        waitingOnMe = c.s27wList(.waitingOnMe)
        waitingOnOthers = c.s27wList(.waitingOnOthers)
        stuckByMe = c.s27wList(.stuckByMe)
        standup = c.s27wList(.standup)
        meetings = c.s27wList(.meetings)
    }
}

struct S27WDiff: Decodable, Equatable, Sendable {
    var since: String?
    var added: [S27WItem] = []
    var closed: [S27WItem] = []
    var decided: [S27WItem] = []

    enum CodingKeys: String, CodingKey { case since, added, closed, decided }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = c.s27w(.since)
        added = c.s27wList(.added)
        closed = c.s27wList(.closed)
        decided = c.s27wList(.decided)
    }

    var isEmpty: Bool { added.isEmpty && closed.isEmpty && decided.isEmpty }
}

struct S27WPersonRef: Decodable, Equatable, Sendable {
    var id: String
    var name: String
    var role: String?

    enum CodingKeys: String, CodingKey { case id, name, role }

    init(id: String, name: String, role: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = c.s27w(.role)
    }
}

struct S27WMilestone: Decodable, Equatable, Sendable {
    var day: String
    var title: String
    var daysLeft: Int?

    enum CodingKeys: String, CodingKey { case day, title, daysLeft = "days_left" }

    init(day: String, title: String, daysLeft: Int? = nil) {
        self.day = day
        self.title = title
        self.daysLeft = daysLeft
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        title = try c.decode(String.self, forKey: .title)
        daysLeft = c.s27w(.daysLeft)
    }
}

struct S27WConflict: Decodable, Equatable, Sendable {
    var a: S27WItem
    var b: S27WItem
}

struct S27WProgress: Decodable, Equatable, Sendable {
    var day: String
    var label: String
    var value: Double
}

struct S27WProjectCounts: Decodable, Equatable, Sendable {
    var homework: Int = 0
    var open: Int = 0
    var issue: Int = 0
    var decided: Int = 0

    enum CodingKeys: String, CodingKey { case homework, open, issue, decided }

    init(homework: Int = 0, open: Int = 0, issue: Int = 0, decided: Int = 0) {
        self.homework = homework
        self.open = open
        self.issue = issue
        self.decided = decided
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homework = c.s27w(.homework) ?? 0
        open = c.s27w(.open) ?? 0
        issue = c.s27w(.issue) ?? 0
        decided = c.s27w(.decided) ?? 0
    }
}

struct S27WProject: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var client: String?
    var kind: String = "mine"
    var signal: String?
    var statusLine: String?
    var lastMoved: String?
    var counts = S27WProjectCounts()
    var people: [S27WPersonRef] = []
    var milestone: S27WMilestone?
    var risk: [String] = []
    var conflicts: [S27WConflict] = []
    var progress: [S27WProgress] = []
    var items: [S27WItem] = []
    var timeline: [S27WItem] = []
    var heard: [S27WHeard] = []
    var stale: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, client, kind, signal, counts, people, milestone, risk, conflicts, progress, items, timeline, heard, stale
        case statusLine = "status_line", lastMoved = "last_moved"
    }

    init(id: String, name: String, client: String? = nil, kind: String = "mine", signal: String? = nil,
         statusLine: String? = nil, lastMoved: String? = nil) {
        self.id = id
        self.name = name
        self.client = client
        self.kind = kind
        self.signal = signal
        self.statusLine = statusLine
        self.lastMoved = lastMoved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        client = c.s27w(.client)
        kind = c.s27w(.kind) ?? "mine"
        signal = c.s27w(.signal)
        statusLine = c.s27w(.statusLine)
        lastMoved = c.s27w(.lastMoved)
        counts = c.s27w(.counts) ?? S27WProjectCounts()
        people = c.s27wList(.people)
        milestone = c.s27w(.milestone)
        risk = c.s27wList(.risk)
        conflicts = c.s27wList(.conflicts)
        progress = c.s27wList(.progress)
        items = c.s27wList(.items)
        timeline = c.s27wList(.timeline)
        heard = c.s27wList(.heard)
        stale = c.s27w(.stale)
    }

    var signalKind: S27WSignal { S27WSignal(rawValue: signal ?? "") ?? .gray }
}

struct S27WRecent: Decodable, Equatable, Sendable {
    var projectID: String?
    var day: String?
    var title: String

    enum CodingKeys: String, CodingKey { case day, title, projectID = "project_id" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        projectID = c.s27w(.projectID)
        day = c.s27w(.day)
    }
}

struct S27WBall: Decodable, Equatable, Sendable {
    var me: Int = 0
    var them: Int = 0

    enum CodingKeys: String, CodingKey { case me, them }

    init(me: Int = 0, them: Int = 0) {
        self.me = me
        self.them = them
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        me = c.s27w(.me) ?? 0
        them = c.s27w(.them) ?? 0
    }
}

struct S27WPromises: Decodable, Equatable, Sendable {
    var mine: [S27WItem] = []
    var theirs: [S27WItem] = []

    enum CodingKeys: String, CodingKey { case mine, theirs }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mine = c.s27wList(.mine)
        theirs = c.s27wList(.theirs)
    }
}

struct S27WPerson: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var org: String?
    var team: String?
    var role: String?
    var projects: [String] = []
    var recent: [S27WRecent] = []
    var theirHomework: [S27WItem] = []
    var ball = S27WBall()
    var promises = S27WPromises()
    var lastTalk: String?
    var quiet: Bool?
    var expertIn: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, name, org, team, role, projects, recent, ball, promises, quiet
        case theirHomework = "their_homework", lastTalk = "last_talk", expertIn = "expert_in"
    }

    init(id: String, name: String, org: String? = nil, team: String? = nil, role: String? = nil) {
        self.id = id
        self.name = name
        self.org = org
        self.team = team
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        org = c.s27w(.org)
        team = c.s27w(.team)
        role = c.s27w(.role)
        projects = c.s27wList(.projects)
        recent = c.s27wList(.recent)
        theirHomework = c.s27wList(.theirHomework)
        ball = c.s27w(.ball) ?? S27WBall()
        promises = c.s27w(.promises) ?? S27WPromises()
        lastTalk = c.s27w(.lastTalk)
        quiet = c.s27w(.quiet)
        expertIn = c.s27wList(.expertIn)
    }
}

/// 材8 副業の段（本業と混ぜない）
struct S27WSide: Decodable, Equatable, Sendable {
    var status: String?
    var lastDay: String?
    var items: [S27WItem] = []

    enum CodingKeys: String, CodingKey { case status, items, lastDay = "last_day" }

    init(status: String? = nil, lastDay: String? = nil) {
        self.status = status
        self.lastDay = lastDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.s27w(.status)
        lastDay = c.s27w(.lastDay)
        items = c.s27wList(.items)
    }
}

/// K2 の全体。`{"available":false}` のときは available が false
struct S27WBoard: Decodable, Equatable, Sendable {
    var available: Bool?
    var version: Int?
    var generatedAt: String?
    var asOf: String?
    var counts: S27WCounts?
    var today = S27WToday()
    var diff: S27WDiff?
    var projects: [S27WProject] = []
    var people: [S27WPerson] = []
    var side: S27WSide?
    var monthlyOther: String?

    enum CodingKeys: String, CodingKey {
        case available, version, counts, today, diff, projects, people, side
        case generatedAt = "generated_at", asOf = "as_of", monthlyOther = "monthly_other"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.s27w(.available)
        version = c.s27w(.version)
        generatedAt = c.s27w(.generatedAt)
        asOf = c.s27w(.asOf)
        counts = c.s27w(.counts)
        today = c.s27w(.today) ?? S27WToday()
        diff = c.s27w(.diff)
        projects = c.s27wList(.projects)
        people = c.s27wList(.people)
        side = c.s27w(.side)
        monthlyOther = c.s27w(.monthlyOther)
    }

    func project(_ id: String) -> S27WProject? { projects.first { $0.id == id } }
    func person(_ id: String) -> S27WPerson? { people.first { $0.id == id } }
}

// MARK: - K3 まとめて 1 回の確かめ

struct S27WChoice: Decodable, Equatable, Sendable {
    var value: String
    var label: String
}

struct S27WConfirmItem: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String?
    var title: String
    var question: String
    var choices: [S27WChoice] = []
    var evidence: [String] = []
    var defaultValue: String?

    enum CodingKeys: String, CodingKey { case id, kind, title, question, choices, evidence, defaultValue = "default" }

    init(id: String, kind: String? = nil, title: String, question: String, choices: [S27WChoice], evidence: [String] = [],
         defaultValue: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.question = question
        self.choices = choices
        self.evidence = evidence
        self.defaultValue = defaultValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        question = try c.decode(String.self, forKey: .question)
        kind = c.s27w(.kind)
        choices = c.s27wList(.choices)
        evidence = c.s27wList(.evidence)
        defaultValue = c.s27w(.defaultValue)
    }
}

private struct S27WConfirmFile: Decodable {
    var items: [S27WConfirmItem] = []

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.s27wList(.items)
    }
}

// MARK: - K5 「あの件どうなった」

struct S27WAnswer: Decodable, Equatable, Sendable {
    var projectID: String?
    var name: String
    var statusLine: String?
    var lastDecided: S27WItem?
    var open: [S27WItem] = []
    var link: String?

    enum CodingKeys: String, CodingKey { case name, open, link, projectID = "project_id", statusLine = "status_line", lastDecided = "last_decided" }

    init(projectID: String?, name: String, statusLine: String?, lastDecided: S27WItem?, open: [S27WItem], link: String?) {
        self.projectID = projectID
        self.name = name
        self.statusLine = statusLine
        self.lastDecided = lastDecided
        self.open = open
        self.link = link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        projectID = c.s27w(.projectID)
        statusLine = c.s27w(.statusLine)
        lastDecided = c.s27w(.lastDecided)
        open = c.s27wList(.open)
        link = c.s27w(.link)
    }
}

private struct S27WAnswerFile: Decodable {
    var answers: [S27WAnswer] = []

    enum CodingKeys: String, CodingKey { case answers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answers = c.s27wList(.answers)
    }
}

// MARK: - 場1・場3 案件の信号（色の役割は s26 の決まりのまま）

enum S27WSignal: String, CaseIterable, Sendable {
    /// 自分が動く（期限が近い・自分の宿題が古い）＝赤（LLRole.act）
    case red
    /// 相手待ちだけ＝オレンジ（LLRole.wait）
    case orange
    /// 3 勤務日動いていない＝灰（色を付けない）
    case gray
    /// 進んでいる＝緑（使う所を絞った LL.good）
    case green

    var label: String {
        switch self {
        case .red: "自分が動く"
        case .orange: "待ち"
        case .gray: "止まっている"
        case .green: "進んでいる"
        }
    }

    var symbol: String {
        switch self {
        case .red: "hand.point.up.left.fill"
        case .orange: "hourglass"
        case .gray: "pause.circle"
        case .green: "arrow.forward.circle"
        }
    }

    /// 色の役割（赤＝本人が動く・オレンジ＝待てば戻る）。灰と緑は役割の外（nil）
    var role: LLRole? {
        switch self {
        case .red: .act
        case .orange: .wait
        case .gray, .green: nil
        }
    }

    /// 並びの順（赤が上）
    var rank: Int {
        switch self {
        case .red: 0
        case .orange: 1
        case .gray: 2
        case .green: 3
        }
    }
}

// MARK: - 守2 顧客名と人名を伏せる

struct S27WMask: Equatable, Sendable {
    /// 本当の名前 → 伏せた名前（長い名前から置き換える）
    var names: [String: String] = [:]
    /// 伏せる名前の短さの下限（1 文字の名前はほかの言葉まで消してしまうので伏せない。仮）
    static let minLength = 2

    /// 人は「人1」「人2」、顧客は「顧客1」…（K2 の並びの順で決める。同じ画面の中で同じ人は同じ名前）
    static func make(_ board: S27WBoard) -> S27WMask {
        var names: [String: String] = [:]
        var personCount = 0
        func addPerson(_ name: String) {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard n.count >= minLength, names[n] == nil else { return }
            personCount += 1
            names[n] = "人\(personCount)"
        }
        for p in board.people { addPerson(p.name) }
        for project in board.projects {
            for p in project.people { addPerson(p.name) }
        }
        var clientCount = 0
        for project in board.projects {
            guard let client = project.client?.trimmingCharacters(in: .whitespacesAndNewlines),
                  client.count >= minLength, names[client] == nil else { continue }
            clientCount += 1
            names[client] = "顧客\(clientCount)"
        }
        return S27WMask(names: names)
    }

    /// 文の中の人名・顧客名を伏せる
    func apply(_ text: String) -> String {
        guard !names.isEmpty, !text.isEmpty else { return text }
        let keys = names.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        var out = text
        for key in keys where out.contains(key) {
            out = out.replacingOccurrences(of: key, with: names[key] ?? "〇〇")
        }
        return out
    }

    /// 人の名前 1 つ（表に無い名前は「だれか」）
    func person(_ name: String?) -> String? {
        guard let name else { return nil }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return nil }
        if let alias = names[n] { return alias }
        let masked = apply(n)
        return masked == n ? "だれか" : masked
    }
}

// MARK: - 画面の文（どれも決まった入力から）

enum S27WRules {
    /// 家の PC の features の名前（K5）
    static let featureWork = "work"
    static let featureConfirm = "workconfirm"
    static let featureAsk = "workask"
    static let featureBoard = "workboard"

    /// 他の案件の話が薄くなる日数・「古い」の印の日数（仮。共通の決まりの 7 日・30 日）
    static let fadeDays = 7
    static let oldDays = 30
    /// 本人が貼る文・お知らせの文の長さの上限（仮）
    static let textLimit = 4000
    /// 人の画面で出す最近の案件の数（仮）
    static let recentLimit = 5

    // MARK: 読む

    static func board(_ data: Data) -> S27WBoard? {
        guard let board = try? JSONDecoder().decode(S27WBoard.self, from: data) else { return nil }
        if board.available == false { return nil }
        return board
    }

    /// 家の PC が「まだ無い」と返した（`{"available":false}`）。読めないだけのときは false（前の写しを残す）
    static func unavailable(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (object["available"] as? Bool) == false
    }

    /// いまの欄（人8 で直した欄と比べる）。人は name・team・role・org、案件は name・client・kind
    static func currentFields(_ board: S27WBoard, id: String) -> [String: String]? {
        if let p = board.person(id) {
            var out: [String: String] = ["name": p.name]
            out["team"] = p.team ?? ""
            out["role"] = p.role ?? ""
            out["org"] = p.org ?? "unknown"
            return out
        }
        if let p = board.project(id) {
            var out: [String: String] = ["name": p.name, "kind": p.kind]
            out["client"] = p.client ?? ""
            return out
        }
        return nil
    }

    /// 直した欄のうち、家の PC の写しがもう同じになったものは外す（反映を待つあいだだけ端末で上書きして見せる）
    static func pruned(_ edits: [String: [String: String]], board: S27WBoard) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (id, fields) in edits {
            guard let now = currentFields(board, id: id) else { continue }
            let rest = fields.filter { now[$0.key] != $0.value }
            if !rest.isEmpty { out[id] = rest }
        }
        return out
    }

    /// 写しの中の済みの項目の id（端末で済みにした印を、反映されたら外す）
    static func doneIDs(_ board: S27WBoard) -> Set<String> {
        var out = Set<String>()
        func add(_ items: [S27WItem]) {
            for item in items where item.isDone { out.insert(item.id) }
        }
        add(board.today.homework)
        add(board.today.waitingOnMe)
        add(board.today.stuckByMe)
        for p in board.projects { add(p.items) }
        return out
    }

    static func confirmItems(_ data: Data) -> [S27WConfirmItem]? {
        (try? JSONDecoder().decode(S27WConfirmFile.self, from: data))?.items
    }

    static func answers(_ data: Data) -> [S27WAnswer]? {
        (try? JSONDecoder().decode(S27WAnswerFile.self, from: data))?.answers
    }

    /// ISO の時刻（秒の小数があってもなくても）
    static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    static func day(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let text, HomeFeeds.isDay(text) else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 2 つの日の間の日数（b − a）。読めなければ nil
    static func days(from a: String?, to b: String?, calendar: Calendar = .current) -> Int? {
        guard let x = day(a, calendar: calendar), let y = day(b, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: x, to: y).day
    }

    // MARK: 並べる

    /// 本人の案件の並び: 信号（赤が上）→ 最後に動いた日の新しい順 → 名前
    static func sortedMine(_ projects: [S27WProject]) -> [S27WProject] {
        projects.filter { $0.kind == "mine" }.sorted { a, b in
            if a.signalKind.rank != b.signalKind.rank { return a.signalKind.rank < b.signalKind.rank }
            let x = a.lastMoved ?? "", y = b.lastMoved ?? ""
            if x != y { return x > y }
            return a.name < b.name
        }
    }

    /// 他の案件・副業の並び: 最後に動いた日の新しい順 → 名前（順位ではない）
    static func sortedByMoved(_ projects: [S27WProject], kind: String) -> [S27WProject] {
        projects.filter { $0.kind == kind }.sorted { a, b in
            let x = a.lastMoved ?? "", y = b.lastMoved ?? ""
            if x != y { return x > y }
            return a.name < b.name
        }
    }

    /// 人の一覧は名前の順だけ（守3: 数・順位で並べない）
    static func sortedPeople(_ people: [S27WPerson]) -> [S27WPerson] {
        people.sorted { a, b in a.name != b.name ? a.name < b.name : a.id < b.id }
    }

    /// 動7 自分が止めているもの（古い順に 3 つまで）
    static func stuck(_ items: [S27WItem], limit: Int = 3) -> [S27WItem] {
        let open = items.filter { !$0.isDone }
        let sorted = open.sorted { a, b in
            let x: Int = a.ageDays ?? 0
            let y: Int = b.ageDays ?? 0
            return x != y ? x > y : a.id < b.id
        }
        return Array(sorted.prefix(limit))
    }

    // MARK: 場2・場6 数

    /// 「今日」の 1 行（「仕事: 宿題 3・会議 2」）
    static func todayLine(_ board: S27WBoard) -> String {
        let homework = board.counts?.homeworkToday ?? board.today.homework.filter { !$0.isDone }.count
        return "仕事: 宿題 \(homework)・会議 \(board.today.meetings.count)"
    }

    /// ウィジェットへ渡す数（中身の文・名前は渡さない＝守1）
    static func widgetCounts(_ board: S27WBoard, now: Date = .now) -> S27WWorkCounts {
        let homework = board.counts?.homeworkToday ?? board.today.homework.filter { !$0.isDone }.count
        let open = board.counts?.openMine ?? 0
        var next = date(board.counts?.nextMeetingAt)
        if next == nil { next = nextMeeting(board.today.meetings, now: now).flatMap { date($0.start) } }
        return S27WWorkCounts(homeworkToday: homework, openMine: open, nextMeeting: next, updated: now)
    }

    /// 場8 次の会議（終わっていないもののうち、いちばん早いもの。終わりが無ければ 1 時間とみなす）
    static func nextMeeting(_ meetings: [S27WMeeting], now: Date = .now) -> S27WMeeting? {
        var best: (meeting: S27WMeeting, start: Date)?
        for m in meetings {
            guard let start = date(m.start) else { continue }
            let end = date(m.end) ?? start.addingTimeInterval(3600)
            guard end > now else { continue }
            if best == nil || start < best!.start { best = (m, start) }
        }
        return best?.meeting
    }

    // MARK: 守4 日と出どころ・たぶん

    /// 「11/24 15:30・会話・見本さん」（伏せるときは名前を伏せる）
    static func meta(_ item: S27WItem, mask: S27WMask?) -> String {
        var parts: [String] = []
        if let day = item.day {
            var d = AppFeeds.monthDay(day)
            if let time = item.time, !time.isEmpty { d += " " + time }
            parts.append(d)
        }
        if let src = item.src, !src.isEmpty { parts.append(srcLabel(src)) }
        if let who = item.who, !who.isEmpty { parts.append((mask?.person(who) ?? who)) }
        return parts.joined(separator: "・")
    }

    /// 出どころの言葉（分からないものはそのまま）
    static func srcLabel(_ src: String) -> String {
        switch src {
        case "talk": "会話"
        case "plaud": "会議の録音"
        case "line": "LINE"
        case "notice": "社内のお知らせ"
        case "chat": "雑談"
        case "calendar": "予定"
        case "app", "work-digest": "仕事のまとめ"
        default: src
        }
    }

    /// 札（たぶん・期限・ボール・そのままの日数）
    static func chips(_ item: S27WItem) -> [String] {
        var out: [String] = []
        if item.isMaybe { out.append("たぶん") }
        if let due = item.due, !due.isEmpty {
            out.append("期限 " + AppFeeds.monthDay(due) + (item.dueGuess == true ? "（仮）" : ""))
        }
        if let ball = ballLabel(item.ball) { out.append(ball) }
        if let age = item.ageDays, age >= 2 { out.append("\(age) 日そのまま") }
        return out
    }

    static func ballLabel(_ ball: String?) -> String? {
        switch ball {
        case "me": "自分の番"
        case "them": "相手待ち"
        default: nil
        }
    }

    static func kindLabel(_ kind: String?) -> String {
        switch kind {
        case "homework": "宿題"
        case "open": "未決"
        case "issue": "指摘"
        case "decided": "決まった"
        default: "項目"
        }
    }

    static func orgLabel(_ org: String?) -> String {
        switch org {
        case "self_company": "自社"
        case "client": "顧客"
        case "vendor": "ベンダー"
        default: "分からない"
        }
    }

    static let orgs = ["self_company", "client", "vendor", "unknown"]
    static let projectKinds = ["mine", "other", "side"]

    static func projectKindLabel(_ kind: String) -> String {
        switch kind {
        case "mine": "自分の案件"
        case "other": "他の案件"
        case "side": "副業"
        default: kind
        }
    }

    static func sideStatusLabel(_ status: String?) -> String {
        switch status {
        case "moved": "動いた"
        case "stopped": "止まった"
        default: "分からない"
        }
    }

    /// 場1 カードの数の行（「宿題 2・未決 1・指摘 0・最後に動いた日 11/24」）。案件の中の数なので順位ではない
    static func countsLine(_ p: S27WProject) -> String {
        var line = "宿題 \(p.counts.homework)・未決 \(p.counts.open)・指摘 \(p.counts.issue)"
        if let moved = p.lastMoved, HomeFeeds.isDay(moved) {
            line += "・最後に動いた日 " + AppFeeds.monthDay(moved)
        } else {
            line += "・最後に動いた日 分からない"
        }
        return line
    }

    /// 案9 節目までの残り（「節目: 見本の締め まで あと 5 日」）
    static func milestoneLine(_ m: S27WMilestone, today: String) -> String {
        let left = m.daysLeft ?? days(from: today, to: m.day) ?? 0
        let when: String
        if left > 0 {
            when = "あと \(left) 日"
        } else if left == 0 {
            when = "今日"
        } else {
            when = "\(-left) 日過ぎ"
        }
        return "節目: " + m.title + "（" + AppFeeds.monthDay(m.day) + "）まで " + when
    }

    // MARK: 他2 聞いた話の新しさ

    enum Freshness: Equatable, Sendable {
        case fresh, faded, old
    }

    /// 7 日より古いと薄く、30 日（か K2 の old）で「古い」（仮）。日が無ければ薄く
    static func freshness(day: String?, old: Bool?, today: String) -> Freshness {
        if old == true { return .old }
        guard let age = days(from: day, to: today) else { return .faded }
        if age >= oldDays { return .old }
        if age >= fadeDays { return .faded }
        return .fresh
    }

    /// 「11/20・見本さんから・会話」
    static func heardMeta(_ h: S27WHeard, mask: S27WMask?) -> String {
        var parts: [String] = []
        parts.append(h.day.map { AppFeeds.monthDay($0) } ?? "日が分からない")
        if let from = h.from, !from.isEmpty { parts.append((mask?.person(from) ?? from) + "から") }
        switch h.place {
        case "talk": parts.append("会話")
        case "notice": parts.append("社内のお知らせ")
        case "chat": parts.append("雑談")
        default: break
        }
        return parts.joined(separator: "・")
    }

    // MARK: 案6 進みの線（数が 2 つ以上ある名前だけ）

    struct Series: Equatable, Sendable {
        var label: String
        var points: [S27WProgress]
    }

    static func series(_ progress: [S27WProgress]) -> [Series] {
        var order: [String] = []
        var groups: [String: [S27WProgress]] = [:]
        for p in progress where p.value.isFinite && HomeFeeds.isDay(p.day) {
            if groups[p.label] == nil { order.append(p.label) }
            groups[p.label, default: []].append(p)
        }
        var out: [Series] = []
        for label in order {
            let points = (groups[label] ?? []).sorted { $0.day < $1.day }
            if points.count >= 2 { out.append(Series(label: label, points: points)) }
        }
        return out
    }

    // MARK: 場7 端末の写しの中で引く（家の PC の /work/ask が使えないとき）

    static func normalize(_ s: String) -> String {
        var t = s.lowercased().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s.lowercased()
        t = t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
        return t
    }

    static func localAnswers(_ board: S27WBoard, query: String, limit: Int = 5) -> [S27WAnswer] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        var hitIDs: [String] = []
        func hit(_ id: String) {
            if !hitIDs.contains(id) { hitIDs.append(id) }
        }
        for p in board.projects {
            let hay = normalize(p.name + " " + (p.client ?? "") + " " + p.id)
            if hay.contains(q) { hit(p.id); continue }
            for item in p.items + p.timeline where normalize(item.text).contains(q) {
                hit(p.id)
                break
            }
        }
        var out: [S27WAnswer] = []
        for id in hitIDs {
            if let p = board.project(id) { out.append(answer(p)) }
        }
        // 人の名前で引いたとき: その人の案件と、その人の宿題
        for person in board.people where normalize(person.name).contains(q) {
            for pid in person.projects where !hitIDs.contains(pid) {
                if let p = board.project(pid) {
                    hitIDs.append(pid)
                    out.append(answer(p))
                }
            }
            if person.projects.isEmpty {
                let line = [person.team, person.role].compactMap { $0 }.joined(separator: "・")
                out.append(S27WAnswer(projectID: nil, name: person.name, statusLine: line.isEmpty ? nil : line, lastDecided: nil,
                                      open: Array(person.theirHomework.prefix(5)), link: S27WLink.person(person.id).url?.absoluteString))
            }
        }
        return Array(out.prefix(limit))
    }

    static func answer(_ p: S27WProject) -> S27WAnswer {
        let decided = (p.items + p.timeline).filter { $0.kind == "decided" }
        let last = decided.max { a, b in when(a) < when(b) }
        let open = p.items.filter { $0.kind != "decided" && !$0.isDone }
        return S27WAnswer(projectID: p.id, name: p.name, statusLine: p.statusLine, lastDecided: last,
                          open: Array(open.prefix(5)), link: S27WLink.project(p.id).url?.absoluteString)
    }

    /// 並べるための「日 時刻」
    static func when(_ item: S27WItem) -> String {
        let day: String = item.day ?? ""
        let time: String = item.time ?? ""
        return day + " " + time
    }

    /// Siri・ショートカットで返す文（いちばん上の 1 件と、ほかの数）
    static func spoken(_ answers: [S27WAnswer], mask: S27WMask?) -> String {
        guard let first = answers.first else { return "仕事の記録に、その件は見つかりませんでした。" }
        func t(_ s: String) -> String { mask?.apply(s) ?? s }
        var lines: [String] = [t(first.name) + "。"]
        if let status = first.statusLine, !status.isEmpty { lines.append(t(status) + "。") }
        if let d = first.lastDecided {
            let when = d.day.map { AppFeeds.monthDay($0) + "に" } ?? ""
            lines.append("最後に決まったこと（" + when + (d.isMaybe ? "たぶん" : "") + "）: " + t(d.text) + "。")
        }
        if !first.open.isEmpty { lines.append("開いているものが \(first.open.count) 件。") }
        if answers.count > 1 { lines.append("ほかに \(answers.count - 1) 件見つかりました。") }
        return lines.joined()
    }

    // MARK: K4 答えの中身（家の PC の FEEDBACK と同じ形。どれも day を付ける）

    static let feedbackKinds = ["work_confirm", "work_edit", "work_numbers", "work_notice", "work_done"]
    static let editFields = ["name", "team", "role", "org", "client", "kind"]

    /// POST /feedback の中身。決まった形でなければ nil
    static func feedback(kind: String, id: String, value: String, day: String) -> Data? {
        guard feedbackKinds.contains(kind), HomeFeeds.isDay(day) else { return nil }
        switch kind {
        case "work_confirm":
            guard HomeFeeds.isID(id), !value.isEmpty, value.count <= 200 else { return nil }
        case "work_edit":
            guard HomeFeeds.isID(id), id.hasPrefix("wp-") || id.hasPrefix("wm-"), !value.isEmpty else { return nil }
        case "work_numbers":
            guard id.isEmpty || HomeFeeds.isID(id) else { return nil }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= textLimit else { return nil }
        case "work_notice":
            guard id.isEmpty else { return nil }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= textLimit else { return nil }
        case "work_done":
            guard HomeFeeds.isID(id), value == "done" || value == "undo" else { return nil }
        default:
            return nil
        }
        let object: [String: String] = ["kind": kind, "id": id, "value": value, "day": day]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 人8 直した欄だけの JSON の文（{"name":…,"team":…}）。何も直していなければ nil。名前は空にできない
    static func editValue(_ changes: [String: String]) -> String? {
        var out: [String: String] = [:]
        for (key, raw) in changes where editFields.contains(key) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "name" && value.isEmpty { continue }
            if key == "org" && !orgs.contains(value) { continue }
            if key == "kind" && !projectKinds.contains(value) { continue }
            out[key] = String(value.prefix(80))
        }
        guard !out.isEmpty, let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 前と違う欄だけ（前の値が無いものは空と見る）
    static func changed(old: [String: String], new: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in new {
            let a = (old[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let b = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if a != b { out[key] = b }
        }
        return out
    }

    /// 守6 まとめて 1 回の答え（選んだものだけ・選べる値だけ）。id の順で返す
    static func confirmAnswers(_ items: [S27WConfirmItem], picks: [String: String]) -> [(id: String, value: String)] {
        var out: [(id: String, value: String)] = []
        for item in items {
            guard let value = picks[item.id], item.choices.contains(where: { $0.value == value }) else { continue }
            out.append((id: item.id, value: value))
        }
        return out
    }

    /// まだ答えていない確かめ（答えた id は次から出さない。1 回に 60 件まで・仮）
    static func unanswered(_ items: [S27WConfirmItem], answered: Set<String>, limit: Int = 60) -> [S27WConfirmItem] {
        Array(items.filter { !answered.contains($0.id) && !$0.choices.isEmpty }.prefix(limit))
    }

    /// 開く先として使える道か（lifelog:// と https だけ）
    static func openable(_ link: String?) -> URL? {
        guard let link, let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return nil }
        return ["https", "lifelog"].contains(scheme) ? url : nil
    }
}

// MARK: - K6 リンク

enum S27WLink: Equatable, Hashable, Sendable {
    case home
    case project(String)
    case person(String)
    case confirm
    /// 他3 社内のお知らせを入れる画面（アプリの中だけ。リンクは無い）
    case notice

    var id: String {
        switch self {
        case .home: "work"
        case .project(let p): "work-project-" + p
        case .person(let p): "work-person-" + p
        case .confirm: "work-confirm"
        case .notice: "work-notice"
        }
    }

    /// lifelog://work・lifelog://work/project/<id>・lifelog://work/person/<id>・lifelog://work/confirm（?w= などは見ない）
    static func parse(_ url: URL) -> S27WLink? {
        guard url.scheme == "lifelog", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (parts.host ?? "").lowercased() == "work" else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        guard let first = path.first else { return .home }
        switch first.lowercased() {
        case "project": return path.count >= 2 && HomeFeeds.isID(path[1]) ? .project(path[1]) : .home
        case "person": return path.count >= 2 && HomeFeeds.isID(path[1]) ? .person(path[1]) : .home
        case "confirm": return .confirm
        default: return .home
        }
    }

    var url: URL? {
        switch self {
        case .home: URL(string: "lifelog://work")
        case .project(let p): URL(string: "lifelog://work/project/" + p)
        case .person(let p): URL(string: "lifelog://work/person/" + p)
        case .confirm: URL(string: "lifelog://work/confirm")
        case .notice: nil
        }
    }
}

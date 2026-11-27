import Foundation

// s33（2026-11-27）アプリ担当 S33A の決まり（決まった入力から決まった出力だけ）。動きは S33ABook.swift、画面は S33AViews.swift。
// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 22」（強1〜強14）・「追記 23」（強15〜強31）。しきい値はどれも仮。
// 取り決め: K33-1（GET /s33 の中身）・K33-2（POST /feedback の ramen_mark・feature_seen・device_ok）。形は変えない。
// - 強15 どこ？: 画面と機能の名前（日本語の言い換えも）で探す目次（S33AWhere）
// - 強5 使われた数: 1 日 1 回 feature_seen（数と英字の名前だけ。中身は送らない）・30 日開かれていないものを畳む候補（S33AFold）
// - 強16 今日タブの並び: 本人の並び → よく使う 3 つを上・30 日使われないカードは「ほかのカード」へ（S33AOrder）
// - 強6 問いの山のふた: 4 種類合わせて 30 件・言葉の候補は 20 語まで（仮・設定で変えられる。S33ACap）
// - 強8 実機で動いた印: 版ごとに、開いて落ちずに閉じた画面の英字の名前（S33ADevice）
// - 強27 時計の版: iPhone と時計の版を並べる（S33AWatch）
// - 強22 ラーメンの 1 押し: ramen_mark（S33ARamen）
// 家の PC の受け口（s33p）: 名前は英数字と _ . : - と空白で 64 字まで・counts は 200 個まで・screens は 100 個まで・
// place は 80 字まで・build は英数字と . で 20 字まで。日本語の名前は端末の表示だけに使う。

// MARK: - K33-1 アプリに出すもの（GET /s33）

/// 数でも文字でも読む（"12"・12・12.5）。読めなければ nil
struct S33ANum: Decodable, Equatable, Sendable {
    let value: Double

    init(_ value: Double) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        var read: Double?
        if let d = try? c.decode(Double.self) {
            read = d
        } else if let s = try? c.decode(String.self) {
            read = Double(s.trimmingCharacters(in: .whitespaces))
        }
        // 無限・とても大きい数は読まない（Int に直すときに落ちないように）
        guard let d = read, d.isFinite, abs(d) < 1e12 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "数ではない")
        }
        value = d
    }
}

extension KeyedDecodingContainer {
    /// 省ける・形が違えば nil
    func s33a<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// 数（文字でもよい）
    func s33aNum(_ key: Key) -> Double? {
        let n: S33ANum? = s33a(key)
        return n?.value
    }

    /// 1 行ずつ読む（読めない行は飛ばす・無ければ空）
    func s33aList<T: Decodable>(_ key: Key) -> [T] {
        let rows: [LossyRow<T>]? = s33a(key)
        return (rows ?? []).compactMap(\.value)
    }

    /// 文字の並び（文字でないものは飛ばす）
    func s33aStrings(_ key: Key) -> [String] {
        let rows: [LossyRow<String>]? = s33a(key)
        return (rows ?? []).compactMap(\.value).filter { !$0.isEmpty }
    }
}

/// 強1 止まっているもの
struct S33AStopped: Decodable, Equatable, Sendable {
    var source: String
    var lastOK: String?
    var missing: String?
    var why: String?

    enum CodingKeys: String, CodingKey { case source, last_ok, missing, why }

    init(source: String, lastOK: String? = nil, missing: String? = nil, why: String? = nil) {
        self.source = source
        self.lastOK = lastOK
        self.missing = missing
        self.why = why
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        lastOK = c.s33a(.last_ok)
        missing = c.s33a(.missing)
        why = c.s33a(.why)
    }
}

/// 強14・強3・強10 操作待ち（今ある操作待ちと同じ一覧に足す）
struct S33AWaiting: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var how: String?
    var since: String?
    var kind: String?

    enum CodingKeys: String, CodingKey { case id, title, how, since, kind }

    init(id: String, title: String, how: String? = nil, since: String? = nil, kind: String? = nil) {
        self.id = id
        self.title = title
        self.how = how
        self.since = since
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        how = c.s33a(.how)
        since = c.s33a(.since)
        kind = c.s33a(.kind)
    }
}

/// 強4 定期の仕事の棚卸し
struct S33ATasks: Decodable, Equatable, Sendable {
    struct Candidate: Decodable, Equatable, Sendable {
        var name: String
        var why: String?
        var cpuSeconds: Double?
        var lastRead: String?

        enum CodingKeys: String, CodingKey { case name, why, cpu_s, last_read }

        init(name: String, why: String? = nil, cpuSeconds: Double? = nil, lastRead: String? = nil) {
            self.name = name
            self.why = why
            self.cpuSeconds = cpuSeconds
            self.lastRead = lastRead
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            why = c.s33a(.why)
            cpuSeconds = c.s33aNum(.cpu_s)
            lastRead = c.s33a(.last_read)
        }
    }

    var total: Int?
    var stopCandidates: [Candidate]

    enum CodingKeys: String, CodingKey { case total, stop_candidates }

    init(total: Int?, stopCandidates: [Candidate]) {
        self.total = total
        self.stopCandidates = stopCandidates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = c.s33aNum(.total).map { Int($0) }
        stopCandidates = c.s33aList(.stop_candidates)
    }
}

/// 強9 効いたか
struct S33AEffect: Decodable, Equatable, Sendable {
    var bundle: String
    var metric: String?
    var now: Double?
    var prev: Double?

    enum CodingKeys: String, CodingKey { case bundle, metric, now, prev }

    init(bundle: String, metric: String? = nil, now: Double? = nil, prev: Double? = nil) {
        self.bundle = bundle
        self.metric = metric
        self.now = now
        self.prev = prev
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundle = try c.decode(String.self, forKey: .bundle)
        metric = c.s33a(.metric)
        now = c.s33aNum(.now)
        prev = c.s33aNum(.prev)
    }
}

/// 強12・強13 仮説ボード
struct S33ABet: Decodable, Equatable, Sendable {
    var name: String
    var hypothesis: String?
    var stopIf: String?
    var stake: Double?
    var payout: Double?
    var runs: Int?
    var alive: Bool?

    enum CodingKeys: String, CodingKey { case name, hypothesis, stop_if, month, alive }
    enum MonthKeys: String, CodingKey { case stake, payout, runs }

    init(name: String, hypothesis: String? = nil, stopIf: String? = nil, stake: Double? = nil, payout: Double? = nil,
         runs: Int? = nil, alive: Bool? = nil) {
        self.name = name
        self.hypothesis = hypothesis
        self.stopIf = stopIf
        self.stake = stake
        self.payout = payout
        self.runs = runs
        self.alive = alive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        hypothesis = c.s33a(.hypothesis)
        stopIf = c.s33a(.stop_if)
        alive = c.s33a(.alive)
        if let m = try? c.nestedContainer(keyedBy: MonthKeys.self, forKey: .month) {
            stake = m.s33aNum(.stake)
            payout = m.s33aNum(.payout)
            runs = m.s33aNum(.runs).map { Int($0) }
        }
    }
}

/// 強28 C の空き
struct S33ADisk: Decodable, Equatable, Sendable {
    struct Growth: Decodable, Equatable, Sendable {
        var what: String
        var gb: Double?

        enum CodingKeys: String, CodingKey { case what, gb }

        init(what: String, gb: Double?) {
            self.what = what
            self.gb = gb
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            what = try c.decode(String.self, forKey: .what)
            gb = c.s33aNum(.gb)
        }
    }

    var freeGB: Double?
    var freePct: Double?
    var growth: [Growth]

    enum CodingKeys: String, CodingKey { case c_free_gb, c_free_pct, growth }

    init(freeGB: Double?, freePct: Double?, growth: [Growth] = []) {
        self.freeGB = freeGB
        self.freePct = freePct
        self.growth = growth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        freeGB = c.s33aNum(.c_free_gb)
        freePct = c.s33aNum(.c_free_pct)
        growth = c.s33aList(.growth)
    }
}

/// 強17 職場の人ごとの話のネタ（職場の中身。時計・ウィジェット・通知には出さない）
struct S33ASmallTalk: Decodable, Equatable, Sendable {
    var personID: String
    var name: String?
    var lines: [String]
    var updated: String?

    enum CodingKeys: String, CodingKey { case person_id, name, lines, updated }

    init(personID: String, name: String? = nil, lines: [String], updated: String? = nil) {
        self.personID = personID
        self.name = name
        self.lines = lines
        self.updated = updated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personID = try c.decode(String.self, forKey: .person_id)
        name = c.s33a(.name)
        lines = Array(c.s33aStrings(.lines).prefix(S33ARules.smallTalkLines))
        updated = c.s33a(.updated)
    }
}

/// 強18 会議での自分の話し方（職場の中身）
struct S33ASpeaking: Decodable, Equatable, Sendable {
    struct Meeting: Decodable, Equatable, Sendable {
        var title: String
        var myShare: Double?
        var overlaps: Int?
        var longRuns: Int?

        enum CodingKeys: String, CodingKey { case title, my_share, overlaps, long_runs }

        init(title: String, myShare: Double? = nil, overlaps: Int? = nil, longRuns: Int? = nil) {
            self.title = title
            self.myShare = myShare
            self.overlaps = overlaps
            self.longRuns = longRuns
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            myShare = c.s33aNum(.my_share)
            overlaps = c.s33aNum(.overlaps).map { Int($0) }
            // long_runs は数でも、長く話した所の並びでもよい（並びならその数）
            if let n = c.s33aNum(.long_runs) {
                longRuns = Int(n)
            } else if let rows: [LossyRow<S33AAny>] = c.s33a(.long_runs) {
                longRuns = rows.count
            }
        }
    }

    var week: String?
    var meetings: [Meeting]

    enum CodingKeys: String, CodingKey { case week, meetings }

    init(week: String?, meetings: [Meeting]) {
        self.week = week
        self.meetings = meetings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = c.s33a(.week)
        meetings = c.s33aList(.meetings)
    }
}

/// 中身を見ずに 1 つ読み飛ばす（並びの数だけ数えるとき）
struct S33AAny: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

/// 強19 出す前のチェック（上司の指摘の型。職場の中身）
struct S33AReviewRule: Decodable, Equatable, Sendable {
    var type: String
    var count: Int?
    var check: String?

    enum CodingKeys: String, CodingKey { case type, count, check }

    init(type: String, count: Int? = nil, check: String? = nil) {
        self.type = type
        self.count = count
        self.check = check
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        count = c.s33aNum(.count).map { Int($0) }
        check = c.s33a(.check)
    }
}

/// 強20 副業の稼働
struct S33ASideHours: Decodable, Equatable, Sendable {
    struct Day: Decodable, Equatable, Sendable {
        var day: String
        var minutes: Int
        var overlapWork: Bool

        enum CodingKeys: String, CodingKey { case day, minutes, overlap_work }

        init(day: String, minutes: Int, overlapWork: Bool = false) {
            self.day = day
            self.minutes = minutes
            self.overlapWork = overlapWork
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(String.self, forKey: .day)
            minutes = Int(c.s33aNum(.minutes) ?? 0)
            // 数（重なった分）でも、はい・いいえでもよい
            if let b: Bool = c.s33a(.overlap_work) {
                overlapWork = b
            } else {
                overlapWork = (c.s33aNum(.overlap_work) ?? 0) > 0
            }
        }
    }

    var month: String?
    var days: [Day]

    enum CodingKeys: String, CodingKey { case month, days }

    init(month: String?, days: [Day]) {
        self.month = month
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = c.s33a(.month)
        days = c.s33aList(.days)
    }

    var totalMinutes: Int { days.reduce(0) { $0 + max(0, $1.minutes) } }
    var overlapDays: Int { days.filter(\.overlapWork).count }
}

/// 強21 経費の候補
struct S33AExpense: Decodable, Equatable, Sendable {
    var day: String?
    var shop: String
    var amount: Double?
    var why: String?
    var src: String?

    enum CodingKeys: String, CodingKey { case day, shop, amount, why, src }

    init(day: String? = nil, shop: String, amount: Double? = nil, why: String? = nil, src: String? = nil) {
        self.day = day
        self.shop = shop
        self.amount = amount
        self.why = why
        self.src = src
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shop = try c.decode(String.self, forKey: .shop)
        day = c.s33a(.day)
        amount = c.s33aNum(.amount)
        why = c.s33a(.why)
        src = c.s33a(.src)
    }
}

/// 強22 ラーメン帳（本人の年の目安と比べて、どれだけ拾えているか）
struct S33ARamen: Decodable, Equatable, Sendable {
    struct Recent: Decodable, Equatable, Sendable {
        var day: String
        var shop: String?
        var how: String?

        enum CodingKeys: String, CodingKey { case day, shop, how }

        init(day: String, shop: String? = nil, how: String? = nil) {
            self.day = day
            self.shop = shop
            self.how = how
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(String.self, forKey: .day)
            shop = c.s33a(.shop)
            how = c.s33a(.how)
        }
    }

    var year: Int?
    var bowls: Int?
    var yardstick: Int?
    /// 0〜1 の割合（1 より大きければ % として読む）
    var coverage: Double?
    var recent: [Recent]

    enum CodingKeys: String, CodingKey { case year, bowls, yardstick, coverage, recent }

    init(year: Int? = nil, bowls: Int? = nil, yardstick: Int? = nil, coverage: Double? = nil, recent: [Recent] = []) {
        self.year = year
        self.bowls = bowls
        self.yardstick = yardstick
        self.coverage = coverage
        self.recent = recent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = c.s33aNum(.year).map { Int($0) }
        bowls = c.s33aNum(.bowls).map { Int($0) }
        yardstick = c.s33aNum(.yardstick).map { Int($0) }
        coverage = c.s33aNum(.coverage)
        recent = c.s33aList(.recent)
    }
}

/// 強23 車の利用
struct S33ACar: Decodable, Equatable, Sendable {
    var day: String
    var from: String?
    var to: String?
    var hours: Double?
    var yen: Double?
    var station: String?

    enum CodingKeys: String, CodingKey { case day, from, to, hours, yen, station }

    init(day: String, from: String? = nil, to: String? = nil, hours: Double? = nil, yen: Double? = nil, station: String? = nil) {
        self.day = day
        self.from = from
        self.to = to
        self.hours = hours
        self.yen = yen
        self.station = station
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        from = c.s33a(.from)
        to = c.s33a(.to)
        hours = c.s33aNum(.hours)
        yen = c.s33aNum(.yen)
        station = c.s33a(.station)
    }
}

/// 強24 年のまとめ（12 月だけ）
struct S33AYear: Decodable, Equatable, Sendable {
    struct Part: Decodable, Equatable, Sendable {
        var title: String
        var lines: [String]

        enum CodingKeys: String, CodingKey { case title, lines }

        init(title: String, lines: [String]) {
            self.title = title
            self.lines = lines
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            lines = c.s33aStrings(.lines)
        }
    }

    var year: Int?
    var sections: [Part]

    enum CodingKeys: String, CodingKey { case year, sections }

    init(year: Int?, sections: [Part]) {
        self.year = year
        self.sections = sections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = c.s33aNum(.year).map { Int($0) }
        sections = c.s33aList(.sections)
    }
}

/// 強25 欲しい物の候補（やることには入れない）
struct S33AWish: Decodable, Equatable, Sendable {
    var text: String
    var day: String?
    var said: String?

    enum CodingKeys: String, CodingKey { case text, day, said }

    init(text: String, day: String? = nil, said: String? = nil) {
        self.text = text
        self.day = day
        self.said = said
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        day = c.s33a(.day)
        said = c.s33a(.said)
    }
}

/// 強26 約束の棚の数・強31 答え合わせ
struct S33ACount: Equatable, Sendable {
    var a: Int?
    var b: Int?
}

/// K33-1 の全部（どの鍵も省ける。1 つの鍵が壊れていても、ほかは読む）
struct S33AFeed: Decodable, Equatable, Sendable {
    var stopped: [S33AStopped] = []
    var waiting: [S33AWaiting] = []
    var tasks: S33ATasks?
    var effects: [S33AEffect] = []
    var bets: [S33ABet] = []
    var disk: S33ADisk?
    var smallTalk: [S33ASmallTalk] = []
    var speaking: S33ASpeaking?
    var reviewRules: [S33AReviewRule] = []
    var sideHours: S33ASideHours?
    var expenses: [S33AExpense] = []
    var ramen: S33ARamen?
    var car: [S33ACar] = []
    var year: S33AYear?
    var wishes: [S33AWish] = []
    /// 約束の棚（kept・closed）
    var promisesKept: S33ACount?
    /// 答え合わせ（score・total）と週
    var askCheck: S33ACount?
    var askCheckWeek: String?

    enum CodingKeys: String, CodingKey {
        case stopped, waiting, tasks, effects, bets, disk, small_talk, speaking, review_rules, side_hours, expenses, ramen, car, year,
             wishes, promises_kept, ask_check
    }
    enum KeptKeys: String, CodingKey { case kept, closed }
    enum AskKeys: String, CodingKey { case week, score, total }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stopped = c.s33aList(.stopped)
        let waitingRows: [S33AWaiting] = c.s33aList(.waiting)
        waiting = waitingRows.filter { HomeFeeds.isID($0.id) && !$0.title.isEmpty }
        tasks = c.s33a(.tasks)
        effects = c.s33aList(.effects)
        bets = c.s33aList(.bets)
        disk = c.s33a(.disk)
        let talkRows: [S33ASmallTalk] = c.s33aList(.small_talk)
        smallTalk = talkRows.filter { !$0.lines.isEmpty }
        speaking = c.s33a(.speaking)
        reviewRules = c.s33aList(.review_rules)
        sideHours = c.s33a(.side_hours)
        expenses = c.s33aList(.expenses)
        ramen = c.s33a(.ramen)
        car = c.s33aList(.car)
        year = c.s33a(.year)
        wishes = c.s33aList(.wishes)
        if let k = try? c.nestedContainer(keyedBy: KeptKeys.self, forKey: .promises_kept) {
            let kept = k.s33aNum(.kept).map { Int($0) }, closed = k.s33aNum(.closed).map { Int($0) }
            if kept != nil || closed != nil { promisesKept = S33ACount(a: kept, b: closed) }
        }
        if let k = try? c.nestedContainer(keyedBy: AskKeys.self, forKey: .ask_check) {
            let score = k.s33aNum(.score).map { Int($0) }, total = k.s33aNum(.total).map { Int($0) }
            if score != nil || total != nil { askCheck = S33ACount(a: score, b: total) }
            askCheckWeek = k.s33a(.week)
        }
    }

    /// 暮らしの節に出すものがあるか（年のまとめは 12 月だけ）
    func hasLife(month: Int) -> Bool {
        !car.isEmpty || (month == 12 && !(year?.sections.isEmpty ?? true)) || !wishes.isEmpty || promisesKept != nil || askCheck != nil
    }

    /// 設定の奥に出すものがあるか
    var hasDeep: Bool {
        sideHours != nil || !expenses.isEmpty || !bets.isEmpty || tasks != nil || !effects.isEmpty || disk != nil
    }
}

enum S33AReply: Equatable, Sendable {
    case feed(S33AFeed)
    /// {"available":false}（写しを消して出さない）
    case none
    /// 読めない（前の写しを残す）
    case bad
}

enum S33ARules {
    /// 家の PC の features の名前（K33-1）
    static let feature = "s33"
    /// 話のネタは 3 行まで
    static let smallTalkLines = 3

    /// GET /s33 の答えを読む
    static func reply(_ data: Data) -> S33AReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .bad }
        if (object["available"] as? Bool) == false { return .none }
        guard let feed = try? JSONDecoder().decode(S33AFeed.self, from: data) else { return .bad }
        return .feed(feed)
    }

    // MARK: 家の PC の受け口の形（s33p）

    /// 名前: 英数字と _ . : - と空白で 1〜64 字
    static func isName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        return s.unicodeScalars.allSatisfy { u in
            (u.value >= 0x30 && u.value <= 0x39) || (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A)
                || "_.:- ".unicodeScalars.contains(u)
        }
    }

    /// 版: 英数字と . で 1〜20 字
    static func isBuild(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 20 else { return false }
        return s.unicodeScalars.allSatisfy { u in
            (u.value >= 0x30 && u.value <= 0x39) || (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) || u == "."
        }
    }

    static let maxCounts = 200
    static let maxScreens = 100
    static let maxPlace = 80

    // MARK: 強22 ramen_mark

    private struct RamenBody: Encodable {
        let at: String
        let place: String?
        let lat: Double?
        let lon: Double?

        enum CodingKeys: String, CodingKey { case kind, at, place, lat, lon }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("ramen_mark", forKey: .kind)
            try c.encode(at, forKey: .at)
            if let place { try c.encode(place, forKey: .place) } else { try c.encodeNil(forKey: .place) }
            if let lat { try c.encode(lat, forKey: .lat) } else { try c.encodeNil(forKey: .lat) }
            if let lon { try c.encode(lon, forKey: .lon) } else { try c.encodeNil(forKey: .lon) }
        }
    }

    /// {"kind":"ramen_mark","at":ISO,"place":str|null,"lat":num|null,"lon":num|null}。at は押した時刻。
    /// 場所の名前は 80 字まで（空なら null）。緯度・経度は 2 つそろって範囲の中のときだけ（小数 5 桁・約 1 m）
    static func ramenBody(at: Date, place: String?, lat: Double?, lon: Double?, timeZone: TimeZone = .current) -> Data? {
        let name = place?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut: String? = (name?.isEmpty ?? true) ? nil : String(name!.prefix(maxPlace))
        var la: Double?
        var lo: Double?
        if let lat, let lon, lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 {
            la = (lat * 100_000).rounded() / 100_000
            lo = (lon * 100_000).rounded() / 100_000
        }
        let body = RamenBody(at: MothershipOutbox.isoString(at, timeZone: timeZone), place: cut, lat: la, lon: lo)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(body)
    }

    // MARK: 強5 feature_seen

    private struct SeenBody: Encodable {
        let kind = "feature_seen"
        let day: String
        let counts: [String: Int]
    }

    /// その日の Tally の数から、送る数を作る（画面は "screen." を外した英字の名前・機能は "feat.<slug>"・今日のカードは "card.<名前>"）。
    /// 名前の形に合わないもの・0 以下は外す。200 個より多ければ数の多い順に 200 個（同じ数なら名前の順）
    static func seenCounts(_ tally: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, n) in tally where n > 0 {
            var name: String?
            if key.hasPrefix("screen.") {
                name = String(key.dropFirst("screen.".count))
            } else if key.hasPrefix(S25UFeatures.tallyPrefix) {
                name = key
            } else if key.hasPrefix(S33AOrder.tallyPrefix) {
                name = "card." + String(key.dropFirst(S33AOrder.tallyPrefix.count))
            }
            guard let name, isName(name) else { continue }
            out[name, default: 0] += n
        }
        guard out.count > maxCounts else { return out }
        let kept = out.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(maxCounts)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// {"kind":"feature_seen","day":"YYYY-MM-DD","counts":{名前:回数}}。数が無い日・日の形が違えば nil
    static func seenBody(day: String, tally: [String: Int]) -> Data? {
        guard HomeFeeds.isDay(day) else { return nil }
        let counts = seenCounts(tally)
        guard !counts.isEmpty else { return nil }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(SeenBody(day: day, counts: counts))
    }

    /// まだ送っていない、終わった日（昨日まで・古くても 7 日前まで。古い順）
    static func seenDaysToSend(lastSent: String?, today: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> [String] {
        var out: [String] = []
        for back in stride(from: 7, through: 1, by: -1) {
            guard let day = shift(today, by: -back, calendar: calendar) else { continue }
            if let lastSent, day <= lastSent { continue }
            out.append(day)
        }
        return out
    }

    /// "YYYY-MM-DD" を何日ずらす（読めなければ nil）
    static func shift(_ day: String, by days: Int, calendar: Calendar = Calendar(identifier: .gregorian)) -> String? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)),
              let moved = calendar.date(byAdding: .day, value: days, to: d) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: moved)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: 強8 device_ok

    private struct DeviceBody: Encodable {
        let kind = "device_ok"
        let build: String
        let screens: [String]
        let crash = false
    }

    /// {"kind":"device_ok","build":str,"screens":[名前],"crash":false}。名前の形に合わないものは外す・100 個ずつに分ける。
    /// 版の形が違う・送る名前が無いときは空
    static func deviceBodies(build: String, screens: [String]) -> [Data] {
        guard isBuild(build) else { return [] }
        var names: [String] = []
        for s in screens.sorted() where isName(s) && !names.contains(s) { names.append(s) }
        guard !names.isEmpty else { return [] }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var out: [Data] = []
        var i = 0
        while i < names.count {
            let part = Array(names[i..<min(names.count, i + maxScreens)])
            if let data = try? e.encode(DeviceBody(build: build, screens: part)) { out.append(data) }
            i += maxScreens
        }
        return out
    }

    // MARK: 表示の文

    /// ラーメンの小さな 1 行: 「今年 13 杯・目安 200 杯の 7%（拾えている割合）」
    static func ramenLine(_ r: S33ARamen?, marks: Int) -> String? {
        var parts: [String] = []
        if let r, let bowls = r.bowls { parts.append("今年 \(bowls) 杯") }
        if let r, let p = coveragePercent(r) {
            let stick = r.yardstick.map { "目安 \($0) 杯の" } ?? ""
            parts.append(stick + "\(p)%（拾えている割合）")
        }
        if marks > 0 { parts.append("ここで押した印 \(marks)") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// 拾えている割合（%・0〜999）。coverage が無ければ bowls / yardstick
    static func coveragePercent(_ r: S33ARamen) -> Int? {
        if let c = r.coverage, c.isFinite, c >= 0 {
            return min(999, Int((c <= 1 ? c * 100 : c).rounded()))
        }
        if let b = r.bowls, let y = r.yardstick, y > 0 { return min(999, Int((Double(b) / Double(y) * 100).rounded())) }
        return nil
    }

    /// 止まっているもの 1 行: 「止まっているもの: A・B ほか 1」
    static func stoppedLine(_ list: [S33AStopped]) -> String? {
        let names = list.map(\.source).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: "・")
        return "止まっているもの: " + shown + (names.count > 2 ? " ほか \(names.count - 2)" : "")
    }

    /// 割合（0〜1 でも %でも）を「38%」に
    static func percentText(_ v: Double?) -> String? {
        guard let v, v.isFinite, v >= 0 else { return nil }
        return "\(Int((v <= 1 ? v * 100 : v).rounded()))%"
    }

    /// 円の文字「1,280 円」
    static func yenText(_ v: Double?) -> String? {
        guard let v, v.isFinite else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))") + " 円"
    }

    /// 分を「3 時間 20 分」に
    static func minutesText(_ m: Int) -> String {
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r) 分" }
        return r == 0 ? "\(h) 時間" : "\(h) 時間 \(r) 分"
    }

    /// 前と比べた差の文字（「+3」「−1.5」「同じ」・どちらか無ければ nil）
    static func diffText(now: Double?, prev: Double?) -> String? {
        guard let now, let prev, now.isFinite, prev.isFinite else { return nil }
        let d = now - prev
        if abs(d) < 0.0001 { return "前と同じ" }
        let mag = abs(d)
        let text = mag == mag.rounded() ? String(Int(mag)) : String(format: "%.1f", mag)
        return "前より " + (d > 0 ? "+" : "−") + text
    }

    /// 日の表し方「11/8」（時刻つきの ISO でも頭の 10 字で読む）
    static func dayText(_ day: String) -> String {
        AppFeeds.monthDay(String(day.prefix(10)))
    }

    /// 数を短く（整数なら整数で）
    static func numText(_ v: Double?) -> String? {
        guard let v, v.isFinite else { return nil }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - 強16 今日タブの並び

enum S33AOrder {
    /// 今日のカードを押した数（Tally。"s33a.card." + カードの名前）
    static let tallyPrefix = "s33a.card."
    /// 上へ出すよく使うカードの数（本人の並びを含めて）
    static let promote = 3
    /// 使われていないとみなす日数
    static let unusedDays = 30
    /// いつも上にあり、動かさない・畳まないカード（録れているか・今日の三つ・今日の 1 問・気をつけること）
    static let fixed: Set<S24Today.Card> = [.hero, .answer, .ask, .alerts]

    static func tallyName(_ card: S24Today.Card) -> String { tallyPrefix + card.rawValue }

    /// カードの使われた数に入れる、前からある数の名前（仮）
    static let usedBy: [S24Today.Card: [String]] = [
        .nightMood: ["mood.answered"],
        .checkups: ["checkup.answered", "checkup.skipped"],
        .promises: ["promise.added", "promise.ignored"],
        .knowMe: ["know.answered"],
    ]

    /// 30 日の Tally の数から、カードごとの使われた数
    static func uses(_ sums: [String: Int]) -> [S24Today.Card: Int] {
        var out: [S24Today.Card: Int] = [:]
        for card in S24Today.Card.allCases {
            var n = sums[tallyName(card)] ?? 0
            for key in usedBy[card] ?? [] { n += sums[key] ?? 0 }
            if n > 0 { out[card] = n }
        }
        return out
    }

    /// 畳める（隠せる）カード
    static var foldable: [S24Today.Card] {
        S24Today.Card.allCases.filter { !fixed.contains($0) && $0 != .record }
    }

    /// 並べ直す。
    /// 1. 本人が畳んだカードは出さない（fixed は畳めない）
    /// 2. 上は fixed（元の順）→ 本人の並び（pinned の順）→ よく使うもの（数の多い順・同じなら元の順。本人の並びと合わせて 3 つまで・数が 1 以上）
    /// 3. 数え始めて 30 日たっていれば、上にあって 30 日使われていないカード（fixed・本人の並び・よく使うもの以外）は「ほか」へ
    /// 4. 残りは元の場所・元の順（「ほか」に下ろしたものは「ほか」の終わり）
    static func apply(top: [S24Today.Card], more: [S24Today.Card], uses: [S24Today.Card: Int], pinned: [S24Today.Card],
                      hidden: Set<S24Today.Card>, countedDays: Int?) -> (top: [S24Today.Card], more: [S24Today.Card]) {
        let all = top + more
        let present = Set(all)
        let visible: (S24Today.Card) -> Bool = { fixed.contains($0) || !hidden.contains($0) }
        var pins: [S24Today.Card] = []
        for p in pinned where present.contains(p) && !fixed.contains(p) && visible(p) && !pins.contains(p) { pins.append(p) }
        let room = max(0, promote - pins.count)
        let ranked = all.enumerated()
            .filter { !fixed.contains($0.element) && !pins.contains($0.element) && visible($0.element) && (uses[$0.element] ?? 0) > 0 }
            .sorted { a, b in
                let na = uses[a.element] ?? 0, nb = uses[b.element] ?? 0
                return na != nb ? na > nb : a.offset < b.offset
            }
            .prefix(room)
            .map(\.element)
        let raised = Set(pins + ranked)
        let judge = (countedDays ?? 0) >= unusedDays
        // 上に残すもの（元の順）。上げるものは、残したもののうち最後の fixed のすぐ後ろに入れる
        var newTop: [S24Today.Card] = []
        var lowered: [S24Today.Card] = []
        for card in top where visible(card) && !raised.contains(card) {
            if !fixed.contains(card) && judge && (uses[card] ?? 0) == 0 {
                lowered.append(card)
            } else {
                newTop.append(card)
            }
        }
        let at = newTop.lastIndex(where: { fixed.contains($0) }).map { $0 + 1 } ?? 0
        newTop.insert(contentsOf: pins + ranked, at: at)
        var newMore: [S24Today.Card] = more.filter { !raised.contains($0) && visible($0) }
        newMore += lowered
        return (newTop, newMore)
    }

    /// カードの日本語の名前（畳む候補・並びの画面に出す）
    static func title(_ card: S24Today.Card) -> String {
        switch card {
        case .hero: "録れているか"
        case .holiday: "休日の顔"
        case .answer: "今日の三つ"
        case .ask: "今日の 1 問"
        case .alerts: "気をつけること"
        case .pcFeature: "家の PC を新しく"
        case .s22: "文字になるまで・電池"
        case .s23: "新しい版・今日の確かめ"
        case .prep: "次の予定の前に"
        case .morningBrief: "朝の昨日と今日"
        case .oneYearAgo: "1 年前の今日"
        case .nightMood: "夜の 10 秒"
        case .knowMe: "けさの気分・今日の問い"
        case .promises: "会話のあとの約束"
        case .checkups: "1 日 1 分の答え合わせ"
        case .replies: "返事・メールの下書き"
        case .draft: "書いている途中の下書き"
        case .record: "今日の記録"
        }
    }
}

// MARK: - 強5 畳む候補

enum S33AFold {
    /// 30 日使われていない今日のカード（数え始めて 30 日たってから。畳んだもの・fixed は入れない）
    static func cardCandidates(uses: [S24Today.Card: Int], hidden: Set<S24Today.Card>, countedDays: Int?) -> [S24Today.Card] {
        guard (countedDays ?? 0) >= S33AOrder.unusedDays else { return [] }
        return S33AOrder.foldable.filter { !hidden.contains($0) && (uses[$0] ?? 0) == 0 }
    }
}

// MARK: - 強6 問いの山のふた

enum S33ACap {
    /// 問いの種類（順に 1 件ずつ配る順）
    enum Kind: String, CaseIterable, Sendable {
        /// 確かめ待ち（S20Book）
        case review
        /// 仕事の確かめ（S27WBook）
        case work
        /// 話し手の疑い（HomeFeeds）
        case doubt
        /// 言葉の候補（家の PC の辞書から。WordCandidates）
        case word

        var title: String {
            switch self {
            case .review: "確かめ待ち"
            case .work: "仕事の確かめ"
            case .doubt: "話し手の疑い"
            case .word: "言葉の候補"
            }
        }
    }

    static let onKey = "s33a.capOn"
    static let totalKey = "s33a.capTotal"
    static let wordsKey = "s33a.capWords"
    /// 合わせて見せる数（仮）
    static let defaultTotal = 30
    /// 言葉の候補の数（仮）
    static let defaultWords = 20
    static let totalRange = 10...100
    static let wordsRange = 5...100

    /// 数を配る: 種類の順に 1 件ずつ、合わせて total に届くまで（言葉の候補は wordCap まで）。
    /// 1 種類だけ多くても、ほかの種類が 0 にならない
    static func allot(_ counts: [Kind: Int], total: Int, wordCap: Int) -> [Kind: Int] {
        var left: [Kind: Int] = [:]
        for k in Kind.allCases {
            let n = max(0, counts[k] ?? 0)
            left[k] = k == .word ? min(n, max(0, wordCap)) : n
        }
        var out: [Kind: Int] = [:]
        var budget = max(0, total)
        while budget > 0 {
            var gave = false
            for k in Kind.allCases where budget > 0 && (left[k] ?? 0) > 0 {
                out[k, default: 0] += 1
                left[k, default: 0] -= 1
                budget -= 1
                gave = true
            }
            if !gave { break }
        }
        return out
    }

    /// 寝かせた数（あふれた分）
    static func slept(_ counts: [Kind: Int], allotted: [Kind: Int]) -> Int {
        Kind.allCases.reduce(0) { $0 + max(0, (counts[$1] ?? 0) - (allotted[$1] ?? 0)) }
    }

    /// 「寝かせた 12 件（確かめ待ち 5・言葉の候補 7）」。無ければ nil
    static func sleptLine(_ counts: [Kind: Int], allotted: [Kind: Int]) -> String? {
        let n = slept(counts, allotted: allotted)
        guard n > 0 else { return nil }
        let parts: [String] = Kind.allCases.compactMap { k in
            let d = max(0, (counts[k] ?? 0) - (allotted[k] ?? 0))
            return d > 0 ? "\(k.title) \(d)" : nil
        }
        return "寝かせた \(n) 件（" + parts.joined(separator: "・") + "）"
    }

    // MARK: 数の置き場（それぞれの一覧が自分の数を書き、ふたは最後に見た数で配る。描くたびに全部を数え直さない）

    nonisolated(unsafe) private static var raw: [Kind: Int] = [:]
    private static let lock = NSLock()

    static var isOn: Bool { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
    static var total: Int {
        let v = UserDefaults.standard.integer(forKey: totalKey)
        return v == 0 ? defaultTotal : min(totalRange.upperBound, max(totalRange.lowerBound, v))
    }
    static var words: Int {
        let v = UserDefaults.standard.integer(forKey: wordsKey)
        return v == 0 ? defaultWords : min(wordsRange.upperBound, max(wordsRange.lowerBound, v))
    }

    /// 一覧にふたをする（ふたが切ってあればそのまま）。数は覚える
    static func take<T>(_ kind: Kind, _ list: [T]) -> [T] {
        lock.lock()
        raw[kind] = list.count
        let counts = raw
        lock.unlock()
        guard isOn else { return list }
        let n = allot(counts, total: total, wordCap: words)[kind] ?? 0
        return n >= list.count ? list : Array(list.prefix(n))
    }

    /// 最後に見た数と、配った数
    static func snapshot() -> (counts: [Kind: Int], allotted: [Kind: Int]) {
        lock.lock()
        let counts = raw
        lock.unlock()
        guard isOn else { return (counts, counts) }
        return (counts, allot(counts, total: total, wordCap: words))
    }
}

// MARK: - 強27 時計の版

enum S33AWatch {
    enum State: Equatable, Sendable {
        case same
        /// 時計のアプリが古い（iPhone の Watch アプリから更新）
        case watchOlder
        /// 時計のほうが新しい（iPhone のアプリが古い）
        case phoneOlder
        /// 時計の版が届いていない
        case unknown
    }

    static func compare(phone: Int, watch: String?) -> State {
        switch S22Rules.watchVersion(phone: phone, watch: watch) {
        case .same: .same
        case .watchOlder: .watchOlder
        case .phoneOlder: .phoneOlder
        case .unknown: .unknown
        }
    }

    static func line(_ s: State) -> String? {
        switch s {
        case .same: nil
        case .watchOlder: "時計のアプリが古い（iPhone の Watch アプリから更新）"
        case .phoneOlder: "iPhone のアプリのほうが古い（TestFlight から入れ直す）"
        case .unknown: "時計の版がまだ届いていません（時計で LifeLog を一度開く）"
        }
    }

    /// 古いときの手順（今ある手順の初めの 2 つ）
    static let steps: [String] = Array(S22Rules.watchUpdateSteps.prefix(2))
}

// MARK: - 強15 どこ？

/// 開く先
enum S33AWhereTarget: Equatable, Sendable {
    /// 下のタブ
    case tab(AppTab)
    /// 記録の上の切り替え（RecordsPage の rawValue）
    case records(String)
    /// 知らせから開く画面（NoticeScreen の rawValue）
    case screen(String)
    /// lifelog:// のリンク
    case link(String)
    /// この画面から押して開く（S33AViews の名前）
    case view(String)
}

struct S33AWhereEntry: Equatable, Identifiable, Sendable {
    /// 英字の名前（数えるときに使う）
    let id: String
    let name: String
    /// 日本語の言い換え（探すときだけ使う）
    let aliases: [String]
    /// 目次の組（どのタブ・設定のどこにあるか）
    let place: String
    let target: S33AWhereTarget
}

/// 目次の 1 組
struct S33AWhereGroup: Equatable, Identifiable, Sendable {
    let place: String
    let entries: [S33AWhereEntry]
    var id: String { place }
}

enum S33AWhere {
    /// 目次の組の順
    static let places = ["今日", "タスク", "仕事", "直す", "記録", "ふり返り", "設定と点検"]

    static let entries: [S33AWhereEntry] = [
        S33AWhereEntry(id: "today", name: "今日", aliases: ["ホーム", "録音", "録る", "今日の三つ", "はじめ"], place: "今日", target: .tab(.today)),
        S33AWhereEntry(id: "ramen", name: "ラーメンの印", aliases: ["ラーメン食べた", "ラーメン帳", "杯数"], place: "今日",
                       target: .tab(.today)),
        S33AWhereEntry(id: "waiting", name: "本人の操作待ち", aliases: ["操作待ち", "許可", "入れ直し", "止まっているもの"], place: "今日",
                       target: .view("s26uWaiting")),
        S33AWhereEntry(id: "tasks", name: "タスク", aliases: ["やること", "todo", "頼まれごと", "約束", "期限"], place: "タスク", target: .tab(.tasks)),
        S33AWhereEntry(id: "drafts", name: "下書きの棚", aliases: ["下書き", "返事", "メールの下書き"], place: "タスク", target: .link("lifelog://drafts")),
        S33AWhereEntry(id: "work", name: "仕事", aliases: ["仕事タブ", "案件", "職場", "宿題", "会議"], place: "仕事", target: .tab(.work)),
        S33AWhereEntry(id: "workDigest", name: "仕事のまとめ", aliases: ["まとめ", "取り込む", "teams", "copilot", "頼み方"], place: "仕事",
                       target: .view("workDigest")),
        S33AWhereEntry(id: "workConfirm", name: "仕事の確かめ", aliases: ["確かめ", "まとめて確かめる"], place: "仕事", target: .link("lifelog://work/confirm")),
        S33AWhereEntry(id: "workKnow", name: "AI の理解", aliases: ["用語", "言葉", "体制", "仕組み", "番号", "決まったこと", "話し方", "出す前のチェック"],
                       place: "仕事", target: .tab(.work)),
        S33AWhereEntry(id: "smallTalk", name: "話のネタ（職場の人）", aliases: ["雑談", "ネタ", "会う前", "人のページ"], place: "仕事", target: .tab(.work)),
        S33AWhereEntry(id: "fix", name: "直す", aliases: ["確かめ待ち", "答える", "○×", "まる", "ばつ"], place: "直す", target: .tab(.fix)),
        S33AWhereEntry(id: "questions", name: "AI からの質問", aliases: ["質問", "ai", "答え"], place: "直す", target: .screen("questions")),
        S33AWhereEntry(id: "naming", name: "名前付けの山", aliases: ["声の名前", "名前を付ける", "人物n", "知らない声"], place: "直す", target: .view("naming")),
        S33AWhereEntry(id: "vocabulary", name: "言葉の登録", aliases: ["辞書", "単語", "言葉の候補", "固有名詞"], place: "直す", target: .view("vocabulary")),
        S33AWhereEntry(id: "misheard", name: "聞き間違いかも", aliases: ["誤変換", "聞き違い", "直し"], place: "直す", target: .view("misheard")),
        S33AWhereEntry(id: "reviewNudge", name: "今日の聞いて直す", aliases: ["聞き直し", "聞いて直す"], place: "直す", target: .screen("reviewNudge")),
        S33AWhereEntry(id: "recordsDays", name: "記録（日ごと）", aliases: ["日記", "会話", "履歴", "過去", "1日の記録"], place: "記録",
                       target: .records("日ごと")),
        S33AWhereEntry(id: "people", name: "話した相手（人）", aliases: ["人", "人物", "人のページ", "名前"], place: "記録", target: .records("人")),
        S33AWhereEntry(id: "places", name: "場所", aliases: ["地図", "行った所", "マップ"], place: "記録", target: .records("場所")),
        S33AWhereEntry(id: "money", name: "お金", aliases: ["支出", "支払い", "paypay", "カード", "家計"], place: "記録", target: .records("お金")),
        S33AWhereEntry(id: "ask", name: "記録に質問する", aliases: ["質問する", "聞く", "ai に聞く"], place: "記録", target: .view("ask")),
        S33AWhereEntry(id: "search", name: "探す（人・場所・日・言葉）", aliases: ["検索", "さがす", "見つける"], place: "記録", target: .view("search")),
        S33AWhereEntry(id: "shopVisits", name: "行ったお店", aliases: ["店", "外食", "ラーメン屋", "ごはん"], place: "記録", target: .view("shopVisits")),
        S33AWhereEntry(id: "lookBack", name: "ふり返り", aliases: ["振り返り", "週", "月", "物語"], place: "ふり返り", target: .records("ふり返り")),
        S33AWhereEntry(id: "life", name: "暮らし（車・欲しい物・約束・年のまとめ）", aliases: ["車", "カーシェア", "欲しい物", "年のまとめ", "答え合わせ", "約束の棚"],
                       place: "ふり返り", target: .view("s33Life")),
        S33AWhereEntry(id: "goodThings", name: "いいこと帳", aliases: ["お礼", "ほめ言葉", "褒め言葉", "済ませたこと"], place: "ふり返り",
                       target: .screen("goodThings")),
        S33AWhereEntry(id: "speaking", name: "話し方の振り返り", aliases: ["話し方", "しゃべり方"], place: "ふり返り", target: .view("speaking")),
        S33AWhereEntry(id: "facts", name: "わかったこと帳", aliases: ["覚えたこと", "わかったこと"], place: "ふり返り", target: .view("facts")),
        S33AWhereEntry(id: "trends", name: "同じ形の線（14 日）", aliases: ["グラフ", "体重", "歩数", "線", "体"], place: "ふり返り", target: .view("trends")),
        S33AWhereEntry(id: "knowMe", name: "自分を知る", aliases: ["見立て", "自分", "気分"], place: "ふり返り", target: .view("knowMe")),
        S33AWhereEntry(id: "briefCompare", name: "朝のまとめ 比べる", aliases: ["朝のまとめ", "ダイジェスト"], place: "ふり返り", target: .view("briefCompare")),
        S33AWhereEntry(id: "diagnostics", name: "自己点検", aliases: ["点検", "診断", "調子", "実機で動いたか"], place: "設定と点検", target: .screen("diagnostics")),
        S33AWhereEntry(id: "homePC", name: "家の PC", aliases: ["pc", "つなぐ", "文字起こし", "lifelog pc"], place: "設定と点検", target: .screen("homePC")),
        S33AWhereEntry(id: "proposals", name: "家の PC からの提案", aliases: ["提案"], place: "設定と点検", target: .screen("proposals")),
        S33AWhereEntry(id: "notices", name: "知らせの履歴", aliases: ["通知", "知らせ", "便り"], place: "設定と点検", target: .screen("notices")),
        S33AWhereEntry(id: "cloudLog", name: "クラウドに送ったもの", aliases: ["送ったもの", "クラウド", "外に出たもの"], place: "設定と点検",
                       target: .screen("cloudLog")),
        S33AWhereEntry(id: "listenQuality", name: "聞き取りの成績", aliases: ["成績", "精度"], place: "設定と点検", target: .view("listenQuality")),
        S33AWhereEntry(id: "recordingMap", name: "録音の抜けと数の照合", aliases: ["抜け", "録れていない", "取りこぼし"], place: "設定と点検",
                       target: .view("recordingMap")),
        S33AWhereEntry(id: "accuracy", name: "精度の通信簿", aliases: ["通信簿", "精度"], place: "設定と点検", target: .view("accuracy")),
        S33AWhereEntry(id: "hypotheses", name: "見立ての台帳", aliases: ["見立て", "仮説の台帳"], place: "設定と点検", target: .view("hypotheses")),
        S33AWhereEntry(id: "machine", name: "機械がしたこと（戻せる）", aliases: ["自動", "戻す", "機械"], place: "設定と点検", target: .view("s26uMachine")),
        S33AWhereEntry(id: "detailedSettings", name: "くわしい設定", aliases: ["設定", "apple watch", "同期", "google", "ドライブ", "話者"],
                       place: "設定と点検", target: .view("detailedSettings")),
        S33AWhereEntry(id: "watchUpdate", name: "時計の LifeLog を新しく", aliases: ["時計", "watch", "版", "アップデート", "更新"], place: "設定と点検",
                       target: .view("watchUpdate")),
        S33AWhereEntry(id: "dataEntry", name: "取るデータと入口（体重など）", aliases: ["体重", "体重計", "ヘルスケア", "曲", "名刺"], place: "設定と点検",
                       target: .view("dataEntry")),
        S33AWhereEntry(id: "s33Deep", name: "使われ方・畳む候補・問いのふた", aliases: ["畳む", "使われていない", "並び", "ふた", "寝かせた", "上限",
                                                                     "副業", "経費", "確定申告", "仮説ボード", "競馬", "定期の仕事", "効いたか", "ディスク", "c ドライブ"],
                       place: "設定と点検", target: .view("s33Deep")),
    ]

    /// 探す形にそろえる（小文字・カタカナはひらがな・空白と中点を外す）
    static func normalize(_ s: String) -> String {
        // のばす音（ー）は、かなに直す前に落とす。先に直すと Mac では「ラー」が「らあ」になり、
        // 「らーめん」で探しても「ラーメン」に当たらない（2026-11-27 の CI で出た）
        let drop: Set<Character> = [" ", "　", "・", "（", "）", "(", ")", "、", "。", "-", "ー", "ｰ"]
        let t = String(s.lowercased().filter { !drop.contains($0) })
        return t.applyingTransform(.hiraganaToKatakana, reverse: true) ?? t
    }

    /// 探す。語を空白で分け、どの語も名前か言い換えのどれかに入っているもの。
    /// 並び: 名前の頭に合う → 名前に入る → 言い換えに入る（同じなら目次の順）。空なら空
    static func search(_ query: String, in list: [S33AWhereEntry] = entries) -> [S33AWhereEntry] {
        let words = query.split(whereSeparator: { $0 == " " || $0 == "　" }).map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var scored: [(entry: S33AWhereEntry, score: Int, index: Int)] = []
        for (i, e) in list.enumerated() {
            let name = normalize(e.name)
            let aliases = e.aliases.map(normalize)
            var score = 0
            var ok = true
            for w in words {
                if name.hasPrefix(w) {
                    score += 3
                } else if name.contains(w) {
                    score += 2
                } else if aliases.contains(where: { $0.contains(w) }) {
                    score += 1
                } else {
                    ok = false
                    break
                }
            }
            if ok { scored.append((e, score, i)) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.entry)
    }

    /// 目次（組ごと・元の順）
    static func toc(_ list: [S33AWhereEntry] = entries) -> [S33AWhereGroup] {
        var out: [S33AWhereGroup] = []
        for p in places {
            let rows = list.filter { $0.place == p }
            if !rows.isEmpty { out.append(S33AWhereGroup(place: p, entries: rows)) }
        }
        return out
    }
}

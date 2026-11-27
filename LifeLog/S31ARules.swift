import Foundation

// s31（2026-11-27）文字と声を結ぶ（アプリ担当 S31A）の決まり。画面は S31AViews.swift、取り方は S31ABook.swift。
// - K31-1 の K2 の voice（仕事の項目 1 つに 2 件まで）: S31AVoiceRef。S27WItem.voice（省ける）で読む
// - K31-2 の GET /links?day= ・ /links?person= の答え: S31ALinks（links と people）。無いときは {"available":false}
// 結びは「候補」。記録・人の帳は書き換えない。強さ（score）は数ではなく言葉で見せる（たぶん・おそらく。境目は仮）。
// 決まった入力から決まった出力だけ（画面・通信・ディスクに触らない）。

/// 仕事の項目に付いた「声ではこう」1 件（K31-1 の K2 の voice）
struct S31AVoiceRef: Decodable, Equatable, Hashable, Sendable {
    /// 結びの id（ln-…。/links の links の id と同じ）
    var link: String?
    /// 会話の id（アプリの会話 id か canonical の区間の鍵。アプリは時刻で開く）
    var conv: String?
    /// 話し始めの時刻（ISO）
    var start: String?
    var who: [String] = []
    var say: String?

    enum CodingKeys: String, CodingKey { case link, conv, start, who, say }

    init(link: String? = nil, conv: String? = nil, start: String? = nil, who: [String] = [], say: String? = nil) {
        self.link = link
        self.conv = conv
        self.start = start
        self.who = who
        self.say = say
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        link = S31ARules.text(c.s27w(.link))
        conv = S31ARules.text(c.s27w(.conv))
        start = S31ARules.text(c.s27w(.start))
        say = S31ARules.text(c.s27w(.say))
        who = S31ARules.names(c, .who)
    }

    /// 開ける・見せられる中身があるか（時刻も発言も無いものは捨てる）
    var isUsable: Bool { start != nil || say != nil }
}

/// 結びの文字の側（Teams のまとめの項目か LINE の 1 行）
struct S31ALinkText: Decodable, Equatable, Sendable {
    var src: String
    var ref: String?
    var kind: String?
    var who: [String] = []
    var at: String?
    var room: String?
    var quote: String

    enum CodingKeys: String, CodingKey { case src, ref, kind, who, at, room, quote }

    init(src: String, ref: String? = nil, kind: String? = nil, who: [String] = [], at: String? = nil, room: String? = nil, quote: String) {
        self.src = src
        self.ref = ref
        self.kind = kind
        self.who = who
        self.at = at
        self.room = room
        self.quote = quote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        src = S31ARules.text(c.s27w(.src)) ?? "other"
        quote = try c.decode(String.self, forKey: .quote)
        ref = S31ARules.text(c.s27w(.ref))
        kind = S31ARules.text(c.s27w(.kind))
        at = S31ARules.text(c.s27w(.at))
        room = S31ARules.text(c.s27w(.room))
        who = S31ARules.names(c, .who)
    }
}

/// 声の 1 行（3 行まで）
struct S31AVoiceLine: Decodable, Equatable, Sendable {
    var t: String?
    var who: String?
    var say: String
}

/// 結びの声の側
struct S31ALinkVoice: Decodable, Equatable, Sendable {
    var conv: String?
    var start: String?
    var end: String?
    var speakers: [String] = []
    var lines: [S31AVoiceLine] = []

    enum CodingKeys: String, CodingKey { case conv, start, end, speakers, lines }

    init(conv: String? = nil, start: String? = nil, end: String? = nil, speakers: [String] = [], lines: [S31AVoiceLine] = []) {
        self.conv = conv
        self.start = start
        self.end = end
        self.speakers = speakers
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conv = S31ARules.text(c.s27w(.conv))
        start = S31ARules.text(c.s27w(.start))
        end = S31ARules.text(c.s27w(.end))
        speakers = S31ARules.names(c, .speakers)
        let rows: [S31AVoiceLine] = c.s27wList(.lines)
        lines = Array(rows.prefix(3))
    }

    /// 見せる 1 行（初めの行の発言・話した人・時刻）
    var firstRef: S31AVoiceRef {
        let line = lines.first
        let who: [String] = line?.who.map { [$0] } ?? speakers
        return S31AVoiceRef(conv: conv, start: line?.t ?? start, who: who, say: line?.say)
    }
}

/// 文字と声の結び 1 つ（K31-1 の links）
struct S31ALink: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var day: String
    var text: S31ALinkText
    var voice: S31ALinkVoice
    var score: Double?
    var by: String?
    var why: String?
    var work: Bool?
    var itemIDs: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, day, text, voice, score, by, why, work
        case itemIDs = "item_ids"
    }

    init(id: String, day: String, text: S31ALinkText, voice: S31ALinkVoice, score: Double? = nil, by: String? = nil,
         why: String? = nil, work: Bool? = nil, itemIDs: [String] = []) {
        self.id = id
        self.day = day
        self.text = text
        self.voice = voice
        self.score = score
        self.by = by
        self.why = why
        self.work = work
        self.itemIDs = itemIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        day = try c.decode(String.self, forKey: .day)
        text = try c.decode(S31ALinkText.self, forKey: .text)
        voice = try c.decode(S31ALinkVoice.self, forKey: .voice)
        score = S31ARules.unit(c.s27w(.score))
        by = S31ARules.text(c.s27w(.by))
        why = S31ARules.text(c.s27w(.why))
        work = c.s27w(.work)
        itemIDs = S31ARules.names(c, .itemIDs)
    }

    var isWork: Bool { work == true }
}

/// 人ごとのまとめ（K31-1 の people）
struct S31APerson: Decodable, Equatable, Sendable {
    var name: String
    var personID: String?
    var days: [String] = []
    var textN: Int?
    var voiceN: Int?
    var summary: String?
    var linkIDs: [String] = []

    enum CodingKeys: String, CodingKey {
        case name, days, summary
        case personID = "person_id", textN = "text_n", voiceN = "voice_n", linkIDs = "link_ids"
    }

    init(name: String, personID: String? = nil, days: [String] = [], textN: Int? = nil, voiceN: Int? = nil,
         summary: String? = nil, linkIDs: [String] = []) {
        self.name = name
        self.personID = personID
        self.days = days
        self.textN = textN
        self.voiceN = voiceN
        self.summary = summary
        self.linkIDs = linkIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        personID = S31ARules.text(c.s27w(.personID))
        summary = S31ARules.text(c.s27w(.summary))
        textN = c.s27w(.textN)
        voiceN = c.s27w(.voiceN)
        days = S31ARules.names(c, .days)
        linkIDs = S31ARules.names(c, .linkIDs)
    }
}

/// /links の答え（state/s31_links_for_app.json を絞ったもの）
struct S31ALinks: Decodable, Equatable, Sendable {
    var generatedAt: String?
    var links: [S31ALink] = []
    var people: [S31APerson] = []

    enum CodingKeys: String, CodingKey {
        case links, people
        case generatedAt = "generated_at"
    }

    init(generatedAt: String? = nil, links: [S31ALink] = [], people: [S31APerson] = []) {
        self.generatedAt = generatedAt
        self.links = links
        self.people = people
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = S31ARules.text(c.s27w(.generatedAt))
        links = c.s27wList(.links)
        people = c.s27wList(.people)
    }

    var isEmpty: Bool { links.isEmpty }
}

/// /links の答えの読み
enum S31AReply: Equatable, Sendable {
    /// 家の PC に結びがまだ無い（{"available":false}）
    case none
    case links(S31ALinks)
    /// 読めない（前の写しを残す）
    case bad
}

/// 日ごとのまとまり（新しい日が上・中は時刻の順）
struct S31ADay: Equatable, Identifiable, Sendable {
    var day: String
    var links: [S31ALink]
    var id: String { day }
}

/// 声の時刻（開くときの日と時刻）
struct S31AMoment: Equatable, Sendable {
    var day: String
    var time: Date
}

enum S31ARules {
    /// features の名前（K31-2）
    static let feature = "links"
    /// 「おそらく」「たぶん」の境目（仮）
    static let likelyFrom = 0.8
    static let maybeFrom = 0.55
    /// 声を聞くとき、その時刻からいちばん近い行を探す幅（秒・仮）
    static let nearSeconds: TimeInterval = 120

    // MARK: 読み

    static func text(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func unit(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return min(1, max(0, v))
    }

    /// 名前の並び（["a","b"] でも "a" 1 つでも読む。空の名前は捨てる）
    static func names<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [String] {
        let list: [String] = c.s27wList(key)
        if !list.isEmpty { return list.compactMap { text($0) } }
        if let one: String = c.s27w(key), let t = text(one) { return [t] }
        return []
    }

    /// S27WItem の voice（無い・空・読めないものだけなら nil。使えるものを 2 件まで）
    static func voices<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [S31AVoiceRef]? {
        let rows: [S31AVoiceRef] = c.s27wList(key)
        let usable: [S31AVoiceRef] = rows.filter(\.isUsable)
        return usable.isEmpty ? nil : Array(usable.prefix(2))
    }

    /// /links の答え
    static func reply(_ data: Data) -> S31AReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .bad }
        if (object["available"] as? Bool) == false { return .none }
        guard let links = try? JSONDecoder().decode(S31ALinks.self, from: data) else { return .bad }
        return .links(links)
    }

    // MARK: 強さの言葉（数は出さない）

    static func strength(_ score: Double?) -> String {
        guard let score = unit(score) else { return "同じ話の候補" }
        if score >= likelyFrom { return "おそらく同じ話" }
        if score >= maybeFrom { return "たぶん同じ話" }
        return "同じ話かもしれない"
    }

    // MARK: 並び

    /// 日ごと（新しい日が上）。日の中は文字の時刻（無ければ声の時刻）の順
    static func byDay(_ links: [S31ALink]) -> [S31ADay] {
        var groups: [String: [S31ALink]] = [:]
        for link in links { groups[link.day, default: []].append(link) }
        var out: [S31ADay] = []
        for day in groups.keys.sorted(by: >) {
            let sorted = (groups[day] ?? []).sorted { a, b in
                let x = sortKey(a), y = sortKey(b)
                return x == y ? a.id < b.id : x < y
            }
            out.append(S31ADay(day: day, links: sorted))
        }
        return out
    }

    /// 並べる鍵（"HH:MM"。文字の時刻 → 声の時刻 → 末尾）
    static func sortKey(_ link: S31ALink) -> String {
        if let at = link.text.at, at.count >= 4 { return at.count == 4 ? "0" + at : at }
        if let start = link.voice.start, let m = moment(start) { return clock(m.time) }
        return "99:99"
    }

    /// その人のまとめ（名前か id が合うもの。無ければ 1 人だけのときその人）
    static func person(_ links: S31ALinks, name: String, id: String? = nil) -> S31APerson? {
        if let id, let hit = links.people.first(where: { $0.personID == id }) { return hit }
        if let hit = links.people.first(where: { S25TText.sameName($0.name, name) }) { return hit }
        return links.people.count == 1 ? links.people.first : nil
    }

    /// 結び 1 つを id で（項目の voice の link から強さを引く）
    static func link(_ id: String?, in sets: [S31ALinks]) -> S31ALink? {
        guard let id else { return nil }
        for set in sets {
            if let hit = set.links.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    // MARK: 時刻

    /// ISO の時刻から、この端末の日と時刻（読めなければ nil）
    static func moment(_ iso: String?, timeZone: TimeZone = .current) -> S31AMoment? {
        guard let iso = text(iso), let date = date(iso) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return S31AMoment(day: day, time: date)
    }

    static func date(_ iso: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: iso) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: iso) { return d }
        // 時差の無い形（"2026-11-24T15:30:00"）はこの端末の時刻として読む
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: iso) { return d }
        }
        return nil
    }

    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 「11/24 15:30」（読めなければ日だけ・それも無ければ空）
    static func when(_ iso: String?, timeZone: TimeZone = .current) -> String {
        guard let m = moment(iso, timeZone: timeZone) else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: m.time)
        return AppFeeds.monthDay(m.day) + " " + String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 話した人の並び（「見本 花子・自分」。無ければ「話した人は分かりません」）
    static func whoLine(_ who: [String]) -> String {
        let names = who.compactMap { text($0) }
        return names.isEmpty ? "話した人は分かりません" : names.prefix(3).joined(separator: "・")
    }

    /// 仕事の項目の行の小さなしるし（「声・見本 花子・11/24 15:30・ほか 1」）
    static func markLine(who: String, when: String, more: Int) -> String {
        var parts: [String] = ["声", who]
        if !when.isEmpty { parts.append(when) }
        if more > 0 { parts.append("ほか \(more)") }
        return parts.joined(separator: "・")
    }

    /// 文字の出どころ（「Teams」「LINE・見本の部屋」）
    static func source(_ t: S31ALinkText) -> String {
        let name: String
        switch t.src.lowercased() {
        case "teams": name = "Teams"
        case "line": name = "LINE"
        default: name = "文字"
        }
        var parts: [String] = [name]
        if let room = text(t.room) { parts.append(room) }
        if let at = text(t.at) { parts.append(at) }
        return parts.joined(separator: "・")
    }

    /// 声を聞く行を探す: 時刻からいちばん近い行（幅の中だけ）。並びは [(時刻, 鍵)] で渡す
    static func nearest<T>(_ rows: [(Date, T)], to time: Date, within: TimeInterval = nearSeconds) -> T? {
        var bestGap: TimeInterval = .infinity
        var best: T?
        for (t, value) in rows {
            let gap = abs(t.timeIntervalSince(time))
            if gap <= within && gap < bestGap {
                bestGap = gap
                best = value
            }
        }
        return best
    }

    /// 開く会話: 時刻を含む会話（終わりの 60 秒後まで）。無ければ始まりがいちばん近い会話（幅の中）。添字を返す
    static func conversationIndex(_ spans: [(start: Date, end: Date)], at time: Date, within: TimeInterval = 10 * 60) -> Int? {
        for (i, s) in spans.enumerated() where s.start.addingTimeInterval(-30) <= time && time <= s.end.addingTimeInterval(60) {
            return i
        }
        var rows: [(Date, Int)] = []
        for (i, s) in spans.enumerated() { rows.append((s.start, i)) }
        return nearest(rows, to: time, within: within)
    }
}

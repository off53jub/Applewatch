import Foundation

// s26（2026-11-25）の A1 の決まり（決まった入力から決まった出力だけ。テストは LifeLogTests/S26ATests.swift）。
// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 16」。しきい値はどれも仮。動きは S26ABook.swift、画面は S26AViews.swift。
// 言語モデルは呼ばない（0 円）。

// MARK: - K2 端末の合図（集4・集5・集10・集12・集13・集16・集19）

struct S26ASong: Codable, Equatable, Sendable {
    var at: Date
    var title: String
    var artist: String?
    /// "heard"（その場で流れていた）か "played"（聴いた）
    var source: String
}

struct S26ACharge: Codable, Equatable, Sendable {
    var at: Date
    /// "plugged" か "unplugged"
    var state: String
}

struct S26AFocus: Codable, Equatable, Sendable {
    var at: Date
    var name: String?
    var on: Bool
}

struct S26AFloor: Codable, Equatable, Sendable {
    var at: Date
    var delta: Int
}

struct S26AMeal: Codable, Equatable, Sendable {
    var at: Date
    var lat: Double?
    var lon: Double?
}

struct S26ACard: Codable, Equatable, Sendable {
    var at: Date
    var lines: [String]
}

struct S26AScreen: Codable, Equatable, Sendable {
    var app: String
    var minutes: Double
}

/// 1 日分の合図（端末の中だけに持ち、終わった日を 1 回だけドライブに書く）
struct S26ADaySignals: Codable, Equatable, Sendable {
    var songs: [S26ASong] = []
    var charge: [S26ACharge] = []
    var firstUse: Date? = nil
    var focus: [S26AFocus] = []
    var floors: [S26AFloor] = []
    var meals: [S26AMeal] = []
    var cards: [S26ACard] = []
    var screenTime: [S26AScreen] = []

    init() {}

    // 項目が増えても前のファイルが読めるように、無い項目は空にする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songs = try c.decodeIfPresent([S26ASong].self, forKey: .songs) ?? []
        charge = try c.decodeIfPresent([S26ACharge].self, forKey: .charge) ?? []
        firstUse = try c.decodeIfPresent(Date.self, forKey: .firstUse)
        focus = try c.decodeIfPresent([S26AFocus].self, forKey: .focus) ?? []
        floors = try c.decodeIfPresent([S26AFloor].self, forKey: .floors) ?? []
        meals = try c.decodeIfPresent([S26AMeal].self, forKey: .meals) ?? []
        cards = try c.decodeIfPresent([S26ACard].self, forKey: .cards) ?? []
        screenTime = try c.decodeIfPresent([S26AScreen].self, forKey: .screenTime) ?? []
    }

    var isEmpty: Bool {
        songs.isEmpty && charge.isEmpty && firstUse == nil && focus.isEmpty && floors.isEmpty && meals.isEmpty
            && cards.isEmpty && screenTime.isEmpty
    }
}

enum S26ASignals {
    static let version = 1
    /// 朝に最初に使った時刻は、この時より後だけ（夜中に目が覚めて見たのは数えない。仮）
    static let morningFromHour = 4
    /// 同じ曲を続けて数えない間（仮 10 分）
    static let sameSongGap: TimeInterval = 10 * 60
    /// 食事の写真を 1 回の食事にまとめる間（仮 30 分）
    static let mealGap: TimeInterval = 30 * 60

    static func fileName(_ day: String) -> String { "lifelog-signals-\(day).json" }

    /// 母艦が読む形（取り決め K2。無い項目は省く）
    static func json(day: String, _ s: S26ADaySignals, calendar: Calendar = .current) -> Data? {
        func stamp(_ d: Date) -> String { HealthExport.stamp(d, calendar: calendar) }
        /// 無い値は JSON の null
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        func place(_ v: Double?) -> Any { orNull(v.map { ($0 * 10000).rounded() / 10000 }) }
        var object: [String: Any] = ["version": version, "day": day]
        if !s.songs.isEmpty {
            object["songs"] = s.songs.map { x -> [String: Any] in
                ["at": stamp(x.at), "title": x.title, "artist": orNull(x.artist), "source": x.source]
            }
        }
        if !s.charge.isEmpty {
            object["charge"] = s.charge.map { x -> [String: Any] in ["at": stamp(x.at), "state": x.state] }
        }
        if let first = s.firstUse { object["first_use"] = stamp(first) }
        if !s.focus.isEmpty {
            object["focus"] = s.focus.map { x -> [String: Any] in ["at": stamp(x.at), "name": orNull(x.name), "on": x.on] }
        }
        if !s.floors.isEmpty {
            object["floors"] = s.floors.map { x -> [String: Any] in ["at": stamp(x.at), "delta": x.delta] }
        }
        if !s.meals.isEmpty {
            object["meals"] = s.meals.map { m -> [String: Any] in ["at": stamp(m.at), "lat": place(m.lat), "lon": place(m.lon)] }
        }
        if !s.cards.isEmpty {
            object["cards"] = s.cards.map { x -> [String: Any] in ["at": stamp(x.at), "lines": x.lines] }
        }
        if !s.screenTime.isEmpty {
            object["screen_time"] = s.screenTime.map { x -> [String: Any] in ["app": x.app, "minutes": (x.minutes * 10).rounded() / 10] }
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 充電の合図を足す（前と同じ状態なら足さない。充電中→満タンも同じ「つないだ」）
    static func addingCharge(_ list: [S26ACharge], state: String, at: Date) -> [S26ACharge] {
        guard state == "plugged" || state == "unplugged" else { return list }
        if let last = list.last, last.state == state { return list }
        return list + [S26ACharge(at: at, state: state)]
    }

    /// 朝に最初に使った時刻（4 時より前は数えない。いちばん早いもの）
    static func firstUse(current: Date?, candidate: Date, calendar: Calendar = .current) -> Date? {
        guard calendar.component(.hour, from: candidate) >= morningFromHour else { return current }
        guard let current else { return candidate }
        return min(current, candidate)
    }

    /// 曲を足す（同じ曲名・歌手が 10 分以内に続いたら 1 曲）
    static func addingSong(_ list: [S26ASong], _ song: S26ASong) -> [S26ASong] {
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return list }
        var s = song
        s.title = String(title.prefix(120))
        s.artist = song.artist.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }.flatMap { $0.isEmpty ? nil : $0 }
        if list.contains(where: { $0.title == s.title && $0.artist == s.artist && abs($0.at.timeIntervalSince(s.at)) < sameSongGap }) {
            return list
        }
        return (list + [s]).sorted { $0.at < $1.at }
    }

    /// 集中モードを足す（同じ名前・同じ向きが 1 分以内に続いたら 1 回）
    static func addingFocus(_ list: [S26AFocus], _ focus: S26AFocus) -> [S26AFocus] {
        if let last = list.last, last.name == focus.name, last.on == focus.on, abs(last.at.timeIntervalSince(focus.at)) < 60 {
            return list
        }
        return list + [focus]
    }

    /// 食事の写真を足す（30 分以内の写真は同じ 1 回の食事。場所が無ければ、あとの写真の場所で埋める）
    static func addingMeal(_ list: [S26AMeal], _ meal: S26AMeal) -> [S26AMeal] {
        if let i = list.firstIndex(where: { abs($0.at.timeIntervalSince(meal.at)) < mealGap }) {
            var copy = list
            if copy[i].lat == nil, let lat = meal.lat, let lon = meal.lon {
                copy[i].lat = lat
                copy[i].lon = lon
            }
            if meal.at < copy[i].at { copy[i].at = meal.at }
            return copy
        }
        return (list + [meal]).sorted { $0.at < $1.at }
    }

    /// 名刺を足す（同じ文の名刺は 1 枚）
    static func addingCard(_ list: [S26ACard], _ card: S26ACard) -> [S26ACard] {
        guard !card.lines.isEmpty, !list.contains(where: { $0.lines == card.lines }) else { return list }
        return list + [card]
    }

    /// アプリの使用時間を足す（同じアプリは足し合わせる。replace なら置き換える＝ショートカットがその日の合計を渡すとき）
    static func addingScreen(_ list: [S26AScreen], app: String, minutes: Double, replace: Bool) -> [S26AScreen] {
        let name = String(app.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty, minutes.isFinite, minutes > 0, minutes < 24 * 60 else { return list }
        var copy = list
        if let i = copy.firstIndex(where: { $0.app == name }) {
            copy[i].minutes = replace ? minutes : min(24 * 60, copy[i].minutes + minutes)
        } else {
            copy.append(S26AScreen(app: name, minutes: minutes))
        }
        return copy
    }

    /// アプリを開いてから閉じるまでの分（4 時間より長いのは閉じた記録の取りこぼしとみなして数えない。仮）
    static func openMinutes(opened: Date?, closed: Date) -> Double? {
        guard let opened, closed > opened else { return nil }
        let minutes = closed.timeIntervalSince(opened) / 60
        return minutes <= 240 ? minutes : nil
    }

    /// 書く日（古い順）。first から、終わった日（次の日の 0:30 を過ぎた日）まで、まだ書いていない日
    static func dueDays(now: Date, done: Set<String>, first: String, limit: Int = 7, calendar: Calendar = .current) -> [String] {
        HealthExport.dueDays(now: now, done: done, first: first, limit: limit, calendar: calendar)
    }
}

// MARK: - 集3 せき・いびき

enum S26ABodySoundRules {
    /// 音の聞き分けの強さ（仮）
    static let minConfidence: Double = 0.5
    /// この間より近い窓は 1 回のせき・1 続きのいびき（窓は約 1 秒・半分重なり）
    static let joinGap: Double = 1.0

    /// 聞き分けの名前から、せき（cough）・いびき（snore）。ほかは nil
    static func kind(_ identifier: String) -> String? {
        let id = identifier.lowercased()
        if id.contains("cough") { return "cough" }
        if id.contains("snor") { return "snore" }
        return nil
    }

    /// 重なる・近い窓をつなぐ（始まりの順）
    static func merged(_ spans: [(start: Double, end: Double)], gap: Double = joinGap) -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end + gap {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// せきの回数（つないだかたまりの数）
    static func coughCount(_ spans: [(start: Double, end: Double)]) -> Int { merged(spans).count }

    /// いびきの分（つないだかたまりの長さの合計。5 秒より短いかたまりは数えない・仮）
    static func snoreMinutes(_ spans: [(start: Double, end: Double)]) -> Double {
        merged(spans).filter { $0.end - $0.start >= 5 }.reduce(0) { $0 + ($1.end - $1.start) } / 60
    }

    /// いびきを入れる日（18 時より後は次の日の夜の分。睡眠の日の決め方と同じ）
    static func snoreDay(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let day = hour >= 18 ? (calendar.date(byAdding: .day, value: 1, to: date) ?? date) : date
        return HealthExport.dayKey(day, calendar: calendar)
    }
}

// MARK: - 集4 その場で流れていた曲

enum S26AShazamRules {
    /// 曲を引くのに要る、続いた音楽の長さ（秒・仮）
    static let minMusic: Double = 6
    /// 1 回に聞かせる長さ（秒）
    static let sampleSeconds: Double = 10
    /// 1 日に引く数の上限（仮）
    static let perDay = 30

    /// いちばん長く続いた音楽の始まり（minMusic 秒より短ければ nil）
    static func musicStart(_ windows: [(start: Double, end: Double, label: String)]) -> Double? {
        let music: [(start: Double, end: Double)] = windows.filter { $0.label == "音楽" }.map { (start: $0.start, end: $0.end) }
        let spans = S26ABodySoundRules.merged(music)
        guard let best = spans.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }), best.end - best.start >= minMusic else {
            return nil
        }
        return best.start
    }
}

// MARK: - 集13 何階にいたか

/// 気圧の高さの変わりから、階の上り下りを数える。3 分（仮）の中で 1 階ぶん（3m・仮）変われば 1 回。
/// ゆっくりした変わり（天気で気圧が動く分）は、3 分ごとに基準を今の高さに寄せて捨てる
struct S26AFloorTracker: Equatable, Sendable {
    static let perFloor: Double = 3.0
    static let window: TimeInterval = 180

    var baseline: Double?
    var baseAt: Date?

    mutating func feed(_ altitude: Double, at: Date) -> Int? {
        guard let base = baseline, let since = baseAt else {
            baseline = altitude
            baseAt = at
            return nil
        }
        let diff = altitude - base
        if abs(diff) >= Self.perFloor * 0.9 {
            var floors = Int((diff / Self.perFloor).rounded())
            if floors == 0 { floors = diff > 0 ? 1 : -1 }
            baseline = altitude
            baseAt = at
            return floors
        }
        if at.timeIntervalSince(since) > Self.window {
            baseline = altitude
            baseAt = at
        }
        return nil
    }
}

// MARK: - 集10 食事の写真・集16 名刺

enum S26APhotoRules {
    /// 食べ物とみなす Vision の名前（ごはん帖の見分けと同じ表から、飲み物だけのものを除いた）
    static let foodLabels: Set<String> = [
        "food", "meal", "dish", "dessert", "baked_goods", "bread", "cake", "cookie", "cupcake", "donut", "pastry", "pie",
        "ice_cream", "candy", "chocolate", "fruit", "vegetable", "salad", "sandwich", "burger", "hamburger", "hotdog",
        "pizza", "pasta", "spaghetti", "noodles", "ramen", "sushi", "sashimi", "rice", "curry", "soup", "steak", "meat",
        "seafood", "egg", "breakfast", "dumpling", "taco", "burrito", "fries", "fried_chicken", "pancake", "waffle",
        "barbecue", "sausage", "bento", "tofu", "omelet", "crepe", "macaron", "parfait", "pho", "udon", "soba", "gyoza",
        "tempura", "yakitori", "takoyaki", "okonomiyaki", "katsu", "donburi", "onigiri", "miso_soup", "hot_pot", "dim_sum",
        "spring_roll", "kebab",
    ]
    /// 紙・名刺らしい Vision の名前（あれば文字を読む）
    static let paperLabels: Set<String> = ["document", "paper", "text", "printed_page", "business_card", "card", "receipt", "menu"]
    /// 食事とみなす強さ（仮）
    static let mealConfidence: Double = 0.5
    /// 紙とみなす強さ（仮）
    static let paperConfidence: Double = 0.3

    static func isMeal(_ labels: [(id: String, confidence: Double)]) -> Bool {
        labels.contains { foodLabels.contains($0.id) && $0.confidence >= mealConfidence }
    }

    static func isPaper(_ labels: [(id: String, confidence: Double)]) -> Bool {
        labels.contains { paperLabels.contains($0.id) && $0.confidence >= paperConfidence }
    }

    /// 名刺らしいか: 行が 3〜25 で、連絡先（メール・電話）と、会社か肩書きかサイトがある（仮）
    static func looksLikeCard(_ text: String) -> Bool {
        let lines = cardLines(text)
        guard (3...25).contains(lines.count) else { return false }
        let all = lines.joined(separator: "\n")
        let contact = all.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil
            || all.range(of: #"0\d{1,4}[-‐ー−(（ ]?\d{1,4}[-‐ー−)） ]?\d{3,4}"#, options: .regularExpression) != nil
            || all.range(of: #"(?i)\b(tel|mobile|fax)\b"#, options: .regularExpression) != nil
        let marks = ["株式会社", "有限会社", "合同会社", "(株)", "（株）", "Inc", "Co.,", "LLC", "Ltd", "部長", "課長", "代表", "取締役",
                     "マネージャー", "Manager", "Director", "www.", "http"]
        let company = marks.contains { all.contains($0) } || all.range(of: #"[一-龥]+部\b|[一-龥]+課\b"#, options: .regularExpression) != nil
        return contact && company
    }

    /// 名刺の行（空の行を除き、1 行 60 字・20 行まで）
    static func cardLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(20)
            .map { String($0.prefix(60)) }
    }
}

// MARK: - 聞16 予定で録り方を変える

enum S26AMeetingRules {
    /// 会議・面談らしい予定の名前（仮）
    static let words = ["会議", "ミーティング", "mtg", "打合せ", "打ち合わせ", "打合わせ", "面談", "定例", "1on1", "商談",
                        "レビュー", "面接", "朝会", "夕会", "meeting", "sync", "review"]
    /// 予定の何分前から切り替えるか（仮 2 分）
    static let lead: TimeInterval = 120

    static func isMeeting(title: String, attendees: Int, isWork: Bool) -> Bool {
        let t = title.lowercased()
        if words.contains(where: { t.contains($0) }) { return true }
        return isWork && attendees >= 1
    }

    /// いま会議の予定の中なら、その予定の終わり（いちばん遅いもの）。中でなければ nil
    static func meetingEnd(_ events: [(start: Date, end: Date, title: String, attendees: Int, isWork: Bool)], now: Date) -> Date? {
        events.filter { e in
            e.end > e.start && e.end.timeIntervalSince(e.start) <= 6 * 3600
                && e.start.addingTimeInterval(-lead) <= now && now < e.end
                && isMeeting(title: e.title, attendees: e.attendees, isWork: e.isWork)
        }.map { $0.end }.max()
    }
}

/// 切り替える前の録り方（終わったら戻す。S21Preset.Values と同じスイッチ）
struct S26APresetSnapshot: Codable, Equatable, Sendable {
    var chunkLength: String?
    var batterySaver: Bool?
    var skipSilence: Bool?
    var dropNoVoice: Bool?
    var standby: Bool?
    var watchDirect: Bool?
    var watchRelay: Bool?
    var useCloud: Bool?
    var correction: Bool?
    var speakers: Bool?
}

// MARK: - 結9 どこからでも同じリンク（取り決め K3）

enum S26ALink: Equatable, Hashable, Sendable {
    case person(String)
    case day(String)
    case talk(String)
    case task(String)
    case drafts
    case waiting

    var id: String {
        switch self {
        case .person(let n): "person-" + n
        case .day(let d): "day-" + d
        case .talk(let t): "talk-" + t
        case .task(let t): "task-" + t
        case .drafts: "drafts"
        case .waiting: "waiting"
        }
    }

    /// lifelog://person/<名前> など。形が違うもの・中身が空のものは nil（今までの開き方に任せる）
    static func parse(_ url: URL) -> S26ALink? {
        guard url.scheme == "lifelog", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (parts.host ?? "").lowercased()
        var value = parts.path
        while value.hasPrefix("/") { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch host {
        case "person": return value.isEmpty ? nil : .person(String(value.prefix(40)))
        case "day": return isDay(value) ? .day(value) : nil
        case "talk": return value.isEmpty ? nil : .talk(String(value.prefix(80)))
        case "task": return value.isEmpty ? nil : .task(String(value.prefix(80)))
        case "drafts": return .drafts
        case "waiting": return .waiting
        default: return nil
        }
    }

    /// 開く画面。操作待ちの画面は A2 の案内（軽5）ができるまで「今日」を開く
    var route: NoticeRoute {
        switch self {
        case .waiting: .tab(.today)
        default: .link(self)
        }
    }

    /// 住所にする（名前は URL エンコード）
    var url: URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        switch self {
        case .person(let n): return URL(string: "lifelog://person/" + enc(n))
        case .day(let d): return URL(string: "lifelog://day/" + d)
        case .talk(let t): return URL(string: "lifelog://talk/" + enc(t))
        case .task(let t): return URL(string: "lifelog://task/" + enc(t))
        case .drafts: return URL(string: "lifelog://drafts")
        case .waiting: return URL(string: "lifelog://waiting")
        }
    }

    static func isDay(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// 会話の id から日と時刻を読む（「2026-11-24T15:30」「20261124-1530」など。読めなければ nil。時刻が無ければ日だけ）
    static func talkMoment(_ id: String, calendar: Calendar = .current) -> (day: String, time: Date?)? {
        let pattern = #"(\d{4})-?(\d{2})-?(\d{2})(?:[T_ -]?(\d{2}):?(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) else { return nil }
        func part(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: id) else { return nil }
            return Int(id[r])
        }
        guard let y = part(1), let mo = part(2), let d = part(3), (1...12).contains(mo), (1...31).contains(d) else { return nil }
        let day = String(format: "%04d-%02d-%02d", y, mo, d)
        var time: Date?
        if let h = part(4), let mi = part(5), h < 24, mi < 60 {
            time = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))
        }
        return (day, time)
    }

    /// アプリの中の会話の id（Spotlight に載せるもの。日と時刻）
    static func appTalkID(_ start: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        return String(format: "app-%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - 結3 実際にあったことをカレンダーに

enum S26AActualRules {
    static let calendarTitle = "実績"
    /// 書く会話の短さの下限（仮 3 分）・滞在（仮 10 分）
    static let minTalk: TimeInterval = 3 * 60
    static let minStay: TimeInterval = 10 * 60
    /// 1 日に書く数の上限（仮）
    static let perDay = 40

    struct Item: Equatable, Sendable {
        var title: String
        var start: Date
        var end: Date
        var notes: String?
    }

    static func talk(title: String?, people: [String], place: String?, start: Date, end: Date) -> Item? {
        guard end.timeIntervalSince(start) >= minTalk else { return nil }
        var text = "話した: " + (title.flatMap { $0.isEmpty ? nil : $0 } ?? "会話")
        if !people.isEmpty { text += "（" + people.prefix(4).joined(separator: "、") + (people.count > 4 ? " ほか" : "") + "）" }
        return Item(title: String(text.prefix(80)), start: start, end: end, notes: place.map { "場所: " + $0 })
    }

    static func stay(name: String?, start: Date, end: Date) -> Item? {
        guard let name, !name.isEmpty, end.timeIntervalSince(start) >= minStay else { return nil }
        return Item(title: String(("いた: " + name).prefix(80)), start: start, end: end, notes: nil)
    }

    /// 並べて上限まで（始まりの順）
    static func capped(_ items: [Item]) -> [Item] {
        Array(items.sorted { $0.start < $1.start }.prefix(perDay))
    }
}

// MARK: - 結5 小さい区切りはすぐ送る

enum S26AFastSendRules {
    /// すぐ送る区切りの大きさの上限（仮 700KB。2 分ほどの区切り）
    static let maxBytes = 700_000
    /// すぐ送るときに待つ長さ（秒。家の PC は待たせているあいだ 15 秒ごとに空白を書く）
    static let timeout: TimeInterval = 120

    static func eligible(bytes: Int?, on: Bool) -> Bool {
        guard on, let bytes, bytes > 0 else { return false }
        return bytes <= maxBytes
    }
}

// MARK: - 聞10 端末の中の音声認識を正解で測る

enum S26ABenchRules {
    /// 1 日に測る数（充電中だけ。仮）
    static let perDay = 8

    /// 正しい文が、聞き取った文のどこか一続きにどれだけ近いか（足す・消す・置き換えるの最小回数）。
    /// 聞き取った文は区切りまるごとなので、いちばん合う所で比べる（やや甘い・仮）
    static func fitDistance(_ truth: [Character], in heard: [Character]) -> Int {
        guard !truth.isEmpty else { return 0 }
        guard !heard.isEmpty else { return truth.count }
        // 行＝正しい文の位置、列＝聞き取った文の位置。始まりと終わりはどこでもよい
        var previous = [Int](repeating: 0, count: heard.count + 1)
        var current = [Int](repeating: 0, count: heard.count + 1)
        for i in 1...truth.count {
            current[0] = i
            for j in 1...heard.count {
                let cost = truth[i - 1] == heard[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous.min() ?? truth.count
    }

    struct Row: Codable, Equatable, Sendable {
        var id: String
        var chars: Int
        /// 端末の中の音声認識（SpeechAnalyzer）の誤り
        var device: Int
        /// いま記録に入っている文の誤り
        var app: Int
        var at: Date
    }

    /// 合わせた誤り率（端末・記録）。測った数が無ければ nil
    static func rates(_ rows: [Row]) -> (device: Double, app: Double, count: Int)? {
        let chars = rows.reduce(0) { $0 + $1.chars }
        guard chars > 0 else { return nil }
        return (Double(rows.reduce(0) { $0 + $1.device }) / Double(chars),
                Double(rows.reduce(0) { $0 + $1.app }) / Double(chars), rows.count)
    }
}

// MARK: - 軽8 朝のまとめを耳で

enum S26AEarRules {
    /// 次の予定の前の一枚を読む文（題と本文。名前の後ろの「：」は読みやすく「、」に）
    static func briefScript(title: String, body: String) -> String {
        var text = title + "。"
        for raw in body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "・-－".contains(first) { line.removeFirst() }
            line = line.replacingOccurrences(of: "：", with: "、")
            guard !line.isEmpty else { continue }
            if let last = line.last, !"。！？!?".contains(last) { line += "。" }
            text += line
        }
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "。続きはアプリで見てください。"
    }

    /// 読む長さの上限（日本語の声で 1 分ほど）
    static let limit = 400
}

// MARK: - 聞12 人の名前の読みの辞書

enum S26ANameRules {
    /// 名前の後ろの呼び方と空白を取り、1〜8 字の名前だけ
    static func cleaned(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ContactsLink.honorifics where s.hasSuffix(suffix) && s.count > suffix.count {
            s = String(s.dropLast(suffix.count))
            break
        }
        s = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
        guard (1...8).contains(s.count), !s.contains("@"), s.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }) else { return nil }
        return s
    }

    /// 書き方と読みの組（同じ組は 1 つ）
    static func entries(_ names: [String]) -> [(written: String, reading: String)] {
        var seen = Set<String>()
        var out: [(written: String, reading: String)] = []
        for raw in names {
            guard let w = cleaned(raw) else { continue }
            let r = ContactsLink.reading(w)
            guard r.count >= 2, seen.insert(w + "|" + r).inserted else { continue }
            out.append((w, r))
        }
        return out
    }
}

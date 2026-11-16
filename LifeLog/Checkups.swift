import CoreLocation
import Foundation
import Observation
import SwiftUI

/// 1 日 1 分の答え合わせ（2026-11-16。強化案 136・137・90）。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 7」。
/// 場所の名前・同じ人か・聞き間違い・繋がりの確かめを 1 つの列にまとめ、効き目の大きい順に 1 日 5 問まで出す。
/// 材料は 2 つ:
/// - 母艦が作る JSON（GET /checkups。features の "checkups"。場所の担当・繋がりの担当が作る）。形は docs/s16-place-links.md。
/// - アプリの中にある推測（行ったお店の「たぶん」・名前の無い声の「同じ人かも」・「聞き間違いかも」・30 分以上いた名前なしの所）から作れる分。
/// 夜の「繋がり探し」（137）の候補は、母艦が GET /link-candidates（features の "linkfind"）で同じ形（kind が "link"・source が "night"）で渡す。
/// 答えは今ある送り口の流儀で母艦へ（母艦の項目は POST /checkups/answer。アプリの推測の答えは、前からの送り口・名前直しの送り口で返る）。
/// 押すまでは何も送らない。中身の文は記録（ログ）に書かない。

// MARK: - 形

struct CheckupOption: Codable, Equatable, Identifiable {
    var id: String
    var label: String
}

struct CheckupItem: Codable, Equatable, Identifiable {
    var id: String
    /// place（場所の名前）・place_unnamed（名前なしの所をまとめて）・person（同じ人か）・misheard（聞き間違い）・link（繋がり）
    var kind: String
    var title: String
    var detail: String = ""
    var options: [CheckupOption] = []
    /// 効き目の大きさ（大きいほど先に出す）
    var weight: Double = 0
    /// app（アプリの中の推測）・mothership（母艦の列）・night（夜の繋がり探し）
    var source: String = "app"
    var day: String? = nil
    /// 母艦の場所の番号・人の番号（届いていれば）
    var pl: String? = nil
    var pe: String? = nil
    /// 選ぶ代わりに、文字で答えられる
    var allowText: Bool = false
}

struct CheckupFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [CheckupItem] = []
}

/// 30 分以上いた、名前の無い所（立ち寄りの「出た」から。強化案 90）
struct UnnamedStay: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var arrival: Date
    var departure: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    var minutes: Int { Int(departure.timeIntervalSince(arrival) / 60) }
}

// MARK: - 決まり（通信しない・テストする部分）

enum CheckupRules {
    static let dailyLimit = 5
    /// 同じ種類は 3 問まで（場所ばかりにならないように）
    static let perKindMax = 3
    static let kinds: Set<String> = ["place", "place_unnamed", "person", "misheard", "link"]
    static let itemLimit = 100
    static let doneKey = "checkupDone"
    static let answeredKey = "checkupAnswered"
    static let hiddenKey = "checkupHidden"
    static let answeredLimit = 500

    // MARK: 読む

    private struct RawOption: Decodable {
        var id: String?
        var label: String?
    }

    private struct RawItem: Decodable {
        var id: String?
        var kind: String?
        var title: String?
        var detail: String?
        var options: [LossyRow<RawOption>]?
        var weight: Double?
        var source: String?
        var day: String?
        var pl: String?
        var pe: String?
        var text: Bool?
    }

    private struct RawFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawItem>]?
    }

    /// 母艦の列を読む。決まりに合わない行は落とす（選べる答えも文字の欄も無いものは出せない）。defaultSource は source が無いときの出どころ
    static func decode(_ data: Data, defaultSource: String = "mothership") -> CheckupFeed? {
        guard let raw = try? JSONDecoder().decode(RawFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [CheckupItem] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let id = HomeFeeds.trimmed(r.id), HomeFeeds.isID(id),
                  let kind = r.kind, kinds.contains(kind), let title = MothershipFeeds.cut(r.title, 80),
                  seen.insert(id).inserted else { continue }
            var options: [CheckupOption] = []
            var optionIDs = Set<String>()
            for o in r.options ?? [] {
                guard let v = o.value, let oid = HomeFeeds.trimmed(v.id), HomeFeeds.isID(oid),
                      let label = MothershipFeeds.cut(v.label, 30), optionIDs.insert(oid).inserted else { continue }
                options.append(CheckupOption(id: oid, label: label))
                if options.count >= 4 { break }
            }
            let allowText: Bool = r.text == true
            guard !options.isEmpty || allowText else { continue }
            var weight: Double = r.weight ?? 0
            if weight.isNaN || weight < 0 { weight = 0 }
            if weight > 1000 { weight = 1000 }
            var item = CheckupItem(id: id, kind: kind, title: title, detail: MothershipFeeds.cut(r.detail, 160) ?? "",
                                   options: options, weight: weight)
            item.source = r.source == "night" ? "night" : defaultSource
            if let d = HomeFeeds.trimmed(r.day), HomeFeeds.isDay(d) { item.day = d }
            if let pl = HomeFeeds.trimmed(r.pl), HomeFeeds.isID(pl) { item.pl = pl }
            if let pe = HomeFeeds.trimmed(r.pe), HomeFeeds.isID(pe) { item.pe = pe }
            item.allowText = allowText
            items.append(item)
            if items.count >= itemLimit { break }
        }
        return CheckupFeed(generated_at: raw.generated_at, items: items)
    }

    // MARK: 並べる

    /// 出す列: まだ答えていない・「あとで」にしていないものを、効き目の大きい順に。同じ種類は 3 問まで。今日あと remaining 問まで
    static func queue(_ items: [CheckupItem], answered: Set<String>, hidden: Set<String>, remaining: Int) -> [CheckupItem] {
        guard remaining > 0 else { return [] }
        var seen = Set<String>()
        var live: [CheckupItem] = []
        for item in items where !answered.contains(item.id) && !hidden.contains(item.id) && seen.insert(item.id).inserted {
            live.append(item)
        }
        live.sort { a, b in a.weight != b.weight ? a.weight > b.weight : a.id < b.id }
        var perKind: [String: Int] = [:]
        var out: [CheckupItem] = []
        for item in live {
            let n: Int = perKind[item.kind] ?? 0
            if n >= perKindMax { continue }
            perKind[item.kind] = n + 1
            out.append(item)
            if out.count >= min(remaining, dailyLimit) { break }
        }
        return out
    }

    /// 今日あと何問出せるか（答えた・あとでにした数を引く）
    static func remaining(saved: [String: Int], day: String) -> Int {
        max(0, dailyLimit - PlaceAssistRules.count(saved, kind: "done", day: day))
    }

    /// 「あとで」にした印が、いま効いているか（名前なしのまとめは、その週のあいだ。ほかは今日だけ）
    static func isHidden(id: String, hiddenDay: String?, today: String) -> Bool {
        guard let hiddenDay else { return false }
        return id.hasPrefix("unnamed:") || hiddenDay == today
    }

    // MARK: アプリの中の推測から作る

    /// 行ったお店の「たぶん」（推測した・まだ決めていない）。長くいた・はっきりしないものほど先
    static func placeItem(_ v: ShopVisit) -> CheckupItem? {
        guard v.state == .guessed, let guess = v.guess, let name = guess.name, !name.isEmpty else { return nil }
        var minutes: Double = 20
        if let departure = v.departure { minutes = max(0, departure.timeIntervalSince(v.arrival) / 60) }
        let ambiguous: Bool = ShopGuess.isAmbiguous(v.candidates)
        var options: [CheckupOption] = [CheckupOption(id: "yes", label: "合っている")]
        for (i, c) in alternatives(v).enumerated() {
            if let n = c.name { options.append(CheckupOption(id: "c\(i)", label: n)) }
        }
        options.append(CheckupOption(id: "no", label: "お店ではない"))
        let time: String = v.arrival.formatted(date: .abbreviated, time: .shortened)
        var item = CheckupItem(id: "shop:" + v.id, kind: "place", title: "「" + name + "」で合っていますか？",
                               detail: time + " ごろ・" + String(Int(minutes)) + " 分", options: options,
                               weight: min(minutes, 240) + (ambiguous ? 30 : 0))
        item.day = PCJSON.dayString(v.arrival)
        return item
    }

    /// いちばんの候補のほかの候補（名前のあるものから 2 つまで）
    static func alternatives(_ v: ShopVisit) -> [ShopCandidate] {
        var out: [ShopCandidate] = []
        for c in v.candidates where c.id != v.guessID && (c.name ?? "").isEmpty == false {
            out.append(c)
            if out.count >= 2 { break }
        }
        return out
    }

    static func samePersonItem(_ m: SamePersonMaybe) -> CheckupItem {
        var item = CheckupItem(id: "same:" + m.id, kind: "person",
                               title: "「" + m.person.name + "」は「" + m.namedName + "」さんと同じ人ですか？",
                               detail: "声が似ています（" + m.day + "）",
                               options: [CheckupOption(id: "yes", label: "同じ人"), CheckupOption(id: "no", label: "別の人")],
                               weight: m.score * 100 + Double(m.person.lines))
        item.day = m.day
        return item
    }

    static func samePersonItem(_ g: SamePersonGroup) -> CheckupItem {
        var names: [String] = []
        for m in g.people { names.append(m.name) }
        var lines = 0
        for m in g.people { lines += m.lines }
        var item = CheckupItem(id: "group:" + g.id, kind: "person", title: "「" + names.joined(separator: "」と「") + "」は同じ人ですか？",
                               detail: "声が似ています（" + g.day + "）",
                               options: [CheckupOption(id: "yes", label: "同じ人"), CheckupOption(id: "no", label: "別の人")],
                               weight: g.score * 100 + Double(lines))
        item.day = g.day
        return item
    }

    static func misheardItem(_ s: MisheardBox.Suspect) -> CheckupItem {
        var options: [CheckupOption] = []
        if !s.guess.isEmpty { options.append(CheckupOption(id: "fix", label: "「" + s.guess + "」に直す")) }
        options.append(CheckupOption(id: "keep", label: "合っている"))
        let title: String = s.guess.isEmpty
            ? "「" + s.wrong + "」は聞き間違いですか？"
            : "「" + s.wrong + "」は「" + s.guess + "」の聞き間違いですか？"
        return CheckupItem(id: "mis:" + s.id.uuidString, kind: "misheard", title: title, detail: s.reason, options: options,
                           weight: Double(s.refs.count) * 10)
    }

    /// 名前なしの所をまとめて聞く 1 問（その週に 1 回。30 分以上・1 か所以上あるとき）
    static func unnamedItem(stays: [UnnamedStay], now: Date) -> CheckupItem? {
        guard !stays.isEmpty else { return nil }
        var minutes = 0
        for s in stays { minutes += s.minutes }
        var item = CheckupItem(id: "unnamed:" + UnnamedStayRules.weekStart(now), kind: "place_unnamed",
                               title: "名前のない所が \(stays.count) か所あります",
                               detail: "30 分以上いた所を、まとめて聞きます（合わせて " + String(minutes) + " 分）",
                               options: [], weight: min(Double(minutes), 400))
        item.allowText = false
        return item
    }

    // MARK: 母艦へ返す

    struct AnswerBody: Codable, Equatable {
        let id: String
        let kind: String
        let value: String
        let text: String?
        let day: String
        let pl: String?
        let pe: String?
        let source: String
    }

    /// POST /checkups/answer の中身。value は選べる答えの id・"text"（文字で答えた）・"skip"（あとで）のどれか。違えば nil
    static func answerBody(item: CheckupItem, value: String, text: String?, day: String) -> Data? {
        guard HomeFeeds.isID(item.id), HomeFeeds.isDay(day) else { return nil }
        var typed: String?
        if value == "text" {
            guard item.allowText, let t = MothershipFeeds.cut(text, 60) else { return nil }
            typed = t
        } else if value != "skip", !item.options.contains(where: { $0.id == value }) {
            return nil
        }
        let body = AnswerBody(id: item.id, kind: item.kind, value: value, text: typed, day: day, pl: item.pl, pe: item.pe,
                              source: item.source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(body)
    }
}

enum UnnamedStayRules {
    static let minMinutes = 30
    /// これより長い滞在は、立ち寄りの取り違えとみなして残さない（時間）
    static let maxHours = 20
    static let keepDays = 14
    static let limit = 100

    static func qualifies(arrival: Date, departure: Date) -> Bool {
        let seconds: TimeInterval = departure.timeIntervalSince(arrival)
        return seconds >= Double(minMinutes) * 60 && seconds <= Double(maxHours) * 3600
    }

    /// 古いものを捨て、多すぎたら古い順に捨てる
    static func pruned(_ stays: [UnnamedStay], now: Date) -> [UnnamedStay] {
        let cutoff: Date = now.addingTimeInterval(-Double(keepDays) * 86400)
        var out: [UnnamedStay] = stays.filter { $0.departure >= cutoff }
        out.sort { $0.arrival < $1.arrival }
        while out.count > limit { out.removeFirst() }
        return out
    }

    /// 週の初めの日（端末の暦の週。yyyy-MM-dd）
    static func weekStart(_ date: Date, calendar: Calendar = .current) -> String {
        let start: Date = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return PCJSON.dayString(start, calendar: calendar)
    }

    /// 直近の何日かのもの（新しい順）
    static func recent(_ stays: [UnnamedStay], now: Date, days: Int = 7) -> [UnnamedStay] {
        let cutoff: Date = now.addingTimeInterval(-Double(days) * 86400)
        var out: [UnnamedStay] = stays.filter { $0.arrival >= cutoff }
        out.sort { $0.arrival > $1.arrival }
        return out
    }

    /// 同じ所（半径 m 以内）のもの
    static func nearby(_ stays: [UnnamedStay], latitude: Double, longitude: Double, radius: Double = PlaceNameRules.radius) -> [UnnamedStay] {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return stays.filter { $0.location.distance(from: here) <= radius }
    }
}

// MARK: - 名前なしの所の帳

@MainActor
@Observable
final class UnnamedStayBook {
    static let shared = UnnamedStayBook()

    private(set) var stays: [UnnamedStay] = []
    @ObservationIgnored private var loaded = false

    private static var url: URL { URL.applicationSupportDirectory.appendingPathComponent("unnamed-stays.json") }

    init() {
        load()
    }

    private func load() {
        defer { loaded = true }
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([UnnamedStay].self, from: data) {
            stays = UnnamedStayRules.pruned(saved, now: .now)
        } else {
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("unnamed-stays-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    private func save() {
        guard loaded else { return }
        stays = UnnamedStayRules.pruned(stays, now: .now)
        guard let data = try? JSONEncoder().encode(stays) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// 立ち寄りの「出た」が届いたとき。30 分以上いて、知らない所なら足す
    func record(arrival: Date, departure: Date, latitude: Double, longitude: Double, accuracy: Double, known: Bool) {
        guard loaded, !known, UnnamedStayRules.qualifies(arrival: arrival, departure: departure) else { return }
        // 同じ立ち寄りが二度届いた
        if stays.contains(where: { abs($0.arrival.timeIntervalSince(arrival)) < 120 && abs($0.latitude - latitude) < 0.001 }) { return }
        stays.append(UnnamedStay(arrival: arrival, departure: departure, latitude: latitude, longitude: longitude,
                                 accuracy: max(accuracy, 0)))
        save()
        Tally.add("unnamed.recorded")
    }

    /// 名前を付ける（同じ所の名前なしは、まとめて同じ名前にする）。付けたら true
    @discardableResult
    func name(_ id: String, as text: String) -> Bool {
        guard loaded, let stay = stays.first(where: { $0.id == id }),
              PlaceNameBook.shared.fix(name: text, latitude: stay.latitude, longitude: stay.longitude, source: "checkup") else { return false }
        let same: Set<String> = Set(UnnamedStayRules.nearby(stays, latitude: stay.latitude, longitude: stay.longitude).map { $0.id })
        stays.removeAll { same.contains($0.id) }
        save()
        Tally.add("unnamed.named")
        return true
    }

    /// 覚えなくていい（その 1 か所を外す）
    func dismiss(_ id: String) {
        guard loaded else { return }
        stays.removeAll { $0.id == id }
        save()
        Tally.add("unnamed.dismissed")
    }
}

// MARK: - 列

@MainActor
@Observable
final class CheckupBook {
    static let shared = CheckupBook()

    /// 母艦の列と、夜の繋がり探し（読んだ写し）
    private(set) var feedItems: [CheckupItem] = []
    /// 答えたときなどに増やす（画面が列を作り直す）
    private(set) var version = 0
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var fetching = false

    static let feedFile = "mfeed-checkups.json"
    static let linkFile = "mfeed-link-candidates.json"
    private static let every: TimeInterval = 30 * 60

    private static func url(_ name: String) -> URL { URL.applicationSupportDirectory.appendingPathComponent(name) }

    init() {
        var items: [CheckupItem] = []
        if let data = try? Data(contentsOf: Self.url(Self.feedFile)), let feed = try? JSONDecoder().decode(CheckupFeed.self, from: data) {
            items.append(contentsOf: feed.items)
        }
        if let data = try? Data(contentsOf: Self.url(Self.linkFile)), let feed = try? JSONDecoder().decode(CheckupFeed.self, from: data) {
            items.append(contentsOf: feed.items)
        }
        feedItems = items
    }

    /// 読み直す（force でなければ30分に1回まで）。読めなかった写しは前のまま。ためた答えも送る
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.isConfigured else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every {
            await MothershipOutbox.send(pc)
            return
        }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        var main: [CheckupItem]? = nil
        var night: [CheckupItem]? = nil
        if pc.features.contains("checkups"), let body = try? await pc.appFeed("checkups", feature: "checkups"),
           let feed = CheckupRules.decode(body) {
            main = feed.items
            if let data = try? JSONEncoder().encode(feed) { try? data.write(to: Self.url(Self.feedFile), options: .atomic) }
        }
        // 夜の「繋がり探し」の候補（強化案 137）。同じ形で、出どころは night
        if pc.features.contains("linkfind"), let body = try? await pc.appFeed("link-candidates", feature: "linkfind"),
           let feed = CheckupRules.decode(body, defaultSource: "night") {
            var items: [CheckupItem] = []
            for var item in feed.items {
                item.source = "night"
                items.append(item)
            }
            night = items
            if let data = try? JSONEncoder().encode(CheckupFeed(generated_at: feed.generated_at, items: items)) {
                try? data.write(to: Self.url(Self.linkFile), options: .atomic)
            }
        }
        if main != nil || night != nil {
            var next: [CheckupItem] = []
            next.append(contentsOf: main ?? feedItems.filter { $0.source != "night" })
            next.append(contentsOf: night ?? feedItems.filter { $0.source == "night" })
            feedItems = next
            version += 1
        }
        await MothershipOutbox.send(pc)
    }

    // MARK: 答えた印

    private func today() -> String { PCJSON.dayString(.now) }

    private var answered: [String: String] {
        UserDefaults.standard.dictionary(forKey: CheckupRules.answeredKey) as? [String: String] ?? [:]
    }

    private var hidden: [String: String] {
        UserDefaults.standard.dictionary(forKey: CheckupRules.hiddenKey) as? [String: String] ?? [:]
    }

    private func markAnswered(_ id: String) {
        var saved: [String: String] = answered
        saved[id] = today()
        if saved.count > CheckupRules.answeredLimit {
            let ordered: [(key: String, value: String)] = saved.sorted { $0.value < $1.value }
            for entry in ordered.prefix(saved.count - CheckupRules.answeredLimit) { saved[entry.key] = nil }
        }
        UserDefaults.standard.set(saved, forKey: CheckupRules.answeredKey)
        countDone()
    }

    private func countDone() {
        let counts: [String: Int] = UserDefaults.standard.dictionary(forKey: CheckupRules.doneKey) as? [String: Int] ?? [:]
        UserDefaults.standard.set(PlaceAssistRules.bumped(counts, kind: "done", day: today()), forKey: CheckupRules.doneKey)
        version += 1
    }

    private func remaining() -> Int {
        let counts: [String: Int] = UserDefaults.standard.dictionary(forKey: CheckupRules.doneKey) as? [String: Int] ?? [:]
        return CheckupRules.remaining(saved: counts, day: today())
    }

    /// 「あとで」（今日は出さない。名前なしのまとめは、その週は出さない）
    func skip(_ item: CheckupItem, pipeline: Pipeline) {
        var saved: [String: String] = hidden
        saved[item.id] = today()
        // 今日の分だけ残す（名前なしのまとめは週ごとの名前なので、そのまま）
        var keep: [String: String] = [:]
        for (key, day) in saved where day == today() || key.hasPrefix("unnamed:") { keep[key] = day }
        UserDefaults.standard.set(keep, forKey: CheckupRules.hiddenKey)
        Tally.add("checkup.skipped")
        if item.source != "app", let body = CheckupRules.answerBody(item: item, value: "skip", text: nil, day: today()) {
            MothershipOutbox.enqueue(path: "checkups/answer", body: body)
            Task { await MothershipOutbox.send(pipeline.homePC) }
        }
        countDone()
    }

    // MARK: 列を作る

    /// アプリの中の推測から作った分と、母艦の列を合わせた、今日出す列（5 問まで）
    func queue(_ pipeline: Pipeline, now: Date = .now) -> [CheckupItem] {
        var all: [CheckupItem] = feedItems
        if pipeline.shopVisits.isOn {
            for v in pipeline.shopVisits.visits where v.arrival >= now.addingTimeInterval(-10 * 86400) {
                if let item = CheckupRules.placeItem(v) { all.append(item) }
            }
        }
        for m in pipeline.samePersonMaybes { all.append(CheckupRules.samePersonItem(m)) }
        for g in pipeline.samePersonGroups { all.append(CheckupRules.samePersonItem(g)) }
        for s in pipeline.misheard.open.prefix(5) { all.append(CheckupRules.misheardItem(s)) }
        let stays: [UnnamedStay] = unknownStays(now: now)
        if let item = CheckupRules.unnamedItem(stays: stays, now: now) { all.append(item) }
        let today: String = PCJSON.dayString(now)
        let hiddenDays: [String: String] = hidden
        var hiddenIDs = Set<String>()
        for item in all where CheckupRules.isHidden(id: item.id, hiddenDay: hiddenDays[item.id], today: today) { hiddenIDs.insert(item.id) }
        return CheckupRules.queue(all, answered: Set(answered.keys), hidden: hiddenIDs, remaining: remaining())
    }

    /// 名前なしの所のうち、いまも知らない所（そのあいだに名前を直した所は外す）
    func unknownStays(now: Date = .now) -> [UnnamedStay] {
        var out: [UnnamedStay] = []
        for s in UnnamedStayRules.recent(UnnamedStayBook.shared.stays, now: now) {
            if PlaceAssist.shared.isKnownPlace(latitude: s.latitude, longitude: s.longitude, accuracy: s.accuracy) { continue }
            out.append(s)
        }
        return out
    }

    // MARK: 答える

    /// 選べる答えを押した。返すのは画面に出す一文
    func answer(_ item: CheckupItem, option: String, pipeline: Pipeline) async -> String {
        var note: String = "答えました。"
        if item.id.hasPrefix("shop:") {
            note = answerShop(String(item.id.dropFirst(5)), option: option, pipeline: pipeline)
        } else if item.id.hasPrefix("same:") {
            let id: String = String(item.id.dropFirst(5))
            if let m = pipeline.samePersonMaybes.first(where: { $0.id == id }) {
                note = await pipeline.answerSamePersonMaybe(m, same: option == "yes")
            }
        } else if item.id.hasPrefix("group:") {
            let id: String = String(item.id.dropFirst(6))
            if let g = pipeline.samePersonGroups.first(where: { $0.id == id }) {
                note = await pipeline.answerSamePerson(g, same: option == "yes")
            }
        } else if item.id.hasPrefix("mis:") {
            let uuid: String = String(item.id.dropFirst(4))
            if let s = pipeline.misheard.open.first(where: { $0.id.uuidString == uuid }) {
                if option == "fix", !s.guess.isEmpty {
                    note = await pipeline.fixMisheard(s, to: s.guess, everywhere: false, addFix: true)
                } else {
                    pipeline.misheard.settle(s.id, as: .kept)
                    note = "合っているとして、もう出しません。"
                }
            }
        } else if let body = CheckupRules.answerBody(item: item, value: option, text: nil, day: today()) {
            MothershipOutbox.enqueue(path: "checkups/answer", body: body)
            await MothershipOutbox.send(pipeline.homePC)
            note = "母艦に伝えます。"
        } else {
            return "この答えは送れませんでした。"
        }
        Tally.add("checkup.answered")
        Tally.add("checkup.answered." + item.kind)
        markAnswered(item.id)
        return note
    }

    /// 文字で答えた（母艦の列の、文字の欄のある問）
    func answer(_ item: CheckupItem, text: String, pipeline: Pipeline) async -> String {
        guard let body = CheckupRules.answerBody(item: item, value: "text", text: text, day: today()) else {
            return "この答えは送れませんでした。"
        }
        MothershipOutbox.enqueue(path: "checkups/answer", body: body)
        // 場所の名前なら、アプリでも覚える（位置は分からないので、場所の番号があれば番号で）
        if item.kind == "place", let pl = item.pl { PlaceNameBook.shared.fixPage(id: pl, name: text) }
        await MothershipOutbox.send(pipeline.homePC)
        Tally.add("checkup.answered")
        Tally.add("checkup.answered." + item.kind)
        markAnswered(item.id)
        return "母艦に伝えます。"
    }

    private func answerShop(_ visitID: String, option: String, pipeline: Pipeline) -> String {
        guard let v = pipeline.shopVisits.visits.first(where: { $0.id == visitID }) else { return "もう見つかりませんでした。" }
        let book = pipeline.shopVisits
        switch option {
        case "yes":
            guard let name = v.guess?.name else { return "名前が見つかりませんでした。" }
            book.confirm(visitID)
            PlaceNameBook.shared.fix(name: name, latitude: v.latitude, longitude: v.longitude, source: "checkup")
            return "「" + name + "」で決めました。"
        case "no":
            book.markNotShop(visitID)
            return "お店ではないにしました。"
        default:
            guard option.hasPrefix("c"), let i = Int(option.dropFirst()), i >= 0 else { return "答えが分かりませんでした。" }
            let alts: [ShopCandidate] = CheckupRules.alternatives(v)
            guard alts.indices.contains(i), let name = alts[i].name else { return "候補が見つかりませんでした。" }
            book.choose(visitID, candidate: alts[i].id)
            PlaceNameBook.shared.fix(name: name, latitude: v.latitude, longitude: v.longitude, source: "checkup")
            return "「" + name + "」で決めました。"
        }
    }
}

// MARK: - 画面

/// 「今日」の「1日1分の答え合わせ」（問があるときだけ）
struct CheckupsSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = CheckupBook.shared
        let list: [CheckupItem] = book.queue(pipeline)
        if !list.isEmpty {
            Section {
                NavigationLink {
                    CheckupsView()
                } label: {
                    LabeledContent {
                        Text("\(list.count) 問")
                    } label: {
                        Label("1日1分の答え合わせ", systemImage: "checkmark.bubble")
                    }
                }
            } footer: {
                Text("場所の名前・同じ人か・聞き間違い・繋がりの確かめを、効き目の大きい順に 1 日 5 問まで出します。答えは次から使い、母艦にも伝えます。")
            }
        }
    }
}

struct CheckupsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var notes: [String: String] = [:]
    @State private var texts: [String: String] = [:]
    @State private var busy: String?

    var body: some View {
        let book = CheckupBook.shared
        let list: [CheckupItem] = book.queue(pipeline)
        List {
            ForEach(list) { item in
                CheckupCard(item: item, note: notes[item.id], text: Binding(get: { texts[item.id] ?? "" }, set: { texts[item.id] = $0 }),
                            busy: busy == item.id,
                            onOption: { option in run(item) { await book.answer(item, option: option, pipeline: pipeline) } },
                            onText: { run(item) { await book.answer(item, text: texts[item.id] ?? "", pipeline: pipeline) } },
                            onSkip: { book.skip(item, pipeline: pipeline) })
            }
            if list.isEmpty {
                Section {
                    Text("今日の答え合わせは、ここまでです。").foregroundStyle(.secondary)
                } footer: {
                    Text("1 日 5 問までです。答えると、次から同じ所・同じ人に使います。")
                }
            }
        }
        .navigationTitle("答え合わせ")
        .countsOpen("checkups")
        .refreshable { await book.refresh(pipeline.homePC, force: true) }
        .task { await book.refresh(pipeline.homePC) }
    }

    private func run(_ item: CheckupItem, _ work: @escaping () async -> String) {
        guard busy == nil else { return }
        busy = item.id
        Task {
            let note: String = await work()
            notes[item.id] = note
            busy = nil
        }
    }
}

struct CheckupCard: View {
    let item: CheckupItem
    let note: String?
    @Binding var text: String
    let busy: Bool
    let onOption: (String) -> Void
    let onText: () -> Void
    let onSkip: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
                if item.source == "night" {
                    Text("夜に見つけた繋がりの候補です").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            } else if busy {
                HStack { ProgressView(); Text("送っています…") }
            } else if item.kind == "place_unnamed" {
                NavigationLink("まとめて見る") { UnnamedPlacesView() }
                Button("あとで", action: onSkip)
            } else {
                ForEach(item.options) { option in
                    Button(option.label) { onOption(option.id) }
                }
                if item.allowText {
                    TextField("名前や答えを書く", text: $text)
                    Button("この答えで送る", action: onText)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("あとで", action: onSkip)
            }
        }
    }
}

/// 30 分以上いた名前なしの所を、週に 1 回まとめて聞く（強化案 90）
struct UnnamedPlacesView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var candidates: [String: [String]] = [:]
    @State private var typed: [String: String] = [:]

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    var body: some View {
        let stays: [UnnamedStay] = CheckupBook.shared.unknownStays()
        List {
            if stays.isEmpty {
                Text("名前のない所は、もうありません。").foregroundStyle(.secondary)
            }
            ForEach(stays) { stay in
                Section {
                    ForEach(candidates[stay.id] ?? [], id: \.self) { name in
                        Button(name) { _ = UnnamedStayBook.shared.name(stay.id, as: name) }
                    }
                    TextField("この所の名前", text: Binding(get: { typed[stay.id] ?? "" }, set: { typed[stay.id] = $0 }))
                    Button("この名前にする") { _ = UnnamedStayBook.shared.name(stay.id, as: typed[stay.id] ?? "") }
                        .disabled((typed[stay.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    NavigationLink("その時を見る") {
                        MomentView(from: stay.arrival, to: stay.departure, title: "この所にいた時")
                    }
                    Button("覚えなくていい", role: .destructive) { UnnamedStayBook.shared.dismiss(stay.id) }
                } header: {
                    Text(Self.clock.string(from: stay.arrival) + "〜" + Self.clock.string(from: stay.departure) + "（\(stay.minutes) 分）")
                }
                .task(id: stay.id) {
                    if candidates[stay.id] == nil {
                        candidates[stay.id] = await PlaceAssist.shared.candidates(for: stay.location, arrival: stay.arrival)
                    }
                }
            }
        }
        .navigationTitle("名前のない所")
        .countsOpen("unnamedPlaces")
    }
}

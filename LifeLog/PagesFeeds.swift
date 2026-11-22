import Foundation
import Observation
import SwiftUI

/// 人・話題の糸・場所・決めごとのページ（2026-11-15。強化案 53・54・55・61。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 3」）。
/// 読む（家の PC の GET。母艦が作った写しを、PC とアプリの両方で確かめる）:
/// - 人のページ（GET /people-pages。features の "peoplepages"。53）: 記録→人の上の「人のページ」・人の画面・会う前の一枚から
/// - 話題の糸（GET /threads。"threads"。54）: ふり返りの「話題の糸」
/// - 場所のページ（GET /place-pages。"placepages"。55）: 記録→場所の「行った場所のページ」
/// - 決めごと（GET /decisions。"decisions"。61）: タスクの「決めごと」と、今日の「気をつけること」（期限が 3 日以内）。
///   選んだら POST /decisions/answer（MothershipOutbox。押すまでは何も送らない・確かめの画面つき）
/// 写しは端末に置き（同期しない）、家の PC につながらないときも前の写しを見せる。中身の文は記録（ログ）に書かない。

// MARK: - 読んだ形

/// ほかのページへの行き来の 1 件（2026-11-16。強化案 139・123）。母艦の番号（人 pe_・場所 pl_）が届いていれば id に入る。
/// 無ければ名前の文字で引く。どの項目も省ける（前の写しには無い）
struct PageRef: Codable, Equatable {
    var id: String? = nil
    var name: String
}

struct PageDated: Codable, Equatable {
    var text: String
    var day: String? = nil
}

struct PageTalk: Codable, Equatable {
    var day: String
    var summary: String
    /// app・line
    var source: String
}

struct PagePromise: Codable, Equatable {
    var text: String
    /// me（自分がする）・them（相手がする）
    var by: String
    var day: String? = nil
    /// line・talk・task・todo
    var source: String
}

struct PageUpcoming: Codable, Equatable {
    var day: String
    var time: String = ""
    var title: String
}

struct PersonPage: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var group: String = ""
    var aliases: [String] = []
    var last_talk: PageTalk? = nil
    var last_line: String? = nil
    var line_7d: Int = 0
    var line_30d: Int = 0
    var talks_30d: Int = 0
    var topics: [PageDated] = []
    var promises: [PagePromise] = []
    var likes: [String] = []
    var next_line: String = ""
    var next_why: String = ""
    var upcoming: PageUpcoming? = nil
    var updated: String? = nil
    /// この人とよく行く場所（母艦が番号つきで渡したとき。2026-11-16。強化案 139）
    var places: [PageRef]? = nil
}

struct PeoplePagesFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [PersonPage] = []
}

struct ThreadPage: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// work・private
    var kind: String
    /// open・settled
    var status: String
    var decided: [PageDated] = []
    var open: [PageDated] = []
    var next: String = ""
    var days: [String] = []
    var last_day: String
    /// machine・claude
    var source: String = "machine"
    /// 話に出てくる人・場所（母艦が渡したときだけ。省ける。2026-11-16。強化案 123）
    var people: [PageRef]? = nil
    var places: [PageRef]? = nil
}

struct ThreadsFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [ThreadPage] = []
}

struct PlaceVisit: Codable, Equatable {
    var day: String
    /// "HH:MM–HH:MM"
    var time: String
    var amount: Int? = nil
    var with: [String] = []
    var talk: String = ""
}

struct PlacePage: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// 名前が確か（決済の店名と合った・本人が答えた）か
    var sure: Bool = false
    var visit_days: Int
    var visits: Int
    var last_day: String
    var spent: Int? = nil
    var with: [String] = []
    var recent: [PlaceVisit] = []
    /// 「誰と」の番号つきの形（母艦が渡したとき。省ける。2026-11-16。強化案 139）
    var people: [PageRef]? = nil
}

struct PlacePagesFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [PlacePage] = []
}

struct DecisionOption: Codable, Equatable, Identifiable {
    var n: Int
    var label: String
    var detail: String = ""
    var is_default: Bool = false
    var id: Int { n }
}

struct DecisionItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var deadline: String? = nil
    /// 決めないときの答え（帳面の「デフォルト」。JSON では "default"）
    var defaultAnswer: String = ""
    var options: [DecisionOption] = []
    var background: String = ""
    var opened: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, deadline, defaultAnswer = "default", options, background, opened
    }
}

struct DecisionsFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [DecisionItem] = []
}

// MARK: - 確かめ方（決まった入力から決まった出力だけ）

enum PagesFeeds {
    static let peopleLimit = 60
    static let threadLimit = 40
    static let placeLimit = 80
    static let decisionLimit = 30
    static let choiceMax = 20
    /// 「今日」の「気をつけること」に出す、期限までの日数
    static let dueDays = 3
    static let promiseSources: [String] = ["line", "talk", "task", "todo"]

    private struct RawRef: Decodable {
        var id: String?
        var name: String?
    }

    private struct RawDated: Decodable {
        var text: String?
        var day: String?
    }

    private struct RawTalk: Decodable {
        var day: String?
        var summary: String?
        var source: String?
    }

    private struct RawPromise: Decodable {
        var text: String?
        var by: String?
        var day: String?
        var source: String?
    }

    private struct RawUpcoming: Decodable {
        var day: String?
        var time: String?
        var title: String?
    }

    private struct RawPerson: Decodable {
        var id: String?
        var name: String?
        var group: String?
        var aliases: [LossyRow<String>]?
        var last_talk: LossyRow<RawTalk>?
        var last_line: String?
        var line_7d: Int?
        var line_30d: Int?
        var talks_30d: Int?
        var topics: [LossyRow<RawDated>]?
        var promises: [LossyRow<RawPromise>]?
        var likes: [LossyRow<String>]?
        var next_line: String?
        var next_why: String?
        var upcoming: LossyRow<RawUpcoming>?
        var updated: String?
        var places: [LossyRow<RawRef>]?
    }

    private struct RawPeopleFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawPerson>]?
    }

    private struct RawThread: Decodable {
        var id: String?
        var title: String?
        var kind: String?
        var status: String?
        var decided: [LossyRow<RawDated>]?
        var open: [LossyRow<RawDated>]?
        var next: String?
        var days: [LossyRow<String>]?
        var source: String?
        var people: [LossyRow<RawRef>]?
        var places: [LossyRow<RawRef>]?
    }

    private struct RawThreadsFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawThread>]?
    }

    private struct RawVisit: Decodable {
        var day: String?
        var time: String?
        var amount: Int?
        var with: [LossyRow<String>]?
        var talk: String?
    }

    private struct RawPlace: Decodable {
        var id: String?
        var name: String?
        var sure: Bool?
        var visit_days: Int?
        var visits: Int?
        var last_day: String?
        var spent: Int?
        var with: [LossyRow<String>]?
        var recent: [LossyRow<RawVisit>]?
        var people: [LossyRow<RawRef>]?
    }

    private struct RawPlacesFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawPlace>]?
    }

    private struct RawOption: Decodable {
        var n: Int?
        var label: String?
        var detail: String?
        var is_default: Bool?
    }

    private struct RawDecision: Decodable {
        var id: String?
        var title: String?
        var deadline: String?
        var defaultAnswer: String?
        var options: [LossyRow<RawOption>]?
        var background: String?
        var opened: String?

        enum CodingKeys: String, CodingKey {
            case id, title, deadline, defaultAnswer = "default", options, background, opened
        }
    }

    private struct RawDecisionsFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawDecision>]?
    }

    private static func day(_ text: String?) -> String? {
        guard let t = HomeFeeds.trimmed(text), HomeFeeds.isDay(t) else { return nil }
        return t
    }

    private static func id(_ text: String?) -> String? {
        guard let t = text, HomeFeeds.isID(t) else { return nil }
        return t
    }

    private static func count(_ value: Int?) -> Int {
        guard let value, value >= 0 else { return 0 }
        return value
    }

    /// 文の並び（空のものは落とし、n 文字まで・limit 個まで）
    static func strings(_ rows: [LossyRow<String>]?, _ n: Int, _ limit: Int) -> [String] {
        var out: [String] = []
        for row in rows ?? [] {
            guard let text = MothershipFeeds.cut(row.value, n) else { continue }
            out.append(text)
            if out.count >= limit { break }
        }
        return out
    }

    private static func dated(_ rows: [LossyRow<RawDated>]?, _ n: Int, _ limit: Int) -> [PageDated] {
        var out: [PageDated] = []
        for row in rows ?? [] {
            guard let r = row.value, let text = MothershipFeeds.cut(r.text, n) else { continue }
            out.append(PageDated(text: text, day: day(r.day)))
            if out.count >= limit { break }
        }
        return out
    }

    /// "HH:MM–HH:MM" か
    static func isSpan(_ text: String?) -> Bool {
        guard let text else { return false }
        let parts: [Substring] = text.split(separator: "–")
        guard parts.count == 2 else { return false }
        for part in parts {
            let p = String(part)
            guard p.count == 5, p.dropFirst(2).first == ":" else { return false }
            let digits: String = p.replacingOccurrences(of: ":", with: "")
            guard digits.count == 4, Int(digits) != nil else { return false }
        }
        return true
    }

    /// "H:MM"・"HH:MM" か
    static func isClock(_ text: String?) -> Bool {
        guard let text else { return false }
        let parts: [Substring] = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return parts[1].count == 2 && h >= 0 && h < 30 && m >= 0 && m < 60
    }

    // MARK: 人のページ

    static func decodePeople(_ data: Data) -> PeoplePagesFeed? {
        guard let raw = try? JSONDecoder().decode(RawPeopleFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [PersonPage] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let pid = id(r.id), let name = MothershipFeeds.cut(r.name, 20),
                  seen.insert(pid).inserted else { continue }
            var page = PersonPage(id: pid, name: name)
            page.group = MothershipFeeds.cut(r.group, 10) ?? ""
            page.aliases = strings(r.aliases, 20, 10)
            if let t = r.last_talk?.value, let d = day(t.day), let s = MothershipFeeds.cut(t.summary, 120),
               let source = t.source, source == "app" || source == "line" {
                page.last_talk = PageTalk(day: d, summary: s, source: source)
            }
            page.last_line = day(r.last_line)
            page.line_7d = count(r.line_7d)
            page.line_30d = count(r.line_30d)
            page.talks_30d = count(r.talks_30d)
            page.topics = dated(r.topics, 60, 5)
            for p in r.promises ?? [] {
                guard let v = p.value, let text = MothershipFeeds.cut(v.text, 80), let by = v.by, by == "me" || by == "them",
                      let source = v.source, promiseSources.contains(source) else { continue }
                page.promises.append(PagePromise(text: text, by: by, day: day(v.day), source: source))
                if page.promises.count >= 8 { break }
            }
            page.likes = strings(r.likes, 60, 6)
            page.next_line = MothershipFeeds.cut(r.next_line, 100) ?? ""
            page.next_why = MothershipFeeds.cut(r.next_why, 80) ?? ""
            if let u = r.upcoming?.value, let d = day(u.day), let title = MothershipFeeds.cut(u.title, 40) {
                let time: String = isClock(u.time) ? (u.time ?? "") : ""
                page.upcoming = PageUpcoming(day: d, time: time, title: title)
            }
            page.updated = day(r.updated)
            page.places = refs(r.places)
            items.append(page)
            if items.count >= peopleLimit { break }
        }
        return PeoplePagesFeed(generated_at: raw.generated_at, items: items)
    }

    /// 行き来の相手の並び（名前が読めないものは落とす。空なら nil）
    private static func refs(_ rows: [LossyRow<RawRef>]?, limit: Int = 8) -> [PageRef]? {
        var out: [PageRef] = []
        for row in rows ?? [] {
            guard let v = row.value, let name = MothershipFeeds.cut(v.name, 40) else { continue }
            var ref = PageRef(name: name)
            if let rid = v.id, HomeFeeds.isID(rid) { ref.id = rid }
            out.append(ref)
            if out.count >= limit { break }
        }
        return out.isEmpty ? nil : out
    }

    /// 行き来の相手が、そのページか。番号が両方にあれば番号で、無ければ名前の文字で
    static func refMatches(_ refs: [PageRef]?, id: String, name: String) -> Bool {
        for ref in refs ?? [] {
            if let rid = ref.id {
                if rid == id { return true }
            } else if !nameKey(ref.name).isEmpty, nameKey(ref.name) == nameKey(name) {
                return true
            }
        }
        return false
    }

    /// 場所のページの立ち寄りの時間（日と "HH:MM–HH:MM" から）。読めなければ nil
    static func visitSpan(day: String, time: String, calendar: Calendar = .current) -> (from: Date, to: Date)? {
        guard HomeFeeds.isDay(day), isSpan(time) else { return nil }
        let dayParts: [Substring] = day.split(separator: "-")
        guard dayParts.count == 3, let y = Int(dayParts[0]), let m = Int(dayParts[1]), let d = Int(dayParts[2]),
              let base = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let times: [Substring] = time.split(separator: "–")
        guard times.count == 2 else { return nil }
        var clocks: [Date] = []
        for t in times {
            let hm: [Substring] = t.split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let mi = Int(hm[1]),
                  let date = calendar.date(byAdding: .minute, value: h * 60 + mi, to: base) else { return nil }
            clocks.append(date)
        }
        var end: Date = clocks[1]
        // 日をまたぐ立ち寄り（終わりが始まりより前）は、翌日の時刻として読む
        if end < clocks[0] { end = end.addingTimeInterval(86400) }
        return (clocks[0], end)
    }

    /// 空白を除いた形（「見本 花子」と「見本花子」を同じにする）
    static func nameKey(_ text: String) -> String {
        var out: String = ""
        for ch in text where !ch.isWhitespace { out.append(ch) }
        return out.lowercased()
    }

    /// 名前（呼び名か別名）が合う人のページ。合う人が 2 人以上なら出さない（同じ名前の別の人を混ぜない）
    static func page(named name: String, in items: [PersonPage]) -> PersonPage? {
        let key: String = nameKey(name)
        guard key.count >= 2 else { return nil }
        var found: [PersonPage] = []
        for item in items {
            var keys: [String] = [nameKey(item.name)]
            for alias in item.aliases { keys.append(nameKey(alias)) }
            if keys.contains(key) { found.append(item) }
        }
        return found.count == 1 ? found[0] : nil
    }

    static func promiseLabel(_ by: String) -> String {
        by == "me" ? "自分がする" : "相手がする"
    }

    static func promiseSourceLabel(_ source: String) -> String {
        switch source {
        case "line": return "LINE"
        case "talk": return "会話"
        case "task": return "頼まれごと帳"
        case "todo": return "TODO"
        default: return source
        }
    }

    /// 「11/14 アプリの会話」
    static func talkLine(_ talk: PageTalk) -> String {
        let source: String = talk.source == "line" ? "LINE" : "アプリの会話"
        return AppFeeds.monthDay(talk.day) + " " + source
    }

    /// 「LINE 7日 4 通・30日 20 通・会話 30日 3 回」
    static func countsLine(_ page: PersonPage) -> String {
        let line: String = "LINE 7日 \(page.line_7d) 通・30日 \(page.line_30d) 通"
        return line + "・会話 30日 \(page.talks_30d) 回"
    }

    // MARK: 話題の糸

    static func decodeThreads(_ data: Data) -> ThreadsFeed? {
        guard let raw = try? JSONDecoder().decode(RawThreadsFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [ThreadPage] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let tid = id(r.id), let title = MothershipFeeds.cut(r.title, 40),
                  let kind = r.kind, kind == "work" || kind == "private",
                  let status = r.status, status == "open" || status == "settled" else { continue }
            var days: [String] = []
            for d in r.days ?? [] {
                if let v = day(d.value), !days.contains(v) { days.append(v) }
            }
            days.sort(by: >)
            guard let last = days.first, seen.insert(tid).inserted else { continue }
            let source: String = r.source == "claude" ? "claude" : "machine"
            items.append(ThreadPage(id: tid, title: title, kind: kind, status: status, decided: dated(r.decided, 100, 8),
                                    open: dated(r.open, 100, 8), next: MothershipFeeds.cut(r.next, 100) ?? "",
                                    days: Array(days.prefix(30)), last_day: last, source: source,
                                    people: refs(r.people), places: refs(r.places)))
            if items.count >= threadLimit { break }
        }
        items.sort { $0.last_day > $1.last_day }
        return ThreadsFeed(generated_at: raw.generated_at, items: items)
    }

    static func kindLabel(_ kind: String) -> String {
        kind == "private" ? "自分の予定" : "仕事"
    }

    /// 「11/14・11/12・11/10 ほか 3 日」
    static func daysLine(_ days: [String], limit: Int = 4) -> String {
        var parts: [String] = []
        for d in days.prefix(limit) { parts.append(AppFeeds.monthDay(d)) }
        var text: String = parts.joined(separator: "・")
        if days.count > limit { text += " ほか \(days.count - limit) 日" }
        return text
    }

    // MARK: 場所のページ

    static func decodePlaces(_ data: Data) -> PlacePagesFeed? {
        guard let raw = try? JSONDecoder().decode(RawPlacesFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [PlacePage] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let pid = id(r.id), let name = MothershipFeeds.cut(r.name, 40), let last = day(r.last_day),
                  let days = r.visit_days, days >= 0, let visits = r.visits, visits >= 0, seen.insert(pid).inserted else { continue }
            var page = PlacePage(id: pid, name: name, sure: r.sure == true, visit_days: days, visits: visits, last_day: last)
            if let spent = r.spent, spent >= 0 { page.spent = spent }
            page.with = strings(r.with, 20, 6)
            page.people = refs(r.people)
            for v in r.recent ?? [] {
                guard let x = v.value, let d = day(x.day), isSpan(x.time), let time = x.time else { continue }
                var amount: Int?
                if let a = x.amount, a >= 0 { amount = a }
                page.recent.append(PlaceVisit(day: d, time: time, amount: amount, with: strings(x.with, 20, 4),
                                              talk: MothershipFeeds.cut(x.talk, 100) ?? ""))
                if page.recent.count >= 20 { break }
            }
            items.append(page)
            if items.count >= placeLimit { break }
        }
        items.sort { $0.last_day != $1.last_day ? $0.last_day > $1.last_day : $0.visit_days > $1.visit_days }
        return PlacePagesFeed(generated_at: raw.generated_at, items: items)
    }

    /// 「1,280円」
    static func yen(_ amount: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let text: String = f.string(from: NSNumber(value: amount)) ?? String(amount)
        return text + "円"
    }

    /// 「行った日 2 日・立ち寄り 3 回・使ったお金 1,280円」
    static func placeLine(_ p: PlacePage) -> String {
        var text: String = "行った日 \(p.visit_days) 日・立ち寄り \(p.visits) 回"
        if let spent = p.spent { text += "・使ったお金 " + yen(spent) }
        return text
    }

    // MARK: 決めごと

    static func decodeDecisions(_ data: Data) -> DecisionsFeed? {
        guard let raw = try? JSONDecoder().decode(RawDecisionsFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [DecisionItem] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let did = id(r.id), let title = MothershipFeeds.cut(r.title, 60) else { continue }
            var options: [DecisionOption] = []
            var numbers = Set<Int>()
            for o in r.options ?? [] {
                guard let v = o.value, let n = v.n, n >= 1, n <= choiceMax, let label = MothershipFeeds.cut(v.label, 60),
                      numbers.insert(n).inserted else { continue }
                options.append(DecisionOption(n: n, label: label, detail: MothershipFeeds.cut(v.detail, 120) ?? "",
                                              is_default: v.is_default == true))
                if options.count >= 8 { break }
            }
            let fallback: String = MothershipFeeds.cut(r.defaultAnswer, 120) ?? ""
            guard !options.isEmpty || !fallback.isEmpty, seen.insert(did).inserted else { continue }
            items.append(DecisionItem(id: did, title: title, deadline: day(r.deadline), defaultAnswer: fallback, options: options,
                                      background: MothershipFeeds.cut(r.background, 300) ?? "", opened: day(r.opened)))
            if items.count >= decisionLimit { break }
        }
        items.sort { a, b in
            let x: String = a.deadline ?? "9999-12-31"
            let y: String = b.deadline ?? "9999-12-31"
            return x < y
        }
        return DecisionsFeed(generated_at: raw.generated_at, items: items)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormat.string(from: date) }

    /// 期限までの日数（今日が期限なら 0・過ぎていれば負）。読めなければ nil
    static func daysLeft(_ deadline: String?, today: String) -> Int? {
        guard let deadline, let end = dayFormat.date(from: deadline), let start = dayFormat.date(from: today) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        return cal.dateComponents([.day], from: start, to: end).day
    }

    /// 「あと 2 日（11/17）」「今日まで」「期限を過ぎています（11/14）」「期限なし」
    static func deadlineLabel(_ deadline: String?, today: String) -> String {
        guard let deadline, let left = daysLeft(deadline, today: today) else { return "期限なし" }
        let md: String = AppFeeds.monthDay(deadline)
        if left < 0 { return "期限を過ぎています（" + md + "）" }
        if left == 0 { return "今日まで" }
        return "あと \(left) 日（" + md + "）"
    }

    /// 期限が dueDays 日以内（過ぎたものも）の決めごと。まだ答えていないものだけ
    static func dueSoon(_ items: [DecisionItem], today: String, answered: Set<String>) -> [DecisionItem] {
        var out: [DecisionItem] = []
        for item in items where !answered.contains(item.id) {
            if let left = daysLeft(item.deadline, today: today), left <= dueDays { out.append(item) }
        }
        return out
    }

    /// 選べるもの: 番号つきの選択肢。無ければ「デフォルト」（番号 0）だけ
    static func choices(_ item: DecisionItem) -> [DecisionOption] {
        if !item.options.isEmpty { return item.options }
        return [DecisionOption(n: 0, label: item.defaultAnswer, detail: "", is_default: true)]
    }

    /// ボタンの文（「やめる（決めないときの答え）」・番号 0 は「決めないときの答えにする（…）」）
    static func choiceTitle(_ option: DecisionOption) -> String {
        if option.n == 0 { return "決めないときの答えにする（" + option.label + "）" }
        return option.is_default ? option.label + "（決めないときの答え）" : option.label
    }

    private struct AnswerBody: Codable {
        let id: String
        let choice: Int
        let day: String
    }

    /// POST /decisions/answer の中身（選んだものの文は送らない。家の PC が写しから作る）
    static func answerBody(id: String, choice: Int, day: String) -> Data? {
        guard HomeFeeds.isID(id), choice >= 0, choice <= choiceMax, HomeFeeds.isDay(day) else { return nil }
        return try? JSONEncoder().encode(AnswerBody(id: id, choice: choice, day: day))
    }
}

// MARK: - 読み込みと選ぶ

@MainActor
@Observable
final class PagesBook {
    static let shared = PagesBook()

    private(set) var people: [PersonPage] = []
    private(set) var threads: [ThreadPage] = []
    private(set) var places: [PlacePage] = []
    private(set) var decisions: [DecisionItem] = []
    /// アプリで選んだ決めごと（id → 選んだもの）。家の PC が帳面に入れて写しから消えたら、ここからも消す
    private(set) var answered: [String: String] = [:]
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var fetching = false

    private static let every: TimeInterval = 30 * 60
    static let peopleFile = "mfeed-people-pages.json"
    static let threadsFile = "mfeed-threads.json"
    static let placesFile = "mfeed-place-pages.json"
    static let decisionsFile = "mfeed-decisions.json"
    static let answeredFile = "pages-decisions-answered.json"

    private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(name)
    }

    /// 写しを書いた時刻（ファイルの時刻。無ければ nil。2026-11-22。s22 の 見14「前の写し ○分前」）
    static func copiedAt(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(name).path))?[.modificationDate] as? Date
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    init() {
        people = Self.read(PeoplePagesFeed.self, Self.peopleFile)?.items ?? []
        threads = Self.read(ThreadsFeed.self, Self.threadsFile)?.items ?? []
        places = Self.read(PlacePagesFeed.self, Self.placesFile)?.items ?? []
        decisions = Self.read(DecisionsFeed.self, Self.decisionsFile)?.items ?? []
        answered = Self.read([String: String].self, Self.answeredFile) ?? [:]
    }

    /// 読み直す（force でなければ30分に1回まで）。読めなかった写しは前のまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.isConfigured else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        if pc.features.contains("peoplepages"), let body = try? await pc.appFeed("people-pages", feature: "peoplepages"),
           let feed = PagesFeeds.decodePeople(body) {
            people = feed.items
            Self.write(feed, Self.peopleFile)
        }
        if pc.features.contains("threads"), let body = try? await pc.appFeed("threads", feature: "threads"),
           let feed = PagesFeeds.decodeThreads(body) {
            threads = feed.items
            Self.write(feed, Self.threadsFile)
        }
        if pc.features.contains("placepages"), let body = try? await pc.appFeed("place-pages", feature: "placepages"),
           let feed = PagesFeeds.decodePlaces(body) {
            places = feed.items
            Self.write(feed, Self.placesFile)
        }
        if pc.features.contains("decisions"), let body = try? await pc.appFeed("decisions", feature: "decisions"),
           let feed = PagesFeeds.decodeDecisions(body) {
            decisions = feed.items
            Self.write(feed, Self.decisionsFile)
            // 帳面に入って写しから消えたものは、選んだ印も消す（同じ題がまた出たら、また選べる）
            var kept: [String: String] = [:]
            for item in feed.items {
                if let label = answered[item.id] { kept[item.id] = label }
            }
            if kept != answered {
                answered = kept
                Self.write(answered, Self.answeredFile)
            }
        }
    }

    func page(named name: String) -> PersonPage? {
        PagesFeeds.page(named: name, in: people)
    }

    // MARK: ページどうしの行き来（2026-11-16。強化案 139）

    /// 行き来の相手の人のページ（番号があれば番号で。無ければ名前の文字で、合う人が 1 人のときだけ）
    func person(ref: PageRef) -> PersonPage? {
        if let id = ref.id, let hit = people.first(where: { $0.id == id }) { return hit }
        return PagesFeeds.page(named: ref.name, in: people)
    }

    /// 行き来の相手の場所のページ（番号があれば番号で。無ければ名前の文字が同じ場所が 1 つのときだけ）
    func place(ref: PageRef) -> PlacePage? {
        if let id = ref.id, let hit = places.first(where: { $0.id == id }) { return hit }
        let key: String = PagesFeeds.nameKey(ref.name)
        guard !key.isEmpty else { return nil }
        let hits: [PlacePage] = places.filter { PagesFeeds.nameKey($0.name) == key }
        return hits.count == 1 ? hits[0] : nil
    }

    /// その人とよく行く場所（人のページの places か、場所のページの「誰と」から。新しく行った順）
    func placesWith(_ person: PersonPage) -> [PlacePage] {
        var out: [PlacePage] = []
        for ref in person.places ?? [] {
            if let hit = place(ref: ref), !out.contains(where: { $0.id == hit.id }) { out.append(hit) }
        }
        for place in places where !out.contains(where: { $0.id == place.id }) {
            let seen: Bool = PagesFeeds.refMatches(place.people, id: person.id, name: person.name)
                || place.with.contains { PagesFeeds.nameKey($0) == PagesFeeds.nameKey(person.name) }
            if seen { out.append(place) }
        }
        return out
    }

    /// その人が出てくる話題の糸
    func threads(with person: PersonPage) -> [ThreadPage] {
        self.threads.filter { PagesFeeds.refMatches($0.people, id: person.id, name: person.name) }
    }

    /// その場所が出てくる話題の糸
    func threads(at place: PlacePage) -> [ThreadPage] {
        self.threads.filter { PagesFeeds.refMatches($0.places, id: place.id, name: place.name) }
    }

    /// まだ選んでいない決めごと
    var openDecisions: [DecisionItem] {
        var out: [DecisionItem] = []
        for item in decisions where answered[item.id] == nil { out.append(item) }
        return out
    }

    func dueSoon(now: Date = .now) -> [DecisionItem] {
        PagesFeeds.dueSoon(decisions, today: PagesFeeds.dayKey(now), answered: Set(answered.keys))
    }

    /// 選ぶ（家の PC に送るものをためる。押したあとに呼ぶ）。ためたら true
    @discardableResult
    func choose(_ item: DecisionItem, option: DecisionOption, now: Date = .now) -> Bool {
        guard let body = PagesFeeds.answerBody(id: item.id, choice: option.n, day: PagesFeeds.dayKey(now)) else { return false }
        MothershipOutbox.enqueue(path: "decisions/answer", body: body, now: now)
        answered[item.id] = option.label
        Self.write(answered, Self.answeredFile)
        Tally.add("decision.chosen")
        return true
    }
}

// MARK: - 画面: 人のページ（53）

/// 記録→人のいちばん上（写しがあるときだけ）
struct PeoplePagesSection: View {
    var body: some View {
        let people: [PersonPage] = PagesBook.shared.people
        if !people.isEmpty {
            Section {
                NavigationLink {
                    PeoplePagesView()
                } label: {
                    LabeledContent {
                        Text("\(people.count) 人")
                    } label: {
                        Label("人のページ", systemImage: "person.text.rectangle")
                    }
                }
            } footer: {
                Text("この60日に話した・LINE した人ごとに、最後に話したこと・続いている話題・互いの約束・好み・次に会うときの一言を、家の PCがまとめた1枚です。")
            }
        }
    }
}

struct PeoplePagesView: View {
    @Environment(Pipeline.self) private var pipeline

    private static let groups: [String] = ["家族", "友人", "仕事"]

    var body: some View {
        let people: [PersonPage] = PagesBook.shared.people
        LLList {
            if people.isEmpty {
                Text("まだ家の PC から届いていません。つながると読みます。").foregroundStyle(LL.dim)
            }
            ForEach(Self.groups, id: \.self) { group in
                let rows: [PersonPage] = people.filter { $0.group == group }
                if !rows.isEmpty {
                    Section(group) {
                        ForEach(rows) { page in PersonPageRow(page: page) }
                    }
                }
            }
            let rest: [PersonPage] = people.filter { !Self.groups.contains($0.group) }
            if !rest.isEmpty {
                Section("そのほか") {
                    ForEach(rest) { page in PersonPageRow(page: page) }
                }
            }
            // 前の写し ○分前（2026-11-22。s22 の 見14）。引っ張って読み直しているあいだは骨組み
            if refreshing {
                Section { LLSkeletonRows(count: 3) }
            }
            Section { LLCopyAgeLabel(at: copiedAt) }
        }
        .navigationTitle("人のページ")
        .countsOpen("peoplePages")
        .task { copiedAt = PagesBook.copiedAt(PagesBook.peopleFile) }
        .refreshable {
            refreshing = true
            await PagesBook.shared.refresh(pipeline.homePC, force: true)
            refreshing = false
            copiedAt = PagesBook.copiedAt(PagesBook.peopleFile)
        }
    }

    @State private var copiedAt: Date?
    @State private var refreshing = false
}

struct PersonPageRow: View {
    let page: PersonPage

    var body: some View {
        NavigationLink {
            PersonPageView(page: page)
        } label: {
            // 人の丸（2026-11-22。s22 の 見13）
            HStack(alignment: .top, spacing: LL.Space.s) {
                PersonAvatar(name: page.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.name)
                    if let last = page.last_talk {
                        Text(AppFeeds.monthDay(last.day) + " " + last.summary)
                            .font(.caption).foregroundStyle(LL.dim).lineLimit(2)
                    }
                }
            }
        }
    }
}

struct PersonPageView: View {
    let page: PersonPage

    var body: some View {
        LLList {
            if !page.next_line.isEmpty {
                Section {
                    Text(page.next_line)
                    if !page.next_why.isEmpty {
                        Text("もと:「" + page.next_why + "」").font(.caption).foregroundStyle(LL.dim)
                    }
                } header: {
                    Text("次に会うときの一言")
                }
            }
            if let last = page.last_talk {
                Section("最後に話したこと") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last.summary)
                        Text(PagesFeeds.talkLine(last)).font(.caption).foregroundStyle(LL.dim)
                    }
                }
            }
            if !page.topics.isEmpty {
                Section("続いている話題") {
                    ForEach(Array(page.topics.enumerated()), id: \.offset) { _, topic in
                        PageDatedRow(item: topic)
                    }
                }
            }
            let mine: [PagePromise] = page.promises.filter { $0.by == "me" }
            let theirs: [PagePromise] = page.promises.filter { $0.by == "them" }
            if !mine.isEmpty {
                Section(PagesFeeds.promiseLabel("me")) {
                    ForEach(Array(mine.enumerated()), id: \.offset) { _, p in PagePromiseRow(promise: p) }
                }
            }
            if !theirs.isEmpty {
                Section(PagesFeeds.promiseLabel("them")) {
                    ForEach(Array(theirs.enumerated()), id: \.offset) { _, p in PagePromiseRow(promise: p) }
                }
            }
            if !page.likes.isEmpty {
                Section {
                    ForEach(Array(page.likes.enumerated()), id: \.offset) { _, like in Text(like) }
                } header: {
                    Text("好み")
                } footer: {
                    Text("人物ノートと自分のプロファイルに書いてあることだけです（会話から推し量っていません）。")
                }
            }
            PersonLinksSection(page: page)
            // この人とどうなりたいか（2026-11-19。s18。KnowMeViews.swift）
            PersonGoalSection(name: page.name, pe: page.id)
            Section("やりとり") {
                Text(PagesFeeds.countsLine(page))
                if let last = page.last_line {
                    LabeledContent("最後の LINE", value: AppFeeds.monthDay(last))
                }
                if let up = page.upcoming {
                    let when: String = AppFeeds.monthDay(up.day) + " " + up.time
                    LabeledContent("次の予定", value: when + " " + up.title)
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("家の PCが人物ノート・会話・LINE・約束の記録からまとめました。会話の見出しは要約なので、事実と違うことがあります。")
            }
        }
        .navigationTitle(page.name)
        .countsOpen("personPage")
    }
}

struct PageDatedRow: View {
    let item: PageDated

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text)
            if let day = item.day {
                Text(AppFeeds.monthDay(day)).font(.caption).foregroundStyle(LL.dim)
            }
        }
    }
}

struct PagePromiseRow: View {
    let promise: PagePromise

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(promise.text)
            let day: String = promise.day.map { AppFeeds.monthDay($0) + "・" } ?? ""
            Text(day + PagesFeeds.promiseSourceLabel(promise.source)).font(.caption).foregroundStyle(LL.dim)
        }
    }
}

/// 人の画面（声）から、同じ名前の人のページへ（合う人が1人のときだけ）
struct PersonPageLinkSection: View {
    let name: String

    var body: some View {
        if let page = PagesBook.shared.page(named: name) {
            Section {
                NavigationLink {
                    PersonPageView(page: page)
                } label: {
                    Label("人のページ", systemImage: "person.text.rectangle")
                }
            }
        }
    }
}

/// 会う前の一枚（今日の「次の予定の前に」）の相手のページへ
struct PrepPeopleLinks: View {
    let names: [String]

    var body: some View {
        let book = PagesBook.shared
        ForEach(names, id: \.self) { name in
            if let page = book.page(named: name) {
                NavigationLink {
                    PersonPageView(page: page)
                } label: {
                    Label(name + " のページ", systemImage: "person.text.rectangle").font(.callout)
                }
            }
        }
    }
}

// MARK: - 画面: 話題の糸（54）

/// ふり返りの「話題の糸」（写しがあるときだけ）
struct ThreadsLookBackSection: View {
    var body: some View {
        let threads: [ThreadPage] = PagesBook.shared.threads
        if !threads.isEmpty {
            let open: Int = threads.filter { $0.status == "open" }.count
            Section {
                NavigationLink {
                    ThreadsView()
                } label: {
                    LabeledContent {
                        Text("続いている \(open) 本")
                    } label: {
                        Label("話題の糸", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
            } footer: {
                Text("何日もまたいだ同じ話（仕事の案件・旅行などの予定）ごとに、決まったこと・まだのこと・次の一手をまとめています。")
            }
        }
    }
}

struct ThreadsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let threads: [ThreadPage] = PagesBook.shared.threads
        let open: [ThreadPage] = threads.filter { $0.status == "open" }
        let settled: [ThreadPage] = threads.filter { $0.status != "open" }
        LLList {
            if threads.isEmpty {
                Text("まだ家の PC から届いていません。つながると読みます。").foregroundStyle(LL.dim)
            }
            if !open.isEmpty {
                Section("続いている") {
                    ForEach(open) { t in ThreadRow(thread: t) }
                }
            }
            if !settled.isEmpty {
                Section("落ち着いた") {
                    ForEach(settled) { t in ThreadRow(thread: t) }
                }
            }
        }
        .navigationTitle("話題の糸")
        .countsOpen("threads")
        .refreshable { await PagesBook.shared.refresh(pipeline.homePC, force: true) }
    }
}

struct ThreadRow: View {
    let thread: ThreadPage

    var body: some View {
        NavigationLink {
            ThreadDetailView(thread: thread)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.title)
                    Spacer(minLength: 4)
                    Text(PagesFeeds.kindLabel(thread.kind)).font(.caption2).foregroundStyle(LL.dim)
                }
                if !thread.next.isEmpty {
                    Text("次: " + thread.next).font(.caption).foregroundStyle(LL.dim).lineLimit(2)
                }
                Text(PagesFeeds.daysLine(thread.days)).font(.caption2).foregroundStyle(LL.dim)
            }
        }
    }
}

struct ThreadDetailView: View {
    let thread: ThreadPage

    var body: some View {
        LLList {
            if !thread.next.isEmpty {
                Section("次の一手") {
                    Text(thread.next)
                }
            }
            Section("まだのこと") {
                if thread.open.isEmpty {
                    Text("いまは無いようです").foregroundStyle(LL.dim)
                }
                ForEach(Array(thread.open.enumerated()), id: \.offset) { _, item in PageDatedRow(item: item) }
            }
            if !thread.decided.isEmpty {
                Section("決まったこと") {
                    ForEach(Array(thread.decided.enumerated()), id: \.offset) { _, item in PageDatedRow(item: item) }
                }
            }
            ThreadLinksSection(thread: thread)
            Section {
                Text(PagesFeeds.daysLine(thread.days, limit: 10))
            } header: {
                Text("出てきた日（\(thread.days.count) 日）")
            } footer: {
                Text(thread.source == "claude"
                     ? "家の PCが仕事のまとめ・朝のまとめから整えました（記録の文を引用できたものだけ）。"
                     : "家の PCが、案件のノートの名前が出てきた仕事のまとめの行から並べました。")
            }
        }
        .navigationTitle(thread.title)
        .countsOpen("threadDetail")
    }
}

// MARK: - 画面: 場所のページ（55）

/// 記録→場所の「行った場所のページ」（写しがあるときだけ）
struct PlacePagesSection: View {
    var body: some View {
        let places: [PlacePage] = PagesBook.shared.places
        if !places.isEmpty {
            Section {
                NavigationLink {
                    PlacePagesView()
                } label: {
                    LabeledContent("行った場所のページ", value: "\(places.count) か所")
                }
            } footer: {
                Text("お店・場所ごとに、行った回数・誰と・いくら・そこでの会話を、家の PCの場所のノートからまとめています。")
            }
        }
    }
}

struct PlacePagesView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let places: [PlacePage] = PagesBook.shared.places
        LLList {
            if places.isEmpty {
                Text("まだ家の PC から届いていません。つながると読みます。").foregroundStyle(LL.dim)
            }
            ForEach(places) { place in
                NavigationLink {
                    PlacePageView(place: place)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PlaceNameBook.shared.shown(pageID: place.id, original: place.name) + (place.sure ? "" : "（たぶん）"))
                        Text(PagesFeeds.placeLine(place) + "・最後 " + AppFeeds.monthDay(place.last_day))
                            .font(.caption).foregroundStyle(LL.dim)
                    }
                }
            }
        }
        .navigationTitle("行った場所")
        .countsOpen("placePages")
        .refreshable { await PagesBook.shared.refresh(pipeline.homePC, force: true) }
    }
}

struct PlacePageView: View {
    let place: PlacePage
    /// 名前を直している（2026-11-16。強化案 89。直した名前は場所の番号で覚えて、母艦にも送る）
    @State private var renaming = false
    @State private var nameText = ""

    private var shownName: String { PlaceNameBook.shared.shown(pageID: place.id, original: place.name) }

    var body: some View {
        LLList {
            Section {
                Text(PagesFeeds.placeLine(place))
                LabeledContent("最後に行った日", value: AppFeeds.monthDay(place.last_day))
            } footer: {
                if !place.sure {
                    Text("名前は位置からの推測（「たぶん」）です。同じ時間の支払いの店名で確かめられていません。")
                }
            }
            PlaceLinksSection(place: place)
            if !place.recent.isEmpty {
                Section {
                    ForEach(Array(place.recent.enumerated()), id: \.offset) { _, visit in PlaceVisitRow(visit: visit) }
                } header: {
                    Text("立ち寄り")
                } footer: {
                    Text("会話の1行は、その時間に始まった会話の見出しです（要約なので、事実と違うことがあります）。")
                }
            }
        }
        .navigationTitle(shownName)
        .countsOpen("placePage")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("名前を変える", systemImage: "pencil") {
                    nameText = shownName
                    renaming = true
                }
            }
        }
        .alert("場所の名前を変える", isPresented: $renaming) {
            TextField("新しい名前", text: $nameText)
            Button("変える") { _ = PlaceNameBook.shared.fixPage(id: place.id, name: nameText) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("直した名前は、家の PC の記録にも伝えます。")
        }
    }
}

struct PlaceVisitRow: View {
    let visit: PlaceVisit

    var body: some View {
        if let span = PagesFeeds.visitSpan(day: visit.day, time: visit.time) {
            // その時の会話・支払い・写真へ（2026-11-16。強化案 139）
            NavigationLink {
                MomentView(from: span.from, to: span.to, title: AppFeeds.monthDay(visit.day) + " " + visit.time)
            } label: {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppFeeds.monthDay(visit.day) + " " + visit.time).font(.subheadline.monospacedDigit())
                Spacer(minLength: 4)
                if let amount = visit.amount {
                    Text(PagesFeeds.yen(amount)).font(.subheadline.monospacedDigit())
                }
            }
            if !visit.with.isEmpty {
                Text("誰と: " + visit.with.joined(separator: "、")).font(.caption).foregroundStyle(LL.dim)
            }
            if !visit.talk.isEmpty {
                Text(visit.talk).font(.caption).foregroundStyle(LL.dim).lineLimit(2)
            }
        }
    }
}

// MARK: - 画面: 決めごと（61）

/// タスクの「やる」の上の「決めごと」（まだ選んでいないものがあるときだけ）
struct DecisionsTaskSection: View {
    var body: some View {
        let open: [DecisionItem] = PagesBook.shared.openDecisions
        if !open.isEmpty {
            let due: Int = PagesBook.shared.dueSoon().count
            Section {
                NavigationLink {
                    DecisionsView()
                } label: {
                    LabeledContent {
                        Text(due > 0 ? "\(open.count) 件（期限が近い \(due)）" : "\(open.count) 件")
                    } label: {
                        Label("決めごと", systemImage: "signpost.right.and.left")
                    }
                }
            }
        }
    }
}

struct DecisionsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var picking: DecisionItem?
    @State private var picked: DecisionOption?
    @State private var asking = false
    @State private var note: String?

    var body: some View {
        let book = PagesBook.shared
        let today: String = PagesFeeds.dayKey(.now)
        LLList {
            if let note {
                Section { Text(note).font(.footnote).foregroundStyle(LL.dim) }
            }
            if book.decisions.isEmpty {
                Text("まだ家の PC から届いていません。つながると読みます。").foregroundStyle(LL.dim)
            }
            ForEach(book.decisions) { item in
                Section {
                    DecisionCard(item: item, today: today, chosen: book.answered[item.id]) { option in
                        picking = item
                        picked = option
                        asking = true
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("家の PCの「決めごとの帳面」の、まだ決めていないものです。選ぶと確かめてから家の PC に送り、家の PC が帳面のその項目の下に「決定（日付・アプリで）」の1行を足します。30日たったら「その決定どうだった」を提案で聞きます。")
            }
        }
        .navigationTitle("決めごと")
        .countsOpen("decisions")
        .refreshable { await PagesBook.shared.refresh(pipeline.homePC, force: true) }
        .confirmationDialog(dialogTitle, isPresented: $asking, titleVisibility: .visible) {
            Button("決める") { decide() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("家の PC に送ると、家の PC の帳面に1行足します。あとで変えるときは、PC の帳面を直してください。")
        }
    }

    private var dialogTitle: String {
        guard let picking, let picked else { return "" }
        return "「" + picking.title + "」を「" + picked.label + "」に決めますか？"
    }

    private func decide() {
        guard let item = picking, let option = picked else { return }
        let ok: Bool = PagesBook.shared.choose(item, option: option)
        note = ok ? "「" + option.label + "」で送ります（つながらないときは、ためて次に送ります）。" : "送れませんでした。"
        picking = nil
        picked = nil
        Task { await pipeline.mothershipFeeds.sendOutbox(pipeline.homePC) }
    }
}

struct DecisionCard: View {
    let item: DecisionItem
    let today: String
    let chosen: String?
    let onPick: (DecisionOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.headline)
                Spacer(minLength: 4)
                let left: Int = PagesFeeds.daysLeft(item.deadline, today: today) ?? 99
                Text(PagesFeeds.deadlineLabel(item.deadline, today: today))
                    .font(.caption)
                    .foregroundStyle(left <= PagesFeeds.dueDays ? LL.warn : LL.dim)
            }
            if !item.defaultAnswer.isEmpty {
                Text("決めないと: " + item.defaultAnswer).font(.caption).foregroundStyle(LL.dim)
            }
            if !item.background.isEmpty {
                Text(item.background).font(.caption).foregroundStyle(LL.dim).lineLimit(4)
            }
        }
        if let chosen {
            Label("「" + chosen + "」で送りました", systemImage: "checkmark.circle").foregroundStyle(LL.good)
        } else {
            ForEach(PagesFeeds.choices(item)) { option in
                Button {
                    onPick(option)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PagesFeeds.choiceTitle(option))
                        if !option.detail.isEmpty {
                            Text(option.detail).font(.caption).foregroundStyle(LL.dim)
                        }
                    }
                }
            }
        }
    }
}

/// 今日の「気をつけること」の行（期限が3日以内の決めごと）。押すと決めごとの画面
struct DecisionDueRows: View {
    let items: [DecisionItem]

    var body: some View {
        let today: String = PagesFeeds.dayKey(.now)
        ForEach(items) { item in
            NavigationLink {
                DecisionsView()
            } label: {
                Label("決めごと「" + item.title + "」" + PagesFeeds.deadlineLabel(item.deadline, today: today),
                      systemImage: "signpost.right.and.left")
                    .foregroundStyle(LL.warn)
            }
        }
    }
}


// MARK: - 行き来（2026-11-16。強化案 139・123）

/// 人のページの「よく行く場所」「出てくる話題の糸」（あるときだけ）
struct PersonLinksSection: View {
    let page: PersonPage

    var body: some View {
        let book = PagesBook.shared
        let places: [PlacePage] = book.placesWith(page)
        let threads: [ThreadPage] = book.threads(with: page)
        if !places.isEmpty {
            Section("よく行く場所") {
                ForEach(places) { place in
                    NavigationLink {
                        PlacePageView(place: place)
                    } label: {
                        Label(PlaceNameBook.shared.shown(pageID: place.id, original: place.name), systemImage: "mappin.and.ellipse")
                    }
                }
            }
        }
        if !threads.isEmpty {
            Section("出てくる話題の糸") {
                ForEach(threads) { thread in
                    NavigationLink {
                        ThreadDetailView(thread: thread)
                    } label: {
                        Label(thread.title, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
            }
        }
    }
}

/// 場所のページの「誰と」（人のページへ）と「出てくる話題の糸」
struct PlaceLinksSection: View {
    let place: PlacePage

    /// 番号つきの「誰と」があればそれ。無ければ名前の文字
    private var refs: [PageRef] {
        if let people = place.people, !people.isEmpty { return people }
        var out: [PageRef] = []
        for name in place.with { out.append(PageRef(name: name)) }
        return out
    }

    var body: some View {
        let book = PagesBook.shared
        let refs: [PageRef] = self.refs
        let threads: [ThreadPage] = book.threads(at: place)
        if !refs.isEmpty {
            Section("誰と") {
                ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                    if let page = book.person(ref: ref) {
                        NavigationLink {
                            PersonPageView(page: page)
                        } label: {
                            Label(ref.name, systemImage: "person.text.rectangle")
                        }
                    } else {
                        Text(ref.name)
                    }
                }
            }
        }
        if !threads.isEmpty {
            Section("出てくる話題の糸") {
                ForEach(threads) { thread in
                    NavigationLink {
                        ThreadDetailView(thread: thread)
                    } label: {
                        Label(thread.title, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
            }
        }
    }
}

/// 話題の糸の「人」「場所」（母艦が渡したときだけ。省ける項目。強化案 123）
struct ThreadLinksSection: View {
    let thread: ThreadPage

    var body: some View {
        let book = PagesBook.shared
        let people: [PageRef] = thread.people ?? []
        let places: [PageRef] = thread.places ?? []
        if !people.isEmpty {
            Section("人") {
                ForEach(Array(people.enumerated()), id: \.offset) { _, ref in
                    if let page = book.person(ref: ref) {
                        NavigationLink {
                            PersonPageView(page: page)
                        } label: {
                            Label(ref.name, systemImage: "person.text.rectangle")
                        }
                    } else {
                        Text(ref.name)
                    }
                }
            }
        }
        if !places.isEmpty {
            Section("場所") {
                ForEach(Array(places.enumerated()), id: \.offset) { _, ref in
                    if let page = book.place(ref: ref) {
                        NavigationLink {
                            PlacePageView(place: page)
                        } label: {
                            Label(ref.name, systemImage: "mappin.and.ellipse")
                        }
                    } else {
                        Text(ref.name)
                    }
                }
            }
        }
    }
}

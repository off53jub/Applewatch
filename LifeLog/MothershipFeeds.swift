import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// 母艦（家の PC の D:\Lifelog）とのやり取りのうち、2026-11-13 の施策で足したもの。
/// 番号は母艦の docs/system-proposal-2026-11-13.md の番号。
/// 読む（家の PC の GET。母艦が作った写しを、PC とアプリの両方で確かめる）:
/// - 週のふり返り・見立ての台帳・使われ方の数（GET /weekly。features の "weekly"。2・3・1）
/// - 会う前の一枚（GET /prep。"prep"。4）
/// - 朝のまとめを比べる（GET /brief-compare。"briefcmp"。5）
/// - 精度の通信簿（GET /accuracy。"accuracy"。12）
/// - あまり開かれていない画面（GET /unused。"unused"。21）
/// 送る（POST。家の PC が母艦の inbox に1行足すだけ。つながらないときは端末にためて、次に送る）:
/// - 使われたか（POST /feedback。"feedback"。1）: 今日の三つの「やった・やらない」・朝のまとめを開いた・週のふり返りと会う前の一枚の「役に立った・いまいち」・
///   朝のまとめの「こっちがいい」
/// - 夜の10秒（POST /mood。"mood"。6）
/// - アプリを開いた記録（POST /app-usage。"appusage"。8。ショートカットのオートメーションから。AppUsage.swift）
/// 写しは端末に置き（同期しない）、家の PC につながらないときも前の写しを見せる。中身の文は記録（ログ）に書かない。

// MARK: - 読んだ形

struct WeeklyFeed: Codable, Equatable {
    struct Evidence: Codable, Equatable {
        var day: String
        var source: String? = nil
        var quote: String
    }

    /// 週のふり返りの1つ（theme 繰り返し出た話題・stuck 進んでいないこと・change 先週との違い）
    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var kind: String
        var title: String
        var body: String
        var evidence: [Evidence] = []
    }

    /// 見立て1つ（alive まだ生きている・weakened 弱まった・confirmed 確かめられた・unknown 分からない）
    struct Hypothesis: Codable, Equatable, Identifiable {
        var id: String
        var text: String
        var said_on: String? = nil
        var status: String
        var note: String = ""
        var checked_on: String? = nil
    }

    /// 出したものの使われ方（母艦が app_feedback.jsonl などから数える）
    struct Feedback: Codable, Equatable {
        struct Three: Codable, Equatable {
            var done = 0
            var skipped = 0
            var unknown = 0
        }

        struct Answers: Codable, Equatable {
            var accept = 0
            var later = 0
            var never = 0
        }

        var today_three = Three()
        var proposal = Answers()
        var brief_read = 0
    }

    var generated_at: String? = nil
    var week: String? = nil
    var from: String? = nil
    var to: String? = nil
    var items: [Item] = []
    var hypotheses: [Hypothesis] = []
    var feedback: Feedback? = nil
}

struct PrepItem: Codable, Equatable, Identifiable {
    struct LastTalk: Codable, Equatable {
        var day: String
        var summary: String
    }

    var id: String
    var start: String
    var end: String? = nil
    var title: String
    var people: [String] = []
    var last_talk: LastTalk? = nil
    var promises: [String] = []
    var recent: [String] = []
}

struct PrepFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [PrepItem] = []
}

struct BriefCompareDay: Codable, Equatable, Identifiable {
    var day: String
    var codex: String
    var claude: String
    var id: String { day }
}

struct BriefCompareFeed: Codable, Equatable {
    var generated_at: String? = nil
    var days: [BriefCompareDay] = []
}

struct AccuracyWeek: Codable, Equatable, Identifiable {
    var week: String
    var from: String? = nil
    var to: String? = nil
    var caught_self: Double? = nil
    var caught_other: Double? = nil
    var person_n_kinds_median: Int? = nil
    var fix_kept_ratio: Double? = nil
    var judge_agree: Double? = nil
    var night_review_kept: Double? = nil
    var speaking_score: Double? = nil
    var id: String { week }
}

struct AccuracyFeed: Codable, Equatable {
    var generated_at: String? = nil
    var weeks: [AccuracyWeek] = []
}

struct UnusedScreen: Codable, Equatable, Identifiable {
    var screen: String
    var opens: Int
    var days: Int
    var note: String = ""
    var id: String { screen }
}

struct UnusedFeed: Codable, Equatable {
    var generated_at: String? = nil
    var month: String? = nil
    var items: [UnusedScreen] = []
}

// MARK: - 確かめ方（決まった入力から決まった出力だけ）

enum MothershipFeeds {
    static let weeklyItemLimit = 5
    static let evidenceLimit = 5
    static let hypothesisLimit = 30
    static let prepLimit = 10
    static let prepListLimit = 5
    static let compareDayLimit = 7
    static let compareChars = 20000
    static let accuracyWeekLimit = 12
    static let unusedLimit = 40
    static let weeklyKinds: [String] = ["theme", "stuck", "change"]
    static let hypothesisStatuses: [String] = ["alive", "weakened", "confirmed", "unknown"]
    /// 「次の予定の前に」に出す幅（始まりがこれより先の予定は出さない）
    static let prepAhead: TimeInterval = 3 * 3600
    /// 始まってから少しのあいだは出しておく
    static let prepGrace: TimeInterval = 10 * 60

    // 読む前の形（どの項目も無いことがある。型が違う行は LossyRow が落とす）
    private struct RawWeekly: Decodable {
        var available: Bool?
        var generated_at: String?
        var week: String?
        var from: String?
        var to: String?
        var items: [LossyRow<RawWeeklyItem>]?
        var hypotheses: [LossyRow<RawHypothesis>]?
        var feedback: LossyRow<RawFeedback>?
    }

    private struct RawWeeklyItem: Decodable {
        var id: String?
        var kind: String?
        var title: String?
        var body: String?
        var evidence: [LossyRow<RawEvidence>]?
    }

    private struct RawEvidence: Decodable {
        var day: String?
        var source: String?
        var quote: String?
    }

    private struct RawHypothesis: Decodable {
        var id: String?
        var text: String?
        var said_on: String?
        var status: String?
        var note: String?
        var checked_on: String?
    }

    private struct RawFeedback: Decodable {
        var today_three: LossyRow<RawThree>?
        var proposal: LossyRow<RawAnswers>?
        var brief_read: Int?
    }

    private struct RawThree: Decodable {
        var done: Int?
        var skipped: Int?
        var unknown: Int?
    }

    private struct RawAnswers: Decodable {
        var accept: Int?
        var later: Int?
        var never: Int?
    }

    private struct RawPrepFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawPrep>]?
    }

    private struct RawPrep: Decodable {
        var id: String?
        var start: String?
        var end: String?
        var title: String?
        var people: [LossyRow<String>]?
        var last_talk: LossyRow<RawLastTalk>?
        var promises: [LossyRow<String>]?
        var recent: [LossyRow<String>]?
    }

    private struct RawLastTalk: Decodable {
        var day: String?
        var summary: String?
    }

    private struct RawCompareFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var days: [LossyRow<RawCompareDay>]?
    }

    private struct RawCompareDay: Decodable {
        var day: String?
        var codex: String?
        var claude: String?
    }

    private struct RawAccuracyFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var weeks: [LossyRow<RawWeek>]?
    }

    private struct RawWeek: Decodable {
        var week: String?
        var from: String?
        var to: String?
        var caught_self: Double?
        var caught_other: Double?
        var person_n_kinds_median: Double?
        var fix_kept_ratio: Double?
        var judge_agree: Double?
        var night_review_kept: Double?
        var speaking_score: Double?
    }

    private struct RawUnusedFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var month: String?
        var items: [LossyRow<RawUnused>]?
    }

    private struct RawUnused: Decodable {
        var screen: String?
        var opens: Int?
        var days: Int?
        var note: String?
    }

    /// 前後の空白を除き、limit 文字まで。空なら nil
    static func cut(_ text: String?, _ limit: Int) -> String? {
        guard let s = HomeFeeds.trimmed(text) else { return nil }
        return s.count > limit ? String(s.prefix(limit)) : s
    }

    /// "2026-W46" の形か
    static func isWeek(_ text: String?) -> Bool {
        guard let text, text.count == 8 else { return false }
        for (i, ch) in text.enumerated() {
            if i == 4 {
                if ch != "-" { return false }
            } else if i == 5 {
                if ch != "W" { return false }
            } else if !ch.isASCII || !ch.isNumber {
                return false
            }
        }
        return true
    }

    /// "2026-11" の形か
    static func isMonth(_ text: String?) -> Bool {
        guard let text, text.count == 7 else { return false }
        for (i, ch) in text.enumerated() {
            if i == 4 {
                if ch != "-" { return false }
            } else if !ch.isASCII || !ch.isNumber {
                return false
            }
        }
        return true
    }

    /// 0〜1 の割合（それ以外・無いときは nil）
    static func ratio(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 1 else { return nil }
        return value
    }

    private static func strings(_ rows: [LossyRow<String>]?, limit: Int, chars: Int) -> [String] {
        var out: [String] = []
        for row in rows ?? [] {
            guard let text = cut(row.value, chars) else { continue }
            out.append(text)
            if out.count >= limit { break }
        }
        return out
    }

    private static func day(_ text: String?) -> String? {
        guard let t = HomeFeeds.trimmed(text), HomeFeeds.isDay(t) else { return nil }
        return t
    }

    // MARK: 週のふり返り・見立ての台帳

    private static func clean(_ raw: RawWeeklyItem) -> WeeklyFeed.Item? {
        guard let id = HomeFeeds.trimmed(raw.id), HomeFeeds.isID(id),
              let kind = raw.kind, weeklyKinds.contains(kind),
              let title = cut(raw.title, 40) else { return nil }
        var evidence: [WeeklyFeed.Evidence] = []
        for row in raw.evidence ?? [] {
            guard let e = row.value, let d = day(e.day), let quote = cut(e.quote, 80) else { continue }
            evidence.append(WeeklyFeed.Evidence(day: d, source: cut(e.source, 20), quote: quote))
            if evidence.count >= evidenceLimit { break }
        }
        return WeeklyFeed.Item(id: id, kind: kind, title: title, body: cut(raw.body, 300) ?? "", evidence: evidence)
    }

    private static func clean(_ raw: RawHypothesis) -> WeeklyFeed.Hypothesis? {
        guard let id = HomeFeeds.trimmed(raw.id), HomeFeeds.isID(id),
              let text = cut(raw.text, 120),
              let status = raw.status, hypothesisStatuses.contains(status) else { return nil }
        return WeeklyFeed.Hypothesis(id: id, text: text, said_on: day(raw.said_on), status: status,
                                     note: cut(raw.note, 200) ?? "", checked_on: day(raw.checked_on))
    }

    /// GET /weekly の答え。読めない・{"available": false} なら nil（前の写しのままにする）
    static func decodeWeekly(_ data: Data) -> WeeklyFeed? {
        guard let raw = try? JSONDecoder().decode(RawWeekly.self, from: data), raw.available != false else { return nil }
        var feed = WeeklyFeed(generated_at: raw.generated_at)
        feed.week = isWeek(raw.week) ? raw.week : nil
        feed.from = day(raw.from)
        feed.to = day(raw.to)
        var seen = Set<String>()
        for row in raw.items ?? [] {
            guard let item = row.value.flatMap({ clean($0) }), seen.insert(item.id).inserted else { continue }
            feed.items.append(item)
            if feed.items.count >= weeklyItemLimit { break }
        }
        var seenH = Set<String>()
        for row in raw.hypotheses ?? [] {
            guard let h = row.value.flatMap({ clean($0) }), seenH.insert(h.id).inserted else { continue }
            feed.hypotheses.append(h)
            if feed.hypotheses.count >= hypothesisLimit { break }
        }
        if let f = raw.feedback?.value {
            var out = WeeklyFeed.Feedback()
            if let t = f.today_three?.value {
                out.today_three = WeeklyFeed.Feedback.Three(done: max(0, t.done ?? 0), skipped: max(0, t.skipped ?? 0),
                                                            unknown: max(0, t.unknown ?? 0))
            }
            if let p = f.proposal?.value {
                out.proposal = WeeklyFeed.Feedback.Answers(accept: max(0, p.accept ?? 0), later: max(0, p.later ?? 0),
                                                           never: max(0, p.never ?? 0))
            }
            out.brief_read = max(0, f.brief_read ?? 0)
            feed.feedback = out
        }
        return feed
    }

    /// 使われ方の数の1行「今日の三つ やった 3・やらない 1／提案 受けた 2・今はいい 1・いらない 0／朝のまとめ 開いた 4日」
    static func feedbackLine(_ f: WeeklyFeed.Feedback) -> String {
        var three = "今日の三つ やった \(f.today_three.done)・やらない \(f.today_three.skipped)"
        if f.today_three.unknown > 0 { three += "・分からない \(f.today_three.unknown)" }
        let proposal = "提案 受けた \(f.proposal.accept)・今はいい \(f.proposal.later)・いらない \(f.proposal.never)"
        let brief = "朝のまとめ 開いた \(f.brief_read)日"
        return three + "／" + proposal + "／" + brief
    }

    static func weeklyKindLabel(_ kind: String) -> String {
        switch kind {
        case "theme": return "くり返し出た話"
        case "stuck": return "進んでいないこと"
        case "change": return "先週との違い"
        default: return kind
        }
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "alive": return "まだ生きている"
        case "weakened": return "弱まった"
        case "confirmed": return "確かめられた"
        default: return "分からない"
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "alive": return .green
        case "weakened": return .orange
        case "confirmed": return .blue
        default: return .secondary
        }
    }

    /// 「11/9〜11/15」（分からなければ week のまま）
    static func weekLabel(week: String?, from: String?, to: String?) -> String {
        if let from, let to { return AppFeeds.monthDay(from) + "〜" + AppFeeds.monthDay(to) }
        if let from { return AppFeeds.monthDay(from) + "〜" }
        return week ?? ""
    }

    // MARK: 会う前の一枚

    private static func clean(_ raw: RawPrep) -> PrepItem? {
        guard let id = HomeFeeds.trimmed(raw.id), HomeFeeds.isID(id),
              let start = HomeFeeds.trimmed(raw.start), let from = AppFeeds.parseTime(start),
              let title = cut(raw.title, 60) else { return nil }
        let end = HomeFeeds.trimmed(raw.end)
        if let end {
            guard let to = AppFeeds.parseTime(end), to >= from else { return nil }
        }
        var last: PrepItem.LastTalk?
        if let l = raw.last_talk?.value, let d = day(l.day), let summary = cut(l.summary, 200) {
            last = PrepItem.LastTalk(day: d, summary: summary)
        }
        return PrepItem(id: id, start: start, end: end, title: title,
                        people: strings(raw.people, limit: prepListLimit, chars: 20), last_talk: last,
                        promises: strings(raw.promises, limit: prepListLimit, chars: 80),
                        recent: strings(raw.recent, limit: prepListLimit, chars: 80))
    }

    /// GET /prep の答え。始まりの早い順に10件まで
    static func decodePrep(_ data: Data) -> PrepFeed? {
        guard let raw = try? JSONDecoder().decode(RawPrepFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [PrepItem] = []
        for row in raw.items ?? [] {
            guard let p = row.value.flatMap({ clean($0) }), seen.insert(p.id).inserted else { continue }
            items.append(p)
        }
        items.sort { (AppFeeds.parseTime($0.start) ?? .distantFuture) < (AppFeeds.parseTime($1.start) ?? .distantFuture) }
        return PrepFeed(generated_at: raw.generated_at, items: Array(items.prefix(prepLimit)))
    }

    /// 「次の予定の前に」に出す予定。始まりが今から3時間以内（始まって10分までは出しておく）で、いちばん早いもの
    static func nextPrep(_ items: [PrepItem], now: Date, ahead: TimeInterval = MothershipFeeds.prepAhead,
                         grace: TimeInterval = MothershipFeeds.prepGrace) -> PrepItem? {
        var best: (item: PrepItem, start: Date)?
        for item in items {
            guard let start = AppFeeds.parseTime(item.start) else { continue }
            guard start >= now.addingTimeInterval(-grace), start <= now.addingTimeInterval(ahead) else { continue }
            if best == nil || start < best!.start { best = (item, start) }
        }
        return best?.item
    }

    /// 「10:00〜11:00」「10:00〜」
    static func prepTime(_ item: PrepItem, timeZone: TimeZone = .current) -> String {
        guard let start = AppFeeds.parseTime(item.start) else { return "" }
        var text = HomeFeeds.clock(start, timeZone: timeZone) + "〜"
        if let end = AppFeeds.parseTime(item.end) { text += HomeFeeds.clock(end, timeZone: timeZone) }
        return text
    }

    // MARK: 朝のまとめを比べる

    /// GET /brief-compare の答え。両方そろった日だけ、新しい日から7日まで
    static func decodeCompare(_ data: Data) -> BriefCompareFeed? {
        guard let raw = try? JSONDecoder().decode(RawCompareFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var days: [BriefCompareDay] = []
        for row in raw.days ?? [] {
            guard let r = row.value, let d = day(r.day),
                  let codex = HomeFeeds.trimmed(r.codex), let claude = HomeFeeds.trimmed(r.claude),
                  seen.insert(d).inserted else { continue }
            days.append(BriefCompareDay(day: d, codex: String(codex.prefix(compareChars)),
                                        claude: String(claude.prefix(compareChars))))
        }
        days.sort { $0.day > $1.day }
        return BriefCompareFeed(generated_at: raw.generated_at, days: Array(days.prefix(compareDayLimit)))
    }

    // MARK: 精度の通信簿

    /// GET /accuracy の答え。おかしな値は nil（「—」で見せる）。新しい週から12週まで
    static func decodeAccuracy(_ data: Data) -> AccuracyFeed? {
        guard let raw = try? JSONDecoder().decode(RawAccuracyFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var weeks: [AccuracyWeek] = []
        for row in raw.weeks ?? [] {
            guard let w = row.value, let week = w.week, isWeek(week), seen.insert(week).inserted else { continue }
            var median: Int?
            if let m = w.person_n_kinds_median, m.isFinite, m >= 0, m <= 100_000, m.rounded() == m { median = Int(m) }
            var speaking: Double?
            if let s = w.speaking_score, s.isFinite, s >= 0, s <= 100 { speaking = s }
            weeks.append(AccuracyWeek(week: week, from: day(w.from), to: day(w.to), caught_self: ratio(w.caught_self),
                                      caught_other: ratio(w.caught_other), person_n_kinds_median: median,
                                      fix_kept_ratio: ratio(w.fix_kept_ratio), judge_agree: ratio(w.judge_agree),
                                      night_review_kept: ratio(w.night_review_kept), speaking_score: speaking))
        }
        weeks.sort { $0.week > $1.week }
        return AccuracyFeed(generated_at: raw.generated_at, weeks: Array(weeks.prefix(accuracyWeekLimit)))
    }

    /// 「72%」。無ければ「—」
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    static func number(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)"
    }

    static func score(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))"
    }

    // MARK: あまり開かれていない画面

    /// GET /unused の答え。40件まで（同じ画面は初めのものだけ）
    static func decodeUnused(_ data: Data) -> UnusedFeed? {
        guard let raw = try? JSONDecoder().decode(RawUnusedFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [UnusedScreen] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let screen = cut(r.screen, 40), let opens = r.opens, opens >= 0,
                  let days = r.days, days >= 0, seen.insert(screen).inserted else { continue }
            items.append(UnusedScreen(screen: screen, opens: opens, days: days, note: cut(r.note, 80) ?? ""))
            if items.count >= unusedLimit { break }
        }
        return UnusedFeed(generated_at: raw.generated_at, month: isMonth(raw.month) ? raw.month : nil, items: items)
    }

    /// 画面の Tally の名前（"goodThings"）なら、その画面の名前に。知らなければそのまま
    static func screenName(_ key: String) -> String {
        for s in FeatureProof.screens where s.key == key || FeatureProof.screenKey(s) == key {
            return s.name
        }
        return key
    }

    // MARK: 今日の三つの印

    /// 今日の三つの1つを母艦に返すときの id（英数字と _ . : - で64字まで）。
    /// 家の PC のやることの id → アプリのタスクの id → 文から作った印（同じ文なら同じ）の順
    static func pickID(_ pick: MorningBrief.Pick) -> String {
        if let home = pick.homeID {
            let id = "h:" + home
            if HomeFeeds.isID(id) { return id }
        }
        if let task = pick.taskID {
            let id = "t:" + task
            if HomeFeeds.isID(id) { return id }
        }
        return "x:" + hash(pick.text)
    }

    /// FNV-1a（64bit）の16進。言葉そのものは送らない
    static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }
}

// MARK: - 送る前のもの（端末にためる。ショートカットからも足す）

struct OutboxItem: Codable, Equatable, Identifiable {
    var id: String
    /// "feedback"・"mood"・"app-usage"（家の PC の POST の道）
    var path: String
    /// 送る JSON
    var body: Data
    var queued: Date
    /// 家の PC に断られた回数（5回で捨てる。通じなかったときは数えない）
    var tries: Int? = nil
}

enum MothershipOutbox {
    static let fileName = "mothership-outbox.json"
    /// ためておく数（多すぎたら、古いアプリの記録から捨てる）
    static let limit = 1000
    static let maxTries = 5

    static let feedbackKinds: [String: [String]] = [
        "today_three": ["done", "skipped"], "brief": ["read"], "weekly": ["useful", "not_useful"],
        "prep": ["useful", "not_useful"], "brief_compare": ["codex", "claude"], "night_review": ["kept", "dropped"],
        "same_person": ["merged", "different"], "promise": ["added", "ignored"], "bulk": ["ok"],
        // 正しさの抜き取り「合ってる？」（2026-11-15。強化案 41。SettleFeeds.swift）
        "check": ["right", "wrong", "unsure"],
    ]
    static let appEvents: [String] = ["open", "close", "focus_on", "focus_off"]

    /// 道 → 家の PC の features の名前
    static func feature(for path: String) -> String {
        switch path {
        case "feedback": return "feedback"
        case "mood": return "mood"
        case "app-usage": return "appusage"
        case "decisions/answer": return "decisions"  // 決めごとの答え（2026-11-15。強化案 61。PagesFeeds.swift）
        default: return path
        }
    }

    /// "2026-11-13T21:40:00+09:00"
    static func isoString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    private struct FeedbackBody: Codable {
        let kind: String
        let id: String
        let value: String
        let day: String
    }

    private struct MoodBody: Codable {
        let day: String
        let at: String
        let mood: Int
        let energy: Int
        let grip: Int
        let note: String?
    }

    private struct AppUsageBody: Codable {
        let at: String
        let app: String
        let event: String
    }

    /// POST /feedback の中身。決めた組でなければ nil
    static func feedbackBody(kind: String, id: String, value: String, day: String) -> Data? {
        guard let values = feedbackKinds[kind], values.contains(value), HomeFeeds.isID(id), HomeFeeds.isDay(day) else { return nil }
        return try? JSONEncoder().encode(FeedbackBody(kind: kind, id: id, value: value, day: day))
    }

    /// POST /mood の中身。3つとも1〜5でなければ nil。覚え書きは200文字まで（空なら付けない）
    static func moodBody(day: String, at: Date, mood: Int, energy: Int, grip: Int, note: String?,
                         timeZone: TimeZone = .current) -> Data? {
        let scores: [Int] = [mood, energy, grip]
        for s in scores where s < 1 || s > 5 { return nil }
        guard HomeFeeds.isDay(day) else { return nil }
        let text: String? = MothershipFeeds.cut(note, 200)
        return try? JSONEncoder().encode(MoodBody(day: day, at: isoString(at, timeZone: timeZone), mood: mood,
                                                  energy: energy, grip: grip, note: text))
    }

    /// POST /app-usage の中身。名前が空・出来事が違えば nil（名前は40文字まで）
    static func appUsageBody(at: Date, app: String, event: String, timeZone: TimeZone = .current) -> Data? {
        guard appEvents.contains(event), let name = MothershipFeeds.cut(app, 40) else { return nil }
        return try? JSONEncoder().encode(AppUsageBody(at: isoString(at, timeZone: timeZone), app: name, event: event))
    }

    /// 1つ足す。数が limit を超えたら、古いアプリの記録から捨てる（使われ方・気分はなるべく残す）
    static func appending(_ list: [OutboxItem], _ item: OutboxItem, limit: Int = MothershipOutbox.limit) -> [OutboxItem] {
        var next = list
        next.append(item)
        while next.count > limit {
            if let i = next.firstIndex(where: { $0.path == "app-usage" }) {
                next.remove(at: i)
            } else {
                next.removeFirst()
            }
        }
        return next
    }

    static func removing(_ list: [OutboxItem], id: String) -> [OutboxItem] {
        list.filter { $0.id != id }
    }

    /// 家の PC に断られた。回数を足し、maxTries 回で捨てる
    static func failing(_ list: [OutboxItem], id: String, maxTries: Int = MothershipOutbox.maxTries) -> [OutboxItem] {
        var next: [OutboxItem] = []
        for var item in list {
            if item.id == id {
                let tries = (item.tries ?? 0) + 1
                if tries >= maxTries { continue }
                item.tries = tries
            }
            next.append(item)
        }
        return next
    }

    // MARK: ファイル（アプリの中でも、ショートカットからでも、同じ所に足す）

    private static var url: URL { URL.applicationSupportDirectory.appendingPathComponent(fileName) }

    /// 読めない行は飛ばす。ファイルの形が違えば、そのファイルは横に残して（.bad）空から始める
    @MainActor
    static func load() -> [OutboxItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let rows = try? JSONDecoder().decode([LossyRow<OutboxItem>].self, from: data) {
            var out: [OutboxItem] = []
            for row in rows {
                if let item = row.value { out.append(item) }
            }
            return out
        }
        let bad = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        return []
    }

    @MainActor
    static func save(_ list: [OutboxItem]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 1つためる（すぐには送らない。送るのは send）
    @MainActor
    static func enqueue(path: String, body: Data, now: Date = .now) {
        let item = OutboxItem(id: UUID().uuidString, path: path, body: body, queued: now)
        save(appending(load(), item))
    }

    /// POST /feedback を1つためる（決めた組でなければ捨てる）。ためたら true
    @MainActor
    @discardableResult
    static func enqueueFeedback(kind: String, id: String, value: String, day: String, now: Date = .now) -> Bool {
        guard let body = feedbackBody(kind: kind, id: id, value: value, day: day) else { return false }
        enqueue(path: "feedback", body: body, now: now)
        return true
    }

    // MARK: 送る（送り口はここ1つ。2026-11-15。強化案 46）

    @MainActor private static var sending = false

    /// ためたものを古い順に送る。家の PC がまだ受けない種類は飛ばして残す。通じなければそこでやめる。
    /// 家の PC に断られたもの（中身がおかしい）は、5回で捨てる
    @MainActor
    static func send(_ pc: HomePC) async {
        guard !sending, pc.isConfigured else { return }
        sending = true
        defer { sending = false }
        var skipped = Set<String>()
        sendLoop: while true {
            let list: [OutboxItem] = load()
            guard let item = list.first(where: { !skipped.contains($0.id) }) else { break sendLoop }
            guard pc.features.contains(feature(for: item.path)) else {
                skipped.insert(item.id)
                continue sendLoop
            }
            do {
                _ = try await pc.postJSONData(item.path, body: item.body, timeout: 10)
                save(removing(load(), id: item.id))
                Tally.add("mfeed.sent")
            } catch {
                if let failure = error as? HomePC.Failure, case .server(_) = failure {
                    save(failing(load(), id: item.id))
                    skipped.insert(item.id)
                    continue sendLoop
                }
                break sendLoop
            }
        }
    }

    // MARK: 前の送り口からの引っ越し（2026-11-15。強化案 46）

    /// 前の「直す」の答えのため場所（SamePerson.swift の FixFeedback。[{"kind","id","value","day"}] の JSON）
    static let legacyFixKey = "fixFeedbackPending"
    /// 前の約束の答えのため場所（Promises.swift の PromiseFeedbackQueue。送る JSON の並び）
    static let legacyPromiseKey = "promiseFeedbackQueue"

    private struct LegacyFeedback: Codable {
        let kind: String
        let id: String
        let value: String
        let day: String
    }

    /// 前の2つの送り口にたまっていたものを、古い順にうしろへ足す（数の上限で落とさない。次に足すときに上限に戻る）
    static func migrating(_ list: [OutboxItem], fix: [Data], promise: [Data], now: Date) -> [OutboxItem] {
        var next: [OutboxItem] = list
        var bodies: [Data] = fix
        bodies.append(contentsOf: promise)
        for (i, body) in bodies.enumerated() {
            let item = OutboxItem(id: "legacy-\(i)-" + UUID().uuidString, path: "feedback", body: body, queued: now)
            next = appending(next, item, limit: Int.max)
        }
        return next
    }

    /// 前の「直す」のため場所の中身を、1つずつの JSON に（読めなければ nil。そのときは前の所を消さない）
    static func legacyFixBodies(_ data: Data) -> [Data]? {
        guard let rows = try? JSONDecoder().decode([LegacyFeedback].self, from: data) else { return nil }
        var out: [Data] = []
        for row in rows {
            if let body = try? JSONEncoder().encode(row) { out.append(body) }
        }
        return out
    }

    /// 起動のときに1回。前の2つの送り口にたまっていたものをここへ移し、書けたのを確かめてから前の所を消す
    @MainActor
    static func migrateLegacy(now: Date = .now) {
        let defaults = UserDefaults.standard
        var fix: [Data] = []
        var fixReadable = true
        if let data = defaults.data(forKey: legacyFixKey) {
            if let bodies = legacyFixBodies(data) {
                fix = bodies
            } else {
                fixReadable = false
            }
        }
        let promise: [Data] = defaults.array(forKey: legacyPromiseKey) as? [Data] ?? []
        guard !fix.isEmpty || !promise.isEmpty else {
            if fixReadable { defaults.removeObject(forKey: legacyFixKey) }
            defaults.removeObject(forKey: legacyPromiseKey)
            return
        }
        let before: [OutboxItem] = load()
        let next: [OutboxItem] = migrating(before, fix: fix, promise: promise, now: now)
        guard saveChecked(next) else { return }
        if fixReadable { defaults.removeObject(forKey: legacyFixKey) }
        defaults.removeObject(forKey: legacyPromiseKey)
        Tally.add("mfeed.migrated", fix.count + promise.count)
    }

    /// 書いて、読み直して同じ数なら true
    @MainActor
    private static func saveChecked(_ list: [OutboxItem]) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        return load().count == list.count
    }

    /// アプリを開いた記録（ショートカットの「アプリを開いた記録」から。AppUsage.swift）。足せたら true
    @MainActor
    @discardableResult
    static func enqueueAppUsage(app: String, event: String, at: Date = .now) -> Bool {
        guard let body = appUsageBody(at: at, app: app, event: event) else { return false }
        enqueue(path: "app-usage", body: body, now: at)
        Tally.add("appusage.queued")
        return true
    }
}

// MARK: - 端末の中だけの印

/// 今日の三つの1つを覚えておく（あとでタスクを済みにしたら「やった」を返すため）
struct PickRef: Codable, Equatable {
    var fid: String
    var taskID: String? = nil
    var homeID: String? = nil
}

struct MothershipLocal: Codable, Equatable {
    /// 返した答え（"kind|id" → value）。同じ答えは二度送らない
    var voted: [String: String] = [:]
    /// 日（yyyy-MM-dd）→ その日に見せた今日の三つ
    var picks: [String: [PickRef]] = [:]
    /// 夜の10秒に答えた日
    var moodDay: String? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voted = try c.decodeIfPresent([String: String].self, forKey: .voted) ?? [:]
        picks = try c.decodeIfPresent([String: [PickRef]].self, forKey: .picks) ?? [:]
        moodDay = try c.decodeIfPresent(String.self, forKey: .moodDay)
    }

    private enum CodingKeys: String, CodingKey {
        case voted, picks, moodDay
    }

    static func key(_ kind: String, _ id: String) -> String { kind + "|" + id }

    /// 7日より前の今日の三つの印を消す。答えも 1000 を超えたら、今日の三つ以外の古いものから消す（順は分からないので、kind で選ぶ）
    static func pruned(_ local: MothershipLocal, today: String, keepDays: Int = 7) -> MothershipLocal {
        var next = local
        let days: [String] = next.picks.keys.sorted()
        if days.count > keepDays {
            for d in days.prefix(days.count - keepDays) { next.picks.removeValue(forKey: d) }
        }
        for d in days where d > today { next.picks.removeValue(forKey: d) }
        if next.voted.count > 1000 {
            let keys: [String] = next.voted.keys.sorted()
            for k in keys.prefix(next.voted.count - 1000) { next.voted.removeValue(forKey: k) }
        }
        return next
    }
}

// MARK: - 夜の10秒（6）

enum NightMood {
    static let reminderOnKey = "nightMoodReminderOn"
    static let reminderTimeKey = "nightMoodReminderTime"
    static let noticeID = "night-mood"
    /// 出し始める時刻
    static let startHour = 20
    /// この時刻（朝）までは前の日の分として出す
    static let endHour = 4

    /// 知らせるか（初めはオフ）
    static var reminderOn: Bool { UserDefaults.standard.object(forKey: reminderOnKey) as? Bool ?? false }
    /// 知らせる時刻（0時からの分。初めは21時30分）
    static var reminderMinutes: Int { UserDefaults.standard.object(forKey: reminderTimeKey) as? Int ?? 21 * 60 + 30 }

    /// 「夜の10秒」を出す日（20時〜翌朝4時。0〜4時は前の日の分）。出さない時間なら nil
    static func windowDay(_ now: Date, calendar: Calendar = .current) -> String? {
        let hour = calendar.component(.hour, from: now)
        let base: Date
        if hour >= startHour {
            base = now
        } else if hour < endHour {
            base = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        } else {
            return nil
        }
        let c = calendar.dateComponents([.year, .month, .day], from: base)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 毎日の知らせを頼み直す（オフなら消すだけ）。iPad では出さない
    @MainActor
    static func scheduleReminder() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [noticeID])
        guard reminderOn, UIDevice.current.userInterfaceIdiom != .pad else { return }
        let content = UNMutableNotificationContent()
        content.title = "夜の10秒"
        content.body = "今日の気分・疲れ・手ごたえを3つ押すだけです。"
        content.sound = .default
        var comps = DateComponents()
        comps.hour = reminderMinutes / 60
        comps.minute = reminderMinutes % 60
        try? await center.add(UNNotificationRequest(
            identifier: noticeID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
    }
}

// MARK: - 読み込みと送り

@MainActor
@Observable
final class MothershipFeedsBook {
    private(set) var weekly: WeeklyFeed?
    private(set) var prep: [PrepItem] = []
    private(set) var compare: [BriefCompareDay] = []
    private(set) var accuracy: [AccuracyWeek] = []
    private(set) var unused: UnusedFeed?
    private(set) var local = MothershipLocal()
    /// まだ送っていない数
    private(set) var waiting = 0
    private(set) var fetchedAt: Date?
    @ObservationIgnored private var fetching = false

    private static let every: TimeInterval = 30 * 60
    static let weeklyFile = "mfeed-weekly.json"
    static let prepFile = "mfeed-prep.json"
    static let compareFile = "mfeed-briefcmp.json"
    static let accuracyFile = "mfeed-accuracy.json"
    static let unusedFile = "mfeed-unused.json"
    static let localFile = "mfeed-local.json"

    private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(name)
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormat.string(from: date) }

    /// 端末の印のファイルが読めなかった（壊れていた）ときは、上書きしない
    @ObservationIgnored private var localUnreadable = false

    init() {
        weekly = Self.read(WeeklyFeed.self, Self.weeklyFile)
        prep = Self.read(PrepFeed.self, Self.prepFile)?.items ?? []
        compare = Self.read(BriefCompareFeed.self, Self.compareFile)?.days ?? []
        accuracy = Self.read(AccuracyFeed.self, Self.accuracyFile)?.weeks ?? []
        unused = Self.read(UnusedFeed.self, Self.unusedFile)
        if let data = try? Data(contentsOf: Self.url(Self.localFile)) {
            if let saved = try? JSONDecoder().decode(MothershipLocal.self, from: data) {
                local = saved
            } else {
                localUnreadable = true
            }
        }
        // 前の2つの送り口（直すの答え・約束の答え）にたまっていたものを、ここへ移す（2026-11-15。強化案 46）
        MothershipOutbox.migrateLegacy()
        waiting = MothershipOutbox.load().count
    }

    private func saveLocal() {
        guard !localUnreadable else { return }
        local = MothershipLocal.pruned(local, today: Self.dayKey(.now))
        Self.write(local, Self.localFile)
    }

    // MARK: 使われたか（1）

    /// 返した答え（無ければ nil）
    func voted(_ kind: String, id: String) -> String? {
        local.voted[MothershipLocal.key(kind, id)]
    }

    /// 答えをためる（同じ答えは二度ためない）。ためたら true
    @discardableResult
    func vote(_ kind: String, id: String, value: String, day: String) -> Bool {
        let key = MothershipLocal.key(kind, id)
        guard local.voted[key] != value,
              let body = MothershipOutbox.feedbackBody(kind: kind, id: id, value: value, day: day) else { return false }
        MothershipOutbox.enqueue(path: "feedback", body: body)
        local.voted[key] = value
        saveLocal()
        waiting = MothershipOutbox.load().count
        Tally.add("mfeed." + kind)
        return true
    }

    /// 朝のまとめを開いた（1日に1回だけ返す）
    func noteBriefRead(day: String) {
        vote("brief", id: "brief-" + day, value: "read", day: day)
    }

    /// 今日の三つを見せた（あとでタスクを済みにしたら「やった」を返すため、その日の分を覚える）
    func notePicks(_ picks: [MorningBrief.Pick], day: String) {
        var refs: [PickRef] = local.picks[day] ?? []
        var changed = false
        for pick in picks {
            let fid = MothershipFeeds.pickID(pick)
            if refs.contains(where: { $0.fid == fid }) { continue }
            refs.append(PickRef(fid: fid, taskID: pick.taskID, homeID: pick.homeID))
            changed = true
        }
        guard changed else { return }
        local.picks[day] = Array(refs.suffix(20))
        saveLocal()
    }

    /// 今日の三つの答え（"done"・"skipped"。まだなら nil）
    func threeAnswer(_ pick: MorningBrief.Pick) -> String? {
        voted("today_three", id: MothershipFeeds.pickID(pick))
    }

    func answerThree(_ pick: MorningBrief.Pick, done: Bool, day: String) {
        vote("today_three", id: MothershipFeeds.pickID(pick), value: done ? "done" : "skipped", day: day)
    }

    /// 見せた今日の三つのうち、ほかの所（タスクの○・家の PC のやることの「済み」）で済みにしたものに「やった」を返す
    func reconcileThree(doneTasks: Set<String>, doneHome: Set<String>) {
        let days: [String] = local.picks.keys.sorted()
        for day in days {
            for ref in local.picks[day] ?? [] where voted("today_three", id: ref.fid) == nil {
                let taskDone = ref.taskID.map { doneTasks.contains($0) } ?? false
                let homeDone = ref.homeID.map { doneHome.contains($0) } ?? false
                if taskDone || homeDone {
                    vote("today_three", id: ref.fid, value: "done", day: day)
                }
            }
        }
    }

    // MARK: 夜の10秒（6）

    func answeredMood(day: String) -> Bool { local.moodDay == day }

    /// 気分・疲れ・手ごたえをためる。ためたら true
    @discardableResult
    func saveMood(day: String, mood: Int, energy: Int, grip: Int, note: String?) -> Bool {
        guard let body = MothershipOutbox.moodBody(day: day, at: .now, mood: mood, energy: energy, grip: grip, note: note) else {
            return false
        }
        MothershipOutbox.enqueue(path: "mood", body: body)
        local.moodDay = day
        saveLocal()
        waiting = MothershipOutbox.load().count
        Tally.add("mood.answered")
        return true
    }

    // MARK: 家の PC と

    /// 「次の予定の前に」の予定（無ければ nil）
    func nextPrep(now: Date = .now) -> PrepItem? {
        MothershipFeeds.nextPrep(prep, now: now)
    }

    /// 読み直す（force でなければ30分に1回まで）。読めなかった写しは前のまま。ためたものも送る
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every {
            await sendOutbox(pc)
            return
        }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        if pc.features.contains("weekly"), let body = try? await pc.appFeed("weekly", feature: "weekly"),
           let feed = MothershipFeeds.decodeWeekly(body) {
            weekly = feed
            Self.write(feed, Self.weeklyFile)
        }
        if pc.features.contains("prep"), let body = try? await pc.appFeed("prep", feature: "prep"),
           let feed = MothershipFeeds.decodePrep(body) {
            prep = feed.items
            Self.write(feed, Self.prepFile)
        }
        if pc.features.contains("briefcmp"), let body = try? await pc.appFeed("brief-compare", feature: "briefcmp"),
           let feed = MothershipFeeds.decodeCompare(body) {
            compare = feed.days
            Self.write(feed, Self.compareFile)
        }
        if pc.features.contains("accuracy"), let body = try? await pc.appFeed("accuracy", feature: "accuracy"),
           let feed = MothershipFeeds.decodeAccuracy(body) {
            accuracy = feed.weeks
            Self.write(feed, Self.accuracyFile)
        }
        if pc.features.contains("unused"), let body = try? await pc.appFeed("unused", feature: "unused"),
           let feed = MothershipFeeds.decodeUnused(body) {
            unused = feed
            Self.write(feed, Self.unusedFile)
        }
        await sendOutbox(pc)
    }

    /// ためたものを古い順に送る。家の PC がまだ受けない種類は飛ばして残す。通じなければそこでやめる。
    /// 家の PC に断られたもの（中身がおかしい）は、5回で捨てる
    func sendOutbox(_ pc: HomePC) async {
        // 送り口は MothershipOutbox.send の1つ（直す・約束の答えも同じ所から。2026-11-15。強化案 46）
        await MothershipOutbox.send(pc)
        waiting = MothershipOutbox.load().count
    }
}

// MARK: - Pipeline から

extension Pipeline {
    /// アプリを開いたときに呼ぶ。済みにした今日の三つを確かめてから、写しを読み直し、ためたものを送る
    func refreshMothershipFeeds(force: Bool = false) async {
        reconcileTodayThree()
        await mothershipFeeds.refresh(homePC, force: force)
    }

    /// 見せた今日の三つのうち、タスク・家の PC のやることで済みにしたものに「やった」を返す
    func reconcileTodayThree() {
        var doneTasks = Set<String>()
        for item in tasks.items where item.state == .done { doneTasks.insert(item.id) }
        let doneHome = Set(mothership.done.keys)
        mothershipFeeds.reconcileThree(doneTasks: doneTasks, doneHome: doneHome)
    }

    /// 今日の三つの「やった」。当たるタスク（無ければ家の PC のやること）を済みにしてから、母艦に返す
    func finishTodayPick(_ pick: MorningBrief.Pick) async {
        let day = MothershipFeedsBook.dayKey(.now)
        if let id = pick.taskID, let task = tasks.items.first(where: { $0.id == id }), task.state == .open {
            tasks.set(id, .done)
            tasksChanged()
        } else if let id = pick.homeID, let home = mothership.export?.items.first(where: { $0.id == id }) {
            await mothership.markDone(home, pc: homePC)
        }
        mothershipFeeds.answerThree(pick, done: true, day: day)
        await mothershipFeeds.sendOutbox(homePC)
    }

    func skipTodayPick(_ pick: MorningBrief.Pick) async {
        mothershipFeeds.answerThree(pick, done: false, day: MothershipFeedsBook.dayKey(.now))
        await mothershipFeeds.sendOutbox(homePC)
    }
}

// MARK: - 画面: 今日の三つ（「今日」と「タスク」で同じ行）

/// 今日の三つの行と「やった」「やらない」（「今日」のいちばん上と、タスクの「やる」の上。同じ部品）
struct TodayThreeRows: View {
    @Environment(Pipeline.self) private var pipeline
    let picks: [MorningBrief.Pick]

    var body: some View {
        ForEach(Array(picks.enumerated()), id: \.offset) { i, pick in
            TodayThreeRow(number: i + 1, pick: pick)
        }
    }
}

private struct TodayThreeRow: View {
    @Environment(Pipeline.self) private var pipeline
    let number: Int
    let pick: MorningBrief.Pick
    @State private var working = false

    var body: some View {
        let answer: String? = pipeline.mothershipFeeds.threeAnswer(pick)
        VStack(alignment: .leading, spacing: 4) {
            TodayPickRow(number: number, pick: pick)
                .opacity(answer == "skipped" ? 0.5 : 1)
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                if answer == "skipped" {
                    Text("やらない にしました").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    working = true
                    Task {
                        await pipeline.finishTodayPick(pick)
                        working = false
                    }
                } label: {
                    Label("やった", systemImage: "checkmark.circle")
                }
                Button {
                    working = true
                    Task {
                        await pipeline.skipTodayPick(pick)
                        working = false
                    }
                } label: {
                    Label("やらない", systemImage: "xmark.circle")
                }
                .disabled(answer == "skipped")
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .disabled(working)
        }
        // 見せた日を覚え、ほかの所で済みにしたものに「やった」を返す
        .task(id: pick.id) {
            pipeline.mothershipFeeds.notePicks([pick], day: MothershipFeedsBook.dayKey(.now))
            pipeline.reconcileTodayThree()
        }
    }
}

/// 「今日」のいちばん上の1枚: 今日の三つと、まだ答えていない提案1つと、タスクの入口（施策 16）
struct TodayAnswerCard: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var working: String?
    @State private var note: String?

    var body: some View {
        let three: [MorningBrief.Pick] = pipeline.todayThree()
        let open: [Proposal] = pipeline.homeFeeds.openProposals()
        Section {
            if three.isEmpty {
                Text("今日の三つはまだありません。タスクが入ると、ここに出ます。").font(.callout).foregroundStyle(.secondary)
            } else {
                TodayThreeRows(picks: three)
            }
            if let first = open.first {
                ProposalCard(proposal: first, busy: working == first.id) { answer in act(first, answer) }
                    .onAppear { pipeline.homeFeeds.noteShown([first.id]) }
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if !open.isEmpty {
                NavigationLink("提案をすべて見る（\(open.count)）") { ProposalsView() }
            }
            TodayTaskLink()
        } header: {
            Text("今日の三つ")
        } footer: {
            if !open.isEmpty {
                Text("提案は家の PC（母艦）からです。押すまでは何も変えず、何も送りません。")
            }
        }
    }

    private func act(_ p: Proposal, _ answer: ProposalRules.Answer) {
        working = p.id
        Task {
            let text = await pipeline.answerProposal(p, answer)
            working = nil
            withAnimation { note = text }
        }
    }
}

/// タスクの数（押すと「タスク」タブ）
private struct TodayTaskLink: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        Button {
            pipeline.tab = .tasks
        } label: {
            LabeledContent {
                Text(summary())
            } label: {
                Label("タスク", systemImage: "checklist")
            }
        }
    }

    /// 「まだ 5 件・今日まで 1・確かめ待ち 2」
    private func summary() -> String {
        let book = pipeline.tasks
        let open: [TaskBook.Item] = book.open
        let end: Date = Calendar.current.startOfDay(for: .now).addingTimeInterval(86400)
        var late = 0
        for item in open where (item.due ?? .distantFuture) < end { late += 1 }
        var text = "まだ \(open.count) 件"
        if late > 0 { text += "・今日まで \(late)" }
        if !book.candidates.isEmpty { text += "・確かめ待ち \(book.candidates.count)" }
        return text
    }
}

// MARK: - 画面: 次の予定の前に（4）

/// 「今日」の「次の予定の前に」。3時間以内に始まる予定があるときだけ
struct PrepCardSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        if let item = pipeline.mothershipFeeds.nextPrep() {
            Section {
                PrepCard(item: item)
                PrepPeopleLinks(names: item.people)  // 相手の人のページ（2026-11-15。強化案 53。PagesFeeds.swift）
            } header: {
                Text("次の予定の前に")
            }
            .onAppear { Tally.add("prep.shown") }
        }
    }
}

struct PrepCard: View {
    let item: PrepItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(MothershipFeeds.prepTime(item)).font(.subheadline.monospacedDigit().bold())
                Text(item.title).font(.headline)
            }
            if !item.people.isEmpty {
                Text(item.people.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
            }
            if let last = item.last_talk {
                PrepLines(title: "前回（" + AppFeeds.monthDay(last.day) + "）", lines: [last.summary])
            }
            PrepLines(title: "約束", lines: item.promises)
            PrepLines(title: "近ごろ", lines: item.recent)
            FeedbackButtons(kind: "prep", id: item.id)
        }
        .padding(.vertical, 2)
    }
}

private struct PrepLines: View {
    let title: String
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text("・" + line).font(.callout)
                }
            }
        }
    }
}

/// 「役に立った」「いまいち」（週のふり返り・会う前の一枚）。押したものを母艦に返す
struct FeedbackButtons: View {
    @Environment(Pipeline.self) private var pipeline
    let kind: String
    let id: String

    var body: some View {
        let book = pipeline.mothershipFeeds
        let current: String? = book.voted(kind, id: id)
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Button {
                send("useful")
            } label: {
                Label("役に立った", systemImage: current == "useful" ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button {
                send("not_useful")
            } label: {
                Label("いまいち", systemImage: current == "not_useful" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private func send(_ value: String) {
        pipeline.mothershipFeeds.vote(kind, id: id, value: value, day: MothershipFeedsBook.dayKey(.now))
        Task { await pipeline.mothershipFeeds.sendOutbox(pipeline.homePC) }
    }
}

// MARK: - 画面: 夜の10秒（6）

/// 「今日」の「夜の10秒」。20時から翌朝まで、その日にまだ答えていないときだけ
struct NightMoodSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var mood = 0
    @State private var energy = 0
    @State private var grip = 0
    @State private var note = ""
    @State private var done = false

    private var windowDay: String? {
        #if DEBUG && targetEnvironment(simulator)
        if DemoData.isOn { return MothershipFeedsBook.dayKey(.now) }
        #endif
        return NightMood.windowDay(.now)
    }

    var body: some View {
        if let day = windowDay, done || !pipeline.mothershipFeeds.answeredMood(day: day) {
            Section {
                if done {
                    Label("残しました。おつかれさまでした。", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    MoodScaleRow(title: "気分", low: "わるい", high: "よい", value: $mood)
                    MoodScaleRow(title: "疲れ", low: "くたくた", high: "元気", value: $energy)
                    MoodScaleRow(title: "手ごたえ", low: "なし", high: "あった", value: $grip)
                    TextField("ひとこと（なくてよい）", text: $note)
                        .font(.callout)
                    Button("残す") { save(day) }
                        .disabled(mood == 0 || energy == 0 || grip == 0)
                }
            } header: {
                Text("夜の10秒")
            } footer: {
                if !done {
                    Text("1 から 5 で押します。疲れは 1 がいちばん疲れている、5 が元気です。家の PC（母艦）に送ります。")
                }
            }
        }
    }

    private func save(_ day: String) {
        let text: String? = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        guard pipeline.mothershipFeeds.saveMood(day: day, mood: mood, energy: energy, grip: grip, note: text) else { return }
        withAnimation { done = true }
        Task { await pipeline.mothershipFeeds.sendOutbox(pipeline.homePC) }
    }
}

/// 1〜5 を押す1行（両はしに、どちらの向きかを書く）
private struct MoodScaleRow: View {
    let title: String
    let low: String
    let high: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            HStack(spacing: 6) {
                Text("1 " + low).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(1...5, id: \.self) { n in
                    MoodScaleButton(n: n, selected: value == n) { value = n }
                }
                Spacer(minLength: 4)
                Text(high + " 5").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MoodScaleButton: View {
    let n: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(n)")
                .font(.callout.monospacedDigit().bold())
                .frame(width: 32, height: 32)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(n)")
    }
}

/// 設定（ふだん）の「夜の10秒を知らせる」と時刻
struct NightMoodSettingsRows: View {
    @AppStorage(NightMood.reminderOnKey) private var on = false
    @AppStorage(NightMood.reminderTimeKey) private var minutes = 21 * 60 + 30

    var body: some View {
        Toggle("夜の10秒を知らせる", isOn: $on)
            .onChange(of: on) { Task { await NightMood.scheduleReminder() } }
        if on {
            DatePicker("夜の知らせの時刻", selection: time, displayedComponents: .hourAndMinute)
                .onChange(of: minutes) { Task { await NightMood.scheduleReminder() } }
        }
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes * 60))
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (c.hour ?? 21) * 60 + (c.minute ?? 30)
        }
    }
}

// MARK: - 画面: ふり返り（2・3・5）

/// 「ふり返り」の「今週のふり返り」と「見立ての台帳」の入口と、使われ方の数の1行
struct WeeklyLookBackSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = pipeline.mothershipFeeds
        if let weekly = book.weekly {
            Section {
                ForEach(weekly.items) { item in
                    WeeklyItemRow(item: item)
                }
                if weekly.items.isEmpty {
                    Text("今週のふり返りはまだありません。").foregroundStyle(.secondary)
                }
                if !weekly.hypotheses.isEmpty {
                    NavigationLink {
                        HypothesesView()
                    } label: {
                        LabeledContent {
                            Text("\(weekly.hypotheses.count) 件")
                        } label: {
                            Label("見立ての台帳", systemImage: "list.bullet.clipboard")
                        }
                    }
                }
                if let feedback = weekly.feedback {
                    Text(MothershipFeeds.feedbackLine(feedback)).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("今週のふり返り" + headerWeek(weekly))
            } footer: {
                Text("家の PC（母艦）が1週間の記録から選んだ3つです。")
            }
            .onAppear { Tally.add("weekly.shown") }
        }
    }

    private func headerWeek(_ w: WeeklyFeed) -> String {
        let label = MothershipFeeds.weekLabel(week: w.week, from: w.from, to: w.to)
        return label.isEmpty ? "" : "（" + label + "）"
    }
}

private struct WeeklyItemRow: View {
    let item: WeeklyFeed.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MothershipFeeds.weeklyKindLabel(item.kind))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            Text(item.title).font(.headline)
            if !item.body.isEmpty {
                Text(item.body).font(.callout)
            }
            ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, e in
                Text("・「" + e.quote + "」（" + AppFeeds.monthDay(e.day) + "）").font(.caption).foregroundStyle(.secondary)
            }
            FeedbackButtons(kind: "weekly", id: item.id)
        }
        .padding(.vertical, 2)
    }
}

/// 見立ての台帳（本人が口にした見立てと、その後の記録で「まだ生きているか」）
struct HypothesesView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let list: [WeeklyFeed.Hypothesis] = pipeline.mothershipFeeds.weekly?.hypotheses ?? []
        List {
            Section {
                if list.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                }
                ForEach(list) { h in
                    HypothesisRow(hypothesis: h)
                }
            } footer: {
                Text("口にした見立てを、家の PC（母艦）がその後の記録と照らしたものです（月に1回）。見立ては見立てで、決まったことではありません。")
            }
        }
        .navigationTitle("見立ての台帳")
        .countsOpen("hypotheses")
    }
}

private struct HypothesisRow: View {
    let hypothesis: WeeklyFeed.Hypothesis

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(MothershipFeeds.statusLabel(hypothesis.status))
                    .font(.caption2.bold())
                    .foregroundStyle(MothershipFeeds.statusColor(hypothesis.status))
                Spacer(minLength: 8)
                if let said = hypothesis.said_on {
                    Text(AppFeeds.monthDay(said) + " に").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(hypothesis.text)
            if !hypothesis.note.isEmpty {
                Text(hypothesis.note).font(.caption).foregroundStyle(.secondary)
            }
            if let checked = hypothesis.checked_on {
                Text(AppFeeds.monthDay(checked) + " に照らしました").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// 「ふり返り」の「朝のまとめ 比べる」の入口（両方そろった日があるときだけ）
struct BriefCompareLink: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let days: [BriefCompareDay] = pipeline.mothershipFeeds.compare
        if let first = days.first {
            NavigationLink {
                BriefCompareView()
            } label: {
                LabeledContent {
                    Text(AppFeeds.monthDay(first.day) + " ほか")
                } label: {
                    Label("朝のまとめ 比べる", systemImage: "rectangle.split.2x1")
                }
            }
        }
    }
}

/// 同じ日の朝のまとめを、Codex と Claude の2つで並べる（iPhone では上下）。「こっちがいい」を母艦に返す
struct BriefCompareView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var index = 0

    var body: some View {
        let days: [BriefCompareDay] = pipeline.mothershipFeeds.compare
        List {
            if days.isEmpty {
                Text("比べる朝のまとめはまだありません。").foregroundStyle(.secondary)
            } else {
                let shown: BriefCompareDay = days[min(index, days.count - 1)]
                Section {
                    Picker("日", selection: $index) {
                        ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                            Text(AppFeeds.monthDay(d.day)).tag(i)
                        }
                    }
                } footer: {
                    Text("同じ日の朝のまとめを、2つの作り手（Codex と Claude）で作りました。読みやすい方の「こっちがいい」を押してください。家の PC（母艦）に返します。")
                }
                if sizeClass == .regular {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            BriefVersion(day: shown.day, maker: "codex", text: shown.codex)
                            Divider()
                            BriefVersion(day: shown.day, maker: "claude", text: shown.claude)
                        }
                    }
                } else {
                    Section("ひとつ目（Codex）") {
                        BriefVersion(day: shown.day, maker: "codex", text: shown.codex)
                    }
                    Section("ふたつ目（Claude）") {
                        BriefVersion(day: shown.day, maker: "claude", text: shown.claude)
                    }
                }
            }
        }
        .navigationTitle("朝のまとめ 比べる")
        .countsOpen("briefCompare")
    }
}

private struct BriefVersion: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String
    let maker: String
    let text: String

    var body: some View {
        let chosen: String? = pipeline.mothershipFeeds.voted("brief_compare", id: "cmp-" + day)
        VStack(alignment: .leading, spacing: 8) {
            Text(maker == "codex" ? "Codex" : "Claude").font(.caption.bold()).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
            Button {
                pipeline.mothershipFeeds.vote("brief_compare", id: "cmp-" + day, value: maker, day: day)
                Task { await pipeline.mothershipFeeds.sendOutbox(pipeline.homePC) }
            } label: {
                Label(chosen == maker ? "こっちにしました" : "こっちがいい",
                      systemImage: chosen == maker ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 画面: 点検（12・21）

/// 歯車→点検の「精度の通信簿」「あまり開かれていない画面」（写しがあるときだけ）
struct MothershipCheckSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = pipeline.mothershipFeeds
        if !book.accuracy.isEmpty || book.unused != nil {
            Section {
                if !book.accuracy.isEmpty {
                    NavigationLink("精度の通信簿") { AccuracyView() }
                }
                if let unused = book.unused {
                    NavigationLink {
                        UnusedScreensView()
                    } label: {
                        LabeledContent("あまり開かれていない画面", value: "\(unused.items.count)")
                    }
                }
            } header: {
                Text("母艦から")
            } footer: {
                Text("家の PC（母艦）が週ごと・月ごとに数えたものです。施策の前と後を比べる物差しにします。")
            }
        }
    }
}

/// 精度の通信簿（週ごと）。値の無い所は「—」
struct AccuracyView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let weeks: [AccuracyWeek] = pipeline.mothershipFeeds.accuracy
        List {
            Section {
                if weeks.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        AccuracyGrid(weeks: weeks)
                            .padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("自分・ほか: PLAUD と比べて拾えた割合（自分の声・ほかの人の声）。人物N: 1日の人物Nの種類（中央値。少ないほど良い）。直し: 直しの提案を残した割合。審判: 選び直しが PLAUD と合った割合。夜: 夜の読み直しの候補を残した割合。話し方: 話し方の点。")
            }
        }
        .navigationTitle("精度の通信簿")
        .countsOpen("accuracy")
    }
}

private struct AccuracyGrid: View {
    let weeks: [AccuracyWeek]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("週").gridColumnAlignment(.leading)
                Text("自分")
                Text("ほか")
                Text("人物N")
                Text("直し")
                Text("審判")
                Text("夜")
                Text("話し方")
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            ForEach(weeks) { w in
                AccuracyGridRow(week: w)
            }
        }
    }
}

private struct AccuracyGridRow: View {
    let week: AccuracyWeek

    var body: some View {
        GridRow {
            Text(MothershipFeeds.weekLabel(week: week.week, from: week.from, to: nil))
            Text(MothershipFeeds.percent(week.caught_self))
            Text(MothershipFeeds.percent(week.caught_other))
            Text(MothershipFeeds.number(week.person_n_kinds_median))
            Text(MothershipFeeds.percent(week.fix_kept_ratio))
            Text(MothershipFeeds.percent(week.judge_agree))
            Text(MothershipFeeds.percent(week.night_review_kept))
            Text(MothershipFeeds.score(week.speaking_score))
        }
        .font(.caption.monospacedDigit())
    }
}

/// あまり開かれていない画面（母艦が月に1回数える。見せるだけで、何も止めない）
struct UnusedScreensView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let feed: UnusedFeed? = pipeline.mothershipFeeds.unused
        let items: [UnusedScreen] = feed?.items ?? []
        List {
            Section {
                if items.isEmpty {
                    Text("ありません").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(MothershipFeeds.screenName(item.screen), value: "\(item.days)日で \(item.opens) 回")
                        if !item.note.isEmpty {
                            Text(item.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                if let month = feed?.month { Text(month) }
            } footer: {
                Text("畳む候補です。見せるだけで、何も止めません。畳むかどうかは本人が決めます。")
            }
        }
        .navigationTitle("あまり開かれていない画面")
        .countsOpen("unused")
    }
}

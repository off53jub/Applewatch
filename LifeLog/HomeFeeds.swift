import Foundation
import Observation
import SwiftUI
import UserNotifications

/// 母艦が作る、新しい3つの「アプリ向けの写し」を家の PC から読む（2026-11-13）。
/// - 提案（GET /proposals。features の "proposals"）: 母艦がアプリに出す提案。1日に新しいのは3つまで。
///   本人が「受ける」「今はいい」「この種類はいらない」を押したときだけ、タスク・言葉の登録に足し、答えを POST /proposals/answer で返す。
/// - PLAUD で埋めた所（GET /plaud-fill。"plaudfill"）: アプリに行が無い時間の、PLAUD の公式の文字起こし。見せるだけで、記録・会話には入れない。
/// - 話し手の疑い（GET /speaker-doubts。"spkdoubt"）: 話し手が違っていそうな行。疑いの印だけで、名前は自動では変えない。
/// どれも、押すまでは何も変えず、何も送らない。写しは端末に置き（新しいファイル。同期しない）、家の PC につながらないときも前の写しを見せる。
/// 中身の文は記録（ログ）に書かない。

// MARK: - 読んだ形（家の PC が型と長さを確かめてから渡すが、アプリでも確かめ、おかしな行は落とす）

/// 1行が壊れていても、ほかの行は読めるようにする包み（読めない行は nil）
struct LossyRow<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct Proposal: Codable, Identifiable, Equatable {
    struct Evidence: Codable, Equatable {
        var text: String
        /// いつのことか（ISO8601。分からなければ nil）
        var when: String? = nil
        /// conversation・line・calendar・plaud・stats・task・web
        var source: String? = nil
    }

    struct Action: Codable, Equatable {
        /// task（タスクに足す）・vocab（言葉の登録に足す）・place（行ったお店の名前を決める）・none（答えを返すだけ）
        var type: String
        /// タスクの題か、登録する言葉か、お店の名前
        var text: String? = nil
        /// 言葉の読み（あれば）
        var reading: String? = nil
        /// place のときだけ: その会話の日（yyyy-MM-dd）と始まり（ISO8601）
        var day: String? = nil
        var conversation_start: String? = nil
    }

    var id: String
    /// followup・research・selffix・pattern・review・chance・health・prep・vocab（知らない種類も、そのまま読む）
    var kind: String
    var title: String
    var body: String
    var evidence: [Evidence] = []
    var action: Action? = nil
    var created: String? = nil
    var expires: String? = nil
}

struct ProposalFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [Proposal] = []
}

struct PlaudFillDay: Codable, Identifiable, Equatable {
    struct Line: Codable, Equatable {
        var time: String
        var speaker: String? = nil
        var text: String
    }

    /// 時間の切れ目1つ（アプリに行が無い時間）
    struct Span: Codable, Identifiable, Equatable {
        var start: String
        var end: String
        var lines: [Line]
        var id: String { start + "|" + end }
    }

    var day: String
    var ranges: [Span]
    var id: String { day }
}

struct PlaudFillFeed: Codable, Equatable {
    var generated_at: String? = nil
    var days: [PlaudFillDay] = []
}

struct SpeakerDoubt: Codable, Identifiable, Equatable {
    var day: String
    var conversation_start: String
    var line_time: String
    var text_head: String
    /// 今の話し手の名前
    var current: String
    /// self（自分かも）・other（別の人かも）
    var suggest: String
    /// plaud-turn（PLAUD の区切り）・text（文の中身）・night（家の PC の夜の読み直し。2026-11-13）
    var why: String
    var score: Double
    /// 母艦が「本人が見ればほぼ必ず OK する」と印を付けたもの（施策 14。省ける。true のときだけ入る）
    var sure: Bool? = nil
    var sure_why: String? = nil
    var id: String { line_time + "|" + suggest }
}

struct SpeakerDoubtFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [SpeakerDoubt] = []
}

// MARK: - 確かめ方（決まった入力から決まった出力だけ）

enum HomeFeeds {
    static let proposalLimit = 50
    static let evidenceLimit = 5
    static let fillDayLimit = 14
    static let fillSpanLimit = 60
    static let fillLineLimit = 200
    static let doubtLimit = 200
    /// 話し手の疑いの行を記録から探すときの幅（秒）
    static let doubtTolerance: TimeInterval = 2

    // 読む前の形（どの項目も無いことがある。型が違う行は LossyRow が落とす）
    private struct RawFeed<Row: Decodable>: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<Row>]?
        var days: [LossyRow<Row>]?
    }

    private struct RawProposal: Decodable {
        var id: String?
        var kind: String?
        var title: String?
        var body: String?
        var evidence: [LossyRow<Proposal.Evidence>]?
        var action: Proposal.Action?
        var created: String?
        var expires: String?
    }

    private struct RawFillDay: Decodable {
        var day: String?
        var ranges: [LossyRow<RawFillSpan>]?
    }

    private struct RawFillSpan: Decodable {
        var start: String?
        var end: String?
        var lines: [LossyRow<PlaudFillDay.Line>]?
    }

    private struct RawDoubt: Decodable {
        var day: String?
        var conversation_start: String?
        var line_time: String?
        var text_head: String?
        var current: String?
        var suggest: String?
        var why: String?
        var score: Double?
        // 施策 14 の印（型が違っても行は落とさない）
        var sure: LossyRow<Bool>?
        var sure_why: LossyRow<String>?
    }

    /// 前後の空白を除いた文。空なら nil
    static func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// "yyyy-MM-dd" の形か
    static func isDay(_ text: String?) -> Bool {
        guard let text, text.count == 10 else { return false }
        for (i, ch) in text.enumerated() {
            if i == 4 || i == 7 {
                if ch != "-" { return false }
            } else if !ch.isASCII || !ch.isNumber {
                return false
            }
        }
        return true
    }

    /// 提案の id（英数字と _ . : - だけ・64字まで）
    static func isID(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 64 else { return false }
        return text.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) || (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
                || s == "_" || s == "." || s == ":" || s == "-"
        }
    }

    /// 無い（nil）か、ISO8601 として読める時刻か
    private static func optionalTime(_ text: String?) -> Bool {
        guard let text = trimmed(text) else { return true }
        return AppFeeds.parseTime(text) != nil
    }

    // MARK: 提案

    private static func clean(_ raw: RawProposal) -> Proposal? {
        guard let id = trimmed(raw.id), isID(id),
              let kind = trimmed(raw.kind), kind.count <= 20,
              let title = trimmed(raw.title), title.count <= 60 else { return nil }
        let body = trimmed(raw.body) ?? ""
        guard body.count <= 400, optionalTime(raw.created), optionalTime(raw.expires) else { return nil }
        var action: Proposal.Action?
        if let a = raw.action {
            switch a.type {
            case "task", "vocab":
                guard let text = trimmed(a.text), text.count <= 80 else { return nil }
                let reading = trimmed(a.reading)
                guard (reading?.count ?? 0) <= 40 else { return nil }
                action = Proposal.Action(type: a.type, text: text, reading: reading)
            case "place":
                guard let text = trimmed(a.text), text.count <= 80,
                      let day = trimmed(a.day), isDay(day),
                      let start = trimmed(a.conversation_start), AppFeeds.parseTime(start) != nil else { return nil }
                action = Proposal.Action(type: "place", text: text, day: day, conversation_start: start)
            case "none":
                action = Proposal.Action(type: "none")
            default:
                return nil
            }
        }
        // 根拠は、おかしなものだけ落とす（提案は残す）
        var evidence: [Proposal.Evidence] = []
        for row in raw.evidence ?? [] {
            guard let e = row.value, let text = trimmed(e.text), text.count <= 120, optionalTime(e.when),
                  (e.source?.count ?? 0) <= 20 else { continue }
            evidence.append(Proposal.Evidence(text: text, when: trimmed(e.when), source: trimmed(e.source)))
        }
        return Proposal(id: id, kind: kind, title: title, body: body, evidence: Array(evidence.prefix(evidenceLimit)),
                        action: action, created: trimmed(raw.created), expires: trimmed(raw.expires))
    }

    /// GET /proposals の答え。読めない・{"available": false} なら nil（前の写しのままにする）
    static func decodeProposals(_ data: Data) -> ProposalFeed? {
        guard let raw = try? JSONDecoder().decode(RawFeed<RawProposal>.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [Proposal] = []
        for row in raw.items ?? [] {
            guard let p = row.value.flatMap({ clean($0) }), seen.insert(p.id).inserted else { continue }
            items.append(p)
        }
        return ProposalFeed(generated_at: raw.generated_at, items: Array(items.prefix(proposalLimit)))
    }

    // MARK: PLAUD で埋めた所

    private static func clean(_ raw: RawFillDay) -> PlaudFillDay? {
        guard let day = trimmed(raw.day), isDay(day) else { return nil }
        var spans: [PlaudFillDay.Span] = []
        for row in raw.ranges ?? [] {
            guard let s = row.value, let start = trimmed(s.start), let end = trimmed(s.end),
                  let from = AppFeeds.parseTime(start), let to = AppFeeds.parseTime(end), from <= to else { continue }
            var lines: [PlaudFillDay.Line] = []
            for lineRow in s.lines ?? [] {
                guard let l = lineRow.value, let time = trimmed(l.time), AppFeeds.parseTime(time) != nil,
                      let text = trimmed(l.text), text.count <= 400 else { continue }
                let speaker = trimmed(l.speaker)
                guard (speaker?.count ?? 0) <= 20 else { continue }
                lines.append(PlaudFillDay.Line(time: time, speaker: speaker, text: text))
                if lines.count >= fillLineLimit { break }
            }
            guard !lines.isEmpty else { continue }
            spans.append(PlaudFillDay.Span(start: start, end: end, lines: lines))
            if spans.count >= fillSpanLimit { break }
        }
        guard !spans.isEmpty else { return nil }
        spans.sort { (AppFeeds.parseTime($0.start) ?? .distantPast) < (AppFeeds.parseTime($1.start) ?? .distantPast) }
        return PlaudFillDay(day: day, ranges: spans)
    }

    /// GET /plaud-fill の答え。新しい日から14日まで（同じ日は初めのものだけ）
    static func decodePlaudFill(_ data: Data) -> PlaudFillFeed? {
        guard let raw = try? JSONDecoder().decode(RawFeed<RawFillDay>.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var days: [PlaudFillDay] = []
        for row in raw.days ?? [] {
            guard let d = row.value.flatMap({ clean($0) }), seen.insert(d.day).inserted else { continue }
            days.append(d)
        }
        days.sort { $0.day > $1.day }
        return PlaudFillFeed(generated_at: raw.generated_at, days: Array(days.prefix(fillDayLimit)))
    }

    // MARK: 話し手の疑い

    private static func clean(_ raw: RawDoubt) -> SpeakerDoubt? {
        guard let day = trimmed(raw.day), isDay(day),
              let start = trimmed(raw.conversation_start), AppFeeds.parseTime(start) != nil,
              let time = trimmed(raw.line_time), AppFeeds.parseTime(time) != nil,
              let head = trimmed(raw.text_head), head.count <= 40,
              let current = trimmed(raw.current), current.count <= 20,
              let suggest = raw.suggest, suggest == "self" || suggest == "other",
              let why = raw.why, why == "plaud-turn" || why == "text" || why == "night",
              let score = raw.score, score.isFinite, score >= 0, score <= 1 else { return nil }
        let sure: Bool = raw.sure?.value == true
        let sureWhy: String? = sure ? String((trimmed(raw.sure_why?.value) ?? "").prefix(60)) : nil
        return SpeakerDoubt(day: day, conversation_start: start, line_time: time, text_head: head, current: current,
                            suggest: suggest, why: why, score: score, sure: sure ? true : nil, sure_why: sureWhy)
    }

    /// GET /speaker-doubts の答え。200件まで（同じ行・同じ向きは初めのものだけ）
    static func decodeDoubts(_ data: Data) -> SpeakerDoubtFeed? {
        guard let raw = try? JSONDecoder().decode(RawFeed<RawDoubt>.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [SpeakerDoubt] = []
        for row in raw.items ?? [] {
            guard let d = row.value.flatMap({ clean($0) }), seen.insert(d.id).inserted else { continue }
            items.append(d)
            if items.count >= doubtLimit { break }
        }
        return SpeakerDoubtFeed(generated_at: raw.generated_at, items: items)
    }

    /// 「違う」にしたものを除き、点の高い順（同じ点は新しい順）
    static func visibleDoubts(_ items: [SpeakerDoubt], hidden: Set<String>) -> [SpeakerDoubt] {
        items.filter { !hidden.contains($0.id) }.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.line_time > b.line_time
        }
    }

    /// 時刻がいちばん近い行（tolerance 秒以内）。無ければ nil
    static func nearestLine(at time: Date, in times: [Date], tolerance: TimeInterval = doubtTolerance) -> Int? {
        var best: (index: Int, gap: TimeInterval)?
        for (i, t) in times.enumerated() {
            let gap = abs(t.timeIntervalSince(time))
            if gap <= tolerance, best == nil || gap < best!.gap { best = (i, gap) }
        }
        return best?.index
    }

    /// 会話の始まりを探す幅（秒）。提案の place の conversation_start と、記録の会話の始まりを比べる
    static let conversationTolerance: TimeInterval = 60
    /// 重なる立ち寄りが無いとき、会話の始まりからこれだけ離れた立ち寄りまで見る（秒）
    static let visitNear: TimeInterval = 30 * 60

    /// 会話（start〜end）と重なる立ち寄り。重なるものが無ければ、会話の始まりからいちばん近い立ち寄り（30分以内）。
    /// 重なるものがいくつもあれば、重なりのいちばん長いもの。visits は (着いた時刻, 出た時刻。まだいれば nil)
    static func visitIndex(start: Date, end: Date, visits: [(arrival: Date, departure: Date?)],
                           near: TimeInterval = visitNear) -> Int? {
        var overlap: (index: Int, length: TimeInterval)?
        var nearest: (index: Int, gap: TimeInterval)?
        for (i, v) in visits.enumerated() {
            // 出た時刻が分からなければ、着いてから3時間とみなす（PayPay の明細の合わせ方と同じ）
            let vEnd = v.departure ?? v.arrival.addingTimeInterval(3 * 3600)
            let length = min(end, vEnd).timeIntervalSince(max(start, v.arrival))
            if v.arrival <= end && vEnd >= start {
                if overlap == nil || length > overlap!.length { overlap = (i, length) }
                continue
            }
            // 重ならない: 会話の始まりと、立ち寄りのいちばん近い端との間
            let gap = start < v.arrival ? v.arrival.timeIntervalSince(start) : start.timeIntervalSince(vEnd)
            if gap <= near, nearest == nil || gap < nearest!.gap { nearest = (i, gap) }
        }
        return overlap?.index ?? nearest?.index
    }

    // MARK: 見せ方

    static func clock(_ date: Date, seconds: Bool = false, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: date)
    }

    /// 「09:10〜09:40」
    static func spanLabel(_ span: PlaudFillDay.Span, timeZone: TimeZone = .current) -> String {
        guard let from = AppFeeds.parseTime(span.start), let to = AppFeeds.parseTime(span.end) else { return span.start }
        return clock(from, timeZone: timeZone) + "〜" + clock(to, timeZone: timeZone)
    }

    /// 「09:12:05　話し手」（話し手が無ければ時刻だけ）
    static func fillLineHead(_ line: PlaudFillDay.Line, timeZone: TimeZone = .current) -> String {
        let time = AppFeeds.parseTime(line.time).map { clock($0, seconds: true, timeZone: timeZone) } ?? ""
        guard let speaker = line.speaker else { return time }
        return time + "　" + speaker
    }

    static func suggestLabel(_ suggest: String) -> String {
        suggest == "self" ? "自分かも" : "別の人かも"
    }

    static func whyLabel(_ why: String) -> String {
        switch why {
        case "plaud-turn": "PLAUD の区切りから"
        case "night": "夜の読み直しから"
        default: "文の中身から"
        }
    }

    /// 「11/12 09:30」
    static func doubtWhen(_ d: SpeakerDoubt, timeZone: TimeZone = .current) -> String {
        guard let date = AppFeeds.parseTime(d.line_time) else { return AppFeeds.monthDay(d.day) }
        return AppFeeds.shortTime(date, timeZone: timeZone)
    }
}

// MARK: - 提案の答えと、隠す決まり

enum ProposalRules {
    /// 「今はいい」で隠す日数
    static let laterDays = 3
    /// 新しい提案の知らせの名前の頭（1日に1回まで。後ろに日付）
    static let noticePrefix = "proposal-"

    enum Answer: String, Codable {
        case accept, later, never
    }

    /// 送る前の答え（家の PC につながらないときはためておく）
    struct PendingAnswer: Codable, Equatable {
        var id: String
        var answer: Answer
        var at: Date
    }

    /// 答えた提案（「提案」の画面の「これまで」に出す）
    struct Past: Codable, Equatable, Identifiable {
        var proposal: Proposal
        var answer: Answer
        var at: Date
        var id: String { proposal.id }
    }

    /// 端末の中だけに置く、答えと隠す印（proposals-local.json）
    struct Local: Codable, Equatable {
        /// 答えた提案（id → accept・never）。二度と出さない
        var answered: [String: Answer] = [:]
        /// 「今はいい」にした提案と、また出す時刻
        var laterUntil: [String: Date] = [:]
        /// 「この種類はいらない」にした種類（「提案」の画面で戻すまで出さない）
        var offKinds: [String] = []
        /// 「今日」で見せた提案（数えるのは1回だけ）
        var shown: [String] = []
        /// 知らせた提案
        var notified: [String] = []
        /// 最後に知らせた日（yyyy-MM-dd）
        var noticeDay: String? = nil
        var pending: [PendingAnswer] = []
        var history: [Past] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            answered = try c.decodeIfPresent([String: Answer].self, forKey: .answered) ?? [:]
            laterUntil = try c.decodeIfPresent([String: Date].self, forKey: .laterUntil) ?? [:]
            offKinds = try c.decodeIfPresent([String].self, forKey: .offKinds) ?? []
            shown = try c.decodeIfPresent([String].self, forKey: .shown) ?? []
            notified = try c.decodeIfPresent([String].self, forKey: .notified) ?? []
            noticeDay = try c.decodeIfPresent(String.self, forKey: .noticeDay)
            pending = try c.decodeIfPresent([PendingAnswer].self, forKey: .pending) ?? []
            history = try c.decodeIfPresent([Past].self, forKey: .history) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case answered, laterUntil, offKinds, shown, notified, noticeDay, pending, history
        }
    }

    /// まだ答えていない・隠していない・期限の切れていない提案か
    static func isOpen(_ p: Proposal, local: Local, now: Date) -> Bool {
        if local.answered[p.id] != nil { return false }
        if local.offKinds.contains(p.kind) { return false }
        if let until = local.laterUntil[p.id], until > now { return false }
        if let expires = AppFeeds.parseTime(p.expires), expires <= now { return false }
        return true
    }

    /// 見せる提案（新しい順）
    static func openItems(_ items: [Proposal], local: Local, now: Date) -> [Proposal] {
        items.filter { isOpen($0, local: local, now: now) }.sorted { a, b in
            let x = AppFeeds.parseTime(a.created) ?? .distantPast, y = AppFeeds.parseTime(b.created) ?? .distantPast
            return x != y ? x > y : a.id < b.id
        }
    }

    /// 答えを覚える。answered・laterUntil・offKinds・history・pending を書き換えたものを返す
    static func answering(_ local: Local, _ p: Proposal, _ answer: Answer, now: Date) -> Local {
        var next = local
        switch answer {
        case .accept:
            next.answered[p.id] = .accept
            next.laterUntil.removeValue(forKey: p.id)
        case .later:
            next.laterUntil[p.id] = now.addingTimeInterval(TimeInterval(laterDays) * 86400)
        case .never:
            next.answered[p.id] = .never
            next.laterUntil.removeValue(forKey: p.id)
            if !next.offKinds.contains(p.kind) { next.offKinds.append(p.kind) }
        }
        next.history.removeAll { $0.proposal.id == p.id }
        next.history.insert(Past(proposal: p, answer: answer, at: now), at: 0)
        next.history = Array(next.history.prefix(100))
        next.pending.append(PendingAnswer(id: p.id, answer: answer, at: now))
        next.pending = Array(next.pending.suffix(200))
        // 過ぎた「今はいい」は消す
        next.laterUntil = next.laterUntil.filter { $0.value > now }
        return next
    }

    /// 種類を戻す・止める
    static func settingKind(_ local: Local, _ kind: String, on: Bool) -> Local {
        var next = local
        if on {
            next.offKinds.removeAll { $0 == kind }
        } else if !next.offKinds.contains(kind) {
            next.offKinds.append(kind)
        }
        return next
    }

    /// 知らせる提案。今日まだ知らせておらず、まだ知らせても見せてもいない提案があるときだけ（1日に1回まで）
    static func toNotify(_ open: [Proposal], local: Local, today: String) -> [Proposal] {
        guard local.noticeDay != today else { return [] }
        let known = Set(local.notified).union(local.shown)
        return open.filter { !known.contains($0.id) }
    }

    /// 種類の言い方
    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "followup": return "やり残しの続き"
        case "research": return "調べもの"
        case "selffix": return "自分の直し"
        case "pattern": return "くり返し"
        case "review": return "ふり返り"
        case "chance": return "チャンス"
        case "health": return "体調"
        case "prep": return "準備"
        case "vocab": return "言葉の登録"
        case "place": return "行ったお店"
        default: return kind
        }
    }

    static func sourceLabel(_ source: String?) -> String? {
        guard let source else { return nil }
        switch source {
        case "conversation": return "会話"
        case "line": return "LINE"
        case "calendar": return "予定"
        case "plaud": return "PLAUD"
        case "stats": return "数"
        case "task": return "タスク"
        case "web": return "ウェブ"
        default: return source
        }
    }

    /// 根拠の1行「・〇〇（11/12 09:30・会話）」
    static func evidenceLine(_ e: Proposal.Evidence, timeZone: TimeZone = .current) -> String {
        let parts = [AppFeeds.parseTime(e.when).map { AppFeeds.shortTime($0, timeZone: timeZone) }, sourceLabel(e.source)].compactMap { $0 }
        return "・" + e.text + (parts.isEmpty ? "" : "（" + parts.joined(separator: "・") + "）")
    }

    /// 受けたら何をするか（何もしないなら nil）
    static func actionLine(_ p: Proposal) -> String? {
        guard let a = p.action, let text = a.text else { return nil }
        switch a.type {
        case "task": return "受けると、タスク「\(text)」を足します"
        case "vocab": return "受けると、言葉「\(text)」" + (a.reading.map { "（読み: \($0)）" } ?? "") + "を言葉の登録に足します"
        case "place": return "受けると、その時間の行ったお店の名前を「\(text)」に決めます"
        default: return nil
        }
    }

    static func answerLabel(_ a: Answer) -> String {
        switch a {
        case .accept: return "受けた"
        case .later: return "今はいい"
        case .never: return "この種類はいらない"
        }
    }
}

// MARK: - 読み込み

@MainActor
@Observable
final class HomeFeedsBook {
    private(set) var proposals: [Proposal] = []
    private(set) var local = ProposalRules.Local()
    private(set) var plaudFill: [PlaudFillDay] = []
    private(set) var doubts: [SpeakerDoubt] = []
    /// 「違う」・直し済みにした話し手の疑い
    private(set) var hiddenDoubts: Set<String>
    private(set) var fetchedAt: Date?
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var sending = false

    private static let every: TimeInterval = 30 * 60
    static let hiddenDoubtsKey = "speakerDoubtsHidden"
    private static let hiddenLimit = 1000

    static let proposalsFile = "app-feed-proposals.json"
    static let plaudFillFile = "app-feed-plaudfill.json"
    static let doubtsFile = "app-feed-spkdoubt.json"
    static let localFile = "proposals-local.json"

    private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(name)
    }

    init() {
        hiddenDoubts = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenDoubtsKey) ?? [])
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.url(Self.proposalsFile)), let feed = try? decoder.decode(ProposalFeed.self, from: data) {
            proposals = feed.items
        }
        if let data = try? Data(contentsOf: Self.url(Self.plaudFillFile)), let feed = try? decoder.decode(PlaudFillFeed.self, from: data) {
            plaudFill = feed.days
        }
        if let data = try? Data(contentsOf: Self.url(Self.doubtsFile)), let feed = try? decoder.decode(SpeakerDoubtFeed.self, from: data) {
            doubts = feed.items
        }
        if let data = try? Data(contentsOf: Self.url(Self.localFile)), let saved = try? decoder.decode(ProposalRules.Local.self, from: data) {
            local = saved
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func saveLocal() {
        guard let data = try? JSONEncoder().encode(local) else { return }
        try? data.write(to: Self.url(Self.localFile), options: .atomic)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    // MARK: 提案

    func openProposals(now: Date = .now) -> [Proposal] {
        ProposalRules.openItems(proposals, local: local, now: now)
    }

    /// 「今はいい」で、まだ隠しているもの
    func laterProposals(now: Date = .now) -> [Proposal] {
        proposals.filter { p in
            local.answered[p.id] == nil && (local.laterUntil[p.id].map { $0 > now } ?? false)
        }
    }

    /// 「この種類はいらない」で隠しているもの（まだ答えていないもの）
    func kindHiddenProposals() -> [Proposal] {
        proposals.filter { local.answered[$0.id] == nil && local.offKinds.contains($0.kind) }
    }

    /// 切り替えられる種類（届いた提案の種類・止めた種類）
    var kinds: [String] {
        let all = Set(local.offKinds + proposals.map(\.kind) + local.history.map(\.proposal.kind))
        return all.sorted { ProposalRules.kindLabel($0) < ProposalRules.kindLabel($1) }
    }

    func setKind(_ kind: String, on: Bool) {
        local = ProposalRules.settingKind(local, kind, on: on)
        saveLocal()
    }

    /// 「今日」で見せた。初めて見せたものだけ proposal.shown に数える
    func noteShown(_ ids: [String]) {
        let fresh = ids.filter { !local.shown.contains($0) }
        guard !fresh.isEmpty else { return }
        local.shown = Array((local.shown + fresh).suffix(500))
        saveLocal()
        Tally.add("proposal.shown", fresh.count)
    }

    /// 答えを覚えて（すぐ隠れる）、家の PC に送る（送れなければ、ためて次に送る）
    func answer(_ p: Proposal, _ answer: ProposalRules.Answer, pc: HomePC) async {
        local = ProposalRules.answering(local, p, answer, now: .now)
        saveLocal()
        await sendPending(pc)
    }

    /// ためた答えを古い順に送る。1つでも送れなければ、そこでやめる
    func sendPending(_ pc: HomePC) async {
        guard !sending, pc.features.contains("proposals"), !local.pending.isEmpty else { return }
        sending = true
        defer { sending = false }
        struct Body: Encodable {
            let id: String
            let answer: String
        }
        while let first = local.pending.first {
            guard let body = try? JSONEncoder().encode(Body(id: first.id, answer: first.answer.rawValue)) else {
                local.pending.removeFirst()
                continue
            }
            do {
                _ = try await pc.postJSONData("proposals/answer", body: body, timeout: 10)
            } catch {
                break
            }
            if local.pending.first == first { local.pending.removeFirst() }
            saveLocal()
        }
    }

    // MARK: PLAUD・話し手の疑い

    func fill(for day: String) -> PlaudFillDay? {
        plaudFill.first { $0.day == day }
    }

    /// PLAUD の写しだけがある日（アプリの記録の日に無いもの。新しい順）
    func fillOnlyDays(recorded: [String]) -> [String] {
        let have = Set(recorded)
        return plaudFill.map(\.day).filter { !have.contains($0) }.sorted(by: >)
    }

    var visibleDoubts: [SpeakerDoubt] { HomeFeeds.visibleDoubts(doubts, hidden: hiddenDoubts) }

    /// 「違う」・直し済み。もう出さない
    func hideDoubt(_ id: String) {
        hiddenDoubts.insert(id)
        if hiddenDoubts.count > Self.hiddenLimit {
            // いま疑いにあるものを優先して残す
            let live = Set(doubts.map(\.id))
            hiddenDoubts = hiddenDoubts.filter { live.contains($0) }
        }
        UserDefaults.standard.set(Array(hiddenDoubts), forKey: Self.hiddenDoubtsKey)
    }

    // MARK: 家の PC から読む

    /// 読み直す（force でなければ30分に1回まで）。読めなかった写しは前のまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching else { return }
        guard pc.features.contains("proposals") || pc.features.contains("plaudfill") || pc.features.contains("spkdoubt") else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every {
            await sendPending(pc)
            return
        }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        if pc.features.contains("proposals"), let body = try? await pc.appFeed("proposals", feature: "proposals"),
           let feed = HomeFeeds.decodeProposals(body) {
            proposals = feed.items
            Self.write(feed, Self.proposalsFile)
            await notifyNew()
        }
        if pc.features.contains("plaudfill"), let body = try? await pc.appFeed("plaud-fill", feature: "plaudfill"),
           let feed = HomeFeeds.decodePlaudFill(body) {
            plaudFill = feed.days
            Self.write(feed, Self.plaudFillFile)
        }
        if pc.features.contains("spkdoubt"), let body = try? await pc.appFeed("speaker-doubts", feature: "spkdoubt"),
           let feed = HomeFeeds.decodeDoubts(body) {
            doubts = feed.items
            Self.write(feed, Self.doubtsFile)
        }
        await sendPending(pc)
    }

    /// 新しい提案が届いたら、1日に1回まで知らせる（押すと「提案」の画面）
    private func notifyNew() async {
        let today = Self.dayKey(.now)
        let fresh = ProposalRules.toNotify(openProposals(), local: local, today: today)
        guard let first = fresh.first else { return }
        local.notified = Array((local.notified + fresh.map(\.id)).suffix(500))
        local.noticeDay = today
        saveLocal()
        let content = UNMutableNotificationContent()
        content.title = "家の PC からの提案"
        content.body = first.title + (fresh.count > 1 ? " ほか \(fresh.count - 1) 件" : "")
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: ProposalRules.noticePrefix + today, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }
}

// MARK: - 押したときの動き

extension Pipeline {
    /// 提案に答える。「受ける」はタスク・言葉の登録に足してから。返すのは画面に出す一文
    func answerProposal(_ p: Proposal, _ answer: ProposalRules.Answer) async -> String {
        var note: String
        switch answer {
        case .accept:
            note = "受けました。"
            if let action = p.action, let text = action.text {
                if action.type == "task" {
                    // 手で書いたタスクと同じ足し方（TaskBook.add。同じらしいものがあれば足さない）
                    var item = TaskBook.Item(what: text, said: .now, source: .manual, state: .open, work: taskTime(.now))
                    item.quote = "家の PC の提案「\(p.title)」"
                    if tasks.add([item]).isEmpty {
                        note = "同じらしいタスクがもうあるので、足しませんでした。"
                    } else {
                        tasksChanged()
                        note = "タスクに「\(text)」を足しました。"
                    }
                } else if action.type == "vocab" {
                    // 言葉の登録と同じ足し方（Vocabulary.add。「いつも」の組）。読みは登録の形に無いので残さない
                    if Vocabulary.Group.allCases.contains(where: { vocabulary.words(in: $0).contains(text) }) {
                        note = "「\(text)」はもう登録してあります。"
                    } else {
                        vocabulary.add(text, to: .always)
                        note = "言葉の登録（いつも）に「\(text)」を足しました。"
                    }
                } else if action.type == "place" {
                    note = acceptPlace(text, action: action)
                }
            }
            Tally.add("proposal.accept")
        case .later:
            note = "\(ProposalRules.laterDays)日たったら、もう一度出します。"
            Tally.add("proposal.later")
        case .never:
            note = "「\(ProposalRules.kindLabel(p.kind))」の提案は、もう出しません（「提案」の画面で戻せます）。"
            Tally.add("proposal.never")
        }
        await homeFeeds.answer(p, answer, pc: homePC)
        return note
    }

    /// 行ったお店の提案を受ける。会話（その日の、始まりが前後60秒の会話）と重なる立ち寄り
    /// （無ければ会話の始まりから30分以内でいちばん近い立ち寄り）の名前を、本人が「名前を入れる」で入れたのと同じ
    /// ShopVisitBook.setName で決める。会話の記録そのものは変えない。立ち寄りが無ければ何もしない
    func acceptPlace(_ name: String, action: Proposal.Action) -> String {
        guard let day = action.day, let start = AppFeeds.parseTime(action.conversation_start) else {
            return "重なる立ち寄りが見つかりませんでした。"
        }
        // 日をまたぐ会話は前の日に入っているので、前の日も探す
        let talks = [Self.previousDay(of: day), day].compactMap { $0 }.flatMap { conversations(on: $0) }
        let talk = talks.filter { abs($0.start.timeIntervalSince(start)) <= HomeFeeds.conversationTolerance }
            .min { abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start)) }
        let end = talk.map { max($0.end, start) } ?? start
        let visits = shopVisits.visits
        guard let i = HomeFeeds.visitIndex(start: talk?.start ?? start, end: end,
                                           visits: visits.map { (arrival: $0.arrival, departure: $0.departure) }) else {
            return "重なる立ち寄りが見つかりませんでした。"
        }
        shopVisits.setName(visits[i].id, name)
        return "その時間の行ったお店を「\(name)」に決めました（「記録」→「場所」→「行ったお店」で直せます）。"
    }

    /// 話し手の疑いの行と、その会話（同じ日と前の日から、時刻が前後2秒以内でいちばん近い行）
    struct DoubtSpot {
        let day: String
        let conversation: ConversationLog.Conversation
        let line: ConversationLog.Line
        let next: ConversationLog.Line?
    }

    func findDoubtLine(_ d: SpeakerDoubt) -> DoubtSpot? {
        guard let at = AppFeeds.parseTime(d.line_time) else { return nil }
        var found: [(day: String, conversation: ConversationLog.Conversation, index: Int)] = []
        // 日をまたぐ会話は前の日に入っているので、前の日も探す
        for day in [Self.previousDay(of: d.day), d.day].compactMap({ $0 }) {
            for c in conversations(on: day) {
                for i in c.lines.indices { found.append((day: day, conversation: c, index: i)) }
            }
        }
        let times: [Date] = found.map { $0.conversation.lines[$0.index].time }
        guard let best = HomeFeeds.nearestLine(at: at, in: times) else { return nil }
        let hit = found[best]
        let line = hit.conversation.lines[hit.index]
        let next = hit.conversation.lines[(hit.index + 1)...].first { $0.audio == line.audio }
        return DoubtSpot(day: hit.day, conversation: hit.conversation, line: line, next: next)
    }

    /// 話し手の疑い（「違う」にしたものを除く）
    var speakerDoubtCount: Int { homeFeeds.visibleDoubts.count }
}

// MARK: - 画面: 提案

/// 提案の1枚（題・中身・根拠・受けたら何をするか・3つのボタン）
struct ProposalCard: View {
    let proposal: Proposal
    /// 答えたもの（「これまで」）なら、その答えと時刻
    var past: ProposalRules.Past? = nil
    var busy = false
    var onAnswer: ((ProposalRules.Answer) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(ProposalRules.kindLabel(proposal.kind))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                Spacer(minLength: 8)
                if let past {
                    Text(ProposalRules.answerLabel(past.answer) + "・" + AppFeeds.shortTime(past.at))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let created = AppFeeds.parseTime(proposal.created) {
                    Text(AppFeeds.shortTime(created)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(proposal.title).font(.headline)
            if !proposal.body.isEmpty {
                Text(proposal.body).font(.callout)
            }
            ForEach(Array(proposal.evidence.enumerated()), id: \.offset) { _, e in
                Text(ProposalRules.evidenceLine(e)).font(.caption).foregroundStyle(.secondary)
            }
            if past == nil, let action = ProposalRules.actionLine(proposal) {
                Text(action).font(.caption).foregroundStyle(.secondary)
            }
            if let onAnswer {
                HStack(spacing: 8) {
                    Button("受ける") { onAnswer(.accept) }
                        .buttonStyle(.borderedProminent)
                    Button("今はいい") { onAnswer(.later) }
                        .buttonStyle(.bordered)
                    Button("この種類はいらない") { onAnswer(.never) }
                        .buttonStyle(.bordered)
                    if busy { ProgressView() }
                }
                .font(.caption)
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 「今日」の提案（まだ答えていないものを3つまで）。無ければ何も出さない
struct ProposalCardsSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var working: String?
    @State private var note: String?

    var body: some View {
        let book = pipeline.homeFeeds
        let open = book.openProposals()
        if !open.isEmpty || note != nil {
            Section {
                ForEach(Array(open.prefix(3))) { p in
                    ProposalCard(proposal: p, busy: working == p.id) { answer in act(p, answer) }
                        .onAppear { book.noteShown([p.id]) }
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                NavigationLink("提案をすべて見る") { ProposalsView() }
            } header: {
                Text(open.isEmpty ? "提案" : "提案（\(open.count)）")
            } footer: {
                Text("家の PC（母艦）からの提案です。押すまでは何も変えず、何も送りません。")
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

/// 「提案」の画面。まだのもの・今はいいにしたもの・これまで・種類の切り替え
struct ProposalsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var working: String?
    @State private var note: String?

    var body: some View {
        let book = pipeline.homeFeeds
        let open = book.openProposals()
        let later = book.laterProposals()
        let offKind = book.kindHiddenProposals()
        List {
            Section {
                if open.isEmpty {
                    Text("いまは提案はありません").foregroundStyle(.secondary)
                }
                ForEach(open) { p in
                    ProposalCard(proposal: p, busy: working == p.id) { answer in act(p, answer) }
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("まだ答えていない（\(open.count)）")
            } footer: {
                Text("家の PC（母艦）が、記録・LINE・予定などから作った提案です。1日に新しいのは3つまで。押すまでは何も変えず、何も送りません。「受ける」はタスクか言葉の登録に足し、どの答えも家の PC に返します（つながらないときは、ためて次に送ります）。「今はいい」は\(ProposalRules.laterDays)日隠し、「この種類はいらない」は下の「種類」で戻すまで、その種類を出しません。")
            }
            if !later.isEmpty {
                Section("今はいい にしたもの（\(later.count)）") {
                    ForEach(later) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title)
                            if let until = book.local.laterUntil[p.id] {
                                Text(AppFeeds.shortTime(until) + " にまた出します").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !offKind.isEmpty {
                Section("止めた種類の提案（\(offKind.count)）") {
                    ForEach(offKind) { p in
                        LabeledContent(p.title, value: ProposalRules.kindLabel(p.kind))
                    }
                }
            }
            if !book.local.history.isEmpty {
                Section("これまで（\(book.local.history.count)）") {
                    ForEach(book.local.history) { past in
                        ProposalCard(proposal: past.proposal, past: past)
                    }
                }
            }
            if !book.kinds.isEmpty {
                Section {
                    ForEach(book.kinds, id: \.self) { kind in
                        Toggle(ProposalRules.kindLabel(kind), isOn: Binding(
                            get: { !book.local.offKinds.contains(kind) },
                            set: { book.setKind(kind, on: $0) }))
                    }
                } header: {
                    Text("種類")
                } footer: {
                    Text("オフにした種類の提案は出しません（「この種類はいらない」を押すとオフになります）。オンに戻すと、また出します。この切り替えは端末の中だけで、家の PC には送りません。")
                }
            }
        }
        .navigationTitle("提案")
        .countsOpen("proposals")
        .refreshable { await book.refresh(pipeline.homePC, force: true) }
        .task { await book.refresh(pipeline.homePC) }
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

// MARK: - 画面: PLAUD で埋めた所

/// 「記録」→「日ごと」の1日に出す、畳んだ「PLAUD で埋めた所」。その日の写しがあるときだけ
struct PlaudFillSection: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String
    @State private var open = false

    var body: some View {
        if let fill = pipeline.homeFeeds.fill(for: day) {
            Section {
                DisclosureGroup(isExpanded: $open) {
                    ForEach(fill.ranges) { span in
                        PlaudFillSpanRow(span: span, limit: 3)
                    }
                } label: {
                    Label("PLAUD で埋めた所（\(fill.ranges.count) か所）", systemImage: "text.quote")
                }
                .onChange(of: open) {
                    if open { Tally.add("plaudfill.viewed") }
                }
            } footer: {
                Text("アプリの記録が無い時間を、PLAUD の文字起こしで見せています（家の PC から。読むだけ）。アプリの記録・会話には入れていません。")
            }
        }
    }
}

/// 時間の切れ目1つ（limit 行まで。続きは押して読む）
struct PlaudFillSpanRow: View {
    let span: PlaudFillDay.Span
    var limit: Int? = nil

    var body: some View {
        let shown: [PlaudFillDay.Line] = limit.map { Array(span.lines.prefix($0)) } ?? span.lines
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(HomeFeeds.spanLabel(span)).font(.subheadline.monospacedDigit().bold())
                Text("PLAUD の文字").font(.caption2)
                    .padding(.horizontal, 4)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(HomeFeeds.fillLineHead(line)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(line.text).font(.callout)
                }
            }
            if let limit, span.lines.count > limit {
                NavigationLink("全部読む（\(span.lines.count) 行）") { PlaudFillSpanView(span: span) }
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 時間の切れ目1つを全部読む
struct PlaudFillSpanView: View {
    let span: PlaudFillDay.Span

    var body: some View {
        List {
            Section {
                ForEach(Array(span.lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HomeFeeds.fillLineHead(line)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(line.text).textSelection(.enabled)
                    }
                }
            } footer: {
                Text("PLAUD の文字起こしです（読むだけ）。アプリの記録・会話には入れていません。")
            }
        }
        .navigationTitle("PLAUD " + HomeFeeds.spanLabel(span))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// PLAUD の写しだけがあって、アプリの記録が無い日を開く（「記録」→「日ごと」の下）
struct PlaudOnlyDayView: View {
    let day: String

    var body: some View {
        List {
            PlaudFillSection(day: day)
        }
        .navigationTitle(day)
    }
}

// MARK: - 画面: 話し手の疑い

/// 疑いの1行（日時・文の頭・今の話し手と、疑い・どこから）
struct SpeakerDoubtRow: View {
    let doubt: SpeakerDoubt

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(HomeFeeds.doubtWhen(doubt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(HomeFeeds.whyLabel(doubt.why)).font(.caption2).foregroundStyle(.secondary)
            }
            Text("「\(doubt.text_head)」").lineLimit(2)
            Text("今は「\(doubt.current)」→ \(HomeFeeds.suggestLabel(doubt.suggest))")
                .font(.caption)
                .foregroundStyle(doubt.suggest == "self" ? Color.accentColor : Color.orange)
            if doubt.sure == true {
                Text(NightReviewRules.sureLabel(doubt.sure_why))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// 「直す」の「話し手の疑い」の全部
struct SpeakerDoubtsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let list = pipeline.homeFeeds.visibleDoubts
        List {
            Section {
                if list.isEmpty {
                    Text("確かめるものはありません").foregroundStyle(.secondary)
                }
                SpeakerDoubtBulkRow()
                ForEach(list) { d in
                    NavigationLink { SpeakerDoubtView(doubt: d) } label: { SpeakerDoubtRow(doubt: d) }
                }
            } footer: {
                Text("家の PC（母艦）が PLAUD の区切りや文の中身から見つけた「話し手が違っていそう」な行です。疑いの印だけで、名前は自動では変えません。押して行を確かめ、「自分の声にする」か「違う」を選んでください。")
            }
        }
        .navigationTitle("話し手の疑い")
        .countsOpen("speakerDoubts")
        .refreshable { await pipeline.homeFeeds.refresh(pipeline.homePC, force: true) }
        .task { await pipeline.homeFeeds.refresh(pipeline.homePC) }
    }
}

/// 疑いの1つ。記録の行を探して見せ、本人が押したときだけ直す
struct SpeakerDoubtView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let doubt: SpeakerDoubt
    @State private var spot: Pipeline.DoubtSpot?
    @State private var looked = false
    @State private var working = false
    @State private var result: String?
    /// 直したら、この画面を閉じるときに一覧から外す（開いているあいだに外すと、画面が閉じてしまうため）
    @State private var resolved = false
    @State private var fixing = false
    @State private var player = ClipPlayer()

    var body: some View {
        List {
            Section {
                SpeakerDoubtRow(doubt: doubt)
            }
            Section {
                if let spot {
                    lineRows(spot)
                } else if looked {
                    Text("この時刻（前後\(Int(HomeFeeds.doubtTolerance))秒）の行が、この端末の記録に見つかりませんでした。")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } header: {
                Text("記録の行")
            }
            Section {
                if let result {
                    Text(result)
                } else {
                    if doubt.suggest == "self", let spot, let id = spot.line.speakerID, id != SpeakerLabeler.selfID {
                        Button("自分の声にする") { claim(spot, from: id) }
                            .disabled(working)
                    }
                    if spot != nil {
                        Button("話し手を選んで直す") { fixing = true }
                            .disabled(working)
                    }
                    Button("違う") {
                        player.stop()
                        Tally.add("spkdoubt.dismiss")
                        NightReviewRules.noteDoubt(doubt, kept: false)
                        pipeline.homeFeeds.hideDoubt(doubt.id)
                        dismiss()
                    }
                    .disabled(working)
                    if working { ProgressView() }
                }
            } footer: {
                Text("押すまでは何も変えません。名前の付いた人を自動で変えることはありません。「自分の声にする」は、この行だけを「自分」に直します（声は覚え足しません）。「話し手を選んで直す」は、記録の行の「話者を直す」と同じです。「違う」を押すと、この疑いはもう出しません。")
            }
        }
        .navigationTitle("話し手の疑い")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            spot = pipeline.findDoubtLine(doubt)
            looked = true
        }
        .onDisappear {
            player.stop()
            if resolved {
                NightReviewRules.noteDoubt(doubt, kept: true)
                pipeline.homeFeeds.hideDoubt(doubt.id)
            }
        }
        .sheet(isPresented: $fixing) {
            if let spot {
                SpeakerFixView(line: spot.line, next: spot.next, context: pipeline.places.context(at: spot.line.time)) {
                    resolved = true
                    self.spot = pipeline.findDoubtLine(doubt)
                }
            }
        }
    }

    @ViewBuilder
    private func lineRows(_ spot: Pipeline.DoubtSpot) -> some View {
        let key = "doubt-" + doubt.id
        VStack(alignment: .leading, spacing: 4) {
            Text(HomeFeeds.clock(spot.line.time, seconds: true) + "　" + (spot.line.speaker ?? "話し手なし"))
                .font(.caption.bold())
            Text(spot.line.text)
        }
        if let audio = spot.line.audio, pipeline.archive.canPlay(audio) {
            Button {
                Task {
                    await player.toggle(key, at: spot.line.offset ?? 0, until: spot.next?.offset) {
                        await pipeline.archive.playableURL(for: audio)
                    }
                }
            } label: {
                if player.loading == key {
                    ProgressView()
                } else {
                    Label(player.playing == key ? "止める" : "聞く",
                          systemImage: player.playing == key ? "stop.circle.fill" : "play.circle")
                }
            }
        }
        NavigationLink("この会話を開く") {
            ConversationsView(day: spot.day, range: spot.conversation.start...spot.conversation.start)
                .navigationTitle(ConversationLog.headingText(spot.conversation))
        }
    }

    /// この行だけを「自分」にする（人の画面の「自分の行にする」と同じ claimAsSelf。声は覚え足さない）
    private func claim(_ spot: Pipeline.DoubtSpot, from id: String) {
        player.stop()
        working = true
        Task {
            let clip = Pipeline.SplitClip(line: spot.line, end: spot.next?.offset ?? (spot.line.offset ?? 0) + 10, embedding: [])
            let message = await pipeline.claimAsSelf(id, clips: [clip])
            Tally.add("spkdoubt.self")
            working = false
            resolved = true
            result = message
            self.spot = pipeline.findDoubtLine(doubt)
        }
    }
}

/// 「直す」の「話し手の疑い」（上から5つと、全部の入口）
struct SpeakerDoubtsSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let list = pipeline.homeFeeds.visibleDoubts
        if !list.isEmpty {
            Section {
                SpeakerDoubtBulkRow()
                ForEach(Array(list.prefix(5))) { d in
                    NavigationLink { SpeakerDoubtView(doubt: d) } label: { SpeakerDoubtRow(doubt: d) }
                }
                NavigationLink("話し手の疑いをすべて見る（\(list.count)）") { SpeakerDoubtsView() }
            } header: {
                Text("話し手の疑い（\(list.count)）")
            } footer: {
                Text("疑いの印だけです。名前は自動では変えません。")
            }
        }
    }
}

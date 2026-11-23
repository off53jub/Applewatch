import BackgroundTasks
import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications

/// 自分を知ってもらう（2026-11-19。s18。番号は母艦に出した 84 案の番号）。形の決まりは docs/s18-know-me.md。
/// 読む（家の PC の GET。features の "knowme"。写しが無ければ空の表示のまま）:
/// - 見立て（GET /know/hypotheses。1）: 週 3 つを ○×。答えは POST /feedback の kind "hypothesis"
/// - 1 日 1 問（GET /know/questions。2・4・8・10・12・13・30・41・46・61）: その日はじめて読んだときに上から 3 問を決め、その日は入れ替えない。
///   答えたものは二度と出ない（家の PC も、答えた id を外して返す。65）
/// - 抜き打ち検査（GET /know/spot-checks。81）: 答えは POST /feedback の kind "spot"
/// - 自信の段（GET /know/tiers。61・66）
/// 送る（MothershipOutbox。つながらないときは端末にためて、次に送る）: know/answer・know/recheck・know/note（7）・know/person-goal（9）・
/// know/why-wrong（42）・know/mark（4・11・30）・know/voice-fix（63）・mood/tap（6）
/// 中身の文は記録（ログ）に書かない。

// MARK: - 形

struct KnowEvidence: Codable, Equatable {
    var text: String
    var source: String?
    var day: String?
    var conversation_start: String?
    var line_time: String?
    var ref: String?
}

struct KnowHypothesis: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var label: String
    var text: String
    var why: String
    var evidence: [KnowEvidence]
    var made_on: String?
    var recheck_by: String?
    var confidence: Double?
    var tier: String?
    var tier_why: String?
}

struct KnowQuestion: Codable, Equatable, Identifiable {
    var id: String
    /// general・notdo・dislike・respect・adult・ask_friend・family・draft・recheck・hypothesis
    var group: String
    /// text（文で答える）・record（録って印を付ける）・yesno（はい・いいえ）・recheck（いまもそうか）
    var answer: String
    var text: String
    var evidence: [KnowEvidence]
    var draft: String?
    var current: String?
    var checked_on: String?
    var tier: String?
}

struct KnowSpot: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var claim: String
    var day: String?
    var evidence: [KnowEvidence]
    var note: String
}

/// 端末だけに置くもの（同期しない）
struct KnowLocal: Codable, Equatable {
    /// 今日の問いを決めた日と、その問い（1 日 1 回。65）
    var questionDay: String?
    var todayQuestions: [KnowQuestion] = []
    /// 答えた問い（id → answered・skip・ok・fixed・still など）
    var answered: [String: String] = [:]
    /// 今週の見立て（週の頭で 3 つ決める）
    var hypothesisWeek: String?
    var weekHypotheses: [KnowHypothesis] = []
    /// 朝と夜の 1 タップ（"日|slot" → 1〜5）
    var moodTaps: [String: Int] = [:]
    /// 会話への一言（"日|始まり" → 文）
    var notes: [String: String] = [:]
    /// 人ごとのなりたい形（人の番号か名前 → 文）
    var goals: [String: String] = [:]
    /// 録っている途中の印（kind・始まり・問いの id）
    var markKind: String?
    var markStart: Date?
    var markQuestion: String?
    /// 通知で聞いた日（1 日 1 通まで）
    var noticeDay: String?
}

// MARK: - 決まり（決まった入力から決まった出力だけ）

enum KnowMeRules {
    static let feature = "knowme"
    static let perDay = 3
    static let hypothesesPerWeek = 3
    static let category = "knowYesNo"
    static let geoCategory = "knowGeo"
    static let noticePrefix = "know-"
    static let yesNoID = "know-yesno"
    static let weeklyTalkID = "know-weekly-talk"
    static let geoWorkID = "know-geo-work"
    static let yesAction = "know.yes"
    static let noAction = "know.no"
    static let unsureAction = "know.unsure"
    static let recordAction = "know.rec"
    /// with_people は「この時間に一緒にいた人（仮）」の確かめ（2026-11-21。s19 の 休16。母艦の M2 が questions_for_app.json に足す）
    static let groups: [String] = ["general", "notdo", "dislike", "respect", "adult", "ask_friend", "family", "draft",
                                   "recheck", "hypothesis", "with_people"]
    static let answers: [String] = ["text", "record", "yesno", "recheck"]
    static let tiers: [String] = ["auto", "tentative", "ask"]
    /// 送り口（MothershipOutbox の道）。どれも家の PC の features の "knowme"
    static let paths: [String] = ["know/answer", "know/recheck", "know/note", "know/person-goal", "know/why-wrong", "know/mark",
                                  "know/voice-fix", "mood/tap"]
    static let whyReasons: [(id: String, label: String)] = [("fact", "事実が違う"), ("person", "人が違う"), ("old", "古い"),
                                                            ("offtopic", "的外れ"), ("tone", "言い方"), ("other", "そのほか")]
    static let markKinds: [String] = ["ask_friend", "weekly_talk", "family_childhood", "other"]

    // しきい値（すべて仮。docs/s18-know-me.md）
    /// 朝の 1 タップを出す時間（5 時〜11 時。仮）
    static let morningFrom = 5
    static let morningTo = 11
    /// 通知で聞く時刻（20:30。仮）
    static let noticeHour = 20
    static let noticeMinute = 30
    /// 週の振り返りの促し（日曜 20:00。仮）
    static let weeklyTalkWeekday = 1
    static let weeklyTalkHour = 20
    /// 同じ場所に「着いた」を数え直すまでの間（6 時間。仮）
    static let arriveGap: TimeInterval = 6 * 3600
    /// 場所の見張りの半径の下限（150 m。仮。登録した場所の半径が小さすぎると出入りを取りこぼす）
    static let minRadius: Double = 150
    /// 仮の印（tentative）のものも聞くか（仮。いまの自分の声・話し手の確かめを急に減らさないため、初めは聞く）
    static let askTentative = true

    static func shouldAsk(tier: String?) -> Bool {
        switch tier {
        case "auto": false
        case "tentative": askTentative
        default: true
        }
    }

    /// 時計の「違う、〇〇さん」に添える、直前の会話の行を探す幅（10 分。仮）
    static let fixLookBack: TimeInterval = 10 * 60

    // MARK: 読む

    private struct RawFeed<T: Decodable>: Decodable {
        var available: Bool?
        var items: [LossyRow<T>]?
        var week: String?
    }

    private struct RawEvidence: Decodable {
        var text: String?
        var source: String?
        var day: String?
        var conversation_start: String?
        var line_time: String?
        var ref: String?
    }

    private struct RawHypothesis: Decodable {
        var id: String?
        var kind: String?
        var label: String?
        var text: String?
        var why: String?
        var evidence: [LossyRow<RawEvidence>]?
        var made_on: String?
        var recheck_by: String?
        var confidence: Double?
        var tier: String?
        var tier_why: String?
    }

    private struct RawQuestion: Decodable {
        var id: String?
        var group: String?
        var answer: String?
        var text: String?
        var evidence: [LossyRow<RawEvidence>]?
        var draft: String?
        var current: String?
        var checked_on: String?
        var tier: String?
    }

    private struct RawSpot: Decodable {
        var id: String?
        var kind: String?
        var claim: String?
        var day: String?
        var evidence: [LossyRow<RawEvidence>]?
        var note: String?
    }

    private static func evidence(_ rows: [LossyRow<RawEvidence>]?) -> [KnowEvidence] {
        var out: [KnowEvidence] = []
        for row in rows ?? [] {
            guard let e = row.value, let text = MothershipFeeds.cut(e.text, 120) else { continue }
            let day: String? = HomeFeeds.isDay(e.day) ? e.day : nil
            out.append(KnowEvidence(text: text, source: MothershipFeeds.cut(e.source, 20), day: day,
                                    conversation_start: date(e.conversation_start) == nil ? nil : e.conversation_start,
                                    line_time: date(e.line_time) == nil ? nil : e.line_time, ref: MothershipFeeds.cut(e.ref, 160)))
            if out.count >= 5 { break }
        }
        return out
    }

    static func decodeHypotheses(_ data: Data) -> [KnowHypothesis]? {
        guard let raw = try? JSONDecoder().decode(RawFeed<RawHypothesis>.self, from: data), raw.available == true else { return nil }
        var out: [KnowHypothesis] = []
        var seen = Set<String>()
        for row in raw.items ?? [] {
            guard let x = row.value, let id = x.id, HomeFeeds.isID(id), !seen.contains(id),
                  let text = MothershipFeeds.cut(x.text, 200) else { continue }
            let ev: [KnowEvidence] = evidence(x.evidence)
            guard !ev.isEmpty else { continue }  // 根拠の無い見立ては見せない
            seen.insert(id)
            let tier: String? = x.tier.flatMap { tiers.contains($0) ? $0 : nil }
            let conf: Double? = x.confidence.flatMap { $0 >= 0 && $0 <= 1 ? $0 : nil }
            out.append(KnowHypothesis(id: id, kind: MothershipFeeds.cut(x.kind, 40) ?? "", label: "見立て（仮）", text: text,
                                      why: MothershipFeeds.cut(x.why, 200) ?? "", evidence: ev,
                                      made_on: HomeFeeds.isDay(x.made_on) ? x.made_on : nil,
                                      recheck_by: HomeFeeds.isDay(x.recheck_by) ? x.recheck_by : nil,
                                      confidence: conf, tier: tier, tier_why: MothershipFeeds.cut(x.tier_why, 40)))
        }
        return out
    }

    static func decodeQuestions(_ data: Data) -> [KnowQuestion]? {
        guard let raw = try? JSONDecoder().decode(RawFeed<RawQuestion>.self, from: data), raw.available == true else { return nil }
        var out: [KnowQuestion] = []
        var seen = Set<String>()
        for row in raw.items ?? [] {
            guard let x = row.value, let id = x.id, HomeFeeds.isID(id), !seen.contains(id),
                  let text = MothershipFeeds.cut(x.text, 160) else { continue }
            seen.insert(id)
            let group: String = x.group.flatMap { groups.contains($0) ? $0 : nil } ?? "general"
            let answer: String = x.answer.flatMap { answers.contains($0) ? $0 : nil } ?? "text"
            out.append(KnowQuestion(id: id, group: group, answer: answer, text: text, evidence: evidence(x.evidence),
                                    draft: MothershipFeeds.cut(x.draft, 400), current: MothershipFeeds.cut(x.current, 200),
                                    checked_on: HomeFeeds.isDay(x.checked_on) ? x.checked_on : nil,
                                    tier: x.tier.flatMap { tiers.contains($0) ? $0 : nil }))
        }
        return out
    }

    static func decodeSpots(_ data: Data) -> [KnowSpot]? {
        guard let raw = try? JSONDecoder().decode(RawFeed<RawSpot>.self, from: data), raw.available == true else { return nil }
        var out: [KnowSpot] = []
        var seen = Set<String>()
        for row in raw.items ?? [] {
            guard let x = row.value, let id = x.id, HomeFeeds.isID(id), !seen.contains(id),
                  let claim = MothershipFeeds.cut(x.claim, 160) else { continue }
            seen.insert(id)
            out.append(KnowSpot(id: id, kind: MothershipFeeds.cut(x.kind, 40) ?? "", claim: claim,
                                day: HomeFeeds.isDay(x.day) ? x.day : nil, evidence: evidence(x.evidence),
                                note: MothershipFeeds.cut(x.note, 120) ?? ""))
        }
        return Array(out.prefix(5))
    }

    // MARK: 選ぶ（65）

    /// その日の問い。前に決めた日が今日なら、そのまま（入れ替えない）。違う日なら、答えていないものから上の perDay 問
    static func todayQuestions(day: String, local: KnowLocal, fetched: [KnowQuestion]) -> (day: String, items: [KnowQuestion]) {
        if local.questionDay == day { return (day, local.todayQuestions) }
        var picked: [KnowQuestion] = []
        for q in fetched where local.answered[q.id] == nil {
            picked.append(q)
            if picked.count >= perDay { break }
        }
        return (day, picked)
    }

    /// まだ答えていない今日の問い
    static func openQuestions(_ local: KnowLocal) -> [KnowQuestion] {
        local.todayQuestions.filter { local.answered[$0.id] == nil }
    }

    /// 今週の見立て。週が変われば、まだ ○× を付けていないものから hypothesesPerWeek 個
    static func weekHypotheses(week: String, local: KnowLocal, fetched: [KnowHypothesis],
                               voted: (String) -> Bool) -> [KnowHypothesis] {
        if local.hypothesisWeek == week, !local.weekHypotheses.isEmpty { return local.weekHypotheses }
        var picked: [KnowHypothesis] = []
        for h in fetched where !voted(h.id) {
            picked.append(h)
            if picked.count >= hypothesesPerWeek { break }
        }
        return picked
    }

    /// "2026-W47"（月曜はじまりの週）
    static func weekKey(_ date: Date, calendar: Calendar = .current) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = calendar.timeZone
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 朝の 1 タップを出す時間か
    static func isMorning(_ date: Date, calendar: Calendar = .current) -> Bool {
        let h = calendar.component(.hour, from: date)
        return h >= morningFrom && h < morningTo
    }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = precise.date(from: text) { return d }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: 送る中身（家の PC の knowme.py と同じ形。おかしければ nil）

    private static func json(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let answerValues: [String: [String]] = ["question": ["answered", "skip"], "draft": ["ok", "fixed", "skip"]]

    static func answerBody(id: String, kind: String, value: String, day: String, text: String?, group: String?,
                           question: String?, by: String = "app") -> Data? {
        guard HomeFeeds.isID(id), HomeFeeds.isDay(day), let values = answerValues[kind], values.contains(value) else { return nil }
        let body: String? = MothershipFeeds.cut(text, 1000)
        if (value == "answered" || value == "fixed") && body == nil { return nil }
        var o: [String: Any] = ["id": id, "kind": kind, "value": value, "day": day, "by": by]
        if let body { o["text"] = body }
        if let group, groups.contains(group) { o["group"] = group }
        if let q = MothershipFeeds.cut(question, 160) { o["question"] = q }
        return json(o)
    }

    static func recheckBody(id: String, value: String, note: String?) -> Data? {
        guard HomeFeeds.isID(id), ["still", "changed", "outdated"].contains(value) else { return nil }
        var o: [String: Any] = ["id": id, "value": value]
        if let n = MothershipFeeds.cut(note, 400) { o["note"] = n }
        return json(o)
    }

    static func noteBody(day: String, start: Date, text: String) -> Data? {
        guard HomeFeeds.isDay(day), let t = MothershipFeeds.cut(text, 400) else { return nil }
        return json(["day": day, "conversation_start": MothershipOutbox.isoString(start), "text": t])
    }

    static func goalBody(day: String, person: String, pe: String?, text: String) -> Data? {
        guard HomeFeeds.isDay(day), let name = MothershipFeeds.cut(person, 40), let t = MothershipFeeds.cut(text, 200) else { return nil }
        var o: [String: Any] = ["day": day, "person": name, "text": t]
        if let pe, HomeFeeds.isID(pe) { o["pe"] = pe }
        return json(o)
    }

    static func whyWrongBody(day: String, target: String, reason: String, why: String?, head: String?, question: String?) -> Data? {
        let targets: [String] = ["ask", "mother", "hypothesis", "proposal", "brief", "question", "other"]
        guard HomeFeeds.isDay(day), targets.contains(target), whyReasons.contains(where: { $0.id == reason }) else { return nil }
        var o: [String: Any] = ["day": day, "target": target, "reason": reason]
        if let w = MothershipFeeds.cut(why, 400) { o["why"] = w }
        if let h = MothershipFeeds.cut(head, 120) { o["head"] = h }
        if let q = MothershipFeeds.cut(question, 200) { o["question"] = q }
        return json(o)
    }

    static func markBody(day: String, kind: String, start: Date, end: Date?, questionID: String?) -> Data? {
        guard HomeFeeds.isDay(day), markKinds.contains(kind) else { return nil }
        var o: [String: Any] = ["day": day, "kind": kind, "start": MothershipOutbox.isoString(start)]
        if let end {
            guard end > start, end.timeIntervalSince(start) <= 6 * 3600 else { return nil }
            o["end"] = MothershipOutbox.isoString(end)
        }
        if let questionID, HomeFeeds.isID(questionID) { o["question_id"] = questionID }
        return json(o)
    }

    struct Near: Equatable {
        var conversationStart: Date?
        var lineTime: Date?
        var speaker: String?
        var textHead: String?
        var audio: String?
    }

    static func voiceFixBody(text: String, saidAt: Date, by: String, near: Near?) -> Data? {
        guard let t = MothershipFeeds.cut(text, 200), ["watch", "app", "notice"].contains(by) else { return nil }
        var o: [String: Any] = ["text": t, "said_at": MothershipOutbox.isoString(saidAt), "by": by]
        if let near {
            var n: [String: Any] = [:]
            if let d = near.conversationStart { n["conversation_start"] = MothershipOutbox.isoString(d) }
            if let d = near.lineTime { n["line_time"] = MothershipOutbox.isoString(d) }
            if let s = MothershipFeeds.cut(near.speaker, 40) { n["speaker"] = s }
            if let s = MothershipFeeds.cut(near.textHead, 60) { n["text_head"] = s }
            if let s = MothershipFeeds.cut(near.audio, 120) { n["audio"] = s }
            if !n.isEmpty { o["near"] = n }
        }
        return json(o)
    }

    static func moodTapBody(day: String, at: Date, slot: String, mood: Int) -> Data? {
        guard HomeFeeds.isDay(day), ["morning", "night"].contains(slot), mood >= 1, mood <= 5 else { return nil }
        return json(["day": day, "at": MothershipOutbox.isoString(at), "slot": slot, "mood": mood])
    }

    /// 時計の「違う、〇〇さん」の直前の行（言った時刻より前で、fixLookBack 以内のいちばん新しい行）
    static func near(_ conversations: [ConversationLog.Conversation], before at: Date) -> Near? {
        var best: (ConversationLog.Conversation, ConversationLog.Line)?
        for c in conversations {
            for line in c.lines where line.time <= at && at.timeIntervalSince(line.time) <= fixLookBack {
                if best == nil || line.time > best!.1.time { best = (c, line) }
            }
        }
        guard let found = best else { return nil }
        let c: ConversationLog.Conversation = found.0
        let line: ConversationLog.Line = found.1
        return Near(conversationStart: c.start, lineTime: line.time, speaker: line.speaker,
                    textHead: String(line.text.prefix(60)), audio: line.audio)
    }

    // MARK: 通知（62。はい・いいえは通知の上と時計で答えられる。時計には iPhone の通知がそのまま出る）

    static func notificationCategories() -> [UNNotificationCategory] {
        let yes = UNNotificationAction(identifier: yesAction, title: "はい", options: [])
        let no = UNNotificationAction(identifier: noAction, title: "いいえ", options: [])
        let unsure = UNNotificationAction(identifier: unsureAction, title: "わからない", options: [])
        let record = UNNotificationAction(identifier: recordAction, title: "録音を始める", options: [.foreground])
        return [UNNotificationCategory(identifier: category, actions: [yes, no, unsure], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: geoCategory, actions: [record], intentIdentifiers: [], options: [])]
    }

    /// 押されたボタン → 答え（はい → right・いいえ → wrong・わからない → unsure）。知らせそのものなら nil
    static func value(forAction id: String) -> String? {
        switch id {
        case yesAction: "right"
        case noAction: "wrong"
        case unsureAction: "unsure"
        default: nil
        }
    }
}

// MARK: - 読み込みと答え

@MainActor
@Observable
final class KnowMeBook {
    static let shared = KnowMeBook()

    private(set) var hypotheses: [KnowHypothesis] = []
    private(set) var questions: [KnowQuestion] = []
    private(set) var spots: [KnowSpot] = []
    private(set) var tiers: [String: String] = [:]
    private(set) var local = KnowLocal()
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var fetching = false
    /// 家の PC（通知のボタンから答えたときに送る）
    @ObservationIgnored var pc: HomePC?
    /// 録音を始める（場所の見張り・通知のボタンから）
    @ObservationIgnored var startRecording: (() async -> Void)?
    @ObservationIgnored var feeds: MothershipFeedsBook?

    private static let every: TimeInterval = 30 * 60
    private static let file = "know-me.json"
    private static let feedFile = "know-me-feed.json"

    private struct Saved: Codable {
        var hypotheses: [KnowHypothesis] = []
        var questions: [KnowQuestion] = []
        var spots: [KnowSpot] = []
    }

    private static func url(_ name: String) -> URL { URL.applicationSupportDirectory.appendingPathComponent(name) }

    init() {
        if let data = try? Data(contentsOf: Self.url(Self.file)), let saved = try? JSONDecoder().decode(KnowLocal.self, from: data) {
            local = saved
        }
        if let data = try? Data(contentsOf: Self.url(Self.feedFile)), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            hypotheses = saved.hypotheses
            questions = saved.questions
            spots = saved.spots
        }
    }

    private func saveLocal() {
        guard let data = try? JSONEncoder().encode(local) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.url(Self.file), options: .atomic)
    }

    private func saveFeed() {
        guard let data = try? JSONEncoder().encode(Saved(hypotheses: hypotheses, questions: questions, spots: spots)) else { return }
        try? data.write(to: Self.url(Self.feedFile), options: .atomic)
    }

    /// 読み直す（force でなければ 30 分に 1 回まで）。読めなかった写しは前のまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        self.pc = pc
        guard !fetching, pc.isConfigured, pc.features.contains(KnowMeRules.feature) else {
            pickToday()
            return
        }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every {
            pickToday()
            return
        }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        if let body = try? await pc.appFeed("know/hypotheses", feature: KnowMeRules.feature),
           let got = KnowMeRules.decodeHypotheses(body) {
            hypotheses = got
        }
        if let body = try? await pc.appFeed("know/questions", feature: KnowMeRules.feature),
           let got = KnowMeRules.decodeQuestions(body) {
            questions = got
        }
        if let body = try? await pc.appFeed("know/spot-checks", feature: KnowMeRules.feature),
           let got = KnowMeRules.decodeSpots(body) {
            spots = got
        }
        if let body = try? await pc.appFeed("know/tiers", feature: KnowMeRules.feature),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let items = object["items"] as? [String: Any] {
            var map: [String: String] = [:]
            for (key, value) in items {
                if let row = value as? [String: Any], let tier = row["tier"] as? String { map[key] = tier }
            }
            tiers = map
        }
        saveFeed()
        pickToday()
        scheduleYesNoNotice()
        await MothershipOutbox.send(pc)
    }

    /// 今日の問い・今週の見立てを決める（決めてあればそのまま）
    func pickToday(now: Date = .now) {
        let day = KnowMeRules.dayKey(now)
        let picked = KnowMeRules.todayQuestions(day: day, local: local, fetched: questions)
        let week = KnowMeRules.weekKey(now)
        let feeds = self.feeds
        // 今週の見立ては、聞く段（ask）でないものを先に（ask のものは今日の問いで聞く）
        let ordered: [KnowHypothesis] = hypotheses.filter { $0.tier != "ask" } + hypotheses.filter { $0.tier == "ask" }
        let weekH = KnowMeRules.weekHypotheses(week: week, local: local, fetched: ordered) { id in
            feeds?.voted("hypothesis", id: id) != nil
        }
        var next = local
        next.questionDay = picked.day
        next.todayQuestions = picked.items
        next.hypothesisWeek = week
        next.weekHypotheses = weekH
        if next != local {
            local = next
            saveLocal()
        }
    }

    // MARK: 数（「直す」タブ）

    /// まだ答えていない今日の問い（見立ての問いを「今週の見立て」や通知で答えたものも外す）
    var openQuestions: [KnowQuestion] {
        KnowMeRules.openQuestions(local).filter { $0.group != "hypothesis" || hypothesisAnswer($0.id) == nil }
    }

    func hypothesisAnswer(_ id: String) -> String? { feeds?.voted("hypothesis", id: id) }
    func spotAnswer(_ id: String) -> String? { feeds?.voted("spot", id: id) }

    var openHypotheses: [KnowHypothesis] { local.weekHypotheses.filter { hypothesisAnswer($0.id) == nil } }
    var openSpots: [KnowSpot] { spots.filter { spotAnswer($0.id) == nil } }

    /// 「直す」の数（今日の問い・今週の見立て・抜き打ちのうち、まだ答えていないもの）
    var pendingCount: Int { openQuestions.count + openHypotheses.count + openSpots.count }

    /// その判定の段（GET /know/tiers。"<出力名>:<item の鍵>"。無ければ nil）
    func tier(_ output: String, _ key: String) -> String? { tiers[output + ":" + key] }

    /// 本人に聞くか（61）。段が無い・ask なら聞く。auto（黙って入れる）は聞かない。tentative は KnowMeRules.askTentative（仮）
    func shouldAsk(_ output: String, _ key: String) -> Bool {
        KnowMeRules.shouldAsk(tier: tier(output, key))
    }

    // MARK: 答える

    private func enqueue(_ path: String, _ body: Data?) -> Bool {
        guard let body else { return false }
        MothershipOutbox.enqueue(path: path, body: body)
        Tally.add("know." + path.replacingOccurrences(of: "/", with: "."))
        return true
    }

    private func send() {
        guard let pc else { return }
        Task { await MothershipOutbox.send(pc) }
    }

    private func markAnswered(_ id: String, _ value: String) {
        local.answered[id] = value
        // 古い印は 2000 件まで（二度と聞かないのは家の PC も見ている）
        if local.answered.count > 2000, let first = local.answered.keys.sorted().first { local.answered[first] = nil }
        saveLocal()
    }

    /// 文で答える（下書きがあって、そのままでよいなら draftOK）
    @discardableResult
    func answer(_ q: KnowQuestion, text: String, day: String) -> Bool {
        let kind: String = q.draft == nil ? "question" : "draft"
        let value: String = q.draft == nil ? "answered" : "fixed"
        guard enqueue("know/answer", KnowMeRules.answerBody(id: q.id, kind: kind, value: value, day: day, text: text,
                                                            group: q.group, question: q.text)) else { return false }
        markAnswered(q.id, value)
        send()
        return true
    }

    func draftOK(_ q: KnowQuestion, day: String) {
        guard let draft = q.draft,
              enqueue("know/answer", KnowMeRules.answerBody(id: q.id, kind: "draft", value: "ok", day: day, text: draft,
                                                            group: q.group, question: q.text)) else { return }
        markAnswered(q.id, "ok")
        send()
    }

    func skip(_ q: KnowQuestion, day: String) {
        guard enqueue("know/answer", KnowMeRules.answerBody(id: q.id, kind: "question", value: "skip", day: day, text: nil,
                                                            group: q.group, question: q.text)) else { return }
        markAnswered(q.id, "skip")
        send()
    }

    func recheck(_ q: KnowQuestion, value: String, note: String?) {
        guard enqueue("know/recheck", KnowMeRules.recheckBody(id: q.id, value: value, note: note)) else { return }
        markAnswered(q.id, value)
        send()
    }

    /// 見立ての ○×（1。問いの「はい・いいえ」も同じ。61）
    func voteHypothesis(_ id: String, value: String, day: String) {
        feeds?.vote("hypothesis", id: id, value: value, day: day)
        if local.todayQuestions.contains(where: { $0.id == id }) { markAnswered(id, value) }
        send()
    }

    func voteSpot(_ id: String, value: String, day: String) {
        feeds?.vote("spot", id: id, value: value, day: day)
        send()
    }

    func moodTap(slot: String, mood: Int, now: Date = .now) {
        let day = KnowMeRules.dayKey(now)
        guard enqueue("mood/tap", KnowMeRules.moodTapBody(day: day, at: now, slot: slot, mood: mood)) else { return }
        local.moodTaps[day + "|" + slot] = mood
        saveLocal()
        send()
    }

    func moodTapped(slot: String, now: Date = .now) -> Int? { local.moodTaps[KnowMeRules.dayKey(now) + "|" + slot] }

    func note(day: String, start: Date, text: String) {
        guard enqueue("know/note", KnowMeRules.noteBody(day: day, start: start, text: text)) else { return }
        local.notes[day + "|" + MothershipOutbox.isoString(start)] = text
        saveLocal()
        send()
    }

    func savedNote(day: String, start: Date) -> String? { local.notes[day + "|" + MothershipOutbox.isoString(start)] }

    func goal(person: String, pe: String?, text: String, now: Date = .now) {
        guard enqueue("know/person-goal", KnowMeRules.goalBody(day: KnowMeRules.dayKey(now), person: person, pe: pe, text: text))
        else { return }
        local.goals[pe ?? person] = text
        saveLocal()
        send()
    }

    func savedGoal(person: String, pe: String?) -> String? { local.goals[pe ?? person] }

    @discardableResult
    func whyWrong(target: String, reason: String, why: String?, head: String?, question: String?, now: Date = .now) -> Bool {
        let ok = enqueue("know/why-wrong", KnowMeRules.whyWrongBody(day: KnowMeRules.dayKey(now), target: target, reason: reason,
                                                                  why: why, head: head, question: question))
        if ok { send() }
        return ok
    }

    // MARK: 録って印を付ける（4・11・30）

    var markOpen: Bool { local.markStart != nil }
    var markKind: String? { local.markKind }

    /// 録り始める（録音していなければ始める）。印の始まりを覚える
    func startMark(kind: String, questionID: String?, now: Date = .now) async {
        guard KnowMeRules.markKinds.contains(kind) else { return }
        local.markKind = kind
        local.markStart = now
        local.markQuestion = questionID
        saveLocal()
        Tally.add("know.mark.start")
        await startRecording?()
    }

    /// 録り終えた。印を母艦へ（問いから始めたなら、その問いも答えたことにする）
    func endMark(now: Date = .now) {
        guard let kind = local.markKind, let start = local.markStart else { return }
        let day = KnowMeRules.dayKey(start)
        let end: Date = now > start ? min(now, start.addingTimeInterval(6 * 3600)) : start.addingTimeInterval(1)
        _ = enqueue("know/mark", KnowMeRules.markBody(day: day, kind: kind, start: start, end: end, questionID: local.markQuestion))
        if let qid = local.markQuestion, let q = local.todayQuestions.first(where: { $0.id == qid }) {
            let text = "録音に印を付けた（" + MothershipOutbox.isoString(start) + "〜" + MothershipOutbox.isoString(end) + "）"
            _ = enqueue("know/answer", KnowMeRules.answerBody(id: q.id, kind: "question", value: "answered", day: day, text: text,
                                                              group: q.group, question: q.text))
            local.answered[qid] = "answered"
        }
        local.markKind = nil
        local.markStart = nil
        local.markQuestion = nil
        saveLocal()
        send()
    }

    // MARK: 時計の「違う、〇〇さん」（63）

    func voiceFix(text: String, saidAt: Date, by: String, near: KnowMeRules.Near?) {
        _ = enqueue("know/voice-fix", KnowMeRules.voiceFixBody(text: text, saidAt: saidAt, by: by, near: near))
        send()
    }

    // MARK: 通知（62）

    /// その日の「はい・いいえ」で答えられる 1 つ（今日の問いの見立て → 抜き打ち → 今週の見立て）
    func yesNoItem() -> (id: String, kind: String, text: String, day: String?)? {
        for q in openQuestions where q.answer == "yesno" { return (q.id, "hypothesis", q.text, nil) }
        for s in openSpots { return (s.id, "spot", s.claim, s.day) }
        for h in openHypotheses { return (h.id, "hypothesis", h.text, nil) }
        return nil
    }

    /// その日の 1 通を頼む（1 日 1 通まで。決めた時刻を過ぎていれば頼まない。設定で切れる）
    func scheduleYesNoNotice(now: Date = .now) {
        guard UserDefaults.standard.object(forKey: KnowMeSettings.noticeKey) as? Bool ?? true else { return }
        let day = KnowMeRules.dayKey(now)
        guard local.noticeDay != day, let item = yesNoItem() else { return }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        c.hour = KnowMeRules.noticeHour
        c.minute = KnowMeRules.noticeMinute
        guard let when = Calendar.current.date(from: c), when > now else { return }
        let content = UNMutableNotificationContent()
        content.title = item.kind == "spot" ? "合ってる？（抜き打ち）" : "見立て（仮）: 当たってる？"
        content.body = item.text
        content.categoryIdentifier = KnowMeRules.category
        content.userInfo = ["kid": item.id, "kkind": item.kind, "kday": item.day ?? day]
        let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: false)
        NoticeGate.add(UNNotificationRequest(identifier: KnowMeRules.yesNoID, content: content, trigger: trigger))
        local.noticeDay = day
        saveLocal()
    }

    /// 通知のボタンが押された（アプリが閉じていても iOS が裏で起こしてここに来る。時計の通知のボタンも同じ）
    func noticeAnswered(actionID: String, userInfo: [AnyHashable: Any]) async {
        if actionID == KnowMeRules.recordAction {
            Tally.add("know.geo.tapRecord")
            await startRecording?()
            return
        }
        guard let value = KnowMeRules.value(forAction: actionID), let id = userInfo["kid"] as? String,
              let kind = userInfo["kkind"] as? String else { return }
        let day: String = (userInfo["kday"] as? String).flatMap { HomeFeeds.isDay($0) ? $0 : nil } ?? KnowMeRules.dayKey(.now)
        Tally.add("know.notice." + value)
        if kind == "spot" {
            feeds?.vote("spot", id: id, value: value, day: day)
        } else {
            feeds?.vote("hypothesis", id: id, value: value, day: day)
            if local.todayQuestions.contains(where: { $0.id == id }) { markAnswered(id, value) }
        }
        if let pc { await MothershipOutbox.send(pc) }
    }

    /// 週の振り返りの促し（11。日曜 20:00。仮。設定で切れる）
    static func scheduleWeeklyTalk() {
        let center = UNUserNotificationCenter.current()
        guard UserDefaults.standard.object(forKey: KnowMeSettings.weeklyTalkKey) as? Bool ?? true else {
            center.removePendingNotificationRequests(withIdentifiers: [KnowMeRules.weeklyTalkID])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "5 分しゃべる振り返り"
        content.body = "今週あったこと・思ったことを 5 分しゃべってみませんか。「直す」→「自分を知る」の「録り始める」で印が付きます。"
        S23Notices.decorate(content, id: KnowMeRules.weeklyTalkID)  // 押すとどうなるかを文に（2026-11-23。s23 の 知8）
        var c = DateComponents()
        c.weekday = KnowMeRules.weeklyTalkWeekday
        c.hour = KnowMeRules.weeklyTalkHour
        let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: true)
        center.add(UNNotificationRequest(identifier: KnowMeRules.weeklyTalkID, content: content, trigger: trigger))
    }
}

/// 設定の名前（UserDefaults）
enum KnowMeSettings {
    /// 通知の上で「はい・いいえ」（初めはオン）
    static let noticeKey = "knowMe.notice"
    /// 週の振り返りの促し（初めはオン）
    static let weeklyTalkKey = "knowMe.weeklyTalk"
    /// 職場に着いたら録音を始めてみる（初めはオフ）
    static let workRecordKey = "knowMe.workRecord"
    /// 家に着いたら取り込みを急ぐ（初めはオン）
    static let homeRushKey = "knowMe.homeRush"
}

// MARK: - 場所の見張り（57）

/// 職場・自宅（登録した場所）に着いたときの動き。iOS の場所の見張り（CLMonitor）で、アプリが閉じていても起こされる。
/// - 職場: 録音していなければ、録音を始めてみる。iOS は裏からマイクを起こすことを許さないので、始められなかったら
///   「録音を始める」ボタンの付いた知らせを出す（押すとアプリが開いて始まる）。確実に始めたいときは、ショートカットのオートメーション
///   （「職場に到着したとき」→ LifeLog の「録音を始める」）を使う。始められたか・始められなかったかは tally の know.geo.bgrec.* に数える。
/// - 自宅: たまっている区切りを文字にし、ためた答えを家の PC に送り、次の裏の処理を早めに頼む。
@MainActor
final class KnowGeo {
    static let shared = KnowGeo()
    private var monitor: CLMonitor?
    private var listening: Task<Void, Never>?
    private weak var pipeline: Pipeline?
    private static let signatureKey = "knowGeo.signature"
    private static let arrivedKey = "knowGeo.arrived"

    struct Region: Equatable {
        var id: String
        var kind: String
        var latitude: Double
        var longitude: Double
        var radius: Double
    }

    /// 見張る場所（職場は isWork、自宅は名前が「自宅」を含むか「家」「うち」。PlaceLog.placeKind と同じ決まり）
    nonisolated static func regions(_ places: [PlaceLog.Place]) -> [Region] {
        var out: [Region] = []
        for p in places {
            let kind: String
            if p.isWork == true {
                kind = "work"
            } else if p.name.contains("自宅") || p.name == "家" || p.name == "うち" {
                kind = "home"
            } else {
                continue
            }
            out.append(Region(id: kind + ":" + p.id.uuidString, kind: kind, latitude: p.latitude, longitude: p.longitude,
                              radius: max(p.radius, KnowMeRules.minRadius)))
        }
        return out
    }

    nonisolated static func signature(_ regions: [Region]) -> String {
        regions.map { String(format: "%@|%.4f|%.4f|%.0f", $0.id, $0.latitude, $0.longitude, $0.radius) }.sorted().joined(separator: ";")
    }

    /// 前に「着いた」と数えてから arriveGap たっていれば true
    nonisolated static func shouldCount(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= KnowMeRules.arriveGap
    }

    func start(_ pipeline: Pipeline) {
        self.pipeline = pipeline
        Task { await sync() }
    }

    /// 場所の登録が変わっていれば、見張りを付け直す（変わっていなければ触らない。付け直すと「中にいる」がもう一度届くため）
    func sync() async {
        guard let pipeline else { return }
        let wanted = Self.regions(pipeline.places.places)
        let sig = Self.signature(wanted)
        if monitor == nil { monitor = await CLMonitor("lifelogKnowGeo") }
        guard let monitor else { return }
        if UserDefaults.standard.string(forKey: Self.signatureKey) != sig {
            for id in await monitor.identifiers { await monitor.remove(id) }
            for r in wanted {
                let center = CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)
                await monitor.add(CLMonitor.CircularGeographicCondition(center: center, radius: r.radius), identifier: r.id,
                                  assuming: .unsatisfied)
            }
            UserDefaults.standard.set(sig, forKey: Self.signatureKey)
        }
        guard listening == nil else { return }
        listening = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    // 自宅を出た（2026-11-21。s19 の 休6・休7・休8。Holiday.swift）
                    if event.state == .unsatisfied, event.identifier.hasPrefix("home:") {
                        await HolidayNudges.shared.leftHome(at: event.date)
                        continue
                    }
                    guard event.state == .satisfied else { continue }
                    // 家に戻った（時計の外出モードが溜めた区切りを送る。2026-11-21。s19 の 休8）
                    if event.identifier.hasPrefix("home:") { await HolidayNudges.shared.arrivedHome() }
                    await self?.arrived(event.identifier, at: event.date)
                }
            } catch {
                Tally.add("know.geo.error")
            }
        }
    }

    private func arrived(_ id: String, at date: Date) async {
        let kind: String = id.hasPrefix("work:") ? "work" : id.hasPrefix("home:") ? "home" : ""
        guard !kind.isEmpty else { return }
        var last = UserDefaults.standard.dictionary(forKey: Self.arrivedKey) as? [String: Double] ?? [:]
        let prev: Date? = last[kind].map { Date(timeIntervalSince1970: $0) }
        guard Self.shouldCount(last: prev, now: date) else { return }
        last[kind] = date.timeIntervalSince1970
        UserDefaults.standard.set(last, forKey: Self.arrivedKey)
        Tally.add("know.geo." + kind)
        let app = UIApplication.shared
        let token = app.beginBackgroundTask(withName: "knowGeo", expirationHandler: nil)
        defer { if token != .invalid { app.endBackgroundTask(token) } }
        if kind == "work" {
            await arrivedAtWork()
        } else {
            await arrivedHome()
        }
    }

    private func arrivedAtWork() async {
        guard let pipeline, UserDefaults.standard.bool(forKey: KnowMeSettings.workRecordKey), !pipeline.isRecording else { return }
        await pipeline.handle(.startRecording)
        try? await Task.sleep(for: .seconds(3))
        if pipeline.isRecording {
            Tally.add("know.geo.bgrec.ok")
            return
        }
        Tally.add("know.geo.bgrec.fail")
        let content = UNMutableNotificationContent()
        content.title = "職場に着きました"
        content.body = "録音を始めますか（iOS が裏から録音を始めさせないので、押すと開いて始めます）"
        content.categoryIdentifier = KnowMeRules.geoCategory
        NoticeGate.add(UNNotificationRequest(identifier: KnowMeRules.geoWorkID, content: content, trigger: nil))
    }

    private func arrivedHome() async {
        guard let pipeline, UserDefaults.standard.object(forKey: KnowMeSettings.homeRushKey) as? Bool ?? true else { return }
        Tally.add("know.geo.homeRush")
        await pipeline.runQueue()
        await MothershipOutbox.send(pipeline.homePC)
        // 次の裏の処理を早めに（15 分後ではなく 1 分後から）頼む
        let refresh = BGAppRefreshTaskRequest(identifier: Pipeline.refreshTaskID)
        refresh.earliestBeginDate = .now.addingTimeInterval(60)
        try? BGTaskScheduler.shared.submit(refresh)
    }
}

// MARK: - Pipeline から

extension Pipeline {
    /// 時計から「違う、〇〇さん」が届いた（63）。直前の会話の行を添えて家の PC へ（言葉の解釈は家の PC）
    func receiveVoiceFix(_ text: String, at: Date) {
        let day = KnowMeRules.dayKey(at)
        let near = KnowMeRules.near(conversations(on: day), before: at)
        KnowMeBook.shared.voiceFix(text: text, saidAt: at, by: "watch", near: near)
        Tally.add("know.voiceFix.watch")
    }
}

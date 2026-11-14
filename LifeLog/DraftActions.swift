import EventKit
import Foundation
import Observation
import SwiftUI
import UIKit

/// 下書きまでやる・時間の家計簿（2026-11-15。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 3」）。
/// - 58 (a) 約束・タスクに期限の日があれば「予定に仮登録」「リマインダーに」。どちらも確かめの画面で「入れる」を押すまで何も入れない。
///   カレンダーは初めて押したときだけ許可を聞く（読む許可がもうあればそれを使い、無ければ書くだけの許可）。
/// - 58 (b)(c) 家の PC の GET /replies（features "replies"）: 返事をしていないらしい LINE の下書きと、約束したメールの下書き。
///   「写す」「LINE を開く」だけで、**ここからは何も送らない**。
/// - 60 家の PC の GET /time-ledger（"timeledger"）: 週ごとの時間の使い道。「ふり返り」に出す。
/// 写しは端末に置き（同期しない）、家の PC につながらないときも前の写しを見せる。中身の文は記録（ログ）に書かない。

// MARK: - 予定・リマインダーへの仮登録（58 (a)）

/// どこへ入れるか
enum DraftTarget: String, Identifiable {
    case calendar
    case reminder
    var id: String { rawValue }
}

/// カレンダーに仮の予定を入れる（本人が確かめの画面で「入れる」を押したときだけ）
enum CalendarDraft {
    private static let store = EKEventStore()

    enum Failure: LocalizedError {
        case denied
        case noDate

        var errorDescription: String? {
            switch self {
            case .denied: return "カレンダーが許可されていません（設定 → プライバシー → カレンダー）"
            case .noDate: return "期限の日が無いので、予定にできません"
            }
        }
    }

    /// 入れる予定の形（確かめの画面に出す）
    struct Plan: Equatable {
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var notes: String
    }

    /// 頼まれごとから、入れる予定を作る（時刻があれば 30 分、無ければ終日）。期限の日が無ければ nil
    static func plan(for item: TaskBook.Item) -> Plan? {
        guard let due = item.due else { return nil }
        let title: String = "（仮）" + item.what
        var lines: [String] = []
        if let from = item.from { lines.append(item.kindOrDefault.partyLabel + ": " + from) }
        if let quote = item.quote, !quote.isEmpty { lines.append("もとの言葉: " + quote) }
        lines.append("LifeLog から（仮登録）")
        let notes: String = lines.joined(separator: "\n")
        if item.dueTime != nil, let moment = item.dueMoment {
            let end: Date = moment.addingTimeInterval(30 * 60)
            return Plan(title: title, start: moment, end: end, allDay: false, notes: notes)
        }
        let start: Date = Calendar.current.startOfDay(for: due)
        let end: Date = start.addingTimeInterval(86400)
        return Plan(title: title, start: start, end: end, allDay: true, notes: notes)
    }

    /// 予定を入れて、その予定の id を返す
    static func add(_ plan: Plan) async throws -> String {
        let status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if status != .fullAccess && status != .writeOnly {
            let granted: Bool = try await store.requestWriteOnlyAccessToEvents()
            guard granted else { throw Failure.denied }
        }
        let event = EKEvent(eventStore: store)
        event.title = plan.title
        event.startDate = plan.start
        event.endDate = plan.end
        event.isAllDay = plan.allDay
        event.notes = plan.notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }
}

/// 下書きの決まり（画面を持たない）
enum DraftRules {
    /// 約束の期限の言い方から日を読む（「2026-11-20」「11/20」「11月20日」だけ。曜日や「来週」は読まない）
    static func dueDay(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let s: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let iso = firstMatch(s, #"\d{4}-\d{2}-\d{2}"#), let date = TaskBook.dueDate(iso) { return date }
        guard let md = firstMatch(s, #"\d{1,2}[/月]\d{1,2}"#) else { return nil }
        let parts: [String] = md.replacingOccurrences(of: "月", with: "/").split(separator: "/").map { String($0) }
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let year: Int = calendar.component(.year, from: now)
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        guard let thisYear = calendar.date(from: comps) else { return nil }
        // 30 日より前なら来年のこと
        if thisYear < now.addingTimeInterval(-30 * 86400) {
            comps.year = year + 1
            return calendar.date(from: comps)
        }
        return thisYear
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// 約束を、仮登録に使うタスクの形にする（期限の日が読めなければ nil。帳には入れない）
    static func taskForPromise(_ p: PromiseItem, now: Date = .now) -> TaskBook.Item? {
        guard let day = dueDay(p.due, now: now) else { return nil }
        var item: TaskBook.Item = PromiseRules.taskItem(p, work: p.work ?? true, now: now)
        item.due = Calendar.current.startOfDay(for: day)
        return item
    }

    /// 確かめの画面の「日時」
    static func whenText(target: DraftTarget, item: TaskBook.Item) -> String {
        if target == .calendar, let plan = CalendarDraft.plan(for: item) {
            if plan.allDay { return plan.start.formatted(date: .abbreviated, time: .omitted) + "（終日）" }
            return plan.start.formatted(date: .abbreviated, time: .shortened) + "から 30 分"
        }
        guard let moment = item.dueMoment else { return "期限なし" }
        let time: Date.FormatStyle.TimeStyle = item.dueTime == nil ? .omitted : .shortened
        return moment.formatted(date: .abbreviated, time: time)
    }
}

/// 「入れる」「やめる」の確かめ
struct DraftConfirmView: View {
    let target: DraftTarget
    let item: TaskBook.Item
    var onDecide: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(target == .calendar ? "カレンダーに入れる予定" : "リマインダーに入れる項目") {
                    LabeledContent("題", value: titleText)
                    LabeledContent("日時", value: DraftRules.whenText(target: target, item: item))
                    if let quote = item.quote, !quote.isEmpty {
                        Text("もとの言葉: " + quote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(footerText).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("確かめる")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") {
                        onDecide(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("入れる") {
                        onDecide(true)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var titleText: String {
        target == .calendar ? "（仮）" + item.what : item.what
    }

    private var footerText: String {
        let app: String = target == .calendar ? "カレンダー" : "リマインダー"
        return "「入れる」を押すまで、何も入りません。入れたあとは iPhone の" + app + "で直したり消したりできます。"
    }
}

/// タスクの「書く・直す」の「予定に仮登録」「リマインダーに」（TaskEditView に置く）
struct TaskDraftSection: View {
    @Binding var item: TaskBook.Item
    let hasDue: Bool
    var prepare: () -> Void
    @State private var target: DraftTarget?
    @State private var note: String?

    var body: some View {
        Section {
            Button(item.eventID == nil ? "予定に仮登録" : "予定にもう一度仮登録") {
                prepare()
                target = .calendar
            }
            .disabled(!hasDue)
            Button(item.reminderID == nil ? "リマインダーに" : "リマインダーに送り直す") {
                prepare()
                target = .reminder
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("下書き（押すまで入りません）")
        } footer: {
            Text(hasDue ? "予定は題の頭に「（仮）」を付けて入れます。リマインダーでは、期限の時刻に知らせが来ます。"
                        : "予定にするには、上で期限の日を入れてください。リマインダーは期限が無くても入れられます。")
        }
        .sheet(item: $target) { t in
            DraftConfirmView(target: t, item: item) { ok in
                if ok { run(t) }
            }
        }
    }

    private func run(_ t: DraftTarget) {
        let snapshot: TaskBook.Item = item
        Task {
            do {
                switch t {
                case .calendar:
                    guard let plan = CalendarDraft.plan(for: snapshot) else { throw CalendarDraft.Failure.noDate }
                    item.eventID = try await CalendarDraft.add(plan)
                    note = "予定に入れました（題の頭に「（仮）」）。"
                case .reminder:
                    item.reminderID = try await RemindersExport.send(snapshot)
                    note = "リマインダーに入れました。"
                }
            } catch {
                note = "入れられませんでした: " + error.localizedDescription
            }
        }
    }
}

/// 会話のあとの約束の「予定に仮登録」「リマインダーに」（期限の日が読めるものだけ。タスクの帳には入れない）
struct PromiseDraftButtons: View {
    let item: PromiseItem
    @State private var target: DraftTarget?
    @State private var note: String?

    var body: some View {
        if let task = DraftRules.taskForPromise(item) {
            HStack(spacing: 16) {
                Button("予定に仮登録") { target = .calendar }
                Button("リマインダーに") { target = .reminder }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .sheet(item: $target) { t in
                DraftConfirmView(target: t, item: task) { ok in
                    if ok { run(t, task) }
                }
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func run(_ t: DraftTarget, _ task: TaskBook.Item) {
        Task {
            do {
                switch t {
                case .calendar:
                    guard let plan = CalendarDraft.plan(for: task) else { throw CalendarDraft.Failure.noDate }
                    _ = try await CalendarDraft.add(plan)
                    note = "予定に入れました。"
                case .reminder:
                    _ = try await RemindersExport.send(task)
                    note = "リマインダーに入れました。"
                }
            } catch {
                note = "入れられませんでした: " + error.localizedDescription
            }
        }
    }
}

// MARK: - 読んだ形（58 (b)(c)・60）

struct ReplyDraft: Codable, Equatable, Identifiable {
    var id: String
    var chat: String
    var who: String
    var last_at: String
    var waiting_hours: Int
    var ask: String
    var draft: String
    var note: String
}

struct MailDraft: Codable, Equatable, Identifiable {
    var id: String
    var to: String
    var subject: String
    var body: String
    var why: String
    var day: String?
}

struct RepliesFeed: Codable, Equatable {
    var generated_at: String?
    var items: [ReplyDraft]
    var mails: [MailDraft]
}

struct LedgerCategory: Codable, Equatable, Identifiable {
    var key: String
    var label: String
    var overlay: Bool
    var id: String { key }
}

struct LedgerWeek: Codable, Equatable, Identifiable {
    var week: String
    var from: String?
    var to: String?
    var days: Int
    var covered: Double
    var hours: [String: Double]
    var id: String { week }
}

struct TimeLedgerFeed: Codable, Equatable {
    var generated_at: String?
    var method: String
    var categories: [LedgerCategory]
    var weeks: [LedgerWeek]
}

// MARK: - 確かめ方（決まった入力から決まった出力だけ）

enum ActionFeeds {
    static let replyLimit = 10
    static let mailLimit = 5
    static let weekLimit = 12
    /// LINE のアプリを開く（トークの一覧。どのトークかは選べない）
    static let lineURL = "line://nv/chat"

    private struct RawReplies: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawReply>]?
        var mails: [LossyRow<RawMail>]?
    }

    private struct RawReply: Decodable {
        var id: String?
        var chat: String?
        var who: String?
        var last_at: String?
        var waiting_hours: Int?
        var ask: String?
        var draft: String?
        var note: String?
    }

    private struct RawMail: Decodable {
        var id: String?
        var to: String?
        var subject: String?
        var body: String?
        var why: String?
        var day: String?
    }

    private struct RawLedger: Decodable {
        var available: Bool?
        var generated_at: String?
        var method: String?
        var categories: [LossyRow<RawCategory>]?
        var weeks: [LossyRow<RawWeek>]?
    }

    private struct RawCategory: Decodable {
        var key: String?
        var label: String?
        var overlay: Bool?
    }

    private struct RawWeek: Decodable {
        var week: String?
        var from: String?
        var to: String?
        var days: Int?
        var covered: Double?
        var hours: [String: Double]?
    }

    /// GET /replies の答え。id・トーク・下書き・時刻の無い行は落とす
    static func decodeReplies(_ data: Data) -> RepliesFeed? {
        guard let raw = try? JSONDecoder().decode(RawReplies.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [ReplyDraft] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let id = r.id, HomeFeeds.isID(id), let chat = MothershipFeeds.cut(r.chat, 40),
                  let draft = MothershipFeeds.cut(r.draft, 300), let lastAt = r.last_at,
                  PromiseRules.date(lastAt) != nil, seen.insert(id).inserted else { continue }
            let hours: Int = max(0, r.waiting_hours ?? 0)
            items.append(ReplyDraft(id: id, chat: chat, who: MothershipFeeds.cut(r.who, 20) ?? "", last_at: lastAt,
                                    waiting_hours: hours, ask: MothershipFeeds.cut(r.ask, 120) ?? "", draft: draft,
                                    note: MothershipFeeds.cut(r.note, 80) ?? ""))
            if items.count >= replyLimit { break }
        }
        var mails: [MailDraft] = []
        for row in raw.mails ?? [] {
            guard let r = row.value, let id = r.id, HomeFeeds.isID(id), let subject = MothershipFeeds.cut(r.subject, 80),
                  let body = MothershipFeeds.cut(r.body, 800), seen.insert(id).inserted else { continue }
            let day: String? = HomeFeeds.isDay(r.day) ? r.day : nil
            mails.append(MailDraft(id: id, to: MothershipFeeds.cut(r.to, 40) ?? "", subject: subject, body: body,
                                   why: MothershipFeeds.cut(r.why, 120) ?? "", day: day))
            if mails.count >= mailLimit { break }
        }
        return RepliesFeed(generated_at: raw.generated_at, items: items, mails: mails)
    }

    /// GET /time-ledger の答え。種類の無い時間・形の違う週は落とす。新しい週から
    static func decodeLedger(_ data: Data) -> TimeLedgerFeed? {
        guard let raw = try? JSONDecoder().decode(RawLedger.self, from: data), raw.available != false else { return nil }
        var keys = Set<String>()
        var categories: [LedgerCategory] = []
        for row in raw.categories ?? [] {
            guard let c = row.value, let key = MothershipFeeds.cut(c.key, 20), let label = MothershipFeeds.cut(c.label, 30),
                  keys.insert(key).inserted else { continue }
            categories.append(LedgerCategory(key: key, label: label, overlay: c.overlay ?? false))
        }
        if categories.isEmpty { return nil }
        var weeks: [LedgerWeek] = []
        var seen = Set<String>()
        for row in raw.weeks ?? [] {
            guard let w = row.value, MothershipFeeds.isWeek(w.week), let week = w.week, seen.insert(week).inserted else { continue }
            var hours: [String: Double] = [:]
            for key in keys {
                let value: Double = w.hours?[key] ?? 0
                hours[key] = value.isFinite && value >= 0 && value <= 168 ? value : 0
            }
            let covered: Double = min(1, max(0, w.covered ?? 0))
            let from: String? = HomeFeeds.isDay(w.from) ? w.from : nil
            let to: String? = HomeFeeds.isDay(w.to) ? w.to : nil
            weeks.append(LedgerWeek(week: week, from: from, to: to, days: max(0, min(7, w.days ?? 0)), covered: covered,
                                    hours: hours))
        }
        weeks.sort { $0.week > $1.week }
        let kept: [LedgerWeek] = Array(weeks.prefix(weekLimit))
        return TimeLedgerFeed(generated_at: raw.generated_at, method: MothershipFeeds.cut(raw.method, 400) ?? "",
                              categories: categories, weeks: kept)
    }

    /// 「3 時間前から」（last_at から今まで。読めなければ waiting_hours）
    static func waitingText(_ item: ReplyDraft, now: Date = .now) -> String {
        var hours: Int = item.waiting_hours
        if let at = PromiseRules.date(item.last_at) {
            hours = max(0, Int(now.timeIntervalSince(at) / 3600))
        }
        if hours >= 48 { return "\(hours / 24) 日前から" }
        return "\(hours) 時間前から"
    }

    /// 「会議 30.6・ひとり作業 23.6・家 23.8」（重ねる種類と記録なしを除き、多い順に limit まで）
    static func summary(_ week: LedgerWeek, _ categories: [LedgerCategory], limit: Int = 3) -> String {
        var rows: [(label: String, hours: Double)] = []
        for c in categories where !c.overlay && c.key != "unknown" {
            let h: Double = week.hours[c.key] ?? 0
            if h > 0 { rows.append((label: c.label, hours: h)) }
        }
        rows.sort { $0.hours > $1.hours }
        var parts: [String] = []
        for row in rows.prefix(limit) { parts.append(row.label + " " + hoursText(row.hours)) }
        return parts.joined(separator: "・")
    }

    static func hoursText(_ h: Double) -> String {
        String(format: "%.1f 時間", h)
    }

    /// 棒の長さ（その週の日数×24 時間に対する割合）
    static func fraction(_ hours: Double, days: Int) -> Double {
        let total: Double = Double(max(1, days)) * 24
        return min(1, max(0, hours / total))
    }
}

// MARK: - 読み込み

@MainActor
@Observable
final class ActionsBook {
    static let shared = ActionsBook()

    private(set) var replies: RepliesFeed?
    private(set) var ledger: TimeLedgerFeed?
    /// 「返した」にした下書き（この端末だけ）
    private(set) var done: Set<String> = []
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var fetching = false

    private static let every: TimeInterval = 30 * 60
    static let repliesFile = "mfeed-replies.json"
    static let ledgerFile = "mfeed-time-ledger.json"
    static let doneKey = "replyDraftsDone"

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

    init() {
        replies = Self.read(RepliesFeed.self, Self.repliesFile)
        ledger = Self.read(TimeLedgerFeed.self, Self.ledgerFile)
        let saved: [String] = UserDefaults.standard.stringArray(forKey: Self.doneKey) ?? []
        done = Set(saved)
    }

    /// まだ「返した」にしていない返事の下書き
    var openReplies: [ReplyDraft] {
        var out: [ReplyDraft] = []
        for item in replies?.items ?? [] where !done.contains(item.id) { out.append(item) }
        return out
    }

    var openMails: [MailDraft] {
        var out: [MailDraft] = []
        for item in replies?.mails ?? [] where !done.contains(item.id) { out.append(item) }
        return out
    }

    /// 「返した」「送った」（ここで隠すだけ。母艦の側は本人が返すと次の回で消える）
    func markDone(_ id: String) {
        done.insert(id)
        var list: [String] = Array(done)
        if list.count > 200 { list = Array(list.suffix(200)) }
        UserDefaults.standard.set(list, forKey: Self.doneKey)
    }

    /// 読み直す（force でなければ30分に1回まで）。読めなかった写しは前のまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.isConfigured else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        if pc.features.contains("replies"), let body = try? await pc.appFeed("replies", feature: "replies"),
           let feed = ActionFeeds.decodeReplies(body) {
            replies = feed
            Self.write(feed, Self.repliesFile)
        }
        if pc.features.contains("timeledger"), let body = try? await pc.appFeed("time-ledger", feature: "timeledger"),
           let feed = ActionFeeds.decodeLedger(body) {
            ledger = feed
            Self.write(feed, Self.ledgerFile)
        }
    }
}

// MARK: - 画面: 返事の下書き（58 (b)(c)）

/// 「今日」の「返事の下書き」（下書きがあるときだけ）
struct RepliesSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = ActionsBook.shared
        let replies: [ReplyDraft] = book.openReplies
        let mails: [MailDraft] = book.openMails
        Group {
            if !replies.isEmpty || !mails.isEmpty {
                Section {
                    ForEach(replies) { item in
                        ReplyDraftRow(item: item)
                    }
                    ForEach(mails) { mail in
                        MailDraftRow(mail: mail)
                    }
                } header: {
                    Text("返事の下書き（\(replies.count + mails.count)）")
                } footer: {
                    Text("家の PC が、まだ返していないらしい LINE と、送ると言ったメールに下書きを作りました。ここからは何も送りません。写して、自分で直して送ります。「〇〇」は自分で埋めてください。")
                }
            }
        }
        .task { await book.refresh(pipeline.homePC) }
    }
}

struct ReplyDraftRow: View {
    let item: ReplyDraft
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.chat).font(.subheadline.bold())
                Spacer(minLength: 4)
                Text(ActionFeeds.waitingText(item)).font(.caption).foregroundStyle(.secondary)
            }
            if !item.ask.isEmpty {
                Text("「" + item.ask + "」").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Text(item.draft)
                .font(.callout)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            if !item.note.isEmpty {
                Text("送る前に: " + item.note).font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 16) {
                Button(copied ? "写しました" : "写す") {
                    UIPasteboard.general.string = item.draft
                    copied = true
                }
                Button("LINE を開く") {
                    if let url = URL(string: ActionFeeds.lineURL) { openURL(url) }
                }
                Spacer(minLength: 0)
                Button("返した") {
                    withAnimation { ActionsBook.shared.markDone(item.id) }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.vertical, 2)
    }
}

struct MailDraftRow: View {
    let mail: MailDraft
    @State private var copiedSubject = false
    @State private var copiedBody = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("メールの下書き", systemImage: "envelope").font(.caption).foregroundStyle(.secondary)
            Text(mail.subject).font(.subheadline.bold())
            if !mail.to.isEmpty {
                Text("宛先: " + mail.to).font(.caption).foregroundStyle(.secondary)
            }
            Text(mail.body)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(8)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            if !mail.why.isEmpty {
                Text("もとの約束: " + mail.why).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button(copiedSubject ? "件名を写しました" : "件名を写す") {
                    UIPasteboard.general.string = mail.subject
                    copiedSubject = true
                }
                Button(copiedBody ? "本文を写しました" : "本文を写す") {
                    UIPasteboard.general.string = mail.body
                    copiedBody = true
                }
                Spacer(minLength: 0)
                Button("送った") {
                    withAnimation { ActionsBook.shared.markDone(mail.id) }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 画面: 時間の家計簿（60）

/// 「ふり返り」の「時間の家計簿」への入口（写しがあるときだけ）
struct TimeLedgerSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = ActionsBook.shared
        Group {
            if let ledger = book.ledger, let latest = ledger.weeks.first {
                Section {
                    NavigationLink {
                        TimeLedgerView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("時間の家計簿", systemImage: "clock")
                            Text(ActionFeeds.summary(latest, ledger.categories)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("時間")
                }
            }
        }
        .task { await book.refresh(pipeline.homePC) }
    }
}

/// 週ごとの時間の使い道（新しい週から）
struct TimeLedgerView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let ledger: TimeLedgerFeed? = ActionsBook.shared.ledger
        List {
            if let ledger {
                ForEach(ledger.weeks) { week in
                    Section {
                        ForEach(ledger.categories) { c in
                            LedgerRow(category: c, hours: week.hours[c.key] ?? 0, days: week.days)
                        }
                    } header: {
                        Text(weekTitle(week))
                    } footer: {
                        Text(footerText(week))
                    }
                }
                if !ledger.method.isEmpty {
                    Section("数え方") {
                        Text(ledger.method).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("まだ写しがありません。家の PC につながると読みます。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("時間の家計簿")
        .countsOpen("timeLedger")
        .refreshable { await ActionsBook.shared.refresh(pipeline.homePC, force: true) }
    }

    private func footerText(_ week: LedgerWeek) -> String {
        let percent: Int = Int((week.covered * 100).rounded())
        return "年表のある日 \(week.days) 日・記録のある時間 \(percent) パーセント"
    }

    private func weekTitle(_ week: LedgerWeek) -> String {
        guard let from = week.from, let to = week.to else { return week.week }
        return week.week + "（" + String(from.suffix(5)) + "〜" + String(to.suffix(5)) + "）"
    }
}

struct LedgerRow: View {
    let category: LedgerCategory
    let hours: Double
    let days: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(category.label, value: valueText)
                .font(.callout)
            if !category.overlay {
                ProgressView(value: ActionFeeds.fraction(hours, days: days))
                    .tint(category.key == "unknown" ? Color.gray : Color.accentColor)
            }
        }
    }

    private var valueText: String {
        if category.key == "iphone" { return "\(Int(hours.rounded())) 時間帯" }
        return ActionFeeds.hoursText(hours)
    }
}

// MARK: - 見本（CI の画面の写真）

#if DEBUG && targetEnvironment(simulator)  // DemoData はこの条件のときだけある（DemoData.swift）
extension DemoData {
    /// 返事の下書き・メールの下書き・時間の家計簿の見本（2026-11-15。名前・文・時間はすべて作り物）。
    /// 長いクロージャの式は CI が落ちるので、明示的なループと型で書く
    static func installActions(base: URL, now: Date, day: String) {
        let encoder = JSONEncoder()
        let stamp: String = MothershipOutbox.isoString(now)
        let lastAt: String = MothershipOutbox.isoString(now.addingTimeInterval(-5 * 3600))
        let reply = ReplyDraft(id: "demo-reply-1", chat: "見本 花子", who: "見本 花子", last_at: lastAt, waiting_hours: 5,
                               ask: "来週の食事、何曜日なら空いてる？",
                               draft: "連絡ありがとう！来週は〇〇曜日なら空いてるよ。お店はどこがいい？",
                               note: "空いている曜日を入れる")
        let mail = MailDraft(id: "demo-mail-1", to: "見本 商事 ご担当者さま", subject: "お見積もりの送付（見本）",
                             body: "いつもお世話になっております。\n先日お話しした件のお見積もりをお送りします。\n金額は〇〇円です。\nどうぞよろしくお願いいたします。",
                             why: "見積もりをメールで送る（見本）", day: day)
        let replies = RepliesFeed(generated_at: stamp, items: [reply], mails: [mail])
        if let data = try? encoder.encode(replies) {
            try? data.write(to: base.appendingPathComponent(ActionsBook.repliesFile), options: .atomic)
        }
        let keys: [String] = ["meeting", "work_solo", "move", "home", "eat_out", "people", "out_other", "sleep", "unknown",
                              "pc", "iphone"]
        let labels: [String] = ["仕事の会議", "仕事のひとり作業", "移動", "家", "外食", "人と会う", "外のそのほか",
                                "睡眠（上限の目安）", "記録なし", "PC（重なってよい）", "iPhone を使った時間帯（数）"]
        let values: [Double] = [12.5, 26.0, 6.5, 30.0, 3.5, 6.0, 2.0, 42.0, 39.5, 14.0, 20.0]
        var categories: [LedgerCategory] = []
        var hours: [String: Double] = [:]
        for i in 0..<keys.count {
            categories.append(LedgerCategory(key: keys[i], label: labels[i], overlay: i >= 9))
            hours[keys[i]] = values[i]
        }
        let week = LedgerWeek(week: "2026-W46", from: "2026-11-09", to: "2026-11-15", days: 7, covered: 0.76, hours: hours)
        let ledger = TimeLedgerFeed(generated_at: stamp, method: "1日の年表を1分ずつに分けて数えた見本です。", categories: categories,
                                    weeks: [week])
        if let data = try? encoder.encode(ledger) {
            try? data.write(to: base.appendingPathComponent(ActionsBook.ledgerFile), options: .atomic)
        }
    }
}
#endif

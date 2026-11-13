import Foundation
import Observation
import SwiftUI
import UserNotifications

// MARK: - 会話のあとの約束（施策 13。2026-11-13。実機では未確認）
//
// 家の PC が、会話が終わって10分ほどで、その会話から約束・頼まれごとだけを Claude で拾い、目に見える通知（カテゴリ "promise"）で知らせる
// （中身は pc/promises.py）。通知の「タスクに入れる」「いらない」か、「今日」の「会話のあとの約束」で答える。
// - 「タスクに入れる」は、手で書いたタスクと同じ足し方（TaskBook.add。同じらしいものがあれば足さない）で、はじめから帳に入れる。
// - どちらの答えも母艦に返す（POST /feedback の kind "promise"・value added|ignored）。届かなければ、ためて次に送る。
// - 通知を見逃しても、アプリを開くと GET /promises-now（36時間ぶん）から出す。答えたもの・同じらしいタスクがあるものは出さない。
// - 設定（「会話のあとに約束を知らせる」・「通知に中身を出さない」と、Claude の2つのスイッチ）は POST /promises/settings で家の PC に渡す。
//   家の PC は、アプリから設定が届くまで何もしない。

/// 家の PC が拾った約束1つ（GET /promises-now の items の1つ）
struct PromiseItem: Codable, Identifiable, Equatable {
    var id: String
    var day: String
    var conversationStart: String?
    var saidAt: String?
    /// asked（頼まれた）・promised（約束）・delegated（頼んだ）
    var kind: String
    var who: String
    var what: String
    var due: String
    var quote: String
    var work: Bool?
    var createdAt: String?
    var alerted: Bool

    enum CodingKeys: String, CodingKey {
        case id, day, kind, who, what, due, quote, work, alerted
        case conversationStart = "conversation_start"
        case saidAt = "said_at"
        case createdAt = "created_at"
    }

    init(id: String, day: String, kind: String, who: String, what: String, due: String = "", quote: String = "",
         saidAt: String? = nil, conversationStart: String? = nil, work: Bool? = nil, createdAt: String? = nil,
         alerted: Bool = true) {
        self.id = id
        self.day = day
        self.kind = kind
        self.who = who
        self.what = what
        self.due = due
        self.quote = quote
        self.saidAt = saidAt
        self.conversationStart = conversationStart
        self.work = work
        self.createdAt = createdAt
        self.alerted = alerted
    }

    /// 読めない欄は空にする（id と what が無いものは読まない）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        what = try c.decode(String.self, forKey: .what)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "asked"
        who = (try? c.decodeIfPresent(String.self, forKey: .who)) ?? ""
        due = (try? c.decodeIfPresent(String.self, forKey: .due)) ?? ""
        quote = (try? c.decodeIfPresent(String.self, forKey: .quote)) ?? ""
        conversationStart = try? c.decodeIfPresent(String.self, forKey: .conversationStart)
        saidAt = try? c.decodeIfPresent(String.self, forKey: .saidAt)
        work = try? c.decodeIfPresent(Bool.self, forKey: .work)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        alerted = (try? c.decodeIfPresent(Bool.self, forKey: .alerted)) ?? false
    }

    var kindLabel: String {
        switch kind {
        case "promised": "約束"
        case "delegated": "頼んだ"
        default: "頼まれた"
        }
    }

    /// 「見本 花子と・金曜まで」のような添え書き（無ければ空）
    var note: String {
        var parts: [String] = []
        if !who.isEmpty { parts.append(kind == "delegated" ? who + "へ" : who + "と") }
        if !due.isEmpty { parts.append(due) }
        return parts.joined(separator: "・")
    }
}

/// GET /promises-now の答え
struct PromisesFeed: Codable, Equatable {
    var available: Bool
    var on: Bool?
    var generatedAt: String?
    var items: [PromiseItem]
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case available, on, items, reason
        case generatedAt = "generated_at"
    }

    init(available: Bool, on: Bool? = nil, generatedAt: String? = nil, items: [PromiseItem], reason: String? = nil) {
        self.available = available
        self.on = on
        self.generatedAt = generatedAt
        self.items = items
        self.reason = reason
    }

    /// 読めない行は飛ばす（1つおかしくても、ほかは出す）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        on = try? c.decodeIfPresent(Bool.self, forKey: .on)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        var list: [PromiseItem] = []
        if var rows = try? c.nestedUnkeyedContainer(forKey: .items) {
            while !rows.isAtEnd {
                if let item = try? rows.decode(PromiseItem.self) {
                    list.append(item)
                } else if (try? rows.decode(PromiseSkipRow.self)) == nil {
                    break
                }
            }
        }
        items = list
    }
}

/// 読めない行を読み捨てる（どんな値でも読めたことにして、次の行に進む。Promises.swift・AskMothership.swift）
struct PromiseSkipRow: Decodable {
    init(from decoder: Decoder) throws {}
}

/// 約束の決まり（画面を持たない。テストで確かめる）
enum PromiseRules {
    /// 家の PC が知らせる働きの名前（GET /promises-now・POST /promises/settings）
    static let feature = "promisesnow"
    /// 通知のカテゴリ（家の PC の apns.py の PROMISE_CATEGORY と同じ）
    static let category = "promise"
    /// 「会話のあとに約束を知らせる」（初めはオン）
    static let onKey = "promiseNoticeOn"
    /// 「通知に中身を出さない」（初めはオフ）
    static let hideKey = "promiseHideBody"
    static let cacheFile = "app-feed-promises.json"

    static var isOn: Bool { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
    static var hideBody: Bool { UserDefaults.standard.bool(forKey: hideKey) }

    /// 通知のボタン（名前は NoticeActions の keep・reject と同じ。押したときの動きは Pipeline.handlePromiseNotice）
    static func actions() -> [UNNotificationAction] {
        let keep = UNNotificationAction(identifier: NoticeActions.Action.keep.rawValue, title: "タスクに入れる", options: [])
        let reject = UNNotificationAction(identifier: NoticeActions.Action.reject.rawValue, title: "いらない", options: [.destructive])
        return [keep, reject]
    }

    static func notificationCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: actions(), intentIdentifiers: [], options: [])
    }

    static func decode(_ data: Data) -> PromisesFeed? {
        guard let feed = try? JSONDecoder().decode(PromisesFeed.self, from: data), feed.available else { return nil }
        return feed
    }

    /// 出すもの: 答えていないもの、同じらしいタスク（同じ日のもの・まだ済んでいないもの）が無いもの。新しい順
    static func visible(_ items: [PromiseItem], answered: Set<String>, tasks: [TaskBook.Item]) -> [PromiseItem] {
        var out: [PromiseItem] = []
        for item in items where !answered.contains(item.id) {
            var duplicate = false
            for task in tasks {
                let live: Bool = task.state == .candidate || task.state == .open
                if (live || task.day == item.day) && TaskBook.similar(task.what, item.what) {
                    duplicate = true
                    break
                }
            }
            if !duplicate { out.append(item) }
        }
        return out
    }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// タスクに入れる形（本人が「入れる」と決めたので、はじめから帳に入れる）
    static func taskItem(_ p: PromiseItem, work: Bool, now: Date = .now) -> TaskBook.Item {
        let kind: TaskBook.Kind
        switch p.kind {
        case "promised": kind = .promise
        case "delegated": kind = .delegated
        default: kind = .asked
        }
        let said: Date = date(p.saidAt) ?? now
        let quote: String? = p.quote.isEmpty ? nil : p.quote
        return TaskBook.Item(what: p.what, from: p.who.isEmpty ? nil : p.who, dueText: TaskBook.cleanDue(p.due),
                             said: said, day: p.day.isEmpty ? nil : p.day, quote: quote, source: .conversation,
                             state: .open, work: p.work ?? work, kind: kind)
    }

    /// POST /promises/settings の中身
    static func settingsBody(on: Bool, claude: Bool, work: Bool, hide: Bool, device: String) -> Data? {
        let body: [String: Any] = ["on": on, "claude": claude, "work": work, "hide_body": hide, "device": device]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// POST /feedback の中身（家の PC の appfeeds.py。決まりは「施策 1〜22 の共通の約束」）
    static func feedbackBody(id: String, added: Bool, day: String) -> Data? {
        let body: [String: Any] = ["kind": "promise", "id": String(id.prefix(64)), "value": added ? "added" : "ignored", "day": day]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// 母艦に返す答えをためておく所。
/// TODO: 担当 S1 の MothershipFeeds.swift（POST /feedback をまとめて送る仕組み）が main に入ったら、そちらに渡してこれは消す。
/// 中身の形は同じ（{"kind","id","value","day"}）。家の PC が "feedback" を知らせるまでは送らずにためる（200 件まで）。
enum PromiseFeedbackQueue {
    private static let key = "promiseFeedbackQueue"
    private static let limit = 200

    static var pending: [Data] { UserDefaults.standard.array(forKey: key) as? [Data] ?? [] }

    static func add(_ body: Data) {
        let list: [Data] = Array((pending + [body]).suffix(limit))
        UserDefaults.standard.set(list, forKey: key)
    }

    /// 古い順に送る。1つでも送れなければ、そこでやめる
    @MainActor private static var flushing = false

    @MainActor
    static func flush(_ pc: HomePC) async {
        guard !flushing, pc.features.contains("feedback") else { return }
        flushing = true
        defer { flushing = false }
        var list: [Data] = pending
        while let first = list.first {
            do {
                _ = try await pc.postJSONData("feedback", body: first, timeout: 10)
            } catch {
                break
            }
            // 送っている間に足されたものを消さないよう、読み直してから外す
            var current: [Data] = pending
            if current.first == first { current.removeFirst() }
            UserDefaults.standard.set(current, forKey: key)
            list = current
        }
    }
}

// MARK: - 読み込みと答え

@MainActor
@Observable
final class PromiseInbox {
    static let shared = PromiseInbox()

    private(set) var items: [PromiseItem] = []
    /// 答えたもの（id → added / ignored）
    private(set) var answered: [String: String] = [:]
    /// 知らせが届いたときに増やす（「今日」の欄が読み直す）
    private(set) var wake = 0
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var fetching = false

    private static let answeredKey = "promiseAnswered"
    /// 知らせのボタンを押したが、まだ中身を読めていないもの（id → added / ignored）
    private static let wantedKey = "promiseWanted"
    private static let settingsStampKey = "promiseSettingsSent"
    private static let settingsAtKey = "promiseSettingsSentAt"
    private static let every: TimeInterval = 5 * 60
    private static let answeredLimit = 500

    private static var cacheURL: URL { URL.applicationSupportDirectory.appendingPathComponent(PromiseRules.cacheFile) }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let feed = try? JSONDecoder().decode(PromisesFeed.self, from: data) {
            items = feed.items
        }
        answered = UserDefaults.standard.dictionary(forKey: Self.answeredKey) as? [String: String] ?? [:]
    }

    func poke() {
        fetchedAt = nil
        wake += 1
    }

    func visible(tasks: [TaskBook.Item]) -> [PromiseItem] {
        PromiseRules.visible(items, answered: Set(answered.keys), tasks: tasks)
    }

    /// 家の PC から読み直す（force でなければ5分に1回まで）。設定も渡す。読めなければ前のまま
    func refresh(_ pipeline: Pipeline, force: Bool = false) async {
        let pc: HomePC = pipeline.homePC
        guard !fetching, pc.features.contains(PromiseRules.feature) else { return }
        await syncSettings(pc)
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every {
            await PromiseFeedbackQueue.flush(pc)
            return
        }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        if let data = try? await pc.appFeed("promises-now", feature: PromiseRules.feature),
           let feed = PromiseRules.decode(data) {
            items = feed.items
            if let encoded = try? JSONEncoder().encode(feed) { try? encoded.write(to: Self.cacheURL, options: .atomic) }
        }
        applyWanted(pipeline)
        await PromiseFeedbackQueue.flush(pc)
    }

    /// 設定を家の PC に渡す（変わったときと、12時間に1回）
    func syncSettings(_ pc: HomePC, force: Bool = false) async {
        guard pc.features.contains(PromiseRules.feature) else { return }
        let on: Bool = PromiseRules.isOn
        let claudeOn: Bool = ClaudeRoute.useClaude
        let work: Bool = ClaudeRoute.forWork
        let hide: Bool = PromiseRules.hideBody
        let stamp: String = "\(on)|\(claudeOn)|\(work)|\(hide)"
        let last: Date = UserDefaults.standard.object(forKey: Self.settingsAtKey) as? Date ?? .distantPast
        if !force, UserDefaults.standard.string(forKey: Self.settingsStampKey) == stamp, Date.now.timeIntervalSince(last) < 12 * 3600 {
            return
        }
        guard let body = PromiseRules.settingsBody(on: on, claude: claudeOn, work: work, hide: hide, device: PCDiag.deviceID) else { return }
        do {
            _ = try await pc.postJSONData("promises/settings", body: body, timeout: 10)
            UserDefaults.standard.set(stamp, forKey: Self.settingsStampKey)
            UserDefaults.standard.set(Date.now, forKey: Self.settingsAtKey)
        } catch {
            // 届かなければ次に読むときにもう一度
        }
    }

    /// 答える。add ならタスクに入れる。画面に出す一文を返す
    @discardableResult
    func answer(_ item: PromiseItem, add: Bool, pipeline: Pipeline) -> String {
        var note: String = "いらない にしました。"
        if add {
            let task: TaskBook.Item = PromiseRules.taskItem(item, work: pipeline.taskTime(PromiseRules.date(item.saidAt) ?? .now))
            if pipeline.tasks.add([task]).isEmpty {
                note = "同じらしいタスクがもうあるので、足しませんでした。"
            } else {
                pipeline.tasksChanged()
                note = "タスクに「\(item.what)」を入れました。"
            }
            Tally.add("promise.added")
        } else {
            Tally.add("promise.ignored")
        }
        remember(item.id, add ? "added" : "ignored")
        if let body = PromiseRules.feedbackBody(id: item.id, added: add, day: item.day) {
            PromiseFeedbackQueue.add(body)
        }
        let pc: HomePC = pipeline.homePC
        Task { await PromiseFeedbackQueue.flush(pc) }
        return note
    }

    /// 知らせのボタンから（中身をまだ読めていなければ、読んでから答える）
    func answer(ids: [String], add: Bool, pipeline: Pipeline) {
        var wanted: [String: String] = UserDefaults.standard.dictionary(forKey: Self.wantedKey) as? [String: String] ?? [:]
        for id in ids where answered[id] == nil {
            wanted[id] = add ? "added" : "ignored"
        }
        UserDefaults.standard.set(wanted, forKey: Self.wantedKey)
        applyWanted(pipeline)
        if !(UserDefaults.standard.dictionary(forKey: Self.wantedKey) ?? [:]).isEmpty {
            Task { await refresh(pipeline, force: true) }
        }
    }

    private func applyWanted(_ pipeline: Pipeline) {
        var wanted: [String: String] = UserDefaults.standard.dictionary(forKey: Self.wantedKey) as? [String: String] ?? [:]
        guard !wanted.isEmpty else { return }
        for item in items {
            guard let value = wanted[item.id] else { continue }
            if answered[item.id] == nil { answer(item, add: value == "added", pipeline: pipeline) }
            wanted.removeValue(forKey: item.id)
        }
        // 読めた一覧に無いもの（36時間を過ぎたもの）は、あきらめる
        if fetchedAt != nil {
            let known: Set<String> = Set(items.map(\.id))
            wanted = wanted.filter { known.contains($0.key) }
        }
        UserDefaults.standard.set(wanted, forKey: Self.wantedKey)
    }

    private func remember(_ id: String, _ value: String) {
        answered[id] = value
        if answered.count > Self.answeredLimit {
            // いま出ているものの答えを優先して残す
            let live: Set<String> = Set(items.map(\.id))
            answered = answered.filter { live.contains($0.key) }
        }
        UserDefaults.standard.set(answered, forKey: Self.answeredKey)
    }
}

extension Pipeline {
    /// 約束の知らせのボタン・知らせそのものを押したとき（NoticeActions.swift の handleNotices から）
    func handlePromiseNotice(_ p: NoticeActions.Pending) {
        switch p.action {
        case .keep:
            PromiseInbox.shared.answer(ids: p.ids, add: true, pipeline: self)
        case .reject:
            PromiseInbox.shared.answer(ids: p.ids, add: false, pipeline: self)
        default:
            PromiseInbox.shared.poke()
            openRoute(.tab(.today))
        }
    }
}

// MARK: - 画面

/// 「今日」の「会話のあとの約束」。まだ答えていないものがあるときだけ出す
struct PromisesSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var note: String?

    var body: some View {
        let inbox: PromiseInbox = PromiseInbox.shared
        let open: [PromiseItem] = inbox.visible(tasks: pipeline.tasks.items)
        Group {
            if !open.isEmpty || note != nil {
                Section {
                    ForEach(Array(open.prefix(5))) { item in
                        PromiseRow(item: item) { add in
                            withAnimation { note = inbox.answer(item, add: add, pipeline: pipeline) }
                        }
                    }
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(open.isEmpty ? "会話のあとの約束" : "会話のあとの約束（\(open.count)）")
                } footer: {
                    Text("会話が終わって10分ほどで、家の PC が見つけた約束・頼まれごとです。押すまでタスクには入りません。")
                }
            }
        }
        .task(id: inbox.wake) { await inbox.refresh(pipeline) }
    }
}

/// 約束1つと「タスクに入れる」「いらない」
struct PromiseRow: View {
    let item: PromiseItem
    var onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.kindLabel).font(.caption).foregroundStyle(.secondary)
                Text(item.what).font(.body)
            }
            if !item.note.isEmpty {
                Text(item.note).font(.caption).foregroundStyle(.secondary)
            }
            if !item.quote.isEmpty {
                Text("「\(item.quote)」").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 20) {
                Button("タスクに入れる") { onAnswer(true) }
                    .buttonStyle(.borderedProminent)
                Button("いらない") { onAnswer(false) }
                    .buttonStyle(.bordered)
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
    }
}

/// 設定の「会話のあとの約束」への入口（設定の画面に1行で置く）
struct PromiseSettingsLink: View {
    var body: some View {
        Section {
            NavigationLink("会話のあとの約束") { PromiseSettingsView() }
        }
    }
}

/// 「会話のあとに約束を知らせる」と「通知に中身を出さない」
struct PromiseSettingsView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(PromiseRules.onKey) private var on = true
    @AppStorage(PromiseRules.hideKey) private var hide = false
    @AppStorage(ClaudeRoute.useKey) private var useClaude = true
    @AppStorage(ClaudeRoute.workKey) private var forWork = true

    var body: some View {
        Form {
            Section {
                Toggle("会話のあとに約束を知らせる", isOn: $on)
                Toggle("通知に中身を出さない", isOn: $hide)
                    .disabled(!on)
                LabeledContent("家の PC", value: pipeline.homePC.features.contains(PromiseRules.feature) ? "使える" : "まだ使えない")
                if !useClaude {
                    Text("「Claude を使う」がオフなので、家の PC は約束を探しません。").font(.caption).foregroundStyle(.secondary)
                } else if !forWork {
                    Text("「職場の会話も Claude で」がオフなので、職場の会話（と、職場か分からない会話）からは探しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("会話が終わって10分ほどで、家の PC がその会話から約束・頼まれごとだけを Claude（軽いモデル）で探し、通知で知らせます。通知の「タスクに入れる」でタスクに入り、「いらない」で消えます。見逃しても「今日」に出ます。通知は1日6回・10分に1回までです。\n「通知に中身を出さない」をオンにすると、通知には件数だけを出します（ロック画面に相手の名前やすることを出したくないとき）。iPhone の「設定」→「通知」→「プレビューを表示」を「ロックされていないときのみ」にしても、ロック画面では隠れます。")
            }
        }
        .navigationTitle("会話のあとの約束")
        .onChange(of: on) { _, _ in sync() }
        .onChange(of: hide) { _, _ in sync() }
        .task { await PromiseInbox.shared.syncSettings(pipeline.homePC) }
    }

    private func sync() {
        let pc: HomePC = pipeline.homePC
        Task { await PromiseInbox.shared.syncSettings(pc, force: true) }
    }
}

#if DEBUG && targetEnvironment(simulator)
extension DemoData {
    /// 「今日」の「会話のあとの約束」の見本（名前・中身はすべて作り物）
    static func installPromises(base: URL, now: Date, day: String, talkStart: Date) {
        let iso = ISO8601DateFormatter()
        var list: [PromiseItem] = []
        let first = PromiseItem(id: "demo-promise-1", day: day, kind: "promised", who: "見本 花子", what: "見本の見積もりを送る",
                                due: "金曜まで", quote: "金曜までに見積もりを送りますね",
                                saidAt: iso.string(from: talkStart.addingTimeInterval(20)), work: true,
                                createdAt: iso.string(from: now.addingTimeInterval(-300)))
        list.append(first)
        let second = PromiseItem(id: "demo-promise-2", day: day, kind: "asked", who: "", what: "見本の書類に目を通す",
                                 quote: "書類を見ておいてもらえますか",
                                 saidAt: iso.string(from: talkStart.addingTimeInterval(40)), work: true,
                                 createdAt: iso.string(from: now.addingTimeInterval(-240)))
        list.append(second)
        let feed = PromisesFeed(available: true, on: true, generatedAt: iso.string(from: now), items: list)
        if let data = try? JSONEncoder().encode(feed) {
            try? data.write(to: base.appendingPathComponent(PromiseRules.cacheFile), options: .atomic)
        }
    }
}
#endif

import Foundation
import UserNotifications

/// 知らせのボタンと、押したときの動き（2026-11-10）。
/// 「頼まれごとを見つけました」には「入れる」「違う」「2時間後にもう一度」、
/// 「期限の1時間前」には「済み」「1時間後にもう一度」「明日に」を付ける（アプリを開かずに片づける）。
/// 知らせそのものを押したときは、その知らせに合う画面を開く（頼まれごと帳・仕事のまとめの取り込み。2026-11-12 からほかの知らせも）。
/// 押されたものは、いったん UserDefaults にためてから Pipeline に渡す（アプリの準備ができる前に押されても落とさない）。
enum NoticeActions {
    /// 「頼まれごとを見つけました」
    static let foundCategory = "taskFound"
    /// 「もうすぐ期限です」（期限に時刻があるものの1時間前）
    static let dueCategory = "taskDue"
    /// 「今日のまとめを取り込みましたか」（退勤の頃）
    static let digestCategory = "workDigest"
    /// 期限の1時間前の知らせの名前の頭（朝夕の知らせと同じ「tasks-」で始めるので、頼み直すときにいっしょに消える）
    static let duePrefix = "tasks-due-"

    enum Action: String, Codable {
        /// 知らせそのものを押した
        case open
        case keep, reject, later
        case done, hour, tomorrow
    }

    /// 押されたもの
    struct Pending: Codable, Equatable {
        var action: Action
        var ids: [String]
        var identifier: String
        var title: String
        var body: String
        var category: String
        var at: Date = .now
    }

    private static let pendingKey = "noticeActions.pending"

    /// Pipeline が受け取る
    @MainActor static var handler: (@MainActor ([Pending]) -> Void)?

    static func categories() -> Set<UNNotificationCategory> {
        let keep = UNNotificationAction(identifier: Action.keep.rawValue, title: "入れる", options: [])
        let reject = UNNotificationAction(identifier: Action.reject.rawValue, title: "違う", options: [.destructive])
        let later = UNNotificationAction(identifier: Action.later.rawValue, title: "2時間後にもう一度", options: [])
        let done = UNNotificationAction(identifier: Action.done.rawValue, title: "済み", options: [])
        let hour = UNNotificationAction(identifier: Action.hour.rawValue, title: "1時間後にもう一度", options: [])
        let tomorrow = UNNotificationAction(identifier: Action.tomorrow.rawValue, title: "明日に", options: [])
        return [
            UNNotificationCategory(identifier: foundCategory, actions: [keep, reject, later], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: dueCategory, actions: [done, hour, tomorrow], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: digestCategory, actions: [], intentIdentifiers: [], options: []),
            // 会話のあとの約束（家の PC から届く。2026-11-13。Promises.swift）
            PromiseRules.notificationCategory(),
        ]
    }

    /// 押されたボタンの名前から、動きを決める（知らせそのものを押したときは open。分からないものは nil）
    static func action(for identifier: String) -> Action? {
        if identifier == UNNotificationDefaultActionIdentifier { return .open }
        return Action(rawValue: identifier)
    }

    /// 押されたものを受け取って、ためた分といっしょに Pipeline に渡す
    @MainActor static func receive(_ pending: Pending) {
        var list = load()
        list.append(pending)
        save(list)
        drain()
    }

    /// たまっている分を Pipeline に渡す（Pipeline がまだなら、ためたまま）
    @MainActor static func drain() {
        guard let handler else { return }
        let list = load()
        guard !list.isEmpty else { return }
        save([])
        handler(list)
    }

    private static func load() -> [Pending] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    private static func save(_ list: [Pending]) {
        // ためすぎない（何かの間違いで受け取り手が無いままでも、50件まで）
        let kept: [Pending] = Array(list.suffix(50))
        if kept.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingKey)
        } else if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }
}

/// 知らせを出した数・押された数（2026-11-10）。知らせが役に立っているかを、数で見る。
/// 端末の中（UserDefaults）だけに置く。中身（頼まれごとの文）は残さない
enum NoticeStats {
    private static let key = "noticeStats"

    /// 知らせの種類（category）と、できごと（"sent" か、Action の名前）を1つ数える
    static func count(_ category: String, _ event: String) {
        var all = values
        all[category + "|" + event, default: 0] += 1
        UserDefaults.standard.set(all, forKey: key)
    }

    /// 頼み直すたびに数えないよう、同じもの（key）は1回だけ「出した」と数える（期限の1時間前の知らせ）
    static func countOnce(_ category: String, key: String) {
        var seen: [String] = UserDefaults.standard.stringArray(forKey: Self.key + ".seen") ?? []
        guard !seen.contains(key) else { return }
        seen.append(key)
        UserDefaults.standard.set(Array(seen.suffix(200)), forKey: Self.key + ".seen")
        count(category, "sent")
    }

    static var values: [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    static func value(_ category: String, _ event: String) -> Int {
        values[category + "|" + event] ?? 0
    }

    /// 画面に出す行（種類ごとに、出した数・開いた数・ボタンを押した数）
    struct Row: Identifiable, Equatable {
        var title: String
        var sent: Int
        var opened: Int
        var buttons: Int
        var id: String { title }
    }

    static func rows() -> [Row] {
        let kinds: [(category: String, title: String)] = [(NoticeActions.foundCategory, "頼まれごとを見つけました"),
                                                          (NoticeActions.dueCategory, "もうすぐ期限です"),
                                                          (NoticeActions.digestCategory, "仕事のまとめ（退勤の頃）")]
        let buttons: [NoticeActions.Action] = [.keep, .reject, .later, .done, .hour, .tomorrow]
        return kinds.map { kind in
            let pressed: Int = buttons.reduce(0) { $0 + value(kind.category, $1.rawValue) }
            return Row(title: kind.title, sent: value(kind.category, "sent"),
                       opened: value(kind.category, NoticeActions.Action.open.rawValue), buttons: pressed)
        }
    }
}

/// 下のタブ（2026-11-12。前は 今日・タスク・ライブ・記録・人と場所）
enum AppTab: String, Hashable, CaseIterable {
    case today, tasks, fix, records, lookBack
}

/// 知らせ・ウィジェットから開く画面のうち、シートで開くもの（2026-11-12）
enum NoticeScreen: String, Equatable {
    case questions, goodThings, money, cloudLog, reviewNudge, diagnostics, homePC
    /// 家の PC からの提案（2026-11-13。HomeFeeds.swift）
    case proposals
}

/// 知らせを押したときに開く画面（2026-11-10。2026-11-12 からタスク以外の知らせも、その画面を開く）
enum NoticeRoute: Identifiable, Equatable {
    /// 下のタブを切り替える（シートは開かない）
    case tab(AppTab)
    /// 仕事のまとめを取り込む画面（文があれば、はじめから入れておく）
    case digestImport(String)
    /// その知らせに合う画面をシートで開く
    case screen(NoticeScreen)
    /// 知らせの文をそのまま読み直す（会う前の1枚。消えても読み返せるように）
    case note(title: String, body: String)

    var id: String {
        switch self {
        case .tab(let t): "tab-" + t.rawValue
        case .digestImport: "digestImport"
        case .screen(let s): "screen-" + s.rawValue
        case .note(let title, _): "note-" + title
        }
    }

    /// 知らせの名前（identifier）から、押したときに開く画面を決める。分からないものは nil（アプリを開くだけ）。
    /// 名前は各ファイルで知らせを頼むときのもの（AskBook・GoodMore・Payments・CloudLog・CaptureSafety・Pipeline・Provisioning など）
    static func route(identifier id: String, title: String, body: String) -> NoticeRoute? {
        if id.hasPrefix("tasks-") || id == NoticePresenter.taskFoundID { return .tab(.tasks) }
        if id.hasPrefix("brief-") { return .note(title: title, body: body) }
        if id.hasPrefix(AppFeeds.noticePrefix) || id.hasPrefix("signExpiry-") { return .tab(.today) }
        if id.hasPrefix(ProposalRules.noticePrefix) { return .screen(.proposals) }
        switch id {
        case MorningBrief.noticeID, "watch-silent", "phone-stopped", "watch-battery", "stall",
             "watch-open-after-update", "watch-not-recording":
            return .tab(.today)
        case "askQuestions": return .screen(.questions)
        case "good-tonight": return .screen(.goodThings)
        case "payments-monthly": return .screen(.money)
        case "cloud-monthly": return .screen(.cloudLog)
        case "review-nudge": return .screen(.reviewNudge)
        case "morning-check": return .screen(.diagnostics)
        // 家の PC と 6 時間やり取りできていない（2026-11-15。PCSilence.swift）
        case "home-pc", PCSilence.noticeID: return .screen(.homePC)
        // 1時間に3通を超えてまとめた知らせ（2026-11-15。NoticeGate.swift）
        case NoticeBundle.bundleID: return .tab(.today)
        case "work-digest-reminder": return .digestImport("")
        default: return nil
        }
    }

    /// ウィジェットの lifelog:// の住所から（lifelog://tasks など）
    static func route(url: URL) -> NoticeRoute? {
        guard url.scheme == "lifelog" else { return nil }
        switch url.host() ?? "" {
        case "tasks": return .tab(.tasks)
        case "fix": return .tab(.fix)
        case "records": return .tab(.records)
        case "lookback": return .tab(.lookBack)
        case "good": return .screen(.goodThings)
        default: return .tab(.today)
        }
    }

    /// 知らせを数えるときの種類（カテゴリの無い知らせは、名前の頭で数える）
    static func kind(of id: String) -> String {
        for prefix in ["tasks-", "brief-", "signExpiry-", AppFeeds.noticePrefix, ProposalRules.noticePrefix] where id.hasPrefix(prefix) { return prefix }
        return id
    }
}

extension Pipeline {
    /// 知らせのボタン・知らせそのものを押されたときの動き
    func handleNotices(_ list: [NoticeActions.Pending]) {
        var changed = false
        for p in list {
            NoticeStats.count(p.category.isEmpty ? NoticeRoute.kind(of: p.identifier) : p.category, p.action.rawValue)
            // 会話のあとの約束は ids が約束の id（タスクの id ではない）。2026-11-13。Promises.swift
            if p.category == PromiseRules.category {
                handlePromiseNotice(p)
                continue
            }
            switch p.action {
            case .open:
                if p.category == NoticeActions.digestCategory {
                    openRoute(.digestImport(""))
                } else if p.category.isEmpty {
                    if let route = NoticeRoute.route(identifier: p.identifier, title: p.title, body: p.body) { openRoute(route) }
                } else {
                    openRoute(.tab(.tasks))
                }
            case .keep:
                for id in p.ids where tasks.items.first(where: { $0.id == id })?.state == .candidate {
                    tasks.set(id, .open)
                    changed = true
                }
            case .reject:
                for id in p.ids {
                    guard let state = tasks.items.first(where: { $0.id == id })?.state,
                          state == .candidate || state == .open else { continue }
                    tasks.reject(id, reason: .notice)
                    changed = true
                }
            case .later:
                Self.repost(p, after: 2 * 3600)
            case .done:
                for id in p.ids where tasks.items.first(where: { $0.id == id })?.state == .open {
                    tasks.set(id, .done)
                    changed = true
                }
            case .hour:
                Self.repost(p, after: 3600)
            case .tomorrow:
                for id in p.ids where tasks.items.first(where: { $0.id == id })?.state == .open {
                    tasks.postpone(id, days: 1)
                    changed = true
                }
            }
        }
        if changed { tasksChanged() }
    }

    /// 知らせ・ウィジェットから画面を開く（タブはタブを切り替え、ほかはシートで開く）
    func openRoute(_ route: NoticeRoute) {
        if case .tab(let t) = route {
            noticeRoute = nil
            tab = t
        } else {
            noticeRoute = route
        }
    }

    /// 同じ知らせを、少したってから出し直す
    static func repost(_ p: NoticeActions.Pending, after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = p.title
        content.body = p.body
        content.sound = .default
        content.categoryIdentifier = p.category
        content.userInfo = ["ids": p.ids]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: p.identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
    }
}

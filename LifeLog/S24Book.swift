import Foundation
import UserNotifications

// s24（2026-11-24）の動き。決まりは S24Rules.swift、画面は S24Views.swift。
// - 知らせの入口（NoticeGate.add のあと・直に頼む所）: 問いの全体の上限（減1）・知らせ全体の上限（減7）・「今週は聞かないで」（減10）・
//   時計を震わせない（形6）・題の印（形7）
// - 見つけた頼まれごとを夜の 1 通に（減6）・開いた数（減8）・今日の候補（本人の困りごと）

// MARK: - 知らせの入口

enum S24Gate {
    private static let lock = NSLock()
    private static let countKey = "s24.dayCounts"

    /// 今日すでに出した問いの数と、別枠でない知らせの数（"yyyy-MM-dd|問い|知らせ"）
    static func counts(now: Date = .now) -> (asked: Int, shown: Int) {
        lock.withLock { read(day: ReviewRules.dayKey(now)) }
    }

    private static func read(day: String) -> (asked: Int, shown: Int) {
        let parts = (UserDefaults.standard.string(forKey: countKey) ?? "").split(separator: "|").map(String.init)
        guard parts.count == 3, parts[0] == day else { return (0, 0) }
        return (Int(parts[1]) ?? 0, Int(parts[2]) ?? 0)
    }

    private static func write(day: String, asked: Int, shown: Int) {
        UserDefaults.standard.set(day + "|" + String(asked) + "|" + String(shown), forKey: countKey)
    }

    /// 入口で決めて、出してよければ数える
    static func admit(identifier: String, category: String, userInfo: [AnyHashable: Any], trigger: UNNotificationTrigger?,
                      now: Date = .now) -> S24NoticeRules.Decision {
        let lane = S24NoticeRules.lane(identifier: identifier, category: category, userInfo: userInfo)
        let immediate = NoticeBundle.isImmediate(trigger)
        let quiet = S24Book.quietNow(now)
        let day = ReviewRules.dayKey(now)
        let decision: S24NoticeRules.Decision = lock.withLock {
            let c = read(day: day)
            let d = S24NoticeRules.decide(lane: lane, immediate: immediate, asked: c.asked, shown: c.shown,
                                          questionCap: S24Settings.questionCap,
                                          dailyCapOn: S24Settings.isOn(S24Settings.dailyCapOnKey), quiet: quiet)
            if d == .pass {
                let asked = c.asked + (lane == .question ? 1 : 0)
                let shown = c.shown + (immediate && !S24NoticeRules.isPriority(lane) ? 1 : 0)
                write(day: day, asked: asked, shown: shown)
            }
            return d
        }
        switch decision {
        case .pass:
            if lane == .question { Tally.add("s24.ask.sent") }
        case .drop(let why):
            Tally.add("s24.notice.drop." + why)
        case .hold:
            Tally.add("s24.notice.capped")
        }
        return decision
    }

    /// NoticeGate.add から。出すなら印などを付けた知らせを、出さない（止めた・便りに回した）なら nil
    static func filter(_ request: UNNotificationRequest, now: Date = .now) -> UNNotificationRequest? {
        let content = request.content
        switch admit(identifier: request.identifier, category: content.categoryIdentifier, userInfo: content.userInfo,
                     trigger: request.trigger, now: now) {
        case .drop:
            return nil
        case .hold:
            S20Notices.hold(title: content.title, now: now)
            return nil
        case .pass:
            guard let copy = content.mutableCopy() as? UNMutableNotificationContent else { return request }
            style(copy, id: request.identifier)
            return UNNotificationRequest(identifier: request.identifier, content: copy, trigger: request.trigger)
        }
    }

    /// 形6・形7 題の頭の印と、時計を震わせない（録音・期限・急ぎ以外は静かに届ける）。何度通しても同じ
    static func style(_ content: UNMutableNotificationContent, id: String) {
        let lane = S24NoticeRules.lane(identifier: id, category: content.categoryIdentifier, userInfo: content.userInfo)
        if S24Settings.isOn(S24Settings.marksKey), !content.title.isEmpty {
            content.title = S24NoticeRules.marked(content.title, lane: lane)
        }
        if S24Settings.isOn(S24Settings.watchQuietKey), S24NoticeRules.quietOnWatch(lane), content.interruptionLevel != .timeSensitive {
            content.interruptionLevel = .passive
        }
    }
}

// MARK: - 帳

enum S24Book {
    private static let todayKey = "s24.todayCandidates"
    private static let nightKey = "s24.foundNight"
    private static let seenKey = "s24.openedSeen"
    private static let lock = NSLock()
    static let nightID = NoticePresenter.taskFoundID

    // MARK: 減10 今週は聞かないで

    static func quietNow(_ now: Date = .now) -> Bool { S24Quiet.active(until: S24Settings.quietUntil, now: now) }

    /// 入れる・やめる。入れたら、もう頼んである問いと便りを取り消す（録音・期限・急ぎは残す）
    static func setQuiet(_ on: Bool, now: Date = .now) {
        if on {
            UserDefaults.standard.set(S24Quiet.until(from: now).timeIntervalSince1970, forKey: S24Settings.quietUntilKey)
            Tally.add("s24.quiet.on")
            let center = UNUserNotificationCenter.current()
            center.getPendingNotificationRequests { pending in
                let ids = pending.filter { r in
                    !S24NoticeRules.isPriority(S24NoticeRules.lane(identifier: r.identifier, category: r.content.categoryIdentifier,
                                                                   userInfo: r.content.userInfo))
                }.map(\.identifier)
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: S24Settings.quietUntilKey)
            Tally.add("s24.quiet.off")
        }
    }

    // MARK: 減8 開いた数

    /// 知らせを押された（知らせそのもの＝開いた・ボタン＝答えた）。同じ知らせは 1 回だけ数える。
    /// 母艦の Build-UxWeekly.py は tally の uxNotifOpened を読むので、その名前で数える
    static func noteResponse(_ response: UNNotificationResponse) {
        let request = response.notification.request
        let open = S24Opened.isOpen(action: response.actionIdentifier)
        let key = S24Opened.key(identifier: request.identifier, date: response.notification.date) + (open ? "|o" : "|a")
        let fresh: Bool = lock.withLock {
            var seen = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
            if seen.contains(key) { return false }
            seen.append(key)
            UserDefaults.standard.set(Array(seen.suffix(300)), forKey: seenKey)
            return true
        }
        guard fresh else { return }
        let kind = openedKind(identifier: request.identifier, category: request.content.categoryIdentifier,
                              userInfo: request.content.userInfo)
        if open {
            Tally.add("uxNotifOpened")
            Tally.add("notice.opened." + kind)
        } else {
            Tally.add("notice.acted." + kind)
        }
    }

    /// 数えるときの種類（家の PC から届いた知らせは名前が APNs の番号なので、急ぎ・カテゴリ・remote にまとめる）
    static func openedKind(identifier: String, category: String, userInfo: [AnyHashable: Any]) -> String {
        if S24Urgent.isUrgent(userInfo) { return S24Urgent.kind }
        if category.isEmpty, UUID(uuidString: identifier) != nil { return "remote" }
        return NoticeBundle.kind(identifier: identifier, category: category)
    }

    // MARK: 減6 見つけた頼まれごとを夜の 1 通に

    /// 夜の 1 通にためて、その 1 通を頼み直す（同じ名前で置き換える。ボタン＝入れる・違うは、並べたもの全部に効く）
    @MainActor
    static func holdFound(_ ids: [String], all items: [TaskBook.Item], now: Date = .now) {
        let slot = S24TaskRules.nightSlot(after: now)
        let day = ReviewRules.dayKey(slot)
        let merged = S24TaskRules.addNight(ids, saved: UserDefaults.standard.string(forKey: nightKey), day: day)
        UserDefaults.standard.set(merged.save, forKey: nightKey)
        Tally.add("s24.found.held", ids.count)
        var list: [TaskBook.Item] = []
        for id in merged.ids { if let hit = items.first(where: { $0.id == id }) { list.append(hit) } }
        guard let text = S24TaskRules.nightNotice(list) else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.categoryIdentifier = NoticeActions.foundCategory
        content.userInfo = ["ids": list.filter { !S24TaskRules.isWeak($0) }.map(\.id)]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: slot)
        NoticeStats.count(NoticeActions.foundCategory, "sent")
        NoticeGate.add(UNNotificationRequest(identifier: nightID, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }
}

// MARK: - 本人の困りごと: 今日の候補

extension TaskBook {
    /// 今日の候補（たぶん違うを除いた候補から、1 日 3 件（仮）まで。その日に選んだものは入れ替えない）。
    /// 「今日の候補」がオフなら、前のように全部
    func todayCandidates(now: Date = .now) -> [Item] {
        let all = candidates
        guard S24Settings.isOn(S24Settings.candidateTodayKey) else { return all }
        let strong = all.filter { !S24TaskRules.isWeak($0) }
        let key = "s24.todayCandidates"
        let picks = S24TaskRules.todayPicks(strong: strong, saved: UserDefaults.standard.string(forKey: key),
                                            day: ReviewRules.dayKey(now))
        if UserDefaults.standard.string(forKey: key) != picks.save { UserDefaults.standard.set(picks.save, forKey: key) }
        return S24TaskRules.split(all, today: picks.ids).today
    }

    /// 「残りは全部いらない」: 今日の候補のほか（残り・たぶん違う。画面に出ている方だけ）を全部「違う」にする。
    /// 押した数（task.bulk.rest）と閉じた数（task.bulk.rest.items）を数える。閉じた id を返す（「戻す」のため）
    @discardableResult
    func rejectRest(_ ids: [String], now: Date = .now) -> [String] {
        let shown = Set(todayCandidates(now: now).map(\.id))
        let rest = ids.filter { id in !shown.contains(id) && items.first(where: { $0.id == id })?.state == .candidate }
        let n = rejectAll(rest, reason: .bulk)
        Tally.add("task.bulk.rest")
        if n > 0 { Tally.add("task.bulk.rest.items", n) }
        return rest
    }
}

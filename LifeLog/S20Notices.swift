import Foundation
import UserNotifications

/// 知らせの総量（s20 の 体16・体17・体19・次2。2026-11-21）。NoticeGate.add の入口で通す。
/// - 「この種類はもう要らない」にした種類は出さない（急ぎは止めない）
/// - 便り（設定「急ぎでない知らせを朝夕の便りに」。初めはオフ）がオンなら、すぐ出す知らせのうち急ぎでないものを
///   朝 7:30・夕 19:00（仮）の 1 通にまとめる。急ぎ（ボタンのある知らせ・録音が止まった・期限・約束・署名の期限）はすぐ出す
/// - 出したもの・便りに回したものを 7 日だけ履歴に残す（題と種類だけ。中身の文は残さない）
enum S20Notices {
    private static let lock = NSLock()
    private static let heldKey = "s20.digestHeld"

    static var digestOn: Bool { UserDefaults.standard.bool(forKey: SceneKey.noticeDigest.rawValue) }
    static var muted: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "s20.noticeMuted") ?? []) }

    /// 入口で決める。true なら NoticeGate はそのまま続ける。false なら、ここで止めた（便りに回した・止めた）
    static func pass(_ request: UNNotificationRequest, now: Date = .now) -> Bool {
        let id = request.identifier
        let category = request.content.categoryIdentifier
        let kind = NoticeBundle.kind(identifier: id, category: category)
        let urgent = NoticeDigestRules.isUrgent(identifier: id, category: category)
        if NoticeHistoryRules.shouldDrop(kind: kind, muted: muted, urgent: urgent) {
            Tally.add("notice.muted." + kind)
            return false
        }
        let title = request.content.title
        // 急ぎ以外を朝の 1 通に（初めはオン。設定で戻せる。2026-11-28。s38 の 活3。S38ARules.swift）。朝夕の便りがオンならそちらが先
        let morningOne: Bool = !digestOn && S38AMorning.holds(identifier: id, category: category, userInfo: request.content.userInfo,
                                                              immediate: NoticeBundle.isImmediate(request.trigger), on: S38AMorning.isOn)
        if (digestOn && !urgent && NoticeBundle.isImmediate(request.trigger)) || morningOne {
            hold(title: title, now: now, morningOnly: morningOne)
            log(id: id, kind: kind, title: title, held: true, at: now)
            return false
        }
        // 時刻を決めた知らせは、頼んだ時ではなく出た時に数えたいので、すぐ出すものだけ残す
        if NoticeBundle.isImmediate(request.trigger) { log(id: id, kind: kind, title: title, held: false, at: now) }
        return true
    }

    private static func log(id: String, kind: String, title: String, held: Bool, at: Date) {
        Task { @MainActor in S20Book.shared.noteNotice(id: id, kind: kind, title: title, held: held, at: at) }
    }

    /// 便りにためて、次の便りの 1 通を頼み直す（同じ名前で置き換える）。
    /// 知らせ全体の 1 日の上限を超えた分もここに回す（2026-11-24。s24 の 減7。S24Book.swift）
    static func hold(title: String, now: Date, morningOnly given: Bool? = nil) {
        // 朝の 1 通の設定がオンで朝夕の便りがオフなら、上限を超えた分も朝の 1 通へ（s38 の 活3）
        let morningOnly: Bool = given ?? (!digestOn && S38AMorning.isOn)
        let previous = morningOnly ? S38AMorning.previousSlot(before: now) : NoticeDigestRules.previousSlot(before: now)
        let titles: [String] = lock.withLock { () -> [String] in
            var rows = UserDefaults.standard.array(forKey: heldKey) as? [[String: Any]] ?? []
            rows = rows.filter { ($0["at"] as? Double ?? 0) > previous.timeIntervalSince1970 }
            rows.append(["t": String(title.prefix(40)), "at": now.timeIntervalSince1970])
            rows = Array(rows.suffix(NoticeDigestRules.keep))
            UserDefaults.standard.set(rows, forKey: heldKey)
            return rows.compactMap { $0["t"] as? String }
        }
        Tally.add("notice.digested")
        let slot = morningOnly ? S38AMorning.nextSlot(after: now) : NoticeDigestRules.nextSlot(after: now)
        let morning = NoticeDigestRules.isMorning(slot)
        let text = NoticeDigestRules.digest(titles: titles, morning: morning)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        S23Notices.decorate(content, id: NoticeDigestRules.morningID)  // 題の頭の「【便り】」もここで（s24 の 形7）  // 押すとどうなるかを文に（2026-11-23。s23 の 知8）
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: slot)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        let id = morning ? NoticeDigestRules.morningID : NoticeDigestRules.eveningID
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// 次の便りにたまっている題（画面に出す）
    static func waiting(now: Date = .now) -> [String] {
        let previous = !digestOn && S38AMorning.isOn ? S38AMorning.previousSlot(before: now) : NoticeDigestRules.previousSlot(before: now)
        let rows = UserDefaults.standard.array(forKey: heldKey) as? [[String: Any]] ?? []
        return rows.filter { ($0["at"] as? Double ?? 0) > previous.timeIntervalSince1970 }.compactMap { $0["t"] as? String }
    }
}

import Foundation
import UserNotifications

/// 見える通知の数と、多いときの束ね（2026-11-15。強化案 44）。
///
/// 数える: アプリが出したローカルの通知と、家の PC からの見える通知（約束など）を、tally の `notice.shown.<種類>` に1つずつ。
/// 数えるのは、通知センターに残っている知らせ（アプリを開いたとき・裏で起きたときに見る）と、アプリを開いているあいだに
/// 画面の上に出した知らせと、押された知らせ（同じ知らせは1回だけ）。見る前に消された知らせは数えられないので、数は下限。
/// 種類は、知らせのカテゴリ（taskFound・taskDue・promise など）か、名前の頭（tasks・fresh・proposal など）。
///
/// 束ねる: すぐ出す知らせが1時間に3通を超えたら、4通目からは1通の「ほかに N 件のお知らせ」にまとめる（同じ名前で置き換える。
/// 音は初めの1回だけ）。束ねないもの（いつも出す）: ボタンのある知らせ（頼まれごとを見つけました・期限の1時間前・約束）、
/// 朝夕の頼まれごと（tasks-）、録音が止まった・時計が録音していない知らせ。これらも1時間の数には入る。
/// 時刻を決めて頼んだ知らせ（朝のまとめ・会う前の一枚・期限の1時間前など）は iOS が出すので束ねない（数えるだけ）。
/// 家の PC からの約束の知らせは、PC の側で 10 分に1通までにまとめてある（apns.LIMITS の "promise"）ので、ここでは数えるだけ。
enum NoticeBundle {
    static let perHour = 3
    static let window: TimeInterval = 3600
    static let bundleID = "notice-bundle"
    /// まとめの文に並べる題の数
    static let titleLimit = 3

    /// いつも出す知らせの名前（録音が止まった・時計が録音していない・見つけました）
    static let alwaysIDs: Set<String> = ["phone-stopped", "watch-silent", "watch-not-recording", "not-recording", "stopped",
                                         "taskFound"]

    /// 束ねない知らせか（ボタンのある知らせは、束ねると押せなくなる）
    static func isExempt(identifier: String, category: String) -> Bool {
        if !category.isEmpty { return true }
        if identifier.hasPrefix("tasks-") { return true }
        return alwaysIDs.contains(identifier)
    }

    /// すぐ出す知らせか（時刻を決めていない・5秒以内）
    static func isImmediate(_ trigger: UNNotificationTrigger?) -> Bool {
        guard let trigger else { return true }
        if let interval = trigger as? UNTimeIntervalNotificationTrigger {
            return !interval.repeats && interval.timeInterval <= 5
        }
        return false
    }

    /// この1時間に出した数
    static func inWindow(_ recent: [Date], now: Date) -> [Date] {
        var out: [Date] = []
        for date in recent where date <= now && now.timeIntervalSince(date) < window { out.append(date) }
        return out
    }

    /// まとめに回すか（束ねない知らせは回さない）
    static func shouldHold(recent: [Date], now: Date, exempt: Bool) -> Bool {
        guard !exempt else { return false }
        return inWindow(recent, now: now).count >= perHour
    }

    /// まとめの題（「ほかに 2 件のお知らせ」）
    static func summaryTitle(count: Int) -> String { "ほかに \(count) 件のお知らせ" }

    /// まとめの文（新しい題から3つまで。残りは「など」）
    static func summaryBody(titles: [String]) -> String {
        var shown: [String] = []
        for title in titles.reversed() where !title.isEmpty {
            shown.append(title)
            if shown.count >= titleLimit { break }
        }
        var text: String = shown.joined(separator: "・")
        if titles.count > shown.count { text += " など" }
        if text.isEmpty { text = "知らせが多かったので、まとめました" }
        return text + "（1時間に3通を超えたので、まとめました。アプリを開くと見られます）"
    }

    /// 数えるときの種類（カテゴリがあればカテゴリ、無ければ名前の頭。英数字と - _ だけ・30 文字まで）
    static func kind(identifier: String, category: String) -> String {
        if !category.isEmpty { return clean(category) }
        let prefixes: [(String, String)] = [("tasks-due-", "taskDue"), ("tasks-", "tasks"), ("brief-", "brief"),
                                            ("signExpiry-", "signExpiry"), ("fresh-", "fresh"), ("proposal-", "proposal")]
        for (prefix, name) in prefixes where identifier.hasPrefix(prefix) { return name }
        if identifier == bundleID { return "bundle" }
        return clean(identifier)
    }

    private static func clean(_ text: String) -> String {
        var out: String = ""
        for ch in text where ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") {
            out.append(ch)
            if out.count >= 30 { break }
        }
        return out.isEmpty ? "other" : out
    }

    /// 同じ知らせを2回数えないための印（名前と出た時刻の秒）
    static func key(identifier: String, date: Date) -> String {
        identifier + "|" + String(Int(date.timeIntervalSince1970))
    }
}

/// 知らせを出す所と数える所（中身の文は残さない。まとめの題だけ1時間残す）
enum NoticeGate {
    private static let recentKey = "noticeGate.recent"
    private static let heldKey = "noticeGate.held"
    private static let heldSinceKey = "noticeGate.heldSince"
    private static let seenKey = "noticeGate.seen"
    private static let lock = NSLock()

    /// すぐ出す知らせを、束ねの決まりを通して出す（時刻を決めた知らせは、そのまま頼む）
    static func add(_ request: UNNotificationRequest, now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        guard NoticeBundle.isImmediate(request.trigger) else {
            center.add(request)
            return
        }
        let exempt: Bool = NoticeBundle.isExempt(identifier: request.identifier, category: request.content.categoryIdentifier)
        let title: String = request.content.title
        let held: [String]? = lock.withLock { () -> [String]? in
            let defaults = UserDefaults.standard
            let stamps: [Double] = defaults.array(forKey: recentKey) as? [Double] ?? []
            var recent: [Date] = []
            for t in stamps { recent.append(Date(timeIntervalSince1970: t)) }
            recent = NoticeBundle.inWindow(recent, now: now)
            if !NoticeBundle.shouldHold(recent: recent, now: now, exempt: exempt) {
                recent.append(now)
                var kept: [Double] = []
                for d in recent { kept.append(d.timeIntervalSince1970) }
                defaults.set(kept, forKey: recentKey)
                return nil
            }
            let since: Double = defaults.double(forKey: heldSinceKey)
            var titles: [String] = defaults.stringArray(forKey: heldKey) ?? []
            if since == 0 || now.timeIntervalSince1970 - since >= NoticeBundle.window {
                titles = []
                defaults.set(now.timeIntervalSince1970, forKey: heldSinceKey)
            }
            titles.append(String(title.prefix(40)))
            defaults.set(Array(titles.suffix(20)), forKey: heldKey)
            return titles
        }
        guard let held else {
            center.add(request)
            return
        }
        Tally.add("notice.bundled")
        let content = UNMutableNotificationContent()
        content.title = NoticeBundle.summaryTitle(count: held.count)
        content.body = NoticeBundle.summaryBody(titles: held)
        if held.count == 1 { content.sound = .default }
        center.add(UNNotificationRequest(identifier: NoticeBundle.bundleID, content: content, trigger: nil))
    }

    /// 見えた知らせを1つ数える（同じものは1回だけ）
    static func noteShown(identifier: String, category: String, date: Date) {
        let key: String = NoticeBundle.key(identifier: identifier, date: date)
        let fresh: Bool = lock.withLock { () -> Bool in
            var seen: [String] = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
            if seen.contains(key) { return false }
            seen.append(key)
            UserDefaults.standard.set(Array(seen.suffix(400)), forKey: seenKey)
            return true
        }
        guard fresh else { return }
        Tally.add("notice.shown." + NoticeBundle.kind(identifier: identifier, category: category), 1, at: date)
    }

    /// 通知センターに残っている知らせを数える（アプリを開いたとき・裏で起きたとき）
    static func scanDelivered() async {
        let list: [UNNotification] = await UNUserNotificationCenter.current().deliveredNotifications()
        for n in list {
            noteShown(identifier: n.request.identifier, category: n.request.content.categoryIdentifier, date: n.date)
        }
    }
}

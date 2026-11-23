import Foundation
import UserNotifications
import WatchKit

/// s23（2026-11-23）「録音が止まらない」の時計の分（決まりは Shared/Audio/S23Rec.swift。番号は母艦の追記 12）。
/// - 止1: 中断ごとに、始まり・戻った時刻・だめだった回数・戻った道・理由を残し、iPhone への様子（s23rec）に載せる
/// - 止2・止3: 音の仕組みが作り直された・つないだ／外したの数（受け口は WatchRecorder）
/// - 止7: 「録音が止まりました」「止まっているかも」「録音していません」に「録音を戻す」（押すと開いてすぐ戻す）
/// - 止10: iPhone に頼まれたら時計で録る（初めはオフ。iPhone の設定）
/// - 止11: 毎日同じ時刻に切れるなら、その 1 分後に見回る
/// - 止12: 止まっていたあいだを iPhone の帯へ
/// - 止13: 1 分より長く止まって戻ったときだけ 1 回知らせる
/// - 止15: iPhone に頼まれたら中断の練習
enum S23WatchRec {
    static let stopsKey = "s23.rec.watchStops"
    static let sinceKey = "s23.rec.since"
    /// 今日の数（"日|名前" → 回数。mediaReset・route・cover・daily）
    static let countsKey = "s23.rec.watchCounts"
    /// 練習の結果（"1970 からの秒|1 か 0|秒"）
    static let drillKey = "s23.rec.watchDrill"
    static let noticesKey = "s23.rec.watchNotices"
    private static let lock = NSLock()
    @MainActor private static weak var recorder: WatchRecorder?

    @MainActor static func setUp(_ recorder: WatchRecorder) {
        self.recorder = recorder
        if UserDefaults.standard.object(forKey: sinceKey) == nil {
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: sinceKey)
        }
        // 押すとアプリが開く（開いたときに WatchContentView が resumeIfWanted を呼んで戻す）。
        // 開かずに裏で録り直せるかは分からないので、いちばん確かな「開く」にする。前からの分類は消さずに足す
        let action = UNNotificationAction(identifier: S23Rec.resumeAction, title: S23Rec.resumeTitle, options: [.foreground])
        let category = UNNotificationCategory(identifier: S23Rec.watchResumeCategory, actions: [action],
                                              intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.filter { $0.identifier != S23Rec.watchResumeCategory }.union([category]))
        }
        scheduleDailyCheck()
    }

    // MARK: 止1 中断の記録

    static func load() -> [S23Rec.Stop] {
        (UserDefaults.standard.array(forKey: stopsKey) as? [[String: Any]] ?? []).compactMap(S23Rec.Stop.init(dict:))
    }

    private static func save(_ list: [S23Rec.Stop]) {
        UserDefaults.standard.set(list.map(\.dict), forKey: stopsKey)
    }

    static func began(_ reason: String, now: Date = .now) {
        lock.withLock { save(S23Rec.adding(load(), S23Rec.Stop(start: now.timeIntervalSince1970, reason: reason), now: now)) }
    }

    static func failed() {
        lock.withLock { save(S23Rec.failing(load())) }
    }

    /// 戻った（止まっていた秒を返す。まだ戻っていない中断が無ければ nil）
    @discardableResult
    static func resumed(way: String, now: Date = .now) -> TimeInterval? {
        let open: S23Rec.Stop? = lock.withLock {
            let list = load()
            let open = list.last { $0.end == nil }
            save(S23Rec.closing(list, end: now, way: way))
            return open
        }
        guard let open else { return nil }
        let seconds = max(0, now.timeIntervalSince1970 - open.start)
        if open.reason != "drill" { Task { @MainActor in noticeResumed(seconds, now: now) } }
        return seconds
    }

    /// 中断のあいだに止めた
    static func abandoned(now: Date = .now) {
        lock.withLock { save(S23Rec.closing(load(), end: now, way: "stopped")) }
    }

    static func count(_ name: String, now: Date = .now) {
        lock.withLock {
            let saved = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
            UserDefaults.standard.set(HolidayRules.bumped(saved, name, day: HolidayRules.dayKey(now)), forKey: countsKey)
        }
    }

    static func noteDrill(ok: Bool, seconds: TimeInterval, now: Date = .now) {
        UserDefaults.standard.set("\(Int(now.timeIntervalSince1970))|\(ok ? 1 : 0)|\(Int(seconds.rounded()))", forKey: drillKey)
    }

    /// iPhone への様子に足す（WatchSender.deliveryState から。どれも省ける）
    static func extraState(now: Date) -> [String: Any] {
        let list = lock.withLock { load() }
        let day = HolidayRules.dayKey(now)
        var rec: [String: Any] = S23Rec.summary(list, day: day)
        // 帯に出すため、直近 24 時間の止まっていたあいだ（30 個まで）
        let recent = list.filter { now.timeIntervalSince1970 - $0.start < 86400 }.suffix(30).map(\.dict)
        if !recent.isEmpty { rec["stops"] = Array(recent) }
        let counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        var events: [String: Int] = [:]
        for name in ["mediaReset", "route", "cover", "daily", "notice"] {
            let n = HolidayRules.count(counts, name, day: day)
            if n > 0 { events[name] = n }
        }
        if !events.isEmpty { rec["ev"] = events }
        if let drill = UserDefaults.standard.string(forKey: drillKey) { rec["drill"] = drill }
        if S23Rec.isOn(S23Rec.legacyKey) { rec["legacy"] = true }
        return [S23Rec.stateKey: rec]
    }

    // MARK: iPhone からの頼み（止4・止10・止15）

    /// WatchSender の didReceiveUserInfo から呼ぶ
    static func received(_ userInfo: [String: Any]) {
        let cover = userInfo[S23Rec.coverKey] as? Bool
        let drill = userInfo[S23Rec.drillKey] as? Bool == true
        let call = userInfo[S23Rec.callEndedKey] as? Bool == true
        guard cover != nil || drill || call else { return }
        Task { @MainActor in
            guard let recorder else { return }
            if let cover { await recorder.s23Cover(cover) }
            if call { recorder.s23CallEnded() }
            if drill { await recorder.s23Drill() }
        }
    }

    // MARK: 止13 戻ったあとの 1 回の知らせ

    @MainActor private static func noticeResumed(_ seconds: TimeInterval, now: Date) {
        guard S23Rec.isOn(S23Rec.resumedNoticeKey), let text = S23Rec.resumedText(seconds),
              WKApplication.shared().applicationState != .active else { return }
        let day = HolidayRules.dayKey(now)
        let saved = UserDefaults.standard.dictionary(forKey: noticesKey) as? [String: Int] ?? [:]
        guard HolidayRules.count(saved, "sent", day: day) < S23Rec.resumedNoticeLimit else { return }
        UserDefaults.standard.set(HolidayRules.bumped(saved, "sent", day: day), forKey: noticesKey)
        count("notice", now: now)
        let content = UNMutableNotificationContent()
        content.title = "時計の録音が戻りました"
        content.body = text
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["watchdog", "stopped", "not-recording"])
        center.add(UNNotificationRequest(identifier: "s23-resumed", content: content, trigger: nil))
    }

    // MARK: 止11 毎日の見回り

    @MainActor private static var dailyTask: Task<Void, Never>?

    @MainActor static func scheduleDailyCheck(now: Date = .now) {
        dailyTask?.cancel()
        dailyTask = nil
        guard S23Rec.isOn(S23Rec.dailyCheckKey) else { return }
        let starts = load().filter { $0.reason != "drill" }.map { Date(timeIntervalSince1970: $0.start) }
        let since = (UserDefaults.standard.object(forKey: sinceKey) as? Double).map { Date(timeIntervalSince1970: $0) }
        guard let next = S23Rec.nextCheck(S23Rec.recurringSlots(starts, since: since, now: now), now: now) else { return }
        dailyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            count("daily")
            await recorder?.s23DailyCheck()
            scheduleDailyCheck()
        }
    }
}

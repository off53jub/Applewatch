import Foundation
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

/// s22（2026-11-22）の iPhone の帳（覚えておくもの・数えるもの・動き。docs/s22-app.md）。
/// 決まりは S22Rules.swift・S22Checkup.swift・Shared/Audio/S22Watch.swift、画面は S22Views.swift。
@MainActor
enum S22Book {
    /// LifeLogApp が入れる（弱く持つ）
    static weak var pipeline: Pipeline?
    private static var timer: Timer?

    /// LifeLogApp の起動で 1 回だけ呼ぶ。live でなければ（テスト・画面の自動確認）見回りを動かさない
    static func install(_ pipeline: Pipeline, live: Bool) {
        self.pipeline = pipeline
        guard live, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in S22Book.tick() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            S22Book.tick()
        }
    }

    /// 5 分ごと（裏で録音しているあいだも動く）とアプリが前に出たとき
    static func tick(now: Date = .now) {
        samplePhoneBattery(now: now)
        drainWidgetAnswers()
        guard let pipeline else { return }
        S22Notices.checkTrain(pipeline, now: now)
        S22Notices.checkWho(pipeline, now: now)
        if let combo = S22Watch.hourlyNow(now: now), pipeline.isWatchRecording {
            // 5 分ごとの数（＝その組で録っていた時間の目安。家の PC が組ごとに数える手がかり）
            Tally.add("s22.recExp." + S22Watch.label(combo), at: now)
        }
    }

    // MARK: - 楽6 時計に溜まった分（iPhone から見た数）と「いま送り直す」

    private static let finishedKey = "s22.watchFinishedRecent"

    static func noteWatch(_ state: PhoneReceiver.WatchState) {
        let defaults = UserDefaults.standard
        if let n = state.finishedRecent { defaults.set(n, forKey: finishedKey) }
        // 確31: 今日こもりで震えた回数が増えた分を tally の watch.muffled に
        if let n = state.muffledToday {
            let day = HolidayRules.dayKey(state.at)
            var seen = defaults.dictionary(forKey: "s22.muffledSeen") as? [String: Int] ?? [:]
            let delta = n - (seen[day] ?? 0)
            if delta > 0 {
                Tally.add("watch.muffled", delta)
                seen = seen.filter { $0.key >= HolidayRules.dayKey(Date.now.addingTimeInterval(-7 * 86400)) }
                seen[day] = n
                defaults.set(seen, forKey: "s22.muffledSeen")
            }
        }
    }

    /// 「あと 120 個・約 40 分」（時計の様子が届いていなければ nil）
    static func watchBacklogText() -> String? {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        guard let pending = detail["watchPending"] as? Int else { return nil }
        let finished = UserDefaults.standard.object(forKey: finishedKey) as? Int ?? 0
        return S22Watch.backlogText(count: pending, finishedRecent: finished)
    }

    /// iPhone の「いま送り直す」: 受け取った名前の一覧を渡して、時計に送り直してもらう
    @discardableResult
    static func resendWatchNow(now: Date = .now) -> Bool {
        guard let pipeline else { return false }
        let names = S21Rules.gotListNames(Storage.receivedTimes(), now: now)
        pipeline.receiver.sendGotList(names)
        S21Book.gotListSentAt = now
        let ok = pipeline.receiver.askWatchToResendNow()
        if ok { Tally.add("s22.watchResendNow") }
        return ok
    }

    // MARK: - 楽19 電池の先回り（iPhone の見本。時計の見本は時計の様子の watchBatteryAt）

    private static let phoneBatteryKey = "s22.phoneBattery"

    static func samplePhoneBattery(now: Date = .now) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        guard device.batteryLevel >= 0 else { return }
        let defaults = UserDefaults.standard
        let samples = defaults.array(forKey: phoneBatteryKey) as? [[Double]] ?? []
        guard HolidayRules.batterySampleDue(last: samples.last?.first, now: now) else { return }
        let charging = device.batteryState == .charging || device.batteryState == .full
        defaults.set(HolidayRules.addingSample(samples, time: now, level: Double(device.batteryLevel), holding: false, charging: charging),
                     forKey: phoneBatteryKey)
    }

    static func phoneBatteryLine(now: Date = .now) -> String? {
        let samples = UserDefaults.standard.array(forKey: phoneBatteryKey) as? [[Double]] ?? []
        return S22Watch.emptyText(S22Watch.emptyAt(samples, now: now), now: now)
    }

    static func watchBatterySamples() -> [[Double]] {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        return (detail["watchBatteryAt"] as? [[Double]]) ?? (detail["watchBatteryAt"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? []
    }

    static func watchBatteryLine(now: Date = .now) -> String? {
        S22Watch.emptyText(S22Watch.emptyAt(watchBatterySamples(), now: now), now: now)
    }

    // MARK: - 確24 録り方の実験を 1 時間ごとに入れ替える（初めはオフ）

    static var hourlyOn: Bool { UserDefaults.standard.bool(forKey: S22Watch.hourlyOnKey) }

    /// オンにした日を 1 日目にする（前の 8 日が終わっていれば、その日からやり直す）。時計にも伝える
    static func setHourly(_ on: Bool, now: Date = .now) {
        let defaults = UserDefaults.standard
        defaults.set(on, forKey: S22Watch.hourlyOnKey)
        let start = defaults.string(forKey: S22Watch.hourlyStartKey)
        if on, start == nil || S22Watch.hourlyFinished(start: start, now: now) {
            defaults.set(RecordingExperiment.dayKey(now), forKey: S22Watch.hourlyStartKey)
        }
        Tally.add(on ? "s22.recExpHourly.on" : "s22.recExpHourly.off")
        if let pipeline { pipeline.receiver.sendSettings(skipSilence: pipeline.skipSilence, held: pipeline.recordingHeld) }
    }

    static func hourlyText(now: Date = .now) -> String {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: S22Watch.hourlyOnKey) else { return "止めています（初めはオフ）" }
        let start = defaults.string(forKey: S22Watch.hourlyStartKey)
        if S22Watch.hourlyFinished(start: start, now: now) { return "8 日終わりました（いつもの録り方）" }
        if let combo = S22Watch.hourlyNow(now: now) { return "\(combo.day) 日目・いまの組 " + S22Watch.label(combo) }
        return "会議モード中か、始まる前です"
    }

    // MARK: - 楽13・楽12・楽14 確かめ待ちに ○×（時計・通知・ウィジェット）

    /// 時計に出す 1 問（はい・いいえで答えられるものだけ）
    static func watchReviewAsk() -> WatchInfo.ReviewAsk? {
        guard let item = firstYesNo() else { return nil }
        return WatchInfo.ReviewAsk(id: item.id, question: WatchInfo.clip(item.question, 120))
    }

    static func firstYesNo(excluding: Set<String> = []) -> ReviewItem? {
        S20Book.shared.openItems().first { S22Rules.isYesNo(answer: $0.answer, choices: $0.choices) && !excluding.contains($0.id) }
    }

    /// ほかの所（時計・通知・ウィジェット）で答えた。一覧に無い問い（写しが古い）も、答えは母艦へ送る
    static func answerReview(id: String, value: String, from source: String) {
        guard HomeFeeds.isID(id), ["yes", "no", "unsure"].contains(value) else { return }
        let book = S20Book.shared
        guard book.answered[id] == nil else { return }
        let known: ReviewItem? = book.review?.items?.first(where: { $0.id == id })
        let item = known ?? ReviewItem(id: id, kind: "", question: "", answer: "yesno")
        book.answer(item, value)
        Tally.add("s22.review." + source)
        guard let pipeline else { return }
        let pc = pipeline.homePC
        Task { await MothershipOutbox.send(pc) }
        pipeline.pushWatchInfo(force: true)
    }

    /// ウィジェットのボタンで答えた分（App Group にたまっている）を送る列に移す
    static func drainWidgetAnswers() {
        for entry in S22WidgetAnswers.take() { answerReview(id: entry.id, value: entry.value, from: "widget") }
    }

    /// ウィジェットの中身に 1 問を入れる（WidgetBridge が呼ぶ）
    static func fillWidget(_ state: inout WidgetState) {
        if let item = firstYesNo(excluding: Set(S22WidgetAnswers.pendingIDs())) {
            state.reviewAskID = item.id
            state.reviewAskQuestion = String(item.question.prefix(80))
        }
    }

    // MARK: - 楽11 実機の確かめ（手で答えた ○×。家の PC への様子に state/device_checks.json の形で入れる）

    static func manualDeviceChecks(now: Date = .now) -> [[String: String]] {
        let done = Checklist.done
        return Checklist.items.filter { $0.id.hasPrefix("s21-") || $0.id.hasPrefix("s22-") }.compactMap { item in
            guard let result = done[item.id] else { return nil }
            // 数から自動で ○ にしたものは source を auto に（2026-11-23。s23 の 試1）
            return ["id": item.id, "name": item.title, "result": result,
                    "source": S23Book.shared.autoChecks.contains(item.id) ? "auto" : "app"]
        }
    }

    // MARK: - 家の PC への様子（どれも省ける）

    static func diagState() -> [String: Any] {
        var out: [String: Any] = [:]
        if let combo = S22Watch.hourlyNow() { out["recExpHourly"] = S22Watch.label(combo) }
        if let launch = S22Launch.summary() {
            out["launchToToday"] = ["last": S22Watch.round1(launch.last), "median": S22Watch.round1(launch.median), "n": launch.n]
        }
        let checks = manualDeviceChecks()
        if !checks.isEmpty { out["deviceChecksManual"] = checks }
        if S22Device.isPad { out["ipadReader"] = S22Device.isReader }
        return out
    }
}

// MARK: - 楽21 開いてから今日の画面が出るまで

enum S22Launch {
    nonisolated(unsafe) private static var start: Date?
    nonisolated(unsafe) private static var shown = false
    private static let key = "s22.launchSeconds"

    /// LifeLogApp の init のいちばん初めに呼ぶ
    static func markStart(now: Date = .now) {
        if start == nil { start = now }
    }

    /// 今日の画面が出たとき（1 回だけ数える。裏で起きてから時間がたって開いたものは数えない）
    @MainActor
    static func todayShown(now: Date = .now) {
        guard !shown, let start else { return }
        shown = true
        let seconds = now.timeIntervalSince(start)
        guard seconds >= 0, seconds < 60, UIApplication.shared.applicationState != .background else {
            Tally.add("launch.today.late")
            return
        }
        Tally.add("launch.today." + S22Rules.launchBucket(seconds))
        SpanClock.note("launch.today", seconds: seconds)
        var list = UserDefaults.standard.array(forKey: key) as? [Double] ?? []
        list = Array((list + [S22Watch.round1(seconds)]).suffix(20))
        UserDefaults.standard.set(list, forKey: key)
    }

    static func summary() -> (last: Double, median: Double, n: Int)? {
        let list = UserDefaults.standard.array(forKey: key) as? [Double] ?? []
        guard let last = list.last, let median = S22Rules.median(list) else { return nil }
        return (last, median, list.count)
    }
}

// MARK: - 楽22 iPad は読むだけ

@MainActor
enum S22Device {
    nonisolated static let readerKey = "s22.ipadReader"
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var readerOn: Bool {
        UserDefaults.standard.object(forKey: readerKey) as? Bool ?? S22Rules.readerDefault(isPad: isPad)
    }
    /// iPad で「読むだけ」がオン（録音を始めない・同期で自分の分を書かない）
    static var isReader: Bool { isPad && readerOn }
}

// MARK: - 楽12・楽15・楽16 知らせ

@MainActor
enum S22Notices {
    nonisolated static let prefix = "s22-"
    nonisolated static let reviewCategory = "s22review"
    nonisolated static let yesAction = "s22.yes"
    nonisolated static let noAction = "s22.no"
    /// 楽15 電車の中で「いま 3 問だけ」（初めはオン・1 日 1 回）
    nonisolated static let trainKey = "s22.trainNudge"
    /// 楽16 会話が終わってすぐ「誰と話した？」（初めはオフ・1 日 3 回まで）
    nonisolated static let whoKey = "s22.whoNudge"

    static var trainOn: Bool { UserDefaults.standard.object(forKey: trainKey) as? Bool ?? true }
    static var whoOn: Bool { UserDefaults.standard.bool(forKey: whoKey) }

    nonisolated static func categories() -> Set<UNNotificationCategory> {
        let yes = UNNotificationAction(identifier: yesAction, title: "○ はい", options: [])
        let no = UNNotificationAction(identifier: noAction, title: "× いいえ", options: [])
        return [UNNotificationCategory(identifier: reviewCategory, actions: [yes, no], intentIdentifiers: [], options: [])]
    }

    /// 確かめ待ちの 1 問を ○× のボタンつきで知らせる（n は何問目か。3 問まで続ける）
    static func postReview(_ item: ReviewItem, n: Int) {
        let content = UNMutableNotificationContent()
        content.title = n == 1 ? "電車の中なら、いま 3 問だけ" : "あと \(4 - n) 問（\(n) / 3）"
        // 「通知に中身を出さない」（約束の設定）なら問いを出さない
        content.body = PromiseRules.hideBody ? "長押しして ○ か × で答えられます" : String(item.question.prefix(120))
        content.categoryIdentifier = reviewCategory
        content.userInfo = ["id": item.id, "n": n]
        content.sound = n == 1 ? .default : nil
        NoticeGate.add(UNNotificationRequest(identifier: prefix + "review-\(n)", content: content, trigger: nil))
        Tally.add("s22.notice.review")
    }

    /// 知らせのボタンを押された（TaskBook.swift の NoticePresenter から）
    static func answered(actionID: String, userInfo: [AnyHashable: Any]) {
        guard let id = userInfo["id"] as? String else { return }
        let n = userInfo["n"] as? Int ?? 1
        let value: String? = actionID == yesAction ? "yes" : actionID == noAction ? "no" : nil
        guard let value else {
            S22Book.pipeline?.openRoute(.tab(.fix))
            return
        }
        S22Book.answerReview(id: id, value: value, from: "notice")
        if n < 3, let next = S22Book.firstYesNo(excluding: [id]) { postReview(next, n: n + 1) }
    }

    /// 楽15: いちばん新しい会話が 20 分以内で電車の中なら、1 日 1 回
    static func checkTrain(_ pipeline: Pipeline, now: Date) {
        let today = HolidayRules.dayKey(now)
        let defaults = UserDefaults.standard
        guard trainOn, defaults.string(forKey: "s22.trainDay") != today,
              let last = pipeline.conversations(on: ReviewRules.dayKey(now)).last,
              now.timeIntervalSince(last.end) < 20 * 60 else { return }
        let train = TrainRules.isTrain(movement: last.movement, inCar: pipeline.carAudio.connected(from: last.start, to: last.end),
                                       place: last.place, scene: last.scene)
        let waiting = S20Book.shared.openItems().filter { S22Rules.isYesNo(answer: $0.answer, choices: $0.choices) }.count
        guard S22Rules.trainNudgeDue(on: true, isTrain: train, waiting: waiting, lastDay: nil, today: today),
              let first = S22Book.firstYesNo() else { return }
        defaults.set(today, forKey: "s22.trainDay")
        postReview(first, n: 1)
        Tally.add("s22.trainNudge")
    }

    /// 楽16: 閉じたばかりの会話に名前の無い声が多ければ「誰と話した？」（名前・中身は出さない）
    static func checkWho(_ pipeline: Pipeline, now: Date) {
        guard whoOn else { return }
        let defaults = UserDefaults.standard
        let today = HolidayRules.dayKey(now)
        var asked = defaults.dictionary(forKey: "s22.whoAsked") as? [String: String] ?? [:]
        asked = asked.filter { $0.value >= HolidayRules.dayKey(now.addingTimeInterval(-2 * 86400)) }
        let askedToday = asked.values.filter { $0 == today }.count
        let unnamed = Set(pipeline.people.filter { !$0.isSelf && !$0.isNamed }.map(\.id))
        for talk in pipeline.conversations(on: ReviewRules.dayKey(now)).reversed() {
            let key = String(Int(talk.start.timeIntervalSince1970))
            var lines = 0
            if talk.media == nil {
                for line in talk.lines where line.media == nil {
                    if let sid = line.speakerID, unnamed.contains(sid) { lines += 1 }
                }
            }
            guard S22Rules.whoNudgeDue(on: true, closed: talk.closed, end: talk.end, unnamedLines: lines,
                                       alreadyAsked: asked[key] != nil, askedToday: askedToday, now: now) else { continue }
            asked[key] = today
            defaults.set(asked, forKey: "s22.whoAsked")
            let f = DateFormatter()
            f.dateFormat = "H:mm"
            let content = UNMutableNotificationContent()
            content.title = "さっき（\(f.string(from: talk.start))〜\(f.string(from: talk.end))）は誰と話しましたか？"
            content.body = "「直す」で声を聞いて、名前を付けられます。"
            NoticeGate.add(UNNotificationRequest(identifier: prefix + "who-" + key, content: content, trigger: nil))
            Tally.add("s22.whoNudge")
            return
        }
    }
}

// MARK: - Pipeline に足す入口

extension Pipeline {
    /// 時計から様子が届くたびに（S21Book の s21WatchState から）
    func s22WatchState(_ state: PhoneReceiver.WatchState) {
        S22Book.noteWatch(state)
    }

    /// 自己点検に足す行（S22 の分）
    func s22DiagnosticItems() -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        func add(_ section: String, _ label: String, _ value: String, _ ok: Bool? = nil) {
            items.append(DiagnosticItem(section: section, label: label, value: value, ok: ok))
        }
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        if let backlog = S22Book.watchBacklogText() { add("時計", "時計に溜まった分", backlog) }
        let version = S22Rules.watchVersion(phone: AppBuild.current, watch: detail["watchBuild"] as? String)
        if case .unknown = version, PCDiag.watchSeenAt != nil {
            add("時計", "時計のアプリの版", "分からない（時計の LifeLog が古い版のまま。一度開くか、Watch アプリで入れ直す）", false)
        }
        if let line = S22Book.watchBatteryLine() { add("時計", "時計の電池", line) }
        if let line = S22Book.phoneBatteryLine() { add("端末", "iPhone の電池", line) }
        add("時計", "録り方の実験（1 時間ごと）", S22Book.hourlyText())
        if let launch = S22Launch.summary() {
            add("処理", "開いてから今日の画面まで", String(format: "前回 %.1f 秒・ふつう %.1f 秒（%d 回）", launch.last, launch.median, launch.n),
                launch.median < 4)
        }
        if S22Device.isPad { add("端末", "iPad は読むだけ", S22Device.isReader ? "オン（録音と同期の書き込みをしない）" : "オフ") }
        return items
    }

    /// Siri・ショートカットの「今日のまとめ」（楽17）
    func s22TodaySummary(now: Date = .now) -> String {
        let state = widgetState(now: now)
        var parts: [String] = []
        parts.append("今日は会話 \(state.todayTalks ?? 0) 件")
        if let hours = state.todayHours, hours > 0 { parts.append("録った時間 " + S22Watch.durationText(hours * 3600)) }
        if let due = state.tasksDue, due > 0 { parts.append("今日までの頼まれごと \(due) 件") }
        if let waiting = state.reviewWaiting, waiting > 0 { parts.append("確かめ待ち \(waiting) 件") }
        var text = parts.joined(separator: "・") + "。"
        if let three = state.todayThree, !three.isEmpty { text += "今日の三つは " + three.joined(separator: "、") + "。" }
        return text
    }
}

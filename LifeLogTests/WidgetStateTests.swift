import XCTest
@testable import LifeLog

/// 文字盤・ウィジェットと分け合う中身（WidgetState）の保存と読み出し、表示の文、iPhone で作る中身（2026-11-07）。
/// App Group は使わず、試しの入れ物（UserDefaults の別の名前）で確かめる。
@MainActor
final class WidgetStateTests: XCTestCase {
    /// 11/7 の昼（日付の変わり目で結果が変わらないように）
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!

    /// 11月 d 日（既定は 7 日）の h 時 m 分
    private func at(_ h: Int, _ m: Int, day d: Int = 7) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
    }

    /// 試しの入れ物（テストが終わったら消す）
    private func scratch() -> UserDefaults {
        let name = "WidgetStateTests-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    // MARK: - 保存と読み出し

    func testSaveAndLoad() {
        let defaults = scratch()
        XCTAssertNil(WidgetState.load(from: defaults))
        var state = WidgetState(updated: now)
        state.phoneRecording = true
        state.tasksDue = 3
        state.tasksOverdue = 1
        state.nextEvent = WidgetState.Event(title: "打ち合わせ", start: at(12, 30), end: nil)
        state.lastProcessed = at(11, 52)
        XCTAssertTrue(state.save(to: defaults))
        XCTAssertEqual(WidgetState.load(from: defaults), state)
    }

    func testSameStateIsNotWrittenAgain() {
        let defaults = scratch()
        var state = WidgetState(updated: now)
        state.watchRecording = false
        state.lastProcessed = now.addingTimeInterval(-123.456)
        XCTAssertTrue(state.save(to: defaults))
        // 書いた時刻（updated）だけが違うときは書かない
        var later = state
        later.updated = now.addingTimeInterval(600)
        XCTAssertFalse(later.save(to: defaults))
        XCTAssertEqual(WidgetState.load(from: defaults)?.updated, now)
        // 中身が変われば書く
        later.watchRecording = true
        XCTAssertTrue(later.save(to: defaults))
        XCTAssertEqual(WidgetState.load(from: defaults)?.watchRecording, true)
        XCTAssertFalse(later.save(to: defaults))
    }

    func testNoAppGroupWritesNothing() {
        // App Group が使えない入れ方（署名なしの IPA）では入れ物が無い
        XCTAssertFalse(WidgetState(updated: now).save(to: nil))
        XCTAssertNil(WidgetState.load(from: nil))
    }

    func testBrokenDataIsReplaced() {
        let defaults = scratch()
        defaults.set(Data("こわれた中身".utf8), forKey: WidgetState.key)
        XCTAssertNil(WidgetState.load(from: defaults))
        XCTAssertTrue(WidgetState(updated: now).save(to: defaults))
        XCTAssertNotNil(WidgetState.load(from: defaults))
    }

    func testOlderFormatStillLoads() {
        // 項目を足す前（土台の形）に書かれた中身も読める
        let defaults = scratch()
        let json = #"{"updated":784180800,"phoneRecording":true,"tasksDue":2,"tasksOverdue":0}"#
        defaults.set(Data(json.utf8), forKey: WidgetState.key)
        let state = WidgetState.load(from: defaults)
        XCTAssertEqual(state?.phoneRecording, true)
        XCTAssertEqual(state?.tasksDue, 2)
        XCTAssertNil(state?.tasksOpen)
        XCTAssertNil(state?.watchQuiet)
        XCTAssertNil(state?.nextEvent)
    }

    // MARK: - 読み直しの間とタイムライン

    func testReloadAtMostOncePerMinute() {
        XCTAssertEqual(WidgetPublisher.delay(since: .distantPast, now: now), 0)
        XCTAssertEqual(WidgetPublisher.delay(since: now.addingTimeInterval(-20), now: now), 40, accuracy: 0.001)
        XCTAssertEqual(WidgetPublisher.delay(since: now.addingTimeInterval(-60), now: now), 0)
        XCTAssertEqual(WidgetPublisher.delay(since: now, now: now), 60, accuracy: 0.001)
        // 文字にした時刻・送っていない数だけの変わり方は15分に1回まで
        XCTAssertEqual(WidgetPublisher.delay(since: now.addingTimeInterval(-5 * 60), now: now, minor: true), 600, accuracy: 0.001)
        XCTAssertEqual(WidgetPublisher.delay(since: now.addingTimeInterval(-15 * 60), now: now, minor: true), 0)
    }

    func testMinorChange() {
        var old = WidgetState(updated: now)
        old.phoneRecording = true
        old.lastProcessed = at(11, 40)
        old.watchUnsent = 0
        var new = old
        new.updated = now.addingTimeInterval(60)
        new.lastProcessed = at(11, 45)
        new.watchUnsent = 3
        XCTAssertTrue(new.isMinorChange(from: old))
        // 録音を止めたのは急ぐ
        new.phoneRecording = false
        XCTAssertFalse(new.isMinorChange(from: old))
        var tasks = old
        tasks.tasksDue = 1
        XCTAssertFalse(tasks.isMinorChange(from: old))
    }

    func testTimelineSwitchesAtEventStartAndEnd() {
        let midnight = day(1)
        var state = WidgetState(updated: now)
        XCTAssertEqual(state.timelineDates(from: now), [now, midnight])
        state.nextEvent = WidgetState.Event(title: "a", start: at(12, 30), end: at(13, 30))
        XCTAssertEqual(state.timelineDates(from: now), [now, at(12, 30), at(13, 30), midnight])
        // もう始まった予定は、終わりだけ
        state.nextEvent = WidgetState.Event(title: "a", start: at(11, 50), end: at(12, 10))
        XCTAssertEqual(state.timelineDates(from: now), [now, at(12, 10), midnight])
        // 終わりの分からない予定は1時間とみなす
        state.nextEvent = WidgetState.Event(title: "a", start: at(12, 10), end: nil)
        XCTAssertEqual(state.timelineDates(from: now), [now, at(12, 10), at(12, 10).addingTimeInterval(3600), midnight])
        // 過ぎた予定（もう終わった）は、今と0時だけ
        state.nextEvent = WidgetState.Event(title: "a", start: at(10, 0), end: at(11, 0))
        XCTAssertEqual(state.timelineDates(from: now), [now, midnight])
    }

    // MARK: - 表示の文

    func testClock() {
        XCTAssertEqual(WidgetText.clock(at(9, 5), now: now), "9:05")
        XCTAssertEqual(WidgetText.clock(at(22, 10, day: 6), now: now), "11/6 22:10")
    }

    func testRecordingTexts() {
        XCTAssertEqual(WidgetText.phone(nil), "—")
        XCTAssertNil(WidgetText.watch(nil))
        XCTAssertEqual(WidgetText.summary(nil), "LifeLog")
        var state = WidgetState(updated: now)
        XCTAssertEqual(WidgetText.summary(state), "LifeLog")
        state.phoneRecording = false
        XCTAssertEqual(WidgetText.phone(state), "停止中")
        XCTAssertEqual(WidgetText.summary(state), "停止中")
        // 時計から知らせが無ければ、時計の行は出さない
        XCTAssertNil(WidgetText.watch(state))
        state.watchRecording = true
        XCTAssertEqual(WidgetText.watch(state), "録音中")
        XCTAssertEqual(WidgetText.summary(state), "時計で録音中")
        XCTAssertTrue(WidgetText.anyRecording(state))
        state.phoneRecording = true
        XCTAssertEqual(WidgetText.phone(state), "録音中")
        XCTAssertEqual(WidgetText.summary(state), "録音中")
        // 録音中のはずの時計から知らせが途絶えた
        state.phoneRecording = false
        state.watchQuiet = true
        XCTAssertEqual(WidgetText.watch(state), "届いていません")
        XCTAssertEqual(WidgetText.summary(state), "時計が届いていません")
        XCTAssertFalse(WidgetText.anyRecording(state))
    }

    func testWatchFaceTexts() {
        XCTAssertEqual(WidgetText.inline(nil, onWatch: true), "LifeLog")
        var state = WidgetState(updated: now)
        state.watchRecording = true
        state.watchUnsent = 0
        // 時計の文字盤では「時計で」と言わない
        XCTAssertEqual(WidgetText.summary(state, onWatch: true), "録音中")
        XCTAssertEqual(WidgetText.watchHeadline(state), "録音中")
        state.watchUnsent = 2
        state.tasksDue = 3
        XCTAssertEqual(WidgetText.watchHeadline(state), "録音中・送っていない 2")
        XCTAssertEqual(WidgetText.inline(state, onWatch: true), "録音中・今日まで 3件")
        XCTAssertEqual(WidgetText.corner(state), "録音中・3件")
        state.watchRecording = false
        XCTAssertEqual(WidgetText.inline(state, onWatch: true), "停止中・今日まで 3件")
        XCTAssertEqual(WidgetText.corner(state), "今日まで 3件")
        state.tasksDue = 0
        XCTAssertEqual(WidgetText.corner(state), "停止中")
        XCTAssertEqual(WidgetText.corner(nil), "LifeLog")
    }

    func testTaskTexts() {
        var state = WidgetState(updated: now)
        XCTAssertEqual(WidgetText.tasks(state), "—")
        XCTAssertNil(WidgetText.openTasks(state))
        state.tasksDue = 0
        XCTAssertEqual(WidgetText.tasks(state), "今日まで 0件")
        state.tasksDue = 3
        XCTAssertEqual(WidgetText.tasks(state), "今日まで 3件")
        state.tasksOverdue = 1
        XCTAssertEqual(WidgetText.tasks(state), "今日まで 3件（期限切れ 1）")
        state.tasksOpen = 8
        XCTAssertEqual(WidgetText.openTasks(state), "まだのもの 全部で 8件")
        state.phoneRecording = true
        XCTAssertEqual(WidgetText.inline(state), "録音中・今日まで 3件")
    }

    func testEventTexts() {
        XCTAssertNil(WidgetText.event(nil, at: now))
        XCTAssertEqual(WidgetText.noEventText(nil), "—")
        var state = WidgetState(updated: now)
        XCTAssertEqual(WidgetText.noEventText(state), "予定なし")
        state.nextEvent = WidgetState.Event(title: "打ち合わせ", start: at(10, 30), end: at(11, 0))
        XCTAssertEqual(WidgetText.event(state, at: at(10, 0))?.time, "10:30")
        XCTAssertEqual(WidgetText.event(state, at: at(10, 0))?.title, "打ち合わせ")
        XCTAssertEqual(WidgetText.event(state, at: at(10, 30))?.time, "いま〜11:00")
        // 終わったら出さない（その次の予定はまだ届いていないので「—」）
        XCTAssertNil(WidgetText.event(state, at: at(11, 0)))
        XCTAssertEqual(WidgetText.noEventText(state), "—")
        // 明日の朝の予定は日付つき
        state.nextEvent = WidgetState.Event(title: "朝会", start: at(9, 0, day: 8), end: nil)
        XCTAssertEqual(WidgetText.event(state, at: at(23, 0))?.time, "11/8 9:00")
    }

    func testProcessedAndPCTexts() {
        var state = WidgetState(updated: now)
        XCTAssertNil(WidgetText.processed(state, at: now))
        XCTAssertNil(WidgetText.pc(state))
        state.lastProcessed = at(11, 52)
        XCTAssertEqual(WidgetText.processed(state, at: now), "文字にした 11:52")
        state.pcOK = true
        XCTAssertEqual(WidgetText.pc(state), "PC ○")
        state.pcOK = false
        XCTAssertEqual(WidgetText.pc(state), "PC ×")
        XCTAssertEqual(WidgetText.pc(state, long: true), "家の PC につながりません")
    }

    // MARK: - iPhone で作る中身（WidgetBridge）

    private func item(_ due: Date?, _ state: TaskBook.State = .open) -> TaskBook.Item {
        TaskBook.Item(what: "頼まれごと", due: due, said: now.addingTimeInterval(-3600), source: .manual, state: state)
    }

    func testTaskCounts() {
        // 相手を待っているもの（「待ち」にした・人に頼んだ）は、朝の読み上げと同じく今日まで・期限切れに数えない
        var waiting = item(day(-1))
        waiting.progress = .waiting
        var delegated = item(day(0))
        delegated.kind = .delegated
        let items = [item(day(0)), item(day(-1)), item(day(-3)), item(day(1)), item(nil), waiting, delegated,
                     item(day(0), .done), item(day(-1), .candidate), item(day(0), .rejected)]
        let counts = WidgetBridge.taskCounts(items, now: now)
        XCTAssertEqual(counts.due, 3)
        XCTAssertEqual(counts.overdue, 2)
        XCTAssertEqual(counts.open, 7)
    }

    func testWatchInfoCarriesOverdueAndWaiting() {
        var waiting = item(day(0))
        waiting.progress = .waiting
        let list = WatchInfo.taskItems([item(day(-1)), waiting, item(day(2))], now: now)
        XCTAssertEqual(list.map(\.late), [true, true, false])
        XCTAssertEqual(list.map(\.overdue), [true, nil, nil])
        XCTAssertEqual(list.map(\.waiting), [nil, true, nil])
    }

    func testWatchStateFromLedger() {
        let none = WidgetBridge.watchState(nil, now: now)
        XCTAssertNil(none.recording)
        XCTAssertNil(none.quiet)
        let fresh = WidgetBridge.watchState(RecordingLedger.State(at: now.addingTimeInterval(-10 * 60), recording: true, resting: false), now: now)
        XCTAssertEqual(fresh.recording, true)
        XCTAssertNil(fresh.quiet)
        let silent = WidgetBridge.watchState(RecordingLedger.State(at: now.addingTimeInterval(-45 * 60), recording: true, resting: true), now: now)
        XCTAssertEqual(silent.recording, true)
        XCTAssertEqual(silent.quiet, true)
        // 止めたあとは、古くても「停止中」
        let stopped = WidgetBridge.watchState(RecordingLedger.State(at: now.addingTimeInterval(-86400), recording: false, resting: false), now: now)
        XCTAssertEqual(stopped.recording, false)
        XCTAssertNil(stopped.quiet)
    }

    func testNextEventPrefersUpcoming() {
        func event(_ title: String, _ start: TimeInterval, _ end: TimeInterval) -> CalendarLink.Event {
            CalendarLink.Event(title: title, attendees: [], isWork: false,
                               start: now.addingTimeInterval(start), end: now.addingTimeInterval(end))
        }
        // 2時間前から続いている研修より、20分後の打ち合わせ
        let picked = WidgetBridge.nextEvent([event("研修", -7200, 3600), event("打ち合わせ", 1200, 4800)], now: now)
        XCTAssertEqual(picked?.title, "打ち合わせ")
        XCTAssertEqual(picked?.start, now.addingTimeInterval(1200))
        XCTAssertEqual(picked?.end, now.addingTimeInterval(4800))
        // 始まって5分の予定は、まだ「次」
        XCTAssertEqual(WidgetBridge.nextEvent([event("朝会", -300, 600), event("打ち合わせ", 1200, 4800)], now: now)?.title, "朝会")
        // これからの予定が無ければ、今やっているもの
        XCTAssertEqual(WidgetBridge.nextEvent([event("研修", -7200, 3600)], now: now)?.title, "研修")
        // 終わった予定は出さない
        XCTAssertNil(WidgetBridge.nextEvent([event("昼", -7200, -60)], now: now))
        XCTAssertNil(WidgetBridge.nextEvent([], now: now))
        // 名前の無い予定は「予定」
        XCTAssertEqual(WidgetBridge.nextEvent([event("", 600, 1200)], now: now)?.title, "予定")
    }
}

import XCTest
@testable import LifeLog

/// s23（2026-11-23）「録音が止まらない」の決まり（Shared/Audio/S23Rec.swift）。
/// 届5: 本物の AVAudioSession は CI で鳴らせないので、中断の知らせを偽って判断（ResumeFlow）に流す。名前はすべて作り物。
@MainActor
final class S23RecTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: 届5 始まった → 終わりが来ない → 1 分後に戻る

    func testBeganWithoutEndedResumesAfterOneMinute() {
        var flow = S23Rec.ResumeFlow(probeOn: false)
        XCTAssertEqual(flow.step(.began, now: t0), .pause(timer: 60, probe: nil))
        XCTAssertTrue(flow.waiting)
        // 「終わった」は来ない。1 分の予約が鳴る
        XCTAssertEqual(flow.step(.timer, now: t0.addingTimeInterval(60)), .tryNow(way: "timer", quiet: false))
        XCTAssertEqual(flow.step(.resumed, now: t0.addingTimeInterval(60.5)), .done(way: "timer", seconds: 60.5))
        XCTAssertFalse(flow.waiting)
        // 戻ったあとの遅れた「終わった」は何もしない
        XCTAssertEqual(flow.step(.ended, now: t0.addingTimeInterval(70)), .nothing)
    }

    func testEndedResumesRightAway() {
        var flow = S23Rec.ResumeFlow()
        _ = flow.step(.began, now: t0)
        XCTAssertEqual(flow.step(.ended, now: t0.addingTimeInterval(8)), .tryNow(way: "ended", quiet: false))
        XCTAssertEqual(flow.step(.resumed, now: t0.addingTimeInterval(8)), .done(way: "ended", seconds: 8))
    }

    func testFailuresBackOffAndNotifyOnce() {
        var flow = S23Rec.ResumeFlow(probeOn: false)
        _ = flow.step(.began, now: t0)
        _ = flow.step(.ended, now: t0.addingTimeInterval(5))
        XCTAssertEqual(flow.step(.failed, now: t0.addingTimeInterval(5)), .retry(after: 15, notify: true))
        XCTAssertEqual(flow.step(.timer, now: t0.addingTimeInterval(20)), .tryNow(way: "retry", quiet: false))
        XCTAssertEqual(flow.step(.failed, now: t0.addingTimeInterval(20)), .retry(after: 30, notify: false))
        _ = flow.step(.timer, now: t0.addingTimeInterval(50))
        XCTAssertEqual(flow.step(.failed, now: t0.addingTimeInterval(50)), .retry(after: 60, notify: false))
        // 開いたら 0 から数え直して、すぐ試す
        XCTAssertEqual(flow.step(.now("open"), now: t0.addingTimeInterval(90)), .tryNow(way: "open", quiet: false))
        XCTAssertEqual(flow.step(.failed, now: t0.addingTimeInterval(90)), .retry(after: 15, notify: true))
        _ = flow.step(.now("button"), now: t0.addingTimeInterval(100))
        XCTAssertEqual(flow.step(.resumed, now: t0.addingTimeInterval(100)), .done(way: "button", seconds: 100))
    }

    func testWaitsMatchRecorder() {
        XCTAssertEqual(S23Rec.ResumeFlow.wait(0), 15)
        XCTAssertEqual(S23Rec.ResumeFlow.wait(99), 300)
        XCTAssertEqual(Recorder.resumeWait(2), S23Rec.ResumeFlow.wait(2))
    }

    // MARK: 止6 音が止んだら 1 分待たずに

    func testProbeTriesQuietlyWhenOtherAudioStops() {
        var flow = S23Rec.ResumeFlow(probeOn: true)
        XCTAssertEqual(flow.step(.began, now: t0), .pause(timer: 60, probe: 5))
        XCTAssertEqual(flow.step(.probe(otherAudio: true), now: t0.addingTimeInterval(5)), .nothing)
        XCTAssertEqual(flow.step(.probe(otherAudio: false), now: t0.addingTimeInterval(10)), .tryNow(way: "probe", quiet: true))
        // 見回りの試しがだめでも、知らせず予約もそのまま
        XCTAssertEqual(flow.step(.failed, now: t0.addingTimeInterval(10)), .nothing)
        XCTAssertTrue(flow.waiting)
        XCTAssertEqual(flow.step(.probe(otherAudio: false), now: t0.addingTimeInterval(15)), .tryNow(way: "probe", quiet: true))
        XCTAssertEqual(flow.step(.resumed, now: t0.addingTimeInterval(15)), .done(way: "probe", seconds: 15))
    }

    func testProbeOffOrTooEarlyDoesNothing() {
        var off = S23Rec.ResumeFlow(probeOn: false)
        _ = off.step(.began, now: t0)
        XCTAssertEqual(off.step(.probe(otherAudio: false), now: t0.addingTimeInterval(10)), .nothing)
        var early = S23Rec.ResumeFlow(probeOn: true)
        _ = early.step(.began, now: t0)
        XCTAssertEqual(early.step(.probe(otherAudio: false), now: t0.addingTimeInterval(2)), .nothing)
    }

    func testWatchKick() {
        XCTAssertTrue(S23Rec.watchKick(elapsed: 5, otherAudio: false, probeOn: true, legacy: false))
        XCTAssertFalse(S23Rec.watchKick(elapsed: 4, otherAudio: false, probeOn: true, legacy: false))
        XCTAssertFalse(S23Rec.watchKick(elapsed: 30, otherAudio: true, probeOn: true, legacy: false))
        XCTAssertFalse(S23Rec.watchKick(elapsed: 30, otherAudio: false, probeOn: false, legacy: false))
        XCTAssertFalse(S23Rec.watchKick(elapsed: 30, otherAudio: false, probeOn: true, legacy: true))
    }

    // MARK: 止4 電話

    func testCallEndedTriesQuietly() {
        var flow = S23Rec.ResumeFlow(probeOn: false)
        _ = flow.step(.began, now: t0)
        XCTAssertEqual(flow.step(.callEnded, now: t0.addingTimeInterval(120)), .tryNow(way: "call", quiet: true))
        XCTAssertEqual(flow.step(.failed, now: t0.addingTimeInterval(120)), .nothing)
        XCTAssertEqual(flow.step(.ended, now: t0.addingTimeInterval(121)), .tryNow(way: "ended", quiet: false))
    }

    // MARK: 止16 前の動き

    func testLegacyTriesOnceAndGivesUp() {
        var flow = S23Rec.ResumeFlow(legacy: true, probeOn: true)
        XCTAssertEqual(flow.step(.began, now: t0), .pause(timer: nil, probe: nil))
        XCTAssertEqual(flow.step(.timer, now: t0.addingTimeInterval(60)), .nothing)
        XCTAssertEqual(flow.step(.probe(otherAudio: false), now: t0.addingTimeInterval(10)), .nothing)
        XCTAssertEqual(flow.step(.now("open"), now: t0.addingTimeInterval(20)), .nothing)
        XCTAssertEqual(flow.step(.callEnded, now: t0.addingTimeInterval(20)), .nothing)
        XCTAssertEqual(flow.step(.ended, now: t0.addingTimeInterval(30)), .tryNow(way: "ended", quiet: false))
        XCTAssertEqual(flow.step(.failed, now: t0.addingTimeInterval(30)), .giveUp)
        XCTAssertFalse(flow.waiting)
    }

    func testSecondBeganKeepsStart() {
        var flow = S23Rec.ResumeFlow(probeOn: false)
        _ = flow.step(.began, now: t0)
        _ = flow.step(.began, now: t0.addingTimeInterval(30))
        _ = flow.step(.ended, now: t0.addingTimeInterval(40))
        XCTAssertEqual(flow.step(.resumed, now: t0.addingTimeInterval(40)), .done(way: "ended", seconds: 40))
    }

    func testSettingsDefaults() {
        let defaults = UserDefaults(suiteName: "s23-test-\(UUID().uuidString)")!
        XCTAssertTrue(S23Rec.isOn(S23Rec.probeKey, defaults: defaults))
        XCTAssertTrue(S23Rec.isOn(S23Rec.callKey, defaults: defaults))
        XCTAssertFalse(S23Rec.isOn(S23Rec.coverByPhoneKey, defaults: defaults))
        XCTAssertFalse(S23Rec.isOn(S23Rec.coverByWatchKey, defaults: defaults))
        XCTAssertFalse(S23Rec.isOn(S23Rec.legacyKey, defaults: defaults))
        var context: [String: Any] = [:]
        defaults.set(true, forKey: S23Rec.legacyKey)
        S23Rec.addSettings(to: &context, defaults: defaults)
        XCTAssertEqual(context[S23Rec.legacyKey] as? Bool, true)
        XCTAssertNil(context[S23Rec.coverByPhoneKey])
        let watch = UserDefaults(suiteName: "s23-test-\(UUID().uuidString)")!
        S23Rec.readSettings(context, defaults: watch)
        XCTAssertTrue(S23Rec.isOn(S23Rec.legacyKey, defaults: watch))
    }

    // MARK: 止5 理由

    func testReasonCode() {
        let onTheMinute = utc.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 6, minute: 30, second: 1))!
        let midMinute = onTheMinute.addingTimeInterval(20)
        XCTAssertEqual(S23Rec.reasonCode(raw: 0, inCall: true, began: midMinute, calendar: utc), "call")
        XCTAssertEqual(S23Rec.reasonCode(raw: 1, inCall: false, began: midMinute, calendar: utc), "suspended")
        XCTAssertEqual(S23Rec.reasonCode(raw: 2, inCall: false, began: midMinute, calendar: utc), "micMuted")
        XCTAssertEqual(S23Rec.reasonCode(raw: 4, inCall: false, began: midMinute, calendar: utc), "route")
        XCTAssertEqual(S23Rec.reasonCode(raw: 0, inCall: false, began: onTheMinute, calendar: utc), "alarm?")
        XCTAssertEqual(S23Rec.reasonCode(raw: nil, inCall: false, began: midMinute, calendar: utc), "interrupt")
        XCTAssertEqual(S23Rec.reasonLabel("alarm?"), "アラーム？（見立て）")
        XCTAssertEqual(S23Rec.reasonLabel("xyz"), "不明")
    }

    // MARK: 止1 数

    func testStopsLogAndSummary() {
        let day = HolidayRules.dayKey(t0, calendar: utc)
        var list: [S23Rec.Stop] = []
        list = S23Rec.adding(list, S23Rec.Stop(start: t0.timeIntervalSince1970, reason: "alarm?"), now: t0)
        list = S23Rec.failing(list)
        list = S23Rec.closing(list, end: t0.addingTimeInterval(75), way: "retry")
        list = S23Rec.adding(list, S23Rec.Stop(start: t0.timeIntervalSince1970 + 100, reason: "call"), now: t0)
        list = S23Rec.closing(list, end: t0.addingTimeInterval(110), way: "call")
        list = S23Rec.adding(list, S23Rec.Stop(start: t0.timeIntervalSince1970 + 200, reason: "drill"), now: t0)
        list = S23Rec.adding(list, S23Rec.Stop(start: t0.timeIntervalSince1970 + 300), now: t0)
        let s = S23Rec.summary(list, day: day, calendar: utc)
        XCTAssertEqual(s["n"] as? Int, 3)  // 練習は数えない
        XCTAssertEqual(s["ok"] as? Int, 2)
        XCTAssertEqual(s["open"] as? Int, 1)
        XCTAssertEqual(s["tries"] as? Int, 1)
        XCTAssertEqual(s["max"] as? Int, 75)
        XCTAssertEqual((s["way"] as? [String: Int])?["call"], 1)
        // 辞書に戻しても同じ
        XCTAssertEqual(list.map(\.dict).compactMap(S23Rec.Stop.init(dict:)), list)
        // 14 日より古いものは捨てる
        let later = S23Rec.adding(list, S23Rec.Stop(start: t0.timeIntervalSince1970 + 15 * 86400), now: t0.addingTimeInterval(15 * 86400))
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(S23Rec.bucket(10), "lt15")
        XCTAssertEqual(S23Rec.bucket(75), "lt300")
        XCTAssertEqual(S23Rec.bucket(600), "ge300")
    }

    func testStoppedIsNotCountedAsResumed() {
        let day = HolidayRules.dayKey(t0, calendar: utc)
        var list = S23Rec.adding([], S23Rec.Stop(start: t0.timeIntervalSince1970), now: t0)
        list = S23Rec.closing(list, end: t0.addingTimeInterval(30), way: "stopped")
        let s = S23Rec.summary(list, day: day, calendar: utc)
        XCTAssertEqual(s["ok"] as? Int, 0)
        XCTAssertEqual(s["open"] as? Int, 0)
    }

    // MARK: 止11 毎日同じ時刻

    func testRecurringSlots() {
        let day0 = utc.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 6, minute: 30))!
        let starts = (0..<4).map { day0.addingTimeInterval(Double($0) * 86400 + Double($0 * 60)) }  // 6:30・6:31・6:32・6:33
            + [day0.addingTimeInterval(2 * 86400 + 5 * 3600)]  // 1 回だけの 11:30
        let now = day0.addingTimeInterval(4 * 86400 + 3600)
        // 記録を始めて 7 日たつまでは空
        XCTAssertEqual(S23Rec.recurringSlots(starts, since: now.addingTimeInterval(-3 * 86400), now: now, calendar: utc), [])
        let slots = S23Rec.recurringSlots(starts, since: now.addingTimeInterval(-8 * 86400), now: now, calendar: utc)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first.map { $0 / 60 }, 6)
        // 次は明日の その時刻＋1 分（今日の分は過ぎている）
        let next = S23Rec.nextCheck(slots, now: now, calendar: utc)
        XCTAssertNotNil(next)
        XCTAssertEqual(next.map { utc.component(.hour, from: $0) }, 6)
        XCTAssertGreaterThan(next!, now)
        XCTAssertNil(S23Rec.nextCheck([], now: now, calendar: utc))
    }

    // MARK: 止13・止14・止15・止3・止12

    func testResumedText() {
        XCTAssertNil(S23Rec.resumedText(59))
        XCTAssertEqual(S23Rec.resumedText(60), "1分止まっていました。いまは録れています")
        XCTAssertEqual(S23Rec.resumedText(185), "3分止まっていました。いまは録れています")
    }

    func testHotSaving() {
        XCTAssertFalse(S23Rec.hotSaving(on: true, thermal: 1))
        XCTAssertTrue(S23Rec.hotSaving(on: true, thermal: 2))
        XCTAssertFalse(S23Rec.hotSaving(on: false, thermal: 3))
    }

    func testDrillText() {
        XCTAssertEqual(S23Rec.drillText(ok: true, seconds: 2.6), "○ 3秒で戻りました")
        XCTAssertTrue(S23Rec.drillText(ok: false, seconds: 10).hasPrefix("×"))
        let parsed = S23Rec.parseDrill("1800000000|1|3")
        XCTAssertEqual(parsed?.ok, true)
        XCTAssertEqual(parsed?.seconds, 3)
        XCTAssertNil(S23Rec.parseDrill("bad"))
    }

    func testRouteShouldAct() {
        XCTAssertTrue(S23Rec.routeShouldAct(1))
        XCTAssertTrue(S23Rec.routeShouldAct(2))
        XCTAssertFalse(S23Rec.routeShouldAct(3))
        XCTAssertFalse(S23Rec.routeShouldAct(nil))
    }

    func testTicksClipAndSkipDrillAndShort() {
        let dayStart = utc.startOfDay(for: t0)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let stops = [
            S23Rec.Stop(start: dayStart.timeIntervalSince1970 - 30, end: dayStart.timeIntervalSince1970 + 60, reason: "alarm?"),
            S23Rec.Stop(start: dayStart.timeIntervalSince1970 + 3600, end: dayStart.timeIntervalSince1970 + 3602),
            S23Rec.Stop(start: dayStart.timeIntervalSince1970 + 7200, end: dayStart.timeIntervalSince1970 + 7300, reason: "drill"),
            S23Rec.Stop(start: dayStart.timeIntervalSince1970 + 9000, reason: "call"),
        ]
        let now = dayStart.addingTimeInterval(9600)
        let ticks = S23Rec.ticks(stops, device: "watch", dayStart: dayStart, dayEnd: dayEnd, now: now)
        XCTAssertEqual(ticks.count, 2)
        XCTAssertEqual(ticks.first?.start, dayStart)
        XCTAssertEqual(ticks.last?.end, now)
        XCTAssertEqual(ticks.last?.label, "時計・電話")
    }
}

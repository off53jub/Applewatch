import XCTest
@testable import LifeLog

/// 休日のライフログ（2026-11-21。s19。Shared/Audio/HolidayRules.swift・LifeLog/Holiday.swift）
final class HolidayTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - 休1 休みの理由

    func testDayOffReason() {
        let cal = tokyo
        XCTAssertEqual(DayOff.reason(at(2026, 11, 21, 12), allDay: [], calendar: cal), HolidayRules.whyWeekend)   // 土曜
        XCTAssertNil(DayOff.reason(at(2026, 11, 24, 12), allDay: [], calendar: cal))                              // 火曜
        let holiday = DayOff.AllDay(title: "勤労感謝の日", holidayCalendar: true)
        XCTAssertEqual(DayOff.reason(at(2026, 11, 23, 12), allDay: [holiday], calendar: cal), HolidayRules.whyHoliday)
        XCTAssertEqual(DayOff.reason(at(2026, 11, 25, 12), allDay: [DayOff.AllDay(title: "有休")], calendar: cal),
                       HolidayRules.whyLeave)
        // 半休は休みではない・祝日のカレンダーの行事も休みではない
        XCTAssertNil(DayOff.reason(at(2026, 11, 25, 12), allDay: [DayOff.AllDay(title: "午後休")], calendar: cal))
        XCTAssertNil(DayOff.reason(at(2026, 11, 25, 12), allDay: [DayOff.AllDay(title: "七五三", holidayCalendar: true)], calendar: cal))
        // 土日と祝日が重なれば「土日」
        XCTAssertEqual(DayOff.reason(at(2026, 11, 22, 12), allDay: [holiday], calendar: cal), HolidayRules.whyWeekend)
        // isOff と食い違わない
        for d in 20...30 {
            let date = at(2026, 11, d, 12)
            XCTAssertEqual(DayOff.reason(date, allDay: [], calendar: cal) != nil, DayOff.isOff(date, allDay: [], calendar: cal))
        }
    }

    func testHolidayFileShape() throws {
        let cal = tokyo
        let drinks = [at(2026, 11, 22, 19), at(2026, 11, 22, 20), at(2026, 11, 23, 1)]
        let notes = [HolidayNote(kind: "best", day: "2026-11-22", at: at(2026, 11, 22, 21, 5), text: "テスト"),
                     HolidayNote(kind: "payment", day: "2026-11-22", at: at(2026, 11, 22, 13), text: "X", ref: "tap-1"),
                     HolidayNote(kind: "golf", day: "2026-11-21", at: at(2026, 11, 21, 15), text: "Y")]
        let places = [HolidayPlaceAnswer(day: "2026-11-22", at: at(2026, 11, 22, 15), name: "場所A", answer: "yes")]
        let data = try XCTUnwrap(HolidayExport.json(day: "2026-11-22", why: "土日", drinks: drinks, notes: notes, places: places,
                                                    calendar: cal))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["day"] as? String, "2026-11-22")
        let dayOff = try XCTUnwrap(object["dayOff"] as? [String: Any])
        XCTAssertEqual(dayOff["off"] as? Bool, true)
        XCTAssertEqual(dayOff["why"] as? String, "土日")
        let drink = try XCTUnwrap(object["drinks"] as? [String: Any])
        XCTAssertEqual(drink["count"] as? Int, 2)   // 次の日の 1 時の分は入れない
        let rows = try XCTUnwrap(object["notes"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["payment", "best"])   // その日の分だけ・時刻の順
        XCTAssertEqual(rows.first?["ref"] as? String, "tap-1")
        XCTAssertEqual((object["places"] as? [[String: Any]])?.first?["answer"] as? String, "yes")

        // 休みでない日は off: false だけ（why・drinks・notes は入れない）
        let plain = try XCTUnwrap(HolidayExport.json(day: "2026-11-24", why: nil, drinks: [], notes: [], places: [], calendar: cal))
        let o2 = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertEqual((o2["dayOff"] as? [String: Any])?["off"] as? Bool, false)
        XCTAssertNil((o2["dayOff"] as? [String: Any])?["why"])
        XCTAssertNil(o2["drinks"])
        XCTAssertNil(o2["notes"])
        XCTAssertEqual(HolidayExport.fileName("2026-11-22"), "lifelog-holiday-2026-11-22.json")
    }

    // MARK: - 知らせの上限

    func testNoticeCaps() {
        let day = "2026-11-22"
        var counts: [String: Int] = [:]
        XCTAssertFalse(HolidayNoticeRules.allowed(holiday: false, enabled: true, kind: "best", counts: counts, day: day))
        XCTAssertFalse(HolidayNoticeRules.allowed(holiday: true, enabled: false, kind: "best", counts: counts, day: day))
        XCTAssertTrue(HolidayNoticeRules.allowed(holiday: true, enabled: true, kind: "best", counts: counts, day: day))
        counts = HolidayRules.bumped(counts, "best", day: day)
        XCTAssertFalse(HolidayNoticeRules.allowed(holiday: true, enabled: true, kind: "best", counts: counts, day: day))  // 1 日 1 回
        // 滞在の直後は 3 回まで
        for _ in 0..<3 {
            XCTAssertTrue(HolidayNoticeRules.allowed(holiday: true, enabled: true, kind: "place", counts: counts, day: day))
            counts = HolidayRules.bumped(counts, "place", day: day)
        }
        XCTAssertFalse(HolidayNoticeRules.allowed(holiday: true, enabled: true, kind: "place", counts: counts, day: day))
        // 合計の上限
        let full = [day + "|total": HolidayNoticeRules.dailyCap]
        XCTAssertFalse(HolidayNoticeRules.allowed(holiday: true, enabled: true, kind: "golf", counts: full, day: day))
        // 次の日は数え直す（bumped は今日の分だけ残す）
        let next = HolidayRules.bumped(counts, "best", day: "2026-11-23")
        XCTAssertEqual(HolidayRules.count(next, "place", day: day), 0)
        XCTAssertEqual(HolidayRules.count(next, "best", day: "2026-11-23"), 1)
    }

    func testAskAfterStayOnlyShortUnknownStays() {
        let m: TimeInterval = 60
        XCTAssertFalse(HolidayNoticeRules.shouldAskAfterStay(known: true, stay: 20 * m, placeAskOn: true))
        XCTAssertFalse(HolidayNoticeRules.shouldAskAfterStay(known: false, stay: 10 * m, placeAskOn: true))
        XCTAssertTrue(HolidayNoticeRules.shouldAskAfterStay(known: false, stay: 20 * m, placeAskOn: true))
        // 30 分より長い所は 91 が聞いている
        XCTAssertFalse(HolidayNoticeRules.shouldAskAfterStay(known: false, stay: 45 * m, placeAskOn: true))
        XCTAssertTrue(HolidayNoticeRules.shouldAskAfterStay(known: false, stay: 45 * m, placeAskOn: false))
    }

    func testCheckupLinesAreFacts() {
        let now = at(2026, 11, 22, 9)
        let lines = HolidayNoticeRules.checkupLines(watchBattery: 0.42, watchCharging: false, watchRecording: true,
                                                    watchSeen: now.addingTimeInterval(-600), phoneBattery: 0.8,
                                                    plaudLast: at(2026, 11, 21, 20, 8), now: now)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("42%（少なめ）"))
        XCTAssertTrue(lines[0].contains("録音中"))
        XCTAssertEqual(lines[1], "iPhone: 80%")
        XCTAssertTrue(lines[2].hasPrefix("PLAUD の最後の取り込み: "))
        let old = HolidayNoticeRules.checkupLines(watchBattery: 0.9, watchCharging: nil, watchRecording: nil,
                                                  watchSeen: now.addingTimeInterval(-3 * 3600), phoneBattery: nil, plaudLast: nil, now: now)
        XCTAssertTrue(old[0].contains("届いていません"))
        XCTAssertTrue(old[2].hasSuffix("分からない"))
        XCTAssertTrue(HolidayNoticeRules.isCheckupHour(at(2026, 11, 22, 9), calendar: tokyo))
        XCTAssertFalse(HolidayNoticeRules.isCheckupHour(at(2026, 11, 22, 18), calendar: tokyo))
    }

    func testPaymentBody() {
        XCTAssertTrue(HolidayNoticeRules.paymentBody(shop: "", amount: 0).contains("どこでいくら"))
        XCTAssertTrue(HolidayNoticeRules.paymentBody(shop: "店A", amount: 1200).hasPrefix("店Aで ¥"))
        XCTAssertTrue(HolidayNoticeRules.paymentBody(shop: "", amount: 500).hasPrefix("¥"))
    }

    // MARK: - 時計の決まり（休8・休9・休13・休17）

    func testLowBatteryWarnsOncePerHoliday() {
        let today = "2026-11-22"
        XCTAssertTrue(HolidayRules.shouldWarnLowBattery(enabled: true, holiday: true, level: 0.19, charging: false,
                                                        warnedDay: nil, today: today))
        XCTAssertFalse(HolidayRules.shouldWarnLowBattery(enabled: true, holiday: true, level: 0.19, charging: false,
                                                         warnedDay: today, today: today))
        XCTAssertFalse(HolidayRules.shouldWarnLowBattery(enabled: true, holiday: false, level: 0.19, charging: false,
                                                         warnedDay: nil, today: today))
        XCTAssertFalse(HolidayRules.shouldWarnLowBattery(enabled: true, holiday: true, level: 0.19, charging: true,
                                                         warnedDay: nil, today: today))
        XCTAssertFalse(HolidayRules.shouldWarnLowBattery(enabled: true, holiday: true, level: 0.25, charging: false,
                                                         warnedDay: nil, today: today))
        XCTAssertFalse(HolidayRules.shouldWarnLowBattery(enabled: false, holiday: true, level: 0.1, charging: false,
                                                         warnedDay: nil, today: today))
        XCTAssertFalse(HolidayRules.shouldWarnLowBattery(enabled: true, holiday: true, level: nil, charging: false,
                                                         warnedDay: nil, today: today))
        let now = at(2026, 11, 22, 10)
        XCTAssertTrue(HolidayRules.isHolidayToday("2026-11-22", now: now, calendar: tokyo))
        XCTAssertFalse(HolidayRules.isHolidayToday("2026-11-21", now: now, calendar: tokyo))   // 古い知らせは使わない
        XCTAssertFalse(HolidayRules.isHolidayToday("", now: now, calendar: tokyo))
    }

    func testAwayHoldAndBatterySamples() {
        XCTAssertTrue(HolidayRules.awayHold(mode: true, away: true, charging: false))
        XCTAssertFalse(HolidayRules.awayHold(mode: false, away: true, charging: false))   // 既定はオフ
        XCTAssertFalse(HolidayRules.awayHold(mode: true, away: false, charging: false))
        XCTAssertFalse(HolidayRules.awayHold(mode: true, away: true, charging: true))

        let t0 = at(2026, 11, 22, 8)
        XCTAssertTrue(HolidayRules.batterySampleDue(last: nil, now: t0))
        XCTAssertFalse(HolidayRules.batterySampleDue(last: t0.timeIntervalSince1970, now: t0.addingTimeInterval(1800)))
        var samples: [[Double]] = []
        // 溜めていない 2 時間で 10% 減り、溜めていた 2 時間で 6% 減った
        let rows: [(Double, Double, Bool)] = [(0, 0.9, false), (1, 0.85, false), (2, 0.8, false),
                                              (3, 0.77, true), (4, 0.74, true), (5, 0.71, true)]
        for (h, level, holding) in rows {
            samples = HolidayRules.addingSample(samples, time: t0.addingTimeInterval(h * 3600), level: level, holding: holding)
        }
        XCTAssertEqual(HolidayRules.drainPerHour(samples, holding: false), 5)
        XCTAssertEqual(HolidayRules.drainPerHour(samples, holding: true), 3)
        XCTAssertNil(HolidayRules.drainPerHour(Array(samples.prefix(1)), holding: false))
        // 数の上限
        var many: [[Double]] = []
        for i in 0..<60 { many = HolidayRules.addingSample(many, time: t0.addingTimeInterval(Double(i) * 3600), level: 0.5, holding: false) }
        XCTAssertEqual(many.count, HolidayRules.batterySampleLimit)
    }

    func testCrowdAndCarMarks() {
        let now = at(2026, 11, 22, 20)
        XCTAssertTrue(HolidayRules.crowdActive(until: now.addingTimeInterval(60).timeIntervalSince1970, now: now))
        XCTAssertFalse(HolidayRules.crowdActive(until: now.addingTimeInterval(-60).timeIntervalSince1970, now: now))
        XCTAssertFalse(HolidayRules.crowdActive(until: 0, now: now))
        XCTAssertFalse(HolidayRules.crowdActive(until: nil, now: now))

        let since = now.timeIntervalSince1970
        XCTAssertTrue(HolidayRules.inCar(chunkStart: now.addingTimeInterval(-60), chunkEnd: now.addingTimeInterval(60), carSince: since))
        XCTAssertFalse(HolidayRules.inCar(chunkStart: now.addingTimeInterval(-300), chunkEnd: now.addingTimeInterval(-60), carSince: since))
        XCTAssertFalse(HolidayRules.inCar(chunkStart: now, chunkEnd: now, carSince: 0))
        XCTAssertFalse(HolidayRules.inCar(chunkStart: nil, chunkEnd: nil, carSince: since))

        // 家の PC への問いに inCar=1 が付く（無ければ付けない）
        let with = WatchDelivery.jobQuery(name: "a.m4a", chunkStart: now, chunkEnd: now, sent: now, hints: nil, weights: nil, car: true)
        XCTAssertEqual(with.first { $0.name == "inCar" }?.value, "1")
        let without = WatchDelivery.jobQuery(name: "a.m4a", chunkStart: now, chunkEnd: now, sent: now, hints: nil, weights: nil)
        XCTAssertNil(without.first { $0.name == "inCar" })

        // 家の PC への会話の記録に inCar・vehicle（印のある会話だけ）
        let body = Data(#"{"conversations":[{"start":1},{"start":2}],"work":[]}"#.utf8)
        let marked = PCRecords.markCar(body, flags: [false, true])
        let list = (try? JSONSerialization.jsonObject(with: marked) as? [String: Any])?["conversations"] as? [[String: Any]]
        XCTAssertNil(list?[0]["inCar"])
        XCTAssertEqual(list?[1]["inCar"] as? Bool, true)
        XCTAssertEqual(list?[1]["vehicle"] as? String, "car")
        XCTAssertEqual(PCRecords.markCar(body, flags: [false, false]), body)   // 印が無ければそのまま
        XCTAssertEqual(PCRecords.markCar(body, flags: [true]), body)           // 数が合わなければそのまま
    }

    // MARK: - 休45 心拍変動

    func testHRVIsExported() throws {
        var day = HealthExport.Day(day: "2026-11-22")
        XCTAssertTrue(day.isEmpty)
        day.hrv = 41.26
        day.hrvMin = 20
        day.hrvMax = 80
        XCTAssertFalse(day.isEmpty)
        let data = try XCTUnwrap(HealthExport.json(day, calendar: tokyo))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try XCTUnwrap((object["data"] as? [String: Any])?["metrics"] as? [[String: Any]])
        let hrv = try XCTUnwrap(metrics.first { $0["name"] as? String == "heart_rate_variability" })
        XCTAssertEqual(hrv["units"] as? String, "ms")
        let row = try XCTUnwrap((hrv["data"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["qty"] as? Double, 41.3)
        XCTAssertEqual(row["Min"] as? Double, 20)
    }

    @MainActor
    func testHealthAsksForHRVOnce() {
        let version: Int = HealthLink.readsVersion
        XCTAssertGreaterThanOrEqual(version, 3)
    }

    // MARK: - 休16 一緒にいた人の確かめ

    func testWithPeopleGroupIsKept() throws {
        let json = """
        {"available": true, "items": [{"id": "wp-1", "group": "with_people", "answer": "yesno", "text": "この時間に一緒にいたのは A さん（仮）？",
          "evidence": [{"text": "予定", "source": "calendar", "day": "2026-11-22"}]}]}
        """
        let items = try XCTUnwrap(KnowMeRules.decodeQuestions(Data(json.utf8)))
        XCTAssertEqual(items.first?.group, "with_people")
        XCTAssertEqual(items.first?.answer, "yesno")
    }

    /// 2026-11-22: 時計の録音が止まりかけた回数と自動で戻せた回数は、中断の数と同じ「今日の数」で数え、ほかの名前とぶつからない
    func testWatchStallCountsAreSeparateDailyCounts() {
        let keys = [HolidayRules.interruptionsKey, HolidayRules.resumedKey, HolidayRules.stallsKey, HolidayRules.autoResumedKey,
                    HolidayRules.lastStallKey, HolidayRules.watchBuildKey, HolidayRules.batteryAtKey, HolidayRules.awayHoldingKey,
                    HolidayRules.crowdKey]
        XCTAssertEqual(Set(keys).count, keys.count)
        var counts: [String: Int] = [:]
        counts = HolidayRules.bumped(counts, HolidayRules.stallsKey, day: "2026-11-22")
        counts = HolidayRules.bumped(counts, HolidayRules.stallsKey, day: "2026-11-22")
        counts = HolidayRules.bumped(counts, HolidayRules.autoResumedKey, day: "2026-11-22")
        XCTAssertEqual(HolidayRules.count(counts, HolidayRules.stallsKey, day: "2026-11-22"), 2)
        XCTAssertEqual(HolidayRules.count(counts, HolidayRules.autoResumedKey, day: "2026-11-22"), 1)
        XCTAssertEqual(HolidayRules.count(counts, HolidayRules.stallsKey, day: "2026-11-23"), 0)
    }
}

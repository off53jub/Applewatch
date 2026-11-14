import XCTest
import HealthKit
@testable import LifeLog

final class HealthExportTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testDueDaysWaitUntilJustAfterMidnight() {
        let cal = tokyo
        // 2026-11-15 から、次の日の 0:30 を過ぎたら書く（前は次の日の昼）。5/21 0:20: 5/19 は済み、5/20 はまだ
        XCTAssertEqual(HealthExport.dueDays(now: at(2026, 5, 21, 0, 20), done: [], first: "2026-05-19", calendar: cal), ["2026-05-19"])
        XCTAssertEqual(HealthExport.dueDays(now: at(2026, 5, 21, 0, 30), done: [], first: "2026-05-19", calendar: cal),
                       ["2026-05-19", "2026-05-20"])
        // 昼に開いたとき（夜中に書けなかった分の受け皿）も同じ日を書く
        XCTAssertEqual(HealthExport.dueDays(now: at(2026, 5, 21, 12), done: ["2026-05-19"], first: "2026-05-19", calendar: cal),
                       ["2026-05-20"])
    }

    func testDueDaysSkipDoneAndLimit() {
        let days = HealthExport.dueDays(now: at(2026, 6, 30, 13), done: ["2026-05-19"], first: "2026-05-19", limit: 3, calendar: tokyo)
        XCTAssertEqual(days, ["2026-05-20", "2026-05-21", "2026-05-22"])
    }

    func testJSONHasHealthAutoExportShape() throws {
        var day = HealthExport.Day(day: "2026-05-19")
        day.steps = 9157
        day.heartMin = 45; day.heartMax = 130; day.heartAverage = 74.26
        day.resting = 61
        day.sleep = .init(start: at(2026, 5, 19, 1, 30), end: at(2026, 5, 19, 7, 0), asleep: 5 * 3600, inBed: nil,
                          deep: 3600, rem: 3600, core: 3 * 3600, awake: 1800)
        let data = try XCTUnwrap(HealthExport.json(day, calendar: tokyo))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try XCTUnwrap((root["data"] as? [String: Any])?["metrics"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0["name"] as! String, ($0["data"] as! [[String: Any]])[0]) })
        XCTAssertEqual(byName["step_count"]?["qty"] as? Int, 9157)
        XCTAssertEqual(byName["step_count"]?["date"] as? String, "2026-05-19T00:00:00+09:00")
        XCTAssertEqual(byName["heart_rate"]?["Avg"] as? Double, 74.3)
        XCTAssertEqual(byName["resting_heart_rate"]?["qty"] as? Double, 61)
        let sleep = try XCTUnwrap(byName["sleep_analysis"])
        XCTAssertEqual(sleep["sleepStart"] as? String, "2026-05-19T01:30:00+09:00")
        XCTAssertEqual(sleep["asleep"] as? Double, 5)
        XCTAssertNil(sleep["inBed"])
    }

    func testEmptyDayWritesNoMetrics() throws {
        let day = HealthExport.Day(day: "2026-05-19")
        XCTAssertTrue(day.isEmpty)
        let data = try XCTUnwrap(HealthExport.json(day, calendar: tokyo))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(((root["data"] as? [String: Any])?["metrics"] as? [Any])?.count, 0)
    }

    func testSleepUsesLongestSourceOnly() {
        typealias V = HKCategoryValueSleepAnalysis
        let from = at(2026, 5, 18, 18), to = at(2026, 5, 19, 12)
        let samples: [(source: String, value: Int, start: Date, end: Date)] = [
            ("watch", V.asleepCore.rawValue, at(2026, 5, 19, 1), at(2026, 5, 19, 4)),
            ("watch", V.asleepDeep.rawValue, at(2026, 5, 19, 4), at(2026, 5, 19, 5)),
            ("watch", V.awake.rawValue, at(2026, 5, 19, 5), at(2026, 5, 19, 5, 30)),
            ("watch", V.asleepREM.rawValue, at(2026, 5, 19, 5, 30), at(2026, 5, 19, 7)),
            // iPhone が同じ夜を大まかに書いた分（重ねて数えない）
            ("phone", V.asleepUnspecified.rawValue, at(2026, 5, 19, 2), at(2026, 5, 19, 6)),
            ("phone", V.inBed.rawValue, at(2026, 5, 19, 0), at(2026, 5, 19, 8)),
        ]
        let sleep = HealthLink.sleep(samples, from: from, to: to)
        XCTAssertEqual(sleep?.start, at(2026, 5, 19, 1))
        XCTAssertEqual(sleep?.end, at(2026, 5, 19, 7))
        XCTAssertEqual(sleep?.asleep, 5.5 * 3600)
        XCTAssertEqual(sleep?.deep, 3600)
        XCTAssertEqual(sleep?.awake, 1800)
        XCTAssertNil(sleep?.inBed)
    }

    func testNoSleepSamples() {
        XCTAssertNil(HealthLink.sleep([], from: at(2026, 5, 18, 18), to: at(2026, 5, 19, 12)))
    }
}

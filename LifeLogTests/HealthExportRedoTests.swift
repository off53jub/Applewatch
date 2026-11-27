import XCTest
@testable import LifeLog

/// 2026-11-27: ロック中にせき・いびきだけで書かれた日を、書かずに待つ・一度だけ書き直す
final class HealthExportRedoTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    func testCoughOnlyIsNotHealthData() {
        var d = HealthExport.Day(day: "2026-11-25")
        d.coughs = 6
        d.snoreMinutes = 1
        XCTAssertFalse(d.isEmpty, "せき・いびきだけでも空ではない（前のまま）")
        XCTAssertFalse(d.hasHealthData, "でもヘルスケアから読めたものは無い")
        d.steps = 1000
        XCTAssertTrue(d.hasHealthData)
    }

    func testReadyWaitsForHealthKit() {
        var d = HealthExport.Day(day: "2026-11-25")
        d.coughs = 3
        XCTAssertFalse(HealthExport.ready(d, now: date("2026-11-26T00:40:00+09:00"), calendar: calendar), "次の日はまだ待つ")
        XCTAssertFalse(HealthExport.ready(d, now: date("2026-11-28T12:00:00+09:00"), calendar: calendar))
        XCTAssertTrue(HealthExport.ready(d, now: date("2026-11-29T00:10:00+09:00"), calendar: calendar), "3 日すぎたら、せき・いびきだけでも書く")
        d.resting = 60
        XCTAssertTrue(HealthExport.ready(d, now: date("2026-11-26T00:40:00+09:00"), calendar: calendar), "読めた日はすぐ書く")
        XCTAssertFalse(HealthExport.ready(HealthExport.Day(day: "2026-11-25"), now: date("2026-12-10T00:00:00+09:00"), calendar: calendar),
                       "空の日は書かない（前のまま）")
    }

    func testRedoOnce() {
        let defaults = UserDefaults(suiteName: "HealthExportRedoTests")!
        defaults.removePersistentDomain(forName: "HealthExportRedoTests")
        var done: Set<String> = ["2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26"]
        XCTAssertTrue(HealthExport.redoOnce(&done, defaults: defaults))
        XCTAssertEqual(done, ["2026-11-23", "2026-11-24"])
        done.insert("2026-11-25")
        XCTAssertFalse(HealthExport.redoOnce(&done, defaults: defaults), "二度目はしない")
        XCTAssertTrue(done.contains("2026-11-25"))
    }
}

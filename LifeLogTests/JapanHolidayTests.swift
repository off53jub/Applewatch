import XCTest
@testable import LifeLog

/// 日本の祝日の計算（2026-11-26）と、時刻で職場を決めるときに祝日を外すこと
final class JapanHolidayTests: XCTestCase {
    func test2026Holidays() {
        let expected: [(Int, Int, String)] = [
            (1, 1, "元日"), (1, 12, "成人の日"), (2, 11, "建国記念の日"), (2, 23, "天皇誕生日"),
            (3, 20, "春分の日"), (4, 29, "昭和の日"), (5, 3, "憲法記念日"), (5, 4, "みどりの日"),
            (5, 5, "こどもの日"), (5, 6, "振替休日"), (7, 20, "海の日"), (8, 11, "山の日"),
            (9, 21, "敬老の日"), (9, 22, "国民の休日"), (9, 23, "秋分の日"), (10, 12, "スポーツの日"),
            (11, 3, "文化の日"), (11, 23, "勤労感謝の日"),
        ]
        for (m, d, name) in expected {
            XCTAssertEqual(JapanHoliday.name(year: 2026, month: m, day: d), name, "2026-\(m)-\(d)")
        }
        // 祝日でない日
        XCTAssertNil(JapanHoliday.name(year: 2026, month: 11, day: 24))
        XCTAssertNil(JapanHoliday.name(year: 2026, month: 5, day: 7))
        XCTAssertNil(JapanHoliday.name(year: 2026, month: 9, day: 24))
    }

    func test2027SubstituteAndEquinox() {
        // 2027: 2/11 は木曜・3/21 春分は日曜 → 3/22 振替休日・9/23 秋分（木）
        XCTAssertEqual(JapanHoliday.name(year: 2027, month: 3, day: 21), "春分の日")
        XCTAssertEqual(JapanHoliday.name(year: 2027, month: 3, day: 22), "振替休日")
        XCTAssertEqual(JapanHoliday.name(year: 2027, month: 9, day: 23), "秋分の日")
        XCTAssertNil(JapanHoliday.name(year: 2027, month: 9, day: 22))
    }

    @MainActor
    func testWorkByTimeSkipsHolidays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ m: Int, _ d: Int, _ h: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
        }
        // 祝日（月曜・勤労感謝の日）の昼は職場にしない
        XCTAssertEqual(Vocabulary.context(byTime: at(11, 23, 11)), .other)
        // ふつうの平日の昼は今までどおり職場
        XCTAssertEqual(Vocabulary.context(byTime: at(11, 24, 11)), .work)
    }
}

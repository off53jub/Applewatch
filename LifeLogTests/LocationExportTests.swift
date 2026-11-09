import XCTest
@testable import LifeLog

final class LocationExportTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testDueDaysOnlyFinishedDaysWithinReach() {
        // 11/10 0:30 では、11/9 はまだ（次の日の1時から）。さかのぼりは6日前の 11/4 まで
        let early = LocationExport.dueDays(now: date(2026, 11, 10, 0, 30), done: [], calendar: calendar)
        XCTAssertEqual(early, ["2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"])
        let later = LocationExport.dueDays(now: date(2026, 11, 10, 1, 30), done: ["2026-11-05"], calendar: calendar)
        XCTAssertEqual(later, ["2026-11-04", "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09"])
    }

    func testJSONHasStaysAndMovesInGoogleShape() throws {
        let points = [
            LocationExport.Point(time: date(2026, 11, 9, 8), latitude: 35.7, longitude: 139.7, accuracy: 30, name: "自宅"),
            LocationExport.Point(time: date(2026, 11, 9, 9), latitude: 35.68, longitude: 139.76, accuracy: 30),
        ]
        let stays = [LocationExport.Stay(start: date(2026, 11, 9, 12), end: date(2026, 11, 9, 13), latitude: 35.68,
                                         longitude: 139.76, name: nil)]
        let end = date(2026, 11, 10, 0)
        let data = try XCTUnwrap(LocationExport.json(day: "2026-11-09", points: points, stays: stays, dayEnd: end, calendar: calendar))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try XCTUnwrap(object["semanticSegments"] as? [[String: Any]])
        // 点2つ → 滞在2つ＋移動1つ、立ち寄り1つ
        XCTAssertEqual(segments.count, 4)
        let visits = segments.compactMap { $0["visit"] as? [String: Any] }
        XCTAssertEqual(visits.count, 3)
        let first = try XCTUnwrap(visits.first?["topCandidate"] as? [String: Any])
        XCTAssertEqual(first["semanticType"] as? String, "自宅")
        let place = try XCTUnwrap(first["placeLocation"] as? [String: Any])
        XCTAssertEqual(place["latLng"] as? String, "35.700000°, 139.700000°")
        let move = try XCTUnwrap(segments.compactMap { $0["activity"] as? [String: Any] }.first)
        let meters = try XCTUnwrap(move["distanceMeters"] as? Int)
        XCTAssertGreaterThan(meters, 5000)
        XCTAssertLessThan(meters, 8000)
        // 名前の無い立ち寄りは「立ち寄り」
        let stay = try XCTUnwrap(visits.last?["topCandidate"] as? [String: Any])
        XCTAssertEqual(stay["semanticType"] as? String, "立ち寄り")
        // 最後の点は、その日の終わりまでいた
        XCTAssertEqual(segments[2]["endTime"] as? String, HealthExport.stamp(end, calendar: calendar))
    }

    func testNothingToWrite() {
        XCTAssertNil(LocationExport.json(day: "2026-11-09", points: [], stays: [], dayEnd: .now, calendar: calendar))
    }
}

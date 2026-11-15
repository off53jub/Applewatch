import XCTest
@testable import LifeLog

/// 名前の無い人物N を自動でまとめる（2026-11-16。強化案 71。SamePersonAuto.swift）の、まとめる組の選び方と間隔を確かめる。
final class SamePersonAutoTests: XCTestCase {
    private func member(_ id: String, lines: Int = 5) -> SamePersonGroup.Member {
        SamePersonGroup.Member(id: id, name: "人物\(id)", lines: lines, seconds: 30, samples: [])
    }

    private func group(_ id: String, _ ids: [String], score: Double, days: [String]?) -> SamePersonGroup {
        SamePersonGroup(id: id, day: days?.last ?? "2026-11-15", score: score, people: ids.map { member($0) }, days: days)
    }

    private let twoDays = ["2026-11-14", "2026-11-15"]

    func testOnlyAcrossDaysWithHighScore() {
        let groups = [
            group("sx-a", ["1", "2"], score: 0.82, days: twoDays),
            group("sx-low", ["3", "4"], score: 0.66, days: twoDays),       // 点が低い
            group("sp-day", ["5", "6"], score: 0.90, days: nil),           // 同じ日の組（自動ではまとめない）
        ]
        let got = SamePersonAuto.candidates(groups, answered: [], eligible: ["1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(got.map(\.id), ["sx-a"])
    }

    func testSkipsGroupsWithIneligiblePeopleOrAnswered() {
        let groups = [
            group("sx-named", ["1", "7"], score: 0.9, days: twoDays),     // 7 は名前がある・覚えた声がある（eligible でない）
            group("sx-done", ["2", "3"], score: 0.9, days: twoDays),      // もう答えた
            group("sx-ok", ["4", "5"], score: 0.75, days: twoDays),
        ]
        let got = SamePersonAuto.candidates(groups, answered: ["sx-done"], eligible: ["1", "2", "3", "4", "5"])
        XCTAssertEqual(got.map(\.id), ["sx-ok"])
    }

    func testLimitAndOrder() {
        var groups: [SamePersonGroup] = []
        for i in 0..<8 { groups.append(group("sx-\(i)", ["\(i * 2 + 10)", "\(i * 2 + 11)"], score: 0.70 + Double(i) * 0.01, days: twoDays)) }
        let eligible = Set(groups.flatMap { $0.people.map(\.id) })
        let got = SamePersonAuto.candidates(groups, answered: [], eligible: eligible, limit: 3)
        XCTAssertEqual(got.map(\.id), ["sx-7", "sx-6", "sx-5"])  // 点の高い順に上限まで
    }

    func testDueEveryHour() {
        let now = Date(timeIntervalSince1970: 1_794_700_000)
        XCTAssertTrue(SamePersonAuto.due(last: nil, now: now))
        XCTAssertFalse(SamePersonAuto.due(last: now.addingTimeInterval(-30 * 60), now: now))
        XCTAssertTrue(SamePersonAuto.due(last: now.addingTimeInterval(-61 * 60), now: now))
    }
}

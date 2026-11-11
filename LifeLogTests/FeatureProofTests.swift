import XCTest
@testable import LifeLog

/// 「実機で動いたか」の帳・家の PC が古いときの知らせ・読まれていない画面・終わりが始まりより前の会話の手直し（2026-11-12）を確かめる。
@MainActor
final class FeatureProofTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    // MARK: - 動いたか

    func testProofUsesEarliestDayAmongKeys() {
        let f = FeatureProof.Feature(name: "テスト", pr: 1, keys: ["a", "b"])
        XCTAssertEqual(FeatureProof.proof(f, seen: [:]), .notYet)
        XCTAssertEqual(FeatureProof.proof(f, seen: ["b": "2026-11-10"]), .ran("2026-11-10"))
        XCTAssertEqual(FeatureProof.proof(f, seen: ["a": "2026-11-12", "b": "2026-11-10"]), .ran("2026-11-10"))
    }

    func testFeatureWithoutKeysIsUnmeasurable() {
        let f = FeatureProof.Feature(name: "テスト", pr: 1, keys: [])
        XCTAssertEqual(FeatureProof.proof(f, seen: ["a": "2026-11-10"]), .unmeasurable)
    }

    func testShortDate() {
        XCTAssertEqual(FeatureProof.shortDate("2026-11-05"), "11/5")
        XCTAssertEqual(FeatureProof.shortDate("おかしい"), "おかしい")
    }

    func testEvidenceKeysCoverFeatureAndScreenKeys() {
        XCTAssertTrue(FeatureProof.evidenceKeys.contains("fix.proposed"))
        XCTAssertTrue(FeatureProof.evidenceKeys.contains("screen.goodThings"))
        XCTAssertFalse(FeatureProof.evidenceKeys.contains("pair.x.n"))
    }

    func testFeatureListHasNoDuplicateNames() {
        let names = FeatureProof.features.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertEqual(FeatureProof.screens.count, Set(FeatureProof.screens.map(\.key)).count)
    }

    // MARK: - 家の PC が古い

    func testNoNoticeUntilPCVersionKnown() {
        XCTAssertTrue(FeatureProof.missingOnPC(version: nil, features: []).isEmpty)
    }

    func testMissingOnPCListsOnlyUpdatableFeatures() {
        let missing = FeatureProof.missingOnPC(version: 7, features: ["vad", "todo"]).compactMap(\.pc)
        XCTAssertTrue(missing.contains("good"))
        XCTAssertTrue(missing.contains("pay"))
        XCTAssertFalse(missing.contains("todo"))
        // PC の環境しだいで出ない働きは、プログラムが古いとは言わない
        XCTAssertFalse(missing.contains("speakers"))
        XCTAssertFalse(missing.contains("semantic"))
    }

    func testNothingMissingWhenPCHasAll() {
        XCTAssertTrue(FeatureProof.missingOnPC(version: 10, features: FeatureProof.updatablePC).isEmpty)
    }

    // MARK: - 読まれていない画面

    func testUnreadScreens() {
        var sums: [String: Int] = [:]
        for s in FeatureProof.screens { sums[FeatureProof.screenKey(s)] = 3 }
        sums[FeatureProof.screenKey(FeatureProof.screens[0])] = 0
        XCTAssertEqual(FeatureProof.unreadScreens(sums: sums), [FeatureProof.screens[0]])
    }

    func testScreenCountingDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9))!
        XCTAssertNil(FeatureProof.screenCountingDays(seen: [:], now: now, calendar: cal))
        let key = FeatureProof.screenKey(FeatureProof.screens[0])
        XCTAssertEqual(FeatureProof.screenCountingDays(seen: [key: "2026-11-02"], now: now, calendar: cal), 10)
    }

    // MARK: - 終わりが始まりより前の会話

    private func line(_ seconds: TimeInterval) -> ConversationLog.Line {
        ConversationLog.Line(time: t0.addingTimeInterval(seconds), speaker: nil, text: "うん")
    }

    func testEndBeforeStartIsRepairedToLastLine() {
        var talk = ConversationLog.Conversation(start: t0, end: t0.addingTimeInterval(-60), docIndex: 0)
        talk.lines = [line(0), line(90), line(30)]
        talk.title = "見出し"
        let result = ConversationLog.repairedEnds(ConversationLog.Day(conversations: [talk]))
        XCTAssertEqual(result.fixed, 1)
        XCTAssertEqual(result.log.conversations[0].end, t0.addingTimeInterval(90))
        // ほかの項目には触らない
        XCTAssertEqual(result.log.conversations[0].start, t0)
        XCTAssertEqual(result.log.conversations[0].title, "見出し")
        XCTAssertEqual(result.log.conversations[0].lines.count, 3)
    }

    func testEndBeforeStartWithoutLinesBecomesStart() {
        let talk = ConversationLog.Conversation(start: t0, end: t0.addingTimeInterval(-5), docIndex: 0)
        let result = ConversationLog.repairedEnds(ConversationLog.Day(conversations: [talk]))
        XCTAssertEqual(result.log.conversations[0].end, t0)
    }

    func testLastLineBeforeStartStillGivesStart() {
        var talk = ConversationLog.Conversation(start: t0, end: t0.addingTimeInterval(-5), docIndex: 0)
        talk.lines = [line(-100)]
        let result = ConversationLog.repairedEnds(ConversationLog.Day(conversations: [talk]))
        XCTAssertEqual(result.log.conversations[0].end, t0)
    }

    func testNormalConversationIsUntouched() {
        var talk = ConversationLog.Conversation(start: t0, end: t0.addingTimeInterval(120), docIndex: 0)
        talk.lines = [line(0), line(300)]
        let day = ConversationLog.Day(conversations: [talk])
        let result = ConversationLog.repairedEnds(day)
        XCTAssertEqual(result.fixed, 0)
        XCTAssertEqual(result.log.conversations[0].end, t0.addingTimeInterval(120))
    }
}

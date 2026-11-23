import UserNotifications
import XCTest
@testable import LifeLog

/// 「ここは、どこですか？」の答え方と、中断のあとの録音の試し直し（2026-11-23）。名前はすべて作り物。
@MainActor
final class PlaceAskAndResumeTests: XCTestCase {
    func testTypedNameIsCleanedAndCut() {
        XCTAssertEqual(PlaceAssistRules.typedName("  駅前のカフェ \n"), "駅前のカフェ")
        XCTAssertNil(PlaceAssistRules.typedName("   "))
        XCTAssertEqual(PlaceAssistRules.typedName(String(repeating: "あ", count: 40))?.count, 24)
    }

    func testCategoryHasTypeAction() {
        let category = PlaceAssistRules.askNotificationCategory()
        let typing = category.actions.first { $0.identifier == PlaceAssistRules.typeAction }
        XCTAssertNotNil(typing)
        XCTAssertTrue(typing is UNTextInputNotificationAction)
        // 書くボタンは候補のボタンと取り違えない
        XCTAssertNil(PlaceAssistRules.index(of: PlaceAssistRules.typeAction))
    }

    func testAskBodySaysWhereToAnswer() {
        XCTAssertTrue(PlaceAssistRules.askBody.contains("押すと"))
    }

    func testResumeWaitsGrowAndStay() {
        XCTAssertEqual(Recorder.resumeWait(0), 15)
        XCTAssertEqual(Recorder.resumeWait(1), 30)
        XCTAssertEqual(Recorder.resumeWait(4), 300)
        XCTAssertEqual(Recorder.resumeWait(99), 300)
        XCTAssertEqual(Recorder.resumeWait(-1), 15)
    }
}

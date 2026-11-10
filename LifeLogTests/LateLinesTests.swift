import XCTest
@testable import LifeLog

/// 遅れて届いた行（時計にたまっていた音声など）の扱い（2026-11-10）。
/// 続いている会話より前の時間の行は別の会話にすること、会話の終わりの時刻が前に戻らないことを確かめる。
@MainActor
final class LateLinesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_000_000)
    /// 会話の切れ目の長さ（ここでは3分）
    private let gap: TimeInterval = 180

    private func line(_ seconds: TimeInterval) -> ConversationLog.Line {
        ConversationLog.Line(time: t0.addingTimeInterval(seconds), speaker: nil, text: "あ")
    }

    func testOlderLinesAreLate() {
        // 続いている会話は 2時間後に始まった
        let open = t0.addingTimeInterval(7200)
        XCTAssertTrue(ConversationLog.isLate([line(3000), line(3600)], openStart: open, gap: gap))
        // 並びが逆でも、いちばん後ろの時刻で見る
        XCTAssertTrue(ConversationLog.isLate([line(3600), line(3000)], openStart: open, gap: gap))
        // 切れ目の長さより、少しでも長く前なら別の会話
        XCTAssertTrue(ConversationLog.isLate([line(7019)], openStart: open, gap: gap))
    }

    func testNearOrLaterLinesAreNotLate() {
        let open = t0.addingTimeInterval(7200)
        // 続き
        XCTAssertFalse(ConversationLog.isLate([line(7300), line(7310)], openStart: open, gap: gap))
        // 始まりの少し前（切れ目の長さの中）は、同じ会話に足す
        XCTAssertFalse(ConversationLog.isLate([line(7100)], openStart: open, gap: gap))
        XCTAssertFalse(ConversationLog.isLate([line(7020)], openStart: open, gap: gap))
        // 前の時間から、続いている会話の中までまたがる行は、続きとして足す
        XCTAssertFalse(ConversationLog.isLate([line(6000), line(7250)], openStart: open, gap: gap))
        XCTAssertFalse(ConversationLog.isLate([], openStart: open, gap: gap))
    }

    func testEndNeverMovesBack() {
        let end = t0.addingTimeInterval(7300)
        // 前の時間の行を足しても、終わりは前に戻らない
        XCTAssertEqual(ConversationLog.extendedEnd(end, adding: [line(3000), line(3600)]), end)
        // 後ろの時間の行なら、いちばん後ろの行まで延びる（並びが逆でも）
        XCTAssertEqual(ConversationLog.extendedEnd(end, adding: [line(7400), line(7350)]), t0.addingTimeInterval(7400))
        XCTAssertEqual(ConversationLog.extendedEnd(end, adding: []), end)
    }
}

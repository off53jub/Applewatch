import XCTest
@testable import LifeLog

/// 飲み会など大勢の場で、何人もの声が1人分にまとめられる件（2026-11-12）
final class CrowdVoicesTests: XCTestCase {
    private func unit(_ values: [Float]) -> [Float] {
        let n = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return values.map { $0 / n }
    }

    func testCoherentClusterIsNotMixed() {
        let center = unit([1, 0, 0])
        let parts: [(seconds: Double, embedding: [Float])] = [
            (seconds: 3, embedding: unit([1, 0.1, 0])),
            (seconds: 2, embedding: unit([1, 0, 0.1])),
        ]
        XCTAssertFalse(SpeakerLabeler.isMixed(center: center, parts: parts, limit: 0.40))
    }

    func testTwoVoicesInOneClusterIsMixed() {
        // 中心は2人の声の平均。片方の人の区間が中心から大きく離れている
        let center = unit([1, 1, 0])
        let parts: [(seconds: Double, embedding: [Float])] = [
            (seconds: 3, embedding: unit([1, 0.9, 0])),
            (seconds: 3, embedding: unit([0, 0.1, 1])),
        ]
        XCTAssertTrue(SpeakerLabeler.isMixed(center: center, parts: parts, limit: 0.40))
    }

    func testOnePartIsNotEnoughToJudge() {
        let center = unit([1, 0, 0])
        let parts: [(seconds: Double, embedding: [Float])] = [(seconds: 5, embedding: unit([0, 1, 0]))]
        XCTAssertFalse(SpeakerLabeler.isMixed(center: center, parts: parts, limit: 0.40))
    }

    func testPartsToCheckUsesLongestAndCapsLength() {
        let segments: [(index: Int, start: Double, end: Double)] = [
            (index: 0, start: 0, end: 1),      // 短すぎる
            (index: 1, start: 2, end: 12),     // 6秒で切る
            (index: 2, start: 13, end: 15),
        ]
        let parts = SpeakerLabeler.partsToCheck(segments)
        XCTAssertEqual(parts.map(\.index), [1, 2])
        XCTAssertEqual(parts[0].end, 8, accuracy: 0.001)
    }

    func testCrowdIDsAreVoicesHeardMostlyInBigConversations() {
        let big = ["me", "1", "2", "3", "4", "5"]
        let small = ["me", "7", "7", "me"]
        // 1 は大勢の会話だけ（3行）、7 は少人数の会話だけ、2 は3つの大勢の会話に1行ずつ
        let convs = [big, big, big + ["1"], small, small]
        let ids = Pipeline.crowdIDs(convs)
        XCTAssertTrue(ids.contains("1"))
        XCTAssertFalse(ids.contains("7"))
        XCTAssertFalse(ids.contains("me"))
        XCTAssertTrue(ids.contains("2"))   // 3つの大勢の会話に1行ずつ
        XCTAssertFalse(Pipeline.crowdIDs([["me", "9", "8"], ["me", "9"], big + ["9"]]).contains("9"))
    }
}

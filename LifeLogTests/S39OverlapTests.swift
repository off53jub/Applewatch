import XCTest
@testable import LifeLog

/// s39（2026-11-29）: iPhone と iPad の 2 台の重なりの見分け方（LifeLog/S39Overlap.swift・ConversationLog.withoutOverlap。
/// docs/s39-two-devices.md）。家の PC の pc/s39overlap.py と同じ答えになるか（pc/v39checks_s39two.py と同じ見本）
@MainActor
final class S39OverlapTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    private func item(_ sec: TimeInterval, _ text: String) -> S39Overlap.Item {
        S39Overlap.Item(time: t0.addingTimeInterval(sec), text: text)
    }

    private func conversation(_ start: TimeInterval, _ end: TimeInterval, _ lines: [(TimeInterval, String)]) -> ConversationLog.Conversation {
        var c = ConversationLog.Conversation(start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end), docIndex: 0)
        c.lines = lines.map { ConversationLog.Line(time: t0.addingTimeInterval($0.0), speaker: nil, text: $0.1) }
        c.closed = true
        return c
    }

    func testNormAndSimilarity() {
        XCTAssertEqual(String(String.UnicodeScalarView(S39Overlap.norm("見本の文、です！ ＡＢ"))), "見本の文ですab")
        XCTAssertEqual(S39Overlap.similarity("見本の文を読みます", "見本の文を読みます。"), 1)
        XCTAssertEqual(S39Overlap.similarity("見本の文を読みます", "見本の文"), 1)
        XCTAssertLessThan(S39Overlap.similarity("見本", "見本の文を読みます"), S39Overlap.similarityMin)
        XCTAssertGreaterThanOrEqual(S39Overlap.similarity("見本の文を読みます", "見本の文を呼びます"), S39Overlap.similarityMin)
        XCTAssertLessThan(S39Overlap.similarity("今日は晴れ", "明日の予定"), S39Overlap.similarityMin)
        XCTAssertEqual(S39Overlap.similarity("", "見本"), 0)
    }

    func testDuplicatesNeedCloseTimeAndText() {
        let local = [item(0, "見本の文を読みます"), item(40, "見本の二つ目の文です")]
        let remote = [item(3, "見本の文を読みます。"), item(41, "見本の二つめの文です"), item(150, "iPad だけが聞いた見本の文"),
                      item(100, "見本の文を読みます")]
        // 時刻が近く文も近い 2 行だけ（100 秒後の同じ文は、仮の 30 秒より離れているので別の発言）
        XCTAssertEqual(S39Overlap.duplicates(remote: remote, local: local), [0, 1])
        XCTAssertEqual(S39Overlap.duplicates(remote: remote, local: []), [])
    }

    func testWithoutOverlapKeepsOnlyNewLines() {
        let mine = conversation(0, 120, [(0, "見本の文を読みます"), (40, "見本の二つ目の文です")])
        let theirs = conversation(2, 200, [(3, "見本の文を読みます。"), (41, "見本の二つめの文です"), (150, "iPad だけが聞いた見本の文")])
        let taken = ConversationLog.withoutOverlap(theirs, against: [mine])
        XCTAssertEqual(taken.lines.map(\.text), ["iPad だけが聞いた見本の文"])
        XCTAssertEqual(taken.start, theirs.start)
        // 重なりなし: 離れた時間の会話はそのまま
        let apart = conversation(3600, 3700, [(3600, "見本の文を読みます")])
        XCTAssertEqual(ConversationLog.withoutOverlap(apart, against: [mine]).lines.count, 1)
        // 同じ会話（同じ start）とは比べない（同期の番号で決める）
        XCTAssertEqual(ConversationLog.withoutOverlap(mine, against: [mine]).lines.count, 2)
    }

    func testTrimmedCopyIsNotTakenBack() {
        let full = [item(0, "見本の一"), item(10, "見本の二"), item(20, "見本の三")]
        XCTAssertTrue(S39Overlap.isTrimmedCopy([item(20, "見本の三")], of: full))
        XCTAssertFalse(S39Overlap.isTrimmedCopy(full, of: full))
        XCTAssertFalse(S39Overlap.isTrimmedCopy([item(20, "見本の直した三")], of: full))
    }

    func testWhoSends() {
        XCTAssertTrue(S39Send.isSender(isPad: false, isReader: false))
        XCTAssertTrue(S39Send.isSender(isPad: false, isReader: true))
        XCTAssertFalse(S39Send.isSender(isPad: true, isReader: true), "iPad の既定（読むだけ）は送らない")
        XCTAssertTrue(S39Send.isSender(isPad: true, isReader: false), "読むだけを切った iPad は送る")
    }

    func testMarkDevice() throws {
        let data = try JSONSerialization.data(withJSONObject: ["conversations": []])
        let marked = PCRecords.markDevice(data, id: "1a2b3c4d", isPad: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: marked) as? [String: Any])
        XCTAssertEqual(object["device"] as? String, "1a2b3c4d")
        XCTAssertEqual(object["deviceKind"] as? String, "pad")
        XCTAssertEqual(PCRecords.markDevice(data, id: nil, isPad: false), data, "印が無ければそのまま（古い形）")
    }
}

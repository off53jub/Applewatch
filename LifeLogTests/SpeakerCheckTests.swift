import XCTest
@testable import LifeLog

/// 家の PC の話し手の見比べ（2026-11-16。GET /speaker-check。CrossCheck.swift の SpeakerCheck）を確かめる。
/// 答えの読み方・時刻の読み方・見た行の数え方（増えた分だけ）・古い日の捨て方・確認箱の番号。
final class SpeakerCheckTests: XCTestCase {
    func testDecodeReadsDaysAndItems() throws {
        let body = """
        {"available": true, "generated_at": "2026-11-16T03:00:00+09:00", "model": "x",
         "days": [{"day": "2026-11-15", "checked": 12,
                   "items": [{"day": "2026-11-15", "line_time": "2026-11-15T01:02:03.456Z", "audio": "a.m4a",
                              "start": 1.0, "end": 4.0, "assigned": "7", "suggest": "me", "gap": 0.2}]},
                  {"day": "2026-11-14", "checked": 0, "items": []}]}
        """
        let days = try XCTUnwrap(SpeakerCheck.decode(Data(body.utf8)))
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].checked, 12)
        XCTAssertEqual(days[0].items.first?.assigned, "7")
        XCTAssertEqual(days[0].items.first?.suggest, "me")
    }

    func testDecodeRejectsUnavailableAndBroken() {
        XCTAssertNil(SpeakerCheck.decode(Data(#"{"available": false, "reason": "まだ"}"#.utf8)))
        XCTAssertNil(SpeakerCheck.decode(Data("壊れた".utf8)))
        // 何も無い日でも読める
        XCTAssertEqual(SpeakerCheck.decode(Data(#"{"available": true}"#.utf8))?.count, 0)
    }

    func testTimeReadsWithAndWithoutFraction() throws {
        let a = try XCTUnwrap(SpeakerCheck.time("2026-11-15T01:02:03.456Z"))
        let b = try XCTUnwrap(SpeakerCheck.time("2026-11-15T01:02:03Z"))
        XCTAssertEqual(a.timeIntervalSince(b), 0.456, accuracy: 0.001)
        XCTAssertNil(SpeakerCheck.time("きのう"))
    }

    func testCountsOnlyNewlyCheckedLines() {
        // 初めての日は全部・同じ数ならもう数えない・増えたら差だけ・減っても 0
        XCTAssertEqual(SpeakerCheck.added(counted: [:], day: "2026-11-15", checked: 10), 10)
        XCTAssertEqual(SpeakerCheck.added(counted: ["2026-11-15": 10], day: "2026-11-15", checked: 10), 0)
        XCTAssertEqual(SpeakerCheck.added(counted: ["2026-11-15": 10], day: "2026-11-15", checked: 14), 4)
        XCTAssertEqual(SpeakerCheck.added(counted: ["2026-11-15": 10], day: "2026-11-15", checked: 3), 0)
    }

    func testTrimKeepsNewestDays() {
        var counted: [String: Int] = [:]
        for d in 1...20 { counted[String(format: "2026-11-%02d", d)] = d }
        let kept = SpeakerCheck.trimmed(counted)
        XCTAssertEqual(kept.count, SpeakerCheck.countedDays)
        XCTAssertNotNil(kept["2026-11-20"])
        XCTAssertNil(kept["2026-11-01"])
    }

    func testNoteIDMatchesTheOldCheck() {
        // 前の見比べと同じ番号にする（同じ行の疑いを二重に出さない）
        let t = Date(timeIntervalSince1970: 1_794_700_000.7)
        XCTAssertEqual(SpeakerCheck.noteID(assigned: "7", time: t), "pc-7-1794700000")
    }
}

import XCTest
@testable import LifeLog

/// 母艦のやることの「済みかも」（2026-11-09）
final class MothershipKindTests: XCTestCase {
    func testMaybeDoneIsRead() throws {
        let json = """
        {"available": true, "generated_at": "2026-11-09T23:00:00+09:00", "today_three": [],
         "items": [{"id": "0123456789ab", "text": "健康データを直す", "work": false, "added": "2026-08-01",
                    "maybe_done": "11/8 アプリが書き出し始めた（会話）"},
                   {"id": "0123456789ac", "text": "資料を送る", "work": true}]}
        """
        let export = try XCTUnwrap(MothershipExport.parse(Data(json.utf8)))
        XCTAssertEqual(export.items.first?.maybeDone, "11/8 アプリが書き出し始めた（会話）")
        XCTAssertNil(export.items.last?.maybeDone)
    }

    func testOldSavedItemsStillRead() throws {
        // 前の版で覚えた形（maybe_done が無い）も読める
        let old = #"{"id": "0123456789ab", "text": "資料を送る", "work": true, "added": "2026-11-01"}"#
        let item = try JSONDecoder().decode(MothershipTodo.self, from: Data(old.utf8))
        XCTAssertEqual(item.text, "資料を送る")
        XCTAssertNil(item.maybeDone)
        // 書いて読み直しても変わらない
        let again = try JSONDecoder().decode(MothershipTodo.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(again, item)
    }
}

import XCTest
@testable import LifeLog

/// いいこと帳の足し（2026-11-12）: 新しい項目の読み込み、「違う」「当たり」の保存と送る中身、21:30 の知らせの文、ウィジェットの数。
@MainActor
final class GoodMoreTests: XCTestCase {
    private func at(_ h: Int, _ m: Int, day d: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    private func scratch() -> (URL, UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("good-feedback-\(UUID().uuidString).json")
        let name = "GoodMoreTests-" + UUID().uuidString
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        return (url, UserDefaults(suiteName: name)!)
    }

    // MARK: - 読み込み

    func testDecodesOldAndNewShapes() throws {
        let old = #"{"available":true,"weeks":[{"start":"2026-11-09","thanks":1,"praise":2,"laughs":null,"done":3,"own":4}],"days":[{"day":"2026-11-12","words":[],"done":[],"laughs":["10:00"]}]}"#
        let a = try JSONDecoder().decode(GoodThings.self, from: Data(old.utf8))
        XCTAssertNil(a.weeks?.first?.consulted)
        XCTAssertNil(a.month)
        XCTAssertNil(a.days?.first?.laughs_ok)
        let new = #"{"available":true,"weeks":[{"start":"2026-11-09","thanks":1,"praise":2,"laughs":null,"done":3,"own":4,"consulted":5}],"days":[{"day":"2026-11-12","words":[],"done":[],"laughs":["10:00"],"laughs_ok":["10:00"]}],"month":{"this":{"thanks":3,"consulted":1},"last":{"thanks":2}},"firsts":[{"day":"2026-11-11","kind":"初めての場所","text":"公園"}],"tonight":[{"kind":"お礼","text":"ありがとう","time":"17:17"}]}"#
        let b = try JSONDecoder().decode(GoodThings.self, from: Data(new.utf8))
        XCTAssertEqual(b.weeks?.first?.consulted, 5)
        XCTAssertEqual(b.days?.first?.laughs_ok, ["10:00"])
        XCTAssertEqual(b.month?.this?.thanks, 3)
        XCTAssertNil(b.month?.last?.praise)
        XCTAssertEqual(b.firsts?.first?.text, "公園")
        XCTAssertEqual(b.tonight?.first?.time, "17:17")
    }

    func testWeekAndMonthLines() {
        var week = GoodThings.Week(start: "2026-11-09", thanks: 2, praise: 1, laughs: nil, done: 3, own: 40)
        XCTAssertEqual(GoodThingsView.weekLine(week), "お礼 2・ほめ言葉 1・済ませた 3・自分の発言 40 行")
        week.consulted = 4
        XCTAssertEqual(GoodThingsView.weekLine(week), "お礼 2・ほめ言葉 1・頼られた 4・済ませた 3・自分の発言 40 行")
        XCTAssertNil(GoodThingsView.monthLines(nil))
        XCTAssertNil(GoodThingsView.monthLines(GoodThings.Month()))
        let month = GoodThings.Month(this: .init(thanks: 5, consulted: 2), last: .init(thanks: 3))
        XCTAssertEqual(GoodThingsView.monthLines(month), ["お礼　今月 5・先月 3", "頼られた　今月 2・先月 —"])
    }

    // MARK: - 「違う」「当たり」

    func testFeedbackIDAndAdding() {
        XCTAssertEqual(GoodFeedbackBook.id(day: "2026-11-12", time: "17:17", kind: "word", text: "ありがとう"), "2026-11-12|17:17|word|ありがとう")
        XCTAssertEqual(GoodFeedbackBook.id(day: "2026-11-12", time: "19:58", kind: "laugh", text: ""), "2026-11-12|19:58|laugh|")
        XCTAssertLessThanOrEqual(GoodFeedbackBook.id(day: "2026-11-12", time: "17:17", kind: "word", text: String(repeating: "あ", count: 500)).count, 200)
        let a = GoodFeedbackBook.Item(id: "a", day: "2026-11-12", time: "10:00", kind: "laugh", verdict: "right")
        let a2 = GoodFeedbackBook.Item(id: "a", day: "2026-11-12", time: "10:00", kind: "laugh", verdict: "wrong")
        let b = GoodFeedbackBook.Item(id: "b", day: "2026-11-12", time: "11:00", kind: "laugh", verdict: "wrong")
        XCTAssertEqual(GoodFeedbackBook.adding(a2, to: [a, b]), [b, a2])
        XCTAssertEqual(GoodFeedbackBook.adding(b, to: [a], max: 1), [b])
    }

    func testMarkHidesSavesAndReloads() {
        let (url, defaults) = scratch()
        let book = GoodFeedbackBook(url: url, defaults: defaults)
        let id = GoodFeedbackBook.id(day: "2026-11-12", time: "17:17", kind: "word", text: "ありがとう")
        XCTAssertFalse(book.isWrong(id))
        book.mark(day: "2026-11-12", time: "17:17", kind: "word", text: "ありがとう", verdict: "wrong", pc: nil)
        XCTAssertTrue(book.isWrong(id))
        book.mark(day: "2026-11-12", time: "19:58", kind: "laugh", text: "", verdict: "right", pc: nil)
        XCTAssertEqual(book.wrongIDs, [id])
        // 読み直しても残る（読む前に保存して消さない）
        let again = GoodFeedbackBook(url: url, defaults: defaults)
        XCTAssertEqual(again.items, book.items)
        XCTAssertEqual(again.verdict("2026-11-12|19:58|laugh|"), "right")
        // 答えを変えられる
        again.mark(day: "2026-11-12", time: "17:17", kind: "word", text: "ありがとう", verdict: "right", pc: nil)
        XCTAssertFalse(again.isWrong(id))
        XCTAssertEqual(again.items.count, 2)
    }

    func testBodyAndContentKey() throws {
        let a = GoodFeedbackBook.Item(id: "x|y", day: "2026-11-12", time: "10:00", kind: "word", verdict: "wrong")
        let body = try XCTUnwrap(GoodFeedbackBook.body([a]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let rows = try XCTUnwrap(json["items"] as? [[String: String]])
        XCTAssertEqual(rows, [["id": "x|y", "day": "2026-11-12", "time": "10:00", "kind": "word", "verdict": "wrong"]])
        let empty = try XCTUnwrap(GoodFeedbackBook.body([]))
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: empty) as? [String: [Any]])?["items"]?.count, 0)
        // 変わったら印が変わる・同じなら同じ
        var b = a
        b.verdict = "right"
        XCTAssertEqual(GoodFeedbackBook.contentKey([a]), GoodFeedbackBook.contentKey([a]))
        XCTAssertNotEqual(GoodFeedbackBook.contentKey([a]), GoodFeedbackBook.contentKey([b]))
        XCTAssertNotEqual(GoodFeedbackBook.contentKey([a]), GoodFeedbackBook.contentKey([]))
    }

    // MARK: - 21:30 の知らせ

    func testNightlyLines() {
        let tonight: [GoodThings.Tonight] = [
            .init(kind: "お礼", text: "ありがとう", time: "17:17"),
            .init(kind: "ほめ言葉", text: "さすが", time: "18:00"),
            .init(kind: "済ませた", text: "資料を送る", time: "18:30"),
            .init(kind: "頼られた", text: "相談", time: "19:00")]
        XCTAssertEqual(GoodNightly.lines(tonight, day: "2026-11-12", hidden: []),
                       ["17:17 お礼「ありがとう」", "18:00 ほめ言葉「さすが」", "18:30 済ませた: 資料を送る"])
        // 違うと答えたものは外れ、次のものが入る
        let hidden: Set<String> = [GoodFeedbackBook.id(day: "2026-11-12", time: "17:17", kind: "word", text: "ありがとう")]
        XCTAssertEqual(GoodNightly.lines(tonight, day: "2026-11-12", hidden: hidden).count, 3)
        XCTAssertFalse(GoodNightly.lines(tonight, day: "2026-11-12", hidden: hidden).contains { $0.contains("ありがとう") })
        XCTAssertEqual(GoodNightly.lines(nil, day: "2026-11-12", hidden: []), [])
        XCTAssertEqual(GoodNightly.lines([], day: "2026-11-12", hidden: []), [])
    }

    func testNightlyDates() {
        XCTAssertEqual(GoodNightly.fireDate(now: at(12, 0)), at(21, 30))
        XCTAssertNil(GoodNightly.fireDate(now: at(21, 30)))
        XCTAssertNil(GoodNightly.fireDate(now: at(22, 0)))
        XCTAssertEqual(GoodNightly.dayKey(at(9, 0)), "2026-11-12")
        XCTAssertTrue(GoodNightly.isFresh(generatedAt: "2026-11-12T01:00:00+0900", now: at(12, 0)))
        XCTAssertFalse(GoodNightly.isFresh(generatedAt: "2026-11-11T23:00:00+0900", now: at(12, 0)))
        XCTAssertFalse(GoodNightly.isFresh(generatedAt: nil, now: at(12, 0)))
    }

    // MARK: - ウィジェット

    func testWidgetCounts() {
        let week = GoodThings.Week(start: "2026-11-09", thanks: 3, praise: 2, laughs: nil, done: 0, own: 0)
        let old = GoodThings.Week(start: "2026-11-02", thanks: 9, praise: 9, laughs: nil, done: 0, own: 0)
        let now = at(12, 0)
        XCTAssertEqual(GoodWidgetCounts.thisWeek([week, old], now: now)?.thanks, 3)
        XCTAssertEqual(GoodWidgetCounts.thisWeek([week], now: at(12, 0, day: 15))?.praise, 2)
        // いちばん新しい週が今週でなければ出さない（古い写し）
        XCTAssertNil(GoodWidgetCounts.thisWeek([week], now: at(12, 0, day: 16)))
        XCTAssertNil(GoodWidgetCounts.thisWeek([old], now: now))
        XCTAssertNil(GoodWidgetCounts.thisWeek(nil, now: now))
    }

    func testWidgetText() {
        var state = WidgetState(updated: .now)
        XCTAssertEqual(WidgetText.goodWeekLine(state), "お礼 —・ほめ言葉 —")
        XCTAssertEqual(WidgetText.goodWeekLine(nil), "お礼 —・ほめ言葉 —")
        state.goodThanks = 3
        state.goodPraise = 0
        XCTAssertEqual(WidgetText.goodWeekLine(state), "お礼 3・ほめ言葉 0")
        // 保存して読み直しても残る
        let name = "GoodMoreTests-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        XCTAssertTrue(state.save(to: defaults))
        XCTAssertEqual(WidgetState.load(from: defaults)?.goodThanks, 3)
    }
}

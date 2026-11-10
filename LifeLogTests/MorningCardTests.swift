import XCTest
@testable import LifeLog

/// 朝の「昨日と今日」と今日の三つ・母艦のやること（2026-11-09）
final class MorningCardTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ d: Int, _ h: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
    }

    // MARK: 昨日と今日

    func testFlowLineIsShort() {
        XCTAssertEqual(MorningBrief.flowLine("06:28〜11:01　ダンス練習と移動（自宅　サピ、ほか8人と）：ダンス練習と移動／練習計画と交通指示"),
                       "6:28〜11:01 ダンス練習と移動（自宅　サピ、ほか8人と）")
        XCTAssertEqual(MorningBrief.flowLine("00:06〜05:52　自宅で過ごす"), "0:06〜5:52 自宅で過ごす")
        let long = MorningBrief.flowLine("9:00〜18:00　" + String(repeating: "あ", count: 80))
        XCTAssertEqual(long.count, 44)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testCardWithEverything() {
        var input = MorningBrief.Input(date: at(9))
        input.flow = ["06:28〜11:01　練習（自宅）：細かい話", "11:06〜18:00　イベント（秋葉原）"]
        input.decisions = ["バーベキューは土曜"]
        input.marks = 2
        input.health = "睡眠 6時間"
        input.three = [MorningBrief.Pick(text: "請求書を出す", why: "期限切れ"), MorningBrief.Pick(text: "資料を送る", why: "")]
        input.events = [MorningBrief.EventLine(time: "10:00", title: "企画会議", people: ["田中"]),
                        MorningBrief.EventLine(time: "15:00", title: "面談")]
        input.checks = ["確かめ待ち 3 件"]
        let lines = MorningBrief.card(input, calendar: tokyo).components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("昨日 11/8"))
        XCTAssertEqual(lines[1], "・6:28〜11:01 練習（自宅）")
        XCTAssertEqual(lines[2], "・11:06〜18:00 イベント（秋葉原）")
        XCTAssertEqual(lines[3], "・決まったこと: バーベキューは土曜")
        XCTAssertEqual(lines[4], "・★ 2 か所／睡眠 6時間")
        XCTAssertEqual(lines[5], "今日の三つ")
        XCTAssertEqual(lines[6], "1. 請求書を出す（期限切れ）")
        XCTAssertEqual(lines[7], "2. 資料を送る")
        XCTAssertEqual(lines[8], "予定: 10:00 企画会議（田中さん） ほか1件")
        XCTAssertEqual(lines[9], "確かめ待ち 3 件")
    }

    func testCardWithNothing() {
        let text = MorningBrief.card(MorningBrief.Input(date: at(9)), calendar: tokyo)
        XCTAssertFalse(text.contains("今日の三つ"))
        XCTAssertTrue(text.contains("まだありません"))
    }

    // MARK: 今日の三つ

    func testPickThreeOrder() {
        let now = at(9, 7)
        var late = TaskBook.Item(what: "請求書を出す", due: at(8), said: at(1), source: .manual, state: .open)
        late.work = true
        let today = TaskBook.Item(what: "資料を送る", due: at(9), said: at(1), source: .manual, state: .open, work: true)
        let later = TaskBook.Item(what: "旅行の計画", due: at(20), said: at(1), source: .manual, state: .open, work: false)
        var urgent = TaskBook.Item(what: "見積もりを確かめる", said: at(1), source: .manual, state: .open, work: true)
        urgent.urgent = true
        let three = MorningBrief.pickThree(open: [later, today, urgent, late],
                                           mothership: [.init(id: "0123456789ab", text: "下期の目標を書く", why: "期限が今日")],
                                           mothershipWork: [], dayOff: false, now: now, calendar: tokyo)
        XCTAssertEqual(three.map(\.text), ["請求書を出す", "資料を送る", "下期の目標を書く"])
        XCTAssertEqual(three.map(\.why), ["期限切れ", "今日まで", "期限が今日"])
    }

    func testPickThreeOnDayOffSkipsWork() {
        let now = at(8, 7)
        let work = TaskBook.Item(what: "資料を送る", due: at(8), said: at(1), source: .manual, state: .open, work: true)
        let life = TaskBook.Item(what: "牛乳を買う", due: at(8), said: at(1), source: .manual, state: .open, work: false)
        let three = MorningBrief.pickThree(open: [work, life],
                                           mothership: [.init(id: "0123456789ab", text: "UAT の資料", why: ""),
                                                        .init(id: "ba9876543210", text: "スノーボードの宿", why: "")],
                                           mothershipWork: ["0123456789ab"], dayOff: true, now: now, calendar: tokyo)
        XCTAssertEqual(three.map(\.text), ["牛乳を買う", "スノーボードの宿"])
    }

    func testPickThreeFillsWithRecentMothershipTodos() {
        let now = at(9, 7)
        let recent = [MothershipTodo(id: "000000000001", text: "下期目標を直す", work: true, added: "2026-11-06"),
                      MothershipTodo(id: "000000000002", text: "古いもの", work: true, added: "2026-08-01"),
                      MothershipTodo(id: "000000000003", text: "宿を取る", work: false, added: "2026-11-05")]
        let three = MorningBrief.pickThree(open: [], mothership: [], mothershipWork: [], recent: recent,
                                           dayOff: false, now: now, calendar: tokyo)
        XCTAssertEqual(three.map(\.text), ["下期目標を直す", "宿を取る"])
        XCTAssertEqual(three.first?.why, "11/06 に足した")
        let off = MorningBrief.pickThree(open: [], mothership: [], mothershipWork: [], recent: recent,
                                         dayOff: true, now: now, calendar: tokyo)
        XCTAssertEqual(off.map(\.text), ["宿を取る"])
    }

    func testPickThreeSkipsSimilar() {
        let now = at(9, 7)
        let a = TaskBook.Item(what: "資料を送る", due: at(9), said: at(1), source: .manual, state: .open, work: true)
        let three = MorningBrief.pickThree(open: [a], mothership: [.init(id: "0123456789ab", text: "資料を送る", why: "")],
                                           mothershipWork: [], dayOff: false, now: now, calendar: tokyo)
        XCTAssertEqual(three.count, 1)
    }

    // MARK: 母艦のやること

    func testMothershipParse() {
        let json = """
        {"available": true, "generated_at": "2026-11-09T07:05:00+09:00",
         "today_three": [{"id": "0123456789ab", "text": "資料を送る", "why": "期限が今日"}],
         "items": [{"id": "0123456789ab", "text": "資料を送る", "project": "新PJ", "work": true, "added": "2026-11-01", "due": "2026-11-09", "source": "x"},
                   {"id": "bad", "text": "id がおかしい"},
                   {"id": "ba9876543210", "text": "  "},
                   {"id": "cafe00000000", "text": "宿を取る", "project": "", "work": false, "added": "2026-10-01", "due": null}]}
        """.data(using: .utf8)!
        let export = MothershipExport.parse(json)
        XCTAssertEqual(export?.items.map(\.id), ["0123456789ab", "cafe00000000"])
        XCTAssertEqual(export?.todayThree.first?.why, "期限が今日")
        XCTAssertNil(export?.items.last?.due)
        XCTAssertNil(MothershipExport.parse(#"{"available": false, "reason": "まだ"}"#.data(using: .utf8)!))
        XCTAssertNil(MothershipExport.parse(#"{"items": "x"}"#.data(using: .utf8)!))
    }

    func testMothershipSortedByDueThenNewest() {
        let items = [MothershipTodo(id: "000000000001", text: "a", added: "2026-10-01"),
                     MothershipTodo(id: "000000000002", text: "b", added: "2026-11-01"),
                     MothershipTodo(id: "000000000003", text: "c", added: "2026-09-01", due: "2026-11-20"),
                     MothershipTodo(id: "000000000004", text: "d", added: "2026-09-01", due: "2026-11-10")]
        XCTAssertEqual(MothershipBook.sorted(items).map(\.text), ["d", "c", "b", "a"])
    }
}

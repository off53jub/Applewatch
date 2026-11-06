import XCTest
@testable import LifeLog

/// 時計に送る中身（WatchInfo）と、朝の読み上げ（MorningBrief）の決まった形を確かめる（2026-11-07）。
@MainActor
final class WatchInfoTests: XCTestCase {
    /// 11/7 の昼（日付の変わり目で結果が変わらないように）
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!

    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
    }

    private func item(_ what: String, due: Date? = nil, state: TaskBook.State = .open, urgent: Bool? = nil) -> TaskBook.Item {
        TaskBook.Item(what: what, due: due, said: now.addingTimeInterval(-3600), source: .manual, state: state, urgent: urgent)
    }

    // MARK: - 頼まれごとの並び

    func testTasksPutLateAndTodayFirst() {
        let items = [
            item("期限なし"),
            item("来週", due: day(3)),
            item("今日", due: day(0)),
            item("済んだ", due: day(-1), state: .done),
            item("確かめ待ち", due: day(-1), state: .candidate),
            item("過ぎた", due: day(-2)),
            item("来週で急ぎ", due: day(4), urgent: true),
        ]
        let list = WatchInfo.taskItems(items, now: now)
        XCTAssertEqual(list.map(\.what), ["過ぎた", "今日", "来週で急ぎ", "来週", "期限なし"])
        XCTAssertEqual(list.map(\.late), [true, true, false, false, false])
    }

    func testTasksAreLimitedTo15() {
        let items = (0..<20).map { item("頼まれごと\($0)", due: day($0)) }
        let list = WatchInfo.taskItems(items, now: now)
        XCTAssertEqual(list.count, 15)
        XCTAssertEqual(list.first?.what, "頼まれごと0")
    }

    func testDueLabel() {
        var withTime = item("a", due: day(0))
        withTime.dueTime = 15 * 60
        XCTAssertEqual(WatchInfo.dueLabel(withTime, now: now), "今日 15:00まで")
        XCTAssertEqual(WatchInfo.dueLabel(item("b", due: day(1)), now: now), "明日まで")
        XCTAssertEqual(WatchInfo.dueLabel(item("c", due: day(-2)), now: now), "2日過ぎ")
        var said = item("d")
        said.dueText = "来週の頭"
        XCTAssertEqual(WatchInfo.dueLabel(said, now: now), "来週の頭")
        XCTAssertNil(WatchInfo.dueLabel(item("e"), now: now))
    }

    // MARK: - 大きさの上限

    private func sample(long: Int) -> WatchInfo {
        let text = String(repeating: "あ", count: long)
        var info = WatchInfo(made: now.timeIntervalSince1970, status: WatchInfo.Status(pending: 2, processed: nil))
        info.tasks = (0..<15).map { WatchInfo.TaskItem(id: "id\($0)", what: text, due: "今日まで", from: "田中", late: true) }
        info.openCount = 20
        info.next = WatchInfo.Event(title: "会議", start: now.timeIntervalSince1970, end: now.timeIntervalSince1970 + 3600,
                                    people: ["田中"], brief: text, place: nil)
        info.last = WatchInfo.Talk(start: 0, end: 60, title: "見出し", points: [text, text, text], people: ["佐藤"])
        info.morning = WatchInfo.Brief(day: "2026-11-07", text: text)
        return info
    }

    func testSmallPayloadIsUnchanged() {
        let info = sample(long: 20)
        let data = WatchInfo.capped(info)
        XCTAssertNotNil(data)
        XCTAssertEqual(data, WatchInfo.encode(info))
        let back = try? JSONDecoder().decode(WatchInfo.self, from: data!)
        XCTAssertEqual(back, info)
    }

    func testLargePayloadIsCut() {
        let info = sample(long: 3_000)
        XCTAssertGreaterThan(WatchInfo.encode(info)!.count, WatchInfo.maxBytes)
        let data = WatchInfo.capped(info)!
        XCTAssertLessThanOrEqual(data.count, WatchInfo.maxBytes)
        let back = try! JSONDecoder().decode(WatchInfo.self, from: data)
        // 頼まれごとは前から残る
        XCTAssertEqual(back.tasks.first?.id, "id0")
        XCTAssertEqual(back.openCount, 20)
    }

    func testTinyLimitStillDecodes() {
        let data = WatchInfo.capped(sample(long: 500), limit: 400)
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data!.count, 400)
        XCTAssertNotNil(try? JSONDecoder().decode(WatchInfo.self, from: data!))
    }

    func testClip() {
        XCTAssertEqual(WatchInfo.clip("  短い ", 10), "短い")
        XCTAssertEqual(WatchInfo.clip("あいうえおかきく", 5), "あいうえ…")
    }

    func testPoliteName() {
        XCTAssertEqual(WatchInfo.politeName("田中"), "田中さん")
        XCTAssertEqual(WatchInfo.politeName("田中さん"), "田中さん")
        XCTAssertEqual(WatchInfo.politeName("山本部長"), "山本部長")
        XCTAssertEqual(WatchInfo.politeName(SpeakerLabeler.selfName), SpeakerLabeler.selfName)
    }

    // MARK: - 朝の読み上げ（言語モデルを使わない形）

    func testTemplateWithEverything() {
        var input = MorningBrief.Input(date: day(0))
        input.events = [
            MorningBrief.EventLine(time: "10時", title: "企画会議", people: ["田中"], note: "田中さんとは、前回11月5日に「見積もり」を話しました"),
            MorningBrief.EventLine(time: "15時", title: "面談"),
            MorningBrief.EventLine(time: "18時", title: "夕食"),
        ]
        input.dueToday = ["資料を送る"]
        input.overdue = ["請求書を出す。"]
        input.yesterdayTopics = ["旅行", "引っ越し"]
        input.yesterdayDecisions = ["日曜に下見する"]
        input.checks = ["iPhone に文字起こし待ちが3件あります"]
        let text = MorningBrief.template(input)
        let sentences = MorningBrief.sentences(text)
        XCTAssertLessThanOrEqual(sentences.count, MorningBrief.maxSentences)
        XCTAssertTrue(sentences[0].hasPrefix("おはようございます"))
        XCTAssertTrue(sentences[0].contains("11月7日"))
        XCTAssertEqual(sentences[1], "今日の予定は3件です。")
        XCTAssertEqual(sentences[2], "10時から企画会議、田中さんと。")
        XCTAssertTrue(text.contains("頼まれごとは、今日までが1件、期限を過ぎたものが1件です。"))
        // 期限を過ぎたものから
        XCTAssertTrue(text.contains("まず「請求書を出す」から。"))
        XCTAssertFalse(text.contains("。。"))
    }

    func testTemplateWithNothing() {
        let text = MorningBrief.template(MorningBrief.Input(date: day(0)))
        let sentences = MorningBrief.sentences(text)
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(text.contains("カレンダーに入っていません"))
        XCTAssertFalse(text.contains("頼まれごと"))
    }

    func testTemplateKeepsEightSentences() {
        var input = MorningBrief.Input(date: day(0))
        input.events = (0..<5).map { MorningBrief.EventLine(time: "\($0 + 9)時", title: "予定\($0)", note: "前回も話しました") }
        input.dueToday = ["a"]
        input.checks = (0..<5).map { "点検\($0)" }
        XCTAssertEqual(MorningBrief.sentences(MorningBrief.template(input)).count, MorningBrief.maxSentences)
    }

    func testTidyModelAnswer() {
        XCTAssertEqual(MorningBrief.tidy("1. 今日は10時から会議です。\n・頼まれごとが2件あります"),
                       "今日は10時から会議です。頼まれごとが2件あります。")
        XCTAssertNil(MorningBrief.tidy("記録に見つかりませんでした。"))
        XCTAssertNil(MorningBrief.tidy("一文だけです。"))
        let many = (0..<12).map { "文\($0)です。" }.joined()
        XCTAssertEqual(MorningBrief.sentences(MorningBrief.tidy(many)!).count, MorningBrief.maxSentences)
    }

    func testHeadlineIsFirstTwoSentences() {
        XCTAssertEqual(MorningBrief.headline("一つ目です。二つ目です。三つ目です。"), "一つ目です。二つ目です。")
    }
}

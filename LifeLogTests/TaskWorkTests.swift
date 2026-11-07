import XCTest
@testable import LifeLog

/// タスクを「仕事」と「仕事以外」に分ける（2026-11-07）を確かめる。
/// 切り替えの絞り込み・古い work: nil の扱い・休みの日の見分け・朝夕の知らせの文・ドライブの写しの見出し・朝の読み上げ。
@MainActor
final class TaskWorkTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    private func day(_ d: Int, month: Int = 11, hour: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: hour))!
    }

    private func item(_ what: String, work: Bool?, due: Date? = nil, state: TaskBook.State = .open,
                      kind: TaskBook.Kind? = nil, from: String? = nil) -> TaskBook.Item {
        TaskBook.Item(what: what, from: from, due: due, said: day(5, hour: 10), source: .manual, state: state, work: work,
                      kind: kind)
    }

    // MARK: - 切り替えの絞り込み・古いもの

    func testOldItemsWithoutWorkCountAsWork() throws {
        XCTAssertTrue(item("a", work: nil).isWork)
        XCTAssertTrue(item("b", work: true).isWork)
        XCTAssertFalse(item("c", work: false).isWork)
        // 「仕事」の印が入る前に保存した帳も、そのまま読めて、仕事とみなす
        let old = #"[{"id":"x","what":"見積書を送る","said":0,"source":"conversation","state":"open","updated":0}]"#
        let items = try JSONDecoder().decode([TaskBook.Item].self, from: Data(old.utf8))
        XCTAssertNil(items.first?.work)
        XCTAssertEqual(items.first?.isWork, true)
        XCTAssertEqual(TaskBook.filter(items, .work).count, 1)
        XCTAssertEqual(TaskBook.filter(items, .life).count, 0)
    }

    func testScopeFilterKeepsOrder() {
        let list = [item("仕事1", work: true), item("家1", work: false), item("古い", work: nil), item("家2", work: false)]
        XCTAssertEqual(TaskBook.filter(list, .work).map(\.what), ["仕事1", "古い"])
        XCTAssertEqual(TaskBook.filter(list, .life).map(\.what), ["家1", "家2"])
        XCTAssertEqual(TaskBook.filter(list, .all).map(\.what), ["仕事1", "家1", "古い", "家2"])
        XCTAssertEqual(TaskBook.Scope.allCases.map(\.label), ["仕事", "仕事以外", "全部"])
        // 覚えておく値（@AppStorage の taskScope）
        XCTAssertEqual(TaskBook.Scope(rawValue: "life"), .life)
        XCTAssertEqual(TaskBook.Scope.all.rawValue, "all")
    }

    func testWorkFlagSurvivesSaving() throws {
        var a = item("家の用事", work: false)
        a.memo = "メモ"
        let data = try JSONEncoder().encode([a])
        let back = try JSONDecoder().decode([TaskBook.Item].self, from: data)
        XCTAssertEqual(back.first?.work, false)
        XCTAssertEqual(back.first?.memo, "メモ")
    }

    // MARK: - 休みの日

    func testWeekendsAreOffWithoutCalendar() {
        XCTAssertTrue(DayOff.isOff(day(7), allDay: [], calendar: cal))   // 土曜
        XCTAssertTrue(DayOff.isOff(day(8), allDay: [], calendar: cal))   // 日曜
        XCTAssertFalse(DayOff.isOff(day(9), allDay: [], calendar: cal))  // 月曜
        // 許可が無ければ祝日も分からない（文化の日・火曜）
        XCTAssertFalse(DayOff.isOff(day(3), allDay: [], calendar: cal))
    }

    func testHolidayCalendarEventsAreOff() {
        XCTAssertTrue(DayOff.isHolidayCalendar("日本の祝日"))
        XCTAssertTrue(DayOff.isHolidayCalendar("Japanese Holidays"))
        XCTAssertTrue(DayOff.isHolidayCalendar("Holidays in Japan"))
        XCTAssertFalse(DayOff.isHolidayCalendar("仕事"))
        let bunka = DayOff.AllDay(title: "文化の日", holidayCalendar: true)
        XCTAssertTrue(DayOff.isOff(day(3), allDay: [bunka], calendar: cal))
        let furikae = DayOff.AllDay(title: "振替休日", holidayCalendar: true)
        XCTAssertTrue(DayOff.isOff(day(4, month: 5), allDay: [furikae], calendar: cal))
        // 祝日のカレンダーに入っている行事は休みではない
        XCTAssertFalse(DayOff.isOff(day(12), allDay: [DayOff.AllDay(title: "七五三", holidayCalendar: true)], calendar: cal))
        XCTAssertFalse(DayOff.isOff(day(12), allDay: [DayOff.AllDay(title: "何かの日", notes: "行事", holidayCalendar: true)],
                                    calendar: cal))
        // ほかのカレンダーの「文化の日」という題だけでは休みとみなさない
        XCTAssertFalse(DayOff.isOff(day(3), allDay: [DayOff.AllDay(title: "文化の日")], calendar: cal))
    }

    func testLeaveEventsAreOff() {
        let wed = day(11)
        for title in ["有休", "有給休暇", "年休", "代休", "夏休み", "お休み", "休暇（旅行）", "Day off"] {
            XCTAssertTrue(DayOff.isOff(wed, allDay: [DayOff.AllDay(title: title)], calendar: cal), title)
        }
        for title in ["午前休", "半休", "休日出勤", "休み明けの会議", "有休申請", "会議", ""] {
            XCTAssertFalse(DayOff.isOff(wed, allDay: [DayOff.AllDay(title: title)], calendar: cal), title)
        }
        // 1つでも休みの予定があれば休み
        XCTAssertTrue(DayOff.isOff(wed, allDay: [DayOff.AllDay(title: "会議"), DayOff.AllDay(title: "代休")], calendar: cal))
    }

    // MARK: - 朝夕の知らせの文

    func testWorkdayNoticeSplitsCounts() throws {
        let end = day(10)  // 9日（月）の終わり
        let open = [item("資料を送る", work: true, due: day(9)), item("古いもの", work: nil),
                    item("牛乳を買う", work: false)]
        let candidates = [item("候補", work: false, state: .candidate)]
        let n = try XCTUnwrap(Pipeline.taskNotice(open: open, candidates: candidates, end: end, morning: true,
                                                  offDay: false, afterOff: false))
        XCTAssertEqual(n.title, "今日の頼まれごと")
        XCTAssertTrue(n.body.hasPrefix("まだ 仕事 2 件・仕事以外 1 件（今日までのもの・過ぎたもの 1 件）・確かめ待ち 1 件"), n.body)
        XCTAssertTrue(n.body.contains("資料を送る"))
        XCTAssertTrue(n.body.contains("牛乳を買う"))
        let evening = try XCTUnwrap(Pipeline.taskNotice(open: open, candidates: [], end: end, morning: false,
                                                        offDay: false, afterOff: false))
        XCTAssertEqual(evening.title, "まだ済んでいない頼まれごと")
        XCTAssertFalse(evening.body.contains("確かめ待ち"))
    }

    func testDayOffNoticeShowsOnlyLife() throws {
        let end = day(8)  // 7日（土）の終わり
        let open = [item("資料を送る", work: true, due: day(6)), item("古いもの", work: nil),
                    item("牛乳を買う", work: false, due: day(7)),
                    item("返事を待つ", work: false, due: day(6), kind: .delegated, from: "母")]
        let candidates = [item("仕事の候補", work: true, state: .candidate), item("家の候補", work: false, state: .candidate)]
        let n = try XCTUnwrap(Pipeline.taskNotice(open: open, candidates: candidates, end: end, morning: true,
                                                  offDay: true, afterOff: false))
        XCTAssertEqual(n.title, "今日のやること（仕事以外）")
        XCTAssertTrue(n.body.hasPrefix("仕事以外 まだ 1 件（今日までのもの・過ぎたもの 1 件）・確かめ待ち 1 件"), n.body)
        XCTAssertTrue(n.body.contains("牛乳を買う"))
        XCTAssertTrue(n.body.contains("確かめる: 返事を待つ（母へ）"))
        XCTAssertFalse(n.body.contains("資料を送る"))
        XCTAssertFalse(n.body.contains("古いもの"))
        XCTAssertTrue(n.body.hasSuffix("仕事の分は、休み明けの朝に知らせます。"))
        // 仕事のものしか無ければ、休みの日は知らせない
        XCTAssertNil(Pipeline.taskNotice(open: [item("資料を送る", work: true)], candidates: [item("候補", work: nil, state: .candidate)],
                                         end: end, morning: true, offDay: true, afterOff: false))
        // 何も無ければ出勤日も知らせない
        XCTAssertNil(Pipeline.taskNotice(open: [], candidates: [], end: end, morning: true, offDay: false, afterOff: false))
    }

    func testMorningAfterDaysOffGathersWork() throws {
        let end = day(10)
        let open = (1...6).map { item("仕事\($0)", work: true, due: day(6)) } + [item("家", work: false)]
        let morning = try XCTUnwrap(Pipeline.taskNotice(open: open, candidates: [], end: end, morning: true,
                                                        offDay: false, afterOff: true))
        XCTAssertEqual(morning.title, "休み明けの頼まれごと（休みのあいだの分も）")
        XCTAssertTrue(morning.body.hasPrefix("まだ 仕事 6 件・仕事以外 1 件（今日までのもの・過ぎたもの 6 件）"), morning.body)
        // 休み明けの朝は5件まで並べる（ふだんは3件）
        XCTAssertEqual(morning.body.components(separatedBy: "\n・").count - 1, 5)
        let usual = try XCTUnwrap(Pipeline.taskNotice(open: open, candidates: [], end: end, morning: true,
                                                      offDay: false, afterOff: false))
        XCTAssertEqual(usual.body.components(separatedBy: "\n・").count - 1, 3)
        // 休み明けでも夕方はふだんどおり
        let evening = try XCTUnwrap(Pipeline.taskNotice(open: open, candidates: [], end: end, morning: false,
                                                        offDay: false, afterOff: true))
        XCTAssertEqual(evening.title, "まだ済んでいない頼まれごと")
    }

    // MARK: - ドライブの写し・朝の読み上げ・上限

    func testDriveCopyHasWorkAndLifeHeadings() {
        let p = Pipeline.taskBookParagraphs(open: [item("資料を送る", work: true), item("牛乳を買う", work: false),
                                                   item("古いもの", work: nil)],
                                            candidates: [item("家の候補", work: false, state: .candidate)], done: [])
        let headings = p.filter { $0.style == "HEADING_2" }.map { $0.text }
        XCTAssertEqual(headings, ["仕事", "仕事以外"])
        func index(_ text: String) -> Int? { p.firstIndex { $0.text.contains(text) } }
        let work = index("仕事")!, life = p.firstIndex { $0.text == "仕事以外" && $0.style == "HEADING_2" }!
        XCTAssertLessThan(work, life)
        XCTAssertLessThan(index("資料を送る")!, life)
        XCTAssertLessThan(index("古いもの")!, life)
        XCTAssertGreaterThan(index("牛乳を買う")!, life)
        XCTAssertGreaterThan(index("家の候補")!, life)
        XCTAssertTrue(p.contains { $0.text == "確かめ待ち（1 件）" && $0.style == "HEADING_3" })
    }

    func testMorningBriefSkipsWorkOnDaysOff() {
        let list = [item("資料を送る", work: true), item("古いもの", work: nil), item("牛乳を買う", work: false)]
        XCTAssertEqual(MorningBrief.tasksToRead(list, dayOff: true).map(\.what), ["牛乳を買う"])
        XCTAssertEqual(MorningBrief.tasksToRead(list, dayOff: false).count, 3)
    }

    func testLifeConversationDailyLimit() {
        XCTAssertEqual(Pipeline.taskLifeLeft(saved: nil, today: "2026-11-07"), Pipeline.taskLifePerDay)
        XCTAssertEqual(Pipeline.taskLifeLeft(saved: "2026-11-07|3", today: "2026-11-07"), Pipeline.taskLifePerDay - 3)
        // 前の日の数は数えない
        XCTAssertEqual(Pipeline.taskLifeLeft(saved: "2026-11-06|9", today: "2026-11-07"), Pipeline.taskLifePerDay)
        XCTAssertEqual(Pipeline.taskLifeLeft(saved: "2026-11-07|99", today: "2026-11-07"), 0)
        XCTAssertEqual(Pipeline.taskLifeLeft(saved: "こわれた", today: "2026-11-07"), Pipeline.taskLifePerDay)
        XCTAssertLessThanOrEqual(Pipeline.taskLifePerRun, 3)
    }
}

import XCTest
@testable import LifeLog

/// s30 のタブ担当（S30T。2026-11-27）: 下のタブを 今日・タスク・仕事・直す・記録 の 5 つにした決まり（S30TTabs.swift）を確かめる。
/// タブの並び・前のふり返り（lookBack）の行き先・仕事の画面の開き方・タスクタブの絞り（作りもののタスク）・面談の 1 枚の取り寄せをやめたこと。
@MainActor
final class S30TTabsTests: XCTestCase {
    private func item(_ what: String, work: Bool?, state: TaskBook.State = .open) -> TaskBook.Item {
        TaskBook.Item(what: what, said: Date(timeIntervalSince1970: 1_795_000_000), source: .manual, state: state, work: work)
    }

    // MARK: タブの並び

    func testBarIsFiveTabsInOrder() {
        XCTAssertEqual(S30TTabs.bar.map(\.title), ["今日", "タスク", "仕事", "直す", "記録"])
        XCTAssertEqual(S30TTabs.bar.map(\.tab), [.today, .tasks, .work, .fix, .records])
        XCTAssertEqual(S30TTabs.item(.work).symbol, "briefcase")
        XCTAssertEqual(S30TTabs.item(.today).symbol, "waveform")
        // 前のふり返りは下のタブに無い（名前を聞かれたら記録のもの）
        XCTAssertFalse(S30TTabs.bar.contains { $0.tab == .lookBack })
        XCTAssertFalse(S30TTabs.bar.contains { $0.title == "ふり返り" })
        XCTAssertEqual(S30TTabs.item(.lookBack).title, "記録")
        // 名前は 1 つずつ違う（UI テストが名前でタブを探す）
        XCTAssertEqual(Set(S30TTabs.bar.map(\.title)).count, 5)
        // AppTab は .work を足し、lookBack は残した（前の値を読める）
        XCTAssertEqual(AppTab(rawValue: "work"), .work)
        XCTAssertEqual(AppTab(rawValue: "lookBack"), .lookBack)
    }

    // MARK: 前のふり返り（lookBack）は記録へ

    func testLookBackGoesToRecords() {
        XCTAssertEqual(S30TTabs.shown(.lookBack), .records)
        for tab in [AppTab.today, .tasks, .work, .fix, .records] {
            XCTAssertEqual(S30TTabs.shown(tab), tab)
        }
        let open = S30TTabs.open(.tab(.lookBack), current: .today)
        XCTAssertEqual(open.tab, .records)
        XCTAssertEqual(open.recordsPage, .lookBack)
        XCTAssertNil(open.sheet)
        // ウィジェット・リンクの lifelog://lookback も同じ道（route → openRoute）
        let url = NoticeRoute.route(url: URL(string: "lifelog://lookback")!)
        XCTAssertEqual(url, .tab(.lookBack))
        if let url { XCTAssertEqual(S30TTabs.open(url, current: .tasks).tab, .records) }
        // ほかのタブは今までどおり（記録の切り替えは変えない）
        let records = S30TTabs.open(.tab(.records), current: .today)
        XCTAssertEqual(records.tab, .records)
        XCTAssertNil(records.recordsPage)
        XCTAssertEqual(S30TTabs.open(.tab(.tasks), current: .work), S30TTabs.Open(tab: .tasks, sheet: nil, recordsPage: nil))
    }

    func testRecordsPagesKeepOldValuesAndAddLookBack() {
        XCTAssertEqual(S30TTabs.RecordsPage.allCases.map(\.rawValue), ["日ごと", "人", "場所", "お金", "ふり返り"])
        // 保存の名前と、前に保存された値（文字）はそのまま読める
        XCTAssertEqual(S30TTabs.recordsPageKey, "recordsPage")
        XCTAssertEqual(S30TTabs.RecordsPage(rawValue: "お金"), .money)
        XCTAssertEqual(S30TTabs.RecordsPage(rawValue: "ふり返り"), .lookBack)
    }

    // MARK: 仕事の画面・仕事のまとめの取り込み

    func testWorkLinksSwitchToTheWorkTab() {
        // 仕事の入口（今日の「仕事:」の 1 行・ショートカット・lifelog://work）はタブを切り替えるだけ
        XCTAssertEqual(S30TTabs.open(.work(.home), current: .today), S30TTabs.Open(tab: .work, sheet: nil, recordsPage: nil))
        XCTAssertEqual(S30TTabs.open(.work(.home), current: .records).tab, .work)
        // 仕事タブにいるときの .home は前の一覧（S27W）をシートで
        XCTAssertEqual(S30TTabs.open(.work(.home), current: .work).sheet, .work(.home))
        // その先（案件・人・確かめ・お知らせ）は仕事タブに切り替えてから、前と同じシートで
        for link in [S27WLink.project("p1"), .person("u1"), .confirm, .notice] {
            let open = S30TTabs.open(.work(link), current: .today)
            XCTAssertEqual(open.tab, .work)
            XCTAssertEqual(open.sheet, .work(link))
        }
        if let route = NoticeRoute.route(url: URL(string: "lifelog://work")!) {
            XCTAssertEqual(S30TTabs.open(route, current: .fix), S30TTabs.Open(tab: .work, sheet: nil, recordsPage: nil))
        } else {
            XCTFail("lifelog://work が読めない")
        }
        // 取り込む画面は仕事タブの上に
        XCTAssertEqual(S30TTabs.open(.digestImport("文"), current: .tasks), S30TTabs.Open(tab: .work, sheet: .digestImport("文"), recordsPage: nil))
        // ほかのシートはタブを変えない
        XCTAssertEqual(S30TTabs.open(.screen(.money), current: .fix), S30TTabs.Open(tab: nil, sheet: .screen(.money), recordsPage: nil))
        XCTAssertNil(S30TTabs.open(.note(title: "題", body: "本文"), current: .today).tab)
    }

    // MARK: タスクタブの絞り（作りもののタスク）

    func testTasksTabShowsOnlyLifeTasks() {
        XCTAssertEqual(S30TTabs.taskScope, .life)
        let list = [item("見本の仕事", work: true), item("見本の家の用事", work: false), item("見本の古い頼まれごと", work: nil),
                    item("見本の買い物", work: false), item("見本の候補", work: true, state: .candidate)]
        // 仕事のもの・印の無い古いもの（仕事とみなす）は出ない。並びはそのまま
        XCTAssertEqual(TaskBook.filter(list, S30TTabs.taskScope).map(\.what), ["見本の家の用事", "見本の買い物"])
        // 仕事のタスクは消さない（仕事だけで絞れば全部ある。仕事タブが使う）
        XCTAssertEqual(TaskBook.filter(list, .work).map(\.what), ["見本の仕事", "見本の古い頼まれごと", "見本の候補"])
        XCTAssertEqual(TaskBook.filter(list, .all).count, list.count)
    }

    func testTaskNoticeTabFollowsTheTasks() {
        let work = item("見本の資料", work: true)
        let old = item("見本の古いもの", work: nil)
        let life = item("見本の本", work: false)
        let all = [work, old, life]
        XCTAssertEqual(S30TTabs.tab(forTasks: [work.id], in: all), .work)
        XCTAssertEqual(S30TTabs.tab(forTasks: [work.id, old.id], in: all), .work)
        XCTAssertEqual(S30TTabs.tab(forTasks: [work.id, life.id], in: all), .tasks)
        XCTAssertEqual(S30TTabs.tab(forTasks: [life.id], in: all), .tasks)
        // 見つからない・空はタスクタブ（前と同じ）
        XCTAssertEqual(S30TTabs.tab(forTasks: [], in: all), .tasks)
        XCTAssertEqual(S30TTabs.tab(forTasks: ["missing"], in: all), .tasks)
        XCTAssertEqual(S30TTabs.tab(forTasks: ["missing", work.id], in: all), .work)
    }

    // MARK: 面談の 1 枚

    func testInterviewSheetIsNoLongerFetched() {
        XCTAssertFalse(S20Book.feedNames.contains("interview"))
        XCTAssertEqual(S20Book.feedNames, ["reviewq", "featcheck", "devchecks", "holidaytags"])
    }
}

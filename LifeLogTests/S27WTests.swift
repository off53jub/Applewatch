import XCTest
@testable import LifeLog

/// s27 の A（S27WRules.swift・Shared/Widget/S27WWorkCounts.swift）: K2 の読み方・信号の色・伏せ字・並べ方・
/// 聞いた話の新しさ・K4 の答えの形・K6 のリンク・端末の写しで引く。見本の名前はどれも作りもの（実在の人・会社・案件ではない）。
final class S27WTests: XCTestCase {
    private static let sample = """
    {"version":1,"generated_at":"2026-11-25T07:00:00+09:00","as_of":"2026-11-25",
     "counts":{"homework_today":2,"open_mine":7,"next_meeting_at":"2026-11-25T10:00:00+09:00"},
     "today":{"homework":[{"id":"h1","kind":"homework","text":"見本さんに見本の表を送る","project_id":"wp-00000001","who":"見本さん",
                           "day":"2026-11-24","time":"15:30","due":"2026-11-26","due_guess":true,"ball":"me","age_days":3,
                           "state":"open","certainty":"maybe","src":"talk","link":null},
                          {"id":"h2","kind":"homework","text":"壊れた行"},
                          {"kind":"homework","text":"id の無い行は飛ばす"}],
              "waiting_on_me":[],"waiting_on_others":[],
              "stuck_by_me":[{"id":"s1","kind":"homework","text":"古い","age_days":9},{"id":"s2","kind":"open","text":"新しい","age_days":1},
                             {"id":"s3","kind":"homework","text":"中","age_days":4},{"id":"s4","kind":"homework","text":"もっと古い","age_days":12}],
              "standup":["きのう: 見本の確認","今日: 見本の表","困っていること: なし"],
              "meetings":[{"start":"2026-11-25T10:00:00+09:00","end":"2026-11-25T11:00:00+09:00","title":"見本の定例","project_id":"wp-00000001",
                           "prep":{"last_decided":[{"id":"d1","kind":"decided","text":"見本の進め方を決めた","day":"2026-11-20"}],"open":[],"my_homework":[],"ask":["見本の残り"]}}]},
     "diff":{"since":"2026-11-24","added":[],"closed":[],"decided":[]},
     "projects":[
       {"id":"wp-00000001","name":"見本の案件 A","client":"見本商事","kind":"mine","signal":"orange","status_line":"見本商事の返事待ち",
        "last_moved":"2026-11-24","counts":{"homework":2,"open":1,"issue":0,"decided":3},
        "people":[{"id":"wm-00000001","name":"見本さん","role":"窓口"}],
        "milestone":{"day":"2026-11-30","title":"見本の締め","days_left":5},
        "progress":[{"day":"2026-11-20","label":"消化","value":10},{"day":"2026-11-24","label":"消化","value":25},{"day":"2026-11-24","label":"NG","value":2}],
        "items":[{"id":"i1","kind":"open","text":"#212 の見本の件","day":"2026-11-24"},{"id":"i2","kind":"decided","text":"見本の形で進める","day":"2026-11-23","time":"10:00"}],
        "timeline":[],"heard":[],"stale":false},
       {"id":"wp-00000002","name":"見本の案件 B","kind":"mine","signal":"red","last_moved":"2026-11-20"},
       {"id":"wp-00000003","name":"見本の案件 C","kind":"mine","signal":"purple","last_moved":"2026-11-25"},
       {"id":"wp-00000004","name":"よその見本","kind":"other","heard":[{"text":"人が足りないらしい","day":"2026-11-01","from":"見本先輩","where":"talk","old":false}]}],
     "people":[{"id":"wm-00000002","name":"見本先輩","org":"self_company","team":null,"role":null,"projects":["wp-00000004"],
                "ball":{"me":1,"them":0}},
               {"id":"wm-00000001","name":"見本さん","org":"client","team":"見本チーム","role":"窓口","projects":["wp-00000001"]},
               {"id":"wm-00000003","name":"甲","org":"unknown"}],
     "side":{"status":"moved","last_day":"2026-11-24","items":[]},
     "monthly_other":null}
    """

    private var board: S27WBoard {
        S27WRules.board(Data(Self.sample.utf8))!
    }

    // MARK: K2 を読む

    func testDecodeSkipsBrokenRowsAndKeepsTheRest() {
        let b = board
        XCTAssertEqual(b.asOf, "2026-11-25")
        XCTAssertEqual(b.counts?.homeworkToday, 2)
        XCTAssertEqual(b.today.homework.map(\.id), ["h1", "h2"], "id の無い行だけ飛ばす")
        let h1 = b.today.homework[0]
        XCTAssertTrue(h1.isMaybe)
        XCTAssertEqual(h1.dueGuess, true)
        XCTAssertEqual(h1.projectID, "wp-00000001")
        XCTAssertEqual(b.projects.count, 4)
        XCTAssertEqual(b.projects[0].counts.decided, 3)
        XCTAssertEqual(b.projects[0].milestone?.daysLeft, 5)
        XCTAssertEqual(b.projects[3].heard.first?.place, "talk")
        XCTAssertEqual(b.people.count, 3)
        XCTAssertEqual(b.people[0].ball.me, 1)
        XCTAssertEqual(b.side?.status, "moved")
        XCTAssertEqual(b.today.meetings.first?.prep?.ask, ["見本の残り"])
    }

    func testUnavailableBoardIsNil() {
        let data = Data(#"{"available":false}"#.utf8)
        XCTAssertNil(S27WRules.board(data))
        XCTAssertTrue(S27WRules.unavailable(data))
        XCTAssertFalse(S27WRules.unavailable(Data("こわれた".utf8)))
        XCTAssertNil(S27WRules.board(Data("こわれた".utf8)))
    }

    func testConfirmAndAnswersDecode() {
        let confirm = #"{"version":1,"items":[{"id":"c1","kind":"person_org","title":"見本さん","question":"どこの人？","choices":[{"value":"client","label":"顧客"},{"value":"vendor","label":"ベンダー"}],"evidence":["11/24 の会話"],"default":"client"},{"id":"c2"}]}"#
        let items = S27WRules.confirmItems(Data(confirm.utf8))
        XCTAssertEqual(items?.map(\.id), ["c1"])
        XCTAssertEqual(items?.first?.defaultValue, "client")
        let ask = #"{"answers":[{"project_id":"wp-00000001","name":"見本の案件 A","status_line":"待ち","last_decided":null,"open":[{"id":"x","text":"見本"}],"link":"lifelog://work/project/wp-00000001"}]}"#
        let answers = S27WRules.answers(Data(ask.utf8))
        XCTAssertEqual(answers?.first?.open.count, 1)
        XCTAssertNil(answers?.first?.lastDecided)
    }

    // MARK: 場3 信号

    func testSignalRolesFollowTheColorRoles() {
        XCTAssertEqual(S27WSignal.red.role, .act)
        XCTAssertEqual(S27WSignal.orange.role, .wait)
        XCTAssertNil(S27WSignal.gray.role)
        XCTAssertNil(S27WSignal.green.role)
        XCTAssertEqual(board.projects[2].signalKind, .gray, "知らない色は灰")
    }

    func testMineSortedBySignalThenMoved() {
        let sorted = S27WRules.sortedMine(board.projects)
        XCTAssertEqual(sorted.map(\.id), ["wp-00000002", "wp-00000001", "wp-00000003"])
        XCTAssertEqual(S27WRules.sortedByMoved(board.projects, kind: "other").map(\.id), ["wp-00000004"])
    }

    func testPeopleSortedByNameOnly() {
        // 守3: 数（ball）で並べない
        let names = S27WRules.sortedPeople(board.people).map(\.name)
        XCTAssertEqual(names, ["見本さん", "甲", "見本先輩"].sorted())
    }

    func testStuckIsOldestThree() {
        XCTAssertEqual(S27WRules.stuck(board.today.stuckByMe).map(\.id), ["s4", "s1", "s3"])
    }

    // MARK: 守2 伏せ字

    func testMaskReplacesPeopleAndClients() {
        let mask = S27WMask.make(board)
        XCTAssertEqual(mask.names["見本先輩"], "人1")
        XCTAssertEqual(mask.names["見本さん"], "人2")
        XCTAssertNil(mask.names["甲"], "1 文字の名前は伏せない（仮）")
        XCTAssertEqual(mask.names["見本商事"], "顧客1")
        XCTAssertEqual(mask.apply("見本商事の見本さんに送る"), "顧客1の人2に送る")
        XCTAssertEqual(mask.apply("見本先輩から聞いた"), "人1から聞いた", "長い名前から置き換える")
        XCTAssertEqual(mask.person("見本さん"), "人2")
        XCTAssertEqual(mask.person("知らない人"), "だれか")
        XCTAssertNil(mask.person(nil))
    }

    // MARK: 守4 日と出どころ

    func testMetaAndChips() {
        let h1 = board.today.homework[0]
        XCTAssertEqual(S27WRules.meta(h1, mask: nil), "11/24 15:30・会話・見本さん")
        XCTAssertEqual(S27WRules.meta(h1, mask: S27WMask.make(board)), "11/24 15:30・会話・人2")
        XCTAssertEqual(S27WRules.chips(h1), ["たぶん", "期限 11/26（仮）", "自分の番", "3 日そのまま"])
    }

    // MARK: 他2 聞いた話の新しさ

    func testFreshness() {
        XCTAssertEqual(S27WRules.freshness(day: "2026-11-24", old: nil, today: "2026-11-25"), .fresh)
        XCTAssertEqual(S27WRules.freshness(day: "2026-11-18", old: nil, today: "2026-11-25"), .faded)
        XCTAssertEqual(S27WRules.freshness(day: "2026-10-26", old: nil, today: "2026-11-25"), .old)
        XCTAssertEqual(S27WRules.freshness(day: "2026-11-24", old: true, today: "2026-11-25"), .old)
        XCTAssertEqual(S27WRules.freshness(day: nil, old: nil, today: "2026-11-25"), .faded)
        let heard = board.projects[3].heard[0]
        XCTAssertEqual(S27WRules.heardMeta(heard, mask: nil), "11/1・見本先輩から・会話")
    }

    // MARK: 案6・案9

    func testSeriesNeedsTwoPoints() {
        let s = S27WRules.series(board.projects[0].progress)
        XCTAssertEqual(s.map(\.label), ["消化"])
        XCTAssertEqual(s.first?.points.map(\.value), [10, 25])
    }

    func testMilestoneLine() {
        let m = S27WMilestone(day: "2026-11-30", title: "見本の締め", daysLeft: nil)
        XCTAssertEqual(S27WRules.milestoneLine(m, today: "2026-11-25"), "節目: 見本の締め（11/30）まで あと 5 日")
        XCTAssertEqual(S27WRules.milestoneLine(m, today: "2026-11-30"), "節目: 見本の締め（11/30）まで 今日")
        XCTAssertEqual(S27WRules.milestoneLine(m, today: "2026-12-02"), "節目: 見本の締め（11/30）まで 2 日過ぎ")
    }

    // MARK: 場2・場6・場8 数

    func testTodayLineAndWidgetCountsHaveNoText() {
        XCTAssertEqual(S27WRules.todayLine(board), "仕事: 宿題 2・会議 1")
        let now = S27WRules.date("2026-11-25T08:00:00+09:00")!
        let counts = S27WRules.widgetCounts(board, now: now)
        XCTAssertEqual(counts.homeworkToday, 2)
        XCTAssertEqual(counts.openMine, 7)
        XCTAssertEqual(counts.nextMeeting, S27WRules.date("2026-11-25T10:00:00+09:00"))
        // 守1: ウィジェットへ渡すものに文・名前が無い
        let json = String(data: try! JSONEncoder().encode(counts), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("見本"))
    }

    func testNextMeetingSkipsFinished() {
        let meetings = [S27WMeeting(start: "2026-11-25T09:00:00+09:00", end: "2026-11-25T09:30:00+09:00", title: "朝"),
                        S27WMeeting(start: "2026-11-25T13:00:00.000+09:00", title: "昼")]
        let now = S27WRules.date("2026-11-25T10:00:00+09:00")!
        XCTAssertEqual(S27WRules.nextMeeting(meetings, now: now)?.title, "昼")
        XCTAssertNil(S27WRules.nextMeeting(meetings, now: now.addingTimeInterval(5 * 3600)))
    }

    func testWidgetCountsRoundTrip() {
        let suite = "s27w.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let counts = S27WWorkCounts(homeworkToday: 3, openMine: 4, nextMeeting: at, updated: at)
        XCTAssertTrue(counts.write(defaults: defaults))
        XCTAssertFalse(counts.write(defaults: defaults), "同じ数は書き直さない")
        XCTAssertEqual(S27WWorkCounts.read(defaults: defaults), counts)
        XCTAssertEqual(counts.line, "宿題 3・開いている 4")
        XCTAssertNil(counts.upcoming(now: at.addingTimeInterval(1)))
        XCTAssertTrue(counts.isStale(now: at.addingTimeInterval(40 * 3600)))
        S27WWorkCounts.clear(defaults: defaults)
        XCTAssertNil(S27WWorkCounts.read(defaults: defaults))
    }

    // MARK: K4 答えの形

    private func object(_ data: Data?) -> [String: String]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }

    func testFeedbackBodies() {
        let day = "2026-11-25"
        XCTAssertEqual(object(S27WRules.feedback(kind: "work_confirm", id: "c1", value: "client", day: day)),
                       ["kind": "work_confirm", "id": "c1", "value": "client", "day": day])
        XCTAssertNil(S27WRules.feedback(kind: "work_confirm", id: "", value: "client", day: day))
        XCTAssertNotNil(S27WRules.feedback(kind: "work_edit", id: "wm-00000001", value: #"{"team":"見本"}"#, day: day))
        XCTAssertNil(S27WRules.feedback(kind: "work_edit", id: "h1", value: #"{"team":"見本"}"#, day: day), "人・案件の id だけ")
        XCTAssertNotNil(S27WRules.feedback(kind: "work_numbers", id: "", value: "消化 25", day: day))
        XCTAssertNotNil(S27WRules.feedback(kind: "work_numbers", id: "wp-00000001", value: "消化 25", day: day))
        XCTAssertNil(S27WRules.feedback(kind: "work_numbers", id: "wp-00000001", value: "  ", day: day))
        XCTAssertNil(S27WRules.feedback(kind: "work_numbers", id: "", value: String(repeating: "あ", count: S27WRules.textLimit + 1), day: day))
        XCTAssertNotNil(S27WRules.feedback(kind: "work_notice", id: "", value: "見本のお知らせ", day: day))
        XCTAssertNil(S27WRules.feedback(kind: "work_notice", id: "x", value: "見本のお知らせ", day: day))
        XCTAssertNotNil(S27WRules.feedback(kind: "work_done", id: "h1", value: "done", day: day))
        XCTAssertNotNil(S27WRules.feedback(kind: "work_done", id: "h1", value: "undo", day: day))
        XCTAssertNil(S27WRules.feedback(kind: "work_done", id: "h1", value: "maybe", day: day))
        XCTAssertNil(S27WRules.feedback(kind: "work_done", id: "h1", value: "done", day: "11/25"))
        XCTAssertNil(S27WRules.feedback(kind: "work_other", id: "h1", value: "done", day: day))
    }

    func testEditValueOnlyChangedAllowedFields() {
        let changes = S27WRules.changed(old: ["name": "見本さん", "team": "", "role": "窓口", "org": "client"],
                                        new: ["name": "見本さん", "team": "見本チーム", "role": "窓口", "org": "vendor"])
        XCTAssertEqual(changes, ["team": "見本チーム", "org": "vendor"])
        let value = S27WRules.editValue(changes)
        XCTAssertEqual(value, #"{"org":"vendor","team":"見本チーム"}"#)
        XCTAssertNil(S27WRules.editValue([:]))
        XCTAssertNil(S27WRules.editValue(["name": "  "]), "名前は空にできない")
        XCTAssertNil(S27WRules.editValue(["org": "どこか"]))
        XCTAssertNil(S27WRules.editValue(["secret": "x"]))
        XCTAssertEqual(S27WRules.editValue(["kind": "side"]), #"{"kind":"side"}"#)
        XCTAssertTrue(S27WRules.canEdit("wm-00000001"))
        XCTAssertFalse(S27WRules.canEdit("wx-00000001"), "台帳ができる前の仮の id は直さない")
    }

    func testPrunedEditsAndDoneIDs() {
        let edits: [String: [String: String]] = ["wm-00000001": ["team": "見本チーム", "role": "新しい役"], "wm-09999999": ["name": "x"]]
        XCTAssertEqual(S27WRules.pruned(edits, board: board), ["wm-00000001": ["role": "新しい役"]])
        var b = board
        b.today.homework[0].state = "done"
        XCTAssertEqual(S27WRules.doneIDs(b), ["h1"])
    }

    // MARK: 守6 まとめて 1 回

    func testConfirmAnswersOnlyValidPicks() {
        let items = [S27WConfirmItem(id: "c1", title: "見本", question: "?", choices: [S27WChoice(value: "a", label: "A")]),
                     S27WConfirmItem(id: "c2", title: "見本", question: "?", choices: [S27WChoice(value: "b", label: "B")]),
                     S27WConfirmItem(id: "c3", title: "見本", question: "?", choices: [])]
        let out = S27WRules.confirmAnswers(items, picks: ["c1": "a", "c2": "z", "c9": "a"])
        XCTAssertEqual(out.map { $0.id }, ["c1"])
        XCTAssertEqual(S27WRules.unanswered(items, answered: ["c1"]).map(\.id), ["c2"], "答えたもの・選べないものは出さない")
        XCTAssertEqual(S27WRules.unanswered(items, answered: [], limit: 1).map(\.id), ["c1"])
    }

    // MARK: K6 リンク

    func testLinks() {
        XCTAssertEqual(S27WLink.parse(URL(string: "lifelog://work")!), .home)
        XCTAssertEqual(S27WLink.parse(URL(string: "lifelog://work?w=work")!), .home)
        XCTAssertEqual(S27WLink.parse(URL(string: "lifelog://work/project/wp-00000001")!), .project("wp-00000001"))
        XCTAssertEqual(S27WLink.parse(URL(string: "lifelog://work/person/wm-00000001")!), .person("wm-00000001"))
        XCTAssertEqual(S27WLink.parse(URL(string: "lifelog://work/confirm")!), .confirm)
        XCTAssertNil(S27WLink.parse(URL(string: "lifelog://tasks")!))
        XCTAssertNil(S27WLink.parse(URL(string: "https://work/confirm")!))
        XCTAssertEqual(S27WLink.project("wp-00000001").url?.absoluteString, "lifelog://work/project/wp-00000001")
        XCTAssertNil(S27WLink.notice.url)
    }

    @MainActor
    func testNoticeRouteOpensWork() {
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://work/confirm")!), .work(.confirm))
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://tasks")!), .tab(.tasks))
    }

    // MARK: 場7 端末の写しで引く

    func testLocalAnswers() {
        let b = board
        XCTAssertEqual(S27WRules.localAnswers(b, query: "案件 a").map(\.projectID), ["wp-00000001"], "空白と大文字小文字を見ない")
        let ticket = S27WRules.localAnswers(b, query: "＃212")
        XCTAssertEqual(ticket.map(\.projectID), ["wp-00000001"], "全角の＃でも引ける")
        XCTAssertEqual(ticket.first?.lastDecided?.id, "i2")
        XCTAssertEqual(ticket.first?.open.map(\.id), ["i1"])
        XCTAssertEqual(S27WRules.localAnswers(b, query: "見本先輩").map(\.projectID), ["wp-00000004"])
        XCTAssertTrue(S27WRules.localAnswers(b, query: "  ").isEmpty)
    }

    func testSpokenAnswer() {
        let answers = S27WRules.localAnswers(board, query: "#212")
        let text = S27WRules.spoken(answers, mask: S27WMask.make(board))
        XCTAssertTrue(text.hasPrefix("見本の案件 A。顧客1の返事待ち。"))
        XCTAssertTrue(text.contains("最後に決まったこと（11/23に）: 見本の形で進める。"))
        XCTAssertTrue(text.contains("開いているものが 1 件。"))
        XCTAssertEqual(S27WRules.spoken([], mask: nil), "仕事の記録に、その件は見つかりませんでした。")
    }

    func testCountsLine() {
        XCTAssertEqual(S27WRules.countsLine(board.projects[0]), "宿題 2・未決 1・指摘 0・最後に動いた日 11/24")
        XCTAssertEqual(S27WRules.countsLine(board.projects[3]), "宿題 0・未決 0・指摘 0・最後に動いた日 分からない")
    }
}

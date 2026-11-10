import XCTest
@testable import LifeLog

/// タスクを1つの一覧にする・今日の三つの解き方・家の PC の1日のまとめ（2026-11-10）。
/// 文はすべて作り物。
@MainActor
final class OneTaskListTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ d: Int, _ h: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
    }

    // MARK: - 新しい項目を読む

    func testNewKeysAreRead() throws {
        let json = """
        {"available": true, "generated_at": "2026-11-10T07:00:00+09:00",
         "plan": {"source": "codex", "generated_at": "2026-11-10T07:01:00+09:00", "day": "2026-11-10"},
         "today_three": [{"id": "0123456789ab", "text": "見積書を仕上げて送る", "why": "会議の前に",
                          "how": ["前回の表を開く", " ", "数字を直す"], "minutes": 30,
                          "draft": "見積書をお送りします。ご確認ください。", "origin": "app", "work": true,
                          "item_text": "見積書を作る"}],
         "items": [{"id": "ba9876543210", "text": "電球を買う", "work": false}],
         "day_summaries": [{"day": "2026-11-09", "generated_at": "2026-11-10T06:30:00+09:00",
                            "summary": "散歩と買い物の日。",
                            "sections": [{"heading": "主要な出来事", "lines": ["09:03 公園を散歩"]}]}]}
        """
        let export = try XCTUnwrap(MothershipExport.parse(Data(json.utf8)))
        XCTAssertEqual(export.plan?.source, "codex")
        XCTAssertEqual(export.plan?.day, "2026-11-10")
        let three = try XCTUnwrap(export.todayThree.first)
        // 空の手順は捨てる
        XCTAssertEqual(three.how, ["前回の表を開く", "数字を直す"])
        XCTAssertEqual(three.minutes, 30)
        XCTAssertEqual(three.draft, "見積書をお送りします。ご確認ください。")
        XCTAssertEqual(three.origin, "app")
        XCTAssertTrue(three.isAppTask)
        XCTAssertEqual(three.work, true)
        XCTAssertEqual(three.itemText, "見積書を作る")
        XCTAssertEqual(export.daySummaries?.count, 1)
        XCTAssertEqual(export.daySummary("2026-11-09")?.summary, "散歩と買い物の日。")
        XCTAssertNil(export.daySummary("2026-11-08"))
        XCTAssertTrue(export.chosenFromSituation(day: "2026-11-10"))
        XCTAssertFalse(export.chosenFromSituation(day: "2026-11-11"))
    }

    func testOldJSONWithoutNewKeysStillWorks() throws {
        let json = """
        {"available": true, "generated_at": "2026-11-09T07:05:00+09:00",
         "today_three": [{"id": "0123456789ab", "text": "電球を買う", "why": "期限が今日"}],
         "items": [{"id": "0123456789ab", "text": "電球を買う", "work": false}]}
        """
        let export = try XCTUnwrap(MothershipExport.parse(Data(json.utf8)))
        XCTAssertNil(export.plan)
        XCTAssertNil(export.daySummaries)
        XCTAssertNil(export.todayThree.first?.how)
        XCTAssertNil(export.todayThree.first?.minutes)
        XCTAssertNil(export.todayThree.first?.origin)
        XCTAssertFalse(export.todayThree.first?.isAppTask ?? true)
        XCTAssertFalse(export.chosenFromSituation(day: "2026-11-09"))
        // 前の版で覚えた形（新しい項目の無いもの）も読め、書いて読み直しても変わらない
        let again = try JSONDecoder().decode(MothershipExport.self, from: JSONEncoder().encode(export))
        XCTAssertEqual(again, export)
    }

    func testBrokenNewKeysDoNotBreakTheRest() throws {
        let json = """
        {"available": true, "plan": "codex",
         "today_three": [{"id": "0123456789ab", "text": "電球を買う", "minutes": "30", "how": "手順"}],
         "items": [{"id": "0123456789ab", "text": "電球を買う"}],
         "day_summaries": {"day": "2026-11-09"}}
        """
        let export = try XCTUnwrap(MothershipExport.parse(Data(json.utf8)))
        XCTAssertEqual(export.items.count, 1)
        XCTAssertEqual(export.todayThree.first?.text, "電球を買う")
        XCTAssertNil(export.todayThree.first?.minutes)
        XCTAssertNil(export.todayThree.first?.how)
        XCTAssertNil(export.plan)
        XCTAssertNil(export.daySummaries)
    }

    func testMachinePlanIsNotChosen() {
        var export = MothershipExport(plan: .init(source: "machine", generatedAt: nil, day: "2026-11-10"))
        XCTAssertFalse(export.chosenFromSituation(day: "2026-11-10"))
        export.plan = .init(source: "codex", generatedAt: nil, day: nil)
        XCTAssertTrue(export.chosenFromSituation(day: "2026-11-10"))
    }

    func testNewKeysSurviveSaving() throws {
        let export = MothershipExport(
            todayThree: [.init(id: "0123456789ab", text: "電球を買う", why: "切れた", how: ["店に寄る"], minutes: 15,
                               draft: nil, origin: "todo", work: false, itemText: nil)],
            items: [MothershipTodo(id: "0123456789ab", text: "電球を買う", work: false)],
            plan: .init(source: "codex", generatedAt: "2026-11-10T07:00:00+09:00", day: "2026-11-10"),
            daySummaries: [.init(day: "2026-11-09", generatedAt: nil, summary: "静かな日。", sections: [])])
        let again = try JSONDecoder().decode(MothershipExport.self, from: JSONEncoder().encode(export))
        XCTAssertEqual(again, export)
    }

    // MARK: - 同じやることか

    func testSameTaskMatching() {
        // 句読点・全角半角・大文字小文字の違いだけ
        XCTAssertTrue(OneTaskList.same("ＰＤＦを送る。", "pdfを送る"))
        XCTAssertTrue(OneTaskList.same("電球を買う", "電球を買う"))
        // 片方がもう片方を含む（短い方が4文字以上で、長い方の半分以上）
        XCTAssertTrue(OneTaskList.same("請求書を出す", "今月分の請求書を出す"))
        // 2文字ずつの重なりが7割以上（1文字だけ違う長い文。重なりは 15/19 ≒ 0.79）
        XCTAssertTrue(OneTaskList.same("来週の会議の資料を共有フォルダに置く", "来週の会議の資料を共有フォルダへ置く"))
        XCTAssertGreaterThanOrEqual(OneTaskList.overlap(OneTaskList.normalized("来週の会議の資料を共有フォルダに置く"),
                                                        OneTaskList.normalized("来週の会議の資料を共有フォルダへ置く")), 0.7)
        // 迷うものは別にする（両方出す）
        XCTAssertFalse(OneTaskList.same("牛乳を買う", "牛乳を飲む"))
        XCTAssertFalse(OneTaskList.same("資料を送る", "資料を作る"))
        XCTAssertFalse(OneTaskList.same("電気", "電気代を払う"))
        XCTAssertFalse(OneTaskList.same("申込書", "申込書を書いて、窓口に出して、控えをもらう"))
        XCTAssertFalse(OneTaskList.same("", "電球を買う"))
    }

    func testExtraHidesOnlyTheSameOnes() {
        let task = TaskBook.Item(what: "請求書を出す", said: at(1), source: .manual, state: .open, work: true)
        let home = [MothershipTodo(id: "000000000001", text: "請求書を出す。", work: true),
                    MothershipTodo(id: "000000000002", text: "電球を買う", work: false)]
        XCTAssertEqual(OneTaskList.extra(home, tasks: [task]).map(\.id), ["000000000002"])
        XCTAssertEqual(OneTaskList.match("今月分の請求書を出す", in: [task])?.id, task.id)
    }

    func testDoneInAppFollowsToHome() {
        let since = at(9)
        var done = TaskBook.Item(what: "請求書を出す", said: at(1), source: .manual, state: .done, work: true)
        done.doneAt = at(10, 9)
        var old = TaskBook.Item(what: "電球を買う", said: at(1), source: .manual, state: .done, work: false)
        old.doneAt = at(8, 9)
        let home = [MothershipTodo(id: "000000000001", text: "請求書を出す", work: true),
                    MothershipTodo(id: "000000000002", text: "電球を買う", work: false),
                    MothershipTodo(id: "000000000003", text: "棚を直す", work: false)]
        // 1つの一覧にする前に済んだものは送らない
        XCTAssertEqual(OneTaskList.doneByApp(home, tasks: [done, old], since: since).map(\.id), ["000000000001"])
        // 同じ文のまだのタスクもあるときは、迷うので送らない
        let open = TaskBook.Item(what: "請求書を出す", said: at(2), source: .manual, state: .open, work: true)
        XCTAssertTrue(OneTaskList.doneByApp(home, tasks: [done, open], since: since).isEmpty)
    }

    func testBucketOfHomeTodo() {
        let now = at(10, 9)
        XCTAssertEqual(OneTaskList.bucket(MothershipTodo(id: "000000000001", text: "a", due: "2026-11-09"), now: now, calendar: tokyo), .late)
        XCTAssertEqual(OneTaskList.bucket(MothershipTodo(id: "000000000002", text: "b", due: "2026-11-10"), now: now, calendar: tokyo), .today)
        XCTAssertEqual(OneTaskList.bucket(MothershipTodo(id: "000000000003", text: "c", due: "2026-11-15"), now: now, calendar: tokyo), .week)
        XCTAssertEqual(OneTaskList.bucket(MothershipTodo(id: "000000000004", text: "d"), now: now, calendar: tokyo), .someday)
    }

    // MARK: - 今日の三つの解き方

    private var threes: [MothershipExport.Three] {
        [.init(id: "aaaaaaaaaaaa", text: "見積書を仕上げて送る", why: "会議の前に", how: ["前回の表を開く", "数字を直す"],
               minutes: 30, origin: "app", work: true, itemText: "見積書を作る"),
         .init(id: "bbbbbbbbbbbb", text: "もう済んだこと", origin: "app", itemText: "アプリに無いタスク"),
         .init(id: "cccccccccccc", text: "友だちに返事をする", why: "", how: ["予定を見る"], minutes: 10,
               draft: "土曜なら空いています。", origin: "new")]
    }

    func testChosenPicksComeFirstWithHowTo() {
        let now = at(10, 7)
        let estimate = TaskBook.Item(what: "見積書を作る", due: at(20), said: at(1), source: .manual, state: .open, work: true)
        let fee = TaskBook.Item(what: "会費を払う", due: at(8), said: at(1), source: .manual, state: .open, work: false)
        let three = MorningBrief.pickThree(open: [estimate, fee], mothership: threes, mothershipWork: [],
                                           dayOff: false, now: now, chosen: true, calendar: tokyo)
        XCTAssertEqual(three.map(\.text), ["見積書を仕上げて送る", "友だちに返事をする", "会費を払う"])
        // アプリのタスクに当たったものは、アプリのタスクを済みにする（家の PC の id には送らない）
        XCTAssertEqual(three[0].taskID, estimate.id)
        XCTAssertNil(three[0].homeID)
        XCTAssertEqual(three[0].how, ["前回の表を開く", "数字を直す"])
        XCTAssertEqual(three[0].minutes, 30)
        XCTAssertTrue(three[0].hasHowTo)
        XCTAssertEqual(three[1].draft, "土曜なら空いています。")
        XCTAssertNil(three[1].homeID)
        XCTAssertEqual(three[2].why, "期限切れ")
        XCTAssertEqual(three[2].taskID, fee.id)
        XCTAssertFalse(three[2].hasHowTo)
    }

    func testNotChosenKeepsOldOrder() {
        let now = at(10, 7)
        let fee = TaskBook.Item(what: "会費を払う", due: at(8), said: at(1), source: .manual, state: .open, work: false)
        let three = MorningBrief.pickThree(open: [fee],
                                           mothership: [.init(id: "dddddddddddd", text: "棚を直す", why: "前から")],
                                           mothershipWork: [], dayOff: false, now: now, calendar: tokyo)
        XCTAssertEqual(three.map(\.text), ["会費を払う", "棚を直す"])
        XCTAssertEqual(three[1].homeID, "dddddddddddd")
    }

    func testCardShowsFirstStepOnce() {
        var input = MorningBrief.Input(date: at(10))
        input.three = [MorningBrief.Pick(text: "会費を払う", why: "期限切れ"),
                       MorningBrief.Pick(text: "見積書を仕上げて送る", why: "", how: ["前回の表を開く", "数字を直す"]),
                       MorningBrief.Pick(text: "友だちに返事をする", why: "", how: ["予定を見る"])]
        let lines = MorningBrief.card(input, calendar: tokyo).components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("まず: ") }, ["まず: 前回の表を開く"])
        // 解き方が無ければ、前と同じ
        input.three = [MorningBrief.Pick(text: "会費を払う", why: "期限切れ")]
        XCTAssertFalse(MorningBrief.card(input, calendar: tokyo).contains("まず: "))
    }

    // MARK: - 家の PC の1日のまとめ

    private var sample: MothershipExport.DaySummary {
        .init(day: "2026-11-09", generatedAt: "2026-11-10T06:30:00+09:00",
              summary: "散歩と買い物の日。\n9時に起きた。",
              sections: [.init(heading: "主要な出来事", lines: ["09:03 公園を散歩", "・14:10 本屋に寄る", " "]),
                         .init(heading: "決まったこと", lines: ["次の週末は部屋の片づけ"]),
                         .init(heading: "空の見出し", lines: [])])
    }

    func testDocBodyText() {
        XCTAssertEqual(sample.docBody,
                       "散歩と買い物の日。\n・9時に起きた。\n主要な出来事\n・09:03 公園を散歩\n・14:10 本屋に寄る\n"
                       + "決まったこと\n・次の週末は部屋の片づけ\n（家の PC が作ったまとめです）\n\n")
    }

    func testFlowAndDecisionsForMorning() {
        XCTAssertEqual(sample.flow, ["09:03 公園を散歩", "14:10 本屋に寄る"])
        XCTAssertEqual(sample.decisions, ["次の週末は部屋の片づけ"])
        XCTAssertEqual(MorningBrief.flowLine(sample.flow[0]), "9:03 公園を散歩")
        // 見出しが無ければ、まとめの文
        let plain = MothershipExport.DaySummary(day: "2026-11-09", summary: "静かな日。")
        XCTAssertEqual(plain.flow, ["静かな日。"])
        XCTAssertTrue(plain.decisions.isEmpty)
        XCTAssertTrue(MothershipExport.DaySummary(day: "2026-11-09", summary: " ", sections: [.init(heading: "x", lines: [" "])]).isEmpty)
    }

    func testWhichDaysToWrite() {
        let summaries = [MothershipExport.DaySummary(day: "2026-11-10", summary: "今日の分"),
                         MothershipExport.DaySummary(day: "2026-11-09", summary: "昨日の分"),
                         MothershipExport.DaySummary(day: "2026-11-08", summary: "おとといの分"),
                         MothershipExport.DaySummary(day: "2026-11-07", summary: "")]
        let days = HomeSummaryLog.toWrite(summaries, written: ["2026-11-08": "x"], today: "2026-11-10").map(\.day)
        // 今日の分（まだ終わっていない）・載せた日・中身の無い日は書かない
        XCTAssertEqual(days, ["2026-11-09"])
    }
}

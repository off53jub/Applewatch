import XCTest
import UserNotifications
@testable import LifeLog

/// 2026-11-10 の強化（知らせのボタン・期限の1時間前・違う理由・7日で片づける・1日のまとめの絞り込み・
/// まとめの宿題と会話の突き合わせ・出どころの番号・何日分かの取り込み・週のまとめ・案件・会議の前・数で見る・ウィジェット）を確かめる。
/// 名前はすべて作り物（Aさん・Bさん）。
@MainActor
final class WorkFollowupsTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    private func day(_ d: Int, month: Int = 11, hour: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: hour))!
    }

    private func item(_ what: String, source: TaskBook.Source = .conversation, state: TaskBook.State = .open,
                      from: String? = nil, due: Date? = nil, dueText: String? = nil, quote: String? = nil,
                      kind: TaskBook.Kind? = nil, said: Date? = nil) -> TaskBook.Item {
        TaskBook.Item(what: what, from: from, dueText: dueText, due: due, said: said ?? day(5, hour: 10), quote: quote,
                      source: source, state: state, work: true, kind: kind)
    }

    // MARK: - タスク

    func testHasDueCue() {
        for text in ["明日までに資料を送る", "11/12に提出する", "15時に電話する", "金曜に会議室を取る", "来週の頭に返事をする", "３日に出す"] {
            XCTAssertTrue(TaskBook.hasDueCue(text), text)
        }
        for text in ["資料を見直す", "Aさんに確認する", "見積書を送る"] {
            XCTAssertFalse(TaskBook.hasDueCue(text), text)
        }
    }

    func testExpiredCandidates() {
        let now = day(20, hour: 12)
        var old = item("古い確かめ待ち", state: .candidate, said: day(10, hour: 12))
        old.updated = day(10, hour: 12)
        var touched = item("最近さわった", state: .candidate, said: day(10, hour: 12))
        touched.updated = day(19, hour: 12)
        var open = item("まだのもの", state: .open, said: day(1, hour: 12))
        open.updated = day(1, hour: 12)
        let fresh = item("新しい確かめ待ち", state: .candidate, said: day(18, hour: 12))
        let expired = TaskBook.expired([old, touched, open, fresh], now: now)
        XCTAssertEqual(expired.map(\.what), ["古い確かめ待ち"])
    }

    func testRejectReasons() {
        XCTAssertEqual(TaskBook.RejectReason.choices, [.machine, .finished, .notMine, .topic, .other])
        XCTAssertEqual(TaskBook.RejectReason(rawValue: "machine")?.label, "機械に言ったこと")
        // 理由は文字で持つので、前の記録（理由なし）も、知らない名前も読める
        let saved = #"[{"id":"x","what":"見積書を送る","said":0,"source":"conversation","state":"rejected","updated":0,"rejectReason":"future-reason"}]"#
        let items = try? JSONDecoder().decode([TaskBook.Item].self, from: Data(saved.utf8))
        XCTAssertEqual(items?.first?.rejectReason, "future-reason")
        XCTAssertEqual(TaskScore.reasonLabel("future-reason"), "理由なし（前のもの）")
    }

    func testWorthNotice() {
        XCTAssertFalse(Pipeline.worthNotice([]))
        XCTAssertFalse(Pipeline.worthNotice([item("資料を見る")]))
        XCTAssertFalse(Pipeline.worthNotice([item("資料を見る", dueText: "")]))
        XCTAssertTrue(Pipeline.worthNotice([item("資料を見る"), item("見積書を送る", from: "Aさん")]))
        XCTAssertTrue(Pipeline.worthNotice([item("見積書を送る", dueText: "来週まで")]))
        XCTAssertTrue(Pipeline.worthNotice([item("見積書を送る", due: day(12))]))
        XCTAssertTrue(Pipeline.worthNotice([item("★を付けたところ", source: .mark)]))
        XCTAssertTrue(Pipeline.worthNotice([item("議事録の宿題", source: .minutes)]))
    }

    func testDueHourNotices() throws {
        let now = day(10, hour: 9)
        var later = item("資料を送る", from: "Aさん", due: day(10), kind: .asked)
        later.dueTime = 15 * 60
        var soon = item("もう過ぎる", due: day(10))
        soon.dueTime = 9 * 60 + 30
        let noTime = item("時刻の無いもの", due: day(10))
        var waiting = item("頼んだもの", from: "Bさん", due: day(10), kind: .delegated)
        waiting.dueTime = 16 * 60
        var far = item("遠いもの", due: day(25))
        far.dueTime = 12 * 60
        let notices = Pipeline.dueHourNotices([later, soon, noTime, waiting, far], now: now)
        XCTAssertEqual(notices.map { $0.item.what }, ["資料を送る"])
        XCTAssertEqual(try XCTUnwrap(notices.first).at, day(10, hour: 14))
        let body = Pipeline.dueHourBody(later)
        XCTAssertTrue(body.hasPrefix("・資料を送る（Aさんから）\n"), body)
        XCTAssertTrue(body.hasSuffix(" まで"), body)
    }

    func testNoticeActions() {
        XCTAssertEqual(NoticeActions.action(for: UNNotificationDefaultActionIdentifier), .open)
        XCTAssertEqual(NoticeActions.action(for: "keep"), .keep)
        XCTAssertEqual(NoticeActions.action(for: "tomorrow"), .tomorrow)
        XCTAssertNil(NoticeActions.action(for: "知らないボタン"))
        let categories = NoticeActions.categories()
        XCTAssertEqual(categories.count, 3)
        let found = categories.first { $0.identifier == NoticeActions.foundCategory }
        XCTAssertEqual(found?.actions.map(\.identifier), ["keep", "reject", "later"])
        let due = categories.first { $0.identifier == NoticeActions.dueCategory }
        XCTAssertEqual(due?.actions.map(\.identifier), ["done", "hour", "tomorrow"])
        // 期限の1時間前の知らせは、朝夕の知らせと同じ頭（頼み直すときに消える）で、開いているあいだも出す
        XCTAssertTrue(NoticeActions.duePrefix.hasPrefix("tasks-"))
        XCTAssertTrue(NoticePresenter.options(for: NoticeActions.duePrefix + "abc").contains(.banner))
    }

    func testDigestDayAndOrigin() {
        let digest = item("見積書を送る", source: .summary, quote: "仕事のまとめ（2026-11-10）の宿題: 見積書を送る")
        XCTAssertEqual(digest.digestDay, "2026-11-10")
        XCTAssertEqual(digest.originLabel, "仕事のまとめから（チャットで来た頼み）")
        let summary = item("資料を見る", source: .summary, quote: "1日のまとめ（2026-11-10）のやること")
        XCTAssertNil(summary.digestDay)
        XCTAssertEqual(summary.originLabel, "1日のまとめから")
        let talk = item("見積書を送る", source: .conversation, quote: "仕事のまとめ（2026-11-10）の宿題: 見積書を送る")
        XCTAssertNil(talk.digestDay)
        XCTAssertEqual(talk.originLabel, "会話から")
    }

    func testDigestMatchesConversationTasks() {
        let fromDigest = item("見積書を送る", source: .summary, quote: "仕事のまとめ（2026-11-09）の宿題: 見積書を送る")
        let talk = item("見積書を送る", source: .conversation, state: .candidate)
        let other = item("議事録をまとめる", source: .conversation)
        let homework = Pipeline.workDigestTasks(["見積書を送る（Aさんから／11/12まで）", "会議室を取る", "見積書を送る"],
                                                day: "2026-11-10", now: day(10, hour: 20))
        let matches = Pipeline.digestMatches(homework, in: [fromDigest, other, talk])
        // まとめから入ったものとは突き合わせず、同じものは1回だけ
        XCTAssertEqual(matches.map { $0.index }, [0])
        XCTAssertEqual(matches.map { $0.id }, [talk.id])
    }

    func testTaskScoreRows() {
        var a = item("a", source: .conversation, state: .rejected)
        a.rejectReason = TaskBook.RejectReason.machine.rawValue
        let b = item("b", source: .conversation, state: .done)
        let c = item("c", source: .conversation, state: .rejected)
        let d = item("d", source: .summary, state: .candidate, quote: "1日のまとめ（2026-11-05）のやること")
        let e = item("e", source: .summary, state: .open, quote: "仕事のまとめ（2026-11-05）の宿題: e")
        let rows = TaskScore.rows([d, a, b, c, e])
        XCTAssertEqual(rows.map(\.title), ["会話から", "1日のまとめから", "仕事のまとめから（チャットで来た頼み）"])
        let talk = rows[0]
        XCTAssertEqual(talk.total, 3)
        XCTAssertEqual(talk.kept, 1)
        XCTAssertEqual(talk.rejected, 2)
        XCTAssertEqual(talk.keptPercent, 33)
        XCTAssertEqual(talk.reasons, ["machine": 1, "none": 1])
        XCTAssertNil(rows[1].keptPercent)
        XCTAssertEqual(rows[1].waiting, 1)
        // 拾った時刻で絞る
        XCTAssertTrue(TaskScore.rows([a], since: day(6)).isEmpty)
    }

    func testWidgetTaskTitles() {
        let now = day(10, hour: 12)
        let late = item("過ぎたもの", due: day(9))
        let today = item("今日のもの", due: day(10))
        var urgent = item("急ぎのもの", due: day(10))
        urgent.urgent = true
        let later = item("あとのもの", due: day(20))
        XCTAssertEqual(WidgetBridge.taskTitles([late, today, urgent, later], now: now, calendar: cal),
                       ["急ぎのもの", "過ぎたもの", "今日のもの"])
        // 今日までのものが無ければ、期限の近いもの
        XCTAssertEqual(WidgetBridge.taskTitles([later], now: now, calendar: cal), ["あとのもの"])
        // 古いウィジェットの中身（項目なし）も読める
        let old = #"{"updated":0}"#
        let state = try? JSONDecoder().decode(WidgetState.self, from: Data(old.utf8))
        XCTAssertNotNil(state)
        XCTAssertNil(state?.taskTitles)
        XCTAssertNil(state?.tasksChecking)
    }

    // MARK: - 仕事のまとめ

    func testSourceTags() {
        XCTAssertEqual(WorkDigestParser.sourceTags("見積書を送る（Aさんから／11/12まで）［1］").text, "見積書を送る（Aさんから／11/12まで）")
        XCTAssertEqual(WorkDigestParser.sourceTags("見積書を送る（Aさんから／11/12まで）［1］").tags, [1])
        XCTAssertEqual(WorkDigestParser.sourceTags("A案にする［1・2］").tags, [1, 2])
        XCTAssertEqual(WorkDigestParser.sourceTags("A案にする [2]").text, "A案にする")
        XCTAssertEqual(WorkDigestParser.sourceTags("A案にする［１］").tags, [1])
        XCTAssertEqual(WorkDigestParser.sourceTags("A案にする［1］［2］").tags, [1, 2])
        XCTAssertEqual(WorkDigestParser.sourceTags("資料を直す（11/10まで）").text, "資料を直す（11/10まで）")
        XCTAssertEqual(WorkDigestParser.sourceTags("資料を直す（11/10まで）").tags, [])
        XCTAssertEqual(WorkDigestParser.sourceTags("第1版を出す").tags, [])
        // 宿題の頼んだ人・期限は、番号を外してから読む
        let tasks = Pipeline.workDigestTasks(["見積書を送る（Aさんから／11/12まで）［1］"], day: "2026-11-10", now: day(10, hour: 20))
        XCTAssertEqual(tasks.map(\.what), ["見積書を送る"])
        XCTAssertEqual(tasks.first?.from, "Aさん")
    }

    func testSourceNumbers() {
        let a = WorkDigestParser.sourceNumber("［1］チーム＞チャネル「週の予定」（いた人：Aさん、Bさん）")
        XCTAssertEqual(a?.number, 1)
        XCTAssertEqual(a?.name, "チーム＞チャネル「週の予定」")
        XCTAssertEqual(WorkDigestParser.sourceNumber("[2] チャット「グループ」")?.name, "チャット「グループ」")
        XCTAssertNil(WorkDigestParser.sourceNumber("チャット「グループ」"))
        XCTAssertEqual(WorkDigestParser.sourceMap(["［1］チーム＞チャネル（いた人：Aさん）", "［2］チャット「グループ」", "番号なし"]),
                       [1: "チーム＞チャネル", 2: "チャット「グループ」"])
    }

    private let tagged = """
        【日付】2026-11-10
        【出どころ】
        ・［1］チーム＞チャネル「週の予定」（いた人：Aさん）
        ・［2］チャット「グループ」
        【決まったこと】
        ・A案にする［1］
        【自分の宿題】
        ・見積書を送る（Aさんから／11/12まで）［2］
        """

    func testDigestLinesShowSources() throws {
        let parsed = WorkDigestParser.parse(tagged, today: day(10, hour: 20))
        XCTAssertTrue(parsed.found)
        let entry = WorkDigest.Entry(id: "t", day: "2026-11-10", text: tagged, sections: parsed.sections, source: .paste,
                                     addedAt: day(10, hour: 20))
        let lines = Pipeline.workDigestLines(entry)
        let decided = try XCTUnwrap(lines.first { $0.heading == "決まったこと" })
        XCTAssertEqual(decided.text, "A案にする")
        XCTAssertEqual(decided.source, "チーム＞チャネル「週の予定」")
        let homework = try XCTUnwrap(lines.first { $0.heading == "自分の宿題" })
        XCTAssertEqual(homework.text, "見積書を送る（Aさんから／11/12まで）")
        XCTAssertEqual(homework.source, "チャット「グループ」")
        // 出どころの行は、そのまま
        XCTAssertTrue(lines.contains { $0.heading == "出どころ" && $0.text.hasPrefix("［1］") })
        // 出どころの名前でも探せる
        XCTAssertEqual(Pipeline.searchWorkDigests("グループ", in: [entry]).map(\.text).first, "［2］チャット「グループ」")
        XCTAssertEqual(Pipeline.searchWorkDigests("グループ 見積", in: [entry]).map(\.source), ["チャット「グループ」"])
        // 質問の材料には、出どころの名前を添える
        let material = Pipeline.workDigestMaterial([entry], keywords: ["A案"], people: [], from: "2026-11-10", to: "2026-11-10",
                                                   anyDay: false, budget: 1000)
        XCTAssertTrue(material.text.contains("・A案にする（出どころ: チーム＞チャネル「週の予定」）\n"), material.text)
        XCTAssertEqual(material.lines.map { $0.text }, ["A案にする"])
    }

    func testMaterialWithNearLines() {
        let entry = WorkDigest.Entry(id: "n", day: "2026-11-10", text: tagged,
                                     sections: WorkDigestParser.parse(tagged, today: day(10, hour: 20)).sections,
                                     source: .paste, addedAt: day(10, hour: 20))
        let near: Set<String> = ["2026-11-10|" + WorkDigestParser.compact("A案にする")]
        // 手がかりの言葉が無くても、意味の近かった行は入る（期間を言わない質問でも）
        let any = Pipeline.workDigestMaterial([entry], keywords: [], people: [], from: "2026-11-01", to: "2026-11-05",
                                              anyDay: true, budget: 1000, near: near)
        XCTAssertEqual(any.lines.map { $0.text }, ["A案にする"])
        XCTAssertEqual(any.days, ["2026-11-10"])
        // 近い行も手がかりも無く、期間を言わない質問には入れない（前と同じ）
        let none = Pipeline.workDigestMaterial([entry], keywords: [], people: [], from: "2026-11-01", to: "2026-11-05",
                                               anyDay: true, budget: 1000)
        XCTAssertEqual(none.text, "")
    }

    func testDigestLinesUsed() {
        let lines: [(day: String, heading: String, text: String)] = [
            ("2026-11-10", "決まったこと", "見積もりは2案で出す"),
            ("2026-11-10", "自分の宿題", "会議室を取る"),
        ]
        let used = Pipeline.digestLinesUsed(answer: "まとめによると、見積もりは2案で出すことに決まりました。", lines: lines)
        XCTAssertEqual(used.map { $0.text }, ["見積もりは2案で出す"])
        XCTAssertTrue(Pipeline.digestLinesUsed(answer: "", lines: lines).isEmpty)
    }

    func testSplitDays() {
        let two = "【日付】2026-11-08\n【決まったこと】\n・A案にする\n【日付】2026-11-09\n【決まったこと】\n・B案にする"
        let days = WorkDigestParser.splitDays(two, today: day(10, hour: 12))
        XCTAssertEqual(days.map { $0.day }, ["2026-11-08", "2026-11-09"])
        XCTAssertTrue(days[0].text.contains("A案"))
        XCTAssertFalse(days[0].text.contains("B案"))
        XCTAssertTrue(days[1].text.hasPrefix("【日付】2026-11-09"))
        // 【日付】が1つ・同じ日が2つなら分けない
        XCTAssertTrue(WorkDigestParser.splitDays("【日付】2026-11-08\n・A案にする", today: day(10, hour: 12)).isEmpty)
        XCTAssertTrue(WorkDigestParser.splitDays("【日付】2026-11-08\n・A\n【日付】2026-11-08\n・B", today: day(10, hour: 12)).isEmpty)
    }

    func testPromptHasTodayAndFormat() {
        let prompt = WorkDigestPrompt.full(day: "2026-11-10")
        XCTAssertTrue(prompt.contains("【日付】2026-11-10"))
        for heading in ["【出どころ】", "【決まったこと】", "【自分の宿題】", "【ほかの人の動き】", "【気になる話題】", "【あとで確かめること】", "【よく出た言葉】"] {
            XCTAssertTrue(prompt.contains(heading), heading)
        }
        // 頼み方の見本の形そのものも、アプリで読める
        let parsed = WorkDigestParser.parse(prompt, today: day(10, hour: 12))
        XCTAssertTrue(parsed.found)
        XCTAssertTrue(WorkDigestPrompt.fix(day: "2026-11-10").hasSuffix(prompt))
    }

    // MARK: - 週・案件・人

    func testWeekStart() {
        // 2026-11-10 は火曜。週は月曜から
        XCTAssertEqual(Pipeline.weekStart(day(10, hour: 15), calendar: cal), day(9))
        XCTAssertEqual(Pipeline.weekStart(day(9, hour: 1), calendar: cal), day(9))
        XCTAssertEqual(Pipeline.weekStart(day(15, hour: 23), calendar: cal), day(9))
    }

    func testDigestPerson() {
        XCTAssertEqual(Pipeline.digestPerson("Aさん: 客先に電話した")?.person, "Aさん")
        XCTAssertEqual(Pipeline.digestPerson("Bさん：資料を直した")?.text, "資料を直した")
        XCTAssertNil(Pipeline.digestPerson("名前の無い行"))
        XCTAssertNil(Pipeline.digestPerson("Aさん:"))
    }

    private func digest(_ dayText: String, _ text: String) -> WorkDigest.Entry {
        let at = TaskBook.dayFormat.date(from: dayText)?.addingTimeInterval(20 * 3600) ?? .now
        return WorkDigest.Entry(id: dayText, day: dayText, text: text, sections: WorkDigestParser.parse(text, today: at).sections,
                                source: .paste, addedAt: at)
    }

    func testWorkWeek() {
        let mon = digest("2026-11-09", "【決まったこと】\n・A案にする\n【ほかの人の動き】\n・Aさん: 客先に電話した\n・会議室が埋まっていた\n【あとで確かめること】\n・予算")
        let tue = digest("2026-11-10", "【決まったこと】\n・A案にする\n・見積もりは来週\n【ほかの人の動き】\n・Aさん: 資料を直した\n・Bさん: 休み")
        let before = digest("2026-11-06", "【決まったこと】\n・前の週のこと")
        var done = item("見積書を送る")
        done.state = .done
        let doneAt = TaskBook.dayFormat.date(from: "2026-11-10")?.addingTimeInterval(12 * 3600)
        done.doneAt = doneAt
        let open = item("議事録をまとめる")
        let date = TaskBook.dayFormat.date(from: "2026-11-11")?.addingTimeInterval(12 * 3600) ?? .now
        let week = Pipeline.workWeek([tue, mon, before], tasks: [done, open], weekOf: date)
        XCTAssertEqual(week.start, "2026-11-09")
        XCTAssertEqual(week.end, "2026-11-15")
        XCTAssertEqual(week.days, ["2026-11-09", "2026-11-10"])
        // 同じ決まったことは1つ
        XCTAssertEqual(week.decided.map { $0.text }, ["A案にする", "見積もりは来週"])
        XCTAssertEqual(week.others.map { $0.person }, ["Aさん", "Bさん", "そのほか"])
        XCTAssertEqual(week.others.first?.lines, ["客先に電話した", "資料を直した"])
        XCTAssertEqual(week.checks, ["予算"])
        XCTAssertEqual(week.done.map(\.what), ["見積書を送る"])
        XCTAssertEqual(week.open.map(\.what), ["議事録をまとめる"])
        let text = Pipeline.workWeekText(week)
        XCTAssertTrue(text.contains("【決まったこと】\n・A案にする\n・見積もりは来週"), text)
        XCTAssertTrue(text.contains("【人ごとの動き】\nAさん\n・客先に電話した"), text)
        XCTAssertFalse(text.contains("前の週のこと"))
    }

    func testWorkThreads() {
        let a = digest("2026-11-08", "【決まったこと】\n・新システムの日程を決めた\n・見積は2案\n【よく出た言葉】\n・新システム\n・見積")
        let b = digest("2026-11-10", "【あとで確かめること】\n・新システムの予算\n【よく出た言葉】\n・新システム")
        let c = digest("2026-11-09", "【決まったこと】\n・見積は来週\n【よく出た言葉】\n・見積")
        let threads = Pipeline.workThreads([b, c, a], now: day(10, hour: 21))
        XCTAssertEqual(threads.map(\.word), ["新システム", "見積"])
        XCTAssertEqual(threads.first?.days, ["2026-11-08", "2026-11-10"])
        let lines = Pipeline.workThreadLines("新システム", in: [b, c, a])
        XCTAssertEqual(lines.map(\.text), ["新システムの日程を決めた", "新システムの予算"])
    }

    func testPersonDigestLinesAndMeetingPrep() {
        // 名前の手がかりは「さん」を除いて2文字から（作り物の名前）
        let a = digest("2026-11-10", "【ほかの人の動き】\n・エーさん: 資料を直した\n【出どころ】\n・チャット（いた人：エーさん）\n【決まったこと】\n・A案にする")
        let lines = Pipeline.digestLines(about: "エーさん", in: [a])
        XCTAssertEqual(lines.map(\.text), ["エーさん: 資料を直した"])
        XCTAssertTrue(Pipeline.digestLines(about: "Aさん", in: [a]).isEmpty)
        let asked = item("見積書を送る", from: "エーさん")
        let other = item("議事録をまとめる", from: "ビーさん")
        let prep = Pipeline.meetingPrep(name: "エーさん", tasks: [asked, other], digests: [a])
        XCTAssertEqual(prep.tasks.map(\.what), ["見積書を送る"])
        XCTAssertEqual(prep.lines.count, 1)
    }
}

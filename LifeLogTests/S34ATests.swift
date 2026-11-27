import XCTest
@testable import LifeLog

/// s34 のアプリ担当 S34A（S34ARules.swift・2026-11-27）: K34-1 の読み（無い・壊れ・1 つの鍵が壊れていてもほかは読む）・
/// 自動で直した数の行（数だけ）・テストの進みの 1 行・頼み方の選び方・会議の前の 1 枚の並び・次の一手の並び・
/// 円1 写真の見分け（見出しの数・頼み方そのものは外す・続けて撮った写真をつなぐ・重なりを 1 回に・日の決め方・次の回へ回す）・どこ？。
/// 見本の名前・会社・数はどれも作りもの（実在の人・会社・案件ではない）。
@MainActor
final class S34ATests: XCTestCase {
    private func feed(_ json: String) -> S34AFeed? {
        if case .feed(let f) = S34ARules.reply(Data(json.utf8)) { return f }
        return nil
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return c
    }

    // MARK: - K34-1 の読み

    func testReplyNoneBadAndEmpty() {
        XCTAssertEqual(S34ARules.reply(Data(#"{"available":false}"#.utf8)), .none)
        XCTAssertEqual(S34ARules.reply(Data("こわれた".utf8)), .bad)
        XCTAssertEqual(S34ARules.reply(Data("[1,2]".utf8)), .bad)
        let empty = feed("{}")
        XCTAssertNotNil(empty)
        XCTAssertEqual(empty?.hasFixed, false)
        XCTAssertNil(S34ARules.testsLine(empty?.tests))
    }

    func testReplyReadsAllKeys() {
        let f = feed("""
        {"self_fixed":{"week":"2026-11-23","speaker":{"fixed":"41","left":9,"undone":2},"reopened":{"solved":57,"left":120},
                       "vocab":{"adopted":6,"dropped":1},"work":{"solved":18,"left":12},"place":{"before":0,"after":0.5,"why":"見本"}},
         "auto_switch":[{"name":"a","state":"on"},{"name":"b","state":"shadow"},{"name":"c","state":"rolled_back"},{"name":"d","state":"on"}],
         "tuned":[{"name":"x","old":2,"new":3,"range":[1,5]},{"name":"y","old":"14","new":"14","range":"7-21"},{"name":"z","old":true,"new":false}],
         "reflow":{"days_done":12,"days_left":18,"last_day":"2026-11-15"},
         "guide_run":{"last_ok":"2026-11-23T03:00:00+09:00","by":"subscription","misses_used":3,"rules_added":2},
         "healed":[{"source":"card","ok":true},{"source":"health","ok":false},{"source":"digest","ok":1}],
         "prompt":{"day":"2026-11-27","text":"見本の頼み方","parts":["今日のまとめ",3,"足りない土台"]},
         "nudges":[{"id":"n1","topic":"見本の話","who":"見本 次郎","days":4,"next":"聞く","draft":"下書き"},{"id":"だめな id","topic":"x"}],
         "prep":[{"meeting":"見本の定例","at":"2026-11-28T10:00:00+09:00","last_decided":["決まった"],"my_tasks":[],"likely_asked":["日程"],"self_check":[]},
                 {"meeting":"空の会議","at":"2026-11-28T11:00:00+09:00"}],
         "tests":{"total":300,"done":182,"ng":5,"waiting":11,"today":14,"finish_guess":"2026-12-06"}}
        """)
        guard let f else { return XCTFail("読めない") }
        XCTAssertEqual(f.selfFixed?.speakerFixed, 41, "数は文字でも読む")
        XCTAssertEqual(f.selfFixed?.placeAfter, 0.5)
        XCTAssertEqual(f.autoSwitch.count, 4)
        XCTAssertEqual(f.tuned.map { $0.old?.text }, ["2", "14", "はい"])
        XCTAssertEqual(f.tuned.filter(\.moved).count, 2, "同じ値は合わせ直していない")
        XCTAssertEqual(f.reflow?.daysLeft, 18)
        XCTAssertEqual(f.guideRun?.by, "subscription")
        XCTAssertEqual(f.healed.filter { $0.ok == true }.count, 2, "ok は数でも読む")
        XCTAssertEqual(f.prompt?.parts, ["今日のまとめ", "足りない土台"], "文字でない部分は飛ばす")
        XCTAssertEqual(f.nudges.map(\.id), ["n1"], "id の形でないものは出さない")
        XCTAssertEqual(f.prep.map(\.meeting), ["見本の定例"], "中身の無い会議は出さない")
        XCTAssertEqual(f.tests?.done, 182)
        XCTAssertTrue(f.hasFixed)
    }

    func testOneBrokenKeyKeepsOthers() {
        let f = feed("""
        {"self_fixed":"こわれた","auto_switch":{"name":"x"},"tests":{"total":10,"done":"4"},"nudges":[{"id":"n1","topic":"見本"},{"topic":"id なし"}],
         "prompt":{"text":"   "},"reflow":{"days_done":-3}}
        """)
        guard let f else { return XCTFail("読めない") }
        XCTAssertNil(f.selfFixed)
        XCTAssertTrue(f.autoSwitch.isEmpty)
        XCTAssertEqual(f.tests?.done, 4)
        XCTAssertEqual(f.nudges.count, 1)
        XCTAssertNil(f.prompt, "空の文は無いのと同じ")
        XCTAssertNil(f.reflow?.daysDone, "負の数は読まない")
    }

    // MARK: - 自動で直した数（数だけ）

    func testFixedLinesNumbersOnly() {
        var f = S34AFeed()
        var s = S34ASelfFixed()
        s.week = "2026-11-23"
        s.speakerFixed = 41
        s.speakerLeft = 9
        s.vocabAdopted = 6
        s.placeBefore = 0
        s.placeAfter = 0.5
        f.selfFixed = s
        f.autoSwitch = [S34ASwitch(name: "a", state: "on"), S34ASwitch(name: "b", state: "rolled_back")]
        f.tuned = [S34ATuned(name: "x", old: S34AValue("2"), new: S34AValue("3"))]
        f.reflow = S34AReflow(daysDone: 12, daysLeft: 18, lastDay: "2026-11-15")
        f.guideRun = S34AGuideRun(lastOK: nil, by: nil, missesUsed: 0, rulesAdded: 0)
        f.healed = [S34AHealed(source: "card", ok: true), S34AHealed(source: "x", ok: nil)]
        let lines = S34ARules.fixedLines(f)
        let byTitle: [String: String] = Dictionary(uniqueKeysWithValues: lines.map { ($0.title, $0.value) })
        XCTAssertEqual(byTitle["話し手（三つの証拠で）"], "直した 41・残り 9")
        XCTAssertEqual(byTitle["聞き違いの言葉"], "入れた 6")
        XCTAssertEqual(byTitle["場所の当たり"], "0% → 50%")
        XCTAssertEqual(byTitle["影から本番への切り替え"], "本番 1・影 0・戻した 1")
        XCTAssertEqual(byTitle["合わせ直した仮の数"], "1 個")
        XCTAssertEqual(byTitle["過去の日の流し直し（日）"], "済 12・残り 18（最後 11/15）")
        XCTAssertEqual(byTitle["週 1 回の読み直し"], "まだできていない・先週外した例 0・足した決まり 0")
        XCTAssertEqual(byTitle["自分で直した止まり"], "2 回（うまくいった 1）")
        XCTAssertNil(byTitle["仕事の確かめ"], "無い鍵の行は出さない")
        // 41 + 6 + 本番 1 + 動いた 1 + うまくいった 1
        XCTAssertEqual(S34ARules.fixedHeadline(f), "11/23 の週、聞かずに直した・解いた数 50")
        XCTAssertNil(S34ARules.fixedHeadline(S34AFeed()))
    }

    func testGuideAndPlaceText() {
        XCTAssertEqual(S34ARules.guideText(S34AGuideRun(lastOK: "2026-11-23T03:00:00+09:00", by: "app_task")),
                       "11/23 にできた（アプリの予約タスク）")
        XCTAssertEqual(S34ARules.placeText(before: 0, after: 9), "0 → 9", "数のときは数のまま")
        XCTAssertEqual(S34ARules.placeText(before: nil, after: 0.25), "いま 25%")
        XCTAssertNil(S34ARules.placeText(before: nil, after: nil))
    }

    // MARK: - 円5 テストの進み

    func testTestsLine() {
        let t = S34ATestProgress(total: 300, done: 182, ng: 5, waiting: 11, today: 14, finishGuess: "2026-12-06")
        XCTAssertEqual(S34ARules.testsLine(t), "テスト 182/300 済・不可 5・待ち 11・今日 +14")
        XCTAssertEqual(S34ARules.finishLine(t), "このままだと 12/6 ごろに終わる見込み")
        XCTAssertEqual(S34ARules.left(t), 113)
        XCTAssertEqual(S34ARules.testsLine(S34ATestProgress(done: 3)), "テスト 3 済")
        XCTAssertEqual(S34ARules.testsLine(S34ATestProgress(total: 10, ng: 0)), "テスト 全 10", "0 件の不可は書かない")
        XCTAssertNil(S34ARules.testsLine(S34ATestProgress()))
        XCTAssertNil(S34ARules.finishLine(S34ATestProgress(total: 1)))
    }

    // MARK: - 円2 頼み方

    func testPromptPick() {
        let now = date("2026-11-27T08:00:00+09:00")
        let p = S34APromptFeed(day: "2026-11-27", text: "見本の頼み方\n")
        XCTAssertEqual(S34APrompt.pick(p, day: "2026-11-27", fetchedAt: nil, now: now), "見本の頼み方")
        XCTAssertNil(S34APrompt.pick(p, day: "2026-11-28", fetchedAt: now, now: now), "違う日の文は使わない")
        let noDay = S34APromptFeed(day: nil, text: "日の無い文")
        XCTAssertEqual(S34APrompt.pick(noDay, day: "2026-11-27", fetchedAt: now.addingTimeInterval(-3600), now: now), "日の無い文")
        XCTAssertNil(S34APrompt.pick(noDay, day: "2026-11-27", fetchedAt: now.addingTimeInterval(-90000), now: now), "古い写しは使わない")
        XCTAssertNil(S34APrompt.pick(noDay, day: "2026-11-27", fetchedAt: nil, now: now))
        XCTAssertNil(S34APrompt.pick(nil, day: "2026-11-27", fetchedAt: now, now: now))
    }

    // MARK: - 円4 会議の前の 1 枚

    func testPrepUpcomingOrderAndWindow() {
        let now = date("2026-11-27T21:00:00+09:00")
        let list = [
            S34APrep(meeting: "あさって", at: "2026-11-29T15:00:00+09:00", likelyAsked: ["x"]),
            S34APrep(meeting: "明日の午後", at: "2026-11-28T15:00:00+09:00", likelyAsked: ["x"]),
            S34APrep(meeting: "時刻なし", at: "そのうち", likelyAsked: ["x"]),
            S34APrep(meeting: "明日の朝", at: "2026-11-28T10:00:00+09:00", likelyAsked: ["x"]),
            S34APrep(meeting: "きのう", at: "2026-11-26T10:00:00+09:00", likelyAsked: ["x"]),
        ]
        XCTAssertEqual(S34APrepRules.upcoming(list, now: now).map(\.meeting), ["明日の朝", "明日の午後", "時刻なし"])
        XCTAssertEqual(S34APrepRules.whenText("2026-11-28T10:00:00+09:00", now: now, calendar: tokyo), "明日 10:00")
        XCTAssertEqual(S34APrepRules.whenText("2026-11-27T22:30:00+09:00", now: now, calendar: tokyo), "今日 22:30")
        XCTAssertEqual(S34APrepRules.whenText("そのうち", now: now, calendar: tokyo), "そのうち")
        XCTAssertNil(S34APrepRules.whenText(nil, now: now))
    }

    // MARK: - 円3 次の一手

    func testNudgeSortAndMeta() {
        var list: [S34ANudge] = []
        for i in 0..<7 { list.append(S34ANudge(id: "n\(i)", topic: "見本 \(i)", days: i % 3)) }
        list.append(S34ANudge(id: "nx", topic: "日数なし"))
        let s = S34ANudgeRules.sorted(list)
        XCTAssertEqual(s.count, S34ANudgeRules.limit)
        XCTAssertEqual(s.map(\.id), ["n2", "n5", "n1", "n4", "n0"], "長く止まっているものから・同じなら届いた順")
        XCTAssertEqual(S34ANudgeRules.meta(S34ANudge(id: "a", topic: "t", who: "見本 次郎", days: 4)), "見本 次郎・4 日止まっている")
        XCTAssertNil(S34ANudgeRules.meta(S34ANudge(id: "a", topic: "t")))
    }

    // MARK: - 円1 写真の見分け

    private let digest1 = """
    【日付】2026-11-27
    【決まったこと】
    ・見本の画面は来週から試す（10:00 見本）［1］
    【自分の宿題】
    ・見本の項目一覧を直す（見本 次郎から／11/28まで）
    """

    func testStrictHeaderNeedsBracket() {
        XCTAssertEqual(S34APhotoRules.strictHeader("【決まったこと】"), .decided)
        XCTAssertEqual(S34APhotoRules.strictHeader("［自分の宿題］"), .homework, "【 が ［ に読まれても見出し")
        XCTAssertEqual(S34APhotoRules.strictHeader("【 会 議 】"), .meetings, "読み取りの空白は除く")
        XCTAssertNil(S34APhotoRules.strictHeader("決まったこと：見本は来週"), "かっこの無い行は見出しにしない")
        XCTAssertNil(S34APhotoRules.strictHeader("・見本の会議に出た"))
    }

    func testLooksLikeDigest() {
        XCTAssertTrue(S34APhotoRules.looksLikeDigest(S34APhotoRules.heads(digest1)))
        XCTAssertTrue(S34APhotoRules.looksLikeDigest([.date, .meetings]), "日付と見出し 1 つ")
        XCTAssertTrue(S34APhotoRules.looksLikeDigest([.decided, .checks]), "日付が写っていなくても見出し 2 つ")
        XCTAssertFalse(S34APhotoRules.looksLikeDigest([.decided]))
        XCTAssertFalse(S34APhotoRules.looksLikeDigest([.date]))
        XCTAssertFalse(S34APhotoRules.looksLikeDigest(S34APhotoRules.heads("見本のレシート\n合計 1,200 円\n決まったこと: なし")))
    }

    func testPromptPhotoIsNotDigest() {
        // 頼み方そのものを撮った写真は拾わない
        let prompt = WorkDigestPrompt.full(day: "2026-11-27")
        XCTAssertTrue(S34APhotoRules.dropPrompt(prompt).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let shots = [S34AShot(id: "p", at: date("2026-11-27T18:00:00+09:00"), text: prompt)]
        XCTAssertTrue(S34APhotoRules.groups(shots).isEmpty)
        // 頼みと答えが 1 枚に写っているときは、答えだけ
        let both = prompt + "\n" + digest1
        let body = S34APhotoRules.dropPrompt(both)
        XCTAssertTrue(body.hasPrefix("【日付】2026-11-27"))
        XCTAssertFalse(body.contains("答えてください"))
        XCTAssertEqual(S34APhotoRules.groups([S34AShot(id: "b", at: date("2026-11-27T18:00:00+09:00"), text: both)]).count, 1)
    }

    func testGroupsJoinAndDiscard() {
        let t0 = date("2026-11-27T18:00:00+09:00")
        let next = """
        ・見本の項目一覧を直す（見本 次郎から／11/28まで）
        ・見本の数を確かめる
        【あとで確かめること】
        ・見本の日程
        """
        let shots = [
            S34AShot(id: "food", at: t0.addingTimeInterval(-600), text: "見本の定食\n890 円"),
            S34AShot(id: "a", at: t0, text: digest1),
            S34AShot(id: "b", at: t0.addingTimeInterval(40), text: next),
            S34AShot(id: "c", at: t0.addingTimeInterval(70), text: "・見本の続きの行\n・もう 1 行"),
            S34AShot(id: "late", at: t0.addingTimeInterval(3600), text: "【決まったこと】\n・1 つだけの見出し"),
            S34AShot(id: "sky", at: t0.addingTimeInterval(7200), text: ""),
        ]
        let groups = S34APhotoRules.groups(shots)
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["a", "b", "c"]], "見出しの 1 つしか無い組・ほかの写真は捨てる")
        let text = S34APhotoRules.text(of: groups[0])
        XCTAssertEqual(text.components(separatedBy: "見本の項目一覧を直す").count - 1, 1, "重なった行は 1 回だけ")
        XCTAssertTrue(text.contains("【あとで確かめること】"))
        XCTAssertTrue(text.hasSuffix("・もう 1 行"))
        let parsed = WorkDigestParser.parse(text)
        XCTAssertEqual(parsed.day, "2026-11-27")
        XCTAssertEqual(parsed.sections.homework.count, 2)
        // 見出しの無い続きの写真（c）は、前の見出し（あとで確かめること）の続きとして読まれる
        XCTAssertEqual(parsed.sections.checks.first, "見本の日程")
        XCTAssertEqual(parsed.sections.checks.count, 3)
    }

    func testGroupsSplitByGapAndPlainPhoto() {
        let t0 = date("2026-11-27T18:00:00+09:00")
        let shots = [
            S34AShot(id: "a", at: t0, text: digest1),
            // 3 分より後の続きは別の組（見出しが 1 つだけなので捨てる）
            S34AShot(id: "b", at: t0.addingTimeInterval(400), text: "【気になる話題】\n・見本"),
            // 見出しも箇条書きも無い写真は、間が短くても入れない
            S34AShot(id: "c", at: t0.addingTimeInterval(30), text: "見本の看板"),
        ]
        XCTAssertEqual(S34APhotoRules.groups(shots).map { $0.map(\.id) }, [["a"]])
    }

    func testJoinOverlap() {
        XCTAssertEqual(S34APhotoRules.join(["a\nb\nc", "b\nc\nd", "d\ne"]), "a\nb\nc\nd\ne")
        XCTAssertEqual(S34APhotoRules.join(["a\n\nb ", " c"]), "a\nb\nc", "空の行と前後の空白を除く")
        XCTAssertEqual(S34APhotoRules.overlap(["x", "y"], ["x y"]), 0)
        XCTAssertEqual(S34APhotoRules.overlap(["見本 の 行"], ["見本の行", "次"]), 1, "空白を除いて比べる")
    }

    func testDaysFromDigest() {
        let taken = date("2026-11-27T18:00:00+09:00")
        XCTAssertEqual(S34APhotoRules.days(digest1, takenAt: taken, calendar: tokyo).map(\.day), ["2026-11-27"])
        let noDate = "【決まったこと】\n・見本\n【自分の宿題】\n・見本"
        XCTAssertEqual(S34APhotoRules.days(noDate, takenAt: taken, calendar: tokyo).map(\.day), ["2026-11-27"], "日付が無ければ撮った日")
        let two = digest1 + "\n【日付】2026-11-26\n【決まったこと】\n・前の日の見本"
        XCTAssertEqual(S34APhotoRules.days(two, takenAt: taken, calendar: tokyo).map(\.day), ["2026-11-27", "2026-11-26"])
        XCTAssertTrue(S34APhotoRules.days("  \n ", takenAt: taken).isEmpty)
    }

    func testSinceHeldAndRemembered() {
        let now = date("2026-11-27T18:00:00+09:00")
        XCTAssertEqual(S34APhotoRules.since(last: nil, onAt: nil, now: now), now.addingTimeInterval(-3 * 86400), "3 日まで")
        XCTAssertEqual(S34APhotoRules.since(last: nil, onAt: now.addingTimeInterval(-3600), now: now), now.addingTimeInterval(-3600 - 86400),
                       "スイッチを入れた 1 日前から")
        let last = now.addingTimeInterval(-600)
        XCTAssertEqual(S34APhotoRules.since(last: last, onAt: now.addingTimeInterval(-3600), now: now), last)

        let t0 = now.addingTimeInterval(-3000)
        let shots = [S34AShot(id: "a", at: t0, text: ""), S34AShot(id: "b", at: t0.addingTimeInterval(900), text: ""),
                     S34AShot(id: "c", at: t0.addingTimeInterval(960), text: "")]
        let held = S34APhotoRules.held(shots, full: true)
        XCTAssertEqual(held.now.map(\.id), ["a"])
        XCTAssertEqual(held.later.map(\.id), ["b", "c"], "上限まで読んだときは、終わりの組を次の回へ")
        XCTAssertEqual(S34APhotoRules.held(shots, full: false).later, [])
        let oneGroup = [S34AShot(id: "a", at: t0, text: ""), S34AShot(id: "b", at: t0.addingTimeInterval(60), text: "")]
        XCTAssertEqual(S34APhotoRules.held(oneGroup, full: true).now.count, 2, "全部が 1 つの組なら回さない")

        XCTAssertEqual(S34APhotoRules.remembered(["a", "b"], adding: ["b", "c"], limit: 2), ["b", "c"])
    }

    // MARK: - どこ？

    func testWhereEntries() {
        let ids = S33AWhere.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "id が重なっている")
        for e in S34AWhere.entries {
            XCTAssertTrue(ids.contains(e.id))
            XCTAssertTrue(S33ARules.isName(e.id), "英字の名前でない: \(e.id)")
            XCTAssertTrue(S33AWhere.places.contains(e.place))
            XCTAssertFalse(e.aliases.isEmpty)
        }
        XCTAssertEqual(S33AWhere.search("自動で直した数").first?.id, "s34Fixed")
        XCTAssertEqual(S33AWhere.search("写真 仕事").first?.id, "s34WorkPhoto")
        XCTAssertTrue(S33AWhere.search("テスト").map(\.id).contains("s34Tests"))
        XCTAssertTrue(S33AWhere.search("催促").map(\.id).contains("s34Nudges"))
        // s33 の探し方は前のまま
        XCTAssertEqual(S33AWhere.search("仕事 頼み方").map(\.id), ["workDigest"])
    }

    // MARK: - 自6・自7 家の PC が集めた声の見本（S34AVoice.swift）

    private func sample(_ audio: String, _ offset: Double, _ length: Double = 4, scene: String? = nil) -> S34AVoiceSample {
        S34AVoiceSample(audio: audio, offset: offset, length: length, scene: scene)
    }

    func testVoicePeopleReadsOnlyAuto() {
        let json = """
        {"available":true,"people":[
          {"speaker":"自分","speakerID":"me","auto":true,"tier":"tentative",
           "samples":[{"day":"2026-11-27","audio":"a1.m4a","offset":"12.5","length":4.2,"path":"/audio-clip?audio=a1.m4a","scene":"home","auto":true},
                      {"audio":"a2.m4a"}]},
          {"speaker":"見本 花子","speakerID":"12","samples":[{"audio":"b.m4a","offset":1,"length":3}]},
          {"speaker":"見本 次郎","speakerID":"13","auto":true,"samples":[{"audio":"c.m4a","offset":2,"length":5}]},
          {"speakerID":"","auto":true,"samples":[]},
          "こわれた行"]}
        """
        let people = S34AVoiceRules.people(Data(json.utf8))
        XCTAssertEqual(people.map(\.speakerID), ["me", "13"], "s34 の自動の人だけ（s18 の候補・id の無い人・壊れた行は外す）")
        XCTAssertEqual(people.first?.samples.count, 1, "offset・length の無い見本は外す")
        XCTAssertEqual(people.first?.samples.first?.offset, 12.5, "数は文字でも読む")
        XCTAssertEqual(people.first?.samples.first?.scene, "home")
        XCTAssertEqual(people.first?.samples.first?.key, "a1.m4a|12.50|4.20")
        XCTAssertTrue(S34AVoiceRules.people(Data(#"{"available":false,"people":[{"speakerID":"me","auto":true,"samples":[]}]}"#.utf8)).isEmpty)
        XCTAssertTrue(S34AVoiceRules.people(Data("こわれた".utf8)).isEmpty)
    }

    func testRecordNeeded() {
        XCTAssertEqual(S34AVoiceRules.recordNeeded(Data(#"{"steps":[],"s34_auto":{"scenes":{"home":2,"work":1,"out":1},"record_needed":false}}"#.utf8)), false)
        XCTAssertEqual(S34AVoiceRules.recordNeeded(Data(#"{"s34_auto":{"record_needed":true}}"#.utf8)), true)
        XCTAssertNil(S34AVoiceRules.recordNeeded(Data(#"{"steps":[]}"#.utf8)), "前の PC（s34_auto が無い）")
        XCTAssertNil(S34AVoiceRules.recordNeeded(Data("x".utf8)))
        // 札を出さなくするのは、record_needed が false で、端末に自分の自動の見本が 3 個以上あるときだけ
        XCTAssertTrue(S34AVoiceRules.selfCardDone(recordNeeded: false, autoSelf: 3))
        XCTAssertFalse(S34AVoiceRules.selfCardDone(recordNeeded: false, autoSelf: 2), "まだ端末に足せていない")
        XCTAssertFalse(S34AVoiceRules.selfCardDone(recordNeeded: true, autoSelf: 9))
        XCTAssertFalse(S34AVoiceRules.selfCardDone(recordNeeded: nil, autoSelf: 9))
    }

    func testAudioName() {
        XCTAssertTrue(S34AVoiceRules.isAudioName("chunk_2026-11-27_0930.m4a"))
        XCTAssertFalse(S34AVoiceRules.isAudioName("../secret.wav"))
        XCTAssertFalse(S34AVoiceRules.isAudioName("a/b.m4a"))
        XCTAssertFalse(S34AVoiceRules.isAudioName(".hidden"))
        XCTAssertFalse(S34AVoiceRules.isAudioName(""))
        XCTAssertFalse(S34AVoiceRules.isAudioName("音声.m4a"))
    }

    func testVoicePlanOnlyExistingNamedPeople() {
        let local = [
            S34AVoiceLocal(id: "me", name: nil, isSelf: true, hidden: false),
            S34AVoiceLocal(id: "12", name: "見本 花子", isSelf: false, hidden: false),
            S34AVoiceLocal(id: "13", name: nil, isSelf: false, hidden: false),
            S34AVoiceLocal(id: "14", name: "見本 三郎", isSelf: false, hidden: true),
            S34AVoiceLocal(id: "15", name: "見本 四郎", isSelf: false, hidden: false),
        ]
        let people = [
            S34AVoicePerson(speaker: "自分", speakerID: "me", samples: [sample("a.m4a", 1)], auto: true),
            S34AVoicePerson(speaker: "見本花子", speakerID: "12", samples: [sample("b.m4a", 1)], auto: true),   // 空白の違いは同じ名前
            S34AVoicePerson(speaker: "見本 太郎", speakerID: "13", samples: [sample("c.m4a", 1)], auto: true),  // 端末で名前が無い
            S34AVoicePerson(speaker: "見本 三郎", speakerID: "14", samples: [sample("d.m4a", 1)], auto: true),  // 隠している
            S34AVoicePerson(speaker: "見本 五郎", speakerID: "15", samples: [sample("e.m4a", 1)], auto: true),  // 名前が違う
            S34AVoicePerson(speaker: "見本 六郎", speakerID: "99", samples: [sample("f.m4a", 1)], auto: true),  // 端末にいない
        ]
        let plan = S34AVoiceRules.plan(people, local: local, marks: [], dropped: [])
        XCTAssertEqual(plan.map(\.person), ["me", "12"], "人は作らない・名前を変えない・隠した人には足さない")
        // 自分は端末にまだいなくても足す（自分を作るのは声の登録の側）
        let noSelf = S34AVoiceRules.plan([people[0]], local: [], marks: [], dropped: [])
        XCTAssertEqual(noSelf.map(\.person), ["me"])
    }

    func testVoicePlanCapsAndSkips() {
        let local = [S34AVoiceLocal(id: "12", name: "見本 花子", isSelf: false, hidden: false)]
        var selfSamples: [S34AVoiceSample] = []
        for i in 0..<20 { selfSamples.append(sample("s\(i).m4a", Double(i), scene: "home")) }
        var other: [S34AVoiceSample] = [sample("bad/name.m4a", 1), sample("short.m4a", 1, 1.5), sample("long.m4a", 1, 11),
                                        sample("dropped.m4a", 1), sample("done.m4a", 1)]
        for i in 0..<8 { other.append(sample("o\(i).m4a", Double(i))) }
        let people = [S34AVoicePerson(speaker: "自分", speakerID: "me", samples: selfSamples, auto: true),
                      S34AVoicePerson(speaker: "見本 花子", speakerID: "12", samples: other, auto: true)]
        let marks = [S34AVoiceMark(key: sample("done.m4a", 1).key, person: "12", voice: "1.000", scene: nil)]
        let dropped: Set<String> = [sample("dropped.m4a", 1).key]
        // 1 回 10 個まで
        XCTAssertEqual(S34AVoiceRules.plan(people, local: local, marks: marks, dropped: dropped).count, S34AVoiceRules.perRun)
        let all = S34AVoiceRules.plan(people, local: local, marks: marks, dropped: dropped, limit: 100)
        XCTAssertEqual(all.filter { $0.person == "me" }.count, S34AVoiceRules.selfMax, "自分は 15 個まで")
        let hers = all.filter { $0.person == "12" }.map(\.sample.audio)
        XCTAssertEqual(hers, ["o0.m4a", "o1.m4a", "o2.m4a", "o3.m4a"], "もう 1 個あるので 5 個まで・名前の形・長さ・外した・足した見本は飛ばす")
        // 同じ回の中でも同じ見本は 1 回だけ
        let twice = [S34AVoicePerson(speaker: nil, speakerID: "me", samples: [sample("x.m4a", 1), sample("x.m4a", 1)], auto: true)]
        XCTAssertEqual(S34AVoiceRules.plan(twice, local: [], marks: [], dropped: []).count, 1)
    }

    func testVoiceMarksLineAndUndo() {
        var marks: [S34AVoiceMark] = []
        for i in 0..<3 { marks.append(S34AVoiceMark(key: "m\(i)", person: "me", voice: "\(i).000", scene: "home")) }
        marks.append(S34AVoiceMark(key: "p1", person: "12", voice: "10.000", scene: nil))
        marks.append(S34AVoiceMark(key: "p2", person: "12", voice: "11.000", scene: nil))
        marks.append(S34AVoiceMark(key: "p3", person: "13", voice: "12.000", scene: nil))
        XCTAssertEqual(S34AVoiceRules.line(marks), "自分 3 個・ほかの人 2 人に 3 個")
        XCTAssertNil(S34AVoiceRules.line([]))
        let by = S34AVoiceRules.byPerson(marks)
        XCTAssertEqual(by["me"], ["0.000", "1.000", "2.000"])
        XCTAssertEqual(by["12"], ["10.000", "11.000"])
        XCTAssertEqual(S34AVoiceRules.added(marks, [S34AVoiceMark(key: "n", person: "me", voice: "20.000", scene: nil)], limit: 3).map(\.key),
                       ["p2", "p3", "n"], "控えは新しいほうから上限まで")
        // 控えは保存して読み直せる
        let data = try? JSONEncoder().encode(marks)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode([S34AVoiceMark].self, from: $0) }, marks)
    }
}

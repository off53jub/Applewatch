import XCTest
@testable import LifeLog

/// s32 の AI の仕事の理解（S32ARules.swift・2026-11-27）: 仕事のまとめの新しい見出しの読み（あり／なし／前の形）・
/// 項目の終わりの（HH:MM 名前）の外し方・頼み方の文の見出し・work_fix の送る形（K32-3）・K2 の新しい鍵の読み（K32-2。
/// 壊れていても K2 は読める）・言葉を押せる場所・人とチームの地図・番号の早見・決まったことの台帳・通信簿・手引き。
/// 見本の名前・言葉・番号はどれも作りもの（実在の人・会社・案件・仕組みではない）。
@MainActor
final class S32ATests: XCTestCase {
    private var today: Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 11
        c.day = 27
        c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c) ?? .now
    }

    // MARK: - K32-1 新しい見出しの読み

    private let daily = """
    【日付】2026-11-27
    【出どころ】
    ・［1］見本チーム＞見本のチャネル「打鍵の相談」（いた人：見本花子、自分）
    【会議】
    ・10:00〜10:30 見本の定例（出席：見本花子、見本太郎）［1］
    【決まったこと】
    ・見本の打ち直しは今週から（10:12 見本花子）［1］
    【自分の宿題】
    ・見本の表を送る（見本花子から／11/30まで）（10:20 見本花子）［1］
    【よく出た言葉】
    ・打鍵
    【メール】
    ・09:15 見本太郎→自分「見本の不具合」: 直しは明日の予定
    """

    func testDailyNewHeadingsAreRead() {
        let parsed = WorkDigestParser.parse(daily, today: today)
        XCTAssertTrue(parsed.found)
        XCTAssertEqual(parsed.day, "2026-11-27")
        let s = parsed.sections
        XCTAssertEqual(s.meetings, ["10:00〜10:30 見本の定例（出席：見本花子、見本太郎）［1］"])
        XCTAssertEqual(s.mail, ["09:15 見本太郎→自分「見本の不具合」: 直しは明日の予定"])
        // 項目はそのまま残す（外すのは読むとき）
        XCTAssertEqual(s.decided, ["見本の打ち直しは今週から（10:12 見本花子）［1］"])
        XCTAssertEqual(s.words, ["打鍵"])
        XCTAssertNil(s.tickets)
        XCTAssertNil(s.terms)
        // 会議は出どころのすぐ後ろ・メールは前の見出しの後ろ
        XCTAssertEqual(s.lists.map(\.title), ["出どころ", "会議", "決まったこと", "自分の宿題", "よく出た言葉", "メール"])
        // 宿題の前置きの扱いは今までどおり（タスクになるのは 1 件）
        XCTAssertEqual(parsed.homeworkTasks.count, 1)
    }

    func testLedgerBaseAndAnswersAreRead() {
        let text = """
        【日付】2026-11-27
        【チケット】
        ・#108｜見本の初めの値が入らない｜直し中｜見本太郎
        ・#108｜見本の初めの値が入らない｜直し中｜見本太郎
        【ケース】
        ・ST-012｜見本の申込から開設まで｜待ち｜自分
        【言葉】
        ・打鍵｜手順どおりに画面を操作して確かめること｜見本チーム
        【体制】
        ・見本花子｜見本チーム｜テストの取りまとめ
        【仕組み】
        ・見本の申込 → 見本の審査｜申込の中身
        【番号の決まり】
        ・ST- はテストのケース、# はチケット
        【自分の役割】
        ・見本の打鍵の取りまとめ
        【答え】
        ・q1｜テストのケースの番号
        """
        let s = WorkDigestParser.parse(text, today: today).sections
        XCTAssertEqual(s.tickets, ["#108｜見本の初めの値が入らない｜直し中｜見本太郎"], "重なった同じ行は 1 つ")
        XCTAssertEqual(s.cases, ["ST-012｜見本の申込から開設まで｜待ち｜自分"])
        XCTAssertEqual(s.terms, ["打鍵｜手順どおりに画面を操作して確かめること｜見本チーム"])
        XCTAssertEqual(s.org, ["見本花子｜見本チーム｜テストの取りまとめ"])
        XCTAssertEqual(s.systems, ["見本の申込→見本の審査｜申込の中身"], "日本語の字のあいだの空白は今までどおり除く")
        XCTAssertEqual(s.numbering, ["ST- はテストのケース、# はチケット"])
        XCTAssertEqual(s.myrole, ["見本の打鍵の取りまとめ"])
        XCTAssertEqual(s.answers, ["q1｜テストのケースの番号"])
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.lists.map(\.title), ["チケット", "ケース", "言葉", "体制", "仕組み", "番号の決まり", "自分の役割", "答え"])
    }

    func testOldFormKeepsNewFieldsEmpty() throws {
        let old = """
        【日付】2026-11-08
        【決まったこと】
        ・A案にする
        【自分の宿題】
        ・見積書を送る（Aさんから／11/10まで）
        """
        let s = WorkDigestParser.parse(old, today: today).sections
        for field in [s.meetings, s.mail, s.tickets, s.cases, s.terms, s.org, s.systems, s.numbering, s.myrole, s.answers] {
            XCTAssertNil(field)
        }
        XCTAssertEqual(s.lists.map(\.title), ["決まったこと", "自分の宿題"])
        // 保存する文字にも出ない・前に保存したものも読める
        let data = try JSONEncoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("meetings"))
        XCTAssertFalse(json.contains("tickets"))
        let saved = #"{"decided":["a"],"homework":[],"others":[],"topics":[],"checks":[]}"#
        let back = try JSONDecoder().decode(WorkDigest.Sections.self, from: Data(saved.utf8))
        XCTAssertNil(back.meetings)
        XCTAssertEqual(back.decided, ["a"])
        // 新しい見出しだけのまとめは空ではない
        XCTAssertFalse(WorkDigest.Sections(terms: ["打鍵｜…"]).isEmpty)
        // 新しい欄を入れて保存したものは読み戻せる
        var made = WorkDigest.Sections()
        made.meetings = ["10:00〜10:30 見本"]
        let again = try JSONDecoder().decode(WorkDigest.Sections.self, from: JSONEncoder().encode(made))
        XCTAssertEqual(again.meetings, ["10:00〜10:30 見本"])
    }

    /// よくある言葉の見出しは、区切りで閉じるだけの文の行では見出しにしない
    func testCommonWordsNeedBracket() {
        let text = """
        【日付】2026-11-27
        【気になる話題】
        会議：来週に延ばすかもしれない
        答え: まだ出ていない
        【会議】
        ・09:00〜09:30 見本の朝会［1］
        """
        let s = WorkDigestParser.parse(text, today: today).sections
        XCTAssertEqual(s.topics, ["会議：来週に延ばすかもしれない", "答え: まだ出ていない"])
        XCTAssertEqual(s.meetings, ["09:00〜09:30 見本の朝会［1］"])
        XCTAssertNil(s.answers)
        // 長い言い方は区切りで閉じるだけでも見出し
        XCTAssertEqual(WorkDigestParser.header("番号の決まり：")?.part, .numbering)
        XCTAssertEqual(WorkDigestParser.header("［会議］")?.part, .meetings)
        XCTAssertNil(WorkDigestParser.header("会議：来週"))
        XCTAssertNil(WorkDigestParser.header("【用語】"), "「用語」だけは見出しにしない")
    }

    // MARK: - （HH:MM 名前）の外し方

    func testStampIsSplit() {
        let a = S32ADigest.split("A案にする（10:30 見本 花子）［1］")
        XCTAssertEqual(a.text, "A案にする")
        XCTAssertEqual(a.tags, [1])
        XCTAssertEqual(a.at, "10:30")
        XCTAssertEqual(a.who, "見本 花子")
        XCTAssertEqual(a.stamp, "10:30・見本 花子")
        // 番号が先でも
        let b = S32ADigest.split("A案にする［2］（9:05 見本 太郎）")
        XCTAssertEqual(b.text, "A案にする")
        XCTAssertEqual(b.tags, [2])
        XCTAssertEqual(b.at, "09:05")
        // 時刻だけ・全角・時刻の幅・空白なし
        let c = S32ADigest.split("見本を直す（１０：３０）")
        XCTAssertEqual(c.text, "見本を直す")
        XCTAssertEqual(c.at, "10:30")
        XCTAssertNil(c.who)
        XCTAssertEqual(S32ADigest.split("見本（10:00〜10:30 見本 花子）").at, "10:00")
        XCTAssertEqual(S32ADigest.split("見本（10:30見本 花子）").who, "見本 花子")
        // 外さないもの: 期限・時刻の無いかっこ・ありえない時刻・見本の形のまま・文がかっこだけ
        XCTAssertEqual(S32ADigest.split("見本を送る（11/30まで）").text, "見本を送る（11/30まで）")
        XCTAssertNil(S32ADigest.split("見本を送る（10:00まで）").at)
        XCTAssertEqual(S32ADigest.split("見本を送る（10:00まで）").text, "見本を送る（10:00まで）")
        XCTAssertNil(S32ADigest.split("見本（A案）").at)
        XCTAssertNil(S32ADigest.split("見本（25:10 見本 花子）").at)
        XCTAssertEqual(S32ADigest.split("…（HH:MM 名前）［1］").text, "…（HH:MM 名前）")
        XCTAssertEqual(S32ADigest.split("（10:30 見本 花子）").text, "（10:30 見本 花子）")
        // 「名前」のままの書きかけは人にしない
        XCTAssertNil(S32ADigest.split("見本（10:30 名前）").who)
    }

    func testHomeworkTaskDropsStamp() throws {
        let items = Pipeline.workDigestTasks(["見本の表を送る（見本花子から／11/30まで）（10:20 見本花子）［1］"], day: "2026-11-27", now: today)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.what, "見本の表を送る")
        XCTAssertEqual(item.from, "見本花子")
        XCTAssertEqual(item.dueText, "11/30まで")
    }

    func testDigestLinesShowStampApart() {
        let parsed = WorkDigestParser.parse(daily, today: today)
        let entry = WorkDigest.Entry(day: "2026-11-27", text: daily, sections: parsed.sections, source: .paste)
        let lines = Pipeline.workDigestLines(entry)
        let decided = lines.first { $0.heading == "決まったこと" }
        XCTAssertEqual(decided?.text, "見本の打ち直しは今週から")
        XCTAssertEqual(decided?.stamp, "10:12・見本花子")
        XCTAssertEqual(decided?.source, "見本チーム＞見本のチャネル「打鍵の相談」")
        let meeting = lines.first { $0.heading == "会議" }
        XCTAssertEqual(meeting?.text, "10:00〜10:30 見本の定例（出席：見本花子、見本太郎）")
        XCTAssertEqual(meeting?.stamp, "")
        // 出どころの行は外さない
        XCTAssertEqual(lines.first { $0.heading == "出どころ" }?.stamp, "")
        // 人の名前で探せる
        XCTAssertFalse(Pipeline.searchWorkDigests("10:12", in: [entry]).isEmpty)
    }

    // MARK: - 頼み方の文

    func testDailyPromptHasNewHeadingsInOrder() {
        let prompt = WorkDigestPrompt.full(day: "2026-11-27")
        XCTAssertTrue(prompt.contains("【日付】2026-11-27"))
        XCTAssertTrue(prompt.contains("Outlook"))
        XCTAssertTrue(prompt.contains("（HH:MM 名前）"))
        // 前の見出しと順はそのまま・新しい見出しが入っている
        let order = ["【日付】2026", "【出どころ】\n", "【会議】\n", "【決まったこと】\n", "【自分の宿題】\n", "【ほかの人の動き】\n",
                     "【気になる話題】\n", "【あとで確かめること】\n", "【よく出た言葉】\n", "【メール】\n"]
        var last = prompt.startIndex
        for heading in order {
            guard let r = prompt.range(of: heading, range: last..<prompt.endIndex) else {
                XCTFail(heading)
                continue
            }
            last = r.upperBound
        }
        // 見本の形そのものも読める
        let parsed = WorkDigestParser.parse(prompt, today: today)
        XCTAssertTrue(parsed.found)
        XCTAssertEqual(parsed.sections.meetings?.count, 1)
        XCTAssertEqual(parsed.sections.mail?.count, 1)
    }

    func testOtherPrompts() throws {
        let ledger = S32APrompt.ledger(day: "2026-11-27")
        XCTAssertTrue(ledger.contains("【チケット】"))
        XCTAssertTrue(ledger.contains("【ケース】"))
        XCTAssertTrue(ledger.contains("#番号｜題｜状態｜担当"))
        let ls = WorkDigestParser.parse(ledger, today: today)
        XCTAssertEqual(ls.day, "2026-11-27")
        XCTAssertEqual(ls.sections.tickets?.count, 1)
        XCTAssertEqual(ls.sections.cases?.count, 1)

        let base = S32APrompt.base(day: "2026-11-27")
        for heading in ["【言葉】", "【体制】", "【仕組み】", "【番号の決まり】", "【自分の役割】"] {
            XCTAssertTrue(base.contains(heading), heading)
        }
        let bs = WorkDigestParser.parse(base, today: today).sections
        XCTAssertNotNil(bs.terms)
        XCTAssertNotNil(bs.org)
        XCTAssertNotNil(bs.systems)
        XCTAssertNotNil(bs.numbering)
        XCTAssertNotNil(bs.myrole)

        XCTAssertNil(S32APrompt.quiz(day: "2026-11-27", quiz: nil))
        XCTAssertNil(S32APrompt.quiz(day: "2026-11-27", quiz: S32AQuiz(week: "2026-11-23", questions: [])))
        let many: [S32AQuestion] = (1...12).map { S32AQuestion(id: "q\($0)", q: "見本の質問 \($0)") }
        let quiz = try XCTUnwrap(S32APrompt.quiz(day: "2026-11-27", quiz: S32AQuiz(questions: many)))
        XCTAssertTrue(quiz.contains("・q1｜見本の質問 1"))
        XCTAssertTrue(quiz.contains("・q10｜見本の質問 10"))
        XCTAssertFalse(quiz.contains("q11｜"), "10 個まで")
        XCTAssertTrue(quiz.contains("【答え】"))
        XCTAssertEqual(WorkDigestParser.parse(quiz, today: today).sections.answers?.count, 1)
        // 母艦が頼み方まで書いていれば、それを使う（【答え】の無いものは使わない）
        let written = "見本の頼み方\n【答え】\n・q1a2b3｜答え"
        XCTAssertEqual(S32APrompt.quiz(day: "2026-11-27", quiz: S32AQuiz(questions: many, prompt: written)), written)
        XCTAssertNotEqual(S32APrompt.quiz(day: "2026-11-27", quiz: S32AQuiz(questions: many, prompt: "形の違う文")), "形の違う文")
    }

    // MARK: - K32-3 work_fix の送る形

    private func object(_ data: Data?) throws -> [String: Any] {
        let d = try XCTUnwrap(data)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    func testFixBody() throws {
        let plain = try object(S32ARules.fixBody(id: "wd-b1", what: .done, value: nil, day: "2026-11-27"))
        XCTAssertEqual(plain["kind"] as? String, "work_fix")
        XCTAssertEqual(plain["id"] as? String, "wd-b1")
        XCTAssertEqual(plain["what"] as? String, "done")
        XCTAssertEqual(plain["day"] as? String, "2026-11-27")
        XCTAssertTrue(plain["value"] is NSNull, "値の無い直しは null")
        XCTAssertEqual(Set(plain.keys), ["kind", "id", "what", "value", "day"])

        let moved = try object(S32ARules.fixBody(id: "wd-b1", what: .project, value: " wp-demo0003 ", day: "2026-11-27"))
        XCTAssertEqual(moved["value"] as? String, "wp-demo0003")
        XCTAssertTrue(try object(S32ARules.fixBody(id: "wd-b1", what: .term, value: "  ", day: "2026-11-27"))["value"] is NSNull)

        XCTAssertEqual(S32AFixKind.allCases.map(\.rawValue), ["project", "person", "term", "done", "notmine"])
        XCTAssertNil(S32ARules.fixBody(id: "", what: .done, value: nil, day: "2026-11-27"))
        XCTAssertNil(S32ARules.fixBody(id: "id with space", what: .done, value: nil, day: "2026-11-27"))
        XCTAssertNil(S32ARules.fixBody(id: "wd-b1", what: .done, value: nil, day: "11/27"))
        XCTAssertNil(S32ARules.fixBody(id: "wd-b1", what: .person, value: String(repeating: "あ", count: 201), day: "2026-11-27"))
        XCTAssertTrue(S32AFixKind.done.hides)
        XCTAssertTrue(S32AFixKind.notmine.hides)
        XCTAssertFalse(S32AFixKind.project.hides)
    }

    func testFixLineAndKeep() {
        let fix = S32AFix(what: .project, value: "wp-demo0003", valueName: "見本の不具合", day: "2026-11-27")
        XCTAssertEqual(S32ARules.fixLine(fix), "伝えました: 案件が違う（→ 見本の不具合）")
        XCTAssertEqual(S32ARules.fixLine(S32AFix(what: .done, day: "2026-11-27")), "伝えました: もう済んだ")
        let fixes: [String: S32AFix] = [
            "new": S32AFix(what: .done, day: "2026-11-26"),
            "old": S32AFix(what: .done, day: "2026-10-01"),
        ]
        XCTAssertEqual(Set(S32ARules.keptFixes(fixes, today: "2026-11-27").keys), ["new"], "30 日より古い覚えは捨てる")
    }

    // MARK: - K32-2 K2 の新しい鍵

    private func board(_ extra: String) -> S27WBoard? {
        let json = """
        {"version":1,"as_of":"2026-11-27",
         "projects":[{"id":"wp-0000000a","name":"見本の案件","kind":"mine",
           "items":[{"id":"a1","kind":"homework","text":"見本の打鍵を頼む"},{"id":"a2","kind":"open","text":"見本の UAT の返事"}],
           "timeline":[{"id":"a3","kind":"decided","text":"見本は今週から"}]}]\(extra)}
        """
        return S27WRules.board(Data(json.utf8))
    }

    func testKnowIsRead() throws {
        let b = try XCTUnwrap(board("""
        ,"glossary":[{"term":"打鍵","meaning":"見本の意味","team":"見本チーム","days":["2026-11-20","2026-11-21"],"sample_ids":["a1"],"voice_says":"だけん","firm":true},
                     {"term":"UAT","days":5}],
         "org":[{"id":"wm-1","name":"見本 花子","team":"見本チーム","role":"取りまとめ","with_me":"asked","last":"2026-11-26","firm":true}],
         "systems":{"nodes":[{"id":"n1","name":"見本の申込"},{"id":"n2"}],"edges":[{"from":"n1","to":"n2","what":"中身"}],"stuck":["n2"]},
         "numbering":[{"no":12,"what":"見本","days":3}],
         "decisions":[{"id":"d1","day":"2026-11-20","text":"来週から","flipped_by":"d2"},{"id":"d2","day":"2026-11-26","text":"今週から"}],
         "threads":[{"id":"t1","title":"見本の糸","keys":["打鍵"],"days":["2026-11-20","2026-11-25"],"items":["a1","a2"],"state":"続いている"},
                    {"title":"数で来た糸","days":4,"items":7}],
         "quiz":{"week":"2026-11-23","questions":[{"id":"q1","q":"見本の質問","why":"分からない","about":"glossary"}]},
         "scorecard":{"week":"2026-11-23","rows":[{"label":"言葉","now":3,"prev":1,"unit":"語"},{"label":"相手","now":"34/196","prev":"27/196"}]},
         "guide":{"written_at":"2026-11-27T03:10:00+09:00","by":"subscription","stale":false}
        """))
        let know = try XCTUnwrap(b.know)
        XCTAssertEqual(know.glossary.map(\.term), ["打鍵", "UAT"])
        XCTAssertEqual(know.glossary[0].days, 2, "日の並びで来たら、その数")
        XCTAssertEqual(know.glossary[0].voiceSays, ["だけん"], "1 つの文字でも読む")
        XCTAssertTrue(know.glossary[0].isFirm)
        XCTAssertFalse(know.glossary[1].isFirm, "firm の無いものは仮")
        XCTAssertEqual(know.org.first?.withMe, "asked")
        XCTAssertEqual(know.systems?.nodes.last?.name, "n2", "名前の無い箱は id を名前に")
        XCTAssertEqual(know.systems?.stuck, ["n2"])
        XCTAssertEqual(know.numbering.first?.no, "12", "数の番号も文字で読む")
        XCTAssertTrue(know.decisions[0].flipped)
        XCTAssertEqual(know.threads[0].lastDay, "2026-11-25")
        XCTAssertEqual(know.threads[0].items, ["a1", "a2"])
        XCTAssertEqual(know.threads[1].days, 4)
        XCTAssertEqual(know.threads[1].itemCount, 7)
        XCTAssertEqual(know.quiz?.questions.first?.id, "q1")
        XCTAssertEqual(know.scorecard?.rows.first?.now, 3)
        XCTAssertEqual(know.scorecard?.rows.last?.nowText, "34/196")
        XCTAssertEqual(know.guide?.by, "subscription")
        // K2 のほかの欄はそのまま
        XCTAssertEqual(b.projects.first?.items.count, 2)
    }

    func testBrokenKnowKeepsBoard() throws {
        let broken = try XCTUnwrap(board("""
        ,"glossary":"見本","org":5,"systems":[1,2],"numbering":{"no":1},"decisions":"x","threads":null,
         "quiz":"見本","scorecard":[],"guide":"見本"
        """), "新しい鍵が壊れていても K2 は読める")
        XCTAssertNil(broken.know)
        XCTAssertEqual(broken.projects.first?.items.count, 2)

        let partly = try XCTUnwrap(board("""
        ,"glossary":[{"term":""},{"term":"UAT"},3,{"meaning":"言葉が無い"}],
         "org":[{"team":"名前が無い"},{"name":"見本 花子"}],
         "decisions":[{"day":"2026-11-27"},{"text":"見本"}],
         "scorecard":{"rows":[{"now":1},{"label":"見本","now":"?"}]}
        """))
        let know = try XCTUnwrap(partly.know)
        XCTAssertEqual(know.glossary.map(\.term), ["UAT"], "読めない行は飛ばす")
        XCTAssertEqual(know.org.map(\.name), ["見本 花子"])
        XCTAssertEqual(know.decisions.map(\.text), ["見本"])
        XCTAssertEqual(know.scorecard?.rows.count, 1)
        XCTAssertNil(know.systems)

        // 前の形（新しい鍵が無い）は nil
        XCTAssertNil(try XCTUnwrap(board("")).know)
        // 空のものだけでも nil
        XCTAssertNil(try XCTUnwrap(board(#","glossary":[],"quiz":{"questions":[]}"#)).know)
    }

    // MARK: - 言葉を押せる場所

    func testTermSpans() throws {
        let text = "UATの打鍵済みとUATSの確かめ"
        let spans = S32ARules.termSpans(text, terms: ["UAT", "打鍵", "打鍵済み", "打"])
        XCTAssertEqual(spans.map { String(text[$0.range]) }, ["UAT", "打鍵済み"], "長い言葉を先に・英字の続きの中では当てない・1 字の言葉は当てない")
        XCTAssertEqual(spans.map(\.index), [0, 2])
        // 大文字小文字・全角半角の違いは同じ言葉
        let wide = "ｕａｔの話"
        XCTAssertEqual(S32ARules.termSpans(wide, terms: ["UAT"]).count, 1)
        XCTAssertTrue(S32ARules.termSpans("見本", terms: []).isEmpty)

        let linked = try XCTUnwrap(S32ARules.linked(text, terms: ["UAT", "打鍵"]))
        let links: [URL] = linked.runs.compactMap { $0.link }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.compactMap { S32ARules.termIndex($0) }, [0, 1])
        XCTAssertEqual(String(linked.characters), text, "文は変えない")
        XCTAssertNil(S32ARules.linked("見本の話", terms: ["UAT"]))
        XCTAssertNil(S32ARules.termIndex(URL(string: "https://example.com/term/1")!))
    }

    func testItemsLookup() throws {
        let b = try XCTUnwrap(board(""))
        XCTAssertEqual(S32ARules.items(b, ids: ["a3", "zz", "a1", "a3"]).map(\.id), ["a3", "a1"])
        XCTAssertTrue(S32ARules.items(b, ids: []).isEmpty)
    }

    // MARK: - 地図・図・早見・台帳・通信簿・手引き

    func testOrgGroups() {
        let people = [
            S32AOrgPerson(name: "見本 一", team: "見本 B"),
            S32AOrgPerson(name: "見本 二"),
            S32AOrgPerson(name: "見本 三", team: "見本 A"),
            S32AOrgPerson(name: "見本 四", team: "見本 A"),
        ]
        let groups = S32ARules.orgGroups(people)
        XCTAssertEqual(groups.map(\.team), ["見本 A", "見本 B", S32ARules.noTeam], "人の多いチームから・分からない人は最後")
        XCTAssertEqual(groups[0].people.map(\.name), ["見本 三", "見本 四"])
        XCTAssertEqual(S32ARules.withMeLabel("ask"), "自分が頼む相手")
        XCTAssertNil(S32ARules.withMeLabel(nil))
    }

    func testSystemsText() {
        let systems = S32ASystems(nodes: [S32ANode(id: "n1", name: "見本の申込"), S32ANode(id: "n2", name: "見本の審査"),
                                          S32ANode(id: "n3", name: "見本の帳票")],
                                  edges: [S32AEdge(from: "n1", to: "n2", what: "中身"), S32AEdge(from: "n2", to: "nx")])
        XCTAssertEqual(S32ARules.edgeLine(systems.edges[0], in: systems), "見本の申込 → 見本の審査（中身）")
        XCTAssertEqual(S32ARules.edgeLine(systems.edges[1], in: systems), "見本の審査 → nx")
        XCTAssertEqual(S32ARules.loneNodes(systems).map(\.id), ["n3"])
    }

    func testNumberingAndDecisions() {
        let list = [S32ANumber(no: "ST-2", days: 1), S32ANumber(no: "ST-10"), S32ANumber(no: "ST-1", days: 5), S32ANumber(no: "ST-3", days: 1)]
        XCTAssertEqual(S32ARules.numberingSorted(list).map(\.no), ["ST-1", "ST-2", "ST-3", "ST-10"])

        let all = [S32ADecision(id: "d1", day: "2026-11-20", text: "来週から", flippedBy: "d2"),
                   S32ADecision(id: "d2", day: "2026-11-26", text: "今週から", who: "見本 花子"),
                   S32ADecision(text: "日の無い決定")]
        XCTAssertEqual(S32ARules.decisionsSorted(all).map(\.text), ["今週から", "来週から", "日の無い決定"])
        XCTAssertEqual(S32ARules.flippedText(all[0], in: all), "今週から")
        XCTAssertNil(S32ARules.flippedText(all[1], in: all))
        XCTAssertTrue(S32ARules.flipsOther(all[1], in: all))
        XCTAssertFalse(S32ARules.flipsOther(all[0], in: all))
        XCTAssertEqual(S32ARules.searchDecisions(all, query: "花子").map(\.text), ["今週から"])
        XCTAssertEqual(S32ARules.searchDecisions(all, query: " ").count, 3)
    }

    func testScoreText() {
        XCTAssertEqual(S32ARules.valueText(S32AScoreRow(label: "案件", now: 51, prev: 43, unit: "%")), "51%")
        XCTAssertEqual(S32ARules.diffText(S32AScoreRow(label: "案件", now: 51, prev: 43, unit: "%")), "前の週から +8%")
        XCTAssertEqual(S32ARules.diffText(S32AScoreRow(label: "聞き違い", now: 18, prev: 20, unit: "%")), "前の週から −2%")
        XCTAssertEqual(S32ARules.diffText(S32AScoreRow(label: "言葉", now: 3, prev: 3, unit: "語")), "前の週と同じ")
        XCTAssertEqual(S32ARules.valueText(S32AScoreRow(label: "言葉", now: 3.5, unit: "語")), "3.5 語")
        XCTAssertNil(S32ARules.diffText(S32AScoreRow(label: "初めて", now: 3)))
        var text = S32AScoreRow(label: "相手")
        text.nowText = "34/196"
        text.prevText = "27/196"
        XCTAssertEqual(S32ARules.valueText(text), "34/196")
        XCTAssertEqual(S32ARules.diffText(text), "前の週は 27/196")
    }

    func testGuideLine() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let guide = S32AGuide(writtenAt: "2026-11-26T18:10:00Z", by: "subscription", stale: false)
        XCTAssertEqual(S32ARules.guideLine(guide, timeZone: tokyo), "11/27 3:10 に書いた・定額の枠で作り直し")
        XCTAssertEqual(S32ARules.guideLine(S32AGuide(by: "rules")), "規則の版（定額の枠が使えなかった）")
        XCTAssertEqual(S32ARules.stampText("2026-11-27"), "11/27")
        XCTAssertEqual(S32ARules.glossaryLine([S32ATerm(term: "a", firm: true), S32ATerm(term: "b")]), "2 語（仮 1）")
    }
}

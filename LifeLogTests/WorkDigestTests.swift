import XCTest
@testable import LifeLog

/// 仕事のまとめ（2026-11-08）の読み方を確かめる。
/// 日付（全角・半角・「/」・無いとき）・見出しで分ける・自分の宿題の分け方・写真の読み取りの崩れ（余計な空白・「・」の揺れ）。
/// 宿題の前置きの文をタスクにしない・まとめを探す・質問の材料にする（2026-11-10）。
/// 名前はすべて作り物（Aさん・Bさん）。
@MainActor
final class WorkDigestTests: XCTestCase {
    private let sample = """
    【日付】2026-11-08
    【決まったこと】
    ・来週の打ち合わせは火曜にする
    ・見積もりは2案で出す
    【自分の宿題】
    ・見積書を送る（Aさんから／11/10まで）
    ・議事録をまとめる（Bさんから／いつまで）
    【ほかの人の動き】
    ・Aさん: 客先に電話した
    【気になる話題】
    ・新しい道具の話
    【あとで確かめること】
    ・会議室が取れているか
    """

    private var today: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
    }

    // MARK: - 日付

    func testDateHalfWidth() {
        XCTAssertEqual(WorkDigestParser.parse(sample, today: today).day, "2026-11-08")
    }

    func testDateFullWidthDigits() {
        let text = "【日付】２０２６－１１－０８\n【決まったこと】\n・あれ"
        XCTAssertEqual(WorkDigestParser.parse(text, today: today).day, "2026-11-08")
    }

    func testDateWithSlashesAndKanji() {
        XCTAssertEqual(WorkDigestParser.parse("【日付】2026/11/08", today: today).day, "2026-11-08")
        XCTAssertEqual(WorkDigestParser.parse("【日付】2026年11月8日（日）", today: today).day, "2026-11-08")
        XCTAssertEqual(WorkDigestParser.parse("【日付】２０２６／１１／０８", today: today).day, "2026-11-08")
        // 空白が混ざっても読む
        XCTAssertEqual(WorkDigestParser.parse("【 日付 】 2026 / 11 / 8", today: today).day, "2026-11-08")
    }

    func testDateOnNextLineAndWithoutYear() {
        XCTAssertEqual(WorkDigestParser.parse("【日付】\n2026-11-07\n【決まったこと】\n・あれ", today: today).day, "2026-11-07")
        // 見出しの中なら、年の無い日付も今年として読む
        XCTAssertEqual(WorkDigestParser.parse("【日付】11月8日", today: today).day, "2026-11-08")
    }

    func testDateMissing() {
        let text = "【決まったこと】\n・あれを決めた\n【自分の宿題】\n・資料を送る（Aさんから／11/10まで）"
        // 宿題の「11/10」は日付にしない
        XCTAssertNil(WorkDigestParser.parse(text, today: today).day)
        XCTAssertNil(WorkDigestParser.parse("", today: today).day)
    }

    func testDateFallbackWithoutHeader() {
        // 見出しが崩れても、年の付いた日付があれば使う
        XCTAssertEqual(WorkDigestParser.parse("2026/11/08 の Teams のまとめ\n・あれ", today: today).day, "2026-11-08")
    }

    func testImpossibleDate() {
        XCTAssertNil(WorkDigestParser.parse("【日付】2026-02-30", today: today).day)
        XCTAssertNil(WorkDigestParser.dayString(year: 2026, month: 13, day: 1))
    }

    // MARK: - 見出しで分ける

    func testSectionSplitting() {
        let parsed = WorkDigestParser.parse(sample, today: today)
        XCTAssertTrue(parsed.found)
        XCTAssertEqual(parsed.sections.decided, ["来週の打ち合わせは火曜にする", "見積もりは2案で出す"])
        XCTAssertEqual(parsed.sections.homework, ["見積書を送る（Aさんから／11/10まで）", "議事録をまとめる（Bさんから／いつまで）"])
        XCTAssertEqual(parsed.sections.others, ["Aさん: 客先に電話した"])
        XCTAssertEqual(parsed.sections.topics, ["新しい道具の話"])
        XCTAssertEqual(parsed.sections.checks, ["会議室が取れているか"])
        XCTAssertEqual(parsed.sections.lists.map(\.title),
                       ["決まったこと", "自分の宿題", "ほかの人の動き", "気になる話題", "あとで確かめること"])
    }

    func testMissingSectionsAndNothing() {
        let text = """
        【日付】2026-11-08
        【決まったこと】
        ・特になし
        【自分の宿題】
        ・資料を直す
        """
        let parsed = WorkDigestParser.parse(text, today: today)
        XCTAssertEqual(parsed.sections.decided, [])
        XCTAssertEqual(parsed.sections.homework, ["資料を直す"])
        XCTAssertEqual(parsed.sections.others, [])
        XCTAssertEqual(parsed.sections.lists.map(\.title), ["自分の宿題"])
    }

    func testNotFormattedText() {
        let parsed = WorkDigestParser.parse("きょうは会議が2つあった。\n午後は資料づくり。", today: today)
        XCTAssertFalse(parsed.found)
        XCTAssertTrue(parsed.sections.isEmpty)
    }

    func testBracketVariantsAndTextBeforeHeaders() {
        // 【 が [ や［ に読まれる・見出しの前に画面の文字が混ざる
        let text = """
        Claude
        [日付] 2026-11-08
        ［決まったこと］
        ・A案にする
        【自分の宿題」
        ・表を作る
        """
        let parsed = WorkDigestParser.parse(text, today: today)
        XCTAssertEqual(parsed.day, "2026-11-08")
        XCTAssertEqual(parsed.sections.decided, ["A案にする"])
        XCTAssertEqual(parsed.sections.homework, ["表を作る"])
    }

    func testItemOnHeaderLine() {
        let parsed = WorkDigestParser.parse("【決まったこと】・A案にする\n・B案はやめる", today: today)
        XCTAssertEqual(parsed.sections.decided, ["A案にする", "B案はやめる"])
    }

    func testBulletLineThatStartsWithSectionWordIsNotHeader() {
        let text = "【決まったこと】\n・宿題は来週までに出す\n宿題の話の続き"
        let parsed = WorkDigestParser.parse(text, today: today)
        // 「・宿題は…」も、印の無い続きの行も、見出しではない
        XCTAssertEqual(parsed.sections.decided, ["宿題は来週までに出す宿題の話の続き"])
        XCTAssertEqual(parsed.sections.homework, [])
    }

    // MARK: - 読み取りの崩れ

    func testBulletVariants() {
        let text = """
        【決まったこと】
        ･半角の点
        • 黒丸
        · 中点
        - ハイフン
        . 点に読まれた
        1. 番号
        """
        let parsed = WorkDigestParser.parse(text, today: today)
        XCTAssertEqual(parsed.sections.decided, ["半角の点", "黒丸", "中点", "ハイフン", "点に読まれた", "番号"])
    }

    func testStraySpacesAndWrappedLines() {
        let text = """
        【 自分 の 宿題 】
        ・ 見積 書 を 送る （ Aさん から ／ 11/10 まで ）
        ・とても長い宿題で、写真の読み取りで
        行が折り返されたもの
        ・Teams の 会議 を 入れる
        """
        let parsed = WorkDigestParser.parse(text, today: today)
        XCTAssertEqual(parsed.sections.homework, ["見積書を送る（Aさんから／11/10 まで）",
                                                  "とても長い宿題で、写真の読み取りで行が折り返されたもの",
                                                  "Teams の会議を入れる"])
    }

    func testTidy() {
        XCTAssertEqual(WorkDigestParser.tidy("資料 を  送る"), "資料を送る")
        XCTAssertEqual(WorkDigestParser.tidy("Send the  file"), "Send the file")
        XCTAssertEqual(WorkDigestParser.tidy("　全角の空白　あり　"), "全角の空白あり")
    }

    // MARK: - 自分の宿題

    func testHomeworkFromAndDue() {
        let h = WorkDigestParser.homework("見積書を送る（Aさんから／11/10まで）")
        XCTAssertEqual(h.what, "見積書を送る")
        XCTAssertEqual(h.from, "Aさん")
        XCTAssertEqual(h.dueText, "11/10まで")
    }

    func testHomeworkPlaceholdersAndHalfWidthParens() {
        let h = WorkDigestParser.homework("議事録をまとめる(Bさんから/いつまで)")
        XCTAssertEqual(h.what, "議事録をまとめる")
        XCTAssertEqual(h.from, "Bさん")
        XCTAssertNil(h.dueText)
        let none = WorkDigestParser.homework("表を作る（誰から／いつまで）")
        XCTAssertEqual(none.what, "表を作る（誰から／いつまで）")
        XCTAssertNil(none.from)
        XCTAssertNil(none.dueText)
    }

    func testHomeworkWithoutParensOrOtherParens() {
        XCTAssertEqual(WorkDigestParser.homework("資料を直す"), WorkDigestParser.Homework(what: "資料を直す"))
        // かっこの中が頼んだ人・期限でなければ、そのまま
        XCTAssertEqual(WorkDigestParser.homework("資料（第2版）を直す").what, "資料（第2版）を直す")
        XCTAssertEqual(WorkDigestParser.homework("資料を直す（第2版）").what, "資料を直す（第2版）")
    }

    func testHomeworkDueOnly() {
        let h = WorkDigestParser.homework("申請を出す（今週中まで）")
        XCTAssertEqual(h.what, "申請を出す")
        XCTAssertNil(h.from)
        XCTAssertEqual(h.dueText, "今週中まで")
    }

    func testDueDate() {
        let f = TaskBook.dayFormat
        XCTAssertEqual(WorkDigestParser.dueDate("11/10まで", digestDay: "2026-11-08").map { f.string(from: $0) }, "2026-11-10")
        XCTAssertEqual(WorkDigestParser.dueDate("２０２６年１１月１２日まで", digestDay: "2026-11-08").map { f.string(from: $0) },
                       "2026-11-12")
        // 年をまたぐ（12月のまとめの「1/5まで」は次の年）
        XCTAssertEqual(WorkDigestParser.dueDate("1/5まで", digestDay: "2026-12-20").map { f.string(from: $0) }, "2027-01-05")
        XCTAssertNil(WorkDigestParser.dueDate("来週の頭まで", digestDay: "2026-11-08"))
    }

    func testHomeworkBecomesWorkCandidates() {
        let homework = WorkDigestParser.parse(sample, today: today).sections.homework
        let items = Pipeline.workDigestTasks(homework, day: "2026-11-08", now: today)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.what), ["見積書を送る", "議事録をまとめる"])
        XCTAssertTrue(items.allSatisfy { $0.state == .open && $0.work == true && $0.day == "2026-11-08" })
        XCTAssertEqual(items.first?.from, "Aさん")
        XCTAssertEqual(items.first?.due.map { TaskBook.dayFormat.string(from: $0) }, "2026-11-10")
        // 同じまとめをもう一度取り込んでも、似たものとして足さない（帳の add と同じ見分け方）
        let again = Pipeline.workDigestTasks(homework, day: "2026-11-08", now: today)
        for (a, b) in zip(items, again) {
            XCTAssertTrue(TaskBook.similar(a.what, b.what))
        }
    }

    // MARK: - よく出た言葉（2026-11-10）

    func testWordsSection() {
        let text = sample + "\n【よく出た言葉】\n・設備台帳\n・AsIs（今の姿のこと）\n・CI/CD\n・設備台帳\n棚卸し\n・なし"
        let parsed = WorkDigestParser.parse(text, today: today)
        // 説明は落とす・同じ言葉は1つ・印の無い行は前の言葉につなげない・「なし」は入れない
        XCTAssertEqual(parsed.sections.words, ["設備台帳", "AsIs", "CI/CD", "棚卸し"])
        // ほかの見出しはそのまま
        XCTAssertEqual(parsed.sections.checks, ["会議室が取れているか"])
        XCTAssertEqual(parsed.sections.lists.last?.title, "よく出た言葉")
    }

    func testWordsOnOneLineAndTooLong() {
        let parsed = WorkDigestParser.parse("【よく出た言葉】設備台帳、業務フロー／ ダミーファイル：試しのファイル", today: today)
        XCTAssertEqual(parsed.sections.words, ["設備台帳", "業務フロー", "ダミーファイル"])
        // 文になっている長いものは言葉にしない
        let long = String(repeating: "あ", count: 31)
        XCTAssertEqual(WorkDigestParser.words([long, "短い言葉", "<b>"]), ["短い言葉"])
        // 30 個まで
        XCTAssertEqual(WorkDigestParser.words((1...40).map { "言葉\($0)" }).count, 30)
    }

    func testWordsAreOptional() throws {
        // 見出しが無ければ nil のまま（前の形と同じ）。「言葉」だけの行は見出しにしない
        let parsed = WorkDigestParser.parse(sample + "\n言葉: これは見出しではない", today: today)
        XCTAssertNil(parsed.sections.words)
        XCTAssertFalse(parsed.sections.isEmpty)
        // 前の版で保存したもの（words が無い）も読める
        let old = #"{"decided":["a"],"homework":[],"others":[],"topics":[],"checks":[]}"#
        let back = try JSONDecoder().decode(WorkDigest.Sections.self, from: Data(old.utf8))
        XCTAssertEqual(back.decided, ["a"])
        XCTAssertNil(back.words)
        // 言葉だけのまとめは「空」ではない
        XCTAssertFalse(WorkDigest.Sections(words: ["設備台帳"]).isEmpty)
    }

    // MARK: - 出どころ（2026-11-10）

    func testSourcesSection() {
        let text = """
        【日付】2026-11-08
        【出どころ】
        ・営業チーム＞一般「来週の段取り」（いた人：Aさん、Bさん、
        Cさん）
        ・チャット「見積もりの相談」（いた人：Aさん）
        ・営業チーム＞一般「来週の段取り」（いた人：Aさん、Bさん、Cさん）
        【決まったこと】
        ・来週の打ち合わせは火曜にする
        """
        let parsed = WorkDigestParser.parse(text, today: today)
        XCTAssertTrue(parsed.found)
        XCTAssertEqual(parsed.day, "2026-11-08")
        // 折り返した行はつなぐ・同じ行は1つだけ
        XCTAssertEqual(parsed.sections.sources, ["営業チーム＞一般「来週の段取り」（いた人：Aさん、Bさん、Cさん）",
                                                 "チャット「見積もりの相談」（いた人：Aさん）"])
        // ほかの見出しはそのまま。並べる順は、出どころが先
        XCTAssertEqual(parsed.sections.decided, ["来週の打ち合わせは火曜にする"])
        XCTAssertEqual(parsed.sections.lists.map(\.title), ["出どころ", "決まったこと"])
        // 見出しと同じ行に書いてあっても読む。別の言い方（出所）も読む
        let oneLine = WorkDigestParser.parse("【出所】チャット「相談」", today: today)
        XCTAssertEqual(oneLine.sections.sources, ["チャット「相談」"])
    }

    func testSourcesAreOptional() throws {
        // 見出しが無ければ nil のまま（前の形と同じ）。箇条書きの中の「出どころ」は見出しにしない
        let parsed = WorkDigestParser.parse(sample + "\n・出どころ: これは見出しではない", today: today)
        XCTAssertNil(parsed.sections.sources)
        XCTAssertEqual(parsed.sections.checks, ["会議室が取れているか", "出どころ: これは見出しではない"])
        // 前の版で保存したもの（sources が無い）も読める
        let old = #"{"decided":["a"],"homework":[],"others":[],"topics":[],"checks":[],"words":["b"]}"#
        let back = try JSONDecoder().decode(WorkDigest.Sections.self, from: Data(old.utf8))
        XCTAssertEqual(back.words, ["b"])
        XCTAssertNil(back.sources)
        // 無いときは、保存する文字にも出ない（前の形のまま）
        let data = try JSONEncoder().encode(WorkDigest.Sections(decided: ["a"]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sources"))
        // 出どころだけのまとめは「空」ではない
        XCTAssertFalse(WorkDigest.Sections(sources: ["チャット「相談」"]).isEmpty)
    }

    // MARK: - 退勤の頃の知らせ（2026-11-10）

    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    func testReminderTime() {
        // today は 12:00。17:30 に出す
        let at = WorkDigestReminder.time(now: today, workedToday: true, hasDigest: false, on: true,
                                         minute: WorkDigestReminder.defaultMinute, calendar: tokyo)
        let parts = at.map { tokyo.dateComponents([.day, .hour, .minute], from: $0) }
        XCTAssertEqual([parts?.day, parts?.hour, parts?.minute], [9, 17, 30])
    }

    func testReminderIsSkipped() {
        let minute = WorkDigestReminder.defaultMinute
        // 設定がオフ・今日は職場の行が無い・もう取り込んだ
        XCTAssertNil(WorkDigestReminder.time(now: today, workedToday: true, hasDigest: false, on: false, minute: minute, calendar: tokyo))
        XCTAssertNil(WorkDigestReminder.time(now: today, workedToday: false, hasDigest: false, on: true, minute: minute, calendar: tokyo))
        XCTAssertNil(WorkDigestReminder.time(now: today, workedToday: true, hasDigest: true, on: true, minute: minute, calendar: tokyo))
        // 時刻を過ぎたあと（12:00 に、11:00 の知らせは出さない。翌日に回さない）
        XCTAssertNil(WorkDigestReminder.time(now: today, workedToday: true, hasDigest: false, on: true, minute: 11 * 60, calendar: tokyo))
        // ちょうど今（30秒より先でなければ出さない）
        XCTAssertNil(WorkDigestReminder.time(now: today, workedToday: true, hasDigest: false, on: true, minute: 12 * 60, calendar: tokyo))
    }

    func testReminderMinuteRoundTripAndBounds() {
        let at = WorkDigestReminder.date(minute: 18 * 60 + 5, now: today, calendar: tokyo)
        XCTAssertEqual(WorkDigestReminder.minute(of: at, calendar: tokyo), 18 * 60 + 5)
        // おかしな数は、その日の中に収める
        let late = WorkDigestReminder.time(now: today, workedToday: true, hasDigest: false, on: true, minute: 99_999, calendar: tokyo)
        let parts = late.map { tokyo.dateComponents([.day, .hour, .minute], from: $0) }
        XCTAssertEqual([parts?.day, parts?.hour, parts?.minute], [9, 23, 59])
        XCTAssertNil(WorkDigestReminder.time(now: today, workedToday: true, hasDigest: false, on: true, minute: -5, calendar: tokyo))
    }

    // MARK: - 宿題の前置き（2026-11-10）

    func testHomeworkLeadIsNotATask() {
        let text = """
        【日付】2026-11-08
        【自分の宿題】
        今日は、次の2つが残っています。
        急ぎのものから書きます。
        ・見積書を送る（Aさんから／11/10まで）
        ・議事録をまとめる
        【決まったこと】
        次のとおりです：
        ・A案にする
        """
        let parsed = WorkDigestParser.parse(text, today: today)
        // 前置きの文は1つにまとめて、まとめには残す
        XCTAssertEqual(parsed.sections.homework, ["今日は、次の2つが残っています。急ぎのものから書きます。",
                                                  "見積書を送る（Aさんから／11/10まで）", "議事録をまとめる"])
        XCTAssertEqual(parsed.homeworkLead, ["今日は、次の2つが残っています。急ぎのものから書きます。"])
        // タスクにするのは、箇条書きの分だけ
        XCTAssertEqual(parsed.homeworkTasks, ["見積書を送る（Aさんから／11/10まで）", "議事録をまとめる"])
        XCTAssertEqual(Pipeline.workDigestTasks(parsed.homeworkTasks, day: "2026-11-08", now: today).map(\.what),
                       ["見積書を送る", "議事録をまとめる"])
        // ほかの見出しの前置きも1つにまとめる（宿題ではないので、目印は付けない）
        XCTAssertEqual(parsed.sections.decided, ["次のとおりです：", "A案にする"])
        // 前置きの無いまとめは、今までどおり
        let usual = WorkDigestParser.parse(sample, today: today)
        XCTAssertEqual(usual.homeworkLead, [])
        XCTAssertEqual(usual.homeworkTasks, usual.sections.homework)
    }

    func testPlainLinesBeforeBulletsStayTasks() {
        // 文になっていない行は、箇条書きの前にあっても宿題
        let parsed = WorkDigestParser.parse("【自分の宿題】\n資料を直す\n表を作る\n・申請を出す", today: today)
        XCTAssertEqual(parsed.sections.homework, ["資料を直す", "表を作る", "申請を出す"])
        XCTAssertEqual(parsed.homeworkLead, [])
        XCTAssertEqual(parsed.homeworkTasks, ["資料を直す", "表を作る", "申請を出す"])
        // 頼んだ人・期限の付いたものは、文になっていても宿題
        let asked = WorkDigestParser.parse("【自分の宿題】\n見積書を送る。（Aさんから／11/10まで）\n・表を作る", today: today)
        XCTAssertEqual(asked.homeworkTasks, ["見積書を送る。（Aさんから／11/10まで）", "表を作る"])
        // 箇条書きが1つも無い見出しは、今までどおり1行ずつ
        let plain = WorkDigestParser.parse("【自分の宿題】\n資料を直す。\n表を作る。", today: today)
        XCTAssertEqual(plain.homeworkTasks, ["資料を直す。", "表を作る。"])
        // 見出しと同じ行の宿題のあとに箇条書きが続いても、宿題のまま
        let sameLine = WorkDigestParser.parse("【自分の宿題】資料を直す\n・表を作る", today: today)
        XCTAssertEqual(sameLine.homeworkTasks, ["資料を直す", "表を作る"])
    }

    func testIsLead() {
        XCTAssertTrue(WorkDigestParser.isLead("今日の分は、次のとおりです。"))
        XCTAssertTrue(WorkDigestParser.isLead("残っているもの："))
        XCTAssertTrue(WorkDigestParser.isLead("Open items:"))
        XCTAssertFalse(WorkDigestParser.isLead("資料を直す"))
        XCTAssertFalse(WorkDigestParser.isLead(""))
        XCTAssertFalse(WorkDigestParser.isLead("見積書を送る。（Aさんから／11/10まで）"))
        XCTAssertFalse(WorkDigestParser.isLead("申請を出す。（今週中まで）"))
    }

    // MARK: - 探す・質問の材料にする（2026-11-10）

    private let older = "【決まったこと】\n・見積もりは来週に回す\n【自分の宿題】\n・Teams の会議を入れる"

    private func entry(_ day: String, _ text: String, id: String) -> WorkDigest.Entry {
        let parsed = WorkDigestParser.parse(text, today: today)
        return WorkDigest.Entry(id: id, day: day, text: text, sections: parsed.found ? parsed.sections : nil,
                                source: .paste, addedAt: today)
    }

    func testDigestLines() {
        let lines = Pipeline.workDigestLines(entry("2026-11-08", sample, id: "a"))
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(lines.first?.heading, "決まったこと")
        XCTAssertEqual(lines.first?.text, "来週の打ち合わせは火曜にする")
        XCTAssertEqual(lines.filter { $0.heading == "自分の宿題" }.count, 2)
        // 決まった形でないまとめは、文を1行ずつ（見出しは空。【日付】の行と空の行は入れない）
        let raw = entry("2026-11-07", "【日付】2026-11-07\nきょうは 会議 が2つあった。\n\n午後は資料づくり。", id: "b")
        let plain = Pipeline.workDigestLines(WorkDigest.Entry(id: "b", day: raw.day, text: raw.text, source: .paste, addedAt: today))
        XCTAssertEqual(plain.map { $0.text }, ["きょうは会議が2つあった。", "午後は資料づくり。"])
        XCTAssertTrue(plain.allSatisfy { $0.heading.isEmpty })
    }

    func testSearchDigests() {
        let a = entry("2026-11-08", sample, id: "a")
        let b = entry("2026-11-07", older, id: "b")
        // 言葉で探す（渡した順＝新しい日から）
        let hits = Pipeline.searchWorkDigests("見積", in: [a, b])
        XCTAssertEqual(hits.map(\.text), ["見積もりは2案で出す", "見積書を送る（Aさんから／11/10まで）", "見積もりは来週に回す"])
        XCTAssertEqual(hits.map(\.day), ["2026-11-08", "2026-11-08", "2026-11-07"])
        XCTAssertEqual(hits.map(\.heading), ["決まったこと", "自分の宿題", "決まったこと"])
        XCTAssertEqual(Set(hits.map(\.id)).count, 3)
        // 空白で区切った言葉は、すべてを含む行。見出しの言葉でも見つかる
        XCTAssertEqual(Pipeline.searchWorkDigests("宿題　見積", in: [a, b]).map(\.text), ["見積書を送る（Aさんから／11/10まで）"])
        XCTAssertEqual(Pipeline.searchWorkDigests("宿題", in: [a, b]).count, 3)
        // 英字の大文字・小文字は区別しない
        XCTAssertEqual(Pipeline.searchWorkDigests("teams", in: [a, b]).map(\.text), ["Teams の会議を入れる"])
        // 同じ日に取り込み直した同じ行は1つだけ
        XCTAssertEqual(Pipeline.searchWorkDigests("見積", in: [a, entry("2026-11-08", sample, id: "c"), b]).count, 3)
        // 上限・空の言葉・無い言葉
        XCTAssertEqual(Pipeline.searchWorkDigests("見積", in: [a, b], limit: 2).count, 2)
        XCTAssertEqual(Pipeline.searchWorkDigests("  ", in: [a, b]), [])
        XCTAssertEqual(Pipeline.searchWorkDigests("どこにも無い言葉", in: [a, b]), [])
    }

    func testDigestMaterialWithCues() {
        let a = entry("2026-11-08", sample, id: "a")
        let b = entry("2026-11-07", older, id: "b")
        // 手がかりのある質問: その言葉を含む行だけ。期間を言ったら、その期間の日だけ
        let one = Pipeline.workDigestMaterial([a, b], keywords: ["見積"], people: [], from: "2026-11-08", to: "2026-11-08",
                                              anyDay: false, budget: 2000)
        XCTAssertEqual(one.days, ["2026-11-08"])
        XCTAssertEqual(one.text, "[2026-11-08 仕事のまとめ]\n【決まったこと】\n・見積もりは2案で出す\n"
                       + "【自分の宿題】\n・見積書を送る（Aさんから／11/10まで）\n\n")
        // 期間を言わなかった質問は、前の日のまとめからも探す
        let any = Pipeline.workDigestMaterial([a, b], keywords: ["見積"], people: [], from: "2026-11-09", to: "2026-11-09",
                                              anyDay: true, budget: 2000)
        XCTAssertEqual(any.days, ["2026-11-08", "2026-11-07"])
        XCTAssertTrue(any.text.contains("見積もりは来週に回す"))
        XCTAssertFalse(any.text.contains("Teams"))
        // 人の名前も手がかり
        let who = Pipeline.workDigestMaterial([a, b], keywords: [], people: ["Aさん"], from: "2026-11-01", to: "2026-11-30",
                                              anyDay: false, budget: 2000)
        XCTAssertEqual(who.days, ["2026-11-08"])
        XCTAssertTrue(who.text.contains("・Aさん: 客先に電話した"))
        XCTAssertFalse(who.text.contains("議事録"))
        // 「仕事」と聞けばまとめの行がすべて、「宿題」と聞けばその見出しの行が当たる
        let work = Pipeline.workDigestMaterial([a, b], keywords: ["仕事"], people: [], from: "2026-11-07", to: "2026-11-07",
                                               anyDay: false, budget: 2000)
        XCTAssertEqual(work.days, ["2026-11-07"])
        XCTAssertTrue(work.text.contains("・見積もりは来週に回す"))
        XCTAssertTrue(work.text.contains("・Teams の会議を入れる"))
        let homework = Pipeline.workDigestMaterial([a, b], keywords: ["宿題"], people: [], from: "2026-11-01", to: "2026-11-30",
                                                   anyDay: false, budget: 2000)
        XCTAssertEqual(homework.days, ["2026-11-08", "2026-11-07"])
        XCTAssertTrue(homework.text.contains("議事録をまとめる"))
        XCTAssertFalse(homework.text.contains("客先に電話した"))
        // 当たる行が無ければ、何も入れない
        let none = Pipeline.workDigestMaterial([a, b], keywords: ["どこにも無い言葉"], people: [], from: "2026-11-01",
                                               to: "2026-11-30", anyDay: true, budget: 2000)
        XCTAssertEqual(none.text, "")
        XCTAssertEqual(none.days, [])
    }

    func testDigestMaterialWithoutCuesAndBudget() {
        let a = entry("2026-11-08", sample, id: "a")
        let b = entry("2026-11-07", older, id: "b")
        // 手がかりが無く、期間を言った質問: その期間のまとめをまるごと
        let day = Pipeline.workDigestMaterial([a, b], keywords: [], people: [""], from: "2026-11-08", to: "2026-11-08",
                                              anyDay: false, budget: 2000)
        XCTAssertEqual(day.days, ["2026-11-08"])
        XCTAssertTrue(day.text.hasPrefix("[2026-11-08 仕事のまとめ]\n【決まったこと】\n・来週の打ち合わせは火曜にする\n"), day.text)
        XCTAssertTrue(day.text.contains("【あとで確かめること】\n・会議室が取れているか\n"))
        XCTAssertFalse(day.text.contains("2026-11-07"))
        // 期間も手がかりも無い質問には入れない
        let nothing = Pipeline.workDigestMaterial([a, b], keywords: [], people: [], from: "2026-11-08", to: "2026-11-08",
                                                  anyDay: true, budget: 2000)
        XCTAssertEqual(nothing.text, "")
        XCTAssertEqual(nothing.days, [])
        // 入る量まで。残りが少なければ、次のまとめは入れない
        let cut = Pipeline.workDigestMaterial([a, b], keywords: ["仕事"], people: [], from: "2026-11-01", to: "2026-11-30",
                                              anyDay: false, budget: 60)
        XCTAssertEqual(cut.text.count, 60)
        XCTAssertEqual(cut.days, ["2026-11-08"])
        // 決まった形でないまとめも、文の行を入れる（見出しは付けない）
        let raw = WorkDigest.Entry(id: "r", day: "2026-11-06", text: "きょうは会議が2つあった。\n午後は資料づくり。", source: .paste,
                                   addedAt: today)
        let plain = Pipeline.workDigestMaterial([raw], keywords: ["会議"], people: [], from: "2026-11-06", to: "2026-11-06",
                                                anyDay: false, budget: 2000)
        XCTAssertEqual(plain.text, "[2026-11-06 仕事のまとめ]\n・きょうは会議が2つあった。\n\n")
    }

    // MARK: - 保存の形

    func testEntryRoundTrip() throws {
        let parsed = WorkDigestParser.parse(sample, today: today)
        let entry = WorkDigest.Entry(day: "2026-11-08", text: sample, sections: parsed.sections, source: .photo,
                                     addedAt: Date(timeIntervalSinceReferenceDate: 1000))
        let data = try JSONEncoder().encode([entry])
        let back = try JSONDecoder().decode([WorkDigest.Entry].self, from: data)
        XCTAssertEqual(back, [entry])
        // 見出しの無いもの（sections が無い）も読める
        let plain = #"[{"id":"x","day":"2026-11-08","text":"メモ","source":"paste","addedAt":0}]"#
        let old = try JSONDecoder().decode([WorkDigest.Entry].self, from: Data(plain.utf8))
        XCTAssertNil(old.first?.sections)
        XCTAssertEqual(old.first?.source, .paste)
    }

    func testCleanKeepsLinesAndDropsExtraBlankLines() {
        XCTAssertEqual(WorkDigestParser.clean("  a  \n\n\n b\n\n"), "a\n\nb")
    }
}

import XCTest
@testable import LifeLog

/// 仕事のまとめ（2026-11-08）の読み方を確かめる。
/// 日付（全角・半角・「/」・無いとき）・見出しで分ける・自分の宿題の分け方・写真の読み取りの崩れ（余計な空白・「・」の揺れ）。
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
        XCTAssertTrue(items.allSatisfy { $0.state == .candidate && $0.work == true && $0.day == "2026-11-08" })
        XCTAssertEqual(items.first?.from, "Aさん")
        XCTAssertEqual(items.first?.due.map { TaskBook.dayFormat.string(from: $0) }, "2026-11-10")
        // 同じまとめをもう一度取り込んでも、似たものとして足さない（帳の add と同じ見分け方）
        let again = Pipeline.workDigestTasks(homework, day: "2026-11-08", now: today)
        for (a, b) in zip(items, again) {
            XCTAssertTrue(TaskBook.similar(a.what, b.what))
        }
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

import XCTest
@testable import LifeLog

/// 聞き取りのヒントに渡す言葉の並べ方と、仕事の成績表（2026-11-10）を確かめる。
/// 1. 言葉の見比べ（大文字小文字・全角半角をそろえる。英字の続きの途中では数えない）
/// 2. 並べ方（ついさっき出た言葉 → 直しの書き方・登録したばかり → 最近よく出た言葉 → 残り。言葉は1つも捨てない）
/// 3. 家の PC に渡る枠と、「先回り」の数
/// 4. 最近の出方の点（7日で半分。テレビの会話・開いたままの会話は数えない。ファイルは別）
/// 5. 仕事の成績表の行と、精度の物差しの「言葉の並べ方」
@MainActor
final class WordHeatTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wordheat-\(UUID().uuidString).json")
    }

    private func talk(_ seconds: TimeInterval, _ text: String, closed: Bool = true, media: String? = nil)
        -> ConversationLog.Conversation {
        let start = t0.addingTimeInterval(seconds)
        var c = ConversationLog.Conversation(start: start, end: start.addingTimeInterval(60), docIndex: 1)
        c.lines = [ConversationLog.Line(time: start, speaker: nil, text: text)]
        c.closed = closed
        c.media = media
        return c
    }

    // MARK: - 1. 言葉の見比べ

    func testKeyFoldsCaseAndWidth() {
        XCTAssertEqual(HintOrder.key("ＡＢＣ"), HintOrder.key("abc"))
        XCTAssertEqual(HintOrder.key(" Abc "), "abc")
    }

    func testShortASCIIWordIsNotCountedInsideAnotherWord() {
        let text = HintOrder.key("Speaker の音がする") as NSString
        XCTAssertFalse(HintOrder.appears(HintOrder.key("SP"), in: text))
        let other = HintOrder.key("次は SP の話です") as NSString
        XCTAssertTrue(HintOrder.appears(HintOrder.key("SP"), in: other))
        // 日本語の言葉は、前後に何が付いていても数える
        let japanese = HintOrder.key("あしたは棚卸しをします") as NSString
        XCTAssertTrue(HintOrder.appears(HintOrder.key("棚卸し"), in: japanese))
        // 数字の前後は数える（「SP2」の SP）。英字の続きだけを外す
        let digits = HintOrder.key("SP2 を見る") as NSString
        XCTAssertTrue(HintOrder.appears(HintOrder.key("SP"), in: digits))
    }

    // MARK: - 2. 並べ方

    func testOrderPutsRecentThenPinnedThenHot() {
        let words = ["いち", "に", "さん", "よん", "ご", "ろく"]
        let heat = [HintOrder.key("よん"): 3.0, HintOrder.key("ご"): 1.0, HintOrder.key("に"): 0.2]
        let out = HintOrder.ordered(words, heat: heat, first: [HintOrder.key("ろく")], recent: [HintOrder.key("さん")],
                                    turn: 0, every: 5)
        // さん（ついさっき）→ ろく（先に出す）→ よん・ご（点の高い順）→ 5個目は残りから → 残り
        XCTAssertEqual(Array(out.prefix(4)), ["さん", "ろく", "よん", "ご"])
        XCTAssertEqual(Set(out), Set(words))
        XCTAssertEqual(out.count, words.count)
    }

    func testEveryFifthSlotComesFromTheRest() {
        let hot = (0..<12).map { "熱い\($0)" }
        let cold = (0..<6).map { "残り\($0)" }
        var heat: [String: Double] = [:]
        for (i, word) in hot.enumerated() { heat[HintOrder.key(word)] = Double(100 - i) }
        let out = HintOrder.ordered(cold + hot, heat: heat, turn: 0, every: 5)
        XCTAssertEqual(out.count, 18)
        XCTAssertTrue(out[4].hasPrefix("残り"))
        XCTAssertTrue(out[9].hasPrefix("残り"))
        XCTAssertTrue(out[0].hasPrefix("熱い"))
        XCTAssertEqual(out[0], "熱い0")
        // 1時間たつと、残りから入れる言葉が替わる
        let later = HintOrder.ordered(cold + hot, heat: heat, turn: 1, every: 5)
        XCTAssertNotEqual(out[4], later[4])
        XCTAssertEqual(Set(later), Set(out))
    }

    func testNothingIsDroppedAndDuplicatesGoLast() {
        let words = ["Alpha", "ベータ", "alpha", "ガンマ", ""]
        let out = HintOrder.ordered(words, heat: [:], turn: 3)
        XCTAssertEqual(out.count, words.count)
        XCTAssertEqual(Array(out.suffix(2)), ["alpha", ""])
        XCTAssertEqual(Set(out.prefix(3)), ["Alpha", "ベータ", "ガンマ"])
    }

    func testColdWordsKeepRegisteredOrderWhenNothingIsHot() {
        let words = ["いち", "に", "さん"]
        XCTAssertEqual(HintOrder.ordered(words, heat: [:], turn: 0), words)
    }

    // MARK: - 3. 渡る枠と先回り

    func testWindowCutsLikeHomePC() {
        let words = (0..<200).map { "言葉\($0)" }
        XCTAssertEqual(HintOrder.window(words, limit: 80).count, 80)
        XCTAssertEqual(HintOrder.window(words, limit: 25), Array(words.prefix(25)))
        // 文字数でも切る
        let long = (0..<10).map { _ in String(repeating: "あ", count: 400) }
        XCTAssertEqual(HintOrder.window(long, limit: 80, chars: 1500).count, 3)
        // 空の言葉と改行のある言葉は飛ばす
        XCTAssertEqual(HintOrder.window(["", "いち", "に\nさん", "よん"], limit: 80), ["いち", "よん"])
    }

    func testReachCountsOnlyNumbers() {
        let words = ["棚卸し", "見積書", "納期", "検収"]
        let r = HintOrder.reach(text: "棚卸しのあとで見積書を出す。棚卸しは来週", words: words,
                                sent: ["見積書", "棚卸し"], registered: ["棚卸し", "納期"])
        XCTAssertEqual(r.heard, 2)
        XCTAssertEqual(r.inSent, 2)
        XCTAssertEqual(r.inRegistered, 1)
        let none = HintOrder.reach(text: "", words: words, sent: words, registered: words)
        XCTAssertEqual(none.heard, 0)
    }

    // MARK: - 4. 最近の出方の点

    func testDecayHalvesInSevenDays() {
        XCTAssertEqual(WordHeat.decay(0), 1, accuracy: 0.0001)
        XCTAssertEqual(WordHeat.decay(7 * 86_400), 0.5, accuracy: 0.0001)
        XCTAssertEqual(WordHeat.decay(14 * 86_400), 0.25, accuracy: 0.0001)
    }

    func testCountSkipsMediaAndOpenTalks() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let heat = WordHeat(url: url)
        let now = t0.addingTimeInterval(4000)
        let talks = [
            talk(0, "棚卸しの話をした"),
            talk(600, "棚卸しと見積書"),
            talk(1200, "テレビで納期の話", media: "テレビ"),
            talk(1800, "検収はまだ", closed: false),
        ]
        heat.count(days: [(day: "2026-11-10", conversations: talks)], words: ["棚卸し", "見積書", "納期", "検収"], now: now)
        let points = heat.heat(now: now)
        XCTAssertEqual(points[HintOrder.key("棚卸し")] ?? 0, 2, accuracy: 0.05)
        XCTAssertEqual(points[HintOrder.key("見積書")] ?? 0, 1, accuracy: 0.05)
        XCTAssertNil(points[HintOrder.key("納期")])
        XCTAssertNil(points[HintOrder.key("検収")])
        XCTAssertEqual(heat.hotCount(now: now), 2)
        // 同じ会話を2回渡しても、2回は数えない
        heat.count(days: [(day: "2026-11-10", conversations: talks)], words: ["棚卸し", "見積書"], now: now)
        XCTAssertEqual(heat.heat(now: now)[HintOrder.key("棚卸し")] ?? 0, 2, accuracy: 0.05)
        // ファイルから読み直しても同じ
        let again = WordHeat(url: url)
        XCTAssertEqual(again.heat(now: now)[HintOrder.key("棚卸し")] ?? 0, 2, accuracy: 0.05)
        XCTAssertFalse(again.needsCatchUp(now: now))
        XCTAssertTrue(again.needsCatchUp(now: now.addingTimeInterval(3 * 86_400)))
    }

    func testOrderedUsesHeatPinnedAndJustHeard() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let heat = WordHeat(url: url)
        let now = t0.addingTimeInterval(4000)
        let words = ["いち", "に", "棚卸し", "見積書", "納期", "検収"]
        heat.count(days: [(day: "2026-11-10", conversations: [talk(0, "見積書を出す"), talk(600, "見積書の直し")])],
                   words: words, now: now)
        heat.noteHeard("検収の日を決める", words: words, at: now)
        let out = heat.ordered(words, pinned: ["納期"], now: now.addingTimeInterval(60))
        XCTAssertEqual(Array(out.prefix(3)), ["検収", "納期", "見積書"])
        XCTAssertEqual(Set(out), Set(words))
        // 1時間たつと「ついさっき」ではなくなる
        let later = heat.ordered(words, pinned: ["納期"], now: now.addingTimeInterval(2 * 3_600))
        XCTAssertEqual(Array(later.prefix(2)), ["納期", "見積書"])
        XCTAssertEqual(Set(later), Set(words))
    }

    func testEmptyHeatFileStartsClean() {
        let heat = WordHeat(url: tempURL())
        XCTAssertTrue(heat.needsCatchUp(now: t0))
        XCTAssertEqual(heat.hotCount(now: t0), 0)
        XCTAssertEqual(heat.ordered(["いち", "に"], now: t0).count, 2)
    }

    // MARK: - 5. 成績表と物差し

    func testWorkRowsShowOnlyNumbers() {
        XCTAssertTrue(Tally.workRows([:]).isEmpty)
        let rows = Tally.workRows(["work.lines": 200, "work.unsure": 50, "other.lines": 100, "other.unsure": 10,
                                   "reach.heard": 40, "reach.in": 30, "reach.inOld": 10, "wordfix.work": 3])
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].value.contains("200 行"))
        XCTAssertTrue(rows[0].value.contains("25%"))
        XCTAssertTrue(rows[0].value.contains("10%"))
        XCTAssertTrue(rows[1].value.contains("75%"))
        XCTAssertTrue(rows[1].value.contains("25%"))
        XCTAssertTrue(rows[2].value.contains("仕事 3"))
    }

    func testWorkCardIsNewestFirstAndSkipsDaysWithoutWork() {
        let rows = Tally.workCard([
            "2026-11-08": ["other.lines": 50],
            "2026-11-09": ["work.lines": 100, "work.unsure": 20],
            "2026-11-10": ["work.lines": 10, "work.unsure": 1, "reach.heard": 4, "reach.in": 2, "reach.inOld": 1],
        ])
        XCTAssertEqual(rows.map { $0.label }, ["2026-11-10", "2026-11-09"])
        XCTAssertTrue(rows[0].value.contains("50%"))
        XCTAssertTrue(rows[1].value.contains("20%"))
    }

    func testBenchmarkTriesWordOrderEveryOtherNightUntilEnough() {
        let all = Benchmark.Variant.allCases
        XCTAssertTrue(all.contains(.registeredOrder))
        // まだ30問たまっていないあいだは、1晩おきに並べ方を試す
        XCTAssertEqual(Benchmark.variant(night: 0, available: all, scores: [:]), .registeredOrder)
        XCTAssertNotEqual(Benchmark.variant(night: 1, available: all, scores: [:]), .registeredOrder)
        XCTAssertEqual(Benchmark.variant(night: 2, available: all, scores: [:]), .registeredOrder)
        XCTAssertNotEqual(Benchmark.variant(night: 1, available: all, scores: [:]),
                          Benchmark.variant(night: 3, available: all, scores: [:]))
        // 30問たまったら、ほかの設定と同じ順番で回す
        var enough = Benchmark.Score()
        enough.count = Benchmark.need
        let scores = [Benchmark.Variant.registeredOrder.rawValue: enough]
        XCTAssertEqual((0..<all.count).map { Benchmark.variant(night: $0, available: all, scores: scores) }, all.map { Optional($0) })
        XCTAssertNil(Benchmark.variant(night: 0, available: [], scores: [:]))
    }

    func testWordOrderGoesBackOnlyWhenRegisteredOrderIsClearlyBetter() {
        // 「今の設定」の側が「いま出そうな順」、「試す設定」の側が登録の順
        var score = Benchmark.Score()
        score.count = 30
        score.chars = 1000
        score.baseErrors = 100
        score.variantErrors = 85
        XCTAssertEqual(Benchmark.decision(score), true)
        score.variantErrors = 110
        XCTAssertEqual(Benchmark.decision(score), false)
        score.variantErrors = 95
        XCTAssertNil(Benchmark.decision(score))
        score.count = 29
        score.variantErrors = 50
        XCTAssertNil(Benchmark.decision(score))
    }

    func testOldBenchmarkPointsStillDecodeAndWorkRowNeedsWorkLines() throws {
        // 前の記録（仕事の行の項目が無い）も読める
        let old = #"{"day": 0, "rate": 0.12, "count": 10}"#.data(using: .utf8)!
        let point = try JSONDecoder().decode(Benchmark.Point.self, from: old)
        XCTAssertNil(point.workRate)
        XCTAssertNil(Benchmark.workRow([point]))
        var work = Benchmark.Point(day: t0, rate: 0.1, count: 12)
        work.workRate = 0.2
        work.workCount = 5
        let row = Benchmark.workRow([point, work])
        XCTAssertEqual(row?.label, "仕事の行の文字の誤り")
        XCTAssertTrue(row?.value.contains("20.0%") ?? false)
        XCTAssertTrue(row?.value.contains("5 問") ?? false)
    }
}

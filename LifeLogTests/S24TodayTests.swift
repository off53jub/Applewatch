import XCTest
@testable import LifeLog

/// s24 の 形1・形2・形3・形5・形8・減12（S24Rules.swift・Shared/Design/S24DesignRules.swift）
final class S24TodayTests: XCTestCase {
    // MARK: 形1 棚卸し

    func testOldLayoutIsKeptWhenFoldIsOff() {
        // 前の並び（s20〜s23）: 昼は上に 8 種・畳んだ所に 7 種
        let day = S24Today.layout(fold: false, part: .day)
        XCTAssertEqual(day.top, [.hero, .holiday, .answer, .alerts, .pcFeature, .s22, .s23, .prep])
        XCTAssertEqual(day.more, [.promises, .checkups, .replies, .nightMood, .knowMe, .morningBrief, .draft])
        XCTAssertEqual(S24Today.layout(fold: false, part: .morning).top.count, 10)
        XCTAssertEqual(S24Today.layout(fold: false, part: .night).top.count, 9)
        XCTAssertFalse(day.top.contains(.ask))
        // 今日の記録を入れて 17 種
        XCTAssertEqual(S24Today.cardKinds(fold: false), 17)
    }

    func testFoldShowsThreeCardsAndKeepsEverything() {
        for part in [DayPart.morning, .day, .night] {
            let old = S24Today.layout(fold: false, part: part)
            let new = S24Today.layout(fold: true, part: part)
            XCTAssertEqual(new.top, [.hero, .answer, .ask, .alerts])
            // なくしたカードは無い（畳んだだけ）
            let before = Set(old.top + old.more)
            let after = Set(new.top + new.more)
            XCTAssertTrue(before.isSubset(of: after), "\(part)")
            // 同じカードを 2 回出さない
            XCTAssertEqual(new.top.count + new.more.count, after.count, "\(part)")
        }
    }

    // MARK: 形3 今日の 1 問

    func testAskPicksOneAndSaysDoneWhenEmpty() {
        XCTAssertEqual(S24Today.pickAsk(foldOffer: [], review: [], know: [], missed: 0), .nothing)
        XCTAssertEqual(S24Today.pickAsk(foldOffer: [], review: [], know: [], missed: 2), .missed)
        XCTAssertEqual(S24Today.pickAsk(foldOffer: [], review: [], know: [(id: "k1", text: "苦手なことは？")], missed: 2),
                       .know(id: "k1", text: "苦手なことは？"))
        XCTAssertEqual(S24Today.pickAsk(foldOffer: [], review: [(id: "r1", question: "ラーメン？"), (id: "r2", question: "x")],
                                        know: [(id: "k1", text: "t")], missed: 1),
                       .review(id: "r1", question: "ラーメン？"))
        XCTAssertEqual(S24Today.pickAsk(foldOffer: ["speaking"], review: [(id: "r1", question: "q")], know: [], missed: 0),
                       .fold(["speaking"]))
        XCTAssertEqual(S24Today.noneText, "今日は聞くことはありません")
    }

    // MARK: 形2 よく触る設定

    func testTopSettingsUseCountsThenInitialAsProvisional() {
        let available = ["standbyOn", "skipSilence", "homePCWatchDirect", "speakerLabels", "correct"]
        let empty = S24Settings.top(available, sums: [:])
        XCTAssertEqual(empty.ids, S24Settings.initial)
        XCTAssertTrue(empty.provisional)

        let sums = [S24Settings.tallyName("correct"): 5, S24Settings.tallyName("speakerLabels"): 2, S24Settings.tallyName("skipSilence"): 2]
        let counted = S24Settings.top(available, sums: sums)
        XCTAssertEqual(counted.ids, ["correct", "skipSilence", "speakerLabels"])  // 同じ数なら一覧の順
        XCTAssertFalse(counted.provisional)

        let one = S24Settings.top(available, sums: [S24Settings.tallyName("correct"): 1])
        XCTAssertEqual(one.ids, ["correct", "standbyOn", "homePCWatchDirect"])
        XCTAssertTrue(one.provisional)
    }

    func testChangedSettings() {
        XCTAssertEqual(S24Settings.changed(before: ["a": true, "b": false, "c": true], after: ["a": false, "b": false, "c": true]), ["a"])
        XCTAssertEqual(S24Settings.changed(before: [:], after: ["a": true]), [])
    }

    // MARK: 形5・減12

    func testEntriesLimitToFiveByUse() {
        let keys = ["a", "b", "c", "d", "e", "f", "g"]
        let opens = ["g": 9, "f": 3, "a": 1]
        let split = S24Entries.split(keys, opens: opens, folded: [], limitOn: true)
        XCTAssertEqual(split.shown, ["a", "b", "c", "f", "g"])  // 元の並びのまま・よく開く 5 つ
        XCTAssertEqual(split.other, ["d", "e"])
        // 切ると前の並び（畳んだものだけ「ほか」）
        let off = S24Entries.split(keys, opens: opens, folded: ["b"], limitOn: false)
        XCTAssertEqual(off.shown, ["a", "c", "d", "e", "f", "g"])
        XCTAssertEqual(off.other, ["b"])
        // 5 つ以下なら畳んだものだけ
        let small = S24Entries.split(["a", "b", "c"], opens: [:], folded: ["c"], limitOn: true)
        XCTAssertEqual(small.shown, ["a", "b"])
        XCTAssertEqual(small.other, ["c"])
    }

    func testUnusedCandidatesNeedThirtyDaysOfCounting() {
        let keys: [(key: String, since: String)] = [("speaking", "2026-11-06"), ("facts", "2026-11-24"), ("ask", "2026-11-06")]
        let sums = ["screen.ask": 4]
        XCTAssertEqual(S24Entries.unusedCandidates(keys, sums30: sums, today: "2026-12-06", folded: []), ["speaking"])
        XCTAssertEqual(S24Entries.unusedCandidates(keys, sums30: sums, today: "2026-12-06", folded: ["speaking"]), [])
        XCTAssertEqual(S24Entries.unusedCandidates(keys, sums30: [:], today: "2026-12-24", folded: []), ["speaking", "facts", "ask"])
        XCTAssertEqual(S24Entries.daysBetween("2026-11-06", "2026-12-06"), 30)
    }

    func testOfferOnlyOnceFromDecemberSixth() {
        XCTAssertFalse(S24Entries.shouldOffer(today: "2026-12-05", offeredDay: nil, answered: false, candidates: ["a"]))
        XCTAssertTrue(S24Entries.shouldOffer(today: "2026-12-06", offeredDay: nil, answered: false, candidates: ["a"]))
        XCTAssertTrue(S24Entries.shouldOffer(today: "2026-12-06", offeredDay: "2026-12-06", answered: false, candidates: ["a"]))
        XCTAssertFalse(S24Entries.shouldOffer(today: "2026-12-07", offeredDay: "2026-12-06", answered: false, candidates: ["a"]))
        XCTAssertFalse(S24Entries.shouldOffer(today: "2026-12-06", offeredDay: nil, answered: true, candidates: ["a"]))
        XCTAssertFalse(S24Entries.shouldOffer(today: "2026-12-06", offeredDay: nil, answered: false, candidates: []))
    }

    // MARK: 形8 色の役割

    func testThreeRolesAndQuestionsHaveNoColor() {
        XCTAssertEqual(S24Alerts.role(.signExpiry), .act)
        XCTAssertEqual(S24Alerts.role(.noLogin), .act)
        XCTAssertEqual(S24Alerts.role(.held), .wait)
        XCTAssertEqual(S24Alerts.role(.stale), .wait)
        XCTAssertEqual(LLRole.of(.act), .act)
        XCTAssertEqual(LLRole.of(.wait), .wait)
        XCTAssertEqual(LLRole.of(.claude), .machine)
        // 知らせの役割に「問い」は無い（問いには色を付けない）
        XCTAssertFalse(S24Alerts.Kind.allCases.map(S24Alerts.role).contains(.ask))
    }
}

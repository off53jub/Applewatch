import XCTest
@testable import LifeLog

/// s26 の A3（S26D）: 絵2・絵3・絵4・絵5・絵6・絵7・絵8 の決まり（Shared/Design/S26DRules.swift・S26DCostViews.swift・S26DTrends.swift）
final class S26DTests: XCTestCase {
    // MARK: 絵3 費用の棒

    func testMeterFraction() {
        XCTAssertEqual(S26DMeterRules.fraction(used: 0.3, cap: 1.0) ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(S26DMeterRules.fraction(used: 2.0, cap: 1.0), 1)
        XCTAssertNil(S26DMeterRules.fraction(used: 0.3, cap: nil))
        XCTAssertNil(S26DMeterRules.fraction(used: 0.3, cap: 0))
        XCTAssertEqual(S26DMeterRules.percentText(0.456), "46%")
        XCTAssertEqual(S26DMeterRules.percentText(1.7), "100%")
    }

    func testCostGroupsPutRestingBelowAndUseTodayCap() {
        let rows = [
            CostToday(purpose: "headline", usd: 0.10, cap: 1.0),
            CostToday(purpose: "today-plan", usd: 0.50, cap: 0.50, effect: "今日の三つは朝の分のまま"),
            CostToday(purpose: "misheard", usd: 0.40, cap: 0.50),
            CostToday(purpose: "asr-judge", usd: 0, cap: nil, stopped: true),
            // 毎朝決め直した今日の上限（cap_today）は cap より先に効く
            CostToday(purpose: "night-review", usd: 0.60, cap: 0.50, cap_today: 1.20),
        ]
        let g = S26DCostRules.groups(rows)
        XCTAssertEqual(g.running.map(\.purpose), ["misheard", "night-review", "headline"])
        XCTAssertEqual(g.resting.map(\.purpose), ["today-plan"])
        XCTAssertEqual(g.stopped.map(\.purpose), ["asr-judge"])
        XCTAssertFalse(rows[4].capped)
        XCTAssertEqual(rows[4].capNow, 1.20)
    }

    func testCostTexts() {
        let capped = CostToday(purpose: "today-plan", usd: 0.5, cap: 0.5, effect: "  今日の三つは朝の分のまま ")
        XCTAssertEqual(S26DCostRules.effectLine(capped), "今日の三つは朝の分のまま")
        XCTAssertEqual(S26DCostRules.effectLine(CostToday(purpose: "x", usd: 1, cap: 1)), S26DCostRules.defaultEffect)
        XCTAssertEqual(S26DCostRules.amountText(capped), "$0.50 / $0.50")
        XCTAssertEqual(S26DCostRules.amountText(CostToday(purpose: "x", usd: 0.2)), "$0.20（上限なし）")
        XCTAssertNil(S26DCostRules.capNote(capped))
        XCTAssertNotNil(S26DCostRules.capNote(CostToday(purpose: "x", usd: 0, cap: 0.5, cap_today: 1.0)))
        XCTAssertTrue(S26DCostRules.restTitle.contains("0 時に戻る"))
    }

    func testCostsFeedReadsEffectAndCapToday() {
        let json = #"""
        {"available": true, "month": "2026-11", "month_usd": 26.98, "projected_usd": 33, "monthly_usd": 100,
         "today": [{"purpose": "today-plan", "usd": 0.5, "cap": 0.5, "stopped": false, "effect": "今日の三つは朝の分のまま", "cap_today": 0.8},
                   {"purpose": "headline", "usd": 0.1, "cap": 1.0, "stopped": false}],
         "month_by_purpose": []}
        """#
        let feed = SettleFeeds.decodeCosts(Data(json.utf8))
        XCTAssertEqual(feed?.today.first?.effect, "今日の三つは朝の分のまま")
        XCTAssertEqual(feed?.today.first?.cap_today, 0.8)
        XCTAssertEqual(feed?.today.first?.capped, false)
        XCTAssertNil(feed?.today.last?.effect)
        XCTAssertNil(feed?.today.last?.cap_today)
    }

    // MARK: 絵4 線のグラフ

    func testQuantileAndBand() {
        XCTAssertEqual(S26DTrendRules.quantile([1, 2, 3, 4, 5], 0.5), 3)
        XCTAssertEqual(S26DTrendRules.quantile([1, 2, 3, 4, 5], 0.25), 2)
        XCTAssertNil(S26DTrendRules.quantile([], 0.5))
        XCTAssertNil(S26DTrendRules.band([1, 2, 3, 4]))  // 日数が足りない
        XCTAssertNil(S26DTrendRules.band([2, 2, 2, 2, 2]))  // 幅が 0
        let band = S26DTrendRules.band([5, 1, 4, 2, 3])
        XCTAssertEqual(band?.low, 2)
        XCTAssertEqual(band?.high, 4)
    }

    func testDomainIsZeroBasedExceptWeight() {
        let counts = S26DTrendRules.domain([0, 10, 20], zeroBased: true)
        XCTAssertEqual(counts.low, 0)
        XCTAssertEqual(counts.high, 23, accuracy: 1e-9)
        XCTAssertEqual(S26DTrendRules.domain([0, 0], zeroBased: true).high, 1)
        XCTAssertEqual(S26DTrendRules.domain([], zeroBased: true).high, 1)
        let weight = S26DTrendRules.domain([64.0, 65.0], zeroBased: false)
        XCTAssertEqual(weight.low, 63.5, accuracy: 1e-9)
        XCTAssertEqual(weight.high, 65.5, accuracy: 1e-9)
    }

    func testSummary() {
        let values: [Double] = Array(repeating: 2, count: 7) + Array(repeating: 4, count: 7)
        XCTAssertEqual(S26DTrendRules.summary(values, unit: "時間", digits: 1), "直近 7 日の平均 4 時間（その前の 7 日 2）")
        XCTAssertEqual(S26DTrendRules.summary([1, 3], unit: "", digits: 0), "直近 7 日の平均 2")
        XCTAssertEqual(S26DTrendRules.summary([], unit: "回", digits: 0), "まだ数がありません")
        XCTAssertEqual(S26DTrendRules.number(12792, digits: 0), "12,792")
    }

    // MARK: 絵5 月の 1 枚

    func testMonthTilesHaveNoMoneyAndSkipMissingSteps() {
        let tiles = S26DMonthRules.tiles(recordedHours: 123.46, talks: 80, stepsPerDay: nil, ramen: 3)
        XCTAssertEqual(tiles.map(\.title), ["録れた時間", "会話", "ラーメン（仮）"])
        XCTAssertEqual(tiles.first?.value, "123.5")
        XCTAssertFalse(tiles.contains { $0.unit == "円" })
        XCTAssertEqual(S26DMonthRules.tiles(recordedHours: 0, talks: 0, stepsPerDay: 8000.4, ramen: -1).count, 4)
        var c = DateComponents()
        c.year = 2026
        c.month = 11
        c.day = 25
        let date = Calendar.current.date(from: c) ?? .now
        XCTAssertEqual(S26DMonthRules.title(date), "2026 年 11 月")
    }

    // MARK: 絵2 色の役割

    func testRoleFromStatus() {
        XCTAssertEqual(S26DRoleRules.role(status: "broken"), .act)
        XCTAssertEqual(S26DRoleRules.role(status: "capped"), .wait)
        XCTAssertEqual(S26DRoleRules.role(status: "live"), .machine)
        XCTAssertEqual(S26DRoleRules.role(status: "知らない"), .machine)
    }

    // MARK: 絵6 日なた

    func testSunMakesTextDarkerAndBackgroundWhite() {
        let bg: UInt32 = 0xF3F6FB
        XCTAssertEqual(LLSun.adjust(bg), 0xFFFFFF)
        XCTAssertEqual(LLSun.adjust(0xE9EEF6), 0xE9EEF6)  // 面2 は面と分かれるよう、そのまま
        for text: UInt32 in [0x0E1726, 0x55657F, 0x11719F, 0x985C0C, 0xB8403F, 0x1E7952] {
            let before = LLSun.contrast(text, bg)
            let after = LLSun.contrast(LLSun.adjust(text), 0xFFFFFF)
            XCTAssertGreaterThan(after, before, String(format: "%06X", text))
            XCTAssertGreaterThanOrEqual(after, 4.5, String(format: "%06X", text))
        }
    }

    // MARK: 絵7 震え

    func testArrivedBuzzOnlyAfterFirstLoad() {
        XCTAssertFalse(S26DHapticRules.shouldBuzzArrived(oldCount: 0, freshCount: 3, on: true))
        XCTAssertTrue(S26DHapticRules.shouldBuzzArrived(oldCount: 2, freshCount: 1, on: true))
        XCTAssertFalse(S26DHapticRules.shouldBuzzArrived(oldCount: 2, freshCount: 0, on: true))
        XCTAssertFalse(S26DHapticRules.shouldBuzzArrived(oldCount: 2, freshCount: 1, on: false))
        // 一覧に全部の型がある
        XCTAssertEqual(Set(S26DHapticRules.table.map(\.haptic)), Set(LLHaptic.allCases))
    }

    // MARK: 絵8 ウィジェット

    func testWidgetNames() {
        XCTAssertEqual(S26DWidgetRules.shortName(kind: "com.off53jub.lifelog.launcher"), "launcher")
        XCTAssertEqual(S26DWidgetRules.installedName(kind: "com.off53jub.lifelog.launcher", family: "systemSmall"),
                       "s26d.widget.launcher.systemSmall")
        XCTAssertEqual(S26DWidgetRules.source(of: URL(string: "lifelog://today?w=band")!), "band")
        XCTAssertNil(S26DWidgetRules.source(of: URL(string: "lifelog://today")!))
        XCTAssertNil(S26DWidgetRules.source(of: URL(string: "https://example.com/?w=band")!))
        // 印を付けても行き先は変わらない
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://today?w=band")!), .tab(.today))
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://tasks?w=tasks")!), .tab(.tasks))
    }
}

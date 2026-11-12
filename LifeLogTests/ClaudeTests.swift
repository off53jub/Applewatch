import XCTest
@testable import LifeLog

/// Claude（家の PC 経由。2026-11-13。Claude.swift）の、頼むかの決まり・家の PC の答えの番号・今月使った額の読み方。
@MainActor
final class ClaudeTests: XCTestCase {
    override func tearDown() {
        ClaudeRoute.resetPauses()
        super.tearDown()
    }

    private func route(on: Bool = true, forWork: Bool = true, offered: Bool = true, sensitive: Bool = false,
                       bench: Bool = false, forceLocal: Bool = false, localAlways: Bool = false,
                       paused: Bool = false, workPaused: Bool = false) -> Bool {
        ClaudeRoute.shouldTry(useClaude: on, forWork: forWork, offered: offered, sensitive: sensitive,
                              bench: bench, forceLocal: forceLocal, localAlways: localAlways,
                              paused: paused, workPaused: workPaused)
    }

    // MARK: - 頼むかの決まり

    func testRoutesToClaudeWhenOnAndOffered() {
        XCTAssertTrue(route())
        XCTAssertFalse(route(on: false))
        XCTAssertFalse(route(offered: false))
    }

    func testWorkFollowsTheWorkSetting() {
        XCTAssertTrue(route(sensitive: true))
        XCTAssertFalse(route(forWork: false, sensitive: true))
        // 職場でない会話は「職場の会話も Claude で」に関係なく頼む
        XCTAssertTrue(route(forWork: false, sensitive: false))
        // 職場の会話だけ止めている間（403 のあと）
        XCTAssertFalse(route(sensitive: true, workPaused: true))
        XCTAssertTrue(route(sensitive: false, workPaused: true))
    }

    func testNeverForBenchSecondOpinionOrAlwaysLocal() {
        XCTAssertFalse(route(bench: true))
        XCTAssertFalse(route(forceLocal: true))
        XCTAssertFalse(route(localAlways: true))
        XCTAssertFalse(route(paused: true))
        XCTAssertFalse(route(sensitive: true, paused: true))
    }

    // MARK: - 家の PC の答えの番号

    func testFailureFromStatus() {
        XCTAssertNil(ClaudeFailure.from(status: 200, data: Data()))
        let capped = Data(#"{"error": "今月の上限に達しました", "month_usd": 100.2, "cap_usd": 100}"#.utf8)
        XCTAssertEqual(ClaudeFailure.from(status: 402, data: capped), .capped(spent: 100.2, cap: 100))
        XCTAssertEqual(ClaudeFailure.from(status: 402, data: Data()), .capped(spent: nil, cap: nil))
        XCTAssertEqual(ClaudeFailure.from(status: 503, data: Data(#"{"error": "Claude の鍵がありません"}"#.utf8)), .noKey)
        XCTAssertEqual(ClaudeFailure.from(status: 422, data: Data(#"{"error": "断られました", "refusal": true}"#.utf8)), .refused)
        XCTAssertEqual(ClaudeFailure.from(status: 403, data: Data()), .workNotAllowed)
        XCTAssertEqual(ClaudeFailure.from(status: 500, data: Data(#"{"error": "なにか"}"#.utf8)), .server(status: 500, reason: "なにか"))
        XCTAssertEqual(ClaudeFailure.from(status: 404, data: Data("not json".utf8)), .server(status: 404, reason: "HTTP 404"))
    }

    func testTallyKeysAndPauses() {
        XCTAssertNil(ClaudeFailure.notReady.tallyKey)
        XCTAssertEqual(ClaudeFailure.capped(spent: nil, cap: nil).tallyKey, "claude.capped")
        XCTAssertEqual(ClaudeFailure.refused.tallyKey, "claude.failed")
        XCTAssertEqual(ClaudeFailure.noKey.tallyKey, "claude.failed")
        XCTAssertEqual(ClaudeFailure.refused.pause.all, 0)
        XCTAssertEqual(ClaudeFailure.unreadable.pause.all, 0)
        XCTAssertEqual(ClaudeFailure.workNotAllowed.pause.all, 0)
        XCTAssertGreaterThan(ClaudeFailure.workNotAllowed.pause.work, 0)
        XCTAssertGreaterThan(ClaudeFailure.capped(spent: nil, cap: nil).pause.all, 0)
    }

    func testPauseWindow() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        ClaudeRoute.resetPauses()
        XCTAssertFalse(ClaudeRoute.paused(now: t).all)
        ClaudeRoute.note(.refused, now: t)
        XCTAssertFalse(ClaudeRoute.paused(now: t).all)
        ClaudeRoute.note(.server(status: 0, reason: "x"), now: t)
        XCTAssertTrue(ClaudeRoute.paused(now: t.addingTimeInterval(60)).all)
        XCTAssertFalse(ClaudeRoute.paused(now: t.addingTimeInterval(121)).all)
        ClaudeRoute.note(.workNotAllowed, now: t)
        let p = ClaudeRoute.paused(now: t.addingTimeInterval(600))
        XCTAssertFalse(p.all)
        XCTAssertTrue(p.work)
        ClaudeRoute.resetPauses()
        XCTAssertFalse(ClaudeRoute.paused(now: t.addingTimeInterval(600)).work)
    }

    func testTimeoutRange() {
        XCTAssertEqual(ClaudeRoute.timeout(maxWait: 20), 40)
        XCTAssertEqual(ClaudeRoute.timeout(maxWait: 30), 60)
        XCTAssertEqual(ClaudeRoute.timeout(maxWait: 90), 180)
        XCTAssertEqual(ClaudeRoute.timeout(maxWait: 600), 180)
    }

    // MARK: - 答えと今月使った額

    func testReplyDecoding() throws {
        let data = Data(#"{"text": "{\"title\": \"打ち合わせ\"}", "model": "claude-haiku-5-5", "usd": 0.0012, "month_usd": 12.4, "cap_usd": 100}"#.utf8)
        let reply = try JSONDecoder().decode(ClaudeReply.self, from: data)
        XCTAssertEqual(LocalModel.parse(reply.text)?["title"] as? String, "打ち合わせ")
        XCTAssertEqual(reply.monthUSD, 12.4)
        XCTAssertEqual(reply.capUSD, 100)
    }

    func testUsageDecodingAndText() throws {
        let data = Data(#"""
        {"available": true, "month": "2026-11", "month_usd": 12.4, "cap_usd": 100, "calls": 321,
         "by_purpose": {"correct": 2.5, "headline": 6.1, "digest.daily": 3.8, "unused": 0},
         "by_who": {"pc": 8.6, "mothership": 3.8}}
        """#.utf8)
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: data)
        XCTAssertTrue(usage.available)
        XCTAssertEqual(usage.month, "2026-11")
        XCTAssertEqual(usage.calls, 321)
        XCTAssertEqual(usage.spendText, "$12.40 / $100")
        XCTAssertEqual(usage.purposeRows.map(\.label), ["会話の見出しと要点", "digest.daily", "誤変換の直し"])
        XCTAssertEqual(usage.whoText, "アプリから $8.60・母艦 $3.80")
    }

    func testUsageToleratesMissingAndBadFields() throws {
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data(#"{"available": false, "month_usd": "x", "by_purpose": [1]}"#.utf8))
        XCTAssertFalse(usage.available)
        XCTAssertEqual(usage.monthUSD, 0)
        XCTAssertTrue(usage.purposeRows.isEmpty)
        XCTAssertEqual(usage.whoText, "")
        XCTAssertEqual(ClaudeUsage.dollars(99.5, whole: true), "$99.50")
        XCTAssertEqual(ClaudeUsage.dollars(100, whole: true), "$100")
    }

    // MARK: - 数える帳

    func testTallyReportShowsClaude() {
        let rows = Tally.report(["claude.ok": 18, "claude.work": 5, "claude.failed": 2])
        let row = rows.first { $0.label == "Claude（家の PC 経由）" }
        XCTAssertEqual(row?.value, "作れた 18（90%）（うち職場 5）・頼めずほかで作った 2")
        XCTAssertEqual(row?.ok, true)
        XCTAssertFalse(Tally.report([:]).contains { $0.label == "Claude（家の PC 経由）" })
        XCTAssertTrue(FeatureProof.evidenceKeys.contains("claude.ok"))
    }
}

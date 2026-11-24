import XCTest
@testable import LifeLog

/// s25 の A2（S25URules.swift）: 大1 引き算の版・大2 機能の数（K5）・堅3 時計の版・早1・早3 段ごとの待ち・片3 オフのまま
final class S25UTests: XCTestCase {
    // MARK: 大1

    func testSimpleShowsAboutAThirdOfSettings() {
        let before = S25USimple.visibleRows(S25USimple.settings, simple: false)
        let after = S25USimple.visibleRows(S25USimple.settings, simple: true)
        XCTAssertGreaterThan(before, 0)
        // 3 分の 1 まで（切り上げ）
        XCTAssertLessThanOrEqual(after * 3, before + 2, "設定 \(after) / \(before)")
        let checkBefore = S25USimple.visibleRows(S25USimple.check, simple: false)
        let checkAfter = S25USimple.visibleRows(S25USimple.check, simple: true)
        XCTAssertLessThanOrEqual(checkAfter * 3, checkBefore + 2, "点検 \(checkAfter) / \(checkBefore)")
    }

    func testNothingIsLost() {
        for items in [S25USimple.settings, S25USimple.check, S25USimple.lookBack] {
            XCTAssertTrue(S25USimple.nothingLost(items))
            // 同じ id を 2 回使わない
            XCTAssertEqual(Set(items.map(\.id)).count, items.count)
            // 前の並びでは「ほか」は空・新しい入口は出さない
            XCTAssertTrue(S25USimple.other(items, simple: false).isEmpty)
            XCTAssertFalse(S25USimple.shown(items, simple: false).contains("otherLink"))
        }
        // 戻すスイッチはどちらの並びにもある
        XCTAssertTrue(S25USimple.shown(S25USimple.settings, simple: true).contains("simpleSwitch"))
        XCTAssertTrue(S25USimple.shown(S25USimple.settings, simple: false).contains("simpleSwitch"))
        // 報告の棚は引き算の版でもいつもの所（大12・大16 は報告の棚で読む）
        XCTAssertTrue(S25USimple.shown(S25USimple.check, simple: true).contains("reports"))
    }

    func testMoveTableHasEveryItem() {
        let table = S25USimple.moveTable()
        let count = S25USimple.settings.count + S25USimple.check.count + S25USimple.lookBack.count
        XCTAssertEqual(table.split(separator: "\n").count, count + 2)
        XCTAssertTrue(table.contains("休日"))
    }

    // MARK: 大2 K5

    func testThirtyOneFeatures() {
        XCTAssertEqual(S25UFeatures.all.count, 31)
        XCTAssertEqual(Set(S25UFeatures.all.map(\.slug)).count, 31)
        XCTAssertEqual(S25UFeatures.all.filter { $0.slug.hasPrefix("app-") }.count, 13)
        // 1 つの数の名前は 1 つの機能にだけ
        let names = S25UFeatures.all.flatMap(\.names)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testSlugForTally() {
        XCTAssertEqual(S25UFeatures.slug(for: "screen.goodThings"), "app-good")
        XCTAssertEqual(S25UFeatures.slug(for: "work.lines"), "app-record")
        XCTAssertEqual(S25UFeatures.slug(for: "s23.promise.today.add"), "app-tasks")
        XCTAssertEqual(S25UFeatures.slug(for: "notice.opened.phone-stopped"), "app-stop-alert")
        XCTAssertNil(S25UFeatures.slug(for: "feat.app-good"))
        XCTAssertNil(S25UFeatures.slug(for: "diag.sent"))
        XCTAssertEqual(S25UFeatures.tallyName("ms-people"), "feat.ms-people")
    }

    func testTallyAlsoCountsFeature() {
        Tally.reset()
        Tally.add("screen.facts", 2)
        let sums = Tally.sums(days: 1)
        XCTAssertEqual(sums["screen.facts"], 2)
        XCTAssertEqual(sums["feat.app-learned"], 2)
        Tally.reset()
    }

    func testKeyTableListsAll() {
        let table = S25UFeatures.keyTable()
        XCTAssertEqual(table.split(separator: "\n").count, 33)
        XCTAssertTrue(table.contains("`feat.app-watch`"))
    }

    // MARK: 堅3

    func testWatchLag() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(S25UWatchLag.pair(phone: 402, watch: "386"), "386-402")
        XCTAssertNil(S25UWatchLag.pair(phone: 402, watch: "402"))
        XCTAssertNil(S25UWatchLag.pair(phone: 402, watch: nil))
        // 初めて見たら今から
        XCTAssertEqual(S25UWatchLag.since(pair: "386-402", savedPair: nil, savedSince: nil, now: now), now)
        // 同じ組なら前の時刻のまま・組が変わったら数え直し
        let old = now.addingTimeInterval(-90_000)
        XCTAssertEqual(S25UWatchLag.since(pair: "386-402", savedPair: "386-402", savedSince: old, now: now), old)
        XCTAssertEqual(S25UWatchLag.since(pair: "386-410", savedPair: "386-402", savedSince: old, now: now), now)
        XCTAssertNil(S25UWatchLag.since(pair: nil, savedPair: "386-402", savedSince: old, now: now))
        // 24 時間たって、時計の便りが届いたことがあるときだけ
        XCTAssertTrue(S25UWatchLag.shouldShow(since: old, now: now, watchSeen: true))
        XCTAssertFalse(S25UWatchLag.shouldShow(since: old, now: now, watchSeen: false))
        XCTAssertFalse(S25UWatchLag.shouldShow(since: now.addingTimeInterval(-3600), now: now, watchSeen: true))
    }

    // MARK: 早1・早3

    private func sample(at: Date, toPhone: Double? = 30, phoneWait: Double? = 60, transfer: Double? = 400,
                        pcWait: Double? = 10, pcWork: Double? = 20, net: String? = "wifi", cellular: Bool? = true,
                        sent: Date? = nil) -> Latency.Sample {
        Latency.Sample(at: at, toPhone: toPhone, toPC: (phoneWait ?? 0) + (transfer ?? 0), pcWait: pcWait, pcWork: pcWork,
                       toRecord: 5, total: 500, sent: sent ?? at.addingTimeInterval(-100), phoneWait: phoneWait,
                       transfer: transfer, net: net, cellular: cellular)
    }

    func testStagesSplitWaits() {
        let s = sample(at: .now)
        let stages = S25UWait.stages(s)
        XCTAssertEqual(stages[.watch], 30)
        XCTAssertEqual(stages[.phone], 60)
        XCTAssertEqual(stages[.toPC], 400)
        XCTAssertEqual(stages[.pc], 30)
    }

    func testCause() {
        XCTAssertEqual(S25UWait.cause(net: .offline, cellularAllowed: true, batched: false), .wifiWait)
        XCTAssertEqual(S25UWait.cause(net: .cell, cellularAllowed: false, batched: true), .wifiWait)
        XCTAssertEqual(S25UWait.cause(net: .cell, cellularAllowed: true, batched: true), .outside)
        XCTAssertEqual(S25UWait.cause(net: .wifi, cellularAllowed: true, batched: true), .batched)
        XCTAssertEqual(S25UWait.cause(net: .wifi, cellularAllowed: true, batched: false), .plain)
        XCTAssertEqual(S25UWait.cause(net: nil, cellularAllowed: nil, batched: false), .plain)
    }

    func testBatched() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let sent = [t, t.addingTimeInterval(5), t.addingTimeInterval(10), t.addingTimeInterval(300)]
        XCTAssertEqual(S25UWait.batched(sent), [true, true, true, false])
    }

    func testSummaryCountsLongestStageAndCauses() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = now.addingTimeInterval(-1000)
        let samples = [
            sample(at: now.addingTimeInterval(-60), net: "cell", sent: t),
            sample(at: now.addingTimeInterval(-50), net: "wifi", sent: t.addingTimeInterval(400)),
            // 2 日前は入れない
            sample(at: now.addingTimeInterval(-3 * 86400)),
        ]
        let out = S25UWait.summary(samples, now: now)
        XCTAssertEqual(out?["count"] as? Int, 2)
        XCTAssertEqual(out?["longest"] as? String, "toPC")
        let causes = out?["toPCCauses"] as? [String: Any]
        XCTAssertEqual((causes?["outside"] as? [String: Any])?["count"] as? Int, 1)
        XCTAssertEqual((causes?["plain"] as? [String: Any])?["count"] as? Int, 1)
        XCTAssertNotNil(out.flatMap { PCDiag.encode(["s": $0]) })
        XCTAssertNil(S25UWait.summary([], now: now))
        XCTAssertNotNil(S25UWait.line(samples, now: now))
    }

    func testLatencySampleKeepsSendRoute() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var m = Latency.Marks(watch: true, chunkStart: t, chunkEnd: t.addingTimeInterval(60), arrived: t.addingTimeInterval(90))
        m.sent = t.addingTimeInterval(150)
        m.received = t.addingTimeInterval(500)
        m.net = "cell"
        m.cellular = true
        let s = Latency.sample(m, applied: t.addingTimeInterval(600))
        XCTAssertEqual(s.phoneWait, 60)
        XCTAssertEqual(s.transfer, 350)
        XCTAssertEqual(s.toPC, 410)
        XCTAssertEqual(s.net, "cell")
    }

    // MARK: 片3

    func testOffLong() {
        let first = S25UOffLong.update(saved: [:], offByDefault: [(id: "a", on: false), (id: "b", on: true)], today: "2026-11-24")
        XCTAssertEqual(first, ["a": "2026-11-24"])
        // 一度オンにしたら忘れる・オフのままなら初めの日のまま
        let next = S25UOffLong.update(saved: ["a": "2026-10-01", "b": "2026-10-01"],
                                      offByDefault: [(id: "a", on: false), (id: "b", on: true)], today: "2026-11-24")
        XCTAssertEqual(next, ["a": "2026-10-01"])
        XCTAssertEqual(S25UOffLong.long(next, today: "2026-11-24"), ["a"])
        XCTAssertEqual(S25UOffLong.long(first, today: "2026-11-24"), [])
    }

    // MARK: 大12・大16 の報告は報告の棚で読める

    func testReportsShelfShowsNewReports() {
        let feed = S22Rules.ReportsFeed(generated_at: nil, reports: [
            .init(name: "speaking-scorecard-2026-W48.md", title: "話し方の成績表"),
            .init(name: "body-forecast-2026-W48.md", title: "体調の先読み"),
        ])
        XCTAssertEqual(S22Rules.visibleReports(feed).count, 2)
    }

    // MARK: 堅4 K6

    @MainActor
    func testPingKind() {
        XCTAssertEqual(PushWake.kind(from: ["lifelog": ["kind": "ping"]]), .ping)
        XCTAssertEqual(PushWake.pingTally, "s25.ping.got")
    }
}

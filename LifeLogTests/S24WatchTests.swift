import XCTest
@testable import LifeLog

/// s24 の 急6（時計に溜まり続けたら自分で送り直す）と 急7（家の PC の watchDirectLast で黙る。取り決め C2）。Shared/Audio/S24Watch.swift
final class S24WatchTests: XCTestCase {
    // MARK: 急6

    private func samples(_ pairs: [(Double, Int)]) -> [[Double]] {
        pairs.map { [$0.0, Double($0.1)] }
    }

    func testGrowingForAnHourTriggers() {
        // 2026-11-24 15:00〜: 5 分ごとに 1 つずつ増え、1 度も減らない
        let start = 1_000_000.0
        let list = samples((0...13).map { (start + Double($0) * 300, 28 + $0) })
        XCTAssertTrue(S24Watch.backlogGrowing(list, now: start + 13 * 300))
    }

    func testShorterThanAnHourDoesNotTrigger() {
        let start = 1_000_000.0
        let list = samples((0...10).map { (start + Double($0) * 300, 28 + $0) })  // 50 分
        XCTAssertFalse(S24Watch.backlogGrowing(list, now: start + 10 * 300))
    }

    func testOneDropMeansSomethingWasDelivered() {
        let start = 1_000_000.0
        var pairs = (0...13).map { (start + Double($0) * 300, 28 + $0) }
        pairs[6].1 = 20  // 途中で始まりより減った＝届いた分がある
        XCTAssertFalse(S24Watch.backlogGrowing(samples(pairs), now: start + 13 * 300))
    }

    func testFlatBacklogDoesNotTrigger() {
        let start = 1_000_000.0
        let list = samples((0...13).map { (start + Double($0) * 300, 28) })
        XCTAssertFalse(S24Watch.backlogGrowing(list, now: start + 13 * 300))
    }

    func testGapInSamplesDoesNotDecide() {
        // アプリが止まっていて、あいだの見本が 1 つしか無い
        let start = 1_000_000.0
        let list = samples([(start, 10), (start + 3900, 40)])
        XCTAssertFalse(S24Watch.backlogGrowing(list, now: start + 3900))
    }

    func testSamplesAreThinnedAndForgotten() {
        var list: [[Double]] = []
        list = S24Watch.addingSample(list, time: 1000, count: 1)
        list = S24Watch.addingSample(list, time: 1030, count: 2)  // 1 分以内は数だけ書き換える
        XCTAssertEqual(list, [[1000, 2]])
        list = S24Watch.addingSample(list, time: 1100, count: 3)
        XCTAssertEqual(list.count, 2)
        list = S24Watch.addingSample(list, time: 1000 + 3 * 3600, count: 4)  // 2 時間より古いものは捨てる
        XCTAssertEqual(list, [[1000 + 3 * 3600, 4]])
    }

    func testRescueGapAndDirectWindow() {
        XCTAssertTrue(S24Watch.rescueDue(last: 0, now: 1000))
        XCTAssertFalse(S24Watch.rescueDue(last: 1000, now: 1000 + 10 * 60))
        XCTAssertTrue(S24Watch.rescueDue(last: 1000, now: 1000 + 31 * 60))
        // 直接送るがオフの日でも、送り直しのあと 30 分は外の道を試す
        XCTAssertTrue(S24Watch.directNow(stored: false, rescueOn: true, rescueUntil: 2000, now: 1500))
        XCTAssertFalse(S24Watch.directNow(stored: false, rescueOn: true, rescueUntil: 2000, now: 2500))
        XCTAssertFalse(S24Watch.directNow(stored: false, rescueOn: false, rescueUntil: 2000, now: 1500))
        XCTAssertTrue(S24Watch.directNow(stored: true, rescueOn: false, rescueUntil: 0, now: 1500))
    }

    func testRescueSettingTravelsToWatch() {
        let defaults = UserDefaults(suiteName: "s24-watch-tests")!
        defaults.removePersistentDomain(forName: "s24-watch-tests")
        var context: [String: Any] = [:]
        S24Watch.addSettings(to: &context, defaults: defaults)
        XCTAssertEqual(context[S24Watch.rescueKey] as? Bool, true)  // 初めはオン
        defaults.set(false, forKey: S24Watch.rescueKey)
        S24Watch.addSettings(to: &context, defaults: defaults)
        XCTAssertEqual(context[S24Watch.rescueKey] as? Bool, false)
    }

    func testCountsKeepAWeek() {
        let counts = S24Watch.addingCount(["2026-11-10": 3, "2026-11-23": 1], day: "2026-11-24", keepFrom: "2026-11-17")
        XCTAssertEqual(counts, ["2026-11-23": 1, "2026-11-24": 1])
    }

    // MARK: 急7（C2）

    func testParseLastReadsOffsetsAndFractions() {
        let a = S24Watch.parseLast("2026-11-24T14:58:49+09:00")
        let b = S24Watch.parseLast("2026-11-24T14:58:49.123456+09:00")
        let c = S24Watch.parseLast("2026-11-24T05:58:49Z")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
        XCTAssertNil(S24Watch.parseLast(nil))
        XCTAssertNil(S24Watch.parseLast(""))
        XCTAssertNil(S24Watch.parseLast("きのう"))
    }

    func testQuietOnlyWhilePCGotItRecently() {
        let last = S24Watch.parseLast("2026-11-24T14:58:49+09:00")!
        // 時計の直接がオン・家の PC に 10 分前に届いた → 黙る
        XCTAssertTrue(S24Watch.quiet(watchDirectOn: true, allowed: true, pcLast: last, now: last.addingTimeInterval(600)))
        // 31 分たった（今日の 15 時台のような止まり方）→ 知らせる
        XCTAssertFalse(S24Watch.quiet(watchDirectOn: true, allowed: true, pcLast: last, now: last.addingTimeInterval(31 * 60)))
        // 読めない（PC が古い・聞けなかった）→ 知らせる
        XCTAssertFalse(S24Watch.quiet(watchDirectOn: true, allowed: true, pcLast: nil, now: last))
        // 時計の直接がオフ・iPhone 経由だけの日 → 知らせる
        XCTAssertFalse(S24Watch.quiet(watchDirectOn: false, allowed: true, pcLast: last, now: last))
        XCTAssertFalse(S24Watch.quiet(watchDirectOn: true, allowed: false, pcLast: last, now: last))
        // PC の時計が少し進んでいるだけなら黙る・大きく先の時刻は信じない
        XCTAssertTrue(S24Watch.quiet(watchDirectOn: true, allowed: true, pcLast: last, now: last.addingTimeInterval(-120)))
        XCTAssertFalse(S24Watch.quiet(watchDirectOn: true, allowed: true, pcLast: last, now: last.addingTimeInterval(-3600)))
    }

    func testAskEveryFiveMinutes() {
        XCTAssertTrue(S24Watch.askDue(lastAsked: 0, now: 1000))
        XCTAssertFalse(S24Watch.askDue(lastAsked: 1000, now: 1000 + 120))
        XCTAssertTrue(S24Watch.askDue(lastAsked: 1000, now: 1000 + 300))
    }
}

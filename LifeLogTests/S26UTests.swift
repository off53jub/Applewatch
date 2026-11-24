import XCTest
@testable import LifeLog

/// s26 の A2（S26URules.swift・Shared/Audio/S26UWatchPlan.swift）: 軽1・軽3・軽4・軽5（K5）・軽6・軽9（K4）・軽10・軽11（K6）
final class S26UTests: XCTestCase {
    // MARK: 軽3 よく変える 3 つ

    func testQuickPutsPresetAndSceneFirstFromRealCounts() {
        // 2026-11-06〜25 の実機の数（録り方の組 7・場面 4・スイッチは 0）
        let sums = ["s21.preset.accuracy": 4, "s21.preset.speed": 2, "s21.preset.battery": 1,
                    "s20.scene.holiday": 3, "s20.scene.usual": 1]
        let pick = S26UQuick.top(switches: ["standbyOn", "homePCWatchDirect", "skipSilence"], sums: sums)
        XCTAssertEqual(Array(pick.ids.prefix(2)), ["preset", "scene"])
        XCTAssertEqual(pick.ids.count, 3)
        XCTAssertTrue(pick.provisional, "数のあるものが 2 つだけなら仮")
        XCTAssertEqual(pick.ids[2], "standbyOn")
    }

    func testQuickOrdersByCountAndIsNotProvisionalWhenFull() {
        let sums = ["s24.touch.skipSilence": 9, "s21.preset.speed": 2, "s20.scene.usual": 5]
        let pick = S26UQuick.top(switches: ["standbyOn", "skipSilence"], sums: sums)
        XCTAssertEqual(pick.ids, ["skipSilence", "scene", "preset"])
        XCTAssertFalse(pick.provisional)
    }

    func testQuickWithNoCountsUsesInitial() {
        let pick = S26UQuick.top(switches: ["standbyOn", "homePCWatchDirect", "skipSilence"], sums: [:])
        XCTAssertEqual(pick.ids, ["preset", "scene", "standbyOn"])
        XCTAssertTrue(pick.provisional)
    }

    func testNextPresetCycles() {
        XCTAssertEqual(S26UQuick.next(after: nil), .battery)
        XCTAssertEqual(S26UQuick.next(after: .battery), .speed)
        XCTAssertEqual(S26UQuick.next(after: .speed), .accuracy)
        XCTAssertEqual(S26UQuick.next(after: .accuracy), .battery)
    }

    // MARK: 軽4 答える山

    func testPileAlternatesKindsAndSortsReviewByImpact() {
        let groups: [S26UPile.Kind: [S26UPile.Card]] = [
            .review: [S26UPile.Card(kind: .review, id: "r1", impact: 1), S26UPile.Card(kind: .review, id: "r2", impact: 5)],
            .listen: [S26UPile.Card(kind: .listen, id: "l1")],
            .know: [S26UPile.Card(kind: .know, id: "k1"), S26UPile.Card(kind: .know, id: "k2")],
        ]
        XCTAssertEqual(S26UPile.merge(groups).map(\.id), ["r2", "l1", "k1", "r1", "k2"])
    }

    func testPileKeepsDailyCap() {
        let cards = (1...5).map { S26UPile.Card(kind: .listen, id: "l\($0)") }
        let split = S26UPile.split(cards, left: 3)
        XCTAssertEqual(split.today.count, 3)
        XCTAssertEqual(split.more.count, 2)
        XCTAssertEqual(S26UPile.split(cards, left: 0).today.count, 0)
        XCTAssertEqual(S26UPile.split(cards, left: -1).more.count, 5)
        XCTAssertEqual(S26UPile.split([], left: 3).today.count, 0)
    }

    func testPileAskKeyMatchesReviewCounting() {
        // 確かめ待ちは S20Book と同じ "q:" + id で数える（同じ問いを 2 回数えない）
        XCTAssertEqual(S26UPile.Card(kind: .review, id: "x").askKey, "q:x")
        XCTAssertEqual(S26UPile.Card(kind: .listen, id: "x").askKey, "pile:listen:x")
    }

    func testPileSwipe() {
        XCTAssertEqual(S26UPile.swipe(150), true)
        XCTAssertEqual(S26UPile.swipe(-150), false)
        XCTAssertNil(S26UPile.swipe(60))
        XCTAssertEqual(S26UPile.minutes(1), 1)
        XCTAssertEqual(S26UPile.minutes(40), 2)
    }

    // MARK: 軽1

    func testEveryHelpHasTwoLines() {
        XCTAssertFalse(S26UHelp.lines.isEmpty)
        for (screen, lines) in S26UHelp.lines {
            XCTAssertEqual(lines.count, 2, screen)
            for line in lines { XCTAssertFalse(line.isEmpty, screen) }
        }
        XCTAssertTrue(S26UHelp.of("見つからない画面").isEmpty)
        XCTAssertTrue(S26UHelp.legend.contains { $0.tone == .act && $0.color == "赤" })
        XCTAssertTrue(S26UHelp.legend.contains { $0.color == "オレンジ" && $0.meaning.contains("明日") })
    }

    // MARK: 軽10

    func testWriteDelayKeepsFilesUnderBudget() {
        let mb = 1024 * 1024
        // 小さい帳はいつものまま
        XCTAssertEqual(S26UWrite.delay(base: 120, lastBytes: 50_000), 120)
        XCTAssertEqual(S26UWrite.delay(base: 120, lastBytes: 0), 120)
        // 1.4MB の声の帳 → 約 20 分（1 日 100MB に収まる）
        let speakers = S26UWrite.delay(base: 180, lastBytes: Int(1.4 * Double(mb)))
        XCTAssertEqual(speakers, 1209.6, accuracy: 1)
        XCTAssertLessThanOrEqual(86400 / speakers * 1.4, 100.1)
        // とても大きい帳でも 30 分まで
        XCTAssertEqual(S26UWrite.delay(base: 180, lastBytes: 50 * mb), 1800)
        // base が上限より長いときは base
        XCTAssertEqual(S26UWrite.delay(base: 3600, lastBytes: 50 * mb), 3600)
    }

    func testFoldOnlyRowsTheOwnerCannotFix() {
        XCTAssertTrue(S26UCheckRows.folds(ok: false, fix: .wait))
        XCTAssertTrue(S26UCheckRows.folds(ok: false, fix: .askClaude))
        XCTAssertFalse(S26UCheckRows.folds(ok: false, fix: .self_))
        XCTAssertFalse(S26UCheckRows.folds(ok: true, fix: .wait))
        XCTAssertFalse(S26UCheckRows.folds(ok: nil, fix: .askClaude))
    }

    // MARK: 軽5・軽9・軽11（K5・K4・K6）

    func testWaitingDecodesAndDropsBadRows() throws {
        let json = """
        {"version":1,"generated_at":"2026-11-25T08:00:00+09:00","items":[
          {"id":"line-webhook","title":"LINE の Webhook の URL を貼る","steps":["開く","貼る"],"link":"https://example.com/x","copy":"https://example.com/hook","done":false},
          {"id":"watch-update","title":"時計の LifeLog を新しく","steps":[],"link":null,"copy":null,"done":true},
          {"id":"bad id with space","title":"落とす"},
          {"title":"id が無い"}
        ]}
        """
        let items = try XCTUnwrap(S26UFeeds.waiting(Data(json.utf8)))
        XCTAssertEqual(items.map(\.id), ["line-webhook", "watch-update"])
        let order = S26UFeeds.waitingOrder(items)
        XCTAssertEqual(order.open.map(\.id), ["line-webhook"])
        XCTAssertEqual(order.done.map(\.id), ["watch-update"])
        XCTAssertNil(S26UFeeds.waiting(Data("{\"available\":false}".utf8)))
    }

    func testOpenableLinks() {
        XCTAssertNotNil(S26UFeeds.openable("https://example.com"))
        XCTAssertNotNil(S26UFeeds.openable("lifelog://waiting"))
        XCTAssertNil(S26UFeeds.openable("http://example.com"))
        XCTAssertNil(S26UFeeds.openable("javascript:alert(1)"))
        XCTAssertNil(S26UFeeds.openable(nil))
    }

    func testMachineActionsOrderAndUndoBody() throws {
        let json = """
        {"version":1,"generated_at":"2026-11-25T08:00:00Z","items":[
          {"id":"a1","at":"2026-11-24T10:00:00Z","kind":"task_closed","what":"タスクを閉じた","undo":true},
          {"id":"a2","at":"2026-11-25T07:00:00Z","kind":"name","what":"名前を付けた","undo":false},
          {"id":"a3","kind":"other","what":"時刻なし"}
        ]}
        """
        let items = try XCTUnwrap(S26UFeeds.machine(Data(json.utf8)))
        XCTAssertEqual(S26UFeeds.machineOrder(items).map(\.id), ["a2", "a1", "a3"])
        XCTAssertTrue(items[0].canUndo)
        XCTAssertFalse(items[1].canUndo)
        XCTAssertFalse(items[2].canUndo)
        XCTAssertEqual(items[0].kindLabel, "タスクを閉じた")
        let body = try XCTUnwrap(S26UFeeds.undoBody(id: "a1", day: "2026-11-25"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["kind": "undo", "id": "a1", "value": "undo", "day": "2026-11-25"])
        XCTAssertNil(S26UFeeds.undoBody(id: "a 1", day: "2026-11-25"))
        XCTAssertNil(S26UFeeds.undoBody(id: "a1", day: "11/25"))
    }

    func testGapTaskPicksOnlyTheCurrentOne() throws {
        let json = """
        {"version":1,"generated_at":"2026-11-25T08:00:00Z","items":[
          {"from":"2026-11-25T09:00:00Z","to":"2026-11-25T09:30:00Z","task_id":"t1","text":"資料を見直す","minutes":15},
          {"from":"2026-11-25T09:10:00Z","to":"2026-11-25T09:20:00Z","task_id":null,"text":"返事を 1 通","minutes":5},
          {"from":"2026-11-25T12:00:00Z","to":"2026-11-25T12:15:00Z","text":"あと"}
        ]}
        """
        let gaps = try XCTUnwrap(S26UFeeds.gaps(Data(json.utf8)))
        XCTAssertEqual(gaps.count, 3)
        let at = { (s: String) in PCJSON.date(s)! }
        XCTAssertEqual(S26UFeeds.currentGap(gaps, now: at("2026-11-25T09:05:00Z"))?.text, "資料を見直す")
        // 重なったら早く終わるほう
        XCTAssertEqual(S26UFeeds.currentGap(gaps, now: at("2026-11-25T09:15:00Z"))?.text, "返事を 1 通")
        XCTAssertNil(S26UFeeds.currentGap(gaps, now: at("2026-11-25T10:00:00Z")))
        // 終わりの時刻ちょうどは外
        XCTAssertNil(S26UFeeds.currentGap(gaps, now: at("2026-11-25T12:15:00Z")))
    }

    // MARK: 軽6 時計への録り方の指図

    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    func testPlanFollowsExperimentAndSetting() throws {
        let cal = tokyo
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10)))
        let combo = RecordingExperiment.Combo(day: 2, bitrate: 48_000, length: .short)
        let plan = S26UWatchPlan.make(base: .normal, combo: combo, now: now, calendar: cal)
        XCTAssertEqual(plan.day, "2026-11-25")
        XCTAssertEqual(plan.length, "short")
        XCTAssertEqual(plan.bitrate, 48_000)
        XCTAssertEqual(plan.until - plan.made, S26UWatchPlan.lifetime, accuracy: 1)
        let plain = S26UWatchPlan.make(base: .normal, combo: nil, now: now, calendar: cal)
        XCTAssertEqual(plain.length, "normal")
        XCTAssertEqual(plain.bitrate, RecordingExperiment.defaultBitrate)
        // 夜遅くに作った指図は、その日の終わりまで
        let late = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 22)))
        let latePlan = S26UWatchPlan.make(base: .short, combo: nil, now: late, calendar: cal)
        XCTAssertEqual(latePlan.until - latePlan.made, 2 * 3600, accuracy: 1)
    }

    func testWatchUsesPlanOnlyWhenFreshAndNotInMeeting() throws {
        let cal = tokyo
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10)))
        let plan = S26UWatchPlan.make(base: .normal, combo: RecordingExperiment.Combo(day: 1, bitrate: 48_000, length: .short),
                                      now: now, calendar: cal)
        XCTAssertNotNil(S26UWatchPlan.usable(plan, now: now.addingTimeInterval(3600), calendar: cal))
        XCTAssertEqual(S26UWatchPlan.length(local: .normal, plan: plan, meeting: false, now: now), .short)
        XCTAssertEqual(S26UWatchPlan.bitrate(local: 32_000, plan: plan, meeting: false, now: now), 48_000)
        // 会議モードのあいだは時計の決まり
        XCTAssertEqual(S26UWatchPlan.length(local: .normal, plan: plan, meeting: true, now: now), .normal)
        XCTAssertEqual(S26UWatchPlan.bitrate(local: 48_000, plan: plan, meeting: true, now: now), 48_000)
        // 有効な時間を過ぎた・指図が無いときは時計の決まり
        XCTAssertNil(S26UWatchPlan.usable(plan, now: now.addingTimeInterval(7 * 3600), calendar: cal))
        XCTAssertEqual(S26UWatchPlan.length(local: .normal, plan: nil, meeting: false, now: now), .normal)
        // 知らない新しい形の版は使わない（古い時計と同じく、自分の決まりで動く）
        var future = plan
        future.v = S26UWatchPlan.version + 1
        XCTAssertNil(S26UWatchPlan.usable(future, now: now, calendar: cal))
        // おかしな音質は使わない
        var odd = plan
        odd.bitrate = 1
        XCTAssertEqual(S26UWatchPlan.bitrate(local: 32_000, plan: odd, meeting: false, now: now), 32_000)
    }

    func testPlanRoundTripsAndOldKeysStayInContext() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = S26UWatchPlan.make(base: .short, combo: nil, now: now)
        let data = try XCTUnwrap(S26UWatchPlan.encode(plan))
        XCTAssertEqual(S26UWatchPlan.decode(data), plan)
        XCTAssertNil(S26UWatchPlan.decode(Data("{}".utf8)))
        // 指図は 1 つの鍵（Data）に入るだけ。今までの鍵は ChunkCutter.addSettings がそのまま入れる（古い時計は知らない鍵を読み飛ばす）
        var context: [String: Any] = ["chunkLength": "short"]
        S26UWatchPlan.addSettings(to: &context, now: now)
        XCTAssertEqual(context["chunkLength"] as? String, "short")
        XCTAssertNotNil(S26UWatchPlan.decode(context[S26UWatchPlan.contextKey] as? Data))
    }

    func testPlanResend() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = S26UWatchPlan.make(base: .short, combo: nil, now: now)
        XCTAssertTrue(S26UWatchPlan.shouldSend(plan, last: nil, now: now))
        XCTAssertFalse(S26UWatchPlan.shouldSend(plan, last: plan, now: now.addingTimeInterval(600)))
        XCTAssertTrue(S26UWatchPlan.shouldSend(plan, last: plan, now: now.addingTimeInterval(S26UWatchPlan.resendEvery)))
        var changed = plan
        changed.length = "normal"
        XCTAssertTrue(S26UWatchPlan.shouldSend(changed, last: plan, now: now.addingTimeInterval(60)))
    }
}

import XCTest
import UserNotifications
@testable import LifeLog

/// 2026-11-15（強化案 36〜38・41・44・46・47・49）: 録り方の実験の組・知らせの束ね・位置の滞在を1つに・送り口の引っ越し・
/// 施策の検品表・費用・正しさの抜き取りの読み方・家の PC の外からの見張り・用途ごとの止め。名前・言葉はすべて作り物。
@MainActor
final class SettleTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ s: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - 録り方の実験（47）

    func testExperimentStartsTomorrowAndRunsFourDays() {
        let cal = tokyo
        XCTAssertEqual(RecordingExperiment.firstDay(after: at(2026, 11, 15, 23, 50), calendar: cal), "2026-11-16")
        let start = "2026-11-16"
        XCTAssertNil(RecordingExperiment.combo(on: true, start: start, meeting: false, now: at(2026, 11, 15, 12), calendar: cal))
        var labels: [String] = []
        for d in 16...19 {
            let combo = RecordingExperiment.combo(on: true, start: start, meeting: false, now: at(2026, 11, d, 9), calendar: cal)
            labels.append(combo?.label ?? "-")
        }
        XCTAssertEqual(labels, ["32kbps・45秒", "48kbps・45秒", "32kbps・300秒", "48kbps・300秒"])
        let day3 = RecordingExperiment.combo(on: true, start: start, meeting: false, now: at(2026, 11, 18, 23, 59), calendar: cal)
        XCTAssertEqual(day3?.day, 3)
        XCTAssertEqual(day3?.length, ChunkCutter.Length.normal)
        // 5日目からは元に戻る
        XCTAssertNil(RecordingExperiment.combo(on: true, start: start, meeting: false, now: at(2026, 11, 20, 0, 1), calendar: cal))
        XCTAssertTrue(RecordingExperiment.finished(start: start, now: at(2026, 11, 20, 0, 1), calendar: cal))
        XCTAssertFalse(RecordingExperiment.finished(start: start, now: at(2026, 11, 19, 23), calendar: cal))
    }

    func testExperimentOffMeetingAndDefaults() {
        let cal = tokyo
        let now = at(2026, 11, 17, 10)
        XCTAssertNil(RecordingExperiment.combo(on: false, start: "2026-11-16", meeting: false, now: now, calendar: cal))
        XCTAssertNil(RecordingExperiment.combo(on: true, start: nil, meeting: false, now: now, calendar: cal))
        XCTAssertNil(RecordingExperiment.combo(on: true, start: "壊れた", meeting: false, now: now, calendar: cal))
        // 会議モードが優先
        XCTAssertNil(RecordingExperiment.combo(on: true, start: "2026-11-16", meeting: true, now: now, calendar: cal))
        let combo = RecordingExperiment.combo(on: true, start: "2026-11-16", meeting: false, now: now, calendar: cal)
        XCTAssertEqual(RecordingExperiment.bitrate(combo: combo, meeting: false, meetingRate: 48_000), 48_000)
        XCTAssertEqual(RecordingExperiment.bitrate(combo: nil, meeting: true, meetingRate: 48_000), 48_000)
        XCTAssertEqual(RecordingExperiment.bitrate(combo: nil, meeting: true, meetingRate: 32_000), 32_000)
        XCTAssertEqual(RecordingExperiment.bitrate(combo: nil, meeting: false, meetingRate: 48_000), 32_000)
        XCTAssertEqual(RecordingExperiment.length(base: .short, combo: nil), .short)
        let day4 = RecordingExperiment.combo(on: true, start: "2026-11-16", meeting: false, now: at(2026, 11, 19, 10), calendar: cal)
        XCTAssertEqual(RecordingExperiment.length(base: .short, combo: day4), .normal)
    }

    func testExperimentSettingsTravelToWatch() {
        let defaults = UserDefaults.standard
        let savedOn = defaults.object(forKey: RecordingExperiment.onKey)
        let savedStart = defaults.object(forKey: RecordingExperiment.startKey)
        defer {
            defaults.set(savedOn, forKey: RecordingExperiment.onKey)
            defaults.set(savedStart, forKey: RecordingExperiment.startKey)
        }
        RecordingExperiment.start = "2026-11-16"
        RecordingExperiment.isOn = false
        var context: [String: Any] = [:]
        RecordingExperiment.addSettings(to: &context)
        XCTAssertEqual(context[RecordingExperiment.onKey] as? Bool, false)
        XCTAssertEqual(context[RecordingExperiment.startKey] as? String, "2026-11-16")
        RecordingExperiment.isOn = true
        RecordingExperiment.readSettings([RecordingExperiment.onKey: false, RecordingExperiment.startKey: "だめ"])
        XCTAssertFalse(RecordingExperiment.isOn)
        XCTAssertEqual(RecordingExperiment.start, "2026-11-16")
    }

    // MARK: - 知らせの束ね（44）

    func testBundleHoldsFourthPerHourButNotExempt() {
        let now = at(2026, 11, 15, 12)
        let three: [Date] = [now.addingTimeInterval(-3000), now.addingTimeInterval(-600), now.addingTimeInterval(-60)]
        XCTAssertFalse(NoticeBundle.shouldHold(recent: Array(three.prefix(2)), now: now, exempt: false))
        XCTAssertTrue(NoticeBundle.shouldHold(recent: three, now: now, exempt: false))
        // 1時間より前の分は数えない
        let old: [Date] = [now.addingTimeInterval(-3700), now.addingTimeInterval(-600), now.addingTimeInterval(-60)]
        XCTAssertFalse(NoticeBundle.shouldHold(recent: old, now: now, exempt: false))
        // 期限・録音が止まった・ボタンのある知らせは、いつも出す
        XCTAssertFalse(NoticeBundle.shouldHold(recent: three, now: now, exempt: true))
        XCTAssertTrue(NoticeBundle.isExempt(identifier: "tasks-due-abc", category: ""))
        XCTAssertTrue(NoticeBundle.isExempt(identifier: "tasks-1763200000", category: ""))
        XCTAssertTrue(NoticeBundle.isExempt(identifier: "phone-stopped", category: ""))
        XCTAssertTrue(NoticeBundle.isExempt(identifier: "watch-not-recording", category: ""))
        XCTAssertTrue(NoticeBundle.isExempt(identifier: "x", category: "promise"))
        XCTAssertFalse(NoticeBundle.isExempt(identifier: "fresh-line", category: ""))
        XCTAssertFalse(NoticeBundle.isExempt(identifier: "pc-silent", category: ""))
    }

    func testBundleImmediateKindAndText() {
        XCTAssertTrue(NoticeBundle.isImmediate(nil))
        XCTAssertTrue(NoticeBundle.isImmediate(UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        XCTAssertFalse(NoticeBundle.isImmediate(UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)))
        var comps = DateComponents()
        comps.hour = 8
        XCTAssertFalse(NoticeBundle.isImmediate(UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
        XCTAssertEqual(NoticeBundle.kind(identifier: "tasks-due-abc", category: "taskDue"), "taskDue")
        XCTAssertEqual(NoticeBundle.kind(identifier: "tasks-1763200000", category: ""), "tasks")
        XCTAssertEqual(NoticeBundle.kind(identifier: "fresh-line", category: ""), "fresh")
        XCTAssertEqual(NoticeBundle.kind(identifier: "proposal-2026-11-15", category: ""), "proposal")
        XCTAssertEqual(NoticeBundle.kind(identifier: "home-pc", category: ""), "home-pc")
        XCTAssertEqual(NoticeBundle.kind(identifier: "見本", category: ""), "other")
        XCTAssertEqual(NoticeBundle.kind(identifier: NoticeBundle.bundleID, category: ""), "bundle")
        XCTAssertEqual(NoticeBundle.summaryTitle(count: 2), "ほかに 2 件のお知らせ")
        let body = NoticeBundle.summaryBody(titles: ["一", "二", "三", "四"])
        XCTAssertTrue(body.hasPrefix("四・三・二 など"))
        XCTAssertNotEqual(NoticeBundle.key(identifier: "a", date: Date(timeIntervalSince1970: 1)),
                          NoticeBundle.key(identifier: "a", date: Date(timeIntervalSince1970: 2)))
    }

    // MARK: - 位置の滞在を1つに（46）

    func testLocationMergesAreaAndShopGuessIntoOneVisit() throws {
        let points: [LocationExport.Point] = [
            LocationExport.Point(time: at(2026, 11, 13, 19, 0, 0), latitude: 35.68, longitude: 139.76, accuracy: 30, name: "見本駅近く"),
            LocationExport.Point(time: at(2026, 11, 13, 22, 0), latitude: 35.7, longitude: 139.7, accuracy: 30, name: "自宅"),
        ]
        let stays: [LocationExport.Stay] = [
            LocationExport.Stay(start: at(2026, 11, 13, 19, 0, 24), end: at(2026, 11, 13, 20, 30), latitude: 35.6801,
                                longitude: 139.7601, name: "たぶん見本の餃子屋"),
        ]
        let end = at(2026, 11, 14, 0)
        let json = try XCTUnwrap(LocationExport.json(day: "2026-11-13", points: points, stays: stays, dayEnd: end, calendar: tokyo))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let segments = try XCTUnwrap(object["semanticSegments"] as? [[String: Any]])
        var visits: [[String: Any]] = []
        for segment in segments where segment["visit"] != nil { visits.append(segment) }
        // 1つにした滞在・残りの広い名前の滞在（20:30〜22:00）・自宅の3つ（前は4つ: 駅近く・自宅・たぶん◯◯）
        XCTAssertEqual(visits.count, 3)
        let first = try XCTUnwrap((visits[0]["visit"] as? [String: Any])?["topCandidate"] as? [String: Any])
        XCTAssertEqual(first["semanticType"] as? String, "たぶん見本の餃子屋")
        XCTAssertEqual(first["guess"] as? String, "たぶん見本の餃子屋")
        XCTAssertEqual(first["area"] as? String, "見本駅近く")
        XCTAssertEqual(visits[0]["startTime"] as? String, HealthExport.stamp(at(2026, 11, 13, 19), calendar: tokyo))
        XCTAssertEqual(visits[0]["endTime"] as? String, HealthExport.stamp(at(2026, 11, 13, 20, 30), calendar: tokyo))
        XCTAssertEqual(visits[1]["startTime"] as? String, HealthExport.stamp(at(2026, 11, 13, 20, 30), calendar: tokyo))
        let rest = try XCTUnwrap((visits[1]["visit"] as? [String: Any])?["topCandidate"] as? [String: Any])
        XCTAssertEqual(rest["semanticType"] as? String, "見本駅近く")
        XCTAssertNil(rest["guess"])
    }

    func testLocationKeepsSeparateWhenStartsFarApart() {
        let points: [LocationExport.Point] = [
            LocationExport.Point(time: at(2026, 11, 13, 9), latitude: 35.68, longitude: 139.76, accuracy: 30, name: "職場"),
        ]
        let near: [LocationExport.Stay] = [LocationExport.Stay(start: at(2026, 11, 13, 9, 1, 59), end: at(2026, 11, 13, 9, 30),
                                                               latitude: 35.68, longitude: 139.76, name: nil)]
        let far: [LocationExport.Stay] = [LocationExport.Stay(start: at(2026, 11, 13, 9, 2, 1), end: at(2026, 11, 13, 9, 30),
                                                              latitude: 35.68, longitude: 139.76, name: nil)]
        XCTAssertEqual(LocationExport.pairs(points: points, stays: near), [0: 0])
        XCTAssertEqual(LocationExport.pairs(points: points, stays: far), [:])
    }

    // MARK: - 送り口を1つに（46）

    func testMigrationKeepsEveryLegacyItemInOrder() throws {
        let now = Date(timeIntervalSince1970: 1_763_200_000)
        let existing = OutboxItem(id: "a", path: "mood", body: data("{}"), queued: now.addingTimeInterval(-60))
        let fixJSON = "[{\"kind\":\"same_person\",\"id\":\"sp-1\",\"value\":\"merged\",\"day\":\"2026-11-14\"},{\"kind\":\"bulk\",\"id\":\"vocab\",\"value\":\"ok\",\"day\":\"2026-11-14\"}]"
        let fix: [Data] = try XCTUnwrap(MothershipOutbox.legacyFixBodies(data(fixJSON)))
        XCTAssertEqual(fix.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: fix[0]) as? [String: String])
        XCTAssertEqual(first["kind"], "same_person")
        XCTAssertEqual(first["value"], "merged")
        let promise: [Data] = [data("{\"day\":\"2026-11-14\",\"id\":\"p-1\",\"kind\":\"promise\",\"value\":\"added\"}")]
        let full: [OutboxItem] = Array(repeating: existing, count: MothershipOutbox.limit)
        let next = MothershipOutbox.migrating(full, fix: fix, promise: promise, now: now)
        // 上限で落とさない（次に足すときに上限に戻る）
        XCTAssertEqual(next.count, MothershipOutbox.limit + 3)
        let tail: [OutboxItem] = Array(next.suffix(3))
        var paths: [String] = []
        for item in tail { paths.append(item.path) }
        XCTAssertEqual(paths, ["feedback", "feedback", "feedback"])
        XCTAssertEqual(tail[0].body, fix[0])
        XCTAssertEqual(tail[2].body, promise[0])
        XCTAssertNil(MothershipOutbox.legacyFixBodies(data("{壊れた")))
    }

    func testCheckFeedbackKind() {
        XCTAssertNotNil(MothershipOutbox.feedbackBody(kind: "check", id: "c-1", value: "right", day: "2026-11-15"))
        XCTAssertNotNil(MothershipOutbox.feedbackBody(kind: "check", id: "c-1", value: "unsure", day: "2026-11-15"))
        XCTAssertNil(MothershipOutbox.feedbackBody(kind: "check", id: "c-1", value: "ok", day: "2026-11-15"))
        XCTAssertEqual(ProposalRules.kindLabel("wish"), "欲しい物")
    }

    // MARK: - 検品表・費用・抜き取りの読み方（36・37・41）

    func testRolloutDropsBadRows() throws {
        let body = "{\"version\":1,\"items\":[{\"no\":37,\"title\":\"費用の見張り\",\"uses_7d\":3,\"status\":\"live\",\"first_live\":\"2026-11-15\"},{\"no\":2,\"title\":\"週のふり返り\",\"uses_7d\":null,\"status\":\"retire_candidate\"},{\"no\":2,\"title\":\"重なり\",\"status\":\"live\"},{\"no\":5,\"title\":\"状態が変\",\"status\":\"dead\"},{\"no\":6,\"title\":\"\",\"status\":\"live\"},{\"no\":7,\"title\":\"日が変\",\"first_live\":\"きのう\",\"uses_7d\":-1,\"status\":\"unused\"}]}"
        let feed = try XCTUnwrap(SettleFeeds.decodeRollout(data(body)))
        var numbers: [Int] = []
        for item in feed.items { numbers.append(item.no) }
        XCTAssertEqual(numbers, [2, 7, 37])
        XCTAssertNil(feed.items[1].first_live)
        XCTAssertNil(feed.items[1].uses_7d)
        XCTAssertEqual(feed.items[2].uses_7d, 3)
        XCTAssertEqual(SettleFeeds.statusSummary(feed.items), "動いている 1・使われていない 1・畳む候補 1")
        XCTAssertNil(SettleFeeds.decodeRollout(data("{\"available\":false,\"reason\":\"まだ\"}")))
    }

    func testChecksAndNextCheck() throws {
        let body = "{\"items\":[{\"id\":\"c-1\",\"day\":\"2026-11-13\",\"source\":\"digest\",\"claim\":\"見本の主張\"},{\"id\":\"c-2\",\"day\":\"2026-11-14\",\"source\":\"promise\",\"claim\":\"見本の約束\",\"evidence\":\"見本の根拠\"},{\"id\":\"c 3\",\"day\":\"2026-11-14\",\"source\":\"digest\",\"claim\":\"id が変\"},{\"id\":\"c-4\",\"day\":\"2026-11-14\",\"source\":\"line\",\"claim\":\"出どころが変\"}]}"
        let feed = try XCTUnwrap(SettleFeeds.decodeChecks(data(body)))
        var ids: [String] = []
        for item in feed.items { ids.append(item.id) }
        XCTAssertEqual(ids, ["c-2", "c-1"])
        XCTAssertEqual(SettleFeeds.nextCheck(feed.items) { _ in false }?.id, "c-2")
        XCTAssertEqual(SettleFeeds.nextCheck(feed.items) { id in id == "c-2" }?.id, "c-1")
        XCTAssertNil(SettleFeeds.nextCheck(feed.items) { _ in true })
    }

    func testCostsLinesAndOffNames() throws {
        let body = "{\"available\":true,\"month\":\"2026-11\",\"month_usd\":12.4,\"projected_usd\":26.57,\"monthly_usd\":100,\"today\":[{\"purpose\":\"misheard\",\"usd\":0.5,\"cap\":0.5,\"stopped\":false},{\"purpose\":\"headline\",\"usd\":0.02,\"cap\":null,\"stopped\":false},{\"purpose\":\"asr-judge\",\"usd\":0,\"cap\":null,\"stopped\":true},{\"purpose\":\"bad\",\"usd\":-1}],\"month_by_purpose\":[{\"purpose\":\"misheard\",\"usd\":3.1,\"calls\":120}]}"
        let costs = try XCTUnwrap(SettleFeeds.decodeCosts(data(body)))
        XCTAssertEqual(costs.today.count, 3)
        XCTAssertEqual(SettleFeeds.costLine(costs), "今月 $12.40・月末の見込み $26.57（上限 $100）")
        XCTAssertEqual(SettleFeeds.topTodayText(costs), "聞き間違いかも $0.50・会話の見出しと要点 $0.02")
        let off = SettleFeeds.offNames(costs)
        XCTAssertEqual(off.stopped, ["割れた行の審判"])
        XCTAssertEqual(off.capped, ["聞き間違いかも"])
        XCTAssertNil(SettleFeeds.decodeCosts(data("{\"available\":true,\"month\":\"11月\",\"month_usd\":1,\"monthly_usd\":100}")))
    }

    // MARK: - 家の PC の外からの見張り（38）・用途ごとの止め（37）

    func testPCSilenceRules() {
        let now = at(2026, 11, 15, 18)
        let fresh = now.addingTimeInterval(-5 * 3600)
        let quiet = now.addingTimeInterval(-6 * 3600)
        XCTAssertFalse(PCSilence.shouldAlert(configured: true, online: true, last: fresh, lastAlert: nil, now: now))
        XCTAssertTrue(PCSilence.shouldAlert(configured: true, online: true, last: quiet, lastAlert: nil, now: now))
        XCTAssertFalse(PCSilence.shouldAlert(configured: true, online: false, last: quiet, lastAlert: nil, now: now))
        XCTAssertFalse(PCSilence.shouldAlert(configured: false, online: true, last: quiet, lastAlert: nil, now: now))
        // 一度もやり取りしていなければ鳴らさない
        XCTAssertFalse(PCSilence.shouldAlert(configured: true, online: true, last: nil, lastAlert: nil, now: now))
        // 12 時間に1回まで
        XCTAssertFalse(PCSilence.shouldAlert(configured: true, online: true, last: quiet, lastAlert: now.addingTimeInterval(-11 * 3600), now: now))
        XCTAssertTrue(PCSilence.shouldAlert(configured: true, online: true, last: quiet, lastAlert: now.addingTimeInterval(-12 * 3600), now: now))
        XCTAssertNil(PCSilence.todayLine(configured: true, last: fresh, now: now))
        XCTAssertTrue(PCSilence.todayLine(configured: true, last: quiet, now: now)?.hasPrefix("家の PC と 6 時間") ?? false)
        // 時計が直接送れた時刻も、やり取りできたうち
        let watch: Double = now.addingTimeInterval(-60).timeIntervalSince1970
        XCTAssertEqual(PCSilence.lastContact(stored: quiet.timeIntervalSince1970, watchSentAt: watch)?.timeIntervalSince1970, watch)
        XCTAssertNil(PCSilence.lastContact(stored: nil, watchSentAt: nil))
    }

    func testPurposeOffDoesNotPauseOtherPurposes() {
        let failure = ClaudeFailure.from(status: 409, data: data("{\"error\":\"止めた\",\"purpose_off\":\"stopped\"}"))
        XCTAssertEqual(failure, .purposeOff(why: "stopped"))
        XCTAssertEqual(failure?.pause.all, 0)
        XCTAssertEqual(failure?.tallyKey, "claude.purposeOff")
        ClaudeRoute.resetPauses()
        let now = Date()
        ClaudeRoute.pausePurpose("misheard", now: now)
        XCTAssertTrue(ClaudeRoute.purposePaused("misheard", now: now.addingTimeInterval(60)))
        XCTAssertFalse(ClaudeRoute.purposePaused("headline", now: now.addingTimeInterval(60)))
        XCTAssertFalse(ClaudeRoute.purposePaused("misheard", now: now.addingTimeInterval(ClaudeRoute.purposePause + 1)))
        ClaudeRoute.resetPauses()
    }
}

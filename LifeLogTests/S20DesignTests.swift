import XCTest
@testable import LifeLog

/// s20 のデザインと画面の決まり（2026-11-21。LifeLog/S20Rules.swift・Shared/Design）
final class S20DesignTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - 体1・体2 意味の色の割り当て

    func testCertaintyFromTier() {
        XCTAssertEqual(Certainty.from(tier: "auto"), .fact)
        XCTAssertEqual(Certainty.from(tier: "tentative"), .guess)
        XCTAssertEqual(Certainty.from(tier: "ask"), .waiting)
        XCTAssertEqual(Certainty.from(tier: nil), .guess)
    }

    func testCertaintyFromStatus() {
        XCTAssertEqual(Certainty.from(hypothesisStatus: "confirmed"), .fact)
        XCTAssertEqual(Certainty.from(hypothesisStatus: "alive"), .guess)
        XCTAssertEqual(Certainty.from(hypothesisStatus: "weakened"), .stopped)
        XCTAssertEqual(Certainty.from(hypothesisStatus: "unknown"), .waiting)
        XCTAssertEqual(Certainty.from(settleStatus: "live"), .good)
        XCTAssertEqual(Certainty.from(settleStatus: "broken"), .danger)
        XCTAssertEqual(Certainty.from(settleStatus: "unused"), .stopped)
    }

    /// 意味の色は 6 つで、どれも別の色・確かめ待ちは差し色・見立ては薄い文字
    func testMeaningColors() {
        XCTAssertEqual(Certainty.allCases.count, 6)
        XCTAssertEqual(Certainty.waiting.color, LL.accent)
        XCTAssertEqual(Certainty.guess.color, LL.dim)
        XCTAssertEqual(Certainty.stopped.color, LL.warn)
        XCTAssertEqual(Certainty.danger.color, LL.danger)
        XCTAssertEqual(Set(Certainty.allCases.map(\.label)).count, 6)
    }

    // MARK: - 体4 札の絵

    func testTagIcons() {
        XCTAssertEqual(TagIcons.symbol(for: "ラーメン"), "fork.knife")
        XCTAssertEqual(TagIcons.symbol(for: "深夜ドライブ"), "car.fill")
        XCTAssertEqual(TagIcons.symbol(for: "ゴルフ"), "figure.golf")
        XCTAssertEqual(TagIcons.symbol(for: "競馬"), "figure.equestrian.sports")
        XCTAssertEqual(TagIcons.symbol(for: "カラオケ"), "music.mic")
        XCTAssertEqual(TagIcons.symbol(for: "見本の何か"), TagIcons.fallback)
    }

    // MARK: - 体28 帯の範囲の選び方

    func testBandRange() {
        let start = at(2026, 11, 21, 0)
        let end = start.addingTimeInterval(86400)
        // 幅 240 の帯で 60〜120 → 6:00〜12:00
        let r = BandRules.range(fromX: 120, toX: 60, width: 240, dayStart: start, dayEnd: end)
        XCTAssertEqual(r.lowerBound, at(2026, 11, 21, 6))
        XCTAssertEqual(r.upperBound, at(2026, 11, 21, 12))
        // 短すぎるときは 5 分に広げる・帯の外は端にそろえる
        let short = BandRules.range(fromX: 100, toX: 100, width: 240, dayStart: start, dayEnd: end)
        XCTAssertEqual(short.upperBound.timeIntervalSince(short.lowerBound), Double(BandRules.shortestMinutes) * 60)
        let edge = BandRules.range(fromX: -50, toX: 999, width: 240, dayStart: start, dayEnd: end)
        XCTAssertEqual(edge.lowerBound, start)
        XCTAssertEqual(edge.upperBound, end)
        // 5 分きざみ
        let t = BandRules.time(atX: 1, width: 240, dayStart: start, dayEnd: end)
        XCTAssertEqual(Int(t.timeIntervalSince(start)) % 300, 0)
        XCTAssertEqual(BandRules.label(at(2026, 11, 21, 10, 5)...at(2026, 11, 21, 11, 30), calendar: tokyo), "10:05〜11:30（85 分）")
    }

    func testForgetSummaryAndBody() {
        XCTAssertEqual(ForgetRules.summary(lines: 12, conversations: 2, audio: 3), "文字 12 行・会話 2 件・録音 3 個")
        XCTAssertEqual(ForgetRules.summary(lines: 0, conversations: 0, audio: 0), "文字 0 行・録音 0 個")
        let body = ForgetRules.pcBody(from: at(2026, 11, 21, 10), to: at(2026, 11, 21, 11), timeZone: tokyo.timeZone)!
        let object = try! JSONSerialization.jsonObject(with: body) as! [String: String]
        XCTAssertEqual(object["from"], "2026-11-21T10:00:00+09:00")
        XCTAssertEqual(object["to"], "2026-11-21T11:00:00+09:00")
        XCTAssertEqual(ForgetRules.undoSeconds, 30)
    }

    // MARK: - 体16・体17 通知のまとめ方

    func testDigestSlots() {
        let cal = tokyo
        XCTAssertEqual(NoticeDigestRules.nextSlot(after: at(2026, 11, 21, 6), calendar: cal), at(2026, 11, 21, 7, 30))
        XCTAssertEqual(NoticeDigestRules.nextSlot(after: at(2026, 11, 21, 8), calendar: cal), at(2026, 11, 21, 19))
        XCTAssertEqual(NoticeDigestRules.nextSlot(after: at(2026, 11, 21, 20), calendar: cal), at(2026, 11, 22, 7, 30))
        XCTAssertEqual(NoticeDigestRules.previousSlot(before: at(2026, 11, 21, 6), calendar: cal), at(2026, 11, 20, 19))
        XCTAssertEqual(NoticeDigestRules.previousSlot(before: at(2026, 11, 21, 12), calendar: cal), at(2026, 11, 21, 7, 30))
        XCTAssertTrue(NoticeDigestRules.isMorning(at(2026, 11, 21, 7, 30), calendar: cal))
        XCTAssertFalse(NoticeDigestRules.isMorning(at(2026, 11, 21, 19), calendar: cal))
    }

    func testUrgentNoticesSkipDigest() {
        // ボタンのある知らせ・録音が止まった・期限・署名の期限は急ぎ
        XCTAssertTrue(NoticeDigestRules.isUrgent(identifier: "x", category: "taskFound"))
        XCTAssertTrue(NoticeDigestRules.isUrgent(identifier: "phone-stopped", category: ""))
        XCTAssertTrue(NoticeDigestRules.isUrgent(identifier: "tasks-due-abc", category: ""))
        XCTAssertTrue(NoticeDigestRules.isUrgent(identifier: "signExpiry-1", category: ""))
        // 止まっているかも・提案は便りへ
        XCTAssertFalse(NoticeDigestRules.isUrgent(identifier: "fresh-plaud", category: ""))
        XCTAssertFalse(NoticeDigestRules.isUrgent(identifier: "proposal-1", category: ""))
    }

    func testDigestText() {
        let text = NoticeDigestRules.digest(titles: ["A", "B", "C", "D"], morning: true)
        XCTAssertEqual(text.title, "朝の便り：4 件")
        let lines = text.body.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)                      // なぜか／押すとどうなるか（題が何が起きたか）
        XCTAssertEqual(lines[0], "D・C・B など")
        XCTAssertTrue(lines[1].hasPrefix("押すと: "))
    }

    func testMuteKeepsUrgent() {
        XCTAssertTrue(NoticeHistoryRules.shouldDrop(kind: "proposal", muted: ["proposal"], urgent: false))
        XCTAssertFalse(NoticeHistoryRules.shouldDrop(kind: "proposal", muted: ["proposal"], urgent: true))
        XCTAssertFalse(NoticeHistoryRules.shouldDrop(kind: "fresh", muted: ["proposal"], urgent: false))
        let now = at(2026, 11, 21, 12)
        let old = NoticeLogEntry(id: "a", kind: "x", title: "古い", at: now.addingTimeInterval(-8 * 86400))
        let new = NoticeLogEntry(id: "b", kind: "x", title: "新しい", at: now.addingTimeInterval(-3600))
        XCTAssertEqual(NoticeHistoryRules.pruned([old, new], now: now).map(\.id), ["b"])
    }

    // MARK: - 体31 場面のセットの中身

    func testSceneSets() {
        XCTAssertEqual(LifeScene.allCases.map(\.label), ["ふだん", "休日", "会議", "旅行"])
        // 休日・会議・旅行は便りにまとめる。ふだんは戻す
        XCTAssertEqual(SceneSets.values(for: .usual)[.noticeDigest], false)
        for scene in [LifeScene.holiday, .meeting, .travel] { XCTAssertEqual(SceneSets.values(for: scene)[.noticeDigest], true) }
        // 録音が止まった知らせは、どの場面でも切らない
        for scene in LifeScene.allCases { XCTAssertNotEqual(SceneSets.values(for: scene)[.stopAlerts], false) }
        // 旅行は時計の外出モード、ふだんは外す・会議では家を出たときの促しを出さない
        XCTAssertEqual(SceneSets.values(for: .travel)[.awayMode], true)
        XCTAssertEqual(SceneSets.values(for: .usual)[.awayMode], false)
        XCTAssertEqual(SceneSets.values(for: .meeting)[.recordNudge], false)
        // 場面のスイッチは前からある設定の名前だけ
        XCTAssertTrue(SceneKey.allCases.map(\.rawValue).contains(HolidaySettings.venueHoldKey))
        XCTAssertTrue(SceneKey.allCases.map(\.rawValue).contains(DayPhotos.enabledKey))
        XCTAssertTrue(SceneSets.matches(.meeting) { SceneSets.values(for: .meeting)[$0] })
        XCTAssertFalse(SceneSets.matches(.meeting) { _ in nil })
    }

    // MARK: - 次10・体37 休む

    func testSleepWindow() {
        XCTAssertTrue(SleepPauseRules.inWindow(minute: 60, start: 30, end: 390))
        XCTAssertFalse(SleepPauseRules.inWindow(minute: 400, start: 30, end: 390))
        // 日をまたぐ
        XCTAssertTrue(SleepPauseRules.inWindow(minute: 23 * 60 + 30, start: 23 * 60, end: 6 * 60))
        XCTAssertTrue(SleepPauseRules.inWindow(minute: 5 * 60, start: 23 * 60, end: 6 * 60))
        XCTAssertFalse(SleepPauseRules.inWindow(minute: 12 * 60, start: 23 * 60, end: 6 * 60))
        // オフなら休まない・集中モードの印は 14 時間まで
        let noon = at(2026, 11, 21, 12)
        XCTAssertFalse(SleepPauseRules.shouldHold(enabled: false, now: at(2026, 11, 21, 2), start: 30, end: 390, focusSince: 0, calendar: tokyo))
        XCTAssertTrue(SleepPauseRules.shouldHold(enabled: true, now: at(2026, 11, 21, 2), start: 30, end: 390, focusSince: 0, calendar: tokyo))
        XCTAssertTrue(SleepPauseRules.shouldHold(enabled: true, now: noon, start: 30, end: 390,
                                                 focusSince: noon.addingTimeInterval(-3600).timeIntervalSince1970, calendar: tokyo))
        XCTAssertFalse(SleepPauseRules.shouldHold(enabled: true, now: noon, start: 30, end: 390,
                                                  focusSince: noon.addingTimeInterval(-15 * 3600).timeIntervalSince1970, calendar: tokyo))
        XCTAssertTrue(PersonPauseRules.holding(until: noon.addingTimeInterval(60).timeIntervalSince1970, now: noon))
        XCTAssertFalse(PersonPauseRules.holding(until: 0, now: noon))
    }

    // MARK: - 次15 電車の中の印

    func testTrainMark() {
        XCTAssertTrue(TrainRules.isTrain(movement: "電車・車で", inCar: false, place: "見本駅", scene: nil))
        XCTAssertTrue(TrainRules.isTrain(movement: "電車・車で", inCar: false, place: nil, scene: "電車"))
        XCTAssertFalse(TrainRules.isTrain(movement: "電車・車で", inCar: true, place: "見本駅", scene: "電車"))
        XCTAssertFalse(TrainRules.isTrain(movement: "歩きながら", inCar: false, place: "見本駅", scene: nil))
        XCTAssertFalse(TrainRules.isTrain(movement: "電車・車で", inCar: false, place: "見本の店", scene: nil))
        // 印は vehicle "train" だけ（inCar は付けない。車の印がある会話は変えない）
        let data = try! JSONSerialization.data(withJSONObject: ["conversations": [["start": "a"], ["start": "b", "vehicle": "car"]]])
        let marked = PCRecords.markTrain(data, flags: [true, true])
        let list = (try! JSONSerialization.jsonObject(with: marked) as! [String: Any])["conversations"] as! [[String: Any]]
        XCTAssertEqual(list[0]["vehicle"] as? String, "train")
        XCTAssertNil(list[0]["inCar"])
        XCTAssertEqual(list[1]["vehicle"] as? String, "car")
        XCTAssertEqual(PCRecords.markTrain(data, flags: [false, false]), data)
    }

    // MARK: - 次3・体11〜15 確かめ待ちの列

    private func item(_ id: String, kind: String = "ramen", q: String = "問い", expires: String? = nil, group: String? = nil) -> ReviewItem {
        ReviewItem(id: id, kind: kind, question: q, answer: "yesno", expires: expires, group: group)
    }

    func testReviewVisible() {
        let now = at(2026, 11, 21, 12)
        let items = [item("a", expires: "2026-11-20"), item("b", expires: "2026-11-21"), item("c", expires: "2026-12-01"), item("d")]
        let shown = ReviewRules.visible(items, answered: ["d"], later: ["c": "2026-11-21"], now: now, calendar: tokyo)
        XCTAssertEqual(shown.map(\.id), ["b"])  // 流れた a・あとでの c・答えた d は出さない
        let tomorrow = ReviewRules.visible(items, answered: [], later: ["c": "2026-11-21"], now: now.addingTimeInterval(86400),
                                           calendar: tokyo)
        XCTAssertEqual(tomorrow.map(\.id), ["c", "d"])
        XCTAssertEqual(ReviewRules.daysLeft(items[2], now: now, calendar: tokyo), 10)
        XCTAssertEqual(ReviewRules.daysLeft(items[1], now: now, calendar: tokyo), 0)
        XCTAssertNil(ReviewRules.daysLeft(items[3], now: now, calendar: tokyo))
    }

    func testReviewGroups() {
        let items = [item("a", kind: "with_people", group: "g1"), item("b", kind: "with_people", group: "g1"),
                     item("c", q: "同じ問い"), item("d", q: "同じ問い"), item("e", q: "ほか")]
        let groups = ReviewRules.groups(items)
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["a", "b"], ["c", "d"]])
    }

    func testReviewAnswerAndChange() {
        let body = ReviewRules.answerBody(id: "rq-1", answer: "yes", at: at(2026, 11, 21, 9), timeZone: tokyo.timeZone)!
        let object = try! JSONSerialization.jsonObject(with: body) as! [String: String]
        XCTAssertEqual(object, ["kind": "review", "id": "rq-1", "answer": "yes", "at": "2026-11-21T09:00:00+09:00"])
        XCTAssertNil(ReviewRules.answerBody(id: "id with space", answer: "yes", at: .now))
        XCTAssertEqual(ReviewRules.changedLine(ReviewDone(id: "x", changed: 4)), "この答えで 4 行が直りました")
        XCTAssertNil(ReviewRules.changedLine(ReviewDone(id: "x", changed: 0)))
        XCTAssertNil(ReviewRules.changedLine(nil))
    }

    func testReviewFeedDecodes() {
        let json = """
        {"version":1,"items":[{"id":"a","kind":"name","question":"q","answer":"pick","choices":["x","y"],
         "evidence":[{"text":"t","ref":"r"}],"expires":"2026-12-01","group":"g"}]}
        """
        let feed = try! JSONDecoder().decode(ReviewQueueFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.items?.first?.choices, ["x", "y"])
        XCTAssertNil(feed.done)
    }

    // MARK: - 次1・体26 検品表

    func testFeatureGrades() {
        typealias I = FeatureCheckFeed.Item
        XCTAssertEqual(FeatureCheckRules.grade(I(id: "a", name: "a", alive: false, used: 30)), "×")
        XCTAssertEqual(FeatureCheckRules.grade(I(id: "a", name: "a", alive: true, used: 10)), "A")
        XCTAssertEqual(FeatureCheckRules.grade(I(id: "a", name: "a", alive: true, used: 2)), "B")
        XCTAssertEqual(FeatureCheckRules.grade(I(id: "a", name: "a", used: nil)), "C")
        let body = FeatureCheckRules.answerBody(id: "s19-08", keep: false, at: at(2026, 11, 21, 9), timeZone: tokyo.timeZone)!
        let object = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(object["keep"] as? Bool, false)
        XCTAssertEqual(object["id"] as? String, "s19-08")
    }

    // MARK: - 体8 録音の丸

    func testCaptureDots() {
        let now = at(2026, 11, 21, 12)
        XCTAssertEqual(CaptureRules.watch(recording: true, resting: false, held: false, seen: now.addingTimeInterval(-60), now: now), .on)
        XCTAssertEqual(CaptureRules.watch(recording: nil, resting: nil, held: false, seen: nil, now: now), .unknown)
        if case .stopped = CaptureRules.watch(recording: true, resting: false, held: false, seen: now.addingTimeInterval(-7200), now: now) {
        } else { XCTFail("古い様子は止まっている") }
        if case .resting = CaptureRules.phone(recording: true, held: true) {} else { XCTFail("休む場所では休み") }
        XCTAssertEqual(CaptureRules.plaud(last: now.addingTimeInterval(-3600), stale: false, now: now), .on)
        XCTAssertNotNil(CaptureRules.fix(.plaud, CaptureRules.plaud(last: nil, stale: true, now: now)))
        XCTAssertNil(CaptureRules.fix(.phone, .on))
    }

    // MARK: - 体20・体22 時計

    func testWatchFace() {
        XCTAssertEqual(WatchFaceRules.hoursLeft(battery: 0.5, drainPerHour: 10), 5)
        XCTAssertEqual(WatchFaceRules.hoursLeft(battery: 0.45, drainPerHour: nil), 5)  // 45 / 9 = 5
        XCTAssertNil(WatchFaceRules.hoursLeft(battery: nil, drainPerHour: 10))
        XCTAssertEqual(WatchFaceRules.topActions(["mark", "drink", "ask", "fix"], counts: ["ask": 5, "fix": 5, "drink": 1]),
                       ["ask", "fix", "drink"])
        XCTAssertEqual(WatchFaceRules.topActions(["mark", "drink", "ask", "fix"], counts: [:]), ["mark", "drink", "ask"])
    }

    // MARK: - 体38 体験の数字

    func testUXMetrics() {
        var day = UXMetrics.Day()
        UXMetrics.addAnswer(&day, seconds: 2)
        UXMetrics.addAnswer(&day, seconds: 4)
        UXMetrics.addAnswer(&day, seconds: 600)  // 置きっぱなしは数えない
        XCTAssertEqual(day.answerSeconds, [2, 4])
        day.notifShown = 4
        day.notifOpened = 1
        let detail = UXMetrics.detail(day)
        XCTAssertEqual(detail["uxAnswerSeconds"] as? Double, 3)
        XCTAssertEqual(detail["uxNotifOpened"] as? Int, 1)
        XCTAssertNil(detail["uxNotifMuted"])
    }

    // MARK: - 体10・体24

    func testDayPartAndStory() {
        XCTAssertEqual(DayPart.of(at(2026, 11, 21, 7), calendar: tokyo), .morning)
        XCTAssertEqual(DayPart.of(at(2026, 11, 21, 14), calendar: tokyo), .day)
        XCTAssertEqual(DayPart.of(at(2026, 11, 21, 22), calendar: tokyo), .night)
        XCTAssertEqual(DayPart.of(at(2026, 11, 22, 2), calendar: tokyo), .night)
        XCTAssertTrue(StoryRules.isRamen("見本ラーメン"))
        XCTAssertFalse(StoryRules.isRamen("見本カフェ"))
        let pages = StoryRules.pages(conversations: 10, people: 0, places: 3, ramen: 2, holidays: 0, recordedHours: 5)
        XCTAssertEqual(pages.map(\.title), ["話した", "行った所", "ラーメン", "録った時間"])
        let r = StoryRules.range(month: true, containing: at(2026, 11, 21, 12), calendar: tokyo)
        XCTAssertEqual(r.start, at(2026, 11, 1, 0))
        XCTAssertEqual(r.end, at(2026, 12, 1, 0))
    }

    // MARK: - 体32 アップデートの案内

    func testWhatsNew() {
        // s21 で 3 つ足した（2026-11-22。s21 の 使4）
        XCTAssertEqual(WhatsNew.items.count, 6)
        XCTAssertEqual(WhatsNew.version, "s21")
        XCTAssertTrue(WhatsNew.items.allSatisfy { $0.key != nil })
        XCTAssertEqual(Set(WhatsNew.items.map(\.id)).count, WhatsNew.items.count)
    }
}

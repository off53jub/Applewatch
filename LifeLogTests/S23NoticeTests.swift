import CoreLocation
import UserNotifications
import XCTest
@testable import LifeLog

/// s23（2026-11-23）: 知らせを押したあと迷わない・場所の質問・確かめ・版。名前・場所はすべて作り物。
@MainActor
final class S23NoticeTests: XCTestCase {
    // MARK: 知1・知8 棚卸しと「押すと」の 1 行

    /// 2026-11-23 にコードにある知らせの名前（新しい知らせを足したら、ここと棚卸しの両方に足す）
    private let known: [(identifier: String, category: String)] = [
        ("taskFound", "taskFound"), ("tasks-due-abc", "taskDue"), ("tasks-1700000000", ""), ("work-digest-reminder", ""),
        ("brief-1700000000-見本の会議", ""), ("morning-brief", ""), ("askQuestions", ""), ("good-tonight", ""),
        ("payments-monthly", ""), ("cloud-monthly", ""), ("review-nudge", ""), ("morning-check", ""), ("home-pc", ""),
        ("pc-silent", ""), ("watch-silent", ""), ("phone-stopped", ""), ("watch-battery", ""), ("stall", ""),
        ("watch-not-recording", ""), ("watch-open-after-update", ""), ("fresh-plaud", ""), ("signExpiry-1", ""),
        ("proposal-x", ""), ("know-yesno", "knowYesNo"), ("know-weekly-talk", ""), ("know-geo-work", "knowGeo"),
        ("holiday-leave", ""), ("holiday-place-1700000000", "holidayPlace"), ("holiday-best-2026-11-23", "holidayNote"),
        ("s22-review-1", "s22review"), ("s22-who-1700000000", ""), ("digest-morning", ""), ("digest-evening", ""),
        ("notice-bundle", ""), ("placeask-1700000000", "placeAsk"), ("placeremind-123", ""), ("night-mood", ""),
        ("promise-abc", "promise"), ("s23-count-1700000000", "s23count"), ("s23-places-2026-11-23", ""), ("s23-version-500", ""),
    ]

    func testEveryKnownNoticeHasAnEntry() {
        XCTAssertEqual(S23NoticeCatalog.missing(known), [])
        XCTAssertEqual(S23NoticeCatalog.missing([("mystery-notice", "")]), ["mystery-notice"])
        for e in S23NoticeCatalog.entries {
            XCTAssertFalse(e.tap.isEmpty, e.title)
            XCTAssertTrue(e.tap.hasSuffix("。"), e.title)
        }
    }

    func testCategoryNamesMatchTheCode() {
        XCTAssertEqual(S23NoticeCatalog.entry(identifier: "x", category: PlaceAssistRules.askCategory)?.question, true)
        XCTAssertNotNil(S23NoticeCatalog.entry(identifier: "x", category: KnowMeRules.category))
        XCTAssertNotNil(S23NoticeCatalog.entry(identifier: "x", category: HolidayNoticeRules.placeCategory))
        XCTAssertNotNil(S23NoticeCatalog.entry(identifier: "x", category: HolidayNoticeRules.noteCategory))
        XCTAssertNotNil(S23NoticeCatalog.entry(identifier: "x", category: S22Notices.reviewCategory))
        XCTAssertNotNil(S23NoticeCatalog.entry(identifier: "x", category: PromiseRules.category))
        XCTAssertNotNil(S23NoticeCatalog.entry(identifier: "x", category: NoticeActions.foundCategory))
    }

    func testLongestPrefixWins() {
        XCTAssertEqual(S23NoticeCatalog.entry(identifier: "tasks-due-1", category: "")?.title, "もうすぐ期限です")
        XCTAssertEqual(S23NoticeCatalog.entry(identifier: "holiday-place-1", category: "")?.title, "さっきの所は〇〇？")
        XCTAssertEqual(S23NoticeCatalog.entry(identifier: "know-weekly-talk", category: "")?.title, "5 分しゃべる振り返り")
    }

    func testDecorateAddsTapAndLongPressOnce() {
        let entry = S23NoticeCatalog.entry(identifier: "x", category: "s22review")!
        let once = S23NoticeCatalog.decorate(body: "見本の問い", entry: entry)
        XCTAssertEqual(once, "見本の問い\n押すと、その問いの画面が開きます。長押しで選べます。")
        XCTAssertEqual(S23NoticeCatalog.decorate(body: once, entry: entry), once)
        XCTAssertTrue(S23NoticeCatalog.hasTapLine(once))
        // もう書いてある文はそのまま
        let place = S23NoticeCatalog.entry(identifier: "placeask-1", category: "placeAsk")!
        XCTAssertEqual(S23NoticeCatalog.decorate(body: PlaceAssistRules.askBody, entry: place), PlaceAssistRules.askBody)
        // ボタンの無い知らせには「長押し」を足さない
        let brief = S23NoticeCatalog.entry(identifier: "morning-brief", category: "")!
        XCTAssertFalse(S23NoticeCatalog.decorate(body: "見本", entry: brief).contains("長押し"))
        XCTAssertEqual(S23NoticeCatalog.decorate(body: "", entry: brief), "押すと、今日が開きます。")
    }

    // MARK: 知2〜知7・知12 押したときの行き先

    private let tapDefault = UNNotificationDefaultActionIdentifier

    func testDefaultActionConstantMatchesUserNotifications() {
        XCTAssertEqual(S23TapRules.defaultAction, UNNotificationDefaultActionIdentifier)
    }

    func testTapRoutes() {
        XCTAssertEqual(S23TapRules.tap(identifier: "s22-who-1700000000", category: "", action: tapDefault, userInfo: [:]),
                       .who("1700000000"))
        XCTAssertEqual(S23TapRules.tap(identifier: "know-yesno", category: "knowYesNo", action: tapDefault,
                                       userInfo: ["kid": "q1", "kkind": "hypothesis", "kday": "2026-11-23"]),
                       .knowMe(id: "q1", kind: "hypothesis", day: "2026-11-23"))
        XCTAssertEqual(S23TapRules.tap(identifier: "s22-review-1", category: "s22review", action: tapDefault, userInfo: ["id": "r1"]),
                       .review("r1"))
        XCTAssertEqual(S23TapRules.tap(identifier: "holiday-place-1", category: "holidayPlace", action: tapDefault,
                                       userInfo: ["hname": "見本の店", "lat": 35.0, "lon": 139.0, "hday": "2026-11-23"]),
                       .holidayPlace(name: "見本の店", latitude: 35.0, longitude: 139.0, day: "2026-11-23"))
        XCTAssertEqual(S23TapRules.tap(identifier: "taskFound", category: "taskFound", action: tapDefault, userInfo: ["ids": ["t1"]]),
                       .tasks(["t1"]))
        XCTAssertEqual(S23TapRules.tap(identifier: "placeremind-1", category: "", action: tapDefault, userInfo: ["ids": ["t2"]]),
                       .tasks(["t2"]))
        XCTAssertEqual(S23TapRules.tap(identifier: "p", category: "promise", action: tapDefault, userInfo: ["ids": ["p1"]]),
                       .promises(["p1"]))
        XCTAssertEqual(S23TapRules.tap(identifier: "watch-silent", category: "", action: tapDefault, userInfo: [:]), .status("watch-silent"))
        XCTAssertEqual(S23TapRules.tap(identifier: "know-geo-work", category: "knowGeo", action: tapDefault, userInfo: [:]), .tab(.today))
        XCTAssertEqual(S23TapRules.tap(identifier: "s23-places-2026-11-23", category: "", action: tapDefault, userInfo: [:]), .placesNight)
        XCTAssertEqual(S23TapRules.tap(identifier: "s23-version-5", category: "", action: tapDefault, userInfo: [:]), .checklist)
    }

    func testTapLeavesOthersAlone() {
        // ほかの所が受けるもの（ボタン・今までの行き先）は nil
        XCTAssertNil(S23TapRules.tap(identifier: "know-yesno", category: "knowYesNo", action: KnowMeRules.yesAction, userInfo: [:]))
        XCTAssertNil(S23TapRules.tap(identifier: "askQuestions", category: "", action: tapDefault, userInfo: [:]))
        XCTAssertNil(S23TapRules.tap(identifier: "taskFound", category: "taskFound", action: tapDefault, userInfo: [:]))
        XCTAssertNil(S23TapRules.tap(identifier: "taskFound", category: "taskFound", action: "keep", userInfo: ["ids": ["t1"]]))
    }

    func testLaterAndHeadcountButtons() {
        XCTAssertEqual(S23TapRules.tap(identifier: "s22-review-1", category: "s22review", action: S23TapRules.laterAction, userInfo: [:]),
                       .snooze(3600))
        XCTAssertEqual(S23TapRules.tap(identifier: "x", category: "holidayNote", action: S23TapRules.tonightAction, userInfo: [:]),
                       .snooze(nil))
        let info: [AnyHashable: Any] = ["start": 1_700_000_000.0, "day": "2026-11-23"]
        XCTAssertEqual(S23TapRules.tap(identifier: "s23-count-1", category: "s23count", action: "s23.n3", userInfo: info),
                       .headcount(start: 1_700_000_000, day: "2026-11-23", count: 3))
        XCTAssertEqual(S23TapRules.tap(identifier: "s23-count-1", category: "s23count", action: tapDefault, userInfo: info),
                       .headcount(start: 1_700_000_000, day: "2026-11-23", count: nil))
    }

    func testSnoozeTonightAndRoomForButtons() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let at15 = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 15))!
        XCTAssertEqual(S23TapRules.snoozeSeconds(nil, now: at15, calendar: cal), 6 * 3600)
        let at2030 = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 20, minute: 30))!
        XCTAssertEqual(S23TapRules.snoozeSeconds(nil, now: at2030, calendar: cal), 3600)
        XCTAssertEqual(S23TapRules.snoozeSeconds(3600, now: at15, calendar: cal), 3600)
        XCTAssertEqual(S23TapRules.laterActionsToAdd(existing: 2).count, 2)
        XCTAssertEqual(S23TapRules.laterActionsToAdd(existing: 3).count, 1)
        XCTAssertEqual(S23TapRules.laterActionsToAdd(existing: 4).count, 0)
    }

    func testCategoriesGetLaterButtonsWithinFour() {
        let all = S23Notices.categories(NoticeActions.categories())
        let review = all.first { $0.identifier == S22Notices.reviewCategory }
        XCTAssertEqual(review?.actions.map(\.identifier), [S22Notices.yesAction, S22Notices.noAction, S23TapRules.laterAction,
                                                           S23TapRules.tonightAction])
        for category in all { XCTAssertLessThanOrEqual(category.actions.count, 4, category.identifier) }
        XCTAssertEqual(all.first { $0.identifier == "s23count" }?.actions.count, 4)
        // 何度通しても増えない
        XCTAssertEqual(S23Notices.categories(all).first { $0.identifier == S22Notices.reviewCategory }?.actions.count, 4)
    }

    func testStatusCards() {
        for id in S23TapRules.statusIDs {
            let card = S23StatusRules.card(id)
            XCTAssertFalse(card.what.isEmpty)
            XCTAssertFalse(card.steps.isEmpty)
        }
        XCTAssertTrue(S23StatusRules.card("phone-stopped").record)
        XCTAssertFalse(S23StatusRules.card("stall").record)
    }

    // MARK: 知11・知13

    func testTapStatsSortByClosed() {
        let rows = S23TapStats.rows(["a|opened": 5, "a|answered": 5, "b|opened": 3, "b|closed": 3, "c|opened": 9, "c|closed": 1])
        XCTAssertEqual(rows.map(\.kind), ["b", "c", "a"])
        XCTAssertEqual(rows.first?.closed, 3)
    }

    func testMissedKeepsInfoAndPrunes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let info = S23MissedRules.info(["id": "r1", "n": 2, "cands": ["見本の店"], "lat": 35.5, 7: "捨てる"])
        XCTAssertEqual(info["id"], .text("r1"))
        XCTAssertEqual(info["cands"], .texts(["見本の店"]))
        let back = S23MissedRules.userInfo(info)
        XCTAssertEqual(back["n"] as? Int, 2)
        XCTAssertEqual(back["lat"] as? Double, 35.5)
        let old = S23MissedQuestion(id: "old", category: "", title: "", body: "", info: [:], at: now.addingTimeInterval(-4 * 86400))
        let later = S23MissedQuestion(id: "later", category: "", title: "", body: "", info: [:], at: now.addingTimeInterval(3600))
        let due = S23MissedQuestion(id: "due", category: "", title: "", body: "", info: [:], at: now.addingTimeInterval(-60))
        var list = S23MissedRules.adding([old], later, now: now)
        list = S23MissedRules.adding(list, due, now: now)
        XCTAssertEqual(list.map(\.id), ["due", "later"])
        XCTAssertEqual(S23MissedRules.due(list, now: now).map(\.id), ["due"])
        // 同じ名前は置き換える
        XCTAssertEqual(S23MissedRules.adding(list, due, now: now).count, 2)
    }

    // MARK: 場1・場2・場6

    func testIgnoreAndAutoName() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let here = (lat: 35.0000, lon: 139.0000)
        let near = S23PlacePoint(latitude: 35.0005, longitude: 139.0000, at: now)
        XCTAssertTrue(S23PlaceRules.isIgnored([near], latitude: here.lat, longitude: here.lon))
        XCTAssertFalse(S23PlaceRules.isIgnored([S23PlacePoint(latitude: 35.01, longitude: 139.0, at: now)], latitude: here.lat,
                                               longitude: here.lon))
        let a = S23PlacePoint(latitude: 35.001, longitude: 139.0, name: "見本の駅", at: now)
        let b = S23PlacePoint(latitude: 35.002, longitude: 139.0, name: "見本の駅", at: now)
        XCTAssertNil(S23PlaceRules.autoName([a], latitude: here.lat, longitude: here.lon))
        XCTAssertEqual(S23PlaceRules.autoName([a, b], latitude: here.lat, longitude: here.lon), "見本の駅")
        let other = S23PlacePoint(latitude: 35.0015, longitude: 139.0, name: "見本の公園", at: now)
        XCTAssertNil(S23PlaceRules.autoName([a, b, other], latitude: here.lat, longitude: here.lon))
    }

    func testTightenWhenFewAnswers() {
        XCTAssertFalse(S23PlaceRules.shouldTighten(asked: 9, answered: 0))
        XCTAssertTrue(S23PlaceRules.shouldTighten(asked: 10, answered: 2))
        XCTAssertFalse(S23PlaceRules.shouldTighten(asked: 10, answered: 3))
        let c = S23PlaceRules.counts(["placeask.scheduled": 10, "placeask.cancelled": 2, "placeask.answer.button": 3,
                                      "placeask.answer.typed": 1, "placeask.sheet.answered": 1])
        XCTAssertEqual(c.answered, 5)
        XCTAssertEqual(c.ignored, 3)
    }

    // MARK: 続5・続6

    func testHeadcountDueAndRow() {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let start = end.addingTimeInterval(-15 * 60)
        XCTAssertTrue(S23HeadcountRules.due(on: true, closed: true, start: start, end: end, media: false, otherLines: 5,
                                            alreadyAsked: false, askedToday: 0, now: end.addingTimeInterval(60)))
        XCTAssertFalse(S23HeadcountRules.due(on: true, closed: true, start: end.addingTimeInterval(-5 * 60), end: end, media: false,
                                             otherLines: 5, alreadyAsked: false, askedToday: 0, now: end.addingTimeInterval(60)))
        XCTAssertFalse(S23HeadcountRules.due(on: true, closed: true, start: start, end: end, media: false, otherLines: 5,
                                             alreadyAsked: false, askedToday: 2, now: end.addingTimeInterval(60)))
        XCTAssertFalse(S23HeadcountRules.due(on: true, closed: true, start: start, end: end, media: false, otherLines: 5,
                                             alreadyAsked: false, askedToday: 0, now: end.addingTimeInterval(30 * 60)))
        XCTAssertFalse(S23HeadcountRules.due(on: true, closed: false, start: start, end: end, media: false, otherLines: 5,
                                             alreadyAsked: false, askedToday: 0, now: end.addingTimeInterval(60)))
        XCTAssertNil(S23HeadcountRules.row(day: "2026-11-23", start: start, count: 1))
        let row = S23HeadcountRules.row(day: "2026-11-23", start: start, count: 3)
        XCTAssertEqual(row?.count, 3)
        let list = S23HeadcountRules.adding(S23HeadcountRules.adding([], row!), S23Headcount(day: "2026-11-23", start: row!.start, count: 4))
        XCTAssertEqual(list.map(\.count), [4])
    }

    func testHeadcountPostBodyAndOutboxFeature() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try XCTUnwrap(S23HeadcountRules.postBody(day: "2026-11-23", start: start, count: 5))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["count"] as? Int, 5)
        XCTAssertEqual(json["orMore"] as? Bool, true)
        XCTAssertEqual(json["day"] as? String, "2026-11-23")
        XCTAssertNotNil(json["start"] as? String)
        let three = try XCTUnwrap(S23HeadcountRules.postBody(day: "2026-11-23", start: start, count: 3))
        XCTAssertNil((try JSONSerialization.jsonObject(with: three) as? [String: Any])?["orMore"])
        XCTAssertNil(S23HeadcountRules.postBody(day: "あした", start: start, count: 3))
        XCTAssertEqual(MothershipOutbox.feature(for: "headcount"), "headcount")
    }

    func testNewReviewKinds() {
        XCTAssertEqual(ReviewRules.kindLabel("voice_pair"), "同じ人の声？")
        XCTAssertEqual(ReviewRules.kindLabel("見本の知らない種類"), "見本の知らない種類")
        XCTAssertTrue(S23ReviewRules.keepAsIs(kind: "gold_noisy"))
        XCTAssertFalse(S23ReviewRules.keepAsIs(kind: "voice_pair"))
        XCTAssertEqual(S22Rules.answerStyle(answer: "text", choices: nil), "text")
        XCTAssertEqual(S22Rules.answerStyle(answer: "yesno", choices: nil), "yesno")
        // 知らない kind・知らない answer の形でも、はい・いいえで答えられる
        XCTAssertEqual(S22Rules.answerStyle(answer: "mystery", choices: nil), "yesno")
    }

    func testPromiseAdvice() {
        XCTAssertTrue(S23PromiseRules.advice(.init(shown: 3)).contains("少ない"))
        XCTAssertTrue(S23PromiseRules.advice(.init(shown: 35, noticeIgnore: 20)).contains("1 回もありません"))
        XCTAssertTrue(S23PromiseRules.advice(.init(shown: 35, noticeAdd: 1, todayAdd: 4)).contains("「今日」"))
        let c = S23PromiseRules.counts(["notice.shown.promise": 35, "s23.promise.notice.ignore": 20])
        XCTAssertEqual(c.shown, 35)
        XCTAssertEqual(c.noticeIgnore, 20)
    }

    // MARK: 届4・届8

    func testVersionTagsAndNewer() {
        XCTAssertEqual(S23VersionRules.build(fromTag: "v2026.11.23-512"), 512)
        XCTAssertNil(S23VersionRules.build(fromTag: "v2026.11.23"))
        XCTAssertEqual(S23VersionRules.newer(current: 500, candidates: [nil, 499, 512]), 512)
        XCTAssertNil(S23VersionRules.newer(current: 512, candidates: [512, 400]))
        XCTAssertNil(S23VersionRules.newer(current: 0, candidates: [512]))
    }

    func testMorningDue() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let next7 = cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 7, minute: 5))!
        let next6 = cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 6))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 22))!
        XCTAssertTrue(S23VersionRules.morningDue(upgradedDay: "2026-11-23", sentFor: nil, build: 512, now: next7, calendar: cal))
        XCTAssertFalse(S23VersionRules.morningDue(upgradedDay: "2026-11-23", sentFor: nil, build: 512, now: next6, calendar: cal))
        XCTAssertFalse(S23VersionRules.morningDue(upgradedDay: "2026-11-23", sentFor: nil, build: 512, now: sameDay, calendar: cal))
        XCTAssertFalse(S23VersionRules.morningDue(upgradedDay: "2026-11-23", sentFor: 512, build: 512, now: next7, calendar: cal))
        XCTAssertFalse(S23VersionRules.morningDue(upgradedDay: nil, sentFor: nil, build: 512, now: next7, calendar: cal))
        let text = S23VersionRules.morningText(build: 512, ran: ["見本A", "見本B", "見本C", "見本D"], notYet: [])
        XCTAssertEqual(text.title, "版 512 で動いたもの・まだのもの")
        XCTAssertTrue(text.body.contains("動いたもの 4 個: 見本A・見本B・見本C など"))
        XCTAssertTrue(text.body.contains("まだのもの: ありません"))
    }

    // MARK: 試1・試5・試7

    func testAutoPassedFromCounts() {
        let passed = S23CheckRules.autoPassed(sums: ["s22.askClaude": 1, "s21.preset.battery": 2, "s22.review.watch": 0],
                                              notice: ["taskFound|open": 1], watchSame: true,
                                              done: ["s22-ask-claude": "ng"])
        XCTAssertTrue(passed.contains("s21-preset"))
        XCTAssertTrue(passed.contains("notice-open-tasks"))
        XCTAssertTrue(passed.contains("s22-watch-version"))
        // 本人が「動かなかった」にしたものは変えない・数が 0 のものは ○ にしない
        XCTAssertFalse(passed.contains("s22-ask-claude"))
        XCTAssertFalse(passed.contains("s22-watch-review"))
    }

    func testEvidenceIDsAreInTheChecklist() {
        let ids = Set(Checklist.items.map(\.id))
        for id in S23CheckRules.evidenceMap.keys { XCTAssertTrue(ids.contains(id), id) }
        for id in S23CheckRules.watchItems { XCTAssertTrue(ids.contains(id), id) }
        XCTAssertEqual(ids.count, Checklist.items.count, "確かめの id が重なっている")
    }

    func testPickTodayIsStable() {
        let ids = ["a", "b", "c", "d"]
        let first = S23CheckRules.pickToday(ids, day: "2026-11-23")
        XCTAssertNotNil(first)
        XCTAssertEqual(S23CheckRules.pickToday(ids, day: "2026-11-23"), first)
        XCTAssertNil(S23CheckRules.pickToday([], day: "2026-11-23"))
    }

    func testAskClaudeTextForFailedChecks() {
        let text = S23CheckRules.askClaudeText(failed: [(title: "見本の確かめ", how: "見本を押す")], phoneBuild: 512, watchBuild: "510")
        XCTAssertTrue(text.contains("iPhone の版 512・時計の版 510"))
        XCTAssertTrue(text.contains("1. 見本の確かめ"))
        XCTAssertEqual(S23CheckRules.failedLines([]), [])
        XCTAssertEqual(S23CheckRules.failedLines(["見本"]), ["実機の確かめで動かなかったもの: 見本"])
    }
}

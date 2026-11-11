import XCTest
@testable import LifeLog

/// 自分の声の候補・新しさ・PLAUD との差（2026-11-12。AppFeeds.swift）と、会う前のおさらいの足し（MeetingBriefPlus.swift）。
/// 名前はすべて作り物（エーさん・ビーさん）。
@MainActor
final class AppFeedsTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func fresh(_ key: String, stale: Bool, last: String? = nil) -> FreshItem {
        FreshItem(key: key, label: key.uppercased(), last_ok: last, limit_hours: 26, stale: stale)
    }

    private func item(_ what: String, from: String? = nil, kind: TaskBook.Kind? = nil,
                      progress: TaskBook.Progress? = nil, state: TaskBook.State = .open) -> TaskBook.Item {
        TaskBook.Item(what: what, from: from, said: Date(timeIntervalSince1970: 1_700_000_000),
                      source: .conversation, state: state, work: true, kind: kind, progress: progress)
    }

    // MARK: - 新しさ

    func testStaleNotifiesOncePerEpisode() {
        let a = fresh("line", stale: true), b = fresh("plaud", stale: false)
        var plan = AppFeeds.staleToNotify([a, b], notified: [])
        XCTAssertEqual(plan.notify.map(\.key), ["line"])
        // 止まったままなら、もう知らせない
        plan = AppFeeds.staleToNotify([a, b], notified: plan.remember)
        XCTAssertTrue(plan.notify.isEmpty)
        XCTAssertEqual(plan.remember, ["line"])
        // 戻ったら印を消す
        plan = AppFeeds.staleToNotify([fresh("line", stale: false), b], notified: plan.remember)
        XCTAssertTrue(plan.remember.isEmpty)
        // また止まったら知らせる
        plan = AppFeeds.staleToNotify([a, b], notified: plan.remember)
        XCTAssertEqual(plan.notify.map(\.key), ["line"])
    }

    func testFreshLine() {
        let line = AppFeeds.freshLine(fresh("line", stale: true, last: "2026-11-04T07:00:00+09:00"), timeZone: tokyo)
        XCTAssertEqual(line, "止まっているかも: LINE（最後 11/4 07:00）")
        XCTAssertEqual(AppFeeds.freshLine(fresh("x", stale: true)), "止まっているかも: X（まだ動いた記録がありません）")
        XCTAssertNotNil(AppFeeds.parseTime("2026-11-04T07:00:00.123Z"))
        XCTAssertNotNil(AppFeeds.parseTime("2026-11-04T07:00:00+0900"))
        XCTAssertNil(AppFeeds.parseTime("きのう"))
    }

    // MARK: - PLAUD

    func testMissingOfficialLine() {
        XCTAssertNil(AppFeeds.missingOfficialLine(nil))
        XCTAssertNil(AppFeeds.missingOfficialLine([]))
        XCTAssertEqual(AppFeeds.missingOfficialLine(["2026-11-09", "2026-11-08"]), "PLAUD の文字起こしがまだの日: 11/8・11/9")
        let many = (1...6).map { "2026-11-0\($0)" }
        XCTAssertEqual(AppFeeds.missingOfficialLine(many), "PLAUD の文字起こしがまだの日: 11/3・11/4・11/5・11/6 ほか2日")
    }

    func testScoreLineAndRows() {
        let feed = PlaudGapFeed(available: true, days: [
            PlaudGapDay(day: "2026-11-08", score: 80.4),
            PlaudGapDay(day: "2026-11-09", ratio: 0.25, gaps: [.init(from: "09:00", to: "09:30")], score: 41.6),
            PlaudGapDay(day: "2026-11-10"),
        ], missing_official: ["2026-11-10"])
        XCTAssertEqual(AppFeeds.latestScoreLine(feed), "PLAUD との合い方（11/9）: 42点")
        XCTAssertEqual(AppFeeds.briefLines(feed), ["PLAUD の文字起こしがまだの日: 11/10", "PLAUD との合い方（11/9）: 42点"])
        XCTAssertTrue(AppFeeds.briefLines(nil).isEmpty)
        let rows = AppFeeds.gapRows(feed)
        XCTAssertEqual(rows.map(\.label), ["11/10", "11/9", "11/8"])
        XCTAssertEqual(rows[1].value, "42点・抜け 1 か所・PLAUD に対して文字数 25%")
        XCTAssertEqual(rows[1].ok, false)
        XCTAssertNil(rows[0].ok)
    }

    // MARK: - 自分の声の候補

    func testBestLineIndexPicksNearestOfSameAudio() {
        let lines: [(audio: String?, offset: TimeInterval?)] = [
            ("a.m4a", 0), ("b.m4a", 10), ("a.m4a", 12), ("a.m4a", nil), (nil, 11), ("a.m4a", 20),
        ]
        XCTAssertEqual(AppFeeds.bestLineIndex(audio: "a.m4a", start: 10, in: lines), 2)
        XCTAssertEqual(AppFeeds.bestLineIndex(audio: "b.m4a", start: 11, in: lines), 1)
        // 近い行が無ければ見つけない
        XCTAssertNil(AppFeeds.bestLineIndex(audio: "a.m4a", start: 100, in: lines))
        XCTAssertNil(AppFeeds.bestLineIndex(audio: "c.m4a", start: 10, in: lines))
    }

    func testVisibleHidesAnsweredAndSortsByScore() {
        func c(_ id: String, _ score: Double) -> SelfCandidate {
            SelfCandidate(id: id, day: "2026-11-10", audio: "a.m4a", start: 0, end: 5, text: "", score: score, why: "plaud-match")
        }
        let list = AppFeeds.visible([c("1", 0.2), c("2", 0.9), c("3", 0.5)], hidden: ["3"])
        XCTAssertEqual(list.map(\.id), ["2", "1"])
    }

    func testPreviousDay() {
        XCTAssertEqual(Pipeline.previousDay(of: "2026-11-01"), "2026-10-31")
        XCTAssertNil(Pipeline.previousDay(of: "x"))
    }

    func testFeedsDecode() throws {
        let body = #"{"available":true,"items":[{"id":"c1","day":"2026-11-10","audio":"a.m4a","start":3,"end":9.5,"text":"お願いします","score":0.4,"why":"plaud-match"}]}"#
        let feed = try JSONDecoder().decode(SelfCandidateFeed.self, from: Data(body.utf8))
        XCTAssertEqual(feed.items?.first?.end, 9.5)
        let gap = #"{"available":true,"days":[{"day":"2026-11-09","gaps":[{"from":"09:00","to":"09:30"}],"score":40}],"missing_official":["2026-11-08"]}"#
        XCTAssertEqual(try JSONDecoder().decode(PlaudGapFeed.self, from: Data(gap.utf8)).days?.first?.gaps?.count, 1)
        let off = try JSONDecoder().decode(FreshnessFeed.self, from: Data(#"{"available":false,"reason":"x"}"#.utf8))
        XCTAssertFalse(off.available)
    }

    func testMorningCardShowsNotes() {
        var input = MorningBrief.Input(date: Date(timeIntervalSince1970: 1_700_000_000))
        input.notes = ["PLAUD の文字起こしがまだの日: 11/8"]
        XCTAssertTrue(MorningBrief.card(input).hasSuffix("PLAUD の文字起こしがまだの日: 11/8"))
    }

    // MARK: - 会う前のおさらい

    func testPromiseLines() {
        let asked = item("見積書を送る", from: "エーさん", kind: .asked)
        let waiting = item("資料の返事", from: "エーさん", kind: .delegated)
        let promise = item("来週会う", from: "エーさん", kind: .promise)
        let other = item("議事録", from: "ビーさん", kind: .asked)
        let done = item("終わったこと", from: "エーさん", kind: .asked, state: .done)
        let home = [MothershipTodo(id: "a", text: "契約書の確認", waitingFor: "エーさん"),
                    MothershipTodo(id: "b", text: "別の人待ち", waitingFor: "ビーさん"),
                    MothershipTodo(id: "c", text: "資料の返事", waitingFor: "エーさん")]
        let lines = Pipeline.promiseLines(name: "エーさん", tasks: [asked, waiting, promise, other, done], home: home)
        XCTAssertEqual(lines, ["頼まれごと 1 件: 見積書を送る", "約束・返事待ち 3 件: 資料の返事・来週会う"])
        XCTAssertTrue(Pipeline.promiseLines(name: "シーさん", tasks: [asked], home: home).isEmpty)
    }

    func testTopicsLine() {
        XCTAssertNil(Pipeline.topicsLine(titles: [nil, "  "]))
        XCTAssertEqual(Pipeline.topicsLine(titles: ["見積の相談", nil, "見積の相談", "日程", "予算", "四つ目"]),
                       "最近の話題: 見積の相談／日程／予算")
        XCTAssertEqual(Pipeline.briefClip("あいうえおかきくけこさしすせそたちつてと", 10), "あいうえおかきくけ…")
    }

    func testBriefLeadDefaultAndValidation() {
        let key = Pipeline.meetingBriefLeadKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Pipeline.meetingBriefLeadMinutes, 30)
        UserDefaults.standard.set(45, forKey: key)
        XCTAssertEqual(Pipeline.meetingBriefLeadMinutes, 45)
        UserDefaults.standard.set(7, forKey: key)
        XCTAssertEqual(Pipeline.meetingBriefLeadMinutes, 30)
    }
}

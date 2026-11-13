import XCTest
@testable import LifeLog

/// 2026-11-13 の施策（MothershipFeeds.swift）: 週のふり返り・会う前の一枚・朝のまとめの比べ・精度の通信簿・開かれていない画面の読み方、
/// 送る前にためるもの（使われ方・夜の10秒・アプリを開いた記録）、夜の10秒を出す時間、話し方の点。名前・言葉はすべて作り物。
@MainActor
final class MothershipFeedsTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func tokyoCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tokyo
        return cal
    }

    // MARK: - 週のふり返り・見立ての台帳

    func testWeeklyDropsBadRowsAndCuts() throws {
        let longTitle = String(repeating: "題", count: 50)
        let body = """
        {"available": true, "version": 1, "generated_at": "2026-11-16T21:00:00+09:00", "week": "2026-W46",
         "from": "2026-11-09", "to": "2026-11-15",
         "items": [
           {"id": "w-1", "kind": "theme", "title": "\(longTitle)", "body": "本文",
            "evidence": [{"day": "2026-11-10", "source": "conversation", "quote": "引用"},
                         {"day": "きのう", "quote": "日が変"}, {"day": "2026-11-11", "quote": ""}]},
           {"id": "w-1", "kind": "stuck", "title": "同じ id"},
           {"id": "w-2", "kind": "other", "title": "知らない種類"},
           {"id": "bad id!", "kind": "change", "title": "id が変"},
           {"id": "w-3", "kind": "change", "title": ""},
           {"id": "w-4", "kind": "stuck", "title": "進んでいない"},
           5
         ],
         "hypotheses": [
           {"id": "h-1", "text": "見立て", "said_on": "2026-10-01", "status": "alive", "note": "", "checked_on": null},
           {"id": "h-2", "text": "x", "status": "maybe"},
           {"id": "h-3", "text": "", "status": "alive"}
         ],
         "feedback": {"today_three": {"done": 3, "skipped": -1, "unknown": 2}, "proposal": {"accept": 1}, "brief_read": 4}}
        """
        let feed = try XCTUnwrap(MothershipFeeds.decodeWeekly(data(body)))
        XCTAssertEqual(feed.items.map(\.id), ["w-1", "w-4"])
        XCTAssertEqual(feed.items[0].title.count, 40)
        XCTAssertEqual(feed.items[0].evidence.count, 1)
        XCTAssertEqual(feed.week, "2026-W46")
        XCTAssertEqual(feed.from, "2026-11-09")
        XCTAssertEqual(feed.hypotheses.map(\.id), ["h-1"])
        XCTAssertNil(feed.hypotheses[0].checked_on)
        let fb = try XCTUnwrap(feed.feedback)
        XCTAssertEqual(fb.today_three, WeeklyFeed.Feedback.Three(done: 3, skipped: 0, unknown: 2))
        XCTAssertEqual(fb.proposal, WeeklyFeed.Feedback.Answers(accept: 1, later: 0, never: 0))
        XCTAssertEqual(fb.brief_read, 4)
        XCTAssertTrue(MothershipFeeds.feedbackLine(fb).contains("やった 3"))
    }

    func testWeeklyLimitsAndUnavailable() throws {
        var rows: [String] = []
        for i in 0..<9 { rows.append("{\"id\": \"w-\(i)\", \"kind\": \"theme\", \"title\": \"t\(i)\"}") }
        var hyps: [String] = []
        for i in 0..<40 { hyps.append("{\"id\": \"h-\(i)\", \"text\": \"x\", \"status\": \"unknown\"}") }
        let body = "{\"items\": [" + rows.joined(separator: ",") + "], \"hypotheses\": [" + hyps.joined(separator: ",") + "], \"feedback\": null, \"week\": \"46\"}"
        let feed = try XCTUnwrap(MothershipFeeds.decodeWeekly(data(body)))
        XCTAssertEqual(feed.items.count, 5)
        XCTAssertEqual(feed.hypotheses.count, 30)
        XCTAssertNil(feed.feedback)
        XCTAssertNil(feed.week)
        XCTAssertNil(MothershipFeeds.decodeWeekly(data("{\"available\": false, \"reason\": \"まだ\"}")))
        XCTAssertNil(MothershipFeeds.decodeWeekly(data("[1]")))
    }

    func testWeekAndMonthShapes() {
        XCTAssertTrue(MothershipFeeds.isWeek("2026-W46"))
        XCTAssertFalse(MothershipFeeds.isWeek("2026-46"))
        XCTAssertFalse(MothershipFeeds.isWeek("2026-w46"))
        XCTAssertTrue(MothershipFeeds.isMonth("2026-11"))
        XCTAssertFalse(MothershipFeeds.isMonth("2026/11"))
        XCTAssertEqual(MothershipFeeds.weekLabel(week: "2026-W46", from: "2026-11-09", to: "2026-11-15"), "11/9〜11/15")
        XCTAssertEqual(MothershipFeeds.weekLabel(week: "2026-W46", from: nil, to: nil), "2026-W46")
    }

    // MARK: - 会う前の一枚

    func testPrepDropsBadRowsAndSorts() throws {
        let body = """
        {"items": [
          {"id": "e-2", "start": "2026-11-14T11:00:00+09:00", "end": null, "title": "あと",
           "people": ["見本 花子", 3, ""], "last_talk": {"day": "x", "summary": "日が変"}},
          {"id": "e-1", "start": "2026-11-14T10:00:00+09:00", "end": "2026-11-14T10:30:00+09:00", "title": "さき",
           "last_talk": {"day": "2026-11-01", "summary": "前回の話"}, "promises": ["約束"], "recent": []},
          {"id": "e-3", "start": "あした", "title": "時刻が変"},
          {"id": "e-4", "start": "2026-11-14T10:00:00+09:00", "end": "2026-11-14T09:00:00+09:00", "title": "終わりが前"},
          {"id": "e-5", "start": "2026-11-14T10:00:00+09:00", "title": ""}
        ]}
        """
        let feed = try XCTUnwrap(MothershipFeeds.decodePrep(data(body)))
        XCTAssertEqual(feed.items.map(\.id), ["e-1", "e-2"])
        XCTAssertEqual(feed.items[1].people, ["見本 花子"])
        XCTAssertNil(feed.items[1].last_talk)
        XCTAssertEqual(feed.items[0].last_talk?.summary, "前回の話")
        XCTAssertEqual(MothershipFeeds.prepTime(feed.items[0], timeZone: tokyo), "10:00〜10:30")
        XCTAssertEqual(MothershipFeeds.prepTime(feed.items[1], timeZone: tokyo), "11:00〜")
    }

    func testNextPrepWithinThreeHours() throws {
        let now = try XCTUnwrap(AppFeeds.parseTime("2026-11-14T08:00:00+09:00"))
        let soon = PrepItem(id: "a", start: "2026-11-14T10:30:00+09:00", title: "2時間半あと")
        let far = PrepItem(id: "b", start: "2026-11-14T11:30:00+09:00", title: "3時間半あと")
        let started = PrepItem(id: "c", start: "2026-11-14T07:55:00+09:00", title: "5分前に始まった")
        let old = PrepItem(id: "d", start: "2026-11-14T07:00:00+09:00", title: "1時間前")
        XCTAssertEqual(MothershipFeeds.nextPrep([far, soon], now: now)?.id, "a")
        XCTAssertEqual(MothershipFeeds.nextPrep([soon, started], now: now)?.id, "c")
        XCTAssertNil(MothershipFeeds.nextPrep([far, old], now: now))
        XCTAssertNil(MothershipFeeds.nextPrep([], now: now))
    }

    // MARK: - 朝のまとめの比べ・精度の通信簿・開かれていない画面

    func testCompareNeedsBothAndKeepsNewest() throws {
        var rows: [String] = []
        for d in 1...9 { rows.append("{\"day\": \"2026-10-0\(d)\", \"codex\": \"a\", \"claude\": \"b\"}") }
        rows.append("{\"day\": \"2026-11-12\", \"codex\": \"一行目\\n二行目\", \"claude\": \"c\"}")
        rows.append("{\"day\": \"2026-11-13\", \"codex\": \"片方だけ\", \"claude\": \"\"}")
        rows.append("{\"day\": \"2026-11-12\", \"codex\": \"同じ日\", \"claude\": \"同じ日\"}")
        let feed = try XCTUnwrap(MothershipFeeds.decodeCompare(data("{\"days\": [" + rows.joined(separator: ",") + "]}")))
        XCTAssertEqual(feed.days.count, 7)
        XCTAssertEqual(feed.days[0].day, "2026-11-12")
        XCTAssertEqual(feed.days[0].codex, "一行目\n二行目")
        XCTAssertFalse(feed.days.contains { $0.day == "2026-11-13" })
    }

    func testAccuracyKeepsRowsWithNulls() throws {
        let body = """
        {"weeks": [
          {"week": "2026-W45", "caught_self": 0.7, "caught_other": 1.5, "person_n_kinds_median": 80,
           "fix_kept_ratio": null, "judge_agree": 0.5, "night_review_kept": null, "speaking_score": 61.5},
          {"week": "2026-W46", "person_n_kinds_median": 2.5, "speaking_score": 120},
          {"week": "46", "caught_self": 0.1},
          {"week": "2026-W45", "caught_self": 0.2}
        ]}
        """
        let feed = try XCTUnwrap(MothershipFeeds.decodeAccuracy(data(body)))
        XCTAssertEqual(feed.weeks.map(\.week), ["2026-W46", "2026-W45"])
        let w45 = feed.weeks[1]
        XCTAssertEqual(w45.caught_self, 0.7)
        XCTAssertNil(w45.caught_other)
        XCTAssertEqual(w45.person_n_kinds_median, 80)
        XCTAssertNil(w45.fix_kept_ratio)
        XCTAssertNil(feed.weeks[0].person_n_kinds_median)
        XCTAssertNil(feed.weeks[0].speaking_score)
        XCTAssertEqual(MothershipFeeds.percent(0.724), "72%")
        XCTAssertEqual(MothershipFeeds.percent(nil), "—")
        XCTAssertEqual(MothershipFeeds.number(nil), "—")
        XCTAssertEqual(MothershipFeeds.score(61.5), "62")
    }

    func testUnusedDropsBadCounts() throws {
        let body = """
        {"month": "2026-11", "items": [
          {"screen": "goodThings", "opens": 0, "days": 30, "note": "メモ"},
          {"screen": "goodThings", "opens": 1, "days": 30},
          {"screen": "money", "opens": -1, "days": 30},
          {"screen": "", "opens": 0, "days": 30},
          {"screen": "ask", "opens": "2", "days": 30}
        ]}
        """
        let feed = try XCTUnwrap(MothershipFeeds.decodeUnused(data(body)))
        XCTAssertEqual(feed.month, "2026-11")
        XCTAssertEqual(feed.items.map(\.screen), ["goodThings"])
        XCTAssertEqual(MothershipFeeds.screenName("goodThings"), "いいこと帳")
        XCTAssertEqual(MothershipFeeds.screenName("知らない画面"), "知らない画面")
    }

    // MARK: - 送る前にためるもの

    private struct FeedbackRow: Decodable, Equatable {
        let kind: String
        let id: String
        let value: String
        let day: String
    }

    func testFeedbackBodyOnlyForKnownPairs() throws {
        let body = try XCTUnwrap(MothershipOutbox.feedbackBody(kind: "today_three", id: "t:abc", value: "done", day: "2026-11-13"))
        XCTAssertEqual(try JSONDecoder().decode(FeedbackRow.self, from: body),
                       FeedbackRow(kind: "today_three", id: "t:abc", value: "done", day: "2026-11-13"))
        XCTAssertNotNil(MothershipOutbox.feedbackBody(kind: "brief_compare", id: "cmp-2026-11-13", value: "claude", day: "2026-11-13"))
        XCTAssertNil(MothershipOutbox.feedbackBody(kind: "brief", id: "x", value: "done", day: "2026-11-13"))
        XCTAssertNil(MothershipOutbox.feedbackBody(kind: "nope", id: "x", value: "ok", day: "2026-11-13"))
        XCTAssertNil(MothershipOutbox.feedbackBody(kind: "bulk", id: "bad id!", value: "ok", day: "2026-11-13"))
        XCTAssertNil(MothershipOutbox.feedbackBody(kind: "bulk", id: "x", value: "ok", day: "11/13"))
    }

    func testMoodBodyRangesAndNote() throws {
        let at = try XCTUnwrap(AppFeeds.parseTime("2026-11-13T21:40:00+09:00"))
        let body = try XCTUnwrap(MothershipOutbox.moodBody(day: "2026-11-13", at: at, mood: 4, energy: 1, grip: 5,
                                                           note: "  ひとこと ", timeZone: tokyo))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["at"] as? String, "2026-11-13T21:40:00+09:00")
        XCTAssertEqual(obj["energy"] as? Int, 1)
        XCTAssertEqual(obj["note"] as? String, "ひとこと")
        let plain = try XCTUnwrap(MothershipOutbox.moodBody(day: "2026-11-13", at: at, mood: 3, energy: 3, grip: 3, note: nil))
        let plainObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(plainObj["note"])
        XCTAssertNil(MothershipOutbox.moodBody(day: "2026-11-13", at: at, mood: 0, energy: 3, grip: 3, note: nil))
        XCTAssertNil(MothershipOutbox.moodBody(day: "2026-11-13", at: at, mood: 3, energy: 6, grip: 3, note: nil))
        XCTAssertNil(MothershipOutbox.moodBody(day: "きょう", at: at, mood: 3, energy: 3, grip: 3, note: nil))
        let long = try XCTUnwrap(MothershipOutbox.moodBody(day: "2026-11-13", at: at, mood: 3, energy: 3, grip: 3,
                                                           note: String(repeating: "あ", count: 300)))
        let longObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: long) as? [String: Any])
        XCTAssertEqual((longObj["note"] as? String)?.count, 200)
    }

    func testAppUsageBody() throws {
        let at = try XCTUnwrap(AppFeeds.parseTime("2026-11-13T21:40:00+09:00"))
        let body = try XCTUnwrap(MothershipOutbox.appUsageBody(at: at, app: " 見本アプリ ", event: "open", timeZone: tokyo))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["app"] as? String, "見本アプリ")
        XCTAssertEqual(obj["event"] as? String, "open")
        XCTAssertNil(MothershipOutbox.appUsageBody(at: at, app: "  ", event: "open"))
        XCTAssertNil(MothershipOutbox.appUsageBody(at: at, app: "見本", event: "launch"))
        XCTAssertNotNil(MothershipOutbox.appUsageBody(at: at, app: "見本", event: "focus_off"))
    }

    private func item(_ id: String, _ path: String) -> OutboxItem {
        OutboxItem(id: id, path: path, body: Data("{}".utf8), queued: Date(timeIntervalSince1970: 0))
    }

    func testQueueDropsOldAppUsageFirst() {
        var list: [OutboxItem] = []
        list = MothershipOutbox.appending(list, item("f1", "feedback"), limit: 3)
        list = MothershipOutbox.appending(list, item("a1", "app-usage"), limit: 3)
        list = MothershipOutbox.appending(list, item("m1", "mood"), limit: 3)
        list = MothershipOutbox.appending(list, item("f2", "feedback"), limit: 3)
        XCTAssertEqual(list.map(\.id), ["f1", "m1", "f2"])
        list = MothershipOutbox.appending(list, item("f3", "feedback"), limit: 3)
        XCTAssertEqual(list.map(\.id), ["m1", "f2", "f3"])
        XCTAssertEqual(MothershipOutbox.removing(list, id: "f2").map(\.id), ["m1", "f3"])
    }

    func testQueueFailingCountsAndDrops() {
        var list: [OutboxItem] = [item("a", "feedback"), item("b", "mood")]
        list = MothershipOutbox.failing(list, id: "a", maxTries: 2)
        XCTAssertEqual(list.first?.tries, 1)
        XCTAssertEqual(list.count, 2)
        list = MothershipOutbox.failing(list, id: "a", maxTries: 2)
        XCTAssertEqual(list.map(\.id), ["b"])
        XCTAssertNil(list[0].tries)
    }

    func testQueueSurvivesRoundTrip() throws {
        let list: [OutboxItem] = [item("a", "feedback"), item("b", "app-usage")]
        let data = try JSONEncoder().encode(list)
        XCTAssertEqual(try JSONDecoder().decode([OutboxItem].self, from: data), list)
        XCTAssertEqual(MothershipOutbox.feature(for: "app-usage"), "appusage")
        XCTAssertEqual(MothershipOutbox.feature(for: "feedback"), "feedback")
        XCTAssertEqual(MothershipOutbox.feature(for: "mood"), "mood")
    }

    func testLocalReadsOldAndEmptyFiles() throws {
        let empty = try JSONDecoder().decode(MothershipLocal.self, from: data("{}"))
        XCTAssertEqual(empty, MothershipLocal())
        let partial = try JSONDecoder().decode(MothershipLocal.self, from: data("{\"moodDay\": \"2026-11-13\"}"))
        XCTAssertEqual(partial.moodDay, "2026-11-13")
        XCTAssertTrue(partial.voted.isEmpty)
    }

    func testLocalPrunesOldPickDays() {
        var local = MothershipLocal()
        for d in 1...9 { local.picks["2026-11-0\(d)"] = [PickRef(fid: "x:\(d)")] }
        local.picks["2026-12-01"] = [PickRef(fid: "x:future")]
        let pruned = MothershipLocal.pruned(local, today: "2026-11-09", keepDays: 7)
        XCTAssertNil(pruned.picks["2026-11-01"])
        XCTAssertNil(pruned.picks["2026-12-01"])
        XCTAssertNotNil(pruned.picks["2026-11-09"])
    }

    // MARK: - 今日の三つの印

    func testPickIDPrefersHomeThenTaskThenHash() {
        var pick = MorningBrief.Pick(text: "見本の資料を送る", why: "")
        let hashed = MothershipFeeds.pickID(pick)
        XCTAssertTrue(hashed.hasPrefix("x:"))
        XCTAssertTrue(HomeFeeds.isID(hashed))
        XCTAssertEqual(hashed, MothershipFeeds.pickID(pick))  // 同じ文なら同じ印
        pick.taskID = "1234-ABCD"
        XCTAssertEqual(MothershipFeeds.pickID(pick), "t:1234-ABCD")
        pick.homeID = "todo-7"
        XCTAssertEqual(MothershipFeeds.pickID(pick), "h:todo-7")
        pick.homeID = "日本語の id"
        XCTAssertEqual(MothershipFeeds.pickID(pick), "t:1234-ABCD")
        XCTAssertEqual(MothershipFeeds.hash(""), "cbf29ce484222325")
    }

    // MARK: - 夜の10秒を出す時間

    func testNightWindow() throws {
        let cal = tokyoCalendar()
        func at(_ day: Int, _ hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: 5))!
        }
        XCTAssertNil(NightMood.windowDay(at(13, 19), calendar: cal))
        XCTAssertEqual(NightMood.windowDay(at(13, 20), calendar: cal), "2026-11-13")
        XCTAssertEqual(NightMood.windowDay(at(13, 23), calendar: cal), "2026-11-13")
        XCTAssertEqual(NightMood.windowDay(at(14, 1), calendar: cal), "2026-11-13")
        XCTAssertNil(NightMood.windowDay(at(14, 4), calendar: cal))
        XCTAssertNil(NightMood.windowDay(at(14, 12), calendar: cal))
    }

    // MARK: - 話し方の点（20）

    func testSpeakingScore() throws {
        XCTAssertNil(SpeakStats.score(SpeakStats()))
        // 話す割合 40%・口ぐせ 0・質問 会話1つに2 → 100
        let best = SpeakStats(conversations: 2, selfLines: 10, selfChars: 400, selfSeconds: 120, totalChars: 1000,
                              fillers: 0, questions: 4, tense: 0)
        XCTAssertEqual(try XCTUnwrap(SpeakStats.score(best)), 100, accuracy: 0.001)
        // 話す割合 80%（0点）・口ぐせ 千字に15（半分）・質問 会話1つに1（半分）→ 0.4*0 + 0.3*0.5 + 0.3*0.5 = 0.3
        let mid = SpeakStats(conversations: 2, selfLines: 10, selfChars: 800, selfSeconds: 120, totalChars: 1000,
                             fillers: 12, questions: 2, tense: 0)
        XCTAssertEqual(try XCTUnwrap(SpeakStats.score(mid)), 30, accuracy: 0.001)
        // 短くて口ぐせが測れないときは、残りの重みで割り直す（割合 40%・質問 0 → 0.4 / 0.7）
        let short = SpeakStats(conversations: 1, selfLines: 1, selfChars: 40, selfSeconds: 10, totalChars: 100,
                               fillers: 0, questions: 0, tense: 0)
        XCTAssertEqual(try XCTUnwrap(SpeakStats.score(short)), 100 * 0.4 / 0.7, accuracy: 0.001)
        XCTAssertEqual(SpeakStats.scoreChange(now: 72.4, before: 66.6), "先月より +5")
        XCTAssertEqual(SpeakStats.scoreChange(now: 60, before: 63), "先月より −3")
        XCTAssertEqual(SpeakStats.scoreChange(now: 60.2, before: 59.9), "先月と同じ")
        XCTAssertNil(SpeakStats.scoreChange(now: 60, before: nil))
    }
}

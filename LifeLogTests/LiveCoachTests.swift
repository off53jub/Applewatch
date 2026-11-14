import XCTest
@testable import LifeLog

/// 2026-11-15（強化案 50・51・52・59）: 会議の相棒・今夜のコーチ・緊張した場面の読み方、心拍の送る窓と中身、読み上げの文。
/// 名前・言葉はすべて作り物。
@MainActor
final class LiveCoachTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - 会議の相棒（50）

    func testMeetingFeedKeepsPreviousItemsWhenUnchanged() {
        let first = data("""
        {"available":true,"on":true,"started_at":"2026-11-15T10:00:00+09:00","title":"見本の定例","version":2,"changed":true,
         "decided":[{"id":"abc123","text":"見本の決定","quote":"見本の言葉"},{"id":"../x","text":"落とす"}],
         "homework":[{"id":"def456","text":"見本の宿題","quote":""}],"unasked":[],"latest":["宿 見本の宿題"],
         "delay":{"last":42.5}}
        """)
        guard let feed = MeetingLive.decode(first, previous: nil) else { return XCTFail("読めない") }
        XCTAssertEqual(feed.decided.map(\.id), ["abc123"])
        XCTAssertEqual(feed.homework.first?.text, "見本の宿題")
        XCTAssertEqual(feed.delay, 42.5)
        let same = data("{\"available\":true,\"on\":true,\"version\":2,\"changed\":false,\"latest\":[]}")
        let kept = MeetingLive.decode(same, previous: feed)
        XCTAssertEqual(kept?.decided.count, 1)
        XCTAssertEqual(kept?.homework.count, 1)
        XCTAssertNil(MeetingLive.decode(data("{\"available\":false,\"reason\":\"x\"}"), previous: feed))
    }

    func testMeetingContentStateFallsBackToFirstItems() {
        var feed = MeetingLiveFeed(on: true)
        feed.homework = [MeetingLiveItem(id: "a1", text: "見本の宿題")]
        feed.unasked = [MeetingLiveItem(id: "b1", text: "見本の問い")]
        let state = MeetingLive.contentState(feed, started: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(state.homework, 1)
        XCTAssertEqual(state.lines, ["宿 見本の宿題", "聞 見本の問い"])
        XCTAssertEqual(MeetingLive.watchItems(feed), ["宿 見本の宿題", "聞 見本の問い"])
    }

    func testMeetingStateBody() throws {
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        let body = try XCTUnwrap(MeetingLive.stateBody(on: true, start: start, title: "見本", claude: true, work: true,
                                                       workOK: false, mine: [(start, "見本の自分の文")]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["on"] as? Bool, true)
        XCTAssertEqual(object["work_ok"] as? Bool, false)
        XCTAssertEqual((object["mine"] as? [[String: String]])?.count, 1)
        XCTAssertEqual(object["start"] as? String, PCJSON.string(start))
    }

    // MARK: - 今夜のコーチ（51）

    func testCoachDropsBadAudioName() {
        let feed = CoachFeeds.decodeCoach(data("""
        {"available":true,"day":"2026-11-15",
         "good":{"text":"見本のよい一言","why":"見本","time":"2026-11-15T10:00:00+09:00","audio":"20261115-100000.m4a","offset":3.5,"end":8},
         "improve":{"text":"見本の直す一言","why":"見本","better":"見本の言い直し","time":"2026-11-15T11:00:00+09:00","audio":"../秘密","offset":1},
         "week":{"from":"2026-11-09","to":"2026-11-15","lines":10,"conclusion_first":0.5,"judged":4,"filler_per_min":1.2,
                 "questions":3,"talk_share_meetings":1.5,"meetings":1,"meeting_source":"guess"},
         "rehearse":{"seeds":2,"first":"見本の題"}}
        """))
        XCTAssertEqual(feed?.good?.audio, "20261115-100000.m4a")
        XCTAssertEqual(feed?.good?.end, 8)
        XCTAssertNil(feed?.improve?.audio)
        XCTAssertEqual(feed?.improve?.better, "見本の言い直し")
        XCTAssertNil(feed?.week.talkShareMeetings)
        XCTAssertEqual(feed?.seeds, 2)
        let lines = CoachFeeds.weekLines(feed?.week ?? CoachWeek())
        XCTAssertTrue(lines.first?.contains("50%") ?? false)
        XCTAssertFalse(CoachFeeds.isAudioName(".hidden"))
    }

    // MARK: - 緊張した場面（52）

    func testTensionDropsBadRowsAndSortsNewestFirst() {
        let feed = CoachFeeds.decodeTension(data("""
        {"available":true,"from":"2026-11-09","to":"2026-11-15","source":"minute",
         "items":[{"id":"t-1","day":"2026-11-14","start":"2026-11-14T10:00:00+09:00","peak_bpm":110,"baseline_bpm":62},
                  {"id":"t-2","day":"2026-11-15","start":"2026-11-15T10:00:00+09:00","peak_bpm":105,"baseline_bpm":62,
                   "conversation":{"title":"見本の会議","people":["見本さん"],"place":"見本の部屋"}},
                  {"id":"t-3","day":"2026-11-15","start":"きのう","peak_bpm":105,"baseline_bpm":62},
                  {"id":"t-4","day":"2026-11-15","start":"2026-11-15T11:00:00+09:00","peak_bpm":400,"baseline_bpm":62}],
         "by_person":[{"name":"見本さん","times":1,"of":3}],"by_topic":[{"word":"見本","times":2}]}
        """))
        XCTAssertEqual(feed?.items.map(\.id), ["t-2", "t-1"])
        XCTAssertEqual(feed?.items.first?.talk?.people, ["見本さん"])
        XCTAssertEqual(feed?.people.first?.of, 3)
        XCTAssertEqual(feed?.source, "minute")
    }

    func testHeartWindowAndBody() throws {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let fresh = HeartMinutes.window(sent: 0, now: now)
        XCTAssertEqual(fresh.to, now)
        XCTAssertEqual(fresh.from, now.addingTimeInterval(-24 * 3600))
        let old = HeartMinutes.window(sent: now.timeIntervalSince1970 - 30 * 86400, now: now)
        XCTAssertEqual(old.from, now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(old.to, old.from.addingTimeInterval(24 * 3600))
        let body = try XCTUnwrap(HeartMinutes.body(heart: [(now, 72.4), (now, 999)], steps: [(now, 12)]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let samples = try XCTUnwrap(object["samples"] as? [[String: Int]])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?["bpm"], 72)
    }

    // MARK: - 声で聞く・耳で聞く（59）

    func testSpokenTextAndMorningScript() {
        XCTAssertEqual(VoiceRecall.spoken("**見本**の答え [1][2]"), "見本の答え")
        let script = VoiceRecall.morningScript("・見本の流れ\n★ 見本の印\n\n見本の予定")
        XCTAssertTrue(script.hasPrefix("おはようございます。"))
        XCTAssertTrue(script.contains("見本の流れ。"))
        XCTAssertFalse(script.contains("★"))
        let long = VoiceRecall.morningScript(String(repeating: "見本の行\n", count: 400))
        XCTAssertLessThanOrEqual(long.count, VoiceRecall.morningChars + 20)
    }
}

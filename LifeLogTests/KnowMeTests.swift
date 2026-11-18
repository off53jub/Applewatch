import XCTest
@testable import LifeLog

/// 2026-11-19（s18 自分を知ってもらう）: 見立て・1 日 1 問・抜き打ちの読み方、1 日 3 問の選び方、送る中身、場所の見張り、
/// 時計の「違う、〇〇さん」に添える行、ヘルスケアの運動。名前・言葉はすべて作り物。
@MainActor
final class KnowMeTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func object(_ d: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(d)) as? [String: Any])
    }

    // MARK: 読む

    func testHypothesesNeedEvidenceAndKeepTier() throws {
        let body = """
        {"available": true, "items": [
         {"id": "h-1", "text": "朝は一人で準備したい人", "kind": "hypothesis.taste", "tier": "tentative", "confidence": 0.7,
          "evidence": [{"text": "朝は静かなほうがいい", "day": "2026-11-18", "conversation_start": "2026-11-18T07:34:10+09:00"}]},
         {"id": "h-2", "text": "根拠なし", "evidence": []},
         {"id": "h-1", "text": "重なり", "evidence": [{"text": "x"}]},
         {"id": "h 3", "text": "おかしな id", "evidence": [{"text": "x"}]},
         "壊れた行"]}
        """
        let got = try XCTUnwrap(KnowMeRules.decodeHypotheses(data(body)))
        XCTAssertEqual(got.map(\.id), ["h-1"])
        XCTAssertEqual(got[0].label, "見立て（仮）")
        XCTAssertEqual(got[0].tier, "tentative")
        XCTAssertEqual(got[0].evidence.first?.day, "2026-11-18")
        XCTAssertNil(KnowMeRules.decodeHypotheses(data(#"{"available": false, "reason": "まだ"}"#)))
    }

    func testQuestionsAndSpotsDecode() throws {
        let q = """
        {"available": true, "items": [
         {"id": "q-dislike-1", "group": "dislike", "answer": "text", "text": "苦手なものは？", "draft": "辛いもの"},
         {"id": "q-friend-1", "group": "ask_friend", "answer": "record", "text": "親しい人に聞いて録る"},
         {"id": "pr-1", "group": "recheck", "answer": "recheck", "text": "いまも朝型？", "current": "朝型"},
         {"id": "x-1", "group": "なにか", "answer": "なにか", "text": "形が違う所は既定に"}]}
        """
        let qs = try XCTUnwrap(KnowMeRules.decodeQuestions(data(q)))
        XCTAssertEqual(qs.map(\.id), ["q-dislike-1", "q-friend-1", "pr-1", "x-1"])
        XCTAssertEqual(qs[0].draft, "辛いもの")
        XCTAssertEqual(qs[1].answer, "record")
        XCTAssertEqual(qs[3].group, "general")
        XCTAssertEqual(qs[3].answer, "text")
        var items: [String] = []
        for n in 1...7 { items.append(#"{"id": "sp-\#(n)", "claim": "主張 \#(n)", "day": "2026-11-18"}"#) }
        let spots = try XCTUnwrap(KnowMeRules.decodeSpots(data(#"{"available": true, "items": ["# + items.joined(separator: ",") + "]}")))
        XCTAssertEqual(spots.count, 5, "抜き打ちは週 5 件まで")
    }

    // MARK: 1 日 3 問（65）

    private func question(_ id: String, answer: String = "text") -> KnowQuestion {
        KnowQuestion(id: id, group: "general", answer: answer, text: "問い " + id, evidence: [], draft: nil, current: nil,
                     checked_on: nil, tier: nil)
    }

    func testTodayQuestionsAreFixedForTheDayAndSkipAnswered() {
        let fetched: [KnowQuestion] = ["a", "b", "c", "d", "e"].map { question($0) }
        var local = KnowLocal()
        local.answered["b"] = "answered"
        let first = KnowMeRules.todayQuestions(day: "2026-11-19", local: local, fetched: fetched)
        XCTAssertEqual(first.items.map(\.id), ["a", "c", "d"], "答えたものは出さない・3 問まで")
        local.questionDay = first.day
        local.todayQuestions = first.items
        // 同じ日は、家の PC の並びが変わっても入れ替えない
        let again = KnowMeRules.todayQuestions(day: "2026-11-19", local: local, fetched: [question("z")] + fetched)
        XCTAssertEqual(again.items.map(\.id), ["a", "c", "d"])
        local.answered["a"] = "answered"
        XCTAssertEqual(KnowMeRules.openQuestions(local).map(\.id), ["c", "d"])
        // 次の日は、答えていないものから選び直す
        let next = KnowMeRules.todayQuestions(day: "2026-11-20", local: local, fetched: fetched)
        XCTAssertEqual(next.items.map(\.id), ["c", "d", "e"])
    }

    func testWeekHypothesesPickThreeUnvoted() {
        let ev = [KnowEvidence(text: "根拠", source: nil, day: nil, conversation_start: nil, line_time: nil, ref: nil)]
        let hs: [KnowHypothesis] = (1...5).map {
            KnowHypothesis(id: "h-\($0)", kind: "", label: "見立て（仮）", text: "見立て", why: "", evidence: ev, made_on: nil,
                           recheck_by: nil, confidence: nil, tier: nil, tier_why: nil)
        }
        let picked = KnowMeRules.weekHypotheses(week: "2026-W47", local: KnowLocal(), fetched: hs) { $0 == "h-1" }
        XCTAssertEqual(picked.map(\.id), ["h-2", "h-3", "h-4"])
        XCTAssertEqual(KnowMeRules.weekKey(at(2026, 11, 19, 9), calendar: tokyo), "2026-W47")
        XCTAssertEqual(KnowMeRules.weekKey(at(2026, 11, 23, 9), calendar: tokyo), "2026-W47", "日曜はまだ同じ週")
        XCTAssertEqual(KnowMeRules.weekKey(at(2026, 11, 24, 9), calendar: tokyo), "2026-W48")
    }

    func testMorningWindow() {
        XCTAssertFalse(KnowMeRules.isMorning(at(2026, 11, 19, 4, 59), calendar: tokyo))
        XCTAssertTrue(KnowMeRules.isMorning(at(2026, 11, 19, 7), calendar: tokyo))
        XCTAssertFalse(KnowMeRules.isMorning(at(2026, 11, 19, 11), calendar: tokyo))
    }

    // MARK: 送る中身（家の PC の knowme.py と同じ形）

    func testAnswerBodies() throws {
        let a = try object(KnowMeRules.answerBody(id: "q-notdo-1", kind: "question", value: "answered", day: "2026-11-19",
                                                  text: "夜ふかし", group: "notdo", question: "やらないと決めたことは？"))
        XCTAssertEqual(a["kind"] as? String, "question")
        XCTAssertEqual(a["text"] as? String, "夜ふかし")
        XCTAssertEqual(a["by"] as? String, "app")
        XCTAssertNil(KnowMeRules.answerBody(id: "q-1", kind: "question", value: "answered", day: "2026-11-19", text: "  ",
                                            group: nil, question: nil), "文の無い答えは送らない")
        XCTAssertNil(KnowMeRules.answerBody(id: "q 1", kind: "question", value: "skip", day: "2026-11-19", text: nil,
                                            group: nil, question: nil))
        XCTAssertNil(KnowMeRules.answerBody(id: "q-1", kind: "hypothesis", value: "right", day: "2026-11-19", text: nil,
                                            group: nil, question: nil), "見立ての ○× は /feedback で送る")
        XCTAssertNotNil(KnowMeRules.answerBody(id: "q-1", kind: "draft", value: "ok", day: "2026-11-19", text: nil,
                                               group: nil, question: nil))
        XCTAssertNotNil(KnowMeRules.recheckBody(id: "pr-1", value: "still", note: nil))
        XCTAssertNil(KnowMeRules.recheckBody(id: "pr-1", value: "maybe", note: nil))
    }

    func testOtherBodies() throws {
        let start = at(2026, 11, 18, 7, 34)
        let note = try object(KnowMeRules.noteBody(day: "2026-11-18", start: start, text: "実は早く帰りたかった"))
        XCTAssertEqual(note["conversation_start"] as? String, MothershipOutbox.isoString(start))
        XCTAssertNil(KnowMeRules.noteBody(day: "2026-11-18", start: start, text: ""))
        let goal = try object(KnowMeRules.goalBody(day: "2026-11-19", person: "人物A", pe: "pe_0001", text: "月に一度は話す"))
        XCTAssertEqual(goal["pe"] as? String, "pe_0001")
        XCTAssertNotNil(KnowMeRules.whyWrongBody(day: "2026-11-19", target: "ask", reason: "fact", why: nil, head: "答え", question: "問い"))
        XCTAssertNil(KnowMeRules.whyWrongBody(day: "2026-11-19", target: "ask", reason: "なんとなく", why: nil, head: nil, question: nil))
        XCTAssertNotNil(KnowMeRules.markBody(day: "2026-11-19", kind: "weekly_talk", start: start, end: start.addingTimeInterval(300),
                                             questionID: nil))
        XCTAssertNil(KnowMeRules.markBody(day: "2026-11-19", kind: "weekly_talk", start: start, end: start.addingTimeInterval(-1),
                                          questionID: nil))
        let mood = try object(KnowMeRules.moodTapBody(day: "2026-11-19", at: start, slot: "morning", mood: 4))
        XCTAssertEqual(mood["mood"] as? Int, 4)
        XCTAssertNil(KnowMeRules.moodTapBody(day: "2026-11-19", at: start, slot: "noon", mood: 4))
        XCTAssertNil(KnowMeRules.moodTapBody(day: "2026-11-19", at: start, slot: "morning", mood: 0))
    }

    func testOutboxKnowsTheNewPaths() {
        for path in KnowMeRules.paths { XCTAssertEqual(MothershipOutbox.feature(for: path), "knowme", path) }
        XCTAssertNotNil(MothershipOutbox.feedbackBody(kind: "spot", id: "sp-1", value: "right", day: "2026-11-19"))
        XCTAssertNotNil(MothershipOutbox.feedbackBody(kind: "hypothesis", id: "h-1", value: "wrong", day: "2026-11-19"))
        XCTAssertEqual(KnowMeRules.value(forAction: KnowMeRules.yesAction), "right")
        XCTAssertEqual(KnowMeRules.value(forAction: KnowMeRules.noAction), "wrong")
        XCTAssertNil(KnowMeRules.value(forAction: "other"))
        XCTAssertEqual(NoticeRoute.route(identifier: KnowMeRules.weeklyTalkID, title: "", body: ""), .tab(.fix))
    }

    // MARK: 時計の「違う、〇〇さん」（63）

    func testVoiceFixTakesTheLineJustBefore() throws {
        let start = at(2026, 11, 19, 9, 50)
        var c = ConversationLog.Conversation(start: start, end: start.addingTimeInterval(600), docIndex: 0)
        c.lines = [ConversationLog.Line(time: at(2026, 11, 19, 9, 51), speaker: "人物C", text: "それでいいと思います"),
                   ConversationLog.Line(time: at(2026, 11, 19, 9, 58), speaker: "人物D", text: "では次へ"),
                   ConversationLog.Line(time: at(2026, 11, 19, 10, 5), speaker: "人物E", text: "言ったあとの行")]
        let near = try XCTUnwrap(KnowMeRules.near([c], before: at(2026, 11, 19, 10, 2)))
        XCTAssertEqual(near.speaker, "人物D")
        XCTAssertEqual(near.conversationStart, start)
        XCTAssertNil(KnowMeRules.near([c], before: at(2026, 11, 19, 11, 30)), "10 分より前の行は添えない")
        let body = try object(KnowMeRules.voiceFixBody(text: "違う、人物Bさん", saidAt: at(2026, 11, 19, 10, 2), by: "watch", near: near))
        XCTAssertEqual(body["text"] as? String, "違う、人物Bさん")
        XCTAssertEqual((body["near"] as? [String: Any])?["speaker"] as? String, "人物D")
        XCTAssertNil(KnowMeRules.voiceFixBody(text: " ", saidAt: .now, by: "watch", near: nil))
    }

    // MARK: 場所の見張り（57）

    func testRegionsAreWorkAndHomeOnly() {
        let work = PlaceLog.Place(name: "職場", latitude: 35.0, longitude: 139.0, radius: 80, isWork: true)
        let home = PlaceLog.Place(name: "自宅", latitude: 35.1, longitude: 139.1)
        let shop = PlaceLog.Place(name: "どこかのお店", latitude: 35.2, longitude: 139.2)
        let regions = KnowGeo.regions([work, home, shop])
        XCTAssertEqual(regions.map(\.kind), ["work", "home"])
        XCTAssertEqual(regions[0].radius, KnowMeRules.minRadius, "小さすぎる半径は下限まで広げる")
        XCTAssertEqual(KnowGeo.signature(regions), KnowGeo.signature(regions.reversed()))
        XCTAssertTrue(KnowGeo.shouldCount(last: nil, now: .now))
        XCTAssertFalse(KnowGeo.shouldCount(last: .now.addingTimeInterval(-3600), now: .now))
        XCTAssertTrue(KnowGeo.shouldCount(last: .now.addingTimeInterval(-7 * 3600), now: .now))
    }

    // MARK: ヘルスケアの運動（48）

    func testHealthExportWritesExercise() throws {
        var day = HealthExport.Day(day: "2026-11-18")
        day.activeKcal = 420.26
        day.exerciseMinutes = 31
        day.standMinutes = 600
        day.workouts = [HealthExport.Day.Workout(name: "ウォーキング", start: at(2026, 11, 18, 7), end: at(2026, 11, 18, 7, 30),
                                                 kcal: 120, km: 2.345)]
        XCTAssertFalse(day.isEmpty)
        let root = try object(HealthExport.json(day, calendar: tokyo))
        let inner = try XCTUnwrap(root["data"] as? [String: Any])
        let metrics = try XCTUnwrap(inner["metrics"] as? [[String: Any]])
        let names: [String] = metrics.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["active_energy", "apple_exercise_time", "apple_stand_time"])
        let workouts = try XCTUnwrap(inner["workouts"] as? [[String: Any]])
        XCTAssertEqual(workouts.first?["duration"] as? Double, 0.5, "duration は時間（母艦が 60 を掛ける）")
        XCTAssertEqual((workouts.first?["distance"] as? [String: Any])?["qty"] as? Double, 2.35)
    }
}

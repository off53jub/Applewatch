import XCTest
@testable import LifeLog

/// s25 の A1（S25TRules.swift）: 連2・仕5（K1）・大8（K2）・連6（K3）・大10（K7）・連4・活5・活7（K8）・片5・大9
final class S25TTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func day(_ d: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))!
    }

    // MARK: 連2・仕5 LINE のタスク候補

    func testLineTasksDecodeDropsBadAndExpiredRows() {
        let data = json(["version": 1, "generated_at": "2026-11-24T22:00:00+09:00", "items": [
            ["id": "a", "text": "資料を送る", "who": "田中", "due": "2026-11-26", "day": "2026-11-24", "work": true,
             "evidence": "資料を送ってほしいです", "expires": "2026-11-27"],
            ["id": "b", "text": "古い", "day": "2026-11-20", "work": false, "expires": "2026-11-23"],
            ["id": "c", "text": "", "day": "2026-11-24", "work": false, "expires": "2026-11-30"],
            ["id": "a", "text": "同じ id", "day": "2026-11-24", "work": false, "expires": "2026-11-30"],
            ["id": "d", "text": "日が変", "day": "11/24", "work": false, "expires": "2026-11-30"],
            ["id": "e", "text": "飲み会の店を決める", "who": NSNull(), "due": "あした", "day": "2026-11-24", "expires": "2026-11-28"],
            "not a row",
        ]])
        let rows = S25TLineTasks.decode(data, today: "2026-11-24")
        XCTAssertEqual(rows.map(\.id), ["a", "e"])
        // 根拠は 8 字まで
        XCTAssertEqual(rows[0].evidence, "資料を送ってほし")
        XCTAssertEqual(rows[0].work, true)
        // 読めない due は無いものに・work が無ければ仕事以外
        XCTAssertNil(rows[1].due)
        XCTAssertNil(rows[1].who)
        XCTAssertFalse(rows[1].work)
        XCTAssertTrue(S25TLineTasks.decode(json(["available": false, "items": []]), today: "2026-11-24").isEmpty)
        XCTAssertTrue(S25TLineTasks.decode(Data("x".utf8), today: "2026-11-24").isEmpty)
    }

    func testWorkNeedsWhoAndDue() {
        XCTAssertTrue(S25TLineTasks.workOK(work: false, who: nil, due: nil, dueText: nil))
        XCTAssertFalse(S25TLineTasks.workOK(work: true, who: "田中", due: nil, dueText: nil))
        XCTAssertFalse(S25TLineTasks.workOK(work: true, who: " ", due: day(26), dueText: nil))
        XCTAssertTrue(S25TLineTasks.workOK(work: true, who: "田中", due: day(26), dueText: nil))
        XCTAssertTrue(S25TLineTasks.workOK(work: true, who: "田中", due: nil, dueText: "来週の頭まで"))
    }

    func testLineCandidatesSkipKnownIDsAndWorkWithoutDue() {
        let rows = [
            S25TLineTask(id: "a", text: "資料を送る", who: "田中", due: "2026-11-26", day: "2026-11-24", work: true, evidence: "資料",
                         expires: "2026-11-27"),
            S25TLineTask(id: "b", text: "見積もりを出す", who: "佐藤", due: nil, day: "2026-11-24", work: true, evidence: nil,
                         expires: "2026-11-27"),
            S25TLineTask(id: "c", text: "店を決める", who: nil, due: nil, day: "2026-11-24", work: false, evidence: nil,
                         expires: "2026-11-27"),
            S25TLineTask(id: "d", text: "もうある", who: nil, due: nil, day: "2026-11-24", work: false, evidence: nil,
                         expires: "2026-11-27"),
        ]
        let items = S25TLineTasks.candidates(rows, existingIDs: ["line-d"])
        XCTAssertEqual(items.map(\.id), ["line-a", "line-c"])
        XCTAssertEqual(items[0].source, .line)
        XCTAssertEqual(items[0].state, .candidate)
        XCTAssertEqual(items[0].from, "田中")
        XCTAssertEqual(items[0].quote, "LINE「資料」")
        XCTAssertNotNil(items[0].due)
        XCTAssertEqual(items[1].work, false)
        // LINE の候補は「たぶん違う」に畳まない（文字なので聞き間違いが無い）
        XCTAssertFalse(S24TaskRules.isWeak(items[0]))
    }

    func testLineComesFirstInTodayPicks() {
        let talk = TaskBook.Item(what: "会話から", said: day(24), source: .conversation, state: .candidate, work: false)
        var line = TaskBook.Item(what: "LINE から", said: day(23), source: .line, state: .candidate, work: false)
        line.id = "line-x"
        let photo = TaskBook.Item(what: "写真から", said: day(24), source: .photo, state: .candidate, work: false)
        let ordered = S25TLineTasks.lineFirst([talk, photo, line])
        XCTAssertEqual(ordered.map(\.what), ["LINE から", "会話から", "写真から"])
        let picks = S24TaskRules.todayPicks(strong: ordered, saved: nil, day: "2026-11-24", cap: 1)
        XCTAssertEqual(picks.ids, ["line-x"])
        XCTAssertEqual(TaskBook.Source.line.label, "LINE から")
    }

    // MARK: 大8 下書き

    func testDraftsDecodeAndShelfOrder() {
        let data = json(["version": 1, "items": [
            ["id": "r1", "kind": "reply", "title": "返事", "body": "了解です", "to": "山田", "expires": "2026-11-30", "source": "M1"],
            ["id": "s1", "kind": "settle", "title": "箱根の精算", "body": "1 人 12,000 円", "expires": "2026-11-30", "source": "M2"],
            ["id": "x1", "kind": "weird", "title": "なにか", "body": "本文", "expires": "2026-11-30", "source": "M2"],
            ["id": "old", "kind": "settle", "title": "古い", "body": "本文", "expires": "2026-11-01", "source": "M2"],
            ["id": "nobody", "kind": "reply", "title": "本文なし", "expires": "2026-11-30", "source": "M1"],
            ["id": "c1", "kind": "calendar", "title": "予定", "body": "12/1 19:00", "when": "2026-12-01T19:00:00+09:00",
             "expires": "2026-11-30", "source": "M1"],
        ]])
        let drafts = S25TDrafts.decode(data, today: "2026-11-24")
        XCTAssertEqual(drafts.map(\.id), ["r1", "s1", "x1", "c1"])
        XCTAssertEqual(drafts[2].kind, "other")
        // 精算が先・答えたものは出さない・3 つまで
        XCTAssertEqual(S25TDrafts.shelf(drafts, handled: []).map(\.id), ["s1", "r1", "c1"])
        XCTAssertEqual(S25TDrafts.shelf(drafts, handled: ["s1"]).map(\.id), ["r1", "c1", "x1"])
        XCTAssertEqual(S25TDrafts.shareText(drafts[0]), "宛先: 山田\n\n了解です")
        XCTAssertEqual(S25TDrafts.shareText(drafts[1]), "1 人 12,000 円")
        XCTAssertEqual(S25TDrafts.kindLabel("settle"), "精算")
        // 答えは取り決め K2 の 3 つだけ（アプリの送り口も同じ組）
        XCTAssertEqual(MothershipOutbox.feedbackKinds["draft"], ["sent", "edited", "dropped"])
    }

    // MARK: 連6 LINE の共有

    func testShareNameFromTitleOrFile() {
        XCTAssertEqual(S25TLineShare.name(text: "[LINE] 山田とのトーク履歴\n保存日時：2026/11/24", fileName: "x.txt"), "山田")
        XCTAssertEqual(S25TLineShare.name(text: "\u{FEFF}[LINE] 箱根旅行のトーク履歴\n", fileName: "x.txt"), "箱根旅行")
        XCTAssertEqual(S25TLineShare.name(text: "こんにちは", fileName: "[LINE] 佐藤とのトーク.txt"), "佐藤")
        XCTAssertEqual(S25TLineShare.name(text: "こんにちは", fileName: "memo.txt"), "memo")
        XCTAssertEqual(S25TLineShare.name(text: "[LINE] a/b:c とのトーク履歴", fileName: ""), "a_b_c")
        XCTAssertEqual(S25TLineShare.safe(""), "LINE")
        XCTAssertEqual(S25TLineShare.safe(String(repeating: "あ", count: 60)).count, 40)
    }

    func testShareCapKeepsTitleAndNewestLines() {
        let small = "[LINE] 山田とのトーク履歴\n1\n2"
        XCTAssertEqual(S25TLineShare.capped(small, maxBytes: 1000).text, small)
        XCTAssertFalse(S25TLineShare.capped(small, maxBytes: 1000).cut)
        let lines = (1...200).map { String(format: "line%03d", $0) }
        let big = "[LINE] 山田とのトーク履歴\n" + lines.joined(separator: "\n")
        let out = S25TLineShare.capped(big, maxBytes: 300)
        XCTAssertTrue(out.cut)
        XCTAssertLessThanOrEqual(out.text.utf8.count, 300)
        XCTAssertTrue(out.text.hasPrefix("[LINE] 山田とのトーク履歴\n" + S25TLineShare.cutNote))
        XCTAssertTrue(out.text.hasSuffix("line200"))
        XCTAssertFalse(out.text.contains("line001"))
        XCTAssertTrue(S25TLineShare.looksLikeLine(big))
        XCTAssertFalse(S25TLineShare.looksLikeLine("ただのメモ"))
        let body = try! JSONSerialization.jsonObject(with: S25TLineShare.body(name: "山田", text: "x")!) as! [String: String]
        XCTAssertEqual(body, ["name": "山田", "text": "x"])
    }

    // MARK: 大10 耳打ち

    func testWhisperDecodeAndWhenToAsk() {
        XCTAssertNil(S25TWhisperRules.decode(json([:])))
        XCTAssertNil(S25TWhisperRules.decode(json(["person": " "])))
        let w = S25TWhisperRules.decode(json(["person": "田中", "last_talk": NSNull(), "promises": ["資料", 3, "", "b", "c", "d"]]))
        XCTAssertEqual(w?.person, "田中")
        XCTAssertNil(w?.lastTalk)
        XCTAssertEqual(w?.promises, ["資料", "b", "c"])
        let now = day(24)
        // 初めはオフ
        XCTAssertFalse(UserDefaults.standard.object(forKey: S25TWhisperRules.onKey) as? Bool ?? false)
        XCTAssertFalse(S25TWhisperRules.shouldAsk(on: false, recording: true, lastAsked: nil, now: now))
        XCTAssertFalse(S25TWhisperRules.shouldAsk(on: true, recording: false, lastAsked: nil, now: now))
        XCTAssertTrue(S25TWhisperRules.shouldAsk(on: true, recording: true, lastAsked: nil, now: now))
        XCTAssertFalse(S25TWhisperRules.shouldAsk(on: true, recording: true, lastAsked: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(S25TWhisperRules.shouldAsk(on: true, recording: true, lastAsked: now.addingTimeInterval(-120), now: now))
        // 同じ相手なら出し直さない（さん付けの違いも同じ）
        XCTAssertTrue(S25TWhisperRules.changed(previous: nil, now: w))
        XCTAssertFalse(S25TWhisperRules.changed(previous: "田中さん", now: w))
        XCTAssertTrue(S25TWhisperRules.changed(previous: "佐藤", now: w))
        XCTAssertFalse(S25TWhisperRules.changed(previous: "佐藤", now: nil))
        XCTAssertTrue(S25TWhisperRules.alive(shownAt: now.addingTimeInterval(-599), now: now))
        XCTAssertFalse(S25TWhisperRules.alive(shownAt: now.addingTimeInterval(-600), now: now))
        XCTAssertFalse(S25TWhisperRules.alive(shownAt: nil, now: now))
    }

    func testWatchInfoCarriesWhisperOptionally() throws {
        var info = WatchInfo(made: 1, status: WatchInfo.Status(pending: 0))
        XCTAssertFalse(String(data: WatchInfo.encode(info)!, encoding: .utf8)!.contains("whisper"))
        info.whisper = WatchInfo.Whisper(person: "田中", lastTalk: "旅行の話", promises: ["写真を送る"], at: 10)
        let back = try JSONDecoder().decode(WatchInfo.self, from: WatchInfo.encode(info)!)
        XCTAssertEqual(back.whisper?.person, "田中")
    }

    // MARK: 連4 会う前の準備に LINE

    func testPrepLineReadsAnyShape() throws {
        XCTAssertEqual(S25TPrepLine.lines(nil), [])
        XCTAssertEqual(S25TPrepLine.lines("土曜の集合は 10 時"), ["土曜の集合は 10 時"])
        XCTAssertEqual(S25TPrepLine.lines(["a", " ", "b", "c", "d"]), ["a", "b", "c"])
        XCTAssertEqual(S25TPrepLine.lines(["summary": "まとめ", "lines": ["x"]] as [String: Any]), ["まとめ", "x"])
        XCTAssertEqual(S25TPrepLine.lines(["points": ["p"]]), ["p"])
        struct Box: Decodable { var line: S25TPrepLineField? }
        let a = try JSONDecoder().decode(Box.self, from: Data(#"{"line": ["集合 10 時"]}"#.utf8))
        XCTAssertEqual(a.line?.lines, ["集合 10 時"])
        let b = try JSONDecoder().decode(Box.self, from: Data(#"{"line": {"summary": "まとめ"}}"#.utf8))
        XCTAssertEqual(b.line?.lines, ["まとめ"])
        let c = try JSONDecoder().decode(Box.self, from: Data(#"{"line": 3}"#.utf8))
        XCTAssertEqual(c.line?.lines, [])
        let d = try JSONDecoder().decode(Box.self, from: Data(#"{}"#.utf8))
        XCTAssertNil(d.line)
    }

    // MARK: 活5・活7 検索と時系列

    func testSearchDecodeAndBody() {
        XCTAssertNil(S25TSearch.decode(json(["available": false])))
        XCTAssertNil(S25TSearch.decode(json(["x": 1])))
        let hits = S25TSearch.decode(json(["hits": [
            ["source": "line", "day": "2026-11-20", "time": "12:30", "text": "土曜どうする？"],
            ["source": "plaud", "day": "2026-11-21", "label": "PLAUD", "text": ""],
            ["source": "digest", "time": "", "text": "日の無い行"],
            ["source": "money", "day": "2026-11", "text": "月のまとめ"],
        ]]))
        XCTAssertEqual(hits?.map(\.text), ["土曜どうする？", "月のまとめ"])
        XCTAssertEqual(hits?.first?.label, "LINE")
        let body = try! JSONSerialization.jsonObject(with: S25TSearch.body(query: "箱根", person: "田中", sources: ["line"], days: 60)!)
            as! [String: Any]
        XCTAssertEqual(body["query"] as? String, "箱根")
        XCTAssertEqual(body["person"] as? String, "田中")
        XCTAssertEqual(body["sources"] as? [String], ["line"])
        XCTAssertEqual(body["days"] as? Int, 60)
    }

    func testTimelineMergesNewestFirst() {
        let line = [
            S25TSearchHit(id: "1", source: "line", day: "2026-11-20", time: "9:05", label: "LINE", text: "おはよう"),
            S25TSearchHit(id: "2", source: "line", day: "2026-11-22", time: "", label: "LINE", text: "日だけ"),
            S25TSearchHit(id: "3", source: "plaud", day: "2026-11-21", time: "+00:01:02", label: "PLAUD", text: "録音から"),
        ]
        let talks = [(day: "2026-11-21", time: "18:00", text: "夕方の会話"), (day: "2026-11-20", time: "09:05", text: "同じ時刻の会話")]
        let rows = S25TTimeline.merge(talks: talks, line: line)
        XCTAssertEqual(rows.map(\.text), ["日だけ", "夕方の会話", "録音から", "同じ時刻の会話", "おはよう"])
        XCTAssertEqual(rows.first?.kind, .line)
        XCTAssertEqual(S25TTimeline.merge(talks: talks, line: line, limit: 2).count, 2)
        XCTAssertEqual(S25TTimeline.key("2026-11-20", "9:05"), "2026-11-20 09:05")
    }

    // MARK: 片5 設定を奥へ

    func testSettingsFoldWaitsThirtyDaysAndKeepsChanged() {
        let ids = ["a", "b", "c", "d"]
        let sums = [S24Settings.tallyName("b"): 2]
        // 数え始めて 30 日たつまでは、何も奥へ入れない
        XCTAssertEqual(S25TSettingsFold.split(ids, sums: sums, changed: [], today: "2026-12-23", searching: false).deep, [])
        let after = S25TSettingsFold.split(ids, sums: sums, changed: ["d"], today: "2026-12-24", searching: false)
        XCTAssertEqual(after.shown, ["b", "d"])
        XCTAssertEqual(after.deep, ["a", "c"])
        // 探しているときは全部出す
        XCTAssertEqual(S25TSettingsFold.split(ids, sums: [:], changed: [], today: "2027-01-30", searching: true).shown, ids)
    }

    // MARK: 大9 この声は誰？・その場で登録

    func testVoicePickHonorsCapAndFilters() {
        let now = day(24)
        func v(_ id: String, named: Bool = false, seconds: Double = 600, last: Date? = nil, sample: Bool = true,
               hidden: Bool = false, isSelf: Bool = false) -> S25TVoiceCandidate {
            S25TVoiceCandidate(id: id, named: named, isSelf: isSelf, hidden: hidden, seconds: seconds, lastHeard: last ?? now,
                               hasSample: sample)
        }
        let people = [v("named", named: true, seconds: 9000), v("short", seconds: 60), v("old", seconds: 5000, last: day(10)),
                      v("nosample", seconds: 5000, sample: false), v("hidden", seconds: 5000, hidden: true),
                      v("self", seconds: 9999, isSelf: true), v("p1", seconds: 900), v("p2", seconds: 1200)]
        XCTAssertEqual(S25TVoice.pick(people, asked: 0, cap: 3, skipped: [], now: now), "p2")
        XCTAssertEqual(S25TVoice.pick(people, asked: 0, cap: 3, skipped: ["p2"], now: now), "p1")
        // 今日の 3 問に達していたら聞かない
        XCTAssertNil(S25TVoice.pick(people, asked: 3, cap: 3, skipped: [], now: now))
        XCTAssertNil(S25TVoice.pick([v("x", seconds: 60)], asked: 0, cap: 3, skipped: [], now: now))
    }

    func testMeetVoiceTargetAndNames() {
        let people: [(id: String, name: String?)] = [("1", nil), ("2", "田中 太郎"), ("3", "佐藤")]
        XCTAssertEqual(S25TVoice.target(name: "田中さん", people: people), "2")
        XCTAssertEqual(S25TVoice.target(name: "佐藤", people: people), "3")
        XCTAssertNil(S25TVoice.target(name: "鈴木", people: people))
        XCTAssertTrue(S25TText.sameName("田中", "田中太郎"))
        XCTAssertFalse(S25TText.sameName("田", "田中"))
        XCTAssertTrue(S25TText.isDay("2026-11-24"))
        XCTAssertFalse(S25TText.isDay("2026-1-24"))
    }
}

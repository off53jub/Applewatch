import XCTest
@testable import LifeLog

/// 提案・PLAUD で埋めた所・話し手の疑い（2026-11-13。HomeFeeds.swift）と、職場の自分の声の今日の10件（AppFeeds.swift）。
/// 名前・お店・言葉はすべて作り物。
@MainActor
final class HomeFeedsTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func proposal(_ id: String, kind: String = "followup", created: String? = nil, expires: String? = nil) -> Proposal {
        Proposal(id: id, kind: kind, title: "題 " + id, body: "", created: created, expires: expires)
    }

    // MARK: - 提案の読み方

    func testProposalsDropBadRows() throws {
        let body = """
        {"available": true, "generated_at": "2026-11-13T07:00:00+09:00", "items": [
          {"id": "p-1", "kind": "followup", "title": "返事を確かめる", "body": "本文",
           "evidence": [{"text": "根拠", "when": "2026-11-12T09:30:00+09:00", "source": "conversation"},
                        {"text": "", "when": null, "source": "line"},
                        {"text": 5}],
           "action": {"type": "task", "text": "返事を確かめる", "reading": null},
           "created": "2026-11-13T07:00:00+09:00", "expires": null},
          {"id": "p-2", "kind": "vocab", "title": "言葉", "body": "",
           "action": {"type": "vocab", "text": "見本商事", "reading": "みほんしょうじ"}},
          {"id": "p-3", "kind": "followup", "title": "", "body": "題が空"},
          {"id": "p 4", "kind": "followup", "title": "id に空白", "body": ""},
          {"id": "p-5", "kind": "followup", "title": "\(String(repeating: "長", count: 61))", "body": ""},
          {"id": "p-6", "kind": "followup", "title": "知らない動き", "body": "", "action": {"type": "mail", "text": "x"}},
          {"id": "p-7", "kind": "followup", "title": "動きの文が無い", "body": "", "action": {"type": "task"}},
          {"id": "p-8", "kind": "followup", "title": "読めない時刻", "body": "", "created": "きのう"},
          {"id": "p-1", "kind": "followup", "title": "同じ id", "body": ""},
          {"id": 9, "kind": "followup", "title": "id が数", "body": ""},
          "おかしな行",
          {"id": "p-10", "kind": "chance", "title": "何もしない", "body": "", "action": {"type": "none"}}
        ]}
        """
        let feed = try XCTUnwrap(HomeFeeds.decodeProposals(data(body)))
        XCTAssertEqual(feed.items.map(\.id), ["p-1", "p-2", "p-10"])
        XCTAssertEqual(feed.items[0].evidence.count, 1, "おかしな根拠だけ落とす")
        XCTAssertEqual(feed.items[0].action?.text, "返事を確かめる")
        XCTAssertEqual(feed.items[1].action?.reading, "みほんしょうじ")
        XCTAssertEqual(feed.items[2].action?.type, "none")
        XCTAssertNil(HomeFeeds.decodeProposals(data(#"{"available": false, "reason": "まだありません"}"#)))
        XCTAssertNil(HomeFeeds.decodeProposals(data("壊れた")))
    }

    func testPlaceActionNeedsDayAndStart() throws {
        let body = """
        {"items": [
          {"id": "pl-1", "kind": "place", "title": "お店はこちらかも", "body": "",
           "action": {"type": "place", "text": "見本の餃子屋", "reading": null, "day": "2026-11-12",
                      "conversation_start": "2026-11-12T19:05:00+09:00"}},
          {"id": "pl-2", "kind": "place", "title": "日が無い", "body": "",
           "action": {"type": "place", "text": "見本の店", "conversation_start": "2026-11-12T19:05:00+09:00"}},
          {"id": "pl-3", "kind": "place", "title": "始まりが読めない", "body": "",
           "action": {"type": "place", "text": "見本の店", "day": "2026-11-12", "conversation_start": "夜"}},
          {"id": "pl-4", "kind": "place", "title": "日の形が違う", "body": "",
           "action": {"type": "place", "text": "見本の店", "day": "11/12", "conversation_start": "2026-11-12T19:05:00+09:00"}},
          {"id": "pl-5", "kind": "place", "title": "名前が無い", "body": "",
           "action": {"type": "place", "day": "2026-11-12", "conversation_start": "2026-11-12T19:05:00+09:00"}}
        ]}
        """
        let feed = try XCTUnwrap(HomeFeeds.decodeProposals(data(body)))
        XCTAssertEqual(feed.items.map(\.id), ["pl-1"])
        let action = try XCTUnwrap(feed.items.first?.action)
        XCTAssertEqual(action.type, "place")
        XCTAssertEqual(action.day, "2026-11-12")
        XCTAssertNotNil(AppFeeds.parseTime(action.conversation_start))
        XCTAssertEqual(ProposalRules.kindLabel("place"), "行ったお店")
        XCTAssertEqual(ProposalRules.actionLine(feed.items[0]), "受けると、その時間の行ったお店の名前を「見本の餃子屋」に決めます")
    }

    func testVisitIndexPrefersOverlapThenNearest() {
        let t = now
        let visits: [(arrival: Date, departure: Date?)] = [
            (t.addingTimeInterval(-7200), t.addingTimeInterval(-6000)),   // ずっと前
            (t.addingTimeInterval(-600), t.addingTimeInterval(600)),      // 重なる（10分）
            (t.addingTimeInterval(300), t.addingTimeInterval(3600)),      // 重なる（長い）
        ]
        // 会話 t〜t+20分。重なりのいちばん長い立ち寄り
        XCTAssertEqual(HomeFeeds.visitIndex(start: t, end: t.addingTimeInterval(1200), visits: visits), 2)
        // 重ならないが、会話の始まりから20分後に着いた立ち寄り
        let later: [(arrival: Date, departure: Date?)] = [(t.addingTimeInterval(1200), t.addingTimeInterval(4000))]
        XCTAssertEqual(HomeFeeds.visitIndex(start: t, end: t.addingTimeInterval(60), visits: later), 0)
        // 30分より離れていれば見つけない
        let far: [(arrival: Date, departure: Date?)] = [(t.addingTimeInterval(2400), t.addingTimeInterval(4000))]
        XCTAssertNil(HomeFeeds.visitIndex(start: t, end: t.addingTimeInterval(60), visits: far))
        // 出た時刻が分からない立ち寄りは、着いてから3時間とみなす
        let open: [(arrival: Date, departure: Date?)] = [(t.addingTimeInterval(-4 * 3600), nil)]
        XCTAssertNil(HomeFeeds.visitIndex(start: t, end: t.addingTimeInterval(60), visits: open))
        XCTAssertNil(HomeFeeds.visitIndex(start: t, end: t, visits: []))
    }

    // MARK: - 提案の隠し方

    func testLaterHidesForThreeDays() {
        let p = proposal("a")
        let local = ProposalRules.answering(ProposalRules.Local(), p, .later, now: now)
        XCTAssertFalse(ProposalRules.isOpen(p, local: local, now: now))
        XCTAssertFalse(ProposalRules.isOpen(p, local: local, now: now.addingTimeInterval(3 * 86400 - 60)))
        XCTAssertTrue(ProposalRules.isOpen(p, local: local, now: now.addingTimeInterval(3 * 86400 + 60)))
        XCTAssertEqual(local.pending.map(\.answer), [.later])
        XCTAssertEqual(local.history.first?.answer, .later)
    }

    func testNeverHidesTheWholeKindUntilTurnedBackOn() {
        let a = proposal("a", kind: "research"), b = proposal("b", kind: "research"), c = proposal("c", kind: "health")
        var local = ProposalRules.answering(ProposalRules.Local(), a, .never, now: now)
        XCTAssertEqual(ProposalRules.openItems([a, b, c], local: local, now: now).map(\.id), ["c"])
        // 種類を戻すと、同じ種類のほかの提案はまた出る（答えた a は出さない）
        local = ProposalRules.settingKind(local, "research", on: true)
        XCTAssertEqual(Set(ProposalRules.openItems([a, b, c], local: local, now: now).map(\.id)), ["b", "c"])
    }

    func testAcceptedNeverComesBackAndExpiredHides() {
        let a = proposal("a"), b = proposal("b", expires: "2026-01-01T00:00:00Z")
        let local = ProposalRules.answering(ProposalRules.Local(), a, .accept, now: now)
        XCTAssertTrue(ProposalRules.openItems([a, b], local: local, now: now.addingTimeInterval(400 * 86400)).isEmpty)
        // 答えを覚えた形は、読み直しても同じ
        let saved = try? JSONDecoder().decode(ProposalRules.Local.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(saved, local)
        // 前の形（項目の足りないファイル）も読める
        XCTAssertEqual(try? JSONDecoder().decode(ProposalRules.Local.self, from: data("{}")), ProposalRules.Local())
    }

    func testOpenIsNewestFirst() {
        let old = proposal("x", created: "2026-11-12T07:00:00+09:00"), new = proposal("y", created: "2026-11-13T07:00:00+09:00")
        XCTAssertEqual(ProposalRules.openItems([old, new], local: .init(), now: now).map(\.id), ["y", "x"])
    }

    func testNoticeOncePerDayOnlyForUnseen() {
        let a = proposal("a"), b = proposal("b")
        var local = ProposalRules.Local()
        XCTAssertEqual(ProposalRules.toNotify([a, b], local: local, today: "2026-11-13").map(\.id), ["a", "b"])
        local.noticeDay = "2026-11-13"
        local.notified = ["a"]
        XCTAssertTrue(ProposalRules.toNotify([a, b], local: local, today: "2026-11-13").isEmpty, "1日に1回まで")
        local.shown = ["b"]
        XCTAssertTrue(ProposalRules.toNotify([a, b], local: local, today: "2026-11-14").isEmpty, "見せたものは知らせない")
    }

    func testEvidenceLine() {
        let e = Proposal.Evidence(text: "根拠", when: "2026-11-12T09:30:00+09:00", source: "conversation")
        XCTAssertEqual(ProposalRules.evidenceLine(e, timeZone: tokyo), "・根拠（11/12 09:30・会話）")
        XCTAssertEqual(ProposalRules.evidenceLine(Proposal.Evidence(text: "だけ")), "・だけ")
    }

    // MARK: - PLAUD で埋めた所

    func testPlaudFillDropsBadRowsAndNeverKeepsEmptySpans() throws {
        let body = """
        {"generated_at": "2026-11-13T07:00:00+09:00", "days": [
          {"day": "2026-11-12", "ranges": [
            {"start": "2026-11-12T10:00:00+09:00", "end": "2026-11-12T10:20:00+09:00", "lines": [
              {"time": "2026-11-12T10:01:00+09:00", "speaker": "話者1", "text": "PLAUD の文"},
              {"time": "いつか", "speaker": null, "text": "時刻が読めない"},
              {"time": "2026-11-12T10:02:00+09:00", "speaker": null, "text": ""},
              {"time": "2026-11-12T10:03:00+09:00", "speaker": null, "text": "話し手なし"}]},
            {"start": "2026-11-12T09:00:00+09:00", "end": "2026-11-12T09:10:00+09:00", "lines": [
              {"time": "2026-11-12T09:01:00+09:00", "text": "先の時間"}]},
            {"start": "2026-11-12T12:00:00+09:00", "end": "2026-11-12T11:00:00+09:00", "lines": [
              {"time": "2026-11-12T12:01:00+09:00", "text": "終わりが始まりより前"}]},
            {"start": "2026-11-12T13:00:00+09:00", "end": "2026-11-12T13:10:00+09:00", "lines": []}]},
          {"day": "2026/11/11", "ranges": []},
          {"day": "2026-11-13", "ranges": [
            {"start": "2026-11-13T08:00:00+09:00", "end": "2026-11-13T08:05:00+09:00", "lines": [
              {"time": "2026-11-13T08:01:00+09:00", "text": "新しい日"}]}]}
        ]}
        """
        let feed = try XCTUnwrap(HomeFeeds.decodePlaudFill(data(body)))
        XCTAssertEqual(feed.days.map(\.day), ["2026-11-13", "2026-11-12"])
        let day = feed.days[1]
        XCTAssertEqual(day.ranges.count, 2)
        XCTAssertEqual(HomeFeeds.spanLabel(day.ranges[0], timeZone: tokyo), "09:00〜09:10", "時刻の順に並べ直す")
        XCTAssertEqual(day.ranges[1].lines.map(\.text), ["PLAUD の文", "話し手なし"])
        XCTAssertEqual(HomeFeeds.fillLineHead(day.ranges[1].lines[0], timeZone: tokyo), "10:01:00　話者1")
        XCTAssertNil(HomeFeeds.decodePlaudFill(data(#"{"available": false}"#)))
    }

    // MARK: - 話し手の疑い

    func testSpeakerDoubtsDropBadRows() throws {
        func row(_ suggest: String = "self", why: String = "plaud-turn", score: String = "0.7",
                 time: String = "2026-11-12T10:00:05+09:00", head: String = "文の頭", current: String = "見本 花子") -> String {
            """
            {"day": "2026-11-12", "conversation_start": "2026-11-12T10:00:00+09:00", "line_time": "\(time)",
             "text_head": "\(head)", "current": "\(current)", "suggest": "\(suggest)", "why": "\(why)", "score": \(score)}
            """
        }
        let rows = [row(), row("other", why: "text", score: "0.4", time: "2026-11-12T10:01:00+09:00"),
                    row("maybe"), row(why: "voice"), row(score: "1.5"), row(time: "朝"),
                    row(head: String(repeating: "長", count: 41)), row(current: ""), row()]
        let feed = try XCTUnwrap(HomeFeeds.decodeDoubts(data(#"{"items": ["# + rows.joined(separator: ",") + "]}")))
        XCTAssertEqual(feed.items.count, 2, "おかしな行と、同じ行・同じ向きの2つ目は落とす")
        let shown = HomeFeeds.visibleDoubts(feed.items, hidden: [])
        XCTAssertEqual(shown.map(\.suggest), ["self", "other"], "点の高い順")
        XCTAssertEqual(HomeFeeds.visibleDoubts(feed.items, hidden: [shown[0].id]).map(\.suggest), ["other"], "「違う」は出さない")
        XCTAssertEqual(HomeFeeds.suggestLabel("self"), "自分かも")
        XCTAssertEqual(HomeFeeds.suggestLabel("other"), "別の人かも")
        XCTAssertEqual(HomeFeeds.whyLabel("plaud-turn"), "PLAUD の区切りから")
        XCTAssertEqual(HomeFeeds.whyLabel("text"), "文の中身から")
    }

    func testNearestLineWithinTwoSeconds() {
        let times = [now, now.addingTimeInterval(3), now.addingTimeInterval(10)]
        XCTAssertEqual(HomeFeeds.nearestLine(at: now.addingTimeInterval(1.5), in: times), 0)
        XCTAssertEqual(HomeFeeds.nearestLine(at: now.addingTimeInterval(2.5), in: times), 1)
        XCTAssertNil(HomeFeeds.nearestLine(at: now.addingTimeInterval(6.5), in: times))
        XCTAssertNil(HomeFeeds.nearestLine(at: now, in: []))
    }

    // MARK: - 職場の自分の声の今日の10件

    func testDailyTenKeepsTheSamePicksAllDay() {
        func c(_ i: Int) -> SelfCandidate {
            SelfCandidate(id: "c\(i)", day: "2026-11-13", audio: "a.m4a", start: 0, end: 5, text: "", score: 1 - Double(i) / 100, why: "plaud-match")
        }
        let all = (1...60).map(c)
        let first = AppFeeds.dailyTen(all, saved: nil, day: "2026-11-13")
        XCTAssertEqual(first.ids, (1...10).map { "c\($0)" })
        // 答えて候補が減っても、その日は入れ替えない（11件目は出さない）
        let again = AppFeeds.dailyTen(Array(all.dropFirst(3)), saved: first.save, day: "2026-11-13")
        XCTAssertEqual(again.ids, first.ids)
        XCTAssertEqual(again.save, first.save)
        // 次の日は、残りから選び直す
        let next = AppFeeds.dailyTen(Array(all.dropFirst(10)), saved: first.save, day: "2026-11-14")
        XCTAssertEqual(next.ids.first, "c11")
        XCTAssertEqual(next.ids.count, 10)
        // 今日の分が空のまま候補が届いたら選び直す
        let empty = AppFeeds.dailyTen([], saved: nil, day: "2026-11-13")
        XCTAssertEqual(AppFeeds.dailyTen(all, saved: empty.save, day: "2026-11-13").ids.count, 10)
        XCTAssertEqual(AppFeeds.tenBriefLine(visible: 60), "職場の自分の声を10件確かめる（「直す」から）")
        XCTAssertEqual(AppFeeds.tenBriefLine(visible: 4), "職場の自分の声を4件確かめる（「直す」から）")
        XCTAssertNil(AppFeeds.tenBriefLine(visible: 0))
    }

    func testDayAndIDChecks() {
        XCTAssertTrue(HomeFeeds.isDay("2026-11-13"))
        XCTAssertFalse(HomeFeeds.isDay("2026-1-13"))
        XCTAssertFalse(HomeFeeds.isDay("２０２６-11-13"))
        XCTAssertTrue(HomeFeeds.isID("p-20261113-1"))
        XCTAssertFalse(HomeFeeds.isID(""))
        XCTAssertFalse(HomeFeeds.isID("提案"))
    }
}

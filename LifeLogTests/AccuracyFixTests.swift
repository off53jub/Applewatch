import XCTest
@testable import LifeLog

/// 同じ人かも（施策 10）・夜の読み直し（施策 9）・まとめて OK と「直す」のタブの数字（施策 14）の読み方と決まり（2026-11-13）。
/// 名前・言葉はすべて作り物。
@MainActor
final class AccuracyFixTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - 同じ人かも

    private func member(_ id: String, name: String? = nil, lines: Int = 3, sample: String = #"{"time": "2026-11-12T01:00:00.000Z", "text": "見本", "audio": "20261112-100000.m4a", "start": 1.0, "end": 3.5}"#) -> String {
        let shown: String = name ?? ("人物" + id)
        return #"{"id": "\#(id)", "name": "\#(shown)", "lines": \#(lines), "seconds": 9.5, "samples": [\#(sample)]}"#
    }

    func testSamePersonDecodeKeepsOnlyUnnamedGroups() throws {
        let badSample = #"{"time": "朝", "audio": "a.m4a", "start": 1, "end": 2}"#
        let body = """
        {"available": true, "generated_at": "2026-11-13T02:00:00+09:00", "days": [
          {"day": "2026-11-12", "groups": [
            {"id": "sp-1", "score": 0.8, "people": [\(member("12", lines: 9)), \(member("15"))]},
            {"id": "sp-2", "score": 0.7, "people": [\(member("12")), \(member("3", name: "見本 花子"))]},
            {"id": "sp-3", "score": 0.7, "people": [\(member("12")), \(member("16", name: "人物17"))]},
            {"id": "sp-4", "score": 0.7, "people": [\(member("12"))]},
            {"id": "sp-5", "score": 0.7, "people": [\(member("12")), \(member("12"))]},
            {"id": "sp 6", "score": 0.7, "people": [\(member("12")), \(member("15"))]},
            {"id": "sp-7", "score": 0.6, "people": [\(member("20")), \(member("21", sample: badSample))]},
            {"id": "sp-1", "score": 0.9, "people": [\(member("30")), \(member("31"))]}
          ]},
          {"day": "きのう", "groups": [{"id": "sp-9", "score": 0.9, "people": [\(member("40")), \(member("41"))]}]}
        ]}
        """
        let feed = try XCTUnwrap(SamePersonRules.decode(data(body)))
        XCTAssertEqual(feed.groups.map(\.id), ["sp-1", "sp-7"],
                       "名前のある人・番号の合わない名前・1人だけ・同じ人2回・おかしな id・同じ組の2つ目・おかしな日を落とす")
        XCTAssertEqual(feed.groups[0].day, "2026-11-12")
        XCTAssertEqual(feed.groups[0].people.map(\.name), ["人物12", "人物15"])
        XCTAssertEqual(feed.groups[0].people[0].samples.first?.audio, "20261112-100000.m4a")
        XCTAssertEqual(feed.groups[1].people[1].samples.count, 0, "読めない聞く所だけ落とす（組は残す）")
        XCTAssertNil(SamePersonRules.decode(data(#"{"available": false, "reason": "まだ"}"#)))
        XCTAssertNil(SamePersonRules.decode(data("壊れた")))
    }

    func testSamePersonUnnamedID() {
        XCTAssertEqual(SamePersonRules.unnamedID("人物12"), "12")
        XCTAssertNil(SamePersonRules.unnamedID("人物"))
        XCTAssertNil(SamePersonRules.unnamedID("人物１２"), "全角の数字は名前の無い人の形ではない")
        XCTAssertNil(SamePersonRules.unnamedID("見本 花子"))
        XCTAssertNil(SamePersonRules.unnamedID("自分"))
    }

    private func group(_ id: String, _ members: [(String, Int)], score: Double = 0.7, day: String = "2026-11-12") -> SamePersonGroup {
        var people: [SamePersonGroup.Member] = []
        for (mid, lines) in members {
            people.append(SamePersonGroup.Member(id: mid, name: "人物" + mid, lines: lines, seconds: 1, samples: []))
        }
        return SamePersonGroup(id: id, day: day, score: score, people: people)
    }

    func testSamePersonVisibleAndMergePlan() {
        let groups = [group("a", [("1", 2), ("2", 5)], score: 0.6), group("b", [("3", 1), ("4", 1)], score: 0.9),
                      group("c", [("5", 1), ("6", 1)])]
        let shown = SamePersonRules.visible(groups, answered: ["c"], unnamed: ["1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(shown.map(\.id), ["b", "a"], "答えた組は出さない・点の高い順")
        XCTAssertEqual(SamePersonRules.visible(groups, answered: [], unnamed: ["1", "3", "4", "5", "6"]).map(\.id), ["b", "c"],
                       "名前が付いた（または、もういない）人が入った組は出さない")
        let plan = SamePersonRules.mergePlan(groups[0])
        XCTAssertEqual(plan.target, "2", "行のいちばん多い人にまとめる")
        XCTAssertEqual(plan.sources, ["1"])
        let tie = SamePersonRules.mergePlan(group("t", [("14", 3), ("9", 3), ("11", 1)]))
        XCTAssertEqual(tie.target, "9", "行の数が同じなら番号の小さい人")
        XCTAssertEqual(tie.sources, ["14", "11"])
    }

    // MARK: - 夜の読み直し

    func testNightReviewDecodeDropsBadRows() throws {
        func row(_ id: String = "nr-1", wrong: String = "さんじ", guess: String = "三時", time: String = "2026-11-12T01:00:05.000Z",
                 day: String = "2026-11-12") -> String {
            #"{"id": "\#(id)", "day": "\#(day)", "line_time": "\#(time)", "wrong": "\#(wrong)", "guess": "\#(guess)", "reason": "時刻の話"}"#
        }
        let rows = [row(), row("nr 2"), row("nr-3", wrong: "あ"), row("nr-4", wrong: String(repeating: "長", count: 13)),
                    row("nr-5", guess: "さんじ"), row("nr-6", guess: String(repeating: "長", count: 21)), row("nr-7", time: "朝"),
                    row("nr-8", day: "11/12"), row(), #""おかしな行""#]
        let items = try XCTUnwrap(NightReviewRules.decode(data(#"{"available": true, "items": ["# + rows.joined(separator: ",") + "]}")))
        XCTAssertEqual(items.map(\.id), ["nr-1"])
        XCTAssertEqual(NightReviewRules.reason(items[0]), "夜の読み直しから：時刻の話")
        var plain = items[0]
        plain.reason = ""
        XCTAssertEqual(NightReviewRules.reason(plain), "夜の読み直しから")
        XCTAssertNil(NightReviewRules.decode(data(#"{"available": false}"#)))
    }

    func testNightReviewPicksTheLineWithTheWord() throws {
        let item = NightMisheard(id: "nr-1", day: "2026-11-12", line_time: "2026-11-12T01:00:05.000Z", wrong: "さんじ", guess: "三時")
        let at = try XCTUnwrap(AppFeeds.parseTime(item.line_time))
        let lines: [(time: Date, text: String, checked: Bool)] = [
            (at.addingTimeInterval(-1), "言葉の無い行", false),
            (at.addingTimeInterval(1.5), "会議はさんじから", true),
            (at.addingTimeInterval(1), "会議はさんじから", false),
            (at.addingTimeInterval(3), "さんじに会う", false),
        ]
        XCTAssertEqual(NightReviewRules.pick(item, in: lines), 2, "前後2秒・その言葉を含む・手で確かめていない行")
        XCTAssertNil(NightReviewRules.pick(item, in: [(at.addingTimeInterval(3), "さんじ", false)]))
    }

    func testSpeakerDoubtsReadNightAndSure() throws {
        let body = """
        {"items": [
          {"day": "2026-11-12", "conversation_start": "2026-11-12T10:00:00+09:00", "line_time": "2026-11-12T10:00:05+09:00",
           "text_head": "文の頭", "current": "人物3", "suggest": "self", "why": "night", "score": 0.55},
          {"day": "2026-11-12", "conversation_start": "2026-11-12T10:00:00+09:00", "line_time": "2026-11-12T10:00:09+09:00",
           "text_head": "文の頭", "current": "人物3", "suggest": "self", "why": "plaud-turn", "score": 0.8,
           "sure": true, "sure_why": "PLAUD と声が合う"},
          {"day": "2026-11-12", "conversation_start": "2026-11-12T10:00:00+09:00", "line_time": "2026-11-12T10:00:20+09:00",
           "text_head": "文の頭", "current": "自分", "suggest": "other", "why": "text", "score": 0.4, "sure": "yes"}
        ]}
        """
        let feed = try XCTUnwrap(HomeFeeds.decodeDoubts(data(body)))
        XCTAssertEqual(feed.items.map(\.why), ["night", "plaud-turn", "text"], "why night も読む・sure の型が違っても行は落とさない")
        XCTAssertNil(feed.items[0].sure)
        XCTAssertEqual(feed.items[1].sure, true)
        XCTAssertEqual(feed.items[1].sure_why, "PLAUD と声が合う")
        XCTAssertNil(feed.items[2].sure)
        XCTAssertEqual(HomeFeeds.whyLabel("night"), "夜の読み直しから")
        XCTAssertEqual(HomeFeeds.whyLabel("plaud-turn"), "PLAUD の区切りから")
        let key = NightReviewRules.doubtKey(feed.items[0])
        XCTAssertTrue(HomeFeeds.isID(key), "母艦へ送る id は約束の形（英数字と _ . : - の 64 字まで）")
        XCTAssertEqual(key, NightReviewRules.doubtKey(feed.items[0]), "同じ疑いからは同じ id")
    }

    // MARK: - まとめて OK・タブの数字

    func testSureOnSelfCandidatesAndWords() throws {
        let body = """
        {"available": true, "items": [
          {"id": "c1", "day": "2026-11-12", "audio": "a.m4a", "start": 1, "end": 2, "text": "見本", "score": 0.9, "why": "plaud-match",
           "sure": true, "sure_why": "合う"},
          {"id": "c2", "day": "2026-11-12", "audio": "a.m4a", "start": 3, "end": 4, "text": "見本", "score": 0.8, "why": "plaud-match"}
        ]}
        """
        let feed = try JSONDecoder().decode(SelfCandidateFeed.self, from: data(body))
        XCTAssertEqual(feed.items?.map { $0.sure == true }, [true, false])
        XCTAssertEqual(feed.items?.first?.sure_why, "合う")
        let words = try XCTUnwrap(WordCandidateBook.parse(data(#"{"items": [{"word": "見本商事", "sure": true, "sure_why": "毎日"}, {"word": "見本駅", "sure": "yes"}, {"word": "見本町"}]}"#)))
        XCTAssertEqual(words.items.map { $0.sure == true }, [true, false, false])
        XCTAssertEqual(words.items[0].sure_why, "毎日")
        XCTAssertEqual(NightReviewRules.sureLabel("毎日"), "ほぼ確か（毎日）")
        XCTAssertEqual(NightReviewRules.sureLabel(nil), "ほぼ確か")
    }

    func testBadgeCountsOnlyTodaysFive() {
        XCTAssertEqual(NightReviewRules.badge([0, 0, 0]), 0)
        XCTAssertEqual(NightReviewRules.badge([1, 0, 2]), 3)
        XCTAssertEqual(NightReviewRules.badge([3, 200, 300]), 5, "たまっていても、今日の5つまで")
        XCTAssertEqual(NightReviewRules.badge([2, 2], cap: 3), 3)
        XCTAssertEqual(NightReviewRules.collapsed(count: 10, sure: 4), 7, "まとめて OK できるものは1つと数える")
        XCTAssertEqual(NightReviewRules.collapsed(count: 3, sure: 0), 3)
        XCTAssertEqual(NightReviewRules.collapsed(count: 3, sure: 3), 1)
        XCTAssertEqual(NightReviewRules.collapsed(count: 2, sure: 5), 1)
    }
}

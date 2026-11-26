import XCTest
@testable import LifeLog

/// 仕事の画面の作り直し（S27WMap.swift・2026-11-26）: 親の案件でのまとめ方・項目とトピックの状態・数え方・節目。
/// 見本の名前はどれも作りもの（実在の人・会社・案件ではない）。
final class S27WMapTests: XCTestCase {
    private static let sample = """
    {"version":1,"as_of":"2026-11-26",
     "projects":[
       {"id":"wp-0000000a","name":"見本の大きい案件","client":"見本商事","kind":"mine","last_moved":"2026-11-25",
        "items":[{"id":"a1","kind":"decided","text":"見本の形で進める","day":"2026-11-20"}]},
       {"id":"wp-0000000b","name":"見本の画面","kind":"mine","parent":"wp-0000000a","parent_name":"見本の大きい案件","last_moved":"2026-11-24",
        "milestone":{"day":"2026-12-04","title":"見本の終わり","days_left":8},
        "items":[{"id":"b1","kind":"issue","text":"急ぎの見本","due":"2026-11-27","ball":"me","age_days":1},
                 {"id":"b2","kind":"homework","text":"見本を送る","ball":"me","age_days":9},
                 {"id":"b3","kind":"open","text":"見本の返事","ball":"them","due":"2026-11-26"},
                 {"id":"b4","kind":"homework","text":"済んだ見本","ball":"me","state":"done"}],
        "timeline":[{"id":"b9","kind":"decided","text":"見本の色を決めた","day":"2026-11-24","time":"10:00"}]},
       {"id":"wp-0000000c","name":"見本の試し","kind":"mine","parent":"wp-0000000z","parent_name":"届いていない親","last_moved":"2026-11-20",
        "milestone":{"day":"2026-11-30","title":"見本の締め"},
        "items":[{"id":"c1","kind":"open","text":"番が分からない見本","due":"2026-11-27","due_guess":true}]},
       {"id":"wp-0000000d","name":"ひとりの見本","kind":"mine","last_moved":"2026-11-22","items":[]},
       {"id":"wp-0000000e","name":"よその見本","kind":"other","items":[{"id":"e1","kind":"homework","text":"よその宿題","ball":"me"}]},
       {"id":"wp-0000000f","name":"よその定例","kind":"other"},
       {"id":"wc-misc","name":"まだ案件に分けていないもの","kind":"mine","items":[{"id":"m1","kind":"open","text":"分けていない見本","ball":"them"}]},
       {"id":"wc-side","name":"副業の見本","kind":"side"}]}
    """
    private var board: S27WBoard { S27WRules.board(Data(Self.sample.utf8))! }
    private let today = "2026-11-26"

    func testParentDecodes() {
        let p = board.project("wp-0000000b")
        XCTAssertEqual(p?.parent, "wp-0000000a")
        XCTAssertEqual(p?.parentName, "見本の大きい案件")
        XCTAssertNil(board.project("wp-0000000a")?.parent, "無い欄は nil のまま（前の形でも読める）")
    }

    func testItemState() {
        let p = board.project("wp-0000000b")!
        XCTAssertEqual(S27WMap.state(p.items[0], today: today), .urgent, "はっきりした期限が明日まで")
        XCTAssertEqual(S27WMap.state(p.items[1], today: today), .mine)
        XCTAssertEqual(S27WMap.state(p.items[2], today: today), .theirs, "相手待ちは期限が近くても急ぎにしない")
        let c = board.project("wp-0000000c")!
        XCTAssertEqual(S27WMap.state(c.items[0], today: today), .unknown, "見込みの期限では急ぎにしない")
        XCTAssertTrue(S27WMap.isOld(p.items[1]))
        XCTAssertFalse(S27WMap.isOld(p.items[0]))
    }

    func testTopicStateAndDone() {
        let p = board.project("wp-0000000b")!
        XCTAssertEqual(S27WMap.openItems(p).map(\.id), ["b1", "b2", "b3"], "済みと決まったは開いていない")
        XCTAssertEqual(S27WMap.topicState(p, today: today), .urgent)
        XCTAssertEqual(S27WMap.openItems(p, done: ["b1"]).map(\.id), ["b2", "b3"], "端末で済みにしたものも除く")
        XCTAssertEqual(S27WMap.topicState(p, today: today, done: ["b1"]), .mine)
        XCTAssertEqual(S27WMap.topicState(board.project("wp-0000000d")!, today: today), .calm)
        XCTAssertEqual(S27WMap.sortedItems(S27WMap.openItems(p), today: today).map(\.id), ["b1", "b2", "b3"])
    }

    func testGroupsByParent() {
        let gs = S27WMap.groups(board.projects)
        XCTAssertEqual(gs.map(\.id), ["g:wp-0000000a", "g:wp-0000000z", "g:wp-0000000d", "g:other", "g:misc"])
        let big = gs[0]
        XCTAssertEqual(big.name, "見本の大きい案件")
        XCTAssertEqual(big.client, "見本商事")
        XCTAssertEqual(big.topID, "wp-0000000a")
        XCTAssertEqual(big.topics.map(\.id), ["wp-0000000a", "wp-0000000b"], "親そのものも 1 つのトピック（案件全体の話）")
        XCTAssertEqual(gs[1].name, "届いていない親", "親が届いていなくても parent_name でまとめる")
        XCTAssertEqual(gs[3].topics.map(\.id), ["wp-0000000e", "wp-0000000f"], "ほかの部署は 1 つの箱")
        XCTAssertFalse(gs.contains { $0.topics.contains { $0.kind == "side" } }, "副業は前の箱のまま")
    }

    func testGroupSortAndCounts() {
        let gs = S27WMap.sortedGroups(S27WMap.groups(board.projects), today: today)
        XCTAssertEqual(gs.map(\.id), ["g:wp-0000000a", "g:wp-0000000z", "g:wp-0000000d", "g:other", "g:misc"])
        let big = gs[0]
        XCTAssertEqual(S27WMap.groupState(big, today: today), .urgent)
        XCTAssertEqual(S27WMap.openCount(big), 3)
        XCTAssertEqual(S27WMap.kindCounts(big), S27WKindCounts(issue: 1, homework: 1, open: 1, decided: 2))
        XCTAssertEqual(S27WMap.topicTally(big, today: today), [.urgent: 1, .calm: 1])
        XCTAssertEqual(S27WMap.tally(S27WMap.groupOpenItems(big), today: today), [.urgent: 1, .mine: 1, .theirs: 1])
        XCTAssertEqual(S27WMap.sortedTopics(big.topics, today: today).map(\.id), ["wp-0000000b", "wp-0000000a"])
        XCTAssertEqual(S27WMap.lastDecided(big)?.id, "b9")
    }

    func testMilestones() {
        let gs = S27WMap.groups(board.projects)
        XCTAssertEqual(S27WMap.milestones(gs[0], today: today).map(\.day), ["2026-12-04"])
        XCTAssertTrue(S27WMap.milestones(gs[1], today: "2026-12-01").isEmpty, "過ぎた節目は出さない")
    }

    func testOldBoardWithoutParentsStillGroups() {
        let old = """
        {"projects":[{"id":"wp-00000001","name":"見本 A","kind":"mine"},{"id":"wp-00000002","name":"見本 B","kind":"mine"}]}
        """
        let gs = S27WMap.groups(S27WRules.board(Data(old.utf8))!.projects)
        XCTAssertEqual(gs.map(\.name), ["見本 A", "見本 B"], "親の無い前の形は 1 つずつの案件")
    }
}

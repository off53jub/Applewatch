import XCTest
@testable import LifeLog

/// s30 の仕事タブ（S30WRules.swift・2026-11-27）: report あり／なしの読み・規則の柱の割り当て・今日の一手の並び・
/// 「済んだかも」「古い」の箱・送る体の形（K30-2）・作り直しの読み。見本の名前はどれも作りもの（実在の人・会社・案件ではない）。
@MainActor
final class S30WTests: XCTestCase {
    private let today = "2026-11-27"

    /// 前の形（report なし）の K2
    private static let oldBoard = """
    {"version":1,"as_of":"2026-11-27",
     "projects":[
       {"id":"wp-0000000a","name":"見本の大きい案件","client":"見本商事","kind":"mine","last_moved":"2026-11-26","status_line":"見本は終盤",
        "progress":[{"day":"2026-11-24","label":"済","value":100},{"day":"2026-11-26","label":"済","value":120},{"day":"2026-11-26","label":"残り","value":5}],
        "items":[{"id":"a1","kind":"decided","text":"見本の週次の報告の形を決めた","day":"2026-11-26"}]},
       {"id":"wp-0000000b","name":"見本の打鍵","kind":"mine","parent":"wp-0000000a","last_moved":"2026-11-26",
        "milestone":{"day":"2026-12-01","title":"見本の終わり"},
        "items":[{"id":"b1","kind":"homework","text":"見本を頼む","due":"2026-11-27","ball":"me","age_days":1},
                 {"id":"b2","kind":"homework","text":"見本を貼る","ball":"me","age_days":9},
                 {"id":"b3","kind":"open","text":"見本の返事","ball":"them","due":"2026-11-30","age_days":2},
                 {"id":"b4","kind":"homework","text":"見本の済んだかも","ball":"me","auto":"done","auto_why":"見本で済んだ"},
                 {"id":"b5","kind":"homework","text":"見本の古い","ball":"me","auto":"old"},
                 {"id":"b6","kind":"homework","text":"写しで済んだ見本","ball":"me","state":"done"},
                 {"id":"b7","kind":"homework","text":"見本を送る","ball":"me","due":"2026-11-29","age_days":3}]},
       {"id":"wp-0000000c","name":"見本の画面","kind":"mine","parent":"wp-0000000a","last_moved":"2026-11-25",
        "items":[{"id":"c1","kind":"issue","text":"見本の不具合を直す","ball":"me","age_days":2},
                 {"id":"c2","kind":"open","text":"見本の相手待ち","ball":"them","age_days":5}]},
       {"id":"wp-0000000d","name":"よその見本","kind":"other","items":[{"id":"d1","kind":"homework","text":"よその見本","ball":"me"}]},
       {"id":"wc-misc","name":"まだ案件に分けていないもの","kind":"mine",
        "items":[{"id":"m1","kind":"open","text":"見本のカードを借りる","ball":"me","age_days":1},
                 {"id":"m2","kind":"open","text":"どれでもない見本","ball":"me","age_days":1}]},
       {"id":"wc-side","name":"副業の見本","kind":"side","items":[{"id":"s1","kind":"homework","text":"副業の見本"}]}]}
    """

    private static let reportPart = """
    ,"report":{"as_of":"2026-11-27","written_at":"2026-11-27T06:30:00+09:00","by":"claude",
     "projects":[{"id":"wp-0000000a","name":"見本の大きい案件","state":"caution","now":"見本は終盤です","moved":"見本の方針が決まった",
                  "snag":"見本の終わりが未定","evidence":["a1","b1","zz","b1"],
                  "numbers":[{"label":"済","value":100,"unit":null,"day":"2026-11-24","heard":true},
                             {"label":"済","value":144,"day":"2026-11-26","heard":true},
                             {"label":"残り","value":6,"day":"2026-11-26","heard":true},
                             {"label":"壊れた数","value":"たくさん"}],
                  "road":[{"day":"2026-11-27","title":"見本の会議","firm":true},{"day":"2026-12-04","title":"見本の終わり","firm":false},
                          {"day":"2026-12-01","title":"見本のカード","firm":true},{"day":"2026-12-01","title":"見本のカード","firm":true},
                          {"day":"2026-11-20","title":"過ぎた見本","firm":true}]}],
     "pillars":[{"id":"test","project":"wp-0000000a","name":"テストの進み（打鍵）","state":"mine","line":"見本の打ち直し中","topic_ids":["wp-0000000b"],"item_ids":[]},
                {"id":"bug","name":"不具合とチケット","state":"urgent","topic_ids":[],"item_ids":["c1"]},
                {"id":"broken","state":"calm"}],
     "next3":[{"item_id":"b7","why":"見本の理由"},{"item_id":"b6"},{"item_id":"b4"},{"item_id":"nope"},{"item_id":"b1"}],
     "waiting3":[{"item_id":"c2"}],
     "outside":[{"label":"ほかの部署・社内の話","item_ids":["d1"]}]}
    """

    private var oldBoard: S27WBoard { S27WRules.board(Data(Self.oldBoard.utf8))! }
    private var newBoard: S27WBoard {
        let text = String(Self.oldBoard.dropLast()) + Self.reportPart + "}"
        return S27WRules.board(Data(text.utf8))!
    }

    // MARK: 読む

    func testOldBoardHasNoReport() {
        let b = oldBoard
        XCTAssertNil(b.report, "前の形は report が無いまま読める")
        let item = b.project("wp-0000000b")!.items.first { $0.id == "b4" }!
        XCTAssertEqual(item.auto, "done")
        XCTAssertEqual(item.autoWhy, "見本で済んだ")
        XCTAssertNil(b.project("wp-0000000b")!.items.first!.auto, "無い欄は nil")
    }

    func testReportDecodesAndSkipsBrokenRows() {
        let r = newBoard.report!
        XCTAssertEqual(r.by, "claude")
        XCTAssertTrue(r.byClaude)
        XCTAssertEqual(r.writtenAt, "2026-11-27T06:30:00+09:00")
        XCTAssertEqual(r.projects.count, 1)
        XCTAssertEqual(r.projects[0].state, "caution")
        XCTAssertEqual(r.projects[0].numbers.count, 3, "数でない値の行は飛ばす")
        XCTAssertEqual(r.projects[0].road.count, 5)
        XCTAssertEqual(r.projects[0].road[1].firm, false)
        XCTAssertEqual(r.pillars.map(\.id), ["test", "bug"], "名前の無い柱は飛ばす")
        XCTAssertEqual(r.next3.count, 5)
        XCTAssertEqual(r.next3[0].why, "見本の理由")
        XCTAssertNil(r.next3[1].why)
        XCTAssertEqual(r.outside.first?.itemIDs, ["d1"])
    }

    func testBrokenReportDoesNotBreakBoard() {
        let text = String(Self.oldBoard.dropLast()) + ",\"report\":\"壊れた\"}"
        let b = S27WRules.board(Data(text.utf8))
        XCTAssertNotNil(b, "report が壊れていても K2 は読める")
        XCTAssertNil(b?.report)
    }

    // MARK: 規則の柱

    func testRulePillarWords() {
        XCTAssertEqual(S30WRules.rulePillar("見本のカードの不具合"), "card", "カードが不具合より先（当てる順）")
        XCTAssertEqual(S30WRules.rulePillar("見本の不具合のチケット"), "bug")
        XCTAssertEqual(S30WRules.rulePillar("見本の打鍵を進める"), "test")
        XCTAssertEqual(S30WRules.rulePillar("見本の締めの日"), "plan")
        XCTAssertEqual(S30WRules.rulePillar("見本の画面の文言"), "spec")
        XCTAssertEqual(S30WRules.rulePillar("見本の定例の資料"), "talk")
        XCTAssertNil(S30WRules.rulePillar("どれでもない見本"))
        XCTAssertEqual(S30WRules.pillars.count, 6)
        XCTAssertEqual(Set(S30WRules.matchOrder), Set(S30WRules.pillars.map(\.id)))
    }

    func testRuleAssignByTopicNameThenItemText() {
        let groups = S27WMap.groups(oldBoard.projects)
        let a = S30WRules.assign(groups)
        // 「見本の打鍵」はトピックの名前で test へ（中の項目は全部）
        XCTAssertEqual(Set((a.bags["test"] ?? []).map(\.id)), ["b1", "b2", "b3", "b4", "b5", "b6", "b7"])
        // 「見本の画面」は名前で spec へ（中の不具合の文も spec のまま）
        XCTAssertEqual(Set((a.bags["spec"] ?? []).map(\.id)), ["c1", "c2"])
        // 案件全体の話は名前では当てない（項目の文で: 報告 → talk）
        XCTAssertEqual((a.bags["talk"] ?? []).map(\.id), ["a1"])
        // まだ分けていないものは項目の文で
        XCTAssertEqual((a.bags["card"] ?? []).map(\.id), ["m1"])
        XCTAssertEqual(a.unassigned.map(\.id), ["m2"])
        XCTAssertEqual(a.other.map(\.id), ["d1"], "ほかの部署は外の箱")
        XCTAssertFalse(a.bags.values.joined().contains { $0.id == "s1" }, "副業は入れない")
    }

    // MARK: report なし（機械の並べ方）

    func testRuleScreen() {
        let s = S30WRules.screen(oldBoard, done: [], restored: [], today: today)
        XCTAssertFalse(s.hasReport)
        XCTAssertTrue(s.pillarsRuled)
        XCTAssertTrue(s.next3Ruled)
        XCTAssertTrue(s.cardsRuled)
        XCTAssertTrue(s.roadRuled)
        XCTAssertEqual(s.pillars.map(\.id), ["test", "card", "spec", "talk"], "中身のある柱だけ・画面の順")
        // 今日の一手: 急ぎ（今日まで）→ 期限の近い順 → 古い順。相手待ち・写しで済み・箱のものは入れない
        XCTAssertEqual(s.next3.map(\.item.id), ["b1", "b7", "b2"])
        XCTAssertEqual(s.next3[0].why, "今日まで")
        XCTAssertEqual(s.next3[1].why, "期限 11/29")
        XCTAssertEqual(s.next3[2].why, "9 日そのまま")
        XCTAssertEqual(s.next3[0].pillar, "テストの進み（打鍵）")
        XCTAssertEqual(s.next3[0].state, .urgent)
        // 相手待ち: 期限の近い順 → 長く待っている順
        XCTAssertEqual(s.waiting3.map(\.item.id), ["b3", "c2"])
        XCTAssertEqual(s.waiting3[1].why, "5 日待ち")
        XCTAssertEqual(s.mineCount, 5, "b1・b2・b7・c1・m1（番の無い m2 は数えない）")
        XCTAssertEqual(s.waitingCount, 2)
        // 状況の 1 枚（親でまとめた 1 つ）
        XCTAssertEqual(s.cards.count, 1)
        XCTAssertEqual(s.cards[0].name, "見本の大きい案件")
        XCTAssertEqual(s.cards[0].state, .caution, "急ぎがあるので注意")
        XCTAssertTrue(s.cards[0].now?.hasPrefix("見本は終盤。") == true)
        XCTAssertTrue(s.cards[0].moved?.contains("見本の週次の報告の形を決めた") == true)
        XCTAssertTrue(s.cards[0].snag?.hasPrefix("急ぎ: 見本を頼む") == true)
        XCTAssertEqual(s.cards[0].evidence.map(\.id), ["a1", "b1", "b2"], "決まった・急ぎ・長くそのまま")
        // 道のり（節目から。確かさは分からないので「?」なし）
        XCTAssertEqual(s.road.map(\.day), ["2026-11-27", "2026-12-01"])
        XCTAssertTrue(s.road[0].isToday)
        XCTAssertFalse(s.anyUnfirm)
        // タイル: 進みの数・課題（不具合の柱が無い）・次の節目
        XCTAssertEqual(s.tiles.count, 3)
        XCTAssertEqual(s.tiles[0].value, "120")
        XCTAssertEqual(s.tiles[0].unit, "済")
        XCTAssertEqual(s.tiles[0].label, "残り 5（11/26 の数）")
        XCTAssertEqual(s.tiles[0].spark, [100, 120])
        XCTAssertEqual(s.tiles[1].label, "開いている課題（古い 0）")
        XCTAssertEqual(s.tiles[1].value, "1")
        XCTAssertEqual(s.tiles[2].value, "4")
        XCTAssertEqual(s.tiles[2].unit, "日後")
        // 外の話
        XCTAssertEqual(s.outside.map(\.label), [S30WRules.otherLabel, S30WRules.unassignedLabel])
        XCTAssertEqual(s.outside[1].items.map(\.id), ["m2"])
        // 前の一覧の数（副業は数えない）
        XCTAssertEqual(s.topicCount, 5)
    }

    func testLocalDoneStaysInNext3ButLeavesCounts() {
        let s = S30WRules.screen(oldBoard, done: ["b1"], restored: [], today: today)
        XCTAssertEqual(s.next3.first?.item.id, "b1", "端末で済みにしたものは丸を付けて残す（写しで済むまで）")
        XCTAssertEqual(s.mineCount, 4)
        XCTAssertFalse(s.pillars.first { $0.id == "test" }!.open.contains { $0.id == "b1" })
    }

    // MARK: 箱（auto）

    func testAutoBoxesAndRestore() {
        let s = S30WRules.screen(oldBoard, done: [], restored: [], today: today)
        let test = s.pillars.first { $0.id == "test" }!
        XCTAssertEqual(test.autoDone.map(\.id), ["b4"])
        XCTAssertEqual(test.autoOld.map(\.id), ["b5"])
        XCTAssertFalse(test.open.contains { $0.id == "b4" || $0.id == "b5" || $0.id == "b6" })
        XCTAssertEqual(test.open.map(\.id), ["b1", "b7", "b2", "b3"], "悪い状態 → 期限 → 古い順")
        XCTAssertEqual(test.oldCount, 1)
        XCTAssertEqual(test.state, .urgent)
        let back = S30WRules.screen(oldBoard, done: [], restored: ["b4"], today: today)
        let test2 = back.pillars.first { $0.id == "test" }!
        XCTAssertTrue(test2.autoDone.isEmpty, "戻したものは箱から出る")
        XCTAssertTrue(test2.open.contains { $0.id == "b4" })
        XCTAssertEqual(S30WRules.boxed(oldBoard.project("wp-0000000b")!.items[4], restored: []), "old")
    }

    func testKeptRestored() {
        let kept = S30WRules.keptRestored(["b4": "2026-11-27", "b1": "2026-11-27", "gone": "2026-11-20"], board: oldBoard)
        XCTAssertEqual(kept, ["b4": "2026-11-27"], "箱の印が無くなった・項目が無いものは捨てる")
    }

    // MARK: report あり

    func testReportScreen() {
        let s = S30WRules.screen(newBoard, done: [], restored: [], today: today)
        XCTAssertTrue(s.hasReport)
        XCTAssertTrue(s.byClaude)
        XCTAssertFalse(s.pillarsRuled)
        XCTAssertEqual(s.cards.count, 1)
        XCTAssertEqual(s.cards[0].state, .caution)
        XCTAssertEqual(s.cards[0].now, "見本は終盤です")
        XCTAssertEqual(s.cards[0].client, "見本商事")
        XCTAssertEqual(s.cards[0].evidence.map(\.id), ["a1", "b1"], "届いていない id と重なりは外す")
        XCTAssertFalse(s.cardsRuled)
        // 柱
        XCTAssertEqual(s.pillars.map(\.id), ["test", "bug"])
        XCTAssertEqual(s.pillars[0].line, "見本の打ち直し中")
        XCTAssertEqual(s.pillars[1].state, .urgent, "report の state をそのまま")
        XCTAssertEqual(s.pillars[1].open.map(\.id), ["c1"])
        XCTAssertNotNil(s.pillars[1].line, "line が無ければ規則の 1 行")
        // 今日の一手: 名指しの順。写しで済み・箱・届いていないものは飛ばす
        XCTAssertEqual(s.next3.map(\.item.id), ["b7", "b1"])
        XCTAssertEqual(s.next3[0].why, "見本の理由")
        XCTAssertEqual(s.next3[1].why, "今日まで", "why が無ければ規則の札")
        XCTAssertFalse(s.next3Ruled)
        XCTAssertEqual(s.waiting3.map(\.item.id), ["c2"])
        // 数字のタイル（聞こえた数・小さな棒）
        XCTAssertEqual(s.tiles[0].value, "144")
        XCTAssertEqual(s.tiles[0].unit, "済")
        XCTAssertEqual(s.tiles[0].label, "残り 6（11/26 に聞こえた数）")
        XCTAssertEqual(s.tiles[0].spark, [100, 144])
        XCTAssertEqual(s.tiles[1].label, "開いている不具合の話（古い 0）")
        XCTAssertEqual(s.tiles[1].value, "1")
        XCTAssertEqual(s.tiles[2].value, "今日")
        XCTAssertEqual(s.tiles[2].label, "見本の会議")
        // 道のり: 過ぎたものは出さない・同じものは 1 つ・確定していない日は「?」
        XCTAssertEqual(s.road.map(\.title), ["見本の会議", "見本のカード", "見本の終わり"])
        XCTAssertEqual(s.road.map(\.firm), [true, true, false])
        XCTAssertTrue(s.anyUnfirm)
        XCTAssertFalse(s.roadRuled)
        XCTAssertEqual(s.road[2].daysLeft, 7)
        // 外
        XCTAssertEqual(s.outside.map(\.label), ["ほかの部署・社内の話"])
        XCTAssertFalse(s.outsideRuled)
    }

    func testReportWithEmptyPartsFallsBackPerPart() {
        let text = String(Self.oldBoard.dropLast()) + ",\"report\":{\"by\":\"rules\",\"projects\":[]}}"
        let s = S30WRules.screen(S27WRules.board(Data(text.utf8))!, done: [], restored: [], today: today)
        XCTAssertTrue(s.hasReport)
        XCTAssertFalse(s.byClaude)
        XCTAssertTrue(s.pillarsRuled, "report の柱が空なら規則で")
        XCTAssertTrue(s.next3Ruled)
        XCTAssertTrue(s.cardsRuled)
        XCTAssertEqual(s.next3.map(\.item.id), ["b1", "b7", "b2"])
    }

    // MARK: 小さな決まり

    func testWhy() {
        func item(_ due: String?, guess: Bool? = nil, age: Int? = nil) -> S27WItem {
            S27WItem(id: "x", kind: "homework", text: "見本", due: due, dueGuess: guess, ageDays: age)
        }
        XCTAssertEqual(S30WRules.why(item("2026-11-27"), today: today), "今日まで")
        XCTAssertEqual(S30WRules.why(item("2026-11-28"), today: today), "明日まで")
        XCTAssertEqual(S30WRules.why(item("2026-11-25"), today: today), "2 日過ぎ")
        XCTAssertEqual(S30WRules.why(item("2026-12-04", guess: true), today: today), "期限 12/4（仮）")
        XCTAssertEqual(S30WRules.why(item(nil, age: 3), today: today), "3 日そのまま")
        XCTAssertNil(S30WRules.why(item(nil, age: 1), today: today))
        XCTAssertEqual(S30WRules.pillarLabel(.calm), "落ち着いている")
        XCTAssertEqual(S30WRules.state("theirs"), .theirs)
        XCTAssertNil(S30WRules.state("?"))
    }

    func testNumberTileWithUnitAndNoHeard() {
        let t = S30WRules.numberTile([S30WNumber(label: "打鍵", value: 12.5, unit: "%", day: "2026-11-26")])
        XCTAssertEqual(t?.value, "12.5")
        XCTAssertEqual(t?.unit, "%")
        XCTAssertEqual(t?.label, "打鍵（11/26 の数）")
        XCTAssertTrue(t?.spark.isEmpty == true)
        XCTAssertNil(S30WRules.numberTile([]))
    }

    func testNextTileWithoutToday() {
        let road = S30WRules.road([S30WRoadPoint(day: "2026-11-28", title: "見本", firm: false)], today: today)
        XCTAssertEqual(road.count, 2, "今日の点はいつも左に")
        XCTAssertEqual(road[0].title, "")
        let t = S30WRules.nextTile(road)
        XCTAssertEqual(t.value, "1")
        XCTAssertEqual(t.tone, .urgent)
        XCTAssertTrue(t.label.contains("?"))
        XCTAssertEqual(S30WRules.nextTile([]).value, "—")
        XCTAssertTrue(S30WRules.road([S30WRoadPoint(day: "2026-11-01", title: "過ぎた")], today: today).isEmpty)
    }

    // MARK: K30-2 送る体・作り直しの読み

    func testFreshEntries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = WorkDigest.Entry(day: "2026-11-27", text: "見本のまとめ", sections: nil, source: .paste, addedAt: now.addingTimeInterval(-10))
        let b = WorkDigest.Entry(day: "2026-11-26", text: "古い見本", sections: nil, source: .photo, addedAt: now.addingTimeInterval(-3600))
        let c = WorkDigest.Entry(day: "2026-11-27", text: "送った見本", sections: nil, source: .paste, addedAt: now.addingTimeInterval(-5))
        let fresh = S30WRules.fresh([b, c, a], sent: [c.id], now: now)
        XCTAssertEqual(fresh.map(\.id), [a.id], "保存したばかりで、まだ送っていないものだけ")
    }

    func testPushBodyIsSameShapeAsWorkDigests() throws {
        var sections = WorkDigest.Sections()
        sections.decided = ["見本の形で進める"]
        let e = WorkDigest.Entry(day: "2026-11-27", text: "【日付】2026-11-27\n【決まったこと】\n・見本の形で進める", sections: sections, source: .photo,
                                 addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let body = try XCTUnwrap(S30WRules.pushBody([e]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Array(object.keys), ["entries"])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(Set(entries[0].keys), ["id", "day", "text", "sections", "source", "addedAt"])
        XCTAssertEqual(entries[0]["source"] as? String, "photo")
        // 端末の work-digests.json と同じ書き方（JSONEncoder の既定の日付）で、そのまま読み戻せる
        let one = try JSONSerialization.data(withJSONObject: entries[0])
        let back = try JSONDecoder().decode(WorkDigest.Entry.self, from: one)
        XCTAssertEqual(back, e)
        XCTAssertNil(S30WRules.pushBody([]))
    }

    func testPushReplyAndRun() {
        let r = S30WRules.pushReply(Data(#"{"accepted":2,"run":"started","available":true}"#.utf8))
        XCTAssertEqual(r, S30WPushReply(accepted: 2, run: "started", available: true))
        XCTAssertNil(S30WRules.pushReply(Data("壊れた".utf8)))
        let run = S30WRules.run(Data(#"{"state":"idle","started_at":"2026-11-27T10:00:00+09:00","finished_at":"2026-11-27T10:01:30+09:00","ok":true,"available":true}"#.utf8))
        XCTAssertEqual(run?.state, "idle")
        XCTAssertEqual(run?.ok, true)
        let running = S30WRules.run(Data(#"{"state":"running","started_at":null,"finished_at":null,"ok":null,"available":true}"#.utf8))
        XCTAssertEqual(running?.state, "running")
        XCTAssertNil(running?.ok)
    }

    func testRunFinished() {
        let posted = S27WRules.date("2026-11-27T10:00:00+09:00")!
        let idleAfter = S30WRun(state: "idle", startedAt: "2026-11-27T10:00:05+09:00", finishedAt: "2026-11-27T10:01:00+09:00", ok: true)
        let idleBefore = S30WRun(state: "idle", startedAt: "2026-11-27T09:40:00+09:00", finishedAt: "2026-11-27T09:45:00+09:00", ok: true)
        let running = S30WRun(state: "running", startedAt: "2026-11-27T10:00:05+09:00")
        XCTAssertTrue(S30WRules.runFinished(idleAfter, postedAt: posted, sawRunning: false, needStartAfter: false))
        XCTAssertFalse(S30WRules.runFinished(idleBefore, postedAt: posted, sawRunning: false, needStartAfter: false), "前の回の終わりは待つ")
        XCTAssertTrue(S30WRules.runFinished(idleBefore, postedAt: posted, sawRunning: true, needStartAfter: false), "走っていたのを見たあとの idle は終わり")
        XCTAssertFalse(S30WRules.runFinished(running, postedAt: posted, sawRunning: true, needStartAfter: false))
        // 送ったときにもう走っていた（already）: 送ったあとに始まった回だけ
        XCTAssertFalse(S30WRules.runFinished(idleBefore, postedAt: posted, sawRunning: true, needStartAfter: true))
        XCTAssertTrue(S30WRules.runFinished(idleAfter, postedAt: posted, sawRunning: true, needStartAfter: true))
        // 時計のずれ（家の PC が 30 秒遅れ）は許す
        let skew = S30WRun(state: "idle", startedAt: nil, finishedAt: "2026-11-27T09:59:40+09:00", ok: true)
        XCTAssertTrue(S30WRules.runFinished(skew, postedAt: posted, sawRunning: false, needStartAfter: false))
    }

    func testRememberedAndBand() {
        XCTAssertEqual(S30WRules.remembered(["a", "b"], adding: ["b", "c"]), ["a", "b", "c"])
        XCTAssertEqual(S30WRules.remembered(["a", "b", "c"], adding: ["d"], limit: 2), ["c", "d"])
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotNil(S30WRules.visible(.rebuilding(at), now: at.addingTimeInterval(170)))
        XCTAssertNil(S30WRules.visible(.rebuilding(at), now: at.addingTimeInterval(400)), "止まった帯は残さない")
        XCTAssertNotNil(S30WRules.visible(.done(at, ok: true), now: at.addingTimeInterval(300)))
        XCTAssertNil(S30WRules.visible(.fallback(at, S30WRules.fallbackFailed), now: at.addingTimeInterval(700)))
        XCTAssertEqual(S30WRules.bandTitle(.rebuilding(at)), "作り直しています")
        XCTAssertNil(S30WRules.bandTitle(.fallback(at, "x")), "今までどおりは小さく書くだけ")
        XCTAssertEqual(S30WRules.bandDetail(.fallback(at, S30WRules.fallbackNoDoor), clock: "10:00"), S30WRules.fallbackNoDoor)
        XCTAssertTrue(S30WRules.fallbackNoDoor.contains("15 分ごと"))
    }
}

import XCTest
@testable import LifeLog

/// s31 の文字と声の結び（S31ARules.swift・2026-11-27）: K2 の項目の voice の読み（あり／なし／前の形）・
/// /links の答えの読み（available false・壊れ）・強さの言葉・日ごとの並び・時刻・開く会話の探し方。
/// 見本の名前・部屋・言葉はどれも作りもの（実在の人・会社・案件・LINE ではない）。
@MainActor
final class S31ATests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func board(_ items: String) -> S27WBoard? {
        let json = """
        {"version":1,"as_of":"2026-11-27",
         "projects":[{"id":"wp-0000000a","name":"見本の案件","kind":"mine","items":[\(items)]}]}
        """
        return S27WRules.board(Data(json.utf8))
    }

    private func item(_ items: String, _ id: String) -> S27WItem? {
        board(items)?.projects.first?.items.first { $0.id == id }
    }

    // MARK: K2 の voice

    func testItemVoiceIsRead() throws {
        let it = try XCTUnwrap(item("""
        {"id":"a1","kind":"homework","text":"見本を頼む",
         "voice":[{"link":"ln-0001","conv":"c-1","start":"2026-11-24T15:30:00+09:00","who":["見本 花子","自分"],"say":"見本は今日中に"}]}
        """, "a1"))
        let v = try XCTUnwrap(it.voice)
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].link, "ln-0001")
        XCTAssertEqual(v[0].conv, "c-1")
        XCTAssertEqual(v[0].who, ["見本 花子", "自分"])
        XCTAssertEqual(v[0].say, "見本は今日中に")
    }

    func testItemWithoutVoiceIsNil() throws {
        let it = try XCTUnwrap(item(#"{"id":"a1","kind":"homework","text":"見本を頼む"}"#, "a1"))
        XCTAssertNil(it.voice)
    }

    /// 前の形・壊れた voice でも項目は読める（voice は nil）
    func testBrokenVoiceKeepsItem() throws {
        let asText = try XCTUnwrap(item(#"{"id":"a1","text":"見本","voice":"声"}"#, "a1"))
        XCTAssertNil(asText.voice)
        let empty = try XCTUnwrap(item(#"{"id":"a2","text":"見本","voice":[]}"#, "a2"))
        XCTAssertNil(empty.voice)
        let useless = try XCTUnwrap(item(#"{"id":"a3","text":"見本","voice":[{"link":"ln-1"},5]}"#, "a3"))
        XCTAssertNil(useless.voice, "時刻も発言も無いもの・形の違う行は捨てる")
    }

    /// 2 件まで・who が 1 つの文字でも読む・使えない行は飛ばす
    func testVoiceKeepsTwoAndReadsSingleWho() throws {
        let it = try XCTUnwrap(item("""
        {"id":"a1","text":"見本","voice":[
          {"start":"2026-11-24T10:00:00+09:00","who":"見本 太郎","say":"一つめ"},
          {"conv":"c-x"},
          {"say":"二つめ"},
          {"say":"三つめ"}]}
        """, "a1"))
        let v = try XCTUnwrap(it.voice)
        XCTAssertEqual(v.map(\.say), ["一つめ", "二つめ"])
        XCTAssertEqual(v[0].who, ["見本 太郎"])
        XCTAssertEqual(v[1].who, [])
    }

    // MARK: /links の答え

    private static let links = """
    {"version":1,"generated_at":"2026-11-27T08:00:00+09:00","days":["2026-11-24","2026-11-25"],
     "links":[
      {"id":"ln-b","day":"2026-11-24","text":{"src":"line","ref":"r","kind":"message","who":["見本 花子"],"at":"18:05","room":"見本の部屋","quote":"見本の夕方"},
       "voice":{"conv":"c-2","start":"2026-11-24T18:20:00+09:00","end":"2026-11-24T18:30:00+09:00","speakers":["見本 花子"],
                "lines":[{"t":"2026-11-24T18:21:00+09:00","who":"見本 花子","say":"夕方の声"}]},
       "score":0.6,"by":"claude","why":"見本の言葉","work":false,"item_ids":[]},
      {"id":"ln-a","day":"2026-11-24","text":{"src":"teams","ref":"r","kind":"homework","who":["見本 花子"],"at":"9:10","room":null,"quote":"見本の朝"},
       "voice":{"conv":"c-1","start":"2026-11-24T09:30:00+09:00","end":"2026-11-24T09:40:00+09:00","speakers":["自分"],"lines":[]},
       "score":0.9,"by":"rules","work":true,"item_ids":["a1"]},
      {"id":"ln-c","day":"2026-11-25","text":{"src":"teams","quote":"見本の次の日"},
       "voice":{"start":"2026-11-25T11:00:00+09:00"}},
      {"id":"ln-broken","day":"2026-11-25","text":{"src":"teams"}},
      7],
     "people":[{"name":"見本 花子","person_id":"pp-1","days":["2026-11-24"],"text_n":2,"voice_n":2,"summary":"見本のまとめ。","link_ids":["ln-a","ln-b"]},
               {"name":"見本 太郎","summary":"別の見本。"}]}
    """

    private func links() throws -> S31ALinks {
        guard case .links(let l) = S31ARules.reply(Data(Self.links.utf8)) else { throw XCTSkip("読めない") }
        return l
    }

    func testLinksReplyIsRead() throws {
        let l = try links()
        XCTAssertEqual(l.links.map(\.id), ["ln-b", "ln-a", "ln-c"], "壊れた行は飛ばす")
        XCTAssertEqual(l.people.count, 2)
        let a = try XCTUnwrap(l.links.first { $0.id == "ln-a" })
        XCTAssertTrue(a.isWork)
        XCTAssertEqual(a.itemIDs, ["a1"])
        XCTAssertNil(a.text.room)
        let b = try XCTUnwrap(l.links.first { $0.id == "ln-b" })
        XCTAssertEqual(b.voice.firstRef.say, "夕方の声")
        XCTAssertEqual(b.voice.firstRef.who, ["見本 花子"])
        XCTAssertEqual(b.voice.firstRef.start, "2026-11-24T18:21:00+09:00")
        // 声の行が無いときは区間の始まりと話し手
        XCTAssertEqual(a.voice.firstRef.start, "2026-11-24T09:30:00+09:00")
        XCTAssertEqual(a.voice.firstRef.who, ["自分"])
        XCTAssertNil(a.voice.firstRef.say)
    }

    func testLinksUnavailableAndBroken() {
        XCTAssertEqual(S31ARules.reply(Data(#"{"available":false}"#.utf8)), .none)
        XCTAssertEqual(S31ARules.reply(Data("見本".utf8)), .bad)
        XCTAssertEqual(S31ARules.reply(Data("[1,2]".utf8)), .bad)
        // links が無い・形が違うときは空として読む（節は出さない）
        guard case .links(let empty) = S31ARules.reply(Data(#"{"links":"x"}"#.utf8)) else { return XCTFail("空として読む") }
        XCTAssertTrue(empty.isEmpty)
    }

    func testScoreClampAndVoiceLinesLimit() throws {
        let json = """
        {"links":[{"id":"ln-1","day":"2026-11-24","text":{"src":"teams","quote":"見本"},"score":4,
          "voice":{"lines":[{"say":"1"},{"say":"2"},{"say":"3"},{"say":"4"}]}}]}
        """
        guard case .links(let l) = S31ARules.reply(Data(json.utf8)) else { return XCTFail("読める") }
        XCTAssertEqual(l.links.first?.score, 1)
        XCTAssertEqual(l.links.first?.voice.lines.count, 3)
    }

    // MARK: 強さの言葉

    func testStrengthWords() {
        XCTAssertEqual(S31ARules.strength(0.95), "おそらく同じ話")
        XCTAssertEqual(S31ARules.strength(0.8), "おそらく同じ話")
        XCTAssertEqual(S31ARules.strength(0.6), "たぶん同じ話")
        XCTAssertEqual(S31ARules.strength(0.2), "同じ話かもしれない")
        XCTAssertEqual(S31ARules.strength(nil), "同じ話の候補")
        XCTAssertEqual(S31ARules.strength(.nan), "同じ話の候補")
    }

    // MARK: 日ごとの並び・人

    func testByDayOrder() throws {
        let days = S31ARules.byDay(try links().links)
        XCTAssertEqual(days.map(\.day), ["2026-11-25", "2026-11-24"], "新しい日が上")
        XCTAssertEqual(days[1].links.map(\.id), ["ln-a", "ln-b"], "日の中は文字の時刻の順（9:10 は 09:10）")
        XCTAssertEqual(days[0].links.map(\.id), ["ln-c"])
    }

    func testPersonSummary() throws {
        let l = try links()
        XCTAssertEqual(S31ARules.person(l, name: "見本 花子さん")?.summary, "見本のまとめ。")
        XCTAssertEqual(S31ARules.person(l, name: "別の名前", id: "pp-1")?.summary, "見本のまとめ。")
        XCTAssertEqual(S31ARules.person(l, name: "見本 太郎")?.summary, "別の見本。")
        XCTAssertNil(S31ARules.person(l, name: "見本 次郎"), "2 人以上いて合わなければ出さない")
        let one = S31ALinks(people: [S31APerson(name: "見本 三郎", summary: "一人だけ")])
        XCTAssertEqual(S31ARules.person(one, name: "見本さぶ")?.summary, "一人だけ")
    }

    func testLinkLookupForItemScore() throws {
        let l = try links()
        XCTAssertEqual(S31ARules.link("ln-a", in: [S31ALinks(), l])?.score, 0.9)
        XCTAssertNil(S31ARules.link("ln-zz", in: [l]))
        XCTAssertNil(S31ARules.link(nil, in: [l]))
    }

    // MARK: 時刻・出どころ

    func testMomentUsesLocalDay() throws {
        let m = try XCTUnwrap(S31ARules.moment("2026-11-23T20:30:00Z", timeZone: tokyo))
        XCTAssertEqual(m.day, "2026-11-24", "UTC の前の日の夜は、東京では次の日の朝")
        XCTAssertEqual(S31ARules.clock(m.time, timeZone: tokyo), "05:30")
        XCTAssertNotNil(S31ARules.moment("2026-11-24T15:30:00.250+09:00", timeZone: tokyo))
        XCTAssertNil(S31ARules.moment("見本", timeZone: tokyo))
        XCTAssertNil(S31ARules.moment(nil, timeZone: tokyo))
        XCTAssertEqual(S31ARules.when("2026-11-24T06:05:00Z", timeZone: tokyo), "11/24 15:05")
        XCTAssertEqual(S31ARules.when(nil, timeZone: tokyo), "")
    }

    func testSourceAndWhoLines() {
        XCTAssertEqual(S31ARules.source(S31ALinkText(src: "line", at: "18:05", room: "見本の部屋", quote: "q")), "LINE・見本の部屋・18:05")
        XCTAssertEqual(S31ARules.source(S31ALinkText(src: "teams", quote: "q")), "Teams")
        XCTAssertEqual(S31ARules.whoLine([]), "話した人は分かりません")
        XCTAssertEqual(S31ARules.whoLine(["見本 花子", " ", "自分"]), "見本 花子・自分")
    }

    func testMarkLine() {
        XCTAssertEqual(S31ARules.markLine(who: "見本 花子", when: "11/24 15:30", more: 0), "声・見本 花子・11/24 15:30")
        XCTAssertEqual(S31ARules.markLine(who: "見本 花子", when: "", more: 1), "声・見本 花子・ほか 1")
    }

    // MARK: 開く会話・声を聞く行

    func testConversationAndNearestLine() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let spans: [(start: Date, end: Date)] = [
            (start: base, end: base.addingTimeInterval(300)),
            (start: base.addingTimeInterval(3600), end: base.addingTimeInterval(3900)),
        ]
        XCTAssertEqual(S31ARules.conversationIndex(spans, at: base.addingTimeInterval(120)), 0, "時刻を含む会話")
        XCTAssertEqual(S31ARules.conversationIndex(spans, at: base.addingTimeInterval(3300)), 1, "含まなければ始まりの近い会話（10 分の中）")
        XCTAssertNil(S31ARules.conversationIndex(spans, at: base.addingTimeInterval(1800)), "どれからも遠ければ開かない（時刻だけ）")
        let rows: [(Date, Int)] = [(base, 0), (base.addingTimeInterval(50), 1), (base.addingTimeInterval(500), 2)]
        XCTAssertEqual(S31ARules.nearest(rows, to: base.addingTimeInterval(40)), 1)
        XCTAssertNil(S31ARules.nearest(rows, to: base.addingTimeInterval(1500)))
    }

    func testCopyFileNamesDoNotHoldNames() {
        XCTAssertEqual(S31ABook.fileName(S31ABook.dayKey("2026-11-24")), "day-2026-11-24.json")
        let person = S31ABook.fileName(S31ABook.personKey("見本 花子"))
        XCTAssertTrue(person.hasPrefix("q-") && person.hasSuffix(".json"))
        XCTAssertFalse(person.contains("見本"))
    }
}

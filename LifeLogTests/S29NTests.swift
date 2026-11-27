import XCTest
@testable import LifeLog

/// s29 の名前付けを軽くする（S29NRules.swift）。人・行・まとまりはすべて作りもの
final class S29NTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ d: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m, second: s))!
    }

    private func line(_ id: String?, _ text: String, at time: Date, audio: String? = "a.m4a", offset: Double? = 1,
                      end: Double? = nil, media: String? = nil) -> ConversationLog.Line {
        var l = ConversationLog.Line(time: time, speaker: id.map { "人物" + $0 }, text: text, audio: audio, offset: offset,
                                     speakerID: id)
        l.end = end
        l.media = media
        return l
    }

    private func person(_ id: String, name: String? = nil, seconds: Double = 600, hidden: Bool? = nil, quiet: Bool? = nil,
                        voices: [[Float]] = [], pinned: Bool = false, samples: [SpeakerLabeler.Sample] = []) -> SpeakerLabeler.Person {
        var list: [SpeakerLabeler.Voice] = []
        for v in voices { list.append(SpeakerLabeler.Voice(embedding: v, pinned: pinned, added: at(20, 9), model: SpeakerLabeler.model)) }
        return SpeakerLabeler.Person(id: id, name: name, context: nil, voices: list, seconds: seconds, lastHeard: at(26, 9),
                                     samples: samples, updated: nil, hidden: hidden, quiet: quiet)
    }

    private func stat(lines: Int, days: [String], seconds: Double, quote: Bool = true) -> S29NStat {
        var s = S29NStat(lines: lines, days: Set(days), seconds: seconds)
        if quote { s.quotes = [S29NQuote(time: at(26, 10), text: "見本の発言です", audio: "a.m4a", offset: 1, end: 3)] }
        return s
    }

    // MARK: 7 日の数（声18・声24）

    func testTallyCountsLinesDaysSecondsQuotesAndApart() {
        let talks = [
            S29NTalk(day: "2026-11-25", media: false, lines: [
                line("12", "おはようございます、今日の件です", at: at(25, 9), offset: 0, end: 4),
                line("40", "はい", at: at(25, 9, 1), offset: 5, end: 6),
                line(SpeakerLabeler.selfID, "自分の行は数えない", at: at(25, 9, 2)),
                line("12", "テレビの行", at: at(25, 9, 3), media: "テレビ"),
            ]),
            S29NTalk(day: "2026-11-26", media: false, lines: [line("12", "あしたもよろしく", at: at(26, 9), audio: "b.m4a", offset: 0, end: 3)]),
            S29NTalk(day: "2026-11-26", media: true, lines: [line("12", "放送の会話", at: at(26, 20))]),
        ]
        let r = S29NRules.tally(talks)
        XCTAssertEqual(r.stats["12"]?.lines, 2)
        XCTAssertEqual(r.stats["12"]?.days, ["2026-11-25", "2026-11-26"])
        XCTAssertEqual(r.stats["12"]?.seconds ?? 0, 7, accuracy: 0.01)
        XCTAssertEqual(r.stats["12"]?.quotes.first?.text, "おはようございます、今日の件です", "長い発言から")
        XCTAssertNil(r.stats[SpeakerLabeler.selfID])
        XCTAssertEqual(r.stats["40"]?.quotes.count, 0, "短すぎる発言は見せない")
        XCTAssertTrue(r.apart.contains(["12", "40"]), "同じ区切りに一緒に出た 2 人は同じ人ではない")
    }

    // MARK: 山の並び・しぼり・quiet

    func testPileOrderFilterQuietAndPasserby() {
        let people = [person("1"), person("2"), person("3"), person("4", quiet: true), person("5"), person("6"),
                      person("7", name: "見本花子"), person(SpeakerLabeler.selfID)]
        let stats: [String: S29NStat] = [
            "1": stat(lines: 40, days: ["2026-11-20", "2026-11-22"], seconds: 400),
            "2": stat(lines: 90, days: ["2026-11-21", "2026-11-23", "2026-11-25"], seconds: 900),
            "3": stat(lines: 200, days: ["2026-11-25"], seconds: 2000),  // 1 日だけ（届かない）
            "4": stat(lines: 300, days: ["2026-11-20", "2026-11-21"], seconds: 3000),  // もう聞かない
            "5": stat(lines: 30, days: ["2026-11-20", "2026-11-21"], seconds: 120),  // 2 分（届かない）
            "6": stat(lines: 50, days: ["2026-11-20", "2026-11-21"], seconds: 500),  // 通りすがり
            "7": stat(lines: 99, days: ["2026-11-20", "2026-11-21"], seconds: 999),  // 名前がある
        ]
        let r = S29NPile.build(people: people, stats: stats, groups: [], skip: [], passerby: ["6"], done: [],
                               minDays: 2, minSeconds: 180, selfVoices: 5, selfVoiceHidden: false)
        XCTAssertEqual(r.cards.map(\.id), ["p:2", "p:1"], "効き目（行）の大きい順・2 日 3 分に届く人だけ")
        XCTAssertEqual(r.below, 2)
        XCTAssertEqual(r.quiet, 1)
        XCTAssertEqual(r.skipped, 1)
        // しきい値を 1 日・1 分にすると届く人が増える（変える前 2 人 → 後 4 人）
        let loose = S29NPile.build(people: people, stats: stats, groups: [], skip: [], passerby: ["6"], done: [],
                                   minDays: 1, minSeconds: 60, selfVoices: 5, selfVoiceHidden: false)
        XCTAssertEqual(loose.cards.map(\.id), ["p:3", "p:2", "p:1", "p:5"])
    }

    func testNoMaterialIsNotAskedAndSelfVoiceCountsInDailyThree() {
        let people = [person("1"), person("2"), person("8"), person("9")]
        let stats: [String: S29NStat] = [
            "1": stat(lines: 10, days: ["2026-11-20", "2026-11-21"], seconds: 300, quote: false),
            "2": stat(lines: 20, days: ["2026-11-20", "2026-11-21"], seconds: 300),
            "8": stat(lines: 30, days: ["2026-11-20", "2026-11-21"], seconds: 300),
            "9": stat(lines: 40, days: ["2026-11-20", "2026-11-21"], seconds: 300),
        ]
        let r = S29NPile.build(people: people, stats: stats, groups: [], skip: [], passerby: [], done: ["p:9"],
                               minDays: 2, minSeconds: 180, selfVoices: 1, selfVoiceHidden: false)
        XCTAssertEqual(r.noMaterial, 1, "発言の無い声は出さない")
        XCTAssertEqual(r.cards.map(\.id), ["self", "p:8", "p:2"], "自分の声を録るは先頭・答えた札は出さない")
        XCTAssertEqual(S29NPile.today(r.cards, answeredToday: 0, daily: 3, gateLeft: 3).count, 3)
        XCTAssertEqual(S29NPile.today(r.cards, answeredToday: 2, daily: 3, gateLeft: 3).map(\.id), ["self"])
        XCTAssertEqual(S29NPile.today(r.cards, answeredToday: 0, daily: 3, gateLeft: 1).count, 1, "全体の 1 日 3 問の残りを超えない")
        XCTAssertEqual(S29NPile.badge(r.cards, answeredToday: 1, daily: 3), 2)
        let enough = S29NPile.build(people: people, stats: stats, groups: [], skip: [], passerby: [], done: [],
                                    minDays: 2, minSeconds: 180, selfVoices: 3, selfVoiceHidden: false)
        XCTAssertFalse(enough.cards.contains { $0.kind == .selfVoice }, "見本が足りていれば出さない")
    }

    // MARK: 声19 まとまり（s29_groups あり／なし）

    func testGroupsDecodeWhenPresentAndNilWhenAbsent() throws {
        let with = """
        {"available":true,"days":[],"s29_groups":[
          {"id":"g29-1","labels":["人物12","人物40","人物41"],"score":0.71,"seconds":420.5,"days":3},
          {"id":"g29-2","labels":["人物50"],"score":0.9},
          {"id":"bad id!","labels":["人物1","人物2"],"score":0.5},
          {"id":"g29-3","labels":["人物60","見本花子"],"score":0.6}]}
        """
        let groups = try XCTUnwrap(S29NGroups.decode(Data(with.utf8)))
        XCTAssertEqual(groups.map(\.id), ["g29-1", "g29-3"], "1 人だけ・id のおかしいものは使わない")
        XCTAssertEqual(groups[0].seconds, 420.5)
        XCTAssertEqual(groups[0].days, 3)
        XCTAssertTrue(S29NGroups.isAvailable(Data(with.utf8)))
        XCTAssertNil(S29NGroups.decode(Data(#"{"available":true,"days":[]}"#.utf8)), "欄が無ければ nil（端末の中でまとめる）")
        XCTAssertEqual(S29NGroups.decode(Data(#"{"available":true,"s29_groups":[]}"#.utf8)), [])
    }

    func testGroupBecomesOneCardAndNamedLabelIsAHint() {
        let people = [person("12"), person("40"), person("41"), person("60"), person("7", name: "見本花子")]
        let days = ["2026-11-20", "2026-11-21"]
        let stats: [String: S29NStat] = [
            "12": stat(lines: 10, days: [days[0]], seconds: 100), "40": stat(lines: 30, days: [days[1]], seconds: 100),
            "41": stat(lines: 5, days: [days[1]], seconds: 10), "60": stat(lines: 8, days: days, seconds: 200),
        ]
        let groups = [S29NGroup(id: "g29-1", labels: ["人物12", "人物40", "人物41"], score: 0.7),
                      S29NGroup(id: "g29-3", labels: ["人物60", "見本花子"], score: 0.6)]
        let r = S29NPile.build(people: people, stats: stats, groups: groups, skip: [], passerby: [], done: [],
                               minDays: 2, minSeconds: 180, selfVoices: 5, selfVoiceHidden: false)
        XCTAssertEqual(r.cards.map(\.id), ["g:g29-1", "p:60"])
        XCTAssertEqual(r.cards[0].members, ["40", "12", "41"], "行の多い順")
        XCTAssertEqual(r.cards[0].lines, 45)
        XCTAssertEqual(r.cards[0].days, 2, "1 人ずつなら届かないが、まとめると 2 日・3.5 分で届く")
        XCTAssertEqual(r.cards[1].hinted, ["7"])
        // 「この中に別の人がいる」と答えたまとまりは、1 人ずつに戻る
        let split = S29NPile.build(people: people, stats: stats, groups: groups, skip: [], passerby: [], done: ["g:g29-1"],
                                   minDays: 1, minSeconds: 60, selfVoices: 5, selfVoiceHidden: false)
        XCTAssertTrue(split.cards.contains { $0.id == "p:40" })
    }

    func testLocalGroupsUseVoiceClosenessAndKeepApart() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0.995, 0.0998, 0]
        let c: [Float] = [0, 1, 0]
        let people = [person("1", seconds: 100, voices: [a]), person("2", seconds: 50, voices: [b]), person("3", seconds: 80, voices: [c])]
        let groups = S29NGroups.local(people, apart: [], limit: 0.40)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].labels), ["人物1", "人物2"])
        XCTAssertFalse(groups[0].fromPC)
        XCTAssertTrue(S29NGroups.local(people, apart: [["1", "2"]], limit: 0.40).isEmpty, "同じ区切りに出た 2 人はまとめない")
    }

    // MARK: 声20 3 ボタンの候補の選び方

    func testGuessPicksOneAddsScoresAndSkipsMembersAndQuiet() {
        let clues = [
            S29NClue(name: "見本太郎", target: nil, reasons: ["「見本太郎さん」と呼ばれたあとに話した（1回）"], score: 3),
            S29NClue(name: "見本花子", target: "7", reasons: ["予定の参加者（1回）"], score: 2),
            S29NClue(name: "見本花子", target: "7", reasons: ["声が少し似ている"], score: 2),
            S29NClue(name: "人物40", target: "40", reasons: ["声がよく似ている"], score: 9),
            S29NClue(name: "見本次郎", target: "9", reasons: ["声がよく似ている"], score: 9),
        ]
        let g = S29NGuess.pick(clues, hinted: [], members: ["12", "40"], blocked: ["9"])
        XCTAssertEqual(g?.target, "7", "同じ人の点は足す（2+2=4 > 3）・まとまりの中の人と聞かない人は選ばない")
        XCTAssertEqual(g?.reasons.count, 2)
        XCTAssertNil(S29NGuess.pick([S29NClue(name: "見本花子", target: "7", reasons: ["声が少し似ている"], score: 2)],
                                    hinted: [], members: [], blocked: []), "手がかりが弱ければ「たぶん」は出さない")
        let hinted = S29NGuess.pick([], hinted: [(id: "7", name: "見本花子")], members: [], blocked: [])
        XCTAssertEqual(hinted?.target, "7")
        XCTAssertEqual(S29NGuess.title("見本花子さん"), "たぶん 見本花子さん")
        XCTAssertEqual(S29NGuess.title(SpeakerLabeler.selfName), "たぶん自分")
        let choices = S29NGuess.choices([person("1"), person("7", name: "見本花子", seconds: 10), person("8", name: "見本太郎", seconds: 900),
                                         person("9", name: "見本次郎", quiet: true), person(SpeakerLabeler.selfID)])
        XCTAssertEqual(choices.map(\.id), [SpeakerLabeler.selfID, "8", "7"])
        XCTAssertNil(S29NGuess.typedName("人物12"))
        XCTAssertEqual(S29NGuess.typedName(" 見本 "), "見本")
    }

    // MARK: 声22 答えの送る形

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testAnswerBodyKeepsOldShapeAndAddsS29Fields() throws {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let a = S29NAnswers.samples([SpeakerLabeler.Sample(audio: "20261126-090000.m4a", start: 1, end: 4)])
        let b = S29NAnswers.samples([SpeakerLabeler.Sample(audio: "20261125-100000.m4a", start: 2, end: 5)])
        let pair = try XCTUnwrap(S29NAnswers.pair(same: true, (id: "12", samples: a), (id: "7", samples: b)))
        let row = try json(S29NAnswers.body(kind: .merged, pairs: [pair], ids: ["12", "7"], group: "g29-1", at: at(27, 9),
                                            salt: "p:12", timeZone: tz))
        XCTAssertEqual(row["kind"] as? String, "same_person", "前の形のまま（今の家の PC も受ける）")
        XCTAssertEqual(row["id"] as? String, "g29-1", "まとまり全体の答えは家の PC のまとまりの id")
        XCTAssertEqual(row["value"] as? String, "merged")
        XCTAssertEqual(row["day"] as? String, "2026-11-27")
        XCTAssertEqual(row["s29_kind"] as? String, "merged")
        XCTAssertEqual(row["s29_group"] as? String, "g29-1")
        let pairs = try XCTUnwrap(row["s29_pairs"] as? [[String: Any]])
        XCTAssertEqual(pairs.first?["same"] as? Bool, true)
        let people = try XCTUnwrap(pairs.first?["people"] as? [[[String: Any]]])
        XCTAssertEqual(people[0].first?["audio"] as? String, "20261126-090000.m4a")
        XCTAssertEqual(people[1].first?["start"] as? Double, 2)

        let unknown = try json(S29NAnswers.body(kind: .unknown, pairs: [], ids: ["12"], group: "g29-1", at: at(27, 9),
                                                salt: "p:12", timeZone: tz))
        XCTAssertEqual(unknown["value"] as? String, "different")
        XCTAssertTrue((unknown["id"] as? String)?.hasPrefix("s29-unknown-") == true, "知らない人は「別の人の組」ではないので、まとまりの id を使わない")
        XCTAssertNil(unknown["s29_pairs"])
        let local = try json(S29NAnswers.body(kind: .named, pairs: [], ids: ["12"], group: "local-12", at: at(27, 9), salt: "x", timeZone: tz))
        XCTAssertTrue((local["id"] as? String)?.hasPrefix("s29-named-") == true, "端末の中のまとまりの id は家の PC に無い")
        XCTAssertEqual(S29NAnswerKind.split.value, "different")
        XCTAssertEqual(S29NAnswerKind.keep.value, "merged")
        // id は家の PC の決まり（英数字と _ . : - の 64 字まで）
        for kind in S29NAnswerKind.allCases {
            let r = try json(S29NAnswers.body(kind: kind, pairs: [], ids: [], group: nil, at: at(27, 9), salt: "p:123", timeZone: tz))
            XCTAssertTrue(HomeFeeds.isID(r["id"] as? String ?? ""))
        }
    }

    func testSamplesAndPairsAreCleaned() {
        XCTAssertNil(S29NAnswers.clean("../x.m4a", start: 1, end: 2))
        XCTAssertNil(S29NAnswers.clean("x.m4a", start: nil, end: 2))
        XCTAssertEqual(S29NAnswers.clean("x.m4a", start: 1, end: nil), S29NSample(audio: "x.m4a", start: 1, end: 9))
        XCTAssertEqual(S29NAnswers.clean("x.m4a", start: 1, end: 100)?.end, 31)
        let s = [S29NSample(audio: "x.m4a", start: 1, end: 2)]
        XCTAssertNil(S29NAnswers.pair(same: true, (id: "1", samples: s), (id: "2", samples: [])), "片方の見本が無ければ組にしない")
        XCTAssertNil(S29NAnswers.pair(same: true, (id: "1", samples: s), (id: "2", samples: s)))
    }

    // MARK: 声23 withNow の書き方

    func testWithNowShape() throws {
        let e = try XCTUnwrap(S29NWithNow.make(ids: ["7", "7", "8"], now: Date(timeIntervalSince1970: 1_764_200_000.6), hours: 2))
        XCTAssertEqual(e, S29NWithNow.Entry(ids: ["7", "8"], start: 1_764_200_000, end: 1_764_207_200))
        let text = try XCTUnwrap(S29NWithNow.encode(e))
        XCTAssertEqual(text, #"{"end":1764207200,"ids":["7","8"],"start":1764200000}"#)
        XCTAssertEqual(S29NWithNow.decode(text), e)
        XCTAssertEqual(S29NWithNow.decode(Data(text.utf8)), e)
        XCTAssertTrue(S29NWithNow.active(e, now: Date(timeIntervalSince1970: 1_764_203_000)))
        XCTAssertFalse(S29NWithNow.active(e, now: Date(timeIntervalSince1970: 1_764_207_200)))
        XCTAssertNil(S29NWithNow.decode(""))
        XCTAssertNil(S29NWithNow.make(ids: [], now: .now, hours: 2))
        XCTAssertEqual(S29NWithNow.key, "s29.withNow")
    }

    // MARK: 声8 通りすがり

    func testPasserbyFromTagsAndBox() throws {
        let body = #"{"available":true,"tags":[{"kind":"passerby","speaker":"人物12","ms":1},{"kind":"overlap","ms":2},{"kind":"passerby","speaker":"見本"}]}"#
        XCTAssertEqual(S29NPasserby.ids(fromTags: Data(body.utf8)), ["12"])
        XCTAssertNil(S29NPasserby.ids(fromTags: Data(#"{"available":false}"#.utf8)))
        let stats: [String: S29NStat] = ["12": stat(lines: 2, days: ["2026-11-25"], seconds: 5),
                                         "13": stat(lines: 9, days: ["2026-11-25", "2026-11-26"], seconds: 50)]
        let tags: [String: Set<String>] = ["2026-11-25": ["12", "13"]]
        XCTAssertEqual(S29NPasserby.merge(tags: tags, stats: stats, box: ["99"]), ["12", "99"],
                       "札が付いたのが声のあった日の一部だけなら通りすがりにしない")
        XCTAssertEqual(S29NPasserby.box(["1", "2"]), ["1", "2"])
        XCTAssertEqual(S29NPasserby.box(#"["3"]"#), ["3"])
        XCTAssertEqual(S29NPasserby.box(nil), [])
    }

    // MARK: 母艦の「この人物N はだれ」の答えを人に届ける

    func testReviewAnswerBecomesAssignRenameOrNothing() {
        let people = [person("5413"), person("7", name: "見本花子"), person("8", name: "見本太郎", hidden: true), person(SpeakerLabeler.selfID)]
        XCTAssertEqual(S29NReviewLink.action(value: "見本花子さん", number: "5413", people: people), .assign("7"))
        XCTAssertEqual(S29NReviewLink.action(value: "自分", number: "5413", people: people), .assign(SpeakerLabeler.selfID))
        XCTAssertEqual(S29NReviewLink.action(value: "見本三郎さん", number: "5413", people: people), .rename("見本三郎"))
        XCTAssertEqual(S29NReviewLink.action(value: "見本太郎", number: "5413", people: people), .rename("見本太郎"),
                       "記録に出さない人にはまとめない")
        XCTAssertEqual(S29NReviewLink.action(value: "分からない", number: "5413", people: people), .none)
        XCTAssertEqual(S29NReviewLink.action(value: "あとで", number: "5413", people: people), .none)
        XCTAssertEqual(S29NReviewLink.action(value: "知らない人", number: "5413", people: people), .quiet)
        XCTAssertEqual(S29NReviewLink.action(value: "見本花子", number: "9999", people: people), .none, "端末にいない声は何もしない")
        XCTAssertEqual(S29NReviewLink.action(value: "見本三郎", number: "7", people: people), .none, "名前のある人の名前は変えない")
        let voice = ReviewItem(id: "spt-5413", kind: "voice", question: "人物5413 は、だれですか", answer: "pick", group: "voice_top")
        let line = ReviewItem(id: "sl-1", kind: "speaker_line", question: "この行は人物5413？", answer: "pick")
        XCTAssertTrue(S29NReviewLink.isNameAsk(voice))
        XCTAssertFalse(S29NReviewLink.isNameAsk(line), "1 行の問いで人全体の名前は変えない")
    }

    // MARK: 名前の比べ方・quiet の形

    func testNameKeyAndQuietIsOptional() throws {
        XCTAssertEqual(S29NRules.nameKey("見本 花子さん"), "見本花子")
        XCTAssertTrue(S29NRules.sameName("見本", "見本花子"))
        XCTAssertFalse(S29NRules.sameName("見", "見本"))
        XCTAssertEqual(S29NRules.unnamedID("人物12"), "12")
        XCTAssertNil(S29NRules.unnamedID("人物"))
        // 前の形（quiet が無い）の人も読める
        let old = #"{"id":"12","voices":[],"seconds":3,"lastHeard":0,"samples":[]}"#
        let p = try JSONDecoder().decode(SpeakerLabeler.Person.self, from: Data(old.utf8))
        XCTAssertNil(p.quiet)
        var q = p
        q.quiet = true
        let back = try JSONDecoder().decode(SpeakerLabeler.Person.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(back.quiet, true)
    }
}

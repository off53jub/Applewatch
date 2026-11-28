import XCTest
@testable import LifeLog

/// s38（S38ARules.swift・S38ABook.swift・2026-11-28）: K38-1 の読む側。続1 仮の名前・続2 通りすがり・続3 声のメモ・
/// 続4 後ろの段（later_done_at）を待つ。どの鍵も省ける（無ければ今のまま）。
/// 公開のリポジトリなので、見本は「見本さん」「見本の案件 A」だけ。
@MainActor
final class S38A1Tests: XCTestCase {
    private let shared = Date(timeIntervalSince1970: 1_795_000_000)

    private func feed(_ json: String) throws -> S36AFeed {
        guard case .feed(let f) = S36ARules.reply(Data(json.utf8)) else {
            XCTFail("読めない")
            throw NSError(domain: "S38ATests", code: 1)
        }
        return f
    }

    // MARK: K38-1 読む

    func testFeedReadsNewKeys() throws {
        let f = try feed("""
        {"version":1,"generated_at":"2026-11-28T18:00:00+09:00",
         "names":[{"speaker_id":"5413","name":"見本さん","how":"presence","sources":["place","source"]},
                  {"speaker_id":700,"name":" 見本 次郎 "},
                  {"speaker_id":"人物88","name":"見本 三郎"},
                  {"speaker_id":"","name":"空"},{"name":"番号なし"},{"speaker_id":"9","name":""},5],
         "passerby":["5565","人物5600",5600,"700","abc",null],
         "voice_memos":[{"id":"vm-1","text":"見本のメモ","day":"2026-11-28","project":"見本の案件 A"},
                        {"id":2,"text":"見本の 2"},{"id":"vm-3","text":""},{"text":"id なし"}],
         "later_done_at":"2026-11-28T18:30:00+09:00"}
        """)
        XCTAssertEqual(f.names?.map(\.speakerID), ["5413", "700", "88"], "番号は文字でも数でも・「人物」は外す。名前か番号の無い行は飛ばす")
        XCTAssertEqual(f.names?[1].name, "見本 次郎", "前後の空白は外す")
        XCTAssertEqual(f.names?.first?.sources, ["place", "source"])
        XCTAssertEqual(f.passerby, ["5565", "5600", "700"], "番号だけ・重ねない・届いた順")
        XCTAssertEqual(f.voiceMemos?.map(\.id), ["vm-1", "2"], "文か id の無いメモは飛ばす")
        XCTAssertEqual(f.voiceMemos?.first?.project, "見本の案件 A")
        XCTAssertEqual(f.laterDoneAt, "2026-11-28T18:30:00+09:00")
    }

    func testFeedWithoutNewKeysIsUnchanged() throws {
        let f = try feed(#"{"version":1,"prompt":{"daily":"まとめ"}}"#)
        XCTAssertNil(f.names)
        XCTAssertNil(f.passerby)
        XCTAssertNil(f.voiceMemos)
        XCTAssertNil(f.laterDoneAt)
        XCTAssertEqual(f.prompt?.daily, "まとめ", "前の鍵は今のまま読む")
        let odd = try feed(#"{"names":"x","passerby":5,"voice_memos":{},"later_done_at":"  "}"#)
        XCTAssertEqual(odd.names, [], "形の違う鍵は空として読む（全体は落とさない）")
        XCTAssertEqual(odd.passerby, [])
        XCTAssertEqual(odd.voiceMemos, [])
        XCTAssertNil(odd.laterDoneAt, "空の時刻は無いのと同じ")
    }

    // MARK: 続1 仮の名前

    func testNameHintOnlyForUnnamedVoices() {
        let names = [S38AName(speakerID: "5413", name: "見本さん")]
        XCTAssertEqual(S38ANames.hint(number: "5413", names: names, isNamed: false), "仮: 見本さん")
        XCTAssertNil(S38ANames.hint(number: "5413", names: names, isNamed: true), "本人が名前を付けた人には出さない（本人の答えが勝つ）")
        XCTAssertNil(S38ANames.hint(number: "1", names: names, isNamed: false), "仮の名前の無い番号には出さない")
        XCTAssertNil(S38ANames.hint(number: "5413", names: nil, isNamed: false), "鍵が無ければ今のまま")
        let long = [S38AName(speakerID: "1", name: String(repeating: "見", count: 30))]
        XCTAssertEqual(S38ANames.hint(number: "1", names: long, isNamed: false)?.count, 3 + S38ANames.nameLimit + 1, "長い名前は切る")
    }

    func testLineHintKeepsTheShownName() {
        let names = [S38AName(speakerID: "12", name: "見本さん")]
        let unnamed: (String) -> Bool = { _ in false }
        XCTAssertEqual(S38ANames.lineHint(speaker: "人物12", speakerID: "12", names: names, named: unnamed), "仮: 見本さん")
        XCTAssertEqual(S38ANames.lineHint(speaker: "人物12", speakerID: nil, names: names, named: unnamed), "仮: 見本さん")
        XCTAssertNil(S38ANames.lineHint(speaker: "見本 太郎", speakerID: "12", names: names, named: unnamed),
                     "行に名前が出ているときは添えない（名前は変えない）")
        XCTAssertNil(S38ANames.lineHint(speaker: "人物12", speakerID: "12", names: names, named: { $0 == "12" }),
                     "その番号の人に名前が付いていれば添えない")
        XCTAssertNil(S38ANames.lineHint(speaker: nil, speakerID: "12", names: names, named: unnamed))
        XCTAssertEqual(S38ARules.number(" 人物7 "), "7")
        XCTAssertNil(S38ARules.number("人物"))
        XCTAssertNil(S38ARules.number("見本"))
    }

    // MARK: 続2 通りすがり

    func testPasserbyBoxesOnlyUnnamedVoices() {
        let set: Set<String> = ["5565", "700"]
        XCTAssertTrue(S38APasserby.boxed(id: "5565", isNamed: false, isSelf: false, passerby: set))
        XCTAssertFalse(S38APasserby.boxed(id: "700", isNamed: true, isSelf: false, passerby: set), "名前を付けた人は箱に入れない")
        XCTAssertFalse(S38APasserby.boxed(id: "0", isNamed: false, isSelf: true, passerby: ["0"]), "自分は入れない")
        XCTAssertFalse(S38APasserby.boxed(id: "1", isNamed: false, isSelf: false, passerby: set))
        XCTAssertFalse(S38APasserby.boxed(id: "5565", isNamed: false, isSelf: false, passerby: []), "鍵が無ければ今のまま")
        XCTAssertEqual(S38APasserby.title(3), "通りすがり（3 人）")
    }

    // MARK: 続3 声のメモ

    func testVoiceMemosAreClippedAndCapped() {
        var memos: [S38AVoiceMemo] = [S38AVoiceMemo(id: "a", text: String(repeating: "見", count: 80), day: "2026-11-28", project: "見本の案件 A"),
                                      S38AVoiceMemo(id: "a", text: "重なり")]
        for i in 0..<40 { memos.append(S38AVoiceMemo(id: "m\(i)", text: "見本 \(i)")) }
        let shown = S38AMemos.shown(memos)
        XCTAssertEqual(shown.count, S38AMemos.limit, "30 件まで")
        XCTAssertEqual(shown.first?.text.count, S38AMemos.textLimit + 1, "60 字で切って「…」")
        XCTAssertEqual(shown.filter { $0.id == "a" }.count, 1, "同じ id は 1 つ")
        XCTAssertEqual(S38AMemos.caption(shown[0]), AppFeeds.monthDay("2026-11-28") + "・見本の案件 A")
        XCTAssertNil(S38AMemos.caption(S38AVoiceMemo(id: "x", text: "見本", day: "きのう", project: " ")))
        XCTAssertEqual(S38AMemos.title(2), "声のメモ（2 件）")
        XCTAssertTrue(S38AMemos.shown(nil).isEmpty, "鍵が無ければ箱を出さない")
    }

    func testVoiceMemosNeverBecomeTasks() {
        let book = S36ABook.shared
        let before = book.feed
        defer { book.use(before, fetchedAt: .now, offered: before != nil) }
        book.use(S36AFeed(voiceMemos: [S38AVoiceMemo(id: "vm", text: "見本のメモ")]), offered: true)
        XCTAssertEqual(S38AFeed.memos.map(\.id), ["vm"])
        book.use(S36AFeed(voiceMemos: [S38AVoiceMemo(id: "vm", text: "見本のメモ")]), offered: false)
        XCTAssertTrue(S38AFeed.memos.isEmpty, "家の PC が /s36 を配っていなければ出さない")
    }

    // MARK: 続4 後ろの段を待つ

    func testLaterStepWaitsUntilNewerThanShare() {
        let started = shared.addingTimeInterval(30)
        let old = S36AFeed(laterDoneAt: "2026-01-01T00:00:00+09:00")
        XCTAssertEqual(S38ALater.step(old, sharedAt: shared, startedAt: started, now: started.addingTimeInterval(60)), .wait)
        let newer = S36AFeed(laterDoneAt: ISO8601DateFormatter().string(from: shared.addingTimeInterval(120)))
        XCTAssertEqual(S38ALater.step(newer, sharedAt: shared, startedAt: started, now: started.addingTimeInterval(180)), .caughtUp)
        let same = S36AFeed(laterDoneAt: ISO8601DateFormatter().string(from: shared))
        XCTAssertEqual(S38ALater.step(same, sharedAt: shared, startedAt: started, now: started.addingTimeInterval(60)), .wait,
                       "同じ時刻はまだ（より新しいときだけ）")
        XCTAssertEqual(S38ALater.step(old, sharedAt: shared, startedAt: started, now: started.addingTimeInterval(S38ALater.limit)), .timeUp,
                       "20 分でやめる")
        XCTAssertEqual(S38ALater.step(S36AFeed(), sharedAt: shared, startedAt: started, now: started), .noField, "欄が無くなったらやめる")
        XCTAssertEqual(S38ALater.step(S36AFeed(laterDoneAt: "読めない"), sharedAt: shared, startedAt: started, now: started), .wait)
        XCTAssertEqual(S38ALater.every, 60)
        XCTAssertEqual(S38ALater.limit, 1200)
    }

    func testLaterFollowsOnlyWhenTheFieldExists() {
        XCTAssertFalse(S38ALater.follows(nil, offered: true))
        XCTAssertFalse(S38ALater.follows(S36AFeed(), offered: true), "欄が無ければ今の動きのまま")
        XCTAssertFalse(S38ALater.follows(S36AFeed(laterDoneAt: "2026-11-28T18:00:00+09:00"), offered: false))
        XCTAssertTrue(S38ALater.follows(S36AFeed(laterDoneAt: "2026-11-28T18:00:00+09:00"), offered: true))
        XCTAssertTrue(S38ALater.caughtUp("2026-11-28T18:00:01", sharedAt: S31ARules.date("2026-11-28T18:00:00") ?? .distantFuture),
                      "時差の無い形はこの端末の時刻として読む")
    }

    func testFollowStartsOnlyWithTheField() {
        let book = S36ABook.shared
        let before = book.feed
        let later = S38ABook.shared
        defer {
            later.stop()
            book.use(before, fetchedAt: .now, offered: before != nil)
        }
        book.use(S36AFeed(), offered: true)
        later.follow(sharedAt: shared)
        XCTAssertNil(later.waitingSince, "欄が無ければ待たない")
        book.use(S36AFeed(laterDoneAt: "2026-01-01T00:00:00+09:00"), offered: true)
        later.follow(sharedAt: shared)
        XCTAssertEqual(later.waitingSince, shared, "欄があれば共有の時刻で待ち始める")
        later.follow(sharedAt: shared.addingTimeInterval(10))
        XCTAssertEqual(later.waitingSince, shared.addingTimeInterval(10), "新しい共有で待ち直す")
        later.stop()
        XCTAssertNil(later.waitingSince)
    }
}

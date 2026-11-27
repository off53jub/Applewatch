import XCTest
@testable import LifeLog

/// s36（S36ARules.swift・S36ABook.swift・2026-11-28）: K36-1 の読み・頼み方（置く文の帯・毎日の 1 語）・数の 1 行（見込みは「仮」）・
/// 止める候補（K36-3）・よく使う設定・写真の種類と枚数（K36-2・細1）・下の入口（大3）・仕事のことを聞く（K36-4）・14 日の項目を畳む。
/// 公開のリポジトリなので、見本は「見本の案件 A」「見本さん」「W-001」だけ。
@MainActor
final class S36ATests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private let full = """
    {"version":1,"generated_at":"2026-11-28T06:00:00+09:00",
     "prompt":{"setup":"見本の置く文","setup_version":"20261128-1","daily":"まとめ W-001",
               "open_refs":[{"ref":"W-001","text":"見本の案件 A を見本さんに確かめる"}, 5]},
     "cases":{"as_of":"2026-11-28","total":300,"done":182,"ng":5,"waiting":11,"left":118,"per_day":14,"eta":"2026-12-07",
              "eta_note":"見本","evidence_missing":[{"ref":"W-001","text":"見本の案件 A の写しが無い"}],
              "by_area":[{"area":"見本の区分","total":120,"done":80},{"area":"見本の区分 2","total":-3,"done":"x"}]},
     "bugs":{"as_of":"2026-11-28","open":1,"closed":3,"items":[{"ref":"W-001","text":"見本の案件 A の数","state":"open","who":"見本さん","day":null}]},
     "ledger":{"open":12,"closed_7d":4,"folded":2,"closed_by_reply_7d":1},
     "stop":{"items":[{"id":"s1","kind":"build","title":"見本の作り直し","why":"見本の画面のため","saves":"3 秒","state":"candidate"},
                      {"id":"s2","kind":"claude","title":"見本の頼み","state":"kept"},{"kind":"screen"}]},
     "nav":{"settings_top":["detailedSettings","自己点検","無い画面"]}}
    """

    private func feed(_ json: String) -> S36AFeed? {
        if case .feed(let f) = S36ARules.reply(Data(json.utf8)) { return f }
        return nil
    }

    private func fakeJPEG(_ n: Int) -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0, UInt8(n % 256), 0xFF, 0xD9]) }

    // MARK: K36-1 の読み

    func testReplyReadsFullFeedAndSkipsBadRows() throws {
        let f = try XCTUnwrap(feed(full))
        XCTAssertEqual(f.version, 1)
        XCTAssertEqual(f.prompt?.setupVersion, "20261128-1")
        XCTAssertEqual(f.prompt?.daily, "まとめ W-001")
        XCTAssertEqual(f.prompt?.openRefs.map(\.ref), ["W-001"], "読めない行は読み捨てる")
        XCTAssertEqual(f.cases?.left, 118)
        XCTAssertEqual(f.cases?.perDay, 14)
        XCTAssertEqual(f.cases?.byArea.count, 2)
        XCTAssertNil(f.cases?.byArea.last?.total, "負の数は読まない")
        XCTAssertNil(f.cases?.byArea.last?.done, "形の違う数は読まない")
        XCTAssertEqual(f.bugs?.items.first?.who, "見本さん")
        XCTAssertNil(f.bugs?.items.first?.day)
        XCTAssertEqual(f.ledger?.closedByReply7d, 1)
        XCTAssertEqual(f.stop?.items.map(\.id), ["s1", "s2"], "id の無い候補は読まない")
        XCTAssertEqual(f.nav?.settingsTop.count, 3)
    }

    func testReplyNoneAndBad() {
        XCTAssertEqual(S36ARules.reply(Data(#"{"available":false}"#.utf8)), .none)
        XCTAssertEqual(S36ARules.reply(Data("こわれた".utf8)), .bad)
        // 欄が全部無くても読める（どの欄も省ける）
        guard case .feed(let empty) = S36ARules.reply(Data("{}".utf8)) else { return XCTFail("空でも読める") }
        XCTAssertNil(empty.prompt)
        XCTAssertNil(empty.cases)
        XCTAssertNil(S36ARules.casesLine(empty.cases))
    }

    // MARK: 大2 頼み方

    func testSetupBand() {
        XCTAssertNil(S36ARules.setupBand(version: nil, copied: nil), "版が無ければ帯は出さない")
        XCTAssertEqual(S36ARules.setupBand(version: "v2", copied: nil), .first, "まだ写していない")
        XCTAssertEqual(S36ARules.setupBand(version: "v2", copied: "v1"), .changed, "前に写した版と違うときだけ置き直し")
        XCTAssertNil(S36ARules.setupBand(version: "v2", copied: "v2"))
    }

    func testDailyOnlyAfterSetupWasCopiedAndWhileFresh() throws {
        let prompt = try XCTUnwrap(feed(full)?.prompt)
        XCTAssertNil(S36ARules.daily(prompt, copiedVersion: nil, fetchedAt: now, now: now), "置く文をまだ写していなければ、今の長い頼み方のまま")
        XCTAssertEqual(S36ARules.daily(prompt, copiedVersion: "20261127-1", fetchedAt: now, now: now), "まとめ W-001",
                       "前の版でも置いてあれば 1 語を使う（帯で置き直しを出す）")
        XCTAssertNil(S36ARules.daily(prompt, copiedVersion: "v", fetchedAt: now.addingTimeInterval(-4 * 86400), now: now), "古い写しは使わない（仮 3 日）")
        XCTAssertNil(S36ARules.daily(prompt, copiedVersion: "v", fetchedAt: nil, now: now))
        var blank = prompt
        blank.daily = "  "
        XCTAssertNil(S36ARules.daily(blank, copiedVersion: "v", fetchedAt: now, now: now))
        XCTAssertEqual(S36ARules.refsLine(prompt), "開いている番号 1 件を載せています")
        XCTAssertNil(S36ARules.refsLine(S36APrompt()))
    }

    func testCopyButtonsUseDailyWhenPlaced() throws {
        let book = S36ABook.shared
        let f = try XCTUnwrap(feed(full))
        defer {
            book.use(nil, fetchedAt: nil, offered: false)
            book.setCopiedVersion(nil)
        }
        book.use(f, fetchedAt: .now, offered: true)
        book.setCopiedVersion(nil)
        XCTAssertTrue(book.hasPromptPlace)
        XCTAssertEqual(book.setupBand, .first)
        XCTAssertNil(book.dailyPrompt())
        XCTAssertNotEqual(S34ABook.shared.promptText(day: "2026-11-28"), "まとめ W-001", "置く前は今の動きのまま")
        XCTAssertEqual(book.setupCopied(), "見本の置く文")
        XCTAssertNil(book.setupBand, "写した版と同じなら帯は出さない")
        XCTAssertEqual(book.dailyPrompt(), "まとめ W-001")
        XCTAssertEqual(S34ABook.shared.promptText(day: "2026-11-28"), "まとめ W-001", "今のコピーのボタンは 1 語を写す")
        book.use(nil, fetchedAt: nil, offered: false)
        XCTAssertNil(book.dailyPrompt(), "K36-1 が無ければ今のまま")
        XCTAssertFalse(book.hasPromptPlace)
    }

    // MARK: 大2 数

    func testNumberLinesSayKari() throws {
        let f = try XCTUnwrap(feed(full))
        XCTAssertEqual(S36ARules.casesLine(f.cases), "残り 118（済 182・不可 5・待ち 11／全 300）")
        let eta = try XCTUnwrap(S36ARules.etaLine(f.cases))
        XCTAssertTrue(eta.contains("（仮）"), "見込みは「仮」と書く")
        XCTAssertTrue(eta.contains("12/7"))
        XCTAssertTrue(eta.contains("1 日 14 件"))
        var noEta = try XCTUnwrap(f.cases)
        noEta.eta = nil
        XCTAssertTrue(S36ARules.etaLine(noEta)?.hasPrefix("終わる見込み まだ出せません（仮）") ?? false)
        // left が無ければ total と done から
        let derived = S36ACases(total: 10, done: 4)
        XCTAssertEqual(S36ARules.casesLine(derived), "残り 6（済 4／全 10）")
        XCTAssertEqual(S36ARules.areaLine(S36AArea(area: "見本の区分", total: 120, done: 80)), "見本の区分: 80 / 120")
        XCTAssertEqual(S36ARules.bugsLine(f.bugs), "開いている 1・閉じた 3")
        XCTAssertEqual(S36ARules.bugsLine(S36ABugs(items: [S36ABug(ref: "W-001", text: "見本", state: "closed")])), "開いている 0")
        XCTAssertNil(S36ARules.bugsLine(S36ABugs()))
        XCTAssertEqual(S36ARules.ledgerLine(f.ledger), "開いている 12・7 日で閉じた 4（返事で 1）・奥に畳んだ 2")
        XCTAssertNil(S36ARules.ledgerLine(S36ALedger()))
    }

    func testFoldedItemsGoIntoTheOldBox() throws {
        let json = #"{"id":"w1","text":"見本の案件 A の宿題","kind":"homework","folded":true}"#
        let item = try JSONDecoder().decode(S27WItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.folded, true)
        XCTAssertEqual(S30WRules.boxed(item, restored: []), "old", "14 日動かない項目は「古い」の箱に畳む（消さない）")
        XCTAssertNil(S30WRules.boxed(item, restored: ["w1"]), "戻したものは畳まない")
        let plain = try JSONDecoder().decode(S27WItem.self, from: Data(#"{"id":"w2","text":"見本","kind":"homework"}"#.utf8))
        XCTAssertNil(plain.folded)
        XCTAssertNil(S30WRules.boxed(plain, restored: []), "印の無いものは今のまま")
    }

    func testDoneRefsHeadingIsReadApartFromThePreviousHeading() {
        let text = """
        【日付】2026-11-28
        【決まったこと】
        ・見本の案件 A は来週から試す（10:00 見本さん）［1］
        【あとで確かめること】
        ・見本さんに並びを確かめる
        【済んだ番号】
        ・W-001 済
        ・W-001 まだ（見本の理由）
        ・W-001 わからない
        """
        let parsed = WorkDigestParser.parse(text)
        XCTAssertTrue(parsed.found)
        XCTAssertEqual(parsed.sections.checks, ["見本さんに並びを確かめる"], "【済んだ番号】の行を前の見出しに混ぜない")
        XCTAssertEqual(parsed.sections.decided.count, 1)
        XCTAssertEqual(parsed.doneRefs, ["W-001 済", "W-001 まだ（見本の理由）", "W-001 わからない"])
        XCTAssertFalse(parsed.sections.homework.contains { $0.contains("W-001") }, "宿題にもならない")
        XCTAssertEqual(WorkDigestParser.header("【済んだ番号】")?.part, .doneRefs)
        // 見出しが【済んだ番号】だけでも、ほかの見出しの項目は増えない
        let only = WorkDigestParser.parse("【済んだ番号】\n・W-001 済")
        XCTAssertTrue(only.sections.lists.allSatisfy { $0.items.isEmpty })
    }

    // MARK: 大3 止める候補（K36-3）

    func testStopCandidatesAndBody() throws {
        let stop = try XCTUnwrap(feed(full)?.stop)
        XCTAssertEqual(S36ARules.candidates(stop, answered: [:]).map(\.id), ["s1"])
        XCTAssertEqual(S36ARules.settled(stop, answered: [:]).map(\.id), ["s2"])
        XCTAssertTrue(S36ARules.candidates(stop, answered: ["s1": "stop"]).isEmpty, "押したものは候補から外す")
        XCTAssertEqual(S36ARules.stateLabel(stop.items[0], answered: ["s1": "stop"]), "止めると伝えました（家の PC が次の回に止めます）")
        XCTAssertEqual(S36ARules.stateLabel(stop.items[1], answered: [:]), "残しています")
        XCTAssertEqual(S36ARules.kindLabel("claude"), "Claude の頼み")
        let body = try XCTUnwrap(S36ARules.stopBody(id: "s1", choice: "stop"))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(raw, ["id": "s1", "choice": "stop"])
        XCTAssertNotNil(S36ARules.stopBody(id: "s1", choice: "keep"))
        XCTAssertNil(S36ARules.stopBody(id: "s1", choice: "delete"), "止める・残す のほかは送らない")
        XCTAssertNil(S36ARules.stopBody(id: "", choice: "stop"))
    }

    // MARK: 大3 よく使う設定

    func testSettingsTopMatchesWhereEntries() throws {
        let nav = try XCTUnwrap(feed(full)?.nav)
        let rows = S36ARules.settingsTop(nav, in: S33AWhere.entries)
        XCTAssertEqual(rows.map(\.id), ["detailedSettings", "diagnostics"], "id か名前で当てる・当たらない名前は出さない")
        XCTAssertTrue(S36ARules.settingsTop(nil, in: S33AWhere.entries).isEmpty, "無ければ出さない")
        let many = S36ANav(settingsTop: ["diagnostics", "accuracy", "homePC", "notices", "cloudLog", "listenQuality", "diagnostics"])
        XCTAssertEqual(S36ARules.settingsTop(many, in: S33AWhere.entries).count, 5, "5 つまで（仮）・同じものは 1 回")
        XCTAssertEqual(S36ARules.settingsTop(S36ANav(settingsTop: ["settings"]), in: S33AWhere.entries).map(\.id), ["detailedSettings"])
    }

    // MARK: K36-2 写真の種類と枚数（細1）

    func testPhotoLimitAndKind() {
        XCTAssertEqual(S36APhotoRules.limit([]), 12, "無ければ今のまま 12 枚")
        XCTAssertEqual(S36APhotoRules.limit(["workphoto"]), 12)
        XCTAssertEqual(S36APhotoRules.limit(["workphoto", "workphoto30"]), 30)
        XCTAssertNil(S36APhotoRules.kindField(.cases, ["workphoto"]), "workphoto30 が無ければ kind を付けない")
        XCTAssertEqual(S36APhotoRules.kindField(.digest, ["workphoto30"]), "digest")
        XCTAssertEqual(S36APhotoKind.allCases.map(\.label), ["まとめ", "テストケースの表", "不具合の一覧"])
        XCTAssertEqual(S36APhotoKind.allCases.first, .digest, "初めは「まとめ」")
        XCTAssertEqual(S36APhotoRules.overflowLine(dropped: 2, limit: 30), "30 枚までです。31 枚目からは送っていません（2 枚）。")
        XCTAssertNil(S36APhotoRules.overflowLine(dropped: 0, limit: 30))
        XCTAssertEqual(S36APhotoRules.overflowLine(dropped: 1, limit: 12), "12 枚までです。13 枚目からは送っていません（1 枚）。")
    }

    func testBodyCarriesKindAndThirty() throws {
        let id = "11111111-2222-3333-4444-555555555555"
        let jpeg = fakeJPEG(1)
        XCTAssertNil(S35PhotoRules.body(id: id, day: "2026-11-28", index: 0, count: 13, jpeg: jpeg), "前のままなら 12 まで")
        let data = try XCTUnwrap(S35PhotoRules.body(id: id, day: "2026-11-28", index: 29, count: 30, jpeg: jpeg, kind: "cases", cap: 30))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["kind"] as? String, "cases")
        XCTAssertEqual(raw["count"] as? Int, 30)
        XCTAssertNil(S35PhotoRules.body(id: id, day: "2026-11-28", index: 0, count: 31, jpeg: jpeg, kind: "cases", cap: 31), "30 を超えない")
        let plain = try XCTUnwrap(S35PhotoRules.body(id: id, day: "2026-11-28", index: 0, count: 1, jpeg: jpeg))
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: plain) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("kind"), "kind が無ければ体に入れない（K35 のまま）")
    }

    func testJobsAndTableJob() throws {
        let many: [Data] = (0..<35).map(fakeJPEG)
        let job = S35PhotoJob(id: "11111111-2222-3333-4444-555555555555", day: "2026-11-28", photos: many, cap: 30, kind: "digest")
        XCTAssertEqual(job.count, 30)
        XCTAssertEqual(job.kind, "digest")
        XCTAssertEqual(S35PhotoJob(id: "11111111-2222-3333-4444-555555555555", day: "2026-11-28", photos: many).count, 12, "前のまま 12")
        let entry = WorkDigest.Entry(id: "11111111-2222-3333-4444-555555555555", day: "2026-11-28", text: "見本の案件 A", source: .photo)
        let jobs = S35PhotoRules.jobs(for: [entry], byID: [:], loose: many, cap: 30, kind: "digest")
        XCTAssertEqual(jobs.first?.count, 30)
        XCTAssertEqual(jobs.first?.kind, "digest")
        let id = UUID().uuidString
        let table = try XCTUnwrap(S36APhotoRules.tableJob(id: id, day: "2026-11-28", photos: many, kind: .cases, features: ["workphoto30"]))
        XCTAssertEqual(table.id, id, "まとめとは別の新しい id")
        XCTAssertEqual(table.kind, "cases")
        XCTAssertEqual(table.count, 30)
        XCTAssertNil(S36APhotoRules.tableJob(id: id, day: "2026-11-28", photos: many, kind: .digest, features: ["workphoto30"]),
                     "まとめは表の道を通らない")
        XCTAssertNil(S36APhotoRules.tableJob(id: id, day: "2026-11-28", photos: many, kind: .bugs, features: ["workphoto"]),
                     "workphoto30 が無ければ送らない")
        XCTAssertNil(S36APhotoRules.tableJob(id: "x", day: "2026-11-28", photos: many, kind: .bugs, features: ["workphoto30"]))
        XCTAssertNil(S36APhotoRules.tableJob(id: id, day: "2026-11-28", photos: [], kind: .bugs, features: ["workphoto30"]))
    }

    func testSendPutsKindIntoEveryPiece() async {
        let job = S35PhotoJob(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", day: "2026-11-28", photos: (0..<14).map(fakeJPEG), cap: 30, kind: "bugs")
        var kinds: [String] = []
        var counts: [Int] = []
        let outcome = await S35PhotoSend.run([job], features: ["workphoto30"]) { body in
            if let b = try? JSONDecoder().decode(S35PhotoBody.self, from: body) {
                kinds.append(b.kind ?? "")
                counts.append(b.count ?? 0)
            }
            return Data(#"{"ok":true,"have":1,"count":14,"run":"waiting"}"#.utf8)
        }
        XCTAssertEqual(kinds.count, 14, "13 枚目からも切らずに送る")
        XCTAssertEqual(Set(kinds), ["bugs"])
        XCTAssertEqual(Set(counts), [14])
        XCTAssertEqual(outcome.complete, [job.id])
    }

    func testRetryPlanAcceptsThirty() {
        let p = S35PhotoPending(id: "11111111-2222-3333-4444-555555555555", day: "2026-11-28", count: 30, madeOn: "2026-11-28",
                                madeAt: now.addingTimeInterval(-60), retried: false, done: [], kind: "cases")
        let plan = S35PhotoRules.retryPlan([p], today: "2026-11-28", openedAt: now)
        XCTAssertEqual(plan.send.count, 1, "30 枚の分も送り直せる")
        let resend = S35PhotoJob(id: "11111111-2222-3333-4444-555555555555", day: "2026-11-28", count: 30, pieces: [], kind: "cases")
        XCTAssertEqual(resend.cap, 30)
        XCTAssertEqual(resend.kind, "cases")
    }

    // MARK: 大3 下の入口

    func testTabsAreFourAndDeep() {
        XCTAssertEqual(S36ATabs.bar.map(\.title), ["今日", "仕事", "タスク", "人", "奥"])
        XCTAssertEqual(S36ATabs.bar.map(\.tab), [.today, .work, .tasks, .people, .deep])
        XCTAssertEqual(S36ATabs.beforeTitles, ["今日", "タスク", "仕事", "直す", "記録"], "前の 5 つ（PR の文の「前」）")
        XCTAssertEqual(Set(S36ATabs.bar.map(\.title)).count, 5, "名前は 1 つずつ違う（UI テストが名前で探す）")
        XCTAssertEqual(AppTab(rawValue: "people"), .people)
        XCTAssertEqual(AppTab(rawValue: "deep"), .deep)
        // 新しい形: 直す・記録・ふり返りは奥の中
        for tab in [AppTab.fix, .records, .lookBack] {
            XCTAssertEqual(S36ATabs.shown(tab, on: true), .deep)
        }
        for tab in [AppTab.today, .work, .tasks, .people, .deep] {
            XCTAssertEqual(S36ATabs.shown(tab, on: true), tab)
        }
        XCTAssertEqual(S36ATabs.deepPage(.fix), .fix)
        XCTAssertEqual(S36ATabs.deepPage(.records), .records)
        XCTAssertEqual(S36ATabs.deepPage(.lookBack), .records)
        XCTAssertEqual(S36ATabs.deepPage(.deep), .list)
        XCTAssertEqual(S36ATabs.item(.fix).title, "奥")
        // 奥の中で前の画面を見ているときに奥を押すと、一覧へ
        XCTAssertEqual(S36ATabs.selected(.deep, current: .fix, on: true), .deep)
        XCTAssertEqual(S36ATabs.selected(.work, current: .fix, on: true), .work)
        // 前の形（切ったとき）は S30T のまま。人は記録・奥は今日
        XCTAssertEqual(S36ATabs.shown(.people, on: false), .records)
        XCTAssertEqual(S36ATabs.shown(.deep, on: false), .today)
        XCTAssertEqual(S36ATabs.shown(.lookBack, on: false), .records)
        XCTAssertEqual(S36ATabs.shown(.fix, on: false), .fix)
    }

    func testWhereHasEveryScreenOnceAndFindsS36() {
        let ids = S33AWhere.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "目次の id は 1 つずつ")
        for e in S36AWhere.entries {
            XCTAssertTrue(ids.contains(e.id))
            XCTAssertTrue(S33AWhere.places.contains(e.place), "目次の組に入る: " + e.id)
        }
        XCTAssertEqual(S33AWhere.search("止める").first?.id, "s36Stop")
        XCTAssertTrue(S33AWhere.search("頼み方").contains { $0.id == "s36Prompt" })
        // 前の入口の画面（直す・記録・ふり返り）も目次から探せる（消していない）
        for id in ["fix", "recordsDays", "lookBack", "people"] { XCTAssertTrue(ids.contains(id), id) }
    }

    // MARK: 大4 仕事のことを聞く（K36-4）

    func testAskBodyScope() throws {
        let work = try XCTUnwrap(MothershipAsk.body("W-001 は誰待ち？", scope: "work"))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: work) as? [String: String])
        XCTAssertEqual(raw["scope"], "work")
        XCTAssertEqual(raw["question"], "W-001 は誰待ち？")
        let plain = try XCTUnwrap(MothershipAsk.body("見本", scope: nil))
        XCTAssertNil((try JSONSerialization.jsonObject(with: plain) as? [String: String])?["scope"], "省けば今のまま")
        let odd = try XCTUnwrap(MothershipAsk.body("見本", scope: "ほか"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: odd) as? [String: String])?["scope"], "決まった値のほかは付けない")
        XCTAssertEqual(S36ARules.featureAskWork, "askwork")
    }
}

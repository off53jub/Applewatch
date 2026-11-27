import XCTest
@testable import LifeLog

/// s33 のアプリ担当 S33A（S33ARules.swift・S33ABook.swift・2026-11-27）: どこ？の検索・使われた数の送る形と 1 日 1 回・
/// 30 日の畳む候補・今日の並び・問いのふた・device_ok の形・時計の版の比べ・K33-1 の読み（無い・壊れ・あり）・ramen_mark の形。
/// 見本の名前・店・数はどれも作りもの（実在の人・店・会社ではない）。
@MainActor
final class S33ATests: XCTestCase {
    private func object(_ data: Data?) -> [String: Any] {
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }

    // MARK: - 強15 どこ？

    func testWhereNamesAreUniqueAndSendable() {
        let ids = S33AWhere.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "id が重なっている")
        for e in S33AWhere.entries {
            XCTAssertTrue(S33ARules.isName(e.id), "英字の名前でない: \(e.id)")
            XCTAssertTrue(S33AWhere.places.contains(e.place), "目次に無い組: \(e.place)")
        }
    }

    func testWhereSearchByNameAndAlias() {
        XCTAssertEqual(S33AWhere.search("仕事のまとめ").first?.id, "workDigest")
        // 言い換え（体重）でも見つかる
        let weight = S33AWhere.search("体重").map(\.id)
        XCTAssertTrue(weight.contains("dataEntry"))
        XCTAssertTrue(weight.contains("trends"))
        // ひらがなでも・のばす音が無くても
        XCTAssertEqual(S33AWhere.search("らーめん").first?.id, "ramen")
        XCTAssertEqual(S33AWhere.search("らめん").first?.id, "ramen")
        // 英字は大文字小文字を問わない
        XCTAssertTrue(S33AWhere.search("PayPay").map(\.id).contains("money"))
        // 語を分けると、どの語にも合うものだけ
        XCTAssertEqual(S33AWhere.search("仕事 頼み方").map(\.id), ["workDigest"])
        // 名前の頭に合うものが先
        let voice = S33AWhere.search("声の名前").map(\.id)
        XCTAssertEqual(voice.first, "naming")
    }

    func testWhereSearchEmptyAndUnknown() {
        XCTAssertTrue(S33AWhere.search("").isEmpty)
        XCTAssertTrue(S33AWhere.search("   ").isEmpty)
        XCTAssertTrue(S33AWhere.search("見本のありえない言葉").isEmpty)
    }

    func testWhereTocKeepsPlaceOrder() {
        let toc = S33AWhere.toc()
        XCTAssertEqual(toc.map(\.place), S33AWhere.places.filter { p in S33AWhere.entries.contains { $0.place == p } })
        XCTAssertEqual(toc.reduce(0) { $0 + $1.entries.count }, S33AWhere.entries.count)
    }

    // MARK: - 強5 feature_seen

    func testSeenCountsShape() {
        let tally: [String: Int] = [
            "screen.today": 5, "screen.goodThings": 1, "feat.app-good": 2, "s33a.card.promises": 3,
            "screen.日本語": 4, "screen.zero": 0, "s20.review.answered": 9, "screen.": 1,
        ]
        let counts = S33ARules.seenCounts(tally)
        XCTAssertEqual(counts, ["today": 5, "goodThings": 1, "feat.app-good": 2, "card.promises": 3])
        for key in counts.keys { XCTAssertTrue(S33ARules.isName(key)) }
    }

    func testSeenCountsCappedAt200() {
        var tally: [String: Int] = [:]
        for i in 0..<250 { tally["screen.s\(i)"] = i + 1 }
        let counts = S33ARules.seenCounts(tally)
        XCTAssertEqual(counts.count, 200)
        XCTAssertNotNil(counts["s249"], "数の多いものを残す")
        XCTAssertNil(counts["s0"])
    }

    func testSeenBody() {
        let o = object(S33ARules.seenBody(day: "2026-11-26", tally: ["screen.today": 3]))
        XCTAssertEqual(o["kind"] as? String, "feature_seen")
        XCTAssertEqual(o["day"] as? String, "2026-11-26")
        XCTAssertEqual((o["counts"] as? [String: Int]) ?? [:], ["today": 3])
        XCTAssertEqual(o.count, 3, "中身は送らない（kind・day・counts だけ）")
        XCTAssertNil(S33ARules.seenBody(day: "2026-11-26", tally: [:]), "数の無い日は送らない")
        XCTAssertNil(S33ARules.seenBody(day: "11/26", tally: ["screen.today": 1]))
    }

    func testSeenOncePerDay() {
        // 初めては昨日まで 7 日
        let first = S33ARules.seenDaysToSend(lastSent: nil, today: "2026-11-27")
        XCTAssertEqual(first.first, "2026-11-20")
        XCTAssertEqual(first.last, "2026-11-26")
        XCTAssertEqual(first.count, 7)
        // 昨日まで送ってあれば、今日はもう送らない（今日の分は明日）
        XCTAssertTrue(S33ARules.seenDaysToSend(lastSent: "2026-11-26", today: "2026-11-27").isEmpty)
        // 日をまたいだら 1 日分
        XCTAssertEqual(S33ARules.seenDaysToSend(lastSent: "2026-11-26", today: "2026-11-28"), ["2026-11-27"])
        // 月をまたいでも
        XCTAssertEqual(S33ARules.seenDaysToSend(lastSent: "2026-11-29", today: "2026-12-01"), ["2026-11-30"])
    }

    // MARK: - 強5 30 日の畳む候補・強16 今日の並び

    func testFoldCandidatesNeed30Days() {
        XCTAssertTrue(S33AFold.cardCandidates(uses: [:], hidden: [], countedDays: 29).isEmpty)
        XCTAssertTrue(S33AFold.cardCandidates(uses: [:], hidden: [], countedDays: nil).isEmpty)
        let list = S33AFold.cardCandidates(uses: [.promises: 2], hidden: [.draft], countedDays: 30)
        XCTAssertFalse(list.contains(.promises), "使われたものは入れない")
        XCTAssertFalse(list.contains(.draft), "畳んだものは入れない")
        XCTAssertFalse(list.contains(.hero), "動かさないカードは入れない")
        XCTAssertFalse(list.contains(.record))
        XCTAssertTrue(list.contains(.replies))
    }

    func testOrderPromotesMostUsedThree() {
        let base = S24Today.layout(fold: true, part: .day)
        let r = S33AOrder.apply(top: base.top, more: base.more, uses: [.replies: 9, .promises: 5, .checkups: 5, .draft: 1],
                                pinned: [], hidden: [], countedDays: 3)
        XCTAssertEqual(Array(r.top.prefix(4)), [.hero, .answer, .ask, .alerts], "大事な 3 枚と気をつけることは先頭のまま")
        // 数の多い順・同じなら元の順（promises が checkups より先）
        XCTAssertEqual(Array(r.top.dropFirst(4)), [.replies, .promises, .checkups])
        XCTAssertFalse(r.more.contains(.replies))
        XCTAssertTrue(r.more.contains(.draft), "4 つ目は上に出さない")
        XCTAssertEqual(Set(r.top + r.more), Set(base.top + base.more), "カードは減らない")
    }

    func testOrderPinnedFirstThenUsed() {
        let base = S24Today.layout(fold: true, part: .day)
        let r = S33AOrder.apply(top: base.top, more: base.more, uses: [.replies: 9, .promises: 5],
                                pinned: [.draft, .hero], hidden: [], countedDays: 3)
        XCTAssertEqual(Array(r.top.dropFirst(4)), [.draft, .replies, .promises], "本人の並びが先・合わせて 3 つ")
    }

    func testOrderHidesFoldedAndLowersUnused() {
        let base = S24Today.layout(fold: false, part: .day)
        XCTAssertTrue(base.top.contains(.s22))
        let r = S33AOrder.apply(top: base.top, more: base.more, uses: [.holiday: 1], pinned: [], hidden: [.promises, .hero],
                                countedDays: 30)
        XCTAssertFalse((r.top + r.more).contains(.promises), "畳んだカードは出さない")
        XCTAssertTrue(r.top.contains(.hero), "動かさないカードは畳めない")
        XCTAssertFalse(r.top.contains(.s22), "30 日使われないカードは「ほか」へ")
        XCTAssertTrue(r.more.contains(.s22))
        XCTAssertTrue(r.top.contains(.holiday))
        // 数え始めて 30 日たつまでは下ろさない
        let early = S33AOrder.apply(top: base.top, more: base.more, uses: [:], pinned: [], hidden: [], countedDays: 29)
        XCTAssertEqual(early.top, base.top)
    }

    func testCardUsesIncludeOldCounts() {
        let uses = S33AOrder.uses(["s33a.card.replies": 2, "mood.answered": 3, "s33a.card.nightMood": 1, "other": 9])
        XCTAssertEqual(uses[.replies], 2)
        XCTAssertEqual(uses[.nightMood], 4)
        XCTAssertNil(uses[.draft])
    }

    // MARK: - 強6 問いのふた

    func testCapSharesAcrossKinds() {
        let counts: [S33ACap.Kind: Int] = [.review: 47, .work: 30, .doubt: 70, .word: 300]
        let a = S33ACap.allot(counts, total: 30, wordCap: 20)
        XCTAssertEqual(a[.review], 8)
        XCTAssertEqual(a[.work], 8)
        XCTAssertEqual(a[.doubt], 7)
        XCTAssertEqual(a[.word], 7)
        XCTAssertEqual(S33ACap.slept(counts, allotted: a), 447 - 30)
        XCTAssertEqual(S33ACap.sleptLine(counts, allotted: a)?.hasPrefix("寝かせた 417 件"), true)
    }

    func testCapWordsLimitAndSmallPiles() {
        XCTAssertEqual(S33ACap.allot([.word: 300], total: 30, wordCap: 20)[.word], 20, "言葉の候補は 20 語まで")
        let small = S33ACap.allot([.review: 3, .doubt: 2], total: 30, wordCap: 20)
        XCTAssertEqual(small[.review], 3)
        XCTAssertEqual(small[.doubt], 2)
        XCTAssertNil(S33ACap.sleptLine([.review: 3, .doubt: 2], allotted: small), "あふれなければ出さない")
        // 1 種類だけ多くても、ほかが 0 にならない
        let one = S33ACap.allot([.review: 100, .work: 1], total: 30, wordCap: 20)
        XCTAssertEqual(one[.work], 1)
        XCTAssertEqual(one[.review], 29)
    }

    // MARK: - 強8 device_ok

    func testDeviceBodyShape() {
        let bodies = S33ARules.deviceBodies(build: "462", screens: ["today", "s33aWhere", "today", "日本語", ""])
        XCTAssertEqual(bodies.count, 1)
        let o = object(bodies.first)
        XCTAssertEqual(o["kind"] as? String, "device_ok")
        XCTAssertEqual(o["build"] as? String, "462")
        XCTAssertEqual(o["screens"] as? [String], ["s33aWhere", "today"])
        XCTAssertEqual(o["crash"] as? Bool, false)
        XCTAssertTrue(S33ARules.deviceBodies(build: "4 6 2", screens: ["today"]).isEmpty, "版の形が違えば送らない")
        XCTAssertTrue(S33ARules.deviceBodies(build: "462", screens: []).isEmpty)
        let many = S33ARules.deviceBodies(build: "1.2", screens: (0..<150).map { "s\($0)" })
        XCTAssertEqual(many.count, 2, "100 個ずつに分ける")
        XCTAssertEqual((object(many[0])["screens"] as? [String])?.count, 100)
    }

    func testDeviceOnlyClosedScreensOncePerBuild() {
        var s = S33ADevice.State(build: "462")
        s = S33ADevice.opening(s, "today")
        s = S33ADevice.opening(s, "settings")
        s = S33ADevice.closing(s, "today")
        // 開いたままの画面（落ちた・アプリを閉じた）は入れない
        XCTAssertEqual(S33ADevice.due(s, today: "2026-11-27"), ["today"])
        s.sent = ["today"]
        s.ok = []
        s.sentDay = "2026-11-27"
        s = S33ADevice.opening(s, "today")
        s = S33ADevice.closing(s, "today")
        XCTAssertTrue(s.ok.isEmpty, "この版で送った画面は 2 回送らない")
        s = S33ADevice.opening(s, "money")
        s = S33ADevice.closing(s, "money")
        XCTAssertTrue(S33ADevice.due(s, today: "2026-11-27").isEmpty, "1 日 1 回")
        XCTAssertEqual(S33ADevice.due(s, today: "2026-11-28"), ["money"])
        // 開いていない画面を閉じても何もしない
        XCTAssertEqual(S33ADevice.closing(s, "never"), s)
    }

    // MARK: - 強27 時計の版

    func testWatchCompare() {
        XCTAssertEqual(S33AWatch.compare(phone: 462, watch: "462"), .same)
        XCTAssertEqual(S33AWatch.compare(phone: 462, watch: "386"), .watchOlder)
        XCTAssertEqual(S33AWatch.compare(phone: 386, watch: "462"), .phoneOlder)
        XCTAssertEqual(S33AWatch.compare(phone: 462, watch: nil), .unknown)
        XCTAssertEqual(S33AWatch.compare(phone: 462, watch: "abc"), .unknown)
        XCTAssertNil(S33AWatch.line(.same))
        XCTAssertEqual(S33AWatch.line(.watchOlder), "時計のアプリが古い（iPhone の Watch アプリから更新）")
        XCTAssertFalse(S33AWatch.steps.isEmpty)
    }

    // MARK: - K33-1 の読み

    func testReplyNoneAndBroken() {
        XCTAssertEqual(S33ARules.reply(Data(#"{"available":false}"#.utf8)), .none)
        XCTAssertEqual(S33ARules.reply(Data("not json".utf8)), .bad)
        XCTAssertEqual(S33ARules.reply(Data("[1,2]".utf8)), .bad)
        // 鍵が 1 つも無くても読める（何も出さない）
        guard case .feed(let empty) = S33ARules.reply(Data("{}".utf8)) else { return XCTFail("空の写しも読む") }
        XCTAssertTrue(empty.stopped.isEmpty)
        XCTAssertFalse(empty.hasDeep)
        XCTAssertFalse(empty.hasLife(month: 12))
    }

    func testReplyReadsAllKeys() {
        let json = """
        {"stopped":[{"source":"見本の入口","last_ok":"2026-11-08","missing":"1 日 1 件","why":"見本"}],
         "waiting":[{"id":"s33w-1","title":"見本のログイン","how":"見本の手順","since":"2026-11-26","kind":"login"},{"id":"bad id!","title":"x"}],
         "tasks":{"total":"87","stop_candidates":[{"name":"見本の見張り","cpu_s":12.5}]},
         "effects":[{"bundle":"見本","metric":"割合","now":31,"prev":"36"}],
         "bets":[{"name":"見本の AI","month":{"stake":1000,"payout":800,"runs":3},"alive":false}],
         "disk":{"c_free_gb":85,"c_free_pct":9.1,"growth":[{"what":"見本","gb":2}]},
         "small_talk":[{"person_id":"wm-1","lines":["一","二","三","四"]},{"person_id":"wm-2","lines":[]}],
         "speaking":{"week":"2026-11-23","meetings":[{"title":"見本の定例","my_share":0.4,"overlaps":2,"long_runs":[{"at":"10:00"},{"at":"10:30"}]}]},
         "review_rules":[{"type":"数の根拠","count":4,"check":"出どころ"}],
         "side_hours":{"month":"2026-11","days":[{"day":"2026-11-25","minutes":90,"overlap_work":true},{"day":"2026-11-26","minutes":30,"overlap_work":0}]},
         "expenses":[{"day":"2026-11-24","shop":"見本のサーバー","amount":"1280"}],
         "ramen":{"year":2026,"bowls":13,"yardstick":200,"coverage":0.065,"recent":[{"day":"2026-11-23","shop":"見本の麺屋"}]},
         "car":[{"day":"2026-11-22","from":"見本の駅","to":"見本の県","hours":9,"yen":8800}],
         "year":{"year":2026,"sections":[{"title":"見本","lines":["一行"]}]},
         "wishes":[{"text":"見本の欲しい物","day":"2026-11-25","said":"ひとりごと"}],
         "promises_kept":{"kept":12,"closed":25},
         "ask_check":{"week":"2026-11-23","score":16,"total":20}}
        """
        guard case .feed(let f) = S33ARules.reply(Data(json.utf8)) else { return XCTFail("読めない") }
        XCTAssertEqual(f.stopped.first?.source, "見本の入口")
        XCTAssertEqual(f.waiting.map(\.id), ["s33w-1"], "形の違う id は外す")
        XCTAssertEqual(f.tasks?.total, 87, "文字の数も読む")
        XCTAssertEqual(f.tasks?.stopCandidates.first?.cpuSeconds, 12.5)
        XCTAssertEqual(f.effects.first?.prev, 36)
        XCTAssertEqual(f.bets.first?.runs, 3)
        XCTAssertEqual(f.bets.first?.alive, false)
        XCTAssertEqual(f.disk?.freePct, 9.1)
        XCTAssertEqual(f.smallTalk.count, 1, "行の無い人は外す")
        XCTAssertEqual(f.smallTalk.first?.lines.count, 3, "3 行まで")
        XCTAssertEqual(f.speaking?.meetings.first?.longRuns, 2, "並びならその数")
        XCTAssertEqual(f.reviewRules.first?.count, 4)
        XCTAssertEqual(f.sideHours?.totalMinutes, 120)
        XCTAssertEqual(f.sideHours?.overlapDays, 1)
        XCTAssertEqual(f.expenses.first?.amount, 1280)
        XCTAssertEqual(f.ramen?.bowls, 13)
        XCTAssertEqual(f.car.first?.yen, 8800)
        XCTAssertEqual(f.year?.sections.count, 1)
        XCTAssertEqual(f.wishes.first?.said, "ひとりごと")
        XCTAssertEqual(f.promisesKept?.a, 12)
        XCTAssertEqual(f.askCheck?.b, 20)
        XCTAssertEqual(f.askCheckWeek, "2026-11-23")
        XCTAssertTrue(f.hasDeep)
        XCTAssertTrue(f.hasLife(month: 11))
    }

    func testReplyBrokenKeyKeepsOthers() {
        let json = """
        {"tasks":"壊れ","disk":[1],"car":[{"day":1},{"day":"2026-11-20","yen":"x"}],"ramen":{"bowls":"13"},
         "stopped":"x","year":{"sections":[{"title":"見本","lines":["一",2]}]}}
        """
        guard case .feed(let f) = S33ARules.reply(Data(json.utf8)) else { return XCTFail("1 つの鍵が壊れていても読む") }
        XCTAssertNil(f.tasks)
        XCTAssertNil(f.disk)
        XCTAssertTrue(f.stopped.isEmpty)
        XCTAssertEqual(f.car.map(\.day), ["2026-11-20"], "読めない行は飛ばす")
        XCTAssertNil(f.car.first?.yen)
        XCTAssertEqual(f.ramen?.bowls, 13)
        XCTAssertEqual(f.year?.sections.first?.lines, ["一"])
    }

    func testYearOnlyInDecember() {
        guard case .feed(let f) = S33ARules.reply(Data(#"{"year":{"year":2026,"sections":[{"title":"見本","lines":["一"]}]}}"#.utf8)) else {
            return XCTFail("読めない")
        }
        XCTAssertFalse(f.hasLife(month: 11), "年のまとめは 12 月だけ")
        XCTAssertTrue(f.hasLife(month: 12))
    }

    func testLines() {
        XCTAssertNil(S33ARules.stoppedLine([]))
        XCTAssertEqual(S33ARules.stoppedLine([S33AStopped(source: "A"), S33AStopped(source: "B"), S33AStopped(source: "C")]),
                       "止まっているもの: A・B ほか 1")
        let r = S33ARamen(year: 2026, bowls: 13, yardstick: 200, coverage: 0.07)
        XCTAssertEqual(S33ARules.coveragePercent(r), 7)
        XCTAssertEqual(S33ARules.coveragePercent(S33ARamen(bowls: 50, yardstick: 200)), 25)
        XCTAssertEqual(S33ARules.coveragePercent(S33ARamen(coverage: 12)), 12, "1 より大きければ %")
        XCTAssertEqual(S33ARules.ramenLine(r, marks: 2), "今年 13 杯・目安 200 杯の7%（拾えている割合）・ここで押した印 2")
        XCTAssertNil(S33ARules.ramenLine(nil, marks: 0))
        XCTAssertEqual(S33ARules.minutesText(200), "3 時間 20 分")
        XCTAssertEqual(S33ARules.diffText(now: 31, prev: 36), "前より −5")
        XCTAssertEqual(S33ARules.dayText("2026-11-27T10:00:00+09:00"), "11/27")
    }

    // MARK: - 強22 ramen_mark

    func testRamenBodyShape() {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 27; c.hour = 12; c.minute = 40
        let tz = TimeZone(identifier: "Asia/Tokyo") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let at = cal.date(from: c) ?? .now
        let o = object(S33ARules.ramenBody(at: at, place: "見本の麺屋", lat: 35.6895123456, lon: 139.6917, timeZone: tz))
        XCTAssertEqual(o["kind"] as? String, "ramen_mark")
        XCTAssertEqual(o["at"] as? String, "2026-11-27T12:40:00+09:00", "押した時刻をそのまま")
        XCTAssertEqual(o["place"] as? String, "見本の麺屋")
        XCTAssertEqual(o["lat"] as? Double, 35.68951)
        XCTAssertEqual(o["lon"] as? Double, 139.6917)
        XCTAssertEqual(Set(o.keys), ["kind", "at", "place", "lat", "lon"])
        // 取れなければ null（鍵は残す）
        let none = object(S33ARules.ramenBody(at: at, place: "  ", lat: nil, lon: nil, timeZone: tz))
        XCTAssertTrue(none["place"] is NSNull)
        XCTAssertTrue(none["lat"] is NSNull)
        XCTAssertTrue(none["lon"] is NSNull)
        // 片方だけ・範囲の外は送らない
        let bad = object(S33ARules.ramenBody(at: at, place: nil, lat: 91, lon: 10, timeZone: tz))
        XCTAssertTrue(bad["lat"] is NSNull)
        let long = object(S33ARules.ramenBody(at: at, place: String(repeating: "見", count: 100), lat: nil, lon: nil, timeZone: tz))
        XCTAssertEqual((long["place"] as? String)?.count, 80)
    }

    func testNameRules() {
        XCTAssertTrue(S33ARules.isName("work.tab"))
        XCTAssertTrue(S33ARules.isName("settings.where:a-b_c d"))
        XCTAssertFalse(S33ARules.isName("日本語"))
        XCTAssertFalse(S33ARules.isName(String(repeating: "a", count: 65)))
        XCTAssertTrue(S33ARules.isBuild("462"))
        XCTAssertTrue(S33ARules.isBuild("1.2.3"))
        XCTAssertFalse(S33ARules.isBuild("462-a"))
        XCTAssertFalse(S33ARules.isBuild(String(repeating: "1", count: 21)))
    }
}

import XCTest
@testable import LifeLog

/// s37（S37ARules.swift・2026-11-28）: K37-1 操作待ちの「あとでいいもの」・K37-2 確かめの問いの 1 日の数・
/// K37-3 おすすめどおり止める（ボタンの出る出ない・確かめの文・結果の 1 行）・K37-4 仕事のタスク・約束の知らせの見分け。
/// 公開のリポジトリなので、見本は「見本さん」「見本の案件 A」だけ。
@MainActor
final class S37ATests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    // MARK: K37-1 操作待ち

    func testWaitingReadsGroupAndSplitsLater() throws {
        let json = """
        {"version":1,"generated_at":"2026-11-28T08:00:00+09:00","items":[
          {"id":"w-now","title":"見本の許可","steps":["開く"],"group":"now"},
          {"id":"w-later","title":"見本の好みの設定","group":"later"},
          {"id":"w-none","title":"見本の入れ直し"},
          {"id":"w-odd","title":"見本の登録","group":" LATER "},
          {"id":"w-done","title":"見本の済んだもの","group":"later","done":true},
          {"id":"w-bad","title":"見本の変な group","group":5}
        ]}
        """
        let items = try XCTUnwrap(S26UFeeds.waiting(Data(json.utf8)))
        XCTAssertEqual(items.map(\.id), ["w-now", "w-later", "w-none", "w-odd", "w-done"], "group が読めない行は落とす（ほかは読む）")
        XCTAssertEqual(items.first?.group, "now")
        XCTAssertNil(items[2].group, "group は省ける")
        let order = S26UFeeds.waitingOrder(items)
        let split = S37AWaiting.split(order.open)
        XCTAssertEqual(split.now.map(\.id), ["w-now", "w-none"], "group が無いものは今のまま（今要るもの）")
        XCTAssertEqual(split.later.map(\.id), ["w-later", "w-odd"], "later は畳んだ箱へ・消さない")
        XCTAssertEqual(order.done.map(\.id), ["w-done"], "済んだものは今までどおり")
    }

    func testWaitingWithoutGroupIsUnchanged() {
        let items = [S26UWaitingItem(id: "a", title: "見本 1"), S26UWaitingItem(id: "b", title: "見本 2")]
        let split = S37AWaiting.split(items)
        XCTAssertEqual(split.now.map(\.id), ["a", "b"])
        XCTAssertTrue(split.later.isEmpty)
        XCTAssertFalse(S37AWaiting.isLater(nil))
        XCTAssertFalse(S37AWaiting.isLater("now"))
        XCTAssertTrue(S37AWaiting.isLater("later"))
    }

    // MARK: K37-2 確かめの問いの 1 日の数

    func testReviewDailyMaxIsReadAndBadValueIgnored() throws {
        let good = """
        {"version":1,"daily_max":1,"items":[{"id":"q1","kind":"name","question":"見本さんですか","answer":"yesno"}]}
        """
        let feed = try JSONDecoder().decode(ReviewQueueFeed.self, from: Data(good.utf8))
        XCTAssertEqual(S37AReview.dailyMax(feed), 1)
        XCTAssertEqual(feed.items?.count, 1)

        let none = try JSONDecoder().decode(ReviewQueueFeed.self, from: Data(#"{"items":[]}"#.utf8))
        XCTAssertNil(S37AReview.dailyMax(none), "無ければ今の数")

        let bad = try JSONDecoder().decode(ReviewQueueFeed.self,
                                           from: Data(#"{"daily_max":"x","items":[{"id":"q1","kind":"name","question":"見本","answer":"yesno"}]}"#.utf8))
        XCTAssertNil(S37AReview.dailyMax(bad), "読めない daily_max は無いのと同じ")
        XCTAssertEqual(bad.items?.count, 1, "daily_max が変でも列は読む")

        XCTAssertNil(S37AReview.dailyMax(ReviewQueueFeed(daily_max: -2)), "負の数は無いのと同じ")
        XCTAssertEqual(S37AReview.dailyMax(ReviewQueueFeed(daily_max: 0)), 0)
    }

    func testReviewLimitKeepsMothershipOrder() {
        let items: [ReviewItem] = [
            ReviewItem(id: "a", kind: "name", question: "見本 1", answer: "yesno", impact: 1),
            ReviewItem(id: "b", kind: "voice_pair", question: "見本 2", answer: "yesno", impact: 9),
            ReviewItem(id: "c", kind: "place", question: "見本 3", answer: "yesno", impact: 5),
            ReviewItem(id: "d", kind: "place", question: "見本 4", answer: "yesno", expires: "2000-01-01"),
        ]
        let ordered = S37AReview.mothershipOrder(items, samePersonAsk: false, today: "2026-11-28")
        XCTAssertEqual(ordered.map(\.id), ["a", "c"], "並べ替えない（impact が大きくても前に出さない）・同じ人か・期限切れは今までどおり落とす")
        XCTAssertEqual(S37AReview.limited(ordered, dailyMax: 1, used: 0).map(\.id), ["a"], "1 日 daily_max 問まで")
        XCTAssertTrue(S37AReview.limited(ordered, dailyMax: 1, used: 1).isEmpty, "今日もう答えた分は引く")
        XCTAssertEqual(S37AReview.limited(ordered, dailyMax: 5, used: 0).map(\.id), ["a", "c"], "上限より少なければ全部")
        XCTAssertEqual(S37AReview.limited(ordered, dailyMax: nil, used: 3).map(\.id), ["a", "c"], "daily_max が無ければ今のまま")
        XCTAssertTrue(S37AReview.limited(ordered, dailyMax: 0, used: 0).isEmpty)
    }

    func testReviewUsedTodayCountsAnsweredAndLaterOnce() {
        let answered = ["a": "2026-11-28", "b": "2026-11-27", "c": "2026-11-28"]
        let later = ["c": "2026-11-28", "d": "2026-11-28", "e": "2026-11-26"]
        XCTAssertEqual(S37AReview.usedToday(answered: answered, later: later, today: "2026-11-28"), 3, "a・c・d（同じ問いは 1 回）")
        XCTAssertEqual(S37AReview.usedToday(answered: [:], later: [:], today: "2026-11-28"), 0)
    }

    // MARK: K37-3 おすすめどおり止める

    private func stop(_ json: String) -> S36AStop? {
        if case .feed(let f) = S36ARules.reply(Data(json.utf8)) { return f.stop }
        return nil
    }

    func testStopReadsRecommendAndShowsBulkButton() throws {
        let json = """
        {"version":1,"stop":{"items":[
          {"id":"s1","kind":"build","title":"見本の作り直し","state":"candidate","recommend":true},
          {"id":"s2","kind":"claude","title":"見本の頼み","state":"candidate","recommend":false},
          {"id":"s3","kind":"screen","title":"見本の画面","state":"candidate","recommend":true},
          {"id":"s4","kind":"screen","title":"見本の止めたもの","state":"stopped","recommend":true},
          {"id":"s5","title":"見本の変な印","state":"candidate","recommend":"yes"}
        ]}}
        """
        let feed = try XCTUnwrap(stop(json))
        XCTAssertEqual(feed.items.count, 5, "recommend が読めなくても行は読む")
        XCTAssertNil(feed.items[4].recommend)
        let candidates = S36ARules.candidates(feed, answered: [:])
        XCTAssertTrue(S37AStop.showsBulk(candidates))
        XCTAssertEqual(S37AStop.recommended(candidates).map(\.id), ["s1", "s3"], "候補のうち true のものだけ・止めたものは入らない")
        XCTAssertEqual(S37AStop.recommended(S36ARules.candidates(feed, answered: ["s1": "stop"])).map(\.id), ["s3"],
                       "もう押したものは入らない")
    }

    func testStopWithoutRecommendHidesButton() throws {
        let json = """
        {"version":1,"stop":{"items":[{"id":"s1","title":"見本の作り直し","state":"candidate"},
                                      {"id":"s2","title":"見本の頼み","state":"candidate"}]}}
        """
        let candidates = S36ARules.candidates(try XCTUnwrap(stop(json)), answered: [:])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertFalse(S37AStop.showsBulk(candidates), "recommend の欄が無いときは出さない")
        let allFalse = [S36AStopItem(id: "x", title: "見本", recommend: false)]
        XCTAssertFalse(S37AStop.showsBulk(allFalse), "true が 1 つも無ければ出さない")
        XCTAssertFalse(S37AStop.showsBulk([]))
    }

    func testStopConfirmAndResultText() {
        let items = (1...17).map { S36AStopItem(id: "s\($0)", title: "見本 \($0)", recommend: true) }
        XCTAssertEqual(S37AStop.confirmTitle(items), "おすすめの 17 件を止めますか？")
        let message = S37AStop.confirmMessage(items)
        XCTAssertTrue(message.contains("・見本 1\n"))
        XCTAssertTrue(message.contains("・見本 15"))
        XCTAssertFalse(message.contains("・見本 16"), "並べるのは 15 件まで")
        XCTAssertTrue(message.contains("ほか 2 件"))
        XCTAssertFalse(S37AStop.confirmMessage(Array(items.prefix(2))).contains("ほか"))
        XCTAssertEqual(S37AStop.resultNote(sent: 3, failed: 0), "おすすめの 3 件を止めると伝えました。")
        XCTAssertEqual(S37AStop.resultNote(sent: 2, failed: 1), "止めると伝えた 2 件・伝えられなかった 1 件。伝えられなかったものは候補に残っています。")
        XCTAssertTrue(S37AStop.resultNote(sent: 0, failed: 4).hasPrefix("4 件とも"))
    }

    // MARK: K37-4 仕事のタスク・約束の知らせ

    private func item(_ id: String, source: TaskBook.Source = .conversation, work: Bool?, quote: String? = nil) -> TaskBook.Item {
        TaskBook.Item(id: id, what: "見本のこと " + id, said: now, quote: quote, source: source, state: .candidate, work: work)
    }

    func testWorkTasksAreNotNotifiedUnlessSettingOn() {
        let workTalk = item("a", work: true)
        let life = item("b", work: false)
        let old = item("c", source: .line, work: nil)
        let ledger = item("d", source: .summary, work: nil, quote: "仕事のまとめ（2026-11-28）の宿題: 見本の案件 A")
        let minutes = item("e", source: .minutes, work: true)
        XCTAssertTrue(S37AWorkNotice.isWork(workTalk), "職場の会話の印")
        XCTAssertTrue(S37AWorkNotice.isWork(ledger), "仕事の台帳（仕事のまとめ）の宿題")
        XCTAssertTrue(S37AWorkNotice.isWork(minutes))
        XCTAssertFalse(S37AWorkNotice.isWork(life))
        XCTAssertFalse(S37AWorkNotice.isWork(old), "印の無いもの（LINE など）は止めない")
        let all = [workTalk, life, old, ledger, minutes]
        XCTAssertEqual(S37AWorkNotice.notifiable(all, workOn: false).map(\.id), ["b", "c"])
        XCTAssertEqual(S37AWorkNotice.notifiable(all, workOn: true).map(\.id), ["a", "b", "c", "d", "e"], "設定でオンに戻せる")
    }

    func testWorkNoticeSettingIsOffAtFirst() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: S37AWorkNotice.key)
        defer { if let saved { d.set(saved, forKey: S37AWorkNotice.key) } else { d.removeObject(forKey: S37AWorkNotice.key) } }
        d.removeObject(forKey: S37AWorkNotice.key)
        XCTAssertFalse(S37AWorkNotice.isOn, "初めはオフ")
        d.set(true, forKey: S37AWorkNotice.key)
        XCTAssertTrue(S37AWorkNotice.isOn)
    }

    func testWorkPromiseNoticeIsSilenced() {
        let items = [PromiseItem(id: "p1", day: "2026-11-28", kind: "asked", who: "見本さん", what: "見本の案件 A", work: true),
                     PromiseItem(id: "p2", day: "2026-11-28", kind: "promised", who: "見本さん", what: "見本の約束", work: false),
                     PromiseItem(id: "p3", day: "2026-11-28", kind: "asked", who: "", what: "見本の頼み", work: nil)]
        S37AWorkNotice.remember(items)
        let known = S37AWorkNotice.snapshot()
        XCTAssertEqual(known.known, ["p1", "p2", "p3"])
        XCTAssertEqual(known.work, ["p1"])
        XCTAssertTrue(S37AWorkNotice.silencesPromise(ids: ["p1"], workIDs: known.work, knownIDs: known.known, workOn: false),
                      "仕事の約束だけの知らせは出さない")
        XCTAssertFalse(S37AWorkNotice.silencesPromise(ids: ["p1"], workIDs: known.work, knownIDs: known.known, workOn: true),
                       "設定がオンなら出す")
        XCTAssertFalse(S37AWorkNotice.silencesPromise(ids: ["p1", "p2"], workIDs: known.work, knownIDs: known.known, workOn: false),
                       "仕事以外が混ざれば出す")
        XCTAssertFalse(S37AWorkNotice.silencesPromise(ids: ["p3"], workIDs: known.work, knownIDs: known.known, workOn: false),
                       "印の無いものは止めない")
        XCTAssertFalse(S37AWorkNotice.silencesPromise(ids: ["p9"], workIDs: known.work, knownIDs: known.known, workOn: false),
                       "写しにまだ無いものは止めない")
        XCTAssertFalse(S37AWorkNotice.silencesPromise(ids: [], workIDs: known.work, knownIDs: known.known, workOn: false))
        XCTAssertEqual(S37AWorkNotice.promiseIDs(["ids": ["p1", 3, "", "p2"], "day": "2026-11-28"]), ["p1", "p2"])
        XCTAssertTrue(S37AWorkNotice.promiseIDs([:]).isEmpty)
        S37AWorkNotice.remember([])
    }
}

import UserNotifications
import XCTest
@testable import LifeLog

/// 会話のあとの約束（施策 13。Promises.swift）と、記録に質問するを母艦まで（施策 15。AskMothership.swift）。
/// 名前・中身はすべて作り物。
@MainActor
final class PromisesTests: XCTestCase {
    private func task(_ what: String, day: String?, state: TaskBook.State) -> TaskBook.Item {
        TaskBook.Item(what: what, said: Date(timeIntervalSince1970: 1_700_000_000), day: day, source: .conversation,
                      state: state, work: true)
    }

    // MARK: - 読み方

    func testDecodeFeedSkipsBrokenRows() throws {
        let json: String = """
        {"available": true, "on": true, "generated_at": "2026-11-13T10:00:00+09:00", "items": [
          {"id": "p1", "day": "2026-11-13", "kind": "promised", "who": "見本 花子", "what": "見積もりを送る", "due": "金曜まで",
           "quote": "金曜までに送ります", "said_at": "2026-11-13T00:58:25.123Z", "work": true, "alerted": true, "extra": 1},
          {"id": "p2", "what": "欄の少ないもの"},
          {"day": "2026-11-13", "what": "id が無い"},
          3
        ]}
        """
        let feed: PromisesFeed = try XCTUnwrap(PromiseRules.decode(Data(json.utf8)))
        XCTAssertEqual(feed.items.map(\.id), ["p1", "p2"])
        XCTAssertEqual(feed.items[0].note, "見本 花子と・金曜まで")
        XCTAssertEqual(feed.items[0].kindLabel, "約束")
        XCTAssertEqual(feed.items[1].kind, "asked")
        XCTAssertFalse(feed.items[1].alerted)
        XCTAssertNil(PromiseRules.decode(Data(#"{"available": false, "reason": "x"}"#.utf8)))
        XCTAssertNil(PromiseRules.decode(Data("x".utf8)))
    }

    func testCacheRoundTrip() throws {
        let item = PromiseItem(id: "p1", day: "2026-11-13", kind: "delegated", who: "見本 太郎", what: "資料を頼む")
        let feed = PromisesFeed(available: true, on: true, generatedAt: nil, items: [item])
        let data: Data = try JSONEncoder().encode(feed)
        let back: PromisesFeed = try XCTUnwrap(PromiseRules.decode(data))
        XCTAssertEqual(back, feed)
        XCTAssertEqual(back.items[0].note, "見本 太郎へ")
    }

    // MARK: - 出すもの

    func testVisibleHidesAnsweredAndSimilarTasks() {
        let a = PromiseItem(id: "a", day: "2026-11-13", kind: "promised", who: "", what: "見積もりを送る")
        let b = PromiseItem(id: "b", day: "2026-11-13", kind: "asked", who: "", what: "会議室を取る")
        let c = PromiseItem(id: "c", day: "2026-11-13", kind: "asked", who: "", what: "書類を出す")
        let d = PromiseItem(id: "d", day: "2026-11-13", kind: "asked", who: "", what: "名刺を作る")
        let tasks: [TaskBook.Item] = [
            task("見積もりを送ります", day: "2026-11-01", state: .open),    // まだ済んでいない → 同じ
            task("会議室を取ります", day: "2026-11-13", state: .done),      // 同じ日 → 同じ
            task("書類を出します", day: "2026-11-01", state: .done),        // 別の日に済んだ → 別
        ]
        let shown: [PromiseItem] = PromiseRules.visible([a, b, c, d], answered: ["d"], tasks: tasks)
        XCTAssertEqual(shown.map(\.id), ["c"])
    }

    // MARK: - タスクに入れる形

    func testTaskItem() throws {
        let p = PromiseItem(id: "p1", day: "2026-11-13", kind: "promised", who: "見本 花子", what: "見積もりを送る",
                            due: "金曜まで", quote: "金曜までに送ります", saidAt: "2026-11-13T00:58:25.123Z", work: nil)
        let item: TaskBook.Item = PromiseRules.taskItem(p, work: false)
        XCTAssertEqual(item.what, "見積もりを送る")
        XCTAssertEqual(item.from, "見本 花子")
        XCTAssertEqual(item.dueText, "金曜まで")
        XCTAssertEqual(item.kind, .promise)
        XCTAssertEqual(item.state, .open)
        XCTAssertEqual(item.source, .conversation)
        XCTAssertEqual(item.day, "2026-11-13")
        XCTAssertEqual(item.quote, "金曜までに送ります")
        XCTAssertEqual(item.work, false)
        XCTAssertEqual(item.said.timeIntervalSince1970, 1_794_531_505.123, accuracy: 0.01)
        let asked: TaskBook.Item = PromiseRules.taskItem(PromiseItem(id: "x", day: "", kind: "asked", who: "", what: "x",
                                                                     due: "なし", work: true), work: false)
        XCTAssertNil(asked.from)
        XCTAssertNil(asked.dueText)
        XCTAssertNil(asked.day)
        XCTAssertEqual(asked.kind, .asked)
        XCTAssertEqual(asked.work, true)
        XCTAssertEqual(PromiseRules.taskItem(PromiseItem(id: "y", day: "", kind: "delegated", who: "", what: "y"), work: true).kind, .delegated)
    }

    // MARK: - 家の PC に送る中身

    func testBodies() throws {
        let settings: Data = try XCTUnwrap(PromiseRules.settingsBody(on: true, claude: true, work: false, hide: true, device: "dev-0001-aaaa"))
        let s = try XCTUnwrap(JSONSerialization.jsonObject(with: settings) as? [String: Any])
        XCTAssertEqual(s["on"] as? Bool, true)
        XCTAssertEqual(s["work"] as? Bool, false)
        XCTAssertEqual(s["hide_body"] as? Bool, true)
        XCTAssertEqual(s["device"] as? String, "dev-0001-aaaa")
        let feedback: Data = try XCTUnwrap(PromiseRules.feedbackBody(id: String(repeating: "a", count: 80), added: false, day: "2026-11-13"))
        let f = try XCTUnwrap(JSONSerialization.jsonObject(with: feedback) as? [String: String])
        XCTAssertEqual(f, ["kind": "promise", "id": String(repeating: "a", count: 64), "value": "ignored", "day": "2026-11-13"])
    }

    func testNotificationCategory() {
        let category = PromiseRules.notificationCategory()
        XCTAssertEqual(category.identifier, "promise")
        XCTAssertEqual(category.actions.map(\.identifier), ["keep", "reject"])
        XCTAssertEqual(category.actions.map(\.title), ["タスクに入れる", "いらない"])
        XCTAssertTrue(NoticeActions.categories().contains { $0.identifier == "promise" })
    }

    // MARK: - 母艦の答え

    func testMothershipAnswerDecode() throws {
        let json: String = """
        {"available": true, "found": true, "answer": "11/01 の LINE で決めていました [1]",
         "sources": [{"n": 1, "day": "2026-11-01", "time": "12:34", "source": "line", "label": "LINE", "text": "見本の店に7時で"},
                     {"n": 2, "day": "2026-10", "time": "", "source": "money", "text": "支出のまとめ"},
                     {"day": "x"}],
         "searched": {"queries": 2, "snippets": 7, "by_source": {"line": 5}}, "seconds": 12.3}
        """
        let answer: MothershipAnswer = try XCTUnwrap(MothershipAsk.decode(Data(json.utf8)))
        XCTAssertTrue(answer.found)
        XCTAssertEqual(answer.snippets, 7)
        XCTAssertEqual(answer.sources.map(\.n), [1, 2])
        XCTAssertEqual(answer.sources[0].caption, "LINE・11/01 12:34")
        XCTAssertEqual(answer.sources[1].label, "お金")
        XCTAssertEqual(answer.sources[1].caption, "お金・2026-10")
        XCTAssertNil(MothershipAsk.decode(Data(#"{"found": true}"#.utf8)))
    }

    func testMothershipUsable() {
        let on: Set<String> = ["askmother"]
        XCTAssertTrue(MothershipAsk.usable(features: on, useClaude: true, forWork: true))
        XCTAssertFalse(MothershipAsk.usable(features: [], useClaude: true, forWork: true))
        XCTAssertFalse(MothershipAsk.usable(features: on, useClaude: false, forWork: true))
        XCTAssertFalse(MothershipAsk.usable(features: on, useClaude: true, forWork: false))
        XCTAssertNil(MothershipAsk.blocked(features: on, useClaude: true, forWork: true))
        XCTAssertNotNil(MothershipAsk.blocked(features: on, useClaude: true, forWork: false))
        let body = try? JSONSerialization.jsonObject(with: MothershipAsk.body(String(repeating: "あ", count: 600)) ?? Data()) as? [String: String]
        XCTAssertEqual(body?["question"]?.count, 500)
    }
}

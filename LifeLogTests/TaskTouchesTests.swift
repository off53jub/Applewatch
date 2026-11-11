import XCTest
@testable import LifeLog

/// 返事の下書き・待たれている日数・店名の無いかざした記録の場所推測（2026-11-12）
@MainActor
final class TaskTouchesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_793_000_000)

    private func item(_ what: String, from: String?, kind: TaskBook.Kind? = nil) -> TaskBook.Item {
        TaskBook.Item(what: what, from: from, said: base, source: .conversation, state: .open, kind: kind)
    }

    // MARK: C4 返事の下書き

    func testReplyDraftForAskedItem() {
        let draft = TaskReply.draft(for: item("見積書を送る。", from: "テスト太郎"))
        XCTAssertEqual(draft?.text, "テスト太郎さん、見積書を送るの件、終わりました。")
    }

    func testReplyNameKeepsSingleHonorific() {
        XCTAssertEqual(TaskReply.text(what: "資料", from: "テスト花子さん"), "テスト花子さん、資料の件、終わりました。")
        XCTAssertEqual(TaskReply.text(what: "資料", from: "テスト部長様"), "テスト部長さん、資料の件、終わりました。")
    }

    func testReplyNotForOthers() {
        XCTAssertNil(TaskReply.draft(for: item("電球を買う", from: nil)))
        XCTAssertNil(TaskReply.draft(for: item("電球を買う", from: "   ")))
        XCTAssertNil(TaskReply.draft(for: item("返事を待つ", from: "テスト太郎", kind: .delegated)))
        XCTAssertNil(TaskReply.draft(for: item("会う", from: "テスト太郎", kind: .promise)))
    }

    func testShortTitleCutsLongAndFirstLine() {
        XCTAssertEqual(TaskReply.shortTitle("資料を直す！\n二行目"), "資料を直す")
        let long = String(repeating: "あ", count: 40)
        XCTAssertEqual(TaskReply.shortTitle(long), String(repeating: "あ", count: TaskReply.maxTitle) + "…")
        XCTAssertEqual(TaskReply.text(what: "  ", from: "テスト太郎"), "テスト太郎さん、お願いされていた件、終わりました。")
    }

    // MARK: C2 待たれている日数

    private func parse(_ json: String) -> MothershipExport? {
        MothershipExport.parse(json.data(using: .utf8)!)
    }

    func testDecodeWithWaitingFields() throws {
        let export = try XCTUnwrap(parse(#"{"items":[{"id":"0123456789ab","text":"資料を送る","waiting_for":"テスト太郎","waiting_days":4}]}"#))
        let item = try XCTUnwrap(export.items.first)
        XCTAssertEqual(item.waitingFor, "テスト太郎")
        XCTAssertEqual(item.waitingDays, 4)
        XCTAssertTrue(item.isWaitedLong)
        XCTAssertEqual(item.waitingLine, "テスト太郎さんが 4日待っています")
    }

    func testDecodeWithoutWaitingFields() throws {
        let export = try XCTUnwrap(parse(#"{"items":[{"id":"0123456789ab","text":"資料を送る","work":true}]}"#))
        let item = try XCTUnwrap(export.items.first)
        XCTAssertNil(item.waitingFor)
        XCTAssertNil(item.waitingDays)
        XCTAssertFalse(item.isWaitedLong)
        XCTAssertNil(item.waitingLine)
        XCTAssertEqual(item.work, true)
    }

    func testBadWaitingTypeDoesNotBreakEverything() throws {
        let export = try XCTUnwrap(parse(#"{"items":[{"id":"0123456789ab","text":"a","waiting_days":"たくさん","waiting_for":5},{"id":"0123456789ac","text":"b","waiting_days":3.0}]}"#))
        XCTAssertEqual(export.items.count, 2)
        XCTAssertNil(export.items[0].waitingDays)
        XCTAssertNil(export.items[0].waitingFor)
        XCTAssertEqual(export.items[1].waitingDays, 3)
    }

    func testWaitingLineWithoutName() {
        var item = MothershipTodo(id: "0123456789ab", text: "a")
        item.waitingDays = 2
        XCTAssertEqual(item.waitingLine, "2日待っている人がいます")
        XCTAssertFalse(item.isWaitedLong)
        item.waitingDays = 0
        XCTAssertNil(item.waitingLine)
    }

    func testSortPutsLongWaitedFirst() {
        var long = MothershipTodo(id: "000000000001", text: "long", added: "2026-09-01")
        long.waitingDays = 3
        var longer = MothershipTodo(id: "000000000002", text: "longer", added: "2026-09-01")
        longer.waitingDays = 7
        var short = MothershipTodo(id: "000000000003", text: "short", added: "2026-11-01", due: "2026-11-10")
        short.waitingDays = 2
        let plain = MothershipTodo(id: "000000000004", text: "plain", added: "2026-11-05")
        let sorted = MothershipBook.sorted([plain, short, long, longer])
        XCTAssertEqual(sorted.map(\.text), ["longer", "long", "short", "plain"])
    }

    // MARK: D6 場所からの推測

    private func visit(_ from: TimeInterval, _ to: TimeInterval?, name: String?, state: ShopVisit.State = .confirmed) -> ShopVisit {
        var v = ShopVisit(arrival: base.addingTimeInterval(from), departure: to.map { base.addingTimeInterval($0) },
                          latitude: 35, longitude: 139, accuracy: 20)
        v.state = state
        if state == .confirmed {
            v.confirmedName = name
        } else if state == .guessed {
            v.candidates = [ShopCandidate(id: "c", source: .apple, name: name, kind: .food, distance: 5, fetched: base)]
            v.guessID = "c"
        }
        return v
    }

    func testGuessInsideVisit() {
        let v = visit(-600, 600, name: "テスト食堂")
        XCTAssertEqual(PaymentMatch.placeGuess(at: base, visits: [v]), "テスト食堂")
    }

    func testGuessWithinTenMinutesOutside() {
        // 出てから9分後は当たり・11分後は外れ
        let v = visit(-1800, 0, name: "テスト食堂")
        XCTAssertEqual(PaymentMatch.placeGuess(at: base.addingTimeInterval(540), visits: [v]), "テスト食堂")
        XCTAssertNil(PaymentMatch.placeGuess(at: base.addingTimeInterval(660), visits: [v]))
        // 着く9分前は当たり
        let later = visit(540, 1800, name: "テスト食堂")
        XCTAssertEqual(PaymentMatch.placeGuess(at: base, visits: [later]), "テスト食堂")
        XCTAssertNil(PaymentMatch.placeGuess(at: base.addingTimeInterval(-120), visits: [visit(840, 1800, name: "テスト食堂")]))
    }

    func testGuessOpenVisitAndPicksNearest() {
        let open = visit(-60, nil, name: "まだいる店", state: .guessed)
        XCTAssertEqual(PaymentMatch.placeGuess(at: base, visits: [open]), "まだいる店")
        let near = visit(-300, 300, name: "近い店")
        let far = visit(-1200, -420, name: "遠い店")
        XCTAssertEqual(PaymentMatch.placeGuess(at: base, visits: [far, near]), "近い店")
    }

    func testGuessIgnoresNotShopAndNoName() {
        XCTAssertNil(PaymentMatch.placeGuess(at: base, visits: [visit(-60, 60, name: "x", state: .notShop)]))
        XCTAssertNil(PaymentMatch.placeGuess(at: base, visits: [visit(-60, 60, name: nil, state: .waiting)]))
        XCTAssertNil(PaymentMatch.placeGuess(at: base, visits: [visit(-60, 60, name: " ", state: .confirmed)]))
        XCTAssertNil(PaymentMatch.placeGuess(at: base, visits: []))
    }

    func testLabelOnlyForEmptyTap() {
        let v = visit(-60, 60, name: "テスト食堂")
        let emptyTap = Payment(id: "1", time: base, amount: 300, shop: "", source: Payment.tap)
        let namedTap = Payment(id: "2", time: base, amount: 300, shop: "店X", source: Payment.tap)
        let emptyMail = Payment(id: "3", time: base, amount: 300, shop: "", source: Payment.cardMail)
        XCTAssertEqual(PaymentMatch.placeGuessLabel(for: emptyTap, visits: [v]), "たぶんテスト食堂（場所から）")
        XCTAssertNil(PaymentMatch.placeGuessLabel(for: namedTap, visits: [v]))
        XCTAssertNil(PaymentMatch.placeGuessLabel(for: emptyMail, visits: [v]))
        // 記録そのものは変わらない
        XCTAssertEqual(emptyTap.shop, "")
    }
}

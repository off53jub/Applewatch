import XCTest
@testable import LifeLog

final class PaymentTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tokyo
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // 作り物の明細（PayPay の書き出しと同じ列）
    private let csv = """
    \u{FEFF}取引日,出金金額（円）,入金金額（円）,海外出金金額,通貨,変換レート（円）,利用国,取引内容,取引先,取引方法,支払い区分,利用者,取引番号
    2026/09/03 12:05:10,"1,280",-,-,-,-,-,支払い,テスト食堂 本店,PayPay残高,-,-,A001
    2026/09/03 13:00:00,-,"8,000",-,-,-,-,チャージ,テスト銀行,テスト銀行 *****00,-,-,A002
    2026/09/02 19:30:00,450,-,-,-,-,-,支払い,"カフェ,テスト",PayPayポイント,-,-,A003
    2026/09/02 19:31:00,0,-,-,-,-,-,支払い,ゼロ円,PayPayポイント,-,-,A004
    """

    func testParseKeepsOnlyPayments() throws {
        let list = try XCTUnwrap(PayPayCSV.parse(Data(csv.utf8), timeZone: tokyo))
        XCTAssertEqual(list.map(\.id), ["A001", "A003"])
        XCTAssertEqual(list[0].amount, 1280)
        XCTAssertEqual(list[0].shop, "テスト食堂 本店")
        XCTAssertEqual(list[0].time, at(2026, 9, 3, 12, 5).addingTimeInterval(10))
        XCTAssertEqual(list[1].shop, "カフェ,テスト")
    }

    func testParseRejectsOtherFiles() {
        XCTAssertNil(PayPayCSV.parse(Data("名前,電話\nあ,1\n".utf8)))
    }

    func testMergeSkipsSameTransaction() throws {
        let list = try XCTUnwrap(PayPayCSV.parse(Data(csv.utf8), timeZone: tokyo))
        let merged = PaymentBook.merged(list, list)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.id, "A003")  // 古い順
    }

    func testMatchWithinVisit() {
        let v = ShopVisit(arrival: at(2026, 9, 3, 11, 50), departure: at(2026, 9, 3, 12, 30), latitude: 35, longitude: 139, accuracy: 20)
        let inside = Payment(id: "1", time: at(2026, 9, 3, 12, 25), amount: 1000, shop: "店A")
        let afterLeaving = Payment(id: "2", time: at(2026, 9, 3, 12, 38), amount: 500, shop: "店B")
        let farAway = Payment(id: "3", time: at(2026, 9, 3, 14, 0), amount: 500, shop: "店C")
        XCTAssertEqual(PaymentMatch.payment(for: v, in: [farAway, inside, afterLeaving])?.id, "1")
        XCTAssertEqual(PaymentMatch.payment(for: v, in: [afterLeaving, farAway])?.id, "2")
        XCTAssertNil(PaymentMatch.payment(for: v, in: [farAway]))
        XCTAssertEqual(PaymentMatch.unmatched([inside, farAway], visits: [v]).map(\.id), ["3"])
    }

    func testScore() {
        var hit = ShopVisit(arrival: at(2026, 9, 3, 12), departure: at(2026, 9, 3, 13), latitude: 35, longitude: 139, accuracy: 20)
        hit.state = .guessed
        hit.candidates = [ShopCandidate(id: "c1", source: .apple, name: "テスト食堂", kind: .food, distance: 10, fetched: .now)]
        hit.guessID = "c1"
        let none = ShopVisit(arrival: at(2026, 9, 3, 18), departure: at(2026, 9, 3, 19), latitude: 35, longitude: 139, accuracy: 20)
        let payments = [Payment(id: "1", time: at(2026, 9, 3, 12, 40), amount: 1000, shop: "テスト食堂"),
                        Payment(id: "2", time: at(2026, 9, 3, 18, 40), amount: 300, shop: "店X")]
        XCTAssertEqual(PaymentMatch.score([hit, none], payments: payments), PaymentMatch.Score(hit: 1, miss: 0, none: 1))
    }
}

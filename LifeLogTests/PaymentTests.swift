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

    // MARK: カードの利用速報・ウォレットでかざした記録（2026-11-09）

    func testYen() {
        XCTAssertEqual(CardTap.yen("¥1,234"), 1234)
        XCTAssertEqual(CardTap.yen("1,280円"), 1280)
        XCTAssertEqual(CardTap.yen("１２８０"), 1280)
        XCTAssertEqual(CardTap.yen("1234.00"), 1234)
        XCTAssertEqual(CardTap.yen(""), 0)
        XCTAssertEqual(CardTap.yen(nil), 0)
    }

    func testCardMailExport() throws {
        let json = """
        {"available": true, "items": [
          {"id": "19a0b1c2d3e4f5a6", "time": "2026-10-20T07:10:00+09:00", "amount": 35000, "shop": "テスト銀行", "card": "PayPayカード"},
          {"id": "x", "time": "きのう", "amount": 1, "shop": "y"},
          {"id": "z", "time": "2026-10-20T07:10:00+09:00", "amount": 0, "shop": "y"}]}
        """
        let list = try XCTUnwrap(CardMailExport.parse(Data(json.utf8)))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "mail-19a0b1c2d3e4f5a6")
        XCTAssertEqual(list[0].time, at(2026, 10, 20, 7, 10))
        XCTAssertEqual(list[0].source, Payment.cardMail)
        XCTAssertEqual(list[0].via, "カード")
        XCTAssertNil(CardMailExport.parse(Data(#"{"available": false}"#.utf8)))
    }

    func testOldSavedPaymentsStillRead() throws {
        // 前の版の payments.json（source・card が無い）も読める
        let old = #"[{"id":"A001","time":0,"amount":100,"shop":"店"}]"#
        let list = try JSONDecoder().decode([Payment].self, from: Data(old.utf8))
        XCTAssertNil(list[0].source)
        XCTAssertEqual(list[0].via, "PayPay")
    }

    func testTapLinesRoundTrip() throws {
        let a = CardTap.make(shop: " テスト食堂 ", amount: "¥980", card: "PayPayカード", at: at(2026, 11, 9, 12))
        let b = CardTap.make(shop: nil, amount: nil, card: "PASMO", at: at(2026, 11, 9, 13))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(a) + Data([0x0A]) + Data("壊れた行".utf8) + Data([0x0A])
        data += try encoder.encode(b)
        let list = CardTap.read(data)
        XCTAssertEqual(list.map(\.shop), ["テスト食堂", ""])
        XCTAssertEqual(list.map(\.amount), [980, 0])
        XCTAssertFalse(list[1].hasShop)
        XCTAssertEqual(list[1].via, "かざした")
    }

    func testGenericShopIsNotAName() {
        XCTAssertFalse(Payment(id: "1", time: .now, amount: 1, shop: "JCB国内加盟店").hasShop)
        XCTAssertFalse(Payment(id: "1", time: .now, amount: 1, shop: "ＰａｙＰａｙ").hasShop)
        XCTAssertTrue(Payment(id: "1", time: .now, amount: 1, shop: "テスト食堂").hasShop)
        // 名前の無い支払いは、立ち寄りの名前に使わない
        let v = ShopVisit(arrival: at(2026, 9, 3, 11, 50), departure: at(2026, 9, 3, 12, 30), latitude: 35, longitude: 139, accuracy: 20)
        let noName = Payment(id: "t", time: at(2026, 9, 3, 12), amount: 0, shop: "", source: Payment.tap)
        XCTAssertNil(PaymentMatch.payment(for: v, in: [noName]))
    }

    func testCombineTapWithMail() {
        let mail = Payment(id: "mail-1", time: at(2026, 11, 9, 12, 5), amount: 980, shop: "テスト食堂", source: Payment.cardMail)
        // かざした記録（金額なし・名前なし）→ メールと1件に。時刻はかざした方
        let tap = Payment(id: "tap-1", time: at(2026, 11, 9, 12, 4).addingTimeInterval(30), amount: 0, shop: "", source: Payment.tap)
        // 別の支払い（金額が違う）→ そのまま残る
        let other = Payment(id: "tap-2", time: at(2026, 11, 9, 12, 6), amount: 150, shop: "", source: Payment.tap)
        let all = PaymentMerge.combine(paypay: [], mail: [mail], taps: [tap, other])
        XCTAssertEqual(all.map(\.id), ["mail-1", "tap-2"])
        XCTAssertEqual(all[0].time, tap.time)
        XCTAssertEqual(all[0].shop, "テスト食堂")
    }

    func testCombineTapGivesNameToGenericMail() {
        let mail = Payment(id: "mail-1", time: at(2026, 11, 9, 12, 5), amount: 980, shop: "VISA国内加盟店", source: Payment.cardMail)
        let tap = Payment(id: "tap-1", time: at(2026, 11, 9, 12, 5), amount: 980, shop: "テスト食堂", source: Payment.tap)
        let all = PaymentMerge.combine(paypay: [], mail: [mail], taps: [tap])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].shop, "テスト食堂")
    }

    func testCombineDropsCardMailForPayPayPayment() {
        // PayPay の支払いにカードを使ったとき: PayPay の明細（お店の名前あり）を残し、カードのメール（払った先が PayPay）は落とす
        let paypay = Payment(id: "A001", time: at(2026, 11, 9, 12, 5), amount: 980, shop: "テスト食堂")
        let mail = Payment(id: "mail-1", time: at(2026, 11, 9, 12, 6), amount: 980, shop: "PAYPAY", source: Payment.cardMail)
        let far = Payment(id: "mail-2", time: at(2026, 11, 9, 15), amount: 980, shop: "PAYPAY", source: Payment.cardMail)
        XCTAssertEqual(PaymentMerge.combine(paypay: [paypay], mail: [mail, far], taps: []).map(\.id), ["A001", "mail-2"])
    }
}

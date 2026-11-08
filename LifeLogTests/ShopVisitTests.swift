import CoreLocation
import XCTest
@testable import LifeLog

/// 行ったお店（2026-11-08）の決まりを確かめる。
/// 点数・はっきりしないときの決まり・Google に聞くか・回数の上限・30日で名前を消す・名前のそろえ方・残す立ち寄り。
/// 名前はすべて作り物か、よくあるお店の形。
@MainActor
final class ShopVisitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func cand(_ name: String?, _ kind: ShopKind, _ distance: Double, source: ShopCandidate.Source = .apple,
                      fetched: Date? = nil, id: String? = nil) -> ShopCandidate {
        ShopCandidate(id: id ?? "\(source.rawValue):\(name ?? "x")", source: source, name: name, kind: kind,
                      distance: distance, latitude: 35, longitude: 139, googleID: source == .google ? "pid-\(name ?? "x")" : nil,
                      fetched: fetched ?? now)
    }

    // MARK: - 点数

    func testCloserWinsWithoutTalk() {
        let ranked = ShopGuess.score([cand("見本カフェ", .cafe, 80), cand("見本パン", .cafe, 10)], text: "", radius: 100)
        XCTAssertEqual(ranked.first?.name, "見本パン")
        XCTAssertEqual(ranked.first?.score ?? 0, 0.9, accuracy: 0.001)
    }

    func testNameInTalkWins() {
        let list = [cand("ミホンベーカリー", .cafe, 5), cand("サンプル珈琲", .cafe, 90)]
        let ranked = ShopGuess.score(list, text: "サンプル珈琲のブレンドおいしいね", radius: 100)
        XCTAssertEqual(ranked.first?.name, "サンプル珈琲")
        XCTAssertEqual(ranked.first?.clues, ["会話に名前"])
    }

    func testPartOfNameInTalk() {
        let list = [cand("スターバックス コーヒー 見本店", .cafe, 60), cand("見本書房", .store, 10)]
        let ranked = ShopGuess.score(list, text: "スターバックスで待ってるね", radius: 100)
        XCTAssertEqual(ranked.first?.name, "スターバックス コーヒー 見本店")
        XCTAssertEqual(ranked.first?.clues, ["会話に名前の一部"])
    }

    func testCategoryWords() {
        let list = [cand("見本ストア", .store, 20), cand("見本食堂", .food, 20)]
        let ranked = ShopGuess.score(list, text: "店内でお召し上がりですか。ご注文は", radius: 100)
        XCTAssertEqual(ranked.first?.name, "見本食堂")
        let pharmacy = ShopGuess.score([cand("見本ストア", .store, 20), cand("見本薬局", .pharmacy, 25)],
                                       text: "処方箋をお預かりします", radius: 100)
        XCTAssertEqual(pharmacy.first?.name, "見本薬局")
        let store = ShopGuess.score([cand("見本カフェ", .cafe, 20), cand("見本ストア", .store, 22)],
                                    text: "袋はご利用ですか。レシートです。ポイントカードは", radius: 100)
        XCTAssertEqual(store.first?.name, "見本ストア")
    }

    func testCategoryBoostIsCapped() {
        let ranked = ShopGuess.score([cand("見本ストア", .store, 100)], text: "ポイントカード 袋 レシート 温めますか 試着 在庫", radius: 100)
        XCTAssertEqual(ranked.first?.score ?? 0, 0.75, accuracy: 0.001)
    }

    func testKnownShopBoost() {
        let list = [cand("見本カフェ", .cafe, 10), cand("見本パン", .cafe, 30)]
        let ranked = ShopGuess.score(list, text: "", radius: 100, known: [ShopGuess.normalize("見本パン")])
        XCTAssertEqual(ranked.first?.name, "見本パン")
    }

    func testGenericNameIsNotAClue() {
        // 「カフェ」だけの名前は、会話に「カフェ」と出ても名前の手がかりにしない
        let ranked = ShopGuess.score([cand("カフェ", .other, 50)], text: "カフェに行こう", radius: 100)
        XCTAssertNil(ranked.first?.clues)
    }

    // MARK: - はっきりしない・Google に聞くか

    func testAmbiguity() {
        var a = cand("A店舗", .cafe, 10), b = cand("B店舗", .cafe, 20)
        a.score = 1.0
        b.score = 0.9
        XCTAssertTrue(ShopGuess.isAmbiguous([a, b]))
        b.score = 0.7
        XCTAssertFalse(ShopGuess.isAmbiguous([a, b]))
        XCTAssertFalse(ShopGuess.isAmbiguous([a]))
        XCTAssertFalse(ShopGuess.isAmbiguous([]))
    }

    func testNeedsGoogle() {
        var a = cand("A店舗", .cafe, 10), b = cand("B店舗", .cafe, 20)
        a.score = 1.0
        b.score = 0.95
        // Apple で見つからない
        XCTAssertTrue(ShopGuess.needsGoogle([], hasKey: true, underCap: true, alreadyTried: false))
        // はっきりしない
        XCTAssertTrue(ShopGuess.needsGoogle([a, b], hasKey: true, underCap: true, alreadyTried: false))
        // キーが無い・上限・もう聞いた
        XCTAssertFalse(ShopGuess.needsGoogle([], hasKey: false, underCap: true, alreadyTried: false))
        XCTAssertFalse(ShopGuess.needsGoogle([], hasKey: true, underCap: false, alreadyTried: false))
        XCTAssertFalse(ShopGuess.needsGoogle([], hasKey: true, underCap: true, alreadyTried: true))
        // はっきりしている
        b.score = 0.2
        XCTAssertFalse(ShopGuess.needsGoogle([a, b], hasKey: true, underCap: true, alreadyTried: false))
    }

    func testMergeSkipsSameShop() {
        let base = [cand("見本カフェ 駅前店", .cafe, 10)]
        let extra = [cand("見本カフェ駅前店", .cafe, 12, source: .google), cand("別の見本屋", .store, 30, source: .google)]
        let merged = ShopGuess.merged(base, adding: extra)
        XCTAssertEqual(merged.map(\.name), ["見本カフェ 駅前店", "別の見本屋"])
    }

    // MARK: - 回数の上限

    func testCaps() {
        XCTAssertTrue(ShopGuess.underCap(day: 0, month: 0, dayCap: 20, monthCap: 300))
        XCTAssertFalse(ShopGuess.underCap(day: 20, month: 20, dayCap: 20, monthCap: 300))
        XCTAssertFalse(ShopGuess.underCap(day: 3, month: 300, dayCap: 20, monthCap: 300))
        XCTAssertFalse(ShopGuess.underCap(day: 0, month: 0, dayCap: 0, monthCap: 300))
    }

    func testCallCounting() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var saved: [String: Int] = ["d:2000-01-01": 9, "m:2000-01": 50]
        saved = ShopGuess.bumped(saved, now: now, calendar: cal)
        saved = ShopGuess.bumped(saved, now: now, calendar: cal)
        XCTAssertEqual(saved.count, 2, "今日と今月のほかは捨てる")
        XCTAssertEqual(ShopGuess.callCounts(saved, now: now, calendar: cal), ShopGuess.Calls(day: 2, month: 2))
        // 次の日は、今日は0・今月は続き（同じ月のうちなら）
        let next = now.addingTimeInterval(86400)
        let counts = ShopGuess.callCounts(saved, now: next, calendar: cal)
        XCTAssertEqual(counts.day, 0)
        if cal.component(.month, from: next) == cal.component(.month, from: now) { XCTAssertEqual(counts.month, 2) }
    }

    // MARK: - 30日で Google の名前を消す

    func testPruneGoogleAfter30Days() {
        let old = now.addingTimeInterval(-31 * 86400), recent = now.addingTimeInterval(-10 * 86400)
        var v = ShopVisit(arrival: old, departure: old.addingTimeInterval(600), latitude: 35, longitude: 139, accuracy: 50)
        v.candidates = [cand("古いG", .cafe, 10, source: .google, fetched: old),
                        cand("新しいG", .cafe, 20, source: .google, fetched: recent),
                        cand("古いA", .cafe, 30, source: .apple, fetched: old)]
        var confirmed = v
        confirmed.id = "c"
        confirmed.state = .confirmed
        confirmed.confirmedID = "google:古いG"
        confirmed.confirmedName = "古いG"
        let out = ShopGuess.pruned([v, confirmed], now: now)
        XCTAssertNil(out[0].candidates[0].name)
        XCTAssertNil(out[0].candidates[0].latitude)
        XCTAssertEqual(out[0].candidates[0].googleID, "pid-古いG", "place id は残す")
        XCTAssertEqual(out[0].candidates[1].name, "新しいG")
        XCTAssertEqual(out[0].candidates[2].name, "古いA", "Apple の候補は消さない")
        XCTAssertEqual(out[1].candidates[0].name, "古いG", "本人が決めた候補は残す")
        XCTAssertEqual(out[1].confirmedName, "古いG")
    }

    // MARK: - 名前のそろえ方

    func testNormalize() {
        XCTAssertEqual(ShopGuess.normalize("ｽﾀｰﾊﾞｯｸｽ"), "スターバックス")
        XCTAssertEqual(ShopGuess.normalize("ＡＢＣ Mart"), "abcmart")
        XCTAssertEqual(ShopGuess.normalize("すき家"), "スキ家")
        XCTAssertEqual(ShopGuess.normalize("見本・カフェ　（駅前）"), "見本カフェ駅前")
    }

    func testNameKeys() {
        let a = ShopGuess.nameKeys("マクドナルド見本店")
        XCTAssertEqual(a.first, "マクドナルド見本店")
        XCTAssertTrue(a.contains("マクドナルド"))
        let b = ShopGuess.nameKeys("スターバックス コーヒー 見本駅前店")
        XCTAssertTrue(b.contains("スターバックス"))
        XCTAssertFalse(b.contains("コーヒー"), "ありふれた言葉は入れない")
        XCTAssertFalse(b.contains("見本駅前店"), "「〜店」の部分は入れない")
        XCTAssertEqual(ShopGuess.nameKeys("松屋"), ["松屋"])
    }

    // MARK: - 残す立ち寄り

    func testKeepFiltersShortAndRegistered() {
        let home = PlaceLog.Place(name: "見本の家", latitude: 35.0, longitude: 139.0)
        let a = now
        // 3分未満は残さない
        XCTAssertFalse(ShopGuess.keep(arrival: a, departure: a.addingTimeInterval(120), latitude: 35.1, longitude: 139.1,
                                      accuracy: 30, places: [home]))
        // 登録した場所の中は残さない（約110m）
        XCTAssertFalse(ShopGuess.keep(arrival: a, departure: a.addingTimeInterval(1800), latitude: 35.001, longitude: 139.0,
                                      accuracy: 30, places: [home]))
        // 離れたお店は残す（約1.1km）
        XCTAssertTrue(ShopGuess.keep(arrival: a, departure: a.addingTimeInterval(1800), latitude: 35.01, longitude: 139.0,
                                     accuracy: 30, places: [home]))
        // いる途中（出た時刻が分からない）は残す
        XCTAssertTrue(ShopGuess.keep(arrival: a, departure: nil, latitude: 35.01, longitude: 139.0, accuracy: 30, places: []))
    }

    func testSearchRadius() {
        XCTAssertEqual(ShopGuess.searchRadius(accuracy: 5), 40)
        XCTAssertEqual(ShopGuess.searchRadius(accuracy: 90), 90)
        XCTAssertEqual(ShopGuess.searchRadius(accuracy: 900), 150)
    }

    func testOpenVisitMatching() {
        let open = ShopVisit(arrival: now, latitude: 35.0, longitude: 139.0, accuracy: 50)
        var closed = ShopVisit(arrival: now.addingTimeInterval(-7200), latitude: 35.0, longitude: 139.0, accuracy: 50)
        closed.departure = now.addingTimeInterval(-3600)
        let visits = [closed, open]
        XCTAssertEqual(ShopGuess.openIndex(visits, latitude: 35.0005, longitude: 139.0, arrival: now.addingTimeInterval(30)), 1)
        XCTAssertEqual(ShopGuess.openIndex(visits, latitude: 35.0, longitude: 139.0, arrival: nil), 1)
        XCTAssertNil(ShopGuess.openIndex(visits, latitude: 35.01, longitude: 139.0, arrival: now))
        XCTAssertNil(ShopGuess.openIndex(visits, latitude: 35.0, longitude: 139.0, arrival: now.addingTimeInterval(3600)))
    }

    func testNeedsRetry() {
        var v = ShopVisit(arrival: now.addingTimeInterval(-3600), departure: now.addingTimeInterval(-1800),
                          latitude: 35, longitude: 139, accuracy: 50)
        v.state = .guessed
        v.searchedAt = now.addingTimeInterval(-1800)
        v.linesRead = 0
        XCTAssertFalse(ShopGuess.needsRetry(v, lineCount: 0, now: now), "変わっていなければやり直さない")
        XCTAssertTrue(ShopGuess.needsRetry(v, lineCount: 5, now: now), "会話が文字になったらやり直す")
        v.searchedAt = nil
        XCTAssertTrue(ShopGuess.needsRetry(v, lineCount: 0, now: now), "調べられなかったらやり直す")
        v.state = .confirmed
        XCTAssertFalse(ShopGuess.needsRetry(v, lineCount: 5, now: now), "決めたものはやり直さない")
        v.state = .guessed
        XCTAssertFalse(ShopGuess.needsRetry(v, lineCount: 5, now: now.addingTimeInterval(2 * 86400)), "24時間より前はやり直さない")
        // いる途中は、6時間たつまで推測しない
        let open = ShopVisit(arrival: now.addingTimeInterval(-3600), latitude: 35, longitude: 139, accuracy: 50)
        XCTAssertFalse(ShopGuess.needsRetry(open, lineCount: 0, now: now))
        XCTAssertTrue(ShopGuess.needsRetry(open, lineCount: 0, now: now.addingTimeInterval(6 * 3600)))
    }

    // MARK: - 種類・Google の答え

    func testKinds() {
        XCTAssertEqual(ShopGuess.kind(apple: .cafe), .cafe)
        XCTAssertEqual(ShopGuess.kind(apple: .pharmacy), .pharmacy)
        XCTAssertEqual(ShopGuess.kind(apple: nil), .other)
        XCTAssertEqual(ShopGuess.kind(google: ["ramen_restaurant", "restaurant"]), .food)
        XCTAssertEqual(ShopGuess.kind(google: ["convenience_store"]), .store)
        XCTAssertEqual(ShopGuess.kind(google: ["drugstore"]), .pharmacy)
        XCTAssertEqual(ShopGuess.kind(google: ["coffee_shop"]), .cafe)
    }

    func testGoogleRequest() throws {
        let r = GoogleNearby.request(key: "TEST-KEY", latitude: 35.5, longitude: 139.5, radius: 80)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://places.googleapis.com/v1/places:searchNearby")
        XCTAssertFalse(r.url?.absoluteString.contains("TEST-KEY") ?? true, "キーは URL に入れない")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Goog-Api-Key"), "TEST-KEY")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Goog-FieldMask"),
                       "places.id,places.displayName,places.primaryType,places.types,places.location")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["maxResultCount"] as? Int, 10)
        XCTAssertEqual(body["rankPreference"] as? String, "DISTANCE")
        XCTAssertEqual(body["languageCode"] as? String, "ja")
        let circle = (body["locationRestriction"] as? [String: Any])?["circle"] as? [String: Any]
        XCTAssertEqual(circle?["radius"] as? Double, 80)
        XCTAssertEqual((circle?["center"] as? [String: Any])?["latitude"] as? Double, 35.5)
    }

    func testGoogleParse() {
        let json = """
        {"places":[
          {"id":"p1","displayName":{"text":"見本ラーメン","languageCode":"ja"},"primaryType":"ramen_restaurant",
           "types":["ramen_restaurant","restaurant"],"location":{"latitude":35.0003,"longitude":139.0}},
          {"id":"p2","displayName":{"text":"見本駅"},"primaryType":"train_station","types":["train_station"],
           "location":{"latitude":35.0,"longitude":139.0}},
          {"id":"p3","primaryType":"cafe"}
        ]}
        """
        let out = GoogleNearby.parse(Data(json.utf8), latitude: 35.0, longitude: 139.0, now: now)
        XCTAssertEqual(out.count, 1, "駅と名前の無いものは除く")
        XCTAssertEqual(out.first?.id, "google:p1")
        XCTAssertEqual(out.first?.googleID, "p1")
        XCTAssertEqual(out.first?.kind, .food)
        XCTAssertEqual(out.first?.source, .google)
        XCTAssertEqual(out.first?.distance ?? 0, 33, accuracy: 3)
        XCTAssertTrue(GoogleNearby.parse(Data("not json".utf8), latitude: 35, longitude: 139, now: now).isEmpty)
    }

    func testShownName() {
        var v = ShopVisit(arrival: now, departure: now.addingTimeInterval(600), latitude: 35, longitude: 139, accuracy: 50)
        v.candidates = [cand("見本カフェ", .cafe, 10)]
        v.guessID = "apple:見本カフェ"
        v.state = .guessed
        XCTAssertEqual(v.shownName, "たぶん見本カフェ")
        v.state = .confirmed
        v.confirmedName = "見本カフェ"
        XCTAssertEqual(v.shownName, "見本カフェ")
        v.state = .notShop
        XCTAssertNil(v.shownName)
    }

    func testSavedVisitRoundTrip() throws {
        var v = ShopVisit(arrival: now, departure: nil, latitude: 35, longitude: 139, accuracy: 50)
        v.candidates = [cand("見本カフェ", .cafe, 10)]
        v.updated = now
        let data = try JSONEncoder().encode([v])
        let back = try JSONDecoder().decode([ShopVisit].self, from: data)
        XCTAssertEqual(back, [v])
    }
}

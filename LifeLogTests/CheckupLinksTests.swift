import CoreLocation
import MapKit
import XCTest
@testable import LifeLog

/// 1日1分の答え合わせ・名前なしの所・地図・ページどうしの行き来・会う前の行き先（2026-11-16。強化案 136・137・90・103・139・123・138）。
/// 名前はすべて作り物。
@MainActor
final class CheckupLinksTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    private func item(_ id: String, _ kind: String, _ weight: Double, source: String = "mothership") -> CheckupItem {
        var i = CheckupItem(id: id, kind: kind, title: "問 " + id, options: [CheckupOption(id: "yes", label: "はい")], weight: weight)
        i.source = source
        return i
    }

    // MARK: - 母艦の列を読む（136・137）

    func testDecodeKeepsGoodRowsAndDropsBad() throws {
        let json = """
        {"available": true, "generated_at": "2026-11-16T20:00:00+09:00", "items": [
          {"id": "q1", "kind": "place", "title": "ここは見本の店ですか", "detail": "11/15", "weight": 42.5,
           "options": [{"id": "yes", "label": "はい"}, {"id": "no", "label": "いいえ"}], "pl": "pl_1", "day": "2026-11-15"},
          {"id": "q2", "kind": "unknown_kind", "title": "知らない種類", "options": [{"id": "a", "label": "a"}]},
          {"id": "q3", "kind": "person", "title": "選べる答えが無い", "options": []},
          {"id": "q4", "kind": "link", "title": "文字で答える", "text": true, "source": "night", "pe": "pe_9"},
          {"id": "bad id", "kind": "place", "title": "idが不正", "options": [{"id": "a", "label": "a"}]},
          {"id": "q1", "kind": "place", "title": "重複", "options": [{"id": "a", "label": "a"}]},
          "壊れた行"
        ]}
        """
        let feed = try XCTUnwrap(CheckupRules.decode(Data(json.utf8)))
        XCTAssertEqual(feed.items.map { $0.id }, ["q1", "q4"])
        XCTAssertEqual(feed.items[0].weight, 42.5, accuracy: 0.001)
        XCTAssertEqual(feed.items[0].pl, "pl_1")
        XCTAssertEqual(feed.items[0].source, "mothership")
        XCTAssertEqual(feed.items[1].source, "night")
        XCTAssertTrue(feed.items[1].allowText)
        XCTAssertEqual(feed.items[1].pe, "pe_9")
    }

    func testDecodeDefaultSourceAndUnavailable() throws {
        let json = #"{"items": [{"id": "n1", "kind": "link", "title": "繋がり", "options": [{"id": "ok", "label": "合う"}]}]}"#
        let night = try XCTUnwrap(CheckupRules.decode(Data(json.utf8), defaultSource: "night"))
        XCTAssertEqual(night.items.first?.source, "night")
        XCTAssertNil(CheckupRules.decode(Data(#"{"available": false, "items": []}"#.utf8)))
        XCTAssertNil(CheckupRules.decode(Data("[]".utf8)))
    }

    func testCheckupFeedRoundTrips() throws {
        let feed = CheckupFeed(generated_at: nil, items: [item("a", "place", 3)])
        let back = try JSONDecoder().decode(CheckupFeed.self, from: JSONEncoder().encode(feed))
        XCTAssertEqual(back, feed)
    }

    // MARK: - 列（効き目の大きい順に 5 問まで）

    func testQueueSortsByWeightAndLimits() {
        var items: [CheckupItem] = []
        let kinds = ["place", "person", "misheard", "link"]
        for i in 0..<8 { items.append(item("i\(i)", kinds[i % 4], Double(i))) }
        let out = CheckupRules.queue(items, answered: [], hidden: [], remaining: 5)
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.first?.id, "i7")
        let weights = out.map { $0.weight }
        XCTAssertEqual(weights, weights.sorted(by: >))
    }

    func testQueueSkipsAnsweredAndHiddenAndCapsPerKind() {
        var items: [CheckupItem] = []
        for i in 0..<6 { items.append(item("p\(i)", "place", Double(100 - i))) }
        items.append(item("m0", "misheard", 1))
        let out = CheckupRules.queue(items, answered: ["p0"], hidden: ["p1"], remaining: 5)
        // 場所は 3 問まで（p2・p3・p4）、そのあとに聞き間違い
        XCTAssertEqual(out.map { $0.id }, ["p2", "p3", "p4", "m0"])
    }

    func testQueueRespectsRemainingAndDuplicates() {
        let items = [item("a", "place", 5), item("a", "place", 9), item("b", "person", 4)]
        XCTAssertEqual(CheckupRules.queue(items, answered: [], hidden: [], remaining: 0), [])
        XCTAssertEqual(CheckupRules.queue(items, answered: [], hidden: [], remaining: 1).count, 1)
        XCTAssertEqual(CheckupRules.queue(items, answered: [], hidden: [], remaining: 9).count, 2)
    }

    func testRemainingToday() {
        var saved: [String: Int] = [:]
        XCTAssertEqual(CheckupRules.remaining(saved: saved, day: "2026-11-16"), 5)
        for _ in 0..<3 { saved = PlaceAssistRules.bumped(saved, kind: "done", day: "2026-11-16") }
        XCTAssertEqual(CheckupRules.remaining(saved: saved, day: "2026-11-16"), 2)
        XCTAssertEqual(CheckupRules.remaining(saved: saved, day: "2026-11-17"), 5)
    }

    func testHiddenLasts() {
        XCTAssertTrue(CheckupRules.isHidden(id: "a", hiddenDay: "2026-11-16", today: "2026-11-16"))
        XCTAssertFalse(CheckupRules.isHidden(id: "a", hiddenDay: "2026-11-15", today: "2026-11-16"))
        XCTAssertFalse(CheckupRules.isHidden(id: "a", hiddenDay: nil, today: "2026-11-16"))
        // 名前なしのまとめは、その週のあいだ
        XCTAssertTrue(CheckupRules.isHidden(id: "unnamed:2026-11-15", hiddenDay: "2026-11-12", today: "2026-11-16"))
    }

    // MARK: - 答えの形

    func testAnswerBody() throws {
        var i = item("q1", "place", 1)
        i.options = [CheckupOption(id: "yes", label: "はい")]
        i.pl = "pl_1"
        let data = try XCTUnwrap(CheckupRules.answerBody(item: i, value: "yes", text: nil, day: "2026-11-16"))
        let body = try JSONDecoder().decode(CheckupRules.AnswerBody.self, from: data)
        XCTAssertEqual(body.id, "q1")
        XCTAssertEqual(body.value, "yes")
        XCTAssertEqual(body.pl, "pl_1")
        XCTAssertNil(body.text)
        XCTAssertNotNil(CheckupRules.answerBody(item: i, value: "skip", text: nil, day: "2026-11-16"))
        // 選べる答えに無いもの・日が不正・文字の欄が無いのに文字
        XCTAssertNil(CheckupRules.answerBody(item: i, value: "maybe", text: nil, day: "2026-11-16"))
        XCTAssertNil(CheckupRules.answerBody(item: i, value: "yes", text: nil, day: "11/16"))
        XCTAssertNil(CheckupRules.answerBody(item: i, value: "text", text: "名前", day: "2026-11-16"))
        i.allowText = true
        let typed = try XCTUnwrap(CheckupRules.answerBody(item: i, value: "text", text: " 見本の店 ", day: "2026-11-16"))
        XCTAssertEqual(try JSONDecoder().decode(CheckupRules.AnswerBody.self, from: typed).text, "見本の店")
        XCTAssertNil(CheckupRules.answerBody(item: i, value: "text", text: "   ", day: "2026-11-16"))
    }

    func testAnswerPathNeedsCheckupsFeature() {
        XCTAssertEqual(MothershipOutbox.feature(for: "checkups/answer"), "checkups")
    }

    // MARK: - アプリの中の推測から作る

    private func visit(state: ShopVisit.State, names: [String]) -> ShopVisit {
        var v = ShopVisit(arrival: t0, departure: t0.addingTimeInterval(45 * 60), latitude: 35.0, longitude: 139.0, accuracy: 30)
        var list: [ShopCandidate] = []
        for (i, n) in names.enumerated() {
            list.append(ShopCandidate(id: "apple:\(i)", source: .apple, name: n, kind: .cafe, distance: Double(10 + i * 5), fetched: t0,
                                      score: 1.0 - Double(i) * 0.1))
        }
        v.candidates = list
        v.guessID = list.first?.id
        v.state = state
        return v
    }

    func testPlaceItemFromGuessedVisit() throws {
        let v = visit(state: .guessed, names: ["見本カフェ", "見本パン", "見本書房", "見本薬局"])
        let i = try XCTUnwrap(CheckupRules.placeItem(v))
        XCTAssertEqual(i.kind, "place")
        XCTAssertEqual(i.id, "shop:" + v.id)
        XCTAssertTrue(i.title.contains("見本カフェ"))
        // 合っている・ほかの候補 2 つ・お店ではない
        XCTAssertEqual(i.options.map { $0.id }, ["yes", "c0", "c1", "no"])
        XCTAssertEqual(i.options[1].label, "見本パン")
        XCTAssertEqual(i.weight, 45 + 30, accuracy: 0.001)  // 45 分・点数の差が小さい（はっきりしない）
    }

    func testPlaceItemOnlyForGuessed() {
        XCTAssertNil(CheckupRules.placeItem(visit(state: .confirmed, names: ["見本カフェ"])))
        XCTAssertNil(CheckupRules.placeItem(visit(state: .waiting, names: [])))
        XCTAssertNil(CheckupRules.placeItem(visit(state: .notShop, names: ["見本カフェ"])))
    }

    func testUnnamedItem() throws {
        let stays = [UnnamedStay(arrival: t0, departure: t0.addingTimeInterval(40 * 60), latitude: 35, longitude: 139, accuracy: 20),
                     UnnamedStay(arrival: t0, departure: t0.addingTimeInterval(90 * 60), latitude: 36, longitude: 139, accuracy: 20)]
        let i = try XCTUnwrap(CheckupRules.unnamedItem(stays: stays, now: t0))
        XCTAssertEqual(i.kind, "place_unnamed")
        XCTAssertTrue(i.id.hasPrefix("unnamed:"))
        XCTAssertTrue(i.title.contains("2 か所"))
        XCTAssertEqual(i.weight, 130, accuracy: 0.001)
        XCTAssertNil(CheckupRules.unnamedItem(stays: [], now: t0))
    }

    // MARK: - 名前なしの所（90）

    func testStayQualifies() {
        XCTAssertTrue(UnnamedStayRules.qualifies(arrival: t0, departure: t0.addingTimeInterval(30 * 60)))
        XCTAssertFalse(UnnamedStayRules.qualifies(arrival: t0, departure: t0.addingTimeInterval(29 * 60)))
        XCTAssertFalse(UnnamedStayRules.qualifies(arrival: t0, departure: t0.addingTimeInterval(21 * 3600)))
    }

    func testStayPrunedAndRecentAndNearby() {
        let old = UnnamedStay(arrival: t0.addingTimeInterval(-20 * 86400), departure: t0.addingTimeInterval(-20 * 86400 + 3600),
                              latitude: 35, longitude: 139, accuracy: 10)
        let fresh = UnnamedStay(arrival: t0.addingTimeInterval(-3600), departure: t0, latitude: 35.0005, longitude: 139, accuracy: 10)
        let far = UnnamedStay(arrival: t0.addingTimeInterval(-7200), departure: t0.addingTimeInterval(-3600), latitude: 36, longitude: 139,
                              accuracy: 10)
        let kept = UnnamedStayRules.pruned([old, fresh, far], now: t0)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(UnnamedStayRules.recent(kept, now: t0).first?.id, fresh.id)
        XCTAssertEqual(UnnamedStayRules.nearby(kept, latitude: 35, longitude: 139).map { $0.id }, [fresh.id])
    }

    func testWeekStartIsSameWithinWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let sunday = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9)) ?? t0
        let friday = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9)) ?? t0
        let nextSunday = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9)) ?? t0
        XCTAssertEqual(UnnamedStayRules.weekStart(sunday, calendar: cal), "2026-11-15")
        XCTAssertEqual(UnnamedStayRules.weekStart(friday, calendar: cal), "2026-11-15")
        XCTAssertEqual(UnnamedStayRules.weekStart(nextSunday, calendar: cal), "2026-11-22")
    }

    func testStayRoundTrips() throws {
        let stay = UnnamedStay(arrival: t0, departure: t0.addingTimeInterval(3600), latitude: 35, longitude: 139, accuracy: 10)
        let back = try JSONDecoder().decode([UnnamedStay].self, from: JSONEncoder().encode([stay]))
        XCTAssertEqual(back, [stay])
    }

    // MARK: - 地図（103）

    func testMapWindow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15)) ?? t0
        let today = MapRules.window(offset: 0, now: now, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: today.from), 0)
        XCTAssertEqual(today.to.timeIntervalSince(today.from), 86400, accuracy: 1)
        let yesterday = MapRules.window(offset: 1, now: now, calendar: cal)
        XCTAssertEqual(yesterday.to, today.from)
    }

    func testThinnedKeepsEndsAndDropsNear() {
        let coords = [CLLocationCoordinate2D(latitude: 35.0, longitude: 139.0), CLLocationCoordinate2D(latitude: 35.00005, longitude: 139.0),
                      CLLocationCoordinate2D(latitude: 35.01, longitude: 139.0), CLLocationCoordinate2D(latitude: 35.01005, longitude: 139.0)]
        let out = MapRules.thinned(coords)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.last?.latitude ?? 0, 35.01005, accuracy: 0.0000001)
        XCTAssertTrue(MapRules.thinned([]).isEmpty)
    }

    func testMapRectCoversPointsAndHasMinimumSize() throws {
        XCTAssertNil(MapRules.rect(for: []))
        let one = try XCTUnwrap(MapRules.rect(for: [CLLocationCoordinate2D(latitude: 35, longitude: 139)]))
        XCTAssertGreaterThan(one.width, 0)
        let two = try XCTUnwrap(MapRules.rect(for: [CLLocationCoordinate2D(latitude: 35, longitude: 139),
                                                    CLLocationCoordinate2D(latitude: 35.1, longitude: 139.1)]))
        XCTAssertTrue(two.contains(MKMapPoint(CLLocationCoordinate2D(latitude: 35.05, longitude: 139.05))))
    }

    func testMomentWindow() {
        let span = MapRules.moment(from: t0, to: t0.addingTimeInterval(600))
        XCTAssertEqual(span.lo, t0.addingTimeInterval(-600))
        XCTAssertEqual(span.hi, t0.addingTimeInterval(1200))
        let reversed = MapRules.moment(from: t0, to: t0.addingTimeInterval(-100))
        XCTAssertEqual(reversed.hi, t0.addingTimeInterval(600))
    }

    // MARK: - 行き来（139・123）

    func testRefMatches() {
        let refs = [PageRef(id: "pe_1", name: "見本 花子"), PageRef(id: nil, name: "架空 太郎")]
        XCTAssertTrue(PagesFeeds.refMatches(refs, id: "pe_1", name: "別の名前"))
        XCTAssertTrue(PagesFeeds.refMatches(refs, id: "pe_9", name: "架空太郎"))
        // 番号がある行は、番号が違えば名前が同じでも別の人
        XCTAssertFalse(PagesFeeds.refMatches(refs, id: "pe_9", name: "見本花子"))
        XCTAssertFalse(PagesFeeds.refMatches(nil, id: "pe_1", name: "見本 花子"))
    }

    func testVisitSpan() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let span = try XCTUnwrap(PagesFeeds.visitSpan(day: "2026-11-15", time: "10:30–11:45", calendar: cal))
        XCTAssertEqual(span.to.timeIntervalSince(span.from), 75 * 60, accuracy: 1)
        XCTAssertEqual(cal.component(.hour, from: span.from), 10)
        // 日をまたぐ
        let night = try XCTUnwrap(PagesFeeds.visitSpan(day: "2026-11-15", time: "23:30–00:20", calendar: cal))
        XCTAssertEqual(night.to.timeIntervalSince(night.from), 50 * 60, accuracy: 1)
        XCTAssertNil(PagesFeeds.visitSpan(day: "11/15", time: "10:30–11:45", calendar: cal))
        XCTAssertNil(PagesFeeds.visitSpan(day: "2026-11-15", time: "午前", calendar: cal))
    }

    func testPlacePageDecodesPeopleRefsAndStaysReadable() throws {
        let json = """
        {"items": [{"id": "pl_1", "name": "見本の店", "sure": true, "visit_days": 2, "visits": 3, "last_day": "2026-11-14",
          "with": ["架空 太郎"], "people": [{"id": "pe_1", "name": "架空 太郎"}, {"name": "見本 花子"}, 7],
          "recent": [{"day": "2026-11-14", "time": "10:00–11:00"}]}]}
        """
        let feed = try XCTUnwrap(PagesFeeds.decodePlaces(Data(json.utf8)))
        let page = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(page.people?.count, 2)
        XCTAssertEqual(page.people?.first?.id, "pe_1")
        XCTAssertNil(page.people?.last?.id)
        // 番号の無い前の形は、そのまま読める
        let old = """
        {"items": [{"id": "pl_2", "name": "見本の駅", "visit_days": 1, "visits": 1, "last_day": "2026-11-13"}]}
        """
        let oldPage = try XCTUnwrap(PagesFeeds.decodePlaces(Data(old.utf8))?.items.first)
        XCTAssertNil(oldPage.people)
        // 端末に残した写し（前の版が書いたもの）は、新しい項目が無くても読める
        let cached = #"{"id":"pl_3","name":"見本","sure":false,"visit_days":1,"visits":1,"last_day":"2026-11-13","with":[],"recent":[]}"#
        XCTAssertNotNil(try? JSONDecoder().decode(PlacePage.self, from: Data(cached.utf8)))
    }

    func testThreadDecodesPeopleAndPlaces() throws {
        let json = """
        {"items": [{"id": "th_1", "title": "見本の案件", "kind": "work", "status": "open", "days": ["2026-11-14"],
          "people": [{"id": "pe_1", "name": "架空 太郎"}], "places": [{"id": "pl_1", "name": "見本の店"}]}]}
        """
        let thread = try XCTUnwrap(PagesFeeds.decodeThreads(Data(json.utf8))?.items.first)
        XCTAssertEqual(thread.people?.first?.id, "pe_1")
        XCTAssertEqual(thread.places?.first?.name, "見本の店")
        let cached = #"{"id":"th_2","title":"見本","kind":"work","status":"open","decided":[],"open":[],"next":"","days":["2026-11-14"],"last_day":"2026-11-14","source":"machine"}"#
        let old = try JSONDecoder().decode(ThreadPage.self, from: Data(cached.utf8))
        XCTAssertNil(old.people)
        XCTAssertNil(old.places)
    }

    func testPersonPageDecodesPlacesAndOldCache() throws {
        let json = """
        {"items": [{"id": "pe_1", "name": "架空 太郎", "places": [{"id": "pl_1", "name": "見本の店"}]}]}
        """
        let page = try XCTUnwrap(PagesFeeds.decodePeople(Data(json.utf8))?.items.first)
        XCTAssertEqual(page.places?.first?.id, "pl_1")
        let cached = #"{"id":"pe_2","name":"見本","group":"","aliases":[],"line_7d":0,"line_30d":0,"talks_30d":0,"topics":[],"promises":[],"likes":[],"next_line":"","next_why":""}"#
        XCTAssertNil(try JSONDecoder().decode(PersonPage.self, from: Data(cached.utf8)).places)
    }

    // MARK: - 会う前の行き先（138）

    func testPrepWhereUsesSameTitleAndMatchesPlace() throws {
        var page = PlacePage(id: "pl_1", name: "見本ビル", sure: true, visit_days: 2, visits: 3, last_day: "2026-11-10")
        page.with = []
        let rows: [(title: String, location: String?)] = [(title: "別の予定", location: "別の所"), (title: "打ち合わせ", location: " 見本ビル 3階 ")]
        let info = try XCTUnwrap(PrepWhereRules.make(title: "打ち合わせ", locations: rows, places: [page]))
        XCTAssertEqual(info.location, "見本ビル 3階")
        XCTAssertEqual(info.placeID, "pl_1")
        XCTAssertEqual(info.lastDay, "2026-11-10")
        XCTAssertEqual(info.visits, 3)
        XCTAssertNotNil(info.mapURL)
    }

    func testPrepWhereWithoutLocationOrMatch() throws {
        XCTAssertNil(PrepWhereRules.make(title: "予定", locations: [(title: "予定", location: nil), (title: "予定", location: "  ")], places: []))
        let info = try XCTUnwrap(PrepWhereRules.make(title: "予定", locations: [(title: "予定", location: "どこかの所")], places: []))
        XCTAssertNil(info.placeID)
        XCTAssertNil(info.lastDay)
        XCTAssertEqual(info.visits, 0)
    }

    func testPrepWhereDoesNotGuessBetweenTwoPlaces() {
        let a = PlacePage(id: "pl_1", name: "見本ビル", sure: true, visit_days: 1, visits: 1, last_day: "2026-11-10")
        let b = PlacePage(id: "pl_2", name: "見本ビル別館", sure: true, visit_days: 1, visits: 1, last_day: "2026-11-11")
        XCTAssertNil(PrepWhereRules.matchPlace("見本ビル別館 2階 見本ビル", in: [a, b]))
        XCTAssertEqual(PrepWhereRules.matchPlace("見本ビル 2階", in: [a])?.id, "pl_1")
    }
}

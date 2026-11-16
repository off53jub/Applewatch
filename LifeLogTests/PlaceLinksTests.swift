import CoreLocation
import XCTest
@testable import LifeLog

/// 場所の名前の直し・着いたときの決まり（2026-11-16。強化案 88・89・91・104）。名前はすべて作り物。
@MainActor
final class PlaceLinksTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    private func fix(_ name: String, _ lat: Double, _ lon: Double, pl: String? = nil) -> PlaceNameFix {
        PlaceNameFix(name: name, latitude: lat, longitude: lon, placeID: pl, at: t0, source: "app")
    }

    // MARK: - 名前の直し（89）

    func testCleanName() {
        XCTAssertEqual(PlaceNameRules.clean("  見本カフェ  "), "見本カフェ")
        XCTAssertEqual(PlaceNameRules.clean("たぶん見本カフェ"), "見本カフェ")
        XCTAssertNil(PlaceNameRules.clean("   "))
        XCTAssertNil(PlaceNameRules.clean("たぶん"))
        XCTAssertEqual(PlaceNameRules.clean(String(repeating: "あ", count: 80))?.count, PlaceNameRules.nameLimit)
    }

    func testNearestUsesRadiusAndAccuracy() {
        let list = [fix("見本の店", 35.0, 139.0)]
        // 約 60 m 離れている（北へ 0.00054 度）
        XCTAssertEqual(PlaceNameRules.nearest(list, latitude: 35.00054, longitude: 139.0, accuracy: 10)?.name, "見本の店")
        // 約 300 m 離れている → 範囲の外
        XCTAssertNil(PlaceNameRules.nearest(list, latitude: 35.0027, longitude: 139.0, accuracy: 10))
        // 精度が粗ければ、その分だけ広げる（100 m まで。約 200 m 離れていて精度 100 m なら入る）
        XCTAssertNotNil(PlaceNameRules.nearest(list, latitude: 35.0018, longitude: 139.0, accuracy: 100))
    }

    func testNearestPicksClosest() {
        let list = [fix("遠い店", 35.0008, 139.0), fix("近い店", 35.0001, 139.0)]
        XCTAssertEqual(PlaceNameRules.nearest(list, latitude: 35.0, longitude: 139.0, accuracy: 0)?.name, "近い店")
    }

    func testAddingReplacesSameSpotAndSamePlaceID() {
        var list = PlaceNameRules.adding([], fix("前の名前", 35.0, 139.0))
        list = PlaceNameRules.adding(list, fix("直した名前", 35.00005, 139.0))
        XCTAssertEqual(list.map { $0.name }, ["直した名前"])
        list = PlaceNameRules.adding(list, fix("別の所", 35.01, 139.0, pl: "pl_a"))
        list = PlaceNameRules.adding(list, fix("別の所の直し", 35.02, 139.0, pl: "pl_a"))
        XCTAssertEqual(list.map { $0.name }, ["直した名前", "別の所の直し"])
    }

    func testAddingKeepsLimit() {
        var list: [PlaceNameFix] = []
        for i in 0..<7 { list = PlaceNameRules.adding(list, fix("店\(i)", 35.0 + Double(i) * 0.01, 139.0), limit: 5) }
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list.first?.name, "店2")
    }

    func testShownPageName() {
        XCTAssertEqual(PlaceNameRules.shown(pageID: "pl_1", original: "元の名前", pageNames: ["pl_1": "直した名前"]), "直した名前")
        XCTAssertEqual(PlaceNameRules.shown(pageID: "pl_2", original: "元の名前", pageNames: ["pl_1": "直した名前"]), "元の名前")
    }

    func testBodyShape() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let data = try XCTUnwrap(PlaceNameRules.body(name: " 見本の店 ", latitude: 35.1234567, longitude: 139.7654321, placeID: "pl_x",
                                                      source: "conversation", at: t0, timeZone: zone))
        let body = try JSONDecoder().decode(PlaceNameRules.Body.self, from: data)
        XCTAssertEqual(body.name, "見本の店")
        XCTAssertEqual(body.lat ?? 0, 35.12346, accuracy: 0.000001)
        XCTAssertEqual(body.lon ?? 0, 139.76543, accuracy: 0.000001)
        XCTAssertEqual(body.pl, "pl_x")
        XCTAssertEqual(body.from, "conversation")
        XCTAssertTrue(body.at.hasSuffix("+09:00"))
        XCTAssertEqual(body.day.count, 10)
    }

    func testBodyWithoutPositionAndUnknownSource() throws {
        let data = try XCTUnwrap(PlaceNameRules.body(name: "見本", latitude: nil, longitude: nil, placeID: "", source: "x", at: t0))
        let body = try JSONDecoder().decode(PlaceNameRules.Body.self, from: data)
        XCTAssertNil(body.lat)
        XCTAssertNil(body.lon)
        XCTAssertNil(body.pl)
        XCTAssertEqual(body.from, "app")
        XCTAssertNil(PlaceNameRules.body(name: "  ", latitude: 1, longitude: 2, placeID: nil, source: "app", at: t0))
    }

    func testOutboxPathNeedsPlaceNamesFeature() {
        XCTAssertEqual(MothershipOutbox.feature(for: "place-names"), "placenames")
    }

    // MARK: - 古いデータを読める

    func testOldPlaceJSONStillDecodes() throws {
        let old = #"[{"id":"7B5B1C34-0000-4000-8000-000000000001","name":"見本の家","latitude":35.0,"longitude":139.0,"radius":300}]"#
        let list = try JSONDecoder().decode([PlaceLog.Place].self, from: Data(old.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].isWork)
        XCTAssertNil(list[0].pausesRecording)
    }

    func testSavedFixesTolerateMissingKeys() throws {
        let empty = try JSONDecoder().decode(PlaceNameSaved.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, PlaceNameSaved())
        let only = try JSONDecoder().decode(PlaceNameSaved.self, from: Data(#"{"pageNames":{"pl_1":"見本"}}"#.utf8))
        XCTAssertEqual(only.pageNames["pl_1"], "見本")
        XCTAssertTrue(only.fixes.isEmpty)
    }

    func testSavedFixesRoundTrip() throws {
        let saved = PlaceNameSaved(fixes: [fix("見本", 35.0, 139.0, pl: "pl_1")], pageNames: ["pl_1": "見本"])
        let back = try JSONDecoder().decode(PlaceNameSaved.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.fixes.first?.name, "見本")
        XCTAssertEqual(back.fixes.first?.placeID, "pl_1")
    }

    // MARK: - 立ち寄りを受けるか（88・91・104）

    func testWantsVisits() {
        XCTAssertTrue(PlaceLog.wantsVisits(shopOn: true, locationOn: false, arrival: false, ask: false, remind: false))
        XCTAssertTrue(PlaceLog.wantsVisits(shopOn: false, locationOn: true, arrival: true, ask: false, remind: false))
        XCTAssertTrue(PlaceLog.wantsVisits(shopOn: false, locationOn: true, arrival: false, ask: true, remind: false))
        XCTAssertFalse(PlaceLog.wantsVisits(shopOn: false, locationOn: false, arrival: true, ask: true, remind: true))
        XCTAssertFalse(PlaceLog.wantsVisits(shopOn: false, locationOn: true, arrival: false, ask: false, remind: false))
    }

    // MARK: - 30 分いたら聞く（91）

    func testFireDate() {
        XCTAssertEqual(PlaceAssistRules.fireDate(arrival: t0, now: t0.addingTimeInterval(600)), t0.addingTimeInterval(1800))
        // もう 30 分過ぎていれば 1 分後
        XCTAssertEqual(PlaceAssistRules.fireDate(arrival: t0, now: t0.addingTimeInterval(3000)), t0.addingTimeInterval(3060))
    }

    func testShouldAsk() {
        XCTAssertTrue(PlaceAssistRules.shouldAsk(on: true, known: false, meeting: false, askedToday: 2))
        XCTAssertFalse(PlaceAssistRules.shouldAsk(on: false, known: false, meeting: false, askedToday: 0))
        XCTAssertFalse(PlaceAssistRules.shouldAsk(on: true, known: true, meeting: false, askedToday: 0))
        XCTAssertFalse(PlaceAssistRules.shouldAsk(on: true, known: false, meeting: true, askedToday: 0))
        XCTAssertFalse(PlaceAssistRules.shouldAsk(on: true, known: false, meeting: false, askedToday: PlaceAssistRules.askDailyCap))
    }

    func testCandidatesDedupeAndLimit() {
        let list = PlaceAssistRules.candidates(fixed: ["見本カフェ"], shop: ["見本パン", "見本カフェ"], nearby: ["見本書房", "見本薬局"],
                                               area: "見本駅近く")
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0], "見本カフェ")
        XCTAssertEqual(Set(list).count, 3)
        XCTAssertEqual(PlaceAssistRules.candidates(fixed: [], shop: [], nearby: [], area: nil), [])
        XCTAssertEqual(PlaceAssistRules.candidates(fixed: [], shop: [], nearby: [], area: "見本付近"), ["見本付近"])
    }

    func testActionIndex() {
        XCTAssertEqual(PlaceAssistRules.index(of: "ask0"), 0)
        XCTAssertEqual(PlaceAssistRules.index(of: "ask2"), 2)
        XCTAssertNil(PlaceAssistRules.index(of: "ask3"))
        XCTAssertNil(PlaceAssistRules.index(of: "keep"))
        XCTAssertEqual(PlaceAssistRules.actionID(1), "ask1")
    }

    func testDailyCounts() {
        var saved: [String: Int] = [:]
        saved = PlaceAssistRules.bumped(saved, kind: "ask", day: "2026-11-16")
        saved = PlaceAssistRules.bumped(saved, kind: "ask", day: "2026-11-16")
        XCTAssertEqual(PlaceAssistRules.count(saved, kind: "ask", day: "2026-11-16"), 2)
        XCTAssertEqual(PlaceAssistRules.count(saved, kind: "remind", day: "2026-11-16"), 0)
        // 日が変わったら、前の日の分は残さない
        saved = PlaceAssistRules.bumped(saved, kind: "ask", day: "2026-11-17")
        XCTAssertEqual(PlaceAssistRules.count(saved, kind: "ask", day: "2026-11-17"), 1)
        XCTAssertEqual(PlaceAssistRules.count(saved, kind: "ask", day: "2026-11-16"), 0)
    }

    // MARK: - 着いたら知らせる（104）

    private func task(_ what: String, from: String? = nil, state: TaskBook.State = .open) -> TaskBook.Item {
        TaskBook.Item(what: what, from: from, said: t0, source: .manual, state: state)
    }

    func testMatchTasksByPlaceName() {
        let tasks = [task("見本ストアで牛乳を買う"), task("見本書房で本を受け取る"), task("見本ストアで洗剤を買う", state: .done)]
        let hit = PlaceAssistRules.matchTasks(placeNames: ["見本ストア"], companions: [], tasks: tasks)
        XCTAssertEqual(hit.map { $0.what }, ["見本ストアで牛乳を買う"])
    }

    func testMatchTasksByCompanion() {
        let tasks = [task("資料を渡す", from: "架空 太郎"), task("別の件", from: "架空 花子")]
        let hit = PlaceAssistRules.matchTasks(placeNames: ["見本"], companions: ["架空太郎"], tasks: tasks)
        XCTAssertEqual(hit.map { $0.what }, ["資料を渡す"])
    }

    func testMatchTasksIgnoresShortNamesAndLimits() {
        var short: [TaskBook.Item] = []
        for i in 0..<6 { short.append(task("あ\(i)")) }
        XCTAssertTrue(PlaceAssistRules.matchTasks(placeNames: ["あ"], companions: [], tasks: short).isEmpty)
        var many: [TaskBook.Item] = []
        for i in 0..<6 { many.append(task("見本ストアで\(i)")) }
        XCTAssertEqual(PlaceAssistRules.matchTasks(placeNames: ["見本ストア"], companions: [], tasks: many).count, 3)
    }

    func testRemindBodyCutsLongText() {
        let body = PlaceAssistRules.remindBody([task(String(repeating: "あ", count: 60)), task("短い")])
        let lines = body.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("…"))
        XCTAssertEqual(lines[1], "・短い")
    }

    func testRemindKeyIsPerDayPerPlace() {
        XCTAssertEqual(PlaceAssistRules.remindKey(day: "2026-11-16", place: "見本ストア"),
                       PlaceAssistRules.remindKey(day: "2026-11-16", place: "見本 ストア"))
        XCTAssertNotEqual(PlaceAssistRules.remindKey(day: "2026-11-16", place: "見本ストア"),
                          PlaceAssistRules.remindKey(day: "2026-11-17", place: "見本ストア"))
    }
}

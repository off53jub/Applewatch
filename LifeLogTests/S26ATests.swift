import XCTest
@testable import LifeLog

/// s26 の A1（S26ARules.swift・HealthExport.swift）: 集1・集2・集3（K1）・K2 の合図・集4・集10・集13・集16・聞10・聞12・聞16・
/// 軽8・結3・結5・結9（K3）
final class S26ATests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    private func object(_ data: Data?) -> [String: Any] {
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }

    // MARK: 集1・集2・集3 体の記録（K1）

    func testBodyMetricsUseHealthAutoExportNames() {
        var d = HealthExport.Day(day: "2026-11-24")
        d.weightKg = 63.456
        d.bodyFatPercent = 18.24
        d.bmi = 21.7
        d.respiratoryRate = 14.2
        d.oxygenPercent = 97.5
        d.wristTempC = 35.123
        d.vo2Max = 41.3
        d.flights = 12
        d.daylightMinutes = 34
        d.environmentDB = 62.4
        d.headphoneDB = 70.1
        d.coughs = 3
        d.snoreMinutes = 12.5
        XCTAssertFalse(d.isEmpty)
        let o = object(HealthExport.json(d, calendar: cal))
        let metrics = ((o["data"] as? [String: Any])?["metrics"] as? [[String: Any]]) ?? []
        var units: [String: String] = [:]
        var qty: [String: Double] = [:]
        for m in metrics {
            guard let name = m["name"] as? String else { continue }
            units[name] = m["units"] as? String
            qty[name] = ((m["data"] as? [[String: Any]])?.first?["qty"] as? NSNumber)?.doubleValue
        }
        XCTAssertEqual(units["weight_body_mass"], "kg")
        XCTAssertEqual(qty["weight_body_mass"], 63.46)
        XCTAssertEqual(units["body_fat_percentage"], "%")
        XCTAssertEqual(qty["body_fat_percentage"], 18.2)
        XCTAssertEqual(units["body_mass_index"], "count")
        XCTAssertEqual(units["respiratory_rate"], "count/min")
        XCTAssertEqual(units["blood_oxygen_saturation"], "%")
        XCTAssertEqual(units["apple_sleeping_wrist_temperature"], "degC")
        XCTAssertEqual(qty["apple_sleeping_wrist_temperature"], 35.12)
        XCTAssertEqual(units["vo2_max"], "ml/(kg·min)")
        XCTAssertEqual(units["flights_climbed"], "count")
        XCTAssertEqual(units["time_in_daylight"], "min")
        XCTAssertEqual(units["environmental_audio_exposure"], "dBASPL")
        XCTAssertEqual(units["headphone_audio_exposure"], "dBASPL")
        XCTAssertEqual(qty["lifelog_cough_count"], 3)
        XCTAssertEqual(units["lifelog_snore_minutes"], "min")
    }

    func testWeightOnlyDayIsWrittenAndMissingValuesAreSkipped() {
        var d = HealthExport.Day(day: "2026-11-24")
        XCTAssertTrue(d.isEmpty)
        d.weightKg = 60
        XCTAssertFalse(d.isEmpty)
        let names = HealthExport.bodyMetrics(d, date: "x").compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["weight_body_mass"])
        d.coughs = 0
        d.flights = 0
        XCTAssertEqual(HealthExport.bodyMetrics(d, date: "x").count, 1)
    }

    func testCoughAndSnoreCounting() {
        XCTAssertEqual(S26ABodySoundRules.kind("cough"), "cough")
        XCTAssertEqual(S26ABodySoundRules.kind("snoring"), "snore")
        XCTAssertNil(S26ABodySoundRules.kind("speech"))
        // 半分重なった窓は 1 回のせき。離れていれば 2 回
        XCTAssertEqual(S26ABodySoundRules.coughCount([(0, 1), (0.5, 1.5), (5, 6)]), 2)
        // いびきは 5 秒より短いかたまりは数えない
        var snores: [(start: Double, end: Double)] = []
        for i in 0..<60 {
            let s: Double = Double(i)
            snores.append((start: s, end: s + 1.0))
        }
        snores.append((start: 100.0, end: 102.0))
        XCTAssertEqual(S26ABodySoundRules.snoreMinutes(snores), 1.0, accuracy: 0.02)
        // 23 時のいびきは次の日、3 時はその日
        XCTAssertEqual(S26ABodySoundRules.snoreDay(at(24, 23), calendar: cal), "2026-11-25")
        XCTAssertEqual(S26ABodySoundRules.snoreDay(at(25, 3), calendar: cal), "2026-11-25")
    }

    // MARK: K2 端末の合図

    func testSignalsJSONShapeAndOmittedKeys() {
        var s = S26ADaySignals()
        XCTAssertTrue(s.isEmpty)
        s.songs = [S26ASong(at: at(24, 20), title: "見本の曲", artist: nil, source: "heard")]
        s.charge = [S26ACharge(at: at(24, 23), state: "plugged")]
        s.floors = [S26AFloor(at: at(24, 9), delta: -2)]
        s.meals = [S26AMeal(at: at(24, 12), lat: 35.123456, lon: nil)]
        let o = object(S26ASignals.json(day: "2026-11-24", s, calendar: cal))
        XCTAssertEqual(o["version"] as? Int, 1)
        XCTAssertEqual(o["day"] as? String, "2026-11-24")
        XCTAssertNil(o["first_use"])
        XCTAssertNil(o["focus"])
        XCTAssertNil(o["screen_time"])
        let song = (o["songs"] as? [[String: Any]])?.first
        XCTAssertTrue(song?["artist"] is NSNull)
        XCTAssertEqual(song?["source"] as? String, "heard")
        XCTAssertEqual(song?["at"] as? String, "2026-11-24T20:00:00+09:00")
        XCTAssertEqual((o["floors"] as? [[String: Any]])?.first?["delta"] as? Int, -2)
        let meal = (o["meals"] as? [[String: Any]])?.first
        XCTAssertEqual(meal?["lat"] as? Double, 35.1235)
        XCTAssertTrue(meal?["lon"] is NSNull)
        XCTAssertEqual(S26ASignals.fileName("2026-11-24"), "lifelog-signals-2026-11-24.json")
    }

    func testSignalsDecodeOldFileWithMissingKeys() throws {
        let data = Data(#"{"charge":[]}"#.utf8)
        let s = try JSONDecoder().decode(S26ADaySignals.self, from: data)
        XCTAssertTrue(s.isEmpty)
    }

    func testChargeFirstUseSongsFocus() {
        var charge = S26ASignals.addingCharge([], state: "plugged", at: at(24, 23))
        charge = S26ASignals.addingCharge(charge, state: "plugged", at: at(24, 23, 30))
        charge = S26ASignals.addingCharge(charge, state: "unplugged", at: at(25, 6))
        charge = S26ASignals.addingCharge(charge, state: "unknown", at: at(25, 7))
        XCTAssertEqual(charge.map(\.state), ["plugged", "unplugged"])
        // 4 時より前は朝の最初に数えない
        XCTAssertNil(S26ASignals.firstUse(current: nil, candidate: at(25, 2), calendar: cal))
        let first = S26ASignals.firstUse(current: at(25, 7), candidate: at(25, 5, 40), calendar: cal)
        XCTAssertEqual(first, at(25, 5, 40))
        XCTAssertEqual(S26ASignals.firstUse(current: first, candidate: at(25, 8), calendar: cal), at(25, 5, 40))
        var songs = S26ASignals.addingSong([], S26ASong(at: at(24, 20), title: " 見本 ", artist: "", source: "played"))
        songs = S26ASignals.addingSong(songs, S26ASong(at: at(24, 20, 5), title: "見本", artist: nil, source: "played"))
        songs = S26ASignals.addingSong(songs, S26ASong(at: at(24, 21), title: "見本", artist: nil, source: "played"))
        songs = S26ASignals.addingSong(songs, S26ASong(at: at(24, 21), title: "  ", artist: nil, source: "played"))
        XCTAssertEqual(songs.count, 2)
        XCTAssertNil(songs[0].artist)
        var focus = S26ASignals.addingFocus([], S26AFocus(at: at(24, 22), name: "睡眠", on: true))
        focus = S26ASignals.addingFocus(focus, S26AFocus(at: at(24, 22).addingTimeInterval(20), name: "睡眠", on: true))
        focus = S26ASignals.addingFocus(focus, S26AFocus(at: at(25, 6), name: "睡眠", on: false))
        XCTAssertEqual(focus.map(\.on), [true, false])
    }

    func testMealsCardsAndScreenTime() {
        var meals = S26ASignals.addingMeal([], S26AMeal(at: at(24, 12, 10), lat: nil, lon: nil))
        meals = S26ASignals.addingMeal(meals, S26AMeal(at: at(24, 12, 0), lat: 35.6, lon: 139.7))
        meals = S26ASignals.addingMeal(meals, S26AMeal(at: at(24, 19), lat: nil, lon: nil))
        XCTAssertEqual(meals.count, 2)
        XCTAssertEqual(meals[0].at, at(24, 12, 0))
        XCTAssertEqual(meals[0].lat, 35.6)
        let card = S26ACard(at: at(24, 10), lines: ["見本株式会社", "営業部"])
        XCTAssertEqual(S26ASignals.addingCard([card], card).count, 1)
        XCTAssertTrue(S26ASignals.addingCard([], S26ACard(at: at(24, 10), lines: [])).isEmpty)
        var screen = S26ASignals.addingScreen([], app: "見本アプリ", minutes: 10, replace: false)
        screen = S26ASignals.addingScreen(screen, app: "見本アプリ", minutes: 5, replace: false)
        XCTAssertEqual(screen.first?.minutes, 15)
        screen = S26ASignals.addingScreen(screen, app: "見本アプリ", minutes: 40, replace: true)
        XCTAssertEqual(screen.first?.minutes, 40)
        XCTAssertEqual(S26ASignals.addingScreen(screen, app: "x", minutes: -1, replace: false).count, 1)
        XCTAssertEqual(S26ASignals.openMinutes(opened: at(24, 10), closed: at(24, 10, 30)), 30)
        XCTAssertNil(S26ASignals.openMinutes(opened: at(24, 1), closed: at(24, 10)))
        XCTAssertNil(S26ASignals.openMinutes(opened: nil, closed: at(24, 10)))
    }

    // MARK: 集4・集13・集10・集16

    func testMusicStartNeedsSixSeconds() {
        let w: [(start: Double, end: Double, label: String)] = [(0, 1, "音楽"), (0.5, 1.5, "音楽"), (10, 11, "電車")]
        XCTAssertNil(S26AShazamRules.musicStart(w))
        var long: [(start: Double, end: Double, label: String)] = []
        for i in 0..<14 {
            let s: Double = 20.0 + Double(i) * 0.5
            long.append((start: s, end: s + 1.0, label: "音楽"))
        }
        XCTAssertEqual(S26AShazamRules.musicStart(w + long), 20)
    }

    func testFloorTrackerCountsQuickChangesAndIgnoresDrift() {
        var t = S26AFloorTracker()
        let t0 = at(24, 9)
        XCTAssertNil(t.feed(0, at: t0))
        XCTAssertNil(t.feed(1.0, at: t0.addingTimeInterval(30)))
        XCTAssertEqual(t.feed(6.2, at: t0.addingTimeInterval(60)), 2)
        XCTAssertEqual(t.feed(3.0, at: t0.addingTimeInterval(90)), -1)
        // ゆっくりした変わり（3 分を過ぎた）は捨てる
        XCTAssertNil(t.feed(4.5, at: t0.addingTimeInterval(400)))
        XCTAssertNil(t.feed(6.5, at: t0.addingTimeInterval(800)))
    }

    func testMealAndCardRules() {
        XCTAssertTrue(S26APhotoRules.isMeal([(id: "ramen", confidence: 0.8)]))
        XCTAssertFalse(S26APhotoRules.isMeal([(id: "coffee", confidence: 0.9)]))
        XCTAssertFalse(S26APhotoRules.isMeal([(id: "food", confidence: 0.3)]))
        XCTAssertTrue(S26APhotoRules.isPaper([(id: "document", confidence: 0.4)]))
        let card = "見本株式会社\n営業部 課長\n見本 太郎\nTEL 03-1234-5678\ninfo@example.com"
        XCTAssertTrue(S26APhotoRules.looksLikeCard(card))
        XCTAssertFalse(S26APhotoRules.looksLikeCard("今日の会議の資料\n1. はじめに\n2. まとめ"))
        XCTAssertFalse(S26APhotoRules.looksLikeCard("見本株式会社\n営業部"))
        XCTAssertEqual(S26APhotoRules.cardLines("a\n\n b \n" + String(repeating: "x", count: 80)).map(\.count), [1, 1, 60])
    }

    // MARK: 聞16 予定で録り方

    func testMeetingDetection() {
        XCTAssertTrue(S26AMeetingRules.isMeeting(title: "定例ミーティング", attendees: 0, isWork: false))
        XCTAssertTrue(S26AMeetingRules.isMeeting(title: "Weekly MTG", attendees: 0, isWork: false))
        XCTAssertTrue(S26AMeetingRules.isMeeting(title: "見本", attendees: 2, isWork: true))
        XCTAssertFalse(S26AMeetingRules.isMeeting(title: "歯医者", attendees: 0, isWork: false))
        let events: [(start: Date, end: Date, title: String, attendees: Int, isWork: Bool)] = [
            (at(24, 10), at(24, 11), "面談", 1, false),
            (at(24, 10), at(24, 12), "ランチ", 0, false),
        ]
        XCTAssertEqual(S26AMeetingRules.meetingEnd(events, now: at(24, 9, 59)), at(24, 11))
        XCTAssertNil(S26AMeetingRules.meetingEnd(events, now: at(24, 9, 50)))
        XCTAssertNil(S26AMeetingRules.meetingEnd(events, now: at(24, 11)))
    }

    // MARK: 結9 リンク（K3）

    func testLinksParseAndRoundTrip() {
        let person = S26ALink.person("見本 花子")
        XCTAssertEqual(person.url.flatMap(S26ALink.parse), person)
        XCTAssertEqual(S26ALink.parse(URL(string: "lifelog://person/%E8%A6%8B%E6%9C%AC")!), .person("見本"))
        XCTAssertEqual(S26ALink.parse(URL(string: "lifelog://day/2026-11-24")!), .day("2026-11-24"))
        XCTAssertNil(S26ALink.parse(URL(string: "lifelog://day/11-24")!))
        XCTAssertEqual(S26ALink.parse(URL(string: "lifelog://talk/abc-123")!), .talk("abc-123"))
        XCTAssertEqual(S26ALink.parse(URL(string: "lifelog://task/t1")!), .task("t1"))
        XCTAssertEqual(S26ALink.parse(URL(string: "lifelog://drafts")!), .drafts)
        XCTAssertEqual(S26ALink.parse(URL(string: "lifelog://waiting")!), .waiting)
        XCTAssertNil(S26ALink.parse(URL(string: "lifelog://person/")!))
        XCTAssertNil(S26ALink.parse(URL(string: "lifelog://tasks")!))
        // 今までのウィジェットの住所はそのまま
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://tasks")!), .tab(.tasks))
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://day/2026-11-24")!), .link(.day("2026-11-24")))
        XCTAssertEqual(NoticeRoute.route(url: URL(string: "lifelog://waiting")!), .link(.waiting))
    }

    func testTalkMoment() {
        let a = S26ALink.talkMoment("2026-11-24T15:30", calendar: cal)
        XCTAssertEqual(a?.day, "2026-11-24")
        XCTAssertEqual(a?.time, at(24, 15, 30))
        XCTAssertEqual(S26ALink.talkMoment("20261124-0905", calendar: cal)?.time, at(24, 9, 5))
        XCTAssertNil(S26ALink.talkMoment("2026-11-24", calendar: cal)?.time)
        XCTAssertNil(S26ALink.talkMoment("abc", calendar: cal))
        let id = S26ALink.appTalkID(at(24, 15, 30), calendar: cal)
        XCTAssertEqual(id, "app-2026-11-24T15:30")
        XCTAssertEqual(S26ALink.talkMoment(id, calendar: cal)?.time, at(24, 15, 30))
    }

    // MARK: 結3 実績

    func testActualItems() {
        XCTAssertNil(S26AActualRules.talk(title: "短い", people: [], place: nil, start: at(24, 10), end: at(24, 10, 2)))
        let t = S26AActualRules.talk(title: nil, people: ["A", "B", "C", "D", "E"], place: "見本の店", start: at(24, 10), end: at(24, 10, 30))
        XCTAssertEqual(t?.title, "話した: 会話（A、B、C、D ほか）")
        XCTAssertEqual(t?.notes, "場所: 見本の店")
        XCTAssertNil(S26AActualRules.stay(name: nil, start: at(24, 10), end: at(24, 11)))
        XCTAssertNil(S26AActualRules.stay(name: "店", start: at(24, 10), end: at(24, 10, 5)))
        XCTAssertEqual(S26AActualRules.stay(name: "店", start: at(24, 10), end: at(24, 11))?.title, "いた: 店")
    }

    // MARK: 結5・聞10・軽8・聞12

    func testFastSendEligibility() {
        XCTAssertTrue(S26AFastSendRules.eligible(bytes: 300_000, on: true))
        XCTAssertFalse(S26AFastSendRules.eligible(bytes: 1_200_000, on: true))
        XCTAssertFalse(S26AFastSendRules.eligible(bytes: 300_000, on: false))
        XCTAssertFalse(S26AFastSendRules.eligible(bytes: nil, on: true))
    }

    func testFitDistanceFindsBestSpan() {
        let truth = Array("あしたの会議")
        XCTAssertEqual(S26ABenchRules.fitDistance(truth, in: Array("えっとあしたの会議はね")), 0)
        XCTAssertEqual(S26ABenchRules.fitDistance(truth, in: Array("えっとあしたの会儀はね")), 1)
        XCTAssertEqual(S26ABenchRules.fitDistance(truth, in: []), truth.count)
        let rows = [S26ABenchRules.Row(id: "a", chars: 10, device: 2, app: 1, at: at(24, 1)),
                    S26ABenchRules.Row(id: "b", chars: 10, device: 0, app: 1, at: at(24, 1))]
        let r = S26ABenchRules.rates(rows)
        XCTAssertEqual(r?.device ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(r?.app ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertNil(S26ABenchRules.rates([]))
    }

    func testBriefScript() {
        let s = S26AEarRules.briefScript(title: "まもなく 面談", body: "見本さん：前回 11/20\n・資料の話")
        XCTAssertEqual(s, "まもなく 面談。見本さん、前回 11/20。資料の話。")
        XCTAssertTrue(S26AEarRules.briefScript(title: "x", body: String(repeating: "あ", count: 600)).hasSuffix("続きはアプリで見てください。"))
    }

    func testNameDictionary() {
        XCTAssertEqual(S26ANameRules.cleaned("たなかさん"), "たなか")
        XCTAssertNil(S26ANameRules.cleaned("a@b.com"))
        XCTAssertNil(S26ANameRules.cleaned("とても長い名前の人ですよね"))
        let e = S26ANameRules.entries(["たなかさん", "サトウ", "さとう", "サトウ"])
        XCTAssertEqual(e.map { $0.written }, ["たなか", "サトウ", "さとう"])
        XCTAssertEqual(e[1].reading, e[2].reading)
    }
}

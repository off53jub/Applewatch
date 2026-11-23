import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// 休日のライフログ（2026-11-21。s19。番号は母艦に出した 休1〜休50 の番号。docs/s19-holiday-app.md）。iPhone の分。
/// - 休1 休みの印: その日が休みか（土日・祝日・アプリの休み）を、ドライブの「LifeLog/休日」に 1 日 1 ファイルで書く（母艦の M1 が読む）
/// - 休6・休7 休日に家を出たら: 出かける前の点検（時計と iPhone の電池・時計が録音中か・PLAUD の最後の取り込み）と、録音の促しを 1 通に
/// - 休21 滞在の直後に「さっきの所は〇〇？」を はい・いいえ で（91 の「30 分いたら」より短い滞在だけ。1 日 3 回まで）
/// - 休22 かざした決済の直後に「一言どうぞ」（時計に写る通知に音声で答える。決済の id と結んで書く）
/// - 休32 ゴルフの日にスコアを一言・休34 映画館・ライブ会場では録音を休み、出たら感想を一言・休42 夜に「今日いちばんよかった瞬間」
/// - 休30 時計の「お酒 +1」の数を、その日のファイルに書く
/// 新しい知らせは休日だけ・1 日の数に上限（仮）。既定がオフのもの（録音の促し・外出モード・映画館で休む）は設定で入れるまで動かない。
/// 一言の中身はこの端末と、ドライブのその日のファイルにだけ置く（ログには書かない）。

// MARK: - 決まり（決まった入力から決まった出力だけ）

enum HolidaySettings {
    /// 休6 休日に家を出たら、録音を始める促し（初めはオフ）
    static let recordNudgeKey = "holiday.recordNudge"
    /// 休7 出かける前の点検（初めはオン）
    static let checkupKey = "holiday.checkup"
    /// 休8 時計の外出モード（初めはオフ。時計に送る）
    static let awayModeKey = "holiday.awayMode"
    /// 休9 時計の電池が少ないとき「PLAUD に任せて」（初めはオン。時計に送る）
    static let lowBatteryKey = "holiday.lowBattery"
    /// 休21 滞在の直後に「ここは〇〇？」（初めはオン）
    static let placeAfterKey = "holiday.placeAfter"
    /// 休22 かざした決済の直後に一言（初めはオン）
    static let payNoteKey = "holiday.payNote"
    /// 休32 ゴルフの日にスコアを一言（初めはオン）
    static let golfKey = "holiday.golf"
    /// 休34 映画館・ライブ会場で録音を休む（初めはオフ）
    static let venueHoldKey = "holiday.venueHold"
    /// 休42 夜に「今日いちばんよかった瞬間」（初めはオン）
    static let bestKey = "holiday.best"
    /// iPhone が「家を出ている」と思っているか（登録した「自宅」の見張りから。休8）
    static let awayKey = "holiday.away"

    static let defaults: [String: Bool] = [recordNudgeKey: false, checkupKey: true, awayModeKey: false, lowBatteryKey: true,
                                           placeAfterKey: true, payNoteKey: true, golfKey: true, venueHoldKey: false,
                                           bestKey: true]

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaults[key] ?? false
    }
}

enum HolidayNoticeRules {
    static let prefix = "holiday-"
    /// 一言を音声（文字）で答える知らせ
    static let noteCategory = "holidayNote"
    static let noteAction = "holiday.say"
    /// はい・いいえ の知らせ（休21）
    static let placeCategory = "holidayPlace"
    static let yesAction = "holiday.yes"
    static let noAction = "holiday.no"

    // しきい値（すべて仮）
    /// 休日の新しい知らせの、1 日の合計の上限（6 通。仮）
    static let dailyCap = 6
    /// 種類ごとの 1 日の上限（滞在の直後は 3 回・決済は 3 回・ほかは 1 回。仮）
    static let kindCaps: [String: Int] = ["place": 3, "payment": 3]
    /// 滞在の直後に聞く長さ（15 分より長くいた所。仮）。30 分（91 の askAfter）より長い所は 91 がもう聞いている
    static let placeMinStay: TimeInterval = 15 * 60
    /// 出かける前の点検を出す時間（5 時〜15 時に、その日はじめて家を出たとき。仮）
    static let checkupFrom = 5
    static let checkupTo = 15
    /// 点検で「少なめ」と書く電池（50%。仮）
    static let checkupLowBattery: Double = 0.5
    /// 夜の「いちばんよかった瞬間」の時刻（21:00。仮）
    static let bestHour = 21
    /// ゴルフのスコアを聞くのは、この時刻より後（13 時。仮）
    static let golfAfterHour = 13
    /// 映画館・ライブ会場とみなす距離（100 m。仮）と、休む長さの上限（4 時間。仮。出たことを取りこぼしても戻す）
    static let venueRadius: Double = 100
    static let venueMaxHold: TimeInterval = 4 * 3600
    /// 会場から離れたとみなす距離（300 m。仮）
    static let venueLeftDistance: Double = 300

    /// 出してよいか（休日・設定がオン・種類の上限と合計の上限の中）
    static func allowed(holiday: Bool, enabled: Bool, kind: String, counts: [String: Int], day: String,
                        cap: Int = dailyCap) -> Bool {
        guard holiday, enabled else { return false }
        let kindCap: Int = kindCaps[kind] ?? 1
        guard HolidayRules.count(counts, kind, day: day) < kindCap else { return false }
        return HolidayRules.count(counts, "total", day: day) < cap
    }

    /// 滞在の直後に聞くか（知らない所・15 分より長い・91 が聞いていない長さ）
    static func shouldAskAfterStay(known: Bool, stay: TimeInterval, placeAskOn: Bool,
                                   askAfter: TimeInterval = PlaceAssistRules.askAfter, minStay: TimeInterval = placeMinStay) -> Bool {
        guard !known, stay >= minStay else { return false }
        return !placeAskOn || stay < askAfter
    }

    /// 出かける前の点検を出す時間か
    static func isCheckupHour(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= checkupFrom && hour < checkupTo
    }

    /// 点検の文（事実だけ。分からないものは「分からない」）
    static func checkupLines(watchBattery: Double?, watchCharging: Bool?, watchRecording: Bool?, watchSeen: Date?,
                             phoneBattery: Double?, plaudLast: Date?, now: Date) -> [String] {
        func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" + (v < checkupLowBattery ? "（少なめ）" : "") }
        var lines: [String] = []
        if let seen = watchSeen, now.timeIntervalSince(seen) < 2 * 3600 {
            var watch = "時計: " + (watchBattery.map(percent) ?? "電池は分からない")
            if watchCharging == true { watch += "・充電中" }
            watch += watchRecording == true ? "・録音中" : "・録音していません"
            lines.append(watch)
        } else {
            lines.append("時計: 2 時間より前から様子が届いていません")
        }
        lines.append("iPhone: " + (phoneBattery.map(percent) ?? "電池は分からない"))
        if let plaudLast {
            lines.append("PLAUD の最後の取り込み: " + AppFeeds.shortTime(plaudLast))
        } else {
            lines.append("PLAUD の最後の取り込み: 分からない")
        }
        return lines
    }

    /// 決済のあとの一言の文（店と金額が届いていなければ、それも一言で）
    static func paymentBody(shop: String, amount: Int) -> String {
        let s = shop.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty && amount <= 0 { return "いまの支払い、どこでいくら？ 一言で残せます（何を・誰と、も）。" }
        var head = s.isEmpty ? "" : s
        if amount > 0 { head += (head.isEmpty ? "" : "で ") + "¥" + amount.formatted() }
        return head + "。何を買った・誰と、を一言で残せます。"
    }

    static func categories() -> [UNNotificationCategory] {
        let say = UNTextInputNotificationAction(identifier: noteAction, title: "一言", options: [],
                                                textInputButtonTitle: "残す", textInputPlaceholder: "一言")
        let yes = UNNotificationAction(identifier: yesAction, title: "はい", options: [])
        let no = UNNotificationAction(identifier: noAction, title: "いいえ", options: [])
        return [UNNotificationCategory(identifier: noteCategory, actions: [say], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: placeCategory, actions: [yes, no], intentIdentifiers: [], options: [])]
    }
}

// MARK: - ドライブへの書き出し（休1・休30・休21・休22・休32・休34・休42）

/// 1 日の一言（夜のよかった瞬間・ゴルフのスコア・決済のメモ・映画の感想）
struct HolidayNote: Codable, Equatable {
    /// best・golf・payment・venue
    var kind: String
    var day: String
    var at: Date
    var text: String
    /// 結び先（決済の id・会場の名前。無ければ nil）
    var ref: String? = nil
}

/// 滞在の直後の「ここは〇〇？」の答え
struct HolidayPlaceAnswer: Codable, Equatable {
    var day: String
    var at: Date
    var name: String
    /// yes・no
    var answer: String
}

enum HolidayExport {
    static let folderName = "休日"
    static let doneKey = "holidayExportedDays"
    /// ここから後の日を書く（休みの印はカレンダーからさかのぼって分かる）
    static let firstDay = "2026-11-01"
    static let perRun = 10

    static func fileName(_ day: String) -> String { "lifelog-holiday-\(day).json" }

    /// 母艦が読む 1 日分。dayOff は必ず入れる（休みでない日も off: false）。ほかは有るときだけ
    static func json(day: String, why: String?, drinks: [Date], notes: [HolidayNote], places: [HolidayPlaceAnswer],
                     calendar: Calendar = .current) -> Data? {
        var dayOff: [String: Any] = ["off": why != nil]
        if let why { dayOff["why"] = why }
        var object: [String: Any] = ["source": "LifeLog", "version": 1, "day": day, "dayOff": dayOff]
        let todays = drinks.filter { HolidayRules.dayKey($0, calendar: calendar) == day }.sorted()
        if !todays.isEmpty {
            object["drinks"] = ["count": todays.count, "at": todays.map { HealthExport.stamp($0, calendar: calendar) }]
        }
        let dayNotes = notes.filter { $0.day == day }.sorted { $0.at < $1.at }
        if !dayNotes.isEmpty {
            object["notes"] = dayNotes.map { n -> [String: Any] in
                var row: [String: Any] = ["kind": n.kind, "at": HealthExport.stamp(n.at, calendar: calendar), "text": n.text]
                if let ref = n.ref { row["ref"] = ref }
                return row
            }
        }
        let dayPlaces = places.filter { $0.day == day }.sorted { $0.at < $1.at }
        if !dayPlaces.isEmpty {
            object["places"] = dayPlaces.map { ["at": HealthExport.stamp($0.at, calendar: calendar), "name": $0.name, "answer": $0.answer] }
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - 端末の中の帳面

@MainActor
@Observable
final class HolidayBook {
    static let shared = HolidayBook()

    private struct Saved: Codable {
        var notes: [HolidayNote] = []
        var drinks: [Date] = []
        var places: [HolidayPlaceAnswer] = []
        /// "日|種類" → 出した知らせの数（total は合計）
        var counts: [String: Int] = [:]
        /// 映画館・ライブ会場で休んでいるあいだ（名前・位置・いつまで）
        var venueName: String?
        var venueLat: Double?
        var venueLon: Double?
        var venueUntil: Date?
    }

    private var saved = Saved()
    /// 読み込めたか（読めなかったときは書かない。読み込む前に保存しない）
    @ObservationIgnored private var loaded = false
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("holiday-notes.json")
    /// 残す日数（ドライブに書いたあとも 30 日は端末に置く）
    private static let keepDays: TimeInterval = 30 * 86400

    init() {
        if let data = try? Data(contentsOf: Self.url) {
            if let s = try? JSONDecoder().decode(Saved.self, from: data) {
                saved = s
                loaded = true
            }
        } else {
            loaded = !FileManager.default.fileExists(atPath: Self.url.path)
        }
    }

    private func save() {
        guard loaded else { return }
        let old = Date.now.addingTimeInterval(-Self.keepDays)
        saved.notes.removeAll { $0.at < old }
        saved.drinks.removeAll { $0 < old }
        saved.places.removeAll { $0.at < old }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    var notes: [HolidayNote] { saved.notes }
    var drinks: [Date] { saved.drinks }
    var places: [HolidayPlaceAnswer] { saved.places }
    var counts: [String: Int] { saved.counts }

    func drinks(on day: String) -> Int { saved.drinks.filter { HolidayRules.dayKey($0) == day }.count }

    func addDrink(_ at: Date) {
        // 同じ時刻（時計が送り直した）は 1 杯
        guard !saved.drinks.contains(where: { abs($0.timeIntervalSince(at)) < 1 }) else { return }
        saved.drinks.append(at)
        save()
        Tally.add("holiday.drink")
    }

    func addNote(kind: String, day: String, text: String, ref: String?, at: Date = .now) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !t.isEmpty else { return }
        saved.notes.append(HolidayNote(kind: kind, day: day, at: at, text: t, ref: ref))
        save()
        Tally.add("holiday.note." + kind)
    }

    func addPlaceAnswer(day: String, name: String, answer: String, at: Date = .now) {
        saved.places.append(HolidayPlaceAnswer(day: day, at: at, name: String(name.prefix(80)), answer: answer))
        save()
    }

    /// 知らせを 1 つ出したと数える（種類と合計）
    func countNotice(_ kind: String, day: String) {
        saved.counts = HolidayRules.bumped(saved.counts, kind, day: day)
        saved.counts[day + "|total", default: 0] += 1
        save()
        Tally.add("holiday.notice." + kind)
    }

    // 映画館・ライブ会場（休34）
    var venueName: String? { saved.venueName }

    func venueHolding(now: Date = .now) -> Bool {
        guard let until = saved.venueUntil else { return false }
        return now < until
    }

    func venueDistance(from here: CLLocation) -> Double? {
        guard let lat = saved.venueLat, let lon = saved.venueLon else { return nil }
        return CLLocation(latitude: lat, longitude: lon).distance(from: here)
    }

    func startVenue(name: String, latitude: Double, longitude: Double, until: Date) {
        saved.venueName = String(name.prefix(80))
        saved.venueLat = latitude
        saved.venueLon = longitude
        saved.venueUntil = until
        save()
    }

    func endVenue() {
        saved.venueName = nil
        saved.venueLat = nil
        saved.venueLon = nil
        saved.venueUntil = nil
        save()
    }
}

// MARK: - 知らせ

@MainActor
final class HolidayNudges {
    static let shared = HolidayNudges()
    private weak var pipeline: Pipeline?

    func attach(_ pipeline: Pipeline) {
        self.pipeline = pipeline
        pipeline.carAudio.onChange = { [weak self] in self?.sendWatchContext() }
        sendWatchContext()
    }

    private var today: String { HolidayRules.dayKey(.now) }

    func isHoliday(_ date: Date = .now) -> Bool { pipeline?.isDayOff(date) ?? false }

    /// 時計に、今日が休みか・電池の知らせ・外出モード・家を出ているか・車につないだ時刻を送る（変わったときだけ）
    func sendWatchContext() {
        guard let pipeline else { return }
        let now = Date.now
        let open = pipeline.carAudio.periods.last.flatMap { $0.end == nil ? $0.start : nil }
        pipeline.receiver.sendHolidayContext(holidayDay: isHoliday(now) ? HolidayRules.dayKey(now) : "",
                                             lowBattery: HolidaySettings.isOn(HolidaySettings.lowBatteryKey),
                                             awayMode: HolidaySettings.isOn(HolidaySettings.awayModeKey),
                                             away: UserDefaults.standard.bool(forKey: HolidaySettings.awayKey),
                                             carSince: open?.timeIntervalSince1970 ?? 0)
    }

    /// 出してよければ数えて true
    private func take(_ kind: String, setting: String) -> Bool {
        let book = HolidayBook.shared
        guard HolidayNoticeRules.allowed(holiday: isHoliday(), enabled: HolidaySettings.isOn(setting), kind: kind,
                                         counts: book.counts, day: today) else { return false }
        book.countNotice(kind, day: today)
        return true
    }

    private func noteRequest(id: String, title: String, body: String, kind: String, ref: String?,
                             trigger: UNNotificationTrigger? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = HolidayNoticeRules.noteCategory
        content.interruptionLevel = .passive
        var info: [String: Any] = ["hkind": kind, "hday": today]
        if let ref { info["href"] = ref }
        content.userInfo = info
        return UNNotificationRequest(identifier: HolidayNoticeRules.prefix + id, content: content, trigger: trigger)
    }

    // MARK: 見回り（アプリが動くたび）

    /// 夜の「いちばんよかった瞬間」を頼む・ゴルフの日にスコアを聞く・時計に休日の設定を送る
    func tick(now: Date = .now) async {
        guard let pipeline else { return }
        sendWatchContext()
        // 映画館で休む時間が過ぎていたら戻す（出たことを取りこぼしたとき）
        if HolidayBook.shared.venueName != nil, !HolidayBook.shared.venueHolding(now: now) {
            HolidayBook.shared.endVenue()
            pipeline.updateHold()
        }
        guard isHoliday(now) else { return }
        let calendar = Calendar.current
        let day = HolidayRules.dayKey(now)
        // 休42 夜に一言（21:00。仮。その日の 1 回）
        if calendar.component(.hour, from: now) < HolidayNoticeRules.bestHour,
           HolidayRules.count(HolidayBook.shared.counts, "best", day: day) == 0,
           take("best", setting: HolidaySettings.bestKey) {
            var c = calendar.dateComponents([.year, .month, .day], from: now)
            c.hour = HolidayNoticeRules.bestHour
            let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: false)
            NoticeGate.add(noteRequest(id: "best-" + day, title: "今日いちばんよかった瞬間は？",
                                       body: "一言で残せます（いいこと帳に入ります）。", kind: "best", ref: nil, trigger: trigger))
        }
        // 休32 ゴルフ（その日にゴルフのワークアウトがあれば、13 時より後に 1 回）
        let golfWanted: Bool = calendar.component(.hour, from: now) >= HolidayNoticeRules.golfAfterHour
            && HolidaySettings.isOn(HolidaySettings.golfKey)
            && HolidayRules.count(HolidayBook.shared.counts, "golf", day: day) == 0
        var golfed = false
        if golfWanted { golfed = await pipeline.health.didGolf(from: calendar.startOfDay(for: now), to: now) }
        if golfed, take("golf", setting: HolidaySettings.golfKey) {
            NoticeGate.add(noteRequest(id: "golf-" + day, title: "ゴルフおつかれさまでした",
                                       body: "スコアを一言で残せます（「52・48」など）。", kind: "golf", ref: nil))
        }
    }

    // MARK: 家を出た・戻った（KnowGeo から。休6・休7・休8）

    func leftHome(at date: Date) async {
        UserDefaults.standard.set(true, forKey: HolidaySettings.awayKey)
        sendWatchContext()
        guard let pipeline, isHoliday(date), HolidayNoticeRules.isCheckupHour(date) else { return }
        let checkup = HolidaySettings.isOn(HolidaySettings.checkupKey)
        let nudge = HolidaySettings.isOn(HolidaySettings.recordNudgeKey)
        guard checkup || nudge else { return }
        let watch = pipeline.ledger.lastState
        let notRecording = !pipeline.isRecording && watch?.recording != true
        // 録音していて点検がオフなら、出すものが無い
        guard checkup || notRecording else { return }
        guard take("leave", setting: checkup ? HolidaySettings.checkupKey : HolidaySettings.recordNudgeKey) else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let plaud: Date? = pipeline.appFeeds.freshness.first { $0.key == "plaud_audio" }.flatMap { AppFeeds.parseTime($0.last_ok) }
        let content = UNMutableNotificationContent()
        content.title = nudge && notRecording ? "出かけますか？ 録音を始めますか" : "出かける前の点検"
        var lines: [String] = checkup ? HolidayNoticeRules.checkupLines(
            watchBattery: watch?.battery, watchCharging: watch?.charging, watchRecording: watch?.recording, watchSeen: watch?.at,
            phoneBattery: level >= 0 ? Double(level) : nil, plaudLast: plaud, now: date) : []
        if nudge && notRecording { lines.append("（押すと開いて録音を始めます）") }
        content.body = lines.joined(separator: "\n")
        if nudge && notRecording { content.categoryIdentifier = KnowMeRules.geoCategory }
        NoticeGate.add(UNNotificationRequest(identifier: HolidayNoticeRules.prefix + "leave", content: content, trigger: nil))
    }

    func arrivedHome() {
        UserDefaults.standard.set(false, forKey: HolidaySettings.awayKey)
        sendWatchContext()
    }

    // MARK: 滞在（PlaceAssist から。休21・休34）

    /// 滞在を出た直後に「さっきの所は〇〇？」
    func stayEnded(arrival: Date, departure: Date, here: CLLocation, known: Bool) async {
        venueLeft(here, departed: true)
        // 「ここは覚えなくていい」にした所では聞かない・聞く長さは場6 で絞った長さに揃える（2026-11-23。s23 の 場1・場6）
        guard arrival != .distantPast, departure > arrival, MeetingMode.active == nil,
              !S23Places.isIgnored(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude),
              HolidayNoticeRules.shouldAskAfterStay(known: known, stay: departure.timeIntervalSince(arrival),
                                                    placeAskOn: PlaceAssistRules.askOn, askAfter: S23Places.askAfter()) else { return }
        let names: [String] = await PlaceAssist.shared.candidates(for: here, arrival: arrival)
        guard let name = names.first, take("place", setting: HolidaySettings.placeAfterKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = "さっきの所は「\(name)」？"
        content.body = "合っていれば、次からこの名前を使います。"
        content.categoryIdentifier = HolidayNoticeRules.placeCategory
        content.interruptionLevel = .passive
        content.userInfo = ["hname": name, "lat": here.coordinate.latitude, "lon": here.coordinate.longitude, "hday": today]
        NoticeGate.add(UNNotificationRequest(identifier: HolidayNoticeRules.prefix + "place-" + String(Int(departure.timeIntervalSince1970)),
                                             content: content, trigger: nil))
    }

    /// 着いた所が映画館・ライブ会場なら、録音を休む（設定がオンのときだけ）
    func venueArrived(_ here: CLLocation, at arrival: Date) async {
        guard let pipeline, HolidaySettings.isOn(HolidaySettings.venueHoldKey), !HolidayBook.shared.venueHolding() else { return }
        let request = MKLocalPointsOfInterestRequest(center: here.coordinate, radius: HolidayNoticeRules.venueRadius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.movieTheater, .theater, .musicVenue])
        guard let response = try? await MKLocalSearch(request: request).start() else { return }
        let near = response.mapItems.compactMap { item -> (String, Double)? in
            guard let name = item.name, let loc = item.placemark.location else { return nil }
            let d = loc.distance(from: here)
            return d <= HolidayNoticeRules.venueRadius ? (name, d) : nil
        }.min { $0.1 < $1.1 }
        guard let near else { return }
        let start: Date = arrival == .distantPast ? .now : arrival
        HolidayBook.shared.startVenue(name: near.0, latitude: here.coordinate.latitude, longitude: here.coordinate.longitude,
                                      until: start.addingTimeInterval(HolidayNoticeRules.venueMaxHold))
        Tally.add("holiday.venue.hold")
        pipeline.updateHold()
    }

    /// 会場から離れた（滞在を出た・大きく動いた）。休みを戻し、休日なら感想を一言。
    /// departed は滞在の「出た」の知らせ（同じ所で届くので、近くても終える）。大きく動いただけなら、離れたときだけ終える
    func venueLeft(_ here: CLLocation, departed: Bool) {
        let book = HolidayBook.shared
        guard let name = book.venueName, let distance = book.venueDistance(from: here) else { return }
        let far = distance > HolidayNoticeRules.venueLeftDistance
        guard (departed && !far) || (!departed && far) || !book.venueHolding() else { return }
        book.endVenue()
        pipeline?.updateHold()
        Tally.add("holiday.venue.end")
        if take("venue", setting: HolidaySettings.venueHoldKey) {
            NoticeGate.add(noteRequest(id: "venue-" + String(Int(Date.now.timeIntervalSince1970)), title: "\(name)、どうでしたか？",
                                       body: "感想を一言で残せます。", kind: "venue", ref: name))
        }
    }

    // MARK: かざした決済（休22）

    func cardTapped(_ payment: Payment?) {
        guard let payment, Date.now.timeIntervalSince(payment.time) < 600,
              take("payment", setting: HolidaySettings.payNoteKey) else { return }
        NoticeGate.add(noteRequest(id: "pay-" + payment.id, title: "支払いを残しました",
                                   body: HolidayNoticeRules.paymentBody(shop: payment.shop, amount: payment.amount),
                                   kind: "payment", ref: payment.id))
    }

    // MARK: 答え

    /// 一言の知らせに答えた（時計の音声入力も同じ）
    func answeredNote(text: String, userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo["hkind"] as? String else { return }
        let day: String = (userInfo["hday"] as? String).flatMap { HomeFeeds.isDay($0) ? $0 : nil } ?? today
        HolidayBook.shared.addNote(kind: kind, day: day, text: text, ref: userInfo["href"] as? String)
    }

    /// 「さっきの所は〇〇？」に答えた
    func answeredPlace(actionID: String, userInfo: [AnyHashable: Any]) {
        guard let name = userInfo["hname"] as? String else { return }
        let day: String = (userInfo["hday"] as? String).flatMap { HomeFeeds.isDay($0) ? $0 : nil } ?? today
        if actionID == HolidayNoticeRules.yesAction {
            PlaceAssist.shared.answered(actionID: PlaceAssistRules.actionID(0), candidates: [name],
                                        latitude: userInfo["lat"] as? Double, longitude: userInfo["lon"] as? Double)
            HolidayBook.shared.addPlaceAnswer(day: day, name: name, answer: "yes")
        } else if actionID == HolidayNoticeRules.noAction {
            HolidayBook.shared.addPlaceAnswer(day: day, name: name, answer: "no")
        }
        Tally.add("holiday.place." + (actionID == HolidayNoticeRules.yesAction ? "yes" : "no"))
        // 答えそびれた質問から外す（2026-11-23。s23 の 知13）
        S23Book.shared.answeredQuestions(prefix: HolidayNoticeRules.prefix + "place-")
    }
}

// MARK: - 画面（設定）

struct HolidaySettingsSection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(HolidaySettings.checkupKey) private var checkup = true
    @AppStorage(HolidaySettings.recordNudgeKey) private var recordNudge = false
    @AppStorage(HolidaySettings.awayModeKey) private var awayMode = false
    @AppStorage(HolidaySettings.lowBatteryKey) private var lowBattery = true
    @AppStorage(HolidaySettings.placeAfterKey) private var placeAfter = true
    @AppStorage(HolidaySettings.payNoteKey) private var payNote = true
    @AppStorage(HolidaySettings.golfKey) private var golf = true
    @AppStorage(HolidaySettings.venueHoldKey) private var venueHold = false
    @AppStorage(HolidaySettings.bestKey) private var best = true

    var body: some View {
        Section {
            Toggle("家を出たら、出かける前の点検", isOn: $checkup)
            Toggle("家を出たら、録音を始める促し", isOn: $recordNudge)
            Toggle("時計の外出モード（外では溜めて、家か充電中にまとめて送る）", isOn: $awayMode)
                .onChange(of: awayMode) { HolidayNudges.shared.sendWatchContext() }
            Toggle("時計の電池が 20% を切ったら「PLAUD に任せて」", isOn: $lowBattery)
                .onChange(of: lowBattery) { HolidayNudges.shared.sendWatchContext() }
            Toggle("滞在のすぐあとに「さっきの所は〇〇？」", isOn: $placeAfter)
            Toggle("かざして払ったあとに一言", isOn: $payNote)
            Toggle("ゴルフの日にスコアを一言", isOn: $golf)
            Toggle("映画館・ライブ会場では録音を休む", isOn: $venueHold)
            Toggle("夜に「今日いちばんよかった瞬間」", isOn: $best)
            let day = HolidayRules.dayKey(.now)
            let drinks = HolidayBook.shared.drinks(on: day)
            Text((pipeline.isDayOff(.now) ? "今日は休みの日です" : "今日は休みの日ではありません")
                 + (drinks > 0 ? "・お酒 \(drinks) 杯" : ""))
                .font(.caption).foregroundStyle(LL.dim)
        } header: {
            Text("休日")
        } footer: {
            Text("知らせは休みの日（土日・祝日・休みの終日の予定）だけ、1 日 \(HolidayNoticeRules.dailyCap) 通まで（仮）です。家を出た・戻ったは、登録した場所の「自宅」の見張りで分かります（位置の「常に」の許可が要ります）。一言はこの iPhone と、ドライブの「LifeLog/休日」のその日のファイルにだけ書きます。外出モードの電池の効き目はまだ仮説なので、前後の電池の減りを時計の様子に残して測ります。")
        }
    }
}

import Foundation
import Observation
import UIKit

/// 1日の流れを1つに・PayPay の写真・位置を当日のうちに・反映の見張り（2026-11-14）。
/// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記（2026-11-14）」の強化案。
/// - 25: 家の PC の GET /timeline?day=（features の "timeline"）で母艦の1日の年表を読み、1日の画面（DayView）の会話のあいだに
///   会話以外の行（位置・決済・LINE・予定など）を時刻の順に挟む。日ごとに端末に写しを置き（同期しない）、つながらないときは写しを見せる。
/// - 28: PayPay のアプリの取引履歴のスクリーンショットを、家の PC（POST /pay/paypay-shot。"paypayshot"）が Claude で読む。
///   本人が確かめた行だけを POST /pay/paypay-rows（"paypayrows"）で母艦へ。画像は端末の外に残さない（PC も保存しない）。
/// - 30: 終わった滞在と今いる滞在を、15分に1回まで POST /location/stays（"livestays"）で母艦へ（送る前のものは端末にためる）。
///   「場所を記録する」がオフなら何もしない。
/// - 34: GET /reflection（"reflection"）で、要素 × 反映先の「最後に反映された日」を読み、歯車→点検に表で出す。
/// 中身の文は記録（ログ）に書かない。

// MARK: - 1日の年表（25）

/// 母艦の年表の1行
struct TimelineRow: Codable, Equatable {
    /// "HH:MM"
    var time: String
    var end: String? = nil
    /// 会話・位置・決済・LINE・予定・写真・閲覧・PC・iPhone・体調・天気・注文
    var lane: String
    var text: String
    /// 決済の円（無ければ nil）
    var amount: Int? = nil
    /// 位置の場所の名前（無ければ nil）
    var place: String? = nil
}

struct TimelineDay: Codable, Equatable {
    var day: String
    var generated_at: String? = nil
    var rows: [TimelineRow] = []
    /// この端末で家の PC から読めた時刻
    var fetched: Date? = nil
}

enum OneTimeline {
    static let lanes: [String] = ["会話", "位置", "決済", "LINE", "予定", "写真", "閲覧", "PC", "iPhone", "体調", "天気", "注文"]
    static let rowLimit = 600
    /// 家の PC が年表を配る日数（今日を入れて）
    static let recentDays = 14
    /// 会話は1日の画面にもとからあるので、年表からは挟まない
    static let nativeLane = "会話"

    private struct RawDay: Decodable {
        var available: Bool?
        var day: String?
        var generated_at: String?
        var rows: [LossyRow<RawRow>]?
    }

    // 型が違う値は、その値だけ落とす（行は残す）
    private struct RawRow: Decodable {
        var time: String?
        var end: LossyRow<String>?
        var lane: String?
        var text: String?
        var amount: LossyRow<Int>?
        var place: LossyRow<String>?
    }

    /// "HH:MM"（00:00〜23:59）か
    static func isClock(_ text: String?) -> Bool {
        guard let text, text.count == 5 else { return false }
        let chars: [Character] = Array(text)
        guard chars[2] == ":" else { return false }
        let digits: [Character] = [chars[0], chars[1], chars[3], chars[4]]
        for ch in digits where !(ch.isASCII && ch.isNumber) { return false }
        guard let h = Int(String(chars[0...1])), let m = Int(String(chars[3...4])) else { return false }
        return h < 24 && m < 60
    }

    /// 時刻の順（同じ時刻は元の並びのまま）
    static func sortedByTime(_ rows: [TimelineRow]) -> [TimelineRow] {
        var keyed: [(index: Int, row: TimelineRow)] = []
        for (i, r) in rows.enumerated() { keyed.append((index: i, row: r)) }
        keyed.sort { a, b in a.row.time != b.row.time ? a.row.time < b.row.time : a.index < b.index }
        var out: [TimelineRow] = []
        for k in keyed { out.append(k.row) }
        return out
    }

    /// GET /timeline の答え。読めない・{"available": false}・違う日なら nil（前の写しのままにする）
    static func decode(_ data: Data, day: String) -> TimelineDay? {
        guard let raw = try? JSONDecoder().decode(RawDay.self, from: data), raw.available != false else { return nil }
        if let d = raw.day, d != day { return nil }
        var rows: [TimelineRow] = []
        for row in raw.rows ?? [] {
            guard let r = row.value, let time = r.time, isClock(time),
                  let lane = r.lane, lanes.contains(lane),
                  let text = MothershipFeeds.cut(r.text, 80) else { continue }
            var item = TimelineRow(time: time, lane: lane, text: text)
            if let end = r.end?.value, isClock(end) { item.end = end }
            if let amount = r.amount?.value, amount >= 0 { item.amount = amount }
            item.place = MothershipFeeds.cut(r.place?.value, 40)
            rows.append(item)
            if rows.count >= rowLimit { break }
        }
        return TimelineDay(day: day, generated_at: raw.generated_at, rows: sortedByTime(rows))
    }

    /// 1日の画面に挟む行（会話は除く）
    static func shown(_ rows: [TimelineRow]) -> [TimelineRow] {
        rows.filter { $0.lane != nativeLane }
    }

    /// その日のその時刻（この端末の時間帯）
    static func date(day: String, clock: String, calendar: Calendar = .current) -> Date? {
        guard HomeFeeds.isDay(day), isClock(clock) else { return nil }
        let d: [Int] = day.split(separator: "-").compactMap { Int($0) }
        let c: [Int] = clock.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, c.count == 2 else { return nil }
        var comps = DateComponents()
        comps.year = d[0]
        comps.month = d[1]
        comps.day = d[2]
        comps.hour = c[0]
        comps.minute = c[1]
        return calendar.date(from: comps)
    }

    /// 年表の行を、会話（や過ごし方の塊）のあいだに振り分ける。返すのは anchors.count + 1 個の並び:
    /// 0 番は、どの始まりよりも前の行。k 番（1〜）は、anchors[k-1] に始まったものより後（次に始まるものより前）の行。
    /// anchors はふつう古い順。並んでいなくても、行の時刻以前に始まった中でいちばん遅いものの後ろに入れる
    static func slots(anchors: [Date], rows: [TimelineRow], day: String, calendar: Calendar = .current) -> [[TimelineRow]] {
        var out: [[TimelineRow]] = []
        for _ in 0...anchors.count { out.append([]) }
        for row in rows {
            guard let when = date(day: day, clock: row.time, calendar: calendar) else { continue }
            var best: Int = -1
            var bestStart: Date = .distantPast
            for (i, start) in anchors.enumerated() where start <= when {
                if best < 0 || start >= bestStart {
                    best = i
                    bestStart = start
                }
            }
            out[best + 1].append(row)
        }
        return out
    }

    /// lane の印（SF Symbols）
    static func laneIcon(_ lane: String) -> String {
        switch lane {
        case "位置": return "mappin.and.ellipse"
        case "決済": return "yensign.circle"
        case "LINE": return "message"
        case "予定": return "calendar"
        case "写真": return "photo"
        case "閲覧": return "safari"
        case "PC": return "desktopcomputer"
        case "iPhone": return "iphone"
        case "体調": return "heart"
        case "天気": return "cloud.sun"
        case "注文": return "shippingbox"
        case "会話": return "text.bubble"
        default: return "circle"
        }
    }

    /// 「12:10〜12:45」「8:05」
    static func timeLabel(_ row: TimelineRow) -> String {
        guard let end = row.end, end != row.time else { return row.time }
        return row.time + "〜" + end
    }

    /// 行の右に添えるもの（決済は金額・位置は場所。文に入っていれば添えない）
    static func detail(_ row: TimelineRow) -> String? {
        if row.lane == "決済", let amount = row.amount { return "\(amount.formatted())円" }
        if row.lane == "位置", let place = row.place, !row.text.contains(place) { return place }
        return nil
    }

    /// 家の PC が配る日か（今日を入れて14日）
    static func isRecent(_ day: String, now: Date, calendar: Calendar = .current) -> Bool {
        guard let date = HealthExport.dayDate(day, calendar: calendar) else { return false }
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(recentDays - 1), to: today) else { return false }
        return date >= first && date <= today
    }

    /// 今日か昨日か（家の PC につながらないとき、写しを使ったことをそっと知らせる日）
    static func isTodayOrYesterday(_ day: String, now: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return day == HealthExport.dayKey(today, calendar: calendar) || day == HealthExport.dayKey(yesterday, calendar: calendar)
    }
}

// MARK: - 反映の見張り（34）

struct ReflectionTable: Codable, Equatable {
    struct Element: Codable, Equatable, Identifiable {
        var element: String
        /// destinations と同じ並び。最後に反映された日（"yyyy-MM-dd"。無ければ nil）
        var cells: [String?]
        var id: String { element }
    }

    var generated_at: String? = nil
    /// 家の PC の今日（"yyyy-MM-dd"。無ければ端末の今日で数える）
    var today: String? = nil
    var destinations: [String] = []
    var elements: [Element] = []
}

enum Reflection {
    static let elementLimit = 40
    static let destinationLimit = 13
    /// この日数より遅れたら色を付ける
    static let warnDays = 2
    static let badDays = 5
    static let entryName = "取り込み"

    private struct Raw: Decodable {
        var available: Bool?
        var generated_at: String?
        var today: String?
        var destinations: [LossyRow<String>]?
        var elements: [LossyRow<RawElement>]?
    }

    private struct RawElement: Decodable {
        var element: String?
        var cells: [LossyRow<String>]?
    }

    /// GET /reflection の答え。読めない・{"available": false} なら nil
    static func decode(_ data: Data) -> ReflectionTable? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.available != false else { return nil }
        var destinations: [String] = []
        for row in raw.destinations ?? [] {
            guard let name = MothershipFeeds.cut(row.value, 20) else { continue }
            destinations.append(name)
            if destinations.count >= destinationLimit { break }
        }
        guard !destinations.isEmpty else { return nil }
        var elements: [ReflectionTable.Element] = []
        var seen = Set<String>()
        for row in raw.elements ?? [] {
            guard let e = row.value, let name = MothershipFeeds.cut(e.element, 20), seen.insert(name).inserted else { continue }
            var cells: [String?] = []
            let listed: [LossyRow<String>] = e.cells ?? []
            for i in 0..<destinations.count {
                var value: String? = nil
                if i < listed.count, let text = listed[i].value, HomeFeeds.isDay(text) { value = text }
                cells.append(value)
            }
            elements.append(ReflectionTable.Element(element: name, cells: cells))
            if elements.count >= elementLimit { break }
        }
        let today: String? = HomeFeeds.isDay(raw.today) ? raw.today : nil
        return ReflectionTable(generated_at: raw.generated_at, today: today, destinations: destinations, elements: elements)
    }

    /// from から to までの日数（どちらかが読めなければ nil）
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let a = HealthExport.dayDate(from, calendar: calendar), let b = HealthExport.dayDate(to, calendar: calendar) else {
            return nil
        }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    /// 何日遅れているか。取り込みの列は今日から、ほかの列は取り込みの日から数える（取り込みが無ければ今日から）。
    /// 反映された日が無ければ nil（「—」）
    static func behind(_ cell: String?, entry: String?, today: String, isEntry: Bool) -> Int? {
        guard let cell else { return nil }
        let reference: String = isEntry ? today : (entry ?? today)
        guard let days = daysBetween(cell, reference) else { return nil }
        return max(0, days)
    }

    static func entryIndex(_ table: ReflectionTable) -> Int {
        table.destinations.firstIndex(of: entryName) ?? 0
    }

    /// 表の1マスの文字（遅れの日数。無ければ「—」）
    static func cellText(_ behind: Int?) -> String {
        guard let behind else { return "—" }
        return "\(behind)"
    }

    /// 2日以上遅れている所の数
    static func lateCount(_ table: ReflectionTable, today: String) -> Int {
        let entry: Int = entryIndex(table)
        var count = 0
        for e in table.elements {
            let entryDay: String? = entry < e.cells.count ? e.cells[entry] : nil
            for (i, cell) in e.cells.enumerated() {
                if let b = behind(cell, entry: entryDay, today: today, isEntry: i == entry), b >= warnDays { count += 1 }
            }
        }
        return count
    }
}

// MARK: - PayPay のスクリーンショット（28）

/// 写真から読めた支払いの1行（id は端末の中で見分けるためだけ。送らない）
struct PayShotRow: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    /// ISO8601（画面に時刻が無ければ nil）
    var time: String? = nil
    /// "yyyy-MM-dd"
    var day: String
    var shop: String
    var amount: Int
    var method: String = ""
}

enum PayShots {
    static let maxPhotos = 10
    static let maxRows = 60
    /// 家の PC に送る JPEG の大きさ（約束は 4MB まで。少し余らせる）
    static let maxBytes = 3_800_000
    /// 長い辺をこの点数までに縮める（Claude もこれより大きい画像は縮めて読む）
    static let maxSide: CGFloat = 1568
    static let sentFile = "paypay-shot-sent.json"

    private struct RawReply: Decodable {
        var rows: [LossyRow<RawRow>]?
    }

    private struct RawRow: Decodable {
        var time: LossyRow<String>?
        var day: String?
        var shop: LossyRow<String>?
        var amount: Int?
        var method: LossyRow<String>?
    }

    /// POST /pay/paypay-shot の答え。読めなければ nil（行が無ければ空）
    static func decode(_ data: Data) -> [PayShotRow]? {
        guard let raw = try? JSONDecoder().decode(RawReply.self, from: data), let listed = raw.rows else { return nil }
        var out: [PayShotRow] = []
        for row in listed {
            guard let r = row.value, let day = HomeFeeds.trimmed(r.day), HomeFeeds.isDay(day),
                  let amount = r.amount, amount > 0, amount < 10_000_000 else { continue }
            var item = PayShotRow(day: day, shop: MothershipFeeds.cut(r.shop?.value, 40) ?? "", amount: amount)
            if let t = HomeFeeds.trimmed(r.time?.value), t.hasPrefix(day), AppFeeds.parseTime(t) != nil { item.time = t }
            item.method = MothershipFeeds.cut(r.method?.value, 20) ?? ""
            out.append(item)
            if out.count >= maxRows { break }
        }
        return out
    }

    /// 同じ支払いか（日・金額・店・時刻）。何枚かの写真に同じ支払いが写ったときに1行にする
    static func sameKey(_ row: PayShotRow) -> String {
        row.day + "|" + String(row.amount) + "|" + row.shop + "|" + (row.time ?? "")
    }

    /// すでに取り込んだかを見る印（日と金額）
    static func knownKey(day: String, amount: Int) -> String { day + "|" + String(amount) }

    static func merged(_ list: [PayShotRow], adding: [PayShotRow]) -> [PayShotRow] {
        var out: [PayShotRow] = list
        var seen = Set<String>()
        for r in list { seen.insert(sameKey(r)) }
        for r in adding where seen.insert(sameKey(r)).inserted {
            out.append(r)
        }
        return out
    }

    /// もうある支払いか: アプリの支払い（PayPay の明細・カードの利用速報・かざした記録）に同じ日・同じ金額があるか、前に送った行か
    static func isKnown(_ row: PayShotRow, payments: [Payment], sent: Set<String>, calendar: Calendar = .current) -> Bool {
        if sent.contains(knownKey(day: row.day, amount: row.amount)) { return true }
        for p in payments where p.amount == row.amount {
            if HealthExport.dayKey(p.time, calendar: calendar) == row.day { return true }
        }
        return false
    }

    /// 入れた金額（「1,200」「１２００円」も読む）。1円〜999万9999円でなければ nil
    static func parseAmount(_ text: String) -> Int? {
        let digits: String = text.precomposedStringWithCompatibilityMapping.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 7, let value = Int(digits), value > 0 else { return nil }
        return value
    }

    private struct SendRow: Encodable {
        let time: String?
        let day: String
        let shop: String
        let amount: Int
        let method: String
    }

    private struct SendBody: Encodable {
        let rows: [SendRow]
    }

    /// POST /pay/paypay-rows の中身。行が無い・おかしな行があれば nil
    static func body(_ rows: [PayShotRow]) -> Data? {
        guard !rows.isEmpty, rows.count <= 200 else { return nil }
        var out: [SendRow] = []
        for r in rows {
            let shop: String = r.shop.trimmingCharacters(in: .whitespacesAndNewlines)
            let method: String = r.method.trimmingCharacters(in: .whitespacesAndNewlines)
            guard HomeFeeds.isDay(r.day), r.amount > 0, r.amount < 10_000_000, shop.count <= 40, method.count <= 20 else {
                return nil
            }
            if let t = r.time, !t.hasPrefix(r.day) || AppFeeds.parseTime(t) == nil { return nil }
            out.append(SendRow(time: r.time, day: r.day, shop: shop, amount: r.amount, method: method))
        }
        return try? JSONEncoder().encode(SendBody(rows: out))
    }

    /// 写真を家の PC に送る JPEG に（長い辺を縮め、大きければ質を下げる）。開けなければ nil
    static func jpeg(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size: CGSize = image.size
        let longest: CGFloat = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale: CGFloat = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized: UIImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        let qualities: [CGFloat] = [0.8, 0.6, 0.4, 0.3]
        for q in qualities {
            if let out = resized.jpegData(compressionQuality: q), out.count <= maxBytes { return out }
        }
        return nil
    }
}

// MARK: - 位置を当日のうちに（30）

struct LiveStay: Codable, Equatable {
    var start: Date
    /// まだいる（今の滞在）なら nil
    var end: Date? = nil
    var lat: Double
    var lon: Double
    var name: String? = nil
    /// home・work・shop・other（分からなければ nil）
    var kind: String? = nil
}

/// 送る前の滞在と、送った印（live-stays.json。端末ごと・同期しない）
struct LiveStayState: Codable, Equatable {
    var queue: [LiveStay] = []
    /// 始まり（1970 からの秒）→ 送った中身の印
    var sent: [String: String] = [:]
    var lastTried: Date? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queue = try c.decodeIfPresent([LiveStay].self, forKey: .queue) ?? []
        sent = try c.decodeIfPresent([String: String].self, forKey: .sent) ?? [:]
        lastTried = try c.decodeIfPresent(Date.self, forKey: .lastTried)
    }

    private enum CodingKeys: String, CodingKey {
        case queue, sent, lastTried
    }
}

enum LiveStays {
    /// 送るのは、これより間をあけて（15分に1回まで）
    static let every: TimeInterval = 15 * 60
    /// ためておく数
    static let limit = 300
    /// 点から作る滞在は、次の点までこれより短ければ、移動の途中とみなして送らない
    static let minStay: TimeInterval = 10 * 60
    /// 送った印は、この日数で消す
    static let keepDays: Double = 3
    static let kinds: [String] = ["home", "work", "shop", "other"]

    static func key(_ s: LiveStay) -> String { String(Int(s.start.timeIntervalSince1970)) }

    static func signature(_ s: LiveStay) -> String {
        let end: String = s.end.map { String(Int($0.timeIntervalSince1970)) } ?? "open"
        return end + "|" + (s.name ?? "") + "|" + (s.kind ?? "")
    }

    /// 位置の点から滞在に（次の点までそこにいた。最後の点は今の滞在で、終わりは nil）
    static func fromPoints(_ points: [LocationExport.Point]) -> [LiveStay] {
        let sorted: [LocationExport.Point] = points.sorted { $0.time < $1.time }
        var out: [LiveStay] = []
        for (i, p) in sorted.enumerated() {
            let next: Date? = i + 1 < sorted.count ? sorted[i + 1].time : nil
            if let next, next.timeIntervalSince(p.time) < minStay { continue }
            out.append(LiveStay(start: p.time, end: next, lat: p.latitude, lon: p.longitude, name: p.name, kind: nil))
        }
        return out
    }

    /// 今の滞在の一覧のうち、まだ送っていない・前に送ったものと変わったものを、ためるものに足す（同じ始まりは新しい方に）
    static func pending(_ current: [LiveStay], state: LiveStayState) -> LiveStayState {
        var next = state
        for s in current {
            let k = key(s)
            if next.sent[k] == signature(s) { continue }
            next.queue.removeAll { key($0) == k }
            next.queue.append(s)
        }
        next.queue.sort { $0.start < $1.start }
        if next.queue.count > limit { next.queue = Array(next.queue.suffix(limit)) }
        return next
    }

    /// 送れた（または家の PC に断られた）。印を付けて、ためたものから外す。古い印は消す
    static func sentAll(_ state: LiveStayState, _ sent: [LiveStay], now: Date) -> LiveStayState {
        var next = state
        for s in sent {
            let k = key(s)
            let sig = signature(s)
            next.sent[k] = sig
            next.queue.removeAll { key($0) == k && signature($0) == sig }
        }
        let cutoff: Double = now.timeIntervalSince1970 - keepDays * 86400
        next.sent = next.sent.filter { (Double($0.key) ?? 0) >= cutoff }
        return next
    }

    /// 送る時か（ためたものがあり、前に試してから15分たった）
    static func isDue(_ state: LiveStayState, now: Date) -> Bool {
        guard !state.queue.isEmpty else { return false }
        guard let last = state.lastTried else { return true }
        return now.timeIntervalSince(last) >= every
    }

    /// POST /location/stays の中身（{"stays": [{"start","end"|null,"lat","lon","name"|null,"kind"|null}]}）
    static func body(_ stays: [LiveStay], calendar: Calendar = .current) -> Data? {
        guard !stays.isEmpty else { return nil }
        var list: [[String: Any]] = []
        for s in stays.prefix(limit) {
            guard s.lat >= -90, s.lat <= 90, s.lon >= -180, s.lon <= 180 else { continue }
            var row: [String: Any] = ["start": HealthExport.stamp(s.start, calendar: calendar), "lat": s.lat, "lon": s.lon]
            if let end = s.end, end >= s.start {
                row["end"] = HealthExport.stamp(end, calendar: calendar)
            } else {
                row["end"] = NSNull()
            }
            if let name = MothershipFeeds.cut(s.name, 60) { row["name"] = name } else { row["name"] = NSNull() }
            if let kind = s.kind, kinds.contains(kind) { row["kind"] = kind } else { row["kind"] = NSNull() }
            list.append(row)
        }
        guard !list.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["stays": list], options: [.sortedKeys])
    }
}

// MARK: - 読み込みと送り

@MainActor
@Observable
final class OneTimelineBook {
    /// 日 → 年表（家の PC から読めた写し）
    private(set) var days: [String: TimelineDay] = [:]
    /// 新しい分を読めなかった日（つながらない・まだ無い）
    private(set) var stale: Set<String> = []
    private(set) var reflection: ReflectionTable?
    private(set) var reflectionFetched: Date?
    /// 前に送った PayPay の写真の行（日と金額。「もうある」の印に使う）
    private(set) var sentShots: Set<String> = []
    @ObservationIgnored private var tried: [String: Date] = [:]
    @ObservationIgnored private var live = LiveStayState()
    @ObservationIgnored private var sendingStays = false
    @ObservationIgnored private var fetchingReflection = false

    nonisolated static let folder = "timeline"
    nonisolated static let reflectionFile = "oneline-reflection.json"
    nonisolated static let liveFile = "live-stays.json"
    /// 同じ日を読み直すのは、これより間をあけて
    private static let again: TimeInterval = 60
    private static let reflectionEvery: TimeInterval = 30 * 60

    private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(name)
    }

    private static func dayURL(_ day: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(day + ".json")
    }

    private static func readDay(_ day: String) -> TimelineDay? {
        guard let data = try? Data(contentsOf: dayURL(day)) else { return nil }
        return try? JSONDecoder().decode(TimelineDay.self, from: data)
    }

    private static func writeDay(_ value: TimelineDay) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let dir = URL.applicationSupportDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dayURL(value.day), options: .atomic)
    }

    init() {
        if let data = try? Data(contentsOf: Self.url(Self.reflectionFile)) {
            reflection = try? JSONDecoder().decode(ReflectionTable.self, from: data)
        }
        if let data = try? Data(contentsOf: Self.url(Self.liveFile)), let saved = try? JSONDecoder().decode(LiveStayState.self, from: data) {
            live = saved
        }
        if let data = try? Data(contentsOf: Self.url(PayShots.sentFile)), let saved = try? JSONDecoder().decode([String].self, from: data) {
            sentShots = Set(saved)
        }
    }

    // MARK: 年表（25）

    /// 1日の画面に挟む行（会話は除く。写しが無ければ空）
    func rows(for day: String) -> [TimelineRow] {
        OneTimeline.shown(days[day]?.rows ?? [])
    }

    /// 年表の上に出す、そっとした一言（無ければ nil）。今日と昨日で、新しい分を読めなかったときだけ
    func note(for day: String, now: Date = .now) -> String? {
        guard stale.contains(day), OneTimeline.isTodayOrYesterday(day, now: now) else { return nil }
        if let fetched = days[day]?.fetched {
            return "家の PC につながらないので、" + HomeFeeds.clock(fetched) + " に読んだ分を出しています。"
        }
        return "家の PC につながると、場所・お金・LINE などもここに並びます。"
    }

    /// その日の写しを読み、家の PC から読み直す（同じ日は1分に1回まで）
    func refresh(day: String, pc: HomePC, force: Bool = false) async {
        if days[day] == nil, let saved = Self.readDay(day) { days[day] = saved }
        guard pc.isConfigured, OneTimeline.isRecent(day, now: .now) else { return }
        if !force, let at = tried[day], Date.now.timeIntervalSince(at) < Self.again { return }
        tried[day] = .now
        // 家の PC がまだ年表を配らない版なら、何も言わない（つながらないときは features が空のことがある）
        if !pc.features.isEmpty && !pc.features.contains("timeline") { return }
        guard pc.shouldTry, pc.features.contains("timeline") else {
            stale.insert(day)
            return
        }
        do {
            let data = try await pc.getJSONData("timeline", query: [URLQueryItem(name: "day", value: day)], timeout: 10)
            if var parsed = OneTimeline.decode(data, day: day) {
                parsed.fetched = .now
                days[day] = parsed
                Self.writeDay(parsed)
                stale.remove(day)
                Tally.add("timeline.fetched")
            } else {
                stale.insert(day)
            }
        } catch {
            stale.insert(day)
        }
    }

    /// アプリを開いたとき: 今日と昨日を先に読んでおく（家の PC につながらないときも、1日の画面に写しを出せるように）。古い写しは消す
    func prefetch(_ pc: HomePC, now: Date = .now) async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        await refresh(day: HealthExport.dayKey(today), pc: pc)
        await refresh(day: HealthExport.dayKey(yesterday), pc: pc)
        prune(now: now)
    }

    private func prune(now: Date) {
        let dir = URL.applicationSupportDirectory.appendingPathComponent(Self.folder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasSuffix(".json") {
            let day = String(name.dropLast(5))
            if !OneTimeline.isRecent(day, now: now) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                days.removeValue(forKey: day)
            }
        }
    }

    // MARK: 反映の見張り（34）

    func refreshReflection(_ pc: HomePC, force: Bool = false) async {
        guard !fetchingReflection, pc.shouldTry, pc.features.contains("reflection") else { return }
        if !force, let at = reflectionFetched, Date.now.timeIntervalSince(at) < Self.reflectionEvery { return }
        fetchingReflection = true
        defer { fetchingReflection = false }
        reflectionFetched = .now
        guard let data = try? await pc.appFeed("reflection", feature: "reflection"),
              let table = Reflection.decode(data) else { return }
        reflection = table
        if let encoded = try? JSONEncoder().encode(table) {
            try? encoded.write(to: Self.url(Self.reflectionFile), options: .atomic)
        }
    }

    // MARK: PayPay の写真（28）

    /// 送った行の印を残す（次に同じ支払いが写っても「もうある」にする）
    func noteShotsSent(_ rows: [PayShotRow]) {
        for r in rows { sentShots.insert(PayShots.knownKey(day: r.day, amount: r.amount)) }
        let list: [String] = Array(sentShots.sorted().suffix(2000))
        sentShots = Set(list)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: Self.url(PayShots.sentFile), options: .atomic)
        }
    }

    // MARK: 位置を当日のうちに（30）

    /// まだ送っていない滞在の数
    var waitingStays: Int { live.queue.count }

    /// 今の滞在の一覧をためるものに足し、15分たっていて家の PC が受けるなら送る
    func sendStays(_ current: [LiveStay], pc: HomePC, now: Date = .now) async {
        live = LiveStays.pending(current, state: live)
        saveLive()
        guard !sendingStays, LiveStays.isDue(live, now: now), pc.shouldTry, pc.features.contains("livestays") else { return }
        let batch: [LiveStay] = Array(live.queue.prefix(LiveStays.limit))
        guard let body = LiveStays.body(batch) else { return }
        sendingStays = true
        defer { sendingStays = false }
        live.lastTried = now
        do {
            _ = try await pc.postJSONData("location/stays", body: body, timeout: 15)
            live = LiveStays.sentAll(live, batch, now: now)
            Tally.add("livestays.sent")
        } catch {
            // 断られた（中身がおかしい）ものを送り続けないよう、印を付けて外す。つながらないときは残して、次に送る
            if let failure = error as? HomePC.Failure, case .server(_) = failure {
                live = LiveStays.sentAll(live, batch, now: now)
            }
        }
        saveLive()
    }

    private func saveLive() {
        guard let data = try? JSONEncoder().encode(live) else { return }
        try? data.write(to: Self.url(Self.liveFile), options: .atomic)
    }
}

// MARK: - Pipeline から

extension Pipeline {
    /// 位置を当日のうちに母艦へ（強化案 30）。「場所を記録する」がオフなら何もしない（ためもしない）。iPhone だけ（iPad と二重に送らない）
    func sendLiveStaysIfDue(now: Date = .now) async {
        guard places.isOn, UIDevice.current.userInterfaceIdiom != .pad else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -1, to: today) else { return }
        var current: [LiveStay] = []
        // 位置の点から（登録した場所・前に調べた地名があれば名前に）
        let points: [LocationExport.Point] = places.points(from: from, to: now.addingTimeInterval(60))
        var named: [LocationExport.Point] = []
        for p in points {
            var q = p
            q.name = places.knownName(latitude: p.latitude, longitude: p.longitude, accuracy: p.accuracy)
            named.append(q)
        }
        for s in LiveStays.fromPoints(named) {
            var stay = s
            stay.kind = places.placeKind(latitude: s.lat, longitude: s.lon, accuracy: 100)
            current.append(stay)
        }
        // 立ち寄り（「行ったお店」がオンのとき）
        for v in shopVisits.visits where v.arrival >= from {
            var stay = LiveStay(start: v.arrival, end: v.departure, lat: v.latitude, lon: v.longitude)
            stay.name = v.shownName ?? places.knownName(latitude: v.latitude, longitude: v.longitude, accuracy: v.accuracy)
            if v.state == .guessed || v.state == .confirmed {
                stay.kind = "shop"
            } else {
                stay.kind = places.placeKind(latitude: v.latitude, longitude: v.longitude, accuracy: v.accuracy)
            }
            current.append(stay)
        }
        await oneTimeline.sendStays(current, pc: homePC, now: now)
    }

    /// アプリを開いたとき: 今日と昨日の年表・反映の見張りを読み、滞在を送る
    func refreshOneTimeline() async {
        await oneTimeline.prefetch(homePC)
        await oneTimeline.refreshReflection(homePC)
        await sendLiveStaysIfDue()
    }
}

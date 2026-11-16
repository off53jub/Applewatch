import CoreLocation
import Foundation
import Observation

/// 場所の名前を本人が直せる（2026-11-16。強化案 89）。
/// 直せるもの: 会話の見出しの自動の地名（「〇〇駅近く」「〇〇付近」）・登録した場所の名前・場所のページの名前。
/// 直した名前は「位置」と、母艦の場所の番号（pl_。届いていれば）で覚えて、次から同じ所に使う。
/// 母艦へは POST /place-names（家の PC の features の "placenames"。MothershipOutbox。つながらないときは端末にためる）。
/// 形は docs/s16-place-links.md に書いた。名前と位置だけを送り、会話の中身は送らない。

// MARK: - 覚える1件

struct PlaceNameFix: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var latitude: Double
    var longitude: Double
    /// 母艦の場所の番号（pl_…）。届いていなければ nil
    var placeID: String? = nil
    var at: Date = .now
    /// どこで直したか（conversation・page・registered・watch・visit・checkup）
    var source: String = "app"

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

/// 帳に残す形（読めなければ前のものを横に置く）
struct PlaceNameSaved: Codable, Equatable {
    var fixes: [PlaceNameFix] = []
    /// 場所の番号 → 直した名前（場所のページ用。位置が無くても覚えられる）
    var pageNames: [String: String] = [:]

    init(fixes: [PlaceNameFix] = [], pageNames: [String: String] = [:]) {
        self.fixes = fixes
        self.pageNames = pageNames
    }

    /// 足りない項目は空として読む（前の形・足した項目を読めるように）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fixes = try c.decodeIfPresent([PlaceNameFix].self, forKey: .fixes) ?? []
        pageNames = try c.decodeIfPresent([String: String].self, forKey: .pageNames) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case fixes, pageNames }
}

// MARK: - 決まり（通信しない・テストする部分）

enum PlaceNameRules {
    /// この距離（m）の中なら、同じ所とみなす
    static let radius: Double = 120
    /// 同じ所に直し直したら、前のものと置き換える距離（m）
    static let sameSpot: Double = 30
    static let limit = 500
    static let nameLimit = 40

    /// 名前を整える（空・長すぎるものは nil。先頭の「たぶん」は外す）
    static func clean(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("たぶん") { s = String(s.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !s.isEmpty else { return nil }
        if s.count > nameLimit { s = String(s.prefix(nameLimit)) }
        return s
    }

    /// その位置にいちばん近い直した名前。位置の精度が粗いときは、その分だけ広げる（100 m まで）
    static func nearest(_ fixes: [PlaceNameFix], latitude: Double, longitude: Double, accuracy: Double) -> PlaceNameFix? {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let slack: Double = min(max(accuracy, 0), 100)
        var best: PlaceNameFix?
        var bestDistance: Double = .greatestFiniteMagnitude
        for fix in fixes {
            let d: Double = fix.location.distance(from: here)
            if d <= radius + slack, d < bestDistance {
                best = fix
                bestDistance = d
            }
        }
        return best
    }

    /// 足す。同じ所（30 m 以内）か同じ場所の番号の前のものは置き換える。多すぎたら古いものから捨てる
    static func adding(_ fixes: [PlaceNameFix], _ fix: PlaceNameFix, limit: Int = PlaceNameRules.limit) -> [PlaceNameFix] {
        var next: [PlaceNameFix] = []
        for old in fixes {
            if old.location.distance(from: fix.location) <= sameSpot { continue }
            if let pl = fix.placeID, old.placeID == pl { continue }
            next.append(old)
        }
        next.append(fix)
        while next.count > limit { next.removeFirst() }
        return next
    }

    /// 場所のページに出す名前（直したものがあればそれ）
    static func shown(pageID: String, original: String, pageNames: [String: String]) -> String {
        pageNames[pageID] ?? original
    }

    // MARK: 母艦に送る形

    struct Body: Codable, Equatable {
        let name: String
        let lat: Double?
        let lon: Double?
        let pl: String?
        let from: String
        let day: String
        let at: String
    }

    static let sources: Set<String> = ["conversation", "page", "registered", "watch", "visit", "checkup", "app"]

    /// 5 桁（約 1 m）に丸める
    static func rounded(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }

    /// POST /place-names の中身。名前が空なら nil。位置の無いもの（場所のページ）は lat・lon を付けない
    static func body(name: String, latitude: Double?, longitude: Double?, placeID: String?, source: String, at: Date,
                     timeZone: TimeZone = .current) -> Data? {
        guard let cleaned = clean(name) else { return nil }
        var lat: Double?
        var lon: Double?
        if let latitude, let longitude {
            lat = rounded(latitude)
            lon = rounded(longitude)
        }
        let pl: String? = (placeID?.isEmpty == false) ? placeID : nil
        let from: String = sources.contains(source) ? source : "app"
        let body = Body(name: cleaned, lat: lat, lon: lon, pl: pl, from: from, day: PCJSON.dayString(at),
                        at: MothershipOutbox.isoString(at, timeZone: timeZone))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(body)
    }
}

// MARK: - 帳

@MainActor
@Observable
final class PlaceNameBook {
    static let shared = PlaceNameBook()

    private(set) var fixes: [PlaceNameFix] = []
    private(set) var pageNames: [String: String] = [:]
    /// 直した数の更新を画面に知らせる
    private(set) var version = 0
    @ObservationIgnored private var loaded = false

    private static var url: URL { URL.applicationSupportDirectory.appendingPathComponent("place-name-fixes.json") }

    init() {
        load()
    }

    /// 読む（読めなかったファイルは上書きせず、横に置く）。読む前には保存しない
    private func load() {
        defer { loaded = true }
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode(PlaceNameSaved.self, from: data) {
            fixes = saved.fixes
            pageNames = saved.pageNames
        } else {
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("place-name-fixes-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    private func save() {
        guard loaded else { return }
        version += 1
        let saved = PlaceNameSaved(fixes: fixes, pageNames: pageNames)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// その位置で直した名前（無ければ nil）
    func name(near location: CLLocation, accuracy: Double) -> String? {
        PlaceNameRules.nearest(fixes, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                               accuracy: accuracy)?.name
    }

    /// その位置で直した名前の一覧（近い順に 3 つまで。30 分の「ここは？」の候補に使う）
    func names(near location: CLLocation, limit: Int = 3) -> [String] {
        var scored: [(String, Double)] = []
        for fix in fixes {
            let d: Double = fix.location.distance(from: location)
            if d <= PlaceNameRules.radius * 2 { scored.append((fix.name, d)) }
        }
        scored.sort { $0.1 < $1.1 }
        var out: [String] = []
        for item in scored where !out.contains(item.0) {
            out.append(item.0)
            if out.count >= limit { break }
        }
        return out
    }

    /// 位置の名前を直す（覚えて、母艦に送る）。直せたら true
    @discardableResult
    func fix(name: String, latitude: Double, longitude: Double, placeID: String? = nil, source: String, now: Date = .now) -> Bool {
        guard loaded, let cleaned = PlaceNameRules.clean(name) else { return false }
        let fix = PlaceNameFix(name: cleaned, latitude: latitude, longitude: longitude, placeID: placeID, at: now, source: source)
        fixes = PlaceNameRules.adding(fixes, fix)
        if let placeID, !placeID.isEmpty { pageNames[placeID] = cleaned }
        save()
        send(name: cleaned, latitude: latitude, longitude: longitude, placeID: placeID, source: source, now: now)
        Tally.add("placename.fixed")
        Tally.add("placename.fixed." + (PlaceNameRules.sources.contains(source) ? source : "app"))
        return true
    }

    /// 場所のページの名前を直す（位置は無い。場所の番号で覚えて、母艦に送る）
    @discardableResult
    func fixPage(id: String, name: String, now: Date = .now) -> Bool {
        guard loaded, !id.isEmpty, let cleaned = PlaceNameRules.clean(name) else { return false }
        pageNames[id] = cleaned
        save()
        send(name: cleaned, latitude: nil, longitude: nil, placeID: id, source: "page", now: now)
        Tally.add("placename.fixed")
        Tally.add("placename.fixed.page")
        return true
    }

    /// 場所のページに出す名前
    func shown(pageID: String, original: String) -> String {
        PlaceNameRules.shown(pageID: pageID, original: original, pageNames: pageNames)
    }

    /// 直した名前を消す（場所のページ）
    func resetPage(id: String) {
        guard loaded, pageNames[id] != nil else { return }
        pageNames[id] = nil
        save()
    }

    private func send(name: String, latitude: Double?, longitude: Double?, placeID: String?, source: String, now: Date) {
        guard let body = PlaceNameRules.body(name: name, latitude: latitude, longitude: longitude, placeID: placeID,
                                             source: source, at: now) else { return }
        MothershipOutbox.enqueue(path: "place-names", body: body, now: now)
    }
}

// MARK: - 会話の見出しの場所を直す

extension Pipeline {
    /// 会話の見出しの場所の名前を直す。直した名前は、その会話の始まりの位置で覚える（位置が 7 日より前で残っていなければ、見出しだけ直す）
    func renameConversationPlace(first: Date, starts: [Date], day: String, to name: String) async {
        guard let cleaned = PlaceNameRules.clean(name) else { return }
        if let point = places.fixPoint(at: first) {
            PlaceNameBook.shared.fix(name: cleaned, latitude: point.latitude, longitude: point.longitude, source: "conversation")
        } else {
            Tally.add("placename.nopoint")
        }
        await conversations.setPlace(cleaned, starts: starts, day: day)
    }
}

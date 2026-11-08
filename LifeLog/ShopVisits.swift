import CoreLocation
import Foundation
import MapKit
import Observation
import Security

/// 行ったお店（2026-11-08）。iPhone が「ここにしばらくいた」と知らせてくる立ち寄り（CLVisit）ごとに、
/// 近くのお店（Apple の地図。はっきりしないときだけ Google）と、その時間の会話（端末の中だけで読む）から、
/// 「12:10〜12:45 たぶん〇〇」と推測する。本人が「合っている」・ほかの候補・名前を入れる・「お店ではない」で決める。
/// 中身は `shop-visits.json` に端末ごとに持つ（同期はしない。小さいので長く残す）。docs/shop-visits.md

/// お店の種類（会話の言葉の手がかりに使う）
enum ShopKind: String, Codable, CaseIterable {
    case food, cafe, store, pharmacy, beauty, fitness, nightlife, other

    var label: String {
        switch self {
        case .food: "食べるお店"
        case .cafe: "カフェ・パン"
        case .store: "お店"
        case .pharmacy: "薬局"
        case .beauty: "美容"
        case .fitness: "ジム"
        case .nightlife: "飲み屋"
        case .other: "そのほか"
        }
    }
}

/// お店の候補1つ
struct ShopCandidate: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        /// Apple の地図
        case apple
        /// Google（Places API）。名前と位置は30日まで（本人が決めたものは除く）
        case google
        /// 本人が前に決めた・入れた名前
        case mine
    }

    var id: String
    var source: Source
    /// お店の名前。Google の候補は30日たつと消す（nil）
    var name: String?
    var kind: ShopKind
    /// 立ち寄りの位置からの距離（m）
    var distance: Double
    var latitude: Double? = nil
    var longitude: Double? = nil
    /// Google の place id（長く残してよい）
    var googleID: String? = nil
    /// 調べた時刻
    var fetched: Date
    /// 推測の点数（大きいほど、たぶんここ）
    var score: Double = 0
    /// 点数の手がかり（「会話に名前」など。画面に出す）
    var clues: [String]? = nil
}

/// 立ち寄り1回
struct ShopVisit: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        /// まだ推測していない（いる途中・調べられなかった）
        case waiting
        /// 推測した（たぶん）
        case guessed
        /// 本人が決めた
        case confirmed
        /// 本人が「お店ではない」にした
        case notShop
    }

    var id = UUID().uuidString
    var arrival: Date
    /// 出た時刻。まだいる（分からない）なら nil
    var departure: Date? = nil
    var latitude: Double
    var longitude: Double
    /// 位置の精度（m）
    var accuracy: Double
    var state: State = .waiting
    /// 点数の高い順
    var candidates: [ShopCandidate] = []
    /// いちばん点数の高い候補
    var guessID: String? = nil
    /// 本人が決めた名前（本人のもの。消さない）
    var confirmedName: String? = nil
    var confirmedID: String? = nil
    /// 近くのお店を調べた時刻（調べられなかったら nil のまま。あとでやり直す）
    var searchedAt: Date? = nil
    /// Google にも聞いたか（1回の立ち寄りで1回まで）
    var googleTried: Bool? = nil
    /// 推測に使った会話の行の数（増えたら推測し直す）
    var linesRead: Int? = nil
    /// 仕事の時間・職場なので会話を読まなかった
    var skippedAudio: Bool? = nil
    var updated: Date = .now

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    var guess: ShopCandidate? { candidates.first { $0.id == guessID } }

    /// 画面と会話の見出しに出す名前（決めたものはそのまま、推測は「たぶん」を付ける）
    var shownName: String? {
        switch state {
        case .confirmed: return confirmedName
        case .guessed: return guess?.name.map { "たぶん" + $0 }
        case .waiting, .notShop: return nil
        }
    }
}

/// 推測の決まり（通信しない・テストする部分）
enum ShopGuess {
    /// これより短い立ち寄りは残さない（出た時刻が分かるとき）
    static let minStay: TimeInterval = 180
    /// 1位と2位の点数の差がこれより小さければ「はっきりしない」
    static let ambiguousGap = 0.25
    /// 候補の数
    static let maxCandidates = 8
    /// Google の名前と位置を残す日数
    static let googleKeepDays = 30
    static let defaultDayCap = 20
    static let defaultMonthCap = 300

    /// 近くのお店を探す半径（位置の精度を 40〜150m に収める）
    static func searchRadius(accuracy: Double) -> Double {
        min(max(accuracy, 40), 150)
    }

    // MARK: - 残す立ち寄り

    /// 残す立ち寄りか。短すぎる（3分未満）・登録した場所（自宅・会社など）の中は残さない。
    static func keep(arrival: Date, departure: Date?, latitude: Double, longitude: Double, accuracy: Double,
                     places: [PlaceLog.Place]) -> Bool {
        if let departure, departure.timeIntervalSince(arrival) < minStay { return false }
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let slack = min(max(accuracy, 0), 100)
        return !places.contains { $0.location.distance(from: here) <= $0.radius + slack }
    }

    /// いる途中として残っている立ち寄りのうち、同じ立ち寄りの知らせ（出た時刻など）が来たもの
    static func openIndex(_ visits: [ShopVisit], latitude: Double, longitude: Double, arrival: Date?) -> Int? {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return visits.lastIndex { v in
            guard v.departure == nil, v.location.distance(from: here) < 200 else { return false }
            guard let arrival else { return true }
            return abs(v.arrival.timeIntervalSince(arrival)) < 300
        }
    }

    /// あとで推測し直すか（出てから24時間以内・まだ決めていない・調べられなかったか、会話の行が増えた）
    static func needsRetry(_ v: ShopVisit, lineCount: Int, now: Date) -> Bool {
        guard v.state == .waiting || v.state == .guessed, let end = windowEnd(v, now: now),
              now.timeIntervalSince(end) < 24 * 3600 else { return false }
        return v.searchedAt == nil || lineCount != (v.linesRead ?? 0)
    }

    /// 会話を読む時間の終わり。出た時刻が分からず6時間たったら、着いてから1時間とみなす。まだいるなら nil
    static func windowEnd(_ v: ShopVisit, now: Date) -> Date? {
        if let d = v.departure { return d }
        return now.timeIntervalSince(v.arrival) > 6 * 3600 ? v.arrival.addingTimeInterval(3600) : nil
    }

    // MARK: - 名前をそろえる

    /// 比べるための形。全角英数は半角・半角カナは全角に、ひらがなはカタカナに、英字は小文字に。空白と記号は除く。
    static func normalize(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping
        s = s.applyingTransform(.hiraganaToKatakana, reverse: false) ?? s
        s = s.lowercased()
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        let scalars = s.unicodeScalars.filter { !drop.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// 名前だけでは何の店か分からない、ありふれた言葉（これだけでは名前の手がかりにしない）
    private static let generic: Set<String> = Set([
        "コーヒー", "カフェ", "cafe", "coffee", "レストラン", "食堂", "ストア", "ショップ", "shop", "store",
        "薬局", "ドラッグ", "ドラッグストア", "スーパー", "ベーカリー", "バー", "居酒屋", "ラーメン", "うどん", "そば",
        "すし", "寿司", "焼肉", "パン", "ジム", "サロン", "ヘアサロン", "美容室", "クリニック", "本店", "支店",
    ].map(normalize))

    private static let shopSuffixes = ["本店", "支店", "店舗", "号店", "店"]

    private static func isKanji(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || $0 == "々" }
    }

    /// 会話の中で探す名前の形。先頭は名前全体。そのあとに「〇〇店」を除いた形・区切りごとの部分。
    /// 例:「スターバックス コーヒー 渋谷店」→ スターバックスコーヒー渋谷店・スターバックスコーヒー渋谷・スターバックス
    ///    「マクドナルド渋谷店」→ マクドナルド渋谷店・マクドナルド渋谷・マクドナルド
    static func nameKeys(_ name: String) -> [String] {
        let full = normalize(name)
        var keys = [full]
        func add(_ k: String) {
            let usable = k.count >= 3 || (k.count == 2 && k.allSatisfy(isKanji))
            if usable, !generic.contains(k), !keys.contains(k) { keys.append(k) }
        }
        func stripShop(_ s: String) -> String {
            for suffix in shopSuffixes where s.hasSuffix(suffix) && s.count > suffix.count + 1 {
                return String(s.dropLast(suffix.count))
            }
            return s
        }
        let noShop = stripShop(full)
        if noShop != full {
            add(noShop)
            // 末尾の漢字（地名）を取る（カタカナ・英字の名前に地名が続くとき）
            let trimmed = String(String(noShop.reversed().drop(while: isKanji)).reversed())
            if trimmed != noShop { add(trimmed) }
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "・/()（）「」-‐－"))
        let parts = name.components(separatedBy: separators).map(normalize).filter { !$0.isEmpty }
        if parts.count > 1 {
            for p in parts where !shopSuffixes.contains(where: { p.hasSuffix($0) }) { add(p) }
        }
        return keys.filter { !$0.isEmpty }
    }

    // MARK: - 会話の言葉の手がかり

    /// 言葉と、その言葉がよく出る種類
    private static let keywordGroups: [(words: [String], kinds: Set<ShopKind>)] = [
        (["ご注文", "お召し上がり", "店内", "テイクアウト", "お持ち帰り", "メニュー", "おかわり", "ごちそうさま", "いただきます", "お冷"],
         [.food, .cafe]),
        (["ラテ", "ドリンク", "フラペチーノ", "エスプレッソ"], [.cafe]),
        (["ポイントカード", "袋", "レシート", "温めますか", "試着", "在庫"], [.store, .pharmacy]),
        (["お会計", "お支払い", "現金で", "カードで"], [.store, .pharmacy, .food, .cafe]),
        (["処方箋", "お薬手帳", "お薬"], [.pharmacy]),
        (["カット", "シャンプー", "前髪", "カラー"], [.beauty]),
        (["乾杯", "生ビール", "飲み放題", "ハイボール"], [.nightlife, .food]),
        (["トレーニング", "マシン", "ストレッチ"], [.fitness]),
    ]

    /// その種類の言葉で、会話（normalize したもの）に出てきたもの
    static func keywordHits(_ said: String, kind: ShopKind) -> [String] {
        var hits: [String] = []
        for group in keywordGroups where group.kinds.contains(kind) {
            for word in group.words where said.contains(normalize(word)) && !hits.contains(word) {
                hits.append(word)
            }
        }
        return hits
    }

    // MARK: - 点数

    /// 候補に点数を付けて、高い順に並べる。
    /// 距離が元の点数（0〜1）。会話に名前が出たら +3（名前の一部なら +2）、本人が前に決めた店なら +1、
    /// 種類の言葉は1つ +0.25（0.75 まで）。
    static func score(_ list: [ShopCandidate], text: String, radius: Double, known: Set<String> = []) -> [ShopCandidate] {
        let said = normalize(text)
        let r = max(radius, 1)
        var out: [ShopCandidate] = []
        for var c in list {
            var s = max(0, 1 - c.distance / r)
            var why: [String] = []
            if let name = c.name {
                let keys = nameKeys(name)
                if !said.isEmpty, let first = keys.first, !generic.contains(first), said.contains(first) {
                    s += 3
                    why.append("会話に名前")
                } else if !said.isEmpty, keys.dropFirst().contains(where: { said.contains($0) }) {
                    s += 2
                    why.append("会話に名前の一部")
                }
                if known.contains(normalize(name)) {
                    s += 1
                    why.append("前にも来た")
                }
            }
            let hits = said.isEmpty ? [] : keywordHits(said, kind: c.kind)
            if !hits.isEmpty {
                s += min(Double(hits.count) * 0.25, 0.75)
                why.append("「" + hits.prefix(2).joined(separator: "」「") + "」")
            }
            c.score = (s * 100).rounded() / 100
            c.clues = why.isEmpty ? nil : why
            out.append(c)
        }
        return out.sorted { a, b in a.score != b.score ? a.score > b.score : a.distance < b.distance }
    }

    /// 1位と2位が近くて、はっきりしないか（並べたあとのもの）
    static func isAmbiguous(_ ranked: [ShopCandidate]) -> Bool {
        guard ranked.count >= 2 else { return false }
        return ranked[0].score - ranked[1].score < ambiguousGap
    }

    /// Google にも聞くか。Apple で見つからない・はっきりしないときで、キーがあり、上限の中で、まだ聞いていないときだけ。
    static func needsGoogle(_ ranked: [ShopCandidate], hasKey: Bool, underCap: Bool, alreadyTried: Bool) -> Bool {
        guard hasKey, underCap, !alreadyTried else { return false }
        return ranked.isEmpty || isAmbiguous(ranked)
    }

    /// 同じお店らしい名前か（そろえた形が同じか、片方がもう片方を含む）
    static func sameShop(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// Google の候補を足す（Apple の候補と同じ店は足さない）
    static func merged(_ base: [ShopCandidate], adding extra: [ShopCandidate]) -> [ShopCandidate] {
        var out = base
        for c in extra {
            guard let name = c.name else { continue }
            let dup = out.contains { $0.name.map { sameShop($0, name) } ?? false } || out.contains { $0.id == c.id }
            if !dup { out.append(c) }
        }
        return out
    }

    // MARK: - Google の回数の上限

    /// 今日・今月の回数
    struct Calls: Equatable {
        var day: Int
        var month: Int
    }

    static func underCap(day: Int, month: Int, dayCap: Int, monthCap: Int) -> Bool {
        day < dayCap && month < monthCap
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "d:%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "m:%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func callCounts(_ saved: [String: Int], now: Date, calendar: Calendar = .current) -> Calls {
        Calls(day: saved[dayKey(now, calendar: calendar)] ?? 0, month: saved[monthKey(now, calendar: calendar)] ?? 0)
    }

    /// 1回足す（今日と今月のほかは捨てる）
    static func bumped(_ saved: [String: Int], now: Date, calendar: Calendar = .current) -> [String: Int] {
        let d = dayKey(now, calendar: calendar), m = monthKey(now, calendar: calendar)
        return [d: (saved[d] ?? 0) + 1, m: (saved[m] ?? 0) + 1]
    }

    // MARK: - Google の決まり（名前と位置は30日まで）

    /// Google の候補の名前と位置を、30日たったら消す（place id は残す）。本人が決めた候補はそのまま。
    static func pruned(_ visits: [ShopVisit], now: Date) -> [ShopVisit] {
        let limit = now.addingTimeInterval(-Double(googleKeepDays) * 86400)
        return visits.map { v in
            var v = v
            v.candidates = v.candidates.map { c in
                guard c.source == .google, c.fetched < limit, c.name != nil || c.latitude != nil else { return c }
                if v.state == .confirmed && v.confirmedID == c.id { return c }
                var c = c
                c.name = nil
                c.latitude = nil
                c.longitude = nil
                c.clues = nil
                return c
            }
            return v
        }
    }

    // MARK: - お店の種類

    /// Apple の地図で探す種類
    static let appleCategories: [MKPointOfInterestCategory] = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .distillery, .foodMarket, .store, .pharmacy,
        .nightlife, .fitnessCenter, .beauty, .spa, .laundry, .movieTheater,
    ]

    static func kind(apple category: MKPointOfInterestCategory?) -> ShopKind {
        guard let category else { return .other }
        switch category {
        case .restaurant: return .food
        case .cafe, .bakery: return .cafe
        case .brewery, .winery, .distillery, .nightlife: return .nightlife
        case .foodMarket, .store: return .store
        case .pharmacy: return .pharmacy
        case .fitnessCenter: return .fitness
        case .beauty, .spa: return .beauty
        default: return .other
        }
    }

    /// Google の種類（primaryType を先に見る）
    static func kind(google types: [String]) -> ShopKind {
        for t in types {
            if ["cafe", "bakery", "coffee_shop", "tea_house", "dessert_shop", "ice_cream_shop"].contains(t) { return .cafe }
            if ["bar", "night_club", "pub", "wine_bar", "izakaya_restaurant"].contains(t) { return .nightlife }
            if t.hasSuffix("restaurant") || ["meal_takeaway", "meal_delivery", "food_court", "fast_food_restaurant"].contains(t) {
                return .food
            }
            if ["pharmacy", "drugstore"].contains(t) { return .pharmacy }
            if ["gym", "fitness_center"].contains(t) { return .fitness }
            if ["beauty_salon", "hair_care", "hair_salon", "nail_salon", "spa", "barber_shop"].contains(t) { return .beauty }
            if t.hasSuffix("store") || ["supermarket", "grocery_store", "shopping_mall", "market"].contains(t) { return .store }
        }
        return .other
    }

    /// お店ではない Google の種類（駅・公園・学校など。候補に入れない）
    static let googleNotShop: Set<String> = [
        "train_station", "subway_station", "transit_station", "bus_station", "bus_stop", "light_rail_station",
        "parking", "park", "school", "primary_school", "secondary_school", "university", "city_hall",
        "local_government_office", "police", "apartment_building", "housing_complex", "atm", "church", "shinto_shrine",
        "buddhist_temple", "hospital",
    ]
}

/// Google Places API (New) の Nearby Search（キーがあり、Apple の答えがはっきりしないときだけ）
enum GoogleNearby {
    static let endpoint = URL(string: "https://places.googleapis.com/v1/places:searchNearby")!
    static let fieldMask = "places.id,places.displayName,places.primaryType,places.types,places.location"

    static func request(key: String, latitude: Double, longitude: Double, radius: Double) -> URLRequest {
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        r.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        // キーを「iOS アプリ」で制限したとき、Google はこの印でアプリを見分ける（2026-11-08）
        if let bundle = Bundle.main.bundleIdentifier { r.setValue(bundle, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        let center: [String: Any] = ["latitude": latitude, "longitude": longitude]
        let circle: [String: Any] = ["center": center, "radius": radius]
        let body: [String: Any] = [
            "maxResultCount": 10,
            "rankPreference": "DISTANCE",
            "languageCode": "ja",
            "locationRestriction": ["circle": circle],
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    private struct Response: Decodable {
        struct Name: Decodable { let text: String? }
        struct Spot: Decodable { let latitude: Double; let longitude: Double }
        struct Place: Decodable {
            let id: String?
            let displayName: Name?
            let primaryType: String?
            let types: [String]?
            let location: Spot?
        }
        let places: [Place]?
    }

    /// 答えを候補にする（お店ではない種類は除く）
    static func parse(_ data: Data, latitude: Double, longitude: Double, now: Date) -> [ShopCandidate] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let here = CLLocation(latitude: latitude, longitude: longitude)
        var out: [ShopCandidate] = []
        for p in response.places ?? [] {
            guard let id = p.id, let name = p.displayName?.text, !name.isEmpty else { continue }
            let types = (p.primaryType.map { [$0] } ?? []) + (p.types ?? [])
            if let primary = p.primaryType, ShopGuess.googleNotShop.contains(primary) { continue }
            let spot = p.location.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) } ?? here
            out.append(ShopCandidate(id: "google:" + id, source: .google, name: name, kind: ShopGuess.kind(google: types),
                                     distance: here.distance(from: spot), latitude: p.location?.latitude,
                                     longitude: p.location?.longitude, googleID: id, fetched: now))
        }
        return out
    }
}

/// iPhone が知らせてきた立ち寄り（CLVisit から写したもの）
struct RawVisit: Sendable {
    let arrival: Date
    let departure: Date
    let latitude: Double
    let longitude: Double
    let accuracy: Double
}

/// 行ったお店の帳
@MainActor
@Observable
final class ShopVisitBook {
    nonisolated static let onKey = "shopVisitsOn"
    nonisolated private static let dayCapKey = "shopGoogleDayCap"
    nonisolated private static let monthCapKey = "shopGoogleMonthCap"
    nonisolated private static let callsKey = "shopGoogleCalls"

    /// 立ち寄りを受け取って推測する（オンのあいだだけ、位置の「立ち寄り」の知らせを受け取る）
    var isOn: Bool = UserDefaults.standard.bool(forKey: ShopVisitBook.onKey) {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.onKey)
            places?.setVisits(isOn)
        }
    }
    private(set) var visits: [ShopVisit] = []
    private(set) var hasGoogleKey: Bool = ShopKeychain.read() != nil
    var dayCap: Int = ShopVisitBook.savedCap(ShopVisitBook.dayCapKey, ShopGuess.defaultDayCap) {
        didSet { UserDefaults.standard.set(dayCap, forKey: Self.dayCapKey) }
    }
    var monthCap: Int = ShopVisitBook.savedCap(ShopVisitBook.monthCapKey, ShopGuess.defaultMonthCap) {
        didSet { UserDefaults.standard.set(monthCap, forKey: Self.monthCapKey) }
    }
    /// 今日・今月 Google に聞いた回数
    private(set) var googleCalls: ShopGuess.Calls = ShopGuess.callCounts(ShopVisitBook.savedCalls(), now: .now)

    @ObservationIgnored private weak var places: PlaceLog?
    /// PayPay の明細・カードの利用速報・かざした記録（Payments.swift）。答え合わせと、会話の見出しの名前に使う
    @ObservationIgnored weak var paymentBook: PaymentBook?
    /// その時間の会話の行（端末の中の記録から）
    @ObservationIgnored var lines: (Date, Date) -> [ConversationLog.Line] = { _, _ in [] }
    /// その時刻は仕事の時間・職場か（会話を読まない）
    @ObservationIgnored var isWork: (Date) -> Bool = { _ in false }
    /// ファイルを読み終えたか（読む前に保存しない）
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var running: Set<String> = []

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("shop-visits.json")

    nonisolated private static func savedCap(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    nonisolated private static func savedCalls() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: callsKey) as? [String: Int] ?? [:]
    }

    init() {
        load()
        #if DEBUG && targetEnvironment(simulator)
        if DemoData.isOn && visits.isEmpty { visits = Self.demoVisits() }
        #endif
    }

    private func load() {
        defer { loaded = true }
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let decoder = JSONDecoder()
        if let saved = try? decoder.decode([ShopVisit].self, from: data) {
            visits = ShopGuess.pruned(saved, now: .now)
        } else {
            // 読めないファイルは上書きせず、脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("shop-visits-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    private func save() {
        guard loaded else { return }
        visits = ShopGuess.pruned(visits, now: .now)
        guard let data = try? JSONEncoder().encode(visits) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Pipeline とつなぐ（位置・会話・仕事の時間）
    func attach(_ pipeline: Pipeline) {
        places = pipeline.places
        paymentBook = pipeline.payments
        pipeline.places.onVisit = { [weak self] raw in self?.received(raw) }
        isWork = { [weak pipeline] time in pipeline?.vocabularyContext(at: time) == .work }
        lines = { [weak pipeline] start, end in
            guard let pipeline else { return [] }
            return Self.visitLines(in: pipeline, from: start, to: end)
        }
        if isOn { pipeline.places.setVisits(true) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 立ち寄りの時間（前後2分）の会話の行。テレビ・動画の行は除く
    private static func visitLines(in pipeline: Pipeline, from start: Date, to end: Date) -> [ConversationLog.Line] {
        let from = start.addingTimeInterval(-120), to = end.addingTimeInterval(120)
        var days: [String] = []
        for t in [from, to] {
            let d = dayFormatter.string(from: t)
            if !days.contains(d) { days.append(d) }
        }
        var out: [ConversationLog.Line] = []
        for day in days {
            for c in pipeline.conversations(on: day) where c.media == nil && c.end >= from && c.start <= to {
                out += c.lines.filter { $0.media == nil && $0.time >= from && $0.time <= to }
            }
        }
        return out
    }

    // MARK: - 立ち寄りを受け取る

    func received(_ raw: RawVisit) {
        guard isOn, loaded else { return }
        let departure: Date? = raw.departure == .distantFuture ? nil : raw.departure
        let arrival: Date? = raw.arrival == .distantPast ? nil : raw.arrival
        let placeList = places?.places ?? []
        if let i = ShopGuess.openIndex(visits, latitude: raw.latitude, longitude: raw.longitude, arrival: arrival) {
            // いる途中の立ち寄りに、出た時刻が来た
            guard let departure else { return }
            let v = visits[i]
            if !ShopGuess.keep(arrival: v.arrival, departure: departure, latitude: v.latitude, longitude: v.longitude,
                               accuracy: v.accuracy, places: placeList) {
                visits.remove(at: i)
                save()
                return
            }
            visits[i].departure = departure
            visits[i].updated = .now
            save()
            let id = v.id
            Task { await guess(id) }
            return
        }
        guard let arrival else { return }
        let here = CLLocation(latitude: raw.latitude, longitude: raw.longitude)
        // 同じ立ち寄りが二度届いた
        let duplicate = visits.contains { v in
            abs(v.arrival.timeIntervalSince(arrival)) < 120 && v.location.distance(from: here) < 200
        }
        guard !duplicate, ShopGuess.keep(arrival: arrival, departure: departure, latitude: raw.latitude,
                                         longitude: raw.longitude, accuracy: raw.accuracy, places: placeList) else { return }
        let v = ShopVisit(arrival: arrival, departure: departure, latitude: raw.latitude, longitude: raw.longitude,
                          accuracy: max(raw.accuracy, 0))
        visits.append(v)
        visits.sort { $0.arrival < $1.arrival }
        save()
        if departure != nil {
            let id = v.id
            Task { await guess(id) }
        }
    }

    /// アプリを開いたとき: 24時間以内の、まだ決めていない立ち寄りを推測し直す（通信するのは調べられなかったものだけ）
    func retryRecent() {
        guard isOn, loaded else { return }
        let now = Date()
        for v in visits where v.state == .waiting || v.state == .guessed {
            guard let end = ShopGuess.windowEnd(v, now: now), now.timeIntervalSince(end) < 24 * 3600 else { continue }
            let work = isWork(v.arrival) || isWork(end)
            let count = work ? 0 : lines(v.arrival, end).count
            guard ShopGuess.needsRetry(v, lineCount: count, now: now) else { continue }
            let id = v.id
            Task { await guess(id) }
        }
    }

    // MARK: - 推測する

    func guess(_ id: String) async {
        guard !running.contains(id), let start = visits.first(where: { $0.id == id }),
              start.state == .waiting || start.state == .guessed else { return }
        running.insert(id)
        defer { running.remove(id) }
        let now = Date()
        let end = ShopGuess.windowEnd(start, now: now) ?? now
        let radius = ShopGuess.searchRadius(accuracy: start.accuracy)
        var candidates = start.candidates.filter { $0.source != .mine }
        var searched = start.searchedAt
        if searched == nil {
            let found = await Self.appleCandidates(latitude: start.latitude, longitude: start.longitude, radius: radius)
            if let found {
                candidates = found
                searched = now
            }
        }
        // 本人が前に決めた、近くのお店
        let known = knownShops(near: start)
        for k in known where !candidates.contains(where: { $0.name.map { ShopGuess.sameShop($0, k.name) } ?? false }) {
            candidates.append(ShopCandidate(id: "mine:" + ShopGuess.normalize(k.name), source: .mine, name: k.name,
                                            kind: k.kind, distance: k.distance, fetched: now))
        }
        let knownNames = Set(known.map { ShopGuess.normalize($0.name) })
        // 会話（仕事の時間・職場なら読まない）
        let work = isWork(start.arrival) || isWork(end)
        let heard: [ConversationLog.Line] = work ? [] : lines(start.arrival, end)
        let text = heard.map(\.text).joined(separator: "\n")
        var ranked = ShopGuess.score(candidates, text: text, radius: radius, known: knownNames)
        var tried = start.googleTried ?? false
        let key = ShopKeychain.read()
        let under = ShopGuess.underCap(day: googleCalls.day, month: googleCalls.month, dayCap: dayCap, monthCap: monthCap)
        if searched != nil, let key,
           ShopGuess.needsGoogle(ranked, hasKey: true, underCap: under, alreadyTried: tried) {
            tried = true
            countGoogleCall()
            let extra = await Self.googleCandidates(key: key, latitude: start.latitude, longitude: start.longitude,
                                                    radius: radius)
            let all = ShopGuess.merged(candidates, adding: extra)
            ranked = ShopGuess.score(all, text: text, radius: radius, known: knownNames)
        }
        // 待っているあいだに本人が決めたなら、上書きしない
        guard let i = visits.firstIndex(where: { $0.id == id }),
              visits[i].state == .waiting || visits[i].state == .guessed else { return }
        let top = Array(ranked.prefix(ShopGuess.maxCandidates + 2))
        visits[i].candidates = top
        visits[i].guessID = top.first?.id
        visits[i].state = top.isEmpty ? .waiting : .guessed
        visits[i].searchedAt = searched
        visits[i].googleTried = tried ? true : nil
        visits[i].linesRead = heard.count
        visits[i].skippedAudio = work ? true : nil
        visits[i].updated = .now
        save()
    }

    /// 本人が前に決めた、80m 以内のお店
    private func knownShops(near v: ShopVisit) -> [(name: String, kind: ShopKind, distance: Double)] {
        var out: [(name: String, kind: ShopKind, distance: Double)] = []
        for other in visits where other.id != v.id && other.state == .confirmed {
            guard let name = other.confirmedName, !out.contains(where: { ShopGuess.sameShop($0.name, name) }) else { continue }
            let d = other.location.distance(from: v.location)
            guard d <= 80 else { continue }
            let kind = other.candidates.first { $0.id == other.confirmedID }?.kind ?? .other
            out.append((name, kind, d))
        }
        return out
    }

    private static func appleCandidates(latitude: Double, longitude: Double, radius: Double) async -> [ShopCandidate]? {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: ShopGuess.appleCategories)
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            // 近くに何も無いのは「無し」。通信できないなどは失敗（あとでやり直す）
            if let e = error as? MKError, e.code == .placemarkNotFound { return [] }
            return nil
        }
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let now = Date()
        var out: [ShopCandidate] = []
        for item in response.mapItems {
            guard let name = item.name, !name.isEmpty else { continue }
            let spot: CLLocation = item.placemark.location ?? here
            let id = "apple:" + name + String(format: "@%.5f,%.5f", spot.coordinate.latitude, spot.coordinate.longitude)
            guard !out.contains(where: { $0.id == id }) else { continue }
            out.append(ShopCandidate(id: id, source: .apple, name: name, kind: ShopGuess.kind(apple: item.pointOfInterestCategory),
                                     distance: here.distance(from: spot), latitude: spot.coordinate.latitude,
                                     longitude: spot.coordinate.longitude, fetched: now))
        }
        let sorted = out.sorted { $0.distance < $1.distance }
        return Array(sorted.prefix(ShopGuess.maxCandidates))
    }

    private static func googleCandidates(key: String, latitude: Double, longitude: Double, radius: Double) async -> [ShopCandidate] {
        let request = GoogleNearby.request(key: key, latitude: latitude, longitude: longitude, radius: radius)
        let result = try? await URLSession.shared.data(for: request)
        guard let result, (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let found = GoogleNearby.parse(result.0, latitude: latitude, longitude: longitude, now: .now)
        return Array(found.prefix(ShopGuess.maxCandidates))
    }

    private func countGoogleCall() {
        let next = ShopGuess.bumped(Self.savedCalls(), now: .now)
        UserDefaults.standard.set(next, forKey: Self.callsKey)
        googleCalls = ShopGuess.callCounts(next, now: .now)
    }

    /// 画面を開いたとき、日が変わっていたら回数を出し直す
    func refreshCounts() {
        googleCalls = ShopGuess.callCounts(Self.savedCalls(), now: .now)
        hasGoogleKey = ShopKeychain.read() != nil
    }

    // MARK: - 本人が決める

    private func change(_ id: String, _ edit: (inout ShopVisit) -> Void) {
        guard let i = visits.firstIndex(where: { $0.id == id }) else { return }
        edit(&visits[i])
        visits[i].updated = .now
        save()
    }

    /// いちばんの候補で合っている
    func confirm(_ id: String) {
        change(id) { v in
            guard let g = v.guess, let name = g.name else { return }
            v.state = .confirmed
            v.confirmedName = name
            v.confirmedID = g.id
        }
    }

    /// ほかの候補にする
    func choose(_ id: String, candidate: String) {
        change(id) { v in
            guard let c = v.candidates.first(where: { $0.id == candidate }), let name = c.name else { return }
            v.state = .confirmed
            v.confirmedName = name
            v.confirmedID = c.id
            v.guessID = c.id
        }
    }

    /// 名前を入れる
    func setName(_ id: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        change(id) { v in
            v.state = .confirmed
            v.confirmedName = trimmed
            v.confirmedID = nil
        }
    }

    func markNotShop(_ id: String) {
        change(id) { v in
            v.state = .notShop
            v.confirmedName = nil
            v.confirmedID = nil
        }
    }

    /// 決めたのを取り消して、推測に戻す
    func undo(_ id: String) {
        change(id) { v in
            v.state = v.candidates.isEmpty ? .waiting : .guessed
            v.confirmedName = nil
            v.confirmedID = nil
        }
    }

    func remove(_ id: String) {
        visits.removeAll { $0.id == id }
        save()
    }

    /// その立ち寄りのあいだの PayPay の支払い（明細を読み込んであれば）
    func paid(_ v: ShopVisit) -> Payment? {
        guard let payments = paymentBook?.all, !payments.isEmpty else { return nil }
        return PaymentMatch.payment(for: v, in: payments)
    }

    /// 見出しに出す名前。本人が決めたものがいちばん。次に PayPay で払った先、次に推測（たぶん）
    func name(for v: ShopVisit) -> String? {
        switch v.state {
        case .confirmed, .notShop: return v.shownName
        case .guessed, .waiting: return paid(v).map { $0.shop + "（\($0.via)）" } ?? v.shownName
        }
    }

    /// 会話の見出しに添える名前（その会話と重なる立ち寄りの名前）。保存はしない
    func label(from start: Date, to end: Date) -> String? {
        guard isOn else { return nil }
        let hit = visits.last { v in
            let vEnd = v.departure ?? .distantFuture
            return v.arrival <= end && vEnd >= start && name(for: v) != nil
        }
        return hit.flatMap { name(for: $0) }
    }

    // MARK: - Google のキー（Keychain。この端末だけ）

    func saveGoogleKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { ShopKeychain.delete() } else { ShopKeychain.save(trimmed) }
        hasGoogleKey = ShopKeychain.read() != nil
    }

    // MARK: - 見本（画面の自動確認だけ）

    #if DEBUG && targetEnvironment(simulator)
    private static func demoVisits() -> [ShopVisit] {
        let now = Date()
        let a = now.addingTimeInterval(-3 * 3600)
        var v1 = ShopVisit(arrival: a, departure: a.addingTimeInterval(35 * 60), latitude: 35.0, longitude: 139.0, accuracy: 60)
        v1.state = .guessed
        v1.searchedAt = a
        v1.candidates = [
            ShopCandidate(id: "apple:demo1", source: .apple, name: "見本のカフェ", kind: .cafe, distance: 12, fetched: a,
                          score: 1.6, clues: ["「店内」"]),
            ShopCandidate(id: "apple:demo2", source: .apple, name: "見本のパン屋", kind: .cafe, distance: 40, fetched: a, score: 0.7),
        ]
        v1.guessID = "apple:demo1"
        v1.linesRead = 4
        let b = now.addingTimeInterval(-26 * 3600)
        var v2 = ShopVisit(arrival: b, departure: b.addingTimeInterval(20 * 60), latitude: 35.0, longitude: 139.0, accuracy: 80)
        v2.state = .confirmed
        v2.confirmedName = "見本の本屋"
        v2.searchedAt = b
        return [v2, v1]
    }
    #endif
}

/// Google Places のキー（キーチェーン。この端末だけ。コード・記録・設定には書かない）
private enum ShopKeychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.off53jub.lifelog",
            kSecAttrAccount as String: "google-places-key",
        ]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        // 裏で立ち寄りを受け取ったときにも読めるように、初回ロック解除後は読めるようにする
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

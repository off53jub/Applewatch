import CoreLocation
import MapKit
import Observation

/// どこで話したかを残す。大きく移動したとき（数百 m）だけ位置を受け取るので、電池はほとんど使わない。
/// 会話の見出しには、登録した場所（自宅・会社など）か、近くの駅・地名を出す。
@MainActor
@Observable
final class PlaceLog: NSObject, CLLocationManagerDelegate {
    struct Place: Codable, Identifiable {
        var id = UUID()
        var name: String
        var latitude: Double
        var longitude: Double
        /// この距離（m）の中なら、その場所にいるとみなす
        var radius: Double = 300
        /// 職場か（話者の聞き分けで、職場の人を先に比べる）
        var isWork: Bool?
        /// ここでは録音を休む（家の iPad が録音するとき用）。ない場合は休まない。
        var pausesRecording: Bool?

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    private struct Sample: Codable {
        let time: Date
        let latitude: Double
        let longitude: Double
        let accuracy: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    var isOn = UserDefaults.standard.bool(forKey: "places") {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "places")
            if isOn { start() } else { manager.stopMonitoringSignificantLocationChanges() }
            refreshVisitMonitoring(askAuthorization: false)
        }
    }
    private(set) var places: [Place] = []
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// 位置や場所の登録が変わったら呼ぶ
    @ObservationIgnored var onChange: (() -> Void)?
    /// しばらくいた所（立ち寄り）の知らせ。「行ったお店」がオンのときだけ受け取る（2026-11-08。ShopVisits.swift）
    @ObservationIgnored var onVisit: ((RawVisit) -> Void)?
    /// 立ち寄りの「着いた」「出た」の知らせ。「行ったお店」の設定に関係なく受ける（2026-11-16。強化案 88・91・104。PlaceAssist.swift）
    @ObservationIgnored var onVisitEvent: ((RawVisit) -> Void)?
    /// 大きく動いて新しい位置が届いたとき（2026-11-16。PlaceAssist.swift）
    @ObservationIgnored var onSample: ((CLLocation) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    /// 地名の問い合わせを減らすため、100 m 四方ごとに覚えておく
    @ObservationIgnored private var names: [String: String] = [:]
    /// 着いたときの細かい測りの返事を待っている（強化案 88）
    @ObservationIgnored private var arrivalFixPending = false

    private static let samplesURL = URL.applicationSupportDirectory.appendingPathComponent("locations.json")
    /// 端末間の同期用の、登録と削除の時刻（場所の一覧とは別に保存する）
    @ObservationIgnored private var times = UserDefaults.standard.data(forKey: "placeSync")
        .flatMap { try? JSONDecoder().decode(SyncTimes.self, from: $0) } ?? SyncTimes() {
        didSet {
            if let data = try? JSONEncoder().encode(times) { UserDefaults.standard.set(data, forKey: "placeSync") }
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
        if let data = UserDefaults.standard.data(forKey: "placeList"),
           let list = try? JSONDecoder().decode([Place].self, from: data) {
            places = list
        }
        if let data = try? Data(contentsOf: Self.samplesURL),
           let list = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = list
        }
        // 位置の変化でアプリが起こされたときも、ここで受け取りを続ける
        if isOn { start() }
        refreshVisitMonitoring(askAuthorization: false)
    }

    // MARK: - 立ち寄り（着いた・出た）

    /// 着いたとき、1回だけ細かく測る（初めはオン。設定で切れる。強化案 88）
    nonisolated static let arrivalKey = "arrivalMeasure"
    nonisolated static var arrivalOn: Bool { UserDefaults.standard.object(forKey: arrivalKey) as? Bool ?? true }

    /// 立ち寄りの知らせがいるか。「行ったお店」がオンか、位置を残していて、着いたときの測り・30 分の「ここは？」・着いたら知らせるのどれかがオン
    nonisolated static func wantsVisits(shopOn: Bool, locationOn: Bool, arrival: Bool, ask: Bool, remind: Bool) -> Bool {
        shopOn || (locationOn && (arrival || ask || remind))
    }

    /// 立ち寄りの知らせを受け取る・やめる（電池はほとんど使わない。「常に」の許可が要る）。「行ったお店」の設定から呼ばれる
    func setVisits(_ on: Bool) {
        refreshVisitMonitoring(askAuthorization: on)
    }

    /// 設定が変わったら呼ぶ。いまの設定で、立ち寄りの知らせを受けるかを決め直す
    func refreshVisitMonitoring(askAuthorization: Bool = true) {
        let defaults = UserDefaults.standard
        let want: Bool = Self.wantsVisits(shopOn: defaults.bool(forKey: ShopVisitBook.onKey), locationOn: isOn,
                                          arrival: Self.arrivalOn, ask: PlaceAssistRules.askOn,
                                          remind: PlaceAssistRules.remindOn)
        guard want else {
            manager.stopMonitoringVisits()
            return
        }
        if askAuthorization, manager.authorizationStatus == .notDetermined || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        manager.startMonitoringVisits()
    }

    /// 着いた直後に、1回だけ高い精度で測る（電池への配慮: 立ち寄りの知らせで起きたときだけ。続けて測らない）
    func measureOnArrival() {
        guard isOn, Self.arrivalOn, !arrivalFixPending else { return }
        arrivalFixPending = true
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestLocation()
    }

    private func start() {
        if manager.authorizationStatus == .notDetermined || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    /// 会話の始まった時刻にいた場所の名前。分からなければ nil。
    func name(at time: Date) async -> String? {
        guard isOn, let sample = sample(at: time) else { return nil }
        // 位置の精度が悪い（150m より粗い）か、30分より離れた位置しか無いときは「たぶん〇〇」（2026-11-06）
        let unsure = Self.isUnsure(accuracy: sample.accuracy, age: abs(time.timeIntervalSince(sample.time)))
        var name = registered(near: sample.location, accuracy: sample.accuracy)?.name
        // 本人が直した名前（2026-11-16。強化案 89）
        if name == nil { name = PlaceNameBook.shared.name(near: sample.location, accuracy: sample.accuracy) }
        if name == nil { name = await areaName(for: sample.location) }
        return name.map { unsure ? "たぶん" + $0 : $0 }
    }

    /// 通信せずに分かる場所の名前（登録した場所か、前に調べた地名）。聞き取りのヒント用
    func quickName(at time: Date) -> String? {
        guard isOn, let sample = sample(at: time) else { return nil }
        if let place = registered(near: sample.location, accuracy: sample.accuracy) { return place.name }
        if let fixed = PlaceNameBook.shared.name(near: sample.location, accuracy: sample.accuracy) { return fixed }
        let key = String(format: "%.3f,%.3f", sample.location.coordinate.latitude, sample.location.coordinate.longitude)
        return names[key]
    }

    /// 通信せずに分かる場所の名前（登録した場所か、前に調べた地名）。位置の書き出し用（2026-11-09。LocationExport.swift）
    func knownName(latitude: Double, longitude: Double, accuracy: Double) -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        if let place = registered(near: location, accuracy: accuracy) { return place.name }
        if let fixed = PlaceNameBook.shared.name(near: location, accuracy: accuracy) { return fixed }
        return names[String(format: "%.3f,%.3f", latitude, longitude)]
    }

    /// 登録した場所の種類（位置を当日のうちに母艦へ。2026-11-14。OneTimeline.swift）。
    /// 職場は "work"、名前が「自宅」を含むか「家」「うち」なら "home"、ほかの登録した場所は "other"。登録した場所でなければ nil
    func placeKind(latitude: Double, longitude: Double, accuracy: Double) -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let place = registered(near: location, accuracy: accuracy) else { return nil }
        if place.isWork == true { return "work" }
        if place.name.contains("自宅") || place.name == "家" || place.name == "うち" { return "home" }
        return "other"
    }

    /// 端末に残っている位置の点（7日分）のうち、from〜to のもの。位置の書き出し用（2026-11-09）
    func points(from: Date, to: Date) -> [LocationExport.Point] {
        samples.filter { $0.time >= from && $0.time < to }.map {
            LocationExport.Point(time: $0.time, latitude: $0.latitude, longitude: $0.longitude, accuracy: $0.accuracy)
        }
    }

    /// これより粗い位置は「たぶん」とし、職場かどうかの切り替えには使わない
    nonisolated static let unsureAccuracy: Double = 150

    nonisolated static func isUnsure(accuracy: Double, age: TimeInterval) -> Bool {
        accuracy > unsureAccuracy || age > 1800
    }

    /// その時刻より前の最後の位置。無ければ、30分以内に分かった位置。
    private func sample(at time: Date) -> Sample? {
        samples.last(where: { $0.time <= time.addingTimeInterval(60) })
            ?? samples.first(where: { $0.time.timeIntervalSince(time) < 1800 })
    }

    /// その時刻の位置（無ければ nil）。名前を直すときに、直した名前を位置で覚えるのに使う（2026-11-16。強化案 89）
    func fixPoint(at time: Date) -> (latitude: Double, longitude: Double, accuracy: Double)? {
        guard let s = sample(at: time) else { return nil }
        return (s.latitude, s.longitude, s.accuracy)
    }

    /// 登録した場所のうち、その位置にあるもの（2026-11-16）
    func registeredPlace(near location: CLLocation, accuracy: Double) -> Place? {
        registered(near: location, accuracy: accuracy)
    }

    /// 通信せずに分かる、その位置の自動の地名（前に調べたもの）
    func cachedAreaName(near location: CLLocation) -> String? {
        names[String(format: "%.3f,%.3f", location.coordinate.latitude, location.coordinate.longitude)]
    }

    /// 「〇〇駅近く」「〇〇付近」を調べる（通信する。1か所ごとに覚えておく）
    func areaNameFor(_ location: CLLocation) async -> String? {
        await areaName(for: location)
    }

    /// その時刻に職場にいたか。職場を登録していない・位置が分からないときは nil。
    func context(at time: Date) -> SpeakerLabeler.Context? {
        guard isOn, places.contains(where: { $0.isWork == true }), let sample = sample(at: time),
              !Self.isUnsure(accuracy: sample.accuracy, age: abs(time.timeIntervalSince(sample.time))) else { return nil }
        return registered(near: sample.location, accuracy: sample.accuracy)?.isWork == true ? .work : .other
    }

    /// 登録した場所にいたなら、そこが職場かどうか。登録していない場所・分からないときは nil。
    func registeredContext(at time: Date) -> SpeakerLabeler.Context? {
        guard isOn, let sample = sample(at: time),
              !Self.isUnsure(accuracy: sample.accuracy, age: abs(time.timeIntervalSince(sample.time))),
              let place = registered(near: sample.location, accuracy: sample.accuracy) else { return nil }
        return place.isWork == true ? .work : .other
    }

    private func registered(near location: CLLocation, accuracy: Double) -> Place? {
        let slack = min(max(accuracy, 0), 200)
        return places
            .map { ($0, $0.location.distance(from: location)) }
            .filter { $0.1 <= $0.0.radius + slack }
            .min { $0.1 < $1.1 }?.0
    }

    /// 「〇〇駅近く」か「〇〇付近」
    private func areaName(for location: CLLocation) async -> String? {
        let key = String(format: "%.3f,%.3f", location.coordinate.latitude, location.coordinate.longitude)
        if let cached = names[key] { return cached }

        var result: String?
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 500)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
        if let response = try? await MKLocalSearch(request: request).start() {
            let station = response.mapItems
                .filter { ($0.name ?? "").hasSuffix("駅") }
                .min { a, b in
                    location.distance(from: a.placemark.location ?? location)
                        < location.distance(from: b.placemark.location ?? location)
                }
            if let name = station?.name { result = name + "近く" }
        }
        if result == nil, let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
           let area = mark.subLocality ?? mark.locality {
            result = area + "付近"
        }
        if let result { names[key] = result }
        return result
    }

    // MARK: - 登録した場所

    /// 今いる場所を、名前を付けて登録する。
    func addCurrentPlace(named name: String, isWork: Bool = false) async -> Bool {
        guard let location = await currentLocation() else { return false }
        let place = Place(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                          isWork: isWork)
        places.append(place)
        times.added[place.id.uuidString] = .now
        savePlaces()
        return true
    }

    func setWork(_ id: UUID, _ isWork: Bool) {
        guard let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].isWork = isWork
        times.added[id.uuidString] = .now
        savePlaces()
    }

    /// 登録した場所の名前を直す（端末間の同期にも載る。直した名前は位置でも覚え、母艦にも送る。強化案 89）
    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        guard let i = places.firstIndex(where: { $0.id == id }), let cleaned = PlaceNameRules.clean(name) else { return false }
        guard places[i].name != cleaned else { return true }
        places[i].name = cleaned
        times.added[id.uuidString] = .now
        savePlaces()
        PlaceNameBook.shared.fix(name: cleaned, latitude: places[i].latitude, longitude: places[i].longitude, source: "registered")
        onChange?()
        return true
    }

    func setPause(_ id: UUID, _ pauses: Bool) {
        guard let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].pausesRecording = pauses ? true : nil
        savePlaces()
        onChange?()
    }

    func removePlaces(at offsets: IndexSet) {
        for i in offsets where places.indices.contains(i) { times.removed[places[i].id.uuidString] = .now }
        places.remove(atOffsets: offsets)
        savePlaces()
        onChange?()
    }

    /// いま、録音を休む場所にいるか。位置が分からない・位置情報が使えないときは false（書き落とさないように）。
    func atPausePlace() -> Bool {
        guard isOn, authorization == .authorizedAlways || authorization == .authorizedWhenInUse,
              places.contains(where: { $0.pausesRecording == true }), let last = samples.last,
              Date.now.timeIntervalSince(last.time) < 36 * 3600 else { return false }
        return registered(near: last.location, accuracy: last.accuracy)?.pausesRecording == true
    }

    private func currentLocation() async -> CLLocation? {
        if let last = samples.last, Date.now.timeIntervalSince(last.time) < 120, last.accuracy <= 100 {
            return last.location
        }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
        }
    }

    // MARK: - 端末間の同期

    struct SyncCopy: Codable {
        var places: [Place]
        var times: SyncTimes
    }

    /// ほかの端末に渡す登録した場所。「ここでは録音を休む」は端末ごとの設定なので渡さない。
    func syncCopy() -> SyncCopy {
        SyncCopy(places: places.map { p in
            var p = p
            p.pausesRecording = nil
            return p
        }, times: times)
    }

    /// ほかの端末の登録した場所を合わせる。この端末の「ここでは録音を休む」はそのまま。変わったら true。
    @discardableResult
    func mergeRemote(_ remote: SyncCopy) -> Bool {
        var result: [Place] = []
        for place in places {
            let other = remote.places.first { $0.id == place.id }
            let d = SyncTimes.decide(place.id.uuidString, here: true, there: other != nil, local: times, remote: remote.times)
            guard d.present else { continue }
            if d.fromRemote, var other {
                other.pausesRecording = place.pausesRecording
                result.append(other)
            } else {
                result.append(place)
            }
        }
        for other in remote.places where !places.contains(where: { $0.id == other.id }) {
            guard SyncTimes.decide(other.id.uuidString, here: false, there: true, local: times, remote: remote.times).present
            else { continue }
            var p = other
            p.pausesRecording = nil
            result.append(p)
        }
        let merged = times.merged(with: remote.times)
        if merged != times { times = merged }
        let before = try? JSONEncoder().encode(places)
        guard (try? JSONEncoder().encode(result)) != before else { return false }
        places = result
        savePlaces()
        onChange?()
        return true
    }

    private func savePlaces() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: "placeList")
        }
    }

    // MARK: - CLLocationManagerDelegate

    private func received(_ location: CLLocation?) {
        for continuation in waiting { continuation.resume(returning: location) }
        waiting = []
        // 着いたときの細かい測りの返事か（測った数を数える。電池の差は、この数の多い日と少ない日を比べて見る。強化案 88）
        let isArrival = arrivalFixPending
        arrivalFixPending = false
        guard let location, location.horizontalAccuracy >= 0 else {
            if isArrival { Tally.add("place.arrival.fail") }
            return
        }
        if isArrival {
            Tally.add("place.arrival.fix")
            Tally.add(location.horizontalAccuracy <= 50 ? "place.arrival.fine" : "place.arrival.coarse")
        }
        let sample = Sample(time: location.timestamp, latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy)
        // ほとんど動いていなければ、新しい点は足さない（着いたときの測りのほうが細かければ、前の点と置き換える）
        if let last = samples.last, last.location.distance(from: location) < 50,
           sample.time.timeIntervalSince(last.time) < 3600 {
            if isArrival, sample.accuracy < last.accuracy {
                samples[samples.count - 1] = sample
                if let data = try? JSONEncoder().encode(samples) { try? data.write(to: Self.samplesURL, options: .atomic) }
            }
            return
        }
        samples.append(sample)
        samples.sort { $0.time < $1.time }
        // 1週間より前の位置は消す（まだ文字起こししていない分にも足りる長さ）
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 3600)
        if let keepLast = samples.last(where: { $0.time < cutoff }) {
            samples = [keepLast] + samples.filter { $0.time >= cutoff }
        }
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: Self.samplesURL, options: .atomic)
        }
        onSample?(location)
        onChange?()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.received(latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let raw = RawVisit(arrival: visit.arrivalDate, departure: visit.departureDate, latitude: visit.coordinate.latitude,
                           longitude: visit.coordinate.longitude, accuracy: visit.horizontalAccuracy)
        Task { @MainActor in
            self.onVisit?(raw)
            // 着いた（出た時刻がまだ無い）ときだけ、1回細かく測る。そのあとに 30 分の「ここは？」・着いたら知らせるが続く
            if raw.departure == .distantFuture { self.measureOnArrival() }
            self.onVisitEvent?(raw)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.received(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.isOn, status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.startMonitoringSignificantLocationChanges()
                self.manager.requestLocation()
            }
        }
    }
}

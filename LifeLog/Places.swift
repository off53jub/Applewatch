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
        }
    }
    private(set) var places: [Place] = []
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// 位置や場所の登録が変わったら呼ぶ
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    /// 地名の問い合わせを減らすため、100 m 四方ごとに覚えておく
    @ObservationIgnored private var names: [String: String] = [:]

    private static let samplesURL = URL.applicationSupportDirectory.appendingPathComponent("locations.json")

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
        if let place = registered(near: sample.location, accuracy: sample.accuracy) { return place.name }
        return await areaName(for: sample.location)
    }

    /// その時刻より前の最後の位置。無ければ、30分以内に分かった位置。
    private func sample(at time: Date) -> Sample? {
        samples.last(where: { $0.time <= time.addingTimeInterval(60) })
            ?? samples.first(where: { $0.time.timeIntervalSince(time) < 1800 })
    }

    /// その時刻に職場にいたか。職場を登録していない・位置が分からないときは nil。
    func context(at time: Date) -> SpeakerLabeler.Context? {
        guard isOn, places.contains(where: { $0.isWork == true }), let sample = sample(at: time) else { return nil }
        return registered(near: sample.location, accuracy: sample.accuracy)?.isWork == true ? .work : .other
    }

    /// 登録した場所にいたなら、そこが職場かどうか。登録していない場所・分からないときは nil。
    func registeredContext(at time: Date) -> SpeakerLabeler.Context? {
        guard isOn, let sample = sample(at: time),
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
        places.append(Place(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                            isWork: isWork))
        savePlaces()
        return true
    }

    func setWork(_ id: UUID, _ isWork: Bool) {
        guard let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].isWork = isWork
        savePlaces()
    }

    func setPause(_ id: UUID, _ pauses: Bool) {
        guard let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].pausesRecording = pauses ? true : nil
        savePlaces()
        onChange?()
    }

    func removePlaces(at offsets: IndexSet) {
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

    private func savePlaces() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: "placeList")
        }
    }

    // MARK: - CLLocationManagerDelegate

    private func received(_ location: CLLocation?) {
        for continuation in waiting { continuation.resume(returning: location) }
        waiting = []
        guard let location, location.horizontalAccuracy >= 0 else { return }
        let sample = Sample(time: location.timestamp, latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy)
        // ほとんど動いていなければ、新しい点は足さない
        if let last = samples.last, last.location.distance(from: location) < 50,
           sample.time.timeIntervalSince(last.time) < 3600 { return }
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
        onChange?()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.received(latest) }
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

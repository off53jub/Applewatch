import AVFoundation
import Foundation

/// iPhone が車（CarPlay・車の Bluetooth）に音をつないでいた時間を覚えておく。会話の見出しの「どこで」の手がかりにする。
/// 位置は使わず、iOS が教えてくれる音の出口の種類だけを見る。中身は端末の中だけ（UserDefaults、14日分）。
@MainActor
final class CarAudioLog {
    struct Period: Codable, Equatable {
        var start: Date
        var end: Date?
    }

    private static let key = "carAudioPeriods"
    private(set) var periods: [Period]
    private var observer: NSObjectProtocol?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Period].self, from: data) {
            periods = saved
        } else {
            periods = []
        }
    }

    /// 音の出口の変化を見始める（今つながっているかもすぐ確かめる）
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    // MARK: - 自分で選ぶ車の機器（2026-11-06）

    nonisolated private static let chosenKey = "carDevices"
    nonisolated private static let seenKey = "seenBluetooth"

    /// 「この機器は車」と選んだ Bluetooth の名前と、「車ではない」と選んだ名前
    nonisolated static var chosen: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: chosenKey) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: chosenKey) }
    }

    /// これまでにつないだ Bluetooth の機器の名前（選ぶ画面に出す。30個まで）
    nonisolated static var seen: [String] { UserDefaults.standard.stringArray(forKey: seenKey) ?? [] }

    private static func noteSeen(_ name: String) {
        var list = seen.filter { $0 != name }
        list.insert(name, at: 0)
        UserDefaults.standard.set(Array(list.prefix(30)), forKey: seenKey)
    }

    /// その機器を車とみなすか。自分で選んだものはそれに従い、選んでいなければ名前で決める
    nonisolated static func isCar(_ name: String, chosen: [String: Bool]) -> Bool {
        chosen[name] ?? looksLikeCar(name)
    }

    /// 今の音の出口が車かを見て、つながった・離れた時刻を記録する
    func check(now: Date = .now) {
        let route = AVAudioSession.sharedInstance().currentRoute.outputs
        let outputs = route.map(\.portType)
        let bluetooth = route.filter { [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains($0.portType) }
        for port in bluetooth { Self.noteSeen(port.portName) }
        let chosen = Self.chosen
        let inCar = outputs.contains(.carAudio) || bluetooth.contains { Self.isCar($0.portName, chosen: chosen) }
        let open = periods.last.map { $0.end == nil } ?? false
        if inCar && !open {
            periods.append(Period(start: now))
        } else if !inCar && open {
            periods[periods.count - 1].end = now
        } else {
            return
        }
        let old = now.addingTimeInterval(-14 * 86400)
        periods.removeAll { ($0.end ?? now) < old }
        if let data = try? JSONEncoder().encode(periods) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// その時間の半分以上（か3分以上）、車につながっていたか
    func connected(from start: Date, to end: Date, now: Date = .now) -> Bool {
        Self.overlaps(periods, from: start, to: end, now: now)
    }

    nonisolated static func overlaps(_ periods: [Period], from start: Date, to end: Date, now: Date = .now) -> Bool {
        let length = max(end.timeIntervalSince(start), 1)
        let covered = periods.reduce(0.0) { sum, p in
            sum + max(0, min(p.end ?? now, end).timeIntervalSince(max(p.start, start)))
        }
        return covered >= min(length * 0.5, 180)
    }

    /// Bluetooth の機器名が車らしいか（車のオーディオは、メーカー名や「CAR」「My Car」などの名前が多い）
    nonisolated static func looksLikeCar(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.range(of: "(^|[^a-z])car([^a-z]|$)", options: .regularExpression) != nil { return true }
        let words = ["toyota", "honda", "nissan", "mazda", "subaru", "suzuki", "daihatsu", "lexus", "mitsubishi",
                     "bmw", "mercedes", "audi", "volkswagen", "vw ", "tesla", "volvo", "uconnect", "carplay",
                     "トヨタ", "ホンダ", "日産", "マツダ", "スバル", "スズキ", "ダイハツ", "レクサス", "三菱", "車"]
        return words.contains { n.contains($0) }
    }
}

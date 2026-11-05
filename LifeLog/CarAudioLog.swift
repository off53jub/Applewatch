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

    /// 今の音の出口が車かを見て、つながった・離れた時刻を記録する
    func check(now: Date = .now) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        let inCar = outputs.contains(.carAudio)
            || (outputs.contains(.bluetoothHFP) || outputs.contains(.bluetoothA2DP))
            && AVAudioSession.sharedInstance().currentRoute.outputs.contains { Self.looksLikeCar($0.portName) }
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

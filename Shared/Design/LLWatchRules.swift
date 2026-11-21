import Foundation

// 時計の決まり（iPhone のテストからも確かめる。s20 の 体20・体22。2026-11-21）

enum WatchFaceRules {
    /// 減り方が分からないときの 1 時間あたりの減り（% 。録音中の目安。仮）
    static let defaultDrainPerHour = 9.0

    /// あと何時間録れるか（電池 0〜1 と、1 時間あたりの減り %）
    static func hoursLeft(battery: Double?, drainPerHour: Double?) -> Double? {
        guard let battery, battery >= 0 else { return nil }
        let drain = max(drainPerHour ?? defaultDrainPerHour, 1)
        let hours = battery * 100 / drain
        return (hours * 2).rounded(.down) / 2
    }

    /// よく使う 3 つ（使った回数の多い順。同じなら前からの順）
    static func topActions(_ all: [String], counts: [String: Int], take: Int = 3) -> [String] {
        let sorted = all.enumerated().sorted { a, b in
            let ca = counts[a.element] ?? 0
            let cb = counts[b.element] ?? 0
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(take))
    }
}


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


// MARK: - 見16 時計の録音画面「輪＋大きな数字 1 つ」（s22。2026-11-22）

enum WatchRingRules {
    /// 輪がいっぱいになる、今日録れた時間（12 時間。仮）
    static let goal: TimeInterval = 12 * 3600
    static let key = "watchRingNumber"

    /// 大きな数字に出すもの（押すと次へ）
    enum Number: String, CaseIterable, Sendable {
        case recorded, hoursLeft, unsent, waiting

        var label: String {
            switch self {
            case .recorded: "今日録れた"
            case .hoursLeft: "あと録れる"
            case .unsent: "送っていない"
            case .waiting: "確かめ待ち"
            }
        }

        var next: Number {
            let all = Number.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    /// 輪の満ち具合（0〜1）
    static func progress(recorded: TimeInterval) -> Double {
        guard recorded.isFinite, recorded > 0 else { return 0 }
        return min(1, recorded / goal)
    }

    /// 大きな数字と、その下の小さな言葉
    static func display(_ number: Number, recorded: TimeInterval, hoursLeft: Double?, unsent: Int,
                        waiting: Int?) -> (big: String, caption: String) {
        switch number {
        case .recorded:
            let m = Int(max(0, recorded) / 60)
            return ("\(m / 60):" + String(format: "%02d", m % 60), "今日録れた")
        case .hoursLeft:
            guard let hoursLeft else { return ("—", "あと録れる（分からない）") }
            let text = hoursLeft >= 10 ? "\(Int(hoursLeft))" : (hoursLeft == hoursLeft.rounded() ? "\(Int(hoursLeft))" : String(format: "%.1f", hoursLeft))
            return (text, "あと録れる時間")
        case .unsent:
            return ("\(max(0, unsent))", "送っていない区切り")
        case .waiting:
            guard let waiting else { return ("—", "確かめ待ち（iPhone から届く前）") }
            return ("\(waiting)", "確かめ待ち")
        }
    }

    /// 読み上げの文
    static func spoken(_ number: Number, recorded: TimeInterval, hoursLeft: Double?, unsent: Int, waiting: Int?) -> String {
        let d = display(number, recorded: recorded, hoursLeft: hoursLeft, unsent: unsent, waiting: waiting)
        switch number {
        case .recorded:
            let m = Int(max(0, recorded) / 60)
            return "今日録れた時間 \(m / 60) 時間 \(m % 60) 分"
        case .hoursLeft: return d.big == "—" ? "あと録れる時間は分からない" : "あと \(d.big) 時間録れる"
        case .unsent: return "送っていない区切り \(d.big) 個"
        case .waiting: return d.big == "—" ? "確かめ待ちはまだ届いていない" : "確かめ待ち \(d.big) 件"
        }
    }
}

// MARK: - 見17 文字盤の電池の部品

enum WatchGaugeRules {
    /// 電池の輪の中の短い文字（「6h」「<1h」「—」）
    static func short(hoursLeft: Double?) -> String {
        guard let hoursLeft else { return "—" }
        if hoursLeft < 1 { return "<1h" }
        return "\(Int(hoursLeft.rounded(.down)))h"
    }

    /// 電池（0〜1）。分からなければ nil
    static func level(_ battery: Double?) -> Double? {
        guard let battery, battery >= 0 else { return nil }
        return min(1, battery)
    }
}

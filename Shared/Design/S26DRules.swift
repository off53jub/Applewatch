import Foundation
import SwiftUI

// s26 のデザインの決まり（A3・S26D。2026-11-25）。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 16」。
// ここは iPhone・時計・ウィジェットの全部で読む「字の大きさ」と、純粋な決まり（計算だけ）。テストは LifeLogTests/S26DTests.swift。
// 部品表の入口は LifeLog/S26DKit.swift の先頭（色・余白・角は LLTheme.swift の LL のまま。二重に作らない）。

// MARK: - 絵1 字の大きさ（Dynamic Type に乗る大きさだけ。数字で書かない）

extension LL {
    /// 字の大きさの決まり（画面ごとに .font(.system(size:)) を書かない。文字を大きくする設定に合わせて伸びる）
    enum TypeScale {
        /// 画面のいちばん上の大きな題（ナビゲーションの題を使わない画面だけ）
        static let screenTitle: Font = .title2.weight(.bold)
        /// カードの題
        static let cardTitle: Font = .headline
        /// 節の見出し（LLHeader と同じ）
        static let section: Font = .subheadline.weight(.bold)
        /// 本文
        static let body: Font = .body
        /// 行の 2 段目・ボタンの文字
        static let detail: Font = .callout
        /// 補足・注
        static let note: Font = .caption
        /// 札・印
        static let tag: Font = .caption2.weight(.semibold)
        /// 大きな数（カードの数・費用）。桁がそろう
        static let number: Font = .title2.weight(.bold).monospacedDigit()
        /// 行の右の数
        static let rowNumber: Font = .callout.monospacedDigit()
    }
}

// MARK: - 絵2 色の役割（赤＝本人が動く・オレンジ＝待てば戻る・青＝ふつう）

enum S26DRoleRules {
    /// 画面の下に出す 1 行の説明（軽1 の「?」の 2 行とは別。費用の画面などの足元で使う）
    static let legend = "赤＝あなたが動くもの・オレンジ＝待てば戻る（今日はお休み）・青＝ふつうに動いている"

    /// 状態の言葉から役割を決める（家の PC・母艦の状態の名前。知らない名前はふつう）
    static func role(status: String) -> LLRole {
        switch status {
        case "broken", "failed", "error", "act", "needs_you", "ng": .act
        case "capped", "paused", "waiting", "wait", "resting", "retire_candidate", "unused", "stale": .wait
        default: .machine
        }
    }
}

// MARK: - 絵3 費用の棒

enum S26DMeterRules {
    /// 使った割合（0〜1。上限が無い・0 以下なら nil）
    static func fraction(used: Double, cap: Double?) -> Double? {
        guard let cap, cap > 0, used.isFinite else { return nil }
        return min(1, max(0, used / cap))
    }

    /// 読み上げの「何パーセント」
    static func percentText(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

// MARK: - 絵4 線のグラフ（体・声・お金・録れた時間を同じ形で）

enum S26DTrendRules {
    /// 並べる日数
    static let days = 14
    /// グラフの高さ（pt。全部同じ）
    static let height: Double = 120
    /// 「ふだんの帯」を出すのに要る日数（これより少ないと帯を出さない）
    static let bandMinDays = 5

    /// 並べた値の q の所（0〜1。間は線でつなぐ）
    static func quantile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }
        let pos = min(1, max(0, q)) * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(sorted.count - 1, lo + 1)
        let t = pos - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * t
    }

    /// ふだんの帯（下から 4 分の 1 〜 4 分の 3。日数が足りない・幅が 0 なら nil）
    static func band(_ values: [Double]) -> (low: Double, high: Double)? {
        let v = values.filter { $0.isFinite }.sorted()
        guard v.count >= bandMinDays, let low = quantile(v, 0.25), let high = quantile(v, 0.75), high > low else { return nil }
        return (low, high)
    }

    /// 縦の目盛りの幅。数（回・時間・円・歩）は 0 から、体重は値のまわりだけ
    static func domain(_ values: [Double], zeroBased: Bool) -> (low: Double, high: Double) {
        let v = values.filter { $0.isFinite }
        guard let mn = v.min(), let mx = v.max() else { return (0, 1) }
        if zeroBased {
            let top = max(mx, 0)
            return (0, top > 0 ? top * 1.15 : 1)
        }
        let pad = max(0.5, (mx - mn) * 0.2)
        return (mn - pad, mx + pad)
    }

    /// 平均（空なら nil）
    static func mean(_ values: [Double]) -> Double? {
        let v = values.filter { $0.isFinite }
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }

    /// 「直近 7 日の平均 6.2 時間（その前の 7 日 5.8）」。値の無い日は数えない
    static func summary(_ values: [Double], unit: String, digits: Int) -> String {
        let recent = mean(Array(values.suffix(7)))
        let before = values.count > 7 ? mean(Array(values.dropLast(7).suffix(7))) : nil
        guard let recent else { return "まだ数がありません" }
        var text = "直近 7 日の平均 " + number(recent, digits: digits) + (unit.isEmpty ? "" : " " + unit)
        if let before { text += "（その前の 7 日 " + number(before, digits: digits) + "）" }
        return text
    }

    /// 桁区切りつきの数（digits 桁まで。端数の無いときは整数）
    static func number(_ v: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ja_JP")
        f.maximumFractionDigits = max(0, digits)
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

// MARK: - 絵7 震えの決まり

enum S26DHapticRules {
    /// 「届いた」の震えを使うか（設定の名前。初めはオン。画面を開いているときだけ震える）
    static let arrivedKey = "s26dHapticArrived"

    static var arrivedOn: Bool { UserDefaults.standard.object(forKey: arrivedKey) as? Bool ?? true }

    /// 文字が届いたときに震えるか。画面を開いた直後（前が空）は震えない。届いた所が無ければ震えない
    static func shouldBuzzArrived(oldCount: Int, freshCount: Int, on: Bool) -> Bool {
        on && oldCount > 0 && freshCount > 0
    }

    /// docs と設定に出す一覧（出来事 → 震えの型）
    static let table: [(event: String, haptic: LLHaptic)] = [
        ("録音が始まった", .started),
        ("録音が止まった", .stopped),
        ("答えた（○×・選んだ）", .confirm),
        ("済んだ・送れた", .done),
        ("文字が届いた（画面を開いているときだけ）", .arrived),
        ("うまくいかなかった", .failed),
    ]
}

// MARK: - 絵8 ウィジェットの使われ方

enum S26DWidgetRules {
    /// ウィジェットの kind から数える名前（知らない kind は末尾の語）
    static func shortName(kind: String) -> String {
        let last = kind.split(separator: ".").last.map(String.init) ?? kind
        let cleaned = last.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned.isEmpty ? "other" : String(cleaned.prefix(32))
    }

    /// 置かれているウィジェットの数を数える名前（tally）
    static func installedName(kind: String, family: String) -> String {
        let fam = family.filter { $0.isLetter || $0.isNumber }
        return "s26d.widget." + shortName(kind: kind) + "." + (fam.isEmpty ? "other" : String(fam.prefix(24)))
    }

    /// ウィジェットから開かれたときの印（lifelog://today?w=band の w）。無ければ nil
    static func source(of url: URL) -> String? {
        guard url.scheme == "lifelog",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let w = items.first(where: { $0.name == "w" })?.value, !w.isEmpty else { return nil }
        let cleaned = w.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned.isEmpty ? nil : String(cleaned.prefix(24))
    }
}

// MARK: - 絵6 日なたの版（明るい画面の文字を濃く・地を白く）

enum LLSun {
    /// 見た目の設定（LLAppearance）が「日なた」のときの値
    static let rawValue = "sun"

    static var isOn: Bool { UserDefaults.standard.string(forKey: "llAppearance") == rawValue }

    /// 明るさ（0〜1。sRGB の相対輝度）
    static func luminance(_ hex: UInt32) -> Double {
        func ch(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(hex >> 16) + 0.7152 * ch(hex >> 8) + 0.0722 * ch(hex)
    }

    /// 2 つの色の見やすさの比（1〜21）
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 明るい画面の色を日なた用にする: 暗い色（文字・差し色）はさらに濃く、線は少し濃く、地と面は白に寄せる
    static func adjust(_ hex: UInt32) -> UInt32 {
        let l = luminance(hex)
        let factor: Double
        if l < 0.4 {
            factor = 0.72  // 文字・差し色・意味の色
        } else if l < 0.8 {
            factor = 0.85  // 線
        } else {
            return l > 0.9 ? 0xFFFFFF : hex  // 地・面（面2 は面と分かれるよう、そのまま）
        }
        func scale(_ v: UInt32) -> UInt32 { UInt32((Double(v & 0xFF) * factor).rounded()) }
        return (scale(hex >> 16) << 16) | (scale(hex >> 8) << 8) | scale(hex)
    }
}

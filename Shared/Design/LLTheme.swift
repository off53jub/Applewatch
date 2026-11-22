import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// デザインの決まり（s20 の 体1。方向 A「夜の青」。2026-11-21）。iPhone・時計・ウィジェットの全部で使う。
/// 静かな道具の顔: 黒に近い紺の地・青みのグレー・差し色は水色 1 色だけ。暗い画面が先で、明るい画面も同じ意味で作る。
/// 色・余白・角の丸み・影・動き・振動の型はここだけに置き、画面ごとに数字を書かない（docs/s20-design.md）。
enum LL {
    // MARK: 色（地・面・線・文字）

    /// 地（画面のいちばん奥）。朝・昼・夜でわずかに変わる（2026-11-22。s22 の 見20。設定「見た目」で切れる。時計は変えない）
    static let bg = Color.llDayTinted()
    /// 面（カード・一覧の行）
    static let surface = Color.ll(light: 0xFFFFFF, dark: 0x121A2B)
    /// 面2（カードの中の一段上・押せる札）
    static let surface2 = Color.ll(light: 0xE9EEF6, dark: 0x18233A)
    /// 線（区切り・枠）
    static let line = Color.ll(light: 0xD5DDEA, dark: 0x22304A)
    /// 文字（確かなこと）
    static let text = Color.ll(light: 0x0E1726, dark: 0xE6EDF7)
    /// 薄い文字（補足・見立て（仮））
    static let dim = Color.ll(light: 0x55657F, dark: 0x8A9BB8)
    /// 差し色（水色 1 色だけ。押せる所・確かめ待ちの枠）
    static let accent = Color.ll(light: 0x147FB3, dark: 0x5BC8F5)

    // MARK: 意味の色（体1。使う所を絞る）

    /// 止まっている・注意（琥珀）
    static let warn = Color.ll(light: 0xA8660E, dark: 0xF2B24C)
    /// 危ない（くすんだ赤）
    static let danger = Color.ll(light: 0xB8403F, dark: 0xE26D6D)
    /// よかった（くすんだ緑。使う所を絞る）
    static let good = Color.ll(light: 0x22875C, dark: 0x5FC79A)

    // MARK: 余白・角・線の太さ

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        /// 小さな札・印
        static let chip: CGFloat = 6
        /// 押せる札・小さなカード
        static let small: CGFloat = 10
        /// カード
        static let card: CGFloat = 16
        /// 大きなカード（○× のカード・雑誌のページ）
        static let big: CGFloat = 22
    }

    enum Stroke {
        static let hair: CGFloat = 0.5
        static let thin: CGFloat = 1
        static let bold: CGFloat = 1.5
        /// 見立て（仮）の点線
        static let dash: [CGFloat] = [4, 3]
    }

    // MARK: 動き（控えめ。状態が変わる所だけ）

    enum Motion {
        /// 状態が変わったとき（録音の丸・○× のカード）
        static let state = Animation.spring(response: 0.35, dampingFraction: 0.86)
        /// 出る・消える
        static let fade = Animation.easeOut(duration: 0.2)
        /// 録音中の丸がゆっくり息をする
        static let breathe = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    }
}

/// 振動の型（体21）。意味ごとに 1 つ。鳴らし方は iPhone（DesignKit.swift）と時計（WatchDesign.swift）で別に持つ
enum LLHaptic: String, CaseIterable, Sendable {
    /// 録音が始まった
    case started
    /// 録音が止まった
    case stopped
    /// 確かめてほしい（確かめ待ち・印）
    case confirm
    /// 終わった・送れた
    case done
    /// うまくいかなかった
    case failed

    /// 画面と docs に出す言葉
    var label: String {
        switch self {
        case .started: "始まった（短く 2 回）"
        case .stopped: "止まった（長く 1 回）"
        case .confirm: "確かめて（軽く 1 回）"
        case .done: "完了（上がる 2 回）"
        case .failed: "うまくいかない（下がる 3 回）"
        }
    }
}

extension Color {
    /// 暗い画面と明るい画面で変わる色（時計はいつも暗い画面）
    static func ll(light: UInt32, dark: UInt32) -> Color {
        #if os(watchOS)
        return Color(llHex: dark)
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(llHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }

    /// 地の色: 色を使うたびに、いまの時刻と設定から決める（LLDayTint。切っていれば #0B1220・#F3F6FB のまま）
    static func llDayTinted() -> Color {
        #if os(watchOS)
        return Color(llHex: 0x0B1220)
        #else
        return Color(uiColor: UIColor { traits in
            let hour = Calendar.current.component(.hour, from: Date())
            return UIColor(llHex: LLDayTint.bgHex(hour: hour, dark: traits.userInterfaceStyle == .dark, enabled: LLDayTint.isOn))
        })
        #endif
    }

    init(llHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

#if canImport(UIKit) && !os(watchOS)
extension UIColor {
    convenience init(llHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// `.foregroundStyle(.llDim)` のように、システムの色（.secondary・.orange など）と同じ書き方で使う
extension ShapeStyle where Self == Color {
    static var llBg: Color { LL.bg }
    static var llSurface: Color { LL.surface }
    static var llSurface2: Color { LL.surface2 }
    static var llLine: Color { LL.line }
    static var llText: Color { LL.text }
    static var llDim: Color { LL.dim }
    static var llAccent: Color { LL.accent }
    static var llWarn: Color { LL.warn }
    static var llDanger: Color { LL.danger }
    static var llGood: Color { LL.good }
}

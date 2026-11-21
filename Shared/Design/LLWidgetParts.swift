import SwiftUI

/// ウィジェットの地（s20 の 追2。2026-11-21）。ホーム画面・StandBy の大きなウィジェットだけに効く
/// （ロック画面・文字盤は iOS が色を決めるので、ここは使われない）
struct LLWidgetBackground: View {
    var body: some View {
        LinearGradient(colors: [LL.surface, LL.bg], startPoint: .top, endPoint: .bottom)
    }
}

/// ウィジェットの小さな見出し（「LifeLog」と印）
struct LLWidgetTitle: View {
    let text: String
    var symbol: String = "waveform"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(LL.accent)
            Text(text).foregroundStyle(LL.dim)
        }
        .font(.caption2.weight(.semibold))
    }
}

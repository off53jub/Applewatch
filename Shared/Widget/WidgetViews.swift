import SwiftUI

/// ウィジェットの予定の行（「10:30 打ち合わせ」「いま〜11:00 打ち合わせ」。2026-11-07）。
/// 予定の名前は、ロック中（時計は手首を下ろしたとき）は隠す。
struct WidgetEventLine: View {
    let state: WidgetState?
    /// タイムラインの項目の時刻（始まる前か・始まったかを、この時刻で決める）
    let date: Date
    var showsIcon = true

    var body: some View {
        HStack(spacing: 3) {
            if showsIcon {
                Image(systemName: "calendar").foregroundStyle(.secondary)
            }
            if let event = WidgetText.event(state, at: date) {
                Text(event.time).monospacedDigit()
                Text(event.title).privacySensitive()
            } else {
                Text(WidgetText.noEventText(state))
            }
        }
    }
}

/// 印と短い文を詰めて並べる（ウィジェットの1行）
struct WidgetIconText: View {
    let symbol: String
    let text: String
    /// 印の色（無ければ薄い色）
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(tint ?? Color.secondary)
            Text(text)
        }
    }
}

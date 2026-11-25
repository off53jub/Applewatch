import SwiftUI
import WidgetKit

/// 充電中の 1 枚「LifeLog の今日のまとめ」（s20 の 追3。2026-11-21）。iPhone を横向きで充電しているとき（StandBy）に、
/// 会話の数・録った時間・今日の三つ・確かめ待ちを大きく出す。ホーム画面の小さいウィジェットとしても置ける。
/// 中身は「LifeLog の様子」と同じ App Group の WidgetState（todayTalks・todayHours・todayThree・reviewWaiting）。
struct TodayStandByWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.todayKind, provider: StatusProvider()) { entry in
            TodayStandByView(state: entry.state)
                .containerBackground(for: .widget) { LLWidgetBackground() }
                .widgetURL(URL(string: "lifelog://today?w=standby"))
        }
        .configurationDisplayName("LifeLog の今日のまとめ")
        .description("会話の数・録った時間・今日の三つ・確かめ待ち。充電中の StandBy で大きく見られます。")
        .supportedFamilies([.systemSmall])
    }
}

private struct TodayStandByView: View {
    let state: WidgetState?
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.showsWidgetContainerBackground) private var hasBackground

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LLWidgetTitle(text: "今日", symbol: WidgetText.anyRecording(state) ? "record.circle.fill" : "waveform")
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(state?.todayTalks.map(String.init) ?? WidgetText.unknown)
                    .font(.system(size: hasBackground ? 40 : 52, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LL.text)
                    .widgetAccentable()
                Text("会話").font(.caption).foregroundStyle(LL.dim)
            }
            if let hours = state?.todayHours {
                Text("録った \(hours.formatted(.number.precision(.fractionLength(0...1)))) 時間")
                    .font(.caption.weight(.semibold)).foregroundStyle(LL.accent).monospacedDigit()
            }
            ForEach(Array((state?.todayThree ?? []).prefix(hasBackground ? 2 : 3).enumerated()), id: \.offset) { _, t in
                Text("・" + t).font(.caption2).foregroundStyle(LL.text).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let n = state?.reviewWaiting, n > 0 {
                Label("確かめ待ち \(n)", systemImage: "hand.raised").font(.caption2).foregroundStyle(LL.dim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .minimumScaleFactor(0.7)
    }
}

import SwiftUI
import WidgetKit

/// ロック画面の「LifeLog の今日の帯」（s22 の 見18。2026-11-22）。今日の 1 日を 30 分ごとの 48 こまで小さく描く:
/// 会話＝高い棒・録れた＝低い棒・何も無い＝点。いまの所に縦の線。中身は「LifeLog の様子」と同じ App Group の WidgetState
/// （todayBand・todayTalks・todayHours）。ロック画面は iOS が色を決めるので、濃さ（不透明さ）と高さで分ける。
struct TodayBandWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.bandKind, provider: StatusProvider()) { entry in
            TodayBandView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "lifelog://today?w=band"))
        }
        .configurationDisplayName("LifeLog の今日の帯")
        .description("今日の会話と録れた時間を、1 本の帯で小さく出します。")
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct TodayBandView: View {
    let entry: StatusProvider.Entry

    var body: some View {
        let state = entry.state
        let slots = BandSlots.decode(state?.todayBand)
        let dayStart = Calendar.current.startOfDay(for: entry.date)
        let now = BandSlots.index(of: entry.date, dayStart: dayStart)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: WidgetText.anyRecording(state) ? "record.circle.fill" : "waveform")
                    .widgetAccentable()
                Text(Self.headline(state)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .font(.headline)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<BandSlots.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(Self.alpha(slots[i], future: i > now)))
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.barHeight(slots[i]))
                        .overlay(alignment: .bottom) {
                            if i == now { Rectangle().fill(Color.primary).frame(width: 1.5, height: 20) }
                        }
                }
            }
            .frame(height: 20, alignment: .bottom)
            .widgetAccentable()
            HStack {
                Text("0").monospacedDigit()
                Spacer()
                Text("12").monospacedDigit()
                Spacer()
                Text("24").monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日の時間の線。" + Self.headline(state))
    }

    /// 「会話 5・3.2 時間」（分からなければ「今日」）
    static func headline(_ state: WidgetState?) -> String {
        guard let state, let talks = state.todayTalks else { return "今日 " + WidgetText.unknown }
        let hours = state.todayHours.map { "・\($0.formatted(.number.precision(.fractionLength(0...1)))) 時間" } ?? ""
        return "会話 \(talks)" + hours
    }

    static func barHeight(_ slot: Int) -> CGFloat {
        switch slot {
        case 2: 18
        case 1: 8
        default: 2
        }
    }

    static func alpha(_ slot: Int, future: Bool) -> Double {
        if future { return 0.15 }
        switch slot {
        case 2: return 1
        case 1: return 0.55
        default: return 0.25
        }
    }
}

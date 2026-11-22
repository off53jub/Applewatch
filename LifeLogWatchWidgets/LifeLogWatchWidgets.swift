import SwiftUI
import WidgetKit

/// 時計の文字盤に置く LifeLog（コンプリケーション）。2026-11-07 から中身を出す。
/// 丸: 録音中の印と、今日までの頼まれごとの数。長方形: 録音中か・iPhone に送っていない録音の数・次の予定・今日までの頼まれごと。
/// 角・1行: 録音中かと、今日までの頼まれごとの数。
/// 中身は時計のアプリが App Group（group.com.off53jub.lifelog）に書く（LifeLogWatch/WatchWidgets.swift。次の予定と頼まれごとは
/// iPhone から届いた分）。読めないとき（App Group が使えない入れ方など）は「—」を出す。押すと LifeLog を開く。
/// 種類の名前（kind）は前の「開くボタン」と同じにしてある（文字盤に置いたものが消えないように）。
@main
struct LifeLogWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        LifeLogWatchWidgets()
        // 録音中か・電池の残り時間を、丸と角の形で（2026-11-22。s22 の 見17）
        WatchBatteryWidget()
    }
}

struct LifeLogWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.watchKind, provider: Provider()) { entry in
            StatusView(entry: entry)
                .containerBackground(for: .widget) { LLWidgetBackground() }
        }
        .configurationDisplayName("LifeLog")
        .description("録音しているか、あと何時間録れるか、確かめ待ちの数を出します。押すと LifeLog を開きます。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

private struct StatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Provider.Entry

    private var state: WidgetState? { entry.state }
    private var symbol: String { state?.watchRecording == true ? "record.circle.fill" : "waveform" }

    static func hoursText(_ hours: Double?) -> String {
        guard let hours else { return "あと " + WidgetText.unknown }
        return hours >= 1 ? "あと \(hours.formatted(.number.precision(.fractionLength(0...1)))) 時間" : "あと 1 時間より少ない"
    }

    static func reviewText(_ count: Int?) -> String {
        guard let count else { return "確かめ待ち " + WidgetText.unknown }
        return count == 0 ? "確かめ待ちなし" : "確かめ待ち \(count)"
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            ViewThatFits {
                Label(WidgetText.inline(state, onWatch: true), systemImage: symbol)
                Label(WidgetText.summary(state, onWatch: true), systemImage: symbol)
            }
        case .accessoryRectangular:
            // 文字盤に 3 つ: 録音中か・あと何時間録れるか・確かめ待ちの数（2026-11-21。s20 の 体22）
            VStack(alignment: .leading, spacing: 0) {
                Label(WidgetText.watchHeadline(state), systemImage: symbol)
                    .font(.headline)
                    .widgetAccentable()
                WidgetIconText(symbol: "battery.75percent", text: Self.hoursText(state?.watchHoursLeft))
                WidgetIconText(symbol: "hand.raised", text: Self.reviewText(state?.reviewWaiting))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title3)
                .widgetAccentable()
                .widgetLabel(WidgetText.corner(state))
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: symbol)
                        .font(.title3)
                        .widgetAccentable()
                    if state == nil {
                        Text(WidgetText.unknown).font(.headline)
                    } else if let due = state?.tasksDue, due > 0 {
                        Text(String(due))
                            .font(.headline)
                    }
                }
            }
        }
    }
}

private struct Provider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
        /// 時計のアプリが書いた中身（読めなければ nil）
        let state: WidgetState?
    }

    func placeholder(in context: Context) -> Entry { Entry(date: .now, state: WidgetState.sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        // 文字盤を選ぶ画面では、まだ中身が無ければ見本を出す
        let state: WidgetState? = WidgetState.load() ?? (context.isPreview ? WidgetState.sample : nil)
        completion(Entry(date: .now, state: state))
    }

    /// 今と、次の予定の始まり・終わり、次の0時に切り替わる。中身は時計のアプリが書いたら読み直してもらう
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        let state = WidgetState.load()
        let entries = (state?.timelineDates(from: now) ?? [now]).map { Entry(date: $0, state: state) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(WidgetState.refreshAfter))))
    }
}

/// 文字盤の「LifeLog の電池」（s22 の 見17。2026-11-22）。丸: 電池の輪の中に録音中の印と「あと○時間」。
/// 角: 録音中の印と、曲がった電池の目盛り。中身は時計のアプリが書く WidgetState（watchRecording・watchBattery・watchHoursLeft）
struct WatchBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.watchBatteryKind, provider: Provider()) { entry in
            WatchBatteryView(state: entry.state)
                .containerBackground(for: .widget) { LLWidgetBackground() }
        }
        .configurationDisplayName("LifeLog の電池")
        .description("録音しているかと、あと何時間録れるかを、丸か角に出します。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

private struct WatchBatteryView: View {
    @Environment(\.widgetFamily) private var family
    let state: WidgetState?

    private var recording: Bool { state?.watchRecording == true }
    private var symbol: String { recording ? "record.circle.fill" : "waveform" }
    private var level: Double { WatchGaugeRules.level(state?.watchBattery) ?? 0 }
    private var short: String { WatchGaugeRules.short(hoursLeft: state?.watchHoursLeft) }

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title3)
                .widgetAccentable()
                .widgetLabel {
                    Gauge(value: level) {
                        Text("電池")
                    } currentValueLabel: {
                        Text(short)
                    } minimumValueLabel: {
                        Text("")
                    } maximumValueLabel: {
                        Text(short)
                    }
                    .tint(recording ? LL.danger : LL.accent)
                }
                .accessibilityLabel((recording ? "録音中" : "止まっている") + "、あと " + short)
        default:
            Gauge(value: level) {
                Image(systemName: symbol)
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Image(systemName: symbol).font(.caption2).widgetAccentable()
                    Text(short).font(.caption2.weight(.semibold)).monospacedDigit()
                }
            }
            .gaugeStyle(.accessoryCircular)
            .tint(recording ? LL.danger : LL.accent)
            .accessibilityLabel((recording ? "録音中" : "止まっている") + "、あと " + short)
        }
    }
}

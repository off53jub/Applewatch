import SwiftUI
import WidgetKit

/// 時計の文字盤に置く LifeLog（コンプリケーション）。2026-11-07 から中身を出す。
/// 丸: 録音中の印と、今日までの頼まれごとの数。長方形: 録音中か・iPhone に送っていない録音の数・次の予定・今日までの頼まれごと。
/// 角・1行: 録音中かと、今日までの頼まれごとの数。
/// 中身は時計のアプリが App Group（group.com.off53jub.lifelog）に書く（LifeLogWatch/WatchWidgets.swift。次の予定と頼まれごとは
/// iPhone から届いた分）。読めないとき（App Group が使えない入れ方など）は「—」を出す。押すと LifeLog を開く。
/// 種類の名前（kind）は前の「開くボタン」と同じにしてある（文字盤に置いたものが消えないように）。
@main
struct LifeLogWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.watchKind, provider: Provider()) { entry in
            StatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("LifeLog")
        .description("録音しているか、今日までの頼まれごと、次の予定を出します。押すと LifeLog を開きます。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

private struct StatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Provider.Entry

    private var state: WidgetState? { entry.state }
    private var symbol: String { state?.watchRecording == true ? "record.circle.fill" : "waveform" }

    var body: some View {
        switch family {
        case .accessoryInline:
            ViewThatFits {
                Label(WidgetText.inline(state, onWatch: true), systemImage: symbol)
                Label(WidgetText.summary(state, onWatch: true), systemImage: symbol)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Label(WidgetText.watchHeadline(state), systemImage: symbol)
                    .font(.headline)
                    .widgetAccentable()
                WidgetEventLine(state: state, date: entry.date)
                WidgetIconText(symbol: "checklist", text: WidgetText.tasks(state))
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

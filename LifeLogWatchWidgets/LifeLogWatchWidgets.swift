import SwiftUI
import WidgetKit

/// 時計の文字盤に置く、LifeLog を開くボタン（コンプリケーション）。
/// アプリとデータを共有する仕組み（App Group）は Sideloadly で入れられないので、録音の状態は出さない。
/// 状態（録音中か・iPhone に送れていない録音の数）は、押して開いた LifeLog の画面に出る。
@main
struct LifeLogWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.off53jub.lifelog.watch.launcher", provider: Provider()) { _ in
            LauncherView()
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("LifeLog")
        .description("押すと LifeLog を開きます。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

private struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("LifeLog", systemImage: "waveform")
        case .accessoryRectangular:
            HStack {
                Image(systemName: "waveform")
                Text("LifeLog").font(.headline)
            }
        case .accessoryCorner:
            Image(systemName: "waveform")
                .font(.title3)
                .widgetLabel("LifeLog")
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "waveform").font(.title3)
            }
        }
    }
}

private struct Provider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
    }

    func placeholder(in context: Context) -> Entry { Entry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

import SwiftUI
import WidgetKit

/// ロック画面・ホーム画面に置く「LifeLog のいいこと帳」（2026-11-12）。今週のお礼とほめ言葉の数だけを出す。
/// 中身は「LifeLog の様子」と同じ WidgetState（アプリが App Group に書く。いいこと帳を読み直したときに更新）。
/// 読めないとき（App Group が使えない入れ方など）は「—」。押すといいこと帳を開く。
struct GoodWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.goodKind, provider: StatusProvider()) { entry in
            GoodView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // 押すといいこと帳を開く（2026-11-12。LifeLog の NoticeRoute.route(url:)）
                .widgetURL(URL(string: "lifelog://good"))
        }
        .configurationDisplayName("LifeLog のいいこと帳")
        .description("今週のお礼とほめ言葉の数を出します。押すといいこと帳を開きます。")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

private struct GoodView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusProvider.Entry

    var body: some View {
        let week = WidgetText.goodWeek(entry.state)
        switch family {
        case .accessoryInline:
            Label(WidgetText.goodWeekLine(entry.state), systemImage: "hand.thumbsup")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Text("今週のいいこと帳").font(.headline).widgetAccentable()
                Text("お礼 \(week.thanks)")
                Text("ほめ言葉 \(week.praise)")
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("今週のいいこと帳", systemImage: "hand.thumbsup")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("お礼 \(week.thanks)").font(.title3.bold())
                Text("ほめ言葉 \(week.praise)").font(.title3.bold())
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

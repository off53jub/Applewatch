import AppIntents
import SwiftUI
import WidgetKit

/// ホーム画面・ロック画面に置く「LifeLog の 1 問」（2026-11-22。s22 の 楽14）。
/// 確かめ待ちのうち、はい・いいえで答えられる 1 問を出し、○× のボタンで答える（アプリを開かない）。
/// 答えは App Group にため、アプリが次に動いたときに母艦へ送る。問いはロック中は隠す（privacySensitive）
struct S22ReviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.reviewKind, provider: StatusProvider()) { entry in
            S22ReviewWidgetView(entry: entry)
                .containerBackground(for: .widget) { LLWidgetBackground() }
                .widgetURL(URL(string: "lifelog://review"))
        }
        .configurationDisplayName("LifeLog の 1 問")
        .description("確かめ待ちの 1 問に ○ か × で答えます。答えはアプリが次に動いたときに送ります。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct S22ReviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusProvider.Entry

    var body: some View {
        let id = entry.state?.reviewAskID
        let question = entry.state?.reviewAskQuestion
        VStack(alignment: .leading, spacing: 6) {
            if family != .accessoryRectangular { LLWidgetTitle(text: "1 問", symbol: "checkmark.circle") }
            if let id, let question {
                Text(question)
                    .font(family == .systemMedium ? .subheadline : .caption)
                    .lineLimit(family == .accessoryRectangular ? 1 : 3)
                    .privacySensitive()
                HStack(spacing: 8) {
                    Button(intent: S22WidgetAnswerIntent(id: id, value: "yes")) {
                        Label("はい", systemImage: "circle").labelStyle(.iconOnly).frame(maxWidth: .infinity)
                    }
                    .tint(LL.good)
                    Button(intent: S22WidgetAnswerIntent(id: id, value: "no")) {
                        Label("いいえ", systemImage: "xmark").labelStyle(.iconOnly).frame(maxWidth: .infinity)
                    }
                    .tint(LL.danger)
                }
            } else {
                Text(entry.state == nil ? WidgetText.unknown : "いまは確かめ待ちはありません")
                    .font(.caption).foregroundStyle(LL.dim)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

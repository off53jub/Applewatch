import SwiftUI
import WidgetKit

/// ロック画面・ホーム画面に置く「LifeLog のやること」（2026-11-10）。
/// 今日まで（期限を過ぎたものを含む）の頼まれごとを3件までと、確かめ待ちの数。今日までのものが無ければ、期限の近いまだのもの。
/// 中身は「LifeLog の様子」と同じ WidgetState（アプリが App Group に書く）。頼まれごとの文は、ロック中は隠す（privacySensitive）。
struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.tasksKind, provider: StatusProvider()) { entry in
            TasksView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // 押すと「タスク」タブを開く（2026-11-12。LifeLog の NoticeRoute.route(url:)）
                .widgetURL(URL(string: "lifelog://tasks"))
        }
        .configurationDisplayName("LifeLog のやること")
        .description("今日までの頼まれごと（3件まで）と、確かめ待ちの数を出します。押すと LifeLog のタスクを開きます。")
        .supportedFamilies([.accessoryRectangular, .systemSmall, .systemMedium])
    }
}

private struct TasksView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusProvider.Entry

    private var state: WidgetState? { entry.state }
    private var titles: [String] { state?.taskTitles ?? [] }
    private var checking: Int { state?.tasksChecking ?? 0 }
    private var due: Int { state?.tasksDue ?? 0 }

    /// 「今日まで 2」「確かめ待ち 3」
    private var header: String {
        guard state != nil else { return "やること " + WidgetText.unknown }
        var parts: [String] = [due > 0 ? "今日まで \(due)" : "今日までは無し"]
        if checking > 0 { parts.append("確かめ待ち \(checking)") }
        return parts.joined(separator: "・")
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Text(header).font(.headline).widgetAccentable()
                ForEach(Array(titles.prefix(2).enumerated()), id: \.offset) { item in
                    Text("・" + item.element).privacySensitive()
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "checklist")
                    Text(header).font(.caption.bold())
                }
                .foregroundStyle((state?.tasksOverdue ?? 0) > 0 ? Color.orange : Color.secondary)
                if titles.isEmpty {
                    Text(state == nil ? WidgetText.unknown : "まだのものはありません")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(titles.enumerated()), id: \.offset) { item in
                    Text("・" + item.element)
                        .font(family == .systemMedium ? .subheadline : .caption)
                        .lineLimit(family == .systemMedium ? 1 : 2)
                        .privacySensitive()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

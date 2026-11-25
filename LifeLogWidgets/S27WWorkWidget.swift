import SwiftUI
import WidgetKit

/// s27 の 場6（2026-11-25）: 「LifeLog の仕事」。今日の宿題の数・開いている数・次の会議までの時間だけを出す
/// （守1: 案件名・人名・文は出さない＝職場で画面を見られてもよい形）。ロック画面の小さい形（丸・横長・1 行）とホーム画面の小。
/// 中身は App Group の S27WWorkCounts（iPhone の LifeLog が家の PC の写しから書く。Shared/Widget/S27WWorkCounts.swift）。
struct S27WWorkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: S27WWorkCounts.kind, provider: S27WWorkProvider()) { entry in
            S27WWorkView(entry: entry)
                .containerBackground(for: .widget) { LLWidgetBackground() }
                .widgetURL(URL(string: "lifelog://work?w=work"))
        }
        .configurationDisplayName("LifeLog の仕事")
        .description("今日の仕事の宿題の数と、次の会議までの時間だけを出します。中身の文や名前は出しません。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

struct S27WWorkEntry: TimelineEntry {
    let date: Date
    let counts: S27WWorkCounts?
}

struct S27WWorkProvider: TimelineProvider {
    func placeholder(in context: Context) -> S27WWorkEntry {
        S27WWorkEntry(date: .now, counts: S27WWorkCounts(homeworkToday: 2, openMine: 8, nextMeeting: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (S27WWorkEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : S27WWorkEntry(date: .now, counts: S27WWorkCounts.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<S27WWorkEntry>) -> Void) {
        let now = Date.now
        let counts = S27WWorkCounts.read()
        var entries: [S27WWorkEntry] = [S27WWorkEntry(date: now, counts: counts)]
        // 次の会議の時刻を過ぎたら出し直す（「あと…」を消す）
        if let next = counts?.upcoming(now: now) {
            entries.append(S27WWorkEntry(date: next.addingTimeInterval(60), counts: counts))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(WidgetState.refreshAfter))))
    }
}

private struct S27WWorkView: View {
    @Environment(\.widgetFamily) private var family
    let entry: S27WWorkEntry

    private var counts: S27WWorkCounts? {
        guard let c = entry.counts, !c.isStale(now: entry.date) else { return nil }
        return c
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "briefcase").font(.caption2).widgetAccentable()
                Text(counts.map { "\($0.homeworkToday ?? 0)" } ?? WidgetText.unknown)
                    .font(.title3.bold()).monospacedDigit()
                Text("宿題").font(.caption2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(counts.map { "仕事の宿題 \($0.homeworkToday ?? 0)" } ?? "仕事の数はまだありません")
        case .accessoryInline:
            Label(inline, systemImage: "briefcase")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Text("仕事").font(.headline).widgetAccentable()
                Text(counts?.line ?? "まだ数がありません").lineLimit(1).minimumScaleFactor(0.6)
                meetingLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                LLWidgetTitle(text: "仕事", symbol: "briefcase")
                Text(counts.map { "\($0.homeworkToday ?? 0)" } ?? WidgetText.unknown)
                    .font(.largeTitle.bold()).monospacedDigit().foregroundStyle(LL.text)
                Text("今日の宿題").font(.caption).foregroundStyle(LL.dim)
                Text("開いている \(counts?.openMine ?? 0)").font(.caption).foregroundStyle(LL.dim)
                meetingLine.font(.caption).foregroundStyle(LL.dim)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var inline: String {
        guard let counts else { return "仕事 " + WidgetText.unknown }
        return "仕事 宿題 \(counts.homeworkToday ?? 0)"
    }

    @ViewBuilder
    private var meetingLine: some View {
        if let next = counts?.upcoming(now: entry.date) {
            HStack(spacing: 2) {
                Text("次の会議")
                Text(next, style: .relative)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        } else {
            Text("次の会議 なし").lineLimit(1)
        }
    }
}

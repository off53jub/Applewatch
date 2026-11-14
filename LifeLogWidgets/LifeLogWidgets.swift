import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// コントロールセンター・ロック画面・アクションボタンに置ける LifeLog のボタンと、録音中の Live Activity。
/// ボタン（コントロール）と開くボタンには状態を出さない。録音中か・頼まれごと・次の予定などの様子は、
/// ロック画面・ホーム画面の「LifeLog の様子」に出す（2026-11-07。StatusWidget.swift。App Group が使えない入れ方では「—」）。
@main
struct LifeLogWidgets: WidgetBundle {
    var body: some Widget {
        RecordControl()
        MarkControl()
        LauncherWidget()
        StatusWidget()
        // 今日までの頼まれごとと確かめ待ちの数（2026-11-10）
        TasksWidget()
        // 今週のお礼とほめ言葉の数（2026-11-12）
        GoodWidget()
        RecordingLiveActivity()
        // 会議モードのあいだの「決まったこと・宿題・聞き忘れ」（2026-11-15。強化案 50。MeetingActivityWidget.swift）
        MeetingLiveActivity()
    }
}

/// アプリを開かずに録音を始めたときの表示（ロック画面と Dynamic Island）。目立たないよう小さくする。
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LifeLog 録音中").font(.subheadline.bold())
                    Text(context.state.started, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: ToggleRecordingIntent()) {
                    Label("止める", systemImage: "stop.fill")
                }
                .tint(.red)
            }
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("録音中", systemImage: "waveform").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.started, style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: ToggleRecordingIntent()) {
                        Label("録音を止める", systemImage: "stop.fill")
                    }
                    .tint(.red)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.red)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(.red)
            }
        }
    }
}

struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.off53jub.lifelog.control.record") {
            ControlWidgetButton(action: ToggleRecordingIntent()) {
                Label("LifeLog 録音", systemImage: "record.circle")
            }
        }
        .displayName("録音を始める・止める")
        .description("LifeLog を開かずに、この端末の録音を始めるか止めます。")
    }
}

struct MarkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.off53jub.lifelog.control.mark") {
            ControlWidgetButton(action: MarkIntent()) {
                Label("LifeLog 印", systemImage: "star.fill")
            }
        }
        .displayName("印を付ける")
        .description("LifeLog を開いて、今のところに印を付けます。")
    }
}

/// ロック画面に置く、LifeLog を開く丸いボタン
struct LauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.off53jub.lifelog.launcher", provider: LauncherProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "waveform").font(.title3)
            }
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("LifeLog")
        .description("押すと LifeLog を開きます。")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LauncherProvider: TimelineProvider {
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

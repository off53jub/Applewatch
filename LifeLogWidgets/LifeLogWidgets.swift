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
        // 並び（2026-11-25。s26 の 絵8）: 選ぶ画面で上に出るよう、今日の様子・1 問と帯・頼まれごとを先に。
        // 使われた数がまだ無いので、どれも消さない（数は S26DWidgetUse が 1 日 1 回数える。数がそろったら 2〜3 種に絞る）
        RecordControl()
        MarkControl()
        StatusWidget()
        // s22 の 2 つ（楽14 の 1 問・見18 の今日の帯）は、束が 10 個を超えないよう別の束にまとめる（2026-11-22）
        S22Widgets().body
        // 今日までの頼まれごとと確かめ待ちの数（2026-11-10）
        TasksWidget()
        // 充電中（StandBy）の今日のまとめ（2026-11-21。s20 の 追3。TodayStandByWidget.swift）
        TodayStandByWidget()
        // 今週のお礼とほめ言葉の数（2026-11-12）
        GoodWidget()
        LauncherWidget()
        RecordingLiveActivity()
        // 会議モードのあいだの「決まったこと・宿題・聞き忘れ」（2026-11-15。強化案 50。MeetingActivityWidget.swift）
        MeetingLiveActivity()
    }
}

/// s22 で足したウィジェット（WidgetBundle の中身は 10 個までなので、別の束にして上の束から読む。2026-11-22）
struct S22Widgets: WidgetBundle {
    var body: some Widget {
        // 確かめ待ちの 1 問に ○×（s22 の 楽14。S22ReviewWidget.swift）
        S22ReviewWidget()
        // ロック画面の今日の帯（s22 の 見18。TodayBandWidget.swift）
        TodayBandWidget()
    }
}

/// アプリを開かずに録音を始めたときの表示（ロック画面と Dynamic Island）。目立たないよう小さくする。
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(LL.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LifeLog 録音中").font(.subheadline.bold())
                    Text(context.state.started, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LL.dim)
                }
                Spacer()
                Button(intent: ToggleRecordingIntent()) {
                    Label("止める", systemImage: "stop.fill")
                }
                .tint(LL.danger)
            }
            .padding()
            .activityBackgroundTint(LL.bg.opacity(0.92))
                .activitySystemActionForegroundColor(LL.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("録音中", systemImage: "waveform").foregroundStyle(LL.danger)
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
                    .tint(LL.danger)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(LL.danger)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(LL.danger)
            }
            .keylineTint(LL.danger)
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

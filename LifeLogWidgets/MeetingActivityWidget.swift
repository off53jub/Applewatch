import ActivityKit
import SwiftUI
import WidgetKit

/// 会議モードのあいだのロック画面と Dynamic Island（会議の相棒・その場版。2026-11-15。強化案 50）。
/// 中身はアプリが家の PC の GET /meeting-live を 60 秒ごとに見て入れる（MeetingLive.swift）。
struct MeetingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
            MeetingLockView(state: context.state)
                .padding()
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("会議", systemImage: "person.3.sequence")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.started, style: .timer)
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: 70, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MeetingWidgetText.counts(context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(Array(context.state.lines.prefix(2).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "person.3.sequence")
            } compactTrailing: {
                Text(MeetingWidgetText.short(context.state))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "person.3.sequence")
            }
        }
    }
}

/// ロック画面の 1 枚
struct MeetingLockView: View {
    let state: MeetingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("会議の相棒", systemImage: "person.3.sequence")
                    .font(.subheadline.bold())
                Spacer()
                Text(state.started, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(MeetingWidgetText.counts(state))
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.lines.isEmpty {
                Text(state.updated == nil ? "まだ作っていません（1 分に 1 回まで）" : "新しく出たものはありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(state.lines.prefix(2).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).lineLimit(2)
                }
            }
        }
    }
}

enum MeetingWidgetText {
    /// 「決まった 2・宿題 1・聞き忘れ 3」
    static func counts(_ s: MeetingActivityAttributes.ContentState) -> String {
        let decided: String = "決まった \(s.decided)"
        let homework: String = "宿題 \(s.homework)"
        let unasked: String = "聞き忘れ \(s.unasked)"
        return decided + "・" + homework + "・" + unasked
    }

    /// Dynamic Island の右の小さな数（宿題と聞き忘れ）
    static func short(_ s: MeetingActivityAttributes.ContentState) -> String {
        let homework: String = "宿\(s.homework)"
        let unasked: String = "聞\(s.unasked)"
        return homework + " " + unasked
    }
}

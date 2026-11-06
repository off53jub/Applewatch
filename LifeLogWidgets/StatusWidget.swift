import SwiftUI
import UIKit
import WidgetKit

/// ロック画面・ホーム画面に置く「LifeLog の様子」（2026-11-07）。
/// 録音しているか（iPhone・時計）・今日までと期限切れの頼まれごと・次の予定・最後に文字にした時刻・家の PC とつながるか。
/// 中身は iPhone のアプリが App Group（group.com.off53jub.lifelog）に書く（LifeLog/WidgetBridge.swift）。
/// 読めないとき（App Group が使えない入れ方など）は「—」を出す。押すと LifeLog を開く。予定の名前はロック中は隠す。
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.phoneKind, provider: StatusProvider()) { entry in
            StatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("LifeLog の様子")
        .description("録音しているか、今日までの頼まれごと、次の予定、家の PC を出します。押すと LifeLog を開きます。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall, .systemMedium])
    }
}

struct StatusProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
        /// アプリが書いた中身（読めなければ nil）
        let state: WidgetState?
    }

    func placeholder(in context: Context) -> Entry { Entry(date: .now, state: WidgetState.sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        // ウィジェットを選ぶ画面では、まだ中身が無ければ見本を出す
        let state: WidgetState? = WidgetState.load() ?? (context.isPreview ? WidgetState.sample : nil)
        completion(Entry(date: .now, state: state))
    }

    /// 今と、次の予定の始まり・終わり、次の0時に切り替わる。中身はアプリが書いたら読み直してもらう
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        let state = WidgetState.load()
        let entries = (state?.timelineDates(from: now) ?? [now]).map { Entry(date: $0, state: state) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(WidgetState.refreshAfter))))
    }
}

private struct StatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusProvider.Entry

    private var state: WidgetState? { entry.state }
    private var recording: Bool { WidgetText.anyRecording(state) }
    private var recordingSymbol: String { recording ? "record.circle.fill" : "waveform" }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// この端末の印と名前（iPad なら iPad）
    private var device: String { isPad ? "ipad" : "iphone" }
    private var deviceName: String { isPad ? "iPad" : "iPhone" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            // 入りきらなければ短いほう
            ViewThatFits {
                Label(WidgetText.inline(state), systemImage: recordingSymbol)
                Label(WidgetText.summary(state), systemImage: recordingSymbol)
            }
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: - ロック画面

    /// 録音中の印と、今日までの頼まれごとの数
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: recordingSymbol)
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

    /// 録音（iPhone・時計）・次の予定・今日までの頼まれごと
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                WidgetIconText(symbol: device, text: WidgetText.phone(state))
                if let watch = WidgetText.watch(state) {
                    WidgetIconText(symbol: "applewatch", text: watch)
                }
            }
            .font(.headline)
            .widgetAccentable()
            WidgetEventLine(state: state, date: entry.date)
            WidgetIconText(symbol: "checklist", text: WidgetText.tasks(state))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - ホーム画面

    private var phoneTint: Color? { state?.phoneRecording == true ? .red : nil }
    private var watchTint: Color? {
        if state?.watchQuiet == true { return .orange }
        return state?.watchRecording == true ? .red : nil
    }
    private var tasksTint: Color? { (state?.tasksOverdue ?? 0) > 0 ? .orange : nil }
    private var pcTint: Color? { state?.pcOK == false ? .orange : nil }

    /// 録音（iPhone・時計）・頼まれごと・次の予定・文字にした時刻と PC
    private var small: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("LifeLog")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                }
            }
            WidgetIconText(symbol: device, text: WidgetText.phone(state), tint: phoneTint)
                .font(.subheadline.bold())
            if let watch = WidgetText.watch(state) {
                WidgetIconText(symbol: "applewatch", text: watch, tint: watchTint)
            }
            WidgetIconText(symbol: "checklist", text: WidgetText.tasks(state), tint: tasksTint)
            WidgetEventLine(state: state, date: entry.date)
            Spacer(minLength: 0)
            Text(footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 小さいウィジェットの下の行（「文字にした 10:32・PC ○」）
    private var footer: String {
        let parts = [WidgetText.processed(state, at: entry.date), WidgetText.pc(state)].compactMap { $0 }
        return parts.isEmpty ? WidgetText.unknown : parts.joined(separator: "・")
    }

    /// 左に録音と様子、右に次の予定と頼まれごと
    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("録音")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                WidgetIconText(symbol: device, text: deviceName + " " + WidgetText.phone(state), tint: phoneTint)
                if let watch = WidgetText.watch(state) {
                    WidgetIconText(symbol: "applewatch", text: "時計 " + watch, tint: watchTint)
                }
                if let pc = WidgetText.pc(state, long: true) {
                    WidgetIconText(symbol: "desktopcomputer", text: pc, tint: pcTint)
                }
                WidgetIconText(symbol: "text.bubble",
                               text: WidgetText.processed(state, at: entry.date) ?? "文字にした " + WidgetText.unknown)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("次の予定")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                WidgetEventLine(state: state, date: entry.date)
                Text("頼まれごと")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                WidgetIconText(symbol: "checklist", text: WidgetText.tasks(state), tint: tasksTint)
                if let open = WidgetText.openTasks(state) {
                    Text(open)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

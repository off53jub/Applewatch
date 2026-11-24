import Foundation
import Network
import SwiftUI

// s25（2026-11-24）の A2 の画面と様子: 引き算の版（大1）・時計の版が古いまま（堅3）・段ごとの待ち（早1・早3）・
// 初めはオフのまま 30 日（片3）・静かな試し（堅4・K6）。決まりは S25URules.swift。番号は母艦の docs/system-proposal-2026-11-13.md の
// 「追記 14」「追記 15」。

// MARK: - 早3 送ったときの道

/// いまの通り道（Wi-Fi・モバイル通信・つながっていない）。名前も住所も残さない
final class S25UNet: @unchecked Sendable {
    static let shared = S25UNet()
    private let monitor = NWPathMonitor()

    private init() {
        monitor.start(queue: DispatchQueue(label: "LifeLog.s25u.net"))
    }

    static var now: S25UWait.Net { shared.read() }

    private func read() -> S25UWait.Net {
        let path = monitor.currentPath
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) { return .cell }
        return .wifi
    }
}

// MARK: - 様子と時計の版

@MainActor
enum S25UBook {
    /// 静かな試し（K6）が最後に届いた時刻
    static let pingAtKey = "s25u.pingAt"

    /// 「初めはオフ」で S22 の一覧に無いスイッチ（片3。どれも UserDefaults の Bool・初めはオフ）
    static let extraOffKeys: [String] = [HolidaySettings.recordNudgeKey, HolidaySettings.awayModeKey,
                                         HolidaySettings.venueHoldKey, Summarizer.pcLLMKey]

    /// 様子（diag の state）に足すもの（どれも省ける）
    static func diagState(_ pipeline: Pipeline, now: Date = .now) -> [String: Any] {
        var out: [String: Any] = [:]
        // 早1・早3: 段ごとの待ちと、iPhone→PC の中身
        if let wait = S25UWait.summary(Latency.samples(), now: now) { out["s25uWait"] = wait }
        // 片3: 初めはオフのまま 30 日の設定（消さない・一覧だけ）
        let off = offLong(pipeline, now: now)
        out["s25uOffLong"] = off.long
        out["s25uOffWatching"] = off.watching
        // 堅4・K6: 静かな試しが最後に届いた時刻
        if let at = UserDefaults.standard.object(forKey: pingAtKey) as? Date { out["s25uPingAt"] = PCJSON.string(at) }
        // 堅3: 時計の版が古いと分かった時刻
        let lag = watchLag(now: now)
        if let since = lag.since, let pair = lag.pair {
            out["s25uWatchLagSince"] = PCJSON.string(since)
            out["s25uWatchLagPair"] = pair
        }
        // 大1: 引き算の版か
        out["s25uSimple"] = S25USimple.isOn
        return out
    }

    /// 片3 の帳を新しくして、30 日オフのままのものと、見ている数を返す
    static func offLong(_ pipeline: Pipeline, now: Date = .now) -> (long: [String], watching: Int) {
        var entries: [(id: String, on: Bool)] = S22SettingEntry.all.filter { !$0.defaultOn }.map { (id: $0.id, on: $0.get(pipeline)) }
        for key in extraOffKeys { entries.append((id: key, on: UserDefaults.standard.bool(forKey: key))) }
        let today = ReviewRules.dayKey(now)
        let saved = UserDefaults.standard.dictionary(forKey: S25UOffLong.key) as? [String: String] ?? [:]
        let next = S25UOffLong.update(saved: saved, offByDefault: entries, today: today)
        if next != saved { UserDefaults.standard.set(next, forKey: S25UOffLong.key) }
        return (S25UOffLong.long(next, today: today), next.count)
    }

    /// 堅3: 時計が古いと分かった組と時刻を新しくする（古くなければ忘れる）
    static func watchLag(now: Date = .now) -> (pair: String?, since: Date?) {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        let pair = S25UWatchLag.pair(phone: AppBuild.current, watch: detail["watchBuild"] as? String)
        let defaults = UserDefaults.standard
        let savedPair = defaults.string(forKey: S25UWatchLag.pairKey)
        let savedSince = defaults.object(forKey: S25UWatchLag.sinceKey) as? Date
        let since = S25UWatchLag.since(pair: pair, savedPair: savedPair, savedSince: savedSince, now: now)
        if let pair, let since {
            if pair != savedPair || since != savedSince {
                defaults.set(pair, forKey: S25UWatchLag.pairKey)
                defaults.set(since, forKey: S25UWatchLag.sinceKey)
            }
        } else if savedPair != nil {
            defaults.removeObject(forKey: S25UWatchLag.pairKey)
            defaults.removeObject(forKey: S25UWatchLag.sinceKey)
        }
        return (pair, since)
    }

    /// 「今日」の「気をつけること」の 1 行（出さないときは nil）
    static func watchLagLine(now: Date = .now) -> String? {
        let lag = watchLag(now: now)
        guard S25UWatchLag.shouldShow(since: lag.since, now: now, watchSeen: PCDiag.watchSeenAt != nil),
              let since = lag.since, let watch = lag.pair?.split(separator: "-").first else { return nil }
        return S25UWatchLag.line(phone: AppBuild.current, watch: String(watch), hours: Int(now.timeIntervalSince(since) / 3600))
    }
}

/// 時計の版が古いままの 1 行（押すと今ある「時計の LifeLog を新しく」の手順）
struct S25UWatchLagRow: View {
    let text: String

    var body: some View {
        NavigationLink {
            S22WatchUpdateView()
        } label: {
            S24RoleLabel(text: text, role: .act)
        }
    }
}

// MARK: - 大1 引き算の版

/// 設定の「ほか」への入口と、前の並びに戻すスイッチ（どちらの並びでも出す）
struct S25USimpleSection: View {
    @Binding var simple: Bool

    var body: some View {
        Section {
            if simple {
                NavigationLink {
                    S25UMoreSettingsView()
                } label: {
                    Label("ほかの設定（よく使う・説明・録り方の組・朝と夜の知らせ・休日）", systemImage: "square.stack")
                }
            }
            Toggle("設定を少なく見せる（引き算の版）", isOn: $simple)
                .onChange(of: simple) { _, on in Tally.add(on ? "s25u.simple.on" : "s25u.simple.off") }
        } footer: {
            Text(simple
                 ? "あまり触らない設定は「ほかの設定」と「くわしい設定」に移しました（消していません）。スイッチを切ると前の並びに戻ります。"
                 : "オンにすると、設定・点検・ふり返りを主なものだけにして、ほかは「ほか」にまとめます。")
        }
    }
}

/// ほかの設定（引き算の版で「設定」から移したもの。中身は前と同じ）
struct S25UMoreSettingsView: View {
    @AppStorage(ClaudeRoute.useKey) private var useClaude = true
    @AppStorage(ClaudeRoute.workKey) private var claudeForWork = true

    var body: some View {
        LLList {
            // よく使う・説明（s20）
            S20SettingsSection(showScene: false)
            // 電池優先・早さ優先・精度優先（s21）
            S21PresetSection()
            Section {
                MorningBriefSettingsRows()
                NightMoodSettingsRows()
                Toggle("職場の会話も Claude で", isOn: $claudeForWork)
                    .disabled(!useClaude)
                    .onChange(of: claudeForWork) { _, _ in ClaudeRoute.resetPauses() }
            } header: {
                Text("知らせと Claude")
            }
            // 休日（s19）
            HolidaySettingsSection()
        }
        .navigationTitle("ほかの設定")
        .countsOpen("s25uMoreSettings")
    }
}

/// 点検の主なもの（引き算の版）
struct S25UCheckMainSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        Section {
            NavigationLink("自己点検（実機で動いたか・画面を開いた回数も）") { DiagnosticsView() }
            NavigationLink("聞き取りの成績") { ListenQualityView() }
            if pipeline.homePC.features.contains("reports") {
                NavigationLink("報告の棚（母艦の報告を読む）") { S22ReportsView() }
            }
            NavigationLink {
                S25UMoreCheckView()
            } label: {
                Label("ほかの点検（録音の抜け・時計・実機の確かめ・通信簿・控えと掃除 など）", systemImage: "square.stack")
            }
        } header: {
            Text("調子")
        } footer: {
            Text("調子が悪いときは「自己点検」から。ほかの点検は消さずに「ほかの点検」にまとめました（設定の「設定を少なく見せる」を切ると前の並び）。")
        }
    }
}

/// ほかの点検（引き算の版で「点検」から移したもの。中身は前と同じ）
struct S25UMoreCheckView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        LLList {
            Section {
                NavigationLink("録音の抜けと数の照合") { RecordingMapView() }
                if !pipeline.watchDelays.entries.isEmpty {
                    NavigationLink("時計の遅れ") { WatchDelayView() }
                }
                NavigationLink("クラウドに送ったもの") { CloudLogView() }
            } header: {
                Text("調子")
            }
            S21CheckSection()
            S22CheckSection()
            ChecklistSection()
            MothershipCheckSection()
            ReflectionCheckSection()
            SettleCheckSection()
            SettingsBackupSection()
        }
        .navigationTitle("ほかの点検")
        .countsOpen("s25uMoreCheck")
    }
}

/// ふり返りの「ほか」への入口（引き算の版）
struct S25UMoreLookBackLink: View {
    var body: some View {
        Section {
            NavigationLink {
                S25UMoreLookBackView()
            } label: {
                Label("ほかのふり返り（時間の家計簿・緊張した場面・話題の糸）", systemImage: "square.stack")
            }
        }
    }
}

struct S25UMoreLookBackView: View {
    var body: some View {
        LLList {
            TimeLedgerSection()
            TensionLookBackSection()
            ThreadsLookBackSection()
            Section {
                EmptyView()
            } footer: {
                Text("家の PC から写しが届いているものだけが出ます。設定の「設定を少なく見せる」を切ると、ふり返りの前の並びに戻ります。")
            }
        }
        .navigationTitle("ほかのふり返り")
        .countsOpen("s25uMoreLookBack")
    }
}

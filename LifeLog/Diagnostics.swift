import AVFoundation
import CoreLocation
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// アプリの動き具合の記録（エラーと、処理にかかった時間）。
/// 「自己点検」の画面と、ドライブの「診断」ドキュメントに出す。会話の中身や人の名前は入れない。
@MainActor
@Observable
final class DiagnosticsLog {
    struct Problem: Codable {
        let time: Date
        let text: String
    }

    struct Run: Codable {
        let start: Date
        /// 始めから終わりまで（家の PC を待った・裏にいた時間も入る）
        let seconds: Double
        /// そのうち、家の PC が文字にし終わるのを待っていた秒（2026-11-07 から。前の記録は nil。RunClock.swift）
        var waited: Double? = nil
        /// そのうち、アプリが裏にいた秒（iOS がアプリを止めていた時間も入る。2026-11-07 から）
        var background: Double? = nil
        /// 裏で使える時間が切れた（iOS に止められた。2026-11-07 から）
        var expired: Bool? = nil
    }

    private(set) var problems: [Problem] = []
    private(set) var runs: [Run] = []
    /// 最後にドライブに書いた時刻
    var lastWritten = UserDefaults.standard.object(forKey: "diagnosticsWritten") as? Date {
        didSet { UserDefaults.standard.set(lastWritten, forKey: "diagnosticsWritten") }
    }

    private struct Saved: Codable {
        var problems: [Problem] = []
        var runs: [Run] = []
    }

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("diagnostics.json")

    init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            problems = saved.problems
            runs = saved.runs
        }
    }

    /// エラーを残す（同じ文が10分以内に続いたら1つにする。新しい50個まで）
    func problem(_ text: String) {
        guard !text.isEmpty else { return }
        if let last = problems.last, last.text == text, Date.now.timeIntervalSince(last.time) < 600 { return }
        problems = Array((problems + [Problem(time: .now, text: text)]).suffix(50))
        save()
    }

    /// 1回の処理（区切りの文字起こしから、まとめ・同期まで）にかかった時間（新しい300回まで）
    /// parts は、そのあいだに家の PC を待った・裏にいた時間（RunClock.swift）。expired は裏で使える時間が切れたか
    func ran(from start: Date, parts: RunClock.Parts? = nil, expired: Bool = false) {
        var run = Run(start: start, seconds: Date.now.timeIntervalSince(start))
        if let parts {
            run.waited = parts.waited
            run.background = parts.background
        }
        if expired { run.expired = true }
        runs = Array((runs + [run]).suffix(300))
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(problems: problems, runs: runs)) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// 自己点検の1行
struct DiagnosticItem: Identifiable {
    let section: String
    let label: String
    let value: String
    /// 良い・気をつけたい・どちらでもない（nil）
    let ok: Bool?
    var id: String { section + "/" + label }
}

extension Pipeline {
    private static let diagTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private static func when(_ date: Date?) -> String { date.map { diagTime.string(from: $0) } ?? "まだ" }

    private static func seconds(_ s: Double) -> String { s < 10 ? String(format: "%.1f 秒", s) : "\(Int(s)) 秒" }

    /// 自己点検の中身。会話の中身・人の名前・メールアドレスは入れない。
    func diagnosticItems() async -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        func add(_ section: String, _ label: String, _ value: String, _ ok: Bool? = nil) {
            items.append(DiagnosticItem(section: section, label: label, value: value, ok: ok))
        }
        func onOff(_ on: Bool) -> String { on ? "オン" : "オフ" }

        // 端末
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String ?? "?") + "（" + (info?["CFBundleVersion"] as? String ?? "?") + "）"
        add("端末", "アプリの版", version)
        if let expiry = Provisioning.expiryText() {
            add("端末", "署名の期限", expiry + (Provisioning.isNear() ? "・Sideloadly で入れ直す" : ""), !Provisioning.isNear())
        } else {
            add("端末", "署名の期限", "分からない（TestFlight など）")
        }
        add("端末", "機種・iOS", UIDevice.current.model + "・iOS " + UIDevice.current.systemVersion)
        let crashes = CrashWatch.summary()
        add("端末", "落ちた・固まった", crashes.text, crashes.ok)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        add("端末", "低電力モード", onOff(lowPower), !lowPower)
        let free = (try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        if let free { add("端末", "空き容量", String(format: "%.1f GB", Double(free) / 1e9), free > 2_000_000_000) }
        let refresh = UIApplication.shared.backgroundRefreshStatus
        add("端末", "Appのバックグラウンド更新", refresh == .available ? "使える" : "使えない（設定でオンに）", refresh == .available)

        // 許可
        let mic = AVAudioApplication.shared.recordPermission
        add("許可", "マイク", mic == .granted ? "許可" : "未許可", mic == .granted)
        let notify = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        add("許可", "通知", notify == .authorized ? "許可" : "未許可", notify == .authorized)
        if places.isOn {
            let always = places.authorization == .authorizedAlways
            add("許可", "位置情報", always ? "常に" : (places.authorization == .authorizedWhenInUse ? "使用中のみ（「常に」に）" : "未許可"), always)
        } else {
            add("許可", "位置情報", "場所の記録はオフ")
        }
        add("許可", "カレンダー", calendar.enabled ? (calendar.authorized ? "使う" : "未許可") : "オフ",
            calendar.enabled ? calendar.authorized : nil)
        add("許可", "連絡先", contacts.enabled ? (contacts.authorized ? "使う" : "未許可") : "オフ",
            contacts.enabled ? contacts.authorized : nil)
        add("許可", "移動の様子", motion.enabled ? (motion.authorized ? "使う" : "未許可") : "オフ",
            motion.enabled ? motion.authorized : nil)
        add("許可", "ヘルスケア", health.enabled ? (health.note.isEmpty ? "使う" : health.note) : "オフ")

        // 設定
        add("設定", "Google", email != nil ? "ログイン済み" : "ログインしていない", email != nil)
        add("設定", "話者の聞き分け", onOff(speakerLabelsOn))
        add("設定", "高精度（クラウド）", settings.useCloud ? (settings.hasAPIKey ? "オン" : "オン（キーが無い）") : "オフ",
            settings.useCloud ? settings.hasAPIKey : nil)
        add("設定", "今月のクラウドの文字起こし", "\(settings.usedMinutesThisMonth) 分")
        add("設定", "Groq のキー", settings.groqKey != nil ? "あり" : "なし")
        let local = LocalModel.status
        add("設定", "iPhone の中の言語モデル", LocalModel.mode.label + "・" + local.text,
            LocalModel.mode == .off ? nil : local.usable)
        add("設定", "iPhone 内の Haas-ja", haas.enabled ? (haas.isUsable ? "使える" : "準備できていない") : "オフ",
            haas.enabled ? haas.isUsable : nil)
        add("設定", "家の PC", homePC.isConfigured ? (homePC.lastResult.isEmpty ? "設定済み" : homePC.lastResult) : "使わない")
        add("設定", "待機モード", onOff(standbyOn))
        add("設定", "音がしないあいだは書かない", onOff(skipSilence))
        add("設定", "iPhone と iPad の同期", onOff(sync.isOn))
        if sync.isOn {
            // 版が古い端末があると、新しい版で足した項目が同期で抜けやすい（手元の値で埋めて守るが、入れ直すのがいちばん）
            let older = AppBuild.olderPeers()
            add("設定", "同期の相手のアプリの版",
                older.isEmpty ? (AppBuild.peers.isEmpty ? "まだ分からない" : "同じか新しい")
                    : older.map { "端末 \($0.device): " + ($0.build == 0 ? "かなり古い" : "\($0.build)") }.joined(separator: "、") + "（新しい IPA を入れ直す）",
                older.isEmpty)
        }
        add("設定", "音声をドライブにも保存", onOff(audioBackupOn))
        add("設定", "会う前のおさらい", onOff(Self.meetingBriefOn))

        // いまの状態
        add("状態", "録音", isRecording ? (recordingHeld ? "録音中（休む場所にいるので書いていない）" : "録音中") : "止まっている")
        // iPhone で録っているマイクの種類（名前は入れない。2026-11-07。MicInput.swift）
        add("状態", "iPhone のマイク", MicRoute.shared.checkText)
        add("設定", "iPhone のマイク", MicChoice.mode.label + (MicChoice.mode == .auto && MicChoice.bluetoothOn ? "（Bluetooth も）" : "")
            + (StereoMic.isOn ? "・" + StereoMic.selfSideLabel : ""))
        add("状態", "時計", watchStatusNow + (watchLowPower == true ? "・低電力モード" : ""))
        add("状態", "文字起こし待ち", "\(pendingCount) 個", pendingCount < ChunkCutter.scaled(6))
        add("状態", "ドライブに上げる前の音声", "\(backupPending) 個", backupPending < 300)
        if !lastEngine.isEmpty { add("状態", "直近の文字起こし", lastEngine) }
        add("状態", "同期", sync.isOn ? "最後 " + Self.when(sync.lastSynced) + (sync.problem.map { "・" + $0 } ?? "") : "オフ",
            sync.isOn ? sync.problem == nil : nil)
        add("状態", "控え（アプリの中）", "最後 " + Self.when(backups.lastLocal),
            backups.lastLocal.map { Date.now.timeIntervalSince($0) < 2 * 86400 } ?? false)
        add("状態", "控え（ドライブ）", "最後 " + Self.when(backups.lastDrive) + (backups.problem.map { "・" + $0 } ?? ""),
            backups.lastDrive.map { Date.now.timeIntervalSince($0) < 3 * 86400 } ?? false)

        // 家の PC とのやり取り（実機の様子・見えない通知・記録と直し。2026-11-07。PCDiag.swift）
        for row in pcLinkRows() { add(row.section, row.label, row.value, row.ok) }

        // 処理の重さ
        let runs = diagnostics.runs
        if let last = runs.last {
            // 待ち・裏にいた時間があれば、自分で動いていた時間も添える（2026-11-07）
            let own = last.working < last.seconds - 0.5 ? "（自分で動いていたのは \(Self.seconds(last.working))）" : ""
            add("処理", "最後の処理", Self.when(last.start) + "・" + Self.seconds(last.seconds) + own)
        }
        // 「ふつう・いちばん長い」は iPhone が自分で動いていた時間。家の PC を待った・裏にいた時間は別の行に出す（2026-11-07。RunClock.swift）
        if let summary = RunStats.summary(runs) {
            add("処理", "直近24時間の処理", summary.value, summary.ok)
            if let detail = summary.detail { add("処理", "直近24時間の処理の待ち", detail) }
        }
        let stats = recordStats
        add("処理", "記録のある日", "\(stats.days) 日")
        add("処理", "記録の読み込み（起動から）",
            "\(stats.loads.files) 回・" + String(format: "%.1f MB", Double(stats.loads.bytes) / 1e6) + "・" + Self.seconds(stats.loads.seconds))
        add("処理", "覚えている記録", "\(stats.cache.days) 日分・" + String(format: "%.1f MB", Double(stats.cache.bytes) / 1e6))

        // 時計の遅れ
        let arrivals = watchDelays.recent.map(\.arrival).sorted()
        if !arrivals.isEmpty {
            let slow = arrivals.last ?? 0
            add("時計", "届くまで（直近24時間）",
                "ふつう \(WatchDelayLog.text(arrivals[arrivals.count / 2]))・いちばん遅い \(WatchDelayLog.text(slow))", slow < 12 * 60)
            // 内訳: 時計で待ったのか、受け渡し（iPhone のアプリが受け取るまで）が遅いのか（2026-11-07。時計が控えを添えた区切りだけ）
            if let split = WatchDelayLog.splitText(watchDelays.recent) {
                add("時計", "届くまでの内訳（直近24時間）", split)
            }
            // 時計が低電力モードだった区切り（まとめて送るので遅れる）
            let lowPowerArrivals = watchDelays.recent.filter { $0.lowPower == true }.map(\.arrival).sorted()
            if !lowPowerArrivals.isEmpty {
                add("時計", "届くまで（時計が低電力モードのとき）",
                    "\(lowPowerArrivals.count) 個・ふつう \(WatchDelayLog.text(lowPowerArrivals[lowPowerArrivals.count / 2]))")
            }
        }
        // 届かないとき（直近24時間に1つも届かないと上の行は出ない）にも分かるように、最後に届いた時刻と、時計に残っている数（2026-11-07）
        if let last = watchDelays.entries.last {
            let late = Date.now.timeIntervalSince(last.received)
            add("時計", "最後に届いた時計の区切り", Self.when(last.received), isWatchRecording ? late < 3600 : nil)
        } else if isWatchRecording {
            add("時計", "最後に届いた時計の区切り", "まだ届いていません", false)
        }
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        if let pending = detail["watchPending"] as? Int {
            let kept = detail["watchKept"] as? Int ?? 0
            let moving = detail["watchOutstanding"] as? Int
            var text = "まだ送っていない \(pending) 個" + (moving.map { "（うち送っている途中 \($0) 個）" } ?? "") + "・返事待ち \(kept) 個"
            if let cut = detail["watchLastCut"] as? Double { text += "・最後に区切った " + Self.when(Date(timeIntervalSince1970: cut)) }
            if detail["watchHeld"] as? Bool == true { text += "・休む場所にいると思っている" }
            add("時計", "時計に残っている区切り", text, pending + kept <= ChunkCutter.scaled(4))
        }
        // 時計の区切りの長さ（電池が少ないので自動で5分にしているか。2026-11-07。WatchPresence.swift）
        add("時計", "区切りの長さ", watchChunkLengthText)

        // 文字になるまで（区間ごとの中央値。2026-11-07。Latency.swift）
        for row in Latency.rows() { add("文字になるまで", row.label, row.value, row.ok) }

        // 人（数だけ）
        let others = people.filter { !$0.isSelf }
        add("人", "名前のある人", "\(others.filter(\.isNamed).count) 人")
        add("人", "名前の無い声", "\(others.filter { !$0.isNamed }.count) 人")
        add("人", "記録に出さない人", "\(others.filter { $0.hidden == true }.count) 人")
        let review = voiceReview().count
        add("人", "見直したい声のひとこま", "\(review) 個", review == 0)
        add("人", "自分の声", hasSelfVoice ? "登録済み" : "まだ", hasSelfVoice)

        // 直した記録から学んだ値（2026-11-06）
        let shift = Double(SpeakerTuning.shift)
        add("学んだ値", "話者の近さの線", shift == 0 ? "そのまま（直し \(SpeakerTuning.fixes.count) 回）"
            : (shift > 0 ? "ゆるく " : "厳しく ") + String(format: "%.2f", abs(shift)) + "（直し \(SpeakerTuning.fixes.count) 回から）")
        let taught = TaskLearning.examples(tasks.items).count
        add("学んだ値", "頼まれごとの候補の並び", TaskLearning.weights != nil ? "採りそうな順（採用・却下 \(taught) 件から）"
            : "まだ（採用・却下 \(taught) / 30 件）")
        add("学んだ値", "会話の区切り", "\(Int(ConversationGap.current)) 秒（つなぐ・分ける \(ConversationGap.events.count) 回から）")
        add("学んだ値", "多数決の重み（騒がしい・静か）",
            [("騒がしい", ".noisy"), ("静か", ".quiet")].map { label, suffix in
                label + ": " + (UserDefaults.standard.string(forKey: AnswerKey.weightsKey + suffix) ?? "全体のもの")
            }.joined(separator: "／"))
        add("学んだ値", "確かめたほうがよい行", String(format: "線 %.2f", ConversationLog.Line.uncertainBelow)
            + (Calibration.weights != nil ? "・手がかりを束ねて判断" : ""))

        // 精度の物差し（答え合わせの行を今の設定で文字にし直した誤りの割合。2026-11-06）
        let bench = Benchmark.report()
        if bench.isEmpty {
            add("精度の物差し", "まだ測っていません", "答え合わせをして、夜に家の PC につながると測ります")
        }
        for row in bench { add("精度の物差し", row.label, row.value, row.ok) }
        if homePC.isConfigured {
            let model = UserDefaults.standard.bool(forKey: PersonalMaterial.modelKey)
            add("精度の物差し", "あなた向けのモデル", model ? "PC で使っている"
                : "まだ（材料 \(PersonalMaterial.need) 個と NVIDIA の GPU で学べる）")
            // 材料の数と、学び直しまであと何個か（家の PC に聞けたときだけ。2026-11-07。ReviewNudge.swift）
            if let material = PersonalMaterial.latest() {
                add("精度の物差し", "学び直しの材料", PersonalMaterial.text(material) + "（\(Self.when(material.at)) に家の PC で数えた）",
                    material.left == 0 ? true : nil)
            }
            // 「聞いて直す」で答えて、まだ家の PC に送っていない材料（夜に送る）
            let waiting = reviewNudgeUnsent()
            if waiting > 0 {
                add("精度の物差し", "聞いて直すの材料（まだ送っていない）", "\(waiting) 個（夜に充電しているとき送る）")
            }
        }

        // 仕組みごとの効き目（直近7日。数だけ。2026-11-06）
        let report = Tally.report(Tally.sums(days: 7))
        if report.isEmpty {
            add("効き目（直近7日）", "まだ数えていません", "夜の聞き直しや、複数のモデルの見比べが動くと数えます")
        }
        for row in report { add("効き目（直近7日）", row.label, row.value, row.ok) }

        // 最近のエラー
        for problem in diagnostics.problems.suffix(15).reversed() {
            add("最近のエラー", Self.diagTime.string(from: problem.time), problem.text, false)
        }
        return items
    }

    /// ドライブの「診断」に書く形
    static func diagnosticParagraphs(_ items: [DiagnosticItem]) -> [(text: String, style: String?)] {
        var p: [(text: String, style: String?)] = []
        p.append(("LifeLog の診断（\(diagTime.string(from: .now)) に書いた）", "HEADING_1"))
        p.append(("アプリの動き具合です。会話の中身・人の名前は入っていません。アプリが1時間に1回ほど書き直します。✗ は気をつけたいところ。", nil))
        var section = ""
        for item in items {
            if item.section != section {
                section = item.section
                p.append((section, "HEADING_2"))
            }
            let mark = item.ok.map { $0 ? "✓ " : "✗ " } ?? "・"
            p.append((mark + item.label + ": " + item.value, nil))
        }
        return p
    }
}

/// 自己点検の画面
struct DiagnosticsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var items: [DiagnosticItem] = []
    @State private var writing = false
    @State private var note: String?

    var body: some View {
        let sections = items.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        Form {
            Section {
                Button(writing ? "書いています…" : "ドライブの「診断」に書く") {
                    writing = true
                    Task {
                        note = await pipeline.writeDiagnostics(force: true)
                        writing = false
                    }
                }
                .disabled(writing)
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("同じ中身を、ドライブの「LifeLog」フォルダの「診断」ドキュメントにも1時間に1回ほど書きます。会話の中身・人の名前は入れません。Claude などに「診断を見て」と頼むと、実際の iPhone での動き具合を読めます。")
            }
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(items.filter { $0.section == section }) { item in
                        HStack(alignment: .firstTextBaseline) {
                            if let ok = item.ok {
                                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(ok ? Color.green : Color.orange)
                            }
                            if section == "最近のエラー" {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                                    Text(item.value).font(.callout)
                                }
                            } else {
                                LabeledContent(item.label) { Text(item.value).multilineTextAlignment(.trailing) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("自己点検")
        .task {
            items = await pipeline.diagnosticItems()
            // 学び直しの材料の数を家の PC に聞き直して、出し直す（家の PC を使っていて、少し聞いていないときだけ。2026-11-07）
            if pipeline.homePC.isConfigured, PersonalMaterial.isStale() {
                await pipeline.refreshPersonalCount()
                items = await pipeline.diagnosticItems()
            }
        }
        .refreshable {
            if pipeline.homePC.isConfigured { await pipeline.refreshPersonalCount() }
            items = await pipeline.diagnosticItems()
        }
    }
}

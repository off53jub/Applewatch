import MapKit
import Observation
import SwiftUI

// s22（2026-11-22）の画面（決まりは S22Rules.swift・S22Checkup.swift・Shared/Audio/S22Watch.swift、帳は S22Book.swift。docs/s22-app.md）。
// 色・形は DesignKit・LLTheme の部品を使うだけ（見た目は A2 の持ち分）。

// MARK: - 楽1〜3 自己点検のいちばん上: いまやること 3 つ・印・Claude に頼む

struct S22CheckupTopSection: View {
    @Environment(Pipeline.self) private var pipeline
    let items: [DiagnosticItem]

    var body: some View {
        let list = S22Checkup.focus(rows, now: .now)
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        let watchBuild = detail["watchBuild"] as? String
        Section {
            if list.top.isEmpty {
                Label("いまやることはありません", systemImage: "checkmark.circle").foregroundStyle(LL.good)
            }
            ForEach(list.top) { focus in
                HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                    Image(systemName: focus.fix.symbol)
                        .foregroundStyle(focus.fix == .self_ ? LL.warn : LL.dim)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(focus.title).font(.callout)
                        Text(focus.fix.label + (focus.count > 1 ? "・\(focus.count) 回" : "")).font(.caption).foregroundStyle(LL.dim)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if list.others > 0 || list.folded > 0 {
                Text([list.others > 0 ? "ほかに \(list.others) 種類" : nil,
                      list.folded > 0 ? "7 日より前のエラー \(list.folded) 個は畳みました" : nil].compactMap { $0 }.joined(separator: "・"))
                    .font(.caption).foregroundStyle(LL.dim)
            }
            if S22Rules.needsWatchUpdate(S22Rules.watchVersion(phone: AppBuild.current, watch: watchBuild)), PCDiag.watchSeenAt != nil {
                NavigationLink {
                    S22WatchUpdateView()
                } label: {
                    Label("時計の LifeLog を新しくする", systemImage: "applewatch.radiowaves.left.and.right")
                }
            }
            ShareLink(item: S22Checkup.askClaudeText(list, phoneBuild: AppBuild.current, watchBuild: watchBuild, names: names,
                                                     failedChecks: S23Checks.failed().map(\.title))) {
                Label("Claude に頼む（いまの様子を共有）", systemImage: CheckupFix.askClaude.symbol)
            }
            .simultaneousGesture(TapGesture().onEnded { Tally.add("s22.askClaude") })
        } header: {
            LLHeader(title: "いまやること", symbol: "list.number")
        } footer: {
            Text("同じ種類はまとめ、7 日より前のエラーは畳みます。印は「自分で直せる・待てば直る・Claude に頼む」。「Claude に頼む」は、いまの様子を 1 つの文にして共有シートに渡すだけです（人の名前・会話の中身・場所の名前・鍵は入れません）。")
        }
    }

    private var rows: [CheckupRow] {
        var out = items.filter { $0.section != S22Checkup.errorSection }
            .map { CheckupRow(section: $0.section, label: $0.label, value: $0.value, ok: $0.ok) }
        for problem in pipeline.diagnostics.problems where !S21Rules.isProgress(problem.text) {
            out.append(CheckupRow(section: S22Checkup.errorSection, label: "", value: problem.text, ok: false, time: problem.time))
        }
        return out
    }

    private var names: [String] {
        var list = pipeline.people.compactMap(\.name)
        let today = ReviewRules.dayKey(.now)
        let yesterday = ReviewRules.dayKey(Date.now.addingTimeInterval(-86400))
        for day in [today, yesterday] {
            for talk in pipeline.conversations(on: day) {
                if let place = talk.place { list.append(place) }
                if let event = talk.event { list.append(event) }
            }
        }
        return list
    }
}

/// 楽4: 生の英語のエラーを日本語の 1 行に。元の文は「詳しく」に畳む
struct S22ErrorText: View {
    let raw: String
    @State private var open = false

    var body: some View {
        let friendly = S22Checkup.friendlyError(raw)
        VStack(alignment: .leading, spacing: 2) {
            Text(friendly.short).font(.callout)
            if let detail = friendly.detail {
                Button(open ? "閉じる" : "詳しく") { open.toggle() }
                    .font(.caption).buttonStyle(.borderless)
                if open {
                    Text(detail).font(.caption2.monospaced()).foregroundStyle(LL.dim).textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - 楽7・楽19 今日の画面の 1 行

struct S22TodaySection: View {
    var body: some View {
        let latency = S22Rules.talkToTextLine(S22Rules.talkToTextMinutes(totalMedian: Latency.summary()?.total,
                                                                           chunkTypical: ChunkCutter.current.typical))
        let watch = S22Book.watchBatteryLine()
        let phone = S22Book.phoneBatteryLine()
        if latency != nil || watch != nil || phone != nil {
            Section {
                if let latency { Label(latency, systemImage: "text.bubble").font(.callout) }
                if let watch { Label("時計: " + watch, systemImage: "applewatch").font(.caption).foregroundStyle(LL.dim) }
                if let phone { Label("iPhone: " + phone, systemImage: "iphone").font(.caption).foregroundStyle(LL.dim) }
            }
        }
    }
}

// MARK: - 点検のページの入口（楽5・楽10・楽20・楽6）

struct S22CheckSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var note: String?

    var body: some View {
        Section {
            if pipeline.homePC.features.contains("reports") {
                NavigationLink("報告の棚（母艦の報告を読む）") { S22ReportsView() }
            }
            if pipeline.homePC.features.contains("gappatterns") {
                NavigationLink("いつも録れない時間帯と場所") { S22GapPatternsView() }
            }
            NavigationLink("時計の LifeLog を新しくする") { S22WatchUpdateView() }
            if let backlog = S22Book.watchBacklogText() {
                LabeledContent("時計に溜まった分", value: backlog)
            }
            Button("時計に「いま送り直す」を頼む", systemImage: "arrow.clockwise") {
                note = S22Book.resendWatchNow() ? "頼みました（時計とつながったときに始まります）" : "時計とつながっていません"
            }
            if let note { Text(note).font(.caption).foregroundStyle(LL.dim) }
        } header: {
            Text("報告と時計")
        }
    }
}

// MARK: - 楽10 時計の版が古い・分からないときの手順

struct S22WatchUpdateView: View {
    @State private var note: String?

    var body: some View {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        let version = S22Rules.watchVersion(phone: AppBuild.current, watch: detail["watchBuild"] as? String)
        LLList {
            Section {
                LabeledContent("iPhone の版", value: "\(AppBuild.current)")
                LabeledContent("時計の版", value: (detail["watchBuild"] as? String) ?? "分からない")
                Text(stateText(version)).font(.callout)
                    .foregroundStyle(S22Rules.needsWatchUpdate(version) ? LL.warn : LL.good)
            } header: {
                LLHeader(title: "いまの版", symbol: "applewatch")
            }
            Section {
                ForEach(Array(S22Rules.watchUpdateSteps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(i + 1)").font(.headline).foregroundStyle(LL.accent).frame(width: 22)
                        Text(step).font(.callout)
                    }
                }
            } header: {
                LLHeader(title: "新しくする手順（上から順に）", symbol: "list.number")
            } footer: {
                Text("「分からない」は、時計の LifeLog が版を知らせない古い版（356 より前）のままか、時計の便りがまだ届いていないときです。iPhone の LifeLog を入れ替えても、時計の分は入れ替わらないことがあります（仮説）。新しくなると、溜まった返事待ちを時計が自分で片付けます。")
            }
            Section {
                Button("時計に「いま送り直す」を頼む", systemImage: "arrow.clockwise") {
                    note = S22Book.resendWatchNow() ? "頼みました" : "時計とつながっていません"
                }
                if let note { Text(note).font(.caption).foregroundStyle(LL.dim) }
            }
        }
        .navigationTitle("時計の LifeLog を新しく")
        .countsOpen("s22WatchUpdate")
    }

    private func stateText(_ v: S22Rules.WatchVersion) -> String {
        switch v {
        case .same(let b): "同じ版です（\(b)）"
        case .watchOlder(let w, let p): "時計が古い版です（時計 \(w)・iPhone \(p)）"
        case .phoneOlder(let w, let p): "iPhone のほうが古い版です（時計 \(w)・iPhone \(p)）"
        case .unknown: "時計の版が分かりません"
        }
    }
}

// MARK: - 楽5 報告の棚

struct S22ReportsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var reports: [S22Rules.ReportsFeed.Report] = []
    @State private var note: String?
    @State private var loading = true

    var body: some View {
        LLList {
            Section {
                if loading { ProgressView() }
                ForEach(reports) { report in
                    NavigationLink {
                        S22ReportView(report: report)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.title.isEmpty ? report.name : report.title)
                            Text([report.updated_at.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") },
                                  S22Rules.sizeText(report.bytes)].compactMap { $0 }.joined(separator: "・"))
                                .font(.caption).foregroundStyle(LL.dim)
                        }
                    }
                }
                if let note { Text(note).font(.caption).foregroundStyle(LL.dim) }
            } footer: {
                Text("母艦の reports/ にある報告です（家の PC が出すものだけ。職場の中身の報告は出しません）。読むだけです。")
            }
        }
        .overlay {
            if !loading && reports.isEmpty && note == nil { LLEmpty(title: "報告はまだありません", symbol: "doc.text") }
        }
        .navigationTitle("報告の棚")
        .countsOpen("s22Reports")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await pipeline.homePC.appFeed("reports", feature: "reports")
            let feed = try JSONDecoder().decode(S22Rules.ReportsFeed.self, from: data)
            reports = S22Rules.visibleReports(feed)
            note = nil
        } catch {
            note = "読めませんでした: " + S22Checkup.friendlyError(HomePC.describe(error)).short
        }
    }
}

struct S22ReportView: View {
    @Environment(Pipeline.self) private var pipeline
    let report: S22Rules.ReportsFeed.Report
    @State private var text: String?
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let text {
                    // 表は 1 行 1 カードに（見19 の部品。2026-11-23。s23 の 続7）
                    LLMarkdownView(text: text)
                } else if let note {
                    Text(note).foregroundStyle(LL.dim)
                } else {
                    ProgressView()
                }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(LL.bg)
        .navigationTitle(report.title.isEmpty ? report.name : report.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard S22Rules.isSafeReportName(report.name) else {
            note = "読めない名前です"
            return
        }
        do {
            let data = try await pipeline.homePC.appFeed("reports/" + report.name, feature: "reports")
            text = String(data: data, encoding: .utf8) ?? ""
            Tally.add("s22.report.read")
        } catch {
            note = "読めませんでした: " + S22Checkup.friendlyError(HomePC.describe(error)).short
        }
    }
}

// MARK: - 楽20 いつも録れない時間帯と場所

struct S22GapPatternsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var patterns: S22Rules.GapPatterns?
    @State private var note: String?

    var body: some View {
        LLList {
            if let patterns {
                let grid = S22Rules.gapGrid(patterns)
                let top = grid.flatMap { $0 }.max() ?? 0
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 1) {
                            Text("").frame(width: 18)
                            ForEach([0, 6, 12, 18], id: \.self) { h in
                                Text("\(h)").font(.caption2).foregroundStyle(LL.dim).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(0..<7, id: \.self) { d in
                            HStack(spacing: 1) {
                                Text(S22Rules.weekdayLabels[d]).font(.caption2).frame(width: 18)
                                ForEach(0..<24, id: \.self) { h in
                                    Rectangle()
                                        .fill(LL.warn.opacity(top > 0 ? 0.08 + 0.9 * grid[d][h] / top : 0.08))
                                        .frame(height: 14)
                                        .accessibilityLabel("\(S22Rules.weekdayLabels[d]) \(h) 時 \(Int(grid[d][h])) 分")
                                }
                            }
                        }
                    }
                    ForEach(S22Rules.worstHours(patterns), id: \.self) { Text($0).font(.callout) }
                } header: {
                    LLHeader(title: "曜日と時間帯（濃いほど録れていない）", symbol: "calendar")
                }
                Section {
                    let pins = patterns.by_place.filter { $0.lat != nil && $0.lon != nil }
                    if !pins.isEmpty {
                        Map(initialPosition: .automatic) {
                            ForEach(pins) { p in
                                Marker(p.place, coordinate: CLLocationCoordinate2D(latitude: p.lat ?? 0, longitude: p.lon ?? 0))
                                    .tint(LL.warn)
                            }
                        }
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                    }
                    ForEach(patterns.by_place.sorted { $0.gap_minutes > $1.gap_minutes }.prefix(10)) { p in
                        LabeledContent(p.place, value: S22Watch.durationText(p.gap_minutes * 60) + (p.days.map { "（\($0) 日）" } ?? ""))
                    }
                } header: {
                    LLHeader(title: "場所", symbol: "map")
                }
            } else {
                Section { Text(note ?? "読んでいます…").foregroundStyle(LL.dim) }
            }
        }
        .navigationTitle("いつも録れない所")
        .countsOpen("s22GapPatterns")
        .task { await load() }
    }

    private func load() async {
        do {
            let data = try await pipeline.homePC.appFeed("capture-gap-patterns", feature: "gappatterns")
            patterns = try JSONDecoder().decode(S22Rules.GapPatterns.self, from: data)
        } catch {
            note = "読めませんでした: " + S22Checkup.friendlyError(HomePC.describe(error)).short
        }
    }
}

// MARK: - 楽8・楽9 設定を探す・変えた所だけ・初めに戻す

/// 探せる設定 1 つ（スイッチだけ。初めの値と、読み書きの仕方）
struct S22SettingEntry: Identifiable {
    let id: String
    let label: String
    let group: String
    let defaultOn: Bool
    let get: @MainActor (Pipeline) -> Bool
    let set: @MainActor (Pipeline, Bool) -> Void

    @MainActor
    static func defaults(_ key: String, _ label: String, _ group: String, _ defaultOn: Bool,
                         after: (@MainActor (Pipeline) -> Void)? = nil) -> S22SettingEntry {
        S22SettingEntry(id: key, label: label, group: group, defaultOn: defaultOn,
                        get: { _ in UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn },
                        set: { pipeline, on in
                            UserDefaults.standard.set(on, forKey: key)
                            after?(pipeline)
                        })
    }

    /// 一覧（ここに無い設定は、今までどおり「くわしい設定」から）
    @MainActor
    static let all: [S22SettingEntry] = [
        S22SettingEntry(id: "chunkBatterySaver", label: "電池が少ないときは5分に", group: "録音", defaultOn: true,
                        get: { $0.chunkBatterySaver }, set: { $0.chunkBatterySaver = $1 }),
        S22SettingEntry(id: "skipSilence", label: "音がしないあいだは書かない", group: "録音", defaultOn: true,
                        get: { $0.skipSilence }, set: { $0.skipSilence = $1 }),
        S22SettingEntry(id: "dropNoVoice", label: "時計で声の無い区切りは送らない", group: "録音", defaultOn: true,
                        get: { $0.dropNoVoice }, set: { $0.dropNoVoice = $1 }),
        S22SettingEntry(id: "standbyOn", label: "待機モード", group: "録音", defaultOn: true,
                        get: { $0.standbyOn }, set: { $0.standbyOn = $1 }),
        S22SettingEntry(id: "homePCWatchDirect", label: "時計から家の PC に直接送る", group: "家の PC", defaultOn: true,
                        get: { $0.homePC.watchDirect }, set: { $0.homePC.watchDirect = $1 }),
        S22SettingEntry(id: "homePCWatchRelay", label: "時計の音声を家の PC から受け取る", group: "家の PC", defaultOn: true,
                        get: { $0.homePC.watchRelay }, set: { $0.homePC.watchRelay = $1 }),
        S22SettingEntry(id: "speakerLabels", label: "話者の聞き分け", group: "文字", defaultOn: false,
                        get: { $0.speakerLabelsOn }, set: { $0.speakerLabelsOn = $1 }),
        S22SettingEntry(id: "correct", label: "誤変換を直す", group: "文字", defaultOn: true,
                        get: { $0.correctionOn }, set: { $0.correctionOn = $1 }),
        defaults(S21Watch.sleepChunksKey, "寝ている時間は区切りを5分に", "時計", true, after: { _ in S21Book.settingsChanged?() }),
        defaults(S21Watch.workoutGuardKey, "時計の強い守り（ワークアウト扱い）", "時計", false, after: { _ in S21Book.settingsChanged?() }),
        defaults(S22Watch.muffledOnKey, "袖でこもった音なら時計が震える", "時計", false, after: { _ in S21Book.settingsChanged?() }),
        S22SettingEntry(id: S22Watch.hourlyOnKey, label: "録り方の実験を 1 時間ごとに入れ替える（8 日）", group: "時計", defaultOn: false,
                        get: { _ in S22Book.hourlyOn }, set: { _, on in S22Book.setHourly(on) }),
        defaults(RecordingExperiment.onKey, "録り方の実験（1 日ずつ）", "時計", true, after: { _ in S21Book.settingsChanged?() }),
        defaults(S21Rules.routeOnKey, "直接送るの実験（4 日）", "時計", true, after: { $0.scheduleWatchPCSync() }),
        // 時計に 1 時間（仮）溜まり続けたら、時計が自分で送り直す（家の PC への外の道も試す。2026-11-24。s24 の 急6。初めはオン）
        defaults(S24Watch.rescueKey, "時計に溜まり続けたら時計が自分で送り直す", "時計", true, after: { _ in S21Book.settingsChanged?() }),
        defaults(S21Book.shakeKey, "振って「いまの画面が変」を送る", "知らせ", true),
        defaults(S22Notices.trainKey, "電車の中で「いま 3 問だけ」", "知らせ", true),
        defaults(S22Notices.whoKey, "会話が終わってすぐ「誰と話した？」", "知らせ", false),
        defaults(PromiseRules.onKey, "会話のあとに約束を知らせる", "知らせ", true),
        defaults(PromiseRules.hideKey, "通知に中身を出さない", "知らせ", false),
        defaults("morningCheck", "毎朝、前の日の点検を知らせる", "知らせ", true),
        defaults("secondOpinion", "もう1つの言語モデルでも見比べる", "文字", false),
        defaults(S22Device.readerKey, "iPad は読むだけ（iPad のときだけ効く）", "端末", S22Rules.readerDefault(isPad: S22Device.isPad)),
        // 今日は上の 3 枚だけ・入口は 5 つまで（2026-11-24。s24 の 形1・形5。初めはオン。切ると前の並び）
        defaults(S24Today.foldKey, "今日は上の 3 枚だけ（ほかは畳む）", "見た目", true),
        defaults(S24Entries.limitKey, "入口は 5 つまで（ほかは「ほか」に）", "見た目", true),
    ]
}

struct S22SettingsEntrySection: View {
    var body: some View {
        Section {
            NavigationLink {
                S22SettingsSearchView()
            } label: {
                Label("設定を探す・変えた所だけ・初めに戻す", systemImage: "magnifyingglass")
            }
        }
    }
}

struct S22SettingsSearchView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var query = ""
    @State private var changedOnly = false
    @State private var version = 0
    @State private var pending: (entry: S22SettingEntry, on: Bool)?
    @State private var resetAll = false

    var body: some View {
        let entries = S22SettingEntry.all.filter { entry in
            (query.isEmpty || entry.label.localizedCaseInsensitiveContains(query) || entry.group.contains(query))
                && (!changedOnly || entry.get(pipeline) != entry.defaultOn)
        }
        let changedCount = S22SettingEntry.all.filter { $0.get(pipeline) != $0.defaultOn }.count
        LLList {
            Section {
                Toggle("初めから変えた所だけ（\(changedCount)）", isOn: $changedOnly)
                if changedCount > 0 {
                    Button("全部初めに戻す", role: .destructive) { resetAll = true }
                }
            }
            Section {
                ForEach(entries) { entry in
                    let on = entry.get(pipeline)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(entry.label, isOn: Binding(get: { on }, set: { ask(entry, $0) }))
                        HStack {
                            Text(entry.group + "・初めは" + (entry.defaultOn ? "オン" : "オフ")).font(.caption2).foregroundStyle(LL.dim)
                            Spacer()
                            if on != entry.defaultOn {
                                Button("初めに戻す") { apply(entry, entry.defaultOn) }.font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }
                }
            } footer: {
                Text("ここに無い設定は「くわしい設定」から。電池と速さに効くスイッチは、変える前に見込み（仮）を出します。")
            }
        }
        .id(version)
        .searchable(text: $query, prompt: "設定の名前")
        .navigationTitle("設定を探す")
        .countsOpen("s22SettingsSearch")
        .confirmationDialog(pendingTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button(pending?.on == true ? "オンにする" : "オフにする") {
                if let pending { apply(pending.entry, pending.on) }
                pending = nil
            }
            Button("やめる", role: .cancel) { pending = nil }
        }
        .confirmationDialog("全部初めに戻しますか？", isPresented: $resetAll, titleVisibility: .visible) {
            Button("初めに戻す", role: .destructive) {
                for entry in S22SettingEntry.all where entry.get(pipeline) != entry.defaultOn { entry.set(pipeline, entry.defaultOn) }
                Tally.add("s22.settings.resetAll")
                version += 1
            }
            Button("やめる", role: .cancel) {}
        }
    }

    private var pendingTitle: String {
        guard let pending else { return "" }
        return pending.entry.label + "\n" + (S22Rules.switchImpact(pending.entry.id, turningOn: pending.on) ?? "")
    }

    /// 電池と速さに効くスイッチは見込みを出してから。ほかはそのまま
    private func ask(_ entry: S22SettingEntry, _ on: Bool) {
        if S22Rules.switchImpact(entry.id, turningOn: on) != nil {
            pending = (entry, on)
        } else {
            apply(entry, on)
        }
    }

    private func apply(_ entry: S22SettingEntry, _ on: Bool) {
        entry.set(pipeline, on)
        Tally.add("s22.settings.changed")
        Tally.add(S24Settings.tallyName(entry.id))  // よく触る設定を数える（2026-11-24。s24 の 形2）
        version += 1
    }
}

/// 楽9: 組を押す前の見込み（S21PresetSection の中に出す）
struct S22PresetForecastRows: View {
    var body: some View {
        let drain = S22Watch.drainPerHour(S22Book.watchBatterySamples(), now: .now)
        let minutes = S22Rules.talkToTextMinutes(totalMedian: Latency.summary()?.total, chunkTypical: ChunkCutter.current.typical)
        ForEach(S21Preset.allCases) { preset in
            Text(preset.label + " " + S22Rules.forecastLine(preset, drainPerHour: drain, latencyMinutes: minutes))
                .font(.caption2).foregroundStyle(LL.dim)
        }
    }
}

// MARK: - くわしい設定の s22 の分

struct S22WatchSettingsSection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(S22Watch.muffledOnKey) private var muffled = false
    @AppStorage(S22Notices.trainKey) private var train = true
    @AppStorage(S22Notices.whoKey) private var who = false
    @AppStorage(S22Device.readerKey) private var reader = S22Rules.readerDefault(isPad: S22Device.isPad)
    @State private var hourly = S22Book.hourlyOn

    var body: some View {
        Section {
            Toggle("録り方の実験を 1 時間ごとに入れ替える", isOn: $hourly)
                .onChange(of: hourly) { _, on in S22Book.setHourly(on) }
            LabeledContent("いま", value: S22Book.hourlyText())
            Toggle("袖でこもった音なら時計が震える", isOn: $muffled)
                .onChange(of: muffled) { _, _ in S21Book.settingsChanged?() }
            Toggle("電車の中で「いま 3 問だけ」", isOn: $train)
            Toggle("会話が終わってすぐ「誰と話した？」", isOn: $who)
            if S22Device.isPad { Toggle("iPad は読むだけ", isOn: $reader) }
        } header: {
            Text("実験と知らせ（s22）")
        } footer: {
            HelpNote("「1 時間ごとに入れ替える」（初めはオフ）: オンにした日から 8 日、32kbps・48kbps と 45 秒・300 秒の 4 組を 1 時間ごとに入れ替えます（同じ日の中で比べられるので、日による違いが混ざりません）。電池も時計が記録し、家の PC が組ごとに数えます。会議モードのあいだは会議モードの録り方です。\n「こもった音」（初めはオフ）: 高い音が急に消えた区切りが 2 つ続いたら、時計が 1 回震えます（1 時間に 1 回まで・見立て・仮）。\n「電車の中で 3 問」（初めはオン）: 電車の中の会話のあと、1 日 1 回、確かめ待ちを ○× のボタンつきで知らせます。\n「誰と話した？」（初めはオフ）: 名前の無い声と話した会話が終わってすぐ、1 日 3 回まで聞きます（名前・中身は知らせに出しません）。\n「iPad は読むだけ」（iPad は初めオン）: iPad では録音を始めず、同期でも自分の分を書きません（iPhone の記録を読むだけ）。")
        }
    }
}

// MARK: - 楽23 会話の 1 場面のカード

struct S22SceneTarget: Identifiable {
    let id = UUID()
    let conversation: ConversationLog.Conversation
    let around: Date
}

@MainActor
@Observable
final class S22Present {
    static let shared = S22Present()
    var card: S22SceneTarget?
    /// 「ここは、どこですか？」の通知を押したときの答える画面（2026-11-23。PlaceAskSheet.swift）
    var placeAsk: PlaceAskTarget?
}

extension View {
    /// アプリの根に付ける（場面のカードのシート）
    func s22Root(_ pipeline: Pipeline) -> some View { modifier(S22RootModifier(pipeline: pipeline)) }
}

private struct S22RootModifier: ViewModifier {
    let pipeline: Pipeline
    @State private var present = S22Present.shared

    func body(content: Content) -> some View {
        content.sheet(item: $present.card) { target in
            NavigationStack {
                S22SceneCardSheet(target: target) { present.card = nil }
            }
            .environment(pipeline)
            .llRoot()
        }
        .sheet(item: $present.placeAsk) { target in
            NavigationStack {
                PlaceAskSheet(target: target) { present.placeAsk = nil }
            }
            .environment(pipeline)
            .llRoot()
        }
    }
}

struct S22SceneCardSheet: View {
    @Environment(Pipeline.self) private var pipeline
    let target: S22SceneTarget
    let onClose: () -> Void
    /// 名前を伏せる（初めはオン）
    @AppStorage("s22.cardMask") private var mask = true
    @State private var image: Image?

    var body: some View {
        let lines = cardLines
        LLList {
            Section {
                Toggle("名前を伏せる", isOn: $mask)
                S22SceneCard(lines: lines, title: target.conversation.title, start: target.conversation.start)
                    .listRowInsets(EdgeInsets())
                if let image {
                    ShareLink(item: image, preview: SharePreview("会話の 1 場面", image: image)) {
                        Label("共有する", systemImage: "square.and.arrow.up")
                    }
                    .simultaneousGesture(TapGesture().onEnded { Tally.add("s22.sceneCard.share") })
                }
            } footer: {
                Text("絵にするのは、押した行の前後 6 行だけです。名前を伏せると、話した人は「A さん」「B さん」に、文の中の名前は「○○」になります。場所は入れません。")
            }
        }
        .navigationTitle("この場面をカードに")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる", action: onClose) } }
        .task(id: mask) { render(lines) }
    }

    private var cardLines: [S22Rules.CardLine] {
        let lines = target.conversation.lines.map { (speaker: $0.speaker, text: $0.text, time: $0.time, media: $0.media != nil) }
        return S22Rules.sceneLines(lines, around: target.around, selfName: SpeakerLabeler.selfName,
                                   names: pipeline.people.compactMap(\.name), mask: mask)
    }

    private func render(_ lines: [S22Rules.CardLine]) {
        let card = S22SceneCard(lines: lines, title: mask ? nil : target.conversation.title, start: target.conversation.start)
            .frame(width: 360)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let ui = renderer.uiImage { image = Image(uiImage: ui) }
    }
}

/// カードの絵の中身（ImageRenderer で絵にする）
struct S22SceneCard: View {
    let lines: [S22Rules.CardLine]
    let title: String?
    let start: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(LL.accent)
                Text(title ?? "会話の 1 場面").font(.headline).foregroundStyle(LL.text).lineLimit(1)
                Spacer()
                Text(start.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(LL.dim)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top) {
                    if line.isSelf { Spacer(minLength: 30) }
                    VStack(alignment: line.isSelf ? .trailing : .leading, spacing: 2) {
                        Text(line.who).font(.caption2).foregroundStyle(LL.dim)
                        Text(line.text).font(.callout).foregroundStyle(LL.text)
                            .padding(8)
                            .background((line.isSelf ? LL.accent : LL.surface).opacity(line.isSelf ? 0.25 : 1),
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !line.isSelf { Spacer(minLength: 30) }
                }
            }
            Text("LifeLog").font(.caption2).foregroundStyle(LL.dim).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .background(LL.bg)
    }
}

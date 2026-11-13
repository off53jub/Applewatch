import SwiftUI

/// 画面の下の5つのタブ（2026-11-12 に組み替え）。「何をしに開いたか」でタブを分ける。
/// 今日（録る・今を見る）｜タスク（やること）｜直す（記録を正しくする答え）｜記録（探す・読む。日ごと・人・場所・お金）｜ふり返り（自分をふり返る）。
/// 設定と点検は、どのタブでも右上の歯車から開く。前は 今日・タスク・ライブ・記録・人と場所 で、ライブは「今日」のボタンにした。
struct ContentView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage("taskBadgeLateOnly") private var badgeLateOnly = false
    /// 声の見直しの数（記録をひととおり見るので、声のひとこまが変わったときだけ数え直す）
    @State private var reviewCount = 0

    /// 今日までのもの・過ぎたもの（待っているものは除く）
    private var lateTasks: Int {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86400)
        // 家の PC のやることも、アプリのタスクと重ならないものだけ1回数える（2026-11-10。1つの一覧にした）
        let home = pipeline.mothership.extra(.all, tasks: pipeline.tasks.items)
            .filter { (MothershipExport.dueDate($0.due) ?? .distantFuture) < end }.count
        return pipeline.tasks.todo.filter { ($0.due ?? .distantFuture) < end }.count + home
    }

    var body: some View {
        @Bindable var pipeline = pipeline
        let fixCount = pipeline.fixParts(reviewCount: reviewCount).reduce(0) { $0 + $1.count }
        TabView(selection: $pipeline.tab) {
            Tab("今日", systemImage: "waveform", value: AppTab.today) { TodayView() }
            Tab("タスク", systemImage: "checklist", value: AppTab.tasks) { TasksTab() }
                .badge((badgeLateOnly ? 0 : pipeline.tasks.candidates.count) + lateTasks)
            Tab("直す", systemImage: "tray.full", value: AppTab.fix) { FixTab() }
                .badge(fixCount)
            Tab("記録", systemImage: "books.vertical", value: AppTab.records) { RecordsView() }
            Tab("ふり返り", systemImage: "sparkles", value: AppTab.lookBack) { LookBackTab() }
        }
        .task(id: pipeline.people.flatMap(\.samples)) { reviewCount = pipeline.voiceReview().count }
        // 知らせ・ショートカット・ウィジェットから開く画面（2026-11-10。NoticeActions.swift）。タブの切り替えはシートにしない
        .sheet(item: Binding(get: { pipeline.noticeRoute }, set: { pipeline.noticeRoute = $0 })) { route in
            NavigationStack {
                Group {
                    switch route {
                    case .tab:
                        EmptyView()
                    case .digestImport(let text):
                        WorkDigestImportView(initialText: text)
                    case .screen(let screen):
                        NoticeScreenView(screen: screen)
                    case .note(let title, let body):
                        NoticeNoteView(title: title, text: body)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { pipeline.noticeRoute = nil } }
                }
            }
        }
        .onAppear {
            if let text = DigestInbox.take() { pipeline.noticeRoute = .digestImport(text) }
        }
    }
}

/// 知らせから開く画面（シートの中身）
private struct NoticeScreenView: View {
    let screen: NoticeScreen

    var body: some View {
        switch screen {
        case .questions: QuestionsView()
        case .goodThings: GoodThingsView()
        case .money: MoneyView()
        case .cloudLog: CloudLogView()
        case .reviewNudge: ReviewNudgeView()
        case .diagnostics: DiagnosticsView()
        case .homePC: HomePCView()
        case .proposals: ProposalsView()
        }
    }
}

/// 知らせの文を読み直す（会う前の1枚。2026-11-12）
private struct NoticeNoteView: View {
    @Environment(Pipeline.self) private var pipeline
    let title: String
    let text: String

    var body: some View {
        List {
            Section {
                Text(text).textSelection(.enabled)
            } header: {
                Text(title)
            } footer: {
                Text("知らせで届いた文です。頼まれごと・約束はタスクで片づけられます。")
            }
            Section {
                Button("タスクを開く", systemImage: "checklist") {
                    pipeline.noticeRoute = nil
                    pipeline.tab = .tasks
                }
            }
        }
        .navigationTitle("会う前の1枚")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - どのタブにも置く歯車

/// 右上の歯車で設定（点検と設定）を開く（2026-11-12。前は「今日」と「記録」にだけあった）
struct SettingsGear: ViewModifier {
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("設定", systemImage: "gearshape") { show = true }
                }
            }
            .sheet(isPresented: $show) {
                SettingsView { show = false }
            }
    }
}

extension View {
    func settingsGear() -> some View { modifier(SettingsGear()) }
}

/// 長い説明は畳んでおき、押したときだけ出す（2026-11-12。設定と「今日」の説明が長すぎて、中身が下に押し出されていた）
struct HelpNote: View {
    let text: String
    @State private var open = false

    init(_ text: String) { self.text = text }

    var body: some View {
        if open {
            Text(text)
        } else {
            Button {
                withAnimation { open = true }
            } label: {
                Label("説明を読む", systemImage: "info.circle")
            }
            .font(.footnote)
        }
    }
}

// MARK: - 今日

private struct TodayView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var showLive = false
    @State private var showHelp = false
    /// 「いまの様子」を開いているか（いつもは畳む）
    @AppStorage("todayStatusOpen") private var statusOpen = false

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let today = Self.dayFormatter.string(from: .now)
        // 最近の発言が変わる（書き足される）たびに読み直す
        let talks = pipeline.conversations(on: today)
        NavigationStack {
            List {
                recordSection()
                // 困ったことがあるときだけ、上に出す
                alerts()
                PCFeatureNotice()
                // 朝の「昨日と今日」（2026-11-09。MorningBrief.swift）
                MorningBriefSection()
                // 家の PC（母艦）からの提案を3つまで（2026-11-13。HomeFeeds.swift）。押すまでは何も変えない
                ProposalCardsSection()
                taskBook()
                talkSection(today: today, talks: talks)
                // 家の PC が書いている途中の下書き（仮。記録には入れない。2026-11-07。Drafts.swift）
                DraftSection()
                if !pipeline.lastLines.isEmpty {
                    Section("最近の発言") {
                        ForEach(Array(pipeline.lastLines.suffix(8).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                    }
                }
                statusSection()
            }
            .navigationTitle("今日")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("使い方", systemImage: "questionmark.circle") { showHelp = true }
                }
            }
            .settingsGear()
            .sheet(isPresented: $showHelp) { TodayHelpView { showHelp = false } }
            .fullScreenCover(isPresented: $showLive) { LiveView { showLive = false } }
        }
    }

    /// 録る・印・会議・ライブ字幕
    private func recordSection() -> some View {
        Section {
            Button {
                Task { await pipeline.toggleRecording() }
            } label: {
                Label(pipeline.isRecording ? "iPhone の録音を止める" : "iPhone で録音を始める",
                      systemImage: pipeline.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
            }
            .tint(pipeline.isRecording ? .red : .accentColor)
            Button {
                pipeline.addMark()
            } label: {
                Label("今のところに印を付ける", systemImage: "star")
            }
            if let mark = pipeline.lastMark {
                Text("\(mark.formatted(date: .omitted, time: .shortened)) に印を付けました（前後1分の行に★）")
                    .foregroundStyle(.secondary)
            }
            MeetingButton()
            // ライブ字幕（2026-11-12。前は1つのタブだった）
            Button {
                showLive = true
            } label: {
                LabeledContent {
                    Text(pipeline.liveOn ? "オン" : "")
                } label: {
                    Label("ライブ字幕", systemImage: "captions.bubble")
                }
            }
        }
    }

    /// 困ったこと（署名の期限・録音を休む場所・止まっているかも・ログインしていない）。無ければ何も出さない
    @ViewBuilder
    private func alerts() -> some View {
        let sign: String? = Provisioning.isNear() ? Provisioning.expiryText() : nil
        // 止まっているかも（2026-11-12。AppFeeds.swift）。家の PC が対応しているときだけ
        let stale: [FreshItem] = pipeline.homePC.features.contains("fresh") ? pipeline.appFeeds.staleItems : []
        let held = pipeline.recordingHeld
        let noLogin = pipeline.email == nil
        if sign != nil || held || !stale.isEmpty || noLogin {
            Section("気をつけること") {
                if let sign {
                    // 無料の署名は7日で切れ、切れるとアプリが起動しなくなって録音が止まる
                    Label("署名の期限 \(sign)。切れる前に Sideloadly で入れ直してください（記録は消えません）",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if held {
                    Label("録音を休む場所にいるので、書くのを休んでいます", systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }
                ForEach(stale) { item in
                    Label(AppFeeds.freshLine(item), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if noLogin {
                    Text("右上の歯車（設定）で Google にログインすると、ドキュメントに書き始めます。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// タスクの入口。期限の近いものを3つまで出す（押すと「タスク」タブへ）
    private func taskBook() -> some View {
        let book = pipeline.tasks
        let open = book.open
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86400)
        let late = open.filter { ($0.due ?? .distantFuture) < end }.count
        var summary = "まだ \(open.count) 件"
        if late > 0 { summary += "・今日まで \(late)" }
        if !book.candidates.isEmpty { summary += "・確かめ待ち \(book.candidates.count)" }
        return Section {
            Button {
                pipeline.tab = .tasks
            } label: {
                LabeledContent {
                    Text(summary)
                } label: {
                    Label("タスク", systemImage: "checklist")
                }
            }
            ForEach(open.prefix(3)) { item in
                HStack {
                    Text(item.what).font(.callout).lineLimit(2)
                    Spacer(minLength: 8)
                    if let due = item.due {
                        let text = Pipeline.taskDueText(due)
                        Text(text).font(.caption)
                            .foregroundStyle(text.hasSuffix("過ぎ") || text == "今日まで" ? Color.red : Color.secondary)
                    }
                }
            }
        }
    }

    private func talkSection(today: String, talks: [ConversationLog.Conversation]) -> some View {
        Section("今日の会話") {
            if talks.isEmpty {
                Text("まだありません。録音すると、話の切れ目ごとにここに出ます。").foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    DayView(day: today)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(talks.suffix(8).reversed().enumerated()), id: \.offset) { _, c in
                            Text(ConversationLog.headingText(c))
                                .font(.callout)
                                .lineLimit(2)
                        }
                        if talks.count > 8 {
                            Text("ほか \(talks.count - 8) 件").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// いまの様子（時計・マイク・待ち・抜け）。いつもは畳んでおく
    private func statusSection() -> some View {
        Section {
            DisclosureGroup(isExpanded: $statusOpen) {
                LabeledContent("時計", value: pipeline.watchStatusNow)
                // iPhone で録っているマイク（外付けのマイクをつないだとき。2026-11-07。MicInput.swift）
                if pipeline.isRecording {
                    LabeledContent("iPhone のマイク", value: MicRoute.shared.text)
                }
                if let last = pipeline.watchDelays.entries.last {
                    NavigationLink {
                        WatchDelayView()
                    } label: {
                        LabeledContent("時計の遅れ", value: "直近 " + WatchDelayLog.text(last.arrival))
                    }
                }
                LabeledContent("文字起こし待ち", value: "\(pipeline.pendingCount) 件")
                NavigationLink {
                    RecordingMapView()
                } label: {
                    let gaps = pipeline.ledger.map(for: Calendar.current.startOfDay(for: .now)).gaps
                    LabeledContent("録音の抜け（今日）", value: gaps.isEmpty ? "なし" : "\(gaps.reduce(0) { $0 + $1.minutes })分")
                }
                if !pipeline.lastEngine.isEmpty {
                    LabeledContent("直近の文字起こし", value: pipeline.lastEngine)
                }
                if !pipeline.message.isEmpty {
                    Text(pipeline.message).foregroundStyle(.secondary)
                }
            } label: {
                LabeledContent("いまの様子", value: "時計 \(pipeline.watchStatusNow)・待ち \(pipeline.pendingCount)")
            }
        }
    }
}

/// 「今日」の使い方（前は画面の途中に長い説明として出していたもの）
private struct TodayHelpView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("下のタブ") {
                    Text("今日: 録る・印を付ける・今日の会話。困ったことがあるときだけ「気をつけること」が上に出ます。")
                    Text("タスク: やること。上の「仕事のまとめ」から職場の Claude の答えを取り込めます。")
                    Text("直す: AI からの質問・名前を付ける声・聞き間違いなど、答えると記録が正しくなるもの。タブの数字がたまっている数です。")
                    Text("記録: 言葉や名前で探す・日ごとに読む。上の切り替えで、人・場所・お金も見られます。")
                    Text("ふり返り: いいこと帳・話し方・週のまとめ・タスクの数。")
                    Text("設定と点検は、どのタブでも右上の歯車から開きます。")
                }
                Section("印と会議モード") {
                    Text("時計で録音中は、時計の「★ 印」ボタン（またはダブルタップ）でも印を付けられます。会議モードは時計の「会議」ボタンでも始められます（予定の参加者と題名を聞き取りのヒントにし、時計の音質を上げ、終わったらすぐ議事録にします）。")
                }
                Section("ライブ字幕") {
                    Text("オンにしている間だけ、iPhone のマイクの声を話の切れ目ごとに iPhone 内の Haas-ja で文字にして流します（モデルを入れていなければ Groq）。字幕は仮で、記録にはいつも通り区切りごとの文字起こしが書かれます。アプリを閉じて10分たつと自動でオフになります。")
                }
                Section("直す") {
                    Text("1日に上から5つまでで十分です（5分ほど）。残りは明日に回して大丈夫です。直すほど、聞き分けと聞き取りが正確になります。")
                }
            }
            .navigationTitle("使い方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
            }
        }
    }
}

// MARK: - ライブ字幕（「今日」のボタンから全画面で開く）

private struct LiveView: View {
    @Environment(Pipeline.self) private var pipeline
    let onClose: () -> Void
    @State private var visible = false

    var body: some View {
        let live = pipeline.live
        NavigationStack {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { pipeline.liveOn },
                    set: { on in Task { await pipeline.setLive(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ライブ字幕").font(.headline)
                        Text(statusText(live)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(live.lines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(line.time.formatted(date: .omitted, time: .shortened))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    // ライブの文は仮（2026-11-06）。タスク・要約・記録には使わず、記録には多数決のあとの確定した文が入る
                                    Text("仮").font(.caption2).padding(.horizontal, 4)
                                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                    Text(line.text).font(.title3).foregroundStyle(.primary.opacity(0.8))
                                }
                                .id(line.id)
                            }
                        }
                        .padding()
                    }
                    .overlay {
                        if live.lines.isEmpty {
                            ContentUnavailableView(
                                "ライブ字幕", systemImage: "captions.bubble",
                                description: Text("オンにしている間だけ、iPhone のマイクの声を話の切れ目ごとに iPhone 内の Haas-ja で文字にして、ここに流します（モデルを入れていなければ Groq）。記録にはいつも通り区切りごとの文字起こしが書かれます。アプリを閉じて10分たつと自動でオフになります。"))
                        }
                    }
                    .onChange(of: live.lines.count) {
                        if let last = live.lines.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("ライブ字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる", action: onClose) }
                if !live.lines.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("消す", systemImage: "trash") { live.clear() }
                    }
                }
            }
        }
        // ライブを見ている間は画面を消さない
        .onAppear { visible = true; keepAwake() }
        .onDisappear { visible = false; keepAwake() }
        .onChange(of: pipeline.liveOn) { keepAwake() }
    }

    private func statusText(_ live: LiveTranscriber) -> String {
        guard pipeline.liveOn else { return "オフ" }
        if !live.status.isEmpty { return live.status }
        if live.waiting > 0 { return "文字にしています…" }
        return live.hearing ? "聞いています…" : "声を待っています"
    }

    private func keepAwake() {
        UIApplication.shared.isIdleTimerDisabled = visible && pipeline.liveOn
    }
}

// MARK: - 記録

/// 探す・読む。上の切り替えで 日ごと｜人｜場所｜お金（2026-11-12。前の「人と場所」タブと、行ったお店の奥の支払いをここにまとめた）
private struct RecordsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case days = "日ごと", people = "人", places = "場所", money = "お金"
        var id: String { rawValue }
    }

    /// 最後に見ていた切り替えを覚える
    @AppStorage("recordsPage") private var page = Page.days

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case .days: DaysPage()
                case .people: PeoplePage()
                case .places: PlacesPage()
                case .money: MoneyView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("見る", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .settingsGear()
        }
    }
}

/// 日ごと（と、言葉や名前で探す）
private struct DaysPage: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var days: [String] = []
    @State private var query = ""
    @State private var hits: [Pipeline.Hit] = []
    /// 意味で探す（家の PC の索引。2026-11-07。前は入口の無い「記録を探す」の画面にあった）
    @AppStorage("searchByMeaning") private var byMeaning = false
    @State private var searching = false

    private var meaningOn: Bool { byMeaning && pipeline.homePC.features.contains("semantic") }

    var body: some View {
        List {
            if query.count >= 2 {
                if pipeline.homePC.features.contains("semantic") {
                    Toggle("意味で探す（家の PC。検索を押したとき）", isOn: $byMeaning)
                }
                if searching { ProgressView() }
                // タスクも探す（2026-11-06）
                let tasks = pipeline.tasks.items.filter { item in
                    item.what.localizedCaseInsensitiveContains(query)
                        || (item.quote ?? "").localizedCaseInsensitiveContains(query)
                        || (item.from ?? "").localizedCaseInsensitiveContains(query)
                }
                if !tasks.isEmpty {
                    Section("タスク") {
                        ForEach(tasks.prefix(10)) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.what)
                                Text([item.from, item.due.map { Pipeline.taskDueText($0) }, item.state == .done ? "済み" : nil]
                                    .compactMap { $0 }.joined(separator: "・"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                // 仕事のまとめも探す（2026-11-10。行を探すだけで、言語モデルは使わない）
                let digests: [Pipeline.DigestHit] = Pipeline.searchWorkDigests(query, in: pipeline.workDigests.sorted, limit: 10)
                if !digests.isEmpty {
                    Section("仕事のまとめ") {
                        ForEach(digests) { DigestHitRow(hit: $0) }
                    }
                }
                if hits.isEmpty && tasks.isEmpty && digests.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(hits) { HitRow(hit: $0) }
                }
            } else {
                Section {
                    NavigationLink {
                        AskView()
                    } label: {
                        Label("記録に質問する", systemImage: "questionmark.bubble")
                    }
                }
                Section("日ごと") {
                    if days.isEmpty {
                        Text("文字起こしが終わると、ここに日ごとに出てきます。").foregroundStyle(.secondary)
                    }
                    ForEach(days, id: \.self) { day in
                        NavigationLink(day) { DayView(day: day) }
                    }
                }
                // アプリの記録が無く、PLAUD の写しだけがある日（2026-11-13。HomeFeeds.swift。読むだけ）
                let plaudOnly = pipeline.homeFeeds.fillOnlyDays(recorded: days)
                if !plaudOnly.isEmpty {
                    Section {
                        ForEach(plaudOnly, id: \.self) { day in
                            NavigationLink(day) { PlaudOnlyDayView(day: day) }
                        }
                    } header: {
                        Text("PLAUD だけの日")
                    } footer: {
                        Text("アプリの記録が無い日の、PLAUD の文字起こしです（読むだけ）。")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "言葉や名前で探す")
        .onSubmit(of: .search) { run() }
        .onChange(of: query) {
            if query.count < 2 { hits = [] } else if !meaningOn { hits = pipeline.search(query) }
        }
        .onChange(of: byMeaning) { if query.count >= 2 { run() } }
        .navigationTitle("記録")
        .onAppear { days = pipeline.recordedDays() }
        .refreshable { days = pipeline.recordedDays() }
        // ほかの端末から記録が届いたら出し直す
        .onChange(of: pipeline.recordsVersion) { days = pipeline.recordedDays() }
    }

    /// 探す。意味で探すときは、検索を押したときと切り替えたときだけ家の PC に聞く
    private func run() {
        guard query.count >= 2 else { return }
        guard meaningOn else {
            hits = pipeline.search(query)
            return
        }
        let asked = query
        searching = true
        Task {
            let found = await pipeline.semanticSearch(asked)
            searching = false
            guard asked == query else { return }
            hits = found
        }
    }
}

/// 人（話した相手。聞き分けが切なら、入れる所だけ）
private struct PeoplePage: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        if pipeline.speakerLabelsOn {
            PeopleView()
        } else {
            List {
                Section {
                    Toggle("話している人を聞き分ける", isOn: Binding(
                        get: { pipeline.speakerLabelsOn },
                        set: { pipeline.speakerLabelsOn = $0 }))
                } footer: {
                    Text("オンにすると、記録の行に「[自分]」「[人物1]」などを付け、ここに話した相手が並びます（iPhone の中だけで比べます）。")
                }
            }
            .navigationTitle("人")
        }
    }
}

/// 場所（登録した場所・行ったお店）
private struct PlacesPage: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let week = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        List {
            Section {
                if pipeline.places.isOn {
                    NavigationLink {
                        PlacesView()
                    } label: {
                        LabeledContent("登録した場所", value: "\(pipeline.places.places.count) か所")
                    }
                } else {
                    Toggle("場所を記録する", isOn: Binding(
                        get: { pipeline.places.isOn },
                        set: { pipeline.places.isOn = $0 }))
                }
            } footer: {
                Text("職場にした場所では、職場の人の声と職場の言葉で照らし合わせます。")
            }
            Section {
                // 行ったお店（2026-11-08。ShopVisitViews.swift）
                NavigationLink {
                    ShopVisitsView()
                } label: {
                    let n = pipeline.shopVisits.visits.filter { $0.arrival >= week }.count
                    LabeledContent("行ったお店", value: pipeline.shopVisits.isOn ? "この7日で \(n) 件" : "オフ")
                }
            } footer: {
                Text("お店で払ったものは、上の「お金」に並びます。")
            }
        }
        .navigationTitle("場所")
    }
}

// MARK: - 設定

/// 歯車から開く。上の切り替えで「点検」（毎日見る・調子を確かめる）と「設定」（ふだん触らない）に分ける（2026-11-12。前は1本の長い一覧）
private struct SettingsView: View {
    enum Part: String, CaseIterable, Identifiable {
        case check = "点検", setup = "設定"
        var id: String { rawValue }
    }

    @Environment(Pipeline.self) private var pipeline
    /// 最後に開いた方を覚える
    @AppStorage("settingsPart") private var part = Part.check
    private let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }
    @AppStorage(AppLock.key) private var appLock = false
    @AppStorage("morningCheck") private var morningCheck = true
    @State private var exportNote: String?
    @AppStorage(Storage.japanTimeKey) private var japanTime = false
    @AppStorage("secondOpinion") private var secondOpinion = false
    @AppStorage(Summarizer.pcLLMKey) private var pcLLMForWork = false
    /// LocalModel.modeKey と同じ名前
    @AppStorage("localModelMode") private var localModelMode = LocalModel.Mode.fallback.rawValue
    @AppStorage(Pipeline.autoAsideKey) private var autoAside = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("見る", selection: $part) {
                        ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                if part == .check {
                    checkPage()
                } else {
                    setupPage(pipeline.settings)
                }
            }
            .navigationTitle(part == .check ? "点検" : "設定")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
                }
            }
        }
    }

    /// 点検（毎日見るもの・調子が悪いとき）
    @ViewBuilder
    private func checkPage() -> some View {
        Section {
            NavigationLink("自己点検（実機で動いたか・画面を開いた回数も）") { DiagnosticsView() }
            NavigationLink("聞き取りの成績") { ListenQualityView() }
            NavigationLink("録音の抜けと数の照合") { RecordingMapView() }
            if !pipeline.watchDelays.entries.isEmpty {
                NavigationLink("時計の遅れ") { WatchDelayView() }
            }
            NavigationLink("クラウドに送ったもの") { CloudLogView() }
        } header: {
            Text("調子")
        } footer: {
            Text("調子が悪いときは「自己点検」から。")
        }
        // 実機でまだ確かめていない新しい動き（2026-11-10。Checklist.swift。前は「今日」に出していた）
        ChecklistSection()
        Section {
            NavigationLink("登録の控え") { BackupView() }
            NavigationLink("記録の掃除") { CleanupView() }
            Button("今年の分を書き出す") {
                exportNote = "書き出しています…"
                Task {
                    do {
                        let names = try await pipeline.exportYear(Calendar.current.component(.year, from: .now))
                        exportNote = "ドライブの「控え」に置きました: " + names.joined(separator: "、")
                    } catch {
                        exportNote = "書き出せませんでした: \(error.localizedDescription)"
                    }
                }
            }
            .disabled(pipeline.email == nil)
            if let exportNote { Text(exportNote).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("控えと掃除")
        } footer: {
            HelpNote("人・声・言葉の登録は毎日「登録の控え」に残しています。書き出しは、その年の会話・人・タスクを Markdown（読む用）と JSON（プログラム用・中身の説明つき）にします。年が変わると前の年の分を自動で書き出します。")
        }
    }

    /// 設定（ふだん触らないもの）
    @ViewBuilder
    private func setupPage(_ source: TranscriptionSettings) -> some View {
        @Bindable var settings = source
                // 守り（2026-11-06）
                Section {
                    Toggle("開くときに Face ID", isOn: $appLock)
                    Toggle("毎朝、前の日の点検を知らせる", isOn: $morningCheck)
                    // 朝の「昨日と今日」の知らせと時刻（2026-11-09。前の「朝の読み上げ」。MorningBrief.swift）
                    MorningBriefSettingsRows()
                    Toggle("もう1つの言語モデルでも見比べる（充電中か開いているとき）", isOn: $secondOpinion)
                    // 2026-11-06
                    Toggle("職場の会話は、家の PC の言語モデルで作る（PC に Ollama があるとき）", isOn: $pcLLMForWork)
                    NavigationLink("有料の票（ElevenLabs）") { PaidVoteView() }
                    Toggle("日付と時刻を日本時間で（海外にいるとき）", isOn: $japanTime)
                    if japanTime != Storage.japanTimeApplied {
                        Text("アプリを一度終えて開き直すと変わります。").font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("守り")
                } footer: {
                    Text("Face ID をオンにすると、アプリが前に出るたびに確かめるまで記録を隠します（録音と文字起こしは続きます）。")
                }

                Section("Google ドライブ") {
                    if let email = pipeline.email {
                        LabeledContent("ログイン中", value: email)
                        Button("ログアウト", role: .destructive) { pipeline.signOut() }
                    } else {
                        Button("Google でログイン") { Task { await pipeline.signIn() } }
                    }
                }

                Section {
                    Toggle("iPhone と iPad で同じ記録にする", isOn: Binding(
                        get: { pipeline.sync.isOn },
                        set: { pipeline.sync.isOn = $0 }))
                    if pipeline.sync.isOn {
                        LabeledContent("最後に合わせた時刻",
                                       value: pipeline.sync.lastSynced?.formatted(date: .abbreviated, time: .shortened) ?? "まだ")
                        if !pipeline.sync.lastReceived.isEmpty {
                            LabeledContent("前回ほかの端末から届いたもの", value: pipeline.sync.lastReceived)
                        }
                        Button(pipeline.sync.running ? "合わせています…" : "今すぐ合わせる") {
                            Task { await pipeline.syncNow() }
                        }
                        .disabled(pipeline.sync.running || pipeline.email == nil)
                        if let problem = pipeline.sync.problem {
                            Text(problem).font(.footnote).foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("iPhone と iPad の同期")
                } footer: {
                    HelpNote("同じ Google アカウントでログインした iPhone と iPad で、記録・話した相手（名前と登録した声）・言葉の登録・場所を、ドライブの「LifeLog/同期」フォルダを通して合わせます。アプリを開いたときと、文字起こしのあと（3分おきまで）に合わせます。\n「ここでは録音を休む」と、自動で覚えた声は端末ごとのままです。1日のまとめ・人物ノート・週のまとめ・AI 向けの索引は、iPhone が両方の分をまとめて書きます。\n初めて合わせる前に、今の記録と登録をアプリの中に一度だけ控えておきます。")
                }

                Section {
                    Toggle("待機モード", isOn: Binding(
                        get: { pipeline.standbyOn },
                        set: { pipeline.standbyOn = $0 }))
                    Toggle("録音が止まったら知らせる", isOn: Binding(
                        get: { pipeline.stopAlertsOn },
                        set: { pipeline.stopAlertsOn = $0 }))
                    Toggle("音がしないあいだは書かない", isOn: Binding(
                        get: { pipeline.skipSilence },
                        set: { pipeline.skipSilence = $0 }))
                    Picker("区切りの長さ", selection: Binding(
                        get: { pipeline.chunkLength },
                        set: { pipeline.chunkLength = $0 })) {
                        ForEach(ChunkCutter.Length.allCases, id: \.self) { length in
                            Text(length.label).tag(length)
                        }
                    }
                    // 時計の電池が少ないあいだは、自動で5分の区切りにする（2026-11-07）
                    if pipeline.chunkLength == .short {
                        Toggle("電池が少ないときは5分に", isOn: Binding(
                            get: { pipeline.chunkBatterySaver },
                            set: { pipeline.chunkBatterySaver = $0 }))
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pipeline.standbyOn
                             ? "時計が録音しているあいだだけ無音を流してアプリを起こしておき、時計の録音を区切りごとにすぐ文字起こしします。電池を少し多く使います。"
                             : "時計の録音は、アプリを開いたときや充電中にまとめて文字起こしします。")
                        HelpNote("「音がしないあいだは書かない」をオンにすると、時計と iPhone で1分続けて静かなときは録音ファイルに書かず、音がしたらその1秒前から書き始めます（マイクは聞き続けます）。無音を送ったり文字にしたりしないぶん、電池が長持ちします。\n「区切りの長さ」は、録音を区切って送る長さです。短め（初め）は45秒を過ぎた話の切れ目で区切り、長くても2分で区切るので、文字になるまでが早くなります。ふつうは今までどおり5分ほどで区切ります（送る回数が少ないぶん、時計の電池が少し長持ちします）。どちらも次の区切りから変わります。\n「電池が少ないときは5分に」をオンにすると（初めはオン）、時計の電池が 30% より少ないときと低電力モードのあいだは、短めの設定でも時計が自動で5分ごとに区切ります。電池が 35% まで戻るか充電を始めると、短めに戻ります。いま5分にしているかは、時計の画面と自己点検に出ます。時計の設定は、時計と iPhone がつながったときに伝わります。")
                    }
                }

                // 外付けマイク（2026-11-07。MicViews.swift）
                MicSettingsSection()

                // 会話の横に、その時間に撮った写真を出す（2026-11-07。DayPhotos.swift）
                DayPhotoSettingsSection()

                Section {
                    NavigationLink {
                        HomePCView()
                    } label: {
                        LabeledContent("家の PC（多数決）", value: pipeline.homePC.isConfigured ? "使用中" : "オフ")
                    }
                    NavigationLink {
                        HaasView()
                    } label: {
                        LabeledContent("iPhone 内の Haas-ja", value: pipeline.haas.isUsable ? "使用中" : "オフ")
                    }
                    Toggle("高精度で文字起こし", isOn: $settings.useCloud)
                        .disabled(!settings.hasAPIKey)
                    Toggle("誤変換を言語モデルで直す", isOn: Binding(
                        get: { pipeline.correctionOn },
                        set: { pipeline.correctionOn = $0 }))
                        .disabled(pipeline.llmKey == nil)
                    NavigationLink("サービスと API キーの設定") {
                        TranscriptionSettingsView(settings: settings)
                    }
                } header: {
                    Text("文字起こし")
                } footer: {
                    if !settings.hasAPIKey {
                        Text("API キーを登録すると、クラウドの高精度モデルで文字起こしできます（Groq なら無料）。")
                    } else if settings.useCloud && !settings.isUnderLimit {
                        Text("今月の上限に達したので、端末内の文字起こしに戻っています。")
                    } else if settings.provider.dollarsPerMinute > 0 {
                        Text("\(settings.provider.name)・今月 \(settings.usedMinutesThisMonth) 分 / 上限 \(settings.monthlyLimitMinutes) 分")
                    } else {
                        Text(settings.provider.name)
                    }
                }

                Section {
                    Toggle("話している人を聞き分ける", isOn: Binding(
                        get: { pipeline.speakerLabelsOn },
                        set: { pipeline.speakerLabelsOn = $0 }))
                    if pipeline.speakerLabelsOn {
                        Picker("聞き分けの厳しさ", selection: Binding(
                            get: { pipeline.speakerStrictness },
                            set: { pipeline.speakerStrictness = $0 })) {
                            ForEach(SpeakerLabeler.Strictness.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle("食い違った声を自動で外す", isOn: $autoAside)
                    }
                } header: {
                    Text("話者")
                } footer: {
                    HelpNote("iPhone の中だけで声の特徴を比べ、行に「[自分]」「[人物1]」などを付けます（無料）。別の人が同じ名前になるときは「厳しめ」、同じ人が何人にも分かれるときは「ゆるめ」にしてください。「食い違った声を自動で外す」は、覚えた声のひとこまが記録ではほかの人やテレビの行だったとき、見直しを待たずに聞き分けに使わないようにします（消さずに、人の画面から戻せます）。")
                }

                Section {
                    Toggle("会話ごとの見出しと1日のまとめ", isOn: Binding(
                        get: { pipeline.summariesOn },
                        set: { pipeline.summariesOn = $0 }))
                        .disabled(pipeline.llmKey == nil)
                    Toggle("場所を記録する", isOn: Binding(
                        get: { pipeline.places.isOn },
                        set: { pipeline.places.isOn = $0 }))
                } header: {
                    Text("会話のまとめ")
                } footer: {
                    HelpNote("話が3分途切れるごとに、ドキュメントに「時刻・場所・相手・内容」の見出しと要点を付け、日が変わると前の日の先頭に「1日のまとめ」を入れます（家の PC 経由の Claude。使えないときは Groq の無料枠か、iPhone の中の言語モデル）。家の PC が作った1日のまとめ（会話・LINE・メモをまとめたもの）が届いた日は、そちらを先頭に載せます（1日に1回・iPhone だけ。アプリのまとめは週と月のまとめに使います）。")
                }

                Section {
                    Picker("iPhone の中の言語モデル", selection: $localModelMode) {
                        ForEach(LocalModel.Mode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    LabeledContent("この iPhone", value: LocalModel.status.text)
                } header: {
                    Text("言語モデル")
                } footer: {
                    HelpNote("見出し・要点・まとめ・誤変換直し・聞き間違い探し・記録への質問は、まず家の PC を通して Claude に頼みます（下の「Claude（家の PC 経由）」。数の多い仕事は軽いモデル、まとめ・議事録・質問の答えは標準のモデル）。Claude に頼めないとき（PC につながらない・今月の上限・鍵が無い）は、今までどおり Groq、Apple の iPhone の中の言語モデル（Apple Intelligence）、家の PC の言語モデルで作ります。iPhone の中のモデルは無料で上限が無く、中身を外に送りません。Groq の大きいモデルより賢くなく、長い会話は頭と終わりだけを読むことがあります。「Groq が使えないときだけ」は、キーが無い・無料枠を使い切った・混んでいる・通信できないときの代わり。「職場の会話は端末内で」は、職場にいた時間の会話を Groq に送りません（「職場の会話も Claude で」がオンのあいだは、職場の会話も先に Claude に頼みます）。「いつも端末内で」は、Claude にも Groq にも送りません。")
                }

                // Claude（家の PC 経由。2026-11-13。Claude.swift）
                ClaudeSettingsSection()

                Section {
                    Toggle("音声をドライブにも保存", isOn: Binding(
                        get: { pipeline.audioBackupOn },
                        set: { pipeline.audioBackupOn = $0 }))
                    if pipeline.audioBackupOn && pipeline.backupPending > 0 {
                        LabeledContent("ドライブに上げる前", value: "\(pipeline.backupPending) 件")
                    }
                    NavigationLink("周りの声と雑音") { NoiseSettingsView() }
                    NavigationLink("車の Bluetooth の機器") { CarDevicesView() }
                    NavigationLink("夜の聞き直し") { NightlyView() }
                    NavigationLink("ほかのアプリの音声を取り込む") { ImportView() }
                } header: {
                    Text("音声")
                } footer: {
                    Text(pipeline.audioBackupOn
                         ? "音声は Wi-Fi のときにドライブの「LifeLog/音声」に上げ、古い行もそこから取ってきて聞き直せます。"
                         : "直近1日ぶんは、記録の行を押すとその場面の音声が流れます。")
                }

                Section("ほかのアプリとつなぐ") {
                    NavigationLink("カレンダー・連絡先・移動・睡眠") { IntegrationsView() }
                    NavigationLink("ロック画面・時計の文字盤から使う") { ShortcutsHelpView() }
                }

                // 点検・控え・掃除は、上の「点検」に移した（2026-11-12）
    }
}

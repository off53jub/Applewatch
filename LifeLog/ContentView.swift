import SwiftUI

/// 画面の下の5つのタブ。録っている間に触るものは「今日」、やることは「タスク」。ふだん触らない設定は「今日」の右上の歯車から開く。
struct ContentView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage("taskBadgeLateOnly") private var badgeLateOnly = false

    /// 今日までのもの・過ぎたもの（待っているものは除く）
    private var lateTasks: Int {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86400)
        // 家の PC のやることも、アプリのタスクと重ならないものだけ1回数える（2026-11-10。1つの一覧にした）
        let home = pipeline.mothership.extra(.all, tasks: pipeline.tasks.items)
            .filter { (MothershipExport.dueDate($0.due) ?? .distantFuture) < end }.count
        return pipeline.tasks.todo.filter { ($0.due ?? .distantFuture) < end }.count + home
    }

    var body: some View {
        TabView {
            Tab("今日", systemImage: "waveform") { TodayView() }
            Tab("タスク", systemImage: "checklist") { TasksTab() }
                .badge((badgeLateOnly ? 0 : pipeline.tasks.candidates.count) + lateTasks)
            Tab("ライブ", systemImage: "captions.bubble") { LiveView() }
            Tab("記録", systemImage: "books.vertical") { RecordsView() }
            Tab("人と場所", systemImage: "person.2") { PeoplePlacesView() }
        }
        // 知らせ・ショートカットから開く画面（2026-11-10。NoticeActions.swift）
        .sheet(item: Binding(get: { pipeline.noticeRoute }, set: { pipeline.noticeRoute = $0 })) { route in
            NavigationStack {
                switch route {
                case .tasks:
                    TaskBookView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { pipeline.noticeRoute = nil } }
                        }
                case .digestImport(let text):
                    WorkDigestImportView(initialText: text)
                }
            }
        }
        .onAppear {
            if let text = DigestInbox.take() { pipeline.noticeRoute = .digestImport(text) }
        }
    }
}

// MARK: - 今日

private struct TodayView: View {
    @Environment(Pipeline.self) private var pipeline
    /// 見直したい声のひとこまの数（記録をひととおり見るので、開いてから数える）
    @State private var reviewCount = 0
    @State private var showSettings = false

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
                } footer: {
                    Text("時計で録音中は、時計の「★ 印」ボタン（またはダブルタップ）でも印を付けられます。会議モードは時計の「会議」ボタンでも始められます（予定の参加者と題名を聞き取りのヒントにし、時計の音質を上げ、終わったらすぐ議事録にします）。")
                }

                confirmBox()

                // 朝の「昨日と今日」（2026-11-09。前の「朝の読み上げ」。MorningBrief.swift）。
                // 毎朝の「聞いて直す」の入口はやめた（7日で1行だけだったため。「記録」からは開ける）
                MorningBriefSection()

                // 実機でまだ確かめていない新しい動き（2026-11-10。Checklist.swift）
                ChecklistSection()

                Section("いまの様子") {
                    if Provisioning.isNear(), let expiry = Provisioning.expiryText() {
                        // 無料の署名は7日で切れ、切れるとアプリが起動しなくなって録音が止まる
                        Label("署名の期限 \(expiry)。切れる前に Sideloadly で入れ直してください（記録は消えません）",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if pipeline.recordingHeld {
                        Label("録音を休む場所にいるので、書くのを休んでいます", systemImage: "pause.circle")
                            .foregroundStyle(.orange)
                    }
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
                    if pipeline.email == nil {
                        Text("右上の歯車（設定）で Google にログインすると、ドキュメントに書き始めます。")
                            .foregroundStyle(.secondary)
                    }
                    if !pipeline.message.isEmpty {
                        Text(pipeline.message).foregroundStyle(.secondary)
                    }
                }

                taskBook()
                goodThings()
                PCFeatureNotice()

                // 答え合わせの入口・名前を付ける候補の声・AI からの質問・見直すものは、上の確認箱にまとめた（2026-11-09）

                // 「こんなのあったけど、どう？」は、タスクの確かめ待ちにまとめた（2026-11-09。Suggestions.swift）

                Section("今日の会話") {
                    if talks.isEmpty {
                        Text("まだありません").foregroundStyle(.secondary)
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

                // 家の PC が書いている途中の下書き（仮。記録には入れない。2026-11-07。Drafts.swift）
                DraftSection()

                if !pipeline.lastLines.isEmpty {
                    Section("最近の発言") {
                        ForEach(Array(pipeline.lastLines.suffix(8).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                    }
                }
            }
            .navigationTitle("今日")
            .toolbar {
                Button("設定", systemImage: "gearshape") { showSettings = true }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView { showSettings = false }
            }
            .task(id: pipeline.people.flatMap(\.samples)) {
                reviewCount = pipeline.voiceReview().count
            }
        }
    }

    /// 確認箱（2026-11-06）: 確かめ待ちの数を1か所に。中身はこの下の、大事な順に並べた各欄から開く
    @ViewBuilder
    private func confirmBox() -> some View {
        let week = AnswerKey.weekKey(.now)
        let samples = pipeline.answerKey.samples(of: week)
        let answers = samples.isEmpty ? AnswerKey.perWeek : samples.filter { !$0.isAnswered }.count
        let parts: [(String, Int)] = [
            ("タスクの候補", pipeline.tasks.candidates.count),
            ("AI からの質問", pipeline.asks.open.count),
            ("名前を付ける候補の声", pipeline.newVoices.open.count),
            ("見直したい声", reviewCount),
            ("聞き間違いかも", pipeline.misheardCount),
            ("割れやすい言葉", pipeline.splitWordCandidates().count),
            ("今週の答え合わせ", answers),
        ]
        let total = parts.reduce(0) { $0 + $1.1 }
        if total > 0 {
            Section {
                NavigationLink {
                    ConfirmBoxView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("確かめ待ち 合計 \(total)", systemImage: "tray.full")
                            .font(.headline)
                        Text(parts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: "・"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("確認箱")
            } footer: {
                Text("押すと、確かめ待ちを大事な順に1つの画面に並べます（タスクの候補 → AI からの質問 → 声 → 聞き間違い → 答え合わせ）。1日に上から5つまでで十分です。残りは明日に回して大丈夫です。")
            }
        }
    }

    /// 土日に、今週の答え合わせがまだなら入口を出す
    @ViewBuilder
    private func answerNudge() -> some View {
        let week = AnswerKey.weekKey(.now)
        let samples = pipeline.answerKey.samples(of: week)
        let left = samples.isEmpty ? AnswerKey.perWeek : samples.filter { !$0.isAnswered }.count
        if Calendar.current.isDateInWeekend(.now), left > 0 {
            Section {
                NavigationLink {
                    AnswerKeyView()
                } label: {
                    Label("今週の答え合わせ（あと \(left) 問・5分ほど）", systemImage: "checkmark.seal")
                }
            } footer: {
                Text("場面を聞いて「だれが・何を・どこで」が合っているかを答えると、聞き取りの数字が週ごとにたまります。")
            }
        }
    }

    /// いいこと帳の入口（2026-11-12）。家の PC が「good」を持つか、前に読んだ写しがあるときだけ出す。
    @ViewBuilder
    private func goodThings() -> some View {
        let book = pipeline.good
        if pipeline.homePC.features.contains("good") || book.data != nil {
            Section {
                NavigationLink {
                    GoodThingsView()
                } label: {
                    LabeledContent {
                        if let w = book.thisWeek { Text("今週 お礼 \(w.thanks)・ほめ言葉 \(w.praise)") }
                    } label: {
                        Label("いいこと帳", systemImage: "hand.thumbsup")
                    }
                }
            }
        }
    }

    /// 頼まれごと帳の入口。期限の近いものを3つまで出す。
    private func taskBook() -> some View {
        let book = pipeline.tasks
        let open = book.open
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86400)
        let late = open.filter { ($0.due ?? .distantFuture) < end }.count
        var summary = "まだ \(open.count) 件"
        if late > 0 { summary += "・今日まで \(late)" }
        if !book.candidates.isEmpty { summary += "・確かめ待ち \(book.candidates.count)" }
        return Section {
            NavigationLink {
                TaskBookView()
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

    /// AI からの質問（まだ答えていないものがあるときだけ）。いちばん新しい質問を1つ見せる。
    @ViewBuilder
    private func questions() -> some View {
        let open = pipeline.asks.open
        if let first = open.first {
            Section {
                NavigationLink {
                    QuestionsView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("AI からの質問（\(open.count) つ）", systemImage: "questionmark.bubble")
                        Text(first.question).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } footer: {
                Text("記録で合っているか分からないところです。答えると見出しやまとめが正しくなり、次からも覚えておきます。")
            }
        }
    }

    /// あとで見直すもの（今日の人物N・名前を付けてほしい声・声の見直し・聞き間違い）。無ければ出さない。
    @ViewBuilder
    private func todo(today: String, talks: [ConversationLog.Conversation]) -> some View {
        let tv = pipeline.broadcastLike()
        let todayIDs = Set(talks.flatMap(\.lines).compactMap(\.speakerID))
        let unnamed = pipeline.people.filter { !$0.isNamed && !$0.isSelf && $0.hidden != true && !tv.contains($0.id) }
        let todayCount = unnamed.filter { todayIDs.contains($0.id) }.count
        let waiting = pipeline.speakerLabelsOn ? unnamed.filter { $0.seconds >= 30 }.count : 0
        if todayCount > 0 || waiting > 0 || reviewCount > 0 || pipeline.misheardCount > 0 {
            Section {
                if todayCount > 0 {
                    NavigationLink {
                        UnnamedVoicesView(day: today)
                    } label: {
                        Label("今日の人物Nを整理（\(todayCount) 人）", systemImage: "person.crop.circle.badge.questionmark")
                    }
                }
                if waiting > 0 {
                    NavigationLink {
                        PeopleView()
                    } label: {
                        Label("名前を付けてほしい声（\(waiting) 人）", systemImage: "person.badge.plus")
                    }
                }
                if reviewCount > 0 {
                    NavigationLink {
                        VoiceReviewView()
                    } label: {
                        Label("声の見直し（\(reviewCount) 個）", systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                if pipeline.misheardCount > 0 {
                    NavigationLink {
                        MisheardView()
                    } label: {
                        Label("聞き間違いかも（\(pipeline.misheardCount) 個）", systemImage: "text.badge.checkmark")
                    }
                }
            } header: {
                Text("見直すもの")
            } footer: {
                Text("あいたときに少しずつで大丈夫です。直すほど、聞き分けと聞き取りが正確になります。聞き間違いを直し終わると、その日の見出しとまとめを作り直します（テレビ・動画らしい声は入れていません）。")
            }
        }
    }
}

// MARK: - ライブ

private struct LiveView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var visible = false

    var body: some View {
        let live = pipeline.live
        NavigationStack {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { pipeline.liveOn },
                    set: { on in Task { await pipeline.setLive(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ライブ文字起こし").font(.headline)
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
                                "ライブ文字起こし", systemImage: "captions.bubble",
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
            .navigationTitle("ライブ")
            .toolbar {
                if !live.lines.isEmpty {
                    Button("消す", systemImage: "trash") { live.clear() }
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

private struct RecordsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var days: [String] = []
    @State private var query = ""
    @State private var hits: [Pipeline.Hit] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if query.count >= 2 {
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
                        NavigationLink {
                            SpeakingView()
                        } label: {
                            Label("話し方の振り返り", systemImage: "person.wave.2")
                        }
                        NavigationLink {
                            QuestionsView()
                        } label: {
                            Label("AI からの質問・わかったこと帳", systemImage: "lightbulb")
                        }
                        NavigationLink {
                            AnswerKeyView()
                        } label: {
                            Label("答え合わせ（週5分）・聞き取りの数字", systemImage: "checkmark.seal")
                        }
                        // 毎朝の聞いて直す（終わったあとも、ここから開ける。2026-11-07。ReviewNudge.swift）
                        NavigationLink {
                            ReviewNudgeView()
                        } label: {
                            Label("今日の聞いて直す・学び直しの材料", systemImage: "ear")
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
                }
            }
            .searchable(text: $query, prompt: "言葉や名前で探す")
            .onChange(of: query) { hits = query.count >= 2 ? pipeline.search(query) : [] }
            .navigationTitle("記録")
            // 設定は「記録」からも開ける（2026-11-06）
            .toolbar {
                Button("設定", systemImage: "gearshape") { showSettings = true }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView { showSettings = false }
            }
            .onAppear { days = pipeline.recordedDays() }
            .refreshable { days = pipeline.recordedDays() }
        }
    }
}

// MARK: - 人と場所

private struct PeoplePlacesView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if pipeline.speakerLabelsOn {
                        NavigationLink {
                            PeopleView()
                        } label: {
                            let others = pipeline.people.filter { !$0.isSelf }
                            let waiting = others.filter { !$0.isNamed && $0.seconds >= 30 }.count
                            LabeledContent("話した相手",
                                           value: waiting > 0 ? "\(others.count) 人（名前待ち \(waiting)）" : "\(others.count) 人")
                        }
                        NavigationLink {
                            VoiceEnrollView()
                        } label: {
                            LabeledContent("自分の声", value: pipeline.hasSelfVoice ? "登録済み" : "未登録")
                        }
                    } else {
                        Toggle("話している人を聞き分ける", isOn: Binding(
                            get: { pipeline.speakerLabelsOn },
                            set: { pipeline.speakerLabelsOn = $0 }))
                    }
                } header: {
                    Text("話者")
                } footer: {
                    Text("違っていたら「記録」タブで行を長押しして直すと、その声を覚えて次から正確になります。")
                }

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
                    // 行ったお店（2026-11-08。ShopVisitViews.swift）
                    NavigationLink {
                        ShopVisitsView()
                    } label: {
                        LabeledContent("行ったお店", value: pipeline.shopVisits.isOn ? "オン" : "オフ")
                    }
                } header: {
                    Text("場所")
                } footer: {
                    Text("職場にした場所では、職場の人の声と職場の言葉で照らし合わせます。")
                }

                Section {
                    NavigationLink {
                        VocabularyView()
                    } label: {
                        let v = pipeline.vocabulary
                        LabeledContent("言葉の登録",
                                       value: "職場 \(v.words(in: .work).count)・職場以外 \(v.words(in: .other).count)・いつも \(v.words(in: .always).count)")
                    }
                } header: {
                    Text("聞き取ってほしい言葉")
                }
            }
            .navigationTitle("人と場所")
        }
    }
}

// MARK: - 設定

private struct SettingsView: View {
    @Environment(Pipeline.self) private var pipeline
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
        @Bindable var settings = pipeline.settings
        NavigationStack {
            List {
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
                    NavigationLink("クラウドに送ったもの") { CloudLogView() }
                    NavigationLink("録音の抜けと数の照合") { RecordingMapView() }
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
                    Text("守り")
                } footer: {
                    Text("Face ID をオンにすると、アプリが前に出るたびに確かめるまで記録を隠します（録音と文字起こしは続きます）。書き出しは、その年の会話・人・タスクを Markdown（読む用）と JSON（プログラム用・中身の説明つき）にします。年が変わると前の年の分を自動で書き出します。")
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
                    Text("同じ Google アカウントでログインした iPhone と iPad で、記録・話した相手（名前と登録した声）・言葉の登録・場所を、ドライブの「LifeLog/同期」フォルダを通して合わせます。アプリを開いたときと、文字起こしのあと（3分おきまで）に合わせます。\n「ここでは録音を休む」と、自動で覚えた声は端末ごとのままです。1日のまとめ・人物ノート・週のまとめ・AI 向けの索引は、iPhone が両方の分をまとめて書きます。\n初めて合わせる前に、今の記録と登録をアプリの中に一度だけ控えておきます。")
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
                    Text((pipeline.standbyOn
                         ? "時計が録音しているあいだだけ無音を流してアプリを起こしておき、時計の録音を区切りごとにすぐ文字起こしします。電池を少し多く使います。"
                         : "時計の録音は、アプリを開いたときや充電中にまとめて文字起こしします。")
                         + "\n「音がしないあいだは書かない」をオンにすると、時計と iPhone で1分続けて静かなときは録音ファイルに書かず、音がしたらその1秒前から書き始めます（マイクは聞き続けます）。無音を送ったり文字にしたりしないぶん、電池が長持ちします。\n「区切りの長さ」は、録音を区切って送る長さです。短め（初め）は45秒を過ぎた話の切れ目で区切り、長くても2分で区切るので、文字になるまでが早くなります。ふつうは今までどおり5分ほどで区切ります（送る回数が少ないぶん、時計の電池が少し長持ちします）。どちらも次の区切りから変わります。\n「電池が少ないときは5分に」をオンにすると（初めはオン）、時計の電池が 30% より少ないときと低電力モードのあいだは、短めの設定でも時計が自動で5分ごとに区切ります。電池が 35% まで戻るか充電を始めると、短めに戻ります。いま5分にしているかは、時計の画面と自己点検に出ます。時計の設定は、時計と iPhone がつながったときに伝わります。")
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
                    Text("iPhone の中だけで声の特徴を比べ、行に「[自分]」「[人物1]」などを付けます（無料）。別の人が同じ名前になるときは「厳しめ」、同じ人が何人にも分かれるときは「ゆるめ」にしてください。「食い違った声を自動で外す」は、覚えた声のひとこまが記録ではほかの人やテレビの行だったとき、見直しを待たずに聞き分けに使わないようにします（消さずに、人の画面から戻せます）。")
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
                    Text("話が3分途切れるごとに、ドキュメントに「時刻・場所・相手・内容」の見出しと要点を付け、日が変わると前の日の先頭に「1日のまとめ」を入れます（Groq の無料枠か、iPhone の中の言語モデル）。家の PC が作った1日のまとめ（会話・LINE・メモをまとめたもの）が届いた日は、そちらを先頭に載せます（1日に1回・iPhone だけ。アプリのまとめは週と月のまとめに使います）。")
                }

                Section {
                    Picker("iPhone の中の言語モデル", selection: $localModelMode) {
                        ForEach(LocalModel.Mode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    LabeledContent("この iPhone", value: LocalModel.status.text)
                } header: {
                    Text("言語モデル")
                } footer: {
                    Text("見出し・要点・まとめ・誤変換直し・聞き間違い探し・記録への質問を、Apple の iPhone の中の言語モデル（Apple Intelligence）でも作ります。無料で上限が無く、中身を外に送りません。Groq の大きいモデルより賢くなく、長い会話は頭と終わりだけを読むことがあります。「Groq が使えないときだけ」は、キーが無い・無料枠を使い切った・混んでいる・通信できないときの代わり。「職場の会話は端末内で」は、職場にいた時間の会話を Groq に送りません。")
                }

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

                Section {
                    NavigationLink("自己点検") { DiagnosticsView() }
                    NavigationLink("聞き取りの成績") { ListenQualityView() }
                    NavigationLink("登録の控え") { BackupView() }
                    NavigationLink("記録の掃除") { CleanupView() }
                } header: {
                    Text("点検と控え")
                } footer: {
                    Text("調子が悪いときは「自己点検」から。人・声・言葉の登録は毎日「登録の控え」に残しています。")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
                }
            }
        }
    }
}

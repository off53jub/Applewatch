import SwiftUI

/// 画面の下の5つのタブ。録っている間に触るものは「今日」、ふだん触らない設定は「設定」にまとめる。
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("今日", systemImage: "waveform") { TodayView() }
            Tab("ライブ", systemImage: "captions.bubble") { LiveView() }
            Tab("記録", systemImage: "books.vertical") { RecordsView() }
            Tab("人と場所", systemImage: "person.2") { PeoplePlacesView() }
            Tab("設定", systemImage: "gearshape") { SettingsView() }
        }
    }
}

// MARK: - 今日

private struct TodayView: View {
    @Environment(Pipeline.self) private var pipeline

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
                } footer: {
                    Text("時計で録音中は、時計の「★ 印」ボタン（またはダブルタップ）でも印を付けられます。")
                }

                Section("いまの様子") {
                    LabeledContent("時計", value: pipeline.watchStatus)
                    LabeledContent("文字起こし待ち", value: "\(pipeline.pendingCount) 件")
                    if !pipeline.lastEngine.isEmpty {
                        LabeledContent("直近の文字起こし", value: pipeline.lastEngine)
                    }
                    if pipeline.email == nil {
                        Text("「設定」タブで Google にログインすると、ドキュメントに書き始めます。")
                            .foregroundStyle(.secondary)
                    }
                    if !pipeline.message.isEmpty {
                        Text(pipeline.message).foregroundStyle(.secondary)
                    }
                }

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
                        let unnamedIDs = Set(talks.flatMap(\.lines).compactMap(\.speakerID))
                        let unnamed = pipeline.people.filter { !$0.isNamed && unnamedIDs.contains($0.id) }.count
                        if unnamed > 0 {
                            NavigationLink {
                                UnnamedVoicesView(day: today)
                            } label: {
                                Label("人物Nを整理（\(unnamed) 人）", systemImage: "person.crop.circle.badge.questionmark")
                            }
                        }
                    }
                }

                if !pipeline.lastLines.isEmpty {
                    Section("最近の発言") {
                        ForEach(Array(pipeline.lastLines.suffix(8).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                    }
                }
            }
            .navigationTitle("今日")
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
                                    Text(line.text).font(.title3)
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
                                description: Text("オンにしている間だけ、iPhone のマイクの声を数秒ごとにクラウド（Groq）で文字にして、ここに流します。記録にはいつも通り5分ごとの文字起こしが書かれます。アプリを閉じて10分たつと自動でオフになります。"))
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

    var body: some View {
        NavigationStack {
            List {
                if query.count >= 2 {
                    if hits.isEmpty {
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
                }
            }
            .searchable(text: $query, prompt: "言葉や名前で探す")
            .onChange(of: query) { hits = query.count >= 2 ? pipeline.search(query) : [] }
            .navigationTitle("記録")
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

    var body: some View {
        @Bindable var settings = pipeline.settings
        NavigationStack {
            List {
                Section("Google ドライブ") {
                    if let email = pipeline.email {
                        LabeledContent("ログイン中", value: email)
                        Button("ログアウト", role: .destructive) { pipeline.signOut() }
                    } else {
                        Button("Google でログイン") { Task { await pipeline.signIn() } }
                    }
                }

                Section {
                    Toggle("待機モード", isOn: Binding(
                        get: { pipeline.standbyOn },
                        set: { pipeline.standbyOn = $0 }))
                    Toggle("録音が止まったら知らせる", isOn: Binding(
                        get: { pipeline.stopAlertsOn },
                        set: { pipeline.stopAlertsOn = $0 }))
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text(pipeline.standbyOn
                         ? "無音を流してアプリを起こしておき、時計の録音を5分ごとにすぐ文字起こしします。電池を少し多く使います。"
                         : "時計の録音は、アプリを開いたときや充電中にまとめて文字起こしします。")
                }

                Section {
                    NavigationLink {
                        HomePCView()
                    } label: {
                        LabeledContent("家の PC の Haas-ja", value: pipeline.homePC.isConfigured ? "使用中" : "オフ")
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
                        .disabled(settings.groqKey == nil)
                    NavigationLink("サービスと API キーの設定") {
                        TranscriptionSettingsView(settings: settings)
                    }
                } header: {
                    Text("文字起こし")
                } footer: {
                    if !settings.hasAPIKey {
                        Text("API キーを登録すると、クラウドの高精度モデルで文字起こしできます（Groq なら無料）。ライブ文字起こしにも Groq のキーを使います。")
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
                    }
                } header: {
                    Text("話者")
                } footer: {
                    Text("iPhone の中だけで声の特徴を比べ、行に「[自分]」「[人物1]」などを付けます（無料）。別の人が同じ名前になるときは「厳しめ」、同じ人が何人にも分かれるときは「ゆるめ」にしてください。")
                }

                Section {
                    Toggle("会話ごとの見出しと1日のまとめ", isOn: Binding(
                        get: { pipeline.summariesOn },
                        set: { pipeline.summariesOn = $0 }))
                        .disabled(settings.groqKey == nil)
                    Toggle("場所を記録する", isOn: Binding(
                        get: { pipeline.places.isOn },
                        set: { pipeline.places.isOn = $0 }))
                } header: {
                    Text("会話のまとめ")
                } footer: {
                    Text("話が3分途切れるごとに、ドキュメントに「時刻・場所・相手・内容」の見出しと要点を付け、日が変わると前の日の先頭に「1日のまとめ」を入れます（Groq の無料枠）。")
                }

                Section {
                    Toggle("音声をドライブにも保存", isOn: Binding(
                        get: { pipeline.audioBackupOn },
                        set: { pipeline.audioBackupOn = $0 }))
                    if pipeline.audioBackupOn && pipeline.backupPending > 0 {
                        LabeledContent("ドライブに上げる前", value: "\(pipeline.backupPending) 件")
                    }
                    NavigationLink("ほかのアプリの音声を取り込む") { ImportView() }
                    NavigationLink("記録の掃除") { CleanupView() }
                } header: {
                    Text("音声と記録")
                } footer: {
                    Text(pipeline.audioBackupOn
                         ? "音声は Wi-Fi のときにドライブの「LifeLog/音声」に上げ、古い行もそこから取ってきて聞き直せます。"
                         : "直近1日ぶんは、記録の行を押すとその場面の音声が流れます。")
                }
            }
            .navigationTitle("設定")
        }
    }
}

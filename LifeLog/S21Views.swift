import SwiftUI

// s21（2026-11-22）の画面（決まりは S21Rules.swift・帳は S21Book.swift。docs/s21-app.md）。

// MARK: - 使1 電池優先・早さ優先・精度優先

/// 設定の「ふだん」に置く 3 つのボタン。下の表の組をまとめて切り替える（個別のスイッチは「くわしい設定」にそのまま残る）
struct S21PresetSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var note: String?

    var body: some View {
        let current = S21Preset.matching(currentValues, hasCloudKey: pipeline.settings.hasAPIKey)
        Section {
            HStack(spacing: LL.Space.s) {
                ForEach(S21Preset.allCases) { preset in
                    Button {
                        apply(preset)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: preset.symbol).font(.title3)
                            Text(preset.label).font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(current == preset ? LL.accent : LL.dim)
                    .accessibilityLabel(preset.label + (current == preset ? "（いまの組）" : ""))
                }
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(LL.dim)
            } else {
                Text(current.map { "いまは「\($0.label)」の組です" } ?? "いまは自分で選んだ組です")
                    .font(.caption).foregroundStyle(LL.dim)
            }
            // 押す前に、組ごとの電池と速さの見込み（いまの実測から・仮。2026-11-22。s22 の 楽9。S22Views.swift）
            S22PresetForecastRows()
        } header: {
            LLHeader(title: "録り方の組", symbol: "dial.medium")
        } footer: {
            HelpNote("押すと、いくつかのスイッチをまとめて切り替えます。あとから「くわしい設定」で 1 つずつ変えられます。\n電池優先: 区切りふつう（5分）・電池が少ないときは5分・音がしないあいだは書かない・声の無い区切りは送らない・待機モードはオフ・時計から PC に直接送るはオフ。\n早さ優先: 区切り短め・待機モード・時計から PC に直接送る・音声を PC から受け取る。\n精度優先: 区切り短め・高精度で文字起こし（キーがあるとき）・誤変換を直す・話者の聞き分け・声の無い区切りも送る。\n「直接送るの実験」の 4 日のあいだは、実験の組が先です。")
        }
    }

    private var currentValues: S21Preset.Values {
        S21Preset.Values(chunkLength: pipeline.chunkLength, batterySaver: pipeline.chunkBatterySaver,
                         skipSilence: pipeline.skipSilence, dropNoVoice: pipeline.dropNoVoice, standby: pipeline.standbyOn,
                         watchDirect: pipeline.homePC.watchDirect, watchRelay: pipeline.homePC.watchRelay,
                         useCloud: pipeline.settings.useCloud, correction: pipeline.correctionOn, speakers: pipeline.speakerLabelsOn)
    }

    private func apply(_ preset: S21Preset) {
        let count = pipeline.applyPreset(preset)
        LLHaptic.done.play()
        note = "「\(preset.label)」にしました（\(count) 個のスイッチ。時計には、つながったときに伝わります）"
    }
}

extension Pipeline {
    /// 録り方の組をまとめて切り替える（設定・「今日」・コントロールセンターから同じ道で。2026-11-25。s26 の 軽3）。変えたスイッチの数
    @discardableResult
    func applyPreset(_ preset: S21Preset) -> Int {
        let v = preset.values(hasCloudKey: settings.hasAPIKey)
        if let x = v.chunkLength { chunkLength = x }
        if let x = v.batterySaver { chunkBatterySaver = x }
        if let x = v.skipSilence { skipSilence = x }
        if let x = v.dropNoVoice { dropNoVoice = x }
        if let x = v.standby { standbyOn = x }
        if let x = v.watchDirect { homePC.watchDirect = x }
        if let x = v.watchRelay { homePC.watchRelay = x }
        if let x = v.useCloud, settings.hasAPIKey { settings.useCloud = x }
        if let x = v.correction, llmKey != nil { correctionOn = x }
        if let x = v.speakers { speakerLabelsOn = x }
        Tally.add("s21.preset." + preset.rawValue)
        return v.count
    }

    /// いまの組（自分で選んだ組なら nil）
    var currentPreset: S21Preset? {
        S21Preset.matching(S21Preset.Values(chunkLength: chunkLength, batterySaver: chunkBatterySaver, skipSilence: skipSilence,
                                            dropNoVoice: dropNoVoice, standby: standbyOn, watchDirect: homePC.watchDirect,
                                            watchRelay: homePC.watchRelay, useCloud: settings.useCloud, correction: correctionOn,
                                            speakers: speakerLabelsOn),
                           hasCloudKey: settings.hasAPIKey)
    }
}

// MARK: - 電3・守3・守4・電2・使10 時計の守りと実験（くわしい設定の Apple Watch の下）

struct S21WatchSettingsSection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(S21Watch.sleepChunksKey) private var sleepChunks = true
    @AppStorage(S21Watch.workoutGuardKey) private var workoutGuard = false
    @AppStorage(S21Rules.routeOnKey) private var routeOn = true
    @AppStorage(S21Rules.silenceActionKey) private var silenceAction = S21Rules.SilenceAction.notify.rawValue
    @AppStorage(S21Book.shakeKey) private var shake = true

    var body: some View {
        Section {
            Toggle("寝ている時間は区切りを5分に", isOn: $sleepChunks)
            Toggle("時計の強い守り（ワークアウト扱い）", isOn: $workoutGuard)
            Picker("時計の便りが10分途切れたら", selection: $silenceAction) {
                ForEach(S21Rules.SilenceAction.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle("直接送るの実験（4日）", isOn: $routeOn)
            LabeledContent("きょう", value: S21Book.routeText())
            Toggle("振って「いまの画面が変」を送る", isOn: $shake)
        } header: {
            Text("時計の守りと実験")
        } footer: {
            HelpNote("「寝ている時間は区切りを5分に」（初めはオン）: 1:00〜6:00 で時計を充電していないあいだは、短めの設定でも時計が5分ごとに区切ります（送る回数が減って電池が長持ちします）。\n「強い守り」（初めはオフ）: 録音しているあいだだけ、時計をワークアウトと同じ扱いにして、画面が消えても止めにくくします。心拍を測り続けるので電池を多く使います。初めてのときにヘルスケアの許可を聞きます。ワークアウトの記録は残しません。\n「便りが10分途切れたら」: 時計から10分知らせが無いと知らせます（初めは知らせるだけ）。「iPhone で録り始める」にすると、iPhone のアプリが動いているときは iPhone でも録り始め、時計が戻ったら iPhone の分は止めます。\n「直接送るの実験」（初めはオン）: この版を初めて開いた次の日から4日、「時計から PC に直接送る」と「iPhone 経由だけ」を1日ずつ入れ替えて、時計の電池の減りを家の PC が比べます。終わったら元に戻ります。\n「振って送る」: iPhone を振ると、いまの画面の名前とひとことを家の PC に送ります（中身・人の名前は入れません）。")
        }
        .onChange(of: sleepChunks) { _, _ in S21Book.settingsChanged?() }
        .onChange(of: workoutGuard) { _, _ in S21Book.settingsChanged?() }
        .onChange(of: routeOn) { _, _ in pipeline.scheduleWatchPCSync() }
    }
}

// MARK: - 使9 同期の相手から外す

/// 同期の相手のうち、この端末より古い版の端末（外す・戻す）
struct S21SyncPeersRows: View {
    @State private var excluded = S21Book.excludedPeers

    private struct Peer: Identifiable {
        let id: String
        let build: Int
        var device: String { id }
    }

    var body: some View {
        let older = AppBuild.olderPeers().map { Peer(id: $0.device, build: $0.build) }
        ForEach(older) { peer in
            let out = excluded.contains(peer.device)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("端末 \(peer.device)")
                    Text(peer.build == 0 ? "版がかなり古い" : "版 \(peer.build)（この iPhone は \(AppBuild.current)）")
                        .font(.caption).foregroundStyle(LL.dim)
                }
                Spacer()
                Button(out ? "相手に戻す" : "同期の相手から外す") {
                    S21Book.setExcluded(peer.device, !out)
                    excluded = S21Book.excludedPeers
                }
                .buttonStyle(.bordered)
                .tint(out ? LL.accent : LL.warn)
            }
        }
        if !older.isEmpty {
            Text("古い版の端末から届く記録は、新しい版で足した項目が抜けやすくなります。外すと、その端末のファイルを読まなくなります（消しません。こちらからは今までどおり書きます）。入れ直したら「相手に戻す」を押してください。")
                .font(.caption).foregroundStyle(LL.dim)
        }
    }
}

// MARK: - 使7 時計でいちばん長く話している声から、自分の声を ○× で

struct S21SelfVoiceView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var candidates: [S21Rules.SelfCandidate] = []
    @State private var loading = true
    @State private var working = false
    @State private var done: String?
    @State private var player = ClipPlayer()

    var body: some View {
        LLList {
            Section {
                if loading {
                    HStack { ProgressView(); Text("直近7日の時計の録音を数えています…") }
                } else if let first = candidates.first, let person = pipeline.people.first(where: { $0.id == first.id }) {
                    HStack {
                        if let sample = person.samples.last {
                            SampleButton(player: player, sample: sample, key: person.id)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName).font(.headline)
                            Text("時計の録音で \(Int((first.seconds / 60).rounded())) 分ほど・\(first.lines) 行（直近7日）")
                                .font(.caption).foregroundStyle(LL.dim)
                        }
                    }
                    Text("▶︎で聞いて、自分の声ですか？").font(.callout)
                    HStack(spacing: LL.Space.m) {
                        Button {
                            answer(first.id, yes: true)
                        } label: {
                            Label("自分の声", systemImage: "circle").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LL.accent)
                        Button {
                            answer(first.id, yes: false)
                        } label: {
                            Label("違う", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(working)
                } else {
                    LLEmpty(title: "候補はありません", symbol: "person.wave.2", detail: "時計の録音で 10 行以上話している名前の無い声が出ると、ここに出ます。")
                }
                if let done { Text(done).font(.footnote).foregroundStyle(LL.dim) }
            } footer: {
                Text("時計はいつも自分のそばにあるので、時計の録音でいちばん長く話している名前の無い声は、自分の声のことが多いはずです（見立て・仮）。「自分の声」を押すと、その声を自分にまとめ、これまでの記録とドキュメントの名前も「\(SpeakerLabeler.selfName)」に直します。違う声は、もう出しません。")
            }
        }
        .navigationTitle("時計の声から自分を探す")
        .countsOpen("s21SelfVoice")
        .task { await load() }
        .onDisappear { player.stop() }
    }

    private func load() async {
        loading = true
        let unnamed = Set(pipeline.people.filter { !$0.isSelf && !$0.isNamed }.map(\.id))
        var lines: [S21Rules.VoiceLine] = []
        for day in pipeline.recordedDays().prefix(7) {
            for talk in pipeline.conversations(on: day) {
                for line in talk.lines {
                    // 行の長さは文字の数から（1 秒 7 文字ほど。仮）
                    lines.append(S21Rules.VoiceLine(speaker: line.speakerID, audio: line.audio, seconds: Double(line.text.count) / 7))
                }
            }
            await Task.yield()
        }
        candidates = S21Rules.selfCandidates(lines, unnamed: unnamed, rejected: S21Book.rejectedSelf)
        loading = false
    }

    private func answer(_ id: String, yes: Bool) {
        player.stop()
        Tally.add(yes ? "s21.selfVoice.yes" : "s21.selfVoice.no")
        if !yes {
            S21Book.rejectSelf(id)
            candidates.removeAll { $0.id == id }
            done = "違う声として、もう出しません。"
            return
        }
        working = true
        Task {
            await pipeline.mergeIntoSelf([id])
            candidates.removeAll { $0.id == id }
            done = "自分の声にまとめました。"
            working = false
        }
    }
}

// MARK: - 使8 見直したい声のひとこまを 1 画面で ○×

struct S21VoiceQuickReviewView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var items: [Pipeline.ReviewItem] = []
    @State private var done: [String: String] = [:]
    @State private var working: String?
    @State private var player = ClipPlayer()

    var body: some View {
        LLList {
            Section {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            SampleButton(player: player, sample: item.sample, key: item.id)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.person.displayName).font(.subheadline.weight(.semibold))
                                Text("「\(item.info.text)」").font(.callout).lineLimit(2)
                            }
                        }
                        if let note = done[item.id] {
                            Text(note).font(.caption).foregroundStyle(LL.dim)
                        } else if working == item.id {
                            ProgressView()
                        } else {
                            HStack(spacing: LL.Space.s) {
                                Button {
                                    pipeline.keepSample(item)
                                    done[item.id] = "○ この人の声のまま"
                                    Tally.add("s21.quickReview.keep")
                                } label: {
                                    Label("この人の声", systemImage: "circle").frame(maxWidth: .infinity, minHeight: 36)
                                }
                                .buttonStyle(.bordered)
                                .tint(LL.accent)
                                Button {
                                    forget(item)
                                } label: {
                                    Label("違う（忘れる）", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 36)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            } footer: {
                Text("▶︎で聞いて、その人の声なら ○、違えば ×（そのひとこまを聞き分けに使わなくなります。行は消えません）。だれの声かを選びたいときは「声を聞いて直す」から。")
            }
        }
        .overlay {
            if items.isEmpty { LLEmpty(title: "見直したい声はありません", symbol: "checkmark.circle", detail: "記録でほかの人やテレビの行と重なった声のひとこまが、ここに出ます。") }
        }
        .navigationTitle("声を ○× でまとめて")
        .countsOpen("s21QuickReview")
        .onAppear { items = pipeline.voiceReview() }
        .onDisappear { player.stop() }
    }

    private func forget(_ item: Pipeline.ReviewItem) {
        player.stop()
        working = item.id
        Tally.add("s21.quickReview.forget")
        Task {
            let text = await pipeline.dropSample(item.sample, from: item.person.id, moveTo: nil)
            done[item.id] = "× " + text
            working = nil
        }
    }
}

// MARK: - 使10 振って「いまの画面が変」

struct S21ShakeSheet: View {
    @Environment(Pipeline.self) private var pipeline
    let screen: String
    let onClose: () -> Void
    @State private var note = ""
    @State private var sent: String?

    var body: some View {
        LLForm {
            Section {
                LabeledContent("画面", value: screen)
                TextField("どう変でしたか（なくてもよい）", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            } footer: {
                Text("画面の名前・ひとこと・時刻だけを家の PC に送ります（会話の中身・人の名前は入れません）。家の PC につながらないときは、つながったときに送ります。")
            }
            if let sent {
                Section { Text(sent).foregroundStyle(LL.dim) }
            }
        }
        .navigationTitle("いまの画面が変")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("やめる", action: onClose) }
            ToolbarItem(placement: .confirmationAction) {
                Button("送る") {
                    if pipeline.sendShake(screen: screen, note: note) {
                        LLHaptic.done.play()
                        onClose()
                    } else {
                        sent = "送れませんでした。"
                    }
                }
            }
        }
    }
}

/// 振ったときに開く画面の名前（シートの item）
struct S21ShakeTarget: Identifiable {
    let screen: String
    var id: String { screen }
}

// MARK: - 点検のページに置く入口

struct S21CheckSection: View {
    var body: some View {
        Section {
            NavigationLink("時計の声から自分の声を探す（○×）") { S21SelfVoiceView() }
            NavigationLink("見直したい声を ○× でまとめて") { S21VoiceQuickReviewView() }
        } header: {
            Text("声を手早く直す")
        }
    }
}

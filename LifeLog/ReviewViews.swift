import SwiftUI

/// 見直したい声のひとこまの一覧。記録ではほかの人やテレビの行と重なっているひとこまを、▶︎で聞いて直す。
/// ほかの人の声なら、その人の声に移すか忘れる。合っていれば「このままでよい」でもう出さない。
struct VoiceReviewView: View {
    @Environment(Pipeline.self) private var pipeline
    /// この人のひとこまだけ（nil ならすべての人）
    var only: String? = nil
    @State private var items: [Pipeline.ReviewItem] = []
    @State private var player = ClipPlayer()
    @State private var working: String?
    @State private var done: [String: String] = [:]

    var body: some View {
        List {
            ForEach(items) { item in
                Section {
                    HStack {
                        SampleButton(player: player, sample: item.sample, key: item.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("「\(item.info.text)」").lineLimit(3)
                            Text(item.info.caption).font(.caption).foregroundStyle(.secondary)
                            Text(reason(item)).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if let note = done[item.id] {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    } else if working == item.id {
                        HStack { ProgressView(); Text("直しています…") }
                    } else {
                        ForEach(item.others, id: \.self) { other in
                            if let target = pipeline.people.first(where: { $0.id == other }) {
                                Button("「\(target.displayName)」の声だった（移す）") { run(item, moveTo: other) }
                            }
                        }
                        Button("このひとこまを忘れる", role: .destructive) { run(item, moveTo: nil) }
                        Button("「\(item.person.displayName)」の声で合っている") {
                            pipeline.keepSample(item)
                            done[item.id] = "このままにしました。もう出しません。"
                        }
                    }
                } header: {
                    Text("\(item.person.displayName) のひとこま")
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("見直したい声はありません", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("声の見直し")
        .onAppear {
            items = pipeline.voiceReview().filter { only == nil || $0.person.id == only }
        }
        .onDisappear { player.stop() }
        .safeAreaInset(edge: .bottom) {
            if !items.isEmpty {
                Text("▶︎で聞いて、その人の声でなければ直してください。忘れると、そのひとこまの音と同じ声も忘れるので、聞き分けの間違いが減ります。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
            }
        }
    }

    private func reason(_ item: Pipeline.ReviewItem) -> String {
        let names = item.info.speakers.filter { $0 != item.person.displayName }
        if !names.isEmpty { return "記録では「\(names.joined(separator: "」「"))」の行と重なっています" }
        return "テレビ・動画・放送などの行と重なっています"
    }

    private func run(_ item: Pipeline.ReviewItem, moveTo target: String?) {
        player.stop()
        working = item.id
        Task {
            done[item.id] = await pipeline.dropSample(item.sample, from: item.person.id, moveTo: target)
            working = nil
        }
    }
}

/// 1人として扱われている2人を分ける。その人の行の声を取って近さで2つに分け、聞いて、別の人の声のほうを分ける。
struct SplitPersonView: View {
    @Environment(Pipeline.self) private var pipeline
    let id: String
    @State private var result: Pipeline.SplitResult?
    @State private var limit = 60
    @State private var working = false
    @State private var progress = ""
    @State private var player = ClipPlayer()
    /// 別の人にする組（0 か 1）
    @State private var picking: Pick?
    @State private var naming: Pick?
    @State private var newName = ""
    @State private var done: String?
    @State private var applied: (keep: [Pipeline.SplitClip], moved: [Pipeline.SplitClip], target: String)?

    struct Pick: Identifiable { let id: Int }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private var person: SpeakerLabeler.Person? { pipeline.people.first { $0.id == id } }

    var body: some View {
        Form {
            Section {
                Picker("調べる行", selection: $limit) {
                    Text("新しい 60 行").tag(60)
                    Text("新しい 150 行").tag(150)
                }
                Button(working ? progress : (result == nil ? "声を2つに分けてみる" : "もう一度分けてみる")) { run() }
                    .disabled(working)
            } footer: {
                Text("「\(person?.displayName ?? "")」とされた行（2秒以上話したもの）の声を取り、声の近さで2つに分けます。▶︎で聞いて、「\(person?.displayName ?? "")」ではないほうを「この声は別の人」にしてください。その行の名前が変わり、覚えている声も分け直すので、これからの聞き分けも分かれます。録音が手元に無い行はドライブから取ってくるので、Wi-Fi のときに。")
            }
            if let note = result?.note {
                Section { Text(note).foregroundStyle(.orange) }
            }
            if let result, result.groups.count == 2 {
                ForEach(0..<2, id: \.self) { g in
                    Section {
                        ForEach(result.groups[g].prefix(8)) { clip in clipRow(clip) }
                        if result.groups[g].count > 8 {
                            Text("ほか \(result.groups[g].count - 8) 行").font(.caption).foregroundStyle(.secondary)
                        }
                        if done == nil {
                            Button("この声は別の人（分ける）") { picking = Pick(id: g) }
                        }
                    } header: {
                        Text("声\(g == 0 ? "A" : "B")（\(result.groups[g].count) 行）")
                    }
                }
            }
            if let done {
                Section {
                    Text(done)
                    if let applied {
                        Button(working ? progress : "残りの古い行も、声で振り分ける（300 行まで）") {
                            working = true
                            Task {
                                let count = await pipeline.reassignRest(id, keep: applied.keep, moved: applied.moved,
                                                                         to: applied.target) { text in
                                    Task { @MainActor in progress = text }
                                }
                                self.done = (self.done ?? "") + "\n古い行のうち \(count) 行も直しました。"
                                self.applied = nil
                                working = false
                            }
                        }
                        .disabled(working)
                    }
                }
            }
        }
        .navigationTitle("2人を分ける")
        .onDisappear { player.stop() }
        .sheet(item: $picking) { pick in
            NavigationStack {
                PersonPicker(exclude: id, includeSelf: true) { target in
                    picking = nil
                    apply(pick.id, to: target)
                }
                .navigationTitle("だれの声ですか")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { picking = nil } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("新しい人") {
                            picking = nil
                            newName = ""
                            naming = pick
                        }
                    }
                }
            }
        }
        .alert("新しい人の名前", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("名前", text: $newName)
            Button("分ける") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let pick = naming, !name.isEmpty {
                    Task {
                        let target = await pipeline.newPerson(name: name, context: person?.context)
                        apply(pick.id, to: target)
                    }
                }
                naming = nil
            }
            Button("キャンセル", role: .cancel) { naming = nil }
        }
    }

    private func clipRow(_ clip: Pipeline.SplitClip) -> some View {
        let key = "split-\(clip.line.time.timeIntervalSince1970)"
        return Button {
            Task {
                await player.toggle(key, at: clip.line.offset ?? 0, until: clip.end) {
                    guard let audio = clip.line.audio else { return nil }
                    return await pipeline.archive.playableURL(for: audio)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.time.string(from: clip.line.time)).font(.caption).foregroundStyle(.secondary)
                    Text(clip.line.text).lineLimit(3)
                }
                Spacer(minLength: 0)
                if player.loading == key {
                    ProgressView()
                } else {
                    Image(systemName: player.playing == key ? "stop.circle.fill" : "play.circle").foregroundStyle(Color.accentColor)
                }
            }
        }
        .tint(.primary)
    }

    private func run() {
        player.stop()
        working = true
        done = nil
        applied = nil
        progress = "声を調べています…"
        Task {
            result = await pipeline.splitGroups(for: id, limit: limit) { text in
                Task { @MainActor in progress = text }
            }
            working = false
        }
    }

    private func apply(_ group: Int, to target: String) {
        guard let result, result.groups.count == 2 else { return }
        let moved = result.groups[group], keep = result.groups[1 - group]
        player.stop()
        working = true
        progress = "分けています…"
        Task {
            done = await pipeline.applySplit(id, keep: keep, moved: moved, to: target)
            applied = (keep, moved, target)
            working = false
        }
    }
}

/// 登録の控え。毎日の控えの様子と、控えから戻す。
struct BackupView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var drive: [BackupKeeper.Entry] = []
    @State private var driveNote: String?
    @State private var working = false
    @State private var choosing: BackupKeeper.Entry?
    @State private var note: String?

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    var body: some View {
        let backups = pipeline.backups
        Form {
            Section {
                LabeledContent("アプリの中", value: backups.lastLocal.map { Self.time.string(from: $0) } ?? "まだ")
                LabeledContent("ドライブ", value: backups.lastDrive.map { Self.time.string(from: $0) } ?? "まだ")
                if let problem = backups.problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
                Button(working ? "控えています…" : "今すぐ控える") {
                    working = true
                    Task {
                        await backups.runIfDue(signedIn: pipeline.email != nil, force: true)
                        await loadDrive()
                        working = false
                    }
                }
                .disabled(working)
            } header: {
                Text("最後に控えた時刻")
            } footer: {
                Text("覚えた声（名前の無い声と自動で覚えた声も）・まとめた記録・人ごとの言葉・言葉の登録・場所・設定を、毎日1回控えます。アプリの中に7日分、Wi-Fi のときはドライブの「LifeLog/控え」に端末ごとに14日分。会話の記録は同期でドライブに渡っているので、ここには入れません。")
            }
            if pipeline.backups.hasPendingRestore {
                Section {
                    Text("戻す控えを選んであります。アプリを上にスワイプして終わらせ、開き直すと入れ替わります。")
                    Button("戻すのをやめる", role: .destructive) { pipeline.backups.cancelRestore(); note = nil }
                }
            }
            Section("アプリの中の控え") {
                let local = backups.localEntries()
                if local.isEmpty { Text("まだありません").foregroundStyle(.secondary) }
                ForEach(local) { entry in Button(entry.label) { choosing = entry } }
            }
            Section {
                if let driveNote { Text(driveNote).font(.footnote).foregroundStyle(.secondary) }
                ForEach(drive) { entry in Button(entry.label) { choosing = entry } }
            } header: {
                Text("ドライブの控え")
            } footer: {
                Text("アプリを入れ直して中身が消えたときは、ドライブの控えから戻せます（ほかの端末の控えも選べます）。")
            }
            if let note {
                Section { Text(note) }
            }
        }
        .navigationTitle("登録の控え")
        .task { await loadDrive() }
        .confirmationDialog("「\(choosing?.label ?? "")」の控えに戻しますか？",
                            isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                            titleVisibility: .visible, presenting: choosing) { entry in
            Button("この控えに戻す", role: .destructive) {
                Task {
                    do {
                        try await pipeline.backups.prepareRestore(entry)
                        note = "戻す準備ができました。アプリを上にスワイプして終わらせ、開き直すと戻ります。"
                    } catch {
                        note = "控えを読めませんでした: \(error.localizedDescription)"
                    }
                }
            }
        } message: { _ in
            Text("覚えた声・まとめた記録・人ごとの言葉・言葉の登録・場所などを、その時の控えに入れ替えます。会話の記録は変えません。入れ替える前のものもアプリの中に残します。")
        }
    }

    private func loadDrive() async {
        guard pipeline.email != nil else {
            driveNote = "Google にログインすると出ます。"
            return
        }
        do {
            drive = try await pipeline.backups.driveEntries()
            driveNote = drive.isEmpty ? "まだありません（Wi-Fi のときに上げます）" : nil
        } catch {
            driveNote = "読めませんでした: \(error.localizedDescription)"
        }
    }
}

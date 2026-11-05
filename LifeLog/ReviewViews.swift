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
    /// 「ほかの人の声だった」で、移す先を選んでいるひとこま
    @State private var picking: String?
    @State private var naming: String?
    @State private var newName = ""
    /// 「まるごとテレビの声だった」を確かめているひとこま
    @State private var wholeMedia: Pipeline.ReviewItem?

    var body: some View {
        list
            .sheet(item: Binding(get: { picking.map(Pick.init) }, set: { picking = $0?.id })) { pick in
                NavigationStack {
                    PersonPicker(exclude: items.first { $0.id == pick.id }?.person.id, includeSelf: true) { target in
                        picking = nil
                        if let item = items.first(where: { $0.id == pick.id }) { run(item, moveTo: target) }
                    }
                    .navigationTitle("だれの声ですか")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { picking = nil } }
                        ToolbarItem(placement: .primaryAction) {
                            Button("新しい人") {
                                picking = nil
                                newName = ""
                                naming = pick.id
                            }
                        }
                    }
                }
            }
            .alert("新しい人の名前", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("名前", text: $newName)
                Button("決める") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if let key = naming, !name.isEmpty, let item = items.first(where: { $0.id == key }) {
                        Task {
                            let target = await pipeline.newPerson(name: name, context: item.person.context)
                            run(item, moveTo: target)
                        }
                    }
                    naming = nil
                }
                Button("キャンセル", role: .cancel) { naming = nil }
            }
            .confirmationDialog("「\(wholeMedia?.person.displayName ?? "")」はテレビ・動画などの声でしたか？",
                                isPresented: Binding(get: { wholeMedia != nil }, set: { if !$0 { wholeMedia = nil } }),
                                titleVisibility: .visible, presenting: wholeMedia) { item in
                ForEach(Pipeline.mediaKinds, id: \.self) { kind in
                    Button("\(kind)だった") { markWhole(item, kind: kind) }
                }
            } message: { item in
                Text("「\(item.person.displayName)」とされた行を、すべて「テレビ」などの行に書き換え、この声を忘れます（行は消えません）。")
            }
    }

    struct Pick: Identifiable { let id: String }

    private var list: some View {
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
                        Button("「\(item.person.displayName)」の声で合っている") {
                            pipeline.keepSample(item)
                            done[item.id] = "このままにしました。もう出しません。"
                        }
                        Menu("その他…") {
                            Button("ほかの人の声だった（選ぶ）") { picking = item.id }
                            if !item.person.isSelf {
                                Button("自分の声だった") { run(item, moveTo: SpeakerLabeler.selfID) }
                            }
                            Button("テレビ・動画・音楽の声だった（忘れる）") {
                                run(item, moveTo: nil, note: "テレビなどの声として外しました。")
                            }
                            Button("何人かの声が重なっている（忘れる）") { run(item, moveTo: nil) }
                            if !item.person.isNamed && !item.person.isSelf {
                                Button("「\(item.person.displayName)」がまるごとテレビ・動画の声だった") { wholeMedia = item }
                            }
                            Button("分からない（今は飛ばす）") {
                                done[item.id] = "飛ばしました。次に開いたときに、また出ます。"
                            }
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
                Text("▶︎で聞いて、その人の声でなければ直してください。どちらでもないときは「その他…」から（ほかの人・自分・テレビ・分からない）。忘れると、そのひとこまの音と同じ声も忘れるので、聞き分けの間違いが減ります。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
            }
        }
    }

    private func reason(_ item: Pipeline.ReviewItem) -> String {
        let names = item.info.speakers.filter { $0 != item.person.displayName }
        if !names.isEmpty { return "記録では「\(names.joined(separator: "」「"))」の行と重なっています" }
        return "テレビ・動画・放送などの行と重なっています"
    }

    private func run(_ item: Pipeline.ReviewItem, moveTo target: String?, note: String? = nil) {
        player.stop()
        working = item.id
        Task {
            let text = await pipeline.dropSample(item.sample, from: item.person.id, moveTo: target)
            done[item.id] = (note.map { $0 + "\n" } ?? "") + text
            working = nil
        }
    }

    /// 名前の無い声がまるごとテレビなどの声だった。その人のほかのひとこまも、もう出さない。
    private func markWhole(_ item: Pipeline.ReviewItem, kind: String) {
        player.stop()
        working = item.id
        Task {
            let count = await pipeline.markPersonAsMedia(item.person.id, kind: kind)
            let note = "「\(item.person.displayName)」の \(count) 行を「\(kind)」の行にし、この声を忘れました。"
            for other in items where other.person.id == item.person.id { done[other.id] = note }
            working = nil
        }
    }
}

/// 1人として扱われている何人かを分ける。その人の行の声を取って近さで何組にでも分け、聞いて、組ごとに決める。
/// 組ごとに「この人の声」「別の人に移す」「放っておく」。決めた組をまとめて直し、残りの古い行も、いちばん近い組に振り分ける。
struct SplitPersonView: View {
    @Environment(Pipeline.self) private var pipeline
    let id: String
    @State private var result: Pipeline.SplitResult?
    @State private var limit = 60
    @State private var working = false
    @State private var progress = ""
    @State private var player = ClipPlayer()
    /// 組ごとの決め（無ければ放っておく）
    @State private var choices: [Int: Choice] = [:]
    @State private var picking: Pick?
    @State private var naming: Pick?
    @State private var newName = ""
    @State private var done: String?
    @State private var applied: (keep: [Pipeline.SplitClip], moves: [(clips: [Pipeline.SplitClip], target: String)],
                                 media: [Pipeline.SplitClip], kind: String)?

    enum Choice: Equatable {
        case keep
        case move(String)
        /// テレビ・動画などの声だった（その種類）
        case media(String)
    }

    struct Pick: Identifiable { let id: Int }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private var person: SpeakerLabeler.Person? { pipeline.people.first { $0.id == id } }

    private func name(_ target: String) -> String { pipeline.people.first { $0.id == target }?.displayName ?? target }

    private func isMove(_ choice: Choice?) -> Bool {
        if case .move = choice { return true }
        return false
    }

    private func isMedia(_ choice: Choice?) -> Bool {
        if case .media = choice { return true }
        return false
    }

    private var moveCount: Int { choices.values.filter { isMove($0) || isMedia($0) }.count }

    private func groupTitle(_ g: Int, _ result: Pipeline.SplitResult) -> String {
        if g == result.scattered { return "ばらばらの声（\(result.groups[g].count) 行）" }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return "声\(letters[min(g, letters.count - 1)])（\(result.groups[g].count) 行）"
    }

    var body: some View {
        Form {
            Section {
                Picker("調べる行", selection: $limit) {
                    Text("新しい 60 行").tag(60)
                    Text("新しい 150 行").tag(150)
                }
                Button(working ? progress : (result == nil ? "声を分けてみる" : "もう一度分けてみる")) { run() }
                    .disabled(working)
            } footer: {
                Text("「\(person?.displayName ?? "")」とされた行（2秒以上話したもの）の声を取り、声の近さで何組にでも分けます（はっきり近い声だけをまとめるので、同じ人が2組に分かれることもあります）。▶︎で聞いて、組ごとに「この人の声」か「別の人に移す」を選び、最後に「分ける」を押してください。選ばなかった組は、そのままにします。録音が手元に無い行はドライブから取ってくるので、Wi-Fi のときに。")
            }
            if let note = result?.note {
                Section { Text(note).foregroundStyle(.orange) }
            }
            if let result, done == nil {
                ForEach(result.groups.indices, id: \.self) { g in
                    Section {
                        ForEach(result.groups[g].prefix(6)) { clip in clipRow(clip) }
                        if result.groups[g].count > 6 {
                            Text("ほか \(result.groups[g].count - 6) 行").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            choiceButton("この人の声", selected: choices[g] == .keep) { choices[g] = .keep }
                            choiceButton(movedLabel(g), selected: isMove(choices[g])) { picking = Pick(id: g) }
                        }
                        HStack {
                            Menu {
                                ForEach(Pipeline.mediaKinds, id: \.self) { kind in
                                    Button("\(kind)の声だった") { choices[g] = .media(kind) }
                                }
                            } label: {
                                choiceLabel(mediaLabel(g), selected: isMedia(choices[g]))
                            }
                            choiceButton("放っておく", selected: choices[g] == nil) { choices[g] = nil }
                        }
                    } header: {
                        Text(groupTitle(g, result))
                    } footer: {
                        if g == result.scattered {
                            Text("どの組にも近くなかった、1行ずつの声です。いろいろな人やテレビの声が混ざっていることが多いです。")
                        }
                    }
                }
                Section {
                    Button(working ? progress : "分ける（\(moveCount) 組を移す）") { apply() }
                        .disabled(working || moveCount == 0)
                } footer: {
                    Text("移す組の行の名前を変え、覚えている声も移すので、これからの聞き分けも分かれます。「テレビなど」を選んだ組は、行を「テレビ」などの行に書き換え、その声を忘れます（行は消えません）。「この人の声」を選んだ組は、残す声の見本にします。")
                }
            }
            if let done {
                Section {
                    Text(done)
                    if let applied {
                        Button(working ? progress : "残りの古い行も、声で振り分ける（300 行まで）") {
                            working = true
                            Task {
                                let count = await pipeline.reassignRest(id, keep: applied.keep, moves: applied.moves,
                                                                        media: applied.media, kind: applied.kind) { text in
                                    Task { @MainActor in progress = text }
                                }
                                self.done = (self.done ?? "") + "\n古い行のうち \(count) 行も直しました。"
                                self.applied = nil
                                working = false
                            }
                        }
                        .disabled(working)
                    }
                    Button("もう一度分けてみる") { run() }
                        .disabled(working)
                } footer: {
                    Text("まだ混ざっているときは、もう一度分けてみてください（直した行は外れているので、残った行だけで分け直します）。")
                }
            }
        }
        .navigationTitle("混ざった声を分ける")
        .onDisappear { player.stop() }
        .sheet(item: $picking) { pick in
            NavigationStack {
                PersonPicker(exclude: id, includeSelf: true) { target in
                    picking = nil
                    choices[pick.id] = .move(target)
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
            Button("決める") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let pick = naming, !name.isEmpty {
                    Task {
                        let target = await pipeline.newPerson(name: name, context: person?.context)
                        choices[pick.id] = .move(target)
                    }
                }
                naming = nil
            }
            Button("キャンセル", role: .cancel) { naming = nil }
        }
    }

    private func movedLabel(_ g: Int) -> String {
        if case .move(let target) = choices[g] { return "→ \(name(target))" }
        return "別の人に移す"
    }

    private func mediaLabel(_ g: Int) -> String {
        if case .media(let kind) = choices[g] { return "→ \(kind)" }
        return "テレビなどの声"
    }

    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        Text(title).font(.caption).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }

    private func choiceButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            choiceLabel(title, selected: selected)
        }
        .buttonStyle(.borderless)
        .tint(selected ? .accentColor : .primary)
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
        choices = [:]
        progress = "声を調べています…"
        Task {
            let made = await pipeline.splitGroups(for: id, limit: limit) { text in
                Task { @MainActor in progress = text }
            }
            result = made
            // いちばん大きい組（ばらばらの声でなければ）は、はじめから「この人の声」にしておく
            if !made.groups.isEmpty, made.scattered != 0 { choices[0] = .keep }
            working = false
        }
    }

    private func apply() {
        guard let result else { return }
        var keep: [Pipeline.SplitClip] = []
        var moves: [(clips: [Pipeline.SplitClip], target: String)] = []
        var media: [Pipeline.SplitClip] = []
        // テレビなどの組がいくつかあれば、いちばん行の多い組の種類にそろえる
        var kind = "テレビ"
        var kindCount = 0
        for (g, choice) in choices where g < result.groups.count {
            switch choice {
            case .keep: keep += result.groups[g]
            case .move(let target): moves.append((result.groups[g], target))
            case .media(let k):
                media += result.groups[g]
                if result.groups[g].count > kindCount {
                    kind = k
                    kindCount = result.groups[g].count
                }
            }
        }
        player.stop()
        working = true
        progress = "分けています…"
        Task {
            done = await pipeline.applyGroups(id, keep: keep, moves: moves, media: media, kind: kind)
            applied = (keep, moves, media, kind)
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

/// ほかの人の行になっている自分の声を探して、「自分」の行に直す（2026-11-05 本人の希望）。
/// その人とされた行の声を取り、自分の登録・手直しの声にはっきり近い行だけを出す。▶︎で聞いて、選んだ行だけ直す。
struct SelfClaimView: View {
    @Environment(Pipeline.self) private var pipeline
    let id: String
    @State private var limit = 150
    @State private var result: Pipeline.SelfClaim?
    @State private var selected: Set<Date> = []
    @State private var working = false
    @State private var progress = ""
    @State private var done: String?
    @State private var player = ClipPlayer()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private var name: String { pipeline.people.first { $0.id == id }?.displayName ?? "人物\(id)" }

    private var clips: [Pipeline.SplitClip] { result?.clips.map { $0.clip } ?? [] }

    var body: some View {
        Form {
            Section {
                Picker("調べる行", selection: $limit) {
                    Text("新しい 150 行").tag(150)
                    Text("新しい 300 行").tag(300)
                }
                Button(working ? progress : (result == nil ? "自分の声だった行を探す" : "もう一度探す")) { run() }
                    .disabled(working)
            } footer: {
                Text("「\(name)」とされた行（2秒以上話したもの）の声を取り、自分の登録・手直しの声にはっきり近く、「\(name)」の声よりも近い行を探します。▶︎で聞いて、自分の声だった行だけに印を残し、「自分に直す」を押してください。記録とドキュメントの名前が「自分」になり、その会話の見出しと要点を作り直します。迷う行は出しません。録音が手元に無い行はドライブから取ってくるので、Wi-Fi のときに。")
            }
            if let note = result?.note {
                Section { Text(note).foregroundStyle(.orange) }
            }
            if let done {
                Section { Text(done) }
            }
            if let result, done == nil {
                if clips.isEmpty {
                    Section { Text("調べた \(result.checked) 行のうち、自分の声らしい行はありませんでした。") }
                } else {
                    Section {
                        Button(selected.count == clips.count ? "すべての印を外す" : "すべてに印を付ける") {
                            selected = selected.count == clips.count ? [] : Set(clips.map(\.line.time))
                        }
                        ForEach(clips) { clip in row(clip) }
                    } header: {
                        Text("自分の声らしい行（\(clips.count) 行・調べた \(result.checked) 行）")
                    } footer: {
                        Text("印を外した行は、そのままにします。")
                    }
                    Section {
                        Button(working ? progress : "\(selected.count) 行を自分に直す") { apply() }
                            .disabled(working || selected.isEmpty)
                    }
                }
            }
        }
        .navigationTitle("自分の声だった行")
        .onDisappear { player.stop() }
    }

    private func row(_ clip: Pipeline.SplitClip) -> some View {
        let key = "claim-\(clip.line.time.timeIntervalSince1970)"
        let on = selected.contains(clip.line.time)
        return HStack(alignment: .firstTextBaseline) {
            Button {
                if on { selected.remove(clip.line.time) } else { selected.insert(clip.line.time) }
            } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            Button {
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
                        Image(systemName: player.playing == key ? "stop.circle.fill" : "play.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func run() {
        working = true
        done = nil
        progress = "声を調べています…"
        Task {
            let found = await pipeline.selfLikeLines(of: id, limit: limit) { text in
                Task { @MainActor in progress = text }
            }
            result = found
            selected = Set(found.clips.map { $0.clip.line.time })
            working = false
        }
    }

    private func apply() {
        let chosen = clips.filter { selected.contains($0.line.time) }
        working = true
        progress = "直しています…"
        Task {
            done = await pipeline.claimAsSelf(id, clips: chosen)
            working = false
        }
    }
}

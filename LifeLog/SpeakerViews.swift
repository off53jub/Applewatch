import AVFoundation
import SwiftUI

/// 何秒か録音して、録れたファイルを渡す部品。自分の声・相手の声の登録で使う。
struct VoiceCapture: View {
    @Environment(Pipeline.self) private var pipeline
    var seconds = 20
    var title: String
    var disabled = false
    /// 録れた音声を受け取って、結果の一文を返す。終わったらファイルは消す。
    var onRecorded: (URL) async -> String

    @State private var recorder: AVAudioRecorder?
    @State private var remaining = 0
    @State private var status = ""

    var body: some View {
        if remaining > 0 {
            Label("録音中… あと \(remaining) 秒", systemImage: "waveform")
        } else {
            Button(title) { start() }
                .disabled(disabled || pipeline.isRecording)
        }
        if pipeline.isRecording {
            Text("ライフログの録音を止めてから録ってください。").foregroundStyle(.secondary)
        }
        if !status.isEmpty {
            Text(status).foregroundStyle(.secondary)
        }
    }

    private func start() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        pipeline.suspendStandby()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
            ])
            guard r.record(forDuration: TimeInterval(seconds)) else { throw NSError(domain: "Enroll", code: 1) }
            recorder = r
            remaining = seconds
            status = ""
            Task { await countDown(url) }
        } catch {
            status = "録音できませんでした: \(error.localizedDescription)"
            pipeline.resumeStandby()
        }
    }

    private func countDown(_ url: URL) async {
        while remaining > 0 {
            try? await Task.sleep(for: .seconds(1))
            remaining -= 1
        }
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        pipeline.resumeStandby()
        status = "声の特徴を調べています…（初回はモデルのダウンロードがあります）"
        status = await onRecorded(url)
        try? FileManager.default.removeItem(at: url)
    }
}

/// 自分の声を20秒録って登録する画面。録り直すと前の登録に足していく。
struct VoiceEnrollView: View {
    @Environment(Pipeline.self) private var pipeline

    static let sample = "今日はいい天気ですね。朝は駅まで歩いて、電車の中でニュースを読みました。午後からは打ち合わせが二つあって、そのあと資料をまとめる予定です。夜は家でゆっくり過ごそうと思います。"

    var body: some View {
        Form {
            Section {
                Text(Self.sample)
            } header: {
                Text("この文を、ふだんの声で読んでください")
            } footer: {
                Text("静かな場所で、自分だけが話している状態で録ってください。声の特徴だけをこの iPhone に保存し、録音は登録が終わったら消します。何度か録ると（小声・会議の声など）聞き分けが正確になります。")
            }
            Section {
                VoiceCapture(title: pipeline.hasSelfVoice ? "もう一度録って足す（20秒）" : "録音を始める（20秒）") { url in
                    do {
                        try await pipeline.enrollSelf(from: url)
                        return "登録しました。これからは文字起こしに「[自分]」と付きます。"
                    } catch {
                        return "登録できませんでした: \(error.localizedDescription)"
                    }
                }
            }
        }
        .navigationTitle("自分の声を登録")
    }
}

/// これまでに聞いた声の一覧。職場・職場以外に分けて出す。
struct PeopleView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()
    @State private var rebuilding = false
    @State private var rebuildResult = ""

    private var others: [SpeakerLabeler.Person] { pipeline.people.filter { !$0.isSelf } }

    var body: some View {
        List {
            // 名前の無い声のうち、よく聞く声から名前を付けてもらう
            let waiting = others.filter { !$0.isNamed && $0.seconds >= 30 }
                .sorted { $0.lastHeard > $1.lastHeard }
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { person in row(person) }
                } header: {
                    Text("名前を付けてほしい声")
                } footer: {
                    Text("▶︎で声を聞いて、タップして名前を付けてください。名前を付けると、これまでの記録とドキュメントの「人物N」もその名前に変わります。")
                }
            }
            ForEach([SpeakerLabeler.Context.work, .other], id: \.self) { context in
                let list = others.filter { $0.isNamed && $0.context == context }
                if !list.isEmpty {
                    Section(context.label) { ForEach(list) { row($0) } }
                }
            }
            let both = others.filter { $0.isNamed && $0.context == nil }
            if !both.isEmpty {
                Section("どちらでも") { ForEach(both) { row($0) } }
            }
            let rest = others.filter { !$0.isNamed && $0.seconds < 30 }
            if !rest.isEmpty {
                Section {
                    ForEach(rest) { row($0) }
                } header: {
                    Text("少しだけ聞いた声")
                } footer: {
                    Text("名前を付けていない声は、2週間聞かなければ自動で忘れます。")
                }
            }
            Section {
                Button(rebuilding ? "作り直しています…" : "記録から人と声を作り直す") {
                    rebuilding = true
                    Task {
                        rebuildResult = await pipeline.rebuildPeople { rebuildResult = $0 }
                        rebuilding = false
                    }
                }
                .disabled(rebuilding)
                if !rebuildResult.isEmpty {
                    Text(rebuildResult).font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text("覚えている人が消えてしまったときに。これまでの記録に残っている名前（自分を含む）から人を作り直し、その人が話していた録音から声を取り直します。手元に無い録音はドライブから取ってくるので、Wi-Fi のときに。")
            }
        }
        .navigationTitle("話した相手")
        .toolbar {
            NavigationLink {
                SelfMergeView()
            } label: {
                Text("自分をまとめる")
            }
            .disabled(others.isEmpty)
            NavigationLink {
                RegisterPersonView()
            } label: {
                Image(systemName: "plus")
            }
        }
        .onDisappear { player.stop() }
    }

    private func row(_ person: SpeakerLabeler.Person) -> some View {
        HStack {
            if let sample = person.samples.last {
                SampleButton(player: player, sample: sample, key: person.id)
            }
            NavigationLink {
                PersonView(id: person.id)
            } label: {
                LabeledContent(person.displayName) {
                    Text("\(person.minutes) 分・\(person.lastHeard.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
    }
}

/// 覚えている声のひとこまを鳴らすボタン。音声が手元に無ければドライブから取ってくる。
struct SampleButton: View {
    @Environment(Pipeline.self) private var pipeline
    let player: ClipPlayer
    let sample: SpeakerLabeler.Sample
    let key: String

    var body: some View {
        if player.loading == key {
            ProgressView()
        } else {
            Button {
                Task {
                    await player.toggle(key, at: sample.start + 1, until: sample.end) {
                        await pipeline.archive.playableURL(for: sample.audio)
                    }
                }
            } label: {
                Image(systemName: player.playing == key ? "stop.circle.fill" : "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(!pipeline.archive.canPlay(sample.audio))
        }
    }
}

/// 1人分の設定：名前・場・声を足す・ほかの人とまとめる・消す。
struct PersonView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @State private var player = ClipPlayer()
    @State private var merging = false
    @State private var mergingSelf = false
    @State private var deleting = false
    @State private var merges: [MergeLog.Record] = []
    @State private var undoing: MergeLog.Record?
    @State private var undoMessage: String?

    private var person: SpeakerLabeler.Person? { pipeline.people.first { $0.id == id } }

    private static let mergeDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    var body: some View {
        Form {
            if let person {
                if !person.isSelf {
                    Section {
                        TextField("名前", text: $name)
                            .onSubmit { save() }
                        if name != (person.name ?? "") && !name.isEmpty {
                            Button("この名前にする") { save() }
                        }
                    } header: {
                        Text("名前")
                    } footer: {
                        Text("名前を付けると、これまでの記録とドキュメントの名前も変わり、その人の「人物ノート」に会話が書き足されます。")
                    }
                    Section {
                        Picker("会う場", selection: Binding(
                            get: { person.context },
                            set: { value in Task { await pipeline.setContext(id, to: value) } })) {
                            Text("どちらでも").tag(SpeakerLabeler.Context?.none)
                            ForEach(SpeakerLabeler.Context.allCases) { Text($0.label).tag(Optional($0)) }
                        }
                    } footer: {
                        Text("職場の人は職場にいるときに、職場以外の人はそれ以外のときに先に照らし合わせます。")
                    }
                }
                Section {
                    ForEach(Array(person.samples.enumerated()).reversed(), id: \.offset) { i, sample in
                        HStack {
                            SampleButton(player: player, sample: sample, key: "\(i)")
                            Text("声のひとこま \(person.samples.count - i)")
                        }
                    }
                    LabeledContent("覚えている声", value: "\(person.voices.count)（登録・手直し \(person.pinnedCount)）")
                    VoiceCapture(seconds: 15, title: "その場で声を録って足す（15秒）") { url in
                        do {
                            try await pipeline.addVoice(from: url, to: id)
                            return "声を足しました。"
                        } catch {
                            return "足せませんでした: \(error.localizedDescription)"
                        }
                    }
                } header: {
                    Text("声")
                } footer: {
                    Text("その人だけが話しているときに録ってください（相手の了承を取ってから）。記録の行を長押しして「話者を直す」と、その行の声も覚えます。")
                }
                if !person.isSelf {
                    Section {
                        Button("ほかの人と同じ人としてまとめる") { merging = true }
                        Button("自分の声だった（自分にまとめる）") { mergingSelf = true }
                        Button("この声を忘れる", role: .destructive) { deleting = true }
                    }
                }
                Section {
                    ForEach(merges) { record in
                        Button { undoing = record } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("「\(record.sourceName)」を戻す")
                                Text("\(Self.mergeDate.string(from: record.date)) に\(record.automatic == true ? "自動で" : "")まとめた・\(record.lines.count) 行")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink("ドキュメントの履歴から探す") { PastMergesView(target: id) }
                    if let undoMessage { Text(undoMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("まとめた人を分け直す")
                } footer: {
                    Text("間違えてまとめた人を、まとめる前の人（「人物123」など）に戻します。記録が残っていない前のまとめは、ドライブの日ごとのドキュメントの版の履歴から探します。")
                }
            }
        }
        .navigationTitle(person?.displayName ?? "")
        .onAppear {
            name = person?.name ?? ""
            merges = MergeLog.records(into: id)
        }
        .confirmationDialog("「\(undoing?.sourceName ?? "")」を戻しますか？",
                            isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } }),
                            titleVisibility: .visible, presenting: undoing) { record in
            Button("戻す") {
                Task {
                    await pipeline.undoMerge(record)
                    merges = MergeLog.records(into: id)
                    undoMessage = "「\(record.sourceName)」を声ごと戻し、\(record.lines.count) 行の名前も戻しました。"
                }
            }
        } message: { record in
            Text("まとめる前の「\(record.sourceName)」を声ごと戻し、そのとき「\(record.targetName)」に書き換えた行の名前も戻します。そのあと手で別の人に直した行はそのままです。")
        }
        .onDisappear { player.stop() }
        .sheet(isPresented: $merging) {
            NavigationStack {
                PersonPicker(exclude: id, includeSelf: true) { target in
                    merging = false
                    Task {
                        if target == SpeakerLabeler.selfID {
                            await pipeline.mergeIntoSelf([id])
                            dismiss()
                            return
                        }
                        // 名前の無いほうを、名前のあるほうにまとめる
                        let mine = pipeline.people.first { $0.id == id }
                        let theirs = pipeline.people.first { $0.id == target }
                        if mine?.isNamed == true && theirs?.isNamed == false {
                            await pipeline.mergePerson(target, into: id)
                        } else {
                            await pipeline.mergePerson(id, into: target)
                            dismiss()
                        }
                    }
                }
                .navigationTitle("同じ人を選ぶ")
                .toolbar { Button("キャンセル") { merging = false } }
            }
        }
        .confirmationDialog("「\(person?.displayName ?? "")」を自分にまとめますか？", isPresented: $mergingSelf,
                            titleVisibility: .visible) {
            Button("自分にまとめる") {
                Task {
                    await pipeline.mergeIntoSelf([id])
                    dismiss()
                }
            }
        } message: {
            Text("この声を自分の声として覚え、これまでの記録とドキュメントの名前も「\(SpeakerLabeler.selfName)」に直します。")
        }
        .confirmationDialog("この声を忘れますか？", isPresented: $deleting, titleVisibility: .visible) {
            Button("忘れる", role: .destructive) {
                Task {
                    await pipeline.removePerson(id)
                    dismiss()
                }
            }
        } message: {
            Text("これまでの記録の名前はそのまま残ります。")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await pipeline.renamePerson(id, to: trimmed) }
    }
}

/// まとめを記録していなかったころのまとめを、ドキュメントの版の履歴から探して戻す。
struct PastMergesView: View {
    @Environment(Pipeline.self) private var pipeline
    let target: String
    @State private var found: [Pipeline.PastMerge] = []
    @State private var searched = false
    @State private var working = false
    @State private var status: String?
    @State private var confirming: Pipeline.PastMerge?

    private static let lineTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm:ss"
        return f
    }()

    private var targetName: String { pipeline.people.first { $0.id == target }?.displayName ?? "" }

    var body: some View {
        Form {
            Section {
                Button(working ? "探しています…" : (searched ? "もう一度探す" : "探す")) { search() }
                    .disabled(working)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("いま「\(targetName)」になっている行のうち、ドライブの日ごとのドキュメントの前の版で「人物N」だった行を、番号ごとに集めます。行の話者を手で直したところも混ざるので、中身を見て選んでください。記録はまだ変えません。")
            }
            ForEach(found) { past in
                Section {
                    ForEach(Array(past.lines.prefix(4).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.lineTime.string(from: item.line.time)).font(.caption).foregroundStyle(.secondary)
                            Text(item.line.text).lineLimit(2)
                        }
                    }
                    if past.lines.count > 4 {
                        Text("ほか \(past.lines.count - 4) 行").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("「\(past.name)」に戻す") { confirming = past }
                        .disabled(working)
                } header: {
                    Text("\(past.name)　\(past.lines.count) 行（\(past.days.map { String($0.dropFirst(5)) }.joined(separator: "、"))）")
                }
            }
        }
        .navigationTitle("まとめた人を探す")
        .confirmationDialog("\(confirming?.lines.count ?? 0) 行を「\(confirming?.name ?? "")」に戻しますか？",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { past in
            Button("戻す") { restore(past) }
        } message: { past in
            Text("行の名前を「\(past.name)」に戻し、その声を録音から覚え直します。「\(targetName)」の登録・手直しで覚えた声と名前はそのままです。")
        }
    }

    private func search() {
        working = true
        Task {
            let result = await pipeline.findPastMerges(into: target) { text in
                Task { @MainActor in status = text }
            }
            found = result.found
            status = result.note ?? (result.found.isEmpty ? nil : "\(result.found.count) 人分見つかりました。")
            searched = true
            working = false
        }
    }

    private func restore(_ past: Pipeline.PastMerge) {
        working = true
        Task {
            let text = await pipeline.splitOut(past, from: target) { text in
                Task { @MainActor in status = text }
            }
            found.removeAll { $0.id == past.id }
            status = text
            working = false
        }
    }
}

/// 人を1人選ぶ一覧（職場・職場以外・名前の無い声の順）。
struct PersonPicker: View {
    @Environment(Pipeline.self) private var pipeline
    var exclude: String? = nil
    var includeSelf = true
    /// 先に出す場（今いる場など）
    var context: SpeakerLabeler.Context? = nil
    var onPick: (String) -> Void

    var body: some View {
        let people = pipeline.people.filter { $0.id != exclude && (includeSelf || !$0.isSelf) }
        let named = people.filter { $0.isNamed && !$0.isSelf }
        let order: [SpeakerLabeler.Context?] = context == .other ? [.other, nil, .work] : [.work, nil, .other]
        List {
            if includeSelf {
                Button(SpeakerLabeler.selfName) { onPick(SpeakerLabeler.selfID) }
            }
            ForEach(order, id: \.self) { c in
                let list = named.filter { $0.context == c }
                if !list.isEmpty {
                    Section(c?.label ?? "どちらでも") {
                        ForEach(list) { p in Button(p.displayName) { onPick(p.id) } }
                    }
                }
            }
            let unnamed = people.filter { !$0.isNamed }.sorted { $0.lastHeard > $1.lastHeard }
            if !unnamed.isEmpty {
                Section("名前の無い声") {
                    ForEach(unnamed) { p in Button(p.displayName) { onPick(p.id) } }
                }
            }
        }
        .tint(.primary)
    }
}

/// 相手の声をその場で録って、名前を付けて登録する。
struct RegisterPersonView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var name = ""
    @State private var context: SpeakerLabeler.Context? = nil

    var body: some View {
        Form {
            Section {
                TextField("名前", text: $name)
                Picker("会う場", selection: $context) {
                    Text("どちらでも").tag(SpeakerLabeler.Context?.none)
                    ForEach(SpeakerLabeler.Context.allCases) { Text($0.label).tag(Optional($0)) }
                }
            }
            Section {
                VoiceCapture(title: "その人の声を録る（20秒）",
                             disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) { url in
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    do {
                        try await pipeline.registerPerson(from: url, name: trimmed, context: context)
                        name = ""
                        return "\(trimmed) さんを登録しました。続けて別の人も登録できます。"
                    } catch {
                        return "登録できませんでした: \(error.localizedDescription)"
                    }
                }
            } footer: {
                Text("相手の了承を取ってから、その人だけが話している状態で録ってください（自己紹介や雑談で十分です）。声の特徴だけをこの iPhone に保存し、録音は消します。")
            }
        }
        .navigationTitle("相手の声を登録")
    }
}

/// 記録の行の話者を直す画面。直すと、その行の声をその人の声として覚える。
struct SpeakerFixView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let line: ConversationLog.Line
    let next: ConversationLog.Line?
    /// その時いた場（候補の並び順に使う）
    let context: SpeakerLabeler.Context?
    var onDone: () -> Void

    @State private var scope: Pipeline.SpeakerFix = .sameVoice
    @State private var creating = false
    @State private var newName = ""
    @State private var working = false

    private var oldIsUnnamed: Bool {
        guard let id = line.speakerID else { return false }
        return pipeline.people.first { $0.id == id }?.isNamed == false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(line.speaker.map { "いま: \($0)" } ?? "いま: 話者なし").font(.caption).foregroundStyle(.secondary)
                Text(line.text).lineLimit(3)
                Picker("直す範囲", selection: $scope) {
                    Text("この行だけ").tag(Pipeline.SpeakerFix.line)
                    Text("同じ5分の同じ声").tag(Pipeline.SpeakerFix.sameVoice)
                    if line.speakerID != nil {
                        Text("この声すべて").tag(Pipeline.SpeakerFix.everywhere)
                    }
                }
                .pickerStyle(.segmented)
                Text(scopeHint).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            PersonPicker(exclude: line.speakerID, context: context) { id in apply(id) }
                .overlay { if working { ProgressView() } }
                .disabled(working)
                .navigationTitle("この声は誰？")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("新しい人") {
                            newName = ""
                            creating = true
                        }
                    }
                }
                .alert("新しい人の名前", isPresented: $creating) {
                    TextField("名前", text: $newName)
                    Button("登録して直す") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        Task { apply(await pipeline.newPerson(name: name, context: context)) }
                    }
                    Button("キャンセル", role: .cancel) {}
                }
            }
        }
        .onAppear { if oldIsUnnamed { scope = .everywhere } }
    }

    private var scopeHint: String {
        switch scope {
        case .line: "この行だけ直します。"
        case .sameVoice: "同じ録音の区切り（5分）で、同じ声とされた行をまとめて直します。"
        case .everywhere: "これまでに「\(line.speaker ?? "")」とされた行をすべて直し、2人を1人にまとめます。"
        }
    }

    private func apply(_ id: String) {
        working = true
        Task {
            await pipeline.fixSpeaker(of: line, next: next, to: id, scope: scope)
            working = false
            onDone()
            dismiss()
        }
    }
}

/// 「話した相手」の中に混ざった自分の声を選んで、まとめて自分にする。
struct SelfMergeView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var player = ClipPlayer()
    @State private var chosen: Set<String> = []
    @State private var confirming = false
    @State private var working = false

    private var others: [SpeakerLabeler.Person] {
        pipeline.people.filter { !$0.isSelf }.sorted { ($0.isNamed ? 1 : 0, $1.lastHeard) < ($1.isNamed ? 1 : 0, $0.lastHeard) }
    }

    var body: some View {
        List {
            Section {
                ForEach(others) { person in
                    HStack {
                        if let sample = person.samples.last {
                            SampleButton(player: player, sample: sample, key: person.id)
                        }
                        Button {
                            if chosen.contains(person.id) { chosen.remove(person.id) } else { chosen.insert(person.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(person.displayName)
                                    Text("\(person.minutes) 分・\(person.lastHeard.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: chosen.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(person.id) ? Color.accentColor : Color.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                }
            } footer: {
                Text("▶︎で声を聞いて、自分の声だったものを選んでください。選んだ声は自分の声として覚え、これまでの記録とドキュメントの名前も「\(SpeakerLabeler.selfName)」に直します。ほかの人の声を混ぜると、その人の声まで自分と間違えやすくなるので、確かなものだけを。")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(working ? "まとめています…" : "選んだ \(chosen.count) 人を自分にまとめる") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty || working)
                .padding()
        }
        .confirmationDialog("選んだ \(chosen.count) 人を自分にまとめますか？", isPresented: $confirming, titleVisibility: .visible) {
            Button("自分にまとめる") {
                working = true
                Task {
                    await pipeline.mergeIntoSelf(Array(chosen))
                    working = false
                    dismiss()
                }
            }
        }
        .navigationTitle("自分の声をまとめる")
        .onDisappear { player.stop() }
    }
}

/// その日の記録に出てくる「人物N」を、名前のある人にまとめたり、名前を付けたりする。
struct UnnamedVoicesView: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String
    @State private var player = ClipPlayer()
    @State private var suggestions: [String: (id: String, name: String, distance: Float)] = [:]
    /// 「〇〇さん」と呼ばれたすぐあとに話した声と、その名前
    @State private var called: [String: [(name: String, count: Int)]] = [:]
    @State private var picking: Pick?
    @State private var naming: Pick?
    @State private var newName = ""
    @State private var working: String?

    struct Pick: Identifiable { let id: String }

    struct Item: Identifiable {
        let person: SpeakerLabeler.Person
        let lines: [ConversationLog.Line]
        var id: String { person.id }
    }

    /// その日の行に出てくる、名前の無い声と、その行（多い順）
    private var unnamed: [Item] {
        let lines = pipeline.conversations(on: day).flatMap(\.lines)
        return pipeline.people.filter { !$0.isNamed }.compactMap { person in
            let mine = lines.filter { $0.speakerID == person.id }
            return mine.isEmpty ? nil : Item(person: person, lines: mine)
        }
        .sorted { $0.lines.count > $1.lines.count }
    }

    var body: some View {
        let list = unnamed
        List {
            ForEach(list) { item in
                Section {
                    HStack {
                        if let sample = item.person.samples.last {
                            SampleButton(player: player, sample: sample, key: item.person.id)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.lines.last?.text ?? "").lineLimit(2)
                            Text("この日 \(item.lines.count) 行").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if working == item.person.id {
                        HStack { ProgressView(); Text("直しています…") }
                    } else {
                        if let s = suggestions[item.person.id], s.distance <= Self.showLimit {
                            Button("「\(s.name)」にまとめる（\(s.distance <= Self.closeLimit ? "声がよく似ています" : "少し似ています")）") {
                                apply(item.person.id) { await pipeline.assign(item.person.id, to: s.id) }
                            }
                        }
                        if let top = called[item.person.id]?.first {
                            calledButton(item.person.id, name: top.name, count: top.count)
                        }
                        Button("ほかの人を選ぶ") { picking = Pick(id: item.person.id) }
                        Button("新しく名前を付ける") {
                            newName = ""
                            naming = Pick(id: item.person.id)
                        }
                    }
                } header: {
                    Text(item.person.displayName)
                }
            }
        }
        .overlay {
            if list.isEmpty {
                ContentUnavailableView("名前の無い声はありません", systemImage: "person.crop.circle.badge.checkmark")
            }
        }
        .navigationTitle("人物Nを整理")
        .task(id: list.map(\.id)) {
            called = pipeline.calledNames(on: day)
            for item in list where suggestions[item.person.id] == nil {
                if let s = await pipeline.voiceSuggestion(for: item.person.id) {
                    suggestions[item.person.id] = s
                }
            }
        }
        .onDisappear { player.stop() }
        .sheet(item: $picking) { pick in
            NavigationStack {
                PersonPicker(exclude: pick.id, includeSelf: true,
                             context: pipeline.places.context(at: .now)) { target in
                    picking = nil
                    apply(pick.id) { await pipeline.assign(pick.id, to: target) }
                }
                .navigationTitle("だれの声ですか")
                .toolbar { Button("キャンセル") { picking = nil } }
            }
        }
        .alert("名前を付ける", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("名前", text: $newName)
            Button("付ける") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let id = naming?.id, !name.isEmpty {
                    apply(id) { await pipeline.renamePerson(id, to: name) }
                }
                naming = nil
            }
            Button("キャンセル", role: .cancel) { naming = nil }
        } message: {
            Text("これまでの記録とドキュメントの名前も変わります。")
        }
    }

    /// 「〇〇さん」と呼ばれた名前から。名前を付けた人に同じ名前の人がいればその人にまとめ、いなければその名前を付ける。
    @ViewBuilder
    private func calledButton(_ id: String, name: String, count: Int) -> some View {
        let heard = "「\(name)さん」と呼ばれたあとに話していました（\(count)回）"
        if let match = pipeline.people.first(where: { $0.isNamed && !$0.isSelf && ($0.displayName.hasPrefix(name) || name.hasPrefix($0.displayName)) }) {
            Button {
                apply(id) { await pipeline.assign(id, to: match.id) }
            } label: {
                VStack(alignment: .leading) {
                    Text("「\(match.displayName)」にまとめる")
                    Text(heard).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Button {
                apply(id) { await pipeline.renamePerson(id, to: name) }
            } label: {
                VStack(alignment: .leading) {
                    Text("「\(name)」と名前を付ける")
                    Text(heard).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 似ていると出す距離と、よく似ているとする距離
    private static let showLimit: Float = 0.55
    private static let closeLimit: Float = 0.40

    private func apply(_ id: String, _ action: @escaping () async -> Void) {
        working = id
        Task {
            await action()
            suggestions[id] = nil
            working = nil
        }
    }
}

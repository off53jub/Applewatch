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
    @State private var places = Pipeline.PlaceIndex()
    @State private var showAllWaiting = false
    /// 名前の無い声の、名前の候補
    @State private var clues: [String: Pipeline.VoiceClues] = [:]
    /// ▶︎で鳴らす声のひとこまの、その時に話していた文
    @State private var sampleInfo: [SpeakerLabeler.Sample: Pipeline.SampleInfo] = [:]
    /// 見直したい声のひとこまの数
    @State private var reviewCount = 0
    /// テレビ・動画らしい名前の無い声（名前を付けてほしい声には出さない）
    @State private var broadcast: Set<String> = []
    @State private var confirmForget = false

    /// 名前を付けてほしい声の、はじめに出す数
    private static let waitingShown = 10

    private var others: [SpeakerLabeler.Person] { pipeline.people.filter { !$0.isSelf && $0.hidden != true } }

    /// 名前の無い声のうち、よく話した声（よく話した順。テレビ・動画らしい声は除く）
    private var waiting: [SpeakerLabeler.Person] {
        others.filter { !$0.isNamed && $0.seconds >= 30 && !broadcast.contains($0.id) }.sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        List {
            // 自分の声（声を足す・まとめた人を分け直す）
            if let me = pipeline.people.first(where: \.isSelf) {
                Section {
                    row(me)
                    // 職場では自分の声が「自分」と見分けられていないことが多い（2026-11-10 に数えたら、職場の会話の「自分」の割合は真ん中で 0%）
                    NavigationLink {
                        SelfMergeView(workOnly: true)
                    } label: {
                        Label("職場の会話から自分の声を探す", systemImage: "building.2")
                    }
                } footer: {
                    Text("職場の会話でよく話している名前の無い声を、多い順に出します。▶︎で聞いて、自分の声だったものを選ぶと、自分の声として覚え直します。")
                }
            }
            if reviewCount > 0 {
                Section {
                    NavigationLink {
                        VoiceReviewView()
                    } label: {
                        LabeledContent("声の見直し", value: "\(reviewCount) 個")
                    }
                } footer: {
                    Text("覚えている声のひとこまのうち、記録ではほかの人やテレビの行と重なっているものです。聞いて直すと、聞き分けの間違いが減ります。")
                }
            }
            // 名前の無い声のうち、よく話した声から名前を付けてもらう
            if !waiting.isEmpty {
                Section {
                    ForEach(showAllWaiting ? waiting : Array(waiting.prefix(Self.waitingShown))) { person in row(person) }
                    if waiting.count > Self.waitingShown {
                        Button(showAllWaiting ? "上の \(Self.waitingShown) 人だけ出す" : "ほか \(waiting.count - Self.waitingShown) 人も出す") {
                            showAllWaiting.toggle()
                        }
                    }
                } header: {
                    Text("名前を付けてほしい声")
                } footer: {
                    Text("よく話した順です。声だけで分からないときは、押すと、その声が話したこと・会話の時刻と場所・名前の候補（呼ばれた名前・予定の参加者・声の近い人）が出ます。名前を付けると、これまでの記録とドキュメントの「人物N」もその名前に変わります。")
                }
            }
            let tv = others.filter { broadcast.contains($0.id) }.sorted { $0.seconds > $1.seconds }
            if !tv.isEmpty {
                Section {
                    DisclosureGroup("テレビ・動画らしい声（\(tv.count) 人）") {
                        ForEach(tv) { person in row(person) }
                    }
                    Button("テレビ・動画らしい声をまとめて忘れる", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("名前の無い声のうち、行の7割以上（家で聞いた声は半分以上）が、テレビ・動画の会話や行・背景がテレビや音楽・前後3分に自分が話していない、のどれかの声です。「名前を付けてほしい声」と「人物Nを整理」には出しません。中に知っている人がいれば、押して名前を付けてください。忘れても記録の行はそのままです。")
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
            let hidden = pipeline.people.filter { $0.hidden == true }
            if !hidden.isEmpty {
                Section {
                    ForEach(hidden) { row($0) }
                } header: {
                    Text("記録に出さない声")
                } footer: {
                    Text("この人の声とされた行は、記録にもドキュメントにも書かず、「記録の掃除」の「消した行」に30日間残します。")
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
        .countsOpen("people")
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
        .onAppear { places = pipeline.placeIndex() }
        .task(id: waiting.map(\.id)) {
            clues = await pipeline.voiceClues(for: Set(waiting.map(\.id)), talkLimit: 0,
                                              withCalendar: false, withVoice: false)
        }
        .task(id: pipeline.people.flatMap(\.samples)) {
            sampleInfo = pipeline.sampleInfo(for: pipeline.people.compactMap(\.samples.last))
            reviewCount = pipeline.voiceReview().count
            broadcast = pipeline.broadcastLike()
        }
        .confirmationDialog("テレビ・動画らしい声を \(broadcast.count) 人まとめて忘れますか？", isPresented: $confirmForget,
                            titleVisibility: .visible) {
            Button("忘れる", role: .destructive) {
                Task {
                    _ = await pipeline.forgetBroadcastLike()
                    broadcast = pipeline.broadcastLike()
                }
            }
        } message: {
            Text("名前の無い声だけです。記録とドキュメントの行はそのまま残ります。")
        }
    }

    private func row(_ person: SpeakerLabeler.Person) -> some View {
        HStack {
            if let sample = person.samples.last {
                SampleButton(player: player, sample: sample, key: person.id)
            }
            NavigationLink {
                PersonView(id: person.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent(person.displayName) {
                        Text("\(person.minutes) 分・\(person.lastHeard.formatted(date: .abbreviated, time: .omitted))")
                    }
                    // どこで話した声か（場所の分かる会話から、多い順に3つまで）
                    if let list = places.byPerson[person.id], !list.isEmpty {
                        Text(list.prefix(3).map(\.place).joined(separator: "・"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // ▶︎で鳴る声が、いつ何を話したところか（声だけでは分かりにくいので）
                    if let sample = person.samples.last, let info = sampleInfo[sample] {
                        Text("▶︎「\(info.text)」\(info.caption)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    // 名前の無い声は、呼ばれた名前を添える
                    if let top = clues[person.id]?.candidates.first {
                        Text("もしかして: \(top.name)").font(.caption).foregroundStyle(Color.accentColor)
                    }
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
    @State private var places = Pipeline.PlaceIndex()
    @State private var removingLines = false
    @State private var confirmRemove = false
    @State private var removedMessage: String?
    /// この声が話したことと、名前の候補（声だけでは誰か分かりにくいので）
    @State private var clues = Pipeline.VoiceClues()
    @State private var naming = false
    /// 声のひとこまごとの、その時に話していた文
    @State private var sampleInfo: [SpeakerLabeler.Sample: Pipeline.SampleInfo] = [:]
    @State private var askingMedia = false
    @State private var markingMedia = false
    /// 名前を付けた人を放送の声にするか聞いている（2026-11-09）
    @State private var askingBroadcast = false
    /// 記録と食い違って、聞き分けから外したひとこま（戻せる）
    @State private var aside: [SpeakerLabeler.SetAside] = []
    @State private var asideInfo: [SpeakerLabeler.Sample: Pipeline.SampleInfo] = [:]
    /// （自分の画面）自分の声に近い声を外した人＝自分の行が混ざっていそうな人
    @State private var selfMixed: [Pipeline.SelfMixed] = []

    private var person: SpeakerLabeler.Person? { pipeline.people.first { $0.id == id } }

    private func loadAside() async {
        if id == SpeakerLabeler.selfID { selfMixed = await pipeline.peopleWithSelfVoices() }
        aside = await pipeline.setAsideItems(of: id)
        asideInfo = pipeline.sampleInfo(for: aside.filter(\.hasClip).map(\.sample))
    }

    private static let mergeDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    var body: some View {
        Form {
            // まとめた・消した声を開いたとき、中身が何も無く真っ黒な画面になっていた（2026-11-07）
            if person == nil {
                Section {
                    Text("この声は、もうありません（ほかの人にまとめたか、消した声です）。")
                        .foregroundStyle(.secondary)
                }
            }
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
                    if !person.isNamed && !clues.candidates.isEmpty {
                        Section {
                            ForEach(clues.candidates) { candidate in
                                NameCandidateRow(candidate: candidate) { pick(candidate) }
                                    .disabled(naming)
                            }
                        } header: {
                            Text("名前の候補")
                        } footer: {
                            Text("この声が自分で名乗った名前（「〇〇と申します」など）、「〇〇さん」と呼ばれたすぐあとに話していた名前、その会話の時間のカレンダーの予定の参加者、声の近い人から。下の「この声が話したこと」で確かめてから押してください。名前を付けた人に同じ名前の人がいれば、その人にまとめます。")
                        }
                    }
                    if !person.isSelf {
                        PersonHistorySection(person: person)
                        // 仕事のまとめで、この人の出てくる行（2026-11-10。WorkInsights.swift）
                        if person.isNamed {
                            PersonDigestSection(name: person.displayName)
                        }
                    }
                    if !clues.talks.isEmpty {
                        VoiceTalksSection(talks: clues.talks, player: player)
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
                if let list = places.byPerson[id], !list.isEmpty {
                    Section {
                        ForEach(list.prefix(8), id: \.place) { item in
                            LabeledContent(item.place) {
                                Text("\(item.count) 回・最後 \(item.last.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                    } header: {
                        Text("話した場所")
                    } footer: {
                        Text("この声が出てきた会話の場所（多い順）。「設定」の「場所を記録する」がオンのときの会話だけです。")
                    }
                }
                Section {
                    ForEach(Array(person.samples.enumerated()).reversed(), id: \.offset) { i, sample in
                        HStack {
                            SampleButton(player: player, sample: sample, key: "\(i)")
                            VStack(alignment: .leading, spacing: 2) {
                                // どの声を拾ったか分かるよう、その時に話していた文と、いつ・どこか・記録での名前を出す
                                if let info = sampleInfo[sample] {
                                    Text("「\(info.text)」").lineLimit(3)
                                    Text(info.caption).font(.caption).foregroundStyle(.secondary)
                                    let elsewhere = info.speakers.filter { $0 != person.displayName }
                                    if !elsewhere.isEmpty {
                                        Text("記録では「\(elsewhere.joined(separator: "」「"))」の行（ほかの人の声を拾っているかもしれません）")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                    if !elsewhere.isEmpty || info.media {
                                        NavigationLink("見直す") { VoiceReviewView(only: id) }
                                            .font(.caption)
                                    }
                                } else {
                                    Text("声のひとこま \(person.samples.count - i)")
                                    if let place = places.byAudio[sample.audio] {
                                        Text(place).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
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
                    NavigationLink("ほかの人の声が混ざっている（分ける）") { SplitPersonView(id: id) }
                    if !person.isSelf {
                        NavigationLink("自分の声だった行を探す（自分に直す）") { SelfClaimView(id: id) }
                    }
                } header: {
                    Text("声")
                } footer: {
                    Text("聞き分けを厳しくしても、ほかの人の行がこの人になってしまうときは「ほかの人の声が混ざっている（分ける）」で、行の声を近さで何組にでも分けて聞き比べ、組ごとに分けられます。ひとこまごとに、その時に話していた文と、いつ・どこかを出します（登録で録った声には出ません）。記録で別の名前の行なら、ほかの人の声を拾っているかもしれません。声を足すときは、その人だけが話しているときに録ってください（相手の了承を取ってから）。記録の行を長押しして「話者を直す」と、その行の声も覚えます。")
                }
                if person.isSelf && !selfMixed.isEmpty {
                    Section {
                        ForEach(selfMixed) { entry in
                            NavigationLink {
                                SelfClaimView(id: entry.id)
                            } label: {
                                LabeledContent(pipeline.people.first { $0.id == entry.id }?.displayName ?? "人物\(entry.id)",
                                               value: "自分に近い声 \(entry.count) 個")
                            }
                        }
                    } header: {
                        Text("自分の行が混ざっていそうな人")
                    } footer: {
                        Text("自分の声がこの人の声として覚えられていました（その声は聞き分けから外してあります）。それまでに書いた行には、自分の発言がこの人の名前になっているものがあります。押すと行の声を調べ、自分の声らしい行を▶︎で聞いて確かめてから「自分」に直せます。")
                    }
                }
                if !aside.isEmpty {
                    Section {
                        ForEach(aside) { item in
                            HStack {
                                if item.hasClip {
                                    SampleButton(player: player, sample: item.sample, key: "aside-" + item.id)
                                } else {
                                    // 声の特徴だけを外したもの（聞ける音のひとこまは無い）
                                    Image(systemName: "person.wave.2").foregroundStyle(.secondary).frame(width: 32)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    if item.hasClip {
                                        if let info = asideInfo[item.sample] {
                                            Text("「\(info.text)」").lineLimit(3)
                                            Text(info.caption).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text("記録では\(item.reason)だった").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(item.reason).font(.caption)
                                        Text("\(item.at.formatted(date: .abbreviated, time: .shortened))に外した（聞ける音はありません）")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Button(item.hasClip ? "この人の声だった（戻す）" : "この人の声だった（\(item.voices.count) 個を戻す）") {
                                        Task {
                                            _ = await pipeline.restoreAside(item)
                                            await loadAside()
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    } header: {
                        Text("聞き分けから外した声（\(aside.count)）")
                    } footer: {
                        Text("記録ではほかの人の行やテレビの行と重なっていた声のひとこまは、見直しを待たずに、この人の聞き分けに使わないようにしています。自動で覚えた声のうち、この人の登録・手直しの声より、ほかの人（たいてい自分）の登録・手直しの声にずっと近いものも外します（自分の声がほかの人の声として覚えられ、自分の発言がその人の行になっていたため）。消してはいないので、この人の声だったら戻せます。登録や手直しで覚えた声は外しません。設定の「食い違った声を自動で外す」で止められます。")
                    }
                }
                if !person.isSelf {
                    Section {
                        Toggle("この人の声を記録に出さない", isOn: Binding(
                            get: { person.hidden == true },
                            set: { value in Task { await pipeline.setHidden(id, value) } }))
                        if person.hidden == true {
                            Button(removingLines ? "消しています…" : "これまでの行も記録から消す") { confirmRemove = true }
                                .disabled(removingLines)
                        }
                        if let removedMessage {
                            Text(removedMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("記録に出さない")
                    } footer: {
                        Text("職場のよく通る声など、記録に要らない人に。声で見分けて、その人の行は記録にもドキュメントにも書かず、「記録の掃除」の「消した行」に30日間残します（そこから戻せます）。見分けるのにこの人の声を使い続けるので、声は忘れません。声のひとこまが少ないときは、上の「その場で声を録って足す」か、記録の行の「話者を直す」でこの人を選ぶと見分けやすくなります。")
                    }
                    Section {
                        Button("ほかの人と同じ人としてまとめる") { merging = true }
                        Button("自分の声だった（自分にまとめる）") { mergingSelf = true }
                        if !person.isNamed {
                            Button(markingMedia ? "書き換えています…" : "テレビ・動画・ラジオの声だった") { askingMedia = true }
                                .disabled(markingMedia)
                        } else {
                            Button(markingMedia ? "書き換えています…" : "放送にする（アナウンスの声だった）") { askingBroadcast = true }
                                .disabled(markingMedia)
                        }
                        Button("この声を忘れる", role: .destructive) { deleting = true }
                    } footer: {
                        if !person.isNamed {
                            Text("「テレビ・動画・ラジオの声だった」は、この声の行をすべて「テレビ」などの行に書き換えて、声を忘れます（行は消えず、これからの数にも入りません）。")
                        } else {
                            Text("「放送にする」は、電車や駅・お店のアナウンスなど、人ではない声に名前を付けていたときに。この人の行をすべて「放送」の行に書き換え、この人を消します（行は消えず、話した相手にも数えません）。")
                        }
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
            places = pipeline.placeIndex()
        }
        .task(id: person?.samples ?? []) {
            sampleInfo = pipeline.sampleInfo(for: person?.samples ?? [])
            await loadAside()
        }
        .task(id: person?.name) {
            guard person?.isSelf == false else { return }
            let named = person?.isNamed == true
            clues = await pipeline.voiceClues(for: [id], withCalendar: !named, withVoice: !named)[id] ?? .init()
        }
        .confirmationDialog("この人のこれまでの行を消しますか？", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                removingLines = true
                Task {
                    let count = await pipeline.removeLines(of: id)
                    removedMessage = "\(count) 行を記録とドキュメントから消しました（「消した行」から戻せます）。"
                    removingLines = false
                }
            }
        } message: {
            Text("この人の声とされた行を、アプリの記録とドキュメントから消します。「記録の掃除」の「消した行」に30日間残り、そこから戻せます。")
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
        .confirmationDialog("「\(person?.displayName ?? "")」は何の声でしたか？", isPresented: $askingMedia,
                            titleVisibility: .visible) {
            ForEach(Pipeline.mediaKinds, id: \.self) { kind in
                Button("\(kind)の声だった") {
                    markingMedia = true
                    Task {
                        _ = await pipeline.markPersonAsMedia(id, kind: kind)
                        markingMedia = false
                        dismiss()
                    }
                }
            }
        } message: {
            Text("この声の行をすべて、その種類の行（「テレビ」など）に書き換え、この声を忘れます。行は消えません。")
        }
        .confirmationDialog("「\(person?.displayName ?? "")」を放送にしますか？", isPresented: $askingBroadcast,
                            titleVisibility: .visible) {
            Button("放送にする", role: .destructive) {
                markingMedia = true
                Task {
                    _ = await pipeline.markNamedPersonAsBroadcast(id)
                    markingMedia = false
                    dismiss()
                }
            }
        } message: {
            Text("これまでの行をすべて「放送」の行に書き換え（ドキュメントも直します）、この人を消します。行は消えません。名前と声は戻せないので、人だったときは押さないでください。")
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

    /// 名前の候補を選ぶ。ほかの人にまとめたら、この人はいなくなるので画面を閉じる。
    private func pick(_ candidate: Pipeline.NameCandidate) {
        naming = true
        Task {
            await pipeline.applyName(candidate, to: id)
            naming = false
            if candidate.target != nil {
                dismiss()
            } else {
                name = candidate.name
            }
        }
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
    @State private var places = Pipeline.PlaceIndex()

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
                    ForEach(unnamed) { p in
                        Button { onPick(p.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.displayName)
                                // どこで聞いた声か（名前の無い声を見分ける手がかり）
                                if let list = places.byPerson[p.id], !list.isEmpty {
                                    Text(list.prefix(3).map(\.place).joined(separator: "・"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .tint(.primary)
        .onAppear { places = pipeline.placeIndex() }
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
                    Text("同じ区切りの同じ声").tag(Pipeline.SpeakerFix.sameVoice)
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
        case .sameVoice: "同じ録音の区切り（2〜5分）で、同じ声とされた行をまとめて直します。"
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
    @State private var sampleInfo: [SpeakerLabeler.Sample: Pipeline.SampleInfo] = [:]
    /// 職場の会話でよく話している、名前の無い声だけを出す（2026-11-10）
    var workOnly: Bool = false
    /// 直近14日の職場の会話で、その声が話した行の数（workOnly のとき）
    @State private var workLines: [String: Int] = [:]

    private var others: [SpeakerLabeler.Person] {
        if workOnly {
            return pipeline.people.filter { !$0.isSelf && !$0.isNamed && (workLines[$0.id] ?? 0) > 0 }
                .sorted { (workLines[$0.id] ?? 0) > (workLines[$1.id] ?? 0) }
                .prefix(15).map { $0 }
        }
        return pipeline.people.filter { !$0.isSelf }.sorted { ($0.isNamed ? 1 : 0, $1.lastHeard) < ($1.isNamed ? 1 : 0, $0.lastHeard) }
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
                                    Text("\(person.minutes) 分・\(person.lastHeard.formatted(date: .abbreviated, time: .omitted))"
                                         + (workOnly ? "・職場で \(workLines[person.id] ?? 0) 行" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let sample = person.samples.last, let info = sampleInfo[sample] {
                                        Text("▶︎「\(info.text)」\(info.caption)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
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
        .navigationTitle(workOnly ? "職場の自分の声を探す" : "自分の声をまとめる")
        .onAppear {
            if workOnly { workLines = pipeline.workSpeakerLines() }
            sampleInfo = pipeline.sampleInfo(for: others.compactMap(\.samples.last))
        }
        .onDisappear { player.stop() }
    }
}

/// その日の記録に出てくる「人物N」を、名前のある人にまとめたり、名前を付けたりする。
struct UnnamedVoicesView: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String
    @State private var player = ClipPlayer()
    /// 声ごとの名前の候補（呼ばれた名前・予定の参加者・声の近い人）
    @State private var clues: [String: Pipeline.VoiceClues] = [:]
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

    /// 「この日 12 行・渋谷駅近く、自宅」
    private func dayCaption(_ item: Item) -> String {
        var places: [String] = []
        for c in pipeline.conversations(on: day) where c.lines.contains(where: { $0.speakerID == item.person.id }) {
            if let place = c.place, !places.contains(place) { places.append(place) }
        }
        return "この日 \(item.lines.count) 行" + (places.isEmpty ? "" : "・" + places.joined(separator: "、"))
    }

    /// その日の行に出てくる、名前の無い声と、その行（多い順。テレビ・動画らしい声は除く）
    private var unnamed: [Item] {
        let lines = pipeline.conversations(on: day).flatMap(\.lines)
        let tv = pipeline.broadcastLike()
        return pipeline.people.filter { !$0.isNamed && !tv.contains($0.id) }.compactMap { person in
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
                            Text(dayCaption(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if working == item.person.id {
                        HStack { ProgressView(); Text("直しています…") }
                    } else {
                        ForEach(clues[item.person.id]?.candidates ?? []) { candidate in
                            NameCandidateRow(candidate: candidate) {
                                apply(item.person.id) { await pipeline.applyName(candidate, to: item.person.id) }
                            }
                        }
                        NavigationLink("この声が話したことを見る") { PersonView(id: item.person.id) }
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
        .countsOpen("unnamedVoices")
        .task(id: list.map(\.id)) {
            clues = await pipeline.voiceClues(for: Set(list.map(\.id)), talkLimit: 0)
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

    private func apply(_ id: String, _ action: @escaping () async -> Void) {
        working = id
        Task {
            await action()
            clues[id] = nil
            working = nil
        }
    }
}

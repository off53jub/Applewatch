import SwiftUI

// s31（2026-11-27）文字と声を結ぶ（S31A）の画面。決まりは S31ARules.swift、取り方は S31ABook.swift。
// - 仕事タブの項目の行（柱の中・今日の一手・相手待ち・根拠の一覧）に、voice があれば小さな「声」のしるし（S31AVoiceMark）。
//   押すと「声ではこう」のシート（発言・話した人・時刻・この会話を開く・声を聞く）
// - 人のページに「チャット・LINE と声」の節（S31APersonSection。/links?person=）
// - 記録の日の画面に「この日の文字と声」（S31ADaySection。/links?day=。畳んである）
// 会話を開くのは今ある会話の画面（ConversationsView をその会話の時刻で）、声を聞くのは今ある ClipPlayer。
// 結びは候補なので、強さを言葉（たぶん・おそらく）で添える。仕事の結び（work）は仕事タブの伏せる切り替えに従う。
// 知らせ・問いは足さない。

@MainActor private func s31aMask(_ text: String, work: Bool) -> String {
    work ? S27WBook.shared.t(text) : text
}

// MARK: - 仕事の項目の「声」のしるし

/// voice があるときだけ出る小さなしるし（波形・話した人・時刻）。押すと「声ではこう」
struct S31AVoiceMark: View {
    let item: S27WItem
    @State private var showing = false

    var body: some View {
        if let refs = item.voice, let first = refs.first {
            let who: String = S27WBook.shared.t(S31ARules.whoLine(first.who))
            let when: String = S31ARules.when(first.start)
            let label: String = S31ARules.markLine(who: who, when: when, more: refs.count - 1)
            Button {
                showing = true
                Tally.add("s31a.voice.open")
            } label: {
                HStack(spacing: LL.Space.xs) {
                    Image(systemName: "waveform")
                    Text(label).lineLimit(1)
                }
                .font(LL.TypeScale.note)
                .foregroundStyle(LL.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("声でも話していた候補。" + who + " " + when)
            .accessibilityHint("声ではどう話していたかを開きます")
            .sheet(isPresented: $showing) {
                S31AVoiceSheet(refs: refs, scores: refs.map { S31ABook.shared.link($0.link)?.score },
                               textLine: item.text, work: true)
            }
        }
    }
}

// MARK: - 「声ではこう」のシート

struct S31AVoiceSheet: View {
    let refs: [S31AVoiceRef]
    /// refs と同じ並び（分からないものは nil）
    var scores: [Double?] = []
    /// 文字の側（Teams・LINE・項目の文）
    var textLine: String? = nil
    var textSource: String? = nil
    var why: String? = nil
    var work = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LLList {
                if let textLine, !textLine.isEmpty {
                    Section {
                        Text(s31aMask(textLine, work: work)).font(LL.TypeScale.detail).foregroundStyle(LL.text)
                        if let textSource, !textSource.isEmpty {
                            Text(s31aMask(textSource, work: work)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                        }
                    } header: {
                        LLHeader(title: "文字では", symbol: "text.bubble")
                    }
                }
                ForEach(Array(refs.enumerated()), id: \.offset) { n, ref in
                    S31AVoiceRefSection(ref: ref, score: n < scores.count ? scores[n] : nil, why: n == 0 ? why : nil,
                                        work: work, first: n == 0)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("文字と声は、話題の言葉・時刻・人から機械が結んだ候補です。記録と人の帳は書き換えていません。")
                }
            }
            .navigationTitle("声ではこう")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct S31AVoiceRefSection: View {
    let ref: S31AVoiceRef
    let score: Double?
    let why: String?
    let work: Bool
    let first: Bool

    var body: some View {
        Section {
            if let say = ref.say {
                Text("「" + s31aMask(say, work: work) + "」").font(LL.TypeScale.body).foregroundStyle(LL.text)
            }
            LabeledContent("話した人", value: s31aMask(S31ARules.whoLine(ref.who), work: work))
            let when: String = S31ARules.when(ref.start)
            if !when.isEmpty {
                LabeledContent("時刻", value: when)
            }
            Label(S31ARules.strength(score), systemImage: "link")
                .font(LL.TypeScale.note)
                .foregroundStyle(LL.dim)
            if let why, !why.isEmpty {
                Text("結んだわけ: " + s31aMask(why, work: work)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            S31AOpenRows(start: ref.start)
        } header: {
            if first { LLHeader(title: "声では", symbol: "waveform") }
        }
    }
}

/// 「この会話を開く」と「声を聞く」。この iPhone の記録にその時刻の会話が無ければ時刻だけ
private struct S31AOpenRows: View {
    @Environment(Pipeline.self) private var pipeline
    let start: String?
    @State private var player = ClipPlayer()
    @State private var found: Found?
    @State private var looked = false

    struct Found: Equatable {
        var day: String
        var range: ClosedRange<Date>
        var audio: String?
        var offset: TimeInterval
    }

    var body: some View {
        let moment: S31AMoment? = S31ARules.moment(start)
        Group {
            if let found {
                NavigationLink {
                    ConversationsView(day: found.day, range: found.range)
                        .navigationTitle(S31ARules.when(start))
                        .navigationBarTitleDisplayMode(.inline)
                        .onAppear { Tally.add("s31a.conv.open") }
                } label: {
                    Label("この会話を開く", systemImage: "bubble.left.and.text.bubble.right")
                }
                if let audio = found.audio {
                    let key: String = "s31a-" + (start ?? "")
                    Button {
                        Tally.add("s31a.play")
                        Task {
                            let from = max(0, found.offset - 2)
                            await player.toggle(key, at: from, until: from + 20) {
                                await pipeline.archive.playableURL(for: audio)
                            }
                        }
                    } label: {
                        if player.loading == key {
                            ProgressView()
                        } else {
                            Label(player.playing == key ? "止める" : "声を聞く",
                                  systemImage: player.playing == key ? "stop.circle.fill" : "play.circle")
                        }
                    }
                    .buttonStyle(.borderless)
                }
            } else if !looked {
                Text("この iPhone の記録を探しています…")
                    .font(LL.TypeScale.note)
                    .foregroundStyle(LL.dim)
            } else if moment != nil {
                Text("この iPhone の記録には、この時刻の会話がありません（家の PC の記録にだけあるのかもしれません）。")
                    .font(LL.TypeScale.note)
                    .foregroundStyle(LL.dim)
            }
        }
        .task(id: start) { look(moment) }
        .onDisappear { player.stop() }
    }

    private func look(_ moment: S31AMoment?) {
        defer { looked = true }
        guard let moment else { return }
        let talks: [ConversationLog.Conversation] = pipeline.conversations(on: moment.day)
        var spans: [(start: Date, end: Date)] = []
        for t in talks { spans.append((start: t.start, end: t.end)) }
        guard let i = S31ARules.conversationIndex(spans, at: moment.time) else { return }
        let talk = talks[i]
        var rows: [(Date, Int)] = []
        for (n, line) in talk.lines.enumerated() {
            if let audio = line.audio, pipeline.archive.canPlay(audio) { rows.append((line.time, n)) }
        }
        let near: Int? = S31ARules.nearest(rows, to: moment.time)
        let line: ConversationLog.Line? = near.map { talk.lines[$0] }
        found = Found(day: moment.day, range: talk.start...talk.start, audio: line?.audio, offset: line?.offset ?? 0)
    }
}

// MARK: - 文字 → 声 の 1 組

struct S31APairRow: View {
    let link: S31ALink
    @State private var showing = false

    var body: some View {
        let work: Bool = link.isWork
        let voice: S31AVoiceRef = link.voice.firstRef
        let when: String = S31ARules.when(voice.start)
        Button {
            showing = true
            Tally.add("s31a.pair.open")
        } label: {
            VStack(alignment: .leading, spacing: LL.Space.xs) {
                Label(s31aMask(S31ARules.source(link.text), work: work),
                      systemImage: link.text.src.lowercased() == "line" ? "message" : "text.bubble")
                    .font(LL.TypeScale.note)
                    .foregroundStyle(LL.dim)
                Text("「" + s31aMask(link.text.quote, work: work) + "」")
                    .font(LL.TypeScale.detail)
                    .foregroundStyle(LL.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(alignment: .firstTextBaseline, spacing: LL.Space.xs) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(LL.accent)
                    Image(systemName: "waveform").foregroundStyle(LL.accent)
                    Text(s31aMask(S31ARules.whoLine(voice.who), work: work) + (when.isEmpty ? "" : "・" + when))
                        .foregroundStyle(LL.dim)
                }
                .font(LL.TypeScale.note)
                if let say = voice.say {
                    Text("「" + s31aMask(say, work: work) + "」")
                        .font(LL.TypeScale.detail)
                        .foregroundStyle(LL.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(S31ARules.strength(link.score)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("声ではどう話していたかを開きます")
        .sheet(isPresented: $showing) {
            S31AVoiceSheet(refs: [voice], scores: [link.score], textLine: link.text.quote,
                           textSource: S31ARules.source(link.text), why: link.why, work: work)
        }
    }
}

// MARK: - 人のページ「チャット・LINE と声」

struct S31APersonSection: View {
    let name: String
    var personID: String? = nil

    var body: some View {
        let book = S31ABook.shared
        if book.offered, let set = book.person(name), !set.isEmpty {
            let summary: String? = S31ARules.person(set, name: name, id: personID)?.summary
            let days: [S31ADay] = S31ARules.byDay(set.links)
            Section {
                if let summary {
                    Text(summary).font(LL.TypeScale.detail).foregroundStyle(LL.text)
                }
                ForEach(days) { day in
                    Text(AppFeeds.monthDay(day.day))
                        .font(LL.TypeScale.tag)
                        .foregroundStyle(LL.dim)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.links) { link in S31APairRow(link: link) }
                }
            } header: {
                LLHeader(title: "チャット・LINE と声", symbol: "link", trailing: "\(set.links.count) 組")
            } footer: {
                Text("チャット（Teams）・LINE の文と、同じ話を声でもしていた所を、機械が結んだ候補です。押すとその会話を開きます。")
            }
        }
    }
}

// MARK: - 記録の日の画面「この日の文字と声」

struct S31ADaySection: View {
    let day: String
    @State private var open = false

    var body: some View {
        let book = S31ABook.shared
        if book.offered, let set = book.day(day), !set.isEmpty {
            let links: [S31ALink] = S31ARules.byDay(set.links).first?.links ?? []
            Section {
                DisclosureGroup(isExpanded: $open) {
                    ForEach(links) { link in S31APairRow(link: link) }
                } label: {
                    Label("この日の文字と声（\(links.count) 組）", systemImage: "link")
                        .font(LL.TypeScale.detail)
                        .foregroundStyle(LL.text)
                }
            }
        }
    }
}

// MARK: - 読みに行く（画面を開いたとき）

/// 人のページ・日の画面を開いたとき、/links を読む（features に links があるときだけ）
struct S31ALoad: ViewModifier {
    @Environment(Pipeline.self) private var pipeline
    var person: String? = nil
    var day: String? = nil

    func body(content: Content) -> some View {
        content
            .task(id: (person ?? "") + "|" + (day ?? "")) {
                if let person { await S31ABook.shared.load(person: person, pc: pipeline.homePC) }
                if let day { await S31ABook.shared.load(day: day, pc: pipeline.homePC) }
            }
    }
}

import SwiftUI
import UIKit

// s25（2026-11-24）の A1 の画面。決まりは S25TRules.swift、動きは S25TBook.swift。
// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 14」「追記 15」。

// MARK: - 大8 下書きの棚（タスクの「やる」の上）

struct S25TDraftShelfSection: View {
    @State private var sharing: S25TDraft?
    @State private var editing: S25TDraft?
    @State private var editText = ""
    @State private var copied: String?

    var body: some View {
        let book = S25TDraftBook.shared
        let list = book.shelf()
        if !list.isEmpty {
            Section {
                ForEach(list) { draft in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(S25TDrafts.kindLabel(draft.kind)).font(.caption.bold()).foregroundStyle(LL.accent)
                            Text(draft.title).font(.callout.bold())
                        }
                        if let to = draft.to { Text("宛先: " + to).font(.caption).foregroundStyle(LL.dim) }
                        if let when = draft.when { Text("日時: " + when).font(.caption).foregroundStyle(LL.dim) }
                        Text(draft.body).font(.callout).lineLimit(8)
                        if let evidence = draft.evidence { Text("もと: " + evidence).font(.caption2).foregroundStyle(LL.dim) }
                        if S25TDrafts.isCalendarFix(draft) {
                            // 家の PC が Google カレンダーを直す（押したときだけ）。「反映」= sent・「そのまま」= dropped
                            HStack(spacing: 10) {
                                Button("カレンダーに反映") { withAnimation { book.answer(draft, action: "sent") } }
                                    .buttonStyle(LLPillButtonStyle(filled: true))
                                Button("そのまま") { withAnimation { book.answer(draft, action: "dropped") } }
                                    .buttonStyle(LLPillButtonStyle(tint: LL.dim))
                            }
                        } else {
                        HStack(spacing: 10) {
                            Button("送る") { sharing = draft }
                                .buttonStyle(LLPillButtonStyle(filled: true))
                            Button("コピー") {
                                UIPasteboard.general.string = S25TDrafts.shareText(draft)
                                book.answer(draft, action: "sent")
                                copied = draft.title
                            }
                            .buttonStyle(LLPillButtonStyle())
                            Button("直す") {
                                editText = draft.body
                                editing = draft
                            }
                            .buttonStyle(LLPillButtonStyle())
                            Button("捨てる") { withAnimation { book.answer(draft, action: "dropped") } }
                                .buttonStyle(LLPillButtonStyle(tint: LL.dim))
                        }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let copied {
                    Text("「" + copied + "」をコピーしました。送る先に貼ってください。").font(.caption).foregroundStyle(LL.dim)
                }
            } header: {
                LLHeader(title: "下書き", symbol: "square.and.pencil")
            } footer: {
                Text("家の PC が 8 割まで書いた下書きです（いまは旅行の精算など）。「送る」「コピー」「直す」「捨てる」を押すまで、どこへも出ません。送る先は共有のシート（LINE・メールなど）で自分で選びます。")
            }
            .sheet(item: $sharing) { draft in
                S25TActivitySheet(items: [S25TDrafts.shareText(draft)]) { done in
                    if done { book.answer(draft, action: "sent") }
                    sharing = nil
                }
            }
            .sheet(item: $editing) { draft in
                NavigationStack {
                    TextEditor(text: $editText)
                        .padding(.horizontal)
                        .navigationTitle(draft.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("やめる") { editing = nil } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("これにする") {
                                    book.answer(draft, action: "edited", edited: editText)
                                    editing = nil
                                }
                                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                }
            }
        }
    }
}

/// 共有のシート（送り終えたかを返す）
struct S25TActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in onDone(completed) }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 連6 共有で受けた LINE のトーク履歴

struct S25TRootModifier: ViewModifier {
    let pipeline: Pipeline

    func body(content: Content) -> some View {
        let box = S25TShareBox.shared
        content.sheet(item: Binding(get: { box.pending }, set: { if $0 == nil { box.close() } })) { pending in
            S25TShareSheet(pending: pending, pipeline: pipeline)
        }
    }
}

extension View {
    func s25tRoot(_ pipeline: Pipeline) -> some View { modifier(S25TRootModifier(pipeline: pipeline)) }
}

private struct S25TShareSheet: View {
    let pending: S25TShareBox.Pending
    let pipeline: Pipeline

    var body: some View {
        let box = S25TShareBox.shared
        NavigationStack {
            LLForm {
                if !pending.text.isEmpty {
                    Section {
                        LabeledContent("相手", value: pending.name)
                        LabeledContent("大きさ", value: ByteCountFormatter.string(fromByteCount: Int64(pending.bytes), countStyle: .file))
                        if pending.cut {
                            Text("1 MB を超えたので、古い方を省いて新しい方を送ります。").font(.caption).foregroundStyle(LL.warn)
                        }
                        if !pending.looksLine {
                            Text("LINE の書き出しの形ではないようです。そのまま送れます。").font(.caption).foregroundStyle(LL.dim)
                        }
                        Button(box.sending ? "送っています…" : "家の PC へ送る") { Task { await box.send(pipeline) } }
                            .disabled(box.sending)
                    } footer: {
                        Text("LINE の「トーク履歴を送信」で選んだ分を、家の PC から母艦の LINE の取り込みへ渡します。会う直前に、その人との LINE を入れたいときに。送るまでは、どこにも出ません。")
                    }
                }
                if let result = box.result {
                    Section { Text(result) }
                }
            }
            .navigationTitle("LINE を入れる")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(box.result == nil ? "やめる" : "閉じる") { box.close() }
                }
            }
        }
    }
}

// MARK: - 活5 探すの窓から家の PC の記録を引く

struct S25TMotherSearchSection: View {
    @Environment(Pipeline.self) private var pipeline
    let query: String
    @State private var outcome: S25TSearchOutcome?
    @State private var searched = ""
    @State private var working = false

    var body: some View {
        Section {
            Button(working ? "探しています…" : "「\(query)」を家の PC の記録からも探す", systemImage: "desktopcomputer") { run() }
                .disabled(working || query.count < 2)
            if searched == query, let outcome {
                switch outcome {
                case .hits(let hits):
                    if hits.isEmpty {
                        Text("家の PC の記録には見つかりませんでした").font(.callout).foregroundStyle(LL.dim)
                    }
                    ForEach(hits) { S25THitRow(hit: $0) }
                case .notYet:
                    Text("家の PC がまだこの探し方に対応していません。上の「記録に質問する」なら、家の PC の記録も探せます（Claude を使います）。")
                        .font(.caption).foregroundStyle(LL.dim)
                case .failed(let why):
                    Text("探せませんでした" + (why.isEmpty ? "" : ": " + why)).font(.caption).foregroundStyle(LL.dim)
                }
            }
        } header: {
            LLHeader(title: "家の PC の記録", symbol: "desktopcomputer")
        } footer: {
            Text("母艦の LINE・PLAUD・1 日のまとめなどを言葉で探します（Claude には頼みません）。押したときだけ探します。")
        }
    }

    private func run() {
        let q = query
        working = true
        Task {
            outcome = await pipeline.s25tSearch(q)
            searched = q
            working = false
        }
    }
}

struct S25THitRow: View {
    let hit: S25TSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.label + "・" + AppFeeds.monthDay(hit.day) + (hit.time.isEmpty ? "" : " " + hit.time))
                .font(.caption).foregroundStyle(LL.dim)
            Text(hit.text).font(.callout).lineLimit(4)
        }
    }
}

// MARK: - 活7 話した相手に、会話と LINE を同じ時系列で

struct S25TPersonTimelineSection: View {
    @Environment(Pipeline.self) private var pipeline
    let person: SpeakerLabeler.Person
    @State private var rows: [S25TTimelineRow] = []
    @State private var note: String?
    @State private var loaded = false
    @State private var showAll = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Section {
            if !loaded {
                HStack { ProgressView(); Text("並べています…").foregroundStyle(LL.dim) }
            } else if rows.isEmpty {
                Text("まだありません").foregroundStyle(LL.dim)
            }
            ForEach(showAll ? rows : Array(rows.prefix(10))) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.kind == .line ? "message" : "waveform")
                        .foregroundStyle(row.kind == .line ? LL.accent : LL.dim)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((row.kind == .line ? "LINE・" : "会話・") + AppFeeds.monthDay(row.day) + (row.time.isEmpty ? "" : " " + row.time))
                            .font(.caption).foregroundStyle(LL.dim)
                        Text(row.text).font(.callout).lineLimit(3)
                    }
                }
            }
            if rows.count > 10 && !showAll {
                Button("ほか \(rows.count - 10) 件も出す") { showAll = true }
            }
            if let note { Text(note).font(.caption).foregroundStyle(LL.dim) }
        } header: {
            Text("会話と LINE（新しい順）")
        } footer: {
            Text("この人と話した会話（iPhone の記録）と、LINE（家の PC の母艦から）を 1 本に並べます。")
        }
        .task(id: person.id) { await load() }
    }

    private func load() async {
        let name = person.displayName
        let talks = pipeline.history(of: person).map { entry in
            (day: entry.day, time: Self.clock.string(from: entry.conversation.start),
             text: entry.conversation.title ?? entry.conversation.points.first ?? "（見出しなし）")
        }
        var line: [S25TSearchHit] = []
        switch await pipeline.s25tSearch(name, person: name, sources: ["line"], days: 60) {
        case .hits(let hits):
            line = hits.filter { $0.source == "line" || $0.source.isEmpty }
            note = nil
        case .notYet:
            // 家の PC に 1 通ずつ引く口がまだ無い: 人のページの数と、最後の LINE の要点だけ
            if let page = PagesBook.shared.page(named: name) {
                if let last = page.last_talk, last.source == "line" {
                    line = [S25TSearchHit(id: "page", source: "line", day: last.day, time: "", label: "LINE", text: last.summary)]
                }
                if page.line_30d > 0 {
                    note = "LINE は 30 日で \(page.line_30d) 通" + (page.last_line.map { "（最後 " + AppFeeds.monthDay($0) + "）" } ?? "")
                        + "。1 通ずつ並べるのは、家の PC が対応してからです。"
                }
            }
        case .failed:
            note = "家の PC につながらないので、LINE は並べていません。"
        }
        rows = S25TTimeline.merge(talks: talks, line: line)
        loaded = true
    }
}

// MARK: - 大9 この声は誰？（今日の 1 問の、ほかに聞くことが無いとき）

struct S25TVoiceAskRow: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var version = 0

    var body: some View {
        let candidates = pipeline.people.map { p in
            S25TVoiceCandidate(id: p.id, named: p.isNamed, isSelf: p.isSelf, hidden: p.hidden == true, seconds: p.seconds,
                               lastHeard: p.lastHeard, hasSample: !p.samples.isEmpty)
        }
        let counts = S24Gate.counts()
        let pick = S24Book.quietNow() ? nil
            : S25TVoice.pick(candidates, asked: counts.asked, cap: S24AskSettings.questionCap, skipped: S25TVoiceAskBook.skipped(), now: .now)
        Group {
            if let id = pick, let person = pipeline.people.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink {
                        PersonView(id: id)
                            .onAppear {
                                S24Gate.noteAnswered(key: "voice:" + id)
                                Tally.add("s25t.voiceAsk.open")
                            }
                    } label: {
                        S24RoleLabel(text: "この声は誰？（\(max(1, person.minutes)) 分ほど話した、名前の無い声）", role: .ask).font(.callout)
                    }
                    Button("今日はいい") {
                        S25TVoiceAskBook.skip(id)
                        version += 1
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .onAppear { Tally.add("s25t.voiceAsk.shown") }
            } else {
                Label {
                    Text(S24Today.noneText).foregroundStyle(LL.dim)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(LL.dim)
                }
                .accessibilityLabel(S24Today.noneText)
            }
        }
        .id(version)
    }
}

// MARK: - 大9 会ったその場で 1 タップで声を登録（次の予定の前に）

struct S25TMeetVoiceRows: View {
    @Environment(Pipeline.self) private var pipeline
    let names: [String]

    var body: some View {
        // 声をまだ登録していない相手だけ（2 人まで）
        let people = pipeline.people.filter { !$0.isSelf }
        let lacking = names.filter { name in
            guard let id = S25TVoice.target(name: name, people: people.map { (id: $0.id, name: $0.name) }),
                  let p = people.first(where: { $0.id == id }) else { return true }
            return p.pinnedCount == 0
        }
        ForEach(Array(lacking.prefix(2)), id: \.self) { name in
            VoiceCapture(seconds: 15, title: name + "さんの声をいま登録する（15 秒）") { url in
                await register(name, url)
            }
            .font(.callout)
        }
    }

    private func register(_ name: String, _ url: URL) async -> String {
        let people = pipeline.people.filter { !$0.isSelf }.map { (id: $0.id, name: $0.name) }
        do {
            if let id = S25TVoice.target(name: name, people: people) {
                try await pipeline.addVoice(from: url, to: id)
                Tally.add("s25t.meetVoice.added")
                return name + "さんの声を足しました。"
            }
            try await pipeline.registerPerson(from: url, name: name, context: nil)
            Tally.add("s25t.meetVoice.new")
            return name + "さんを声で登録しました。"
        } catch {
            return "登録できませんでした: " + error.localizedDescription
        }
    }
}

import MapKit
import SwiftUI

// s23（2026-11-23）の画面。決まりは S23Rules.swift、動きは S23Notices.swift。
// 色・形は DesignKit・LLTheme の部品を使うだけ。文は短く、やさしく。

// MARK: - アプリの根に付ける（知らせを押したあとの画面）

extension View {
    /// 知らせから開く s23 の画面（S23Present.shared.sheet）
    func s23Root(_ pipeline: Pipeline) -> some View { modifier(S23RootModifier(pipeline: pipeline)) }
}

private struct S23RootModifier: ViewModifier {
    let pipeline: Pipeline
    @State private var present = S23Present.shared

    func body(content: Content) -> some View {
        content.sheet(item: $present.sheet) { sheet in
            NavigationStack {
                S23SheetView(sheet: sheet)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("閉じる") { present.sheet = nil } }
                    }
            }
            .environment(pipeline)
            .llRoot()
        }
    }
}

struct S23SheetView: View {
    let sheet: S23Sheet

    var body: some View {
        content
            .onAppear { S23Present.shared.shown(sheet) }
            .onDisappear { S23Present.shared.closed(sheet) }
    }

    @ViewBuilder
    private var content: some View {
        switch sheet.kind {
        case .who(let key): S23WhoView(key: key)
        case .knowMe(let id, let kind, let day, let text): S23KnowMeView(id: id, kind: kind, day: day, text: text)
        case .review(let id, let fallback): S23ReviewView(id: id, fallback: fallback)
        case .note(let title, let info): S23NoteView(title: title, info: info)
        case .tasks(let ids): S23TasksView(ids: ids)
        case .promises(let ids): S23PromisesView(ids: ids)
        case .status(let id): S23StatusView(id: id)
        case .headcount(let start, let day): S23HeadcountView(start: start, day: day)
        case .placesNight: S23PlacesNightView()
        case .checklist: ChecklistView()
        case .missed: S23MissedView()
        }
    }
}

/// 答えたあとの 1 行（知14）
private struct S23AfterLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(LL.good)
    }
}

// MARK: - 知2 誰と話しましたか

struct S23WhoView: View {
    @Environment(Pipeline.self) private var pipeline
    let key: String
    @State private var talk: ConversationLog.Conversation?
    @State private var loaded = false
    @State private var typed: [String: String] = [:]
    @State private var done: [String: String] = [:]
    @State private var busy = false

    var body: some View {
        LLList {
            if let talk {
                Section {
                    Text(talk.title ?? "会話").font(.headline)
                    Text(talk.start.formatted(date: .omitted, time: .shortened) + "〜" + talk.end.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(LL.dim)
                } header: {
                    LLHeader(title: "この会話", symbol: "waveform")
                }
                let voices = unnamed(talk)
                if voices.isEmpty {
                    Section { Text("名前の無い声は、もうありません。").foregroundStyle(LL.dim) }
                }
                ForEach(voices, id: \.self) { sid in
                    Section {
                        ForEach(Array(talk.lines.filter { $0.speakerID == sid }.prefix(2).enumerated()), id: \.offset) { _, line in
                            Text("「" + String(line.text.prefix(60)) + "」").font(.callout).foregroundStyle(LL.dim)
                        }
                        if let name = done[sid] {
                            S23AfterLine(text: S23AfterRules.who(name))
                        } else {
                            FlowLayout(spacing: LL.Space.s) {
                                ForEach(candidates, id: \.id) { person in
                                    Button(person.displayName) { merge(sid, into: person.id, name: person.displayName) }
                                        .buttonStyle(LLPillButtonStyle())
                                        .disabled(busy)
                                }
                            }
                            HStack {
                                TextField("名前を書く", text: Binding(get: { typed[sid] ?? "" }, set: { typed[sid] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                Button("付ける") { rename(sid) }
                                    .buttonStyle(LLPillButtonStyle(filled: true))
                                    .disabled(busy || (typed[sid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    } header: {
                        Text(pipeline.people.first { $0.id == sid }?.displayName ?? "名前の無い声")
                    } footer: {
                        Text("候補は、最近話した名前のある人です。違う人なら、名前を書いてください。")
                    }
                }
            } else if loaded {
                Section {
                    LLEmpty(title: "この会話が見つかりません", symbol: "questionmark.circle",
                            detail: "消したか、同期で入れ替わったのかもしれません。「直す」で声に名前を付けられます。")
                    Button("「直す」を開く") {
                        pipeline.openRoute(.tab(.fix))
                        S23Present.shared.sheet = nil
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("誰と話しましたか？")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s23Who")
        .task { load() }
    }

    private var candidates: [SpeakerLabeler.Person] {
        Array(pipeline.people.filter { $0.isNamed && !$0.isSelf && $0.hidden != true }.sorted { $0.lastHeard > $1.lastHeard }.prefix(5))
    }

    private func unnamed(_ talk: ConversationLog.Conversation) -> [String] {
        let names = Set(pipeline.people.filter { !$0.isNamed }.map(\.id))
        var out: [String] = []
        for line in talk.lines {
            guard let sid = line.speakerID, names.contains(sid) || done[sid] != nil, !out.contains(sid) else { continue }
            out.append(sid)
        }
        return out
    }

    private func load() {
        guard let start = Double(key) else {
            loaded = true
            return
        }
        let date = Date(timeIntervalSince1970: start)
        talk = pipeline.conversations(on: ReviewRules.dayKey(date)).first { Int($0.start.timeIntervalSince1970) == Int(start) }
        loaded = true
    }

    private func merge(_ sid: String, into target: String, name: String) {
        busy = true
        Task {
            await pipeline.mergePerson(sid, into: target)
            done[sid] = name
            busy = false
            S23Present.shared.markAnswered()
        }
    }

    private func rename(_ sid: String) {
        let name = (typed[sid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true
        Task {
            await pipeline.renamePerson(sid, to: name)
            done[sid] = name
            busy = false
            S23Present.shared.markAnswered()
        }
    }
}

// MARK: - 知4 自分を知るの 1 問

struct S23KnowMeView: View {
    let id: String
    let kind: String
    let day: String?
    let text: String
    @State private var after: String?

    var body: some View {
        LLList {
            Section {
                Text(question).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let after {
                    S23AfterLine(text: after)
                } else {
                    HStack(spacing: LL.Space.m) {
                        Button { answer(KnowMeRules.noAction, "no") } label: {
                            Label("いいえ", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LLPillButtonStyle(tint: LL.danger))
                        Button { answer(KnowMeRules.yesAction, "yes") } label: {
                            Label("はい", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LLPillButtonStyle(tint: LL.good, filled: true))
                    }
                    Button("分からない") { answer(KnowMeRules.unsureAction, "unsure") }
                        .buttonStyle(LLPillButtonStyle(tint: LL.dim))
                }
            } header: {
                LLHeader(title: kind == "spot" ? "合ってる？（抜き打ち）" : "見立て（仮）", symbol: "person.crop.circle.badge.questionmark")
            } footer: {
                Text("答えは家の PC を通して残ります。")
            }
        }
        .navigationTitle("自分を知る")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 知らせの文から、足した「押すと…」の行を外す
    private var question: String {
        text.components(separatedBy: "\n").filter { !$0.hasPrefix("押すと") }.joined(separator: "\n")
    }

    private func answer(_ action: String, _ value: String) {
        var info: [AnyHashable: Any] = ["kid": id, "kkind": kind]
        if let day { info["kday"] = day }
        let sendable = info
        Task { await KnowMeBook.shared.noticeAnswered(actionID: action, userInfo: sendable) }
        LLHaptic.done.play()
        S23Present.shared.markAnswered()
        after = S23AfterRules.knowMe(value)
    }
}

// MARK: - 知6 確かめ待ちの 1 問

struct S23ReviewView: View {
    @Environment(Pipeline.self) private var pipeline
    let id: String
    let fallback: String
    @State private var after: String?
    @State private var text = ""

    var body: some View {
        let item = S20Book.shared.review?.items?.first { $0.id == id }
        LLList {
            Section {
                Text(item?.question ?? fallbackQuestion).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                // 声を聞いて答える（voice_pair は 2 つとも聞ける）
                if let clips = item?.clips, !clips.isEmpty {
                    ClipChooser(clips: clips)
                }
                if let evidence = item?.evidence, !evidence.isEmpty {
                    ForEach(Array(evidence.prefix(3).enumerated()), id: \.offset) { _, e in
                        Text(e.text).font(.callout).foregroundStyle(LL.dim)
                    }
                }
                if let after {
                    S23AfterLine(text: after)
                } else if S20Book.shared.answered[id] != nil {
                    Text("この問いは、もう答えてあります。").foregroundStyle(LL.dim)
                } else {
                    buttons(item)
                }
            } header: {
                LLHeader(title: item.map { ReviewRules.kindLabel($0.kind) } ?? "確かめ待ち", symbol: "hand.raised")
            }
        }
        .navigationTitle("確かめ待ち")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var fallbackQuestion: String {
        let lines = fallback.components(separatedBy: "\n").filter { !$0.hasPrefix("押すと") && !$0.contains("長押し") }
        return lines.isEmpty ? "この問いは、もう一覧にありません。" : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func buttons(_ item: ReviewItem?) -> some View {
        let style = item.map { S22Rules.answerStyle(answer: $0.answer, choices: $0.choices) } ?? "yesno"
        if style == "pick", let item {
            FlowLayout(spacing: LL.Space.s) {
                ForEach(item.choices ?? [], id: \.self) { choice in
                    Button(choice) { answerOther(item, choice) }.buttonStyle(LLPillButtonStyle())
                }
            }
        } else if style == "text", let item {
            HStack {
                TextField(S23ReviewRules.placeholder(kind: item.kind), text: $text).textFieldStyle(.roundedBorder)
                Button("送る") {
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { answerOther(item, value) }
                }
                .buttonStyle(LLPillButtonStyle(filled: true))
            }
            if S23ReviewRules.keepAsIs(kind: item.kind) {
                Button("そのまま（合っている）") { answerOther(item, S23ReviewRules.keepValue) }
                    .buttonStyle(LLPillButtonStyle(tint: LL.good))
            }
        } else {
            HStack(spacing: LL.Space.m) {
                Button { answerYesNo("no") } label: { Label("いいえ", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(LLPillButtonStyle(tint: LL.danger))
                Button { answerYesNo("yes") } label: { Label("はい", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(LLPillButtonStyle(tint: LL.good, filled: true))
            }
        }
        HStack {
            Button("分からない") { answerYesNo("unsure") }.buttonStyle(LLPillButtonStyle(tint: LL.dim))
            Spacer()
            if let item {
                Button("あとで") {
                    S20Book.shared.postpone(item)
                    after = "あとで（明日また出ます）"
                }
                .buttonStyle(LLPillButtonStyle(tint: LL.dim))
            }
        }
    }

    private func answerYesNo(_ value: String) {
        S22Book.answerReview(id: id, value: value, from: "sheet")
        finish()
    }

    private func answerOther(_ item: ReviewItem, _ value: String) {
        S20Book.shared.answer(item, value)
        let pc = pipeline.homePC
        Task { await MothershipOutbox.send(pc) }
        finish()
    }

    private func finish() {
        LLHaptic.done.play()
        S23Present.shared.markAnswered()
        after = S23AfterRules.review(changed: S20Book.shared.done(for: id)?.changed)
    }
}

// MARK: - 休日の一言（押しただけのとき）

struct S23NoteView: View {
    let title: String
    let info: [String: S23InfoValue]
    @State private var text = ""
    @State private var after: String?
    @FocusState private var focused: Bool

    var body: some View {
        LLList {
            Section {
                Text(title).font(.headline)
                if let after {
                    S23AfterLine(text: after)
                } else {
                    TextField("一言", text: $text, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...4)
                    Button("残す") { save() }
                        .buttonStyle(LLPillButtonStyle(filled: true))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("この iPhone と、ドライブのその日のファイルにだけ書きます。")
            }
        }
        .navigationTitle("一言")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func save() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        HolidayNudges.shared.answeredNote(text: value, userInfo: S23MissedRules.userInfo(info))
        S23Present.shared.markAnswered()
        after = S23AfterRules.note
    }
}

// MARK: - 知5 その知らせのタスク（光らせて出す）

struct S23TasksView: View {
    @Environment(Pipeline.self) private var pipeline
    let ids: [String]
    @State private var note: String?

    var body: some View {
        let items = pipeline.tasks.items.filter { ids.contains($0.id) }
        LLList {
            Section {
                if items.isEmpty {
                    Text("このタスクは、もう一覧にありません（済み・消したなど）。").foregroundStyle(LL.dim)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.what).font(.headline)
                        let sub = [item.from.map { $0 + "から" }, item.dueText].compactMap { $0 }.filter { !$0.isEmpty }
                        if !sub.isEmpty { Text(sub.joined(separator: "・")).font(.caption).foregroundStyle(LL.dim) }
                        buttons(item)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(LL.accent.opacity(0.15))
                }
                if let note { Text(note).font(.caption).foregroundStyle(LL.dim) }
            } header: {
                LLHeader(title: "この知らせのタスク", symbol: "checklist")
            }
            Section {
                Button("タスクの一覧で見る") {
                    pipeline.openRoute(.tab(.tasks))
                    S23Present.shared.sheet = nil
                }
            }
        }
        .navigationTitle("タスク")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func buttons(_ item: TaskBook.Item) -> some View {
        HStack(spacing: LL.Space.s) {
            switch item.state {
            case .candidate:
                Button("入れる") { act { pipeline.tasks.set(item.id, .open) } }.buttonStyle(LLPillButtonStyle(filled: true))
                Button("違う") { act { pipeline.tasks.reject(item.id, reason: .notice) } }.buttonStyle(LLPillButtonStyle(tint: LL.danger))
            case .open:
                Button("済み") { act { pipeline.tasks.set(item.id, .done) } }.buttonStyle(LLPillButtonStyle(filled: true))
                Button("明日に") { act { pipeline.tasks.postpone(item.id, days: 1) } }.buttonStyle(LLPillButtonStyle(tint: LL.dim))
            default:
                Text("済みです").font(.caption).foregroundStyle(LL.dim)
            }
        }
    }

    private func act(_ change: () -> Void) {
        change()
        pipeline.tasksChanged()
        LLHaptic.done.play()
        S23Present.shared.markAnswered()
        note = "直しました。タスクの一覧にも入っています。"
    }
}

// MARK: - 知5 その知らせの約束

struct S23PromisesView: View {
    @Environment(Pipeline.self) private var pipeline
    let ids: [String]
    @State private var note: String?

    var body: some View {
        let inbox = PromiseInbox.shared
        let items = inbox.items.filter { ids.contains($0.id) && inbox.answered[$0.id] == nil }
        LLList {
            Section {
                if items.isEmpty && note == nil {
                    Text("読み込み中か、もう答えてあります。").foregroundStyle(LL.dim)
                }
                ForEach(items) { item in
                    PromiseRow(item: item) { add in
                        Tally.add(add ? "s23.promise.today.add" : "s23.promise.today.ignore")
                        note = inbox.answer(item, add: add, pipeline: pipeline)
                        S23Present.shared.markAnswered()
                    }
                    .listRowBackground(LL.accent.opacity(0.15))
                }
                if let note { S23AfterLine(text: note) }
            } header: {
                LLHeader(title: "この知らせの約束", symbol: "hand.thumbsup")
            }
        }
        .navigationTitle("約束")
        .navigationBarTitleDisplayMode(.inline)
        .task { await inbox.refresh(pipeline, force: true) }
    }
}

// MARK: - 知7 いまの様子の 1 枚

struct S23StatusView: View {
    @Environment(Pipeline.self) private var pipeline
    let id: String

    var body: some View {
        let card = S23StatusRules.card(id)
        LLList {
            Section {
                Text(card.what).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                LabeledContent("iPhone の録音", value: pipeline.isRecording ? "録っています" : "止まっています")
                LabeledContent("時計の録音", value: pipeline.isWatchRecording ? "録っています" : "止まっているか、分からない")
                if let seen = PCDiag.watchSeenAt {
                    LabeledContent("時計から最後に届いた", value: seen.formatted(date: .omitted, time: .shortened))
                }
                if let backlog = S22Book.watchBacklogText() { LabeledContent("時計に溜まった分", value: backlog) }
            } header: {
                LLHeader(title: "いま起きていること", symbol: "exclamationmark.circle")
            }
            Section {
                ForEach(Array(card.steps.enumerated()), id: \.offset) { i, step in
                    Label(step, systemImage: "\(i + 1).circle")
                }
                if card.record && !pipeline.isRecording {
                    Button {
                        Task { await pipeline.handle(.startRecording) }
                        S23Present.shared.markAnswered()
                    } label: {
                        Label(id == "phone-stopped" ? "録音を始める" : "iPhone で録る", systemImage: "record.circle")
                    }
                    .buttonStyle(LLPillButtonStyle(filled: true))
                }
                Button("自己点検を開く") {
                    S23Present.shared.markAnswered()
                    S23Present.shared.sheet = nil
                    pipeline.openRoute(.screen(.diagnostics))
                }
            } header: {
                LLHeader(title: "押すもの", symbol: "hand.tap")
            }
        }
        .navigationTitle("いまの様子")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 続5 何人でしたか

struct S23HeadcountView: View {
    let start: Double
    let day: String
    @State private var after: String?

    var body: some View {
        LLList {
            Section {
                Text(Date(timeIntervalSince1970: start).formatted(date: .omitted, time: .shortened) + " からの会話は、自分も入れて何人でしたか？")
                    .font(.headline)
                if let after {
                    S23AfterLine(text: after)
                } else {
                    FlowLayout(spacing: LL.Space.s) {
                        ForEach(S23TapRules.countActions, id: \.id) { option in
                            Button(option.title) { answer(option.count) }.buttonStyle(LLPillButtonStyle(filled: true))
                        }
                    }
                }
            } footer: {
                Text("人数はこの iPhone に残し、家の PC への様子に入れます（名前は入れません）。")
            }
        }
        .navigationTitle("何人でしたか？")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func answer(_ count: Int) {
        S23Book.shared.answerHeadcount(start: start, day: day, count: count)
        S23Present.shared.markAnswered()
        after = S23AfterRules.headcount(count)
    }
}

// MARK: - 場4 今日の名前の無い場所（地図つき・1 画面で続けて答える）

struct S23PlacesNightView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var candidates: [String: [String]] = [:]
    @State private var typed: [String: String] = [:]
    @State private var done: [String: String] = [:]

    var body: some View {
        let stays = S23PlaceRules.today(CheckupBook.shared.unknownStays(), now: .now)
            .filter { !S23Places.isIgnored(latitude: $0.latitude, longitude: $0.longitude) || done[$0.id] != nil }
        LLList {
            if let first = stays.first {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: first.location.coordinate, latitudinalMeters: 3000,
                                                                    longitudinalMeters: 3000))) {
                        ForEach(Array(stays.enumerated()), id: \.element.id) { i, stay in
                            Marker("\(i + 1)", coordinate: stay.location.coordinate)
                        }
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    LLEmpty(title: "今日の名前の無い場所は、もうありません", symbol: "checkmark.circle")
                }
            }
            ForEach(Array(stays.enumerated()), id: \.element.id) { i, stay in
                Section {
                    if let name = done[stay.id] {
                        S23AfterLine(text: name.isEmpty ? "この近くでは、もう聞きません。" : S23AfterRules.place(name))
                    } else {
                        FlowLayout(spacing: LL.Space.s) {
                            ForEach(candidates[stay.id] ?? [], id: \.self) { name in
                                Button(name) { assign(stay, name) }.buttonStyle(LLPillButtonStyle())
                            }
                        }
                        HStack {
                            TextField("この所の名前", text: Binding(get: { typed[stay.id] ?? "" }, set: { typed[stay.id] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button("付ける") { assign(stay, typed[stay.id] ?? "") }
                                .buttonStyle(LLPillButtonStyle(filled: true))
                                .disabled(PlaceAssistRules.typedName(typed[stay.id] ?? "") == nil)
                        }
                        HStack {
                            NavigationLink("その時を見る") {
                                MomentView(from: stay.arrival, to: stay.departure, title: "この所にいた時")
                            }
                            Spacer()
                            Button("覚えなくていい", role: .destructive) {
                                S23Places.ignore(latitude: stay.latitude, longitude: stay.longitude)
                                UnnamedStayBook.shared.dismiss(stay.id)
                                done[stay.id] = ""
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                } header: {
                    Text("\(i + 1). " + stay.arrival.formatted(date: .omitted, time: .shortened) + "〜"
                         + stay.departure.formatted(date: .omitted, time: .shortened) + "（\(stay.minutes) 分）")
                }
                .task(id: stay.id) {
                    if candidates[stay.id] == nil {
                        candidates[stay.id] = await PlaceAssist.shared.candidates(for: stay.location, arrival: stay.arrival)
                    }
                }
            }
        }
        .navigationTitle("今日の名前の無い場所")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s23PlacesNight")
    }

    private func assign(_ stay: UnnamedStay, _ raw: String) {
        guard let name = PlaceAssistRules.typedName(raw), UnnamedStayBook.shared.name(stay.id, as: name) else { return }
        S23Places.noteAnswer(name: name, latitude: stay.latitude, longitude: stay.longitude)
        Tally.add("s23.placesNight.answered")
        S23Present.shared.markAnswered()
        done[stay.id] = name
    }
}

// MARK: - 知13 答えそびれた質問

struct S23MissedView: View {
    @State private var version = 0

    var body: some View {
        let list = S23Book.shared.dueMissed()
        LLList {
            Section {
                if list.isEmpty {
                    LLEmpty(title: "答えそびれた質問はありません", symbol: "checkmark.circle", detail: "3 日より前のものは流れます。")
                }
                ForEach(list) { q in
                    NavigationLink {
                        S23MissedDestination(question: q)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.title).font(.callout).foregroundStyle(LL.text).lineLimit(2)
                            Text(q.at.formatted(.dateTime.month().day().hour().minute().locale(LL.ja))).font(.caption2).foregroundStyle(LL.dim)
                        }
                    }
                    .swipeActions {
                        Button("消す") {
                            S23Book.shared.answeredQuestion(id: q.id)
                            version += 1
                        }
                        .tint(LL.warn)
                    }
                }
            } footer: {
                Text("押すと、その質問に答える画面が開きます。")
            }
        }
        .id(version)
        .navigationTitle("答えそびれた質問")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s23Missed")
    }
}

/// 答えそびれた質問 1 つの答える画面（一覧から押して開く）
private struct S23MissedDestination: View {
    let question: S23MissedQuestion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch S23Notices.destination(for: question) {
        case .sheet(let sheet):
            S23SheetView(sheet: sheet).onAppear { Tally.add("s23.missed.answered") }
        case .place(let target):
            PlaceAskSheet(target: target) { dismiss() }.onAppear { Tally.add("s23.missed.answered") }
        case nil:
            Text("この質問には、ここからは答えられません。").foregroundStyle(LL.dim)
        }
    }
}

/// 知らせの履歴の上に置く入口（答えそびれ・棚卸し）
struct S23NoticeLinks: View {
    var body: some View {
        let missed = S23Book.shared.dueMissed().count
        Section {
            NavigationLink {
                S23MissedView()
            } label: {
                LabeledContent {
                    Text(missed > 0 ? "\(missed) 問" : "なし")
                } label: {
                    Label("答えそびれた質問", systemImage: "questionmark.bubble")
                }
            }
            NavigationLink {
                S23NoticeInventoryView()
            } label: {
                Label("知らせの棚卸しと切り替え", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

// MARK: - 知1・知10・知11・場6 知らせの棚卸し（押すとどこが開くか・時計で答えられるか・押したのに答えなかった数）

struct S23NoticeInventoryView: View {
    @AppStorage(S23Settings.placeAutoKey) private var placeAuto = false
    @AppStorage(S23Settings.placeOnLeaveKey) private var placeOnLeave = false
    @AppStorage(S23Settings.placesNightKey) private var placesNight = true
    @AppStorage(S23Settings.placeTightenKey) private var placeTighten = true
    @AppStorage(S23Settings.headcountKey) private var headcount = true
    @AppStorage(S23Settings.versionCheckKey) private var versionCheck = true
    @AppStorage(S23Settings.versionMorningKey) private var versionMorning = true
    @AppStorage(S23Settings.tryTodayKey) private var tryToday = true
    @State private var ignoredCount = S23Places.ignored.count

    var body: some View {
        let stats = S23TapStats.rows(S23Book.shared.tapStats)
        let places = S23Places.counts()
        LLList {
            Section {
                if stats.isEmpty { Text("まだ数えていません").foregroundStyle(LL.dim) }
                ForEach(stats.prefix(10)) { row in
                    LabeledContent(NoticeHistoryRules.kindLabel(row.kind)) {
                        Text("開いた \(row.opened)・答えた \(row.answered)・答えずに閉じた \(row.closed)").font(.caption).monospacedDigit()
                    }
                }
            } header: {
                LLHeader(title: "押したあと（答えずに閉じた多い順）", symbol: "hand.tap")
            } footer: {
                Text("答えずに閉じたのが多い知らせから、行き先や文を直します。")
            }
            Section {
                LabeledContent("聞いた", value: "\(places.asked) 回（聞く前に離れた \(places.cancelled)）")
                LabeledContent("答えた", value: "ボタン \(places.button)・書いた \(places.typed)・画面 \(places.sheet)")
                LabeledContent("答えなかった", value: "\(places.ignored) 回")
                LabeledContent("いまの聞き方", value: S23Places.tightened() ? "60 分いた所だけ（答えが少ないので絞っています）" : "30 分いた所")
            } header: {
                LLHeader(title: "「ここは、どこですか？」（14 日）", symbol: "mappin.and.ellipse")
            }
            Section {
                Toggle("答えが少なければ、聞く条件を絞る", isOn: $placeTighten)
                Toggle("いる最中ではなく、出たときに聞く", isOn: $placeOnLeave)
                Toggle("同じ名前を 2 回選んだ所では、聞かずに入れる", isOn: $placeAuto)
                Toggle("夜に「今日の名前の無い場所」", isOn: $placesNight)
                Toggle("会話のあとに「何人でしたか？」", isOn: $headcount)
                Toggle("新しい版を GitHub で確かめる", isOn: $versionCheck)
                Toggle("版を上げた翌朝に「動いたもの・まだのもの」", isOn: $versionMorning)
                Toggle("「今日」に今日の 1 つの確かめ", isOn: $tryToday)
                if ignoredCount > 0 {
                    Button("「覚えなくていい」にした所（\(ignoredCount)）を戻す") {
                        S23Places.clearIgnored()
                        ignoredCount = 0
                    }
                }
                let auto = S23Places.autoNamed
                if !auto.isEmpty {
                    Text("聞かずに入れた名前: " + auto.prefix(5).map(\.name).joined(separator: "・") + "（違えば地図の画面で直せます）")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            } header: {
                LLHeader(title: "切り替え（s23）", symbol: "switch.2")
            } footer: {
                HelpNote("「絞る」（初めはオン）: 14 日で 10 回以上聞いて答えが 3 割より少ないときだけ、60 分いた所だけにします（仮）。\n「出たときに聞く」（初めはオフ）: 出たあとのほうが答えやすいかは仮説です。\n「聞かずに入れる」（初めはオフ）: 間違えると名前が黙って変わるので、初めは聞きます。\n「何人でしたか？」（初めはオン）: 10 分より長い会話のあと、1 日 2 回まで。答えは家の PC への様子に入れます。\n「GitHub で確かめる」（初めはオン）: 公開のリリースの名前を読むだけで、何も送りません。")
            }
            Section {
                ForEach(S23NoticeCatalog.entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.callout)
                        Text("押すと: " + e.opens).font(.caption).foregroundStyle(LL.dim)
                        Text("時計: " + e.watch + (e.buttons ? "・長押しでボタン" : "")).font(.caption2).foregroundStyle(LL.dim)
                    }
                }
            } header: {
                LLHeader(title: "知らせの一覧（\(S23NoticeCatalog.entries.count)）", symbol: "list.bullet")
            } footer: {
                Text("時計で答えられるかは、まだ実機で確かめていません。")
            }
        }
        .navigationTitle("知らせの棚卸し")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s23NoticeInventory")
    }
}

// MARK: - 続6 約束の知らせの出し方ごとの数

struct S23PromiseCountsSection: View {
    var body: some View {
        let c = S23PromiseRules.counts(Tally.sums(days: 35))
        Section {
            LabeledContent("知らせた", value: "\(c.shown) 通")
            LabeledContent("知らせのボタン", value: "入れる \(c.noticeAdd)・いらない \(c.noticeIgnore)")
            LabeledContent("知らせを押して開いた", value: "\(c.noticeOpen) 回")
            LabeledContent("「今日」の欄", value: "入れる \(c.todayAdd)・いらない \(c.todayIgnore)")
            Text(S23PromiseRules.advice(c)).font(.caption).foregroundStyle(LL.dim)
        } header: {
            Text("出し方ごとの数（35 日）")
        } footer: {
            Text("やめるときは、上の「会話のあとに約束を知らせる」を切ります（初めは今のまま）。")
        }
    }
}

// MARK: - 「今日」に出すもの（届4・試5・知13・場4）

struct S23TodaySection: View {
    @AppStorage(S23Settings.tryTodayKey) private var tryToday = true
    @AppStorage("s23.tryTodayHidden") private var hiddenDay = ""
    @State private var open = false
    @State private var version = 0

    var body: some View {
        let book = S23Book.shared
        let newer = book.newerToShow
        let today = ReviewRules.dayKey(.now)
        let pick = tryToday && hiddenDay != today ? S23Checks.todayItem() : nil
        let missed = book.dueMissed().count
        if newer != nil || pick != nil || missed > 0 {
            Section {
                if let newer {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("新しい版（\(newer)）があるようです", systemImage: "arrow.down.app")
                        LLAdaptiveStack(spacing: LL.Space.s) {  // 文字がとても大きいときは縦に（s26 の 絵10）
                            Button("TestFlight を開く") { book.openTestFlight() }.buttonStyle(LLPillButtonStyle(filled: true))
                            Button("この版は知らせない") { book.dismissBuild(newer) }.buttonStyle(LLPillButtonStyle(tint: LL.dim))
                        }
                    }
                }
                if let pick {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation { open.toggle() }
                        } label: {
                            Label("今日はこれを試してください（30 秒）: " + pick.title, systemImage: "checkmark.circle.badge.questionmark")
                                .foregroundStyle(LL.text)
                        }
                        .buttonStyle(.borderless)
                        if open {
                            Text(pick.how).font(.callout).foregroundStyle(LL.dim)
                            LLAdaptiveStack(spacing: LL.Space.l) {  // 文字がとても大きいときは縦に（s26 の 絵10）
                                Button("確かめた", systemImage: "checkmark") { mark(pick.id, true) }
                                Button("動かなかった", systemImage: "xmark", role: .destructive) { mark(pick.id, false) }
                                Button("今日は出さない") { hiddenDay = today }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    .id(version)
                }
                if missed > 0 {
                    Button {
                        S23Present.shared.sheet = S23Sheet(kind: .missed)
                    } label: {
                        Label("答えそびれた質問が \(missed) 問あります", systemImage: "questionmark.bubble")
                    }
                }
            }
        }
    }

    private func mark(_ id: String, _ ok: Bool) {
        Checklist.mark(id, ok: ok)
        Tally.add(ok ? "s23.tryToday.ok" : "s23.tryToday.ng")
        open = false
        version += 1
    }
}

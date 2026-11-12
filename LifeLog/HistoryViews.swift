import AVFoundation
import Observation
import SwiftUI

/// 1日の記録。「過ごし方」（何時から何時まで何をしていたか）と「会話ごと」を切り替えて見る。
struct DayView: View {
    let day: String
    /// 0: 過ごし方、1: 会話ごと
    @AppStorage("dayViewMode") private var mode = 0

    var body: some View {
        Group {
            if mode == 0 {
                ActivitiesView(day: day)
            } else {
                ConversationsView(day: day)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("見方", selection: $mode) {
                Text("過ごし方").tag(0)
                Text("会話ごと").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)
            .background(.bar)
        }
        .navigationTitle(day)
        .toolbar {
            NavigationLink {
                MinutesView(day: day)
            } label: {
                Image(systemName: "doc.text")
            }
            NavigationLink {
                UnnamedVoicesView(day: day)
            } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
            }
        }
    }
}

/// 1日を「何をしていたか」の長い塊で、時刻順に見る。塊を押すと、その中の会話を見る。
struct ActivitiesView: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String
    @State private var activities: [Activity] = []
    @State private var building = false
    /// まだ塊にまとめていない会話（閉じていない会話や、まとめたあとに増えた会話）
    @State private var newer: [ConversationLog.Conversation] = []

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        List {
            // PLAUD で埋めた所（アプリの記録が無い時間。読むだけ。2026-11-13。HomeFeeds.swift）
            PlaudFillSection(day: day)
            if building {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("過ごし方をまとめています…").foregroundStyle(.secondary)
                }
            }
            ForEach(activities) { activity in
                Section {
                    if activity.kind == .recorded, let first = activity.first, let last = activity.last {
                        NavigationLink {
                            ConversationsView(day: day, range: first...last)
                                .navigationTitle(activity.title)
                        } label: {
                            ActivityRow(activity: activity)
                        }
                    } else {
                        ActivityRow(activity: activity)
                    }
                }
            }
            if let first = newer.first {
                Section {
                    NavigationLink {
                        ConversationsView(day: day, range: first.start...Date.distantFuture)
                            .navigationTitle("まだまとめていない会話")
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.clock.string(from: first.start) + "〜")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("まだまとめていない会話（\(newer.count) 件）")
                            Text("話が3分途切れて会話が閉じると、過ごし方に入ります。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if activities.isEmpty && newer.isEmpty && !building && pipeline.homeFeeds.fill(for: day) == nil {
                ContentUnavailableView("記録がありません", systemImage: "calendar.day.timeline.left")
            }
        }
        .task { await load(rebuild: false) }
        .refreshable { await load(rebuild: true) }
    }

    private func load(rebuild: Bool) async {
        if activities.isEmpty { activities = pipeline.savedActivities(on: day) }
        updateNewer()
        building = true
        activities = await pipeline.activities(on: day, rebuild: rebuild)
        building = false
        updateNewer()
    }

    private func updateNewer() {
        let last = activities.compactMap(\.last).max()
        newer = pipeline.conversations(on: day).filter { c in
            !c.lines.isEmpty && (last.map { c.start > $0 } ?? true)
        }
    }
}

/// 過ごし方の1つの塊
private struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(activity.timeRange)
                    .font(.subheadline.monospacedDigit().bold())
                Text(activity.length)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                switch activity.kind {
                case .recorded:
                    if activity.count > 0 {
                        Text("会話 \(activity.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .plan:
                    Label("予定・録音なし", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                case .move:
                    Label("移動", systemImage: "figure.walk").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(activity.title)
                .font(.headline)
            if !activity.detail.isEmpty {
                Text(activity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !activity.did.isEmpty {
                Text(activity.did.map { "・" + $0 }.joined(separator: "\n"))
                    .font(.callout)
            }
        }
        .padding(.vertical, 2)
        .opacity(activity.kind == .recorded ? 1 : 0.7)
    }
}

/// 1日の記録を、会話ごとに新しい順で見る。行を押すと、その場面から音声を再生する。
/// range を渡すと、その時間に始まった会話だけを出す（過ごし方の塊の中身）。
struct ConversationsView: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String
    var range: ClosedRange<Date>? = nil
    @State private var conversations: [ConversationLog.Conversation] = []
    @State private var player = ClipPlayer()
    @State private var fixing: Fix?
    @State private var addingWord: WordTarget?
    @State private var editing: WordTarget?
    /// 会話ごとの、その時間に撮った写真（始まりの時刻ごと。iPhone の中で探すだけで保存しない。2026-11-07。DayPhotos.swift）
    @State private var photos: [Date: [DayPhoto]] = [:]
    @Environment(\.displayScale) private var displayScale

    struct WordTarget: Identifiable {
        let id = UUID()
        let line: ConversationLog.Line
    }

    /// 話者を直す行と、同じ音声の次の行
    struct Fix: Identifiable {
        let id = UUID()
        let line: ConversationLog.Line
        let next: ConversationLog.Line?
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let lineTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        List {
            // PLAUD で埋めた所（1日を見るときだけ。読むだけで、会話には入れない。2026-11-13。HomeFeeds.swift）
            if range == nil { PlaudFillSection(day: day) }
            // 間が短く、場所と相手が同じ会話は1つのまとまりで見せる
            ForEach(Array(ConversationLog.grouped(conversations).enumerated()).reversed(), id: \.offset) { g, group in
                Section {
                    ForEach(Array(group.enumerated()), id: \.offset) { c, conversation in
                        if group.count > 1, let title = conversation.title, !title.isEmpty {
                            Text(title).font(.subheadline.bold())
                        }
                        if !conversation.points.isEmpty {
                            Text(conversation.points.map { "・" + $0 }.joined(separator: "\n"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        // その会話の時間（と前後5分）に撮った写真（許可があるときだけ。押すと大きく見る。2026-11-07。DayPhotos.swift）
                        if let shots = photos[conversation.start], !shots.isEmpty {
                            ConversationPhotoStrip(photos: shots)
                        }
                        // 前の会話とつなぐ（2026-11-06。閉じた会話で、その日の前に閉じた会話があるとき）
                        if conversation.closed, conversations.contains(where: { $0.closed && $0.start < conversation.start }) {
                            Button("前の会話とつなぐ", systemImage: "arrow.up.and.down.text.horizontal") {
                                Task {
                                    await pipeline.joinConversation(start: conversation.start, day: day)
                                    conversations = load()
                                }
                            }
                            .font(.caption)
                        }
                        ForEach(Array(conversation.lines.enumerated()), id: \.offset) { l, line in
                            let next = conversation.lines[(l + 1)...].first { $0.audio == line.audio }
                            row(line, key: "\(g)-\(c)-\(l)")
                                .contextMenu {
                                    Button("話者を直す", systemImage: "person.crop.circle.badge.questionmark") {
                                        fixing = Fix(line: line, next: next)
                                    }
                                    Button("文字を直す", systemImage: "pencil") {
                                        editing = WordTarget(line: line)
                                    }
                                    Button("言葉を登録", systemImage: "character.book.closed") {
                                        addingWord = WordTarget(line: line)
                                    }
                                    // この行から別の会話にする（2026-11-06）
                                    if conversation.closed, l > 0 {
                                        Button("ここで会話を分ける", systemImage: "scissors") {
                                            Task {
                                                await pipeline.splitConversation(start: conversation.start, at: line.time, day: day)
                                                conversations = load()
                                            }
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button("話者", systemImage: "person.crop.circle.badge.questionmark") {
                                        fixing = Fix(line: line, next: next)
                                    }
                                    .tint(.indigo)
                                    Button("文字", systemImage: "pencil") {
                                        editing = WordTarget(line: line)
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                } header: {
                    Text(heading(for: group))
                }
            }
        }
        .overlay {
            if conversations.isEmpty && (range != nil || pipeline.homeFeeds.fill(for: day) == nil) {
                ContentUnavailableView("記録がありません", systemImage: "text.bubble")
            }
        }
        .onAppear { conversations = load() }
        .refreshable { conversations = load() }
        // 会話が変わったら、写真を探し直す（許可が無い・設定がオフなら何もしない）
        .task(id: conversations.map(\.start)) {
            photos = await DayPhotos.load(conversations.map { (start: $0.start, end: $0.end) }, scale: displayScale)
        }
        .onDisappear { player.stop() }
        .sheet(item: $addingWord) { AddWordView(line: $0.line) }
        .sheet(item: $editing) { target in
            EditLineView(line: target.line) { conversations = load() }
        }
        .sheet(item: $fixing) { fix in
            SpeakerFixView(line: fix.line, next: fix.next, context: pipeline.places.context(at: fix.line.time)) {
                conversations = load()
            }
        }
    }

    private func load() -> [ConversationLog.Conversation] {
        let all = pipeline.conversations(on: day)
        guard let range else { return all }
        return all.filter { range.contains($0.start) }
    }

    @ViewBuilder
    private func row(_ line: ConversationLog.Line, key: String) -> some View {
        let audio = line.audio.flatMap { pipeline.archive.canPlay($0) ? $0 : nil }
        let label = HStack(alignment: .firstTextBaseline) {
            VStack(spacing: 2) {
                Text(Self.lineTimeFormatter.string(from: line.time))
                    .font(.caption.monospacedDigit())
                // 時計で録った音から書いた行
                if line.audio?.hasSuffix("-w.m4a") == true {
                    Image(systemName: "applewatch").font(.caption2)
                }
                // 騒がしいところで聞き取った行
                if line.noisy == true {
                    Image(systemName: "speaker.wave.3").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if line.speaker != nil || line.marked == true {
                    HStack(spacing: 4) {
                        if line.marked == true {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        if let speaker = line.speaker {
                            Text(speaker)
                            // 2つの声のモデルで話し手が食い違った行（2026-11-06）
                            if let doubt = line.speakerDoubt, doubt != line.speakerID {
                                Text("？").foregroundStyle(.orange)
                            }
                        }
                    }
                    .font(.caption.bold())
                }
                // 確からしさの低い行は薄く出す（聞き直して確かめたほうがよい行）
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if line.isUncertain {
                        Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.orange)
                    }
                    // 自信の低い行は、名前・数字・日時・金額に下線（要確認。2026-11-06）
                    Text(line.isUncertain ? UncertainMarks.underlined(line.text) : AttributedString(line.text))
                        .opacity(line.isUncertain ? 0.55 : 1)
                }
                if let original = line.original {
                    Text("直す前: " + original)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if player.loading == key {
                ProgressView()
            } else if audio != nil {
                Image(systemName: player.playing == key ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(Color.accentColor)
            }
        }
        if let audio {
            Button {
                Task {
                    await player.toggle(key, at: line.offset ?? 0) {
                        await pipeline.archive.playableURL(for: audio)
                    }
                }
            } label: {
                label
            }
            .tint(.primary)
        } else {
            label
        }
    }

    private func heading(for group: [ConversationLog.Conversation]) -> String {
        guard let c = group.first else { return "" }
        let end = group.map(\.end).max() ?? c.end
        var parts = ["\(Self.timeFormatter.string(from: c.start))〜\(Self.timeFormatter.string(from: end))"]
        if let place = group.compactMap(\.place).first { parts.append(place) }
        // 行ったお店（その会話と重なる立ち寄り。画面に出すだけで、記録には書かない。2026-11-08）
        if let shop = pipeline.shopVisits.label(from: c.start, to: end) { parts.append(shop) }
        // 場面（PC の音の分類と iPhone の背景の音の多数決。2026-11-06）
        if let scene = group.compactMap(\.scene).first { parts.append("［\(scene)］") }
        let people = Array(NSOrderedSet(array: group.flatMap(\.people))) as? [String] ?? []
        if let media = c.media {
            parts.append("［\(media)］" + (c.program.map { "「\($0)」" } ?? ""))
        } else if !people.isEmpty {
            parts.append(people.joined(separator: "、") + "と")
        }
        if group.count > 1 {
            parts.append("\(group.count) つの会話")
        } else if let title = c.title, !title.isEmpty {
            parts.append(title)
        }
        // ヘルスケアで、ふだんより心拍がはっきり上がっていた会話
        if let max = group.filter({ $0.tense == true }).compactMap(\.heartRateMax).max() {
            parts.append("♥︎\(max)")
        }
        return parts.joined(separator: "　")
    }
}

/// 記録の行の文字を直す。直したところを、誤変換の一覧に足すかをその場で選べる。
struct EditLineView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let line: ConversationLog.Line
    let onDone: () -> Void
    @State private var text = ""
    @State private var addFix = true
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        let part = Pipeline.changedPart(from: line.text, to: text)
        NavigationStack {
            Form {
                Section {
                    TextField("文", text: $text, axis: .vertical)
                } header: {
                    Text("この行の文字")
                } footer: {
                    if let original = line.original { Text("最初の文字起こし: " + original) }
                }
                if let part {
                    Section {
                        Toggle("「\(part.wrong)」→「\(part.right)」を誤変換の一覧に足す", isOn: $addFix)
                    } footer: {
                        Text("足すと、これからの文字起こしでも同じ書き間違いを自動で直します。あとから「言葉」の画面で消せます。")
                    }
                }
                // 変更の履歴（2026-11-06）: 自動や手で書き換えた前の文に戻せる
                if let history = line.history, !history.isEmpty {
                    Section {
                        ForEach(Array(history.enumerated().reversed()), id: \.offset) { _, edit in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(edit.at.formatted(date: .abbreviated, time: .shortened))　\(edit.by)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("前の文: " + edit.from)
                                Button("この文に戻す") {
                                    text = edit.from
                                    // 戻すときは、誤変換の一覧には足さない
                                    addFix = false
                                }
                                .font(.callout)
                                .disabled(text == edit.from)
                            }
                        }
                    } header: {
                        Text("変更の履歴")
                    } footer: {
                        Text("「この文に戻す」を押してから「直す」を押すと、その文に戻ります。戻した行は手で直した行として扱い、夜の聞き直しでも変えません。")
                    }
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("文字を直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("直す") {
                            saving = true
                            Task {
                                failure = await pipeline.editLine(line, to: text, addFix: addFix ? part : nil)
                                saving = false
                                if failure == nil {
                                    onDone()
                                    dismiss()
                                }
                            }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == line.text)
                    }
                }
            }
            .onAppear { text = line.text }
        }
    }
}

/// 残しておいた音声を、行の少し手前から再生する。手元に無ければドライブから取ってくる。
@MainActor
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: String?
    /// ドライブから取ってきている行
    private(set) var loading: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    /// 雑音を減らした一時ファイル
    @ObservationIgnored private var cleaned: URL?

    /// until を渡すと、その位置（秒）で止める。
    func toggle(_ key: String, at offset: TimeInterval, until end: TimeInterval? = nil,
                file: () async -> URL?) async {
        if playing == key {
            stop()
            return
        }
        stop()
        loading = key
        let url = await file()
        guard loading == key, let url else {
            if loading == key { loading = nil }
            return
        }
        // 雑音を減らして聞くときは、その場面だけを切り出して減らしてから鳴らす
        var cleaned: URL?
        if Self.denoise {
            let from = max(0, offset - 1), to = (end ?? offset + 60) + 0.5
            cleaned = try? await Task.detached(priority: .userInitiated) {
                try Denoiser.clip(url, from: from, to: to)
            }.value
            guard loading == key else {
                if let cleaned { try? FileManager.default.removeItem(at: cleaned) }
                return
            }
        }
        loading = nil
        let session = AVAudioSession.sharedInstance()
        // iPhone で録音中は、録音の設定を崩さないようそのまま鳴らす
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        guard let player = try? AVAudioPlayer(contentsOf: cleaned ?? url) else { return }
        player.delegate = self
        // 切り出したものは頭から全部鳴らす
        player.currentTime = cleaned == nil ? max(0, offset - 1) : 0
        player.play()
        self.player = player
        self.cleaned = cleaned
        playing = key
        if let end, cleaned == nil {
            let length = max(1, end - player.currentTime) + 0.5
            Task {
                try? await Task.sleep(for: .seconds(length))
                if self.player === player { self.stop() }
            }
        }
    }

    /// 聞き直すときに雑音を減らす（設定で切り替え）
    static var denoise: Bool { UserDefaults.standard.object(forKey: "denoisePlayback") as? Bool ?? true }

    func stop() {
        player?.stop()
        player = nil
        if let cleaned { try? FileManager.default.removeItem(at: cleaned) }
        cleaned = nil
        playing = nil
        loading = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

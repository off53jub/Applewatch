import AVFoundation
import Observation
import SwiftUI

/// 記録のある日の一覧。
struct HistoryView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var days: [String] = []

    var body: some View {
        List(days, id: \.self) { day in
            NavigationLink(day) { DayView(day: day) }
        }
        .overlay {
            if days.isEmpty {
                ContentUnavailableView("まだありません", systemImage: "text.bubble",
                                       description: Text("文字起こしが終わると、ここに日ごとに出てきます。"))
            }
        }
        .navigationTitle("これまでの記録")
        .onAppear { days = pipeline.recordedDays() }
    }
}

/// 1日の記録を、会話ごとに新しい順で見る。行を押すと、その場面から音声を再生する。
struct DayView: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String
    @State private var conversations: [ConversationLog.Conversation] = []
    @State private var player = ClipPlayer()
    @State private var fixing: Fix?
    @State private var addingWord: WordTarget?

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
            ForEach(Array(conversations.enumerated()).reversed(), id: \.offset) { c, conversation in
                Section {
                    if !conversation.points.isEmpty {
                        Text(conversation.points.map { "・" + $0 }.joined(separator: "\n"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(conversation.lines.enumerated()), id: \.offset) { l, line in
                        let next = conversation.lines[(l + 1)...].first { $0.audio == line.audio }
                        row(line, key: "\(c)-\(l)")
                            .contextMenu {
                                Button("話者を直す", systemImage: "person.crop.circle.badge.questionmark") {
                                    fixing = Fix(line: line, next: next)
                                }
                                Button("言葉を登録", systemImage: "character.book.closed") {
                                    addingWord = WordTarget(line: line)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button("話者", systemImage: "person.crop.circle.badge.questionmark") {
                                    fixing = Fix(line: line, next: next)
                                }
                                .tint(.indigo)
                            }
                    }
                } header: {
                    Text(heading(for: conversation))
                }
            }
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView("記録がありません", systemImage: "text.bubble")
            }
        }
        .navigationTitle(day)
        .toolbar {
            NavigationLink {
                UnnamedVoicesView(day: day)
            } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
            }
        }
        .onAppear { conversations = pipeline.conversations(on: day) }
        .refreshable { conversations = pipeline.conversations(on: day) }
        .onDisappear { player.stop() }
        .sheet(item: $addingWord) { AddWordView(line: $0.line) }
        .sheet(item: $fixing) { fix in
            SpeakerFixView(line: fix.line, next: fix.next, context: pipeline.places.context(at: fix.line.time)) {
                conversations = pipeline.conversations(on: day)
            }
        }
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
                        }
                    }
                    .font(.caption.bold())
                }
                Text(line.text)
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

    private func heading(for c: ConversationLog.Conversation) -> String {
        var parts = ["\(Self.timeFormatter.string(from: c.start))〜\(Self.timeFormatter.string(from: c.end))"]
        if let place = c.place { parts.append(place) }
        if let media = c.media {
            parts.append("［\(media)］" + (c.program.map { "「\($0)」" } ?? ""))
        } else if !c.people.isEmpty {
            parts.append(c.people.joined(separator: "、") + "と")
        }
        if let title = c.title, !title.isEmpty { parts.append(title) }
        return parts.joined(separator: "　")
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
        loading = nil
        let session = AVAudioSession.sharedInstance()
        // iPhone で録音中は、録音の設定を崩さないようそのまま鳴らす
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.currentTime = max(0, offset - 1)
        player.play()
        self.player = player
        playing = key
        if let end {
            let length = max(1, end - player.currentTime) + 0.5
            Task {
                try? await Task.sleep(for: .seconds(length))
                if self.player === player { self.stop() }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        loading = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

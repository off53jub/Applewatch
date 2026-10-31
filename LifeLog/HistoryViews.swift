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
                        row(line, key: "\(c)-\(l)")
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
        .onAppear { conversations = pipeline.conversations(on: day) }
        .refreshable { conversations = pipeline.conversations(on: day) }
        .onDisappear { player.stop() }
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
                if let speaker = line.speaker {
                    Text(speaker).font(.caption.bold())
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
        if !c.people.isEmpty { parts.append(c.people.joined(separator: "、") + "と") }
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

    func toggle(_ key: String, at offset: TimeInterval, file: () async -> URL?) async {
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

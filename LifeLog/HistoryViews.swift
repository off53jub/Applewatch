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
        let audio = line.audio.flatMap(Storage.keptAudio(named:))
        let label = HStack(alignment: .firstTextBaseline) {
            Text(Self.lineTimeFormatter.string(from: line.time))
                .font(.caption.monospacedDigit())
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
            if audio != nil {
                Image(systemName: player.playing == key ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(Color.accentColor)
            }
        }
        if let audio {
            Button {
                player.toggle(key, file: audio, at: line.offset ?? 0)
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

/// 残しておいた音声を、行の少し手前から再生する。
@MainActor
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ key: String, file: URL, at offset: TimeInterval) {
        if playing == key {
            stop()
            return
        }
        stop()
        let session = AVAudioSession.sharedInstance()
        // iPhone で録音中は、録音の設定を崩さないようそのまま鳴らす
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        guard let player = try? AVAudioPlayer(contentsOf: file) else { return }
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
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

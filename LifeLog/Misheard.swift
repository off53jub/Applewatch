import Foundation
import Observation
import SwiftUI

/// 「この言葉、聞き間違いじゃない？」の一覧。
/// 閉じた会話を言語モデルに読んでもらい、聞き間違いと思われる言葉を、理由と「たぶんこう」の書き方付きで溜める。
/// 記録は変えない。直すのは持ち主が押したときだけ。直した会話は、あとで見出しと要点・1日のまとめを作り直す。
@MainActor
@Observable
final class MisheardBox {
    enum State: String, Codable {
        case open, fixed, kept
    }

    /// 見つけた行
    struct Ref: Codable, Hashable {
        let day: String
        let time: Date
        let text: String
    }

    struct Suspect: Codable, Identifiable {
        var id = UUID()
        let wrong: String
        var guess: String
        var reason: String
        var refs: [Ref]
        let found: Date
        var state: State = .open
        var settled: Date? = nil
    }

    private struct Saved: Codable {
        var suspects: [Suspect] = []
        /// 調べた会話（「日付|始まりの時刻」→ 調べた時刻）
        var checked: [String: Date] = [:]
        /// 「合っている」にした言葉（もう出さない）
        var kept: [String] = []
    }

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("misheard.json")
    private var saved = Saved()

    var open: [Suspect] { saved.suspects.filter { $0.state == .open }.sorted { $0.found > $1.found } }
    var kept: Set<String> { Set(saved.kept) }

    init() {
        if let data = try? Data(contentsOf: Self.url), let loaded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = loaded
        }
    }

    static func key(day: String, start: Date) -> String { "\(day)|\(start.timeIntervalSince1970)" }

    func isChecked(_ key: String) -> Bool { saved.checked[key] != nil }

    func markChecked(_ key: String) {
        saved.checked[key] = .now
        save()
    }

    /// 見つけた言葉を足す。同じ言葉がまだ一覧にあれば、行を足す。
    func add(wrong: String, guess: String, reason: String, ref: Ref) {
        if let i = saved.suspects.firstIndex(where: { $0.state == .open && $0.wrong == wrong }) {
            if !saved.suspects[i].refs.contains(ref) { saved.suspects[i].refs.append(ref) }
            if saved.suspects[i].guess.isEmpty { saved.suspects[i].guess = guess }
        } else {
            saved.suspects.append(Suspect(wrong: wrong, guess: guess, reason: reason, refs: [ref], found: .now))
        }
        save()
    }

    func settle(_ id: UUID, as state: State) {
        guard let i = saved.suspects.firstIndex(where: { $0.id == id }) else { return }
        saved.suspects[i].state = state
        saved.suspects[i].settled = .now
        if state == .kept, !saved.kept.contains(saved.suspects[i].wrong) { saved.kept.append(saved.suspects[i].wrong) }
        save()
    }

    /// 片付けて30日たったものと、30日より前に調べた会話の印を捨てる
    func prune() {
        let limit = Date.now.addingTimeInterval(-30 * 86400)
        saved.suspects.removeAll { $0.state != .open && ($0.settled ?? $0.found) < limit }
        saved.checked = saved.checked.filter { $0.value >= limit }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

extension Pipeline {
    /// 調べる日数（新しい日から）
    private static let misheardDays = 14
    /// 1回に読む文字数（無料枠を使い切らないように）と、1回に渡す会話の長さ
    private static let misheardBudget = 8_000
    private static let misheardPiece = 4_000
    /// 探すのは多くても10分に1回
    private static var misheardChecked = Date.distantPast

    private static let misheardClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// まだ調べていない閉じた会話から、聞き間違いと思われる言葉を探して一覧に足す。足した数を返す。
    @discardableResult
    func findMisheard(force: Bool = false) async -> Int {
        guard summariesOn, let key = settings.groqKey,
              force || Date.now.timeIntervalSince(Self.misheardChecked) >= 600 else { return 0 }
        Self.misheardChecked = .now
        misheard.prune()
        // 正しい書き方の候補（登録した言葉・名前を付けた人・誤変換の直し先）
        var hints: [String] = []
        for group in Vocabulary.Group.allCases { hints += vocabulary.words(in: group) }
        hints += people.filter { $0.isNamed && !$0.isSelf }.map(\.displayName)
        hints += vocabulary.fixes.map(\.right)
        var seen = Set<String>()
        hints = hints.filter { seen.insert($0).inserted }
        let known = Set(hints)
        let kept = misheard.kept

        var budget = Self.misheardBudget
        var added = 0
        for day in recordedDays().prefix(Self.misheardDays) {
            for c in conversations(on: day).reversed() where c.closed && c.media == nil {
                let key = MisheardBox.key(day: day, start: c.start)
                guard !misheard.isChecked(key) else { continue }
                let lines = c.lines.filter { $0.media == nil }
                let total = lines.reduce(0) { $0 + $1.text.count }
                guard total >= 80 else {
                    misheard.markChecked(key)
                    continue
                }
                guard budget > 0 else { return added }
                // 長い会話は区切って渡す
                var pieces: [[ConversationLog.Line]] = [[]]
                var length = 0
                for line in lines {
                    if length + line.text.count > Self.misheardPiece, !(pieces.last ?? []).isEmpty {
                        pieces.append([])
                        length = 0
                    }
                    pieces[pieces.count - 1].append(line)
                    length += line.text.count + 12
                }
                for piece in pieces {
                    let transcript = piece.map { line in
                        Self.misheardClock.string(from: line.time) + " " + (line.speaker.map { "[\($0)] " } ?? "") + line.text
                    }.joined(separator: "\n")
                    budget -= transcript.count
                    guard let found = try? await Summarizer.misheard(transcript, hints: hints, apiKey: key) else {
                        // 混んでいる・無料枠を超えたときは、次の機会にやり直す
                        return added
                    }
                    for item in found {
                        guard (2...12).contains(item.wrong.count), item.wrong != item.guess,
                              !known.contains(item.wrong), !kept.contains(item.wrong) else { continue }
                        // その時刻の行（無ければ、その言葉を含む行）。手で直した行は外す
                        let line = piece.first { Self.misheardClock.string(from: $0.time) == item.time && $0.text.contains(item.wrong) }
                            ?? piece.first { $0.text.contains(item.wrong) }
                        guard let line, line.checked != true else { continue }
                        misheard.add(wrong: item.wrong, guess: item.guess, reason: item.reason,
                                     ref: .init(day: day, time: line.time, text: line.text))
                        added += 1
                    }
                }
                misheard.markChecked(key)
            }
        }
        return added
    }

    /// その言葉を含む行（直近の日から。手で直した行は除く）
    func misheardOccurrences(of wrong: String, days: Int = 30) -> [MisheardBox.Ref] {
        var result: [MisheardBox.Ref] = []
        for day in recordedDays().prefix(days) {
            for c in conversations(on: day) where c.media == nil {
                for line in c.lines where line.media == nil && line.checked != true && line.text.contains(wrong) {
                    result.append(.init(day: day, time: line.time, text: line.text))
                }
            }
        }
        return result
    }

    /// その行の、いまの記録（時刻と文が同じもの。文がもう変わっていれば、時刻が同じもの）
    func currentLine(_ ref: MisheardBox.Ref) -> ConversationLog.Line? {
        let lines = conversations(on: ref.day).flatMap(\.lines)
        return lines.first { $0.time == ref.time && $0.text == ref.text } ?? lines.first { $0.time == ref.time }
    }
}

/// 聞き間違いかもしれない言葉の一覧。直すか「合っている」にする。直し終わったら、まとめを作り直す。
struct MisheardView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()
    @State private var searching = false
    @State private var searchNote: String?
    @State private var working: UUID?
    @State private var notes: [UUID: String] = [:]
    @State private var other: MisheardBox.Suspect?
    @State private var otherText = ""
    @State private var addFix = true
    @State private var counts = (conversations: 0, days: 0)
    @State private var redoing = false
    @State private var redoNote: String?

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    var body: some View {
        let list = pipeline.misheard.open
        List {
            Section {
                Toggle("直したら、誤変換の一覧にも足す", isOn: $addFix)
                Button(searching ? "探しています…" : "今すぐ探す") {
                    searching = true
                    Task {
                        let added = await pipeline.findMisheard(force: true)
                        searchNote = added > 0 ? "\(added) 個見つけました。" : "新しく見つかったものはありません。"
                        searching = false
                    }
                }
                .disabled(searching)
                if let searchNote { Text(searchNote).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("直近14日の閉じた会話を Groq の言語モデルに読んでもらい、音を聞き間違えて書いたと思われる言葉を出します（10分に1回ほど、まだ読んでいない会話から）。登録した言葉と、「合っている」にした言葉は出しません。誤変換の一覧に足すと、これからの文字起こしでも自動で直します。")
            }
            ForEach(list) { suspect in
                suspectSection(suspect)
            }
            if counts.conversations > 0 || counts.days > 0 {
                Section {
                    Button(redoing ? "作り直しています…" : "まとめを作り直す（会話 \(counts.conversations)・日 \(counts.days)）") { redo() }
                        .disabled(redoing)
                    if let redoNote { Text(redoNote).font(.footnote).foregroundStyle(.secondary) }
                } footer: {
                    Text("文字を直した会話の見出しと要点を作り直し、その日の「1日のまとめ」も作り直して、ドキュメントの見出しとまとめを置き換えます。この一覧にその日の言葉が残っていなければ、押さなくても次の処理のときに作り直します（今日の1日のまとめは日が変わってから）。")
                }
            }
        }
        .overlay {
            if list.isEmpty && counts.conversations == 0 && counts.days == 0 {
                ContentUnavailableView("聞き間違いらしい言葉はありません", systemImage: "text.badge.checkmark")
            }
        }
        .navigationTitle("聞き間違いかも")
        .onAppear { counts = pipeline.resummarizeCounts() }
        .onDisappear { player.stop() }
        .alert("別の書き方に直す", isPresented: Binding(get: { other != nil }, set: { if !$0 { other = nil } })) {
            TextField("正しい書き方", text: $otherText)
            Button("直す") {
                if let suspect = other { fix(suspect, to: otherText, everywhere: false) }
                other = nil
            }
            Button("キャンセル", role: .cancel) { other = nil }
        } message: {
            Text("「\(other?.wrong ?? "")」を、入れた書き方に置き換えます。")
        }
    }

    @ViewBuilder
    private func suspectSection(_ suspect: MisheardBox.Suspect) -> some View {
        let everywhere = pipeline.misheardOccurrences(of: suspect.wrong)
        Section {
            ForEach(suspect.refs, id: \.self) { ref in lineRow(ref, wrong: suspect.wrong) }
            if let note = notes[suspect.id] {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            } else if working == suspect.id {
                HStack { ProgressView(); Text("直しています…") }
            } else {
                if !suspect.guess.isEmpty {
                    Button("「\(suspect.guess)」に直す（この \(suspect.refs.count) 行）") {
                        fix(suspect, to: suspect.guess, everywhere: false)
                    }
                    if everywhere.count > suspect.refs.count {
                        Button("「\(suspect.guess)」に直す（直近30日の「\(suspect.wrong)」\(everywhere.count) 行すべて）") {
                            fix(suspect, to: suspect.guess, everywhere: true)
                        }
                    }
                }
                Button("別の書き方に直す…") {
                    otherText = suspect.guess
                    other = suspect
                }
                Button("合っている（もう出さない）") {
                    pipeline.misheard.settle(suspect.id, as: .kept)
                }
            }
        } header: {
            Text("「\(suspect.wrong)」" + (suspect.guess.isEmpty ? "" : " → 「\(suspect.guess)」？"))
        } footer: {
            if !suspect.reason.isEmpty { Text(suspect.reason) }
        }
    }

    @ViewBuilder
    private func lineRow(_ ref: MisheardBox.Ref, wrong: String) -> some View {
        let line = pipeline.currentLine(ref)
        let key = "misheard-\(ref.time.timeIntervalSince1970)"
        let audio = line?.audio.flatMap { pipeline.archive.canPlay($0) ? $0 : nil }
        let label = HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.time.string(from: ref.time) + (line?.speaker.map { "　[\($0)]" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Text(highlighted(ref.text, wrong))
            }
            Spacer(minLength: 0)
            if player.loading == key {
                ProgressView()
            } else if audio != nil {
                Image(systemName: player.playing == key ? "stop.circle.fill" : "play.circle").foregroundStyle(Color.accentColor)
            }
        }
        if let audio, let line {
            Button {
                Task { await player.toggle(key, at: line.offset ?? 0) { await pipeline.archive.playableURL(for: audio) } }
            } label: { label }
                .tint(.primary)
        } else {
            label
        }
    }

    /// 怪しい言葉を太字にした文
    private func highlighted(_ text: String, _ wrong: String) -> AttributedString {
        var result = AttributedString(text)
        var searchStart = result.startIndex
        while let range = result[searchStart...].range(of: wrong) {
            result[range].inlinePresentationIntent = .stronglyEmphasized
            result[range].foregroundColor = .orange
            searchStart = range.upperBound
        }
        return result
    }

    private func fix(_ suspect: MisheardBox.Suspect, to right: String, everywhere: Bool) {
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !right.isEmpty, right != suspect.wrong else { return }
        player.stop()
        working = suspect.id
        Task {
            notes[suspect.id] = await pipeline.fixMisheard(suspect, to: right, everywhere: everywhere, addFix: addFix)
            working = nil
            counts = pipeline.resummarizeCounts()
        }
    }

    private func redo() {
        redoing = true
        Task {
            let done = await pipeline.resummarize(force: true)
            counts = pipeline.resummarizeCounts()
            redoNote = done > 0 || counts.conversations == 0 ? "作り直しました（会話 \(done)）。" : "作り直せませんでした（無料枠や通信）。少したってからもう一度。"
            redoing = false
        }
    }
}

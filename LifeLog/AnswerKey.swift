import Foundation
import Observation
import SwiftUI

/// 正解帳。週に1回、その週の記録から30秒ほどの場面を10個選び、本人に「だれが・何を・どの場面で」が合っているかを答えてもらう。
/// 答えをためて、話者の取り違え・文字の誤り・場面の当たりを週ごとの数字にする（設定や新しい版で良くなったかを確かめるため）。
/// 記録の行そのものは変えない（直すのは記録の画面で）。中身は `answerkey.json` に端末ごとに持つ（同期はしない）。
@MainActor
@Observable
final class AnswerKey {
    struct Sample: Codable, Identifiable, Equatable {
        /// 日と行の時刻
        var id: String
        /// その週の月曜（yyyy-MM-dd）
        var week: String
        var day: String
        var time: Date
        /// アプリが書いた文字・話した人・場所・見出し
        var text: String
        var speaker: String?
        var speakerID: String?
        var place: String?
        var title: String?
        var audio: String
        var offset: TimeInterval
        var confidence: Double?
        var noisy: Bool?
        /// 家の PC の多数決で食い違った行の、モデルごとの文
        var votes: [String: String]? = nil
        /// 週の数字には入れない、モデルの当たりやすさを学ぶための追加の問い（食い違った行から選ぶ）
        var extra: Bool? = nil
        /// 本当の文字（合っていれば text と同じ）
        var rightText: String? = nil
        /// 話した人が合っていたか（分からないときは nil のまま）
        var speakerOK: Bool? = nil
        /// 本当に話した人（違ったときだけ）
        var rightSpeaker: String? = nil
        /// 場所・場面が合っていたか
        var sceneOK: Bool? = nil
        /// 本当の場面（違ったときだけ）
        var rightScene: String? = nil
        /// 聞き取れない・答えられないので飛ばした
        var skipped: Bool? = nil
        var answered: Date? = nil

        var isAnswered: Bool { answered != nil }
    }

    /// 週ごとの数字
    struct Score: Equatable {
        var week: String
        var answered: Int
        /// 話者が合っていた割合（答えたものの中で）
        var speaker: Double?
        /// 文字の誤り率（直した文字数 ÷ 本当の文字数）
        var textError: Double?
        /// 場面が合っていた割合
        var scene: Double?
    }

    /// 1週に選ぶ数
    static let perWeek = 10
    /// 食い違った行から足す問いの数（モデルの重みを学ぶため）
    static let extraPerWeek = 3
    /// 始めて2週のあいだは多めに足す（重みが早く効くように。2026-11-06）
    static let extraFirstWeeks = 8

    /// 足す問いの数。それまでに答え合わせをした週が2つより少なければ多め
    static func extraCount(weeksSoFar: Int) -> Int { weeksSoFar < 2 ? extraFirstWeeks : extraPerWeek }
    /// 学んだ重み（"haas:1.10,reazon:0.80" の形）。家の PC に送る
    static let weightsKey = "homePCWeights"
    /// 重みを決めるのに要る、答えた食い違いの行の数
    static let weightsNeed = 8

    private(set) var samples: [Sample] = []

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("answerkey.json")

    init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = saved
        } else {
            // 読めないファイルは上書きせず、脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("answerkey-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    func samples(of week: String) -> [Sample] { samples.filter { $0.week == week }.sorted { $0.time < $1.time } }

    /// その週の分がまだ無ければ足す
    func fill(_ week: String, with picked: [Sample]) {
        guard samples(of: week).isEmpty, !picked.isEmpty else { return }
        samples += picked
        save()
    }

    func answer(_ sample: Sample) {
        guard let i = samples.firstIndex(where: { $0.id == sample.id && $0.week == sample.week }) else { return }
        var copy = sample
        copy.answered = .now
        samples[i] = copy
        save()
        updateWeights()
    }

    /// 答えたものから、モデルごとの重みを決め直して保存する（足りなければ消す＝どれも同じ重み）
    func updateWeights() {
        let weights = Self.weights(samples)
        if weights.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.weightsKey)
        } else {
            let text = weights.keys.sorted().map { $0 + ":" + String(format: "%.2f", weights[$0]!) }.joined(separator: ",")
            UserDefaults.standard.set(text, forKey: Self.weightsKey)
        }
    }

    /// モデルごとの文字の誤り率（食い違った行の答えから）。答えた数とあわせて
    nonisolated static func engineErrors(_ samples: [Sample]) -> [String: (error: Double, count: Int)] {
        var errors: [String: (e: Int, n: Int, count: Int)] = [:]
        for s in samples where s.isAnswered && s.skipped != true {
            guard let right = s.rightText, let votes = s.votes else { continue }
            let r = normalized(right)
            guard !r.isEmpty else { continue }
            for (engine, text) in votes {
                var e = errors[engine] ?? (0, 0, 0)
                e.e += editDistance(normalized(text), r)
                e.n += r.count
                e.count += 1
                errors[engine] = e
            }
        }
        return errors.mapValues { (Double($0.e) / Double(max($0.n, 1)), $0.count) }
    }

    /// 重み＝全体の誤り率の平均 ÷ そのモデルの誤り率（0.5〜2.0）。答えた食い違いの行が足りなければ空
    nonisolated static func weights(_ samples: [Sample]) -> [String: Double] {
        let errors = engineErrors(samples).filter { $0.value.count >= weightsNeed }
        guard errors.count >= 2 else { return [:] }
        let mean = errors.values.map(\.error).reduce(0, +) / Double(errors.count)
        return errors.mapValues { min(2.0, max(0.5, mean / max($0.error, 0.02))) }
    }

    /// 答えを取り消す（もう一度答える）
    func reset(_ sample: Sample) {
        guard let i = samples.firstIndex(where: { $0.id == sample.id && $0.week == sample.week }) else { return }
        samples[i].rightText = nil
        samples[i].speakerOK = nil
        samples[i].rightSpeaker = nil
        samples[i].sceneOK = nil
        samples[i].rightScene = nil
        samples[i].skipped = nil
        samples[i].answered = nil
        save()
        updateWeights()
    }

    /// 新しい週から（追加の問いは数えない）
    var scores: [Score] {
        let groups = Dictionary(grouping: samples.filter { $0.extra != true }, by: \.week)
        return groups.keys.sorted(by: >).map { Self.score($0, groups[$0]!) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    // MARK: - 数える

    nonisolated static func score(_ week: String, _ samples: [Sample]) -> Score {
        let done = samples.filter { $0.isAnswered && $0.skipped != true }
        func rate(_ values: [Bool]) -> Double? {
            values.isEmpty ? nil : Double(values.filter { $0 }.count) / Double(values.count)
        }
        var errors = 0, length = 0
        for s in done {
            guard let right = s.rightText else { continue }
            let r = normalized(right), t = normalized(s.text)
            errors += editDistance(t, r)
            length += max(r.count, 1)
        }
        return Score(week: week, answered: done.count,
                     speaker: rate(done.compactMap(\.speakerOK)),
                     textError: length > 0 ? Double(errors) / Double(length) : nil,
                     scene: rate(done.compactMap(\.sceneOK)))
    }

    /// 比べる形（空白・句読点を除く）
    nonisolated static func normalized(_ text: String) -> [Character] {
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return Array(String(String.UnicodeScalarView(text.unicodeScalars.filter { !drop.contains($0) })))
    }

    /// 文字の編集距離（足す・消す・置き換えるの最小回数）
    nonisolated static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - 選ぶ

    /// その日を含む週の月曜（yyyy-MM-dd）
    nonisolated static func weekKey(_ date: Date, calendar: Calendar = .current) -> String {
        let weekday = calendar.component(.weekday, from: date)  // 1 = 日曜
        let back = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: date)) ?? date
        let c = calendar.dateComponents([.year, .month, .day], from: monday)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 候補から count 個を、場所と話した人（自分・ほかの人）が偏らないように選ぶ。同じ週なら毎回同じものを選ぶ。
    /// 同じ会話からは2つまで、近すぎる行（2分以内）は選ばない。
    nonisolated static func pick(_ candidates: [Sample], count: Int, seed: String) -> [Sample] {
        func hash(_ s: String) -> UInt64 {
            // 端末や起動ごとに変わらない簡単なハッシュ（FNV-1a）
            var h: UInt64 = 14_695_981_039_346_656_037
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
            return h
        }
        var groups: [String: [Sample]] = [:]
        for c in candidates {
            let who = c.speakerID == SpeakerLabeler.selfID ? "self" : "other"
            groups[(c.place ?? "?") + "|" + who, default: []].append(c)
        }
        var queues = groups.keys.sorted().map { key in
            groups[key]!.sorted { hash(seed + $0.id) < hash(seed + $1.id) }
        }
        var picked: [Sample] = []
        var perConversation: [String: Int] = [:]
        while picked.count < count, queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where picked.count < count {
                while let next = queues[i].first {
                    queues[i].removeFirst()
                    let talk = next.day + "|" + (next.title ?? "")
                    let tooClose = picked.contains { abs($0.time.timeIntervalSince(next.time)) < 120 }
                    if tooClose || perConversation[talk, default: 0] >= 2 { continue }
                    perConversation[talk, default: 0] += 1
                    picked.append(next)
                    break
                }
            }
        }
        return picked.sorted { $0.time < $1.time }
    }
}

// MARK: - 記録から選ぶ

extension Pipeline {
    /// 今週の分（まだ選んでいなければ、直近7日の記録から選んで足す）
    func answerKeyThisWeek() -> [AnswerKey.Sample] {
        let week = AnswerKey.weekKey(.now)
        if answerKey.samples(of: week).isEmpty {
            let candidates = answerKeyCandidates(week: week)
            var picked = AnswerKey.pick(candidates, count: AnswerKey.perWeek, seed: week)
            // 食い違った行（モデルごとの文が残っている行）から、重みを学ぶための問いを足す
            let taken = Set(picked.map(\.id))
            let split = candidates.filter { $0.votes != nil && !taken.contains($0.id) }
            let weeksSoFar = Set(answerKey.samples.map(\.week)).count
            picked += AnswerKey.pick(split, count: AnswerKey.extraCount(weeksSoFar: weeksSoFar), seed: week + "extra").map { s in
                var copy = s
                copy.extra = true
                return copy
            }
            answerKey.fill(week, with: picked.sorted { $0.time < $1.time })
        }
        return answerKey.samples(of: week)
    }

    /// 直近7日の、音声のある・会話の（放送ではない）・手で直していない・8文字以上の行
    private func answerKeyCandidates(week: String) -> [AnswerKey.Sample] {
        var result: [AnswerKey.Sample] = []
        for day in recordedDays().prefix(7) {
            for c in conversations(on: day) where c.media == nil {
                for line in c.lines where line.media == nil && line.checked != true && line.text.count >= 8 {
                    guard let audio = line.audio, let offset = line.offset else { continue }
                    result.append(AnswerKey.Sample(
                        id: day + "|" + String(Int(line.time.timeIntervalSince1970)), week: week, day: day,
                        time: line.time, text: line.text, speaker: line.speaker, speakerID: line.speakerID,
                        place: c.place, title: c.title, audio: audio, offset: offset,
                        confidence: line.confidence, noisy: line.noisy, votes: line.votes))
                }
            }
        }
        return result
    }
}

// MARK: - 画面

/// 答え合わせ（週5分）と、週ごとの数字
struct AnswerKeyView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()
    @State private var week: [AnswerKey.Sample] = []
    @State private var editing: AnswerKey.Sample?

    var body: some View {
        let key = pipeline.answerKey
        let answered = week.filter { current($0).isAnswered }.count
        List {
            Section {
                if week.isEmpty {
                    Text("直近7日に、音声の残っている会話の行がまだありません。").foregroundStyle(.secondary)
                }
                ForEach(week) { s in
                    let sample = current(s)
                    Button {
                        editing = sample
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: sample.isAnswered ? (sample.skipped == true ? "forward.circle" : "checkmark.circle.fill")
                                                                : "circle")
                                .foregroundStyle(sample.isAnswered ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.text).foregroundStyle(.primary).lineLimit(2)
                                Text(caption(sample)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("今週の答え合わせ（\(answered)/\(week.count)）")
            } footer: {
                Text("押すと、その場面の音声を聞いて「だれが・何を・どこで」が合っているかを答えられます。記録の文字は変えません（直したいときは記録の画面で）。週に5分ほどで、下の数字が育ちます。")
            }
            let scores = key.scores.filter { $0.answered > 0 }
            if !scores.isEmpty {
                Section {
                    ForEach(scores, id: \.week) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(s.week) の週（\(s.answered) 問）").font(.subheadline)
                            HStack(spacing: 14) {
                                metric("話者", s.speaker.map { percent($0) + " 正しい" })
                                metric("文字", s.textError.map { percent($0) + " 誤り" })
                                metric("場面", s.scene.map { percent($0) + " 正しい" })
                            }
                            .font(.caption)
                        }
                    }
                } header: {
                    Text("週ごとの数字")
                } footer: {
                    Text("文字の誤りは、直した文字の数を本当の文字の数で割ったもの（空白と句読点は数えない）。少ないほど良い。話者と場面は、答えたものの中で合っていた割合。")
                }
            }
            let engines = AnswerKey.engineErrors(key.samples)
            if !engines.isEmpty {
                let weights = AnswerKey.weights(key.samples)
                Section {
                    ForEach(engines.keys.sorted(), id: \.self) { name in
                        let e = engines[name]!
                        LabeledContent(Self.engineName(name)) {
                            Text(percent(e.error) + " 誤り・\(e.count) 問" + (weights[name].map { "・重み " + String(format: "%.2f", $0) } ?? ""))
                        }
                    }
                } header: {
                    Text("家の PC のモデルごとの当たり")
                } footer: {
                    Text("食い違った行の答えから数えます（印「＋」の問い）。どのモデルも \(AnswerKey.weightsNeed) 問以上たまると、よく当たるモデルの票を重く（0.5〜2倍）して多数決します。")
                }
            }
        }
        .navigationTitle("答え合わせ")
        .onAppear { week = pipeline.answerKeyThisWeek() }
        .onDisappear { player.stop() }
        .sheet(item: $editing) { sample in
            NavigationStack {
                AnswerSheet(sample: sample, player: player) { saved in
                    pipeline.answerKey.answer(saved)
                    editing = nil
                } onReset: {
                    pipeline.answerKey.reset(sample)
                    editing = nil
                }
            }
        }
    }

    private func current(_ s: AnswerKey.Sample) -> AnswerKey.Sample {
        pipeline.answerKey.samples.first { $0.id == s.id && $0.week == s.week } ?? s
    }

    private func caption(_ s: AnswerKey.Sample) -> String {
        var parts = [(s.extra == true ? "＋ " : "") + s.time.formatted(date: .abbreviated, time: .shortened)]
        if let speaker = s.speaker { parts.append(speaker) }
        if let place = s.place { parts.append(place) }
        return parts.joined(separator: "・")
    }

    private func percent(_ v: Double) -> String { String(Int((v * 100).rounded())) + "%" }

    private static func engineName(_ name: String) -> String {
        switch name {
        case "haas": "Haas-ja"
        case "reazon": "ReazonSpeech"
        case "whisper": "Whisper"
        case "cloud": "クラウド"
        default: name
        }
    }

    private func metric(_ name: String, _ value: String?) -> some View {
        Text(name + " " + (value ?? "—"))
    }
}

/// 1問。音声を聞いて、文字・話した人・場面を答える。
private struct AnswerSheet: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    @State var sample: AnswerKey.Sample
    let player: ClipPlayer
    var onSave: (AnswerKey.Sample) -> Void
    var onReset: () -> Void
    @State private var text = ""
    @State private var textOK = true
    @State private var speakerChoice = Choice.unknown
    @State private var otherSpeaker = ""
    @State private var sceneChoice = Choice.unknown
    @State private var scene = ""

    enum Choice: Hashable { case right, wrong, unknown }

    var body: some View {
        Form {
            Section {
                let key = "answer-" + sample.id
                Button {
                    Task {
                        let start = max(0, sample.offset - 2)
                        await player.toggle(key, at: start, until: start + 20) {
                            await pipeline.archive.playableURL(for: sample.audio)
                        }
                    }
                } label: {
                    if player.loading == key {
                        ProgressView()
                    } else {
                        Label(player.playing == key ? "止める" : "その場面を聞く（20秒）",
                              systemImage: player.playing == key ? "stop.circle.fill" : "play.circle")
                    }
                }
                Text(sample.time.formatted(date: .abbreviated, time: .shortened)
                     + (sample.title.map { "・" + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(sample.text)
                Toggle("文字は合っている", isOn: $textOK)
                if !textOK {
                    TextField("本当に言ったこと", text: $text, axis: .vertical)
                }
            } header: {
                Text("何を")
            } footer: {
                Text("言い間違い・言いよどみまでそろえなくて大丈夫です。意味の変わる違い・名前や数字の違いを直してください。")
            }
            Section("だれが（アプリは「\(sample.speaker ?? "分からない")」）") {
                Picker("話した人", selection: $speakerChoice) {
                    Text("合っている").tag(Choice.right)
                    Text("違う").tag(Choice.wrong)
                    Text("分からない").tag(Choice.unknown)
                }
                .pickerStyle(.segmented)
                if speakerChoice == .wrong {
                    Picker("本当は", selection: $otherSpeaker) {
                        Text("選ぶ").tag("")
                        ForEach(names, id: \.self) { Text($0).tag($0) }
                        Text("知らない人").tag("知らない人")
                    }
                }
            }
            Section("どこで（アプリは「\(sample.place ?? "場所なし")」）") {
                Picker("場面", selection: $sceneChoice) {
                    Text("合っている").tag(Choice.right)
                    Text("違う").tag(Choice.wrong)
                    Text("分からない").tag(Choice.unknown)
                }
                .pickerStyle(.segmented)
                if sceneChoice == .wrong {
                    TextField("本当はどこで・何をしていた", text: $scene)
                }
            }
            Section {
                Button("聞き取れないので飛ばす") {
                    var copy = sample
                    copy.skipped = true
                    onSave(copy)
                }
                if sample.isAnswered {
                    Button("答えを取り消す", role: .destructive) { onReset() }
                }
            }
        }
        .navigationTitle("答え合わせ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("答える") {
                    var copy = sample
                    copy.skipped = nil
                    let right = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    copy.rightText = textOK || right.isEmpty ? sample.text : right
                    copy.speakerOK = speakerChoice == .unknown ? nil : speakerChoice == .right
                    copy.rightSpeaker = speakerChoice == .wrong && !otherSpeaker.isEmpty ? otherSpeaker : nil
                    copy.sceneOK = sceneChoice == .unknown ? nil : sceneChoice == .right
                    copy.rightScene = sceneChoice == .wrong && !scene.isEmpty ? scene : nil
                    onSave(copy)
                }
            }
        }
        .onAppear {
            text = sample.rightText ?? sample.text
            textOK = sample.rightText == nil || sample.rightText == sample.text
            speakerChoice = sample.speakerOK.map { $0 ? .right : .wrong } ?? .unknown
            otherSpeaker = sample.rightSpeaker ?? ""
            sceneChoice = sample.sceneOK.map { $0 ? .right : .wrong } ?? .unknown
            scene = sample.rightScene ?? ""
        }
        .onDisappear { player.stop() }
    }

    /// 名前の付いた人（自分を先に）
    private var names: [String] {
        let named = pipeline.people.filter(\.isNamed)
        return named.filter(\.isSelf).map(\.displayName) + named.filter { !$0.isSelf }.map(\.displayName).sorted()
    }
}

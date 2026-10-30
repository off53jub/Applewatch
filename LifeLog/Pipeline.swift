import AVFoundation
import Observation

/// 録音 → 文字起こし → Google ドキュメントへの追記、をつなぐ。
/// 音声は追記に成功してから消すので、圏外や失敗があっても次の機会にやり直せる。
@MainActor
@Observable
final class Pipeline {
    private(set) var isRecording = false
    private(set) var pendingCount = 0
    private(set) var lastLines: [String] = []
    private(set) var message = ""
    private(set) var email: String?
    private(set) var watchStatus = "接続を準備中"
    /// 直近の区切りをどのモデルで文字起こししたか
    private(set) var lastEngine = ""
    let settings = TranscriptionSettings()
    /// 話者の聞き分け（自分の声・話し相手）
    let speakers = SpeakerLabeler()
    private(set) var people: [SpeakerLabeler.Person] = []
    private(set) var hasSelfVoice = false
    var speakerLabelsOn = UserDefaults.standard.bool(forKey: "speakerLabels") {
        didSet {
            UserDefaults.standard.set(speakerLabelsOn, forKey: "speakerLabels")
            if speakerLabelsOn { Task { await loadSpeakers() } }
        }
    }

    private let recorder = Recorder()
    private let docs = GoogleDocs()
    private let receiver = PhoneReceiver()
    private var processing = false

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        recorder.onChunk = { [weak self] _ in self?.processQueue() }
        recorder.onStop = { [weak self] reason in
            self?.isRecording = false
            self?.message = reason
        }
        pendingCount = Storage.pendingChunks().count
        receiver.onFile = { [weak self] in
            self?.pendingCount = Storage.pendingChunks().count
            self?.processQueue()
        }
        receiver.onStateChange = { [weak self] in self?.watchStatus = $0 }
        receiver.activate()
    }

    /// 聞き分けのモデルを用意し、覚えている声を読み込む。
    func loadSpeakers() async {
        do {
            try await speakers.prepare()
            hasSelfVoice = await speakers.hasSelfVoice
            people = await speakers.people()
        } catch {
            message = "話者の聞き分けを準備できませんでした: \(error.localizedDescription)"
        }
    }

    func enrollSelf(from url: URL) async throws {
        try await speakers.enrollSelf(from: url)
        hasSelfVoice = await speakers.hasSelfVoice
    }

    func renamePerson(_ id: String, to name: String) async {
        await speakers.rename(id, to: name)
        people = await speakers.people()
    }

    func removePerson(_ id: String) async {
        await speakers.remove(id)
        people = await speakers.people()
    }

    func restoreSignIn() async {
        await docs.restore()
        email = docs.signedInEmail
        processQueue()
        if speakerLabelsOn { await loadSpeakers() }
    }

    func signIn() async {
        do {
            try await docs.signIn()
            email = docs.signedInEmail
            processQueue()
        } catch {
            message = "ログインできませんでした: \(error.localizedDescription)"
        }
    }

    func signOut() {
        docs.signOut()
        email = nil
    }

    func toggleRecording() async {
        if isRecording {
            recorder.stop()
            isRecording = false
            return
        }
        do {
            message = "日本語モデルを確認中…"
            try await Transcriber.prepare()
            try recorder.start()
            isRecording = true
            message = ""
        } catch {
            message = "録音を始められませんでした: \(error.localizedDescription)"
        }
    }

    /// 溜まっている音声を古い順に処理する。
    func processQueue() {
        guard !processing, email != nil else { return }
        processing = true
        Task {
            defer {
                processing = false
                pendingCount = Storage.pendingChunks().count
            }
            for url in Storage.pendingChunks() where !isActiveChunk(url) {
                do {
                    try await process(url)
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    message = "処理に失敗しました（あとで再試行します）: \(error.localizedDescription)"
                    return
                }
                pendingCount = Storage.pendingChunks().count
            }
        }
    }

    private func process(_ url: URL) async throws {
        let start = Storage.startDate(of: url) ?? .now
        // まず端末内で文字起こしする（無料）。何も聞き取れなければ、お金をかけずにここで終わる。
        let local = try await Transcriber.transcribe(url)
        guard !local.isEmpty else { return }
        var entries: [(offset: TimeInterval?, text: String)] = local.map { ($0.offset, $0.text) }
        lastEngine = "端末内"
        if settings.shouldUseCloud, let key = settings.apiKey {
            do {
                let cloud = try await CloudTranscriber.transcribe(
                    url, provider: settings.provider, apiKey: key, keywords: settings.keywords)
                settings.addUsage(seconds: Self.duration(of: url))
                lastEngine = cloud.model
                if !cloud.lines.isEmpty {
                    entries = cloud.lines.map { ($0.offset, $0.text) }
                }
            } catch CloudTranscriber.Failure.limited {
                // 無料枠を使い切ったら、この区切りは端末内の結果で済ませる（高精度はオンのまま）
                lastEngine = "端末内（無料枠の上限のため）"
            } catch CloudTranscriber.Failure.rejected(let reason) {
                // キーや残高の問題は待っても直らないので、高精度をオフにして端末内の結果を使う
                settings.useCloud = false
                message = reason + "（高精度をオフにして、端末内の文字起こしで続けます）"
            }
        }
        let names = await speakerNames(for: entries, in: url)
        let lines = entries.enumerated().map { i, entry in
            let who = names[i].map { "[\($0)] " } ?? ""
            guard let offset = entry.offset else { return who + entry.text }
            return "\(timeFormatter.string(from: start.addingTimeInterval(offset)))  \(who)\(entry.text)"
        }
        let text = lines.map { $0 + "\n" }.joined()
        try await docs.append(text, day: dayFormatter.string(from: start))
        lastLines = Array((lastLines + lines).suffix(20))
        if speakerLabelsOn { people = await speakers.people() }
    }

    /// 各行を、その時間にいちばん長く話していた人に結びつける。聞き分けがオフ・失敗したときは nil。
    private func speakerNames(for entries: [(offset: TimeInterval?, text: String)], in url: URL) async -> [String?] {
        let none = [String?](repeating: nil, count: entries.count)
        guard speakerLabelsOn, let segments = try? await speakers.label(url), !segments.isEmpty else { return none }
        let chunkEnd = Self.duration(of: url)
        return entries.indices.map { i in
            guard let from = entries[i].offset else { return nil }
            let to = entries[(i + 1)...].lazy.compactMap { $0.offset }.first ?? chunkEnd
            let best = segments.max { a, b in
                overlap(a, from, to) < overlap(b, from, to)
            }
            guard let best, overlap(best, from, to) > 0 else { return nil }
            return best.name
        }
    }

    private func overlap(_ s: SpeakerLabeler.Segment, _ from: TimeInterval, _ to: TimeInterval) -> TimeInterval {
        max(0, min(s.end, to) - max(s.start, from))
    }

    private static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// 録音中の最新ファイルはまだ書き込み中なので飛ばす。
    private func isActiveChunk(_ url: URL) -> Bool {
        isRecording && url == Storage.pendingChunks().last
    }
}

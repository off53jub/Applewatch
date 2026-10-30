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

    func restoreSignIn() async {
        await docs.restore()
        email = docs.signedInEmail
        processQueue()
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
        var lines = local.map { line in
            "\(timeFormatter.string(from: start.addingTimeInterval(line.offset)))  \(line.text)"
        }
        lastEngine = "端末内"
        if settings.shouldUseCloud, let key = settings.apiKey {
            do {
                let cloud = try await CloudTranscriber.transcribe(
                    url, provider: settings.provider, apiKey: key, keywords: settings.keywords)
                settings.addUsage(seconds: Self.duration(of: url))
                lastEngine = cloud.model
                if !cloud.lines.isEmpty {
                    lines = cloud.lines.map { line in
                        guard let offset = line.offset else { return line.text }
                        return "\(timeFormatter.string(from: start.addingTimeInterval(offset)))  \(line.text)"
                    }
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
        let text = lines.map { $0 + "\n" }.joined()
        try await docs.append(text, day: dayFormatter.string(from: start))
        lastLines = Array((lastLines + lines).suffix(20))
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

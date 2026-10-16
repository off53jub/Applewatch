import Foundation
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

    private let recorder = Recorder()
    private let docs = GoogleDocs()
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
        let lines = try await Transcriber.transcribe(url)
        guard !lines.isEmpty else { return }
        let text = lines.map { line in
            "\(timeFormatter.string(from: start.addingTimeInterval(line.offset)))  \(line.text)\n"
        }.joined()
        try await docs.append(text, day: dayFormatter.string(from: start))
        lastLines = Array((lastLines + text.split(separator: "\n").map(String.init)).suffix(20))
    }

    /// 録音中の最新ファイルはまだ書き込み中なので飛ばす。
    private func isActiveChunk(_ url: URL) -> Bool {
        isRecording && url == Storage.pendingChunks().last
    }
}

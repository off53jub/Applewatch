import CoreML
import Foundation
import HaasCore
import Observation

/// iPhone の中で動く日本語の音声認識 Haas-ja-v1.0（Third Intelligence、Apache-2.0）の Core ML 版
/// （Sanami/haas-ja-coreml、非公式の変換）。重い部分は Neural Engine で動く。
///
/// モデル（約620MB）は初回に Hugging Face から取ってきて、この iPhone 用に変換して置いておく。
/// Whisper と違い、雑音にもっともらしい文を作る癖がほとんど無い。
/// 区切りの中で端末内の文字起こしが声を聞き取った区間だけを、14秒までのまとまりにして文字にする。
@MainActor
@Observable
final class HaasEngine {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded
    /// 文字起こしに使う（モデルが揃っているときだけ効く）
    var enabled = UserDefaults.standard.bool(forKey: "haasOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "haasOn") }
    }

    var isUsable: Bool { enabled && state == .ready }

    /// Hugging Face の版（CI の Swift 部品と同じ版に固定する）
    private static let revision = "62f542657b454afa7873424e3dfb6d7a1d9c270d"
    private static let base = "https://huggingface.co/Sanami/haas-ja-coreml/resolve/\(revision)/"
    private static let models = ["encoder_T1504_w8", "decoder", "joint_enc", "joint"]
    private static let packageFiles = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                                       "Data/com.apple.CoreML/weights/weight.bin"]
    /// ダウンロードの大きさの目安（進み具合の表示用）
    private static let totalBytes = 622_000_000.0

    nonisolated static let dir: URL = {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("haas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dir
        try? url.setResourceValues(values)
        return dir
    }()

    private static func compiled(_ name: String) -> URL { dir.appendingPathComponent(name + ".mlmodelc") }

    init() {
        if Self.models.allSatisfy({ FileManager.default.fileExists(atPath: Self.compiled($0).path) }) {
            state = .ready
        }
    }

    // MARK: - ダウンロード

    func download() async {
        if case .downloading = state { return }
        state = .downloading(0)
        var done = 0.0
        do {
            for name in Self.models where !FileManager.default.fileExists(atPath: Self.compiled(name).path) {
                let package = Self.dir.appendingPathComponent(name + ".mlpackage", isDirectory: true)
                for file in Self.packageFiles {
                    let dest = package.appendingPathComponent(file)
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let url = URL(string: Self.base + name + ".mlpackage/" + file)!
                    let before = done
                    let progress = ProgressDelegate { [weak self] bytes in
                        Task { @MainActor in
                            guard let self, case .downloading = self.state else { return }
                            self.state = .downloading(min(0.99, (before + Double(bytes)) / Self.totalBytes))
                        }
                    }
                    let (temp, response) = try await URLSession.shared.download(from: url, delegate: progress)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "\(file) を取ってこられませんでした"])
                    }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: temp, to: dest)
                    done += Double((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                state = .preparing
                // この iPhone 用に変換して置く
                let compiled = try await MLModel.compileModel(at: package)
                try? FileManager.default.removeItem(at: Self.compiled(name))
                try FileManager.default.moveItem(at: compiled, to: Self.compiled(name))
                try? FileManager.default.removeItem(at: package)
                state = .downloading(min(0.99, done / Self.totalBytes))
            }
            state = .preparing
            // 初回の読み込みで Neural Engine 向けの準備をする（数十秒かかる）
            try await HaasRunner.shared.load()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func remove() async {
        await HaasRunner.shared.unload()
        try? FileManager.default.removeItem(at: Self.dir)
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        enabled = false
        state = .notDownloaded
    }

    // MARK: - 文字起こし

    /// 区切りを文字にする。local は端末内の文字起こし（声のある区間を決めるのに使う）。
    func transcribe(_ url: URL, local: [Transcriber.Line]) async throws -> [CloudTranscriber.Line] {
        let segments = Self.segments(from: local)
        guard !segments.isEmpty else { return [] }
        return try await HaasRunner.shared.transcribe(url, segments: segments)
    }

    /// 端末内の文字起こしの区間を、間が1秒未満なら14秒まで1つにまとめる。前後に少し余白を付ける。
    static func segments(from local: [Transcriber.Line]) -> [(start: TimeInterval, end: TimeInterval)] {
        var result: [(start: TimeInterval, end: TimeInterval)] = []
        for line in local.sorted(by: { $0.offset < $1.offset }) {
            let end = max(line.end, line.offset + 0.5)
            if let last = result.last, line.offset - last.end < 1.0, end - last.start <= 14 {
                result[result.count - 1].end = max(last.end, end)
            } else {
                result.append((line.offset, end))
            }
        }
        return result.map { (max(0, $0.start - 0.3), $0.end + 0.4) }
    }

    func testRecent() async -> String {
        guard let url = Storage.keptAudio().last else { return "試せる音声がありません（録音して少し待ってください）。" }
        do {
            let started = Date()
            let local = try await Transcriber.transcribe(url)
            let localTime = Date().timeIntervalSince(started)
            let t = Date()
            let lines = try await transcribe(url, local: local)
            let haasTime = Date().timeIntervalSince(t)
            let text = lines.map(\.text).joined(separator: "\n")
            return "\(url.lastPathComponent)\n端末内の聞き取り \(String(format: "%.1f", localTime)) 秒、Haas-ja \(String(format: "%.1f", haasTime)) 秒\n\n"
                + (text.isEmpty ? "（声が聞き取れませんでした）" : text)
        } catch {
            return "試せませんでした: \(error.localizedDescription)"
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onBytes: (Int64) -> Void
        init(onBytes: @escaping (Int64) -> Void) { self.onBytes = onBytes }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onBytes(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}

/// モデルを読み込んで動かす（画面の糸を止めないよう、別の糸で）。
actor HaasRunner {
    static let shared = HaasRunner()
    private var asr: HaasASR?

    func load() throws {
        guard asr == nil else { return }
        guard let frontend = Bundle.main.url(forResource: "frontend", withExtension: "bin"),
              let vocab = Bundle.main.url(forResource: "vocab", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Haas-ja の部品がアプリに入っていません"])
        }
        let dir = HaasEngine.dir
        asr = try HaasASR(models: HaasASR.Models(encoder: dir.appendingPathComponent("encoder_T1504_w8.mlmodelc"),
                                                 decoder: dir.appendingPathComponent("decoder.mlmodelc"),
                                                 jointEnc: dir.appendingPathComponent("joint_enc.mlmodelc"),
                                                 joint: dir.appendingPathComponent("joint.mlmodelc")),
                          frontend: frontend, vocab: vocab)
    }

    func unload() { asr = nil }

    /// 16kHz の音（ライブの切れ目）をそのまま文字にする。長いときは14秒ずつ。
    func transcribe(samples: [Float]) throws -> String {
        try load()
        guard let asr else { return "" }
        let window = 14 * 16_000
        var text = ""
        var from = 0
        while from < samples.count {
            let to = min(samples.count, from + window)
            if to - from > Int(0.3 * 16_000) {
                text += try asr.transcribe(Array(samples[from..<to])).text
            }
            from = to
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(_ url: URL, segments: [(start: TimeInterval, end: TimeInterval)]) throws -> [CloudTranscriber.Line] {
        try load()
        guard let asr else { return [] }
        let audio = try AudioLoader.load(url)
        let rate = 16_000.0
        var lines: [CloudTranscriber.Line] = []
        for segment in segments {
            let from = min(audio.count, Int(segment.start * rate))
            let to = min(audio.count, Int(segment.end * rate))
            // 短すぎる区間は特徴を作れない
            guard to - from > Int(0.3 * rate) else { continue }
            let text = try asr.transcribe(Array(audio[from..<to])).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(CloudTranscriber.Line(offset: segment.start, text: text))
        }
        return lines
    }
}

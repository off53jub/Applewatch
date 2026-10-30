import CoreML
import FluidAudio
import Foundation

/// 声の特徴（話者の埋め込み）で「誰が話したか」を聞き分ける。iPhone の中だけで動き、無料。
/// 一度聞いた声は覚えておき、次の区切りでも同じ人として扱う。自分の声は登録して「自分」と出す。
/// 名前の分からない声は「人物1」などと出し、あとから名前を付けられる。
actor SpeakerLabeler {
    struct Segment: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let name: String
    }

    struct Person: Identifiable, Sendable {
        let id: String
        let name: String
        let minutes: Int
        let lastHeard: Date
    }

    /// 読み込んだ DiarizerManager をこの actor に渡すための入れ物（渡したあとは actor だけが触る）
    private final class Loaded: @unchecked Sendable {
        let manager: DiarizerManager
        init(manager: DiarizerManager) { self.manager = manager }
    }

    static let selfID = "me"
    static let selfName = "自分"

    private var diarizer: DiarizerManager?
    private var loading: Task<Loaded, Error>?

    private static let storeURL: URL = {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("speakers.json")
    }()

    /// モデル（数十 MB）が無ければダウンロードし、覚えている声を読み込む。
    func prepare() async throws {
        guard diarizer == nil else { return }
        // 同時に呼ばれても、ダウンロードは1回だけにする
        let task = loading ?? Task {
            // 録音中は画面が消えていても処理するので、バックグラウンドで使えない GPU は使わない
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try await DiarizerModels.downloadIfNeeded(configuration: configuration)
            let manager = DiarizerManager()
            manager.initialize(models: models)
            if let data = try? Data(contentsOf: Self.storeURL),
               let speakers = try? JSONDecoder().decode([Speaker].self, from: data) {
                manager.initializeKnownSpeakers(speakers)
            }
            return Loaded(manager: manager)
        }
        loading = task
        do {
            let loaded = try await task.value
            if diarizer == nil { diarizer = loaded.manager }
        } catch {
            loading = nil
            throw error
        }
    }

    var hasSelfVoice: Bool {
        diarizer?.speakerManager.getSpeaker(for: Self.selfID) != nil
    }

    /// 自分だけが話している録音から、自分の声を登録する。
    func enrollSelf(from url: URL) async throws {
        try await prepare()
        guard let diarizer else { return }
        let samples = try AudioConverter().resampleAudioFile(url)
        let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
        diarizer.speakerManager.upsertSpeaker(
            Speaker(id: Self.selfID, name: Self.selfName, currentEmbedding: embedding,
                    duration: Float(samples.count) / 16_000, isPermanent: true))
        save()
    }

    /// 1つの区切りの中で、いつ誰が話したかを返す。
    func label(_ url: URL) async throws -> [Segment] {
        try await prepare()
        guard let diarizer else { return [] }
        let samples = try AudioConverter().resampleAudioFile(url)
        let result = try diarizer.performCompleteDiarization(samples)
        // 名前を付けていない声で、2週間聞いていないものは忘れる（通りすがりの人など）
        diarizer.speakerManager.removeSpeakersInactive(for: 14 * 24 * 3600)
        save()
        return result.segments.map { segment in
            Segment(start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds),
                    name: displayName(for: segment.speakerId))
        }
    }

    /// 自分以外の、これまでに聞いた声。よく話した順。
    func people() -> [Person] {
        guard let diarizer else { return [] }
        return diarizer.speakerManager.getSpeakerList()
            .filter { $0.id != Self.selfID }
            .sorted { $0.duration > $1.duration }
            .map { Person(id: $0.id, name: displayName(for: $0.id),
                          minutes: Int($0.duration / 60), lastHeard: $0.updatedAt) }
    }

    /// 名前を付けた人は、しばらく聞かなくても消さない。
    func rename(_ id: String, to name: String) {
        guard var speaker = diarizer?.speakerManager.getSpeaker(for: id) else { return }
        speaker.name = name
        speaker.isPermanent = true
        diarizer?.speakerManager.upsertSpeaker(speaker)
        save()
    }

    func remove(_ id: String) {
        diarizer?.speakerManager.removeSpeaker(id, keepIfPermanent: false)
        save()
    }

    private func displayName(for id: String) -> String {
        guard let speaker = diarizer?.speakerManager.getSpeaker(for: id) else { return "人物\(id)" }
        return speaker.name == speaker.id ? "人物\(id)" : speaker.name
    }

    private func save() {
        guard let speakers = diarizer?.speakerManager.getSpeakerList(),
              let data = try? JSONEncoder().encode(speakers) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

import CoreML
import FluidAudio
import Foundation

/// 声の特徴（話者の埋め込み）で「誰が話したか」を聞き分ける。iPhone の中だけで動き、無料。
///
/// 1. 区切り（5分）の中で、FluidAudio に「同じ声のまとまり」に分けてもらう。
/// 2. まとまりごとに声の特徴を平均し、覚えている人と照らし合わせる。人ごとに声をいくつも覚えておき
///    （iPhone と時計、静かな所と騒がしい所で声の聞こえ方が違うため）、近いもの上位3つの平均で比べる。
/// 3. 職場にいるときは職場の人を、それ以外では職場以外の人を先に比べる。別の場の人は、よほど近いときだけ選ぶ。
/// 4. どの人にも近くなければ、新しい「人物N」として覚える。短すぎて分からない声には名前を付けない。
/// 5. はっきり一致したときだけ、その声を覚え足す。記録から「この声は誰」と直した声は、必ず覚えて消さない。
actor SpeakerLabeler {
    enum Context: String, Codable, CaseIterable, Identifiable, Sendable {
        case work, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .work: "職場"
            case .other: "職場以外"
            }
        }
    }

    struct Segment: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let personID: String
        let name: String
    }

    struct Voice: Codable, Sendable {
        let embedding: [Float]
        /// 登録や手直しで覚えた声。自動では消さない。
        let pinned: Bool
        let added: Date
    }

    /// 聞き直し用の、その人が話していたところ
    struct Sample: Codable, Sendable, Hashable {
        let audio: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Person: Codable, Identifiable, Sendable {
        let id: String
        /// 付けた名前。nil なら「人物N」
        var name: String?
        /// どちらの場で会う人か。nil ならどちらでも
        var context: Context?
        var voices: [Voice] = []
        var seconds: Double = 0
        var lastHeard: Date = .now
        var samples: [Sample] = []

        var isSelf: Bool { id == SpeakerLabeler.selfID }
        var displayName: String { isSelf ? SpeakerLabeler.selfName : name ?? "人物\(id)" }
        var isNamed: Bool { isSelf || name != nil }
        var minutes: Int { Int(seconds / 60) }
        var pinnedCount: Int { voices.filter(\.pinned).count }
    }

    private struct Store: Codable {
        var people: [Person] = []
        var nextID = 1
    }

    /// 読み込んだ DiarizerManager をこの actor に渡すための入れ物（渡したあとは actor だけが触る）
    private final class Loaded: @unchecked Sendable {
        let manager: DiarizerManager
        init(manager: DiarizerManager) { self.manager = manager }
    }

    static let selfID = "me"
    static let selfName = "自分"

    /// これより近ければ同じ人（コサイン距離。0 が同じ、1 が無関係）
    private static let accept: Float = 0.5
    /// 別の場の人や、2番目の候補と差が小さいときは、これより近いときだけ選ぶ
    private static let strict: Float = 0.38
    /// 声を覚え足すのは、これより近くて3秒以上話していたときだけ
    private static let learn: Float = 0.33
    private static let maxAutoVoices = 20

    private var diarizer: DiarizerManager?
    private var loading: Task<Loaded, Error>?
    private var store = Store()

    private static let storeURL = URL.applicationSupportDirectory.appendingPathComponent("people.json")
    /// 以前の形式（FluidAudio の Speaker の一覧）
    private static let legacyURL = URL.applicationSupportDirectory.appendingPathComponent("speakers.json")

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
            return Loaded(manager: manager)
        }
        loading = task
        do {
            let loaded = try await task.value
            if diarizer == nil {
                diarizer = loaded.manager
                load()
            }
        } catch {
            loading = nil
            throw error
        }
    }

    var hasSelfVoice: Bool { person(Self.selfID)?.voices.isEmpty == false }

    func people() -> [Person] {
        store.people.sorted { $0.seconds > $1.seconds }
    }

    func name(of id: String) -> String? { person(id)?.displayName }

    // MARK: - 聞き分け

    /// 1つの区切りの中で、いつ誰が話したかを返す。context はその時いた場（分からなければ nil）。
    func label(_ url: URL, context: Context?) async throws -> [Segment] {
        try await prepare()
        guard let diarizer else { return [] }
        let samples = try AudioConverter().resampleAudioFile(url)
        // 区切りの中だけで声を分けてもらう（前の区切りの声とは、下で自分で照らし合わせる）
        diarizer.speakerManager.reset()
        diarizer.speakerManager.speakerThreshold = 0.55
        let result = try diarizer.performCompleteDiarization(samples)
        diarizer.speakerManager.reset()

        // 声のまとまりごとに、特徴の平均（話した長さで重み付け）と長さを出す
        struct Cluster {
            var sum = [Float](repeating: 0, count: 256)
            var seconds: Double = 0
            var longest: (start: Double, end: Double) = (0, 0)
            var embedding: [Float] { Self.normalized(sum) }
            static func normalized(_ v: [Float]) -> [Float] {
                let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
                return n > 0 ? v.map { $0 / n } : v
            }
        }
        var clusters: [String: Cluster] = [:]
        for s in result.segments where !s.speakerId.isEmpty && s.embedding.count == 256 {
            let seconds = Double(s.durationSeconds)
            var c = clusters[s.speakerId] ?? Cluster()
            let e = Cluster.normalized(s.embedding)
            for i in 0..<256 { c.sum[i] += e[i] * Float(seconds) }
            c.seconds += seconds
            if seconds > c.longest.end - c.longest.start {
                c.longest = (Double(s.startTimeSeconds), Double(s.endTimeSeconds))
            }
            clusters[s.speakerId] = c
        }

        // 近い組から順に決める。1つの区切りで、同じ人を2つのまとまりに当てるのは、どちらも十分近いときだけ。
        var pairs: [(cluster: String, person: String, distance: Float, second: Float)] = []
        for (key, c) in clusters {
            let scored = store.people.map { ($0, distance(c.embedding, to: $0)) }.sorted { $0.1 < $1.1 }
            for (i, (p, d)) in scored.enumerated() {
                let second = scored.indices.contains(i == 0 ? 1 : 0) ? scored[i == 0 ? 1 : 0].1 : 1
                let inContext = context == nil || p.context == nil || p.context == context || p.isSelf
                let limit = inContext && second - d >= 0.04 ? Self.accept : Self.strict
                if d <= limit { pairs.append((key, p.id, d, second)) }
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var assigned: [String: (person: String, distance: Float)] = [:]
        var used: Set<String> = []
        for pair in pairs where assigned[pair.cluster] == nil {
            if used.contains(pair.person) && pair.distance > Self.strict { continue }
            assigned[pair.cluster] = (pair.person, pair.distance)
            used.insert(pair.person)
        }

        var labels: [String: String] = [:]
        let file = url.lastPathComponent
        for (key, c) in clusters {
            let sample = Sample(audio: file, start: c.longest.start, end: c.longest.end)
            if let match = assigned[key], let i = index(of: match.person) {
                store.people[i].seconds += c.seconds
                store.people[i].lastHeard = .now
                if match.distance <= Self.learn && c.seconds >= 3 {
                    addVoice(c.embedding, pinned: false, to: i)
                    remember(sample, for: i)
                }
                labels[key] = match.person
            } else if c.seconds >= 3 {
                // 知らない声。新しい人として覚え、その場の人とする
                let id = String(store.nextID)
                store.nextID += 1
                store.people.append(Person(id: id, name: nil, context: context,
                                           voices: [Voice(embedding: c.embedding, pinned: false, added: .now)],
                                           seconds: c.seconds, samples: [sample]))
                labels[key] = id
            }
        }
        // 名前を付けていない声で、2週間聞いていないものは忘れる（通りすがりの人など）
        let old = Date.now.addingTimeInterval(-14 * 24 * 3600)
        store.people.removeAll { !$0.isNamed && $0.pinnedCount == 0 && $0.lastHeard < old }
        save()

        return result.segments.compactMap { s in
            guard let id = labels[s.speakerId], let p = person(id) else { return nil }
            return Segment(start: TimeInterval(s.startTimeSeconds), end: TimeInterval(s.endTimeSeconds),
                           personID: id, name: p.displayName)
        }
    }

    /// 近いもの上位3つの距離の平均
    private func distance(_ embedding: [Float], to person: Person) -> Float {
        let ds = person.voices.map { 1 - zip($0.embedding, embedding).reduce(0) { $0 + $1.0 * $1.1 } }.sorted()
        guard !ds.isEmpty else { return 1 }
        let top = ds.prefix(3)
        return top.reduce(0, +) / Float(top.count)
    }

    // MARK: - 登録と手直し

    /// 自分だけが話している録音から、自分の声を登録する。録り直すと前の登録に足す。
    func enrollSelf(from url: URL) async throws {
        ensureSelf()
        try await enroll(url, into: Self.selfID)
    }

    func ensureSelf() {
        guard index(of: Self.selfID) == nil else { return }
        store.people.append(Person(id: Self.selfID, name: nil, context: nil))
        save()
    }

    /// その人だけが話している録音から、新しい人を登録する。
    func register(_ url: URL, name: String, context: Context?) async throws -> String {
        let id = newPerson(name: name, context: context)
        try await enroll(url, into: id)
        return id
    }

    /// 録音を10秒ずつに分けて、それぞれの声を覚える。
    func enroll(_ url: URL, into id: String) async throws {
        try await prepare()
        guard let diarizer, let i = index(of: id) else { return }
        let samples = try AudioConverter().resampleAudioFile(url)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + 160_000)
            // 3秒より短い残りは使わない（最初の1つだけは短くても使う）
            if end - start >= 48_000 || start == 0 {
                let embedding = try diarizer.extractSpeakerEmbedding(from: Array(samples[start..<end]))
                addVoice(embedding, pinned: true, to: i)
            }
            start = end
        }
        save()
    }

    /// 録音の一部（start〜end 秒）がこの人の声だと教える。
    func teach(_ url: URL, from start: TimeInterval, to end: TimeInterval, personID: String) async throws {
        try await prepare()
        guard let diarizer, let i = index(of: personID) else { return }
        let samples = try AudioConverter().resampleAudioFile(url)
        let from = max(0, Int(start * 16_000))
        let to = min(samples.count, Int(end * 16_000))
        guard to - from >= 16_000 else { return }   // 1秒より短いと声の特徴が出ない
        let embedding = try diarizer.extractSpeakerEmbedding(from: Array(samples[from..<min(to, from + 160_000)]))
        addVoice(embedding, pinned: true, to: i)
        remember(Sample(audio: url.lastPathComponent, start: start, end: end), for: i)
        save()
    }

    func newPerson(name: String, context: Context?) -> String {
        let id = String(store.nextID)
        store.nextID += 1
        store.people.append(Person(id: id, name: name, context: context))
        save()
        return id
    }

    func rename(_ id: String, to name: String) {
        guard let i = index(of: id), !store.people[i].isSelf else { return }
        store.people[i].name = name.isEmpty ? nil : name
        save()
    }

    func setContext(_ id: String, to context: Context?) {
        guard let i = index(of: id) else { return }
        store.people[i].context = context
        save()
    }

    /// source の声を target に足し、source を消す（同じ人だったとき）。
    func merge(_ source: String, into target: String) {
        guard source != target, let s = person(source), let t = index(of: target) else { return }
        store.people[t].voices += s.voices
        store.people[t].seconds += s.seconds
        store.people[t].lastHeard = max(store.people[t].lastHeard, s.lastHeard)
        store.people[t].samples = Array((store.people[t].samples + s.samples).suffix(3))
        trimVoices(t)
        store.people.removeAll { $0.id == source }
        save()
    }

    func remove(_ id: String) {
        store.people.removeAll { $0.id == id }
        save()
    }

    // MARK: - 中身

    private func person(_ id: String) -> Person? { store.people.first { $0.id == id } }
    private func index(of id: String) -> Int? { store.people.firstIndex { $0.id == id } }

    private func addVoice(_ embedding: [Float], pinned: Bool, to i: Int) {
        guard embedding.count == 256, embedding.contains(where: { $0 != 0 }) else { return }
        let n = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        store.people[i].voices.append(Voice(embedding: embedding.map { $0 / n }, pinned: pinned, added: .now))
        trimVoices(i)
    }

    /// 自動で覚えた声は新しい20個まで。登録・手直しの声は50個まで。
    private func trimVoices(_ i: Int) {
        var voices = store.people[i].voices
        let auto = voices.filter { !$0.pinned }
        if auto.count > Self.maxAutoVoices, let cutoff = auto.dropLast(Self.maxAutoVoices).last?.added {
            voices.removeAll { !$0.pinned && $0.added <= cutoff }
        }
        let pinned = voices.filter(\.pinned)
        if pinned.count > 50 {
            voices.removeAll { $0.pinned && $0.added <= pinned[pinned.count - 51].added }
        }
        store.people[i].voices = voices
    }

    private func remember(_ sample: Sample, for i: Int) {
        var samples = store.people[i].samples.filter { $0 != sample }
        samples.append(sample)
        store.people[i].samples = Array(samples.suffix(3))
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.storeURL), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
            return
        }
        // 以前の形式から引き継ぐ
        guard let data = try? Data(contentsOf: Self.legacyURL),
              let speakers = try? JSONDecoder().decode([Speaker].self, from: data) else { return }
        var maxID = 0
        for s in speakers {
            let unnamed = s.name == s.id || s.name == "Speaker \(s.id)"
            var voices = [Voice(embedding: s.currentEmbedding, pinned: s.isPermanent, added: s.updatedAt)]
            voices += s.rawEmbeddings.suffix(10).map { Voice(embedding: $0.embedding, pinned: false, added: $0.timestamp) }
            store.people.append(Person(id: s.id, name: s.id == Self.selfID || unnamed ? nil : s.name, context: nil,
                                       voices: voices, seconds: Double(s.duration), lastHeard: s.updatedAt))
            maxID = max(maxID, Int(s.id) ?? 0)
        }
        store.nextID = maxID + 1
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

import CoreML
import FluidAudio
import Foundation

/// 声の特徴（話者の埋め込み）で「誰が話したか」を聞き分ける。iPhone の中だけで動き、無料。
///
/// 1. 区切り（5分）の中で、FluidAudio のオフライン方式（pyannote community-1 の分け方と VBx のまとめ方）に
///    「同じ声のまとまり」に分けてもらう。録り終わった音をまとめて処理する方式で、いちばん正確。
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
        /// どのモデルで取った声の特徴か。モデルが違うと比べられない（nil は以前の方式）
        var model: String? = nil
    }

    /// いま使っている声の特徴のモデル
    static let model = "offline-community1"

    /// 聞き分けの厳しさ。厳しいほど「人物N」が増え、ゆるいほど別の人を同じ人にしやすい。
    enum Strictness: Int, CaseIterable, Identifiable, Sendable {
        case strict, normal, loose
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .strict: "厳しめ"
            case .normal: "ふつう"
            case .loose: "ゆるめ"
            }
        }
        /// これより近ければ同じ人（コサイン距離。0 が同じ、1 が無関係）
        var accept: Float { [0.32, 0.40, 0.48][rawValue] }
        /// 別の場の人や、2番目の候補と差が小さいときは、これより近いときだけ選ぶ
        var strictLimit: Float { [0.24, 0.30, 0.36][rawValue] }
        /// 声を覚え足すのは、これより近くて3秒以上話していたときだけ
        var learn: Float { strictLimit - 0.05 }
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

    /// 読み込んだ OfflineDiarizerManager をこの actor に渡すための入れ物（渡したあとは actor だけが触る）
    private final class Loaded: @unchecked Sendable {
        let manager: OfflineDiarizerManager
        init(manager: OfflineDiarizerManager) { self.manager = manager }
    }

    static let selfID = "me"
    static let selfName = "自分"

    private static let maxAutoVoices = 20

    private var diarizer: OfflineDiarizerManager?
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
            let manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels(configuration: configuration)
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

    var hasSelfVoice: Bool { person(Self.selfID)?.voices.contains { $0.model == Self.model } == true }

    func people() -> [Person] {
        store.people.sorted { $0.seconds > $1.seconds }
    }

    func name(of id: String) -> String? { person(id)?.displayName }

    // MARK: - 聞き分け

    /// 1つの区切りの中で、いつ誰が話したかを返す。context はその時いた場（分からなければ nil）。
    func label(_ url: URL, context: Context?, strictness: Strictness = .normal) async throws -> [Segment] {
        try await prepare()
        guard let diarizer else { return [] }
        // 区切りの中だけで声を分けてもらう（前の区切りの声とは、下で自分で照らし合わせる）
        let result = try await diarizer.process(url)
        let accept = strictness.accept, strict = strictness.strictLimit

        // 声のまとまりごとに、特徴（まとまりの中心）と話した長さ、いちばん長く話したところを出す
        struct Cluster {
            var embedding: [Float] = []
            var seconds: Double = 0
            var longest: (start: Double, end: Double) = (0, 0)
        }
        var clusters: [String: Cluster] = [:]
        for s in result.segments where !s.speakerId.isEmpty {
            let seconds = Double(s.durationSeconds)
            var c = clusters[s.speakerId] ?? Cluster()
            c.seconds += seconds
            if seconds > c.longest.end - c.longest.start {
                c.longest = (Double(s.startTimeSeconds), Double(s.endTimeSeconds))
            }
            clusters[s.speakerId] = c
        }
        for key in clusters.keys {
            let center = result.speakerDatabase?[key]
                ?? result.segments.first { $0.speakerId == key }?.embedding ?? []
            clusters[key]?.embedding = Self.normalized(center)
        }
        clusters = clusters.filter { !$0.value.embedding.isEmpty }

        // 近い組から順に決める。1つの区切りで、同じ人を2つのまとまりに当てるのは、どちらも十分近いときだけ。
        var pairs: [(cluster: String, person: String, distance: Float, second: Float)] = []
        for (key, c) in clusters {
            let scored = store.people.map { ($0, distance(c.embedding, to: $0)) }.sorted { $0.1 < $1.1 }
            for (i, (p, d)) in scored.enumerated() {
                let second = scored.indices.contains(i == 0 ? 1 : 0) ? scored[i == 0 ? 1 : 0].1 : 1
                let inContext = context == nil || p.context == nil || p.context == context || p.isSelf
                let limit = inContext && second - d >= 0.04 ? accept : strict
                if d <= limit { pairs.append((key, p.id, d, second)) }
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var assigned: [String: (person: String, distance: Float)] = [:]
        var used: Set<String> = []
        for pair in pairs where assigned[pair.cluster] == nil {
            if used.contains(pair.person) && pair.distance > strict { continue }
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
                if match.distance <= strictness.learn && c.seconds >= 3 {
                    addVoice(c.embedding, pinned: false, to: i)
                    remember(sample, for: i)
                }
                labels[key] = match.person
            } else if c.seconds >= 3 {
                // 知らない声。新しい人として覚え、その場の人とする
                let id = String(store.nextID)
                store.nextID += 1
                store.people.append(Person(id: id, name: nil, context: context,
                                           voices: [Voice(embedding: c.embedding, pinned: false, added: .now,
                                                          model: Self.model)],
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
        let ds = person.voices.filter { $0.model == Self.model && $0.embedding.count == embedding.count }
            .map { 1 - zip($0.embedding, embedding).reduce(0) { $0 + $1.0 * $1.1 } }.sorted()
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
        guard index(of: id) != nil else { return }
        let samples = try AudioConverter().resampleAudioFile(url)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + 160_000)
            // 3秒より短い残りは使わない（最初の1つだけは短くても使う）
            if end - start >= 48_000 || start == 0, let embedding = try await voice(in: Array(samples[start..<end])),
               let i = index(of: id) {
                addVoice(embedding, pinned: true, to: i)
            }
            start = end
        }
        save()
    }

    /// 録音の一部（start〜end 秒）がこの人の声だと教える。pinned なら自動では消さない。
    func teach(_ url: URL, from start: TimeInterval, to end: TimeInterval, personID: String,
               pinned: Bool = true) async throws {
        try await prepare()
        guard index(of: personID) != nil else { return }
        let samples = try AudioConverter().resampleAudioFile(url)
        let from = max(0, Int(start * 16_000))
        let to = min(samples.count, Int(end * 16_000), from + 160_000)
        guard to - from >= 16_000 else { return }   // 1秒より短いと声の特徴が出ない
        guard let embedding = try await voice(in: Array(samples[from..<to])), let i = index(of: personID) else { return }
        addVoice(embedding, pinned: pinned, to: i)
        remember(Sample(audio: url.lastPathComponent, start: start, end: end), for: i)
        save()
    }

    /// 1人が話している音から、声の特徴を取る（いちばん長く話した声のまとまりの中心）。
    private func voice(in samples: [Float]) async throws -> [Float]? {
        guard let diarizer else { return nil }
        let result = try await diarizer.process(audio: samples)
        var seconds: [String: Float] = [:]
        for s in result.segments { seconds[s.speakerId, default: 0] += s.durationSeconds }
        guard let main = seconds.max(by: { $0.value < $1.value })?.key else { return nil }
        let center = result.speakerDatabase?[main] ?? result.segments.first { $0.speakerId == main }?.embedding
        return center.map(Self.normalized)
    }

    /// 以前のモデルの声しか無い人（名前のある人）の一覧と、覚えている聞き直し用のところ。
    /// 新しいモデルで声を取り直すのに使う。名前の無い声は、取り直さずに忘れる。
    func peopleNeedingVoices() -> [(id: String, samples: [Sample])] {
        store.people.removeAll { p in
            !p.isNamed && !p.voices.contains { $0.model == Self.model }
        }
        save()
        return store.people
            .filter { p in !p.voices.contains { $0.model == Self.model } && !p.samples.isEmpty }
            .map { ($0.id, $0.samples) }
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
        guard !embedding.isEmpty, embedding.contains(where: { $0 != 0 }) else { return }
        store.people[i].voices.append(Voice(embedding: Self.normalized(embedding), pinned: pinned, added: .now,
                                            model: Self.model))
        // 以前のモデルの声は比べられないので消す
        store.people[i].voices.removeAll { $0.model != Self.model }
        trimVoices(i)
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
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

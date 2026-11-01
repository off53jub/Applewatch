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
        /// 名前・場・登録した声を最後に変えた時刻（端末間の同期で、新しいほうの名前を残す）
        var updated: Date? = nil

        var isSelf: Bool { id == SpeakerLabeler.selfID }
        var displayName: String { isSelf ? SpeakerLabeler.selfName : name ?? "人物\(id)" }
        var isNamed: Bool { isSelf || name != nil }
        var minutes: Int { Int(seconds / 60) }
        var pinnedCount: Int { voices.filter(\.pinned).count }
    }

    private struct Store: Codable {
        var people: [Person] = []
        var nextID = 1
        /// 消した人の番号と、消した時刻（端末間の同期で、ほかの端末にも消したと伝える）
        var removed: [String: Date]? = nil
    }

    /// 新しい人の番号の始まり。iPhone は 1 から、iPad は 100000 から数えて、同期したときに番号がぶつからないようにする。
    static let idFloorKey = "personIDFloor"
    private var idFloor: Int { max(1, UserDefaults.standard.integer(forKey: Self.idFloorKey)) }
    /// この端末で付けた番号か（ほかの端末の番号では、次の番号を進めない）
    private func isOwnID(_ n: Int) -> Bool { idFloor >= 100_000 ? n >= 100_000 : n < 100_000 }

    private func allocateID() -> String {
        let n = max(store.nextID, idFloor)
        store.nextID = n + 1
        return String(n)
    }

    /// 人を消し、ほかの端末にも消したと伝える印を残す。
    private func forget(where match: (Person) -> Bool) {
        let gone = store.people.filter { match($0) && !$0.isSelf }
        guard !gone.isEmpty else { return }
        store.people.removeAll { p in gone.contains { $0.id == p.id } }
        var removed = store.removed ?? [:]
        for p in gone { removed[p.id] = .now }
        store.removed = removed
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
    /// 覚えている人。聞き分けのモデルの準備とは別に、最初に触ったときにファイルから読む。
    /// （読む前に書くと、覚えている人を空で上書きしてしまうので、必ずこれを通す）
    private var loadedStore: Store?
    private var store: Store {
        get {
            if let loadedStore { return loadedStore }
            let loaded = Self.readStore()
            loadedStore = loaded
            return loaded
        }
        set { loadedStore = newValue }
    }

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
    /// selfLevel は、その機器で覚えた自分の声の大きさ（dB）。手首や胸元のマイクには自分の声がいちばん大きく入るので、
    /// 自分の声くらい大きい声は「自分」と決めやすく、ずっと小さい声は「自分」にしにくくする。
    func label(_ url: URL, context: Context?, strictness: Strictness = .normal,
               selfLevel: Float? = nil) async throws -> [Segment] {
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

        // まとまりごとの声の大きさ（いちばん長く話したところで測る）
        var loudness: [String: Float] = [:]
        if selfLevel != nil {
            let keys = Array(clusters.keys)
            let spans = keys.map { (start: clusters[$0]!.longest.start, end: clusters[$0]!.longest.end) }
            for (key, level) in zip(keys, OfficeFilter.levels(url, spans: spans)) {
                if let level { loudness[key] = level }
            }
        }

        // 近い組から順に決める。1つの区切りで、同じ人を2つのまとまりに当てるのは、どちらも十分近いときだけ。
        var pairs: [(cluster: String, person: String, distance: Float, second: Float)] = []
        for (key, c) in clusters {
            let scored = store.people.map { ($0, distance(c.embedding, to: $0)) }.sorted { $0.1 < $1.1 }
            for (i, (p, d)) in scored.enumerated() {
                let second = scored.indices.contains(i == 0 ? 1 : 0) ? scored[i == 0 ? 1 : 0].1 : 1
                let inContext = context == nil || p.context == nil || p.context == context || p.isSelf
                var limit = inContext && second - d >= 0.04 ? accept : strict
                if p.isSelf, let selfLevel, let level = loudness[key] {
                    if level >= selfLevel - 3 {
                        // 自分の声と同じくらい大きい声は、声の特徴が少し離れていても自分とみなす
                        limit = max(limit, accept + 0.08)
                    } else if level < selfLevel - 12 {
                        // 自分の声よりずっと小さい声（離れた人）は、よほど近いときだけ自分にする
                        limit = min(limit, strict)
                    }
                }
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
                let id = allocateID()
                store.people.append(Person(id: id, name: nil, context: context,
                                           voices: [Voice(embedding: c.embedding, pinned: false, added: .now,
                                                          model: Self.model)],
                                           seconds: c.seconds, samples: [sample]))
                labels[key] = id
            }
        }
        // 名前を付けていない声で、2週間聞いていないものは忘れる（通りすがりの人など）
        let old = Date.now.addingTimeInterval(-14 * 24 * 3600)
        forget { !$0.isNamed && $0.pinnedCount == 0 && $0.lastHeard < old }
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
                store.people[i].updated = .now
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
        if pinned { store.people[i].updated = .now }
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
        // （ほかの端末から同期した、声を持たない人は消さない）
        store.people.removeAll { p in
            !p.isNamed && !p.voices.isEmpty && !p.voices.contains { $0.model == Self.model }
        }
        save()
        return store.people
            .filter { p in !p.voices.contains { $0.model == Self.model } && !p.samples.isEmpty }
            .map { ($0.id, $0.samples) }
    }

    /// 記録に残っている名前から、人を同じ番号で作り直す（覚えている人が消えてしまったとき）。
    /// 記録に出てくる番号より大きい番号から、新しい人を数え始める。
    func restore(_ people: [(id: String, name: String?, context: Context?)], usedIDs: Set<String>) {
        for p in people where index(of: p.id) == nil {
            if p.id == Self.selfID {
                ensureSelf()
            } else {
                store.people.append(Person(id: p.id, name: p.name, context: p.context))
            }
        }
        let highest = usedIDs.compactMap { Int($0) }.filter(isOwnID).max() ?? 0
        store.nextID = max(store.nextID, highest + 1)
        save()
    }

    func hasVoice(_ id: String) -> Bool { person(id)?.voices.contains { $0.model == Self.model } == true }

    func newPerson(name: String, context: Context?) -> String {
        let id = allocateID()
        store.people.append(Person(id: id, name: name, context: context, updated: .now))
        save()
        return id
    }

    func rename(_ id: String, to name: String) {
        guard let i = index(of: id), !store.people[i].isSelf else { return }
        store.people[i].name = name.isEmpty ? nil : name
        store.people[i].updated = .now
        save()
    }

    func setContext(_ id: String, to context: Context?) {
        guard let i = index(of: id) else { return }
        store.people[i].context = context
        store.people[i].updated = .now
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
        store.people[t].updated = .now
        forget { $0.id == source }
        save()
    }

    /// まとめる前の、その人の記録（まとめを戻すために取っておく）
    func snapshot(_ id: String) -> Person? { person(id) }

    func exists(_ id: String) -> Bool { index(of: id) != nil }

    /// まとめた人を戻す。snapshot（まとめる前の記録）があれば、その名前と声ごと戻し、まとめた先からその声を外す。
    /// snapshot が無ければ（記録を取っていなかった前のまとめ）、名前の無い人として作り直すだけ（声はあとで覚える）。
    /// まとめた先の人の、名前・登録した声・ほかの声には触らない。
    func revive(_ id: String, snapshot: Person?, from target: String) {
        guard id != Self.selfID, id != target else { return }
        if index(of: id) == nil {
            var revived = snapshot ?? Person(id: id, name: nil, context: nil)
            revived.updated = .now
            store.people.append(revived)
            store.removed?[id] = nil
        }
        if let snapshot, let t = index(of: target) {
            let moved = Set(snapshot.voices.map(\.embedding))
            store.people[t].voices.removeAll { moved.contains($0.embedding) }
            store.people[t].seconds = max(0, store.people[t].seconds - snapshot.seconds)
            store.people[t].samples.removeAll { snapshot.samples.contains($0) }
        }
        if let n = Int(id), isOwnID(n) { store.nextID = max(store.nextID, n + 1) }
        save()
    }

    /// 戻した人の声に、まとめた先の人の「登録・手直しで覚えた声」より近い、自動で覚えた声を、戻した人に移す。
    /// まとめた先に登録・手直しの声が無ければ、どちらの声か決められないので動かさない。登録・手直しの声は動かさない。
    func moveVoices(from target: String, to id: String) -> Int {
        guard let t = index(of: target), let restored = person(id),
              restored.voices.contains(where: { $0.model == Self.model }) else { return 0 }
        var anchor = store.people[t]
        anchor.voices = anchor.voices.filter(\.pinned)
        guard anchor.voices.contains(where: { $0.model == Self.model }) else { return 0 }
        var moved: [Voice] = []
        store.people[t].voices.removeAll { v in
            guard !v.pinned, v.model == Self.model,
                  distance(v.embedding, to: restored) < distance(v.embedding, to: anchor) else { return false }
            moved.append(v)
            return true
        }
        if let i = index(of: id), !moved.isEmpty {
            store.people[i].voices += moved
            trimVoices(i)
        }
        save()
        return moved.count
    }

    /// その声にいちばん近い、名前のある人（自分を含む）と、その距離。
    func closestNamed(to id: String) -> (id: String, distance: Float)? {
        guard let source = person(id) else { return nil }
        let voices = source.voices.filter { $0.model == Self.model }
        guard !voices.isEmpty else { return nil }
        var best: (id: String, distance: Float)?
        for p in store.people where p.isNamed && p.id != id {
            let d = voices.map { distance($0.embedding, to: p) }.min() ?? 1
            if d < (best?.distance ?? 1) { best = (p.id, d) }
        }
        return best
    }

    /// 1つの会話に出てきた声のうち、同じ人が別の「人物N」に分かれてしまったものを、まとめる組（source を target に）にして返す。
    /// まとめるのは、名前が無く、登録や手直しで覚えた声も無い「人物N」だけ。名前のある人どうしはまとめない。
    /// apart は、同じ区切りの中で別の声とされた2人（番号の小さい順の組）。別の人とみなしてまとめない。
    func consolidation(among ids: Set<String>, apart: Set<[String]>,
                       strictness: Strictness) -> [(source: String, target: String)] {
        let members = store.people.filter { p in ids.contains(p.id) && p.voices.contains { $0.model == Self.model } }
        var result: [(source: String, target: String)] = []
        var gone = Set<String>()
        // 話した時間の短い声から、ほかの声にまとめられるか見る
        for p in members.filter({ !$0.isNamed && $0.pinnedCount == 0 }).sorted(by: { $0.seconds < $1.seconds }) {
            let voices = p.voices.filter { $0.model == Self.model }
            var best: (id: String, distance: Float)?
            for q in members where q.id != p.id && !gone.contains(q.id) {
                guard !apart.contains([p.id, q.id].sorted()) else { continue }
                let d = voices.map { distance($0.embedding, to: q) }.reduce(0, +) / Float(voices.count)
                // 名前のある人（自分を含む）へは、ふだんの聞き分けと同じ近さで。
                // 名前の無い声どうしは、同じ会話に出てくる人は少ないので、少しゆるく
                let limit = q.isNamed ? strictness.accept : strictness.accept + 0.08
                if d <= limit, d < (best?.distance ?? .infinity) { best = (q.id, d) }
            }
            if let best {
                result.append((p.id, best.id))
                gone.insert(p.id)
            }
        }
        return result
    }

    /// テレビや動画の声だった、名前の無い声を忘れる（登録・手直しした声は残す）。
    func forgetUnnamed(_ ids: Set<String>) {
        forget { ids.contains($0.id) && !$0.isNamed && $0.pinnedCount == 0 }
        save()
    }

    func remove(_ id: String) {
        if id == Self.selfID {
            // 自分の声は端末ごとに登録し直せるよう、ほかの端末には伝えない
            store.people.removeAll { $0.id == id }
        } else {
            forget { $0.id == id }
        }
        save()
    }

    // MARK: - 端末間の同期

    /// 同期で渡す声（登録・手直しで覚えた声だけ。自動で覚えた声は端末ごとのマイクに合わせたものなので渡さない）
    struct SyncVoice: Codable, Sendable {
        /// Float32 を並べたもの
        let embedding: Data
        let added: Date
        let model: String?
    }

    struct SyncPerson: Codable, Sendable {
        let id: String
        let name: String?
        let context: Context?
        let voices: [SyncVoice]
        let seconds: Double
        let lastHeard: Date
        let samples: [Sample]
        let updated: Date?
    }

    struct SyncPeople: Codable, Sendable {
        let people: [SyncPerson]
        let removed: [String: Date]
    }

    private static func pack(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    private static func unpack(_ d: Data) -> [Float] {
        let count = d.count / MemoryLayout<Float>.size
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { d.copyBytes(to: $0, count: count * MemoryLayout<Float>.size) }
        return result
    }

    func syncCopy() -> SyncPeople {
        // 2か月より前に消した印は、もう渡さない
        let cutoff = Date.now.addingTimeInterval(-60 * 24 * 3600)
        let removed = (store.removed ?? [:]).filter { $0.value > cutoff }
        let people = store.people.sorted { $0.id < $1.id }.map { p in
            SyncPerson(id: p.id, name: p.name, context: p.context,
                       voices: p.voices.filter(\.pinned).map { SyncVoice(embedding: Self.pack($0.embedding), added: $0.added, model: $0.model) },
                       // 細かく変わり続けないように、分と日にそろえる
                       seconds: (p.seconds / 60).rounded(.down) * 60,
                       lastHeard: Date(timeIntervalSince1970: (p.lastHeard.timeIntervalSince1970 / 86400).rounded(.down) * 86400),
                       samples: p.samples, updated: p.updated)
        }
        return SyncPeople(people: people, removed: removed)
    }

    /// ほかの端末の人を合わせる。
    /// - 同じ番号の人は、名前と場は後から変えたほうを残し、登録・手直しの声は両方を足す（自動で覚えた声はこの端末のまま）。
    /// - 向こうで消した人は、そのあとこちらで聞いたり直したりしていなければ消す。自分は消さない。
    /// - 次に付ける番号は変えない（番号の範囲が端末ごとに分かれているため）。
    /// 変わったら true。
    func mergeRemote(_ remote: SyncPeople) -> Bool {
        var changed = false
        var removed = store.removed ?? [:]
        for rp in remote.people {
            let voices = rp.voices.map { Voice(embedding: Self.unpack($0.embedding), pinned: true, added: $0.added, model: $0.model) }
            let remoteTouched = max(rp.updated ?? .distantPast, rp.lastHeard)
            if let i = index(of: rp.id) {
                var p = store.people[i]
                let before = p
                if (rp.updated ?? .distantPast) > (p.updated ?? .distantPast), !p.isSelf {
                    p.name = rp.name
                    p.context = rp.context
                    p.updated = rp.updated
                }
                let known = Set(p.voices.map(\.embedding))
                let added = voices.filter { !known.contains($0.embedding) && !$0.embedding.isEmpty }
                if !added.isEmpty { p.voices += added }
                p.seconds = max(p.seconds, rp.seconds)
                p.lastHeard = max(p.lastHeard, rp.lastHeard)
                for sample in rp.samples where !p.samples.contains(sample) { p.samples.append(sample) }
                p.samples = Array(p.samples.suffix(3))
                if !added.isEmpty || p.name != before.name || p.context != before.context
                    || p.seconds != before.seconds || p.lastHeard != before.lastHeard || p.samples != before.samples {
                    store.people[i] = p
                    if !added.isEmpty { trimVoices(i) }
                    changed = true
                }
            } else {
                if let gone = removed[rp.id], gone >= remoteTouched { continue }
                store.people.append(Person(id: rp.id, name: rp.name, context: rp.context, voices: voices,
                                           seconds: rp.seconds, lastHeard: rp.lastHeard, samples: rp.samples,
                                           updated: rp.updated))
                removed[rp.id] = nil
                changed = true
            }
        }
        for (id, when) in remote.removed where id != Self.selfID {
            if (removed[id] ?? .distantPast) < when { removed[id] = when }
            guard let p = person(id) else { continue }
            let touched = max(p.updated ?? .distantPast, p.lastHeard)
            if touched < when {
                store.people.removeAll { $0.id == id }
                changed = true
            }
        }
        if removed != (store.removed ?? [:]) {
            store.removed = removed
            changed = true
        }
        if changed { save() }
        return changed
    }

    /// iPad で、同期を始める前に一度だけ、この端末で付けた番号を iPad の範囲（100000〜）に付け替える。
    /// extra は記録の行にだけ残っている番号（もう覚えていない人）。古い番号 → 新しい番号を返す。
    func moveIDsIntoRange(extra: Set<String>) -> [String: String] {
        var map: [String: String] = [:]
        let floor = idFloor
        guard floor >= 100_000 else { return [:] }
        let ids = Set(store.people.map(\.id)).union(extra).filter { id in Int(id).map { $0 < floor } ?? false }
        for id in ids.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) { map[id] = allocateID() }
        for i in store.people.indices {
            guard let new = map[store.people[i].id] else { continue }
            let p = store.people[i]
            store.people[i] = Person(id: new, name: p.name, context: p.context, voices: p.voices, seconds: p.seconds,
                                     lastHeard: p.lastHeard, samples: p.samples, updated: p.updated)
        }
        save()
        return map
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

    private static func readStore() -> Store {
        if let data = try? Data(contentsOf: storeURL) {
            if let saved = try? JSONDecoder().decode(Store.self, from: data) { return saved }
            // 読めないファイルは消さずに取っておく（上書きで失わないように）
            let backup = storeURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: storeURL, to: backup)
        }
        // 以前の形式から引き継ぐ
        var store = Store()
        guard let data = try? Data(contentsOf: legacyURL),
              let speakers = try? JSONDecoder().decode([Speaker].self, from: data) else { return store }
        var maxID = 0
        for s in speakers {
            let unnamed = s.name == s.id || s.name == "Speaker \(s.id)"
            var voices = [Voice(embedding: s.currentEmbedding, pinned: s.isPermanent, added: s.updatedAt)]
            voices += s.rawEmbeddings.suffix(10).map { Voice(embedding: $0.embedding, pinned: false, added: $0.timestamp) }
            store.people.append(Person(id: s.id, name: s.id == selfID || unnamed ? nil : s.name, context: nil,
                                       voices: voices, seconds: Double(s.duration), lastHeard: s.updatedAt))
            maxID = max(maxID, Int(s.id) ?? 0)
        }
        store.nextID = maxID + 1
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: storeURL, options: .atomic) }
        return store
    }

    private func save() {
        guard let loadedStore, let data = try? JSONEncoder().encode(loadedStore) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

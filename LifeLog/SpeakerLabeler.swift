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
        /// 本人の手直しから少しずつ合わせる（SpeakerTuning。±0.04 まで。2026-11-06）
        var accept: Float { [0.32, 0.40, 0.48][rawValue] + SpeakerTuning.shift }
        /// 別の場の人や、2番目の候補と差が小さいときは、これより近いときだけ選ぶ
        var strictLimit: Float { [0.24, 0.30, 0.36][rawValue] + SpeakerTuning.shift }
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
        /// 記録に出さない人（声で見分けて、その人の行は書かずに「消した行」に回す）
        var hidden: Bool? = nil

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
               selfLevel: Float? = nil, expected: Set<String> = []) async throws -> [Segment] {
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

        // 手首や胸元のマイクに、自分の声くらい大きく入ったまとまり（身につけている自分の声の見込みが高い）
        func isLoud(_ key: String) -> Bool {
            guard let selfLevel, let level = loudness[key] else { return false }
            return level >= selfLevel - 3
        }

        // 近い組から順に決める。1つの区切りで、同じ人を2つのまとまりに当てるのは、どちらも十分近いときだけ。
        var pairs: [(cluster: String, person: String, distance: Float, second: Float, rank: Float)] = []
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
                // 自分の声くらい大きい声は、自分とほかの人で迷うときに自分を先に選ぶ（自分の発言がほかの人の行になっていた。2026-11-05）
                var rank = p.isSelf && isLoud(key) ? d - Self.loudSelfBonus : d
                // 直前に話していた人・予定の出席者は、ほかの人と迷うときに少しだけ先に選ぶ（受け入れる近さは変えない）
                if expected.contains(p.id) { rank -= Self.expectedBonus }
                // 覚え足すかを決めるための、いちばん近い別の人。名前のある人（自分を含む）は、名前のある人どうしで比べる
                // （自分の声から分かれた名前の無い人物Nが近いだけで、自分の声を覚え足せなくならないように）
                let rival = scored.first { $0.0.id != p.id && (!p.isNamed || $0.0.isNamed) }?.1 ?? 1
                if d <= limit { pairs.append((key, p.id, d, rival, rank)) }
            }
        }
        pairs.sort { $0.rank < $1.rank }
        var assigned: [String: (person: String, distance: Float, second: Float)] = [:]
        var used: Set<String> = []
        for pair in pairs where assigned[pair.cluster] == nil {
            if used.contains(pair.person) && pair.distance > strict { continue }
            assigned[pair.cluster] = (pair.person, pair.distance, pair.second)
            used.insert(pair.person)
        }
        // 同じ区切りの2つのまとまりが同じ人になり、片方は自分の声くらい大きく、もう片方はずっと小さいときは、
        // 大きいほうを身につけている自分の声とみなす（1対1で、自分の発言まで相手の名前の行になっていた。2026-11-05）
        if let selfLevel, let me = person(Self.selfID), !assigned.values.contains(where: { $0.person == Self.selfID }) {
            let owners = assigned.mapValues { $0.person }
            for key in Self.wearerClusters(owners: owners, levels: loudness, selfLevel: selfLevel) {
                guard let c = clusters[key] else { continue }
                let d = distance(c.embedding, to: me)
                if d <= accept + 0.08 {
                    // 迷って決めた声なので、自分の声としては覚え足さない（second を同じ距離にしておく）
                    assigned[key] = (Self.selfID, d, d)
                    break
                }
            }
        }

        var labels: [String: String] = [:]
        let file = url.lastPathComponent
        for (key, c) in clusters {
            let sample = Sample(audio: file, start: c.longest.start, end: c.longest.end)
            if let match = assigned[key], let i = index(of: match.person) {
                store.people[i].seconds += c.seconds
                store.people[i].lastHeard = .now
                // 覚え足すのは、2番目に近い人よりはっきり近いときだけ。ほかの人なのに自分の声くらい大きいときは覚えない
                // （迷った声を覚え足すと、自分の声がほかの人の声として増えていく。井上さんの自動の声20個が自分の声だった）
                if Self.mayLearn(distance: match.distance, second: match.second, limit: strictness.learn,
                                 seconds: c.seconds, isSelf: match.person == Self.selfID, loud: isLoud(key)) {
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
        // （記録に出さない人は、また聞こえたときに見分けられるよう忘れない）
        forget { !$0.isNamed && $0.pinnedCount == 0 && $0.lastHeard < old && $0.hidden != true }
        save()

        return result.segments.compactMap { s in
            guard let id = labels[s.speakerId], let p = person(id) else { return nil }
            return Segment(start: TimeInterval(s.startTimeSeconds), end: TimeInterval(s.endTimeSeconds),
                           personID: id, name: p.displayName)
        }
    }

    // MARK: - 迷った声の扱い（2026-11-05。自分の声がほかの人の声として覚えられていた）

    /// 自分の声くらい大きいまとまりを、自分とほかの人で迷うときに自分へ寄せる幅
    static let loudSelfBonus: Float = 0.06
    /// この区切りにいそうな人（直前に話していた人・予定の出席者）を、迷うときに先に選ぶ幅
    static let expectedBonus: Float = 0.03
    /// 覚え足すのは、2番目に近い人よりこれだけ近いときだけ
    static let learnMargin: Float = 0.10

    /// 声を覚え足してよいか。second は2番目に近い人までの距離（選んだ人が2番目なら、いちばん近い人まで）。
    nonisolated static func mayLearn(distance: Float, second: Float, limit: Float, seconds: Double,
                                     isSelf: Bool, loud: Bool) -> Bool {
        guard distance <= limit, seconds >= 3, second - distance >= learnMargin else { return false }
        // ほかの人なのに、身につけたマイクに自分の声くらい大きく入った声は、自分の声かもしれないので覚えない
        return isSelf || !loud
    }

    /// 1つの区切りで同じ人になったまとまりのうち、自分の声くらい大きく（selfLevel-3 dB 以上）、
    /// 同じ人のほかのまとまりより 12 dB 以上大きいもの（大きい順）。身につけている自分の声とみなす候補。
    nonisolated static func wearerClusters(owners: [String: String], levels: [String: Float],
                                           selfLevel: Float) -> [String] {
        var result: [(String, Float)] = []
        for (person, keys) in Dictionary(grouping: owners.keys, by: { owners[$0]! }) where person != selfID && keys.count > 1 {
            let measured: [(String, Float)] = keys.compactMap { k in levels[k].map { (k, $0) } }
            guard let quietest = measured.map({ $0.1 }).min() else { continue }
            result += measured.filter { $0.1 >= selfLevel - 3 && $0.1 - quietest >= 12 }
        }
        return result.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// 近いもの上位3つの距離の平均（声の特徴はどれも長さ1にそろえてある）
    nonisolated static func top3(_ embedding: [Float], _ bank: [[Float]]) -> Float {
        let ds = bank.filter { $0.count == embedding.count }
            .map { 1 - zip($0, embedding).reduce(0) { $0 + $1.0 * $1.1 } }.sorted()
        guard !ds.isEmpty else { return 1 }
        let top = ds.prefix(3)
        return top.reduce(0, +) / Float(top.count)
    }

    /// 自動で覚えた声が、ほかの人の声とみなせるか。own はその人の決めた声（登録・手直し）まで、
    /// other はいちばん近いほかの人の決めた声まで。ほかの人の決めた声にはっきり近く、その人の決めた声からは遠いときだけ。
    nonisolated static func belongsElsewhere(own: Float, other: Float) -> Bool {
        other <= 0.40 && own - other >= 0.20
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

    /// 1つの音声の中のいくつかの場面から、それぞれの声の特徴を取る（1秒より短い・取れなかった場面は nil）。
    func embeddings(_ url: URL, clips: [(start: TimeInterval, end: TimeInterval)]) async throws -> [[Float]?] {
        try await prepare()
        let audio = try AudioConverter().resampleAudioFile(url)
        var result: [[Float]?] = []
        for clip in clips {
            let from = max(0, Int(clip.start * 16_000))
            let to = min(audio.count, Int(clip.end * 16_000), from + 160_000)
            result.append(to - from >= 16_000 ? try await voice(in: Array(audio[from..<to])) : nil)
        }
        return result
    }

    /// 1人に混ざっていた2人を分ける。id の覚えている声のうち、moved の声のほうが keep の声より近いもの（近さ0.3未満）を外し、
    /// moved の声を target の声として覚える（手直しと同じく、自動では消さない声。10個まで）。外した声の数を返す。
    /// target が nil（テレビなどの声だった）なら、外すだけで、だれの声にもしない。
    func split(_ id: String, keep: [[Float]], moved: [[Float]], to target: String?) -> Int {
        guard let i = index(of: id), id != target else { return 0 }
        let t = target.flatMap { index(of: $0) }
        if target != nil && t == nil { return 0 }
        func nearest(_ v: [Float], _ list: [[Float]]) -> Float {
            list.filter { $0.count == v.count }.map { 1 - zip($0, v).reduce(0) { $0 + $1.0 * $1.1 } }.min() ?? 1
        }
        let before = store.people[i].voices.count
        store.people[i].voices.removeAll { v in
            guard v.model == Self.model else { return false }
            let toMoved = nearest(v.embedding, moved)
            return toMoved < 0.3 && toMoved < nearest(v.embedding, keep)
        }
        let removed = before - store.people[i].voices.count
        store.people[i].updated = .now
        if let t {
            for embedding in moved.prefix(10) { addVoice(embedding, pinned: true, to: t) }
            store.people[t].updated = .now
        }
        save()
        return removed
    }

    /// 声のひとこまの音と同じ声とみなす近さ（同じ音から取った特徴なら、ほとんど0になる）
    private static let sameClip: Float = 0.15

    /// 声のひとこまを、この人から外す（ほかの人の声やテレビの声を拾っていたとき）。
    /// url があれば、その音から声の特徴を取り直し、この人の覚えている声のうち、それと同じ声（登録・手直しの声も）を外す。
    /// target を渡すと、その声を target の声として覚え直す（手直しと同じく、自動では消さない声）。外した声の数を返す。
    func dropSample(_ sample: Sample, from id: String, url: URL?, moveTo target: String?) async throws -> Int {
        guard let i = index(of: id) else { return 0 }
        store.people[i].samples.removeAll { $0 == sample }
        save()
        guard let url else { return 0 }
        try await prepare()
        let audio = try AudioConverter().resampleAudioFile(url)
        let from = max(0, Int(sample.start * 16_000))
        let to = min(audio.count, Int(sample.end * 16_000), from + 160_000)
        guard to - from >= 16_000, let embedding = try await voice(in: Array(audio[from..<to])),
              let j = index(of: id) else { return 0 }
        let before = store.people[j].voices.count
        store.people[j].voices.removeAll { v in
            v.model == Self.model && v.embedding.count == embedding.count
                && 1 - zip(v.embedding, embedding).reduce(0) { $0 + $1.0 * $1.1 } < Self.sameClip
        }
        let removed = before - store.people[j].voices.count
        store.people[j].updated = .now
        if let target, target != id, let t = index(of: target) {
            addVoice(embedding, pinned: true, to: t)
            store.people[t].updated = .now
            remember(sample, for: t)
        }
        save()
        return removed
    }

    // MARK: - 食い違った声のひとこまを脇に置く（2026-11-05 本人決定）

    /// 脇に置いた声のひとこまと、そのとき聞き分けから外した声。消さずに取っておき、戻せるようにする。
    /// people.json の形は変えず、別のファイル（voices-set-aside.json）に置く。
    struct SetAside: Codable, Sendable, Identifiable {
        let person: String
        let sample: Sample
        /// 聞き分けから外した、自動で覚えた声
        let voices: [Voice]
        let at: Date
        /// 記録ではだれの行だったか（画面に出す）
        let reason: String
        var id: String { Self.key(person, sample) }
        static func key(_ person: String, _ sample: Sample) -> String { person + "|" + sample.audio + "|\(sample.start)" }
        /// 音のひとこまがあるか（声の特徴だけを外したものは audio が空）
        var hasClip: Bool { !sample.audio.isEmpty }
    }

    private static let asideURL = URL.applicationSupportDirectory.appendingPathComponent("voices-set-aside.json")
    private var asideCache: [SetAside]?

    private func asideList() -> [SetAside] {
        if let asideCache { return asideCache }
        var list: [SetAside] = []
        if let data = try? Data(contentsOf: Self.asideURL) {
            if let saved = try? JSONDecoder().decode([SetAside].self, from: data) {
                list = saved
            } else {
                // 読めないファイルは消さずに取っておく（上書きで失わないように）
                let backup = Self.asideURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: Self.asideURL, to: backup)
            }
        }
        asideCache = list
        return list
    }

    private func saveAside(_ list: [SetAside]) {
        asideCache = list
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.asideURL, options: .atomic) }
    }

    func setAsideItems(of person: String? = nil) -> [SetAside] {
        asideList().filter { person == nil || $0.person == person }.sorted { $0.at > $1.at }
    }

    /// 声のひとこまを脇に置く。その音から声の特徴を取り直し、この人の**自動で覚えた声**のうち同じ声を外して取っておく。
    /// 登録・手直しの声（本人が決めた声）と同じなら、触らずに false を返す（見直しに残す）。
    func setAside(_ sample: Sample, from id: String, url: URL, reason: String) async throws -> Bool {
        guard let i0 = index(of: id), store.people[i0].samples.contains(sample) else { return false }
        try await prepare()
        let audio = try AudioConverter().resampleAudioFile(url)
        let from = max(0, Int(sample.start * 16_000))
        let to = min(audio.count, Int(sample.end * 16_000), from + 160_000)
        guard to - from >= 16_000, let embedding = try await voice(in: Array(audio[from..<to])) else { return false }
        // 待っているあいだに変わっているかもしれないので、もう一度探す
        guard let i = index(of: id), store.people[i].samples.contains(sample) else { return false }
        func same(_ v: Voice) -> Bool {
            v.model == Self.model && v.embedding.count == embedding.count
                && 1 - zip(v.embedding, embedding).reduce(0) { $0 + $1.0 * $1.1 } < Self.sameClip
        }
        if store.people[i].voices.contains(where: { $0.pinned && same($0) }) { return false }
        let removed = store.people[i].voices.filter { !$0.pinned && same($0) }
        store.people[i].voices.removeAll { !$0.pinned && same($0) }
        store.people[i].samples.removeAll { $0 == sample }
        save()
        var list = asideList()
        let item = SetAside(person: id, sample: sample, voices: removed, at: .now, reason: reason)
        list.removeAll { $0.id == item.id }
        list.append(item)
        saveAside(Array(list.suffix(300)))
        return true
    }

    /// 脇に置いたひとこまを戻す（外した声も聞き分けに戻す）。
    func restoreAside(_ key: String) -> Bool {
        var list = asideList()
        guard let item = list.first(where: { $0.id == key }) else { return false }
        list.removeAll { $0.id == key }
        guard let i = index(of: item.person) else { saveAside(list); return false }
        let known = Set(store.people[i].voices.map(\.embedding))
        store.people[i].voices += item.voices.filter { !known.contains($0.embedding) }
        trimVoices(i)
        // 声の特徴だけを外したもの（音のひとこまが無い）は、ひとこまを戻さない
        if item.hasClip { remember(item.sample, for: i) }
        save()
        saveAside(list)
        return true
    }

    // MARK: - ほかの人の決めた声に近い、自動で覚えた声を外す（2026-11-05）

    /// 自動で覚えた声のうち、その人の決めた声（登録・手直し）より、ほかの人の決めた声にずっと近いものを外して取っておく。
    /// 自分の声がほかの人の声として覚えられ、自分の発言がその人の行になっていたため（井上さんの自動の声20個が自分の声だった）。
    /// 決めた声が無い人は比べる手がかりが無いので触らない。記録に出さない人も触らない。
    /// kept は、本人が「この人の声だった（戻す）」にした声（`keptKey(person:added:)`）。外した声の数を返す。
    func setAsideOthersVoices(kept: Set<String>) -> Int {
        let anchors: [String: [[Float]]] = Dictionary(uniqueKeysWithValues: store.people.compactMap { p -> (String, [[Float]])? in
            guard p.isNamed else { return nil }
            let bank = p.voices.filter { $0.pinned && $0.model == Self.model }.map(\.embedding)
            return bank.isEmpty ? nil : (p.id, bank)
        })
        guard anchors.count >= 2 else { return 0 }
        var list = asideList()
        var total = 0
        for i in store.people.indices {
            let p = store.people[i]
            guard p.hidden != true, let own = anchors[p.id] else { continue }
            var out: [Int] = []
            var towards: [String: Int] = [:]
            for (j, v) in p.voices.enumerated() where !v.pinned && v.model == Self.model
                && !kept.contains(Self.keptKey(person: p.id, added: v.added)) {
                let dOwn = Self.top3(v.embedding, own)
                guard let nearest = anchors.filter({ $0.key != p.id })
                    .map({ (id: $0.key, d: Self.top3(v.embedding, $0.value)) })
                    .min(by: { $0.d < $1.d }) else { continue }
                if Self.belongsElsewhere(own: dOwn, other: nearest.d) {
                    out.append(j)
                    towards[nearest.id, default: 0] += 1
                }
            }
            guard !out.isEmpty else { continue }
            let removed = out.map { p.voices[$0] }
            store.people[i].voices = p.voices.enumerated().filter { !out.contains($0.offset) }.map { $0.element }
            let names = towards.sorted { $0.value > $1.value }
                .map { person($0.key)?.displayName ?? "人物\($0.key)" }
            let reason = "「\(names.joined(separator: "」「"))」の決めた声に近かった、自動で覚えた声 \(removed.count) 個"
            // 音のひとこまが無いので、外した時刻で見分ける
            let marker = Sample(audio: "", start: Date.now.timeIntervalSince1970, end: 0)
            list.append(SetAside(person: p.id, sample: marker, voices: removed, at: .now, reason: reason))
            total += removed.count
        }
        guard total > 0 else { return 0 }
        save()
        saveAside(Array(list.suffix(300)))
        return total
    }

    /// 自分の声の見本（登録・手直しの声。3つより少なければ自分の声すべて）と、その人の声の見本
    /// （登録・手直しの声。無ければ、自分の見本から 0.40 より離れた自動の声）。過去の行の声を確かめるのに使う。
    func voiceBanks(for id: String) -> (me: [[Float]], own: [[Float]]) {
        let mine = (person(Self.selfID)?.voices ?? []).filter { $0.model == Self.model }
        var me = mine.filter(\.pinned).map(\.embedding)
        if me.count < 3 { me = mine.map(\.embedding) }
        let theirs = (person(id)?.voices ?? []).filter { $0.model == Self.model }
        var own = theirs.filter(\.pinned).map(\.embedding)
        if own.isEmpty { own = theirs.map(\.embedding).filter { Self.top3($0, me) > 0.40 } }
        return (me, own)
    }

    /// 本人が戻した声の印（同じ声をまた外さないため）
    nonisolated static func keptKey(person: String, added: Date) -> String {
        person + "|" + String(format: "%.3f", added.timeIntervalSinceReferenceDate)
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

    func setHidden(_ id: String, _ hidden: Bool) {
        guard let i = index(of: id), !store.people[i].isSelf else { return }
        store.people[i].hidden = hidden ? true : nil
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
        // 記録に出さない人は、ほかの声とまとめない
        let members = store.people.filter { p in
            ids.contains(p.id) && p.hidden != true && p.voices.contains { $0.model == Self.model }
        }
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

    // MARK: - 名前の無い声の夜の整理（2026-11-09）

    /// 夜の整理で触ってよい声か。名前が無く、自分でなく、登録・手直しの声が無く、記録に出さない人でもなく、
    /// 名前・場・声を一度も手で変えていない（まとめた先になったこともない）声だけ。
    /// （場は、知らない声を覚えたときにその場の場が入るので、手で変えたかは updated で見る）
    nonisolated static func mayTidy(_ p: Person) -> Bool {
        !p.isNamed && !p.isSelf && p.pinnedCount == 0 && p.hidden != true && p.updated == nil
    }

    /// 忘れる声: 記録の行がこれ以下で、
    static let tidyForgetLines = 3
    /// これより前に聞いたきりの声（名前の無い声は、行の数に関係なく2週間聞かなければ聞き分けのときに忘れるので、
    /// 行のごく少ない声は、それより早く3日で忘れる）
    static let tidyForgetAfter: TimeInterval = 3 * 86400

    /// 夜の整理の中身（何もしない。決めるだけ）。
    /// - 忘れる: 行が tidyForgetLines 以下で、最後に聞いてから tidyForgetAfter より前の声（古い順に maxForget まで）
    /// - まとめる: 声の特徴の近さが limit 以内で、場（職場・職場以外）が同じ2つ（話した時間の短いほうを長いほうへ。maxMerges 組まで）。
    ///   同じ音声の区切りで別の声とされた2つ（apart）はまとめない。まとめた先をさらにまとめることはしない。
    /// どちらも mayTidy の声だけで、keep に入っている声には触らない。lines は声の番号ごとの、記録の行の数。
    nonisolated static func tidyPlan(_ people: [Person], lines: [String: Int], apart: Set<[String]>, keep: Set<String>,
                                     limit: Float, now: Date, maxMerges: Int = 30,
                                     maxForget: Int = 300) -> (merges: [(source: String, target: String)], forget: [String]) {
        let candidates = people.filter { mayTidy($0) && !keep.contains($0.id) }
        let forget = candidates
            .filter { (lines[$0.id] ?? 0) <= tidyForgetLines && now.timeIntervalSince($0.lastHeard) > tidyForgetAfter }
            .sorted { $0.lastHeard < $1.lastHeard }.prefix(maxForget).map(\.id)
        let forgotten = Set(forget)
        // まとめるのは、いまのモデルの声があるものだけ
        struct Entry {
            let person: Person
            let voices: [[Float]]
            let center: [Float]
        }
        var pool: [Entry] = []
        for p in candidates where !forgotten.contains(p.id) {
            let voices = p.voices.filter { $0.model == model }.map(\.embedding)
            guard let size = voices.first?.count, size > 0 else { continue }
            let same = voices.filter { $0.count == size }
            var sum = [Float](repeating: 0, count: size)
            for v in same { for k in 0..<size { sum[k] += v[k] } }
            pool.append(Entry(person: p, voices: same, center: normalized(sum)))
        }
        pool.sort { ($0.person.seconds, $0.person.id) < ($1.person.seconds, $1.person.id) }
        var merges: [(source: String, target: String)] = []
        var gone = Set<String>(), targets = Set<String>()
        for (i, p) in pool.enumerated() {
            guard merges.count < maxMerges else { break }
            guard !targets.contains(p.person.id) else { continue }
            var best: (id: String, distance: Float)?
            // 話した時間の長いほう（並びで後ろ）へまとめる
            for q in pool[(i + 1)...] where !gone.contains(q.person.id) && q.center.count == p.center.count
                && q.person.context == p.person.context {
                guard !apart.contains([p.person.id, q.person.id].sorted()) else { continue }
                // まず真ん中どうしで大まかに見てから、声ごとに測る
                let rough = 1 - zip(p.center, q.center).reduce(0) { $0 + $1.0 * $1.1 }
                guard rough <= limit + 0.08 else { continue }
                let d = p.voices.map { top3($0, q.voices) }.reduce(0, +) / Float(p.voices.count)
                if d <= limit, d < (best?.distance ?? .infinity) { best = (q.person.id, d) }
            }
            if let best {
                merges.append((p.person.id, best.id))
                gone.insert(p.person.id)
                targets.insert(best.id)
            }
        }
        return (merges, forget)
    }

    /// 夜の整理の中身を決める。覚えている人を読めていない（名前のある人が1人もいない）ときは、何もしないよう nil。
    func tidyPlan(lines: [String: Int], apart: Set<[String]>, keep: Set<String>, limit: Float,
                  now: Date = .now) -> (merges: [(source: String, target: String)], forget: [String])? {
        let all = store.people
        guard all.contains(where: { $0.isNamed }) else { return nil }
        return Self.tidyPlan(all, lines: lines, apart: apart, keep: keep, limit: limit, now: now)
    }

    /// まだ夜の整理で触ってよい声か（決めてから、まとめるまでのあいだに手で直していないか）
    func mayTidy(_ id: String) -> Bool { person(id).map { Self.mayTidy($0) } ?? false }

    /// 夜の整理で忘れる（触ってよい声だけ）。忘れた数を返す。
    func forgetTidied(_ ids: Set<String>) -> Int {
        let gone = store.people.filter { ids.contains($0.id) && Self.mayTidy($0) }.map(\.id)
        guard !gone.isEmpty else { return 0 }
        let set = Set(gone)
        forget { set.contains($0.id) }
        save()
        return gone.count
    }

    /// テレビや動画の声だった、名前の無い声を忘れる（登録・手直しした声は残す）。
    func forgetUnnamed(_ ids: Set<String>) {
        forget { ids.contains($0.id) && !$0.isNamed && $0.pinnedCount == 0 && $0.hidden != true }
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
        var hidden: Bool? = nil
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
                       samples: p.samples, updated: p.updated, hidden: p.hidden)
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
        // 脇に置いたひとこまは、ほかの端末から戻ってこないようにする
        let aside = Set(asideList().map(\.id))
        for rp in remote.people {
            let voices = rp.voices.map { Voice(embedding: Self.unpack($0.embedding), pinned: true, added: $0.added, model: $0.model) }
            let remoteTouched = max(rp.updated ?? .distantPast, rp.lastHeard)
            if let i = index(of: rp.id) {
                var p = store.people[i]
                let before = p
                if (rp.updated ?? .distantPast) > (p.updated ?? .distantPast), !p.isSelf {
                    p.name = rp.name
                    p.context = rp.context
                    p.hidden = rp.hidden
                    p.updated = rp.updated
                }
                let known = Set(p.voices.map(\.embedding))
                let added = voices.filter { !known.contains($0.embedding) && !$0.embedding.isEmpty }
                if !added.isEmpty { p.voices += added }
                p.seconds = max(p.seconds, rp.seconds)
                p.lastHeard = max(p.lastHeard, rp.lastHeard)
                for sample in rp.samples where !p.samples.contains(sample) && !aside.contains(SetAside.key(rp.id, sample)) {
                    p.samples.append(sample)
                }
                p.samples = Array(p.samples.suffix(3))
                if !added.isEmpty || p.name != before.name || p.context != before.context || p.hidden != before.hidden
                    || p.seconds != before.seconds || p.lastHeard != before.lastHeard || p.samples != before.samples {
                    store.people[i] = p
                    if !added.isEmpty { trimVoices(i) }
                    changed = true
                }
            } else {
                if let gone = removed[rp.id], gone >= remoteTouched { continue }
                store.people.append(Person(id: rp.id, name: rp.name, context: rp.context, voices: voices,
                                           seconds: rp.seconds, lastHeard: rp.lastHeard, samples: rp.samples,
                                           updated: rp.updated, hidden: rp.hidden))
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
                                     lastHeard: p.lastHeard, samples: p.samples, updated: p.updated, hidden: p.hidden)
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

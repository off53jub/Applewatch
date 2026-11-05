import Foundation

// 夜に、家の PC の別の種類のモデルで見比べる（2026-11-06）。
// - 話者: iPhone の声のモデルが決めた行の声を、PC の話者モデル（別の種類）でも測り、名前のある人どうしで食い違ったら確認箱に出す。
//   名前は自動では変えない（本人が「直す」を押したときだけ）。
// - 場面: PC の音の分類（AudioSet）と、iPhone の音の聞き分け（行の背景の音）で多数決し、会話の場面（電車・車・店・職場など）を付ける。

/// PC の話者モデルで測った、名前のある人の声（人の番号 → 声の特徴）。UserDefaults の pcVoiceRefs
enum PCVoiceRefs {
    private static let key = "pcVoiceRefs"

    static func load() -> [String: [[Float]]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let refs = try? JSONDecoder().decode([String: [[Float]]].self, from: data) else { return [:] }
        return refs
    }

    static func save(_ refs: [String: [[Float]]]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(refs), forKey: key)
    }

    /// 2つの声の遠さ（1 − 内積。PC は長さ1にそろえて返す）
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        return 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// PC のモデルでは誰の声に近いか。記録の人（assigned）より、ほかの人のほうが 0.1 以上近いときだけ、その人を返す
    static func disagreement(_ embedding: [Float], assigned: String, refs: [String: [[Float]]]) -> String? {
        guard let own = refs[assigned] else { return nil }
        func nearest(_ list: [[Float]]) -> Float { list.map { distance(embedding, $0) }.min() ?? 2 }
        let mine = nearest(own)
        guard let best = refs.filter({ $0.key != assigned }).map({ (id: $0.key, d: nearest($0.value)) })
            .min(by: { $0.d < $1.d }) else { return nil }
        return mine - best.d >= 0.1 ? best.id : nil
    }
}

/// 場面を決める（AudioSet の名前と、iPhone の背景の音の名前を、場面の名前にそろえて数える）
enum SceneVote {
    /// AudioSet の名前 → 場面
    static func scene(forTag name: String) -> String? {
        let n = name.lowercased()
        if n.contains("television") || n.contains("radio") { return "テレビ・ラジオ" }
        if n.contains("train") || n.contains("subway") || n.contains("rail") { return "電車" }
        if n.contains("car") || n.contains("vehicle") || n.contains("bus") || n.contains("traffic") || n.contains("engine") {
            return "車・道路"
        }
        if n.contains("dishes") || n.contains("cutlery") || n.contains("chatter") || n.contains("crowd")
            || n.contains("hubbub") || n.contains("babble") { return "店・人の多い所" }
        if n.contains("typing") || n.contains("keyboard") || n.contains("printer") { return "職場・机" }
        if n.contains("wind") || n.contains("rain") || n.contains("bird") || n.contains("water") { return "屋外" }
        if n.contains("music") || n.contains("singing") { return "音楽" }
        return nil
    }

    /// iPhone の背景の音の名前 → 場面
    static func scene(forSound sound: String) -> String? {
        if sound.contains("テレビ") { return "テレビ・ラジオ" }
        if sound.contains("電車") { return "電車" }
        if sound.contains("車") { return "車・道路" }
        if sound.contains("食器") || sound.contains("料理") || sound.contains("拍手") || sound.contains("笑い") { return "店・人の多い所" }
        if sound.contains("キーボード") { return "職場・机" }
        if sound.contains("雨") || sound.contains("犬") || sound.contains("水") { return "屋外" }
        if sound.contains("音楽") { return "音楽" }
        return nil
    }

    /// PC の窓ごとの上位の音（確からしさ 0.3 以上）と、iPhone の行ごとの背景の音で数え、
    /// 両方のモデルが挙げていて、合わせて2票以上の場面を返す（無ければ nil）
    static func decide(pcTags: [[(name: String, prob: Double)]], phoneSounds: [String]) -> String? {
        var pc: [String: Int] = [:], phone: [String: Int] = [:]
        for window in pcTags {
            for scene in Set(window.filter { $0.prob >= 0.3 }.compactMap { scene(forTag: $0.name) }) { pc[scene, default: 0] += 1 }
        }
        for sound in phoneSounds {
            for part in sound.components(separatedBy: CharacterSet(charactersIn: "・、 ")) {
                if let scene = scene(forSound: part) { phone[scene, default: 0] += 1 }
            }
        }
        let both = Set(pc.keys).intersection(phone.keys)
        return both.map { (scene: $0, votes: (pc[$0] ?? 0) + (phone[$0] ?? 0)) }
            .filter { $0.votes >= 2 }
            .max { $0.votes < $1.votes }?.scene
    }
}

extension Pipeline {
    private static let crossCheckedKey = "speakerCrossChecked"
    private static let sceneCheckedKey = "sceneChecked"

    /// 夜の聞き直しのあとに呼ぶ。直近2日の閉じた会話を、PC の話者モデルと音の分類で見比べる（1回に数件ずつ）
    func crossCheckWithPC(limit: Int = 6) async {
        guard homePC.shouldTry else { return }
        _ = try? await homePC.hello()
        if homePC.features.contains("speakers") { await crossCheckSpeakers(limit: limit) }
        if homePC.features.contains("scene") { await crossCheckScenes(limit: limit) }
    }

    /// 名前のある人（自分も）の声を PC の話者モデルで測っておく（声のひとこまから。まだの人だけ）
    private func pcReferences() async -> [String: [[Float]]] {
        var refs = PCVoiceRefs.load()
        for person in people where person.isNamed && !person.samples.isEmpty && refs[person.id] == nil {
            var list: [[Float]] = []
            for sample in person.samples {
                guard let url = await archive.playableURL(for: sample.audio),
                      let embeddings = try? await homePC.speakerEmbeddings(url, segments: [(sample.start, sample.end)]),
                      let first = embeddings.first, let embedding = first else { continue }
                list.append(embedding)
            }
            if !list.isEmpty { refs[person.id] = list }
        }
        PCVoiceRefs.save(refs)
        return refs
    }

    private func crossCheckSpeakers(limit: Int) async {
        let refs = await pcReferences()
        guard refs.count >= 2 else { return }
        var checked = UserDefaults.standard.stringArray(forKey: Self.crossCheckedKey) ?? []
        var box = newVoices
        var done = 0
        for day in recordedDays().prefix(2) {
            for c in conversations(on: day) where c.closed && c.media == nil {
                let key = day + "|" + String(Int(c.start.timeIntervalSince1970))
                guard !checked.contains(key), done < limit else { continue }
                let lines = c.lines.filter { line in
                    line.media == nil && line.offset != nil && line.audio != nil && line.text.count >= 4
                        && line.speakerID.map { refs[$0] != nil } == true
                }
                for (audio, group) in Dictionary(grouping: lines, by: { $0.audio ?? "" }) {
                    guard let url = await archive.playableURL(for: audio) else { continue }
                    let sorted = group.sorted { ($0.offset ?? 0) < ($1.offset ?? 0) }
                    let ends = Self.lineEnds(sorted.map { (offset: $0.offset ?? 0, chars: $0.text.count) })
                    let spans = sorted.indices.map { (start: sorted[$0].offset ?? 0, end: ends[$0]) }
                    guard let embeddings = try? await homePC.speakerEmbeddings(url, segments: spans) else { continue }
                    for (line, embedding) in zip(sorted, embeddings) {
                        guard let embedding, let assigned = line.speakerID,
                              let other = PCVoiceRefs.disagreement(embedding, assigned: assigned, refs: refs) else { continue }
                        let id = "pc-\(assigned)-\(Int(line.time.timeIntervalSince1970))"
                        guard !box.notes.contains(where: { $0.id == id }) else { continue }
                        var note = NewVoiceBox.Note(id: id, time: line.time, personID: assigned, claimed: nil, quote: line.text)
                        note.pcSuggests = other
                        box.notes.append(note)
                    }
                }
                checked.append(key)
                done += 1
            }
        }
        box.save()
        newVoices = box
        UserDefaults.standard.set(Array(checked.suffix(400)), forKey: Self.crossCheckedKey)
    }

    private func crossCheckScenes(limit: Int) async {
        var checked = UserDefaults.standard.stringArray(forKey: Self.sceneCheckedKey) ?? []
        var done = 0
        for day in recordedDays().prefix(2) {
            for c in conversations(on: day) where c.closed && c.media == nil && c.scene == nil {
                let key = day + "|" + String(Int(c.start.timeIntervalSince1970))
                guard !checked.contains(key), done < limit else { continue }
                // 会話の中から、10秒の窓を6つまで（始め・中ほど・終わりにばらけるように）
                let withAudio = c.lines.filter { $0.audio != nil && $0.offset != nil }
                let step = max(1, withAudio.count / 6)
                let picks = stride(from: 0, to: withAudio.count, by: step).prefix(6).map { withAudio[$0] }
                var tags: [[(name: String, prob: Double)]] = []
                for (audio, group) in Dictionary(grouping: picks, by: { $0.audio ?? "" }) {
                    guard let url = await archive.playableURL(for: audio) else { continue }
                    let spans = group.map { (start: max(0, ($0.offset ?? 0) - 2), end: ($0.offset ?? 0) + 8) }
                    if let result = try? await homePC.sceneTags(url, segments: spans) { tags += result }
                }
                if let scene = SceneVote.decide(pcTags: tags, phoneSounds: c.lines.compactMap(\.sound)) {
                    setScene(scene, start: c.start, day: day)
                }
                checked.append(key)
                done += 1
            }
        }
        UserDefaults.standard.set(Array(checked.suffix(400)), forKey: Self.sceneCheckedKey)
    }

    /// PC の話者モデルの言う人に、その行を直す（本人が押したとき）
    func applyPCSuggestion(_ note: NewVoiceBox.Note) async {
        guard let target = note.pcSuggests else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: note.time)
        let lines = conversations(on: day).flatMap(\.lines)
        guard let i = lines.firstIndex(where: { $0.time == note.time && $0.speakerID == note.personID }) else { return }
        let next = i + 1 < lines.count ? lines[i + 1] : nil
        await fixSpeaker(of: lines[i], next: next, to: target, scope: .line)
        dismissNewVoice(note.id)
    }
}

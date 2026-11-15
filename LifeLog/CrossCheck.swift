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

/// 家の PC の話し手の見比べ（GET /speaker-check。features の "spkcheck"。2026-11-16）。
/// iPhone の見比べ（声のひとこまを物差しに、行の声をそのまま比べる）は、自己点検で 204 行中 143 行（70%）が食い違い、使えなかった。
/// PC は名寄せ用に置いてある声の特徴（voices.py）で、直近 7 日のその人の行の平均（同じ音声を除く）を物差しにし、
/// ほかの人のほうが 0.15 以上近い行だけを返す（2026-11-09〜15 の記録どおりの行で 1875 行中 15 行＝0.8%）。docs/v18-speaker-check.md
struct SpeakerCheckFeed: Decodable {
    struct Item: Decodable {
        var day: String
        var line_time: String
        var assigned: String
        var suggest: String
        var gap: Double
    }
    struct Day: Decodable {
        var day: String
        var checked: Int
        var items: [Item]
    }
    var available: Bool?
    var days: [Day]?
}

enum SpeakerCheck {
    static let feature = "spkcheck"
    /// 日ごとに、もう数えた「見た行」（PC は作り直すたびに同じ日を返すので、増えた分だけ数える）
    static let countedKey = "pcSpeakerCheckCounted"
    /// もう確認箱に出した疑い（本人が消しても、次に読んだとき出し直さない）
    static let seenKey = "pcSpeakerCheckSeen"
    static let seenLimit = 2000
    static let countedDays = 14
    /// 行の時刻の合わせ方（PC はミリ秒まで返す）
    static let tolerance: TimeInterval = 1

    static func decode(_ data: Data) -> [SpeakerCheckFeed.Day]? {
        guard let feed = try? JSONDecoder().decode(SpeakerCheckFeed.self, from: data), feed.available == true else { return nil }
        return feed.days ?? []
    }

    static func time(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    /// 増えた分だけ（減ったときは 0。PC の窓から外れた日は数え直さない）
    static func added(counted: [String: Int], day: String, checked: Int) -> Int {
        max(0, checked - (counted[day] ?? 0))
    }

    static func noteID(assigned: String, time: Date) -> String {
        "pc-\(assigned)-\(Int(time.timeIntervalSince1970))"
    }

    /// 古い日の数えを捨てる（新しい日から countedDays 日だけ残す）
    static func trimmed(_ counted: [String: Int]) -> [String: Int] {
        let keep = Set(counted.keys.sorted().suffix(countedDays))
        return counted.filter { keep.contains($0.key) }
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

    /// 昼の見比べ（2026-11-06）。アプリを開いていて家の PC につながるとき、閉じたばかりの会話の話し手を PC の声のモデルでも測る。
    /// 20分に1回まで・1回に2つの会話まで。夜と同じく、食い違った行は確認箱と行の「？」に出し、記録は変えない
    func crossCheckDaytime() async {
        let key = "speakerCrossCheckedDay"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date.now.timeIntervalSince(last) < 20 * 60 { return }
        guard homePC.shouldTry else { return }
        UserDefaults.standard.set(Date.now, forKey: key)
        _ = try? await homePC.hello()
        guard homePC.features.contains("speakers") else { return }
        await crossCheckSpeakers(limit: 2)
    }

    /// 名前のある人（自分も）の声を PC の話者モデルで測っておく（声のひとこまから。まだの人だけ）
    private func pcReferences() async -> [String: [[Float]]] {
        // PC の話者モデルが替わったら、前のモデルで測った声は使えないので測り直す（2026-11-06）
        let model = homePC.speakerModel ?? "eres2net-zh"
        if UserDefaults.standard.string(forKey: "pcVoiceRefsModel") != model {
            PCVoiceRefs.save([:])
            UserDefaults.standard.set(model, forKey: "pcVoiceRefsModel")
        }
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
        // 2026-11-16: 家の PC が置き場所の声の特徴で見比べていれば、その答えを使う（音声を送らない・測り直さない）
        if homePC.features.contains(SpeakerCheck.feature) {
            await applyPCSpeakerCheck()
            return
        }
        let refs = await pcReferences()
        guard refs.count >= 2 else { return }
        var checked = UserDefaults.standard.stringArray(forKey: Self.crossCheckedKey) ?? []
        // 見比べているあいだに本人や時計が確認箱を変えても消さないよう、足す分だけ集めて最後に今の箱へ足す（見直しで直した）
        var added: [NewVoiceBox.Note] = []
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
                    // 行の終わりが分かっていれば、それを使う（2026-11-06）
                    let spans = sorted.indices.map { (start: sorted[$0].offset ?? 0, end: sorted[$0].end ?? ends[$0]) }
                    guard let embeddings = try? await homePC.speakerEmbeddings(url, segments: spans) else { continue }
                    Tally.add("pc.speakerChecked", embeddings.compactMap { $0 }.count)
                    for (line, embedding) in zip(sorted, embeddings) {
                        guard let embedding, let assigned = line.speakerID,
                              let other = PCVoiceRefs.disagreement(embedding, assigned: assigned, refs: refs) else { continue }
                        let id = "pc-\(assigned)-\(Int(line.time.timeIntervalSince1970))"
                        guard !newVoices.notes.contains(where: { $0.id == id }), !added.contains(where: { $0.id == id }) else { continue }
                        var note = NewVoiceBox.Note(id: id, time: line.time, personID: assigned, claimed: nil, quote: line.text)
                        note.pcSuggests = other
                        added.append(note)
                        Tally.add("pc.speakerDiffer")
                        // 記録の行にも印（話し手の名前のあとに「？」）
                        markSpeakerDoubt(other, time: line.time, day: day)
                    }
                }
                checked.append(key)
                done += 1
            }
        }
        var box = newVoices
        for note in added where !box.notes.contains(where: { $0.id == note.id }) { box.notes.append(note) }
        box.save()
        newVoices = box
        UserDefaults.standard.set(Array(checked.suffix(400)), forKey: Self.crossCheckedKey)
    }

    /// 家の PC の見比べの答えを、確認箱と行の「？」に出す（記録の話し手は変えない）
    private func applyPCSpeakerCheck() async {
        guard let body = try? await homePC.appFeed("speaker-check", feature: SpeakerCheck.feature),
              let days = SpeakerCheck.decode(body) else { return }
        var counted = UserDefaults.standard.dictionary(forKey: SpeakerCheck.countedKey) as? [String: Int] ?? [:]
        var seen = UserDefaults.standard.stringArray(forKey: SpeakerCheck.seenKey) ?? []
        var seenSet = Set(seen)
        var added: [NewVoiceBox.Note] = []
        for day in days {
            let more = SpeakerCheck.added(counted: counted, day: day.day, checked: day.checked)
            if more > 0 { Tally.add("pc.speakerChecked", more) }
            counted[day.day] = max(counted[day.day] ?? 0, day.checked)
            guard !day.items.isEmpty else { continue }
            let lines = conversations(on: day.day).flatMap(\.lines)
            var marks: [(other: String, time: Date)] = []
            for item in day.items {
                guard let when = SpeakerCheck.time(item.line_time),
                      let line = lines.first(where: {
                          $0.speakerID == item.assigned && abs($0.time.timeIntervalSince(when)) < SpeakerCheck.tolerance
                      }) else { continue }
                let id = SpeakerCheck.noteID(assigned: item.assigned, time: line.time)
                guard !seenSet.contains(id), !newVoices.notes.contains(where: { $0.id == id }) else { continue }
                seenSet.insert(id)
                seen.append(id)
                var note = NewVoiceBox.Note(id: id, time: line.time, personID: item.assigned, claimed: nil, quote: line.text)
                note.pcSuggests = item.suggest
                added.append(note)
                marks.append((other: item.suggest, time: line.time))
                Tally.add("pc.speakerDiffer")
            }
            markSpeakerDoubts(marks, day: day.day)
        }
        UserDefaults.standard.set(SpeakerCheck.trimmed(counted), forKey: SpeakerCheck.countedKey)
        UserDefaults.standard.set(Array(seen.suffix(SpeakerCheck.seenLimit)), forKey: SpeakerCheck.seenKey)
        guard !added.isEmpty else { return }
        var box = newVoices
        for note in added where !box.notes.contains(where: { $0.id == note.id }) { box.notes.append(note) }
        box.save()
        newVoices = box
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
                if !tags.isEmpty { Tally.add("pc.sceneChecked") }
                if let scene = SceneVote.decide(pcTags: tags, phoneSounds: c.lines.compactMap(\.sound)) {
                    setScene(scene, start: c.start, day: day)
                    Tally.add("pc.sceneSet")
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
        Tally.add("pc.speakerAccepted")
        dismissNewVoice(note.id)
    }
}

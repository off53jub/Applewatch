import Foundation

// s29「声を分ける・当てる」のアプリ側・当てる担当（2026-11-27。docs/system-proposal-2026-11-13.md の 追記 19）。
// 受け持ち: 声4・声7・声8（作る側）・声10・声11・声12・声13・声14（当てる側）・声23（使う側）。
// しきい値はすべて仮。記録の話し手を変える動きは、初めは既定オフ（数えるだけ＝影）。問いを減らすだけの動き（声4・声8）は既定オン。
// 決まりは純粋な計算にして LifeLogTests/S29RVoiceTests.swift で確かめる。つなぎこみは SpeakerLabeler.label と S29RPipeline.swift。

// MARK: - 切り替え（UserDefaults。画面はまだ無い）

enum S29RFlags {
    /// 声4 雑音まみれの短い声から人物Nを作らない（既定オン）
    static let gateKey = "s29r.gate"
    /// 声8 通りすがりらしい声は人物Nにせず箱へ（既定オン）
    static let passerbyKey = "s29r.passerby"
    /// 声7 場の人数より多く分けない（既定オフ＝影）
    static let headcountKey = "s29r.headcount"
    /// 声10 場面が同じ見本と先に比べる（既定オフ＝影）
    static let sceneKey = "s29r.sceneFirst"
    /// 声11 見本を短い・雑音の多いものから消す（既定オフ＝影。わけは docs/s29-r.md）
    static let qualityTrimKey = "s29r.qualityTrim"
    /// 声12・声14 交互に話す相手を区切りまたぎで続ける（既定オフ＝影）
    static let chainKey = "s29r.chain"
    /// 声13 声以外の手がかりがはっきりしているときだけ強く加点（既定オフ＝影）
    static let strongKey = "s29r.strongBonus"

    static func isOn(_ key: String, default value: Bool, defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? value
    }

    static var gate: Bool { isOn(gateKey, default: true) }
    static var passerby: Bool { isOn(passerbyKey, default: true) }
    static var headcount: Bool { isOn(headcountKey, default: false) }
    static var sceneFirst: Bool { isOn(sceneKey, default: false) }
    static var qualityTrim: Bool { isOn(qualityTrimKey, default: false) }
    static var chain: Bool { isOn(chainKey, default: false) }
    static var strongBonus: Bool { isOn(strongKey, default: false) }
}

// MARK: - 区切りの手がかり（Pipeline が作って SpeakerLabeler.label に渡す）

struct S29RSpan: Sendable, Equatable {
    var start: Double
    var end: Double
}

struct S29RHints: Sendable {
    /// 周りの音の底（dBFS）と、声との差（dB）。NoiseMeter の測り。分からなければ nil
    var noiseFloor: Float? = nil
    var margin: Float? = nil
    var noisy: Bool = false
    /// 声のある区間（端末内の VAD）。分からなければ nil
    var speech: [S29RSpan]? = nil
    /// 時計の録音か（nil は分からない）
    var watch: Bool? = nil
    /// 区切りの始まり（区切りまたぎの鎖に使う）
    var start: Date? = nil
    /// 場の人数（自分を含む）。予定・会議モード・「今から A さんと」から。分からなければ nil
    var headcount: Int? = nil
    /// 声以外の手がかりがはっきりしている人（声13 の強い加点の相手）
    var strong: Set<String> = []

    /// 場面の札（声10）。騒がしさが分からなければ nil（場面別には比べない）
    var scene: String? { noiseFloor == nil ? nil : S29RScene.tag(watch: watch, noisy: noisy) }
    var level: S29RGate.Level { S29RGate.level(floor: noiseFloor, margin: margin, noisy: noisy) }
}

// MARK: - 声4 足切り

enum S29RGate {
    enum Level: Equatable, Sendable { case quiet, noisy, veryNoisy }

    /// 静かな所で人物Nを作る長さ（秒。今と同じ 3 秒）
    static let quietSeconds: Double = 3
    /// 騒がしい所（NoiseMeter.isNoisy）では、これだけ話していたときだけ（仮）
    static let noisySeconds: Double = 6
    /// とても騒がしい所では、これだけ話していたときだけ（仮）
    static let veryNoisySeconds: Double = 10
    /// 周りの音の底がこれ以上か、声との差がこれ未満なら「とても騒がしい」（仮）
    static let veryNoisyFloor: Float = -35
    static let veryNoisyMargin: Float = 6
    /// まとまりの長さのうち、VAD が声と見た割合がこれ未満なら作らない（仮）
    static let minVoiceShare = 0.5

    static func level(floor: Float?, margin: Float?, noisy: Bool) -> Level {
        if let floor, floor >= veryNoisyFloor { return .veryNoisy }
        if let margin, margin < veryNoisyMargin { return .veryNoisy }
        return noisy ? .noisy : .quiet
    }

    static func minSeconds(_ level: Level) -> Double {
        switch level {
        case .quiet: quietSeconds
        case .noisy: noisySeconds
        case .veryNoisy: veryNoisySeconds
        }
    }

    /// まとまりの区間のうち、声のある区間に重なる割合（区間か声の区間が無ければ nil）
    static func voiceShare(_ parts: [S29RSpan], speech: [S29RSpan]) -> Double? {
        var total = 0.0, voiced = 0.0
        for p in parts where p.end > p.start {
            total += p.end - p.start
            for s in speech {
                let overlap = min(p.end, s.end) - max(p.start, s.start)
                if overlap > 0 { voiced += overlap }
            }
        }
        guard total > 0 else { return nil }
        return min(1, voiced / total)
    }

    /// 知らない声から新しい人物Nを作ってよいか（届かないものは「だれか分からない」のまま）
    static func mayCreate(seconds: Double, share: Double?, level: Level) -> Bool {
        guard seconds >= minSeconds(level) else { return false }
        if let share, share < minVoiceShare { return false }
        return true
    }
}

// MARK: - 声8 通りすがりの箱（作る側）

/// 知らない短い声を、人物Nにせずに入れておく 1 つの箱（端末のメモリだけ。書き込みを増やさない）。
/// 別の区切りでまた同じ声が聞こえたら、そのとき初めて人物Nにする（＝1 区切りだけ・合計が短い声は人物Nにならない）。
/// 箱の声は、名前のある人との比べ相手にもする（前なら人物Nとして比べ相手になっていたので、名前のある人の当たりを変えない）。
/// 声4 で足切りした声も、比べ相手として箱に入れる。
struct S29RPasserbyBox: Sendable {
    struct Entry: Sendable, Equatable {
        var embedding: [Float]
        var seconds: Double
        var audio: String
        var start: Double
        var end: Double
        var heard: Date
    }

    /// これより短い知らない声は箱へ（秒。仮）
    static let maxSeconds: Double = 8
    /// 箱に置いておく長さ（仮 3 日。夜の整理が行の少ない人物Nを忘れるのと同じ）
    static let keep: TimeInterval = 3 * 86400
    /// 箱の大きさ（古い順に捨てる。1 日に通りすがりは 23〜38 人なので、3 日ぶんより多め。仮）
    static let limit = 300

    var entries: [Entry] = []

    static func shouldBox(seconds: Double) -> Bool { seconds < maxSeconds }

    /// 別の区切りで聞いた箱の声のうち、accept 以内でいちばん近いもの
    func match(_ embedding: [Float], audio: String, accept: Float) -> Int? {
        var best: (index: Int, distance: Float)?
        for (i, e) in entries.enumerated() where e.audio != audio && e.embedding.count == embedding.count {
            let d = SpeakerLabeler.top3(embedding, [e.embedding])
            if d <= accept, d < (best?.distance ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }

    /// 別の区切りで聞いた箱の声までの、いちばん近い距離（無ければ 1）。名前のある人の当たりを変えないための比べ相手
    func nearest(_ embedding: [Float], audio: String) -> Float {
        var best: Float = 1
        for e in entries where e.audio != audio && e.embedding.count == embedding.count {
            best = min(best, SpeakerLabeler.top3(embedding, [e.embedding]))
        }
        return best
    }

    mutating func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    mutating func take(_ index: Int) -> Entry { entries.remove(at: index) }

    mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.heard) > Self.keep }
    }
}

// MARK: - 声7 場の人数でまとめ直す

enum S29RHeadcount {
    /// これより離れた 2 つのまとまりは、人数を超えていてもまとめない（コサイン距離。仮）
    static let maxMergeDistance: Float = 0.7

    /// 重みつきの平均（長さ 1 にはしない。呼ぶ側でそろえる）
    static func combine(_ a: [Float], _ wa: Double, _ b: [Float], _ wb: Double) -> [Float] {
        guard a.count == b.count else { return a }
        let total = max(wa + wb, 0.001)
        let x = Float(wa / total), y = Float(wb / total)
        var out = [Float](repeating: 0, count: a.count)
        for k in 0..<a.count { out[k] = a[k] * x + b[k] * y }
        return out
    }

    private static func unit(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var dot: Float = 0
        for k in 0..<a.count { dot += a[k] * b[k] }
        return 1 - dot
    }

    /// まとまり（中心・話した長さ）を、limit 個まで近い組からまとめる。返り値は まとめる元 → 残るまとまり。
    /// 短いほうを長いほうへ。maxMergeDistance より離れた組はまとめない（その時は limit を超えたまま）。
    static func plan(_ clusters: [String: (center: [Float], seconds: Double)], limit: Int) -> [String: String] {
        guard limit >= 1, clusters.count > limit else { return [:] }
        var keys = clusters.keys.sorted()
        var center: [String: [Float]] = [:]
        var seconds: [String: Double] = [:]
        for k in keys {
            center[k] = unit(clusters[k]!.center)
            seconds[k] = clusters[k]!.seconds
        }
        var root: [String: String] = [:]
        while keys.count > limit {
            var best: (a: String, b: String, d: Float)?
            for i in 0..<keys.count {
                for j in (i + 1)..<keys.count {
                    let d = cosineDistance(center[keys[i]]!, center[keys[j]]!)
                    if d < (best?.d ?? .infinity) { best = (keys[i], keys[j], d) }
                }
            }
            guard let pair = best, pair.d <= maxMergeDistance else { break }
            let sa = seconds[pair.a]!, sb = seconds[pair.b]!
            let keep = sa >= sb ? pair.a : pair.b
            let gone = keep == pair.a ? pair.b : pair.a
            center[keep] = unit(combine(center[keep]!, seconds[keep]!, center[gone]!, seconds[gone]!))
            seconds[keep] = sa + sb
            root[gone] = keep
            for (k, v) in root where v == gone { root[k] = keep }
            keys.removeAll { $0 == gone }
        }
        return root
    }
}

// MARK: - 声10 場面別の見本・声11 見本の残し方

/// 自動で覚えた声 1 つの、覚えたときの様子（people.json の Person.s29VoiceInfo。名前のある人だけ持つ）
struct S29RVoiceInfo: Codable, Sendable, Equatable {
    /// 場面の札（"watch.noisy" など）
    var scene: String?
    /// まとまりが話した長さ（秒）
    var seconds: Double?
    /// 区切りの、声と周りの音の差（dB）
    var margin: Float?

    /// 声の見分け（覚えた時刻。keptKey と同じ形）
    static func key(_ added: Date) -> String {
        String(format: "%.3f", added.timeIntervalSinceReferenceDate)
    }

    /// 今ある声の分だけ残す
    static func pruned(_ info: [String: S29RVoiceInfo], keys: Set<String>) -> [String: S29RVoiceInfo]? {
        let kept = info.filter { keys.contains($0.key) }
        return kept.isEmpty ? nil : kept
    }
}

enum S29RScene {
    /// 場面が同じ見本がこれだけあれば、先にそれと比べる（仮）
    static let minSame = 2

    /// 場面の札。マイク（時計・iPhone）と騒がしさで分ける（今ある情報で分けられる範囲）
    static func tag(watch: Bool?, noisy: Bool) -> String {
        let mic: String
        switch watch {
        case true?: mic = "watch"
        case false?: mic = "phone"
        case nil: mic = "any"
        }
        return mic + (noisy ? ".noisy" : ".quiet")
    }

    /// 場面が同じ見本が minSame 以上あればそれと、無ければ全部と比べる（近い 3 つの平均）
    static func distance(_ embedding: [Float], voices: [(embedding: [Float], scene: String?)], scene: String?) -> Float {
        var same: [[Float]] = []
        var all: [[Float]] = []
        for v in voices {
            all.append(v.embedding)
            if let scene, v.scene == scene { same.append(v.embedding) }
        }
        if same.count >= minSame { return SpeakerLabeler.top3(embedding, same) }
        return SpeakerLabeler.top3(embedding, all)
    }
}

struct S29RTrimItem: Sendable, Equatable {
    var key: String
    var added: Date
    var info: S29RVoiceInfo?
}

enum S29RTrim {
    /// 場面ごとに、これだけは残す（騒がしい所の見本まで消えないように。仮）
    static let minPerScene = 3
    /// 古さの減点（30 日で 0.5。仮。ずっと古い声が残り続けないように）
    static let agePenaltyPer30Days = 0.5

    /// 見本の良さ（0〜1 から古さを引く）。長さ 10 秒と声の差 24 dB で満点。様子が分からない声は 0.5
    static func score(_ item: S29RTrimItem, now: Date) -> Double {
        var quality = 0.5
        if let info = item.info {
            let sec = min(max(info.seconds ?? 5, 0), 10) / 10
            let margin = info.margin.map { Double(min(max($0, 0), 24)) / 24 } ?? 0.5
            quality = 0.5 * sec + 0.5 * margin
        }
        let days = max(0, now.timeIntervalSince(item.added)) / 86400
        return quality - min(0.5, agePenaltyPer30Days * days / 30)
    }

    /// 今のやり方（新しい順に max 個）
    static func keepByAge(_ items: [S29RTrimItem], max: Int) -> Set<String> {
        Set(items.sorted { $0.added > $1.added }.prefix(max).map(\.key))
    }

    /// 声11 のやり方: 場面ごとに minPerScene まで良い順に残し、残りの枠を良い順に埋める（短い・雑音の多い・古いものから消える）
    static func keepByQuality(_ items: [S29RTrimItem], max: Int, now: Date) -> Set<String> {
        guard items.count > max else { return Set(items.map(\.key)) }
        let ranked = items.sorted { a, b in
            let sa = score(a, now: now), sb = score(b, now: now)
            return sa != sb ? sa > sb : a.added > b.added
        }
        var keep: Set<String> = []
        var perScene: [String: Int] = [:]
        for item in ranked {
            guard let scene = item.info?.scene, keep.count < max else { continue }
            if perScene[scene, default: 0] < minPerScene {
                keep.insert(item.key)
                perScene[scene, default: 0] += 1
            }
        }
        for item in ranked where keep.count < max { keep.insert(item.key) }
        return keep
    }
}

// MARK: - 声12・声14 交互に話す相手の鎖

enum S29RChain {
    /// 2 つのまとまりが、区切りの話した長さのこれだけを占める（仮）
    static let coverShare = 0.8
    /// 話し手の入れ替わりがこれだけある（仮）
    static let minSwitches = 4
    /// どちらのまとまりもこれだけ話している（秒。仮）
    static let minSeconds: Double = 3
    /// 前の区切りの相手を選ぶのは、受け入れる近さ＋これ以内のとき（仮）
    static let slack: Float = 0.06
    /// 前の区切りの終わりから、これより後に始まった区切りへは続けない（秒。仮）
    static let maxGap: TimeInterval = 120
    /// 声14 自分の声が「固まった」とする数: 登録・手直しの声がこれだけ（仮）
    static let selfPinnedSolid = 3
    /// …か、今のモデルの声が全部でこれだけ（仮）
    static let selfVoicesSolid = 8

    struct State: Sendable, Equatable {
        var partner: String
        var end: Date
        var watch: Bool?
    }

    /// 交互に話す 2 つのまとまり（長く話した順）。当てはまらなければ nil
    static func twoWay(_ turns: [(speaker: String, start: Double, end: Double)]) -> (String, String)? {
        var seconds: [String: Double] = [:]
        var total = 0.0
        for t in turns where t.end > t.start {
            seconds[t.speaker, default: 0] += t.end - t.start
            total += t.end - t.start
        }
        let top = seconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard top.count >= 2, total > 0 else { return nil }
        let a = top[0], b = top[1]
        guard b.value >= minSeconds, (a.value + b.value) / total >= coverShare else { return nil }
        var switches = 0
        var last: String?
        for t in turns.sorted(by: { $0.start < $1.start }) where t.speaker == a.key || t.speaker == b.key {
            if let last, last != t.speaker { switches += 1 }
            last = t.speaker
        }
        return switches >= minSwitches ? (a.key, b.key) : nil
    }

    /// 自分の声が固まっていて、この区切りの自分がはっきり（strict 以内で）当たったか
    static func selfSolid(pinned: Int, voices: Int, distance: Float?, strict: Float) -> Bool {
        guard pinned >= selfPinnedSolid || voices >= selfVoicesSolid else { return false }
        guard let distance else { return false }
        return distance <= strict
    }

    /// 前の区切りから続く相手（同じ機器で、終わりから maxGap 以内に始まった区切りだけ）
    static func carried(_ state: State?, start: Date?, watch: Bool?) -> String? {
        guard let state, let start, state.watch == watch else { return nil }
        let gap = start.timeIntervalSince(state.end)
        return gap >= -30 && gap <= maxGap ? state.partner : nil
    }

    /// 相手のまとまりを前の区切りの相手にするか。名前のある別の人に当たっているときは変えない
    static func shouldAssign(distance: Float, accept: Float, currentNamed: Bool) -> Bool {
        !currentNamed && distance <= accept + slack
    }
}

// MARK: - 声13 声以外の手がかりの強い加点

enum S29RBonus {
    /// はっきりした手がかりの相手への加点（今の 0.03 の代わり。仮）
    static let strong: Float = 0.08

    struct Pair: Sendable, Equatable {
        var cluster: String
        var person: String
        var distance: Float
        var rank: Float
    }

    /// 今の加点に足す分（strong の人だけ。expected に入っていれば今の base を引いた残り）
    static func extra(_ id: String, expected: Set<String>, strong: Set<String>, base: Float) -> Float {
        guard strong.contains(id) else { return 0 }
        return Self.strong - (expected.contains(id) ? base : 0)
    }

    /// SpeakerLabeler.label と同じ決め方（近い順。同じ人を 2 つ目に当てるのは strict 以内のときだけ）
    static func greedy(_ pairs: [Pair], strict: Float) -> [String: String] {
        var assigned: [String: String] = [:]
        var used: Set<String> = []
        for pair in pairs.sorted(by: { $0.rank < $1.rank }) where assigned[pair.cluster] == nil {
            if used.contains(pair.person) && pair.distance > strict { continue }
            assigned[pair.cluster] = pair.person
            used.insert(pair.person)
        }
        return assigned
    }

    /// 2 つの決め方で、当てた人が違うまとまりの数
    static func differences(_ a: [String: String], _ b: [String: String]) -> Int {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.count
    }
}

// MARK: - 手がかりのまとめ（声7・声13）

enum S29RClues {
    /// はっきりした手がかりの相手: 会議モードの参加者・「今から A さんと」・予定の相手が 1 人だけのときのその人
    static func strong(meeting: Set<String>, withNow: Set<String>, singleEventIDs: Set<String>) -> Set<String> {
        var out = meeting.union(withNow)
        if singleEventIDs.count == 1 { out.formUnion(singleEventIDs) }
        return out
    }

    /// 場の人数（自分を含む）。会議モード → 「今から A さんと」→ 重なる予定が 1 つだけのとき、の順
    static func headcount(meetingAttendees: Int, withNow: Int, eventAttendees: [Int]) -> Int? {
        if meetingAttendees > 0 { return meetingAttendees + 1 }
        if withNow > 0 { return withNow + 1 }
        if eventAttendees.count == 1, let n = eventAttendees.first, n > 0 { return n + 1 }
        return nil
    }
}

// MARK: - 声23 「今から A さんと」（名前付け担当が書き、こちらは読むだけ）

struct S29RWithNow: Codable, Equatable, Sendable {
    var ids: [String]
    /// epoch 秒
    var start: Double
    var end: Double

    static let key = "s29.withNow"

    static func parse(_ data: Data) -> S29RWithNow? {
        guard let v = try? JSONDecoder().decode(S29RWithNow.self, from: data), v.end >= v.start else { return nil }
        return v
    }

    static func read(_ defaults: UserDefaults = .standard) -> S29RWithNow? {
        let raw = defaults.object(forKey: key)
        if let data = raw as? Data { return parse(data) }
        if let text = raw as? String, let data = text.data(using: .utf8) { return parse(data) }
        return nil
    }

    func covers(from: Date, to: Date) -> Bool {
        from.timeIntervalSince1970 <= end && to.timeIntervalSince1970 >= start
    }

    /// その時間に重なっていれば、押した人の番号
    static func ids(from: Date, to: Date, defaults: UserDefaults = .standard) -> Set<String> {
        guard let v = read(defaults), v.covers(from: from, to: to) else { return [] }
        return Set(v.ids.filter { !$0.isEmpty && $0 != SpeakerLabeler.selfID })
    }
}

// MARK: - 数えた結果（診断の「効き目」に出す。新しい知らせは作らない）

enum S29RReport {
    static func rows(_ s: [String: Int]) -> [(label: String, value: String, ok: Bool?)] {
        func n(_ k: String) -> Int { s[k] ?? 0 }
        var rows: [(label: String, value: String, ok: Bool?)] = []
        if n("s29r.gate.cut") + n("s29r.gate.would") > 0 {
            rows.append((label: "声4 雑音の中の短い声", value: "人物Nにしなかった \(n("s29r.gate.cut"))・（オフのとき）しなかったはず \(n("s29r.gate.would"))", ok: nil))
        }
        if n("s29r.box.in") + n("s29r.box.promoted") + n("s29r.box.would") > 0 {
            rows.append((label: "声8 通りすがりの箱", value: "箱に入れた \(n("s29r.box.in"))・また聞こえて人物Nにした \(n("s29r.box.promoted"))・（オフのとき）入れたはず \(n("s29r.box.would"))", ok: nil))
        }
        if n("s29r.headcount.would") + n("s29r.headcount.merged") > 0 {
            rows.append((label: "声7 場の人数でまとめ直し", value: "まとめた \(n("s29r.headcount.merged"))・（影）まとめたはず \(n("s29r.headcount.would"))", ok: nil))
        }
        if n("s29r.scene.same") + n("s29r.scene.differ") > 0 {
            rows.append((label: "声10 場面別の見本（影）", value: "同じ人 \(n("s29r.scene.same"))・違う人になる \(n("s29r.scene.differ"))", ok: nil))
        }
        if n("s29r.trim.differ") > 0 {
            rows.append((label: "声11 見本の消す順（影）", value: "良い順なら残ったはずの見本 \(n("s29r.trim.differ"))", ok: nil))
        }
        if n("s29r.chain.agree") + n("s29r.chain.would") + n("s29r.chain.applied") > 0 {
            rows.append((label: "声12 交互の相手の鎖", value: "前と同じ相手だった \(n("s29r.chain.agree"))・続けた \(n("s29r.chain.applied"))・（影）続けたはず \(n("s29r.chain.would"))", ok: nil))
        }
        if n("s29r.strong.would") + n("s29r.strong.changed") > 0 {
            rows.append((label: "声13 手がかりの強い加点", value: "当てた人が変わった \(n("s29r.strong.changed"))・（影）変わるはず \(n("s29r.strong.would"))", ok: nil))
        }
        return rows
    }
}

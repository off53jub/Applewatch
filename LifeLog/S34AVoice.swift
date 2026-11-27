import Foundation
import Observation
import UIKit

// s34（2026-11-28 追加）自6・自7: 家の PC が確かな場面から集めた声の見本を、端末の声の登録に足す（アプリ担当 S34A）。
// 家の PC の形（D:\aw-s34p の pc/s34pvoice.py・pc/voicesamples.py・pc/selfvoice.py に合わせた）:
// - GET /voice-samples（features "voicesamples"）→ {"available", "people":[{"speaker", "speakerID", "samples":[{"day", "line_time",
//   "conversation_start", "audio", "offset", "length", "path", "why", "scene"?, "auto"}], "tier", "auto", ...}]}。
//   s34 の分は人ごとに "auto": true（自分は speakerID "me"・見本ごとに scene = home/work/out）。
// - GET /self-voice（features "selfvoice"）→ 省ける "s34_auto": {"scenes":{home,work,out}, "record_needed"}
// - 音声は GET /audio-clip?audio=…&offset=…&length=…（16kHz・モノラルの WAV）
// 決まり:
// - 足すのは "auto": true の人の見本だけ（s18 の本人の ○ からの候補は、この版では足さない）。
// - 足す先は、端末にもういる人だけ: 自分（me。いなければ作る）と、名前のある人（隠していない・PC の名前と端末の名前が同じ）。
//   人を作らない・名前を付けない／変えない・まとめない。
// - 声は「自動で覚えた声」（pinned でない）として足す。本人が録った声・手直しの声（pinned）は変えない。
//   今の声がある人は、その声から遠い見本（ふつうの受け入れの近さより遠い）は足さない。
// - 上限: 自分 15 個・ほかの人 1 人 5 個・1 回 10 個・覚える印 400 個（どれも仮）。
// - 元に戻せる: 足した声の覚えた時刻の鍵を控え（s34a.voice.marks）、設定の「外す」で s34 の分だけを外す。外した見本は二度と足さない。
// - 動くのは、話し手の聞き分けがオンで（モデルを新しく落とさない）、アプリが前にあるか充電中のとき、6 時間に 1 回（仮）。
// - record_needed が false で、自分の自動の見本が端末に 3 個以上あれば、「自分の声を録る」の札（S29N 声14）を出さない。
// 知らせ・問いは足さない。中身（声・名前）は記録（ログ）に書かない（Tally は数だけ）。

// MARK: - 決まり

struct S34AVoiceSample: Decodable, Equatable, Sendable {
    var audio: String
    var offset: Double
    var length: Double
    var day: String?
    var scene: String?

    enum CodingKeys: String, CodingKey { case audio, offset, length, day, scene }

    init(audio: String, offset: Double, length: Double, day: String? = nil, scene: String? = nil) {
        self.audio = audio
        self.offset = offset
        self.length = length
        self.day = day
        self.scene = scene
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audio = try c.decode(String.self, forKey: .audio)
        guard let o = c.s33aNum(.offset), let l = c.s33aNum(.length) else {
            throw DecodingError.dataCorruptedError(forKey: .offset, in: c, debugDescription: "offset・length が無い")
        }
        offset = o
        length = l
        day = c.s33a(.day)
        scene = c.s33a(.scene)
    }

    /// 同じ見本かを見分ける鍵（音声の名前・始まり・長さ）
    var key: String { audio + "|" + String(format: "%.2f", offset) + "|" + String(format: "%.2f", length) }
}

struct S34AVoicePerson: Decodable, Equatable, Sendable {
    var speaker: String?
    var speakerID: String
    var samples: [S34AVoiceSample]
    var auto: Bool

    enum CodingKeys: String, CodingKey { case speaker, speakerID, samples, auto }

    init(speaker: String?, speakerID: String, samples: [S34AVoiceSample], auto: Bool) {
        self.speaker = speaker
        self.speakerID = speakerID
        self.samples = samples
        self.auto = auto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speaker = c.s33a(.speaker)
        speakerID = try c.decode(String.self, forKey: .speakerID)
        samples = c.s33aList(.samples)
        let a: Bool? = c.s33a(.auto)
        auto = a ?? false
    }
}

/// 足した見本の控え（元に戻すため）
struct S34AVoiceMark: Codable, Equatable, Sendable {
    /// 見本の鍵（S34AVoiceSample.key）
    var key: String
    /// 足した人の id（me・数字）
    var person: String
    /// 足した声の覚えた時刻の鍵（S29RVoiceInfo.key）
    var voice: String
    var scene: String?
}

/// 端末の人（決まりに渡す分だけ）
struct S34AVoiceLocal: Equatable, Sendable {
    var id: String
    var name: String?
    var isSelf: Bool
    var hidden: Bool
}

/// 足す 1 件
struct S34AVoicePlanItem: Equatable, Sendable {
    var person: String
    var sample: S34AVoiceSample
}

enum S34AVoiceRules {
    static let feature = "voicesamples"
    static let selfFeature = "selfvoice"
    static let selfID = "me"
    /// 上限（仮）
    static let selfMax = 15
    static let perPerson = 5
    static let perRun = 10
    static let marksMax = 400
    /// 見本の長さ（秒。家の PC と同じ 2〜10 秒）
    static let minLength = 2.0
    static let maxLength = 10.0
    /// 見る間（仮 6 時間）
    static let every: TimeInterval = 6 * 3600
    /// 「自分の声を録る」の札を出さなくする、端末にある自分の自動の見本の数（仮 3）
    static let selfEnough = 3

    /// GET /voice-samples の答えから、s34 の自動の人だけ（{"available":false}・読めないときは空）
    static func people(_ data: Data) -> [S34AVoicePerson] {
        struct Body: Decodable {
            var available: Bool?
            var people: [LossyRow<S34AVoicePerson>]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), body.available != false else { return [] }
        return (body.people ?? []).compactMap(\.value).filter { $0.auto && !$0.speakerID.isEmpty }
    }

    /// GET /self-voice の答えの s34_auto.record_needed（無ければ nil）
    static func recordNeeded(_ data: Data) -> Bool? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auto = o["s34_auto"] as? [String: Any] else { return nil }
        return auto["record_needed"] as? Bool
    }

    /// 音声の名前（家の PC の safe_audio_name と同じく、英数字と . _ - だけ・128 字まで）
    static func isAudioName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 128, !s.hasPrefix(".") else { return false }
        return s.unicodeScalars.allSatisfy { u in
            (u.value >= 0x30 && u.value <= 0x39) || (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A)
                || "._-".unicodeScalars.contains(u)
        }
    }

    static func nameKey(_ s: String?) -> String {
        (s ?? "").filter { !$0.isWhitespace }
    }

    /// 足すものを決める。marks＝もう足した見本・dropped＝本人が外した見本（二度と足さない）
    static func plan(_ people: [S34AVoicePerson], local: [S34AVoiceLocal], marks: [S34AVoiceMark], dropped: Set<String>,
                     limit: Int = perRun) -> [S34AVoicePlanItem] {
        var have: [String: Int] = [:]
        var done = dropped
        for m in marks {
            have[m.person, default: 0] += 1
            done.insert(m.key)
        }
        var out: [S34AVoicePlanItem] = []
        for p in people {
            let id = p.speakerID
            let isSelf = id == selfID
            if !isSelf {
                // 名前のある人だけ（隠していない・PC の名前と端末の名前が同じ）。人は作らない
                guard let me = local.first(where: { $0.id == id }), !me.isSelf, !me.hidden, let name = me.name,
                      !nameKey(name).isEmpty else { continue }
                if let pcName = p.speaker, !nameKey(pcName).isEmpty, nameKey(pcName) != nameKey(name) { continue }
            }
            let cap = isSelf ? selfMax : perPerson
            for s in p.samples {
                guard out.count < limit else { return out }
                guard have[id, default: 0] < cap else { break }
                guard isAudioName(s.audio), s.offset >= 0, s.length >= minLength, s.length <= maxLength,
                      !done.contains(s.key) else { continue }
                out.append(S34AVoicePlanItem(person: id, sample: s))
                done.insert(s.key)
                have[id, default: 0] += 1
            }
        }
        return out
    }

    /// 控えに足す（新しいほうから marksMax まで）
    static func added(_ marks: [S34AVoiceMark], _ new: [S34AVoiceMark], limit: Int = marksMax) -> [S34AVoiceMark] {
        Array((marks + new).suffix(limit))
    }

    /// 「自分の声を録る」の札を出さなくするか
    static func selfCardDone(recordNeeded: Bool?, autoSelf: Int) -> Bool {
        recordNeeded == false && autoSelf >= selfEnough
    }

    /// 設定に出す 1 行（数だけ）
    static func line(_ marks: [S34AVoiceMark]) -> String? {
        guard !marks.isEmpty else { return nil }
        let mine = marks.filter { $0.person == selfID }.count
        let others = Set(marks.filter { $0.person != selfID }.map(\.person)).count
        let otherCount = marks.count - mine
        return "自分 \(mine) 個・ほかの人 \(others) 人に \(otherCount) 個"
    }

    /// 外すときに、人ごとの声の鍵にまとめる
    static func byPerson(_ marks: [S34AVoiceMark]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for m in marks { out[m.person, default: []].insert(m.voice) }
        return out
    }
}

// MARK: - 動き

@MainActor
@Observable
final class S34AVoiceBook {
    static let shared = S34AVoiceBook()

    /// 設定「家の PC が集めた声の見本を足す」（初めはオン。外すとオフになる）
    static let onKey = "s34a.voice.on"
    private static let marksKey = "s34a.voice.marks"
    private static let droppedKey = "s34a.voice.dropped"
    private static let needKey = "s34a.voice.recordNeeded"
    private static let lastKey = "s34a.voice.last"

    private(set) var marks: [S34AVoiceMark]
    /// 家の PC の record_needed（まだ聞いていなければ nil）
    private(set) var recordNeeded: Bool?
    private(set) var running = false
    private(set) var lastAt: Date?

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.marksKey), let saved = try? JSONDecoder().decode([S34AVoiceMark].self, from: data) {
            marks = saved
        } else {
            marks = []
        }
        recordNeeded = d.object(forKey: Self.needKey) as? Bool
        lastAt = d.object(forKey: Self.lastKey) as? Date
    }

    static var isOn: Bool { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }

    var autoSelf: Int { marks.filter { $0.person == S34AVoiceRules.selfID }.count }

    /// 「自分の声を録る」の札を出さなくするか（S29NBook が読む）
    var selfCardDone: Bool { S34AVoiceRules.selfCardDone(recordNeeded: recordNeeded, autoSelf: autoSelf) }

    /// 1 分ごと（S34ABook.tick から）。6 時間に 1 回
    func tick(now: Date = .now) {
        guard !running, Self.isOn, let pipeline = S34ABook.pipeline else { return }
        if let lastAt, now.timeIntervalSince(lastAt) < S34AVoiceRules.every { return }
        let pc = pipeline.homePC
        guard pc.isConfigured, pc.features.contains(S34AVoiceRules.feature) || pc.features.contains(S34AVoiceRules.selfFeature) else { return }
        let active = UIApplication.shared.applicationState == .active
        guard active || S26ASettings.charging else { return }
        lastAt = now
        UserDefaults.standard.set(now, forKey: Self.lastKey)
        Task { await run(pipeline) }
    }

    func run(_ pipeline: Pipeline) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let pc = pipeline.homePC
        if pc.features.contains(S34AVoiceRules.selfFeature),
           let data = try? await pc.getJSONData("self-voice", timeout: 15) {
            let need = S34AVoiceRules.recordNeeded(data)
            recordNeeded = need
            if let need {
                UserDefaults.standard.set(need, forKey: Self.needKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.needKey)
            }
        }
        // 声の聞き分けがオフなら足さない（声のモデルを新しく落とさない）
        guard Self.isOn, pipeline.speakerLabelsOn, pc.features.contains(S34AVoiceRules.feature),
              let data = try? await pc.getJSONData("voice-samples", timeout: 15) else { return }
        let people = S34AVoiceRules.people(data)
        guard !people.isEmpty else { return }
        await pipeline.reloadPeople()
        let local: [S34AVoiceLocal] = pipeline.people.map {
            S34AVoiceLocal(id: $0.id, name: $0.name, isSelf: $0.isSelf, hidden: $0.hidden == true)
        }
        let dropped = Set(UserDefaults.standard.stringArray(forKey: Self.droppedKey) ?? [])
        let plan = S34AVoiceRules.plan(people, local: local, marks: marks, dropped: dropped)
        guard !plan.isEmpty else { return }

        var fresh: [S34AVoiceMark] = []
        let limit = SpeakerLabeler.Strictness.normal.accept
        for item in plan {
            if Task.isCancelled || !Self.isOn { break }
            guard let embedding = await embed(item.sample, pc: pc, pipeline: pipeline) else {
                Tally.add("s34a.voice.clipFail")
                continue
            }
            let dates = await pipeline.speakers.s34aAddAuto([embedding], to: item.person, limit: limit)
            if let added = dates.first ?? nil {
                fresh.append(S34AVoiceMark(key: item.sample.key, person: item.person, voice: S29RVoiceInfo.key(added),
                                           scene: item.sample.scene))
            } else {
                Tally.add("s34a.voice.far")
            }
        }
        guard !fresh.isEmpty else { return }
        marks = S34AVoiceRules.added(marks, fresh)
        saveMarks()
        await pipeline.reloadPeople()
        Tally.add("s34a.voice.added", fresh.count)
    }

    /// 家の PC から短い音声を受け取り、声の特徴を取る（音声は端末の一時の置き場にだけ置き、すぐ消す）
    private func embed(_ s: S34AVoiceSample, pc: HomePC, pipeline: Pipeline) async -> [Float]? {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "audio", value: s.audio),
            URLQueryItem(name: "offset", value: String(format: "%.2f", s.offset)),
            URLQueryItem(name: "length", value: String(format: "%.2f", s.length)),
        ]
        guard let data = try? await pc.getJSONData("audio-clip", query: query, timeout: 20), data.count > 44,
              data.prefix(4) == Data("RIFF".utf8) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s34a-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        let got = try? await pipeline.speakers.embeddings(url, clips: [(start: 0, end: s.length)])
        return (got?.first ?? nil)
    }

    /// s34 で足した見本を全部外す（登録・手直しの声は外さない）。外した見本は二度と足さず、スイッチもオフにする。外した数
    @discardableResult
    func removeAll() async -> Int {
        guard let pipeline = S34ABook.pipeline, !marks.isEmpty else { return 0 }
        var removed = 0
        for (person, keys) in S34AVoiceRules.byPerson(marks) {
            removed += await pipeline.speakers.s34aRemoveAuto(keys, from: person)
        }
        var dropped = UserDefaults.standard.stringArray(forKey: Self.droppedKey) ?? []
        dropped = Array((dropped + marks.map(\.key)).suffix(1000))
        UserDefaults.standard.set(dropped, forKey: Self.droppedKey)
        UserDefaults.standard.set(false, forKey: Self.onKey)
        marks = []
        saveMarks()
        await pipeline.reloadPeople()
        Tally.add("s34a.voice.removed", removed)
        return removed
    }

    private func saveMarks() {
        if let data = try? JSONEncoder().encode(marks) { UserDefaults.standard.set(data, forKey: Self.marksKey) }
    }
}

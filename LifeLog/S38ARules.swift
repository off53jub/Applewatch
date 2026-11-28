import Foundation

// s38（2026-11-28）アプリ担当 S38A（A1）の決まり。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 30」（続1〜続4）。
// 取り決め K38-1（読む側。GET /s36 の state/s36_for_app.json に足した鍵。どれも省ける・無ければ今のまま）:
// - `names`: [{"speaker_id","name","how","sources"}] … 人物N に「仮: 名前」と薄く添える（続1）。名前は変えない・本人の答え（名前を付けた人）が勝つ
// - `passerby`: ["人物N の番号", …] … 人の一覧で「通りすがり（N 人）」の畳んだ箱へ（続2）。消さない・名前を付けた人は入れない
// - `voice_memos`: [{"id","text","day","project"}] … タスク画面の下に「声のメモ（N 件）」の畳んだ箱（続3）。読むだけ・タスクにしない
// - `later_done_at`: 後ろの段（Run-WorkNow --later）が最後に終わった時刻 ISO … 共有して「済んだ」を出したあと、これが共有の時刻より
//   新しくなるまで 1 分ごとに /s36 と仕事の画面を取り直す（続4・20 分まで。動きは S38ABook.swift）
// 画面は S38AViews.swift。知らせ・問いは足さない。中身の文は記録（ログ）に書かない（Tally は数と種類の名前だけ）。しきい値はどれも仮。

// MARK: - K38-1 読む形

/// 番号（文字でも数でも読む。"人物12" の形でも番号だけにする）
struct S38ALooseID: Decodable, Equatable, Sendable {
    var value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = s
        } else if let n = try? c.decode(Int.self) {
            value = String(n)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "番号ではない")
        }
    }
}

/// 人物N の仮の名前 1 つ（続1）
struct S38AName: Decodable, Equatable, Sendable {
    var speakerID: String
    var name: String
    var how: String?
    var sources: [String]

    enum CodingKeys: String, CodingKey {
        case name, how, sources
        case speakerID = "speaker_id"
    }

    init(speakerID: String, name: String, how: String? = "presence", sources: [String] = []) {
        self.speakerID = speakerID
        self.name = name
        self.how = how
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id: S38ALooseID = try c.decode(S38ALooseID.self, forKey: .speakerID)
        speakerID = S38ARules.number(id.value) ?? ""
        name = ((c.s27w(.name) as String?) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        how = c.s27w(.how)
        sources = c.s27wList(.sources)
        guard !speakerID.isEmpty, !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "番号か名前が無い")
        }
    }
}

/// 声のメモ 1 つ（続3）
struct S38AVoiceMemo: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var day: String?
    var project: String?

    enum CodingKeys: String, CodingKey { case id, text, day, project }

    init(id: String, text: String, day: String? = nil, project: String? = nil) {
        self.id = id
        self.text = text
        self.day = day
        self.project = project
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw: S38ALooseID = try c.decode(S38ALooseID.self, forKey: .id)
        id = raw.value
        text = ((c.s27w(.text) as String?) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        day = c.s27w(.day)
        project = c.s27w(.project)
        guard !id.isEmpty, !text.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "id か文が無い")
        }
    }
}

enum S38ARules {
    /// "12"・"人物12"・" 12 " を "12" に（数字だけのときだけ。ほかは nil）
    nonisolated static func number(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if t.hasPrefix("人物") { t = String(t.dropFirst(2)) }
        guard !t.isEmpty, t.count <= 12, t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return t
    }

    /// passerby の並び（番号だけ・重ねない・届いた順）
    nonisolated static func passerbyIDs(_ rows: [S38ALooseID]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for row in rows {
            guard let n = number(row.value), seen.insert(n).inserted else { continue }
            out.append(n)
        }
        return out
    }
}

// MARK: - 続1 仮の名前

enum S38ANames {
    /// 添える名前の長さ（仮 20 字。長いものは切る）
    static let nameLimit = 20

    /// 会話の行の番号: 見えている名前が「人物N」のときだけ（名前が出ている行には添えない＝本人の答えが勝つ）
    static func number(speaker: String?, speakerID: String?) -> String? {
        guard let speaker, speaker.hasPrefix("人物") else { return nil }
        return S38ARules.number(speaker) ?? S38ARules.number(speakerID)
    }

    /// 番号の仮の名前（名前を付けた人・自分・届いていないときは nil）
    static func hint(number: String?, names: [S38AName]?, isNamed: Bool) -> String? {
        guard !isNamed, let number, let names else { return nil }
        guard let hit = names.first(where: { $0.speakerID == number }) else { return nil }
        let name: String = hit.name.count > nameLimit ? String(hit.name.prefix(nameLimit)) + "…" : hit.name
        return name.isEmpty ? nil : "仮: " + name
    }

    /// 会話の行の 1 語（行の名前が「人物N」で、その番号の人がまだ名前の無い声のとき）
    static func lineHint(speaker: String?, speakerID: String?, names: [S38AName]?, named: (String) -> Bool) -> String? {
        guard let n = number(speaker: speaker, speakerID: speakerID) else { return nil }
        return hint(number: n, names: names, isNamed: named(n))
    }
}

// MARK: - 続2 通りすがり

enum S38APasserby {
    /// 通りすがりの箱に入れるか（名前の無い声で、passerby に番号があるもの）
    static func boxed(id: String, isNamed: Bool, isSelf: Bool, passerby: Set<String>) -> Bool {
        !isNamed && !isSelf && passerby.contains(id)
    }

    static func title(_ n: Int) -> String { "通りすがり（\(n) 人）" }
}

// MARK: - 続3 声のメモ

enum S38AMemos {
    /// 見せる数（仮 30 件・母艦と同じ）と文の長さ（60 字・母艦と同じ）
    static let limit = 30
    static let textLimit = 60

    /// 見せるメモ（同じ id は 1 つ・文は 60 字まで・30 件まで・届いた順）
    static func shown(_ memos: [S38AVoiceMemo]?) -> [S38AVoiceMemo] {
        guard let memos else { return [] }
        var seen: Set<String> = []
        var out: [S38AVoiceMemo] = []
        for var m in memos where seen.insert(m.id).inserted {
            if m.text.count > textLimit { m.text = String(m.text.prefix(textLimit)) + "…" }
            out.append(m)
            if out.count >= limit { break }
        }
        return out
    }

    static func title(_ n: Int) -> String { "声のメモ（\(n) 件）" }

    /// メモの下の小さな 1 行（「11/28・見本の案件 A」。どちらも無ければ nil）
    static func caption(_ m: S38AVoiceMemo) -> String? {
        var parts: [String] = []
        if let d = m.day, HomeFeeds.isDay(d) { parts.append(AppFeeds.monthDay(d)) }
        if let p = m.project?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

// MARK: - 続4 後ろの段を待つ

enum S38ALater {
    /// 取り直す間（仮 1 分）と、待つ長さ（仮 20 分）
    static let every: TimeInterval = 60
    static let limit: TimeInterval = 20 * 60

    enum Step: Equatable, Sendable {
        /// まだ（1 分あけてもう一度）
        case wait
        /// 後ろの段が共有のあとに終わった
        case caughtUp
        /// 欄が無くなった（今の動きに戻す）
        case noField
        /// 20 分たった
        case timeUp
    }

    /// 待ち始めるか（家の PC が /s36 を配っていて、写しに later_done_at の欄があるとき。無ければ今の動きのまま）
    static func follows(_ feed: S36AFeed?, offered: Bool) -> Bool {
        offered && feed?.laterDoneAt != nil
    }

    /// 後ろの段が、共有の時刻より新しく終わったか（読めない時刻は「まだ」）
    static func caughtUp(_ laterDoneAt: String?, sharedAt: Date) -> Bool {
        guard let laterDoneAt, let done = S31ARules.date(laterDoneAt) else { return false }
        return done > sharedAt
    }

    /// 取り直したあとの次の一手
    static func step(_ feed: S36AFeed?, sharedAt: Date, startedAt: Date, now: Date) -> Step {
        guard let at = feed?.laterDoneAt else { return .noField }
        if caughtUp(at, sharedAt: sharedAt) { return .caughtUp }
        return now.timeIntervalSince(startedAt) >= limit ? .timeUp : .wait
    }
}

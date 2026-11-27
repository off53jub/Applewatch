import Foundation

// s29（2026-11-27）名前付けを軽くする（アプリの名前付け担当 S29N）の決まり（決まった入力から決まった出力だけ）。
// 画面は S29NViews.swift、動きは S29NBook.swift。案は母艦の docs/system-proposal-2026-11-13.md の「追記 19」
// （声8・声14・声18〜声24）。しきい値はどれも仮。テストは LifeLogTests/S29NTests.swift。説明は docs/s29-n.md。
// 新しい問い・知らせは足していない（名前付けは今ある 1 日 3 問の枠の中。S24Gate で数える）。

// MARK: - 設定の名前（UserDefaults）

enum S29NSettings {
    /// 声24 名前付けの入口を 1 つの山にする（初めはオン。切ると s28 までの並び）
    static let pileKey = "s29n.pile"
    /// 声18 聞く人のしぼり（7 日のうちの日数・合計の秒。どちらも仮）
    static let minDaysKey = "s29n.minDays"
    static let minSecondsKey = "s29n.minSeconds"
    static let minDaysDefault = 2
    static let minSecondsDefault = 180
    /// 声24 1 日に出す数（仮 3。1〜3。全体の 1 日 3 問の枠も同時に守る）
    static let dailyKey = "s29n.daily"
    static let dailyDefault = 3
    /// 声23 「今から ◯◯さんと」の長さ（時間。仮 2）
    static let withNowHoursKey = "s29n.withNowHours"
    static let withNowHoursDefault = 2
    /// 母艦の「この人物N はだれ」の答えを、端末の人の名前付け・まとめに届ける（初めはオン。本人の答えのときだけ動く）
    static let reviewLinkKey = "s29n.reviewLink"
    /// 数える日数（7 日）
    static let windowDays = 7
    /// 声14 自分の声の見本（登録・手直しで覚えた今のモデルの声）がこれより少なければ「自分の声を録る」を出す（仮 3）
    static let selfVoiceWanted = 3

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static var minDays: Int { clampDays(UserDefaults.standard.object(forKey: minDaysKey) as? Int ?? minDaysDefault) }
    static var minSeconds: Int { clampSeconds(UserDefaults.standard.object(forKey: minSecondsKey) as? Int ?? minSecondsDefault) }
    static var daily: Int { clampDaily(UserDefaults.standard.object(forKey: dailyKey) as? Int ?? dailyDefault) }
    static var withNowHours: Int {
        max(1, min(6, UserDefaults.standard.object(forKey: withNowHoursKey) as? Int ?? withNowHoursDefault))
    }

    static func clampDays(_ n: Int) -> Int { max(1, min(windowDays, n)) }
    static func clampSeconds(_ n: Int) -> Int { max(30, min(1800, n)) }
    static func clampDaily(_ n: Int) -> Int { max(1, min(3, n)) }
}

// MARK: - 7 日の数（声18・声24）

/// 鳴らせる発言 1 つ
struct S29NQuote: Codable, Equatable, Sendable {
    var time: Date
    var text: String
    var audio: String?
    var offset: Double?
    var end: Double?

    var playable: Bool { audio != nil && offset != nil }
}

/// 1 人の 7 日の数
struct S29NStat: Codable, Equatable, Sendable {
    var lines = 0
    var days: Set<String> = []
    var seconds: Double = 0
    var quotes: [S29NQuote] = []
}

/// 1 つの会話（数えるための入れ物）
struct S29NTalk {
    var day: String
    var media: Bool
    var lines: [ConversationLog.Line]
}

enum S29NRules {
    /// 発言として見せる最短の文字数・最長
    static let quoteMin = 4
    static let quoteMax = 60
    static let quoteLimit = 3

    /// 1 行の長さ（秒）。行の終わりが分かればそこまで（30 秒まで）、無ければ文字数から見積もる（15 秒まで）
    static func seconds(_ line: ConversationLog.Line) -> Double {
        if let offset = line.offset, let end = line.end, end > offset { return min(30, end - offset) }
        return min(15, Double(line.text.count) * 0.18 + 0.8)
    }

    /// 発言の並べ方: 鳴らせるもの → 長いもの → 新しいもの
    static func better(_ a: S29NQuote, _ b: S29NQuote) -> Bool {
        if a.playable != b.playable { return a.playable }
        if a.text.count != b.text.count { return a.text.count > b.text.count }
        return a.time > b.time
    }

    static func quote(_ line: ConversationLog.Line) -> S29NQuote? {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= quoteMin else { return nil }
        let cut = text.count > quoteMax ? String(text.prefix(quoteMax)) + "…" : text
        return S29NQuote(time: line.time, text: cut, audio: line.audio, offset: line.offset, end: line.end)
    }

    /// 会話から、声の番号ごとの数（行・日・秒・発言 3 つ）と、同じ区切り（音声）に一緒に出た組（同じ人ではない）を数える。
    /// 放送の会話・放送の行・自分・番号の無い行は数えない
    static func tally(_ talks: [S29NTalk]) -> (stats: [String: S29NStat], apart: Set<[String]>) {
        var stats: [String: S29NStat] = [:]
        var byAudio: [String: Set<String>] = [:]
        for talk in talks where !talk.media {
            for line in talk.lines where line.media == nil {
                guard let id = line.speakerID, id != SpeakerLabeler.selfID else { continue }
                var s = stats[id] ?? S29NStat()
                s.lines += 1
                s.days.insert(talk.day)
                s.seconds += seconds(line)
                if let q = quote(line) {
                    s.quotes.append(q)
                    s.quotes.sort(by: better)
                    if s.quotes.count > quoteLimit { s.quotes.removeLast() }
                }
                stats[id] = s
                if let audio = line.audio { byAudio[audio, default: []].insert(id) }
            }
        }
        var apart = Set<[String]>()
        for ids in byAudio.values where ids.count >= 2 {
            let sorted = ids.sorted()
            for i in sorted.indices {
                for j in sorted.indices where j > i { apart.insert([sorted[i], sorted[j]]) }
            }
        }
        return (stats, apart)
    }

    // MARK: 名前の比べ方（敬称と空白を除く。2 文字以上なら頭が同じでもよい）

    static let honorifics = ["さん", "くん", "君", "ちゃん", "さま", "様", "氏", "先生"]

    static func nameKey(_ s: String) -> String {
        var key = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
        for h in honorifics where key.hasSuffix(h) && key.count > h.count {
            key = String(key.dropLast(h.count))
            break
        }
        return key
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = nameKey(a), y = nameKey(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard min(x.count, y.count) >= 2 else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// 「人物12」→ "12"
    static func unnamedID(_ label: String) -> String? {
        let t = label.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("人物") else { return nil }
        let digits = String(t.dropFirst(2))
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return digits
    }

    /// 名前のある人（自分を含む・記録に出さない人と「もう聞かない」人は除く）のうち、その名前の人
    static func namedPerson(_ name: String, in people: [SpeakerLabeler.Person]) -> String? {
        let key = nameKey(name)
        if key == SpeakerLabeler.selfName { return SpeakerLabeler.selfID }
        var exact: String?
        var loose: String?
        for p in people where p.isNamed && p.hidden != true && p.quiet != true {
            if nameKey(p.displayName) == key { exact = exact ?? p.id }
            if sameName(p.displayName, name) { loose = loose ?? p.id }
        }
        return exact ?? loose
    }
}

// MARK: - 声19 割れた同じ人のまとまり

struct S29NGroup: Codable, Equatable, Sendable {
    var id: String
    /// 記録の話し手ラベル（「人物12」・名前のある人は名前）
    var labels: [String]
    var score: Double
    var seconds: Double?
    var days: Int?
    /// 家の PC から（false は端末の中の声の近さでまとめたもの）
    var fromPC: Bool = true
}

enum S29NGroups {
    private struct RawGroup: Decodable {
        var id: String?
        var labels: [String]?
        var score: Double?
        var seconds: Double?
        var days: Int?
    }

    private struct RawFeed: Decodable {
        var s29_groups: [LossyRow<RawGroup>]?
    }

    static let limit = 60

    private struct RawAvailable: Decodable {
        var available: Bool?
    }

    /// {"available": true} の答えか（false・読めないときは前のまとまりのままにする）
    static func isAvailable(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(RawAvailable.self, from: data))?.available == true
    }

    /// GET /same-person の s29_groups。欄が無ければ nil（端末の中でまとめる）。あれば読めた分（0 個もある）
    static func decode(_ data: Data) -> [S29NGroup]? {
        guard let raw = try? JSONDecoder().decode(RawFeed.self, from: data), let rows = raw.s29_groups else { return nil }
        var out: [S29NGroup] = []
        var seen = Set<String>()
        for row in rows {
            guard let g = row.value, let id = HomeFeeds.trimmed(g.id), HomeFeeds.isID(id), seen.insert(id).inserted else { continue }
            var labels: [String] = []
            for l in g.labels ?? [] {
                guard let t = HomeFeeds.trimmed(l), t.count <= 40, !labels.contains(t) else { continue }
                labels.append(t)
            }
            guard labels.count >= 2, labels.count <= 12 else { continue }
            var score: Double = 0
            if let s = g.score, s.isFinite { score = s }
            var seconds: Double?
            if let s = g.seconds, s.isFinite, s >= 0 { seconds = s }
            var days: Int?
            if let d = g.days, d >= 0 { days = d }
            out.append(S29NGroup(id: id, labels: labels, score: score, seconds: seconds, days: days, fromPC: true))
            if out.count >= limit { break }
        }
        return out
    }

    /// 端末の中の声の近さでまとめる（夜の整理と同じ SpeakerLabeler.tidyPlan のまとめ方。決めるだけで、まとめない）。
    /// candidates は聞いてよい名前の無い人。apart は同じ区切りに一緒に出た組。limit は近さ（コサイン距離・仮）
    static func local(_ candidates: [SpeakerLabeler.Person], apart: Set<[String]>, limit: Float) -> [S29NGroup] {
        var lines: [String: Int] = [:]
        for p in candidates { lines[p.id] = 999 }  // 夜の整理の「忘れる」は使わない
        let plan = SpeakerLabeler.tidyPlan(candidates, lines: lines, apart: apart, keep: [], limit: limit, now: .now,
                                           maxMerges: 60, maxForget: 0)
        var members: [String: [String]] = [:]
        var order: [String] = []
        for m in plan.merges {
            if members[m.target] == nil { order.append(m.target) }
            members[m.target, default: []].append(m.source)
        }
        var out: [S29NGroup] = []
        for target in order {
            let ids = [target] + (members[target] ?? [])
            out.append(S29NGroup(id: "local-" + target, labels: ids.map { "人物" + $0 }, score: 0, fromPC: false))
        }
        return out
    }
}

// MARK: - 声24 名前付けの山

enum S29NKind: String, Codable, Sendable {
    /// 名前の無い声 1 つ
    case person
    /// 同じ人らしい名前の無い声のまとまり（声19）
    case group
    /// 自分の声を録る（声14）
    case selfVoice
}

struct S29NCard: Codable, Equatable, Identifiable, Sendable {
    var kind: S29NKind
    /// "p:12"・"g:<まとまりの id>"・"self"
    var id: String
    /// 名前の無い人の番号（行の多い順）
    var members: [String] = []
    /// まとまりの id（家の PC の s29_groups の id か "local-…"）
    var groupID: String? = nil
    var groupFromPC: Bool = false
    /// まとまりに入っていた、名前のある人の番号（「たぶん ◯◯さん」の手がかり）
    var hinted: [String] = []
    var lines = 0
    var days = 0
    var seconds: Double = 0
    var quotes: [S29NQuote] = []

    /// 1 日 3 問の数えに使う印
    var askKey: String { "s29n:" + id }
}

enum S29NPile {
    struct Result: Equatable {
        /// 聞く順（効き目の大きい順。自分の声を録るは先頭）
        var cards: [S29NCard] = []
        /// 声18 しぼりに届いていない（聞かない）まとまりの数
        var below = 0
        /// 発言の無い（材料の無い）ので出さない数
        var noMaterial = 0
        /// 「もう聞かない」の人の数
        var quiet = 0
        /// 通りすがり・テレビ・大勢の場で外した数
        var skipped = 0
    }

    /// 聞いてよい名前の無い人か（名前・自分・記録に出さない・もう聞かない・テレビや大勢の場・通りすがり・7 日に声の無い人は聞かない）
    static func eligible(_ p: SpeakerLabeler.Person, stats: [String: S29NStat], skip: Set<String>, passerby: Set<String>) -> Bool {
        !p.isNamed && !p.isSelf && p.hidden != true && p.quiet != true && !skip.contains(p.id) && !passerby.contains(p.id)
            && stats[p.id] != nil
    }

    /// 声18 聞く人のしぼり（7 日で minDays 日以上・合計 minSeconds 秒以上。仮）
    static func reaches(days: Int, seconds: Double, minDays: Int, minSeconds: Int) -> Bool {
        days >= minDays && seconds >= Double(minSeconds)
    }

    /// 効き目の順（行の数 → 日数 → 秒。同じなら番号）
    static func moreImpact(_ a: S29NCard, _ b: S29NCard) -> Bool {
        if a.lines != b.lines { return a.lines > b.lines }
        if a.days != b.days { return a.days > b.days }
        if a.seconds != b.seconds { return a.seconds > b.seconds }
        return a.id < b.id
    }

    /// 山を作る。done は答えた・「あとで」の札の id（"p:12" など）
    static func build(people: [SpeakerLabeler.Person], stats: [String: S29NStat], groups: [S29NGroup],
                      skip: Set<String>, passerby: Set<String>, done: Set<String>,
                      minDays: Int, minSeconds: Int, selfVoices: Int, selfVoiceHidden: Bool) -> Result {
        var result = Result()
        for p in people where p.quiet == true && !p.isNamed { result.quiet += 1 }
        for p in people where !p.isNamed && !p.isSelf && p.hidden != true && p.quiet != true && stats[p.id] != nil
            && (skip.contains(p.id) || passerby.contains(p.id)) {
            result.skipped += 1
        }
        let ok = Set(people.filter { eligible($0, stats: stats, skip: skip, passerby: passerby) }.map(\.id))
        var used = Set<String>()
        var units: [S29NCard] = []

        // まとまり（点の高い順）。答えた（別の人がいた）まとまりは使わず、1 人ずつに戻す
        let sortedGroups = groups.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        for g in sortedGroups {
            var members: [String] = []
            var hinted: [String] = []
            for label in g.labels {
                if let n = S29NRules.unnamedID(label) {
                    if ok.contains(n), !used.contains(n), !members.contains(n) { members.append(n) }
                } else if let t = S29NRules.namedPerson(label, in: people), !hinted.contains(t) {
                    hinted.append(t)
                }
            }
            if members.count >= 2 {
                let cardID = "g:" + g.id
                if done.contains(cardID) { continue }
                var card = S29NCard(kind: .group, id: cardID, members: members, groupID: g.id, groupFromPC: g.fromPC, hinted: hinted)
                fill(&card, stats: stats)
                if let s = g.seconds { card.seconds = max(card.seconds, s) }
                if let d = g.days { card.days = max(card.days, min(d, S29NSettings.windowDays)) }
                for m in members { used.insert(m) }
                units.append(card)
            } else if members.count == 1, hinted.count == 1 {
                let cardID = "p:" + members[0]
                if done.contains(cardID) { continue }
                var card = S29NCard(kind: .person, id: cardID, members: members, groupID: g.id, groupFromPC: g.fromPC, hinted: hinted)
                fill(&card, stats: stats)
                used.insert(members[0])
                units.append(card)
            }
        }
        // 残りの 1 人ずつ
        for id in ok.sorted() where !used.contains(id) {
            let cardID = "p:" + id
            if done.contains(cardID) { continue }
            var card = S29NCard(kind: .person, id: cardID, members: [id])
            fill(&card, stats: stats)
            units.append(card)
        }
        var cards: [S29NCard] = []
        for u in units {
            guard reaches(days: u.days, seconds: u.seconds, minDays: minDays, minSeconds: minSeconds) else {
                result.below += 1
                continue
            }
            // 材料の無い問いは出さない（s26 の教え）
            guard !u.quotes.isEmpty else {
                result.noMaterial += 1
                continue
            }
            cards.append(u)
        }
        cards.sort(by: moreImpact)
        if selfVoices < S29NSettings.selfVoiceWanted, !selfVoiceHidden, !done.contains("self") {
            cards.insert(S29NCard(kind: .selfVoice, id: "self"), at: 0)
        }
        result.cards = cards
        return result
    }

    /// まとまり・1 人の数（行・日・秒・発言）を足す。番号は行の多い順に並べ直す
    static func fill(_ card: inout S29NCard, stats: [String: S29NStat]) {
        var days = Set<String>()
        var quotes: [S29NQuote] = []
        card.lines = 0
        card.seconds = 0
        for m in card.members {
            guard let s = stats[m] else { continue }
            card.lines += s.lines
            card.seconds += s.seconds
            days.formUnion(s.days)
            quotes += s.quotes
        }
        card.days = days.count
        quotes.sort(by: S29NRules.better)
        card.quotes = Array(quotes.prefix(S29NRules.quoteLimit))
        card.members.sort { (stats[$0]?.lines ?? 0) != (stats[$1]?.lines ?? 0)
            ? (stats[$0]?.lines ?? 0) > (stats[$1]?.lines ?? 0) : $0 < $1 }
    }

    /// 今日出す分（1 日 daily 件まで・今日もう答えた分は引く・全体の 1 日 3 問の残りも超えない）
    static func today(_ cards: [S29NCard], answeredToday: Int, daily: Int, gateLeft: Int) -> [S29NCard] {
        let n = max(0, min(daily - answeredToday, gateLeft, cards.count))
        return Array(cards.prefix(n))
    }

    /// 「直す」のタブに足す数（全体の 1 日 3 問の枠は fixBadge が守る）
    static func badge(_ cards: [S29NCard], answeredToday: Int, daily: Int) -> Int {
        max(0, min(daily - answeredToday, cards.count))
    }
}

// MARK: - 声20 3 つのボタン（「たぶん ◯◯さん」を 1 人選ぶ）

/// 名前の手がかり（Pipeline.voiceClues の候補を写したもの）
struct S29NClue: Equatable, Sendable {
    var name: String
    var target: String?
    var reasons: [String]
    var score: Int
}

enum S29NGuess {
    /// 「たぶん」と出す最低の点（仮 3: 呼ばれた・名乗った 1 回、声がよく似ている、予定 2 回 で届く。予定 1 回・声が少し似ているだけでは出さない）
    static let minScore = 3
    /// 家の PC のまとまりに名前のある人が入っていたときの点（仮）
    static let hintScore = 4

    /// 候補を 1 人に。同じ人（target か名前）の点は足す。まとまりの中の人・聞かない人（blocked）は選ばない。
    /// 点の高い順、同じなら今いる人（target あり）・理由の多いほう・名前の順
    static func pick(_ clues: [S29NClue], hinted: [(id: String, name: String)], members: Set<String>,
                     blocked: Set<String>, minScore: Int = S29NGuess.minScore) -> S29NClue? {
        var merged: [S29NClue] = []
        func add(_ c: S29NClue) {
            if let t = c.target, members.contains(t) || blocked.contains(t) { return }
            if let i = merged.firstIndex(where: { m in
                if let a = m.target, let b = c.target { return a == b }
                return S29NRules.sameName(m.name, c.name)
            }) {
                merged[i].score += c.score
                for r in c.reasons where !merged[i].reasons.contains(r) { merged[i].reasons.append(r) }
                if merged[i].target == nil, let t = c.target {
                    merged[i].target = t
                    merged[i].name = c.name
                }
            } else {
                merged.append(c)
            }
        }
        for c in clues { add(c) }
        for h in hinted { add(S29NClue(name: h.name, target: h.id, reasons: ["家の PC が同じ声のまとまりに入れていた"], score: hintScore)) }
        let best = merged.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if (a.target != nil) != (b.target != nil) { return a.target != nil }
            if a.reasons.count != b.reasons.count { return a.reasons.count > b.reasons.count }
            return a.name < b.name
        }.first
        guard let best, best.score >= minScore else { return nil }
        return best
    }

    /// 「たぶん ◯◯さん」の言い方
    static func title(_ name: String) -> String {
        if name == SpeakerLabeler.selfName { return "たぶん自分" }
        return "たぶん " + S29NRules.nameKey(name) + "さん"
    }

    /// 「別の人」で選べる人（名前のある人・自分。記録に出さない人ともう聞かない人は除く。よく話した順）
    static func choices(_ people: [SpeakerLabeler.Person]) -> [SpeakerLabeler.Person] {
        let named = people.filter { $0.isNamed && $0.hidden != true && $0.quiet != true }
        return named.sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            return a.seconds != b.seconds ? a.seconds > b.seconds : a.displayName < b.displayName
        }
    }

    /// 打った名前を使えるか（1〜20 文字・「人物」で始まらない）
    static func typedName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 20, !t.hasPrefix("人物") else { return nil }
        return t
    }
}

// MARK: - 声22 答えを家の PC の「答えた組」へ（POST /feedback）

/// 声の見本 1 つ（家の PC の answer_pairs と同じ形）
struct S29NSample: Codable, Equatable, Sendable {
    var audio: String
    var start: Double
    var end: Double
}

/// 「同じ人／違う人」の組 1 つ（people は 2 つの見本の束。家の PC の answer_pairs の people と同じ形）
struct S29NPair: Codable, Equatable, Sendable {
    var same: Bool
    /// 声の番号（「人物12」の 12・自分は "me"。line は行だけのとき）
    var ids: [String]
    var people: [[S29NSample]]
}

/// 答えの種類（s29_kind）
enum S29NAnswerKind: String, Codable, CaseIterable, Sendable {
    /// 行・ひとこまを別の人に移した（移した先と同じ・元の人と違う）
    case move
    /// 見直しで「このままでよい」（その人の声で合っている）
    case keep
    /// 名前を付けた（新しい名前。組は無いことがある）
    case named
    /// 2 人を 1 人にまとめた
    case merged
    /// 知らない人・もう聞かない
    case unknown
    /// まとまりの中に別の人がいた（まとまりは同じ人ではない）
    case split

    /// 前の形の value（家の PC の FEEDBACK の same_person は merged・different だけを受ける）
    var value: String {
        switch self {
        case .move, .keep, .named, .merged: "merged"
        case .unknown, .split: "different"
        }
    }
}

/// POST /feedback の 1 行。前の形 {"kind":"same_person","id","value","day"} に、省ける s29_* を足したもの
struct S29NAnswerBody: Codable, Equatable {
    var kind = "same_person"
    var id: String
    var value: String
    var day: String
    var s29_kind: String
    /// 同じ人／違う人の組（見本の無い答えでは無い）
    var s29_pairs: [S29NPair]?
    /// 答えに出てきた声の番号（名前の無い人は番号・自分は "me"）
    var s29_ids: [String]?
    /// まとまりの id（家の PC の s29_groups の id）
    var s29_group: String?
    /// 答えた時刻（ISO 8601）
    var s29_at: String?
}

enum S29NAnswers {
    static let sampleLimit = 3

    /// 見本を家の PC に渡せる形に（音声の名前は 120 文字まで・道を含まない。長さは 0.3〜30 秒）
    static func clean(_ audio: String?, start: Double?, end: Double?) -> S29NSample? {
        guard let audio, !audio.isEmpty, audio.count <= 120, !audio.contains("/"), !audio.contains(".."),
              let start, start.isFinite, start >= 0 else { return nil }
        var stop: Double = start + 8
        if let end, end.isFinite, end > start { stop = end }
        guard stop - start >= 0.3 else { return nil }
        return S29NSample(audio: audio, start: start, end: min(stop, start + 30))
    }

    static func samples(_ list: [SpeakerLabeler.Sample]) -> [S29NSample] {
        var out: [S29NSample] = []
        for s in list {
            guard let c = clean(s.audio, start: s.start, end: s.end), !out.contains(c) else { continue }
            out.append(c)
            if out.count >= sampleLimit { break }
        }
        return out
    }

    /// 組（どちらかの見本が無ければ作らない）
    static func pair(same: Bool, _ a: (id: String, samples: [S29NSample]), _ b: (id: String, samples: [S29NSample])) -> S29NPair? {
        let x = Array(a.samples.prefix(sampleLimit)), y = Array(b.samples.prefix(sampleLimit))
        guard !x.isEmpty, !y.isEmpty, x != y else { return nil }
        return S29NPair(same: same, ids: [a.id, b.id], people: [x, y])
    }

    /// 答えの id。まとまり全体が同じ人（merged・named）か、同じ人ではない（split）と答えたときは、家の PC の s29_groups の id
    /// （前の形のままでも家の PC が組の答えとして数えられる）。ほかは "s29-<種類>-<ミリ秒>-<しるし>"
    /// （知らない人は「同じ人ではない」ではないので、まとまりの id を使わない）
    static func answerID(kind: S29NAnswerKind, group: String?, at: Date, salt: String) -> String {
        if let group, [.merged, .named, .split].contains(kind), HomeFeeds.isID(group), !group.hasPrefix("local-") { return group }
        let ms = Int((at.timeIntervalSince1970 * 1000).rounded())
        let tail = String(salt.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(6))
        return "s29-\(kind.rawValue)-\(ms)" + (tail.isEmpty ? "" : "-" + tail)
    }

    /// 送る JSON（決まりに合わなければ nil）
    static func body(kind: S29NAnswerKind, pairs: [S29NPair], ids: [String], group: String?, at: Date, salt: String,
                     timeZone: TimeZone = .current) -> Data? {
        let id = answerID(kind: kind, group: group, at: at, salt: salt)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = ReviewRules.dayKey(at, calendar: cal)
        guard HomeFeeds.isID(id), HomeFeeds.isDay(day) else { return nil }
        var shownIDs: [String] = []
        for i in ids where !i.isEmpty && i.count <= 20 && !shownIDs.contains(i) { shownIDs.append(i) }
        let g = group.flatMap { HomeFeeds.isID($0) ? $0 : nil }
        let row = S29NAnswerBody(id: id, value: kind.value, day: day, s29_kind: kind.rawValue,
                                 s29_pairs: pairs.isEmpty ? nil : Array(pairs.prefix(12)),
                                 s29_ids: shownIDs.isEmpty ? nil : shownIDs, s29_group: g,
                                 s29_at: MothershipOutbox.isoString(at, timeZone: timeZone))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(row)
    }
}

// MARK: - 声23 今から ◯◯さんと

enum S29NWithNow {
    /// 当てる担当（S29R）が読む。中身は JSON の文 {"ids":["<人のid>"],"start":<epoch秒>,"end":<epoch秒>}
    static let key = "s29.withNow"

    struct Entry: Codable, Equatable {
        var ids: [String]
        var start: Int
        var end: Int
    }

    static func make(ids: [String], now: Date, hours: Int) -> Entry? {
        var list: [String] = []
        for id in ids where !id.isEmpty && !list.contains(id) { list.append(id) }
        guard !list.isEmpty, hours > 0 else { return nil }
        let start = Int(now.timeIntervalSince1970.rounded(.down))
        return Entry(ids: list, start: start, end: start + hours * 3600)
    }

    static func encode(_ e: Entry) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(e)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 文（String）でもバイト（Data）でも読む
    static func decode(_ raw: Any?) -> Entry? {
        let data: Data?
        if let s = raw as? String { data = Data(s.utf8) } else { data = raw as? Data }
        guard let data, let e = try? JSONDecoder().decode(Entry.self, from: data), e.end > e.start, !e.ids.isEmpty else { return nil }
        return e
    }

    static func active(_ e: Entry?, now: Date) -> Bool {
        guard let e else { return false }
        let t = Int(now.timeIntervalSince1970)
        return t >= e.start && t < e.end
    }
}

// MARK: - 声8 通りすがりは山に出さない

enum S29NPasserby {
    /// 端末の通りすがりの箱（当てる担当 S29R が書く約束。["<人のid>"] の並びか、その JSON の文。無ければ空）
    static let boxKey = "s29.passerby"

    private struct RawTag: Decodable {
        var kind: String?
        var speaker: String?
    }

    private struct RawTags: Decodable {
        var available: Bool?
        var tags: [LossyRow<RawTag>]?
    }

    /// GET /speaker-tags?day= の、通りすがりの札の付いた人の番号（読めない・無い日は nil）
    static func ids(fromTags data: Data) -> Set<String>? {
        guard let raw = try? JSONDecoder().decode(RawTags.self, from: data), raw.available == true else { return nil }
        var out = Set<String>()
        for row in raw.tags ?? [] {
            guard let t = row.value, t.kind == "passerby", let n = t.speaker.flatMap(S29NRules.unnamedID) else { continue }
            out.insert(n)
        }
        return out
    }

    static func box(_ raw: Any?) -> Set<String> {
        if let list = raw as? [String] { return Set(list) }
        let data: Data?
        if let s = raw as? String { data = Data(s.utf8) } else { data = raw as? Data }
        guard let data, let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    /// 通りすがりとみなす人: 端末の箱に入った人と、7 日のうち声のあった日すべてで通りすがりの札が付いた人
    static func merge(tags: [String: Set<String>], stats: [String: S29NStat], box: Set<String>) -> Set<String> {
        var out = box
        for (id, s) in stats where !s.days.isEmpty {
            var all = true
            for d in s.days where !(tags[d]?.contains(id) ?? false) { all = false }
            if all { out.insert(id) }
        }
        return out
    }
}

// MARK: - 母艦の「この人物N はだれ」の答えを、端末の人に届ける

enum S29NReviewLink {
    enum Action: Equatable {
        /// 名前のある人（自分を含む）にまとめる
        case assign(String)
        /// 新しい名前を付ける
        case rename(String)
        /// もう聞かない
        case quiet
        case none
    }

    /// 答えではない言葉（分からない・あとで・はい・いいえ など）
    static let notNames: Set<String> = ["分からない", "わからない", "不明", "あとで", "後で", "unsure", "yes", "no", "はい", "いいえ",
                                        "違う", "ちがう", "その他", "ほか", "ほかの人", "別の人", "とばす", "skip", "?", "？"]
    static let unknownWords: Set<String> = ["知らない人", "知らない", "知らない人・もう聞かない", "もう聞かない"]

    /// 名前の問いか（母艦の上位 5 人の「この人物N はだれ」だけ。1 行の問い speaker_line は家の PC が受ける）
    static func isNameAsk(_ item: ReviewItem) -> Bool {
        item.kind == "voice" || item.group == "voice_top"
    }

    /// 答えから、端末でする 1 つのこと。番号の人が端末に名前の無い人（自分でない・記録に出さない人でない）としていなければ none
    static func action(value raw: String, number: String?, people: [SpeakerLabeler.Person]) -> Action {
        guard let number, let p = people.first(where: { $0.id == number }), !p.isNamed, !p.isSelf, p.hidden != true else { return .none }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 20 else { return .none }
        if notNames.contains(value) || notNames.contains(value.lowercased()) { return .none }
        if unknownWords.contains(value) { return .quiet }
        if S29NRules.nameKey(value) == SpeakerLabeler.selfName { return .assign(SpeakerLabeler.selfID) }
        if S29NRules.unnamedID(value) != nil || value.hasPrefix("人物") { return .none }
        if let target = S29NRules.namedPerson(value, in: people), target != number { return .assign(target) }
        let name = S29NRules.nameKey(value)
        return name.isEmpty ? .none : .rename(name)
    }
}

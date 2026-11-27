import Foundation
import Observation

// s29（2026-11-27）名前付けを軽くする（S29N）の動き。決まりは S29NRules.swift、画面は S29NViews.swift。
// - 声24 名前付けの山: 7 日の記録を 1 日ずつ譲りながら数え、効き目の大きい順に 1 日 3 件（仮）まで
// - 声18 しぼり・声8 通りすがり（家の PC の GET /speaker-tags?day= と端末の箱 s29.passerby）・声21 もう聞かない
// - 声19 家の PC の s29_groups（GET /same-person）か、端末の中の声の近さでまとめてから 1 問に。答えたときだけまとめる
// - 声20 「たぶん ◯◯さん」の手がかりは Pipeline.voiceClues
// - 声22 名前付けの答え（移す・このままでよい・名前を付けた・まとめた・知らない人・まとまりに別の人）を POST /feedback へ
// - 母艦の「この人物N はだれ」（確かめ待ち）の答えを、端末の人の名前付け・まとめに届ける（S29NReviewApply）

@MainActor
@Observable
final class S29NBook {
    static let shared = S29NBook()

    private(set) var result = S29NPile.Result()
    /// 札の id → 「たぶん ◯◯さん」（今日出す札だけ）
    private(set) var guesses: [String: S29NClue] = [:]
    private(set) var refreshing = false
    private(set) var refreshedAt: Date?
    /// 家の PC の s29_groups（欄が無ければ nil = 端末の中でまとめる）
    private(set) var pcGroups: [S29NGroup]?
    /// 答えた・「あとで」の札（id → 日）
    @ObservationIgnored private var done: [String: String]
    @ObservationIgnored private var later: [String: String]
    /// 日 → 通りすがりの札の人（家の PC）
    @ObservationIgnored private var tags: [String: Set<String>] = [:]
    @ObservationIgnored private var tagsAt: [String: Date] = [:]
    private var version = 0

    static let doneKey = "s29n.done"
    static let laterKey = "s29n.later"
    static let answeredKey = "s29n.answeredToday"
    static let groupsFile = "app-feed-s29groups.json"
    private static let every: TimeInterval = 10 * 60

    private static var groupsURL: URL { URL.applicationSupportDirectory.appendingPathComponent(groupsFile) }

    init() {
        done = UserDefaults.standard.dictionary(forKey: Self.doneKey) as? [String: String] ?? [:]
        later = UserDefaults.standard.dictionary(forKey: Self.laterKey) as? [String: String] ?? [:]
        if let data = try? Data(contentsOf: Self.groupsURL) {
            pcGroups = try? JSONDecoder().decode([S29NGroup].self, from: data)
        }
    }

    // MARK: 数

    /// 今日もう答えた数（名前付けの山の分だけ）
    func answeredToday(now: Date = .now) -> Int {
        S24AskRules.daySet(adding: [], saved: UserDefaults.standard.string(forKey: Self.answeredKey),
                           day: ReviewRules.dayKey(now)).ids.count
    }

    /// 「直す」のタブに足す数
    var badgeCount: Int {
        _ = version
        return S29NPile.badge(result.cards, answeredToday: answeredToday(), daily: S29NSettings.daily)
    }

    /// 今日出す札
    func todayCards(now: Date = .now) -> [S29NCard] {
        _ = version
        let left = S24AskRules.left(cap: S24AskSettings.questionCap, asked: S24Gate.counts(now: now).asked)
        return S29NPile.today(result.cards, answeredToday: answeredToday(now: now), daily: S29NSettings.daily, gateLeft: left)
    }

    // MARK: 家の PC のまとまり（SamePersonBook.refresh から渡す）

    func ingestSamePerson(_ body: Data) {
        let groups = S29NGroups.decode(body)
        pcGroups = groups
        if let groups, let data = try? JSONEncoder().encode(groups) {
            try? data.write(to: Self.groupsURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: Self.groupsURL)
        }
    }

    // MARK: 数え直し

    /// 7 日の記録を 1 日ずつ譲りながら数え、山を作り直す（force でなければ 10 分に 1 回まで）
    func refresh(_ pipeline: Pipeline, force: Bool = false, now: Date = .now) async {
        guard pipeline.speakerLabelsOn, !refreshing else { return }
        if !force, let refreshedAt, now.timeIntervalSince(refreshedAt) < Self.every { return }
        refreshing = true
        defer { refreshing = false }
        let oldest = ReviewRules.dayKey(now.addingTimeInterval(-Double(S29NSettings.windowDays - 1) * 86400))
        var talks: [S29NTalk] = []
        for day in pipeline.recordedDays() where day >= oldest {
            for c in pipeline.conversations(on: day) {
                talks.append(S29NTalk(day: day, media: c.media != nil, lines: c.lines))
            }
            await Task.yield()
            if Task.isCancelled { return }
        }
        let counted = S29NRules.tally(talks)
        var days = Set<String>()
        for s in counted.stats.values { days.formUnion(s.days) }
        await fetchTags(pipeline.homePC, days: days, now: now)
        let box = S29NPasserby.box(UserDefaults.standard.object(forKey: S29NPasserby.boxKey))
        let passerby = S29NPasserby.merge(tags: tags, stats: counted.stats, box: box)
        let skip = pipeline.skipVoicesForView()
        let people = pipeline.people
        var groups = pcGroups ?? []
        if pcGroups == nil {
            let candidates = people.filter { S29NPile.eligible($0, stats: counted.stats, skip: skip, passerby: passerby) }
            groups = S29NGroups.local(candidates, apart: counted.apart, limit: SpeakerLabeler.Strictness.normal.accept)
        }
        let selfVoices = people.first(where: \.isSelf)?.voices.filter { $0.pinned && $0.model == SpeakerLabeler.model }.count ?? 0
        let today = ReviewRules.dayKey(now)
        var hidden = Set(done.keys)
        for (id, day) in later where day == today { hidden.insert(id) }
        result = S29NPile.build(people: people, stats: counted.stats, groups: groups, skip: skip, passerby: passerby,
                                done: hidden, minDays: S29NSettings.minDays, minSeconds: S29NSettings.minSeconds,
                                selfVoices: selfVoices,
                                // s34 自6: 家の PC が 3 場面の見本をそろえ（record_needed が false）、端末に足せていれば録る札は出さない
                                selfVoiceHidden: !pipeline.speakerLabelsOn || S34AVoiceBook.shared.selfCardDone)
        refreshedAt = now
        version += 1
        Tally.add("s29n.pile.refresh")
        await loadGuesses(pipeline)
    }

    private func fetchTags(_ pc: HomePC, days: Set<String>, now: Date) async {
        guard pc.isConfigured, pc.features.contains("speakertags") else { return }
        let today = ReviewRules.dayKey(now)
        for day in days.sorted().reversed() {
            // 前の日は 1 度読めば足りる。今日は 1 時間に 1 回まで
            if let at = tagsAt[day], day != today || now.timeIntervalSince(at) < 3600 { continue }
            guard let data = try? await pc.getJSONData("speaker-tags", query: [URLQueryItem(name: "day", value: day)], timeout: 8)
            else { break }
            tagsAt[day] = now
            if let ids = S29NPasserby.ids(fromTags: data) { tags[day] = ids }
        }
    }

    /// 今日出す札の「たぶん ◯◯さん」（声20）。手がかりは Pipeline.voiceClues（予定の相手・呼ばれた名前・声の近さ）
    private func loadGuesses(_ pipeline: Pipeline) async {
        let cards = Array(result.cards.filter { $0.kind != .selfVoice }.prefix(S29NSettings.daily + 2))
        var ids = Set<String>()
        for c in cards { ids.formUnion(c.members) }
        guard !ids.isEmpty else {
            guesses = [:]
            return
        }
        let clues = await pipeline.voiceClues(for: ids, talkLimit: 0)
        let people = pipeline.people
        var blocked = Set<String>()
        for p in people where p.hidden == true || p.quiet == true { blocked.insert(p.id) }
        var out: [String: S29NClue] = [:]
        for c in cards {
            var list: [S29NClue] = []
            for m in c.members {
                for k in clues[m]?.candidates ?? [] {
                    list.append(S29NClue(name: k.name, target: k.target, reasons: k.reasons, score: k.score))
                }
            }
            var hinted: [(id: String, name: String)] = []
            for h in c.hinted {
                if let p = people.first(where: { $0.id == h }) { hinted.append((id: h, name: p.displayName)) }
            }
            if let g = S29NGuess.pick(list, hinted: hinted, members: Set(c.members), blocked: blocked) { out[c.id] = g }
        }
        guesses = out
    }

    // MARK: 答える

    private func markDone(_ card: S29NCard, now: Date = .now) {
        let day = ReviewRules.dayKey(now)
        done[card.id] = day
        // 60 日より前のものは捨てる
        let oldest = ReviewRules.dayKey(now.addingTimeInterval(-60 * 86400))
        done = done.filter { $0.value >= oldest }
        UserDefaults.standard.set(done, forKey: Self.doneKey)
        let merged = S24AskRules.daySet(adding: [card.id], saved: UserDefaults.standard.string(forKey: Self.answeredKey), day: day)
        UserDefaults.standard.set(merged.save, forKey: Self.answeredKey)
        // 全体の 1 日 3 問（仮）にも入れる
        S24Gate.noteAnswered(key: card.askKey, now: now)
        result.cards.removeAll { $0.id == card.id }
        version += 1
    }

    /// 「あとで」（今日は出さない。数えない）
    func postpone(_ card: S29NCard, now: Date = .now) {
        later[card.id] = ReviewRules.dayKey(now)
        later = later.filter { $0.value >= ReviewRules.dayKey(now.addingTimeInterval(-7 * 86400)) }
        UserDefaults.standard.set(later, forKey: Self.laterKey)
        result.cards.removeAll { $0.id == card.id }
        Tally.add("s29n.pile.later")
        version += 1
    }

    /// 自分の声を録る画面を開いた（今日はもう出さない。1 件と数える）
    func openedSelfVoice(_ card: S29NCard) {
        markDone(card)
        done[card.id] = nil  // 録れなければ明日また出す
        UserDefaults.standard.set(done, forKey: Self.doneKey)
        postponeOnly(card)
        Tally.add("s29n.pile.selfVoice")
    }

    private func postponeOnly(_ card: S29NCard, now: Date = .now) {
        later[card.id] = ReviewRules.dayKey(now)
        UserDefaults.standard.set(later, forKey: Self.laterKey)
    }

    /// 「たぶん ◯◯さん」・「別の人」で選んだ人。まとまりの全員をその人にまとめる（Pipeline.assign。戻せる）
    func answer(_ card: S29NCard, target: String, pipeline: Pipeline) async -> String {
        let before = pipeline.people
        let targetSamples = S29NAnswers.samples(before.first { $0.id == target }?.samples ?? [])
        var pairs: [S29NPair] = []
        S29NHooks.suppressed = true
        for m in card.members where m != target {
            let own = S29NAnswers.samples(before.first { $0.id == m }?.samples ?? [])
            if let p = S29NAnswers.pair(same: true, (id: m, samples: own), (id: target, samples: targetSamples)) { pairs.append(p) }
            await pipeline.assign(m, to: target)
        }
        S29NHooks.suppressed = false
        S29NHooks.send(kind: .merged, pairs: pairs, ids: card.members + [target], group: card.groupFromPC ? card.groupID : nil,
                       salt: card.id)
        markDone(card)
        Tally.add("s29n.pile.assign")
        await MothershipOutbox.send(pipeline.homePC)
        let name = pipeline.people.first { $0.id == target }?.displayName ?? ""
        return "「\(name)」にまとめました。その人の画面から戻せます。"
    }

    /// 名前を打った（最後の手段）。今いる人と同じ名前ならその人にまとめ、いなければ行の多い人に名前を付けて、残りをまとめる
    func answer(_ card: S29NCard, name raw: String, pipeline: Pipeline) async -> String {
        guard let name = S29NGuess.typedName(raw), let first = card.members.first else { return "名前を入れてください。" }
        if let target = S29NRules.namedPerson(name, in: pipeline.people), !card.members.contains(target) {
            return await answer(card, target: target, pipeline: pipeline)
        }
        let before = pipeline.people
        let firstSamples = S29NAnswers.samples(before.first { $0.id == first }?.samples ?? [])
        var pairs: [S29NPair] = []
        S29NHooks.suppressed = true
        await pipeline.renamePerson(first, to: name)
        for m in card.members.dropFirst() {
            let own = S29NAnswers.samples(before.first { $0.id == m }?.samples ?? [])
            if let p = S29NAnswers.pair(same: true, (id: m, samples: own), (id: first, samples: firstSamples)) { pairs.append(p) }
            await pipeline.mergePerson(m, into: first)
        }
        S29NHooks.suppressed = false
        S29NHooks.send(kind: .named, pairs: pairs, ids: card.members, group: card.groupFromPC ? card.groupID : nil, salt: card.id)
        markDone(card)
        Tally.add("s29n.pile.named")
        await MothershipOutbox.send(pipeline.homePC)
        return "「\(name)」と名前を付けました。"
    }

    /// 「知らない人・もう聞かない」（声21）。全員に印を付けるだけ（まとめない・名前は付けない。設定の奥から戻せる）
    func answerUnknown(_ card: S29NCard, pipeline: Pipeline) async -> String {
        for m in card.members { await pipeline.setQuiet(m, true) }
        S29NHooks.send(kind: .unknown, pairs: [], ids: card.members, group: card.groupFromPC ? card.groupID : nil, salt: card.id)
        markDone(card)
        Tally.add("s29n.pile.unknown")
        await MothershipOutbox.send(pipeline.homePC)
        return "もう聞きません。設定の「もう聞かない人」から戻せます。"
    }

    /// 「この中に別の人がいる」（まとまりだけ）。まとまりは使わず、1 人ずつに戻す（まとめない）
    func answerSplit(_ card: S29NCard, pipeline: Pipeline) async -> String {
        S29NHooks.send(kind: .split, pairs: [], ids: card.members, group: card.groupFromPC ? card.groupID : nil, salt: card.id)
        markDone(card)
        Tally.add("s29n.pile.split")
        await MothershipOutbox.send(pipeline.homePC)
        await refresh(pipeline, force: true)
        return "まとまりをやめて、1 人ずつにしました。"
    }

    /// 「もう聞かない」を戻す
    func unquiet(_ id: String, pipeline: Pipeline) async {
        await pipeline.setQuiet(id, false)
        done = done.filter { !$0.key.hasSuffix(":" + id) }
        UserDefaults.standard.set(done, forKey: Self.doneKey)
        Tally.add("s29n.quiet.undo")
        await refresh(pipeline, force: true)
    }
}

// MARK: - 声22 ほかの画面の名前付けの答えも送る（Pipeline の renamePerson・mergePerson・fixSpeaker・dropSample・keepSample から 1 行で呼ぶ）

@MainActor
enum S29NHooks {
    /// 山の答えで、まとめて 1 行にするあいだは、1 つずつの答えを送らない
    static var suppressed = false

    static func send(kind: S29NAnswerKind, pairs: [S29NPair], ids: [String], group: String?, salt: String, now: Date = .now) {
        guard let body = S29NAnswers.body(kind: kind, pairs: pairs, ids: ids, group: group, at: now, salt: salt) else { return }
        MothershipOutbox.enqueue(path: "feedback", body: body, now: now)
        Tally.add("s29n.answer." + kind.rawValue)
    }

    private static func samples(_ id: String?, _ people: [SpeakerLabeler.Person], excluding: S29NSample? = nil) -> [S29NSample] {
        guard let id else { return [] }
        return S29NAnswers.samples(people.first { $0.id == id }?.samples ?? []).filter { $0 != excluding }
    }

    /// 名前を付けた・付け替えた（名前を消したときは送らない）
    static func rename(_ id: String, to name: String, people: [SpeakerLabeler.Person]) {
        guard !suppressed, !name.isEmpty else { return }
        send(kind: .named, pairs: [], ids: [id], group: nil, salt: id)
    }

    /// 2 人をまとめた（本人が押したときだけ。夜の整理・自動のまとめは送らない）
    static func merge(_ source: String, into target: String, people: [SpeakerLabeler.Person], automatic: Bool) {
        guard !suppressed, !automatic, source != target else { return }
        var pairs: [S29NPair] = []
        if let p = S29NAnswers.pair(same: true, (id: source, samples: samples(source, people)), (id: target, samples: samples(target, people))) {
            pairs.append(p)
        }
        send(kind: .merged, pairs: pairs, ids: [source, target], group: nil, salt: source)
    }

    /// 行の話し手を直した（すべての行を直すときはまとめと同じなので merge が送る）
    static func move(line: ConversationLog.Line, next: ConversationLog.Line?, to id: String, everywhere: Bool,
                     people: [SpeakerLabeler.Person]) {
        let old = line.speakerID
        guard !suppressed, old != id else { return }
        if everywhere, old != nil { return }
        let start = line.offset
        let end = line.end ?? start.map { min($0 + 10, next?.offset ?? $0 + 10) }
        guard let clip = S29NAnswers.clean(line.audio, start: start, end: end) else {
            send(kind: .move, pairs: [], ids: [old ?? "line", id], group: nil, salt: id)
            return
        }
        var pairs: [S29NPair] = []
        if let p = S29NAnswers.pair(same: true, (id: "line", samples: [clip]), (id: id, samples: samples(id, people, excluding: clip))) {
            pairs.append(p)
        }
        if let p = S29NAnswers.pair(same: false, (id: "line", samples: [clip]), (id: old ?? "", samples: samples(old, people, excluding: clip))) {
            pairs.append(p)
        }
        send(kind: .move, pairs: pairs, ids: [old ?? "line", id], group: nil, salt: id)
    }

    /// 覚えた声のひとこまを外した・別の人へ移した
    static func drop(_ sample: SpeakerLabeler.Sample, from id: String, to target: String?, people: [SpeakerLabeler.Person]) {
        guard !suppressed, let clip = S29NAnswers.clean(sample.audio, start: sample.start, end: sample.end) else { return }
        var pairs: [S29NPair] = []
        if let p = S29NAnswers.pair(same: false, (id: "clip", samples: [clip]), (id: id, samples: samples(id, people, excluding: clip))) {
            pairs.append(p)
        }
        if let target,
           let p = S29NAnswers.pair(same: true, (id: "clip", samples: [clip]), (id: target, samples: samples(target, people, excluding: clip))) {
            pairs.append(p)
        }
        send(kind: .move, pairs: pairs, ids: [id] + (target.map { [$0] } ?? []), group: nil, salt: id)
    }

    /// 見直しで「このままでよい」（そのひとこまは、その人の声で合っている）
    static func keep(_ sample: SpeakerLabeler.Sample, of id: String, people: [SpeakerLabeler.Person]) {
        guard !suppressed, let clip = S29NAnswers.clean(sample.audio, start: sample.start, end: sample.end) else { return }
        var pairs: [S29NPair] = []
        if let p = S29NAnswers.pair(same: true, (id: "clip", samples: [clip]), (id: id, samples: samples(id, people, excluding: clip))) {
            pairs.append(p)
        }
        send(kind: .keep, pairs: pairs, ids: [id], group: nil, salt: id)
    }
}

// MARK: - 母艦の「この人物N はだれ」の答えを、端末の人に届ける（S20Book.answer から 1 行で呼ぶ）

@MainActor
enum S29NReviewApply {
    /// 届けた記録（"日|番号|したこと"。50 件まで。設定の奥に出す）
    static let linkedKey = "s29n.linked"

    static func apply(_ item: ReviewItem, _ value: String, now: Date = .now) {
        guard S29NSettings.isOn(S29NSettings.reviewLinkKey), S29NReviewLink.isNameAsk(item),
              let pipeline = PushWake.pipeline, let number = S26VVoice.number(item) else { return }
        let action = S29NReviewLink.action(value: value, number: number, people: pipeline.people)
        let note: String
        switch action {
        case .none:
            Tally.add("s29n.link.none")
            return
        case .assign(let target):
            note = "まとめた"
            Task { await pipeline.assign(number, to: target) }
        case .rename(let name):
            note = "名前を付けた"
            Task { await pipeline.renamePerson(number, to: name) }
        case .quiet:
            note = "もう聞かない"
            Task { await pipeline.setQuiet(number, true) }
        }
        Tally.add("s29n.link.applied")
        var list = UserDefaults.standard.stringArray(forKey: linkedKey) ?? []
        list.append(ReviewRules.dayKey(now) + "|" + number + "|" + note)
        UserDefaults.standard.set(Array(list.suffix(50)), forKey: linkedKey)
    }
}

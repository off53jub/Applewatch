import Foundation
import Observation
import SwiftUI

/// 同じ人かも（施策 10。2026-11-13）。家の PC（GET /same-person。features の "sameperson"）が、同じ日の名前の無い「人物N」を
/// 声の近さで組にしたもの。「直す」の「同じ人かも」に出し、本人が「同じ人」を押したときだけ、人の画面の「まとめる」と同じ
/// Pipeline.mergePerson でまとめる（merges.json に残るので、まとめた先の人の画面から戻せる）。「別の人」はもう出さない。
/// 名前の付いた人・自分が入った組は、読むときも押したときも使わない（名前の付いた人を自動でまとめない）。
/// 写しは端末に置く（新しいファイル。同期しない）。中身の文は記録（ログ）に書かない。

struct SamePersonGroup: Codable, Identifiable, Equatable {
    struct Sample: Codable, Equatable {
        /// 記録の行の時刻（ISO8601）
        var time: String
        var text: String
        /// 区切りの音声のファイル名（記録の行の audio と同じ）
        var audio: String
        /// その音声の中での位置（秒）
        var start: Double
        var end: Double
    }

    struct Member: Codable, Equatable, Identifiable {
        /// 声の番号（「人物12」の 12）
        var id: String
        var name: String
        var lines: Int
        var seconds: Double
        var samples: [Sample]
    }

    var id: String
    var day: String
    var score: Double
    var people: [Member]
    /// 日をまたぐ組の日（2026-11-15。強化案 56。1日の組は nil）
    var days: [String]? = nil
}

/// 名前の無い声が、名前のある人かもしれない（2026-11-15。強化案 56。家の PC の GET /same-person の "maybe"）。
/// 「同じ人」を押したときだけ、人の画面の「だれの声ですか」と同じ assign でまとめる（merges.json に残るので戻せる）
struct SamePersonMaybe: Codable, Identifiable, Equatable {
    var id: String
    var day: String
    var score: Double
    var person: SamePersonGroup.Member
    /// 名前のある人の番号と、家の PC が見た名前（端末の名前と違えば出さない）
    var namedID: String
    var namedName: String
}

struct SamePersonFeed: Codable, Equatable {
    var generated_at: String? = nil
    var groups: [SamePersonGroup] = []
    /// 2026-11-15（強化案 56）。前の写しには無い
    var maybe: [SamePersonMaybe]? = nil
}

// MARK: - 確かめ方（決まった入力から決まった出力だけ）

enum SamePersonRules {
    static let groupLimit = 30
    static let sampleLimit = 3
    static let memberRange = 2...4

    private struct RawSample: Decodable {
        var time: String?
        var text: String?
        var audio: String?
        var start: Double?
        var end: Double?
    }

    private struct RawMember: Decodable {
        var id: String?
        var name: String?
        var lines: Int?
        var seconds: Double?
        var samples: [LossyRow<RawSample>]?
    }

    private struct RawGroup: Decodable {
        var id: String?
        var score: Double?
        var people: [LossyRow<RawMember>]?
        /// 日をまたぐ組だけ
        var day: String?
        var days: [String]?
    }

    private struct RawDay: Decodable {
        var day: String?
        var groups: [LossyRow<RawGroup>]?
    }

    private struct RawNamed: Decodable {
        var id: String?
        var name: String?
    }

    private struct RawMaybe: Decodable {
        var id: String?
        var day: String?
        var score: Double?
        var person: RawMember?
        var named: RawNamed?
    }

    private struct RawFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var days: [LossyRow<RawDay>]?
        var across: [LossyRow<RawGroup>]?
        var maybe: [LossyRow<RawMaybe>]?
    }

    static let maybeLimit = 20

    /// 「人物12」→ "12"。名前の無い人の名前の形でなければ nil
    static func unnamedID(_ name: String) -> String? {
        guard name.hasPrefix("人物") else { return nil }
        let digits = String(name.dropFirst(2))
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        for ch in digits where !(ch.isASCII && ch.isNumber) { return nil }
        return digits
    }

    private static func clean(_ raw: RawSample) -> SamePersonGroup.Sample? {
        guard let time = HomeFeeds.trimmed(raw.time), AppFeeds.parseTime(time) != nil,
              let audio = HomeFeeds.trimmed(raw.audio), audio.count <= 120, !audio.contains("/"), !audio.contains(".."),
              let start = raw.start, let end = raw.end, start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        let text = String((HomeFeeds.trimmed(raw.text) ?? "").prefix(40))
        return SamePersonGroup.Sample(time: time, text: text, audio: audio, start: start, end: end)
    }

    /// 組の人の1人。名前の無い「人物N」の形でなければ nil
    private static func clean(_ m: RawMember) -> SamePersonGroup.Member? {
        guard let mid = HomeFeeds.trimmed(m.id), let name = HomeFeeds.trimmed(m.name), unnamedID(name) == mid else { return nil }
        var samples: [SamePersonGroup.Sample] = []
        for s in m.samples ?? [] {
            guard let raw = s.value, let sample = clean(raw) else { continue }
            samples.append(sample)
            if samples.count >= sampleLimit { break }
        }
        let lines: Int = max(0, m.lines ?? 0)
        let seconds: Double = max(0, m.seconds ?? 0)
        return SamePersonGroup.Member(id: mid, name: name, lines: lines, seconds: seconds, samples: samples)
    }

    /// 組の1つ。名前の無い「人物N」でない人が1人でも入っていれば、組ごと使わない
    private static func clean(_ raw: RawGroup, day: String) -> SamePersonGroup? {
        guard let id = HomeFeeds.trimmed(raw.id), HomeFeeds.isID(id),
              let score = raw.score, score.isFinite else { return nil }
        var members: [SamePersonGroup.Member] = []
        var ids = Set<String>()
        for row in raw.people ?? [] {
            guard let rawMember = row.value, let member = clean(rawMember), ids.insert(member.id).inserted else { return nil }
            members.append(member)
        }
        guard memberRange.contains(members.count) else { return nil }
        return SamePersonGroup(id: id, day: day, score: score, people: members)
    }

    /// 日をまたぐ組（2026-11-15）。日はいちばん新しい日、days は2日以上
    private static func cleanAcross(_ raw: RawGroup) -> SamePersonGroup? {
        var days: [String] = []
        for d in raw.days ?? [] where HomeFeeds.isDay(d) && !days.contains(d) {
            days.append(d)
        }
        days.sort()
        guard days.count >= 2, let last = days.last, var group = clean(raw, day: last) else { return nil }
        if let d = HomeFeeds.trimmed(raw.day), HomeFeeds.isDay(d), days.contains(d) { group.day = d }
        group.days = days
        return group
    }

    /// 名前のある人かも（2026-11-15）。自分・「人物N」の形の名前・番号の無いものは使わない
    private static func clean(_ raw: RawMaybe) -> SamePersonMaybe? {
        guard let id = HomeFeeds.trimmed(raw.id), HomeFeeds.isID(id),
              let day = HomeFeeds.trimmed(raw.day), HomeFeeds.isDay(day),
              let score = raw.score, score.isFinite,
              let rawPerson = raw.person, let person = clean(rawPerson),
              let namedID = HomeFeeds.trimmed(raw.named?.id), namedID != SpeakerLabeler.selfID, namedID.count <= 20,
              let namedName = HomeFeeds.trimmed(raw.named?.name), unnamedID(namedName) == nil,
              namedID != person.id else { return nil }
        let name: String = String(namedName.prefix(20))
        return SamePersonMaybe(id: id, day: day, score: score, person: person, namedID: namedID, namedName: name)
    }

    /// GET /same-person の答え。読めない・{"available": false} なら nil（前の写しのままにする）
    static func decode(_ data: Data) -> SamePersonFeed? {
        guard let raw = try? JSONDecoder().decode(RawFeed.self, from: data), raw.available == true else { return nil }
        var groups: [SamePersonGroup] = []
        var seen = Set<String>()
        for dayRow in raw.days ?? [] {
            guard let d = dayRow.value, let day = HomeFeeds.trimmed(d.day), HomeFeeds.isDay(day) else { continue }
            for row in d.groups ?? [] {
                guard let g = row.value, let group = clean(g, day: day), seen.insert(group.id).inserted else { continue }
                if groups.count < groupLimit { groups.append(group) }
            }
        }
        // 日をまたぐ組（2026-11-15。強化案 56）。1日の組と同じ枠に、上限まで足す
        for row in raw.across ?? [] {
            guard let g = row.value, let group = cleanAcross(g), seen.insert(group.id).inserted else { continue }
            if groups.count < groupLimit + 20 { groups.append(group) }
        }
        var maybe: [SamePersonMaybe] = []
        for row in raw.maybe ?? [] {
            guard let m = row.value, let item = clean(m), seen.insert(item.id).inserted else { continue }
            maybe.append(item)
            if maybe.count >= maybeLimit { break }
        }
        return SamePersonFeed(generated_at: raw.generated_at, groups: groups, maybe: maybe)
    }

    /// 「◯◯さんかも」の言い方（名前がもう「さん」で終わっていれば足さない）
    static func maybeTitle(_ name: String) -> String {
        name.hasSuffix("さん") ? name + "かも" : name + "さんかも"
    }

    /// 見せる「名前のある人かも」: まだ答えていなくて、声がいまも名前の無い人で、名前のある人がいまも同じ名前で
    /// （自分ではなく）いるもの（点の高い順）。named は番号 → いまの名前（名前のある人だけ）
    static func visibleMaybe(_ items: [SamePersonMaybe], answered: Set<String>, unnamed: Set<String>,
                             named: [String: String]) -> [SamePersonMaybe] {
        var out: [SamePersonMaybe] = []
        for m in items where !answered.contains(m.id) && unnamed.contains(m.person.id) {
            guard let now = named[m.namedID], now == m.namedName else { continue }
            out.append(m)
        }
        out.sort { a, b in a.score != b.score ? a.score > b.score : a.day > b.day }
        return out
    }

    /// 見せる組: まだ答えていなくて、組の全員が、いまも端末に名前の無い人（自分でない）としているもの（点の高い順）
    static func visible(_ groups: [SamePersonGroup], answered: Set<String>, unnamed: Set<String>) -> [SamePersonGroup] {
        var out: [SamePersonGroup] = []
        for g in groups where !answered.contains(g.id) {
            var allUnnamed = true
            for m in g.people where !unnamed.contains(m.id) { allUnnamed = false }
            if allUnnamed { out.append(g) }
        }
        out.sort { a, b in a.score != b.score ? a.score > b.score : a.day > b.day }
        return out
    }

    /// まとめる先（行のいちばん多い人。同じなら番号の小さい人）と、まとめる人
    static func mergePlan(_ group: SamePersonGroup) -> (target: String, sources: [String]) {
        let sorted: [SamePersonGroup.Member] = group.people.sorted { a, b in
            if a.lines != b.lines { return a.lines > b.lines }
            return (Int(a.id) ?? 0) < (Int(b.id) ?? 0)
        }
        guard let first = sorted.first else { return ("", []) }
        var sources: [String] = []
        for m in sorted.dropFirst() { sources.append(m.id) }
        return (first.id, sources)
    }
}

// MARK: - 読み込み

@MainActor
@Observable
final class SamePersonBook {
    static let shared = SamePersonBook()

    private(set) var groups: [SamePersonGroup] = []
    /// 名前のある人かも（2026-11-15。強化案 56）
    private(set) var maybe: [SamePersonMaybe] = []
    /// 「同じ人」「別の人」を押した組
    private(set) var answered: Set<String>
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var fetchedAt: Date?

    nonisolated static let file = "app-feed-sameperson.json"
    static let answeredKey = "samePersonAnswered"
    private static let every: TimeInterval = 30 * 60
    private static let answeredLimit = 500

    private static var url: URL { URL.applicationSupportDirectory.appendingPathComponent(file) }

    init() {
        answered = Set(UserDefaults.standard.stringArray(forKey: Self.answeredKey) ?? [])
        if let data = try? Data(contentsOf: Self.url), let feed = try? JSONDecoder().decode(SamePersonFeed.self, from: data) {
            groups = feed.groups
            maybe = feed.maybe ?? []
        }
    }

    /// 家の PC から読み直す（force でなければ30分に1回まで）。読めなければ前の写しのまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.features.contains("sameperson") else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        guard let body = try? await pc.appFeed("same-person", feature: "sameperson"),
              let feed = SamePersonRules.decode(body) else { return }
        groups = feed.groups
        maybe = feed.maybe ?? []
        if let data = try? JSONEncoder().encode(feed) { try? data.write(to: Self.url, options: .atomic) }
    }

    func markAnswered(_ id: String) {
        answered.insert(id)
        if answered.count > Self.answeredLimit {
            var live = Set(groups.map(\.id))
            for m in maybe { live.insert(m.id) }
            answered = answered.filter { live.contains($0) }
        }
        UserDefaults.standard.set(Array(answered), forKey: Self.answeredKey)
    }
}

// MARK: - 母艦への答え（POST /feedback）

/// 「使われたか」の答えを母艦へ（共通の約束の POST /feedback {"kind", "id", "value", "day"}。features の "feedback"）。
/// 2026-11-15（強化案 46）: ため場所と送り口は MothershipFeeds.swift の MothershipOutbox の1つにまとめた
/// （前のため場所 "fixFeedbackPending" にあった分は、起動のときに MothershipOutbox.migrateLegacy が移す）。
@MainActor
enum FixFeedback {
    static func today(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// ためる（id は英数字と _ . : - の 64 字まで。決めた組でなければ捨てる）
    static func add(kind: String, id: String, value: String, day: String? = nil) {
        MothershipOutbox.enqueueFeedback(kind: kind, id: id, value: value, day: day ?? today())
    }

    /// ためた答えを古い順に送る（送り口は1つ）
    static func send(_ pc: HomePC) async {
        await MothershipOutbox.send(pc)
    }
}

// MARK: - 押したときの動き

extension Pipeline {
    /// いまの名前の無い人（自分でない・記録に出さない人でない）の番号
    var unnamedVoiceIDs: Set<String> {
        Set(people.filter { !$0.isNamed && !$0.isSelf && $0.hidden != true }.map(\.id))
    }

    /// 「同じ人かも」の、いま見せる組
    var samePersonGroups: [SamePersonGroup] {
        let book = SamePersonBook.shared
        return SamePersonRules.visible(book.groups, answered: book.answered, unnamed: unnamedVoiceIDs)
    }

    /// 名前のある人（自分でない）の番号 → いまの名前
    var namedVoiceNames: [String: String] {
        var out: [String: String] = [:]
        for p in people where p.isNamed && !p.isSelf {
            if let name = p.name { out[p.id] = name }
        }
        return out
    }

    /// 「◯◯さんかも」の、いま見せるもの（2026-11-15。強化案 56）
    var samePersonMaybes: [SamePersonMaybe] {
        let book = SamePersonBook.shared
        return SamePersonRules.visibleMaybe(book.maybe, answered: book.answered, unnamed: unnamedVoiceIDs,
                                            named: namedVoiceNames)
    }

    /// 「◯◯さんかも」の「同じ人」「別の人」。「同じ人」は、押した時点でも声が名前の無い人で、名前のある人が同じ名前でいるかを
    /// 確かめ直してから、人の画面の「だれの声ですか」と同じ assign でまとめる（merges.json に残るので戻せる）。名前は付けない・変えない
    func answerSamePersonMaybe(_ item: SamePersonMaybe, same: Bool) async -> String {
        let book = SamePersonBook.shared
        guard same else {
            book.markAnswered(item.id)
            Tally.add("sameperson.maybe.different")
            FixFeedback.add(kind: "same_person", id: item.id, value: "different", day: item.day)
            await FixFeedback.send(homePC)
            return "別の人として、もう出しません。"
        }
        let named: [String: String] = namedVoiceNames
        guard unnamedVoiceIDs.contains(item.person.id), named[item.namedID] == item.namedName else {
            book.markAnswered(item.id)
            return "名前が変わったか、もう名前が付いているので、まとめませんでした。"
        }
        await assign(item.person.id, to: item.namedID)
        book.markAnswered(item.id)
        Tally.add("sameperson.maybe.merged")
        FixFeedback.add(kind: "same_person", id: item.id, value: "merged", day: item.day)
        await FixFeedback.send(homePC)
        return "「\(item.namedName)」にまとめました。その人の画面から戻せます。"
    }

    /// 「同じ人」「別の人」。「同じ人」は、押した時点でも全員が名前の無い人かを確かめ直してから、人の画面の「まとめる」と同じ
    /// mergePerson でまとめる（行の多い人へ。merges.json に残るので戻せる）。返すのは画面に出す一文
    func answerSamePerson(_ group: SamePersonGroup, same: Bool) async -> String {
        let book = SamePersonBook.shared
        guard same else {
            book.markAnswered(group.id)
            Tally.add("sameperson.different")
            FixFeedback.add(kind: "same_person", id: group.id, value: "different", day: group.day)
            await FixFeedback.send(homePC)
            return "別の人として、この組はもう出しません。"
        }
        let unnamed = unnamedVoiceIDs
        for m in group.people where !unnamed.contains(m.id) {
            book.markAnswered(group.id)
            return "名前の付いた人（または自分）が入ったので、まとめませんでした。"
        }
        let plan = SamePersonRules.mergePlan(group)
        guard !plan.target.isEmpty else { return "まとめる人が見つかりませんでした。" }
        for source in plan.sources {
            await mergePerson(source, into: plan.target)
        }
        book.markAnswered(group.id)
        Tally.add("sameperson.merged")
        FixFeedback.add(kind: "same_person", id: group.id, value: "merged", day: group.day)
        await FixFeedback.send(homePC)
        return "「人物\(plan.target)」にまとめました。まとめた先の人の画面から戻せます。"
    }
}

// MARK: - 画面

/// 人物N の1人（▶︎で聞く・行の数・ひとこと）。組と「◯◯さんかも」の両方で使う
struct SamePersonMemberLine: View {
    @Environment(Pipeline.self) private var pipeline
    let member: SamePersonGroup.Member
    /// 再生の印（組の id ＋人の番号）
    let key: String
    let player: ClipPlayer

    var body: some View {
        let sample: SamePersonGroup.Sample? = member.samples.first
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let sample, pipeline.archive.canPlay(sample.audio) {
                Button {
                    play(sample)
                } label: {
                    if player.loading == key {
                        ProgressView()
                    } else {
                        Image(systemName: player.playing == key ? "stop.circle.fill" : "play.circle")
                    }
                }
                .buttonStyle(.borderless)
            } else {
                Image(systemName: "speaker.slash").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(member.name)（\(member.lines) 行）").font(.caption).foregroundStyle(.secondary)
                if let sample, !sample.text.isEmpty {
                    Text("「\(sample.text)」").font(.callout).lineLimit(2)
                }
            }
        }
    }

    private func play(_ sample: SamePersonGroup.Sample) {
        let audio: String = sample.audio
        Task {
            await player.toggle(key, at: sample.start, until: sample.end) {
                await pipeline.archive.playableURL(for: audio)
            }
        }
    }
}

/// 組の1つ（日・人物N ごとの聞く所・「同じ人」「別の人」）
struct SamePersonGroupRow: View {
    @Environment(Pipeline.self) private var pipeline
    let group: SamePersonGroup
    let player: ClipPlayer
    @State private var working = false
    @State private var note: String?

    /// 見出しの日（日をまたぐ組は「11/10・11/13」）
    private var dayLabel: String {
        guard let days = group.days, days.count >= 2 else { return AppFeeds.monthDay(group.day) }
        var parts: [String] = []
        for d in days { parts.append(AppFeeds.monthDay(d)) }
        return parts.joined(separator: "・")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dayLabel + "　" + group.people.map(\.name).joined(separator: "・"))
                .font(.subheadline.bold())
            if let days = group.days, days.count >= 2 {
                Text("別の日の声どうしです").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(group.people) { member in
                SamePersonMemberLine(member: member, key: "same-" + group.id + "-" + member.id, player: player)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("同じ人") { answer(true) }
                        .buttonStyle(.borderedProminent)
                    Button("別の人") { answer(false) }
                        .buttonStyle(.bordered)
                    if working { ProgressView() }
                }
                .disabled(working)
            }
        }
        .padding(.vertical, 2)
    }

    private func answer(_ same: Bool) {
        player.stop()
        working = true
        Task {
            note = await pipeline.answerSamePerson(group, same: same)
            working = false
        }
    }
}

/// 「◯◯さんかも」の1つ（2026-11-15。強化案 56）。「同じ人」を押したときだけ、その人にまとめる
struct SamePersonMaybeRow: View {
    @Environment(Pipeline.self) private var pipeline
    let item: SamePersonMaybe
    let player: ClipPlayer
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppFeeds.monthDay(item.day) + "　" + item.person.name + "は" + SamePersonRules.maybeTitle(item.namedName))
                .font(.subheadline.bold())
            SamePersonMemberLine(member: item.person, key: "maybe-" + item.id, player: player)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("同じ人") { answer(true) }
                        .buttonStyle(.borderedProminent)
                    Button("別の人") { answer(false) }
                        .buttonStyle(.bordered)
                    if working { ProgressView() }
                }
                .disabled(working)
            }
        }
        .padding(.vertical, 2)
    }

    private func answer(_ same: Bool) {
        player.stop()
        working = true
        Task {
            note = await pipeline.answerSamePersonMaybe(item, same: same)
            working = false
        }
    }
}

/// 「直す」の「同じ人かも」（上から3つと、全部の入口）
struct SamePersonSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()

    var body: some View {
        let list: [SamePersonGroup] = pipeline.samePersonGroups
        let maybes: [SamePersonMaybe] = pipeline.samePersonMaybes
        let total: Int = list.count + maybes.count
        let maybeShown: Int = min(maybes.count, 2)
        let groupShown: Int = max(0, 3 - maybeShown)
        if total > 0 {
            Section {
                ForEach(Array(maybes.prefix(maybeShown))) { item in
                    SamePersonMaybeRow(item: item, player: player)
                }
                ForEach(Array(list.prefix(groupShown))) { group in
                    SamePersonGroupRow(group: group, player: player)
                }
                if total > maybeShown + min(list.count, groupShown) {
                    NavigationLink("同じ人かもをすべて見る（\(total)）") { SamePersonListView() }
                }
            } header: {
                Text("同じ人かも（\(total)）")
            } footer: {
                Text("家の PC が、名前の無い声どうしを声の近さで組にしました（同じ日の組と、別の日にまたがる組）。名前のある人に近い声は「◯◯さんかも」と出します。▶︎で聞いて、同じ人なら「同じ人」を押すとまとめます（まとめた先の人の画面から戻せます）。押すまでは何も変えません。名前は自動では付けません。")
            }
            .onDisappear { player.stop() }
        }
    }
}

/// 「同じ人かも」の全部
struct SamePersonListView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()

    var body: some View {
        let list: [SamePersonGroup] = pipeline.samePersonGroups
        let maybes: [SamePersonMaybe] = pipeline.samePersonMaybes
        List {
            if !maybes.isEmpty {
                Section {
                    ForEach(maybes) { item in
                        SamePersonMaybeRow(item: item, player: player)
                    }
                } header: {
                    Text("名前のある人かも（\(maybes.count)）")
                }
            }
            Section {
                if list.isEmpty && maybes.isEmpty {
                    Text("確かめるものはありません").foregroundStyle(.secondary)
                }
                ForEach(list) { group in
                    SamePersonGroupRow(group: group, player: player)
                }
            } footer: {
                Text("押すまでは何も変えません。「別の人」を押したものは、もう出しません。")
            }
        }
        .navigationTitle("同じ人かも")
        .countsOpen("samePerson")
        .onDisappear { player.stop() }
        .refreshable { await SamePersonBook.shared.refresh(pipeline.homePC, force: true) }
    }
}

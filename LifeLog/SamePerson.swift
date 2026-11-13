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
}

struct SamePersonFeed: Codable, Equatable {
    var generated_at: String? = nil
    var groups: [SamePersonGroup] = []
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
    }

    private struct RawDay: Decodable {
        var day: String?
        var groups: [LossyRow<RawGroup>]?
    }

    private struct RawFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var days: [LossyRow<RawDay>]?
    }

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

    /// 組の1つ。名前の無い「人物N」でない人が1人でも入っていれば、組ごと使わない
    private static func clean(_ raw: RawGroup, day: String) -> SamePersonGroup? {
        guard let id = HomeFeeds.trimmed(raw.id), HomeFeeds.isID(id),
              let score = raw.score, score.isFinite else { return nil }
        var members: [SamePersonGroup.Member] = []
        var ids = Set<String>()
        for row in raw.people ?? [] {
            guard let m = row.value, let mid = HomeFeeds.trimmed(m.id), let name = HomeFeeds.trimmed(m.name),
                  unnamedID(name) == mid, ids.insert(mid).inserted else { return nil }
            var samples: [SamePersonGroup.Sample] = []
            for s in m.samples ?? [] {
                guard let raw = s.value, let sample = clean(raw) else { continue }
                samples.append(sample)
                if samples.count >= sampleLimit { break }
            }
            let lines: Int = max(0, m.lines ?? 0)
            let seconds: Double = max(0, m.seconds ?? 0)
            members.append(SamePersonGroup.Member(id: mid, name: name, lines: lines, seconds: seconds, samples: samples))
        }
        guard memberRange.contains(members.count) else { return nil }
        return SamePersonGroup(id: id, day: day, score: score, people: members)
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
        return SamePersonFeed(generated_at: raw.generated_at, groups: groups)
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
        if let data = try? JSONEncoder().encode(feed) { try? data.write(to: Self.url, options: .atomic) }
    }

    func markAnswered(_ id: String) {
        answered.insert(id)
        if answered.count > Self.answeredLimit {
            let live = Set(groups.map(\.id))
            answered = answered.filter { live.contains($0) }
        }
        UserDefaults.standard.set(Array(answered), forKey: Self.answeredKey)
    }
}

// MARK: - 母艦への答え（POST /feedback）

/// 「使われたか」の答えを母艦へ（共通の約束の POST /feedback {"kind", "id", "value", "day"}。features の "feedback"）。
/// 家の PC がまだ受けないとき・つながらないときは、端末にためて次に送る（300 件まで。古いものから捨てる）。
/// TODO: S1 の MothershipFeeds.swift の送り手が main に入ったら、そちらにまとめる（同じ形・同じ口）。
@MainActor
enum FixFeedback {
    struct Item: Codable, Equatable {
        var kind: String
        var id: String
        var value: String
        var day: String
    }

    static let key = "fixFeedbackPending"
    static let limit = 300
    private static var sending = false

    static func today(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func pending() -> [Item] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [Item]) {
        if let data = try? JSONEncoder().encode(Array(list.suffix(limit))) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// ためる（id は英数字と _ . : - の 64 字まで。合わなければ捨てる）
    static func add(kind: String, id: String, value: String, day: String? = nil) {
        guard HomeFeeds.isID(id) else { return }
        save(pending() + [Item(kind: kind, id: id, value: value, day: day ?? today())])
    }

    /// ためた答えを古い順に送る。1つでも送れなければ、そこでやめる
    static func send(_ pc: HomePC) async {
        guard !sending, pc.features.contains("feedback") else { return }
        sending = true
        defer { sending = false }
        var list = pending()
        while let first = list.first {
            guard let body = try? JSONEncoder().encode(first) else {
                list.removeFirst()
                continue
            }
            do {
                _ = try await pc.postJSONData("feedback", body: body, timeout: 10)
            } catch {
                break
            }
            list.removeFirst()
            save(list)
        }
        save(list)
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

/// 組の1つ（日・人物N ごとの聞く所・「同じ人」「別の人」）
struct SamePersonGroupRow: View {
    @Environment(Pipeline.self) private var pipeline
    let group: SamePersonGroup
    let player: ClipPlayer
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppFeeds.monthDay(group.day) + "　" + group.people.map(\.name).joined(separator: "・"))
                .font(.subheadline.bold())
            ForEach(group.people) { member in
                memberRow(member)
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

    @ViewBuilder
    private func memberRow(_ member: SamePersonGroup.Member) -> some View {
        let sample: SamePersonGroup.Sample? = member.samples.first
        let key = "same-" + group.id + "-" + member.id
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let sample, pipeline.archive.canPlay(sample.audio) {
                Button {
                    Task {
                        await player.toggle(key, at: sample.start, until: sample.end) {
                            await pipeline.archive.playableURL(for: sample.audio)
                        }
                    }
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

    private func answer(_ same: Bool) {
        player.stop()
        working = true
        Task {
            note = await pipeline.answerSamePerson(group, same: same)
            working = false
        }
    }
}

/// 「直す」の「同じ人かも」（上から3組と、全部の入口）
struct SamePersonSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()

    var body: some View {
        let list: [SamePersonGroup] = pipeline.samePersonGroups
        if !list.isEmpty {
            Section {
                ForEach(Array(list.prefix(3))) { group in
                    SamePersonGroupRow(group: group, player: player)
                }
                if list.count > 3 {
                    NavigationLink("同じ人かもをすべて見る（\(list.count)）") { SamePersonListView() }
                }
            } header: {
                Text("同じ人かも（\(list.count)）")
            } footer: {
                Text("家の PC が、同じ日の名前の無い声どうしを声の近さで組にしました。▶︎で聞いて、同じ人なら「同じ人」を押すと、行のいちばん多い「人物N」にまとめます（まとめた先の人の画面から戻せます）。押すまでは何も変えません。名前の付いた人は入りません。")
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
        List {
            Section {
                if list.isEmpty {
                    Text("確かめるものはありません").foregroundStyle(.secondary)
                }
                ForEach(list) { group in
                    SamePersonGroupRow(group: group, player: player)
                }
            } footer: {
                Text("押すまでは何も変えません。「別の人」を押した組は、もう出しません。")
            }
        }
        .navigationTitle("同じ人かも")
        .countsOpen("samePerson")
        .onDisappear { player.stop() }
        .refreshable { await SamePersonBook.shared.refresh(pipeline.homePC, force: true) }
    }
}

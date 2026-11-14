import Foundation
import Observation
import SwiftUI

/// 入れたものが動いて使われているかを見る（2026-11-15。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 2」）。
/// 読む（家の PC の GET。母艦と PC が作った写しを、PC とアプリの両方で確かめる）:
/// - 入れた施策の様子（GET /rollout。features の "rollout"。36）: 歯車→点検「入れた施策の様子」
/// - Claude の費用（GET /costs。"costs"。37）: 歯車→点検「Claude の費用」と、設定の「Claude（家の PC 経由）」の1行
/// - 正しさの抜き取り（GET /checks。"checks"。41）: 直す「合ってる？」。答えは POST /feedback の kind "check"（MothershipOutbox）
/// 写しは端末に置き（同期しない）、家の PC につながらないときも前の写しを見せる。中身の文は記録（ログ）に書かない。

// MARK: - 読んだ形

struct RolloutItem: Codable, Equatable, Identifiable {
    var no: Int
    var title: String
    var first_live: String? = nil
    var last_live: String? = nil
    var uses_7d: Int? = nil
    var evidence: String = ""
    /// live・unused・not_started・broken・retire_candidate
    var status: String
    var id: Int { no }
}

struct RolloutFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [RolloutItem] = []
}

struct CheckItem: Codable, Equatable, Identifiable {
    var id: String
    var day: String
    /// digest・proposal・promise・weekly
    var source: String
    var claim: String
    var evidence: String = ""
}

struct ChecksFeed: Codable, Equatable {
    var generated_at: String? = nil
    var items: [CheckItem] = []
}

struct CostToday: Codable, Equatable, Identifiable {
    var purpose: String
    var usd: Double
    var cap: Double? = nil
    var stopped: Bool = false
    var id: String { purpose }

    /// 今日の上限に届いたか
    var capped: Bool {
        guard let cap else { return false }
        return usd >= cap
    }
}

struct CostPurpose: Codable, Equatable, Identifiable {
    var purpose: String
    var usd: Double
    var calls: Int
    var id: String { purpose }
}

struct CostsFeed: Codable, Equatable {
    var month: String
    var month_usd: Double
    var projected_usd: Double
    var monthly_usd: Double
    var today: [CostToday] = []
    var month_by_purpose: [CostPurpose] = []
}

// MARK: - 確かめ方（決まった入力から決まった出力だけ）

enum SettleFeeds {
    static let rolloutStatuses: [String] = ["broken", "retire_candidate", "unused", "not_started", "live"]
    static let checkSources: [String] = ["digest", "proposal", "promise", "weekly"]
    static let checkValues: [String] = ["right", "wrong", "unsure"]
    static let rolloutLimit = 80
    static let checkLimit = 7

    private struct RawRolloutFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawRollout>]?
    }

    private struct RawRollout: Decodable {
        var no: Int?
        var title: String?
        var first_live: String?
        var last_live: String?
        var uses_7d: Int?
        var evidence: String?
        var status: String?
    }

    private struct RawChecksFeed: Decodable {
        var available: Bool?
        var generated_at: String?
        var items: [LossyRow<RawCheck>]?
    }

    private struct RawCheck: Decodable {
        var id: String?
        var day: String?
        var source: String?
        var claim: String?
        var evidence: String?
    }

    private struct RawCostsFeed: Decodable {
        var available: Bool?
        var month: String?
        var month_usd: Double?
        var projected_usd: Double?
        var monthly_usd: Double?
        var today: [LossyRow<RawToday>]?
        var month_by_purpose: [LossyRow<RawPurpose>]?
    }

    private struct RawToday: Decodable {
        var purpose: String?
        var usd: Double?
        var cap: Double?
        var stopped: Bool?
    }

    private struct RawPurpose: Decodable {
        var purpose: String?
        var usd: Double?
        var calls: Int?
    }

    private static func day(_ text: String?) -> String? {
        guard let t = HomeFeeds.trimmed(text), HomeFeeds.isDay(t) else { return nil }
        return t
    }

    private static func money(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value < 1_000_000 else { return nil }
        return value
    }

    /// GET /rollout の答え。番号・状態・題の無い行と同じ番号は落とす。番号の順
    static func decodeRollout(_ data: Data) -> RolloutFeed? {
        guard let raw = try? JSONDecoder().decode(RawRolloutFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<Int>()
        var items: [RolloutItem] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let no = r.no, no >= 1, let status = r.status, rolloutStatuses.contains(status),
                  let title = MothershipFeeds.cut(r.title, 40), seen.insert(no).inserted else { continue }
            var uses: Int?
            if let u = r.uses_7d, u >= 0 { uses = u }
            items.append(RolloutItem(no: no, title: title, first_live: day(r.first_live), last_live: day(r.last_live),
                                     uses_7d: uses, evidence: MothershipFeeds.cut(r.evidence, 80) ?? "", status: status))
            if items.count >= rolloutLimit { break }
        }
        items.sort { $0.no < $1.no }
        return RolloutFeed(generated_at: raw.generated_at, items: items)
    }

    /// GET /checks の答え。7つまで・新しい日から
    static func decodeChecks(_ data: Data) -> ChecksFeed? {
        guard let raw = try? JSONDecoder().decode(RawChecksFeed.self, from: data), raw.available != false else { return nil }
        var seen = Set<String>()
        var items: [CheckItem] = []
        for row in raw.items ?? [] {
            guard let r = row.value, let id = r.id, HomeFeeds.isID(id), let d = day(r.day), let source = r.source,
                  checkSources.contains(source), let claim = MothershipFeeds.cut(r.claim, 120),
                  seen.insert(id).inserted else { continue }
            items.append(CheckItem(id: id, day: d, source: source, claim: claim, evidence: MothershipFeeds.cut(r.evidence, 120) ?? ""))
            if items.count >= checkLimit { break }
        }
        items.sort { $0.day > $1.day }
        return ChecksFeed(generated_at: raw.generated_at, items: items)
    }

    /// GET /costs の答え。額の読めないものは落とす
    static func decodeCosts(_ data: Data) -> CostsFeed? {
        guard let raw = try? JSONDecoder().decode(RawCostsFeed.self, from: data), raw.available != false,
              MothershipFeeds.isMonth(raw.month), let month = raw.month, let spent = money(raw.month_usd),
              let cap = money(raw.monthly_usd) else { return nil }
        var feed = CostsFeed(month: month, month_usd: spent, projected_usd: money(raw.projected_usd) ?? spent, monthly_usd: cap)
        for row in raw.today ?? [] {
            guard let r = row.value, let purpose = MothershipFeeds.cut(r.purpose, 40), let usd = money(r.usd) else { continue }
            feed.today.append(CostToday(purpose: purpose, usd: usd, cap: money(r.cap), stopped: r.stopped ?? false))
        }
        for row in raw.month_by_purpose ?? [] {
            guard let r = row.value, let purpose = MothershipFeeds.cut(r.purpose, 40), let usd = money(r.usd) else { continue }
            feed.month_by_purpose.append(CostPurpose(purpose: purpose, usd: usd, calls: max(0, r.calls ?? 0)))
        }
        return feed
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "live": return "動いている"
        case "unused": return "使われていない"
        case "not_started": return "まだ動いていない"
        case "broken": return "止まっている"
        case "retire_candidate": return "畳む候補"
        default: return status
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "live": return .green
        case "broken": return .red
        case "retire_candidate": return .orange
        case "unused": return .yellow
        default: return .secondary
        }
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "digest": return "朝のまとめ"
        case "proposal": return "提案"
        case "promise": return "約束"
        case "weekly": return "週のふり返り"
        default: return source
        }
    }

    /// 状態ごとの数（「動いている 20・使われていない 5」。0 は出さない）
    static func statusSummary(_ items: [RolloutItem]) -> String {
        var parts: [String] = []
        for status in rolloutStatuses.reversed() {
            var n = 0
            for item in items where item.status == status { n += 1 }
            if n > 0 { parts.append(statusLabel(status) + " \(n)") }
        }
        return parts.joined(separator: "・")
    }

    /// 「今月 $12.40・月末の見込み $48.00（上限 $100）」
    static func costLine(_ c: CostsFeed) -> String {
        let spent: String = ClaudeUsage.dollars(c.month_usd)
        let projected: String = ClaudeUsage.dollars(c.projected_usd)
        let cap: String = ClaudeUsage.dollars(c.monthly_usd, whole: true)
        return "今月 " + spent + "・月末の見込み " + projected + "（上限 " + cap + "）"
    }

    /// 今日の多い用途（0 は出さない。多い順に limit まで）
    static func topToday(_ c: CostsFeed, limit: Int = 3) -> [CostToday] {
        var used: [CostToday] = []
        for row in c.today where row.usd > 0 { used.append(row) }
        used.sort { $0.usd != $1.usd ? $0.usd > $1.usd : $0.purpose < $1.purpose }
        return Array(used.prefix(limit))
    }

    /// 「見出し $0.30・誤変換の直し $0.20」
    static func topTodayText(_ c: CostsFeed) -> String {
        var parts: [String] = []
        for row in topToday(c) { parts.append(ClaudeJob.label(row.purpose) + " " + ClaudeUsage.dollars(row.usd)) }
        return parts.joined(separator: "・")
    }

    /// 止めた用途と、今日の上限に届いた用途の名前
    static func offNames(_ c: CostsFeed) -> (stopped: [String], capped: [String]) {
        var stopped: [String] = []
        var capped: [String] = []
        for row in c.today {
            if row.stopped {
                stopped.append(ClaudeJob.label(row.purpose))
            } else if row.capped {
                capped.append(ClaudeJob.label(row.purpose))
            }
        }
        return (stopped, capped)
    }

    /// 今日「合ってる？」に出す1つ（まだ答えていないもののうち、いちばん新しい日の）
    static func nextCheck(_ items: [CheckItem], answered: (String) -> Bool) -> CheckItem? {
        for item in items where !answered(item.id) { return item }
        return nil
    }
}

// MARK: - 読み込み

@MainActor
@Observable
final class SettleBook {
    static let shared = SettleBook()

    private(set) var rollout: RolloutFeed?
    private(set) var checks: [CheckItem] = []
    private(set) var costs: CostsFeed?
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var fetching = false

    private static let every: TimeInterval = 30 * 60
    static let rolloutFile = "mfeed-rollout.json"
    static let checksFile = "mfeed-checks.json"
    static let costsFile = "mfeed-costs.json"

    private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(name)
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    init() {
        rollout = Self.read(RolloutFeed.self, Self.rolloutFile)
        checks = Self.read(ChecksFeed.self, Self.checksFile)?.items ?? []
        costs = Self.read(CostsFeed.self, Self.costsFile)
    }

    /// 読み直す（force でなければ30分に1回まで）。読めなかった写しは前のまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.isConfigured else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        if pc.features.contains("rollout"), let body = try? await pc.appFeed("rollout", feature: "rollout"),
           let feed = SettleFeeds.decodeRollout(body) {
            rollout = feed
            Self.write(feed, Self.rolloutFile)
        }
        if pc.features.contains("checks"), let body = try? await pc.appFeed("checks", feature: "checks"),
           let feed = SettleFeeds.decodeChecks(body) {
            checks = feed.items
            Self.write(feed, Self.checksFile)
        }
        await refreshCosts(pc)
    }

    /// 費用だけ読み直す（画面を開いたとき）
    func refreshCosts(_ pc: HomePC) async {
        guard pc.features.contains("costs"), let body = try? await pc.appFeed("costs", feature: "costs"),
              let feed = SettleFeeds.decodeCosts(body) else { return }
        costs = feed
        Self.write(feed, Self.costsFile)
    }
}

// MARK: - 画面: 点検（36・37）

/// 歯車→点検の「入れた施策の様子」「Claude の費用」（写しがあるときだけ）
struct SettleCheckSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = SettleBook.shared
        if book.rollout != nil || book.costs != nil {
            Section {
                if let rollout = book.rollout {
                    NavigationLink {
                        RolloutView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("入れた施策の様子")
                            Text(SettleFeeds.statusSummary(rollout.items)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let costs = book.costs {
                    NavigationLink {
                        CostsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude の費用")
                            Text(SettleFeeds.costLine(costs)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("入れたものとお金")
            } footer: {
                Text("家の PC（母艦）が毎朝数えた、入れた施策が本番で動いた日・使われた回数と、Claude に使った額です。畳むかどうかは自分で決めます。")
            }
        }
    }
}

/// 入れた施策の様子（状態ごと。止まっている・畳む候補を先に）
struct RolloutView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let items: [RolloutItem] = SettleBook.shared.rollout?.items ?? []
        List {
            if items.isEmpty {
                Text("まだ写しがありません。家の PC につながると読みます。").foregroundStyle(.secondary)
            }
            ForEach(SettleFeeds.rolloutStatuses, id: \.self) { status in
                let rows: [RolloutItem] = items.filter { $0.status == status }
                if !rows.isEmpty {
                    Section(SettleFeeds.statusLabel(status) + "（\(rows.count)）") {
                        ForEach(rows) { item in
                            RolloutRow(item: item)
                        }
                    }
                }
            }
            if let at = SettleBook.shared.rollout?.generated_at, !at.isEmpty {
                Section {
                    Text("作った時刻: " + at).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("入れた施策の様子")
        .countsOpen("rollout")
        .refreshable { await SettleBook.shared.refresh(pipeline.homePC, force: true) }
    }
}

struct RolloutRow: View {
    let item: RolloutItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(item.no). " + item.title)
                Spacer(minLength: 4)
                Text(SettleFeeds.statusLabel(item.status))
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SettleFeeds.statusColor(item.status).opacity(0.2), in: Capsule())
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if !item.evidence.isEmpty {
                Text(item.evidence).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let uses = item.uses_7d { parts.append("7日で \(uses) 回") }
        if let first = item.first_live { parts.append("初めて動いた日 " + first) }
        if let last = item.last_live { parts.append("最後 " + last) }
        return parts.isEmpty ? "まだ本番で動いた記録がありません" : parts.joined(separator: "・")
    }
}

/// Claude の費用（今月・見込み・今日の用途・今月の用途）
struct CostsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        List {
            if let costs = SettleBook.shared.costs {
                Section {
                    LabeledContent("今月（" + costs.month + "）", value: ClaudeUsage.dollars(costs.month_usd))
                    LabeledContent("月末の見込み", value: ClaudeUsage.dollars(costs.projected_usd))
                    LabeledContent("月の上限", value: ClaudeUsage.dollars(costs.monthly_usd, whole: true))
                } footer: {
                    Text("見込みは、今月ここまでの額を過ぎた日数で割り、月の日数を掛けたものです（仮の目安）。")
                }
                Section("今日") {
                    if costs.today.isEmpty {
                        Text("今日はまだ使っていません。").foregroundStyle(.secondary)
                    }
                    ForEach(costs.today) { row in
                        CostTodayRow(row: row)
                    }
                }
                Section("今月の用途") {
                    ForEach(costs.month_by_purpose) { row in
                        LabeledContent(ClaudeJob.label(row.purpose) + "（\(row.calls) 回）", value: ClaudeUsage.dollars(row.usd))
                            .font(.callout)
                    }
                }
            } else {
                Text("まだ写しがありません。家の PC につながると読みます。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Claude の費用")
        .countsOpen("claudeCosts")
        .task { await SettleBook.shared.refreshCosts(pipeline.homePC) }
        .refreshable { await SettleBook.shared.refreshCosts(pipeline.homePC) }
    }
}

struct CostTodayRow: View {
    let row: CostToday

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(ClaudeJob.label(row.purpose), value: ClaudeUsage.dollars(row.usd))
            if let note = note {
                let color: Color = row.stopped || row.capped ? Color.orange : Color.secondary
                Text(note).font(.caption).foregroundStyle(color)
            }
        }
    }

    private var note: String? {
        if row.stopped { return "止めてあります（家の PC の設定）" }
        guard let cap = row.cap else { return nil }
        let text: String = "1日の上限 " + ClaudeUsage.dollars(cap)
        return row.capped ? text + "に届いたので、今日はもう頼みません" : text
    }
}

/// 設定の「Claude（家の PC 経由）」に出す行（今月・見込み・今日の多い用途・止めた用途）
struct ClaudeCostRows: View {
    let costs: CostsFeed

    var body: some View {
        Text(SettleFeeds.costLine(costs)).font(.caption)
        let top: String = SettleFeeds.topTodayText(costs)
        if !top.isEmpty {
            Text("今日の多い用途: " + top).font(.caption).foregroundStyle(.secondary)
        }
        let off = SettleFeeds.offNames(costs)
        if !off.stopped.isEmpty {
            Text("止めてある用途: " + off.stopped.joined(separator: "・")).font(.caption).foregroundStyle(.secondary)
        }
        if !off.capped.isEmpty {
            Text("今日の上限に届いた用途: " + off.capped.joined(separator: "・")).font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - 画面: 直す「合ってる？」（41）

/// 母艦のまとめ・提案・約束・週のふり返りから1日1つ、確かめられる主張。押した答えを母艦に返す（POST /feedback の kind "check"）
struct CheckClaimSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let feeds = pipeline.mothershipFeeds
        let item: CheckItem? = SettleFeeds.nextCheck(SettleBook.shared.checks) { id in feeds.voted("check", id: id) != nil }
        if let item {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.claim)
                    if !item.evidence.isEmpty {
                        Text("根拠: " + item.evidence).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(SettleFeeds.sourceLabel(item.source) + "・" + item.day).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("合ってる") { answer(item, "right") }
                    Button("違う") { answer(item, "wrong") }
                    Button("わからない") { answer(item, "unsure") }
                }
                .buttonStyle(.bordered)
                .font(.callout)
            } header: {
                Text("合ってる？")
            } footer: {
                Text("家の PC（母艦）が書いたことが合っているかを、1日1つ確かめます。答えは母艦の「精度の通信簿」に入ります。")
            }
        }
    }

    private func answer(_ item: CheckItem, _ value: String) {
        pipeline.mothershipFeeds.vote("check", id: item.id, value: value, day: item.day)
        Task { await pipeline.mothershipFeeds.sendOutbox(pipeline.homePC) }
    }
}

extension Pipeline {
    /// 「直す」の数に入れる「合ってる？」（まだ答えていない抜き取りがあれば 1）
    var pendingCheckCount: Int {
        let feeds = mothershipFeeds
        return SettleFeeds.nextCheck(SettleBook.shared.checks) { id in feeds.voted("check", id: id) != nil } == nil ? 0 : 1
    }
}

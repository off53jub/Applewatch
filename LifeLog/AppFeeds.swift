import Foundation
import Observation
import SwiftUI
import UserNotifications

/// 母艦が作る3つの「アプリ向けの写し」を家の PC から読む（2026-11-12）。
/// - 自分の声の候補（GET /self-candidates。features の "selfcand"）: 職場の録音で、自分が話していそうな場面。
///   本人が「自分の声」を押したときだけ、声を覚えて、その行を「自分」に直す（SelfCandidatesView）。
/// - 新しさ（GET /freshness。"fresh"）: LINE 取得や PLAUD などの自動取得が止まっていないか。止まったら1回だけ知らせる。
/// - PLAUD との差（GET /plaud-gap。"plaudgap"）: アプリの文字起こしと PLAUD の文字起こしの差。朝の知らせと自己点検に出す。
/// アプリは読んで見せるだけ。写しは端末に置き、家の PC につながらないときも見せる（新しいファイル。同期しない）。
/// 中身の文は記録（ログ）に書かない。

// MARK: - 読んだ形（家の PC が型と長さを確かめてから渡す）

struct SelfCandidate: Codable, Identifiable, Equatable {
    var id: String
    var day: String
    /// 区切りの音声のファイル名（記録の行の audio と同じ）
    var audio: String
    /// その音声の中での位置（秒）
    var start: Double
    var end: Double
    var text: String
    var score: Double
    /// "plaud-match"（PLAUD の文と突き合わせて見つけた）・"plaud-most-talk"（その時間帯でいちばん話していた）
    var why: String
    /// 母艦が「本人が見ればほぼ必ず OK する」と印を付けたもの（施策 14。省ける。true のときだけ入る）
    var sure: Bool? = nil
    var sure_why: String? = nil
}

struct SelfCandidateFeed: Codable, Equatable {
    var available: Bool
    var generated_at: String? = nil
    var items: [SelfCandidate]? = nil
    var reason: String? = nil
}

struct FreshItem: Codable, Identifiable, Equatable {
    var key: String
    var label: String
    /// 最後にうまくいった時刻（ISO8601。一度も無ければ nil）
    var last_ok: String? = nil
    var limit_hours: Double
    var stale: Bool
    var note: String? = nil
    var id: String { key }
}

struct FreshnessFeed: Codable, Equatable {
    var available: Bool
    var generated_at: String? = nil
    var items: [FreshItem]? = nil
    var reason: String? = nil
}

struct PlaudGapDay: Codable, Identifiable, Equatable {
    struct Gap: Codable, Equatable {
        var from: String
        var to: String
    }
    var day: String
    var source: String? = nil
    var app_chars: Int? = nil
    var plaud_chars: Int? = nil
    var ratio: Double? = nil
    var gaps: [Gap]? = nil
    var misheard: [String]? = nil
    var score: Double? = nil
    var id: String { day }
}

struct PlaudGapFeed: Codable, Equatable {
    var available: Bool
    var generated_at: String? = nil
    var days: [PlaudGapDay]? = nil
    /// PLAUD の公式の文字起こしがまだ届いていない日（yyyy-MM-dd）
    var missing_official: [String]? = nil
    var reason: String? = nil
}

// MARK: - 見せ方・選び方（確かめられるよう、決まった入力から決まった出力だけにした）

enum AppFeeds {
    /// 新しさの知らせの識別子の頭
    static let noticePrefix = "fresh-"

    /// 「止まっているかも」を知らせる相手と、知らせ済みとして覚えておく印。
    /// 止まっている項目で、まだ知らせていないものだけを知らせる。戻った（止まっていない）項目は印を消し、また止まったら知らせ直す。
    nonisolated static func staleToNotify(_ items: [FreshItem], notified: Set<String>) -> (notify: [FreshItem], remember: Set<String>) {
        let staleKeys = Set(items.filter(\.stale).map(\.key))
        let fresh = items.filter { $0.stale && !notified.contains($0.key) }
        return (fresh, notified.intersection(staleKeys).union(fresh.map(\.key)))
    }

    /// ISO8601 の時刻を読む（秒の端数・時差の有る無しのどちらでも）
    nonisolated static func parseTime(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = format
            if let date = f.date(from: text) { return date }
        }
        return nil
    }

    /// 「11/4 07:00」
    nonisolated static func shortTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = timeZone
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }

    /// 「止まっているかも: LINE取得（最後 11/4 07:00）」
    nonisolated static func freshLine(_ item: FreshItem, timeZone: TimeZone = .current) -> String {
        let last = parseTime(item.last_ok).map { "最後 " + shortTime($0, timeZone: timeZone) } ?? "まだ動いた記録がありません"
        return "止まっているかも: \(item.label)（\(last)）"
    }

    /// 日の表し方「11/8」
    nonisolated static func monthDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return day }
        return "\(m)/\(d)"
    }

    /// 「PLAUD の文字起こしがまだの日: 11/8・11/9」。無ければ nil。古い日から、多いときは新しい4日と「ほか」
    nonisolated static func missingOfficialLine(_ days: [String]?) -> String? {
        let sorted = Array(Set(days ?? [])).sorted()
        guard !sorted.isEmpty else { return nil }
        let shown = sorted.suffix(4).map(monthDay).joined(separator: "・")
        return "PLAUD の文字起こしがまだの日: " + shown + (sorted.count > 4 ? " ほか\(sorted.count - 4)日" : "")
    }

    /// 点のある、いちばん新しい日
    nonisolated static func latestScored(_ feed: PlaudGapFeed?) -> PlaudGapDay? {
        (feed?.days ?? []).filter { $0.score != nil }.max { $0.day < $1.day }
    }

    /// 「PLAUD との合い方（11/9）: 72点」
    nonisolated static func latestScoreLine(_ feed: PlaudGapFeed?) -> String? {
        guard let day = latestScored(feed), let score = day.score else { return nil }
        return "PLAUD との合い方（\(monthDay(day.day))）: \(Int(score.rounded()))点"
    }

    /// 朝の知らせに足す行（無ければ空）
    nonisolated static func briefLines(_ feed: PlaudGapFeed?) -> [String] {
        [missingOfficialLine(feed?.missing_official), latestScoreLine(feed)].compactMap { $0 }
    }

    /// 自己点検の成績表の行（新しい日から7日まで）。点があれば「72点・抜け 3か所」
    nonisolated static func gapRows(_ feed: PlaudGapFeed?, limit: Int = 7) -> [(label: String, value: String, ok: Bool?)] {
        let days = (feed?.days ?? []).sorted { $0.day > $1.day }.prefix(limit)
        return days.map { day in
            var parts: [String] = []
            if let score = day.score { parts.append("\(Int(score.rounded()))点") }
            parts.append("抜け \(day.gaps?.count ?? 0) か所")
            if let ratio = day.ratio, ratio > 0 { parts.append("PLAUD に対して文字数 \(Int((ratio * 100).rounded()))%") }
            return (label: monthDay(day.day), value: parts.joined(separator: "・"), ok: day.score.map { $0 >= 60 })
        }
    }

    /// 候補に当たる記録の行を探す。同じ音声で、行の位置が候補の始まりにいちばん近いもの（tolerance 秒以内）。
    nonisolated static func bestLineIndex(audio: String, start: Double, in lines: [(audio: String?, offset: TimeInterval?)],
                                          tolerance: Double = 6) -> Int? {
        var best: (index: Int, gap: Double)?
        for (i, line) in lines.enumerated() {
            guard line.audio == audio, let offset = line.offset else { continue }
            let gap = abs(offset - start)
            if gap <= tolerance, best == nil || gap < best!.gap { best = (i, gap) }
        }
        return best?.index
    }

    /// 音声の名前の頭（録音の開始時刻）と候補の位置から、その場面のおよその時刻「11/10 17:17」。読めなければ nil
    static func clock(of candidate: SelfCandidate, timeZone: TimeZone = .current) -> String? {
        guard let base = Storage.startDate(of: URL(fileURLWithPath: candidate.audio)) else { return nil }
        return shortTime(base.addingTimeInterval(candidate.start), timeZone: timeZone)
    }

    /// 「違う」を押した候補と、確かめ済みの候補を除いて、点の高い順に
    nonisolated static func visible(_ items: [SelfCandidate], hidden: Set<String>) -> [SelfCandidate] {
        items.filter { !hidden.contains($0.id) }.sorted { $0.score > $1.score }
    }

    /// 1日に確かめる数（「精10」。2026-11-13。60件を一度に出さない）
    static let dailyCount = 10

    /// 今日の10件。その日はじめて見たときに、まだ答えていない候補を点の高い順に選び、その日は入れ替えない
    /// （答えても11件目は出てこない）。saved は "yyyy-MM-dd|id,id,…"。今日の分が空のまま候補が届いたら選び直す。
    /// 返すのは今日の10件の id と、覚えておく文
    nonisolated static func dailyTen(_ visible: [SelfCandidate], saved: String?, day: String,
                                     count: Int = dailyCount) -> (ids: [String], save: String) {
        if let saved, saved.hasPrefix(day + "|") {
            let ids = saved.dropFirst(day.count + 1).split(separator: ",").map(String.init)
            if !ids.isEmpty || visible.isEmpty { return (ids, saved) }
        }
        let ids = visible.prefix(count).map(\.id)
        return (ids, day + "|" + ids.joined(separator: ","))
    }

    /// 朝の知らせに足す1行（まだ答えていない候補があるときだけ）
    nonisolated static func tenBriefLine(visible: Int) -> String? {
        guard visible > 0 else { return nil }
        return "職場の自分の声を\(min(visible, dailyCount))件確かめる（「直す」から）"
    }
}

// MARK: - 読み込み

@MainActor
@Observable
final class AppFeedsBook {
    private(set) var candidates: [SelfCandidate] = []
    private(set) var freshness: [FreshItem] = []
    private(set) var plaudGap: PlaudGapFeed?
    private(set) var fetchedAt: Date?
    /// 「違う」「確かめ済み」にした候補の id
    private(set) var hidden: Set<String>
    @ObservationIgnored private var fetching = false

    private static let every: TimeInterval = 30 * 60
    private static let hiddenKey = "selfCandidatesHidden"
    private static let notifiedKey = "freshnessNotified"
    private static let hiddenLimit = 1000
    /// 今日の10件（"yyyy-MM-dd|id,id,…"）
    static let tenKey = "selfCandidatesTen"

    private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("app-feed-\(name).json")
    }

    init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.url("selfcand")), let feed = try? decoder.decode(SelfCandidateFeed.self, from: data) {
            candidates = feed.items ?? []
        }
        if let data = try? Data(contentsOf: Self.url("fresh")), let feed = try? decoder.decode(FreshnessFeed.self, from: data) {
            freshness = feed.items ?? []
        }
        if let data = try? Data(contentsOf: Self.url("plaudgap")) { plaudGap = try? decoder.decode(PlaudGapFeed.self, from: data) }
    }

    /// 見せる候補（点の高い順）
    var visibleCandidates: [SelfCandidate] { AppFeeds.visible(candidates, hidden: hidden) }
    var staleItems: [FreshItem] { freshness.filter(\.stale) }

    /// 今日の10件の id（その日はじめて見たときに選んで覚える。2026-11-13）
    func todayTen(now: Date = .now) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let saved = UserDefaults.standard.string(forKey: Self.tenKey)
        let plan = AppFeeds.dailyTen(visibleCandidates, saved: saved, day: f.string(from: now))
        if plan.save != saved { UserDefaults.standard.set(plan.save, forKey: Self.tenKey) }
        return plan.ids
    }

    /// 今日の10件のうち、まだ答えていないもの（点の高い順）
    func todayTenLeft(now: Date = .now) -> [SelfCandidate] {
        let ids = Set(todayTen(now: now))
        return visibleCandidates.filter { ids.contains($0.id) }
    }

    /// 「違う」「確かめ済み」。もう出さない
    func hide(_ id: String) {
        hidden.insert(id)
        var list = Array(hidden)
        if list.count > Self.hiddenLimit {
            // いま候補にあるものを優先して残す
            let live = Set(candidates.map(\.id))
            list = list.filter { live.contains($0) }
            hidden = Set(list)
        }
        UserDefaults.standard.set(Array(hidden), forKey: Self.hiddenKey)
    }

    /// 家の PC から読み直す（force でなければ30分に1回まで）。読めなかった写しは前のまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching else { return }
        guard pc.features.contains("selfcand") || pc.features.contains("fresh") || pc.features.contains("plaudgap") else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        let decoder = JSONDecoder()
        if pc.features.contains("selfcand"), let body = try? await pc.appFeed("self-candidates", feature: "selfcand"),
           let feed = try? decoder.decode(SelfCandidateFeed.self, from: body), feed.available {
            candidates = feed.items ?? []
            try? body.write(to: Self.url("selfcand"), options: .atomic)
        }
        if pc.features.contains("plaudgap"), let body = try? await pc.appFeed("plaud-gap", feature: "plaudgap"),
           let feed = try? decoder.decode(PlaudGapFeed.self, from: body), feed.available {
            plaudGap = feed
            try? body.write(to: Self.url("plaudgap"), options: .atomic)
        }
        if pc.features.contains("fresh"), let body = try? await pc.appFeed("freshness", feature: "fresh"),
           let feed = try? decoder.decode(FreshnessFeed.self, from: body), feed.available {
            freshness = feed.items ?? []
            try? body.write(to: Self.url("fresh"), options: .atomic)
            await notifyStale()
        }
    }

    /// 止まっている項目を、止まるたびに1回だけ知らせる（戻るまで同じ項目は知らせない）
    private func notifyStale() async {
        let notified = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
        let plan = AppFeeds.staleToNotify(freshness, notified: notified)
        UserDefaults.standard.set(Array(plan.remember), forKey: Self.notifiedKey)
        guard !plan.notify.isEmpty else { return }
        for item in plan.notify {
            let content = UNMutableNotificationContent()
            content.title = "止まっているかも"
            content.body = AppFeeds.freshLine(item).replacingOccurrences(of: "止まっているかも: ", with: "")
            content.sound = .default
            // 1時間に3通を超えたら1通にまとめる（2026-11-15。強化案 44。NoticeGate.swift）
            NoticeGate.add(UNNotificationRequest(
                identifier: AppFeeds.noticePrefix + item.key, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        }
    }
}

// MARK: - 自分の声を覚えて、行を直す

extension Pipeline {
    /// 本人が「自分の声」を押した候補を、自分の声として覚え、その行を「自分」に直す。返すのは画面に出す一文。
    /// 声を覚えるのは、このボタンを押したときだけ。記録の行が見つからなければ、声だけ覚える。
    func confirmSelfCandidate(_ candidate: SelfCandidate) async -> String {
        await speakers.ensureSelf()
        // 日をまたぐ会話は前の日に入っているので、前の日も探す
        var lines: [ConversationLog.Line] = []
        for day in [Self.previousDay(of: candidate.day), candidate.day].compactMap({ $0 }) {
            for c in conversations(on: day) { lines += c.lines }
        }
        let keys: [(audio: String?, offset: TimeInterval?)] = lines.map { ($0.audio, $0.offset) }
        if let i = AppFeeds.bestLineIndex(audio: candidate.audio, start: candidate.start, in: keys) {
            // 候補の範囲（start〜end 秒）を教えるため、位置だけを候補に合わせた写しを渡す（直す行の見つけ方は変わらない）
            var probe = lines[i]
            probe.offset = candidate.start
            var next = lines[i]
            next.offset = candidate.end
            let found = await archive.playableURL(for: candidate.audio)
            let playable = found != nil
            await fixSpeaker(of: probe, next: next, to: SpeakerLabeler.selfID, scope: .line)
            return playable ? "自分の声として覚え、その行を「自分」に直しました。"
                            : "音声がこの端末にないので、行の名前だけ「自分」に直しました。"
        }
        guard let url = await archive.playableURL(for: candidate.audio) else {
            return "記録の行も音声も見つかりませんでした。"
        }
        try? await speakers.teach(url, from: candidate.start, to: max(candidate.end, candidate.start + 1), personID: SpeakerLabeler.selfID)
        return "記録の行は見つからなかったので、自分の声として覚えただけです。"
    }

    /// 前の日 "yyyy-MM-dd"
    nonisolated static func previousDay(of day: String) -> String? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day), let before = f.calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
        return f.string(from: before)
    }
}

// MARK: - 画面

/// 職場の自分の声の確認。母艦が見つけた「自分が話していそうな場面」を、▶︎で聞いて「自分の声」か「違う」かを答える。
struct SelfCandidatesView: View {
    @Environment(Pipeline.self) private var pipeline
    /// 出す候補を絞る（「直す」の「今日の10件」。nil なら全部）
    var only: [String]? = nil
    @State private var player = ClipPlayer()
    @State private var working: String?
    @State private var results: [String: String] = [:]

    var body: some View {
        let book = pipeline.appFeeds
        // まとめて OK（施策 14）: 母艦が sure の印を付けた、まだ答えていない候補
        let sure: [SelfCandidate] = book.candidates.filter { c in
            (only?.contains(c.id) ?? true) && !book.hidden.contains(c.id) && c.sure == true
        }
        List {
            if !sure.isEmpty {
                Section {
                    BulkOKRow(count: sure.count, what: "職場の自分の声",
                              effect: "1件ずつ「自分の声」を押したのと同じように、その場面を自分の声として覚え、記録の行を「自分」に直します。") {
                        player.stop()
                        let done = await pipeline.bulkConfirmSelf(sure)
                        for (id, message) in done { results[id] = message }
                        return "\(done.count) 件を「自分の声」にしました。"
                    }
                } footer: {
                    Text("母艦が「ほぼ確か」と印を付けたものだけです。迷うものは下で1件ずつ確かめてください。")
                }
            }
            Section {
                // 答えた行は、答えの一文を見せるため、この画面を開いているあいだは残す
                let shown = book.candidates.filter { only?.contains($0.id) ?? true }
                    .filter { !book.hidden.contains($0.id) || results[$0.id] != nil }
                    .sorted { $0.score > $1.score }
                ForEach(shown) { item in
                    row(item)
                }
                if shown.isEmpty {
                    Text("確かめるものはありません").foregroundStyle(.secondary)
                }
            } footer: {
                Text("PLAUD の文字起こしと突き合わせて、自分が話していそうな場面を家の PC が見つけました。▶︎で聞いて、自分の声なら「自分の声」を押してください。その場面を自分の声として覚え、記録の行も「自分」に直します。押すまでは何も変えません。違うときは「違う」を押すと、もう出しません。")
            }
        }
        .navigationTitle(only == nil ? "職場の自分の声の確認" : "職場の自分の声（今日の10件）")
        .refreshable { await book.refresh(pipeline.homePC, force: true) }
        .task { await book.refresh(pipeline.homePC) }
    }

    @ViewBuilder
    private func row(_ item: SelfCandidate) -> some View {
        let key = "selfcand-\(item.id)"
        let playable = pipeline.archive.canPlay(item.audio)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppFeeds.clock(of: item) ?? AppFeeds.monthDay(item.day)).font(.caption).foregroundStyle(.secondary)
                Text(item.why == "plaud-match" ? "PLAUD と文が合った場面" : "いちばん話していた場面")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !item.text.isEmpty { Text("「\(item.text)」").lineLimit(3) }
            if item.sure == true {
                Text(NightReviewRules.sureLabel(item.sure_why))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if playable {
                Button {
                    Task {
                        await player.toggle(key, at: item.start, until: item.end) {
                            await pipeline.archive.playableURL(for: item.audio)
                        }
                    }
                } label: {
                    if player.loading == key {
                        ProgressView()
                    } else {
                        Label(player.playing == key ? "止める" : "聞く", systemImage: player.playing == key ? "stop.circle.fill" : "play.circle")
                    }
                }
                .buttonStyle(.borderless)
            } else {
                Text("音声がこの端末にありません").font(.caption).foregroundStyle(.secondary)
            }
            if let result = results[item.id] {
                Text(result).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("自分の声") { confirm(item) }
                        .buttonStyle(.borderedProminent)
                    Button("違う") {
                        player.stop()
                        pipeline.appFeeds.hide(item.id)
                    }
                    .buttonStyle(.bordered)
                    if working == item.id { ProgressView() }
                }
                .disabled(working != nil)
            }
        }
        .padding(.vertical, 2)
    }

    private func confirm(_ item: SelfCandidate) {
        player.stop()
        working = item.id
        Task {
            let message = await pipeline.confirmSelfCandidate(item)
            working = nil
            results[item.id] = message
            pipeline.appFeeds.hide(item.id)
        }
    }
}

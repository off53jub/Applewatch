import Foundation
import Observation
import SwiftUI
import UIKit

/// 話し方コーチ（強化案 51）と緊張した場面（52）（2026-11-15。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 3」）。
/// 読む（家の PC の GET。母艦が作った写しを、PC とアプリの両方で確かめる）:
/// - 今夜のコーチ（GET /coach。features の "coach"）: 話し方の振り返りのいちばん上。よかった一言・直すとよい一言（その場面を聞ける）と、
///   直近 7 日の数（結論から・言いよどみ・質問・会議で話した割合）。話す練習の題材の数
/// - 緊張した場面（GET /tension。"tension"）: ふり返りの「自分」。心拍が上がった時刻と、そのとき話していた会話・相手・見出しの言葉
/// 送る（52）: 時計の心拍と歩数の 1 分ごと（直近 24 時間。送った所から続き）を家の PC の POST /health/hr（"hrsamples"）へ。
/// ヘルスケアがオンのときだけ・1 時間に 1 回まで。読む許可は前からの心拍・歩数のまま（新しい許可は聞かない）。
/// 写しは端末に置き（同期しない）、家の PC につながらないときも前の写しを見せる。中身の文は記録（ログ）に書かない。

// MARK: - 読んだ形

struct CoachMoment: Codable, Equatable {
    var text: String
    var why: String = ""
    var better: String = ""
    var time: String
    var audio: String? = nil
    var offset: Double? = nil
    var end: Double? = nil
    var conversation: String? = nil
}

struct CoachWeek: Codable, Equatable {
    var from: String? = nil
    var to: String? = nil
    var lines: Int = 0
    var conclusionFirst: Double? = nil
    var judged: Int = 0
    var fillerPerMin: Double? = nil
    var questions: Int = 0
    var talkShareMeetings: Double? = nil
    var meetings: Int = 0
    /// mode（会議モードの時刻）・guess（会議らしい会話の推定）・none
    var meetingSource: String = "none"
}

struct CoachFeed: Codable, Equatable {
    var day: String
    var good: CoachMoment? = nil
    var improve: CoachMoment? = nil
    var week: CoachWeek = CoachWeek()
    var seeds: Int = 0
    var firstSeed: String? = nil
}

struct TensionTalk: Codable, Equatable {
    var title: String = ""
    var people: [String] = []
    var place: String = ""
}

struct TensionItem: Codable, Equatable, Identifiable {
    var id: String
    var day: String
    var start: String
    var end: String? = nil
    var peak: Int
    var baseline: Int
    var talk: TensionTalk? = nil
}

struct TensionGroup: Codable, Equatable, Identifiable {
    var label: String
    var times: Int
    var of: Int
    var id: String { label }
}

struct TensionFeed: Codable, Equatable {
    var from: String? = nil
    var to: String? = nil
    /// minute（1 分ごとの心拍）・conversation（会話ごとの心拍）
    var source: String = "conversation"
    var items: [TensionItem] = []
    var people: [TensionGroup] = []
    var topics: [TensionGroup] = []
}

// MARK: - 確かめ方

enum CoachFeeds {
    static let itemLimit = 30
    static let groupLimit = 10

    private struct RawMoment: Decodable {
        var text: String?
        var why: String?
        var better: String?
        var time: String?
        var audio: String?
        var offset: Double?
        var end: Double?
        var conversation: String?
    }

    private struct RawWeek: Decodable {
        var from: String?
        var to: String?
        var lines: Int?
        var conclusion_first: Double?
        var judged: Int?
        var filler_per_min: Double?
        var questions: Int?
        var talk_share_meetings: Double?
        var meetings: Int?
        var meeting_source: String?
    }

    private struct RawSeeds: Decodable {
        var seeds: Int?
        var first: String?
    }

    private struct RawCoach: Decodable {
        var available: Bool?
        var day: String?
        var good: RawMoment?
        var improve: RawMoment?
        var week: RawWeek?
        var rehearse: RawSeeds?
    }

    private struct RawTalk: Decodable {
        var title: String?
        var people: [String]?
        var place: String?
    }

    private struct RawItem: Decodable {
        var id: String?
        var day: String?
        var start: String?
        var end: String?
        var peak_bpm: Int?
        var baseline_bpm: Int?
        var conversation: RawTalk?
    }

    private struct RawGroup: Decodable {
        var name: String?
        var word: String?
        var times: Int?
        var of: Int?
    }

    private struct RawTension: Decodable {
        var available: Bool?
        var from: String?
        var to: String?
        var source: String?
        var items: [LossyRow<RawItem>]?
        var by_person: [LossyRow<RawGroup>]?
        var by_topic: [LossyRow<RawGroup>]?
    }

    private static func day(_ text: String?) -> String? {
        guard let t = HomeFeeds.trimmed(text), HomeFeeds.isDay(t) else { return nil }
        return t
    }

    private static func ratio(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 1 else { return nil }
        return value
    }

    /// 区切りの音声のファイル名（英数字と . _ - だけ。フォルダは入れない）
    static func isAudioName(_ text: String?) -> Bool {
        guard let text, !text.isEmpty, text.count <= 120 else { return false }
        for s in text.unicodeScalars {
            let v = s.value
            let ok: Bool = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 46 || v == 95 || v == 45
            if !ok { return false }
        }
        return !text.hasPrefix(".")
    }

    private static func moment(_ raw: RawMoment?) -> CoachMoment? {
        guard let raw, let text = MothershipFeeds.cut(raw.text, 120), let time = HomeFeeds.trimmed(raw.time),
              PCJSON.date(time) != nil else { return nil }
        var m = CoachMoment(text: text, time: time)
        m.why = MothershipFeeds.cut(raw.why, 160) ?? ""
        m.better = MothershipFeeds.cut(raw.better, 120) ?? ""
        m.conversation = MothershipFeeds.cut(raw.conversation, 40)
        if isAudioName(raw.audio), let offset = raw.offset, offset.isFinite, offset >= 0, offset < 7200 {
            m.audio = raw.audio
            m.offset = offset
            if let end = raw.end, end.isFinite, end > offset, end < 7200 { m.end = end }
        }
        return m
    }

    /// GET /coach の答え
    static func decodeCoach(_ data: Data) -> CoachFeed? {
        guard let raw = try? JSONDecoder().decode(RawCoach.self, from: data), raw.available != false,
              let d = day(raw.day) else { return nil }
        var feed = CoachFeed(day: d)
        feed.good = moment(raw.good)
        feed.improve = moment(raw.improve)
        if let w = raw.week {
            var week = CoachWeek()
            week.from = day(w.from)
            week.to = day(w.to)
            week.lines = max(0, w.lines ?? 0)
            week.conclusionFirst = ratio(w.conclusion_first)
            week.judged = max(0, w.judged ?? 0)
            if let f = w.filler_per_min, f.isFinite, f >= 0, f < 1000 { week.fillerPerMin = f }
            week.questions = max(0, w.questions ?? 0)
            week.talkShareMeetings = ratio(w.talk_share_meetings)
            week.meetings = max(0, w.meetings ?? 0)
            let source: String = w.meeting_source ?? "none"
            week.meetingSource = ["mode", "guess", "none"].contains(source) ? source : "none"
            feed.week = week
        }
        feed.seeds = max(0, raw.rehearse?.seeds ?? 0)
        feed.firstSeed = MothershipFeeds.cut(raw.rehearse?.first, 80)
        return feed
    }

    private static func groups(_ rows: [LossyRow<RawGroup>]?) -> [TensionGroup] {
        var out: [TensionGroup] = []
        for row in rows ?? [] {
            guard let r = row.value, let label = MothershipFeeds.cut(r.name ?? r.word, 20), let times = r.times, times >= 0 else { continue }
            out.append(TensionGroup(label: label, times: times, of: max(times, r.of ?? times)))
            if out.count >= groupLimit { break }
        }
        return out
    }

    /// GET /tension の答え。心拍の読めない行は落とす。新しい順
    static func decodeTension(_ data: Data) -> TensionFeed? {
        guard let raw = try? JSONDecoder().decode(RawTension.self, from: data), raw.available != false else { return nil }
        var feed = TensionFeed(from: day(raw.from), to: day(raw.to))
        feed.source = raw.source == "minute" ? "minute" : "conversation"
        var seen = Set<String>()
        for row in raw.items ?? [] {
            guard let r = row.value, let id = r.id, id.count <= 64, let d = day(r.day), let start = HomeFeeds.trimmed(r.start),
                  PCJSON.date(start) != nil, let peak = r.peak_bpm, peak >= 30, peak <= 250, let base = r.baseline_bpm,
                  base >= 30, base <= 200, seen.insert(id).inserted else { continue }
            var item = TensionItem(id: id, day: d, start: start, peak: peak, baseline: base)
            item.end = HomeFeeds.trimmed(r.end)
            if let t = r.conversation {
                var people: [String] = []
                for p in t.people ?? [] {
                    if let cut = MothershipFeeds.cut(p, 20) { people.append(cut) }
                    if people.count >= 5 { break }
                }
                item.talk = TensionTalk(title: MothershipFeeds.cut(t.title, 40) ?? "", people: people,
                                        place: MothershipFeeds.cut(t.place, 40) ?? "")
            }
            feed.items.append(item)
            if feed.items.count >= itemLimit { break }
        }
        feed.items.sort { $0.start > $1.start }
        feed.people = groups(raw.by_person)
        feed.topics = groups(raw.by_topic)
        return feed
    }

    /// 「結論から 42%（30 回のうち）」など、週の数の行
    static func weekLines(_ w: CoachWeek) -> [String] {
        var out: [String] = []
        if let c = w.conclusionFirst {
            let pct: Int = Int((c * 100).rounded())
            out.append("結論から話せた \(pct)%（説明の \(w.judged) 回のうち）")
        }
        if let f = w.fillerPerMin {
            out.append("言いよどみ 1 分に " + String(format: "%.1f", f) + " 回")
        }
        out.append("質問 \(w.questions) 回（自分の発言 \(w.lines) のうち）")
        if let s = w.talkShareMeetings {
            let pct: Int = Int((s * 100).rounded())
            let how: String = w.meetingSource == "guess" ? "会議らしい会話 \(w.meetings) 回・推定" : "会議モード \(w.meetings) 回"
            out.append("会議で自分が話した割合 \(pct)%（" + how + "）")
        }
        return out
    }

    /// 「11/15 10:12〜」
    static func when(_ iso: String) -> String {
        guard let date = PCJSON.date(iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d H:mm"
        return f.string(from: date)
    }
}

// MARK: - 読み込み

@MainActor
@Observable
final class CoachBook {
    static let shared = CoachBook()

    private(set) var coach: CoachFeed?
    private(set) var tension: TensionFeed?
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var fetching = false

    private static let every: TimeInterval = 30 * 60
    static let coachFile = "mfeed-coach.json"
    static let tensionFile = "mfeed-tension.json"

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
        coach = Self.read(CoachFeed.self, Self.coachFile)
        tension = Self.read(TensionFeed.self, Self.tensionFile)
    }

    /// 読み直す（force でなければ 30 分に 1 回まで）。読めなかった写しは前のまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.isConfigured else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        if pc.features.contains("coach"), let body = try? await pc.appFeed("coach", feature: "coach"),
           let feed = CoachFeeds.decodeCoach(body) {
            coach = feed
            Self.write(feed, Self.coachFile)
        }
        if pc.features.contains("tension"), let body = try? await pc.appFeed("tension", feature: "tension"),
           let feed = CoachFeeds.decodeTension(body) {
            tension = feed
            Self.write(feed, Self.tensionFile)
        }
    }
}

// MARK: - 心拍の 1 分ごとを家の PC へ（52）

enum HeartMinutes {
    static let feature = "hrsamples"
    /// 「心拍の 1 分ごとを家の PC に送る」（初めはオン。ヘルスケアがオンのときだけ送る）
    static let toggleKey = "heartMinutesToPC"
    /// ここまで送った（1970 年からの秒）
    static let sentKey = "heartMinutesSentUntil"
    static let triedKey = "heartMinutesTried"
    static let every: TimeInterval = 3600
    static let window: TimeInterval = 24 * 3600
    static let oldest: TimeInterval = 7 * 24 * 3600
    static let roundsPerRun = 3

    static var isOn: Bool { UserDefaults.standard.object(forKey: toggleKey) as? Bool ?? true }

    /// 送る窓（前に送った所の 5 分前から、24 時間ぶんまで。7 日より前には戻らない）
    static func window(sent: Double, now: Date) -> (from: Date, to: Date) {
        let floor: Date = now.addingTimeInterval(-oldest)
        var from: Date = sent > 0 ? Date(timeIntervalSince1970: sent - 300) : now.addingTimeInterval(-window)
        if from < floor { from = floor }
        let to: Date = min(now, from.addingTimeInterval(window))
        return (from, to)
    }

    /// POST /health/hr の中身（1 分の頭の時刻・整数の値）
    static func body(heart: [(Date, Double)], steps: [(Date, Double)]) -> Data? {
        var hr: [[String: Int]] = []
        for (time, value) in heart where value.isFinite && value >= 25 && value <= 250 {
            hr.append(["t": Int(time.timeIntervalSince1970), "bpm": Int(value.rounded())])
        }
        var st: [[String: Int]] = []
        for (time, value) in steps where value.isFinite && value >= 0 && value <= 1000 {
            st.append(["t": Int(time.timeIntervalSince1970), "n": Int(value.rounded())])
        }
        let object: [String: Any] = ["samples": hr, "steps": st]
        return try? JSONSerialization.data(withJSONObject: object, options: [])
    }
}

extension Pipeline {
    /// 時計の心拍と歩数の 1 分ごとを、前に送った所から家の PC に送る（1 時間に 1 回まで・1 回に 24 時間ぶんを 3 つまで）。
    /// 送れたところまで印を進める（送れなければ次の機会に同じ所から）。iPhone だけ
    func sendHeartMinutesIfDue(now: Date = .now) async {
        guard HeartMinutes.isOn, health.enabled, health.available, UIDevice.current.userInterfaceIdiom != .pad,
              homePC.isConfigured, homePC.features.contains(HeartMinutes.feature) else { return }
        let defaults = UserDefaults.standard
        guard now.timeIntervalSince1970 - defaults.double(forKey: HeartMinutes.triedKey) >= HeartMinutes.every else { return }
        defaults.set(now.timeIntervalSince1970, forKey: HeartMinutes.triedKey)
        for _ in 0..<HeartMinutes.roundsPerRun {
            let span = HeartMinutes.window(sent: defaults.double(forKey: HeartMinutes.sentKey), now: now)
            guard span.to.timeIntervalSince(span.from) >= 600 else { return }
            let series = await health.minuteSeries(from: span.from, to: span.to)
            if series.heart.isEmpty && series.steps.isEmpty {
                // ロック中で読めない・記録が無い。1 時間より前に終わる窓だけ、記録が無かったものとして先へ進める
                guard span.to < now.addingTimeInterval(-3600) else { return }
                defaults.set(span.to.timeIntervalSince1970, forKey: HeartMinutes.sentKey)
                continue
            }
            guard let body = HeartMinutes.body(heart: series.heart, steps: series.steps) else { return }
            do {
                _ = try await homePC.postJSONData("health/hr", body: body, timeout: 30)
                defaults.set(span.to.timeIntervalSince1970, forKey: HeartMinutes.sentKey)
                Tally.add("heartMinutes.sent", series.heart.count)
            } catch {
                return
            }
            if span.to >= now { return }
        }
    }
}

// MARK: - 画面: 今夜のコーチ（話し方の振り返りのいちばん上）

struct CoachSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()

    var body: some View {
        let book = CoachBook.shared
        if let coach = book.coach {
            Section {
                if let good = coach.good {
                    momentRow("よかった一言", good, key: "coach-good", color: .green)
                }
                if let improve = coach.improve {
                    momentRow("直すとよい一言", improve, key: "coach-improve", color: .orange)
                }
                if coach.good == nil && coach.improve == nil {
                    Text("この日は選べませんでした（自分の発言が少ない日か、Claude を使えなかった日です）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("直近 7 日").font(.caption.bold())
                    ForEach(CoachFeeds.weekLines(coach.week), id: \.self) { line in
                        Text(line).font(.caption)
                    }
                }
                if coach.seeds > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("話す練習の題材 \(coach.seeds) 件", systemImage: "figure.wave")
                            .font(.caption)
                        if let first = coach.firstSeed {
                            Text("最初の題: " + first).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("家の PC で「話す練習（rehearse）」を開くと、実際の相手の物差しで 30 秒×3 本の練習ができます。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("今夜のコーチ（" + shortDay(coach.day) + "）")
            } footer: {
                Text("家の PC が毎晩、その日の自分の発言だけを読んで選びます。文字起こしは聞き違いや言いよどみの書き落としがあるので、目安として見てください。")
            }
            .task { await book.refresh(pipeline.homePC) }
        } else if pipeline.homePC.features.contains("coach") {
            Section("今夜のコーチ") {
                Text("家の PC がまだ作っていません（毎晩 23 時ごろに作ります）。").font(.caption).foregroundStyle(.secondary)
            }
            .task { await book.refresh(pipeline.homePC) }
        }
    }

    private func shortDay(_ day: String) -> String {
        guard day.count == 10 else { return day }
        return String(day.suffix(5)).replacingOccurrences(of: "-", with: "/")
    }

    @ViewBuilder
    private func momentRow(_ title: String, _ m: CoachMoment, key: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(color)
            Text("「" + m.text + "」").font(.callout)
            if !m.why.isEmpty { Text(m.why).font(.caption).foregroundStyle(.secondary) }
            if !m.better.isEmpty { Text("言い直すなら: " + m.better).font(.caption) }
            HStack(spacing: 12) {
                Text(CoachFeeds.when(m.time) + (m.conversation.map { "・" + $0 } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
                if let audio = m.audio, let offset = m.offset {
                    Button {
                        Task {
                            let start: Double = max(0, offset - 2)
                            let stop: Double = (m.end ?? offset + 10) + 1
                            await player.toggle(key, at: start, until: stop) {
                                await pipeline.archive.playableURL(for: audio)
                            }
                        }
                    } label: {
                        if player.loading == key {
                            ProgressView()
                        } else {
                            Label(player.playing == key ? "止める" : "聞く",
                                  systemImage: player.playing == key ? "stop.circle.fill" : "play.circle")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - 画面: 緊張した場面（ふり返りの「自分」）

struct TensionLookBackSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = CoachBook.shared
        if let tension = book.tension {
            Section {
                NavigationLink {
                    TensionView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("緊張した場面", systemImage: "heart.text.square")
                        Text(TensionLookBackSection.summary(tension)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task { await book.refresh(pipeline.homePC) }
        } else if pipeline.homePC.features.contains("tension") {
            EmptyView()
                .task { await book.refresh(pipeline.homePC) }
        }
    }

    /// 「7 日で 5 回・多い相手 ◯◯さん」
    static func summary(_ t: TensionFeed) -> String {
        var text: String = "7 日で \(t.items.count) 回"
        if let top = t.people.first { text += "・多い相手 " + top.label }
        return text
    }
}

struct TensionView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(HeartMinutes.toggleKey) private var sendMinutes = true

    var body: some View {
        let book = CoachBook.shared
        List {
            if let t = book.tension {
                Section {
                    if t.items.isEmpty {
                        Text("この 7 日は、はっきり上がった時刻はありませんでした。").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(t.items) { item in
                        row(item)
                    }
                } header: {
                    Text("心拍が上がった時刻（新しい順）")
                } footer: {
                    Text(t.source == "minute"
                         ? "時計の 1 分ごとの心拍が、その日のふだん（安静時）より 25 以上高かった時刻です。歩いていた時間は外しています。"
                         : "会話ごとの心拍（平均がふだんより 20 以上か、最大が 30 以上高かった会話）です。歩いていたかは分かりません。")
                }
                if !t.people.isEmpty {
                    Section("相手ごと") {
                        ForEach(t.people) { g in
                            LabeledContent(g.label, value: "\(g.times) 回（話した \(g.of) 回のうち）")
                        }
                    }
                }
                if !t.topics.isEmpty {
                    Section("見出しの言葉ごと") {
                        ForEach(t.topics) { g in
                            LabeledContent(g.label, value: "\(g.times) 回")
                        }
                    }
                }
            }
            Section {
                Toggle("心拍の 1 分ごとを家の PC に送る", isOn: $sendMinutes)
            } footer: {
                Text("心拍が上がった時刻と、そのとき話していた会話を並べて数えただけです。体や心の状態の判断には使えません。1 分ごとの心拍は、ヘルスケアがオンのときだけ、1 時間に 1 回まで家の PC に送ります（家の PC と母艦の外には出しません）。")
            }
        }
        .navigationTitle("緊張した場面")
        .countsOpen("tension")
        .refreshable { await book.refresh(pipeline.homePC, force: true) }
    }

    private func row(_ item: TensionItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(CoachFeeds.when(item.start)).font(.callout.monospacedDigit())
                Spacer()
                Text("\(item.peak)（ふだん \(item.baseline)・+\(item.peak - item.baseline)）")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let talk = item.talk {
                if !talk.title.isEmpty { Text(talk.title).font(.caption) }
                let who: String = talk.people.isEmpty ? "" : talk.people.joined(separator: "、")
                let place: String = talk.place
                if !who.isEmpty || !place.isEmpty {
                    Text([who, place].filter { !$0.isEmpty }.joined(separator: "・"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("重なる会話はありませんでした").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

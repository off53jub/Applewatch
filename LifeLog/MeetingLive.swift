import ActivityKit
import Foundation
import Observation
import SwiftUI

/// 会議の相棒（その場版。2026-11-15。強化案 50。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 3」）。
/// 会議モードのあいだ、60 秒ごとに:
/// 1. 家の PC に会議モードの様子を送る（POST /meeting-live/state。始まり・題名・Claude と職場の設定・この会議で「自分」と分けた行）
/// 2. 家の PC が区切りの文から作り直した「決まったこと・自分の宿題・聞き忘れ」を読む（GET /meeting-live。features の "meetinglive"）
/// 3. ロック画面と Dynamic Island（Live Activity）・時計（WatchInfo の meeting）・会議モードのボタンの下に出す
/// 家の PC が作り直すのは 1 分に 1 回まで。区切りが PC に届いて文字になってから出るので、話してから 1〜3 分ほど遅れる（PR の実測）。
/// Live Activity は iOS の決まりで、アプリが前にあるときにしか出せない（時計から会議モードを始めたときは、次にアプリを開いたときに出す）。
/// 中身の文は記録（ログ）に書かない。

struct MeetingLiveItem: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var quote: String = ""
}

struct MeetingLiveFeed: Codable, Equatable {
    var on: Bool
    var startedAt: String? = nil
    var title: String = ""
    var version: Int = 0
    var updatedAt: String? = nil
    var decided: [MeetingLiveItem] = []
    var homework: [MeetingLiveItem] = []
    var unasked: [MeetingLiveItem] = []
    var latest: [String] = []
    var reason: String? = nil
    /// 区切りを PC が受け取ってから、その行を入れて作り直し終えるまで（秒・直近）
    var delay: Double? = nil
    /// 読んだ時刻
    var fetched: Date = .now
}

enum MeetingLive {
    static let feature = "meetinglive"
    static let every: TimeInterval = 60
    static let mineLimit = 20
    static let itemLimit = 5

    private struct RawItem: Decodable {
        var id: String?
        var text: String?
        var quote: String?
    }

    private struct RawDelay: Decodable {
        var last: Double?
    }

    private struct RawFeed: Decodable {
        var available: Bool?
        var on: Bool?
        var started_at: String?
        var title: String?
        var version: Int?
        var changed: Bool?
        var updated_at: String?
        var decided: [LossyRow<RawItem>]?
        var homework: [LossyRow<RawItem>]?
        var unasked: [LossyRow<RawItem>]?
        var latest: [String]?
        var reason: String?
        var delay: RawDelay?
    }

    private static func items(_ rows: [LossyRow<RawItem>]?) -> [MeetingLiveItem] {
        var out: [MeetingLiveItem] = []
        for row in rows ?? [] {
            guard let r = row.value, let id = r.id, HomeFeeds.isID(id), let text = MothershipFeeds.cut(r.text, 40) else { continue }
            out.append(MeetingLiveItem(id: id, text: text, quote: MothershipFeeds.cut(r.quote, 40) ?? ""))
            if out.count >= itemLimit { break }
        }
        return out
    }

    /// GET /meeting-live の答え。changed が false（中身を省いた）なら、前の中身を使う
    static func decode(_ data: Data, previous: MeetingLiveFeed?) -> MeetingLiveFeed? {
        guard let raw = try? JSONDecoder().decode(RawFeed.self, from: data), raw.available != false else { return nil }
        var feed = MeetingLiveFeed(on: raw.on ?? false)
        feed.startedAt = raw.started_at
        feed.title = MothershipFeeds.cut(raw.title, 60) ?? ""
        feed.version = max(0, raw.version ?? 0)
        feed.updatedAt = raw.updated_at
        if raw.changed == false, let previous {
            feed.decided = previous.decided
            feed.homework = previous.homework
            feed.unasked = previous.unasked
        } else {
            feed.decided = items(raw.decided)
            feed.homework = items(raw.homework)
            feed.unasked = items(raw.unasked)
        }
        var latest: [String] = []
        for line in raw.latest ?? [] {
            if let cut = MothershipFeeds.cut(line, 44) { latest.append(cut) }
            if latest.count >= 2 { break }
        }
        feed.latest = latest
        feed.reason = MothershipFeeds.cut(raw.reason, 80)
        if let d = raw.delay?.last, d.isFinite, d >= 0 { feed.delay = d }
        return feed
    }

    /// Live Activity に入れる中身
    static func contentState(_ feed: MeetingLiveFeed, started: Date) -> MeetingActivityAttributes.ContentState {
        var state = MeetingActivityAttributes.ContentState(started: started)
        state.decided = feed.decided.count
        state.homework = feed.homework.count
        state.unasked = feed.unasked.count
        var lines: [String] = feed.latest
        if lines.isEmpty {
            // 新しく出たものが無ければ、宿題・聞き忘れの先頭
            if let first = feed.homework.first { lines.append("宿 " + first.text) }
            if let first = feed.unasked.first { lines.append("聞 " + first.text) }
        }
        state.lines = Array(lines.prefix(2))
        if let at = feed.updatedAt { state.updated = PCJSON.date(at) }
        return state
    }

    /// 時計に送る中身（宿題・聞き忘れ・決まったことの順に 6 つまで）
    static func watchItems(_ feed: MeetingLiveFeed) -> [String] {
        var out: [String] = []
        for item in feed.homework.prefix(3) { out.append("宿 " + item.text) }
        for item in feed.unasked.prefix(2) { out.append("聞 " + item.text) }
        for item in feed.decided.prefix(2) { out.append("決 " + item.text) }
        return Array(out.prefix(6))
    }

    /// POST /meeting-live/state の中身
    static func stateBody(on: Bool, start: Date?, title: String?, claude: Bool, work: Bool, workOK: Bool,
                          mine: [(Date, String)]) -> Data? {
        var body: [String: Any] = ["on": on, "claude": claude, "work": work, "work_ok": workOK]
        if let start { body["start"] = PCJSON.string(start) }
        if let title, !title.isEmpty { body["title"] = String(title.prefix(60)) }
        var rows: [[String: String]] = []
        for (time, text) in mine.suffix(mineLimit) {
            rows.append(["at": PCJSON.string(time), "text": String(text.prefix(400))])
        }
        if !rows.isEmpty { body["mine"] = rows }
        return try? JSONSerialization.data(withJSONObject: body, options: [])
    }
}

// MARK: - Live Activity

@MainActor
enum MeetingActivity {
    static var isShowing: Bool { !ActivityKit.Activity<MeetingActivityAttributes>.activities.isEmpty }

    /// 出す（出ていれば中身を替える）。出せなければ false（アプリが前に無い・Live Activity がオフ）
    @discardableResult
    static func show(_ state: MeetingActivityAttributes.ContentState) -> Bool {
        let content = ActivityContent(state: state, staleDate: Date.now.addingTimeInterval(10 * 60))
        if let current = ActivityKit.Activity<MeetingActivityAttributes>.activities.first {
            Task { await current.update(content) }
            return true
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        do {
            _ = try ActivityKit.Activity<MeetingActivityAttributes>.request(attributes: MeetingActivityAttributes(),
                                                                            content: content, pushType: nil)
            return true
        } catch {
            return false
        }
    }

    static func end() {
        for activity in ActivityKit.Activity<MeetingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .default) }
        }
    }
}

// MARK: - 見に行く

@MainActor
@Observable
final class MeetingLiveBook {
    static let shared = MeetingLiveBook()

    private(set) var feed: MeetingLiveFeed?
    private(set) var note: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loopToken: UUID?

    /// 会議モードを始めた・終えた（Pipeline.setMeeting から）
    func meetingChanged(_ on: Bool, pipeline: Pipeline) {
        if on {
            feed = nil
            note = nil
            if let session = MeetingMode.active {
                MeetingActivity.show(MeetingActivityAttributes.ContentState(started: session.start))
            }
            startLoop(pipeline)
        } else {
            loop?.cancel()
            loop = nil
            MeetingActivity.end()
            Task { await self.sendState(pipeline, on: false) }
            pipeline.pushWatchInfo(force: true)
        }
    }

    /// アプリを開いたとき: 会議モードの最中なら、見に行くのと Live Activity を続ける
    func resumeIfNeeded(_ pipeline: Pipeline) {
        guard let session = MeetingMode.active else {
            if MeetingActivity.isShowing { MeetingActivity.end() }
            return
        }
        if !MeetingActivity.isShowing {
            let state: MeetingActivityAttributes.ContentState = feed.map { MeetingLive.contentState($0, started: session.start) }
                ?? MeetingActivityAttributes.ContentState(started: session.start)
            MeetingActivity.show(state)
        }
        if loop == nil { startLoop(pipeline) }
    }

    private func startLoop(_ pipeline: Pipeline) {
        loop?.cancel()
        let token = UUID()
        loopToken = token
        loop = Task { [weak self] in
            while !Task.isCancelled, MeetingMode.active != nil {
                await self?.tick(pipeline)
                try? await Task.sleep(for: .seconds(MeetingLive.every))
            }
            // 会議モードが終わった（ほかの見に行くが始まっていなければ、次に始められるよう空にする）
            if let self, self.loopToken == token { self.loop = nil }
        }
    }

    private func sendState(_ pipeline: Pipeline, on: Bool) async {
        let pc = pipeline.homePC
        guard pc.isConfigured, pc.features.contains(MeetingLive.feature) else { return }
        let session = MeetingMode.active
        var mine: [(Date, String)] = []
        if on, let session {
            let day = MeetingLiveBook.dayKey.string(from: .now)
            for c in pipeline.conversations(on: day) {
                for line in c.lines where line.speakerID == SpeakerLabeler.selfID && line.time >= session.start && line.media == nil {
                    mine.append((line.time, line.text))
                }
            }
        }
        let work: Bool = pipeline.vocabularyContext(at: .now) == .work
        guard let body = MeetingLive.stateBody(on: on, start: session?.start, title: session?.title,
                                               claude: ClaudeRoute.useClaude, work: work, workOK: ClaudeRoute.forWork,
                                               mine: mine) else { return }
        _ = try? await pc.postJSONData("meeting-live/state", body: body, timeout: 10)
    }

    /// 1 回: 様子を送って、読み直して、出す
    func tick(_ pipeline: Pipeline) async {
        guard let session = MeetingMode.active else { return }
        let pc = pipeline.homePC
        guard pc.isConfigured else {
            note = "家の PC が設定されていません。"
            return
        }
        if pc.version == nil { _ = try? await pc.hello() }
        guard pc.features.contains(MeetingLive.feature) else {
            note = "家の PC がまだ対応していません（家の PC を新しくすると使えます）。"
            return
        }
        await sendState(pipeline, on: true)
        guard let data = try? await pc.appFeed("meeting-live", feature: MeetingLive.feature),
              let fresh = MeetingLive.decode(data, previous: feed) else {
            note = "家の PC につながりませんでした（次の 1 分でまた見ます）。"
            return
        }
        let changed = fresh.version != feed?.version
        feed = fresh
        note = nil
        MeetingActivity.show(MeetingLive.contentState(fresh, started: session.start))
        if changed { pipeline.pushWatchInfo(force: true) }
    }

    /// 時計に出す中身（会議モードの最中と、終わって 30 分まで）
    func watchMeeting() -> WatchInfo.Meeting? {
        guard let feed else { return nil }
        let start: Date = feed.startedAt.flatMap { PCJSON.date($0) } ?? MeetingMode.active?.start ?? feed.fetched
        if MeetingMode.active == nil && Date.now.timeIntervalSince(feed.fetched) > 30 * 60 { return nil }
        var meeting = WatchInfo.Meeting(start: start.timeIntervalSince1970)
        meeting.on = MeetingMode.active != nil
        meeting.decided = feed.decided.count
        meeting.homework = feed.homework.count
        meeting.unasked = feed.unasked.count
        meeting.items = MeetingLive.watchItems(feed)
        meeting.updated = feed.updatedAt.flatMap { PCJSON.date($0) }?.timeIntervalSince1970
        return meeting
    }

    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - 画面（会議モードのボタンの下）

struct MeetingLiveRows: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = MeetingLiveBook.shared
        if pipeline.homePC.features.contains(MeetingLive.feature) {
            VStack(alignment: .leading, spacing: 6) {
                if let feed = book.feed {
                    group("自分の宿題", feed.homework)
                    group("聞き忘れ（まだ出ていない点）", feed.unasked)
                    group("決まったこと", feed.decided)
                    if feed.homework.isEmpty && feed.unasked.isEmpty && feed.decided.isEmpty {
                        Text(feed.updatedAt == nil ? "家の PC がまだ作っていません（1 分に 1 回まで作り直します）。" : "まだ何も出ていません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = feed.reason {
                        Text(reason).font(.caption2).foregroundStyle(.orange)
                    }
                    Text(MeetingLiveRows.footer(feed)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("会議の相棒: 家の PC が区切りの文から作り直すのを待っています。").font(.caption).foregroundStyle(.secondary)
                }
                if let note = book.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [MeetingLiveItem]) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.bold())
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text("・" + item.text).font(.callout)
                    if !item.quote.isEmpty {
                        Text("「" + item.quote + "」").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func footer(_ feed: MeetingLiveFeed) -> String {
        var parts: [String] = ["音声から作ったもので、聞き違いがあります"]
        if let delay = feed.delay { parts.append("PC に届いてから \(Int(delay.rounded())) 秒で作り直し") }
        return parts.joined(separator: "・")
    }
}

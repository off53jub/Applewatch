import Foundation
import Observation

// s25（2026-11-24）の A1 の動き。決まりは S25TRules.swift、画面は S25TViews.swift。
// - 連2・仕5（K1）: 家の PC の GET /line-tasks を 10 分（仮）に 1 回読み、LINE の頼まれごとをタスクの候補（source line）に入れる。
//   知らせは足さない（s24 の 減13）。今日の候補 3 件の中で、会話から拾ったものより先に出る（S24Book の todayCandidates）
// - 大8（K2）: 家の PC の GET /drafts を同じく読み、タスクの「下書き」の棚に出す。答えは POST /feedback の kind "draft"
// - 連6（K3）: 共有で受けた .txt を、本人が「送る」を押したときだけ POST /line/share へ
// - 大10（K7）: 設定がオンのとき（初めはオフ）、録音中に 2 分（仮）に 1 回 GET /whisper-now を聞き、相手が変わったら時計に静かに出す
// どれも家の PC が口を持っていなければ（404 など）何もしない。中身の文は記録（ログ）に書かない。

@MainActor
final class S25TBook {
    static let shared = S25TBook()
    static var pipeline: Pipeline?
    private static var timer: Timer?

    /// 家の PC の写しを読む間（秒。仮 10 分）
    static let feedEvery: TimeInterval = 600
    private var feedAt: Date?
    private var feeding = false

    /// LifeLogApp の起動で 1 回だけ呼ぶ。live でなければ（テスト・画面の自動確認）動かさない
    static func install(_ pipeline: Pipeline, live: Bool) {
        self.pipeline = pipeline
        guard live, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in S25TBook.shared.tick() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(40))
            S25TBook.shared.tick()
        }
    }

    /// 1 分ごと
    func tick(now: Date = .now) {
        guard let pipeline = Self.pipeline else { return }
        S25TWhisperBook.shared.tick(pipeline, now: now)
        if !feeding, feedAt.map({ now.timeIntervalSince($0) >= Self.feedEvery }) ?? true {
            feedAt = now
            feeding = true
            Task {
                await refresh(pipeline, now: now)
                feeding = false
            }
        }
    }

    /// LINE のタスク候補と下書きを読む（口が無い・つながらないときは前のまま）
    func refresh(_ pipeline: Pipeline, now: Date = .now) async {
        let today = ReviewRules.dayKey(now)
        if let data = try? await pipeline.homePC.getJSONData("line-tasks", timeout: 10) {
            let rows = S25TLineTasks.decode(data, today: today)
            let items = S25TLineTasks.candidates(rows, existingIDs: Set(pipeline.tasks.items.map(\.id)))
            let added = pipeline.tasks.add(items)
            Tally.add("s25t.line.read")
            if !added.isEmpty {
                Tally.add("s25t.line.added", added.count)
                pipeline.tasksChanged()
            }
        }
        if let data = try? await pipeline.homePC.getJSONData("drafts", timeout: 10) {
            S25TDraftBook.shared.replace(S25TDrafts.decode(data, today: today))
        }
    }
}

// MARK: - 大8 下書きの棚

@MainActor
@Observable
final class S25TDraftBook {
    static let shared = S25TDraftBook()
    private static let itemsKey = "s25t.drafts"
    private static let handledKey = "s25t.draftsHandled"
    private static let editsKey = "s25t.draftsEdited"

    private(set) var drafts: [S25TDraft] = []
    /// 送った・捨てたもの（棚から外す）
    private(set) var handled: Set<String> = []
    /// 本人が直した本文（id → 文）
    private(set) var edits: [String: String] = [:]

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.itemsKey) { drafts = (try? JSONDecoder().decode([S25TDraft].self, from: data)) ?? [] }
        handled = Set(d.stringArray(forKey: Self.handledKey) ?? [])
        edits = d.dictionary(forKey: Self.editsKey) as? [String: String] ?? [:]
    }

    /// 棚に出すもの（期限の過ぎたものは外す）
    func shelf(now: Date = .now) -> [S25TDraft] {
        let today = ReviewRules.dayKey(now)
        return S25TDrafts.shelf(drafts.filter { $0.expires >= today }, handled: handled).map { d in
            var copy = d
            if let edited = edits[d.id] { copy.body = edited }
            return copy
        }
    }

    func replace(_ list: [S25TDraft]) {
        guard list != drafts else { return }
        drafts = list
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.itemsKey) }
        // もう届かない下書きの印は捨てる（溜めない）
        let ids = Set(list.map(\.id))
        let keep = handled.filter { ids.contains($0) }
        if keep != handled { handled = keep; saveHandled() }
        let keptEdits = edits.filter { ids.contains($0.key) }
        if keptEdits.count != edits.count { edits = keptEdits; UserDefaults.standard.set(edits, forKey: Self.editsKey) }
    }

    /// 答えた（sent・dropped は棚から外す。edited は直した文を残す）。母艦へは POST /feedback の kind "draft"
    func answer(_ draft: S25TDraft, action: String, edited: String? = nil, now: Date = .now) {
        guard S25TDrafts.actions.contains(action) else { return }
        if action == "edited", let edited {
            edits[draft.id] = edited
            UserDefaults.standard.set(edits, forKey: Self.editsKey)
        } else {
            handled.insert(draft.id)
            saveHandled()
        }
        MothershipOutbox.enqueueFeedback(kind: "draft", id: draft.id, value: action, day: ReviewRules.dayKey(now), now: now)
        Tally.add("s25t.draft." + action)
        Tally.add("s25t.draft." + draft.kind + "." + action)
    }

    private func saveHandled() {
        UserDefaults.standard.set(Array(handled.sorted().suffix(300)), forKey: Self.handledKey)
    }
}

// MARK: - 連6 共有で受けた LINE のトーク履歴

@MainActor
@Observable
final class S25TShareBox {
    static let shared = S25TShareBox()

    struct Pending: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var text: String
        var bytes: Int
        var cut: Bool
        var looksLine: Bool
    }

    var pending: Pending?
    /// 送った結果の一文
    var result: String?
    var sending = false

    /// 共有で受けた（読んだら、受け取りの写しは消す。送るのは本人が押してから）
    func received(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            fail("ファイルを読めませんでした。")
            return
        }
        // 受け取りの写し（アプリの中の Inbox）だけを消す
        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .shiftJIS) ?? ""
        guard !text.isEmpty else {
            fail("文字として読めませんでした（LINE の「トーク履歴を送信」の .txt を選んでください）。")
            return
        }
        let capped = S25TLineShare.capped(text)
        pending = Pending(name: S25TLineShare.name(text: text, fileName: url.lastPathComponent), text: capped.text,
                          bytes: capped.text.utf8.count, cut: capped.cut, looksLine: S25TLineShare.looksLikeLine(text))
        result = nil
        Tally.add("s25t.share.received")
    }

    func send(_ pipeline: Pipeline) async {
        guard let p = pending, let body = S25TLineShare.body(name: p.name, text: p.text) else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await pipeline.homePC.postJSONData("line/share", body: body, timeout: 30)
            Tally.add("s25t.share.sent")
            pending?.text = ""
            result = "家の PC へ送りました。母艦の LINE の取り込みで、次の回に入ります。"
        } catch {
            Tally.add("s25t.share.failed")
            result = "送れませんでした: " + error.localizedDescription + "（家の PC がまだ対応していないかもしれません）"
        }
    }

    /// 読めなかったことを、受け取りの画面で伝える（送るものは無し）
    private func fail(_ message: String) {
        pending = Pending(name: "", text: "", bytes: 0, cut: false, looksLine: false)
        result = message
    }

    /// 閉じる（送らずに閉じたときだけ「やめた」と数える）
    func close() {
        if let p = pending, !p.text.isEmpty { Tally.add("s25t.share.cancelled") }
        pending = nil
        result = nil
    }
}

// MARK: - 大10 耳打ち

@MainActor
final class S25TWhisperBook {
    static let shared = S25TWhisperBook()
    private var lastAsked: Date?
    private var asking = false
    private(set) var current: S25TWhisper?
    private var shownAt: Date?
    private var lastPerson: String?

    static var isOn: Bool { UserDefaults.standard.object(forKey: S25TWhisperRules.onKey) as? Bool ?? false }

    func tick(_ pipeline: Pipeline, now: Date = .now) {
        // 出しておく長さを過ぎた・オフにしたら、時計から外す
        if current != nil, !Self.isOn || !S25TWhisperRules.alive(shownAt: shownAt, now: now) {
            current = nil
            shownAt = nil
            if !Self.isOn { lastPerson = nil }
            pipeline.pushWatchInfo(force: true)
        }
        let recording = pipeline.isRecording || pipeline.isWatchRecording
        if !recording { lastPerson = nil }
        guard !asking, S25TWhisperRules.shouldAsk(on: Self.isOn, recording: recording, lastAsked: lastAsked, now: now) else { return }
        lastAsked = now
        asking = true
        Task {
            defer { asking = false }
            guard let data = try? await pipeline.homePC.getJSONData("whisper-now", timeout: 8) else { return }
            let w = S25TWhisperRules.decode(data)
            guard S25TWhisperRules.changed(previous: lastPerson, now: w), let w else { return }
            current = w
            shownAt = .now
            lastPerson = w.person
            Tally.add("s25t.whisper.shown")
            pipeline.pushWatchInfo(force: true)
        }
    }

    /// 時計に出す耳打ち（出しておく長さのあいだだけ）
    func watchWhisper(now: Date = .now) -> WatchInfo.Whisper? {
        guard let current, let shownAt, S25TWhisperRules.alive(shownAt: shownAt, now: now) else { return nil }
        return WatchInfo.Whisper(person: current.person, lastTalk: current.lastTalk, promises: current.promises,
                                 at: shownAt.timeIntervalSince1970)
    }
}

// MARK: - 活5・活7 家の PC の検索の口

enum S25TSearchOutcome: Equatable {
    case hits([S25TSearchHit])
    /// 家の PC がまだこの口を持っていない（404 など）
    case notYet
    case failed(String)
}

extension Pipeline {
    /// 家の PC の記録（母艦の LINE・PLAUD・まとめなど）を言葉で探す。Claude には頼まない
    func s25tSearch(_ query: String, person: String? = nil, sources: [String]? = nil, days: Int? = nil) async -> S25TSearchOutcome {
        guard let body = S25TSearch.body(query: query, person: person, sources: sources, days: days) else { return .failed("") }
        do {
            let data = try await homePC.postJSONData(S25TSearch.path, body: body, timeout: 20)
            guard let hits = S25TSearch.decode(data) else { return .notYet }
            Tally.add("s25t.search.ok")
            return .hits(hits)
        } catch HomePC.Failure.server(let reason) where reason.contains("404") || reason.lowercased().contains("not found") {
            Tally.add("s25t.search.notYet")
            return .notYet
        } catch {
            Tally.add("s25t.search.failed")
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - 大9 この声は誰？（今日見送った声）

enum S25TVoiceAskBook {
    private static let skipKey = "s25t.voiceSkip"

    static func skipped(now: Date = .now) -> Set<String> {
        Set(S24AskRules.daySet(adding: [], saved: UserDefaults.standard.string(forKey: skipKey), day: ReviewRules.dayKey(now)).ids)
    }

    static func skip(_ id: String, now: Date = .now) {
        let merged = S24AskRules.daySet(adding: [id], saved: UserDefaults.standard.string(forKey: skipKey), day: ReviewRules.dayKey(now))
        UserDefaults.standard.set(merged.save, forKey: skipKey)
        Tally.add("s25t.voiceAsk.skip")
    }
}

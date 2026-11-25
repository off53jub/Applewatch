import Foundation
import Observation
import WidgetKit

// s27（2026-11-25）の A の動き。決まりは S27WRules.swift、画面は S27WViews.swift。
// - 場1〜場4・場8（K2）: 家の PC の GET /work を 10 分（仮）に 1 回と、仕事の画面を開いたとき（1 分あけて・仮）に読む。
//   端末の Application Support/S27W/ に写しを置き、つながらないときは前の写しを見せる。features に "work" が無ければ何も出さない
// - 守6（K3）: GET /work/confirm を同じく読む。答えは POST /feedback の kind "work_confirm"（まとめて 1 回）
// - 場7（K5）: GET /work/ask?q=…。使えないときは端末の写しの中で引く
// - 人8・案6・他3・宿題の済み（K4）: POST /feedback の kind "work_edit"・"work_numbers"・"work_notice"・"work_done"
//   （MothershipOutbox にためて、いつもの送り口で送る。他3 は設定でオンにするまで送らない＝初めはオフ）
// - 場6（守1）: ウィジェットへは数だけ（S27WWorkCounts）
// 知らせは足さない（減13）。中身の文は記録（ログ）に書かない（Tally は数と種類の名前だけ）。

@MainActor
@Observable
final class S27WBook {
    static let shared = S27WBook()
    static var pipeline: Pipeline?
    private static var timer: Timer?

    /// 家の PC の写しを読む間（秒。仮 10 分）
    static let feedEvery: TimeInterval = 600
    /// 画面を開いたときに読み直すまでの間（仮 1 分）
    static let openEvery: TimeInterval = 60

    static let offeredKey = "s27w.offered"
    static let askKey = "s27w.askOffered"
    static let confirmOfferedKey = "s27w.confirmOffered"
    /// 守2 顧客名と人名を伏せる（初めはオフ）
    static let maskKey = "s27w.mask"
    /// 他3 社内のお知らせを入れる（初めはオフ。会社の決まりの確かめ＝守5 は本人）
    static let noticeKey = "s27w.notice"
    private static let answeredKey = "s27w.answered"
    private static let doneKey = "s27w.done"
    private static let editsKey = "s27w.edits"
    private static let fetchedKey = "s27w.fetchedAt"

    private(set) var board: S27WBoard?
    private(set) var confirm: [S27WConfirmItem] = []
    /// 写しを最後に受け取った時刻（つながらないときは前のまま）
    private(set) var fetchedAt: Date?
    /// 最後に読みに行ってつながらなかった（前の写しを見せている）
    private(set) var offline = false
    private(set) var loaded = false
    /// 家の PC が仕事の口を持っているか（features。hello のあとに覚える）
    private(set) var offered: Bool
    private(set) var askOffered: Bool
    private(set) var confirmOffered: Bool
    /// 答えた確かめの id（次から出さない）
    private(set) var answered: Set<String>
    /// 端末で済みにした宿題（id → 日）。写しで済みになったら外す
    private(set) var localDone: [String: String]
    /// 本人が直した欄（id → 欄 → 値）。写しが同じになったら外す
    private(set) var edits: [String: [String: String]]
    private(set) var mask = S27WMask()
    var maskOn: Bool {
        didSet {
            UserDefaults.standard.set(maskOn, forKey: Self.maskKey)
            Tally.add(maskOn ? "s27w.mask.on" : "s27w.mask.off")
        }
    }
    var noticeOn: Bool {
        didSet {
            UserDefaults.standard.set(noticeOn, forKey: Self.noticeKey)
            Tally.add(noticeOn ? "s27w.notice.on" : "s27w.notice.off")
        }
    }
    /// ショートカットから渡された社内のお知らせの文（入れる画面を開いたら取る）
    var pendingNotice: String?

    @ObservationIgnored private var feedAt: Date?
    @ObservationIgnored private var tryAt: Date?
    @ObservationIgnored private var feeding = false

    init() {
        let d = UserDefaults.standard
        offered = d.bool(forKey: Self.offeredKey)
        askOffered = d.bool(forKey: Self.askKey)
        confirmOffered = d.bool(forKey: Self.confirmOfferedKey)
        maskOn = d.bool(forKey: Self.maskKey)
        noticeOn = d.bool(forKey: Self.noticeKey)
        answered = Set(d.stringArray(forKey: Self.answeredKey) ?? [])
        localDone = d.dictionary(forKey: Self.doneKey) as? [String: String] ?? [:]
        edits = (d.data(forKey: Self.editsKey)).flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        fetchedAt = d.object(forKey: Self.fetchedKey) as? Date
    }

    /// LifeLogApp の起動で 1 回だけ呼ぶ。live でなければ（テスト・画面の自動確認）動かさない
    static func install(_ pipeline: Pipeline, live: Bool) {
        self.pipeline = pipeline
        guard live, timer == nil else { return }
        Task { @MainActor in await S27WBook.shared.loadCopy() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in S27WBook.shared.tick() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            S27WBook.shared.tick()
        }
    }

    /// 1 分ごと
    func tick(now: Date = .now) {
        guard let pipeline = Self.pipeline else { return }
        noteFeatures(pipeline.homePC.features)
        guard offered, !feeding, feedAt.map({ now.timeIntervalSince($0) >= Self.feedEvery }) ?? true else { return }
        feedAt = now
        Task { await refresh(force: true, now: now) }
    }

    /// 家の PC の features を覚える（hello のあとだけ。まだ hello していない＝空のときは前のまま）
    func noteFeatures(_ features: Set<String>) {
        guard !features.isEmpty else { return }
        let work = features.contains(S27WRules.featureWork)
        let ask = features.contains(S27WRules.featureAsk)
        let conf = features.contains(S27WRules.featureConfirm)
        let d = UserDefaults.standard
        if work != offered {
            offered = work
            d.set(work, forKey: Self.offeredKey)
            if !work { S27WWorkCounts.clear(); WidgetCenter.shared.reloadTimelines(ofKind: S27WWorkCounts.kind) }
        }
        if ask != askOffered { askOffered = ask; d.set(ask, forKey: Self.askKey) }
        if conf != confirmOffered { confirmOffered = conf; d.set(conf, forKey: Self.confirmOfferedKey) }
    }

    /// 仕事の画面を開いたとき（1 分あけて）
    func opened() {
        Tally.add("s27w.open")
        Task { await refresh(force: false) }
    }

    // MARK: 写しを読む

    func refresh(force: Bool, now: Date = .now) async {
        guard let pipeline = Self.pipeline, !feeding else { return }
        let pc = pipeline.homePC
        noteFeatures(pc.features)
        guard pc.isConfigured, pc.features.contains(S27WRules.featureWork) else { return }
        if !force, let tryAt, now.timeIntervalSince(tryAt) < Self.openEvery { return }
        feeding = true
        tryAt = now
        defer { feeding = false }
        do {
            let data = try await pc.getJSONData("work", timeout: 15)
            let decoded: S27WBoard? = await Task.detached { S27WRules.board(data) }.value
            offline = false
            if let decoded {
                apply(decoded, now: now)
                await Self.write(data, name: Self.boardFile)
                Tally.add("s27w.read")
            } else if S27WRules.unavailable(data) {
                board = nil
                await Self.write(nil, name: Self.boardFile)
                S27WWorkCounts.clear()
                WidgetCenter.shared.reloadTimelines(ofKind: S27WWorkCounts.kind)
                Tally.add("s27w.read.none")
            } else {
                Tally.add("s27w.read.bad")
            }
        } catch {
            offline = true
            Tally.add("s27w.read.fail")
        }
        if pc.features.contains(S27WRules.featureConfirm),
           let data = try? await pc.getJSONData("work/confirm", timeout: 10), let items = S27WRules.confirmItems(data) {
            confirm = items
            await Self.write(data, name: Self.confirmFile)
            // もう届かない確かめの「答えた」の印は捨てる（溜めない）
            let ids = Set(items.map(\.id))
            let kept = answered.filter { ids.contains($0) }
            if kept.count != answered.count { answered = kept; saveAnswered() }
        }
    }

    private func apply(_ next: S27WBoard, now: Date) {
        board = next
        fetchedAt = now
        UserDefaults.standard.set(now, forKey: Self.fetchedKey)
        mask = S27WMask.make(next)
        let done = S27WRules.doneIDs(next)
        let keptDone = localDone.filter { !done.contains($0.key) }
        if keptDone.count != localDone.count { localDone = keptDone; saveDone() }
        let keptEdits = S27WRules.pruned(edits, board: next)
        if keptEdits != edits { edits = keptEdits; saveEdits() }
        if S27WRules.widgetCounts(next, now: now).write() {
            WidgetCenter.shared.reloadTimelines(ofKind: S27WWorkCounts.kind)
        }
    }

    /// 起動のとき、端末の写しを読む（ディスクは裏で読む）
    func loadCopy() async {
        guard !loaded else { return }
        loaded = true
        let boardData = await Self.read(Self.boardFile)
        let confirmData = await Self.read(Self.confirmFile)
        if board == nil, let boardData, let decoded = await Task.detached(operation: { S27WRules.board(boardData) }).value {
            board = decoded
            mask = S27WMask.make(decoded)
        }
        if confirm.isEmpty, let confirmData, let items = S27WRules.confirmItems(confirmData) { confirm = items }
    }

    // MARK: 場7 引く

    /// 家の PC の /work/ask（使えないときは端末の写しの中で）。fromPC は家の PC が答えたか
    func ask(_ query: String) async -> (answers: [S27WAnswer], fromPC: Bool) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], false) }
        Tally.add("s27w.ask")
        if let pc = Self.pipeline?.homePC, pc.isConfigured, pc.features.contains(S27WRules.featureAsk),
           let data = try? await pc.getJSONData("work/ask", query: [URLQueryItem(name: "q", value: String(q.prefix(100)))], timeout: 10),
           let list = S27WRules.answers(data) {
            return (list, true)
        }
        if !loaded { await loadCopy() }
        guard let board else { return ([], false) }
        return (S27WRules.localAnswers(board, query: q), false)
    }

    // MARK: K4 答える・直す・貼る

    /// 1 つためて送る（決まった形でなければ何もしない）
    @discardableResult
    private func send(kind: String, id: String, value: String, now: Date) -> Bool {
        guard let body = S27WRules.feedback(kind: kind, id: id, value: value, day: ReviewRules.dayKey(now)) else { return false }
        MothershipOutbox.enqueue(path: "feedback", body: body, now: now)
        Tally.add("s27w.send." + kind)
        if let pipeline = Self.pipeline { Task { await MothershipOutbox.send(pipeline.homePC) } }
        return true
    }

    /// 守6 まとめて 1 回の確かめ。送った数を返す
    @discardableResult
    func answerConfirm(_ picks: [String: String], now: Date = .now) -> Int {
        var sent = 0
        for pick in S27WRules.confirmAnswers(confirm, picks: picks) {
            guard send(kind: "work_confirm", id: pick.id, value: pick.value, now: now) else { continue }
            answered.insert(pick.id)
            sent += 1
        }
        if sent > 0 { saveAnswered() }
        return sent
    }

    var openConfirm: [S27WConfirmItem] { S27WRules.unanswered(confirm, answered: answered) }

    /// 宿題を済みにする・戻す
    func setDone(_ item: S27WItem, done: Bool, now: Date = .now) {
        guard send(kind: "work_done", id: item.id, value: done ? "done" : "undo", now: now) else { return }
        if done {
            localDone[item.id] = ReviewRules.dayKey(now)
        } else {
            localDone[item.id] = nil
        }
        saveDone()
    }

    func isDone(_ item: S27WItem) -> Bool { item.isDone || localDone[item.id] != nil }

    /// 人8 人・案件の名前・チーム・役割などを直す（直した欄だけ送る）。送れたら true
    @discardableResult
    func edit(id: String, changes: [String: String], now: Date = .now) -> Bool {
        guard let value = S27WRules.editValue(changes), send(kind: "work_edit", id: id, value: value, now: now) else { return false }
        var fields = edits[id] ?? [:]
        for (key, v) in changes where S27WRules.editFields.contains(key) {
            fields[key] = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        edits[id] = fields
        saveEdits()
        return true
    }

    /// 案6 本人が貼った数の文
    @discardableResult
    func pasteNumbers(projectID: String?, text: String, now: Date = .now) -> Bool {
        send(kind: "work_numbers", id: projectID ?? "", value: String(text.prefix(S27WRules.textLimit)), now: now)
    }

    /// 他3 社内のお知らせの文（設定がオンのときだけ）
    @discardableResult
    func sendNotice(_ text: String, now: Date = .now) -> Bool {
        guard noticeOn else { return false }
        return send(kind: "work_notice", id: "", value: String(text.prefix(S27WRules.textLimit)), now: now)
    }

    // MARK: 見せる（伏せる・直した欄）

    func t(_ text: String) -> String { maskOn ? mask.apply(text) : text }

    var activeMask: S27WMask? { maskOn ? mask : nil }

    func field(_ id: String, _ key: String) -> String? { edits[id]?[key] }

    func name(_ person: S27WPerson) -> String {
        let n = field(person.id, "name") ?? person.name
        return maskOn ? (mask.person(n) ?? n) : n
    }

    func name(_ ref: S27WPersonRef) -> String {
        let n = field(ref.id, "name") ?? ref.name
        return maskOn ? (mask.person(n) ?? n) : n
    }

    func name(_ project: S27WProject) -> String { t(field(project.id, "name") ?? project.name) }

    func client(_ project: S27WProject) -> String? {
        let c = field(project.id, "client") ?? project.client
        guard let c, !c.isEmpty else { return nil }
        return t(c)
    }

    func team(_ p: S27WPerson) -> String? { nonEmpty(field(p.id, "team") ?? p.team).map { t($0) } }
    func role(_ p: S27WPerson) -> String? { nonEmpty(field(p.id, "role") ?? p.role).map { t($0) } }
    func org(_ p: S27WPerson) -> String? { field(p.id, "org") ?? p.org }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: 置き場

    private static let boardFile = "work.json"
    private static let confirmFile = "confirm.json"

    nonisolated private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("S27W", isDirectory: true).appendingPathComponent(name)
    }

    /// 書く（nil なら消す）。中身は端末の中だけ（守1）
    nonisolated private static func write(_ data: Data?, name: String) async {
        await Task.detached {
            let u = S27WBook.url(name)
            guard let data else {
                try? FileManager.default.removeItem(at: u)
                return
            }
            if let old = try? Data(contentsOf: u), old == data { return }
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
    }

    nonisolated private static func read(_ name: String) async -> Data? {
        await Task.detached { try? Data(contentsOf: S27WBook.url(name)) }.value
    }

    private func saveAnswered() {
        UserDefaults.standard.set(Array(answered.sorted().suffix(500)), forKey: Self.answeredKey)
    }

    private func saveDone() {
        UserDefaults.standard.set(localDone, forKey: Self.doneKey)
    }

    private func saveEdits() {
        if let data = try? JSONEncoder().encode(edits) { UserDefaults.standard.set(data, forKey: Self.editsKey) }
    }
}

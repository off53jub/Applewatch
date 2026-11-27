import Foundation
import Observation

// s33（2026-11-27）アプリ担当 S33A の動き。決まりは S33ARules.swift、画面は S33AViews.swift。
// - K33-1: 家の PC の features に "s33" があるとき、GET /s33 を 10 分（仮）に 1 回と、画面を開いたとき（1 分あけて）に読む。
//   端末の Application Support/S33A/s33.json に写しを置き、つながらないときは前の写しを見せる。{"available":false} なら消す
// - K33-2: POST /feedback に ramen_mark（押したとき）・feature_seen（1 日 1 回・終わった日の数）・device_ok（版ごと・1 日 1 回にまとめて）。
//   どれも家の PC が "s33" を持っているときだけためる（受け口の無い PC に送って 5 回断られて捨てられないように）
// - 強16・強5: 今日のカードを押した数（Tally "s33a.card.<名前>"）・本人が畳んだカード・本人の並び（UserDefaults）
// 知らせ・問いは足さない。中身の文は記録（ログ）に書かない（Tally は数と種類の名前だけ）。

@MainActor
@Observable
final class S33ABook {
    static let shared = S33ABook()
    static var pipeline: Pipeline?
    private static var timer: Timer?

    static let offeredKey = "s33a.offered"
    static let hiddenKey = "s33a.hiddenCards"
    static let pinnedKey = "s33a.pinnedCards"
    static let cardsSinceKey = "s33a.cardsSince"
    static let seenSentKey = "s33a.seenSentDay"
    static let ramenKey = "s33a.ramenMarks"
    static let ramenLastKey = "s33a.ramenLast"
    private static let fetchedKey = "s33a.fetchedAt"

    /// 写しを読む間（仮 10 分）
    static let feedEvery: TimeInterval = 600
    /// 画面を開いたときに読み直すまでの間（仮 1 分）
    static let openEvery: TimeInterval = 60
    /// 続けて押したときの間（仮 10 分。そのあいだは「さっき付けました」）
    static let ramenAgain: TimeInterval = 600
    /// 押した位置として使う古さ（仮 30 分）
    static let ramenPointAge: TimeInterval = 1800

    private(set) var offered: Bool
    private(set) var feed: S33AFeed?
    private(set) var fetchedAt: Date?
    private(set) var offline = false
    /// 本人が畳んだ今日のカード（戻せる）
    private(set) var hiddenCards: Set<S24Today.Card>
    /// 本人が決めた今日の並び（上に出す順）
    private(set) var pinnedCards: [S24Today.Card]
    /// 年 → 押した数（端末の中だけ）
    private(set) var ramenMarks: [String: Int]
    private(set) var ramenLast: Date?

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var feeding = false
    @ObservationIgnored private var feedAt: Date?
    @ObservationIgnored private var tryAt: Date?

    init() {
        let d = UserDefaults.standard
        offered = d.bool(forKey: Self.offeredKey)
        hiddenCards = Set((d.stringArray(forKey: Self.hiddenKey) ?? []).compactMap { S24Today.Card(rawValue: $0) })
        pinnedCards = (d.stringArray(forKey: Self.pinnedKey) ?? []).compactMap { S24Today.Card(rawValue: $0) }
        ramenMarks = d.dictionary(forKey: Self.ramenKey) as? [String: Int] ?? [:]
        ramenLast = d.object(forKey: Self.ramenLastKey) as? Date
        fetchedAt = d.object(forKey: Self.fetchedKey) as? Date
    }

    /// LifeLogApp の起動で 1 回だけ呼ぶ。live でなければ（テスト・画面の自動確認）写しを読むだけ
    static func install(_ pipeline: Pipeline, live: Bool) {
        self.pipeline = pipeline
        if UserDefaults.standard.string(forKey: cardsSinceKey) == nil {
            UserDefaults.standard.set(ReviewRules.dayKey(.now), forKey: cardsSinceKey)
        }
        Task { @MainActor in await S33ABook.shared.loadCopy() }
        guard live, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in S33ABook.shared.tick() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(50))
            S33ABook.shared.tick()
        }
    }

    /// 1 分ごと
    func tick(now: Date = .now) {
        guard let pipeline = Self.pipeline else { return }
        noteFeatures(pipeline.homePC.features)
        guard offered else { return }
        sendDaily(now: now)
        guard !feeding, feedAt.map({ now.timeIntervalSince($0) >= Self.feedEvery }) ?? true else { return }
        feedAt = now
        Task { await refresh(force: true, now: now) }
    }

    /// 家の PC の features を覚える（空＝まだ hello していないときは前のまま）
    func noteFeatures(_ features: Set<String>) {
        guard !features.isEmpty else { return }
        let on = features.contains(S33ARules.feature)
        guard on != offered else { return }
        offered = on
        UserDefaults.standard.set(on, forKey: Self.offeredKey)
        if !on {
            feed = nil
            Task { await Self.write(nil) }
        }
    }

    /// 画面を開いたとき（1 分あけて読み直す）
    func opened() {
        Task {
            await loadCopy()
            await refresh(force: false)
        }
    }

    func refresh(force: Bool, now: Date = .now) async {
        guard let pipeline = Self.pipeline, !feeding else { return }
        let pc = pipeline.homePC
        noteFeatures(pc.features)
        guard pc.isConfigured, pc.features.contains(S33ARules.feature) else { return }
        if !force, let tryAt, now.timeIntervalSince(tryAt) < Self.openEvery { return }
        feeding = true
        tryAt = now
        defer { feeding = false }
        do {
            let data = try await pc.getJSONData("s33", timeout: 15)
            let reply: S33AReply = await Task.detached { S33ARules.reply(data) }.value
            offline = false
            switch reply {
            case .feed(let next):
                feed = next
                fetchedAt = now
                UserDefaults.standard.set(now, forKey: Self.fetchedKey)
                await Self.write(data)
                Tally.add("s33a.read")
            case .none:
                feed = nil
                await Self.write(nil)
                Tally.add("s33a.read.none")
            case .bad:
                Tally.add("s33a.read.bad")
            }
        } catch {
            offline = true
            Tally.add("s33a.read.fail")
        }
    }

    /// 端末の写しを読む（ディスクは裏で読む）
    func loadCopy() async {
        guard !loaded else { return }
        loaded = true
        guard offered, feed == nil, let data = await Self.read() else { return }
        let reply: S33AReply = await Task.detached { S33ARules.reply(data) }.value
        if case .feed(let copy) = reply, feed == nil { feed = copy }
    }

    // MARK: 強22 ラーメンの 1 押し

    var ramenThisYear: Int { ramenMarks[Self.yearKey(.now)] ?? 0 }

    /// さっき押したか（続けて押したとき、もう 1 杯かを分けるため）
    func ramenRecently(now: Date = .now) -> Bool {
        ramenLast.map { now.timeIntervalSince($0) < Self.ramenAgain && now >= $0 } ?? false
    }

    /// 押した時刻と、その場の場所（取れなければ null）で ramen_mark を 1 つためて送る。問い・知らせにはしない
    @discardableResult
    func markRamen(now: Date = .now) async -> Bool {
        guard let pipeline = Self.pipeline, offered else { return false }
        let point = pipeline.places.recentPoint(at: now, maxAge: Self.ramenPointAge)
        var place: String?
        if point != nil { place = await pipeline.places.name(at: now) }
        guard let body = S33ARules.ramenBody(at: now, place: place, lat: point?.latitude, lon: point?.longitude) else { return false }
        MothershipOutbox.enqueue(path: "feedback", body: body, now: now)
        let year = Self.yearKey(now)
        ramenMarks[year, default: 0] += 1
        let keepFrom = String((Int(year) ?? 0) - 1)  // 去年までの数だけ残す
        ramenMarks = ramenMarks.filter { $0.key >= keepFrom }
        ramenLast = now
        UserDefaults.standard.set(ramenMarks, forKey: Self.ramenKey)
        UserDefaults.standard.set(now, forKey: Self.ramenLastKey)
        Tally.add("s33a.ramen.mark")
        Task { await MothershipOutbox.send(pipeline.homePC) }
        return true
    }

    private static func yearKey(_ date: Date) -> String {
        String(Calendar(identifier: .gregorian).component(.year, from: date))
    }

    // MARK: 強5・強8 1 日 1 回

    /// 終わった日の使われた数（feature_seen）と、この版で開いて落ちずに閉じた画面（device_ok）をためる
    func sendDaily(now: Date = .now) {
        guard let pipeline = Self.pipeline, offered, pipeline.homePC.features.contains(S33ARules.feature) else { return }
        let today = ReviewRules.dayKey(now)
        var queued = 0
        let defaults = UserDefaults.standard
        let days = S33ARules.seenDaysToSend(lastSent: defaults.string(forKey: Self.seenSentKey), today: today)
        if !days.isEmpty {
            let all = Tally.days(9, now: now)
            for day in days {
                if let body = S33ARules.seenBody(day: day, tally: all[day] ?? [:]) {
                    MothershipOutbox.enqueue(path: "feedback", body: body, now: now)
                    queued += 1
                }
            }
            if let last = days.last { defaults.set(last, forKey: Self.seenSentKey) }
            Tally.add("s33a.seen.sent", days.count)
        }
        queued += S33ADevice.sendIfDue(build: String(AppBuild.current), today: today, now: now)
        if queued > 0 { Task { await MothershipOutbox.send(pipeline.homePC) } }
    }

    // MARK: 強16・強5 今日のカード

    nonisolated static func cardTapped(_ card: S24Today.Card) {
        Tally.add(S33AOrder.tallyName(card))
    }

    /// 数え始めてからの日数
    var cardCountedDays: Int? {
        guard let since = UserDefaults.standard.string(forKey: Self.cardsSinceKey) else { return nil }
        return S24Entries.daysBetween(since, ReviewRules.dayKey(.now))
    }

    func cardUses(now: Date = .now) -> [S24Today.Card: Int] {
        S33AOrder.uses(Tally.sums(days: S33AOrder.unusedDays, now: now))
    }

    /// 今日のカードの並び（強16）
    func layout(_ base: (top: [S24Today.Card], more: [S24Today.Card])) -> (top: [S24Today.Card], more: [S24Today.Card]) {
        S33AOrder.apply(top: base.top, more: base.more, uses: cardUses(), pinned: pinnedCards, hidden: hiddenCards,
                        countedDays: cardCountedDays)
    }

    func hide(_ card: S24Today.Card) {
        guard !S33AOrder.fixed.contains(card), card != .record else { return }
        hiddenCards.insert(card)
        pinnedCards.removeAll { $0 == card }
        saveCards()
        Tally.add("s33a.card.hide")
    }

    func unhide(_ card: S24Today.Card) {
        guard hiddenCards.remove(card) != nil else { return }
        saveCards()
        Tally.add("s33a.card.unhide")
    }

    /// 上に出す（本人の並びの終わりに足す）・外す
    func togglePin(_ card: S24Today.Card) {
        guard !S33AOrder.fixed.contains(card), card != .record else { return }
        if pinnedCards.contains(card) {
            pinnedCards.removeAll { $0 == card }
        } else {
            pinnedCards.append(card)
            hiddenCards.remove(card)
        }
        saveCards()
        Tally.add("s33a.card.pin")
    }

    func movePin(_ card: S24Today.Card, up: Bool) {
        guard let i = pinnedCards.firstIndex(of: card) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < pinnedCards.count else { return }
        pinnedCards.swapAt(i, j)
        saveCards()
    }

    private func saveCards() {
        UserDefaults.standard.set(hiddenCards.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
        UserDefaults.standard.set(pinnedCards.map(\.rawValue), forKey: Self.pinnedKey)
    }

    // MARK: 置き場（中身は端末の中だけ）

    nonisolated private static var file: URL {
        URL.applicationSupportDirectory.appendingPathComponent("S33A", isDirectory: true).appendingPathComponent("s33.json")
    }

    nonisolated private static func write(_ data: Data?) async {
        await Task.detached {
            let u = S33ABook.file
            guard let data else {
                try? FileManager.default.removeItem(at: u)
                return
            }
            if let old = try? Data(contentsOf: u), old == data { return }
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
    }

    nonisolated private static func read() async -> Data? {
        await Task.detached { try? Data(contentsOf: S33ABook.file) }.value
    }
}

// MARK: - 強8 実機で動いた印（版ごと）

/// 画面を開いた（CountsOpen の onAppear）・閉じた（onDisappear）を版ごとに覚える。
/// 開いたあと落ちずに閉じた画面だけを「動いた」にする（開いたまま落ちた・アプリを閉じた画面は入れない）
@MainActor
enum S33ADevice {
    struct State: Codable, Equatable {
        var build: String
        /// いま開いている画面
        var open: [String] = []
        /// 開いて落ちずに閉じた画面
        var ok: [String] = []
        /// 送った画面
        var sent: [String] = []
        /// 最後に送った日
        var sentDay: String?
    }

    static let key = "s33a.device"
    private static var cache: State?

    private static func load(build: String) -> State {
        if let cache, cache.build == build { return cache }
        let saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        // 版が変わったら初めから
        let state = (saved?.build == build) ? saved! : State(build: build)
        cache = state
        return state
    }

    private static func save(_ s: State) {
        cache = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 決まり: 開いた（同じ名前は 1 つ）
    static func opening(_ s: State, _ name: String) -> State {
        guard S33ARules.isName(name), !s.open.contains(name) else { return s }
        var next = s
        next.open.append(name)
        return next
    }

    /// 決まり: 閉じた（開いていたものだけ。送っていなければ「動いた」に）
    static func closing(_ s: State, _ name: String) -> State {
        guard let i = s.open.firstIndex(of: name) else { return s }
        var next = s
        next.open.remove(at: i)
        if !next.ok.contains(name) && !next.sent.contains(name) { next.ok.append(name) }
        return next
    }

    /// 決まり: 今日まだ送っていなければ、送る名前（送っていない「動いた」）
    static func due(_ s: State, today: String) -> [String] {
        guard s.sentDay != today else { return [] }
        return s.ok.filter { !s.sent.contains($0) }
    }

    static func opened(_ name: String) {
        let build = String(AppBuild.current)
        let s = load(build: build)
        let next = opening(s, name)
        if next != s { save(next) }
    }

    static func closed(_ name: String) {
        let build = String(AppBuild.current)
        let s = load(build: build)
        let next = closing(s, name)
        if next != s { save(next) }
    }

    /// 1 日 1 回、送っていない「動いた」をまとめてためる。ためた数を返す（版が 0＝手元の組み立ては送らない）
    static func sendIfDue(build: String, today: String, now: Date) -> Int {
        guard build != "0" else { return 0 }
        var s = load(build: build)
        let names = due(s, today: today)
        guard !names.isEmpty else { return 0 }
        let bodies = S33ARules.deviceBodies(build: build, screens: names)
        for body in bodies { MothershipOutbox.enqueue(path: "feedback", body: body, now: now) }
        s.sent += names
        s.ok.removeAll { names.contains($0) }
        s.sentDay = today
        save(s)
        Tally.add("s33a.device.sent", names.count)
        return bodies.count
    }
}

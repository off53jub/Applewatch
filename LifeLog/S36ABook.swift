import Foundation
import Observation

// s36（2026-11-28）アプリ担当 S36A の動き。決まりは S36ARules.swift、画面は S36AViews.swift。
// - K36-1: 家の PC の features に "s36" があるとき、GET /s36 を 10 分（仮）に 1 回（S34ABook.tick から）と、仕事タブを開いたとき
//   （1 分あけて）に読む。端末の Application Support/S36A/s36.json に写しを置き、つながらないときは前の写しを見せる。
//   {"available":false} なら消す。features に "s36" が無いときは何もしない（今までどおり）
// - 大2: 置く文（setup）を写した版を端末に覚える（setup_version が変わったら「置き直してください」の帯）。毎日の 1 語は
//   置く文を 1 回は写したあとだけ、今の 3 つのコピーのボタン（S34ABook.promptText）が写す
// - K36-2: 表・一覧の写真は、まとめとは別の新しい id で POST /work/photo に送る（POST /work/digest は送らない）
// - K36-3: 止める候補の「止める／残す」を POST /s36/stop（"s36stop" があるときだけ）。押したものは端末に覚え、次の写しで
//   state が変わったら忘れる
// 知らせ・問いは足さない。中身の文は記録（ログ）に書かない（Tally は数と種類の名前だけ）。

@MainActor
@Observable
final class S36ABook {
    static let shared = S36ABook()

    static let offeredKey = "s36a.offered"
    static let featuresKey = "s36a.features"
    static let copiedKey = "s36a.setup.copied"
    static let fetchedKey = "s36a.fetchedAt"
    private static let answeredKey = "s36a.stop.answered"

    /// 写しを読む間（仮 10 分）
    static let feedEvery: TimeInterval = 600
    /// 画面を開いたときに読み直すまでの間（仮 1 分）
    static let openEvery: TimeInterval = 60

    private(set) var offered: Bool
    /// 覚えている features（S36ARules.remembered のうち、家の PC が持っていたもの）
    private(set) var knownFeatures: Set<String>
    private(set) var feed: S36AFeed?
    private(set) var fetchedAt: Date?
    private(set) var offline = false
    /// 置く文を最後に写した版（無ければ一度も写していない）
    private(set) var copiedVersion: String?
    /// 止める候補に押した答え（id → "stop"|"keep"）
    private(set) var answered: [String: String]
    /// 表・一覧の写真を送った結果の一文（仕事タブに出す・端末の中だけ）
    var tableNote: String?

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var feeding = false
    @ObservationIgnored private var feedAt: Date?
    @ObservationIgnored private var tryAt: Date?

    init() {
        let d = UserDefaults.standard
        offered = d.bool(forKey: Self.offeredKey)
        knownFeatures = Set(d.stringArray(forKey: Self.featuresKey) ?? [])
        fetchedAt = d.object(forKey: Self.fetchedKey) as? Date
        copiedVersion = d.string(forKey: Self.copiedKey)
        answered = d.dictionary(forKey: Self.answeredKey) as? [String: String] ?? [:]
    }

    private var pc: HomePC? { S34ABook.pipeline?.homePC ?? S27WBook.pipeline?.homePC }

    /// いまの features（hello の前は覚えている分）
    func features(_ live: Set<String>? = nil) -> Set<String> {
        let now: Set<String> = live ?? pc?.features ?? []
        return now.isEmpty ? knownFeatures : now
    }

    func has(_ name: String) -> Bool { features().contains(name) }

    /// 1 分ごと（S34ABook.tick から）
    func tick(now: Date = .now) {
        if !loaded { Task { await loadCopy() } }
        guard let pc else { return }
        noteFeatures(pc.features)
        guard offered, !feeding, feedAt.map({ now.timeIntervalSince($0) >= Self.feedEvery }) ?? true else { return }
        feedAt = now
        Task { await refresh(force: true, now: now) }
    }

    /// 家の PC の features を覚える（空＝まだ hello していないときは前のまま）
    func noteFeatures(_ live: Set<String>) {
        guard !live.isEmpty else { return }
        let keep: Set<String> = Set(S36ARules.remembered.filter { live.contains($0) })
        if keep != knownFeatures {
            knownFeatures = keep
            UserDefaults.standard.set(keep.sorted(), forKey: Self.featuresKey)
        }
        let on = live.contains(S36ARules.feature)
        guard on != offered else { return }
        offered = on
        UserDefaults.standard.set(on, forKey: Self.offeredKey)
        if !on {
            feed = nil
            Task { await Self.write(nil) }
        }
    }

    /// 仕事タブ・奥を開いたとき（1 分あけて読み直す）
    func opened() {
        Task {
            await loadCopy()
            await refresh(force: false)
        }
    }

    func refresh(force: Bool, now: Date = .now) async {
        guard let pc, !feeding else { return }
        noteFeatures(pc.features)
        guard pc.isConfigured, pc.features.contains(S36ARules.feature) else { return }
        if !force, let tryAt, now.timeIntervalSince(tryAt) < Self.openEvery { return }
        feeding = true
        tryAt = now
        defer { feeding = false }
        do {
            let data = try await pc.getJSONData("s36", timeout: 15)
            let reply: S36AReply = await Task.detached { S36ARules.reply(data) }.value
            offline = false
            switch reply {
            case .feed(let next):
                feed = next
                fetchedAt = now
                UserDefaults.standard.set(now, forKey: Self.fetchedKey)
                forgetSettled(next.stop)
                await Self.write(data)
                Tally.add("s36a.read")
            case .none:
                feed = nil
                await Self.write(nil)
                Tally.add("s36a.read.none")
            case .bad:
                Tally.add("s36a.read.bad")
            }
        } catch {
            offline = true
            Tally.add("s36a.read.fail")
        }
    }

    /// 端末の写しを読む（ディスクは裏で読む）
    func loadCopy() async {
        guard !loaded else { return }
        loaded = true
        guard offered, feed == nil, let data = await Self.read() else { return }
        let reply: S36AReply = await Task.detached { S36ARules.reply(data) }.value
        if case .feed(let copy) = reply, feed == nil { feed = copy }
    }

    // MARK: 大2 頼み方

    /// 仕事タブに「職場の Claude への頼み方」を出すか（置く文が届いているとき）
    var hasPromptPlace: Bool {
        guard offered, let setup = feed?.prompt?.setup else { return false }
        return !setup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var setupBand: S36ARules.SetupBand? {
        guard hasPromptPlace else { return nil }
        return S36ARules.setupBand(version: feed?.prompt?.setupVersion, copied: copiedVersion)
    }

    /// 置く文を写した（写した版を覚える）
    func setupCopied() -> String? {
        guard hasPromptPlace, let setup = feed?.prompt?.setup else { return nil }
        let version: String = feed?.prompt?.setupVersion ?? ""
        copiedVersion = version.isEmpty ? "copied" : version
        UserDefaults.standard.set(copiedVersion, forKey: Self.copiedKey)
        Tally.add("s36a.setup.copy")
        return setup
    }

    /// 毎日の 1 語（使えないときは nil。今の頼み方のまま）
    func dailyPrompt(now: Date = .now) -> String? {
        guard offered else { return nil }
        return S36ARules.daily(feed?.prompt, copiedVersion: copiedVersion, fetchedAt: fetchedAt, now: now)
    }

    // MARK: K36-2 表・一覧の写真

    /// 表・一覧の写真を送る（まとめとは別の新しい id。返すのは取り込む画面を閉じたあとに出す一文）
    func sendTable(_ kind: S36APhotoKind, day: String, photos: [Data], now: Date = .now) -> String {
        guard let pc, pc.isConfigured, S36APhotoRules.kindsOffered(pc.features) else {
            Tally.add("s36a.table.none")
            return "家の PC が表の写真をまだ受けられないので、送っていません。"
        }
        guard let job = S36APhotoRules.tableJob(id: UUID().uuidString, day: day, photos: photos, kind: kind, features: pc.features) else {
            return "送れる写真がありません。"
        }
        let label: String = kind.label
        let count: Int = job.count
        tableNote = label + "の写真 \(count) 枚を家の PC へ送っています…"
        Tally.add("s36a.table.send")
        Tally.add("s36a.table." + kind.rawValue)
        Task {
            let run: String? = await S35PhotoBook.shared.send([job], pc: pc, now: now)
            self.tableNote = run == nil
                ? label + "の写真を送れませんでした（今日のうちに 1 回だけ送り直します）。"
                : label + "の写真 \(count) 枚を送りました。家の PC が読んで、数を作り直します。"
        }
        return label + "の写真 \(count) 枚を家の PC へ送っています（まとめには入れません）。"
    }

    // MARK: K36-3 止める候補

    var stopOffered: Bool { has(S36ARules.featureStop) }

    var candidates: [S36AStopItem] { S36ARules.candidates(feed?.stop, answered: answered) }
    var settled: [S36AStopItem] { S36ARules.settled(feed?.stop, answered: answered) }

    /// 1 件に答える（本人が押したときだけ）。送れたら true
    func answer(_ item: S36AStopItem, choice: String) async -> Bool {
        guard let pc, pc.isConfigured, pc.features.contains(S36ARules.featureStop),
              let body = S36ARules.stopBody(id: item.id, choice: choice) else { return false }
        do {
            _ = try await pc.postJSONData("s36/stop", body: body, timeout: 15)
        } catch {
            Tally.add("s36a.stop.fail")
            return false
        }
        answered[item.id] = choice
        UserDefaults.standard.set(answered, forKey: Self.answeredKey)
        Tally.add(choice == "stop" ? "s36a.stop.stop" : "s36a.stop.keep")
        return true
    }

    /// 写しで state が candidate でなくなったもの・一覧から消えたものは、端末の覚えを外す
    private func forgetSettled(_ stop: S36AStop?) {
        guard !answered.isEmpty else { return }
        let still: Set<String> = Set((stop?.items ?? []).filter { ($0.state ?? "candidate") == "candidate" }.map(\.id))
        let next: [String: String] = answered.filter { still.contains($0.key) }
        guard next != answered else { return }
        answered = next
        UserDefaults.standard.set(next, forKey: Self.answeredKey)
    }

    // MARK: 置き場（中身は端末の中だけ）

    nonisolated private static var file: URL {
        URL.applicationSupportDirectory.appendingPathComponent("S36A", isDirectory: true).appendingPathComponent("s36.json")
    }

    nonisolated private static func write(_ data: Data?) async {
        await Task.detached {
            let u = S36ABook.file
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
        await Task.detached { try? Data(contentsOf: S36ABook.file) }.value
    }

    /// 試し用: 写しを入れる（画面の自動確認と LifeLogTests）
    func use(_ feed: S36AFeed?, fetchedAt: Date? = .now, offered: Bool = true) {
        self.feed = feed
        self.fetchedAt = fetchedAt
        self.offered = offered
        loaded = true
    }

    /// 試し用: 写した版を入れる・消す
    func setCopiedVersion(_ v: String?) {
        copiedVersion = v
        if let v { UserDefaults.standard.set(v, forKey: Self.copiedKey) } else { UserDefaults.standard.removeObject(forKey: Self.copiedKey) }
    }
}

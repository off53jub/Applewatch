import Foundation
import Observation
import Photos
import UIKit

// s34（2026-11-27）アプリ担当 S34A の動き。決まりは S34ARules.swift、画面は S34AViews.swift。
// - K34-1: 家の PC の features に "s34" があるとき、GET /s34 を 10 分（仮）に 1 回と、画面を開いたとき（1 分あけて）に読む。
//   端末の Application Support/S34A/s34.json に写しを置き、つながらないときは前の写しを見せる。{"available":false} なら消す
// - 円1（K34-3）: 設定の「写真から仕事のまとめを拾う」（初めはオフ）を本人が入れたときだけ、写真の中から職場のまとめ
//   （決まった見出しが写っているもの）を自分で見つける。文字は iPhone の中の Vision で読む（Pipeline.recognizeText）。
//   見つけた文字は、仕事のまとめの帳に入れて（同じ日に同じ文があれば入れない）、今の共有と同じ道（S30WBook.saved →
//   POST /work/digest）で送る。同じ写真は 2 回読まない・ほかの写真の文字はその場で捨てる。
//   s35（2026-11-28・K35）: 家の PC の features に "workphoto" があるときだけ、まとめと見た組の写真そのものも
//   （縮めた JPEG・12 枚まで）同じ id で送る（文のあと。S30WBook.saved → S35PhotoBook）。ほかの写真は送らない。
//   動くのは、アプリが前にあるとき（10 分に 1 回・仮）と、今ある裏の処理の枠（充電中だけ。S26A の写真の見分けと同じ）。
//   写真の許可が無ければ何もしない。許可を求めるのは、本人がスイッチを入れたときだけ（S34APhotoScan.turnedOn）。
// 知らせ・問いは足さない。中身の文は記録（ログ）に書かない（Tally は数と種類の名前だけ）。

@MainActor
@Observable
final class S34ABook {
    static let shared = S34ABook()
    static var pipeline: Pipeline?
    private static var timer: Timer?

    static let offeredKey = "s34a.offered"
    private static let fetchedKey = "s34a.fetchedAt"

    /// 写しを読む間（仮 10 分）
    static let feedEvery: TimeInterval = 600
    /// 画面を開いたときに読み直すまでの間（仮 1 分）
    static let openEvery: TimeInterval = 60

    private(set) var offered: Bool
    private(set) var feed: S34AFeed?
    private(set) var fetchedAt: Date?
    private(set) var offline = false

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var feeding = false
    @ObservationIgnored private var feedAt: Date?
    @ObservationIgnored private var tryAt: Date?

    init() {
        let d = UserDefaults.standard
        offered = d.bool(forKey: Self.offeredKey)
        fetchedAt = d.object(forKey: Self.fetchedKey) as? Date
    }

    /// LifeLogApp の起動で 1 回だけ呼ぶ。live でなければ（テスト・画面の自動確認）写しを読むだけ
    static func install(_ pipeline: Pipeline, live: Bool) {
        self.pipeline = pipeline
        Task { @MainActor in await S34ABook.shared.loadCopy() }
        Task { @MainActor in await S36ABook.shared.loadCopy() }  // s36: K36-1 の写し（S36ABook.swift）
        guard live, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in S34ABook.shared.tick() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(40))
            S34ABook.shared.tick()
        }
    }

    /// 1 分ごと
    func tick(now: Date = .now) {
        S34APhotoScan.shared.tick(now: now)
        S34AVoiceBook.shared.tick(now: now)  // 自6・自7 声の見本（S34AVoice.swift。6 時間に 1 回）
        S35PhotoBook.shared.tick(now: now)  // s35: 送れなかった仕事のまとめの写真を、開いたあと 1 回だけ送り直す（S35PhotoBook.swift）
        S36ABook.shared.tick(now: now)  // s36: GET /s36（K36-1）を 10 分に 1 回（S36ABook.swift）
        guard let pipeline = Self.pipeline else { return }
        noteFeatures(pipeline.homePC.features)
        guard offered else { return }
        guard !feeding, feedAt.map({ now.timeIntervalSince($0) >= Self.feedEvery }) ?? true else { return }
        feedAt = now
        Task { await refresh(force: true, now: now) }
    }

    /// 家の PC の features を覚える（空＝まだ hello していないときは前のまま）
    func noteFeatures(_ features: Set<String>) {
        guard !features.isEmpty else { return }
        let on = features.contains(S34ARules.feature)
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
        guard pc.isConfigured, pc.features.contains(S34ARules.feature) else { return }
        if !force, let tryAt, now.timeIntervalSince(tryAt) < Self.openEvery { return }
        feeding = true
        tryAt = now
        defer { feeding = false }
        do {
            let data = try await pc.getJSONData("s34", timeout: 15)
            let reply: S34AReply = await Task.detached { S34ARules.reply(data) }.value
            offline = false
            switch reply {
            case .feed(let next):
                feed = next
                fetchedAt = now
                UserDefaults.standard.set(now, forKey: Self.fetchedKey)
                await Self.write(data)
                Tally.add("s34a.read")
            case .none:
                feed = nil
                await Self.write(nil)
                Tally.add("s34a.read.none")
            case .bad:
                Tally.add("s34a.read.bad")
            }
        } catch {
            offline = true
            Tally.add("s34a.read.fail")
        }
    }

    /// 端末の写しを読む（ディスクは裏で読む）
    func loadCopy() async {
        guard !loaded else { return }
        loaded = true
        guard offered, feed == nil, let data = await Self.read() else { return }
        let reply: S34AReply = await Task.detached { S34ARules.reply(data) }.value
        if case .feed(let copy) = reply, feed == nil { feed = copy }
    }

    /// 円2: その日の頼み方（届いた 1 つの文が無い・古いときは今の頼み方）
    func promptText(day: String, now: Date = .now) -> String {
        // s36 大2: K36-1 の毎日の 1 語が届いていて、置く文を 1 回写したことがあればそれ（S36ABook.dailyPrompt）
        if let daily = S36ABook.shared.dailyPrompt(now: now) { return daily }
        if offered, let text = S34APrompt.pick(feed?.prompt, day: day, fetchedAt: fetchedAt, now: now) {
            return text
        }
        return WorkDigestPrompt.full(day: day)
    }

    /// 円2: 届いた 1 つの文を使っているか
    func usesFeedPrompt(day: String, now: Date = .now) -> Bool {
        offered && S34APrompt.pick(feed?.prompt, day: day, fetchedAt: fetchedAt, now: now) != nil
    }

    // MARK: 置き場（中身は端末の中だけ）

    nonisolated private static var file: URL {
        URL.applicationSupportDirectory.appendingPathComponent("S34A", isDirectory: true).appendingPathComponent("s34.json")
    }

    nonisolated private static func write(_ data: Data?) async {
        await Task.detached {
            let u = S34ABook.file
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
        await Task.detached { try? Data(contentsOf: S34ABook.file) }.value
    }
}

// MARK: - 円1 写真から仕事のまとめを見つける（K34-3）

@MainActor
@Observable
final class S34APhotoScan {
    static let shared = S34APhotoScan()

    /// 設定「写真から仕事のまとめを拾う」（初めはオフ）
    static let onKey = "s34a.photo.on"
    private static let onAtKey = "s34a.photo.onAt"
    private static let lastKey = "s34a.photo.last"
    private static let seenKey = "s34a.photo.seen"
    private static let foundKey = "s34a.photo.found"
    private static let foundAtKey = "s34a.photo.foundAt"
    private static let entriesKey = "s34a.photo.entries"
    /// 前にあるときに見る間（仮 10 分）
    static let every: TimeInterval = 600

    /// 拾ったまとめの数（端末の中だけ・数だけ）
    private(set) var found: Int
    private(set) var foundAt: Date?
    /// 拾って入れたまとめの id（仕事のまとめの一覧で「写真から自動で」と出す）
    private(set) var entryIDs: Set<String>
    private(set) var running = false

    @ObservationIgnored private var ranAt: Date?

    init() {
        let d = UserDefaults.standard
        found = d.integer(forKey: Self.foundKey)
        foundAt = d.object(forKey: Self.foundAtKey) as? Date
        entryIDs = Set(d.stringArray(forKey: Self.entriesKey) ?? [])
    }

    static var isOn: Bool { UserDefaults.standard.bool(forKey: onKey) }

    /// 本人がスイッチを入れた。入れた時刻を覚え、写真の許可がまだ聞かれていなければ、ここで 1 回だけ聞く。
    /// 返すのは、そのあとに見せる一文（許可があれば nil）
    func turnedOn(now: Date = .now) async -> String? {
        UserDefaults.standard.set(now, forKey: Self.onAtKey)
        Tally.add("s34a.photo.on")
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined, DayPhotos.canAsk {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard DayPhotos.allowed(status) else {
            Tally.add("s34a.photo.noPermission")
            return "写真の許可が無いので、何もしていません。iPhone の設定 → LifeLog → 写真 で許可すると動きます。"
        }
        ranAt = nil
        Task { await self.scan(now: .now) }
        return nil
    }

    func turnedOff() {
        Tally.add("s34a.photo.off")
    }

    /// 1 分ごと（S34ABook.tick から）。前にあるときは 10 分に 1 回、裏では充電中だけ
    func tick(now: Date = .now) {
        guard Self.isOn, DayPhotos.isAllowed, !running else { return }
        let active = UIApplication.shared.applicationState == .active
        guard active || S26ASettings.charging else { return }
        if let ranAt, now.timeIntervalSince(ranAt) < Self.every { return }
        ranAt = now
        Task { await scan(now: now) }
    }

    /// 仕事タブを開いたとき（前にあるので、10 分あいていれば見る）
    func opened(now: Date = .now) { tick(now: now) }

    func scan(now: Date = .now) async {
        guard Self.isOn, DayPhotos.isAllowed, !running, let pipeline = S34ABook.pipeline else { return }
        running = true
        defer { running = false }
        let d = UserDefaults.standard
        let last = d.object(forKey: Self.lastKey) as? Date
        let onAt = d.object(forKey: Self.onAtKey) as? Date
        let since = S34APhotoRules.since(last: last, onAt: onAt, now: now)
        let cutoff = now.addingTimeInterval(-S34APhotoRules.settle)
        guard since < cutoff else { return }
        var seen: [String] = d.stringArray(forKey: Self.seenKey) ?? []
        let seenSet = Set(seen)

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate > %@ AND creationDate <= %@",
                                        PHAssetMediaType.image.rawValue, since as NSDate, cutoff as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = S34APhotoRules.perRun
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        let full = assets.count >= S34APhotoRules.perRun

        // 文字を読む（iPhone の中だけ）。読んだ文字はこの関数の中だけで持ち、まとめでなければ捨てる
        var shots: [S34AShot] = []
        var times: [String: Date] = [:]
        var byID: [String: PHAsset] = [:]
        for asset in assets {
            guard let taken = asset.creationDate else { continue }
            times[asset.localIdentifier] = taken
            byID[asset.localIdentifier] = asset
            if seenSet.contains(asset.localIdentifier) { continue }
            var text = ""
            if let big = await DayPhotos.image(asset, size: CGSize(width: 1800, height: 1800), fit: true, network: false) {
                text = await Pipeline.recognizeText(big)
            }
            shots.append(S34AShot(id: asset.localIdentifier, at: taken, text: text))
        }
        let split = S34APhotoRules.held(shots, full: full)
        let groups = S34APhotoRules.groups(split.now)

        var added: [WorkDigest.Entry] = []
        var photos: [String: [Data]] = [:]
        let sendPhotos: Bool = S35PhotoRules.offered(pipeline.homePC.features)
        for group in groups {
            let text = S34APhotoRules.text(of: group)
            let taken = group.last?.at ?? now
            var first: WorkDigest.Entry?
            for piece in S34APhotoRules.days(text, takenAt: taken) {
                let parsed = WorkDigestParser.parse(piece.text, today: taken)
                let sections: WorkDigest.Sections? = parsed.found ? parsed.sections : nil
                if let entry = pipeline.workDigests.add(day: piece.day, text: piece.text, sections: sections, source: .photo, now: now) {
                    added.append(entry)
                    if first == nil { first = entry }
                }
            }
            // s35: 組の写真そのもの（まとめの写真だけ）を縮めて、組の最初のまとめに付ける（何日分かに分かれたときも最初の 1 件・仮）
            guard sendPhotos, let first else { continue }
            let jpegs: [Data] = await Self.groupJPEGs(group, assets: byID, cap: S36APhotoRules.limit(pipeline.homePC.features))
            if !jpegs.isEmpty { photos[first.id] = jpegs }
        }

        // 見た写真を覚える（次の回に回した終わりの組は覚えない）
        let done: [String] = split.now.map(\.id)
        seen = S34APhotoRules.remembered(seen, adding: done)
        d.set(seen, forKey: Self.seenKey)
        var lastSeen: Date = last ?? since
        if let firstLater = split.later.first {
            lastSeen = max(lastSeen, firstLater.at.addingTimeInterval(-1))
        } else {
            for t in times.values { lastSeen = max(lastSeen, t) }
        }
        d.set(lastSeen, forKey: Self.lastKey)
        Tally.add("s34a.photo.scan")
        Tally.add("s34a.photo.read", shots.count)

        guard !added.isEmpty else { return }
        found += added.count
        foundAt = now
        let before: [String] = d.stringArray(forKey: Self.entriesKey) ?? []
        let keep: [String] = S34APhotoRules.remembered(before, adding: added.map { $0.id }, limit: 300)
        entryIDs = Set(keep)
        d.set(found, forKey: Self.foundKey)
        d.set(now, forKey: Self.foundAtKey)
        d.set(keep, forKey: Self.entriesKey)
        Tally.add("s34a.photo.found", added.count)
        // 今の共有と同じ道: ドライブの写し・退勤の頃の知らせの取り直し（今日の分が入れば出さない）・家の PC へ POST /work/digest
        Task { await pipeline.writeWorkDigests() }
        pipeline.scheduleWorkDigestReminder(now: now)
        S30WBook.shared.saved(added, now: now, photos: photos)
    }

    /// s35: 組の写真を、家の PC に送る形（長い辺 2000px 以下の JPEG）に。12 枚まで（s36: "workphoto30" なら 30 枚）・撮った順
    private static func groupJPEGs(_ group: [S34AShot], assets: [String: PHAsset], cap: Int) async -> [Data] {
        var out: [Data] = []
        let side: CGFloat = S35PhotoRules.maxSide
        for shot in group {
            if out.count >= cap { break }
            guard let asset = assets[shot.id],
                  let big = await DayPhotos.image(asset, size: CGSize(width: side, height: side), fit: true, network: false),
                  let small = await S35PhotoRules.jpeg(big) else { continue }
            out.append(small)
        }
        return out
    }
}

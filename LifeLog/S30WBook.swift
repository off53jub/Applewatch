import Foundation
import Observation

// s30（2026-11-27）仕事タブ（S30W）の動き。決まりは S30WRules.swift、画面は S30WViews.swift。
// - 仕事のまとめを取り込んで「入れる」で保存したあと（WorkDigestImportView の保存のあとに呼ぶ口 1 つ＝saved）、
//   家の PC の features に "workpush" があれば POST /work/digest（K30-2）へ、そのとき入れたまとめを送る。
//   送れたら仕事タブの上に「作り直しています」の帯を出し、GET /work/run を 5 秒ごと（最大 6 分・仮。s35 で 3 分から）に見て、
//   終わったら仕事のデータ（GET /work）を取り直す（S27WBook.refresh）。
//   送れないとき（口が無い・つながらない・止めてある）は、今までどおり（ドライブの写しで 15 分ごと）と小さく書くだけ。
// - s35（2026-11-28・K35）: 文を送れたあと、家の PC の features に "workphoto" があれば、同じ id で写真そのものも
//   POST /work/photo に送る（S35PhotoBook.swift）。写真の無いとき・"workphoto" が無いときは今までどおり。
// - 柱の中の「済んだかも」「古い」の箱（K30-1 の auto）から戻したものを端末に覚える（家の PC には送らない）。
// 送り方・鍵は S27WBook の取り方と同じ（HomePC・オーナーの Bearer）。知らせは足さない。中身の文は記録（ログ）に書かない
// （Tally は数と種類の名前だけ）。

@MainActor
@Observable
final class S30WBook {
    static let shared = S30WBook()

    /// 家の PC が "workpush" を持っているか（hello のあとに覚える。まだ hello していないときは前の値）
    static let offeredKey = "s30w.pushOffered"
    /// 箱から戻した項目（id → 日）
    private static let restoredKey = "s30w.restored"
    /// 送ったまとめの id（同じものを二度送らない）
    private static let sentKey = "s30w.sent"

    private(set) var band: S30WBand?
    private(set) var restored: [String: String]
    private(set) var pushOffered: Bool
    @ObservationIgnored private var sent: [String]
    @ObservationIgnored private var job: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        pushOffered = d.bool(forKey: Self.offeredKey)
        restored = d.dictionary(forKey: Self.restoredKey) as? [String: String] ?? [:]
        sent = d.stringArray(forKey: Self.sentKey) ?? []
    }

    var restoredIDs: Set<String> { Set(restored.keys) }

    func visibleBand(now: Date = .now) -> S30WBand? { S30WRules.visible(band, now: now) }

    /// 終わった帯を閉じる（動いているあいだは閉じない）
    func dismissBand() {
        if band?.working != true { band = nil }
    }

    /// 家の PC の features を覚える（空＝まだ hello していないときは前のまま）
    func noteFeatures(_ features: Set<String>) {
        guard !features.isEmpty else { return }
        let on = features.contains(S30WRules.featurePush)
        guard on != pushOffered else { return }
        pushOffered = on
        UserDefaults.standard.set(on, forKey: Self.offeredKey)
    }

    // MARK: 保存のあと（WorkDigestImportView から）

    /// 仕事のまとめを保存したあとに呼ぶ。そのとき入れたまとめ（保存したばかりで、まだ送っていないもの）を家の PC へ送る。
    /// s35: photos はまとめの id ごとの写真（S34A が写真から拾った組）、loosePhotos は取り込む画面で読んだ写真
    /// （縮めた JPEG。送るまとめの最初の 1 件に付ける）。どちらも文を送れたあとに送る
    func saved(_ entries: [WorkDigest.Entry], now: Date = .now, photos: [String: [Data]] = [:], loosePhotos: [Data] = []) {
        let fresh = S30WRules.fresh(entries, sent: Set(sent), now: now)
        guard !fresh.isEmpty else { return }
        let pc = S27WBook.pipeline?.homePC
        if let pc { noteFeatures(pc.features) }
        guard let pc, pc.isConfigured, pushOffered, let body = S30WRules.pushBody(fresh) else {
            band = .fallback(now, S30WRules.fallbackNoDoor)
            Tally.add("s30w.push.none")
            return
        }
        job?.cancel()
        band = .sending(now)
        let ids: [String] = fresh.map(\.id)
        // s36（K36-2・細1）: "workphoto30" があれば 30 枚まで・kind "digest" を付ける（無ければ今のまま 12 枚・kind なし）
        let shots: [S35PhotoJob] = S35PhotoRules.jobs(for: fresh, byID: photos, loose: loosePhotos, cap: S36APhotoRules.limit(pc.features),
                                                      kind: S36APhotoRules.kindField(.digest, pc.features))
        job = Task { await self.push(body, ids: ids, photos: shots, pc: pc, postedAt: now) }
    }

    private func push(_ body: Data, ids: [String], photos: [S35PhotoJob], pc: HomePC, postedAt: Date) async {
        var reply: S30WPushReply?
        if let data = try? await pc.postJSONData("work/digest", body: body, timeout: 20) {
            reply = S30WRules.pushReply(data)
        }
        if Task.isCancelled { return }
        guard let reply, reply.available != false else {
            band = .fallback(.now, S30WRules.fallbackFailed)
            Tally.add("s30w.push.fail")
            return
        }
        sent = S30WRules.remembered(sent, adding: ids)
        UserDefaults.standard.set(sent, forKey: Self.sentKey)
        Tally.add("s30w.push")
        Tally.add("s30w.push.entries", ids.count)
        // s35: 文のあとに写真（同じ id・1 枚ずつ）。features に "workphoto" が無ければ送らない（S35PhotoBook.send の中で見る）
        let photosAt = Date.now
        var photoRun: String?
        if !photos.isEmpty {
            photoRun = await S35PhotoBook.shared.send(photos, pc: pc, now: photosAt)
        }
        if Task.isCancelled { return }
        let plan = S35PhotoRules.watchPlan(digestRun: reply.run, photoRun: photoRun, postedAt: postedAt, photosAt: photosAt)
        if reply.run == "off" && photoRun != "started" {
            band = .fallback(.now, S30WRules.fallbackOff)
            Tally.add("s30w.push.off")
            return
        }
        band = .rebuilding(.now)
        await watch(pc: pc, postedAt: plan.postedAt, needStartAfter: plan.needStartAfter)
    }

    /// GET /work/run を 5 秒ごと（6 分まで。S30WRules.pollLimit）に見て、終わったら GET /work を取り直す
    private func watch(pc: HomePC, postedAt: Date, needStartAfter: Bool) async {
        let start = Date.now
        var sawRunning = false
        while Date.now.timeIntervalSince(start) < S30WRules.pollLimit {
            try? await Task.sleep(for: .seconds(S30WRules.pollEvery))
            if Task.isCancelled { return }
            guard let data = try? await pc.getJSONData("work/run", timeout: 8), let run = S30WRules.run(data) else { continue }
            if run.state == "running" {
                sawRunning = true
                continue
            }
            if S30WRules.runFinished(run, postedAt: postedAt, sawRunning: sawRunning, needStartAfter: needStartAfter) {
                await S27WBook.shared.refresh(force: true)
                if Task.isCancelled { return }
                band = .done(.now, ok: run.ok != false)
                Tally.add(run.ok == false ? "s30w.run.ng" : "s30w.run.done")
                return
            }
        }
        if Task.isCancelled { return }
        await S27WBook.shared.refresh(force: true)
        band = .late(.now)
        Tally.add("s30w.run.late")
    }

    // MARK: 箱から戻す（端末に覚える）

    func restore(_ id: String, now: Date = .now) {
        guard HomeFeeds.isID(id) else { return }
        restored[id] = ReviewRules.dayKey(now)
        saveRestored()
        Tally.add("s30w.restore")
    }

    /// 写しが新しくなったら、もう箱の印が無い項目の「戻した」を捨てる（溜めない）
    func prune(_ board: S27WBoard) {
        let kept = S30WRules.keptRestored(restored, board: board)
        guard kept != restored else { return }
        restored = kept
        saveRestored()
    }

    private func saveRestored() {
        UserDefaults.standard.set(restored, forKey: Self.restoredKey)
    }
}

import Foundation

// s35（2026-11-28）仕事のまとめの写真を家の PC へ送る動き（K35）。決まりは S35PhotoRules.swift。
// - 送るのは S30WBook.push の中から（POST /work/digest で Vision の文を送れたあと・同じ id で）。
// - 写真は送り終わるまで端末の一時フォルダ（tmp/S35Photo/<id>/<番号>.jpg）に置き、届いたら消す（端末に残さない）。
//   送れなかったら、次に開いたとき（その日のうちだけ）1 回だけ送り直し、送れても送れなくても消す。
// - 知らせ・問い・設定のスイッチは足さない（今の「仕事のまとめを家の PC へ」の流れに乗るだけ）。
//   中身（写真・文字）は記録（ログ）に書かない（Tally は数と種類の名前だけ）。

@MainActor
final class S35PhotoBook {
    static let shared = S35PhotoBook()

    private static let pendingKey = "s35.photo.pending"

    /// 送っている最中の id（送り直しと重ねない）
    private var busy: Set<String> = []
    /// 開いたときの印（features がまだ無いときは、あとの 1 分ごとの見回りで送り直す）
    private var openedAt: Date?

    // MARK: 送る（S30WBook.push から）

    /// 写真を送る。返すのは最後に届いた返事の run（送らなかった・1 枚も届かなかったときは nil）
    func send(_ jobs: [S35PhotoJob], pc: HomePC, now: Date = .now) async -> String? {
        guard !jobs.isEmpty, pc.isConfigured, S35PhotoRules.offered(pc.features) else { return nil }
        let ids: [String] = jobs.map(\.id)
        busy.formUnion(ids)
        defer { busy.subtract(ids) }
        // 送れなかったとき（アプリが途中で閉じられたときも）のために、先に一時ファイルと覚えを置く
        await S35PhotoFiles.write(jobs)
        let today: String = ReviewRules.dayKey(now)
        var pending: [S35PhotoPending] = Self.loadPending().filter { !ids.contains($0.id ?? "") }
        for job in jobs {
            pending.append(S35PhotoPending(id: job.id, day: job.day, count: job.count, madeOn: today, madeAt: now,
                                           retried: false, done: [], kind: job.kind))
        }
        Self.savePending(pending)
        let outcome: S35PhotoOutcome = await S35PhotoSend.run(jobs, features: pc.features) { body in
            try await pc.postJSONData("work/photo", body: body, timeout: S35PhotoRules.postTimeout)
        }
        await settle(outcome, ids: ids, keepFailed: true)
        Tally.add("s35.photo.send")
        Tally.add("s35.photo.pieces", jobs.reduce(0) { $0 + $1.pieces.count })
        return outcome.run
    }

    /// 送った結果を片づける: 届いた・止めてある分は消す。送れなかった分は、届いた番号を覚えて次に開いたときまで置く
    private func settle(_ outcome: S35PhotoOutcome, ids: [String], keepFailed: Bool) async {
        let keep: Set<String> = keepFailed && !outcome.off ? Set(outcome.failed) : []
        let gone: [String] = ids.filter { !keep.contains($0) }
        await S35PhotoFiles.remove(gone)
        var pending: [S35PhotoPending] = Self.loadPending().filter { !gone.contains($0.id ?? "") }
        for n in pending.indices {
            guard let id = pending[n].id, keep.contains(id) else { continue }
            let done: Set<Int> = Set(pending[n].done ?? []).union(outcome.done[id] ?? [])
            pending[n].done = done.sorted()
        }
        Self.savePending(pending)
        if outcome.off { Tally.add("s35.photo.off") }
        if !outcome.failed.isEmpty { Tally.add(keepFailed ? "s35.photo.fail" : "s35.photo.retry.fail") }
        if !outcome.complete.isEmpty { Tally.add(keepFailed ? "s35.photo.done" : "s35.photo.retry.done") }
    }

    // MARK: 次に開いたとき 1 回だけ送り直す

    /// アプリが前に来たとき・仕事タブを開いたとき
    func opened(now: Date = .now) {
        openedAt = now
        tick(now: now)
    }

    /// 1 分ごと（S34ABook.tick から）。開いたあとで、まだ家の PC の features が無かったときの続き
    func tick(now: Date = .now) {
        guard let openedAt, busy.isEmpty, let pc = S27WBook.pipeline?.homePC else { return }
        let pending: [S35PhotoPending] = Self.loadPending()
        guard !pending.isEmpty else {
            self.openedAt = nil
            Task { await S35PhotoFiles.sweep(keep: []) }
            return
        }
        guard !pc.features.isEmpty else { return }  // hello がまだ
        self.openedAt = nil
        let plan = S35PhotoRules.retryPlan(pending, today: ReviewRules.dayKey(now), openedAt: openedAt)
        // 1 回だけ: 送る前に「送り直した」を覚える
        var next: [S35PhotoPending] = plan.wait
        for var p in plan.send {
            p.retried = true
            next.append(p)
        }
        Self.savePending(next)
        let dropIDs: [String] = plan.drop.compactMap(\.id)
        if !dropIDs.isEmpty { Tally.add("s35.photo.drop", dropIDs.count) }
        let send: [S35PhotoPending] = plan.send
        let keepIDs: Set<String> = Set(next.compactMap(\.id))
        Task {
            await S35PhotoFiles.remove(dropIDs)
            await S35PhotoFiles.sweep(keep: keepIDs)
            if !send.isEmpty { await self.retry(send, pc: pc) }
        }
    }

    private func retry(_ items: [S35PhotoPending], pc: HomePC) async {
        let ids: [String] = items.compactMap(\.id)
        busy.formUnion(ids)
        defer { busy.subtract(ids) }
        var jobs: [S35PhotoJob] = []
        for item in items {
            guard let id = item.id, let day = item.day, let count = item.count else { continue }
            let pieces: [S35PhotoPiece] = await S35PhotoFiles.read(id: id, count: count, skip: Set(item.done ?? []))
            if !pieces.isEmpty { jobs.append(S35PhotoJob(id: id, day: day, count: count, pieces: pieces, kind: item.kind)) }
        }
        if pc.isConfigured, S35PhotoRules.offered(pc.features), !jobs.isEmpty {
            let outcome: S35PhotoOutcome = await S35PhotoSend.run(jobs, features: pc.features) { body in
                try await pc.postJSONData("work/photo", body: body, timeout: S35PhotoRules.postTimeout)
            }
            Tally.add("s35.photo.retry")
            await settle(outcome, ids: ids, keepFailed: false)
        }
        // 1 回だけなので、送れても送れなくても消す
        await S35PhotoFiles.remove(ids)
        Self.savePending(Self.loadPending().filter { !ids.contains($0.id ?? "") })
    }

    // MARK: 覚え（UserDefaults。写真そのものは入れない）

    private static func loadPending() -> [S35PhotoPending] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let rows = try? JSONDecoder().decode([S35PhotoPending].self, from: data) else { return [] }
        return rows
    }

    private static func savePending(_ rows: [S35PhotoPending]) {
        if rows.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingKey)
        } else if let data = try? JSONEncoder().encode(Array(rows.suffix(20))) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }
}

/// 写真の一時ファイル（tmp/S35Photo/<id>/<番号>.jpg）。ディスクは裏で触る
enum S35PhotoFiles {
    nonisolated static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("S35Photo", isDirectory: true)
    }

    nonisolated static func place(_ id: String) -> URL? {
        guard S35PhotoRules.isUUID(id) else { return nil }
        return folder.appendingPathComponent(id.lowercased(), isDirectory: true)
    }

    nonisolated static func write(_ jobs: [S35PhotoJob]) async {
        await Task.detached {
            let fm = FileManager.default
            for job in jobs {
                guard let dir = S35PhotoFiles.place(job.id) else { continue }
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for piece in job.pieces {
                    let u = dir.appendingPathComponent("\(piece.index).jpg")
                    try? piece.jpeg.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }
        }.value
    }

    nonisolated static func read(id: String, count: Int, skip: Set<Int>) async -> [S35PhotoPiece] {
        await Task.detached {
            guard let dir = S35PhotoFiles.place(id), count >= 1, count <= S35PhotoRules.maxLimit else { return [] }
            var out: [S35PhotoPiece] = []
            for index in 0..<count where !skip.contains(index) {
                let u = dir.appendingPathComponent("\(index).jpg")
                if let data = try? Data(contentsOf: u), S35PhotoRules.isJPEG(data) {
                    out.append(S35PhotoPiece(index: index, jpeg: data))
                }
            }
            return out
        }.value
    }

    nonisolated static func remove(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        await Task.detached {
            for id in ids {
                if let dir = S35PhotoFiles.place(id) { try? FileManager.default.removeItem(at: dir) }
            }
        }.value
    }

    /// 覚えの無い置き場を消す（途中で閉じられたときの残り）
    nonisolated static func sweep(keep: Set<String>) async {
        await Task.detached {
            let fm = FileManager.default
            let names: [String] = (try? fm.contentsOfDirectory(atPath: S35PhotoFiles.folder.path)) ?? []
            let kept: Set<String> = Set(keep.map { $0.lowercased() })
            for name in names where !kept.contains(name) {
                try? fm.removeItem(at: S35PhotoFiles.folder.appendingPathComponent(name, isDirectory: true))
            }
        }.value
    }
}

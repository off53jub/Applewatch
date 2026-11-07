import Foundation

/// 文字になるまでの時間を、区間ごとに測る（2026-11-07。docs/v8-latency.md の 1）。
///
/// 区切りごとに、時刻を覚えておく:
/// - 区切りの録音の始まり・終わり（名前の時刻が始まり。終わりは「始まり＋音声の長さ」）
/// - iPhone に届いた時刻（時計の区切り。iPhone で録った区切りは終わりと同じ）
/// - PC に送り始めた時刻
/// - PC が受け終わった・文字にし始めた・下書きができた・でき上がった時刻（PC の答えの timing）
/// - 記録に入れた時刻
/// 記録に入れたら、区間ごとの秒数を1つの「測った値」にして残す（48時間分）。直近24時間の中央値を、
/// 自己点検と家の PC への様子（/diag の state.latency）に出す。区切りの名前と時刻だけで、会話の中身は入れない。
enum Latency {
    /// 1つの区切りの時刻
    struct Marks: Codable, Equatable, Sendable {
        /// 時計で録った区切りか
        var watch: Bool
        var chunkStart: Date?
        var chunkEnd: Date?
        var arrived: Date?
        var sent: Date?
        var received: Date?
        var started: Date?
        var draftAt: Date?
        var finished: Date?
        /// 時計で区切った時刻（時計が添えた控え。古い時計のアプリでは nil。2026-11-07）
        var watchCut: Date? = nil
        /// 時計が送り始めた時刻（同じ）
        var watchSent: Date? = nil
    }

    /// 1つの区切りの、区間ごとの秒数（分からない区間は nil）
    struct Sample: Codable, Equatable, Sendable {
        var at: Date
        /// 録音の終わり → iPhone（時計から届くまで。時計の区切りだけ）
        var toPhone: Double?
        /// iPhone → PC（届いてから PC が受け終わるまで）
        var toPC: Double?
        /// PC の待ち（受け終わり → 文字にし始め）
        var pcWait: Double?
        /// PC の作業（文字にし始め → でき上がり）
        var pcWork: Double?
        /// PC → 記録（でき上がり → 記録に入れた）
        var toRecord: Double?
        /// 合計（録音の終わり → 記録に入れた）
        var total: Double?
        /// 時計→iPhone の内訳1: 時計で待った（区切った → 時計が送り始めた。低電力モードでまとめて送るときなど。2026-11-07）
        var watchWait: Double? = nil
        /// 時計→iPhone の内訳2: 受け渡し（時計が送り始めた → iPhone のアプリが受け取った）
        var handoff: Double? = nil
    }

    /// 直近の中央値
    struct Summary: Equatable, Sendable {
        var count: Int
        var toPhone: Double?
        var toPC: Double?
        var pcWait: Double?
        var pcWork: Double?
        var toRecord: Double?
        var total: Double?
        /// 時計で待った・受け渡し（時計→iPhone の内訳。2026-11-07）
        var watchWait: Double? = nil
        var handoff: Double? = nil

        /// 家の PC に送る形（秒。分からない区間は省く）
        var json: [String: Any] {
            var out: [String: Any] = ["count": count]
            func put(_ key: String, _ value: Double?) {
                if let value { out[key] = (value * 10).rounded() / 10 }
            }
            put("toPhone", toPhone)
            put("toPC", toPC)
            put("pcWait", pcWait)
            put("pcWork", pcWork)
            put("toRecord", toRecord)
            put("total", total)
            put("watchWait", watchWait)
            put("handoff", handoff)
            return out
        }
    }

    private struct Store: Codable {
        var marks: [String: Marks] = [:]
        var samples: [Sample] = []
    }

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("latency.json")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: Store?
    /// 時刻を覚えておく長さ（記録に入らなかった区切りは、これで忘れる）
    private static let keepMarks: TimeInterval = 2 * 86400
    /// 測った値を残す長さ
    private static let keepSamples: TimeInterval = 2 * 86400

    // MARK: - 覚える

    /// 区切りができた・届いた（初めの1回だけ覚える）。時計の区切りなら、時計で区切った時刻と送り始めた時刻も（分かれば）
    static func noteChunk(_ name: String, start: Date, end: Date, arrived: Date, watch: Bool,
                          watchCut: Date? = nil, watchSent: Date? = nil) {
        update { store in
            guard store.marks[name] == nil else { return }
            store.marks[name] = Marks(watch: watch, chunkStart: start, chunkEnd: end, arrived: arrived,
                                      watchCut: watchCut, watchSent: watchSent)
        }
    }

    /// PC に送り始めた
    static func noteSent(_ name: String, at date: Date = .now) {
        update { store in
            guard var marks = store.marks[name] else { return }
            if marks.sent == nil { marks.sent = date }
            store.marks[name] = marks
        }
    }

    /// その区切りの時刻（PC に送るときに使う）
    static func marks(_ name: String) -> Marks? {
        lock.withLock { loadLocked().marks[name] }
    }

    /// PC の答えの timing を足す（iPhone の時刻が無ければ、PC が返した iPhone の時刻で埋める）
    static func notePC(_ name: String, timing: PCTiming) {
        update { store in
            var marks = store.marks[name] ?? Marks(watch: Storage.isFromWatch(URL(fileURLWithPath: name)))
            marks.chunkStart = marks.chunkStart ?? timing.chunkStart
            marks.chunkEnd = marks.chunkEnd ?? timing.chunkEnd
            marks.arrived = marks.arrived ?? timing.arrived
            marks.sent = marks.sent ?? timing.sent
            marks.received = timing.received ?? marks.received
            marks.started = timing.started ?? marks.started
            marks.draftAt = timing.draftAt ?? marks.draftAt
            marks.finished = timing.finished ?? marks.finished
            store.marks[name] = marks
        }
    }

    /// 区切りの行を記録に入れた。区間ごとの秒数を残し、時刻は忘れる（2回目からは何もしない）
    static func noteApplied(_ name: String, at date: Date = .now) {
        update { store in
            guard let marks = store.marks.removeValue(forKey: name) else { return }
            let sample = Self.sample(marks, applied: date)
            guard sample.total != nil || sample.toPC != nil || sample.pcWork != nil else { return }
            store.samples.append(sample)
        }
    }

    /// PC に送って、まだでき上がっていない区切り（新しい順。下書きを見に行くのに使う）
    static func awaiting(now: Date = .now, within: TimeInterval = 30 * 60) -> [String] {
        lock.withLock {
            loadLocked().marks.filter { _, m in
                guard let sent = m.sent, m.finished == nil else { return false }
                return now.timeIntervalSince(sent) < within
            }
            .sorted { ($0.value.sent ?? .distantPast) > ($1.value.sent ?? .distantPast) }
            .map(\.key)
        }
    }

    /// 直近24時間の中央値。測った値が無ければ nil
    static func summary(now: Date = .now) -> Summary? {
        let samples = lock.withLock { loadLocked().samples }
        return summarize(samples, now: now)
    }

    /// テスト用に消す
    static func reset() {
        lock.withLock {
            cache = Store()
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 計算（テストしやすいよう、保存とは分けてある）

    /// 区間の秒数。時計どうしが大きくずれている（1分より大きく逆さ）なら nil、少しの逆さは 0
    static func span(_ from: Date?, _ to: Date?) -> Double? {
        guard let from, let to else { return nil }
        let seconds = to.timeIntervalSince(from)
        if seconds < -60 { return nil }
        return max(0, seconds)
    }

    static func sample(_ m: Marks, applied: Date) -> Sample {
        Sample(at: applied,
               toPhone: m.watch ? span(m.chunkEnd, m.arrived) : nil,
               toPC: span(m.arrived, m.received),
               pcWait: span(m.received, m.started),
               pcWork: span(m.started, m.finished),
               toRecord: span(m.finished, applied),
               total: span(m.chunkEnd, applied),
               watchWait: m.watch ? span(m.watchCut, m.watchSent) : nil,
               handoff: m.watch ? span(m.watchSent, m.arrived) : nil)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func summarize(_ samples: [Sample], now: Date, within: TimeInterval = 86400) -> Summary? {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= within && $0.at <= now.addingTimeInterval(60) }
        guard !recent.isEmpty else { return nil }
        return Summary(count: recent.count,
                       toPhone: median(recent.compactMap(\.toPhone)),
                       toPC: median(recent.compactMap(\.toPC)),
                       pcWait: median(recent.compactMap(\.pcWait)),
                       pcWork: median(recent.compactMap(\.pcWork)),
                       toRecord: median(recent.compactMap(\.toRecord)),
                       total: median(recent.compactMap(\.total)),
                       watchWait: median(recent.compactMap(\.watchWait)),
                       handoff: median(recent.compactMap(\.handoff)))
    }

    /// 自己点検の行（見出し・中身・良いか）
    static func rows(now: Date = .now) -> [(label: String, value: String, ok: Bool?)] {
        guard let s = summary(now: now) else {
            return [("直近24時間", "まだ測っていません（区切りが記録に入ると測ります）", nil)]
        }
        func text(_ v: Double) -> String { v < 10 ? String(format: "%.1f 秒", v) : "\(Int(v.rounded())) 秒" }
        var rows: [(label: String, value: String, ok: Bool?)] = []
        rows.append(("直近24時間の合計（ふつう）",
                     (s.total.map(text) ?? "分からない") + "（\(s.count) 個の区切り。録音の終わり→記録に入るまで）",
                     s.total.map { $0 < 600 }))
        let parts: [(String, Double?)] = [("時計→iPhone", s.toPhone), ("iPhone→PC", s.toPC), ("PC の待ち", s.pcWait),
                                         ("PC の作業", s.pcWork), ("PC→記録", s.toRecord)]
        let known = parts.compactMap { name, value in value.map { name + " " + text($0) } }
        if !known.isEmpty { rows.append(("区間ごと（ふつう）", known.joined(separator: "・"), nil)) }
        // 時計→iPhone の内訳（時計が控えを添えた区切りだけ。2026-11-07）
        let watchParts: [(String, Double?)] = [("時計で待った", s.watchWait), ("受け渡し", s.handoff)]
        let watchKnown = watchParts.compactMap { name, value in value.map { name + " " + text($0) } }
        if !watchKnown.isEmpty {
            rows.append(("時計→iPhone の内訳（ふつう）",
                         watchKnown.joined(separator: "・") + "（時計で待った＝区切ってから時計が送り始めるまで。受け渡し＝送り始めてから iPhone のアプリが受け取るまで）",
                         nil))
        }
        return rows
    }

    // MARK: - 保存

    private static func loadLocked() -> Store {
        if let cache { return cache }
        let decoder = JSONDecoder()
        let store = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Store.self, from: $0) } ?? Store()
        cache = store
        return store
    }

    private static func update(_ change: (inout Store) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var store = loadLocked()
        change(&store)
        let now = Date.now
        store.marks = store.marks.filter { _, m in
            let at = m.arrived ?? m.chunkEnd ?? m.sent ?? m.finished ?? now
            return now.timeIntervalSince(at) < keepMarks
        }
        store.samples = store.samples.filter { now.timeIntervalSince($0.at) < keepSamples }
        cache = store
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: url, options: .atomic) }
    }
}

/// PC の答えの "timing"（docs/v8-latency.md の 1）。日時は ISO 8601 の文字か、1970年からの秒の数のどちらでも読む
struct PCTiming: Decodable, Equatable, Sendable {
    var chunkStart: Date?
    var chunkEnd: Date?
    var arrived: Date?
    var sent: Date?
    var received: Date?
    var started: Date?
    var draftAt: Date?
    var finished: Date?

    enum CodingKeys: String, CodingKey {
        case chunkStart = "chunk_start", chunkEnd = "chunk_end", arrived, sent, received, started
        case draftAt = "draft_at", finished
    }

    init(chunkStart: Date? = nil, chunkEnd: Date? = nil, arrived: Date? = nil, sent: Date? = nil,
         received: Date? = nil, started: Date? = nil, draftAt: Date? = nil, finished: Date? = nil) {
        self.chunkStart = chunkStart
        self.chunkEnd = chunkEnd
        self.arrived = arrived
        self.sent = sent
        self.received = received
        self.started = started
        self.draftAt = draftAt
        self.finished = finished
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) -> Date? {
            if let text = try? c.decode(String.self, forKey: key) { return PCJSON.date(text) }
            if let number = try? c.decode(Double.self, forKey: key) { return Date(timeIntervalSince1970: number) }
            return nil
        }
        chunkStart = read(.chunkStart)
        chunkEnd = read(.chunkEnd)
        arrived = read(.arrived)
        sent = read(.sent)
        received = read(.received)
        started = read(.started)
        draftAt = read(.draftAt)
        finished = read(.finished)
    }
}

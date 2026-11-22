import Foundation

/// s22（2026-11-22）の時計と iPhone の両方で使う決まり（決まった入力から決まった出力だけ。docs/s22-app.md）。
/// 番号は母艦に出した s22 の案の番号（楽・確）。しきい値はどれも仮（データがたまったら測り直す）。
/// テストは LifeLogTests/S22Tests.swift。
enum S22Watch {
    // MARK: - iPhone → 時計の設定の名前（applicationContext）

    /// 確24: 録り方の実験を 1 時間ごとに入れ替える（初めはオフ。本人がオンにした日から 8 日）
    static let hourlyOnKey = "s22.recExpHourlyOn"
    /// 確24: 入れ替えの 1 日目（yyyy-MM-dd。オンにした日）
    static let hourlyStartKey = "s22.recExpHourlyStart"
    /// 確31: 袖でこもった音を見つけたら時計が震える（初めはオフ）
    static let muffledOnKey = "s22.muffledOn"

    static func addSettings(to context: inout [String: Any], defaults: UserDefaults = .standard) {
        context[hourlyOnKey] = defaults.bool(forKey: hourlyOnKey)
        context[hourlyStartKey] = defaults.string(forKey: hourlyStartKey) ?? ""
        context[muffledOnKey] = defaults.bool(forKey: muffledOnKey)
    }

    static func readSettings(_ context: [String: Any], defaults: UserDefaults = .standard) {
        if let on = context[hourlyOnKey] as? Bool { defaults.set(on, forKey: hourlyOnKey) }
        if let start = context[hourlyStartKey] as? String {
            if start.isEmpty { defaults.removeObject(forKey: hourlyStartKey) } else { defaults.set(start, forKey: hourlyStartKey) }
        }
        if let on = context[muffledOnKey] as? Bool { defaults.set(on, forKey: muffledOnKey) }
    }

    // MARK: - 時計 → iPhone の名前（どれも省ける）

    /// 確4: 区切りの metadata（transferFile）に付ける音の大きさの要約
    static let levelsKey = "levels"
    /// 確24: 区切りの metadata に付けるその区切りの組（"32k45" など）
    static let recExpKey = "recExp"
    /// 確31: 今日、こもった音で震えた回数（deliveryState）
    static let muffledTodayKey = "muffledToday"
    /// 楽6: 直近 30 分に iPhone への受け渡しが終わった数（deliveryState。あと何分かの見込みに使う）
    static let finishedRecentKey = "finishedRecent"
    /// 楽13: 時計で確かめ待ちに答えた（transferUserInfo）
    static let reviewIDKey = "s22reviewID"
    static let reviewValueKey = "s22reviewValue"
    /// 楽6: iPhone から「いま送り直して」（transferUserInfo。前からの resendKept より強く、止まった受け渡しも取り消す）
    static let resendNowKey = "s22resendNow"

    // MARK: - 確4 区切りの中の音の大きさ（1 秒ごとの dB の要約）

    /// 1 秒ごとの音の大きさ・声らしさ・高い音の割合を数える（時計の書く糸で使う。鍵は呼ぶ側）
    struct LevelMeter: Sendable {
        let rate: Double
        private(set) var secondsDB: [Double] = []
        private(set) var voiced: [Bool] = []
        private(set) var highRatios: [Double] = []
        private var sumSquares: Double = 0
        private var diffSquares: Double = 0
        private var count = 0
        private var last: Float = 0
        private var tonalAtStart: Int?
        /// 長い区切りでも数えすぎない（6 分ぶん）
        static let maxSeconds = 360

        init(rate: Double = 16_000) { self.rate = rate }

        mutating func reset() {
            secondsDB.removeAll(keepingCapacity: true)
            voiced.removeAll(keepingCapacity: true)
            highRatios.removeAll(keepingCapacity: true)
            sumSquares = 0
            diffSquares = 0
            count = 0
            last = 0
            tonalAtStart = nil
        }

        /// tonal は、ここまでに声らしいと数えたこまの合計（VoiceGate.tonalFrames）。1 秒のあいだに増えたら「声の秒」
        mutating func feed(_ samples: UnsafePointer<Float>, count n: Int, tonal: Int) {
            guard n > 0, secondsDB.count < Self.maxSeconds else { return }
            if tonalAtStart == nil { tonalAtStart = tonal }
            let window = max(1, Int(rate))
            for i in 0..<n {
                let x = samples[i]
                sumSquares += Double(x * x)
                let d = x - last
                diffSquares += Double(d * d)
                last = x
                count += 1
                if count >= window {
                    close(tonal: tonal)
                    if secondsDB.count >= Self.maxSeconds { return }
                }
            }
        }

        /// 決まった秒の値を足す（テスト用）
        mutating func appendSecond(db: Double, voiced isVoiced: Bool, high: Double) {
            secondsDB.append(db)
            voiced.append(isVoiced)
            highRatios.append(high)
        }

        private mutating func close(tonal: Int) {
            let mean = sumSquares / Double(max(1, count))
            let db = 10 * log10(max(mean, 1e-12))
            secondsDB.append(db)
            voiced.append(tonal > (tonalAtStart ?? tonal))
            // 1 つ前との差の大きさ ÷ 大きさ（高い音が多いほど大きい。0〜1 ほど。音が無い秒は数えない）
            highRatios.append(sumSquares > 1e-9 ? min(1, diffSquares / (4 * sumSquares)) : -1)
            sumSquares = 0
            diffSquares = 0
            count = 0
            tonalAtStart = tonal
        }

        /// 区切りの要約（音のある秒が 3 つより少なければ nil）
        func summary() -> Levels? { S22Watch.summarize(db: secondsDB, voiced: voiced, high: highRatios) }
    }

    struct Levels: Equatable, Sendable {
        var p10: Double
        var p50: Double
        var p90: Double
        var voicedP50: Double?
        /// 確31 に使う高い音の割合の中央値（metadata には出さない）
        var high: Double?

        /// metadata の形 {"p10","p50","p90","voicedP50"?}（小数 1 桁）
        var json: [String: Double] {
            var out: [String: Double] = ["p10": S22Watch.round1(p10), "p50": S22Watch.round1(p50), "p90": S22Watch.round1(p90)]
            if let voicedP50 { out["voicedP50"] = S22Watch.round1(voicedP50) }
            return out
        }
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// p は 0〜1。近い順位の値（間を埋めない）
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * min(1, max(0, p))).rounded())
        return sorted[index]
    }

    /// デジタルの無音（-90dB より下）は数えない
    static func summarize(db: [Double], voiced: [Bool], high: [Double]) -> Levels? {
        let heard = db.filter { $0 > -90 }
        guard heard.count >= 3, let p10 = percentile(heard, 0.1), let p50 = percentile(heard, 0.5),
              let p90 = percentile(heard, 0.9) else { return nil }
        var voicedDB: [Double] = []
        for (i, value) in db.enumerated() where i < voiced.count && voiced[i] && value > -90 { voicedDB.append(value) }
        var loud: [Double] = []
        for (i, value) in db.enumerated() where i < high.count && value > -60 && high[i] >= 0 { loud.append(high[i]) }
        return Levels(p10: p10, p50: p50, p90: p90, voicedP50: percentile(voicedDB, 0.5), high: percentile(loud, 0.5))
    }

    /// metadata の levels を読む（iPhone。形が違えば nil）
    static func levels(from metadata: [String: Any]?) -> [String: Double]? {
        guard let raw = metadata?[levelsKey] as? [String: Any] else { return nil }
        var out: [String: Double] = [:]
        for key in ["p10", "p50", "p90", "voicedP50"] {
            if let value = raw[key] as? Double { out[key] = value } else if let value = raw[key] as? NSNumber { out[key] = value.doubleValue }
        }
        return out["p50"] == nil ? nil : out
    }

    /// POST /jobs（iPhone）・/w/jobs（時計）の query に足す levels と recExp（家の PC が読む。無ければ付けない）。
    /// levels は metadata と同じ形の JSON（キーの順に並べる）
    static func queryItems(levels: [String: Double]?, recExp: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let levels, !levels.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: levels, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            items.append(URLQueryItem(name: levelsKey, value: text))
        }
        if let recExp, isRecExpLabel(recExp) { items.append(URLQueryItem(name: recExpKey, value: recExp)) }
        return items
    }

    // MARK: - 確24 録り方の実験を 1 時間ごとに入れ替える（4 組・8 日）

    static let hourlyDays = 8
    static let recExpLabels = ["32k45", "48k45", "32k300", "48k300"]

    static func isRecExpLabel(_ text: String) -> Bool { recExpLabels.contains(text) }

    /// その時刻の組（オフ・始まりが無い・8 日の外・会議モードなら nil）。
    /// 何番目の組かは「時 ＋ 何日目」で回す（8 日で、どの組もどの時間帯に 2 回ずつ当たる）
    static func hourlyCombo(on: Bool, start: String?, meeting: Bool, now: Date,
                            calendar: Calendar = .current) -> RecordingExperiment.Combo? {
        guard on, !meeting, let start, let first = RecordingExperiment.date(start, calendar: calendar) else { return nil }
        guard let offset = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day,
              offset >= 0, offset < hourlyDays else { return nil }
        let hour = calendar.component(.hour, from: now)
        let index = (hour + offset) % RecordingExperiment.plan.count
        let entry = RecordingExperiment.plan[index]
        return RecordingExperiment.Combo(day: offset + 1, bitrate: entry.bitrate, length: entry.length)
    }

    /// 入れ替えが終わったか（8 日たった）
    static func hourlyFinished(start: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let start, let first = RecordingExperiment.date(start, calendar: calendar) else { return false }
        return (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day ?? 0) >= hourlyDays
    }

    /// "32k45" の形
    static func label(_ combo: RecordingExperiment.Combo) -> String {
        "\(combo.bitrate / 1000)k\(Int(combo.length.minimum))"
    }

    /// この端末の設定でのいまの組（入れ替えの外は nil）
    static func hourlyNow(now: Date = .now, defaults: UserDefaults = .standard) -> RecordingExperiment.Combo? {
        hourlyCombo(on: defaults.bool(forKey: hourlyOnKey), start: defaults.string(forKey: hourlyStartKey),
                    meeting: defaults.bool(forKey: RecordingExperiment.meetingKey), now: now)
    }

    // MARK: - 確25 符号化の種類（いまは AAC だけ。理由は docs/s22-app.md）

    /// 実験に足せる符号化（m4a の入れ物のまま、iPhone と家の PC が今のまま読めるものだけ）。HE-AAC は時計で使えるか確かめていない
    static let codecs = ["aac"]

    // MARK: - 確31 袖でこもった音

    /// こもり: 高い音の割合が、ふだん（直近の区切りの中央値）の 4 割より下に落ちた区切りが 2 つ続いた（仮）
    static let muffledRatio = 0.4
    static let muffledStreak = 2
    /// 震えるのは 1 時間に 1 回まで
    static let muffledGap: TimeInterval = 3600

    /// 直近の区切りの「高い音の割合」（古い順。最後がいま）から、こもりが続いているか。ふだんは最後の streak 個より前の中央値（5 個以上あるときだけ）
    static func isMuffled(_ history: [Double], streak: Int = muffledStreak, ratio: Double = muffledRatio) -> Bool {
        guard history.count >= streak + 5 else { return false }
        let base = Array(history.dropLast(streak))
        guard let normal = percentile(base, 0.5), normal > 0.01 else { return false }
        return history.suffix(streak).allSatisfy { $0 < normal * ratio }
    }

    /// 震えてよいか（設定がオン・こもりが続いた・前に震えてから 1 時間）
    static func shouldBuzz(on: Bool, history: [Double], lastBuzz: Date?, now: Date) -> Bool {
        guard on, isMuffled(history) else { return false }
        guard let lastBuzz else { return true }
        return now.timeIntervalSince(lastBuzz) >= muffledGap
    }

    // MARK: - 楽6 時計に溜まった分の「あと○個・約○分」

    /// 直近 30 分に終わった受け渡しの数から、残りが終わるまでの分（数が少なくて分からなければ nil）
    static func backlogMinutes(count: Int, finishedRecent: Int, window: TimeInterval = 30 * 60) -> Int? {
        guard count > 0, finishedRecent >= 2 else { return nil }
        let perMinute = Double(finishedRecent) / (window / 60)
        return max(1, Int((Double(count) / perMinute).rounded(.up)))
    }

    /// 「あと 120 個・約 40 分」（分からなければ「あと 120 個」。無ければ nil）
    static func backlogText(count: Int, finishedRecent: Int) -> String? {
        guard count > 0 else { return nil }
        guard let minutes = backlogMinutes(count: count, finishedRecent: finishedRecent) else { return "あと \(count) 個" }
        return "あと \(count) 個・約 " + durationText(Double(minutes) * 60)
    }

    /// 終わった時刻の並びから、直近 window の数（古いものは捨てて返す）
    static func recentFinishes(_ times: [Double], now: Double, window: TimeInterval = 30 * 60, limit: Int = 400) -> [Double] {
        Array(times.filter { now - $0 < window && $0 <= now + 60 }.suffix(limit))
    }

    /// 「40 分」「2 時間 5 分」「約 9 日」（見5 の言い方に寄せた短い版。A2 の数の読み方があればそちらが先）
    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) 分" }
        if minutes < 48 * 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) 時間" : "\(h) 時間 \(m) 分"
        }
        return "\(Int((Double(minutes) / 1440).rounded())) 日"
    }

    // MARK: - 楽6 「受け取った」が先に届いた名前を、アプリが終わっても覚えておく

    /// 名前 → 覚えた時刻。1 日で忘れる・500 個まで
    static func addingAcked(_ saved: [String: Double], name: String, now: Double, keep: TimeInterval = 86400,
                            limit: Int = 500) -> [String: Double] {
        var next = saved.filter { now - $0.value < keep }
        next[name] = now
        if next.count > limit {
            let drop = next.sorted { $0.value < $1.value }.prefix(next.count - limit).map(\.key)
            for key in drop { next[key] = nil }
        }
        return next
    }

    // MARK: - 楽19 電池の先回り「この調子だと○時に切れます」

    /// 見本（[[時刻, 0〜1, …, 充電中なら 1（4 つ目。無ければ増えたかで見る）]]）の、最後に充電していなかった続きから、
    /// 0 になる時刻。1 時間より短い・3% より減っていない・48 時間より先なら nil
    static func emptyAt(_ samples: [[Double]], now: Date) -> Date? {
        let rows = samples.filter { $0.count >= 2 && $0[1] >= 0 && $0[1] <= 1 }.sorted { $0[0] < $1[0] }
        guard let last = rows.last else { return nil }
        if last.count >= 4, last[3] == 1 { return nil }
        // 後ろから、充電していない・増えていないあいだをたどる
        var run: [[Double]] = [last]
        for row in rows.dropLast().reversed() {
            let charging = row.count >= 4 && row[3] == 1
            guard !charging, let next = run.first, row[1] >= next[1] else { break }
            run.insert(row, at: 0)
        }
        guard let first = run.first, run.count >= 2 else { return nil }
        let hours = (last[0] - first[0]) / 3600
        let drop = first[1] - last[1]
        guard hours >= 1, drop >= 0.03 else { return nil }
        let perSecond = drop / (last[0] - first[0])
        let end = last[0] + last[1] / perSecond
        guard end - now.timeIntervalSince1970 <= 48 * 3600 else { return nil }
        return Date(timeIntervalSince1970: max(end, now.timeIntervalSince1970))
    }

    /// 「この調子だと 21:40 に切れます」（明日なら「明日 3:10」）
    static func emptyText(_ date: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let clock = String(format: "%d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        let day = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let prefix = day == 0 ? "" : day == 1 ? "明日 " : "\(day) 日後 "
        return "この調子だと " + prefix + clock + " に切れます"
    }

    /// 1 時間あたりの減り（%。分からなければ nil）
    static func drainPerHour(_ samples: [[Double]], now: Date) -> Double? {
        let rows = samples.filter { $0.count >= 2 }.sorted { $0[0] < $1[0] }
        guard let last = rows.last, let end = emptyAt(samples, now: now) else { return nil }
        let left = end.timeIntervalSince1970 - last[0]
        guard left > 0 else { return nil }
        return last[1] * 100 / (left / 3600)
    }
}

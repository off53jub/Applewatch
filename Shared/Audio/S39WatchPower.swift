import Foundation

/// s39（2026-11-29）外出中の時計の電池の減りを、録る音を変えずに減らす決まり（時計と iPhone の両方で使う。決まった入力から決まった出力だけ）。
/// 番号は本人に見せた案の番号（7 は家だけなので作らない）。しきい値はどれも仮（前後の電池の見本で測り直す）。
/// テストは LifeLogTests/S39WatchPowerTests.swift。docs/s39-watch-away-power.md。
///
/// 「外出中」は 1 つの判定にまとめる（awayWhy）:
/// - iPhone が「家を出ている」と言っている（登録した「自宅」の見張り。s19 の 休8 の holidayAway）、または
/// - iPhone に届かない時間が 30 分（仮）続いている（受け渡しの列に 30 分より前のものが残り、30 分終わっていない）。
/// ただし、充電中・家の Wi-Fi で家の PC に 30 分以内に直接届いた・設定がオフ、のどれかなら外出中ではない（家の動きは変えない）。
enum S39WatchPower {
    // MARK: - iPhone → 時計の設定（applicationContext。どれも初めはオン・くわしい設定で戻せる）

    /// 外出中の省電力（3〜6・8〜10・13・14 のまとめのスイッチ）
    static let onKey = "s39.awayPower"
    /// 休日に家を出たら、時計の外出モード（区切りを溜める）に自動で入る（3）
    static let holidayAutoKey = "s39.holidayAutoAway"
    /// 静かで休んでいるあいだは 16kHz への変換をしない（1）・マイクの音を大きめの束で受け取る（2）・休んでいるあいだの見張りを広げる（11）・
    /// 常時表示で暗いときは輪を動かさない（12）。場所を問わず書く中身は同じ
    static let quietKey = "s39.quietPower"
    static let allKeys = [onKey, holidayAutoKey, quietKey]

    static func isOn(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func addSettings(to context: inout [String: Any], defaults: UserDefaults = .standard) {
        for key in allKeys { context[key] = isOn(key, defaults: defaults) }
    }

    static func readSettings(_ context: [String: Any], defaults: UserDefaults = .standard) {
        for key in allKeys {
            if let on = context[key] as? Bool { defaults.set(on, forKey: key) }
        }
    }

    // MARK: - 時計 → iPhone の様子の名前（どれも省ける）

    /// いま外出中か（"phone"＝iPhone が家を出ていると言う・"reach"＝iPhone に届かない。外出中でなければ付けない）
    static let awayWhyKey = "s39Away"
    /// マイクから 1 回に届いた音の長さ（こま数の平均・今日）と、その速さ（Hz）（2）
    static let tapFramesKey = "s39TapFrames"
    static let tapRateKey = "s39TapRate"
    /// 静かで休んでいるあいだに変換しなかった束の数（今日。1）
    static let rawSkippedKey = "s39RawSkipped"
    /// 元の音と 16kHz の音の、静かなところの大きさの差（dB の平均。1 の安全の見張り）
    static let levelGapKey = "s39LevelGap"
    /// 今日、外出中なので省いた回数（"context"・"wake"・"pc"・"retry"・"haptic"・"widget"・"widgetCall"）
    static let skippedKey = "s39Skipped"

    /// iPhone が家の PC に渡す時計の様子（PCDiag の watchDetail）に、s39 の分を写す（名前の頭に watch を付ける。無ければ足さない）
    static func phoneDetail(_ context: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let why = context[awayWhyKey] as? String, !why.isEmpty { out["watchS39Away"] = why }
        if let n = context[tapFramesKey] as? Int { out["watchS39TapFrames"] = n }
        if let n = context[tapRateKey] as? Int { out["watchS39TapRate"] = n }
        if let n = context[rawSkippedKey] as? Int { out["watchS39RawSkipped"] = n }
        if let gap = context[levelGapKey] as? Double { out["watchS39LevelGap"] = gap }
        if let skipped = context[skippedKey] as? [String: Int], !skipped.isEmpty { out["watchS39Skipped"] = skipped }
        return out
    }

    // MARK: - しきい値（どれも仮）

    /// iPhone に届かない時間がこれだけ続いたら外出中
    static let outOfReachAfter: TimeInterval = 30 * 60
    /// 家の Wi-Fi で家の PC にこれだけ以内に直接届いていれば家にいる
    static let lanFreshFor: TimeInterval = 30 * 60
    /// マイクの音を受け取る束の大きさ（前は 4096。watchOS が聞かないこともあるので、届いた長さを数える）
    static let tapFrames = 16384
    static let oldTapFrames = 4096
    /// 外出中・画面が消えているあいだの、iPhone への様子の知らせの間（iPhone は 10 分便りが無いと「届いていません」と
    /// 見なし、休んでいるあいだの知らせは 5 分ごとなので、5 分ごとの知らせは必ず通る 4 分にする）
    static let contextGapAway: TimeInterval = 4 * 60
    /// 外出中、これより電池が少なければ送らずに溜める。これまで戻るか充電を始めたら送る
    static let lowBattery = 0.20
    static let lowBatteryBack = 0.25
    /// iPhone を起こす sendMessage の間（家・外出中）
    static let wakeGapHome: TimeInterval = 120
    static let wakeGapAway: TimeInterval = 600
    /// マイクの見張りの間（ふだん・静かで休んでいるあいだ。休んでいても止まりは 60 秒ほどで見つかる）
    static let micCheck: TimeInterval = 20
    static let micCheckResting: TimeInterval = 30
    /// 外出中、録音の始め・止め以外の文字盤の出し直しの間
    static let widgetGapAway: TimeInterval = 15 * 60
    /// 外出中で iPhone に届かないあいだの、送り直しの試しの間
    static let retryGapOutOfReach: TimeInterval = 30 * 60
    /// 元の音と 16kHz の音の大きさの差を数える「静かな束」（16kHz の音でこれより小さい）と、数・許す差
    static let levelGapQuietBelow: Float = -45
    static let levelGapMinCount = 50
    static let levelGapLimit: Float = 1.5

    // MARK: - 外出中の判定

    enum Why: String {
        case home = ""
        case phone
        case reach
    }

    /// iPhone に届かない時間が続いているか（つながっている・列が空なら false。列の古いものの年と、最後に受け渡しが終わってからの時間）
    static func outOfReach(reachable: Bool, queued: Int, oldestQueuedAge: TimeInterval?, lastFinishedAgo: TimeInterval?,
                           after: TimeInterval = outOfReachAfter) -> Bool {
        guard !reachable, queued > 0, let oldest = oldestQueuedAge, oldest >= after else { return false }
        guard let finished = lastFinishedAgo else { return true }
        return finished >= after || finished < 0
    }

    /// 外出中か（とその理由）。lanSentAgo は家の Wi-Fi で家の PC に最後に直接届いてからの時間（無ければ nil）
    static func awayWhy(on: Bool, charging: Bool, phoneAway: Bool, outOfReach: Bool, lanSentAgo: TimeInterval?) -> Why {
        guard on, !charging else { return .home }
        if let lan = lanSentAgo, lan >= 0, lan < lanFreshFor { return .home }
        if phoneAway { return .phone }
        if outOfReach { return .reach }
        return .home
    }

    // MARK: - 3 外出モード（休日は自動）

    /// 区切りを溜めるか（外出モードがオン、または休日で「休日は自動」がオン・家を出ている・充電していない）。
    /// 家に戻るか充電を始めたら送る（前の HolidayRules.awayHold に「休日は自動」を足しただけ）
    static func holdAway(mode: Bool, holidayAuto: Bool, holiday: Bool, away: Bool, charging: Bool) -> Bool {
        (mode || (holidayAuto && holiday)) && away && !charging
    }

    // MARK: - 6 電池が少ないときは溜める

    /// 外出中で電池が 20%（仮）を切ったら溜める。25%（仮）まで戻るか充電を始めたら送る（録音は続ける）
    static func lowBatteryHold(on: Bool, away: Bool, level: Double?, charging: Bool, wasHolding: Bool) -> Bool {
        guard on, away, !charging, let level, level >= 0 else { return false }
        return wasHolding ? level < lowBatteryBack : level < lowBattery
    }

    // MARK: - 4 強い守り

    /// ワークアウト扱いで守るか（外出中は切る。止まったら戻す仕組みはそのまま）
    static func guardWanted(recording: Bool, enabled: Bool, away: Bool, on: Bool) -> Bool {
        recording && enabled && !(on && away)
    }

    // MARK: - 5 様子の知らせ

    /// iPhone に様子を知らせてよいか。urgent は録音の始め・止め・止まったとき（いつでもすぐ）
    static func contextDue(urgent: Bool, away: Bool, screenOn: Bool, lastSent: Double, now: Double,
                           gap: TimeInterval = contextGapAway) -> Bool {
        if urgent || !away || screenOn { return true }
        return lastSent <= 0 || now - lastSent >= gap || now < lastSent
    }

    // MARK: - 8 家の PC への直接送り

    /// 家の PC に直接送ってよいか（外出中はしない。溜まり続けて時計が自分で送り直したあとの窓だけは試す＝s24 の 急6）
    static func directAllowed(away: Bool, on: Bool, rescueWindow: Bool) -> Bool {
        !(on && away) || rescueWindow
    }

    // MARK: - 9 届かないあいだの送り直し

    /// 送り直しの試し（止まった受け渡しの取り消し・返事の無い区切りの送り直し）をしてよいか。
    /// 外出中で iPhone に届かないあいだは 30 分（仮）に 1 回まで。つながったらすぐ（reachable）
    static func retryDue(on: Bool, away: Bool, outOfReach: Bool, reachable: Bool, lastRetry: Double, now: Double,
                         gap: TimeInterval = retryGapOutOfReach) -> Bool {
        guard on, away, outOfReach, !reachable else { return true }
        return lastRetry <= 0 || now - lastRetry >= gap || now < lastRetry
    }

    // MARK: - 10 iPhone を起こす間

    static func wakeGap(on: Bool, away: Bool) -> TimeInterval {
        on && away ? wakeGapAway : wakeGapHome
    }

    // MARK: - 11 休んでいるあいだの見張り

    /// マイクの見張りの間（静かで休んでいるあいだは 30 秒。止まりは 60 秒ほどまでに見つかる）
    static func micCheckEvery(resting: Bool, on: Bool) -> TimeInterval {
        on && resting ? micCheckResting : micCheck
    }

    // MARK: - 13 文字盤

    /// 文字盤を出し直してよいか。外出中は、同じ中身なら出さない・録音の始め止め以外は 15 分（仮）に 1 回まで
    static func widgetDue(on: Bool, away: Bool, same: Bool, recordingChanged: Bool, lastWrite: Double, now: Double,
                          gap: TimeInterval = widgetGapAway) -> Bool {
        guard on, away else { return true }
        if same { return false }
        if recordingChanged { return true }
        return lastWrite <= 0 || now - lastWrite >= gap || now < lastWrite
    }

    // MARK: - 14 小さな振動

    /// 印・確かめなどの小さな振動を鳴らすか（外出中は切る。録音の始め・止め・止まった・失敗は、ここを通さない）
    static func lightHaptic(on: Bool, away: Bool) -> Bool { !(on && away) }

    // MARK: - 2 マイクの束

    /// 大きな束を、前の大きさ（4096）くらいに分ける範囲。前の大きさの 1.5 倍以下なら分けない（watchOS が聞かなかったときは前のまま）。
    /// 静かかどうか・区切り・声の数え方を、前と同じ細かさで決めるため
    static func slices(frames: Int, old: Int = oldTapFrames) -> [Range<Int>] {
        guard frames > 0 else { return [] }
        guard old > 0, frames > old + old / 2 else { return [0..<frames] }
        let parts = max(1, Int((Double(frames) / Double(old)).rounded()))
        var out: [Range<Int>] = []
        var start = 0
        for i in 0..<parts {
            let end = i == parts - 1 ? frames : (frames * (i + 1)) / parts
            if end > start { out.append(start..<end) }
            start = end
        }
        return out
    }

    /// マイクから届いた束の数え（今日の回数・こま数・速さ。時計の中だけで数える）
    struct TapCount: Equatable {
        private(set) var day = ""
        private(set) var calls = 0
        private(set) var frames = 0
        private(set) var rate: Double = 0

        /// 1 回届いた（日が変わったら数え直す）
        mutating func add(day: String, frames: Int, rate: Double) {
            if day != self.day {
                self.day = day
                calls = 0
                self.frames = 0
            }
            calls += 1
            self.frames += max(0, frames)
            if rate > 0 { self.rate = rate }
        }

        /// 今日の 1 回あたりのこま数（今日まだ届いていなければ nil）
        func average(day: String) -> Int? {
            guard day == self.day, calls > 0 else { return nil }
            return Int((Double(frames) / Double(calls)).rounded())
        }
    }

    // MARK: - 1 元の音と 16kHz の音の大きさの差

    /// 静かなところで「元の音の大きさ − 16kHz の音の大きさ」を数える。差が小さいと分かったときだけ、休んでいるあいだに
    /// 元の音で静かかどうかを決めてよい（差が大きい＝高い音の雑音が多いと、声で起きる所が前とずれるため）
    struct LevelGap: Equatable {
        private(set) var count = 0
        private(set) var sum: Float = 0

        mutating func feed(rawDB: Float, convertedDB: Float) {
            guard rawDB.isFinite, convertedDB.isFinite, convertedDB < S39WatchPower.levelGapQuietBelow, convertedDB > -110 else { return }
            // 数えすぎないよう、十分たまったら古い分を薄める（新しい音の様子を見る）
            if count >= 2000 {
                sum *= 0.5
                count /= 2
            }
            count += 1
            sum += rawDB - convertedDB
        }

        mutating func reset() {
            count = 0
            sum = 0
        }

        /// 差の平均（数が少なければ nil）
        var mean: Float? { count >= S39WatchPower.levelGapMinCount ? sum / Float(count) : nil }

        /// 元の音で決めてよいか（数が足りて、差の大きさが 1.5dB（仮）以内）
        var usable: Bool {
            guard let mean else { return false }
            return abs(mean) <= S39WatchPower.levelGapLimit
        }
    }

    // MARK: - 電池の見本に「省電力が効いていたか」

    /// いちばん新しい見本の後ろに「外出の省電力が効いていたら 1」を足す（[時刻, 0〜1, 溜めていたら 1, 充電中なら 1] の後ろ。
    /// 前の 4 つは変えない。4 つ揃っていない見本には足さない）
    static func markingLast(_ samples: [[Double]], saving: Bool) -> [[Double]] {
        guard var last = samples.last, last.count == 4 else { return samples }
        last.append(saving ? 1 : 0)
        var out = samples
        out[out.count - 1] = last
        return out
    }

    /// 1 時間あたりの電池の減り（%）を、省電力が効いていた・いなかったで分ける（5 つ目が無い見本は数えない。充電中は除く）
    static func drainPerHour(_ samples: [[Double]], saving: Bool) -> Double? {
        var drop = 0.0, hours = 0.0
        let sorted = samples.filter { $0.count >= 5 }.sorted { $0[0] < $1[0] }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let span = (b[0] - a[0]) / 3600
            guard span > 0, span <= 3, a[3] < 0.5, b[3] < 0.5,
                  (a[4] >= 0.5) == saving, (b[4] >= 0.5) == saving, b[1] <= a[1] else { continue }
            drop += (a[1] - b[1]) * 100
            hours += span
        }
        guard hours >= 1 else { return nil }
        return (drop / hours * 10).rounded() / 10
    }

    /// 今日の数に 1 足す（"日|名前"。今日の分だけ残す）
    static func bumped(_ saved: [String: Int], _ name: String, day: String) -> [String: Int] {
        var out = saved.filter { $0.key.hasPrefix(day + "|") }
        out[day + "|" + name, default: 0] += 1
        return out
    }

    /// 今日の数を、様子に載せる形（名前 → 回数）にする
    static func todayCounts(_ saved: [String: Int], day: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, value) in saved where key.hasPrefix(day + "|") { out[String(key.dropFirst(day.count + 1))] = value }
        return out
    }
}

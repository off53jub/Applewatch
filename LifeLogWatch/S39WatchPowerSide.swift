import Foundation
import WatchConnectivity

/// s39（2026-11-29）外出中の時計の省電力の、時計の中の分。決まりは Shared/Audio/S39WatchPower.swift。docs/s39-watch-away-power.md。
/// 「外出中」の判定はここに 1 つだけ置き（WatchSender が区切るたび・画面を出し直すたびに決め直す）、どの糸からでも読む。
enum S39WatchPowerSide {
    private static let lock = NSLock()
    private static var why: S39WatchPower.Why = .home
    private static var reachLong = false
    private static var screenOn = false
    private static var lastContext: Double = 0
    private static var lastRetry: Double = 0
    private static var lastWidgetWrite: Double = 0
    private static var lastWidget: WidgetState?
    private static var tap = S39WatchPower.TapCount()

    /// 今日、外出中なので省いた回数（"日|名前" → 回数。時計の中だけ・アプリが起き直すと 0 から。書く回数を増やさないため）
    private static var counts: [String: Int] = [:]
    /// 家の Wi-Fi で家の PC に最後に直接届いた時刻（1970 からの秒。WatchPC が書く）
    static let lanSentKey = "s39.lanSentAt"
    /// 外出中で電池が少ないので溜めているか（戻りの幅を持たせるために覚える）
    static let lowHoldKey = "s39.lowBatteryHold"

    static var on: Bool { S39WatchPower.isOn(S39WatchPower.onKey) }
    /// ChunkWriter の 1 の様子（変換しなかった束の数・大きさの差。WatchRecorder が入れる）
    static var quiet: (() -> (skipped: Int, gap: Float?))?

    /// いま外出中か
    static var away: Bool { lock.withLock { why != .home } }
    static var awayWhy: S39WatchPower.Why { lock.withLock { why } }
    /// iPhone に届かない時間が続いているか
    static var outOfReach: Bool { lock.withLock { reachLong } }

    /// 外出中かを決め直す（WatchSender から。WCSession を読むので、区切るたび・画面を出し直すたびくらいに）
    static func refresh(charging: Bool, lastFinished: Date?, now: Date = .now) {
        let defaults = UserDefaults.standard
        var reachable = false
        var queued = 0
        var oldest: TimeInterval?
        if WCSession.isSupported(), WCSession.default.activationState == .activated {
            reachable = WCSession.default.isReachable
            let transfers = WCSession.default.outstandingFileTransfers
            queued = transfers.count
            let sent = transfers.compactMap { $0.file.metadata?[WatchDelivery.sentKey] as? Double }
            if let first = sent.min() { oldest = now.timeIntervalSince1970 - first }
        }
        let far = S39WatchPower.outOfReach(reachable: reachable, queued: queued, oldestQueuedAge: oldest,
                                           lastFinishedAgo: lastFinished.map { now.timeIntervalSince($0) })
        let lan = defaults.double(forKey: lanSentKey)
        let next = S39WatchPower.awayWhy(on: on, charging: charging, phoneAway: defaults.bool(forKey: HolidayRules.awayKey),
                                         outOfReach: far, lanSentAgo: lan > 0 ? now.timeIntervalSince1970 - lan : nil)
        lock.withLock {
            why = next
            reachLong = far
        }
    }

    /// 時計の画面が出ているか（WatchContentView の scenePhase から）
    static func setScreen(_ active: Bool) { lock.withLock { screenOn = active } }

    // MARK: - 5 様子の知らせ

    /// iPhone に様子を知らせてよいか（よければ時刻を覚える。省いたら数える）
    static func takeContext(urgent: Bool, now: Date = .now) -> Bool {
        let t = now.timeIntervalSince1970
        let due = lock.withLock { () -> Bool in
            let ok = S39WatchPower.contextDue(urgent: urgent, away: on && why != .home, screenOn: screenOn, lastSent: lastContext, now: t)
            if ok { lastContext = t }
            return ok
        }
        if !due { count("context", now: now) }
        return due
    }

    // MARK: - 9 届かないあいだの送り直し

    static func takeRetry(reachable: Bool, now: Date = .now) -> Bool {
        let t = now.timeIntervalSince1970
        let due = lock.withLock { () -> Bool in
            let ok = S39WatchPower.retryDue(on: on, away: why != .home, outOfReach: reachLong, reachable: reachable, lastRetry: lastRetry, now: t)
            if ok { lastRetry = t }
            return ok
        }
        if !due { count("retry", now: now) }
        return due
    }

    // MARK: - 13 文字盤

    /// 文字盤を出し直してよいか（呼ばれた回数も数える）
    static func takeWidget(_ state: WidgetState, now: Date = .now) -> Bool {
        let t = now.timeIntervalSince1970
        count("widgetCall", now: now)
        let due = lock.withLock { () -> Bool in
            var previous = lastWidget
            previous?.updated = state.updated
            let same = previous == state
            let recordingChanged = lastWidget?.watchRecording != state.watchRecording
            let ok = S39WatchPower.widgetDue(on: on, away: why != .home, same: same, recordingChanged: recordingChanged,
                                             lastWrite: lastWidgetWrite, now: t)
            if ok {
                lastWidget = state
                lastWidgetWrite = t
            }
            return ok
        }
        if !due { count("widget", now: now) }
        return due
    }

    // MARK: - 14 小さな振動

    /// 小さな振動を鳴らす（外出中は鳴らさず数える）
    static func light(_ haptic: LLHaptic) {
        guard S39WatchPower.lightHaptic(on: on, away: away) else {
            count("haptic")
            return
        }
        haptic.play()
    }

    // MARK: - 2 マイクの束

    static func noteTap(frames: Int, rate: Double, now: Date = .now) {
        let day = HolidayRules.dayKey(now)
        lock.withLock { tap.add(day: day, frames: frames, rate: rate) }
    }

    // MARK: - 数と様子

    /// 今日の数に 1 足す（外出中なので省いた回数など）
    static func count(_ name: String, now: Date = .now) {
        let day = HolidayRules.dayKey(now)
        lock.withLock { counts = S39WatchPower.bumped(counts, name, day: day) }
    }

    /// 時計の様子に足す（どれも省ける。quiet は ChunkWriter の 1 の様子）
    static func extraState(quiet: (skipped: Int, gap: Float?)?, now: Date = .now) -> [String: Any] {
        var out: [String: Any] = [:]
        let day = HolidayRules.dayKey(now)
        let (current, tapNow, saved) = lock.withLock { (why, tap, counts) }
        if current != .home { out[S39WatchPower.awayWhyKey] = current.rawValue }
        if let average = tapNow.average(day: day) {
            out[S39WatchPower.tapFramesKey] = average
            out[S39WatchPower.tapRateKey] = Int(tapNow.rate.rounded())
        }
        if let quiet {
            if quiet.skipped > 0 { out[S39WatchPower.rawSkippedKey] = quiet.skipped }
            if let gap = quiet.gap { out[S39WatchPower.levelGapKey] = (Double(gap) * 10).rounded() / 10 }
        }
        let today = S39WatchPower.todayCounts(saved, day: day)
        if !today.isEmpty { out[S39WatchPower.skippedKey] = today }
        return out
    }
}

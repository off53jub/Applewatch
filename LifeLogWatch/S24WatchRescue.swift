import Foundation

/// s24 の 急6（2026-11-24）の時計の分。決まりは Shared/Audio/S24Watch.swift。
/// 区切るたび（WatchSender.heartbeat）に「まだ送っていない区切り」の数を覚え、1 時間（仮）一度も減らずに増え続けていたら、
/// 「いま送り直す」（s22 の 楽6）と同じことを時計が自分でする。そのうえで、直接送るがオフの日（直接送るの実験の
/// 「iPhone 経由だけ」の日など）でも 30 分（仮）は家の PC への外の道を試し、古い区切りを多めに追いかけて送る。
/// iPhone の設定（時計に溜まったら時計が自分で送り直す。初めはオン）で切れる。
enum S24WatchRescue {
    private static let samplesKey = "s24.backlogSamples"
    private static let lastKey = "s24.rescueLast"
    private static let countsKey = "s24.rescueCounts"
    private static let lock = NSLock()

    /// 区切るたびに呼ぶ（unsent は家の PC から iPhone が受け取るのを待っている分を除いた数）
    static func check(_ sender: WatchSender, unsent: Int, now: Date = .now) {
        let t = now.timeIntervalSince1970
        let due: Bool = lock.withLock {
            let defaults = UserDefaults.standard
            let samples = S24Watch.addingSample(defaults.array(forKey: samplesKey) as? [[Double]] ?? [], time: t, count: unsent)
            defaults.set(samples, forKey: samplesKey)
            guard S24Watch.rescueOn, S24Watch.backlogGrowing(samples, now: t),
                  S24Watch.rescueDue(last: defaults.double(forKey: lastKey), now: t) else { return false }
            defaults.set(t, forKey: lastKey)
            defaults.set(t + S24Watch.rescueDirectFor, forKey: S24Watch.rescueUntilKey)
            let counts = defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
            defaults.set(S24Watch.addingCount(counts, day: HolidayRules.dayKey(now),
                                              keepFrom: HolidayRules.dayKey(now.addingTimeInterval(-7 * 86400))),
                         forKey: countsKey)
            return true
        }
        guard due else { return }
        // 「いま送り直す」と同じ（止まった受け渡しの取り消し・返事待ちの片付け・残りと控えの送り直し）。heartbeat は呼ばない（ここから呼ばれている）
        sender.unstickTransfers(now: now)
        sender.tidyKept(now: now, force: true)
        sender.resendPending()
        sender.resendKept(minAge: 0)
        // 家の PC へ: 30 分は直接送るがオフでも外の道を試す（WatchPC.send が S24Watch.directNow を見る）。古い順に多めに
        sender.pc.catchUp(fresh: true, limit: S24Watch.rescueCatchUp)
        sender.wakePhone(force: true)
    }

    /// 時計の様子に足す（今日の回数・最後の時刻。無ければ足さない）
    static func extraState(now: Date) -> [String: Any] {
        let defaults = UserDefaults.standard
        var out: [String: Any] = [:]
        let counts = defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        if let n = counts[HolidayRules.dayKey(now)], n > 0 { out[S24Watch.rescueCountKey] = n }
        let last = defaults.double(forKey: lastKey)
        if last > 0 { out[S24Watch.rescueAtKey] = last }
        return out
    }
}

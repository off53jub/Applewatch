import Foundation

/// s24（2026-11-24）の時計と iPhone の両方で使う決まり（決まった入力から決まった出力だけ）。
/// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 13」の番号。しきい値はどれも仮（データがたまったら測り直す）。
/// テストは LifeLogTests/S24WatchTests.swift。
///
/// - 急6: 時計の中の「まだ送っていない区切り」が 1 時間（仮）増え続けたら、時計が自分で送り直す（初めはオン）。
///   2026-11-24 は、直接送るの実験（s21 の 電2）が「iPhone 経由だけ」の日で、時計のアプリが 14:54〜14:58 に止められて
///   版 386 で戻ったあと「直接送るがオフ」になり（自己点検の「時計: 直接送るがオフのまま」）、iPhone への受け渡しの列に
///   250 個が 4 時間止まった（19:12〜19:30 にまとめて届いた）。外の道が止まったのは実験のとおりで、戻らない作りではなかった。
///   そこで、溜まり続けたときだけ、実験の日でも 30 分（仮）は家の PC への外の道も試す（送り直した回数は様子に出す）。
/// - 急7: 家の PC が言う「外の道で最後に時計の区切りを預かった時刻」（GET /watch-route の watchDirectLast。取り決め C2）の読み方。
enum S24Watch {
    // MARK: - 急6 iPhone → 時計の設定（applicationContext）

    /// 溜まり続けたら時計が自分で送り直す（無ければオン）
    static let rescueKey = "s24RescueOn"

    static var rescueOn: Bool { UserDefaults.standard.object(forKey: rescueKey) as? Bool ?? true }

    static func addSettings(to context: inout [String: Any], defaults: UserDefaults = .standard) {
        context[rescueKey] = defaults.object(forKey: rescueKey) as? Bool ?? true
    }

    static func readSettings(_ context: [String: Any], defaults: UserDefaults = .standard) {
        if let on = context[rescueKey] as? Bool { defaults.set(on, forKey: rescueKey) }
    }

    // MARK: - 急6 時計 → iPhone の様子の名前（どれも省ける）

    /// 今日、溜まり続けたので自分で送り直した回数
    static let rescueCountKey = "s24Rescue"
    /// 最後に自分で送り直した時刻（1970 からの秒）
    static let rescueAtKey = "s24RescueAt"

    // MARK: - 急6 しきい値（どれも仮）

    /// これだけのあいだ一度も減らずに増えていたら「増え続けた」
    static let growWindow: TimeInterval = 60 * 60
    /// そのあいだに、少なくともこれだけ増えた
    static let growMin = 2
    /// 送り直しの間（続けて何度もしない）
    static let rescueGap: TimeInterval = 30 * 60
    /// 送り直したあと、直接送るがオフでも外の道を試すあいだ
    static let rescueDirectFor: TimeInterval = 30 * 60
    /// 送り直すときに家の PC に追いかけて送る数（ふだんは 3）
    static let rescueCatchUp = 12
    /// 数の見本を覚える長さ・見本どうしの間
    static let keepSamples: TimeInterval = 2 * 3600
    static let sampleGap: TimeInterval = 60
    /// 時計の中の、外の道を試してよい終わりの時刻（1970 からの秒）
    static let rescueUntilKey = "s24.rescueDirectUntil"

    /// 溜まった数の見本（[時刻, 数]）に 1 つ足す。2 時間より古いもの・先の時刻のものは捨てる。
    /// 1 分以内に続けて来たら、時刻はそのまま数だけ書き換える
    static func addingSample(_ samples: [[Double]], time: Double, count: Int) -> [[Double]] {
        var out = samples.filter { $0.count == 2 && $0[0] <= time && time - $0[0] < keepSamples }
            .sorted { $0[0] < $1[0] }
        if let last = out.last, time - last[0] < sampleGap {
            out[out.count - 1] = [last[0], Double(count)]
        } else {
            out.append([time, Double(count)])
        }
        return out
    }

    /// 1 時間（仮）増え続けたか: 1 時間より前の見本のうちいちばん新しいものを始まりにして、そのあと一度も始まりより減らず、
    /// いまは始まりより growMin 以上多い。あいだの見本が 2 つより少ない（アプリが止まっていた）ときは決めない
    static func backlogGrowing(_ samples: [[Double]], now: Double) -> Bool {
        let sorted = samples.filter { $0.count == 2 && $0[0] <= now }.sorted { $0[0] < $1[0] }
        guard let baseIndex = sorted.lastIndex(where: { now - $0[0] >= growWindow }) else { return false }
        let base = sorted[baseIndex][1]
        let after = sorted[(baseIndex + 1)...]
        guard after.count >= 2, let latest = after.last else { return false }
        guard after.allSatisfy({ $0[1] >= base }) else { return false }
        return latest[1] >= base + Double(growMin)
    }

    /// 送り直してよい頃か（前の送り直しから 30 分。仮）
    static func rescueDue(last: Double, now: Double) -> Bool {
        last <= 0 || now - last >= rescueGap || now < last
    }

    /// いま家の PC に直接送ってよいか（iPhone の「直接送る」か、送り直しのあとの 30 分）
    static func directNow(stored: Bool, rescueOn: Bool, rescueUntil: Double, now: Double) -> Bool {
        stored || (rescueOn && rescueUntil > now)
    }

    /// 日ごとの回数に 1 足す（7 日だけ残す）
    static func addingCount(_ counts: [String: Int], day: String, keepFrom: String) -> [String: Int] {
        var out = counts.filter { $0.key >= keepFrom }
        out[day, default: 0] += 1
        return out
    }

    // MARK: - 急7 家の PC の watchDirectLast（取り決め C2）

    /// 家の PC に 30 分（仮）以内に届いていれば、iPhone は「時計の録音が届いていません」を出さない
    static let directFreshFor: TimeInterval = 30 * 60
    /// 家の PC に聞き直す間（仮）
    static let askEvery: TimeInterval = 5 * 60
    /// 時計と PC の時計のずれを、これだけは許す
    static let clockSkew: TimeInterval = 5 * 60

    /// "2026-11-24T14:58:49+09:00"（秒の小数・Z も読む）→ 時刻。読めなければ nil
    static func parseLast(_ text: String?) -> Date? {
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // 秒の小数（.123456 など）は外す（ISO8601DateFormatter は桁の多い小数を読めないことがある）
        if let dot = t.firstIndex(of: "."), let tee = t.firstIndex(of: "T"), dot > tee {
            var end = t.index(after: dot)
            while end < t.endIndex, t[end].isNumber { end = t.index(after: end) }
            t.removeSubrange(dot..<end)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t)
    }

    /// 家の PC に、いまから 30 分（仮）以内に届いているか（先の時刻は 5 分まで許す）。無ければ false
    static func pcGotRecently(_ last: Date?, now: Date) -> Bool {
        guard let last else { return false }
        let age = now.timeIntervalSince(last)
        return age >= -clockSkew && age <= directFreshFor
    }

    /// 家の PC に聞き直す頃か
    static func askDue(lastAsked: Double, now: Double) -> Bool {
        lastAsked <= 0 || now - lastAsked >= askEvery || now < lastAsked
    }

    /// iPhone が「時計の録音が届いていません」と 守4 を黙らせてよいか（C2）:
    /// 時計の「直接送る」がオン・今日の実験が直接送ってよい日・家の PC に 30 分以内に届いている、の全部のときだけ
    static func quiet(watchDirectOn: Bool?, allowed: Bool, pcLast: Date?, now: Date) -> Bool {
        watchDirectOn == true && allowed && pcGotRecently(pcLast, now: now)
    }
}

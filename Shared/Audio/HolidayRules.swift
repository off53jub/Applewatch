import Foundation

/// 休日のライフログ（2026-11-21。s19。番号は母艦に出した 休1〜休50 の番号。docs/s19-holiday-app.md）。
/// 時計と iPhone の両方で使う決まり（決まった入力から決まった出力だけ。テストは LifeLogTests/HolidayTests.swift）。
/// しきい値はどれも仮（データがたまったら測り直す）。
enum HolidayRules {
    // MARK: - iPhone → 時計の設定の名前（applicationContext）

    /// 今日が休みなら、その日（yyyy-MM-dd）。休みでなければ空。時計は自分の今日と同じときだけ休日とみなす（古い知らせを使わない）
    static let holidayDayKey = "holidayDay"
    /// 時計の電池が少ないとき「PLAUD に任せて」と知らせるか（休9。初めはオン）
    static let lowBatteryKey = "holidayLowBattery"
    /// 時計の外出モード（休8。初めはオフ）
    static let awayModeKey = "holidayAwayMode"
    /// iPhone が「家を出ている」と思っているか（休8。登録した「自宅」の見張りから）
    static let awayKey = "holidayAway"
    /// 車につないだ時刻（1970 からの秒。つないでいなければ 0。休13）
    static let carSinceKey = "carSince"

    // MARK: - 時計 → iPhone の様子の名前（deliveryState）

    /// 今日の、アラーム・電話・Siri などの中断の回数（休10）
    static let interruptionsKey = "interruptions"
    /// 今日、中断のあとに録音を流し直せた回数（休10）
    static let resumedKey = "resumed"
    /// 今日、録音が止まりかけた回数（マイクが来ない・流し直せない・書けない。止めずに試し続ける。2026-11-22）
    static let stallsKey = "stalls"
    /// 今日、止まりかけた録音を自動で戻せた回数（2026-11-22）
    static let autoResumedKey = "autoResumed"
    /// 最後に止まりかけた時刻と理由（"1970 からの秒|mic・open・restart・write・alarm"。2026-11-22）
    static let lastStallKey = "lastStall"
    /// 時計のアプリの build（iPhone と版が食い違っていないかを見る。2026-11-22）
    static let watchBuildKey = "build"
    /// 電池の見本（[[時刻, 0〜1, 外出モードで溜めていたら 1]]。1 時間に 1 つ・直近 48 個。休8）
    static let batteryAtKey = "batteryAt"
    /// いま外出モードで区切りを溜めているか（休8）
    static let awayHoldingKey = "awayHolding"
    /// いま「初めての人が多い」モードか（休17）
    static let crowdKey = "crowd"

    // MARK: - しきい値（仮）

    /// 時計の電池がこれより少なければ「PLAUD に任せて」（20%。仮）
    static let lowBattery: Double = 0.20
    /// 電池の見本を残す間（1 時間）と数（48 個）
    static let batterySampleEvery: TimeInterval = 3600
    static let batterySampleLimit = 48
    /// 「初めての人が多い」モードが自動で終わるまで（4 時間。仮）
    static let crowdLength: TimeInterval = 4 * 3600
    /// 区切りごとの「初めての人」の印を、区切った時刻のこれだけ前に付ける（区切りの中ほど。60 秒。仮）
    static let crowdMarkBack: TimeInterval = 60

    // MARK: - 休みの日の印（休1）

    /// 休みの理由。母艦の state/holiday/days.json の why と同じ言葉
    static let whyWeekend = "土日"
    static let whyHoliday = "祝日"
    static let whyLeave = "アプリの休み"

    // MARK: - 1 日ごとの数

    /// 今日の数（"日|名前" の形。日が変わった分は数えない）
    static func count(_ saved: [String: Int], _ name: String, day: String) -> Int {
        saved[day + "|" + name] ?? 0
    }

    /// 1 つ足す（今日の分だけ残す）
    static func bumped(_ saved: [String: Int], _ name: String, day: String, by: Int = 1) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, value) in saved where key.hasPrefix(day + "|") { out[key] = value }
        out[day + "|" + name, default: 0] += by
        return out
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// iPhone が送った休みの日が、時計の今日か
    static func isHolidayToday(_ holidayDay: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let holidayDay, !holidayDay.isEmpty else { return false }
        return holidayDay == dayKey(now, calendar: calendar)
    }

    // MARK: - 時計の電池（休9）

    /// 「PLAUD に任せて」を出すか（休日・設定がオン・充電していない・少ない・今日まだ出していない）
    static func shouldWarnLowBattery(enabled: Bool, holiday: Bool, level: Double?, charging: Bool,
                                     warnedDay: String?, today: String, limit: Double = lowBattery) -> Bool {
        guard enabled, holiday, !charging, let level, level >= 0, level < limit else { return false }
        return warnedDay != today
    }

    // MARK: - 外出モード（休8）

    /// 区切りを送らずに溜めるか（設定がオン・家を出ている・充電していない）。家に戻るか充電を始めたら送る
    static func awayHold(mode: Bool, away: Bool, charging: Bool) -> Bool {
        mode && away && !charging
    }

    /// 電池の見本を足すか（前の見本から 1 時間たった）
    static func batterySampleDue(last: Double?, now: Date, every: TimeInterval = batterySampleEvery) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince1970 - last >= every
    }

    /// 見本を足して、古いものを捨てる。
    /// charging を渡すと 4 つ目に「充電中なら 1」を足す（2026-11-22。s21 の 電1。家の PC が充電中の増えを減りと分けられるように。
    /// 前の 3 つの並びは変えない。古い見本は 3 つのまま）
    static func addingSample(_ samples: [[Double]], time: Date, level: Double, holding: Bool, charging: Bool? = nil,
                             limit: Int = batterySampleLimit) -> [[Double]] {
        var out = samples.filter { $0.count >= 2 }
        var sample: [Double] = [time.timeIntervalSince1970.rounded(), (level * 100).rounded() / 100, holding ? 1 : 0]
        if let charging { sample.append(charging ? 1 : 0) }
        out.append(sample)
        return Array(out.suffix(max(0, limit)))
    }

    /// 1 時間あたりの電池の減り（%。holding が true なら溜めていたあいだ、false ならそれ以外）。
    /// 続いた見本どうしで、減ったところ（充電で増えたところは除く）だけを足す。足りなければ nil
    static func drainPerHour(_ samples: [[Double]], holding: Bool) -> Double? {
        var drop = 0.0, hours = 0.0
        let sorted = samples.filter { $0.count >= 3 }.sorted { $0[0] < $1[0] }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let span = (b[0] - a[0]) / 3600
            guard span > 0, span <= 3, (a[2] >= 0.5) == holding, (b[2] >= 0.5) == holding, b[1] <= a[1] else { continue }
            drop += (a[1] - b[1]) * 100
            hours += span
        }
        guard hours >= 1 else { return nil }
        return (drop / hours * 10).rounded() / 10
    }

    // MARK: - 初めての人が多い日（休17）

    /// モードが続いているか
    static func crowdActive(until: Double?, now: Date) -> Bool {
        guard let until, until > 0 else { return false }
        return now.timeIntervalSince1970 < until
    }

    // MARK: - 車内の印（休13）

    /// その区切りが車につないでいたあいだにかかるか（つないだ時刻より後に終わった区切り）
    static func inCar(chunkStart: Date?, chunkEnd: Date?, carSince: Double?) -> Bool {
        guard let carSince, carSince > 0 else { return false }
        guard let end = chunkEnd ?? chunkStart else { return false }
        return end.timeIntervalSince1970 >= carSince
    }
}

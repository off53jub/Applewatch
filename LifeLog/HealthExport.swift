import Foundation

/// ヘルスケアの1日分を、ドライブの「LifeLog/ヘルスケア」に1日1ファイルで書き出す（2026-11-08）。
///
/// - 母艦（家の PC の D:\Lifelog）のヘルスケアは、2026-05-18 を最後に止まっていた（前は別のアプリ Health Auto Export が書いていた）。
///   母艦の取り込み（Process-HealthInbox.ps1）がそのまま読めるよう、同じ形の JSON にする。
/// - 書くのは終わった日だけ（2026-11-15 から次の日の 0:30 を過ぎてから。前は次の日の昼）。一度書いた日は書き直さない。
/// - 止まっていた日の分も、iPhone のヘルスケアに残っている分を少しずつ書く（1回に `perRun` 日まで）。
/// - 読むだけで、ヘルスケアには何も書かない。iPhone だけで動かす（iPad と二重に書かない）。
enum HealthExport {
    /// ここから後の日を書く（母艦の最後の日は 2026-05-18。その日は前のアプリの分を残す）
    static let firstDay = "2026-05-19"
    /// 1回に書く日数の上限（止まっていた日の分は、毎回少しずつ）
    static let perRun = 20
    /// 書いた日の印（UserDefaults）
    static let doneKey = "healthExportedDays"
    /// ドライブのフォルダの名前（LifeLog フォルダの中）
    static let folderName = "ヘルスケア"

    struct Day: Equatable {
        /// 日付（yyyy-MM-dd）
        var day: String
        var steps: Int?
        var heartMin: Double?
        var heartMax: Double?
        var heartAverage: Double?
        var resting: Double?
        var sleep: Sleep?
        /// 動いたエネルギー（kcal）・エクササイズの分・立った分（2026-11-19。s18 の 48。母艦の Process-HealthInbox.ps1 が読む名前で書く）
        var activeKcal: Double? = nil
        var exerciseMinutes: Double? = nil
        var standMinutes: Double? = nil
        /// 心拍変動（HRV・SDNN の平均と幅。ミリ秒。2026-11-21。s19 の 休45。疲れの抜け具合の見立て（仮）は母艦が 14 日の基準と比べる）
        var hrv: Double? = nil
        var hrvMin: Double? = nil
        var hrvMax: Double? = nil
        /// ワークアウト（始まりがその日のもの）
        var workouts: [Workout] = []

        struct Workout: Equatable {
            var name: String
            var start: Date
            var end: Date
            var kcal: Double?
            var km: Double?
        }

        struct Sleep: Equatable {
            var start: Date
            var end: Date
            /// 寝ていた長さ（秒）
            var asleep: TimeInterval
            /// ベッドにいた長さ（秒。記録が無ければ nil）
            var inBed: TimeInterval?
            var deep: TimeInterval = 0
            var rem: TimeInterval = 0
            var core: TimeInterval = 0
            var awake: TimeInterval = 0
        }

        var isEmpty: Bool {
            (steps ?? 0) == 0 && heartMin == nil && heartMax == nil && heartAverage == nil && resting == nil && sleep == nil
                && (activeKcal ?? 0) == 0 && (exerciseMinutes ?? 0) == 0 && (standMinutes ?? 0) == 0 && workouts.isEmpty
                && hrv == nil
        }
    }

    static func fileName(_ day: String) -> String { "lifelog-health-\(day).json" }

    /// 日が変わってから、これだけたったら前の日を書く（2026-11-15。強化案 46。前は次の日の昼）。
    /// その日の睡眠は「前の日の18時〜その日の昼」なので、日が変わった時点でそろっている。夜中の裏の処理（充電中）で書き、
    /// iPhone がロック中でヘルスケアを読めなかった（どの日も空）ときは印を付けないので、次に開いたとき（昼まで含む）に書く
    static let readyAfterMidnight: TimeInterval = 30 * 60

    /// 書く日（古い順）。first から、終わった日（次の日の 0:30 を過ぎた日）まで、まだ書いていない日を limit 日まで。
    static func dueDays(now: Date, done: Set<String>, first: String = firstDay, limit: Int = perRun,
                        calendar: Calendar = .current) -> [String] {
        guard let start = dayDate(first, calendar: calendar) else { return [] }
        var result: [String] = []
        var day = start
        while result.count < limit {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let ready: Date = next.addingTimeInterval(readyAfterMidnight)
            guard now >= ready else { break }
            let key = dayKey(day, calendar: calendar)
            if !done.contains(key) { result.append(key) }
            day = next
        }
        return result
    }

    /// 母艦の取り込みが読む形（Health Auto Export と同じ: { data: { metrics: [...], workouts: [] } }）
    static func json(_ d: Day, calendar: Calendar = .current) -> Data? {
        guard let dayStart = dayDate(d.day, calendar: calendar) else { return nil }
        let date = stamp(dayStart, calendar: calendar)
        var metrics: [[String: Any]] = []
        if let steps = d.steps, steps > 0 {
            metrics.append(["name": "step_count", "units": "count", "data": [["date": date, "qty": steps]]])
        }
        var heart: [String: Any] = ["date": date]
        if let v = d.heartMin { heart["Min"] = rounded(v) }
        if let v = d.heartMax { heart["Max"] = rounded(v) }
        if let v = d.heartAverage { heart["Avg"] = rounded(v) }
        if heart.count > 1 { metrics.append(["name": "heart_rate", "units": "count/min", "data": [heart]]) }
        if let v = d.resting {
            metrics.append(["name": "resting_heart_rate", "units": "count/min", "data": [["date": date, "qty": rounded(v)]]])
        }
        if let s = d.sleep {
            var entry: [String: Any] = [
                "date": date, "sleepStart": stamp(s.start, calendar: calendar), "sleepEnd": stamp(s.end, calendar: calendar),
                "asleep": hours(s.asleep), "deep": hours(s.deep), "rem": hours(s.rem), "core": hours(s.core), "awake": hours(s.awake),
            ]
            if let inBed = s.inBed { entry["inBed"] = hours(inBed) }
            metrics.append(["name": "sleep_analysis", "units": "hr", "data": [entry]])
        }
        if let v = d.activeKcal, v > 0 {
            metrics.append(["name": "active_energy", "units": "kcal", "data": [["date": date, "qty": rounded(v)]]])
        }
        if let v = d.exerciseMinutes, v > 0 {
            metrics.append(["name": "apple_exercise_time", "units": "min", "data": [["date": date, "qty": rounded(v)]]])
        }
        if let v = d.standMinutes, v > 0 {
            metrics.append(["name": "apple_stand_time", "units": "min", "data": [["date": date, "qty": rounded(v)]]])
        }
        // 心拍変動（Health Auto Export と同じ名前 heart_rate_variability・ms。2026-11-21。s19 の 休45）
        if let v = d.hrv, v > 0 {
            var entry: [String: Any] = ["date": date, "qty": rounded(v)]
            if let low = d.hrvMin { entry["Min"] = rounded(low) }
            if let high = d.hrvMax { entry["Max"] = rounded(high) }
            metrics.append(["name": "heart_rate_variability", "units": "ms", "data": [entry]])
        }
        var workouts: [[String: Any]] = []
        for w in d.workouts {
            // duration は時間（母艦の Process-HealthInbox.ps1 が 60 を掛けて分にする）
            var entry: [String: Any] = ["name": w.name, "start": stamp(w.start, calendar: calendar), "end": stamp(w.end, calendar: calendar),
                                        "duration": hours(max(0, w.end.timeIntervalSince(w.start)))]
            if let kcal = w.kcal, kcal > 0 { entry["activeEnergy"] = ["qty": rounded(kcal), "units": "kcal"] }
            if let km = w.km, km > 0 { entry["distance"] = ["qty": (km * 100).rounded() / 100, "units": "km"] }
            workouts.append(entry)
        }
        let object: [String: Any] = ["source": "LifeLog", "day": d.day, "data": ["metrics": metrics, "workouts": workouts]]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func dayDate(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 時差つきの時刻（例: 2026-05-19T07:30:00+09:00）。母艦は DateTimeOffset で読む
    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = calendar.timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func hours(_ seconds: TimeInterval) -> Double { (seconds / 3600 * 1000).rounded() / 1000 }
    private static func rounded(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

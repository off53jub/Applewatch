import Foundation

/// 日本の祝日を計算で出す（2026-11-26）。
/// それまでは iPhone のカレンダーに「日本の祝日」が入っているときだけ祝日が分かり、入っていないと
/// 祝日の会話まで「職場」になっていた（母艦で数えると 11/3・11/23 の旅先やダンスの会話が職場に入っていた）。
/// 2022 年以降の決まり（国民の祝日に関する法律）。春分・秋分は 1980〜2099 年の近似の式。
/// 振替休日（日曜の祝日の次の祝日でない日）と国民の休日（祝日にはさまれた平日）も出す。
enum JapanHoliday {
    static let tokyo: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return c
    }()

    /// その日（東京の日付）の祝日の名前。祝日でなければ nil
    static func name(_ date: Date, calendar: Calendar = tokyo) -> String? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return name(year: year, month: month, day: day)
    }

    static func isHoliday(_ date: Date, calendar: Calendar = tokyo) -> Bool {
        name(date, calendar: calendar) != nil
    }

    /// 年・月・日で引く（試しと計算のため）
    static func name(year: Int, month: Int, day: Int) -> String? {
        if let fixed = basic(year: year, month: month, day: day) { return fixed }
        // 振替休日: 前の日から日曜まで祝日が続いていて、その日曜が祝日なら、続きの最初の祝日でない日
        var back = 1
        while let prev = shifted(year: year, month: month, day: day, by: -back) {
            guard basic(year: prev.year, month: prev.month, day: prev.day) != nil else { break }
            if weekday(year: prev.year, month: prev.month, day: prev.day) == 1 { return "振替休日" }
            back += 1
        }
        // 国民の休日: 前の日と次の日が祝日（日曜は除く）
        if weekday(year: year, month: month, day: day) != 1,
           let prev = shifted(year: year, month: month, day: day, by: -1),
           let next = shifted(year: year, month: month, day: day, by: 1),
           basic(year: prev.year, month: prev.month, day: prev.day) != nil,
           basic(year: next.year, month: next.month, day: next.day) != nil {
            return "国民の休日"
        }
        return nil
    }

    /// 振替と国民の休日を除いた祝日
    static func basic(year: Int, month: Int, day: Int) -> String? {
        switch (month, day) {
        case (1, 1): return "元日"
        case (2, 11): return "建国記念の日"
        case (2, 23): return "天皇誕生日"
        case (4, 29): return "昭和の日"
        case (5, 3): return "憲法記念日"
        case (5, 4): return "みどりの日"
        case (5, 5): return "こどもの日"
        case (8, 11): return "山の日"
        case (11, 3): return "文化の日"
        case (11, 23): return "勤労感謝の日"
        default: break
        }
        if month == 1 && day == nthMonday(year: year, month: 1, n: 2) { return "成人の日" }
        if month == 7 && day == nthMonday(year: year, month: 7, n: 3) { return "海の日" }
        if month == 9 && day == nthMonday(year: year, month: 9, n: 3) { return "敬老の日" }
        if month == 10 && day == nthMonday(year: year, month: 10, n: 2) { return "スポーツの日" }
        if month == 3 && day == equinox(year: year, base: 20.8431) { return "春分の日" }
        if month == 9 && day == equinox(year: year, base: 23.2488) { return "秋分の日" }
        return nil
    }

    /// 春分・秋分の日（1980〜2099 年の近似）
    static func equinox(year: Int, base: Double) -> Int {
        let y: Int = year - 1980
        let value: Double = base + 0.242194 * Double(y) - Double(y / 4)
        return Int(value.rounded(.down))
    }

    /// その月の n 番目の月曜の日
    static func nthMonday(year: Int, month: Int, n: Int) -> Int {
        let first: Int = weekday(year: year, month: month, day: 1)   // 1=日 … 2=月
        let offset: Int = (2 - first + 7) % 7
        return 1 + offset + (n - 1) * 7
    }

    /// 曜日（1=日曜 … 7=土曜）
    static func weekday(year: Int, month: Int, day: Int) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        guard let date = tokyo.date(from: comps) else { return 0 }
        return tokyo.component(.weekday, from: date)
    }

    private static func shifted(year: Int, month: Int, day: Int, by days: Int) -> (year: Int, month: Int, day: Int)? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        guard let date = tokyo.date(from: comps), let moved = tokyo.date(byAdding: .day, value: days, to: date) else { return nil }
        let p = tokyo.dateComponents([.year, .month, .day], from: moved)
        guard let y = p.year, let m = p.month, let d = p.day else { return nil }
        return (y, m, d)
    }
}

import Foundation

/// 休みの日の見分け（2026-11-07）。土日・カレンダーの祝日・休みの終日の予定（有休・代休など）。
/// 休みの日は、仕事のタスクの朝夕の知らせを止め、朝の読み上げでも仕事の頼まれごとを読まない。
/// カレンダーを使っていない（許可が無い・オフ）ときは、土日だけを休みとみなす。
enum DayOff {
    /// その日の終日の予定1つ
    struct AllDay: Equatable {
        var title: String
        /// 予定のメモ（祝日のカレンダーの「行事」を見分けるのに使う）
        var notes: String = ""
        /// 祝日のカレンダー（「日本の祝日」など）の予定
        var holidayCalendar: Bool = false
    }

    /// 休みの予定とみなす言葉（題にこれがある終日の予定）
    static let leaveWords = ["有休", "有給", "年休", "代休", "振休", "振替休日", "休暇", "休み", "休日", "公休", "特休",
                             "夏休", "冬休", "day off", "vacation"]
    /// 1日まるごとの休みではないもの・休みについての用事（題にこれがあれば休みとみなさない）
    static let notWholeDayWords = ["半休", "午前休", "午後休", "半日", "時間休", "明け", "申請", "提出", "締", "出勤", "当番"]
    /// 祝日のカレンダーに入っている、休みではない行事
    static let observanceWords = ["節分", "ひな祭り", "雛祭り", "桃の節句", "端午の節句", "バレンタイン", "ホワイトデー",
                                  "母の日", "父の日", "七夕", "お盆", "七五三", "ハロウィン", "クリスマス", "大晦日",
                                  "valentine", "white day", "mother's day", "father's day", "tanabata", "setsubun",
                                  "halloween", "christmas", "new year's eve"]

    /// 祝日のカレンダーか（題に「祝日」「祭日」「holiday」がある）
    static func isHolidayCalendar(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("祝日") || t.contains("祭日") || t.contains("holiday")
    }

    /// その終日の予定があると休みか
    static func isOffEvent(_ event: AllDay) -> Bool {
        let title = event.title.lowercased()
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if notWholeDayWords.contains(where: { title.contains($0) }) { return false }
        if event.holidayCalendar {
            // Google の「日本の祝日」は、休みでない行事のメモに「行事」と書いてある
            let notes = event.notes.lowercased()
            if notes.contains("行事") || notes.contains("observance") { return false }
            return !observanceWords.contains { title.contains($0) }
        }
        return leaveWords.contains { title.contains($0) }
    }

    /// 休みの日か（土日か、休みの終日の予定がある）
    static func isOff(_ day: Date, allDay: [AllDay], calendar: Calendar = .current) -> Bool {
        if calendar.isDateInWeekend(day) { return true }
        return allDay.contains { isOffEvent($0) }
    }
}

extension Pipeline {
    /// 休みの日か（土日・カレンダーの祝日・休みの終日の予定）。カレンダーを使っていなければ土日だけ
    func isDayOff(_ date: Date) -> Bool {
        DayOff.isOff(date, allDay: calendar.allDayEvents(on: date))
    }
}

import Foundation

/// ウィジェットに出す短い文（2026-11-07）。iPhone と時計のウィジェットで同じ言い方にする。
/// 中身が読めない（App Group が使えない入れ方など）・分からないときは「—」を出す。
enum WidgetText {
    /// 中身が無い・分からない
    static let unknown = "—"
    /// 12時間以内に予定が無い
    static let noEvent = "予定なし"

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d H:mm"
        return f
    }()

    /// 時刻。now と同じ日なら「10:32」、ほかの日なら「11/6 22:10」
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? timeFormatter.string(from: date) : dayTimeFormatter.string(from: date)
    }

    // MARK: - 録音

    /// この端末（iPhone）の録音
    static func phone(_ state: WidgetState?) -> String {
        guard let recording = state?.phoneRecording else { return unknown }
        return recording ? "録音中" : "停止中"
    }

    /// 時計の録音（iPhone のウィジェット用）。時計から一度も知らせが無ければ nil（時計を使っていない）
    static func watch(_ state: WidgetState?) -> String? {
        guard let state else { return nil }
        if state.watchQuiet == true { return "届いていません" }
        guard let recording = state.watchRecording else { return nil }
        return recording ? "録音中" : "停止中"
    }

    /// どこかで録音しているか（知らせが途絶えた時計は数えない）
    static func anyRecording(_ state: WidgetState?) -> Bool {
        guard let state else { return false }
        return state.phoneRecording == true || (state.watchRecording == true && state.watchQuiet != true)
    }

    /// 録音の様子の一言。onWatch は時計の文字盤（自分のことなので「時計で」と言わない）
    static func summary(_ state: WidgetState?, onWatch: Bool = false) -> String {
        guard let state else { return "LifeLog" }
        if onWatch {
            guard let recording = state.watchRecording else { return "LifeLog" }
            return recording ? "録音中" : "停止中"
        }
        if state.phoneRecording == true { return "録音中" }
        if state.watchQuiet == true { return "時計が届いていません" }
        if state.watchRecording == true { return "時計で録音中" }
        if state.phoneRecording == nil && state.watchRecording == nil { return "LifeLog" }
        return "停止中"
    }

    /// 1行だけのウィジェット（「録音中・今日まで 3件」）
    static func inline(_ state: WidgetState?, onWatch: Bool = false) -> String {
        var text = summary(state, onWatch: onWatch)
        if let due = state?.tasksDue, due > 0 { text += "・今日まで \(due)件" }
        return text
    }

    /// 時計の長方形の1行目（「録音中・送っていない 2」）
    static func watchHeadline(_ state: WidgetState?) -> String {
        var text = summary(state, onWatch: true)
        if let unsent = state?.watchUnsent, unsent > 0 { text += "・送っていない \(unsent)" }
        return text
    }

    /// 時計の文字盤の角の短い文（「録音中・3件」「今日まで 3件」「停止中」）。角は短い文しか入らない
    static func corner(_ state: WidgetState?) -> String {
        let head = summary(state, onWatch: true)
        guard let due = state?.tasksDue, due > 0 else { return head }
        return state?.watchRecording == true ? head + "・\(due)件" : "今日まで \(due)件"
    }

    // MARK: - 頼まれごと

    /// 今日までの頼まれごと（「今日まで 3件（期限切れ 1）」）
    static func tasks(_ state: WidgetState?) -> String {
        guard let due = state?.tasksDue else { return unknown }
        let overdue = state?.tasksOverdue ?? 0
        return "今日まで \(due)件" + (overdue > 0 ? "（期限切れ \(overdue)）" : "")
    }

    /// まだの頼まれごと全部の数（分からなければ nil）
    static func openTasks(_ state: WidgetState?) -> String? {
        state?.tasksOpen.map { "まだのもの 全部で \($0)件" }
    }

    // MARK: - 予定

    /// 予定の時刻の部分。始まる前は「10:30」、始まったら「いま〜11:00」。終わっていたら nil
    static func eventTime(_ event: WidgetState.Event, at date: Date, calendar: Calendar = .current) -> String? {
        if date >= event.until { return nil }
        if date >= event.start { return "いま〜" + clock(event.until, now: date, calendar: calendar) }
        return clock(event.start, now: date, calendar: calendar)
    }

    /// 出す予定の時刻と名前。出す予定が無ければ nil（そのときは noEventText を出す）
    static func event(_ state: WidgetState?, at date: Date, calendar: Calendar = .current) -> (time: String, title: String)? {
        guard let event = state?.nextEvent, let time = eventTime(event, at: date, calendar: calendar) else { return nil }
        return (time, event.title)
    }

    /// 出す予定が無いときの文。12時間以内に予定が無ければ「予定なし」。
    /// 中身が無い・予定が終わった（その次の予定はまだ届いていない）ときは「—」
    static func noEventText(_ state: WidgetState?) -> String {
        guard let state, state.nextEvent == nil else { return unknown }
        return noEvent
    }

    // MARK: - 様子

    /// 最後に文字にした時刻（「文字にした 10:32」）。分からなければ nil
    static func processed(_ state: WidgetState?, at now: Date, calendar: Calendar = .current) -> String? {
        guard let date = state?.lastProcessed else { return nil }
        return "文字にした " + clock(date, now: now, calendar: calendar)
    }

    /// 家の PC とつながるか。PC を使っていなければ nil
    static func pc(_ state: WidgetState?, long: Bool = false) -> String? {
        guard let ok = state?.pcOK else { return nil }
        if long { return ok ? "家の PC につながります" : "家の PC につながりません" }
        return ok ? "PC ○" : "PC ×"
    }
}

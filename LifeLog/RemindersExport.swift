import EventKit
import Foundation

/// 頼まれごとを iPhone のリマインダーに送る（2026-11-06）。選んだものだけ、本人が押したときに送る。
/// 前に送ったもの（reminderID がある）は、同じ項目を書き直す。
enum RemindersExport {
    private static let store = EKEventStore()

    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { "リマインダーが許可されていません（設定 → プライバシー → リマインダー）" }
    }

    static func send(_ item: TaskBook.Item) async throws -> String {
        guard try await store.requestFullAccessToReminders() else { throw Failure.denied }
        let reminder = item.reminderID.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
            ?? EKReminder(eventStore: store)
        if reminder.calendar == nil { reminder.calendar = store.defaultCalendarForNewReminders() }
        reminder.title = item.what
        var notes: [String] = []
        if let from = item.from { notes.append(item.kindOrDefault.partyLabel + ": " + from) }
        if let quote = item.quote, !quote.isEmpty { notes.append("もとの言葉: " + quote) }
        if let memo = item.memo { notes.append(memo) }
        notes.append("LifeLog から")
        reminder.notes = notes.joined(separator: "\n")
        reminder.priority = item.urgent == true ? 1 : 0
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        if let due = item.due {
            let parts: Set<Calendar.Component> = item.dueTime == nil ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: item.dueMoment ?? due)
            if item.dueTime != nil, let moment = item.dueMoment { reminder.addAlarm(EKAlarm(absoluteDate: moment)) }
        } else {
            reminder.dueDateComponents = nil
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
}

import Foundation
import UserNotifications

/// 会う前のおさらい。カレンダーの予定の10分前に、その予定で会う名前のある人と、前回話した会話の見出しと要点を通知する。
/// 会う人は、予定の参加者の名前か、予定名に入っている名前（「田中さんと面談」）で決める。前に話した会話が無い人は出さない。
/// 通知は iOS に先に頼んでおく（アプリが閉じていても時刻に出る）。頼み直すたびに、前に頼んだ分は取り消して作り直す。
extension Pipeline {
    static let meetingBriefKey = "meetingBrief"
    /// 予定のどれだけ前に出すか
    private static let briefLead: TimeInterval = 10 * 60
    /// 先に頼んでおく範囲
    private static let briefWindow: TimeInterval = 24 * 3600
    private static let briefPrefix = "brief-"
    /// 頼み直すのは多くても10分に1回
    private static var briefsChecked = Date.distantPast

    static var meetingBriefOn: Bool { UserDefaults.standard.object(forKey: meetingBriefKey) as? Bool ?? true }

    private static let briefDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        return f
    }()

    func scheduleMeetingBriefs(force: Bool = false) async {
        guard force || Date.now.timeIntervalSince(Self.briefsChecked) >= 10 * 60 else { return }
        Self.briefsChecked = .now
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.briefPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard Self.meetingBriefOn else { return }

        let now = Date.now
        let events = calendar.dayEvents(from: now, to: now.addingTimeInterval(Self.briefWindow))
            .filter { $0.start.addingTimeInterval(-Self.briefLead) > now.addingTimeInterval(30) }
        guard !events.isEmpty else { return }
        let named = people.filter { $0.isNamed && !$0.isSelf && $0.hidden != true }
        var meetings: [(event: CalendarLink.Event, names: [String])] = []
        for event in events {
            let names = named.map(\.displayName).filter { name in
                let key = Self.nameKey(name)
                return event.attendees.contains { Self.sameName($0, name) }
                    || (key.count >= 2 && event.title.contains(key))
            }
            if !names.isEmpty { meetings.append((event, names)) }
        }
        guard !meetings.isEmpty else { return }

        // 人ごとの、いちばん新しい閉じた会話（新しい日から探す）
        var wanted = Set(meetings.flatMap(\.names))
        var last: [String: ConversationLog.Conversation] = [:]
        search: for day in recordedDays() {
            for c in conversations(on: day).reversed() where c.closed && c.media == nil && c.start < now {
                for name in c.people where wanted.contains(name) {
                    last[name] = c
                    wanted.remove(name)
                }
                if wanted.isEmpty { break search }
            }
        }

        for (event, names) in meetings.prefix(10) {
            var parts: [String] = []
            for name in names {
                guard let c = last[name] else { continue }
                var text = "\(name)：前回 \(Self.briefDate.string(from: c.start))"
                if let title = c.title, !title.isEmpty { text += "「\(title)」" }
                for point in c.points.prefix(3) { text += "\n・" + point }
                parts.append(text)
            }
            guard !parts.isEmpty else { continue }
            let content = UNMutableNotificationContent()
            content.title = "まもなく " + (event.title.isEmpty ? "予定" : event.title)
            content.body = parts.joined(separator: "\n")
            content.sound = .default
            let wait = event.start.addingTimeInterval(-Self.briefLead).timeIntervalSince(now)
            let id = Self.briefPrefix + "\(Int(event.start.timeIntervalSince1970))-" + event.title
            try? await center.add(UNNotificationRequest(
                identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
        }
    }
}

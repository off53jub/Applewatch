import Foundation
import UserNotifications

/// 会う前のおさらい。カレンダーの予定の30分前（設定で変えられる。MeetingBriefPlus.swift）に、その予定で会う名前のある人と、前回話した会話・最近の話題・残っている約束を通知する。
/// 会う人は、予定の参加者の名前か、予定名に入っている名前（「田中さんと面談」）で決める。前に話した会話が無い人は出さない。
/// 通知は iOS に先に頼んでおく（アプリが閉じていても時刻に出る）。頼み直すたびに、前に頼んだ分は取り消して作り直す。
extension Pipeline {
    static let meetingBriefKey = "meetingBrief"
    /// 予定のどれだけ前に出すか（初めは30分前。2026-11-12 に10分前から変えた）
    private static var briefLead: TimeInterval { TimeInterval(meetingBriefLeadMinutes) * 60 }
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
            // 知らせる時刻を過ぎていても、予定の5分前までなら、すぐ（少し後に）知らせる
            .filter { $0.start > now.addingTimeInterval(5 * 60) }
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
        // 最近話した会話は、人ごとに3つまで（話題の行に使う）。探すのは90日前まで
        var wanted = Set(meetings.flatMap(\.names))
        var recent: [String: [ConversationLog.Conversation]] = [:]
        search: for day in recordedDays().prefix(90) {
            for c in conversations(on: day).reversed() where c.closed && c.media == nil && c.start < now {
                for name in c.people where wanted.contains(name) {
                    recent[name, default: []].append(c)
                    if (recent[name]?.count ?? 0) >= 3 { wanted.remove(name) }
                }
                if wanted.isEmpty { break search }
            }
        }
        let home = mothership.open(.all)

        for (event, names) in meetings.prefix(10) {
            var parts: [String] = []
            for name in names {
                var text = "\(name)："
                var has = false
                let convs = recent[name] ?? []
                if let c = convs.first {
                    text += "前回 \(Self.briefDate.string(from: c.start))"
                    if let stats = SpeakStats.of(c), stats.selfLines > 0, let share = stats.share {
                        text += "（あなたが話した割合 \(Int((share * 100).rounded()))%）"
                    }
                    // 知らせは短くする（要点は前回の1つだけ。話題は直近3つの見出し）
                    if let point = c.points.first { text += "\n・" + Self.briefClip(point, 40) }
                    has = true
                }
                if let topics = Self.topicsLine(titles: convs.map(\.title)) {
                    text += "\n" + topics
                    has = true
                }
                // その人との、残っている頼まれごと・約束・返事待ち（2026-11-12）と、仕事のまとめのいちばん新しい行（2026-11-10）
                for line in Self.promiseLines(name: name, tasks: tasks.open, home: home) {
                    text += "\n" + line
                    has = true
                }
                let prep = Self.meetingPrep(name: name, tasks: tasks.open, digests: workDigests.sorted)
                if let line = prep.lines.first {
                    text += "\n仕事のまとめ（\(Pipeline.workDigestDayTitle(line.day))）: " + Self.briefClip(line.text, 40)
                    has = true
                }
                guard has else { continue }
                parts.append(text)
            }
            guard !parts.isEmpty else { continue }
            let content = UNMutableNotificationContent()
            content.title = "まもなく " + (event.title.isEmpty ? "予定" : event.title)
            content.body = parts.joined(separator: "\n")
            content.sound = .default
            let wait = max(10, event.start.addingTimeInterval(-Self.briefLead).timeIntervalSince(now))
            let id = Self.briefPrefix + "\(Int(event.start.timeIntervalSince1970))-" + event.title
            try? await center.add(UNNotificationRequest(
                identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
        }
    }
}

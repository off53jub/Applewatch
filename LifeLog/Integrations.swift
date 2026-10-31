import CoreMotion
import EventKit
import Foundation
import Observation

/// カレンダーの予定。会話の見出し、聞き取りのヒント（予定名・参加者）、職場かどうかの判断に使う。
@MainActor
@Observable
final class CalendarLink {
    var enabled = UserDefaults.standard.bool(forKey: "calendarOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "calendarOn") }
    }
    /// 職場の予定が入っているカレンダー（ここの予定の時間は職場とみなす）
    var workCalendars = Set(UserDefaults.standard.stringArray(forKey: "workCalendars") ?? []) {
        didSet { UserDefaults.standard.set(Array(workCalendars), forKey: "workCalendars") }
    }
    private(set) var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    struct Event {
        let title: String
        let attendees: [String]
        let isWork: Bool
    }

    @ObservationIgnored private let store = EKEventStore()

    func requestAccess() async {
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
        if authorized { enabled = true }
    }

    var calendars: [EKCalendar] {
        guard authorized else { return [] }
        return store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    /// その時間に重なる予定（終日の予定は除く）。いちばん長く重なるものから。
    func events(from start: Date, to end: Date) -> [Event] {
        guard enabled, authorized else { return [] }
        let end = max(end, start.addingTimeInterval(60))
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { overlap($0, start, end) > overlap($1, start, end) }
            .map { e in
                let attendees = (e.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { p -> String? in
                    guard let name = p.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") else { return nil }
                    return name
                }
                return Event(title: e.title ?? "", attendees: attendees,
                             isWork: workCalendars.contains(e.calendar.calendarIdentifier))
            }
    }

    func event(at time: Date) -> Event? { events(from: time, to: time).first }

    /// その時間に職場の予定があれば職場（職場のカレンダーを選んでいなければ nil）
    func context(at time: Date) -> SpeakerLabeler.Context? {
        guard !workCalendars.isEmpty, let event = event(at: time) else { return nil }
        return event.isWork ? .work : nil
    }

    private func overlap(_ e: EKEvent, _ start: Date, _ end: Date) -> TimeInterval {
        min(e.endDate, end).timeIntervalSince(max(e.startDate, start))
    }
}

/// 移動の様子（歩いている・乗り物・止まっている）。iPhone の動きから分かる。
@MainActor
@Observable
final class MotionLink {
    enum Movement: String {
        case stationary, walking, running, cycling, vehicle

        /// 見出しに添える言葉（止まっているときは何も付けない）
        var label: String? {
            switch self {
            case .stationary: nil
            case .walking: "歩きながら"
            case .running: "走りながら"
            case .cycling: "自転車で"
            case .vehicle: "電車・車で"
            }
        }
    }

    var enabled = UserDefaults.standard.bool(forKey: "motionOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "motionOn") }
    }
    var available: Bool { CMMotionActivityManager.isActivityAvailable() }
    private(set) var authorized = CMMotionActivityManager.authorizationStatus() == .authorized

    @ObservationIgnored private let manager = CMMotionActivityManager()

    /// 許可を聞く（直近の動きを1回読むと聞かれる）
    func requestAccess() async {
        _ = await activities(from: .now.addingTimeInterval(-60), to: .now)
        authorized = CMMotionActivityManager.authorizationStatus() == .authorized
        if authorized { enabled = true }
    }

    /// その時間でいちばん長かった動き。分からなければ nil。
    func movement(from start: Date, to end: Date) async -> Movement? {
        guard enabled, available else { return nil }
        let shares = await shares(from: start, to: end)
        return shares.max { $0.value < $1.value }.map(\.key)
    }

    /// その時間のうち、止まっていた割合（0〜1）。分からなければ nil。
    func stillness(from start: Date, to end: Date) async -> Double? {
        guard enabled, available else { return nil }
        let shares = await shares(from: start, to: end)
        let total = shares.values.reduce(0, +)
        guard total > 0 else { return nil }
        return (shares[.stationary] ?? 0) / total
    }

    private func shares(from start: Date, to end: Date) async -> [Movement: TimeInterval] {
        let list = await activities(from: start.addingTimeInterval(-600), to: end)
        var result: [Movement: TimeInterval] = [:]
        for (i, a) in list.enumerated() where a.confidence != .low {
            let from = max(a.startDate, start)
            let to = min(i + 1 < list.count ? list[i + 1].startDate : end, end)
            guard to > from else { continue }
            let kind: Movement? = a.automotive ? .vehicle : a.cycling ? .cycling : a.running ? .running
                : a.walking ? .walking : a.stationary ? .stationary : nil
            if let kind { result[kind, default: 0] += to.timeIntervalSince(from) }
        }
        return result
    }

    private func activities(from start: Date, to end: Date) async -> [CMMotionActivity] {
        guard available else { return [] }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { list, _ in
                continuation.resume(returning: list ?? [])
            }
        }
    }
}

/// 寝ているあいだ。寝る時間帯に iPhone がずっと止まっていたら、寝ているとみなす。
/// （ヘルスケアの睡眠は、アプリの署名に特別な許可が要り、Sideloadly では入れられないため使わない）
@MainActor
@Observable
final class SleepGuess {
    var enabled = UserDefaults.standard.bool(forKey: "sleepOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "sleepOn") }
    }
    /// 寝る時間帯（時）。例: 0〜7 なら 0:00〜6:59
    var startHour = UserDefaults.standard.object(forKey: "sleepStart") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(startHour, forKey: "sleepStart") }
    }
    var endHour = UserDefaults.standard.object(forKey: "sleepEnd") as? Int ?? 7 {
        didSet { UserDefaults.standard.set(endHour, forKey: "sleepEnd") }
    }

    func inWindow(_ time: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: time)
        return startHour <= endHour ? (startHour..<endHour).contains(hour)
            : hour >= startHour || hour < endHour
    }

    /// 寝ていたか。時間帯の中で、動きが分かるときはほとんど止まっていたこと、分からないときは時間帯だけで決める。
    func isAsleep(from start: Date, to end: Date, motion: MotionLink) async -> Bool {
        guard enabled, inWindow(start) else { return false }
        guard let still = await motion.stillness(from: start, to: end) else { return true }
        return still >= 0.9
    }
}

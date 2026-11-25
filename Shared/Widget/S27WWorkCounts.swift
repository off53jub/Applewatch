import Foundation

/// s27 の 場6（2026-11-25）: 仕事のウィジェットに出す数だけ（守1。案件名・人名・文は入れない）。
/// iPhone のアプリ（S27WBook）が App Group に書き、ウィジェット（LifeLogWidgets/S27WWorkWidget.swift）が読む。
/// どの項目も省けるようにしておく（足すだけ）。
struct S27WWorkCounts: Codable, Equatable, Sendable {
    /// 今日の自分の宿題の数
    var homeworkToday: Int?
    /// 開いている自分の案件の項目の数
    var openMine: Int?
    /// 次の会議の始まり（題は入れない）
    var nextMeeting: Date?
    var updated: Date = .now

    /// ウィジェットの種類の名前
    static let kind = "com.off53jub.lifelog.work"
    static let key = "s27wWorkCounts"
    /// 古すぎる数は出さない（仮 36 時間。家の PC とつながらない日が続いたとき）
    static let staleAfter: TimeInterval = 36 * 3600

    static func read(defaults: UserDefaults? = UserDefaults(suiteName: WidgetState.suiteName)) -> S27WWorkCounts? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(S27WWorkCounts.self, from: data)
    }

    /// 書いた（前と違った）ら true
    @discardableResult
    func write(defaults: UserDefaults? = UserDefaults(suiteName: WidgetState.suiteName)) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return false }
        if let old = defaults.data(forKey: Self.key), let before = try? JSONDecoder().decode(S27WWorkCounts.self, from: old),
           before.homeworkToday == homeworkToday, before.openMine == openMine, before.nextMeeting == nextMeeting,
           updated.timeIntervalSince(before.updated) < 3600 {
            return false
        }
        defaults.set(data, forKey: Self.key)
        return true
    }

    /// 消す（家の PC が仕事の口を持たなくなったとき）
    static func clear(defaults: UserDefaults? = UserDefaults(suiteName: WidgetState.suiteName)) {
        defaults?.removeObject(forKey: key)
    }

    func isStale(now: Date = .now) -> Bool { now.timeIntervalSince(updated) > Self.staleAfter }

    /// 「宿題 3・開いている 12」
    var line: String {
        "宿題 \(homeworkToday ?? 0)・開いている \(openMine ?? 0)"
    }

    /// 次の会議がまだ先なら、その時刻（過ぎていれば nil）
    func upcoming(now: Date = .now) -> Date? {
        guard let nextMeeting, nextMeeting > now else { return nil }
        return nextMeeting
    }
}

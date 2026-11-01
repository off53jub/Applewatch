import ActivityKit
import Foundation

/// アプリを開かずに（アクションボタンなどで）録音を始めたときに出す Live Activity。
/// iOS の決まりで、こうして始めた録音は Live Activity を出しているあいだだけ続けられる。
/// Live Activity は8時間で iOS に終わらせられるので、録音中にアプリを開いたら、古ければ出し直す。
@MainActor
enum RecordingActivity {
    private static let createdKey = "recordingActivityCreated"
    /// これより古ければ、アプリを開いたときに出し直す
    private static let renewAfter: TimeInterval = 4 * 3600

    static var isShowing: Bool { !Activity<RecordingActivityAttributes>.activities.isEmpty }

    /// 出す（出ていれば出し直す）。started は録音を始めた時刻。出せなければ false。
    @discardableResult
    static func start(started: Date = .now) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        end()
        let content = ActivityContent(state: RecordingActivityAttributes.ContentState(started: started), staleDate: nil)
        do {
            _ = try Activity.request(attributes: RecordingActivityAttributes(), content: content, pushType: nil)
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: createdKey)
            return true
        } catch {
            return false
        }
    }

    static func end() {
        for activity in Activity<RecordingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// 録音中にアプリを開いたとき：出ていない、または古ければ出し直す（録音を始めた時刻はそのまま）
    static func renewIfNeeded(started: Date) {
        let created = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: createdKey))
        guard !isShowing || created.timeIntervalSinceNow < -renewAfter else { return }
        start(started: started)
    }
}

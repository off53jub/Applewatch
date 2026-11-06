import Foundation

/// iPhone・時計のアプリが書き、ウィジェット（文字盤・ロック画面・ホーム画面）が読む中身（2026-11-07）。
/// App Group（group.com.off53jub.lifelog）の UserDefaults に1つだけ置く。iPhone と時計は別の入れ物なので、それぞれで書く。
/// 項目は足すだけにする（古いウィジェットが読めなくならないよう、どれも省けるようにしておく）。
struct WidgetState: Codable, Equatable {
    struct Event: Codable, Equatable {
        var title: String
        var start: Date
        var end: Date?
    }

    var updated: Date = .now
    /// iPhone で録音しているか
    var phoneRecording: Bool?
    /// 時計で録音しているか
    var watchRecording: Bool?
    /// 今日までの頼まれごとの数と、そのうち期限を過ぎた数
    var tasksDue: Int?
    var tasksOverdue: Int?
    /// 次の予定
    var nextEvent: Event?
    /// 最後に文字にした時刻
    var lastProcessed: Date?
    /// 家の PC とつながるか（使っていなければ nil）
    var pcOK: Bool?
    /// 時計から iPhone に送っていない録音の数（時計だけ）
    var watchUnsent: Int?

    static let suiteName = "group.com.off53jub.lifelog"
    static let key = "widgetState"

    /// App Group が使えない入れ方（署名なしの IPA など）では nil
    static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func load() -> WidgetState? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetState.self, from: data)
    }

    /// 変わったときだけ書く。書いたら true
    @discardableResult
    func save() -> Bool {
        guard let defaults = Self.defaults else { return false }
        var old = Self.load()
        old?.updated = updated
        guard old != self, let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}

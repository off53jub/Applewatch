import Foundation

/// ウィジェットのボタンで答えた確かめ待ち（2026-11-22。s22 の 楽14）。ウィジェットが App Group に書き、
/// アプリが次に動いたとき（5 分ごとの見回り・前に出たとき）に読んで、母艦へ送る列に移す。App Group が使えない入れ方では何もしない
enum S22WidgetAnswers {
    static let key = "s22.widgetAnswers"

    struct Entry: Codable, Equatable {
        var id: String
        var value: String
        var at: Double
    }

    static func load(from defaults: UserDefaults? = WidgetState.defaults) -> [Entry] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// 1 つ足す（同じ問いは新しい答えだけ残す。50 個まで）
    static func adding(_ list: [Entry], id: String, value: String, at: Double) -> [Entry] {
        Array((list.filter { $0.id != id } + [Entry(id: id, value: value, at: at)]).suffix(50))
    }

    static func add(id: String, value: String, now: Date = .now, defaults: UserDefaults? = WidgetState.defaults) {
        guard let defaults else { return }
        let next = adding(load(from: defaults), id: id, value: value, at: now.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
        // 答えた問いは、アプリが次の問いを書くまで消しておく
        if var state = WidgetState.load(from: defaults), state.reviewAskID == id {
            state.reviewAskID = nil
            state.reviewAskQuestion = nil
            state.save(to: defaults)
        }
    }

    /// まだアプリが読んでいない答えの id
    static func pendingIDs() -> [String] { load().map(\.id) }

    /// 読んで消す
    static func take(defaults: UserDefaults? = WidgetState.defaults) -> [Entry] {
        let list = load(from: defaults)
        if !list.isEmpty { defaults?.removeObject(forKey: key) }
        return list
    }
}

import Foundation
import Observation
import SwiftUI

/// 1日のまとめの「やること」を、アプリの中で「こんなのあったけど、どう？」と出す。
/// いらなければすぐ消し、考えたいものは残す。Apple のリマインダーには書かない。
/// 自分の判断は `suggestions.json` に端末ごとに持つ（同期はしない）。
@MainActor
@Observable
final class SuggestionBox {
    struct Item: Codable, Identifiable {
        let id: String
        let day: String
        let text: String
        /// 残すと決めた
        var kept: Bool? = nil
        /// 消した（同じものをまた出さないよう、印だけ残す）
        var removed: Bool? = nil
    }

    /// 候補にする日数（古いやることは今さら出さない）
    static let recentDays = 14

    private(set) var items: [Item] = []

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("suggestions.json")

    /// まだ決めていないもの（新しい日から）
    var waiting: [Item] { items.filter { $0.kept != true && $0.removed != true }.sorted { $0.day > $1.day } }
    /// 残しているもの（新しい日から）
    var kept: [Item] { items.filter { $0.kept == true && $0.removed != true }.sorted { $0.day > $1.day } }

    init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        } else {
            // 読めないファイルは上書きせず、脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("suggestions-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    /// 日ごとのやることから、まだ出していないものを足す。足したものを返す。
    func collect(_ days: [(day: String, todos: [String])]) -> [Item] {
        var seen = Set(items.map(\.text))
        var added: [Item] = []
        for (day, todos) in days {
            for todo in todos {
                let text = todo.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, seen.insert(text).inserted else { continue }
                added.append(Item(id: day + "|" + text, day: day, text: text))
            }
        }
        guard !added.isEmpty else { return [] }
        items += added
        save()
        return added
    }

    func keep(_ item: Item) { update(item) { $0.kept = true } }

    func remove(_ item: Item) { update(item) { $0.removed = true } }

    private func update(_ item: Item, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        change(&items[i])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

// MARK: - タスクにまとめる（2026-11-09）

extension Pipeline {
    /// 1日のまとめの「やること」（まだ判断していない・残しているもの）を、タスクの確かめ待ちに入れ、
    /// 「こんなのあったけど、どう？」からは外す。同じ文は SuggestionBox が覚えているので、二度は入らない。
    /// 休みの日に出たものは仕事以外、それ以外は印を付けない（印の無いものは仕事とみなす。前からの決まり）
    func addSummaryCandidates() {
        let box = suggestions
        let items = box.waiting + box.kept
        guard !items.isEmpty else { return }
        // 期限の手がかり（日付・曜日・「明日」「〜まで」など）のあるものだけ入れる（2026-11-10。それまで70件のうち残したのは1件だった）。
        // 入れなかったものも、1日のまとめのドキュメントには残っている
        let new = items.filter { TaskBook.hasDueCue($0.text) }.map { s -> TaskBook.Item in
            let start = TaskBook.dayFormat.date(from: s.day)
            return TaskBook.Item(what: s.text, said: start.map { $0.addingTimeInterval(21 * 3600) } ?? .now, day: s.day,
                                 quote: "1日のまとめ（\(s.day)）のやること", source: .summary, state: .candidate,
                                 work: start.map { isDayOff($0) ? false : nil } ?? nil)
        }
        tasks.add(new)
        for s in items { box.remove(s) }
        tasksChanged()
    }
}

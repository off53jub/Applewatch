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

/// 候補1つ。「残す」「消す」をその場で押せる。
struct SuggestionRow: View {
    @Environment(Pipeline.self) private var pipeline
    let item: SuggestionBox.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.text)
            HStack(spacing: 20) {
                if item.kept != true {
                    Button("残す", systemImage: "bookmark") { pipeline.suggestions.keep(item) }
                }
                Button(item.kept == true ? "もういい" : "消す", systemImage: "xmark", role: .destructive) {
                    pipeline.suggestions.remove(item)
                }
                Spacer(minLength: 0)
                NavigationLink(item.day) { DayView(day: item.day) }
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

/// 候補と、残しているものの一覧。
struct SuggestionsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let box = pipeline.suggestions
        List {
            if !box.waiting.isEmpty {
                Section {
                    ForEach(box.waiting) { SuggestionRow(item: $0) }
                } header: {
                    Text("こんなのあったけど、どう？")
                } footer: {
                    Text("1日のまとめの「やること」から出しています。いらなければ消してください。同じものはもう出しません。")
                }
            }
            if !box.kept.isEmpty {
                Section("残しているもの") {
                    ForEach(box.kept) { SuggestionRow(item: $0) }
                }
            }
        }
        .overlay {
            if box.waiting.isEmpty && box.kept.isEmpty {
                ContentUnavailableView("今はありません", systemImage: "tray",
                                       description: Text("1日のまとめに「やること」が出ると、ここに届きます。"))
            }
        }
        .navigationTitle("こんなのあった")
    }
}

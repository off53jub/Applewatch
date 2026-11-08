import Foundation
import Observation
import SwiftUI

/// 母艦（家の PC の D:\Lifelog）のやること（2026-11-09）。
/// やることが「アプリのタスク」「母艦の TODO」「Teams」の3か所に分かれていて、どこを見ればよいか分からなかったので、
/// アプリのタスクを見る場所に決め、母艦の TODO もここに出す。母艦の TODO.md を書くのは母艦だけで、
/// アプリは家の PC の GET /todo で読み、「済み」は POST /todo/done で知らせる（母艦が15分ごとに TODO.md に反映する）。
/// 読んだものは `mothership-todo.json`（端末ごと・同期しない・新しいファイル）に覚え、家の PC につながらないときも出す。
struct MothershipTodo: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    var project: String? = nil
    var work: Bool? = nil
    var added: String? = nil
    var due: String? = nil
}

struct MothershipExport: Codable, Equatable, Sendable {
    struct Three: Codable, Equatable, Sendable {
        let id: String
        let text: String
        var why: String? = nil
    }

    var generatedAt: String? = nil
    var todayThree: [Three] = []
    var items: [MothershipTodo] = []

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at", todayThree = "today_three", items
    }

    init(generatedAt: String? = nil, todayThree: [Three] = [], items: [MothershipTodo] = []) {
        self.generatedAt = generatedAt
        self.todayThree = todayThree
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
        todayThree = (try? c.decodeIfPresent([Three].self, forKey: .todayThree)) ?? []
        items = try c.decode([MothershipTodo].self, forKey: .items)
    }

    /// GET /todo の答えを読む。母艦にまだ無い（available が false）・形が違うときは nil
    nonisolated static func parse(_ data: Data) -> MothershipExport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["available"] as? Bool != false,
              let export = try? JSONDecoder().decode(MothershipExport.self, from: data) else { return nil }
        // 空の文・おかしな id は出さない
        var out = export
        out.items = export.items.filter { Self.validID($0.id) && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        out.todayThree = export.todayThree.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return out
    }

    nonisolated static func validID(_ id: String) -> Bool {
        id.count == 12 && id.allSatisfy { $0.isHexDigit }
    }

    /// 期限の「yyyy-MM-dd」→ その日の0時
    nonisolated static func dueDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return TaskBook.dueDate(text)
    }
}

@MainActor
@Observable
final class MothershipBook {
    struct Saved: Codable {
        var export: MothershipExport?
        var fetchedAt: Date?
        /// アプリで済みにした id と時刻（母艦の一覧から消えるまで出さない。7日で忘れる）
        var done: [String: Date] = [:]
        /// まだ家の PC に知らせていない済み（id → 文）
        var pending: [String: String] = [:]
    }

    private(set) var export: MothershipExport?
    private(set) var fetchedAt: Date?
    private(set) var done: [String: Date] = [:]
    private var pending: [String: String] = [:]
    /// 読み込めたか（読む前には保存しない）
    private var loaded = false
    private(set) var lastError: String?
    private var fetching = false

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("mothership-todo.json")
    /// 母艦は15分ごとに作り直すので、それより短くは聞かない
    static let refreshEvery: TimeInterval = 10 * 60

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else {
            loaded = true
            return
        }
        if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            export = saved.export
            fetchedAt = saved.fetchedAt
            done = saved.done
            pending = saved.pending
            loaded = true
        } else {
            // 読めないファイルは上書きせず脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("mothership-todo-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
            loaded = true
        }
    }

    private func save() {
        guard loaded else { return }
        let saved = Saved(export: export, fetchedAt: fetchedAt, done: done, pending: pending)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// まだ済んでいないもの（scope で仕事・仕事以外に絞る。work の無いものは仕事とみなさない）
    func open(_ scope: TaskBook.Scope) -> [MothershipTodo] {
        let items = (export?.items ?? []).filter { done[$0.id] == nil }
        let filtered: [MothershipTodo]
        switch scope {
        case .all: filtered = items
        case .work: filtered = items.filter { $0.work == true }
        case .life: filtered = items.filter { $0.work != true }
        }
        return Self.sorted(filtered)
    }

    /// 母艦が選んだ「今日の三つ」（済みにしたものは除く）
    var todayThree: [MothershipExport.Three] {
        (export?.todayThree ?? []).filter { done[$0.id] == nil }
    }

    /// 期限のあるものを先に（近い順）、そのあとは足された日が新しい順
    nonisolated static func sorted(_ items: [MothershipTodo]) -> [MothershipTodo] {
        items.sorted { a, b in
            switch (MothershipExport.dueDate(a.due), MothershipExport.dueDate(b.due)) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.added ?? "") > (b.added ?? "")
            }
        }
    }

    /// 家の PC から読み直す（force でなければ10分に1回まで）。母艦の一覧から消えた済みは忘れる
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.features.contains("todo") else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.refreshEvery, pending.isEmpty { return }
        fetching = true
        defer { fetching = false }
        await flush(pc)
        do {
            let data = try await pc.mothershipTodo()
            guard let parsed = MothershipExport.parse(data) else {
                lastError = "母艦のやることがまだありません"
                return
            }
            export = parsed
            fetchedAt = .now
            lastError = nil
            let ids = Set(parsed.items.map(\.id))
            done = done.filter { ids.contains($0.key) && Date.now.timeIntervalSince($0.value) < 7 * 86400 }
            save()
        } catch {
            lastError = "家の PC から読めませんでした"
        }
    }

    /// 済みにする（すぐ一覧から外し、家の PC に知らせる。届かなければ次に読むときにもう一度）
    func markDone(_ item: MothershipTodo, pc: HomePC) async {
        done[item.id] = .now
        pending[item.id] = item.text
        save()
        await flush(pc)
    }

    /// 済みを取り消す（まだ家の PC に知らせていないものだけ）
    func undo(_ id: String) {
        guard pending[id] != nil else { return }
        pending[id] = nil
        done[id] = nil
        save()
    }

    private func flush(_ pc: HomePC) async {
        guard !pending.isEmpty, pc.features.contains("todo") else { return }
        for (id, text) in pending.sorted(by: { $0.key < $1.key }) {
            do {
                try await pc.mothershipDone(id: id, text: text)
                pending[id] = nil
            } catch {
                break
            }
        }
        save()
    }

    var hasPending: Bool { !pending.isEmpty }
}

// MARK: - 画面

/// タスクの「やる」の下の「母艦のやること」（期限のあるもの・新しいものから8件。続きは一覧で）
struct MothershipSection: View {
    @Environment(Pipeline.self) private var pipeline
    let scope: TaskBook.Scope

    var body: some View {
        let book = pipeline.mothership
        let items = book.open(scope)
        if book.export != nil {
            Section {
                ForEach(items.prefix(8)) { MothershipRow(item: $0) }
                if items.count > 8 {
                    NavigationLink("すべて見る（\(items.count) 件）") { MothershipListView(scope: scope) }
                }
                if items.isEmpty {
                    Text("ありません").foregroundStyle(.secondary)
                }
            } header: {
                Text("母艦のやること（\(items.count)）")
            } footer: {
                Text(footer(book))
            }
        }
    }

    private func footer(_ book: MothershipBook) -> String {
        var text = "家の PC の毎朝のまとめが会話・LINE・メモから拾ったものです。○で済みにすると、母艦の TODO も済みになります。"
        if let fetchedAt = book.fetchedAt {
            text += "\n" + fetchedAt.formatted(date: .abbreviated, time: .shortened) + " に家の PC から読みました。"
        }
        if let error = book.lastError { text += "（\(error)）" }
        return text
    }
}

struct MothershipRow: View {
    @Environment(Pipeline.self) private var pipeline
    let item: MothershipTodo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Task { await pipeline.mothership.markDone(item, pc: pipeline.homePC) }
            } label: {
                Image(systemName: "circle").font(.title3)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                let meta = [item.project.flatMap { $0.isEmpty ? nil : $0 }, item.due.map { "期限 " + $0 },
                            item.added.map { "足した日 " + $0 }].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: "・")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button("済み", systemImage: "checkmark") {
                Task { await pipeline.mothership.markDone(item, pc: pipeline.homePC) }
            }
            .tint(.green)
        }
    }
}

struct MothershipListView: View {
    @Environment(Pipeline.self) private var pipeline
    let scope: TaskBook.Scope

    var body: some View {
        let items = pipeline.mothership.open(scope)
        List {
            ForEach(items) { MothershipRow(item: $0) }
        }
        .navigationTitle("母艦のやること")
        .refreshable { await pipeline.mothership.refresh(pipeline.homePC, force: true) }
    }
}

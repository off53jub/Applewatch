import Foundation

/// 意味で探す（2026-11-07）。会話の行を家の PC の索引（Ollama の bge-m3 で意味を数にしたもの）に入れておき、
/// 言葉が一致しなくても、意味の近い発言を探せるようにする。索引は家の PC の中だけ（外のサービスには送らない）。
/// どの日をどこまで入れたかは `semantic-index.json`（日 → その日の記録の更新時刻と、入れた行の番号）に覚える。
extension Pipeline {
    private struct IndexState: Codable {
        var days: [String: Day] = [:]

        struct Day: Codable {
            var stamp: Double
            var ids: [String]
        }
    }

    private static let indexStateURL = URL.applicationSupportDirectory.appendingPathComponent("semantic-index.json")

    private static func loadIndexState() -> IndexState {
        guard let data = try? Data(contentsOf: indexStateURL),
              let state = try? JSONDecoder().decode(IndexState.self, from: data) else { return IndexState() }
        return state
    }

    private static func saveIndexState(_ state: IndexState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: indexStateURL, options: .atomic)
    }

    /// 行の番号（日と時刻のミリ秒）
    nonisolated static func semanticID(day: String, time: Date) -> String {
        day + "|" + String(Int((time.timeIntervalSince1970 * 1000).rounded()))
    }

    /// 索引に入れる行（閉じた会話の、テレビなどではない行）
    func indexItems(day: String) -> [HomePC.IndexItem] {
        var items: [HomePC.IndexItem] = []
        for c in conversations(on: day) where c.closed && c.media == nil {
            let conversation = Self.semanticID(day: day, time: c.start)
            let work = isWorkTime(c.start)
            for line in c.lines where line.media == nil && line.text.count >= 2 {
                items.append(HomePC.IndexItem(id: Self.semanticID(day: day, time: line.time), day: day,
                                              time: line.time.timeIntervalSince1970, speaker: line.speaker,
                                              text: line.text, work: work, conversation: conversation))
            }
        }
        return items
    }

    /// 変わった日だけ、家の PC の索引に入れ直す（直近 days 日。1回に limit 行まで）。消えた行は索引からも消す
    func refreshSemanticIndex(days: Int = 400, limit: Int = 4000) async {
        guard homePC.shouldTry else { return }
        _ = try? await homePC.hello()
        guard homePC.features.contains("semantic") else { return }
        var state = Self.loadIndexState()
        var sent = 0
        for day in recordedDays().prefix(days) where sent < limit {
            let stamp = dayModified(day)?.timeIntervalSince1970 ?? 0
            guard state.days[day]?.stamp != stamp else { continue }
            let items = indexItems(day: day)
            let ids = Set(items.map(\.id))
            let gone = (state.days[day]?.ids ?? []).filter { !ids.contains($0) }
            do {
                if !gone.isEmpty { try await homePC.forget(gone) }
                var start = 0
                while start < items.count {
                    let end = min(start + 500, items.count)
                    _ = try await homePC.index(Array(items[start..<end]))
                    start = end
                }
            } catch {
                break
            }
            sent += items.count
            state.days[day] = IndexState.Day(stamp: stamp, ids: Array(ids))
            Self.saveIndexState(state)
        }
        if sent > 0 { Tally.add("semantic.indexed", sent) }
    }

    /// 意味の近い行を探す（家の PC の索引。使えなければ空）
    func semanticSearch(_ query: String, from: String? = nil, to: String? = nil, k: Int = 40) async -> [Hit] {
        guard homePC.shouldTry, homePC.features.contains("semantic"),
              let found = try? await homePC.semanticSearch(query, k: k, from: from, to: to) else { return [] }
        var hits: [Hit] = []
        var loaded: [String: [ConversationLog.Conversation]] = [:]
        for item in found {
            let list = loaded[item.day] ?? conversations(on: item.day)
            loaded[item.day] = list
            let time = Date(timeIntervalSince1970: item.time)
            // 索引の行が今の記録にまだあるか確かめる（消した行は出さない）
            guard let c = list.first(where: { $0.lines.contains { abs($0.time.timeIntervalSince(time)) < 0.002 } }),
                  let line = c.lines.first(where: { abs($0.time.timeIntervalSince(time)) < 0.002 }),
                  !hits.contains(where: { $0.day == item.day && $0.line.time == line.time }) else { continue }
            hits.append(Hit(day: item.day, line: line, heading: c.title ?? ""))
        }
        return hits
    }
}

import Foundation

/// 人をまとめたときの記録（まとめを元に戻すため）。people.json とは別のファイル（merges.json）に置く。
/// まとめる前の人の記録（名前・声）と、まとめた先の名前に書き換えた行の時刻を残す。
@MainActor
enum MergeLog {
    struct Record: Codable, Identifiable {
        var id = UUID()
        let date: Date
        /// まとめる前の人（名前・声ごと）
        let source: SpeakerLabeler.Person
        /// まとめる前の名前（「人物123」など）
        let sourceName: String
        let target: String
        let targetName: String
        /// まとめた先の名前に書き換えた行の時刻
        let lines: [Date]
        /// 自動でまとめたか（会話が終わったときのまとめ直し）
        var automatic: Bool? = nil
        var undone: Bool? = nil
    }

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("merges.json")
    private static let limit = 500

    static func all() -> [Record] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [Record]) {
        guard let data = try? JSONEncoder().encode(Array(list.suffix(limit))) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func add(_ record: Record) {
        save(all() + [record])
    }

    /// その人にまとめた記録のうち、まだ戻していないもの（新しい順）
    static func records(into target: String) -> [Record] {
        all().filter { $0.target == target && $0.undone != true }.reversed()
    }

    static func markUndone(_ id: UUID) {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].undone = true
        save(list)
    }
}

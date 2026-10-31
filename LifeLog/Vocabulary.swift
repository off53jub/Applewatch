import Foundation
import Observation

/// 聞き取ってほしい言葉。「いつも」「職場だけ」「職場以外だけ」に分け、録った場所で使う組を切り替える。
/// 文字起こし（クラウド・端末内）のヒントと、誤変換を直す言語モデルに渡す。
@MainActor
@Observable
final class Vocabulary {
    enum Group: String, CaseIterable, Identifiable, Codable {
        case always, work, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .always: "いつも"
            case .work: "職場だけ"
            case .other: "職場以外だけ"
            }
        }
    }

    /// よく間違えられる書き方と、正しい書き方
    struct Fix: Codable, Hashable, Identifiable {
        var id = UUID()
        var wrong: String
        var right: String
        var group: Group
    }

    private struct Store: Codable {
        var words: [Group: [String]] = [:]
        var fixes: [Fix] = []
    }

    private var store: Store {
        didSet {
            guard let data = try? JSONEncoder().encode(store) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
    private static let key = "vocabulary"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        } else {
            // 前の「聞き取ってほしい言葉」は「いつも」に移す
            let legacy = (UserDefaults.standard.string(forKey: "keywords") ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            store = Store(words: [.always: legacy])
        }
    }

    func words(in group: Group) -> [String] { store.words[group] ?? [] }

    var fixes: [Fix] { store.fixes }

    func add(_ word: String, to group: Group) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !word.contains("<"), !word.contains(">"),
              !words(in: group).contains(word) else { return }
        store.words[group, default: []].append(word)
    }

    func remove(at offsets: IndexSet, from group: Group) {
        store.words[group]?.remove(atOffsets: offsets)
    }

    func addFix(wrong: String, right: String, group: Group) {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return }
        store.fixes.append(Fix(wrong: wrong, right: right, group: group))
    }

    func removeFixes(_ ids: Set<UUID>) {
        store.fixes.removeAll { ids.contains($0.id) }
    }

    /// その場で使う言葉。場所の決まった組を先に、次に「いつも」、最後に人の名前。
    func words(for context: SpeakerLabeler.Context, names: [String]) -> [String] {
        let specific = words(in: context == .work ? .work : .other)
        let corrected = fixes(for: context).map(\.right)
        var seen = Set<String>()
        return (specific + words(in: .always) + corrected + names).filter { seen.insert($0).inserted }
    }

    func fixes(for context: SpeakerLabeler.Context) -> [Fix] {
        store.fixes.filter { $0.group == .always || $0.group == (context == .work ? .work : .other) }
    }

    /// 場所が分からないときは時刻で決める。平日の8時〜19時は職場。
    static func context(byTime date: Date) -> SpeakerLabeler.Context {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        return (2...6).contains(weekday) && (8..<19).contains(hour) ? .work : .other
    }
}

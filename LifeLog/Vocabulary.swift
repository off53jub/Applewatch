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

    /// 話題ごとの言葉。合図の言葉（または話題の言葉そのもの）が聞こえたら、しばらくその話題の言葉も使う。
    struct Topic: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        /// 話題に入ったと分かる言葉
        var triggers: [String] = []
        /// その話題で使う専門用語など
        var words: [String] = []

        func isMentioned(in text: String) -> Bool {
            (triggers + words).contains { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }
        }
    }

    private struct Store: Codable {
        var words: [Group: [String]] = [:]
        var fixes: [Fix] = []
        var topics: [Topic] = []

        init(words: [Group: [String]] = [:]) { self.words = words }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            words = try c.decodeIfPresent([Group: [String]].self, forKey: .words) ?? [:]
            fixes = try c.decodeIfPresent([Fix].self, forKey: .fixes) ?? []
            topics = try c.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        }
    }

    /// 話題が出てから、これだけのあいだはその話題の言葉を使う
    static let topicSpan: TimeInterval = 30 * 60
    /// 最後にその話題が聞こえた時刻
    private var topicHeard: [UUID: Date] = [:]

    private var store: Store {
        didSet {
            guard let data = try? JSONEncoder().encode(store) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
    private static let key = "vocabulary"

    /// 端末間の同期用に、登録と削除の時刻を覚えておく（登録の中身とは別に保存し、今の保存の形は変えない）
    private var times: SyncTimes {
        didSet {
            guard let data = try? JSONEncoder().encode(times) else { return }
            UserDefaults.standard.set(data, forKey: Self.timesKey)
        }
    }
    private static let timesKey = "vocabularySync"

    private static func wordKey(_ word: String, _ group: Group) -> String { "w|\(group.rawValue)|\(word)" }
    private static func fixKey(_ id: UUID) -> String { "f|\(id.uuidString)" }
    private static func topicKey(_ id: UUID) -> String { "t|\(id.uuidString)" }

    init() {
        times = UserDefaults.standard.data(forKey: Self.timesKey)
            .flatMap { try? JSONDecoder().decode(SyncTimes.self, from: $0) } ?? SyncTimes()
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
        times.added[Self.wordKey(word, group)] = .now
    }

    func remove(at offsets: IndexSet, from group: Group) {
        let list = words(in: group)
        for i in offsets where list.indices.contains(i) { times.removed[Self.wordKey(list[i], group)] = .now }
        store.words[group]?.remove(atOffsets: offsets)
    }

    func addFix(wrong: String, right: String, group: Group) {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return }
        let fix = Fix(wrong: wrong, right: right, group: group)
        store.fixes.append(fix)
        times.added[Self.fixKey(fix.id)] = .now
    }

    func removeFixes(_ ids: Set<UUID>) {
        for id in ids { times.removed[Self.fixKey(id)] = .now }
        store.fixes.removeAll { ids.contains($0.id) }
    }

    /// その場で使う言葉。場所の決まった組を先に、次に「いつも」、最後に人の名前。
    func words(for context: SpeakerLabeler.Context, names: [String]) -> [String] {
        let specific = words(in: context == .work ? .work : .other)
        let corrected = fixes(for: context).map(\.right)
        var seen = Set<String>()
        return (specific + words(in: .always) + corrected + names).filter { seen.insert($0).inserted }
    }

    // MARK: - 話題

    var topics: [Topic] { store.topics }

    func addTopic(_ name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let topic = Topic(name: name)
        store.topics.append(topic)
        times.added[Self.topicKey(topic.id)] = .now
        return topic.id
    }

    func updateTopic(_ topic: Topic) {
        guard let i = store.topics.firstIndex(where: { $0.id == topic.id }) else { return }
        let clean = { (list: [String]) -> [String] in
            var seen = Set<String>()
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.contains("<") && !$0.contains(">") && seen.insert($0).inserted }
        }
        var topic = topic
        topic.triggers = clean(topic.triggers)
        topic.words = clean(topic.words)
        guard store.topics[i] != topic else { return }
        store.topics[i] = topic
        times.added[Self.topicKey(topic.id)] = .now
    }

    func removeTopics(_ ids: Set<UUID>) {
        for id in ids { times.removed[Self.topicKey(id)] = .now }
        store.topics.removeAll { ids.contains($0.id) }
    }

    // MARK: - 端末間の同期

    /// ほかの端末に渡す登録の中身と、登録・削除の時刻
    struct SyncCopy: Codable {
        var words: [String: [String]]
        var fixes: [Fix]
        var topics: [Topic]
        var times: SyncTimes
    }

    func syncCopy() -> SyncCopy {
        var words: [String: [String]] = [:]
        for group in Group.allCases { words[group.rawValue] = self.words(in: group) }
        return SyncCopy(words: words, fixes: store.fixes, topics: store.topics, times: times)
    }

    /// ほかの端末の登録を合わせる。言葉・直し・話題ごとに、後から登録したか消したかで決める（両方にあるものはそのまま）。
    /// 変わったら true。
    @discardableResult
    func mergeRemote(_ remote: SyncCopy) -> Bool {
        var next = store
        for group in Group.allCases {
            let local = words(in: group)
            let theirs = remote.words[group.rawValue] ?? []
            let keep = { (word: String, here: Bool, there: Bool) -> Bool in
                SyncTimes.decide(Self.wordKey(word, group), here: here, there: there, local: self.times, remote: remote.times).present
            }
            var list = local.filter { keep($0, true, theirs.contains($0)) }
            for word in theirs where !list.contains(word) && !local.contains(word) && keep(word, false, true) {
                list.append(word)
            }
            next.words[group] = list
        }
        next.fixes = Self.merged(store.fixes, remote.fixes, key: { Self.fixKey($0.id) }, local: times, remote: remote.times)
        next.topics = Self.merged(store.topics, remote.topics, key: { Self.topicKey($0.id) }, local: times, remote: remote.times)
        let mergedTimes = times.merged(with: remote.times)
        let changed = (try? JSONEncoder().encode(next)) != (try? JSONEncoder().encode(store))
        if changed { store = next }
        if mergedTimes != times { times = mergedTimes }
        return changed
    }

    private static func merged<T: Identifiable>(_ local: [T], _ remote: [T], key: (T) -> String,
                                                local lt: SyncTimes, remote rt: SyncTimes) -> [T] where T.ID == UUID {
        var result: [T] = []
        for item in local {
            let other = remote.first { $0.id == item.id }
            let d = SyncTimes.decide(key(item), here: true, there: other != nil, local: lt, remote: rt)
            guard d.present else { continue }
            result.append(d.fromRemote ? other ?? item : item)
        }
        for item in remote where !local.contains(where: { $0.id == item.id }) {
            if SyncTimes.decide(key(item), here: false, there: true, local: lt, remote: rt).present { result.append(item) }
        }
        return result
    }

    /// 聞こえた文から話題を見つけ、いま続いている話題（直近30分に出たもの）を返す。
    func activeTopics(hearing text: String, at time: Date) -> [Topic] {
        for topic in store.topics where topic.isMentioned(in: text) {
            topicHeard[topic.id] = max(topicHeard[topic.id] ?? .distantPast, time)
        }
        return store.topics.filter { topic in
            guard let heard = topicHeard[topic.id] else { return false }
            return abs(time.timeIntervalSince(heard)) <= Self.topicSpan
        }
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

/// 端末間の同期で、登録や削除のどちらが後かを決めるための時刻。
/// 時刻の無い登録（同期より前からあるもの）は、ずっと前に登録したものとみなす。
struct SyncTimes: Codable, Equatable {
    var added: [String: Date] = [:]
    var removed: [String: Date] = [:]

    func merged(with other: SyncTimes) -> SyncTimes {
        SyncTimes(added: added.merging(other.added) { max($0, $1) },
                  removed: removed.merging(other.removed) { max($0, $1) })
    }

    /// here / there は、こちら・向こうにいま登録されているか。present は合わせたあとに残すか、
    /// fromRemote は向こうの中身のほうが新しいか。
    static func decide(_ key: String, here: Bool, there: Bool,
                       local: SyncTimes, remote: SyncTimes) -> (present: Bool, fromRemote: Bool) {
        let addL: Date? = here ? local.added[key] ?? .distantPast : nil
        let addR: Date? = there ? remote.added[key] ?? .distantPast : nil
        let removedAt = [local.removed[key], remote.removed[key]].compactMap { $0 }.max()
        let latest = [addL, addR].compactMap { $0 }.max()
        guard let latest else { return (false, false) }
        let present = removedAt.map { latest > $0 } ?? true
        let fromRemote = addR.map { r in addL.map { r > $0 } ?? true } ?? false
        return (present, fromRemote)
    }
}

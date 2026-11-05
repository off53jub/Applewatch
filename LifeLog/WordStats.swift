import Foundation

/// 会話に出てきた言葉の数え上げ。会話の記録から作る別のファイル（people.json や言葉の登録には触らない）。
/// - 人ごとの言葉：名前を付けた人と話した会話によく出て、ほかではあまり出ない言葉。その人の声が聞こえているあいだ、
///   聞き取りと誤変換直しのヒントにする。
/// - 言葉の登録の候補：何日にもわたって出てくる固有名詞らしい言葉と、手で直した言葉。登録は画面で押したときだけ。
@MainActor
final class WordStats {
    private struct Store: Codable {
        /// 言葉ごとの、出てきた会話の数
        var total: [String: Int] = [:]
        /// 言葉ごとの、出てきた日の数と、最後に数えた日
        var days: [String: Int] = [:]
        var lastDay: [String: String] = [:]
        /// 人ごと・言葉ごとの、その人と話した会話のうち出てきた数
        var byPerson: [String: [String: Int]] = [:]
        /// 手で直した言葉（直したあとの書き方）と、その回数
        var edited: [String: Int] = [:]
        /// 数えた日の数
        var dayList: [String] = []
        /// ここまでに閉じた会話は数えた（会話の始まりの時刻）
        var countedUntil: Date = .distantPast
    }

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("wordstats.json")
    private static let dismissedKey = "dismissedWordCandidates"

    private var store: Store

    init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        } else {
            store = Store()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    // MARK: - 数える

    /// まだ一度も数えていない（はじめは、これまでの記録を全部数える）
    var isEmpty: Bool { store.countedUntil == .distantPast }

    /// まだ数えていない閉じた会話を数える。
    func count(days: [(day: String, conversations: [ConversationLog.Conversation])]) {
        var latest = store.countedUntil
        var changed = false
        for (day, conversations) in days {
            for c in conversations where c.closed && c.start > store.countedUntil && c.media == nil {
                latest = max(latest, c.start)
                add(c, day: day)
                changed = true
            }
        }
        guard changed else { return }
        store.countedUntil = latest
        prune()
        save()
    }

    private func add(_ c: ConversationLog.Conversation, day: String) {
        if store.dayList.last != day, !store.dayList.contains(day) { store.dayList.append(day) }
        let words = Self.words(in: c.lines.map(\.text).joined(separator: "\n"))
        for word in words {
            store.total[word, default: 0] += 1
            if store.lastDay[word] != day {
                store.lastDay[word] = day
                store.days[word, default: 0] += 1
            }
        }
        let people = c.people.filter { !$0.hasPrefix("人物") && !$0.hasPrefix("ほか") && $0 != SpeakerLabeler.selfName }
        for person in people {
            for word in words { store.byPerson[person, default: [:]][word, default: 0] += 1 }
        }
        // 手で直した行の、直したところ
        for line in c.lines where line.checked == true {
            guard let original = line.original,
                  let part = Pipeline.changedPart(from: original, to: line.text) else { continue }
            store.edited[part.right, default: 0] += 1
        }
    }

    /// 一度しか出ていない言葉が増えすぎたら捨てる
    private func prune() {
        if store.total.count > 15_000 {
            for (word, n) in store.total where n <= 1 {
                store.total[word] = nil
                store.days[word] = nil
                store.lastDay[word] = nil
            }
        }
        for (person, words) in store.byPerson where words.count > 800 {
            store.byPerson[person] = words.filter { $0.value > 1 }
        }
    }

    // MARK: - 人ごとの言葉

    /// その人たちと話すときによく出る言葉（ほかの会話ではあまり出ないもの）。人ごとに多い順で、合わせて limit 個まで。
    func hints(for people: [String], limit: Int = 10) -> [String] {
        var result: [String] = []
        for person in people {
            guard let words = store.byPerson[person] else { continue }
            let scored = words.compactMap { word, n -> (String, Double)? in
                let all = store.total[word] ?? n
                let share = Double(n) / Double(max(all, 1))
                guard n >= 2, share >= 0.5 else { return nil }
                return (word, Double(n) * share)
            }
            for (word, _) in scored.sorted(by: { $0.1 > $1.1 }).prefix(6) where !result.contains(word) {
                result.append(word)
            }
        }
        return Array(result.prefix(limit))
    }

    /// その人とよく話す言葉（人の画面に出す）
    func topWords(for person: String) -> [String] { hints(for: [person], limit: 6) }

    // MARK: - 言葉の登録の候補

    struct Candidate: Identifiable {
        let word: String
        /// 出てきた会話の数・日の数（手で直した言葉は、直した回数）
        let count: Int
        let days: Int
        /// 手で直した言葉か
        let edited: Bool
        var id: String { word }
    }

    /// 登録の候補。known は登録済みの言葉。手で直した言葉を先に、次によく出る固有名詞らしい言葉。
    func candidates(known: Set<String>) -> [Candidate] {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let skip = known.union(dismissed)
        let totalDays = store.dayList.count
        var result: [Candidate] = store.edited
            .filter { !skip.contains($0.key) && $0.key.count >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { Candidate(word: $0.key, count: $0.value, days: store.days[$0.key] ?? 0, edited: true) }
        let frequent = store.total.compactMap { word, n -> Candidate? in
            let days = store.days[word] ?? 0
            guard n >= 3, days >= 2, !skip.contains(word), Self.looksSpecial(word) else { return nil }
            // ほとんど毎日出る言葉は、ふつうの言葉とみなす
            if totalDays >= 4, Double(days) / Double(totalDays) > 0.5 { return nil }
            return Candidate(word: word, count: n, days: days, edited: false)
        }
        for c in frequent.sorted(by: { $0.count > $1.count }).prefix(30) where !result.contains(where: { $0.word == c.word }) {
            result.append(c)
        }
        return result
    }

    func dismiss(_ word: String) {
        var list = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        guard !list.contains(word) else { return }
        list.append(word)
        UserDefaults.standard.set(list, forKey: Self.dismissedKey)
    }

    // MARK: - 言葉を取り出す

    /// 文の中の、固有名詞や専門用語になりそうな言葉（漢字・カタカナ・英字の2文字以上）
    nonisolated static func words(in text: String) -> Set<String> {
        let string = text as CFString
        guard let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: CFStringGetLength(string)),
                                                      kCFStringTokenizerUnitWord, Locale(identifier: "ja_JP") as CFLocale)
        else { return [] }
        var result = Set<String>()
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (text as NSString).substring(with: NSRange(location: r.location, length: r.length))
            if isWordLike(token) { result.insert(token) }
        }
        return result
    }

    /// 漢字・カタカナ・英字だけで、2〜12文字（ひらがなや数字だけの言葉は除く）
    nonisolated private static func isWordLike(_ s: String) -> Bool {
        guard (2...12).contains(s.count) else { return false }
        var hasLetter = false
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let kanji = scalar.properties.isIdeographic || scalar == "々"
            let katakana = (0x30A1...0x30FC).contains(v)
            let latin = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            let digit = (0x30...0x39).contains(v)
            guard kanji || katakana || latin || digit else { return false }
            if kanji || katakana || latin { hasLetter = true }
        }
        return hasLetter
    }

    /// 登録の候補にする言葉らしさ：カタカナ3文字以上・英字を含む・漢字3文字以上
    nonisolated private static func looksSpecial(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        if scalars.contains(where: { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }) { return s.count >= 2 }
        if scalars.allSatisfy({ (0x30A1...0x30FC).contains($0.value) }) { return s.count >= 3 }
        return s.count >= 3
    }
}

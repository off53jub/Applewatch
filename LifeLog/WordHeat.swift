import Foundation

/// 聞き取りのヒントに渡す言葉を「いま出そうな順」に並べる（2026-11-10）。
///
/// 聞き取りに渡せる言葉には数の上限がある（家の PC は 80 個、PC が混んでいると 45 個・25 個）。
/// 前は登録した順のまま渡していたので、あとから登録した言葉・直しの正しい書き方・人の名前は、いつも枠の外に落ちていた。
/// ここでは渡す順だけを変える。登録の中身も保存の形も変えない（Vocabulary には書かない）。
///
/// 並べ方（上から）:
/// 1. ついさっき（1時間以内）の会話に出た言葉
/// 2. 直しの正しい書き方と、登録して7日以内の言葉
/// 3. 最近の会話によく出た言葉（7日で半分に薄れる点の高い順）
/// 4. 残りは登録の順。ただし5個に1個はこの残りから入れ、1時間ごとに入れる所をずらす
///    （しばらく出ていない言葉も、ときどき枠に入るようにする）
enum HintOrder {
    /// 見比べるときの形（大文字と小文字・全角と半角をそろえる）
    static func key(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private static func isASCIILetter(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    private static func isASCIIAlnum(_ c: unichar) -> Bool {
        isASCIILetter(c) || (c >= 48 && c <= 57)
    }

    /// その言葉（key の形）が、文（key の形）の中に出ているか。
    /// 英数字だけの言葉は、英字の続きの途中にあるときは数えない（「SP」を「Speaker」の中で数えない）。
    static func appears(_ key: String, in text: NSString) -> Bool {
        let needle = key as NSString
        let size = needle.length
        guard size > 0, text.length >= size else { return false }
        var asciiWord = true
        for i in 0..<size where !isASCIIAlnum(needle.character(at: i)) {
            asciiWord = false
            break
        }
        var from = 0
        while from + size <= text.length {
            let found = text.range(of: key, options: .literal, range: NSRange(location: from, length: text.length - from))
            if found.location == NSNotFound { return false }
            if !asciiWord { return true }
            let end = found.location + found.length
            let before = found.location > 0 && isASCIILetter(text.character(at: found.location - 1))
            let after = end < text.length && isASCIILetter(text.character(at: end))
            if !before && !after { return true }
            from = found.location + 1
        }
        return false
    }

    /// 並べ替える。言葉は1つも捨てない（大文字小文字・全角半角だけが違う重なりは、いちばん後ろへ回す）。
    /// - heat: 言葉（key の形）ごとの、最近の出方の点
    /// - first: 先に出す言葉（key の形）。直しの正しい書き方・登録したばかりの言葉
    /// - recent: ついさっきの会話に出た言葉（key の形）
    /// - turn: 残りの言葉を入れる所をずらす番号（1時間に1つ進む）
    static func ordered(_ words: [String], heat: [String: Double], first: Set<String> = [], recent: Set<String> = [],
                        turn: Int = 0, every: Int = 5, floor: Double = 0.5) -> [String] {
        let every = max(2, every)
        var seen = Set<String>()
        var hot: [(index: Int, word: String, tier: Int, heat: Double)] = []
        var cold: [String] = []
        var extra: [String] = []
        for (index, word) in words.enumerated() {
            let k = key(word)
            if k.isEmpty || !seen.insert(k).inserted {
                extra.append(word)
                continue
            }
            let h = heat[k] ?? 0
            if recent.contains(k) {
                hot.append((index: index, word: word, tier: 0, heat: h))
            } else if first.contains(k) {
                hot.append((index: index, word: word, tier: 1, heat: h))
            } else if h >= floor {
                hot.append((index: index, word: word, tier: 2, heat: h))
            } else {
                cold.append(word)
            }
        }
        hot.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.heat != b.heat { return a.heat > b.heat }
            return a.index < b.index
        }
        if cold.count > 1 {
            let size = cold.count
            let shift = ((turn % size) * 5 % size + size) % size
            if shift > 0 { cold = Array(cold[shift...]) + Array(cold[..<shift]) }
        }
        var out: [String] = []
        out.reserveCapacity(words.count)
        var h = 0
        var c = 0
        while h < hot.count || c < cold.count {
            let coldTurn = (out.count + 1) % every == 0 || h >= hot.count
            if c < cold.count && coldTurn {
                out.append(cold[c])
                c += 1
            } else {
                out.append(hot[h].word)
                h += 1
            }
        }
        return out + extra
    }

    /// 家の PC に実際に渡る分（先頭から limit 個・合わせて chars 文字まで）。HomePC の切り方と同じ
    static func window(_ words: [String], limit: Int, chars: Int = 1500) -> [String] {
        var out: [String] = []
        var length = 0
        for word in words where !word.isEmpty && !word.contains("\n") {
            length += word.count + 1
            if length > chars || out.count >= limit { break }
            out.append(word)
        }
        return out
    }

    /// 文に出てきた登録の言葉の数と、そのうち「渡した枠」と「登録の順のままだったときの枠」に入っていた数。
    /// 数だけを返す（どの言葉かは返さない）。
    static func reach(text: String, words: [String], sent: [String], registered: [String])
        -> (heard: Int, inSent: Int, inRegistered: Int) {
        let folded = key(text) as NSString
        guard folded.length > 0 else { return (0, 0, 0) }
        let sentKeys = Set(sent.map { key($0) })
        let registeredKeys = Set(registered.map { key($0) })
        var seen = Set<String>()
        var heard = 0
        var inSent = 0
        var inRegistered = 0
        for word in words {
            let k = key(word)
            guard k.count >= 2, seen.insert(k).inserted, appears(k, in: folded) else { continue }
            heard += 1
            if sentKeys.contains(k) { inSent += 1 }
            if registeredKeys.contains(k) { inRegistered += 1 }
        }
        return (heard, inSent, inRegistered)
    }
}

/// 登録した言葉の「最近の出方」の点。会話の記録から数えた別のファイル（wordheat.json）で、いつでも作り直せる。
/// 言葉の登録（Vocabulary）・人（people.json）には触らない。
@MainActor
final class WordHeat {
    struct Entry: Codable, Equatable {
        /// last の時点の点（1回出ると 1 点。7日で半分に薄れる）
        var score: Double
        var last: Date
    }

    private struct Store: Codable {
        var words: [String: Entry] = [:]
        /// ここまでに閉じた会話は数えた（会話の始まりの時刻）
        var countedUntil: Date = .distantPast
    }

    /// 点が半分に薄れるまでの長さ
    static let halfLife: TimeInterval = 7 * 86_400
    /// この点より上を「最近よく出た言葉」として先に出す
    static let floor = 0.5
    /// 「ついさっき出た言葉」として覚えておく長さ
    static let recentWindow: TimeInterval = 3_600
    /// さかのぼって数える日数（はじめ・しばらく動かしていなかったとき）
    static let lookBackDays = 14
    /// 1回に数える会話の数（多い日でも画面を止めないように。残りは次の回に数える）
    static let perCall = 300

    private let url: URL
    private var store: Store
    /// ついさっきの会話に出た言葉（key の形）と、その時刻。保存しない
    private var recent: [String: Date] = [:]

    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("wordheat.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        } else {
            store = Store()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func decay(_ seconds: TimeInterval) -> Double {
        pow(0.5, max(0, seconds) / halfLife)
    }

    private static func keys(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words {
            let k = HintOrder.key(word)
            // 1文字の言葉はどこにでも出てくるので数えない
            if k.count >= 2, seen.insert(k).inserted { out.append(k) }
        }
        return out
    }

    // MARK: - 数える

    /// 数えるのが2日より前で止まっている（はじめ・しばらく動かしていなかった）。そのときは 14 日前までの記録を渡してもらう
    func needsCatchUp(now: Date = .now) -> Bool {
        store.countedUntil < now.addingTimeInterval(-2 * 86_400)
    }

    /// まだ数えていない閉じた会話に、登録した言葉が出ているかを数える（テレビや動画の会話は数えない）。
    func count(days: [(day: String, conversations: [ConversationLog.Conversation])], words: [String], now: Date = .now) {
        let keys = Self.keys(words)
        guard !keys.isEmpty else { return }
        let from = max(store.countedUntil, now.addingTimeInterval(-Double(Self.lookBackDays) * 86_400))
        var todo: [ConversationLog.Conversation] = []
        for day in days {
            for c in day.conversations where c.closed && c.start > from && c.media == nil { todo.append(c) }
        }
        guard !todo.isEmpty else { return }
        todo.sort { $0.start < $1.start }
        var latest = store.countedUntil
        for c in todo.prefix(Self.perCall) {
            latest = max(latest, c.start)
            let text = HintOrder.key(c.lines.map(\.text).joined(separator: "\n")) as NSString
            guard text.length > 0 else { continue }
            for k in keys where HintOrder.appears(k, in: text) { add(k, at: c.start) }
        }
        store.countedUntil = latest
        // ほとんど薄れた点は捨てる（1回出ただけなら、およそ40日で消える）
        store.words = store.words.filter { $0.value.score * Self.decay(now.timeIntervalSince($0.value.last)) >= 0.02 }
        save()
    }

    private func add(_ key: String, at time: Date) {
        guard var entry = store.words[key] else {
            store.words[key] = Entry(score: 1, last: time)
            return
        }
        if time >= entry.last {
            entry.score = entry.score * Self.decay(time.timeIntervalSince(entry.last)) + 1
            entry.last = time
        } else {
            entry.score += Self.decay(entry.last.timeIntervalSince(time))
        }
        store.words[key] = entry
    }

    /// いまの点（key の形ごと）
    func heat(now: Date = .now) -> [String: Double] {
        store.words.mapValues { $0.score * Self.decay(now.timeIntervalSince($0.last)) }
    }

    /// 点のある言葉の数（診断に出す。数だけ）
    func hotCount(now: Date = .now) -> Int {
        heat(now: now).values.filter { $0 >= Self.floor }.count
    }

    // MARK: - ついさっき出た言葉

    /// いま書いた行に出てきた言葉を覚える（次の区切りのヒントで先頭に出す）
    func noteHeard(_ text: String, words: [String], at time: Date = .now) {
        let folded = HintOrder.key(text) as NSString
        guard folded.length > 0 else { return }
        for k in Self.keys(words) where HintOrder.appears(k, in: folded) {
            if let old = recent[k], old >= time { continue }
            recent[k] = time
        }
    }

    // MARK: - 並べる

    /// 言葉を「いま出そうな順」に並べる。pinned は先に出す言葉（直しの正しい書き方・登録したばかりの言葉）
    func ordered(_ words: [String], pinned: [String] = [], now: Date = .now) -> [String] {
        let live = recent.filter { now.timeIntervalSince($0.value) <= Self.recentWindow }
        if live.count != recent.count { recent = live }
        let turn = Int(now.timeIntervalSinceReferenceDate / 3_600)
        return HintOrder.ordered(words, heat: heat(now: now), first: Set(pinned.map { HintOrder.key($0) }),
                                 recent: Set(live.keys), turn: turn, floor: Self.floor)
    }
}

import Foundation

/// s24（2026-11-24）の見た目と使い心地の決まり（決まった入力から決まった出力だけ）。画面は S24Views.swift。
/// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 13」（形1・形2・形3・形5・減12）。しきい値はどれも仮。
/// テストは LifeLogTests/S24TodayTests.swift。
enum S24Today {
    // MARK: - 形1 「今日」の棚卸し

    /// 上から 3 枚（録れているか・今日の三つ・今日の 1 問）だけを出し、ほかは「ほか」に畳む（初めはオン・設定で戻せる）
    static let foldKey = "s24.todayFold"

    static var foldOn: Bool { UserDefaults.standard.object(forKey: foldKey) as? Bool ?? true }

    /// 「今日」に出るカード（どれも中身があるときだけ出る。record は畳んだ「今日の記録」で、いつも最後）
    enum Card: String, CaseIterable, Identifiable, Sendable {
        /// 録れているか（あいさつ・録音の丸 3 つ・今日の帯）
        case hero
        /// 休日の顔（地図・写真・食べた物）
        case holiday
        /// 今日の三つと提案 1 つ
        case answer
        /// 今日の 1 問（s24 の 形3。聞く物が無ければ「今日は聞くことはありません」）
        case ask
        /// 気をつけること（署名の期限・録音を休む場所・止まっているかも・家の PC と音沙汰なし・期限の近い決めごと）
        case alerts
        /// 家の PC を新しく
        case pcFeature
        /// 話してから文字になるまで・電池（s22）
        case s22
        /// 新しい版・今日の 1 つの確かめ・答えそびれた質問（s23）
        case s23
        /// 次の予定の前に
        case prep
        /// 朝の昨日と今日
        case morningBrief
        /// 1 年前の今日
        case oneYearAgo
        /// 夜の 10 秒
        case nightMood
        /// けさの気分・今日の問い（自分を知る）
        case knowMe
        /// 会話のあとの約束
        case promises
        /// 1 日 1 分の答え合わせ
        case checkups
        /// 返事・メールの下書き
        case replies
        /// 家の PC が書いている途中の下書き
        case draft
        /// 今日の記録（今日の会話・最近の発言・いまの様子。いつも畳んである）
        case record

        var id: String { rawValue }
    }

    /// 上に出すものと「ほか」に畳むもの（record はどちらにも入れない。画面がいつも最後に置く）。
    /// fold が false なら、s20〜s23 の並び（前の動き）のまま
    static func layout(fold: Bool, part: DayPart) -> (top: [Card], more: [Card]) {
        guard fold else {
            var top: [Card] = [.hero, .holiday, .answer, .alerts, .pcFeature, .s22, .s23]
            switch part {
            case .morning: top += [.prep, .morningBrief, .oneYearAgo]
            case .night: top += [.nightMood, .knowMe]
            case .day: top += [.prep]
            }
            var more: [Card] = []
            if part == .night { more.append(.prep) }
            more += [.promises, .checkups, .replies]
            if part != .night { more += [.nightMood, .knowMe] }
            if part != .morning { more.append(.morningBrief) }
            more.append(.draft)
            return (top, more)
        }
        // 気をつけることは、あるときだけ・本人が動く知らせなので上に残す（署名の期限が切れると録音が止まる）
        let top: [Card] = [.hero, .answer, .ask, .alerts]
        var more: [Card] = [.holiday, .s23, .knowMe]
        switch part {
        case .morning: more += [.prep, .morningBrief, .oneYearAgo, .nightMood]
        case .night: more += [.nightMood, .prep, .morningBrief]
        case .day: more += [.prep, .nightMood, .morningBrief]
        }
        more += [.promises, .checkups, .replies, .draft, .s22, .pcFeature]
        return (top, more)
    }

    /// いま「今日」にあるカードの種類の数（棚卸しの数。record を含む）
    static func cardKinds(fold: Bool) -> Int {
        var kinds = Set<Card>()
        for part in [DayPart.morning, .day, .night] {
            let l = layout(fold: fold, part: part)
            kinds.formUnion(l.top)
            kinds.formUnion(l.more)
        }
        kinds.insert(.record)
        return kinds.count
    }

    // MARK: - 形3 今日の 1 問

    enum Ask: Equatable, Sendable {
        /// 30 日使われなかった画面を「ほか」に畳むか（減12。12/6 以降に 1 回だけ）
        case fold([String])
        /// 確かめ待ちの 1 枚（いちばん上）
        case review(id: String, question: String)
        /// 自分を知るの今日の問い
        case know(id: String, text: String)
        /// 答えそびれた質問がある
        case missed
        /// 聞くことは無い（済みの形で見せる）
        case nothing
    }

    /// 1 つだけ選ぶ（減4 に合わせて、溜まった数は出さない）
    static func pickAsk(foldOffer: [String], review: [(id: String, question: String)],
                        know: [(id: String, text: String)], missed: Int) -> Ask {
        if !foldOffer.isEmpty { return .fold(foldOffer) }
        if let first = review.first { return .review(id: first.id, question: first.question) }
        if let first = know.first { return .know(id: first.id, text: first.text) }
        if missed > 0 { return .missed }
        return .nothing
    }

    static let noneText = "今日は聞くことはありません"
}

// MARK: - 形2 よく触る設定を「今日」に

enum S24Settings {
    /// 「くわしい設定」・設定を探す・今日の列で触った設定を数える名前（Tally。"s24.touch." + 設定の名前）
    static let tallyPrefix = "s24.touch."
    /// まだ数が無いうちの 3 つ（仮）: 待機モード・時計から家の PC に直接送る・音がしないあいだは書かない
    static let initial = ["standbyOn", "homePCWatchDirect", "skipSilence"]
    /// 数えるあいだ（日）
    static let days = 30

    static func tallyName(_ id: String) -> String { tallyPrefix + id }

    /// 触る前と後で変わった設定（並びは before の名前順）
    static func changed(before: [String: Bool], after: [String: Bool]) -> [String] {
        before.keys.sorted().filter { key in
            guard let a = after[key], let b = before[key] else { return false }
            return a != b
        }
    }

    /// よく触る 3 つ（数の多い順・同じなら一覧の順）。3 つに足りなければ初めの 3 つで埋め、そのときは provisional（仮）
    static func top(_ available: [String], sums: [String: Int], count: Int = 3) -> (ids: [String], provisional: Bool) {
        var rows: [(id: String, n: Int, index: Int)] = []
        for (index, id) in available.enumerated() {
            let n = sums[tallyName(id)] ?? 0
            if n > 0 { rows.append((id: id, n: n, index: index)) }
        }
        let counted: [String] = rows
            .sorted { $0.n != $1.n ? $0.n > $1.n : $0.index < $1.index }
            .map { $0.id }
        var ids = Array(counted.prefix(count))
        let provisional = ids.count < count
        for id in initial where ids.count < count && available.contains(id) && !ids.contains(id) {
            ids.append(id)
        }
        return (ids, provisional)
    }
}

// MARK: - 形5・減12 入口を 5 つに・使われていない画面を「ほか」に

enum S24Entries {
    /// 一覧の入口を 5 つまでにする（ほかは「ほか」に。初めはオン・設定で戻せる。消さない）
    static let limitKey = "s24.entryLimit"
    /// 本人が畳んだ画面の名前（減12。戻せる）
    static let foldedKey = "s24.folded"
    /// 減12 の候補を出した日（1 回だけ。出した日のうちは出し続ける）と、答えたか
    static let offeredDayKey = "s24.unusedOfferedDay"
    static let answeredKey = "s24.unusedAnswered"
    /// 1 つの一覧に出す入口の数
    static let limit = 5
    /// 減12 を出し始める日（数え始めから 30 日たつころ。仮）
    static let offerFrom = "2026-12-06"
    /// 使われていないとみなす日数
    static let unusedDays = 30

    static var limitOn: Bool { UserDefaults.standard.object(forKey: limitKey) as? Bool ?? true }

    /// 一覧の入口を、出すもの・「ほか」に分ける（どちらも元の並び）。
    /// 本人が畳んだものはいつも「ほか」。limitOn なら、残りのうち 30 日でよく開いた 5 つだけを出す（同じ数なら元の並びの先）
    static func split(_ keys: [String], opens: [String: Int], folded: Set<String>, limitOn: Bool,
                      limit: Int = S24Entries.limit) -> (shown: [String], other: [String]) {
        let open = keys.filter { !folded.contains($0) }
        guard limitOn, open.count > limit else {
            return (open, keys.filter { folded.contains($0) })
        }
        let ranked = open.enumerated()
            .sorted { a, b in
                let na = opens[a.element] ?? 0, nb = opens[b.element] ?? 0
                return na != nb ? na > nb : a.offset < b.offset
            }
            .prefix(limit)
            .map { $0.element }
        let keep = Set(ranked)
        return (keys.filter { keep.contains($0) }, keys.filter { !keep.contains($0) })
    }

    /// 減12 の候補: その画面を数え始めて（since）30 日たった・30 日で 1 回も開かれていない・まだ畳んでいない入口
    static func unusedCandidates(_ keys: [(key: String, since: String)], sums30: [String: Int], today: String,
                                 folded: Set<String>) -> [String] {
        keys.filter { entry in
            guard !folded.contains(entry.key), let days = daysBetween(entry.since, today), days >= unusedDays else { return false }
            return (sums30["screen." + entry.key] ?? 0) == 0
        }
        .map { $0.key }
    }

    /// "YYYY-MM-DD" どうしの日数（読めなければ nil）
    static func daysBetween(_ from: String, _ to: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> Int? {
        func date(_ text: String) -> Date? {
            let p = text.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
        }
        guard let a = date(from), let b = date(to) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    /// 減12 をいま出すか: 12/6 以降・まだ答えていない・出したことが無いか、出した日が今日
    static func shouldOffer(today: String, offeredDay: String?, answered: Bool, candidates: [String]) -> Bool {
        guard !answered, !candidates.isEmpty, today >= offerFrom else { return false }
        guard let offeredDay, !offeredDay.isEmpty else { return true }
        return offeredDay == today
    }
}

// MARK: - 形8 色の役割（今日の「気をつけること」）

enum S24Alerts {
    enum Kind: String, CaseIterable, Sendable {
        /// 期限が 3 日以内の決めごと
        case decisionDue
        /// 家の PC と 6 時間やり取りできていない
        case pcQuiet
        /// 署名の期限
        case signExpiry
        /// 録音を休む場所にいる
        case held
        /// 止まっているかも（家の PC の見張り）
        case stale
        /// Google にログインしていない
        case noLogin
    }

    /// 赤＝いま本人が動く・青＝機械が進めている・灰＝待てば直る（問いには色を付けない）
    static func role(_ kind: Kind) -> LLRole {
        switch kind {
        case .decisionDue, .pcQuiet, .signExpiry, .noLogin: .act
        // 録音を休む場所を出れば戻る・止まっているかもは家の PC の見張りが立て直す（届かなければ LINE・急ぎの知らせ）
        case .held, .stale: .wait
        }
    }
}

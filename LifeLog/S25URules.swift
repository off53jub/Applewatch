import Foundation

/// s25（2026-11-24）の A2 の決まり（決まった入力から決まった出力だけ）。画面は S25UViews.swift。
/// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 14」（堅3・早1・早3・片3）と「追記 15」（大1・大2）。しきい値はどれも仮。
/// テストは LifeLogTests/S25UTests.swift。

// MARK: - 大1 引き算の版

enum S25USimple {
    /// 設定・点検・ふり返りを少なく見せる（初めはオン。切ると s24 までの並びに戻る。消したものは無い）
    static let key = "s25u.simple"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// 画面の下の 5 つの入口（タブ）。どの画面も、このどれか（か設定の歯車）に役割で入る
    enum Role: String, CaseIterable, Sendable {
        case record = "今日（録る・今を見る）"
        case tasks = "タスク（やること）"
        case fix = "直す（記録を正しくする）"
        case find = "記録（探す・読む）"
        case look = "ふり返り（自分をふり返る）"
        /// 歯車の中
        case check = "点検（調子を見る）"
        case setting = "設定（変える）"
    }

    /// 置き場所
    enum Place: String, Sendable {
        /// いつもの所に出す
        case main = "出す"
        /// 同じ画面のいちばん下の「ほか」の中
        case other = "ほか"
        /// 「くわしい設定」の中
        case detailed = "くわしい"
    }

    /// 並べ直す 1 つ（id は画面のかたまり。rows は見える行のだいたいの数＝3 分の 1 の数え方）
    struct Item: Equatable, Sendable {
        var id: String
        var title: String
        var role: Role
        /// s24 までの置き場所（PR の表に出す）
        var before: String
        /// 引き算の版の置き場所
        var after: Place
        var rows: Int
    }

    /// 設定（歯車の「設定」）
    static let settings: [Item] = [
        Item(id: "scene", title: "場面のセット", role: .setting, before: "設定・いちばん上", after: .main, rows: 3),
        Item(id: "search", title: "設定を探す・変えた所だけ・初めに戻す", role: .setting, before: "設定", after: .main, rows: 1),
        Item(id: "everydayCore", title: "Face ID・Claude を使う", role: .setting, before: "設定・ふだん", after: .main, rows: 2),
        Item(id: "simpleSwitch", title: "設定を少なく見せる（前の並びに戻すスイッチ）", role: .setting, before: "（新しい）", after: .main, rows: 1),
        Item(id: "detailedLink", title: "くわしい設定", role: .setting, before: "設定・いちばん下", after: .main, rows: 1),
        Item(id: "otherLink", title: "ほかの設定（入口）", role: .setting, before: "（新しい）", after: .main, rows: 1),
        Item(id: "common", title: "よく使う（見た目・寝ているあいだ・知らせ・一緒にいる人に見せる 1 枚）", role: .setting,
             before: "設定（s20）", after: .other, rows: 4),
        Item(id: "help", title: "説明（新しく入ったもの・守りの 1 枚・言葉の一覧・初めての入口）", role: .setting,
             before: "設定（s20）", after: .other, rows: 4),
        Item(id: "preset", title: "録り方の組（電池・早さ・精度）", role: .setting, before: "設定（s21）", after: .other, rows: 3),
        Item(id: "everydayNotices", title: "朝の知らせ・夜の 10 秒・職場の会話も Claude で", role: .setting,
             before: "設定・ふだん", after: .other, rows: 5),
        Item(id: "holiday", title: "休日（家を出たら・外出モード・映画館で休む など 9 つ）", role: .setting,
             before: "設定（s19）", after: .other, rows: 10),
    ]

    /// 点検（歯車の「点検」）
    static let check: [Item] = [
        Item(id: "diagnostics", title: "自己点検", role: .check, before: "点検・調子", after: .main, rows: 1),
        Item(id: "listen", title: "聞き取りの成績", role: .check, before: "点検・調子", after: .main, rows: 1),
        Item(id: "reports", title: "報告の棚（母艦の報告を読む）", role: .check, before: "点検・報告と時計（s22）", after: .main, rows: 1),
        Item(id: "otherLink", title: "ほかの点検（入口）", role: .check, before: "（新しい）", after: .main, rows: 1),
        Item(id: "condition", title: "録音の抜けと数の照合・時計の遅れ・クラウドに送ったもの", role: .check,
             before: "点検・調子", after: .other, rows: 3),
        Item(id: "voiceQuick", title: "声を手早く直す（○×）", role: .fix, before: "点検（s21）", after: .other, rows: 2),
        Item(id: "watch", title: "いつも録れない所・時計の LifeLog を新しく・時計に溜まった分・送り直し", role: .check,
             before: "点検・報告と時計（s22）", after: .other, rows: 4),
        Item(id: "checklist", title: "実機でまだ確かめていない新しい動き", role: .check, before: "点検", after: .other, rows: 4),
        Item(id: "mothership", title: "精度の通信簿・あまり開かれていない画面", role: .check, before: "点検", after: .other, rows: 2),
        Item(id: "reflection", title: "反映の見張り", role: .check, before: "点検", after: .other, rows: 1),
        Item(id: "settle", title: "入れた施策の様子・Claude の費用", role: .check, before: "点検", after: .other, rows: 2),
        Item(id: "backup", title: "登録の控え・記録の掃除・今年の分を書き出す", role: .check, before: "点検", after: .other, rows: 4),
    ]

    /// ふり返り（2026-11-27 の s30 から「記録」の上の切り替え。前はタブ）。s24 の「入口は 5 つまで」の分はそのまま（S24Entry）
    static let lookBack: [Item] = [
        Item(id: "numbers", title: "数で見る・ふり返りの本（s20）", role: .look, before: "ふり返り・いちばん上", after: .main, rows: 6),
        Item(id: "weekly", title: "今週のふり返り・見立て・使われ方", role: .look, before: "ふり返り", after: .main, rows: 3),
        Item(id: "otherLink", title: "ほかのふり返り（入口）", role: .look, before: "（新しい）", after: .main, rows: 1),
        Item(id: "timeLedger", title: "時間の家計簿", role: .look, before: "ふり返り", after: .other, rows: 2),
        Item(id: "tension", title: "緊張した場面", role: .look, before: "ふり返り", after: .other, rows: 2),
        Item(id: "threads", title: "話題の糸", role: .look, before: "ふり返り", after: .other, rows: 2),
    ]

    /// 前の並びにだけあったもの（新しい入口は前の並びでは出さない）
    static func isNewEntry(_ item: Item) -> Bool { item.before == "（新しい）" }

    /// いつもの所に出すもの（前の並びなら、新しい入口とスイッチを除く全部）
    static func shown(_ items: [Item], simple: Bool) -> [String] {
        simple ? items.filter { $0.after == .main }.map(\.id) : items.filter { !isNewEntry($0) || $0.id == "simpleSwitch" }.map(\.id)
    }

    /// 「ほか」に入るもの（前の並びなら空）
    static func other(_ items: [Item], simple: Bool) -> [String] {
        simple ? items.filter { $0.after == .other }.map(\.id) : []
    }

    /// いつもの所に見える行のだいたいの数
    static func visibleRows(_ items: [Item], simple: Bool) -> Int {
        let ids = Set(shown(items, simple: simple))
        return items.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.rows }
    }

    /// 見えるものが消えていないか（前の並びで見えたものは、引き算の版でも「出す」か「ほか」にある）
    static func nothingLost(_ items: [Item]) -> Bool {
        let before = Set(shown(items, simple: false)).subtracting(["simpleSwitch"])
        let after = Set(shown(items, simple: true) + other(items, simple: true))
        return before.isSubset(of: after)
    }

    /// PR と docs に貼る「何をどこへ動かしたか」の表（Markdown）
    static func moveTable() -> String {
        var lines = ["| 画面 | かたまり | 役割 | s24 まで | s25（引き算の版） |", "|---|---|---|---|---|"]
        for (screen, items) in [("設定", settings), ("点検", check), ("ふり返り", lookBack)] {
            for item in items {
                lines.append("| \(screen) | \(item.title) | \(item.role.rawValue) | \(item.before) | \(item.after.rawValue) |")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 大2（K5） 31 の機能の使った回数

enum S25UFeatures {
    /// 1 つの機能（slug は母艦の docs/features.md の id）
    struct Feature: Equatable, Sendable {
        var slug: String
        var name: String
        /// この名前の数が足されたら、その機能を 1 回使ったと数える
        var names: [String]
        /// この頭の名前でも数える
        var prefixes: [String] = []
        /// アプリが直接 feat.<slug> を足す所（文書用）
        var direct: String? = nil
    }

    static let tallyPrefix = "feat."

    static func tallyName(_ slug: String) -> String { tallyPrefix + slug }

    /// 31 の機能（アプリ 13・母艦 18）。names が空で direct も無いものは、アプリでは数える口が無い（母艦の数で見る）
    static let all: [Feature] = [
        Feature(slug: "app-record", name: "常時録音と文字起こし", names: ["work.lines", "other.lines", "screen.dayView", "screen.recordsDays"]),
        Feature(slug: "app-watch", name: "Apple Watch の録音を家の PC へ", names: [], direct: "時計の区切りが iPhone に届くたび（Latency.noteChunk）"),
        Feature(slug: "app-speaker", name: "話者の聞き分け",
                names: ["sameperson.merged", "sameperson.different", "sameperson.maybe.merged", "sameperson.maybe.different",
                        "unnamed.named", "s21.quickReview.keep", "s21.quickReview.forget", "s21.selfVoice.yes", "s21.selfVoice.no",
                        "spkdoubt.self", "spkdoubt.dismiss", "pc.speakerAccepted", "pc.speakerRejected",
                        "screen.speakerDoubts", "screen.unnamedVoices", "screen.voiceReview", "screen.samePerson"]),
        Feature(slug: "app-tv", name: "テレビ・動画の見分け", names: [], direct: "行を放送の行にしたとき（Pipeline.markMedia）"),
        Feature(slug: "app-headline", name: "会話の見出しと1日のまとめ", names: ["title.made", "title.filled"]),
        Feature(slug: "app-tasks", name: "頼まれごと帳",
                names: ["screen.taskBook", "screen.confirmBox", "task.bulk.rest", "promise.added", "s23.promise.notice.add"],
                prefixes: ["s23.promise.today."]),
        Feature(slug: "app-ask", name: "記録に質問する・探す",
                names: ["screen.ask", "screen.unifiedSearch", "askmother.found", "askmother.none", "voiceAsk.answered", "voiceAsk.timeout"]),
        Feature(slug: "app-stop-alert", name: "録音が止まったら知らせる",
                names: ["notice.opened.phone-stopped", "notice.opened.stopped", "notice.opened.watch-silent",
                        "notice.opened.watch-not-recording", "notice.opened.not-recording"]),
        Feature(slug: "app-weekly", name: "週のまとめ", names: ["weekly.shown", "screen.workWeek"]),
        Feature(slug: "app-good", name: "いいこと帳", names: ["screen.goodThings"]),
        Feature(slug: "app-learned", name: "わかったこと帳", names: ["screen.facts"]),
        Feature(slug: "app-location", name: "位置の書き出し",
                names: ["screen.places", "screen.placeMap", "screen.placePage", "screen.placePages", "screen.unnamedPlaces",
                        "placeask.answered", "s23.placesNight.answered"]),
        Feature(slug: "app-health", name: "ヘルスケアの書き出し", names: []),
        Feature(slug: "ms-line", name: "LINE の自動保存", names: []),
        Feature(slug: "ms-digest", name: "朝のまとめ（日次ダイジェスト）", names: ["morningSpeech.played", "screen.briefCompare", "notice.opened.brief"]),
        Feature(slug: "ms-plaud-audio", name: "PLAUD 音声の取り込み", names: []),
        Feature(slug: "ms-plaud-text", name: "PLAUD 公式の文字起こし", names: ["plaudfill.viewed"]),
        Feature(slug: "ms-drive", name: "母艦からドライブへの写し", names: []),
        Feature(slug: "ms-today", name: "今日の三つ", names: ["proposal.accept", "proposal.later", "proposal.never"]),
        Feature(slug: "ms-todo", name: "TODO の寿命・期限切れの整理", names: []),
        Feature(slug: "ms-decisions", name: "決定の寿命（未決に期限とデフォルト）", names: ["decision.chosen", "screen.decisions"]),
        Feature(slug: "ms-timeline", name: "1日の年表", names: ["timeline.fetched", "screen.moment"]),
        Feature(slug: "ms-people", name: "人物ノート（いまの様子）",
                names: ["screen.personPage", "screen.peoplePages", "screen.people", "prep.shown"]),
        Feature(slug: "ms-spend", name: "カードの利用速報・月次決算",
                names: ["screen.money", "screen.unmatchedPayments", "screen.paypayShot", "paypayshot.sent"]),
        Feature(slug: "ms-sleep", name: "睡眠プロキシ", names: []),
        Feature(slug: "ms-pledge", name: "コスト誓約の突き合わせ", names: []),
        Feature(slug: "ms-browser", name: "閲覧履歴・PC の作業記録", names: []),
        Feature(slug: "ms-work", name: "仕事のまとめの写し", names: ["screen.workDigest", "screen.workThreads"]),
        Feature(slug: "ms-vocab", name: "言葉の登録の候補", names: ["screen.vocabulary", "bulk.vocab"]),
        Feature(slug: "ms-board", name: "止まっていないか（この台帳の入力）", names: ["screen.reflection"]),
        Feature(slug: "ms-photos", name: "写真の索引", names: []),
    ]

    private static let byName: [String: String] = {
        var out: [String: String] = [:]
        for feature in all { for name in feature.names { out[name] = feature.slug } }
        return out
    }()

    /// 足された数の名前から、使った機能の slug（無ければ nil。feat. の名前そのものは nil＝重ねて数えない）
    static func slug(for name: String) -> String? {
        guard !name.hasPrefix(tallyPrefix) else { return nil }
        if let slug = byName[name] { return slug }
        for feature in all where feature.prefixes.contains(where: { name.hasPrefix($0) }) { return feature.slug }
        return nil
    }

    /// docs/s25-feature-keys.md の表（Markdown）
    static func keyTable() -> String {
        var lines = ["| slug | 機能 | tally の名前 | 数える元 |", "|---|---|---|---|"]
        for f in all {
            var from = (f.names + f.prefixes.map { $0 + "*" }).map { "`\($0)`" }.joined(separator: " ")
            if let direct = f.direct { from = direct }
            if from.isEmpty { from = "アプリでは数える口が無い（母艦の数で見る）" }
            lines.append("| \(f.slug) | \(f.name) | `\(tallyName(f.slug))` | \(from) |")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 堅3 時計の版が古いまま 24 時間

enum S25UWatchLag {
    /// 時計が古いと分かった組（"時計-iPhone"）と、初めて見た時刻
    static let pairKey = "s25u.watchLag.pair"
    static let sinceKey = "s25u.watchLag.since"
    /// これだけ続いたら「今日」の「気をつけること」に出す（仮）
    static let after: TimeInterval = 24 * 3600

    /// 覚えておく組（時計が古いときだけ。同じでも新しくても nil＝忘れる）
    static func pair(phone: Int, watch: String?) -> String? {
        guard let watch, let w = Int(watch), w < phone else { return nil }
        return "\(w)-\(phone)"
    }

    /// 次に覚える「初めて見た時刻」（組が変わったら今から数え直す）
    static func since(pair: String?, savedPair: String?, savedSince: Date?, now: Date) -> Date? {
        guard let pair else { return nil }
        if pair == savedPair, let savedSince { return savedSince }
        return now
    }

    /// 出すか（古いまま 24 時間・時計の便りが届いたことがある）
    static func shouldShow(since: Date?, now: Date, watchSeen: Bool) -> Bool {
        guard watchSeen, let since else { return false }
        return now.timeIntervalSince(since) >= after
    }

    /// 「気をつけること」の 1 行
    static func line(phone: Int, watch: String, hours: Int) -> String {
        "時計の LifeLog が古い版のまま \(hours) 時間です（時計 \(watch)・iPhone \(phone)）。押すと入れ直しの手順です"
    }
}

// MARK: - 早1・早3 文字になるまでの待ちを段ごとに

enum S25UWait {
    /// 段（時計で待った・iPhone で待った・iPhone→PC・PC の作業）
    enum Stage: String, CaseIterable, Sendable {
        /// 録音の終わり → iPhone に届いた（時計の区切りだけ）
        case watch
        /// iPhone に届いた → PC に送り始めた
        case phone
        /// 送り始めた → PC が受け終わった
        case toPC
        /// PC が受け終わった → でき上がった（PC の列と作業）
        case pc
    }

    /// 1 つの区切りの段ごとの秒数（Latency.Sample から）
    static func stages(_ s: Latency.Sample) -> [Stage: Double] {
        var out: [Stage: Double] = [:]
        if let v = s.toPhone { out[.watch] = v }
        if let v = s.phoneWait { out[.phone] = v }
        if let v = s.transfer { out[.toPC] = v }
        if let w = s.pcWait, let p = s.pcWork { out[.pc] = w + p } else if let p = s.pcWork { out[.pc] = p }
        return out
    }

    /// 送ったときの道（Wi-Fi・モバイル通信・つながっていない）
    enum Net: String, Sendable {
        case wifi, cell
        case offline = "none"
    }

    /// iPhone→PC の中身の見分け（仮説ごと）
    enum Cause: String, CaseIterable, Sendable {
        /// Wi-Fi 待ち: 送るときにつながっていない・Wi-Fi でなくモバイル通信で送らない設定（つながる道に戻るまで iOS が待つ）
        case wifiWait
        /// 外の道: モバイル通信で送った（家の外から Tailscale を通った）
        case outside
        /// まとめて送り: 同じころに 3 つ以上（仮）まとめて送り始めた
        case batched
        /// どれでもない（Wi-Fi で 1 つずつ）
        case plain
    }

    /// まとめて送りとみなす近さ（秒）と数（仮）
    static let batchWindow: TimeInterval = 20
    static let batchMin = 3

    /// 送り始めた時刻のうち、近くに batchMin 個以上かたまっているもの（自分を含む）
    static func batched(_ sent: [Date], window: TimeInterval = batchWindow, min: Int = batchMin) -> [Bool] {
        sent.map { t in sent.filter { abs($0.timeIntervalSince(t)) <= window }.count >= min }
    }

    static func cause(net: Net?, cellularAllowed: Bool?, batched: Bool) -> Cause {
        // つながっていない・モバイル通信で送らない設定なら、Wi-Fi（つながる道）に戻るまで iOS が待つ
        if net == .offline { return .wifiWait }
        if net == .cell, cellularAllowed == false { return .wifiWait }
        if net == .cell { return .outside }
        if batched { return .batched }
        return .plain
    }

    /// 1 日ぶんの様子（diag の state.s25uWait。秒。中央値・数）。区切りが無ければ nil
    static func summary(_ samples: [Latency.Sample], now: Date, within: TimeInterval = 86400) -> [String: Any]? {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= within && $0.at <= now.addingTimeInterval(60) && $0.pcFirst != true }
        guard !recent.isEmpty else { return nil }
        func round(_ v: Double?) -> Double? { v.map { ($0 * 10).rounded() / 10 } }
        var stageOut: [String: Any] = [:]
        var longest: (Stage, Double)?
        for stage in Stage.allCases {
            let values = recent.compactMap { stages($0)[stage] }
            guard let median = Latency.median(values) else { continue }
            let entry: [String: Any] = ["median": round(median) ?? 0, "count": values.count, "sum": round(values.reduce(0, +)) ?? 0]
            stageOut[stage.rawValue] = entry
            if median > (longest?.1 ?? -1) { longest = (stage, median) }
        }
        // iPhone→PC（届いた → PC が受け終わった）の中身を、わけごとに
        let withSent = recent.filter { $0.sent != nil }
        let flags = batched(withSent.compactMap(\.sent))
        var causeValues: [Cause: [Double]] = [:]
        for (sample, isBatched) in zip(withSent, flags) {
            guard let total = sample.toPC else { continue }
            let c = cause(net: sample.net.flatMap(Net.init(rawValue:)), cellularAllowed: sample.cellular, batched: isBatched)
            causeValues[c, default: []].append(total)
        }
        var causeOut: [String: Any] = [:]
        for c in Cause.allCases {
            guard let values = causeValues[c], let median = Latency.median(values) else { continue }
            let entry: [String: Any] = ["median": round(median) ?? 0, "count": values.count]
            causeOut[c.rawValue] = entry
        }
        var out: [String: Any] = ["count": recent.count, "stages": stageOut]
        if let longest { out["longest"] = longest.0.rawValue }
        if !causeOut.isEmpty { out["toPCCauses"] = causeOut }
        return out
    }

    /// 自己点検の 1 行（段ごとの中央値。分からない段は省く）
    static func line(_ samples: [Latency.Sample], now: Date) -> String? {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= 86400 && $0.pcFirst != true }
        let names: [(Stage, String)] = [(.watch, "時計で待った"), (.phone, "iPhone で待った"), (.toPC, "iPhone→PC"), (.pc, "PC の作業")]
        let parts: [String] = names.compactMap { stage, name in
            Latency.median(recent.compactMap { stages($0)[stage] }).map { name + " " + S25UNumber.seconds($0) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

/// 秒の短い書き方（10 秒未満は小数 1 桁）
enum S25UNumber {
    static func seconds(_ v: Double) -> String {
        if v >= 120 { return String(format: "%.1f 分", v / 60) }
        return v < 10 ? String(format: "%.1f 秒", v) : "\(Int(v.rounded())) 秒"
    }
}

// MARK: - 片3 初めはオフのまま 30 日

enum S25UOffLong {
    /// スイッチの名前 → オフのままだと初めて見た日（"YYYY-MM-DD"）
    static let key = "s25u.offSince"
    /// 一覧に出す日数（仮）
    static let days = 30

    /// 次に覚えるもの（初めはオフのスイッチだけ。いまオンなら忘れる。初めて見たオフは今日から）
    static func update(saved: [String: String], offByDefault: [(id: String, on: Bool)], today: String) -> [String: String] {
        var out: [String: String] = [:]
        for entry in offByDefault where !entry.on {
            out[entry.id] = saved[entry.id] ?? today
        }
        return out
    }

    /// 30 日オフのままのもの（名前の順）
    static func long(_ since: [String: String], today: String) -> [String] {
        since.filter { (S24Entries.daysBetween($0.value, today) ?? 0) >= days }.keys.sorted()
    }
}

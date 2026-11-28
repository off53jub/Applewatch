import Foundation

/// s26（2026-11-25）の A2 の決まり（決まった入力から決まった出力だけ）。画面は S26UViews.swift、動きは S26UBook.swift。
/// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 16」（軽1・軽3・軽4・軽5・軽6・軽9・軽10・軽11）。しきい値はどれも仮。
/// 取り決めは K4（機械がしたこと）・K5（本人の操作待ち）・K6（すきまの 1 件）。テストは LifeLogTests/S26UTests.swift。
/// 新しい問い・知らせは足していない（減13）。言語モデルの新しい呼び出しも無い。

// MARK: - 軽3 設定を開かなくて済むように（よく変える 3 つを「今日」に）

enum S26UQuick {
    /// 「今日」によく変える 3 つを出す（画面の表示だけ。初めはオン。切ると s24 の「よく触る設定」に戻る）
    static let key = "s26u.quick"
    /// 数えるあいだ（日。s24 の 形2 と同じ 30 日）
    static let days = 30

    /// 録り方の組（電池・早さ・精度。tally は s21.preset.*）と、場面のセット（tally は s20.scene.*）
    static let preset = "preset"
    static let scene = "scene"
    /// 数がまだ無いうちの並び（仮）: 2026-11-06〜25 の実機の数で、設定を開いて変えていたのは録り方の組 7 回・場面 4 回だった
    static let initial = [preset, scene]

    /// 1 つの候補の数（preset と scene は頭の名前の合計、ほかは s24.touch.<名前>）
    static func count(_ id: String, sums: [String: Int]) -> Int {
        switch id {
        case preset: return sums.filter { $0.key.hasPrefix("s21.preset.") }.reduce(0) { $0 + $1.value }
        case scene: return sums.filter { $0.key.hasPrefix("s20.scene.") }.reduce(0) { $0 + $1.value }
        default: return sums[S24Settings.tallyName(id)] ?? 0
        }
    }

    /// よく変える 3 つ（数の多い順・同じなら候補の順。preset・scene・スイッチの順で候補を並べる）。
    /// 3 つに足りなければ初めの並び（組・場面・s24 の初めの 3 つ）で埋め、そのときは provisional（仮）
    static func top(switches: [String], sums: [String: Int], count limit: Int = 3) -> (ids: [String], provisional: Bool) {
        let candidates = [preset, scene] + switches
        var rows: [(id: String, n: Int, index: Int)] = []
        for (index, id) in candidates.enumerated() {
            let n = count(id, sums: sums)
            if n > 0 { rows.append((id: id, n: n, index: index)) }
        }
        var ids = rows.sorted { $0.n != $1.n ? $0.n > $1.n : $0.index < $1.index }.prefix(limit).map(\.id)
        let provisional = ids.count < limit
        for id in initial + S24Settings.initial where ids.count < limit && candidates.contains(id) && !ids.contains(id) {
            ids.append(id)
        }
        return (ids, provisional)
    }

    /// コントロールセンターの「録り方の組を替える」で次に選ぶ組（電池 → 早さ → 精度 → 電池。いまの組が分からなければ電池）
    static func next(after current: S21Preset?) -> S21Preset {
        let all = S21Preset.allCases
        guard let current, let i = all.firstIndex(of: current) else { return .battery }
        let j = all.index(after: i)
        return j == all.endIndex ? all[all.startIndex] : all[j]
    }
}

// MARK: - 軽4 答える場所を 1 つに（確かめ待ち・聞いて直す・問い・見直しを 1 つの山に）

enum S26UPile {
    /// 「直す」のいちばん上に 1 つの山を出す（画面の表示だけ。初めはオン。切ると s24 までの並び）
    static let key = "s26u.pile"
    /// 音を自動で鳴らす（聞いて直すの切り出した音・確かめ待ちの声。初めはオン）
    static let autoPlayKey = "s26u.pile.autoPlay"

    /// 山のカードの種類（並びの順）
    enum Kind: String, CaseIterable, Sendable {
        /// 母艦の確かめ待ち（S20Book。○×・選ぶ）
        case review
        /// 聞いて直す（ReviewNudge。合っている・とばす）
        case listen
        /// AI からの質問（AskBook。選ぶ）
        case ask
        /// 自分を知る（KnowMeBook。下書きのまま・開いて答える）
        case know

        var label: String {
            switch self {
            case .review: "確かめ待ち"
            case .listen: "聞いて直す"
            case .ask: "AI からの質問"
            case .know: "自分を知る"
            }
        }

        var symbol: String {
            switch self {
            case .review: "hand.raised"
            case .listen: "ear"
            case .ask: "lightbulb"
            case .know: "person.text.rectangle"
            }
        }
    }

    /// 1 枚（中身は画面が持つ。ここでは並べ方と数え方だけ）
    struct Card: Equatable, Sendable {
        var kind: Kind
        var id: String
        /// 母艦が付けた「直る行の数」の見込み（あるものを先に）
        var impact: Int? = nil

        /// 1 日 3 問の数えに使う印（確かめ待ちは S20Book が "q:" + id で数える）
        var askKey: String { kind == .review ? "q:" + id : "pile:" + kind.rawValue + ":" + id }
    }

    /// 1 つの山の並び: 種類ごとに 1 枚ずつ交互に（同じ種類が続かないように）。種類の中は渡された順（確かめ待ちは impact の多い順）
    static func merge(_ groups: [Kind: [Card]]) -> [Card] {
        var queues: [[Card]] = Kind.allCases.map { kind -> [Card] in
            let cards = groups[kind] ?? []
            guard kind == .review else { return cards }
            return cards.enumerated().sorted { a, b in
                let x = a.element.impact ?? 0, y = b.element.impact ?? 0
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
        }
        var out: [Card] = []
        while queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where !queues[i].isEmpty {
                out.append(queues[i].removeFirst())
            }
        }
        return out
    }

    /// 今日出す分と、上限を超えた分（今の「全部で 1 日 3 問」を守る。超えた分は本人が「続けて答える」を押したときだけ見せる）
    static func split(_ cards: [Card], left: Int) -> (today: [Card], more: [Card]) {
        let n = max(0, min(left, cards.count))
        return (Array(cards.prefix(n)), Array(cards.dropFirst(n)))
    }

    /// 払った向きの答え（右＝はい・左＝いいえ。110 ポイント未満は答えない。s20 の確かめ待ちと同じ）
    static func swipe(_ width: Double, threshold: Double = 110) -> Bool? {
        if width > threshold { return true }
        if width < -threshold { return false }
        return nil
    }

    /// 目安の分（1 枚 3 秒）
    static func minutes(_ count: Int) -> Int { max(1, (count * ReviewRules.secondsPerCard + 59) / 60) }
}

// MARK: - 軽1 色と印の説明・各画面の「?」の 2 行

enum S26UHelp {
    /// 画面の名前（countsOpen の名前と同じ）→ 2 行
    static let lines: [String: [String]] = [
        "today": ["録れているか・今日の三つ・今日の 1 問が上。ほかのカードは「ほかのカード」に畳んでいます。",
                  "よく変える設定とすきまの 1 件もここから。設定を開かなくて済むようにしています。"],
        "taskBook": ["やること・頼まれごと・約束を 1 つの一覧に。期限の近いものが上です。",
                     "機械が自動で閉じたものは「設定 → 機械がしたこと」から 1 タップで戻せます。"],
        "confirmBox": ["記録を正しくするために答えるもの。いちばん上の「答える山」から 1 枚 3 秒で答えられます。",
                       "1 日に聞くのは全部で 3 問（仮）まで。答えないものは期限が来れば静かに閉じます。"],
        "s26uPile": ["右に払うと「はい・合っている」、左は「いいえ・とばす」。音があれば自動で鳴ります。",
                     "今日の分（1 日 3 問・仮）が済んだら、ここで終わりにしてかまいません。"],
        "recordsDays": ["日ごとの会話の記録。押すとその日の会話と年表が開きます。",
                        "文字の直しは会話の中で。直した行は次からの聞き取りの材料になります。"],
        "lookBack": ["数で見る・今週のふり返り・見立てなど、自分をふり返るもの。",
                     "毎日見なくてもかまいません。週に 1 回ほどで十分です。"],
        "settings": ["点検は調子を見る所、設定は変える所です。上の切り替えで分けています。",
                     "よく変えるもの（録り方の組・場面）は「今日」からも変えられます。"],
        "diagnostics": ["赤は本人が動くもの、灰色・琥珀は待てば直るか機械が見ているものです。",
                        "本人が何もできない行は下の「機械が見ている行」に畳んでいます（消していません）。"],
        "s26uWaiting": ["機械ではできず、本人の操作が要るものを 1 件ずつ。開く先とコピーする文字が付いています。",
                        "済んだかは機械が見て、済んだものは下に移ります。"],
        "s26uMachine": ["機械が自動でしたこと（タスクを閉じた・直した・名前を付けた）の一覧です。",
                        "「戻す」を押すと、次の回に母艦が元に戻します（すぐには変わりません）。"],
    ]

    /// その画面の 2 行（無ければ空）
    static func of(_ screen: String) -> [String] { lines[screen] ?? [] }

    /// 色の説明（色の役割。s26 の 絵2 と同じ決め方）
    struct Legend: Equatable, Sendable {
        var tone: LLTone
        var color: String
        var meaning: String
    }

    static let legend: [Legend] = [
        Legend(tone: .act, color: "赤", meaning: "本人が動く（押す・許可する・入れ直す）"),
        Legend(tone: .warn, color: "オレンジ", meaning: "今日はお休み・待てば戻る（明日また動く）。本人は何もしなくてよい"),
        Legend(tone: .wait, color: "灰色", meaning: "待てば直る・まだ分からない"),
        Legend(tone: .ok, color: "緑", meaning: "良い（いつもどおり動いている）"),
    ]
}

// MARK: - 軽10 落ちる原因つぶし（書き込みをまとめる・本人が何もできない行を外す）

enum S26UWrite {
    /// 1 つのファイルに 1 日に書いてよい大きさのめど（バイト。仮 100MB）。iOS は 24 時間に 1GB を超えると「書き込みが多すぎた」にする
    static let dailyBudget = 100 * 1024 * 1024
    /// まとめて書く間の上限（秒。仮 30 分。落ちたときに失うのは、これだけのあいだの覚え足し）
    static let maxDelay: TimeInterval = 1800

    /// 次に書くまで待つ秒。前に書いた大きさから、1 日に書く量が dailyBudget に収まる間を出す（base より短くしない・maxDelay より長くしない）。
    /// 2026-11-22 の実機: 声の帳 650MB・録音の帳 486MB・クラウドの記録 367MB（どれも 2〜3 分まとめで）＝合わせて 1.5GB。
    /// 声の帳 1.4MB なら約 20 分、録音の帳 0.7MB なら約 10 分、クラウドの記録 0.5MB なら約 7 分になる
    static func delay(base: TimeInterval, lastBytes: Int, budget: Int = dailyBudget, maxDelay: TimeInterval = maxDelay) -> TimeInterval {
        guard lastBytes > 0, budget > 0 else { return base }
        let needed = 86400 * Double(lastBytes) / Double(budget)
        return min(max(base, needed), max(base, maxDelay))
    }
}

enum S26UCheckRows {
    /// 自己点検で、本人が何もできない ok でない行を畳む（画面の表示だけ。初めはオン。消さない）
    static let key = "s26u.foldNoAction"

    /// 畳む行か（ok でない・自分で直せる行ではない）
    static func folds(ok: Bool?, fix: CheckupFix) -> Bool { ok == false && fix != .self_ }
}

// MARK: - 軽5（K5）本人の操作待ち

struct S26UWaitingItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var steps: [String]? = nil
    var link: String? = nil
    var copy: String? = nil
    var done: Bool? = nil
    /// "now" | "later"（省ける。later は「あとでいいもの」に畳む。2026-11-28。s37 の K37-1。S37ARules.swift）
    var group: String? = nil

    var isDone: Bool { done == true }
}

// MARK: - 軽9（K4）機械がしたこと

struct S26UMachineAction: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var at: String? = nil
    /// task_closed・fix・name・other
    var kind: String? = nil
    var what: String
    var undo: Bool? = nil

    var canUndo: Bool { undo == true && HomeFeeds.isID(id) }

    var kindLabel: String {
        switch kind {
        case "task_closed": "タスクを閉じた"
        case "fix": "直した"
        case "name": "名前を付けた"
        default: "ほか"
        }
    }
}

// MARK: - 軽11（K6）すきまの 1 件

struct S26UGapTask: Codable, Equatable, Sendable {
    var from: String
    var to: String
    var task_id: String? = nil
    var text: String
    var minutes: Int? = nil
}

/// 家の PC から読む 3 つの写し（K4・K5・K6）。形はどれも {"version":1,"generated_at":ISO,"items":[...]}。
/// 読めない行は落とし、全部が読めなければ nil（前のまま）
enum S26UFeeds {
    struct Envelope<T: Decodable>: Decodable {
        var version: Int?
        var generated_at: String?
        var items: [Lossy<T>]?
    }

    /// 1 行だけ読めなくても、ほかの行は読む
    struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    static func items<T: Decodable>(_ type: T.Type, from data: Data) -> [T]? {
        guard let env = try? JSONDecoder().decode(Envelope<T>.self, from: data), let rows = env.items else { return nil }
        return rows.compactMap(\.value)
    }

    static func waiting(_ data: Data) -> [S26UWaitingItem]? {
        items(S26UWaitingItem.self, from: data)?.filter { HomeFeeds.isID($0.id) && !$0.title.isEmpty }
    }

    static func machine(_ data: Data) -> [S26UMachineAction]? {
        items(S26UMachineAction.self, from: data)?.filter { !$0.id.isEmpty && !$0.what.isEmpty }
    }

    static func gaps(_ data: Data) -> [S26UGapTask]? {
        items(S26UGapTask.self, from: data)?.filter { !$0.text.isEmpty }
    }

    /// 操作待ちの並び: まだのもの（届いた順）・済んだもの（届いた順）
    static func waitingOrder(_ items: [S26UWaitingItem]) -> (open: [S26UWaitingItem], done: [S26UWaitingItem]) {
        (items.filter { !$0.isDone }, items.filter(\.isDone))
    }

    /// 機械がしたことの並び（新しいものから。時刻の読めないものは後ろ）
    static func machineOrder(_ items: [S26UMachineAction]) -> [S26UMachineAction] {
        items.enumerated().sorted { a, b in
            let x = a.element.at.flatMap(PCJSON.date), y = b.element.at.flatMap(PCJSON.date)
            switch (x, y) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// 今の時刻に当たる 1 件（from ≦ いま < to。いくつもあれば早く終わるもの。無ければ nil）
    static func currentGap(_ items: [S26UGapTask], now: Date) -> S26UGapTask? {
        let hits: [(gap: S26UGapTask, to: Date)] = items.compactMap { g in
            guard let from = PCJSON.date(g.from), let to = PCJSON.date(g.to), from <= now, now < to else { return nil }
            return (g, to)
        }
        return hits.min { $0.to < $1.to }?.gap
    }

    /// 「戻す」の答え（POST /feedback の kind "undo"・value "undo"。取り決め K4。家の PC の FEEDBACK と同じ形）
    static func undoBody(id: String, day: String) -> Data? {
        guard HomeFeeds.isID(id), HomeFeeds.isDay(day) else { return nil }
        let object: [String: String] = ["kind": "undo", "id": id, "value": "undo", "day": day]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 開く先として使える道か（https・lifelog:// だけ。ほかは出さない）
    static func openable(_ link: String?) -> URL? {
        guard let link, let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return nil }
        return ["https", "lifelog", "prefs", "app-settings"].contains(scheme) ? url : nil
    }
}

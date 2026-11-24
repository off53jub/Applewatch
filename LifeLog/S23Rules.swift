import CoreLocation
import Foundation
import UserNotifications

// s23（2026-11-23）の決まり（通信しない・画面を持たない・テストする部分）。
// 知らせを押したあと迷わない（知1〜知14）・場所の質問（場1〜場6）・実機の確かめ（試1・試5〜試7）・版（届4・届8）・続5〜続7。
// 動きは S23Notices.swift、画面は S23Screens.swift。

// MARK: - 知1・知8・知9・知10 知らせの棚卸し（押すとどこが開くか・押すとどうなるかの 1 行・長押し・時計）

enum S23NoticeCatalog {
    enum Match: Equatable {
        /// 名前がこれと同じ
        case id(String)
        /// 名前がこれで始まる
        case prefix(String)
        /// カテゴリがこれと同じ
        case category(String)
    }

    struct Entry: Equatable, Identifiable {
        let match: Match
        /// 知らせの種類（画面に出す言い方）
        let title: String
        /// 押すとどうなるか（「押すと、」に続ける。。で終える）
        let tap: String
        /// 押したときに開く所（棚卸しの表）
        let opens: String
        /// 長押しでボタンが出る
        var buttons: Bool = false
        /// 時計に出た知らせから答えられるか（知10。実機で未確認）
        var watch: String = "見るだけ（押すと iPhone で開く）"
        /// 質問の知らせ（あとで・答えそびれ・押したのに答えなかった数の対象）
        var question: Bool = false

        var id: String {
            switch match {
            case .id(let s): "id:" + s
            case .prefix(let s): "prefix:" + s
            case .category(let s): "category:" + s
            }
        }
    }

    // カテゴリの名前（ほかのファイルの定数と同じ。テストで揃っているかを見る）
    static let s23CountCategory = "s23count"

    /// 全部の知らせ（2026-11-23 のコードを読んで作った。新しい知らせを足したら、ここにも 1 行足す。抜けは missing で探す）
    static let entries: [Entry] = [
        // カテゴリ（ボタンのある知らせ）を先に見る
        Entry(match: .category("taskFound"), title: "頼まれごとを見つけました", tap: "そのタスクが開きます。",
              opens: "そのタスクだけの画面（光る）", buttons: true, watch: "ボタンで答えられる（入れる・違う・2時間後）"),
        Entry(match: .category("taskDue"), title: "もうすぐ期限です", tap: "そのタスクが開きます。",
              opens: "そのタスクだけの画面（光る）", buttons: true, watch: "ボタンで答えられる（済み・1時間後・明日に）"),
        Entry(match: .category("workDigest"), title: "仕事のまとめ（退勤の頃）", tap: "取り込む画面が開きます。", opens: "仕事のまとめを取り込む画面"),
        Entry(match: .category("promise"), title: "会話のあとの約束", tap: "その約束が出ます。", opens: "その約束だけの画面",
              buttons: true, watch: "ボタンで答えられる（タスクに入れる・いらない）"),
        Entry(match: .category("placeAsk"), title: "ここは、どこですか？", tap: "名前を選べます。", opens: "答える画面（地図・候補・手がかり）",
              buttons: true, watch: "候補のボタンと、声・手書きで名前を入れられる", question: true),
        Entry(match: .category("knowYesNo"), title: "自分を知る（はい・いいえ）", tap: "その 1 問だけの画面が開きます。",
              opens: "その 1 問だけの画面", buttons: true, watch: "ボタンで答えられる（はい・いいえ・分からない）", question: true),
        Entry(match: .category("knowGeo"), title: "職場に着きました・出かけますか", tap: "今日が開きます。", opens: "今日",
              buttons: true, watch: "ボタンで録音を始められる"),
        Entry(match: .category("holidayPlace"), title: "さっきの所は〇〇？", tap: "答える画面が開きます。", opens: "答える画面（地図・候補）",
              buttons: true, watch: "ボタンで答えられる（はい・いいえ）", question: true),
        Entry(match: .category("holidayNote"), title: "休日の一言", tap: "一言を書く画面が開きます。", opens: "一言を書く画面",
              buttons: true, watch: "声・手書きで一言を入れられる", question: true),
        Entry(match: .category("s22review"), title: "確かめ待ち ○×", tap: "その問いの画面が開きます。", opens: "その問いだけの画面",
              buttons: true, watch: "ボタンで答えられる（○・×）", question: true),
        Entry(match: .category(s23CountCategory), title: "何人でしたか？", tap: "人数を選べます。", opens: "人数を選ぶ画面",
              buttons: true, watch: "ボタンで答えられる（2・3・4・5 人以上）", question: true),
        // 名前で見る
        Entry(match: .prefix("tasks-due-"), title: "もうすぐ期限です", tap: "そのタスクが開きます。", opens: "そのタスクだけの画面（光る）",
              buttons: true, watch: "ボタンで答えられる（済み・1時間後・明日に）"),
        Entry(match: .prefix("tasks-"), title: "朝夕の頼まれごと", tap: "タスクが開きます。", opens: "タスク"),
        Entry(match: .id("taskFound"), title: "頼まれごとを見つけました", tap: "そのタスクが開きます。", opens: "そのタスクだけの画面（光る）",
              buttons: true, watch: "ボタンで答えられる（入れる・違う・2時間後）"),
        Entry(match: .id("work-digest-reminder"), title: "仕事のまとめ（退勤の頃）", tap: "取り込む画面が開きます。", opens: "仕事のまとめを取り込む画面"),
        Entry(match: .prefix("brief-"), title: "会う前の 1 枚", tap: "この文をもう一度読めます。", opens: "知らせの文"),
        Entry(match: .id("morning-brief"), title: "朝の昨日と今日", tap: "今日が開きます。", opens: "今日"),
        Entry(match: .id("askQuestions"), title: "AI からの質問", tap: "質問の画面が開きます。", opens: "AI からの質問"),
        Entry(match: .id("good-tonight"), title: "いいこと帳の夜の 3 つ", tap: "いいこと帳が開きます。", opens: "いいこと帳"),
        Entry(match: .id("payments-monthly"), title: "PayPay の月初め", tap: "お金の画面が開きます。", opens: "お金"),
        Entry(match: .id("cloud-monthly"), title: "クラウドの使った量", tap: "その画面が開きます。", opens: "クラウドの記録"),
        Entry(match: .id("review-nudge"), title: "今日の聞いて直す", tap: "聞いて直す画面が開きます。", opens: "今日の聞いて直す"),
        Entry(match: .id("morning-check"), title: "朝の点検", tap: "自己点検が開きます。", opens: "自己点検"),
        Entry(match: .id("home-pc"), title: "家の PC", tap: "家の PC の画面が開きます。", opens: "家の PC"),
        Entry(match: .id("pc-silent"), title: "家の PC と話せていない", tap: "家の PC の画面が開きます。", opens: "家の PC"),
        Entry(match: .id("watch-silent"), title: "時計の録音が届いていません", tap: "いま何が起きていて、何を押せばいいかが出ます。",
              opens: "いまの様子の 1 枚"),
        Entry(match: .id("phone-stopped"), title: "iPhone の録音が止まった", tap: "いま何が起きていて、何を押せばいいかが出ます。",
              opens: "いまの様子の 1 枚"),
        Entry(match: .id("watch-battery"), title: "時計の電池", tap: "いま何が起きていて、何を押せばいいかが出ます。", opens: "いまの様子の 1 枚"),
        Entry(match: .id("stall"), title: "文字起こし待ちが溜まった", tap: "いま何が起きていて、何を押せばいいかが出ます。", opens: "いまの様子の 1 枚"),
        Entry(match: .id("watch-not-recording"), title: "時計が録音していない", tap: "いま何が起きていて、何を押せばいいかが出ます。",
              opens: "いまの様子の 1 枚"),
        Entry(match: .id("watch-open-after-update"), title: "時計を一度開いて", tap: "いま何が起きていて、何を押せばいいかが出ます。",
              opens: "いまの様子の 1 枚"),
        Entry(match: .prefix("fresh-"), title: "止まっているかも", tap: "今日が開きます。", opens: "今日"),
        Entry(match: .prefix("signExpiry-"), title: "署名の期限", tap: "今日が開きます。", opens: "今日"),
        Entry(match: .prefix("proposal-"), title: "家の PC からの提案", tap: "提案の画面が開きます。", opens: "提案"),
        Entry(match: .id("know-weekly-talk"), title: "5 分しゃべる振り返り", tap: "「直す」が開きます。", opens: "「直す」（自分を知る）"),
        Entry(match: .prefix("know-"), title: "自分を知る", tap: "その 1 問だけの画面が開きます。", opens: "その 1 問だけの画面", question: true),
        Entry(match: .id("holiday-leave"), title: "出かける前の点検", tap: "今日が開きます。", opens: "今日"),
        Entry(match: .prefix("holiday-place-"), title: "さっきの所は〇〇？", tap: "答える画面が開きます。", opens: "答える画面（地図・候補）",
              buttons: true, question: true),
        Entry(match: .prefix("holiday-"), title: "休日の一言", tap: "一言を書く画面が開きます。", opens: "一言を書く画面",
              buttons: true, watch: "声・手書きで一言を入れられる", question: true),
        Entry(match: .prefix("s22-review-"), title: "確かめ待ち ○×", tap: "その問いの画面が開きます。", opens: "その問いだけの画面",
              buttons: true, question: true),
        Entry(match: .prefix("s22-who-"), title: "誰と話しましたか？", tap: "その会話と名前の候補が出ます。", opens: "その会話と名前の候補",
              watch: "見るだけ（名前は iPhone で選ぶ）", question: true),
        Entry(match: .prefix("digest-"), title: "朝夕の便り", tap: "知らせの履歴が開きます。", opens: "知らせの履歴"),
        Entry(match: .id("notice-bundle"), title: "まとめた知らせ", tap: "今日が開きます。", opens: "今日"),
        Entry(match: .prefix("placeask-"), title: "ここは、どこですか？", tap: "名前を選べます。", opens: "答える画面（地図・候補・手がかり）",
              buttons: true, watch: "候補のボタンと、声・手書きで名前を入れられる", question: true),
        Entry(match: .prefix("placeremind-"), title: "着いた所のやること", tap: "そのタスクが開きます。", opens: "そのタスクだけの画面（光る）"),
        Entry(match: .id("night-mood"), title: "夜の 10 秒", tap: "今日が開きます。", opens: "今日（夜の 10 秒）"),
        Entry(match: .prefix("s23-count-"), title: "何人でしたか？", tap: "人数を選べます。", opens: "人数を選ぶ画面", buttons: true, question: true),
        Entry(match: .prefix("s23-places-"), title: "今日の名前の無い場所", tap: "地図と一緒に続けて答えられます。", opens: "今日の名前の無い場所"),
        Entry(match: .prefix("s23-version-"), title: "この版で動いたもの・まだのもの", tap: "確かめの一覧が開きます。", opens: "確かめてほしいこと"),
    ]

    /// 名前とカテゴリから、その知らせの行（カテゴリ → 同じ名前 → 長い頭の順）
    static func entry(identifier: String, category: String) -> Entry? {
        if !category.isEmpty, let hit = entries.first(where: { $0.match == .category(category) }) { return hit }
        if let hit = entries.first(where: { $0.match == .id(identifier) }) { return hit }
        var best: Entry?
        var bestLength = 0
        for e in entries {
            if case .prefix(let p) = e.match, identifier.hasPrefix(p), p.count > bestLength {
                best = e
                bestLength = p.count
            }
        }
        return best
    }

    /// 棚卸しの抜け: 行の無い知らせの名前（CI で抜けを探すときに使う純粋な関数。知8）
    static func missing(_ known: [(identifier: String, category: String)]) -> [String] {
        known.filter { entry(identifier: $0.identifier, category: $0.category) == nil }.map(\.identifier)
    }

    /// 知らせの文の終わりに「押すと、…」と「長押しで選べます」を足す（もう書いてあれば足さない。何度通しても同じ）
    static func decorate(body: String, entry: Entry) -> String {
        var add: [String] = []
        if !body.contains("押すと") { add.append("押すと、" + entry.tap) }
        if entry.buttons, !body.contains("長押し") { add.append("長押しで選べます。") }
        guard !add.isEmpty else { return body }
        let tail = add.joined()
        return body.isEmpty ? tail : body + "\n" + tail
    }

    /// 文に「押すと」の 1 行があるか（CI と画面の表で使う）
    static func hasTapLine(_ body: String) -> Bool { body.contains("押すと") }
}

// MARK: - 知2〜知7・知12 押したときの行き先（ボタンの名前・userInfo から決める）

enum S23Tap: Equatable {
    /// 知12 あとで（秒。nil は今夜）
    case snooze(TimeInterval?)
    /// 知2 誰と話した？（会話の始まりの秒）
    case who(String)
    /// 知4 自分を知るの 1 問
    case knowMe(id: String, kind: String, day: String?)
    /// 知6 確かめ待ちの 1 問
    case review(String)
    /// 知3 休日の「さっきの所は〇〇？」
    case holidayPlace(name: String, latitude: Double?, longitude: Double?, day: String?)
    /// 休日の一言（押しただけ）
    case holidayNote
    /// 知5 タスク・約束
    case tasks([String])
    case promises([String])
    /// 知7 いまの様子の 1 枚
    case status(String)
    /// 続5 何人でしたか（答え。nil は画面を開く）
    case headcount(start: Double, day: String, count: Int?)
    case tab(AppTab)
    /// 場4 今日の名前の無い場所
    case placesNight
    /// 届8 確かめてほしいこと
    case checklist
}

enum S23TapRules {
    static let laterAction = "s23.later"
    static let tonightAction = "s23.tonight"
    static let countActions: [(id: String, count: Int, title: String)] = [("s23.n2", 2, "2 人"), ("s23.n3", 3, "3 人"),
                                                                           ("s23.n4", 4, "4 人"), ("s23.n5", 5, "5 人以上")]
    static let statusIDs: Set<String> = ["watch-silent", "phone-stopped", "watch-battery", "stall", "watch-not-recording",
                                         "watch-open-after-update"]
    /// 「あとで」を足す質問のカテゴリ（ボタンが 4 つを超えない分だけ足す）
    static let laterCategories: Set<String> = ["knowYesNo", "s22review", "holidayPlace", "holidayNote"]
    static let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
    /// 今夜の時刻（21:00。仮）
    static let tonightHour = 21

    /// 押したもの（action）・知らせの名前・カテゴリ・userInfo から、s23 で受けるか。受けないものは nil（今までどおり）
    static func tap(identifier id: String, category: String, action: String, userInfo: [AnyHashable: Any]) -> S23Tap? {
        if action == laterAction { return .snooze(3600) }
        if action == tonightAction { return .snooze(nil) }
        if category == S23NoticeCatalog.s23CountCategory || id.hasPrefix("s23-count-") {
            guard let start = userInfo["start"] as? Double, let day = userInfo["day"] as? String else { return nil }
            if action == defaultAction { return .headcount(start: start, day: day, count: nil) }
            guard let hit = countActions.first(where: { $0.id == action }) else { return nil }
            return .headcount(start: start, day: day, count: hit.count)
        }
        // ここから下は、知らせそのものを押したときだけ
        guard action == defaultAction else { return nil }
        let ids: [String] = userInfo["ids"] as? [String] ?? []
        switch category {
        case "knowYesNo":
            guard let kid = userInfo["kid"] as? String, let kind = userInfo["kkind"] as? String else { return .tab(.fix) }
            return .knowMe(id: kid, kind: kind, day: userInfo["kday"] as? String)
        case "knowGeo":
            return .tab(.today)
        case "s22review":
            guard let rid = userInfo["id"] as? String else { return .tab(.fix) }
            return .review(rid)
        case "holidayPlace":
            guard let name = userInfo["hname"] as? String else { return nil }
            return .holidayPlace(name: name, latitude: userInfo["lat"] as? Double, longitude: userInfo["lon"] as? Double,
                                 day: userInfo["hday"] as? String)
        case "holidayNote":
            return userInfo["hkind"] is String ? .holidayNote : nil
        case "taskFound", "taskDue":
            return ids.isEmpty ? nil : .tasks(ids)
        case "promise":
            return ids.isEmpty ? nil : .promises(ids)
        default:
            break
        }
        guard category.isEmpty else { return nil }
        if statusIDs.contains(id) { return .status(id) }
        if id.hasPrefix("s22-who-") { return .who(String(id.dropFirst("s22-who-".count))) }
        if id.hasPrefix("tasks-") || id.hasPrefix("placeremind-") { return ids.isEmpty ? nil : .tasks(ids) }
        if id == "night-mood" { return .tab(.today) }
        if id.hasPrefix("s23-places-") { return .placesNight }
        if id.hasPrefix("s23-version-") { return .checklist }
        return nil
    }

    /// 「あとで」の待ち時間（秒）。今夜は 21:00 まで（もう 20 時を過ぎていれば 1 時間後）
    static func snoozeSeconds(_ value: TimeInterval?, now: Date, calendar: Calendar = .current) -> TimeInterval {
        if let value { return max(60, value) }
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = tonightHour
        c.minute = 0
        guard let tonight = calendar.date(from: c), tonight.timeIntervalSince(now) >= 3600 else { return 3600 }
        return tonight.timeIntervalSince(now)
    }

    /// 質問のカテゴリに「あとで（1 時間後）」「今夜」を足す（ボタンは 4 つまで。入りきらない分は足さない）
    static func laterActionsToAdd(existing: Int) -> [(id: String, title: String)] {
        let all: [(id: String, title: String)] = [(laterAction, "あとで（1 時間後）"), (tonightAction, "今夜もう一度")]
        let room = max(0, 4 - existing)
        return Array(all.prefix(room))
    }
}

// MARK: - 知7 いまの様子の 1 枚

enum S23StatusRules {
    struct Card: Equatable {
        var what: String
        var steps: [String]
        /// 「録音を始める」ボタンを出す
        var record: Bool
    }

    static func card(_ id: String) -> Card {
        switch id {
        case "watch-silent":
            Card(what: "時計から 10 分以上、録音が届いていません。", steps: [
                "時計の画面で LifeLog を開き、録音中かを見る",
                "iPhone から離れているだけなら、そのままで大丈夫です（あとでまとめて届きます）",
                "時計が使えないあいだは、下の「iPhone で録る」",
            ], record: true)
        case "phone-stopped":
            Card(what: "iPhone の録音が止まっています。", steps: [
                "下の「録音を始める」を押す",
                "何度も止まるときは「自己点検」で理由を見る",
            ], record: true)
        case "watch-battery":
            Card(what: "時計の電池が、もうすぐ切れそうです。", steps: [
                "時計を充電する",
                "充電のあいだは、PLAUD か iPhone で録る",
            ], record: true)
        case "stall":
            Card(what: "文字起こしを待っている音声が溜まっています。", steps: [
                "iPhone を充電につなぐ（充電中に進みます）",
                "しばらくアプリを開いたままにする",
            ], record: false)
        case "watch-not-recording":
            Card(what: "時計の LifeLog が録音していません。", steps: [
                "時計で LifeLog を開き、録音のボタンを押す",
                "時計が使えないあいだは、下の「iPhone で録る」",
            ], record: true)
        case "watch-open-after-update":
            Card(what: "時計の LifeLog が新しくなったあと、まだ開かれていません。", steps: [
                "時計で LifeLog を 1 回開く（開くと録音が戻ります）",
            ], record: false)
        case "urgent":
            // 家の PC からの急ぎ（取り決め C1。2026-11-24。s24 の 急3）
            Card(what: "家の PC から急ぎの知らせが来ました。", steps: [
                "知らせの文に書いてあることを先に見る",
                "録音が止まっていれば、下の「録音を始める」",
                "分からないときは「自己点検」で理由を見る",
            ], record: true)
        default:
            Card(what: "いまの様子を確かめてください。", steps: ["「自己点検」で理由を見る"], record: false)
        }
    }
}

// MARK: - 知11 押したのに答えずに閉じた数

enum S23TapStats {
    struct Row: Equatable, Identifiable {
        var kind: String
        var opened: Int
        var answered: Int
        var closed: Int
        var id: String { kind }
    }

    /// 閉じた数の多い順（同じなら開いた数の多い順）
    static func rows(_ saved: [String: Int]) -> [Row] {
        var kinds: [String] = []
        for key in saved.keys {
            guard let kind = key.split(separator: "|").first.map(String.init), !kinds.contains(kind) else { continue }
            kinds.append(kind)
        }
        let rows = kinds.map { k in
            Row(kind: k, opened: saved[k + "|opened"] ?? 0, answered: saved[k + "|answered"] ?? 0, closed: saved[k + "|closed"] ?? 0)
        }
        return rows.sorted { ($0.closed, $0.opened, $1.kind) > ($1.closed, $1.opened, $0.kind) }
    }
}

// MARK: - 知13 答えそびれた質問

struct S23MissedQuestion: Codable, Equatable, Identifiable {
    var id: String
    var category: String
    var title: String
    var body: String
    /// 文字・数・文字の並びだけ（JSON にできるもの）
    var info: [String: S23InfoValue]
    /// 出る時刻
    var at: Date
}

enum S23InfoValue: Codable, Equatable {
    case text(String)
    case number(Double)
    case texts([String])

    var any: Any {
        switch self {
        case .text(let s): s
        case .number(let n): n
        case .texts(let list): list
        }
    }
}

enum S23MissedRules {
    static let keepDays = 3
    static let limit = 30

    /// userInfo を残せる形に（文字・数・文字の並びだけ）
    static func info(_ userInfo: [AnyHashable: Any]) -> [String: S23InfoValue] {
        var out: [String: S23InfoValue] = [:]
        for (key, value) in userInfo {
            guard let k = key as? String else { continue }
            if let s = value as? String {
                out[k] = .text(s)
            } else if let list = value as? [String] {
                out[k] = .texts(list)
            } else if let n = value as? Double {
                out[k] = .number(n)
            } else if let n = value as? Int {
                out[k] = .number(Double(n))
            }
        }
        return out
    }

    static func userInfo(_ info: [String: S23InfoValue]) -> [AnyHashable: Any] {
        var out: [AnyHashable: Any] = [:]
        for (k, v) in info {
            // 何問目か（n）は Int で読む所があるので、整数に戻す
            if case .number(let n) = v, k == "n" { out[k] = Int(n) } else { out[k] = v.any }
        }
        return out
    }

    /// 足す（同じ名前は置き換える。古いもの・多すぎるものは捨てる）
    static func adding(_ list: [S23MissedQuestion], _ q: S23MissedQuestion, now: Date) -> [S23MissedQuestion] {
        var out = list.filter { $0.id != q.id }
        out.append(q)
        return pruned(out, now: now)
    }

    static func pruned(_ list: [S23MissedQuestion], now: Date) -> [S23MissedQuestion] {
        let oldest = now.addingTimeInterval(-Double(keepDays) * 86400)
        return Array(list.filter { $0.at >= oldest }.sorted { $0.at < $1.at }.suffix(limit))
    }

    /// もう出た（時刻を過ぎた）もの。新しい順
    static func due(_ list: [S23MissedQuestion], now: Date) -> [S23MissedQuestion] {
        list.filter { $0.at <= now }.sorted { $0.at > $1.at }
    }
}

// MARK: - 知14 答えたあとの 1 行

enum S23AfterRules {
    static func knowMe(_ value: String) -> String {
        value == "unsure" ? "「分からない」で送りました。この問いは、しばらく聞きません。"
            : "答えを送りました。次からの見立てと聞き方に使います。"
    }

    static func review(changed: Int?) -> String {
        if let changed, changed > 0 { return "この答えで、記録の \(changed) 行が直りました。" }
        return "答えを送りました。家の PC が次に読み直したとき、この答えで記録が直ります。"
    }

    static func who(_ name: String) -> String { "次からこの声は「\(name)」と出ます。" }

    static func place(_ name: String) -> String { "次からここは「\(name)」と出ます。" }

    static func headcount(_ count: Int) -> String {
        "\(count == 5 ? "5 人以上" : "\(count) 人")で残しました。声の数が多すぎる日は、家の PC がこの人数で見直します（仮）。"
    }

    static let note = "その日の一言として残しました。"
}

// MARK: - 場1〜場6 場所の質問

struct S23PlacePoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var name: String = ""
    var at: Date

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

enum S23PlaceRules {
    /// 場1 「ここは覚えなくていい」の半径（m。仮）
    static let ignoreRadius: Double = 150
    /// 場2 同じ名前を 2 回選んだ所の近く（m。仮）
    static let autoRadius: Double = 500
    static let autoMin = 2
    /// 場6 答えが少ないとき: 14 日で 10 回以上聞いて、答えが 3 割より少なければ、60 分いた所だけにする（仮）
    static let tightenMinAsked = 10
    static let tightenRate = 0.3
    static let tightAskAfter: TimeInterval = 3600

    /// 場1 覚えなくていい所の近くか
    static func isIgnored(_ list: [S23PlacePoint], latitude: Double, longitude: Double, radius: Double = ignoreRadius) -> Bool {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return list.contains { $0.location.distance(from: here) <= radius }
    }

    /// 場2 近くで同じ名前を 2 回以上選び、ほかの名前を選んだことが無ければ、その名前
    static func autoName(_ answers: [S23PlacePoint], latitude: Double, longitude: Double, radius: Double = autoRadius,
                         minimum: Int = autoMin) -> String? {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let near = answers.filter { $0.location.distance(from: here) <= radius && !$0.name.isEmpty }
        guard near.count >= minimum else { return nil }
        let keys = Set(near.map { ShopGuess.normalize($0.name) })
        guard keys.count == 1 else { return nil }
        return near.last?.name
    }

    /// 場6 聞く条件を絞るか
    static func shouldTighten(asked: Int, answered: Int) -> Bool {
        guard asked >= tightenMinAsked else { return false }
        return Double(answered) / Double(asked) < tightenRate
    }

    /// 場6 数の行（聞いた・ボタン・書いた・画面・答えなかった）
    struct Counts: Equatable {
        var asked = 0
        var button = 0
        var typed = 0
        var sheet = 0
        var cancelled = 0
        var answered: Int { button + typed + sheet }
        /// 出したのに答えなかった数（聞く前に離れて取り消した分は数えない）
        var ignored: Int { max(0, asked - cancelled - answered) }
    }

    static func counts(_ sums: [String: Int]) -> Counts {
        Counts(asked: sums["placeask.scheduled"] ?? 0, button: sums["placeask.answer.button"] ?? 0,
               typed: sums["placeask.answer.typed"] ?? 0, sheet: sums["placeask.sheet.answered"] ?? 0,
               cancelled: sums["placeask.cancelled"] ?? 0)
    }

    /// 場4 今日の分（始まりが今日のもの）
    static func today(_ stays: [UnnamedStay], now: Date, calendar: Calendar = .current) -> [UnnamedStay] {
        stays.filter { calendar.isDate($0.arrival, inSameDayAs: now) }.sorted { $0.arrival < $1.arrival }
    }

    /// 場4 夜に知らせる時刻か（21 時から 24 時まで。仮）
    static func isNightHour(_ now: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: now) >= 21
    }
}

// MARK: - 確かめ待ちの新しい kind（家の PC #104）

enum S23ReviewRules {
    /// 合っていれば「そのまま」で答えられる kind
    static let keepKinds: Set<String> = ["gold_noisy"]
    /// 「そのまま」の答え（家の PC へはこの文のまま送る）
    static let keepValue = "そのまま"

    static func keepAsIs(kind: String) -> Bool { keepKinds.contains(kind) }

    static func placeholder(kind: String) -> String { kind == "gold_noisy" ? "正しい文を打つ" : "ひとこと" }
}

// MARK: - 続5 何人でしたか

struct S23Headcount: Codable, Equatable {
    var day: String
    /// 会話の始まり（ISO 8601）
    var start: String
    var count: Int
}

enum S23HeadcountRules {
    /// 1 日に聞く数（仮）
    static let dailyCap = 2
    /// 聞く会話の長さ（10 分より長い。仮）
    static let minMinutes: Double = 10
    /// 会話が終わってから聞くまで（20 分以内。仮）
    static let within: TimeInterval = 20 * 60

    /// 聞くか（閉じた・長い・流していた音でない・自分以外の声がある・まだ聞いていない・1 日の上限の中）
    static func due(on: Bool, closed: Bool, start: Date, end: Date, media: Bool, otherLines: Int, alreadyAsked: Bool,
                    askedToday: Int, now: Date) -> Bool {
        guard on, closed, !media, !alreadyAsked, askedToday < dailyCap, otherLines >= 3 else { return false }
        guard end.timeIntervalSince(start) >= minMinutes * 60 else { return false }
        let since = now.timeIntervalSince(end)
        return since >= 0 && since <= within
    }

    /// 送る形（家の PC の inbox/headcount.jsonl の行と同じ {day, start, count}。数は 2〜30）
    static func row(day: String, start: Date, count: Int) -> S23Headcount? {
        guard HomeFeeds.isDay(day), (2...30).contains(count) else { return nil }
        return S23Headcount(day: day, start: ISO8601DateFormatter().string(from: start), count: count)
    }

    /// 家の PC の POST /headcount の中身 {"start", "count", "orMore"?, "day"}（5 人以上は count 5・orMore true。2026-11-23。#104）
    static func postBody(day: String, start: Date, count: Int) -> Data? {
        guard HomeFeeds.isDay(day), (1...30).contains(count) else { return nil }
        var body: [String: Any] = ["start": ISO8601DateFormatter().string(from: start), "count": count, "day": day]
        if count >= 5 { body["orMore"] = true }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// 同じ会話は最後の答えだけ・古いものは捨てる
    static func adding(_ list: [S23Headcount], _ row: S23Headcount, keep: Int = 200) -> [S23Headcount] {
        var out = list.filter { $0.start != row.start }
        out.append(row)
        return Array(out.suffix(keep))
    }
}

// MARK: - 続6 約束の知らせの出し方ごとの数

enum S23PromiseRules {
    struct Counts: Equatable {
        var shown = 0
        var noticeAdd = 0
        var noticeIgnore = 0
        var noticeOpen = 0
        var todayAdd = 0
        var todayIgnore = 0
    }

    static func counts(_ sums: [String: Int]) -> Counts {
        Counts(shown: sums["notice.shown.promise"] ?? 0, noticeAdd: sums["s23.promise.notice.add"] ?? 0,
               noticeIgnore: sums["s23.promise.notice.ignore"] ?? 0, noticeOpen: sums["s23.promise.notice.open"] ?? 0,
               todayAdd: sums["s23.promise.today.add"] ?? 0, todayIgnore: sums["s23.promise.today.ignore"] ?? 0)
    }

    /// 決める材料の 1 行（決めるのは本人。仮）
    static func advice(_ c: Counts) -> String {
        let added = c.noticeAdd + c.todayAdd
        let ignored = c.noticeIgnore + c.todayIgnore
        if c.shown + added + ignored < 10 { return "まだ数が少ないので、決める材料になりません（10 通を超えたら見てください）。" }
        if added == 0 { return "「入れる」が 1 回もありません。出し方を変えるか、知らせをやめる材料になります（仮）。" }
        if c.todayAdd > c.noticeAdd { return "知らせのボタンより「今日」の欄で入れることが多いです。知らせは減らしてもよいかもしれません（仮）。" }
        return "知らせから入れているものがあります。今のままでよさそうです（仮）。"
    }
}

// MARK: - 届4・届8 版

enum S23VersionRules {
    /// リリースの名前（v2026.11.23-512）からビルドの番号
    static func build(fromTag tag: String) -> Int? {
        guard let dash = tag.lastIndex(of: "-") else { return nil }
        return Int(tag[tag.index(after: dash)...])
    }

    /// いまより新しい版があれば、いちばん新しい番号（同期の相手・時計・GitHub のリリース）
    static func newer(current: Int, candidates: [Int?]) -> Int? {
        guard current > 0 else { return nil }
        let best = candidates.compactMap { $0 }.max() ?? 0
        return best > current ? best : nil
    }

    /// 届8: 版を上げた翌朝か（上げた日の次の日以降の 7 時から。3 日を過ぎたら出さない）
    static func morningDue(upgradedDay: String?, sentFor: Int?, build: Int, now: Date, calendar: Calendar = .current) -> Bool {
        guard let upgradedDay, sentFor != build, calendar.component(.hour, from: now) >= 7 else { return false }
        let today = ReviewRules.dayKey(now, calendar: calendar)
        guard today > upgradedDay else { return false }
        let limit = ReviewRules.dayKey(now.addingTimeInterval(-3 * 86400), calendar: calendar)
        return upgradedDay >= limit
    }

    /// 届8 の文
    static func morningText(build: Int, ran: [String], notYet: [String]) -> (title: String, body: String) {
        func names(_ list: [String]) -> String {
            let head = list.prefix(3).joined(separator: "・")
            return list.count > 3 ? head + " など" : head
        }
        var lines: [String] = []
        lines.append(ran.isEmpty ? "動いたもの: まだありません" : "動いたもの \(ran.count) 個: " + names(ran))
        lines.append(notYet.isEmpty ? "まだのもの: ありません" : "まだのもの \(notYet.count) 個: " + names(notYet))
        return ("版 \(build) で動いたもの・まだのもの", lines.joined(separator: "\n"))
    }
}

// MARK: - 試1・試5・試6・試7 実機の確かめ

enum S23CheckRules {
    /// 試1: 確かめてほしいことの id → 動いた証拠（"tally:名前"・"tally:頭*"・"ns:種類|できごと"・"watch:same"）
    static let evidenceMap: [String: [String]] = [
        "found-notice-buttons": ["ns:taskFound|keep", "ns:taskFound|reject"],
        "notice-open-tasks": ["ns:taskFound|open"],
        "due-hour": ["ns:taskDue|done", "ns:taskDue|tomorrow", "ns:taskDue|hour"],
        "s21-shake": ["tally:s21.shake"],
        "s21-preset": ["tally:s21.preset.*"],
        "s22-checkup-top": ["tally:screen.diagnostics"],
        "s22-ask-claude": ["tally:s22.askClaude"],
        "s22-watch-resend": ["tally:s22.watchResendNow"],
        "s22-watch-version": ["watch:same"],
        "s22-notice-review": ["tally:s22.review.notice"],
        "s22-watch-review": ["tally:s22.review.watch"],
        "s22-widget-review": ["tally:s22.review.widget"],
        "s22-siri": ["tally:s22.intent.pause30", "tally:s22.intent.today"],
        "s22-scene-card": ["tally:s22.sceneCard.share"],
        "s23-tap-sheets": ["tally:s23.sheet.answered"],
        "s23-later": ["tally:s23.snooze.*"],
        "s23-headcount": ["tally:s23.headcount.answered"],
        "s23-place-forget": ["tally:s23.place.ignored"],
        "s23-places-night": ["tally:s23.placesNight.answered"],
        "s23-version-banner": ["tally:s23.version.openTestFlight"],
        "s23-version-morning": ["tally:s23.version.morning.opened"],
        "s23-missed": ["tally:s23.missed.answered"],
    ]

    /// 試6: 時計がらみの確かめ（時計の版が古いあいだは「時計を新しくしてから」に畳む）
    static let watchItems: Set<String> = ["watch-page-order", "s21-watch-today", "s21-sleep-chunks", "s22-watch-resend",
                                          "s22-watch-version", "s22-watch-review", "s22-double-tap"]

    /// 試1: 証拠が 1 つでも 1 以上なら ○。まだ片づけていないものだけ
    static func autoPassed(sums: [String: Int], notice: [String: Int], watchSame: Bool, done: [String: String],
                           evidence: [String: [String]] = evidenceMap) -> [String] {
        var out: [String] = []
        for (id, keys) in evidence where done[id] == nil {
            if keys.contains(where: { hit($0, sums: sums, notice: notice, watchSame: watchSame) }) { out.append(id) }
        }
        return out.sorted()
    }

    static func hit(_ key: String, sums: [String: Int], notice: [String: Int], watchSame: Bool) -> Bool {
        if key == "watch:same" { return watchSame }
        if key.hasPrefix("ns:") { return (notice[String(key.dropFirst(3))] ?? 0) > 0 }
        guard key.hasPrefix("tally:") else { return false }
        let name = String(key.dropFirst(6))
        if name.hasSuffix("*") {
            let head = String(name.dropLast())
            return sums.contains { $0.key.hasPrefix(head) && $0.value > 0 }
        }
        return (sums[name] ?? 0) > 0
    }

    /// 試5: 今日の 1 つ（日ごとに決まる。同じ日なら同じもの）
    static func pickToday(_ ids: [String], day: String) -> String? {
        guard !ids.isEmpty else { return nil }
        var seed = 0
        for scalar in day.unicodeScalars { seed = (seed &* 31 &+ Int(scalar.value)) & 0x7fff_ffff }
        return ids[seed % ids.count]
    }

    /// 試7: 動かなかった確かめを「Claude に頼む」文に（人の名前・中身は入らない。確かめの題と確かめ方だけ）
    static func askClaudeText(failed: [(title: String, how: String)], phoneBuild: Int, watchBuild: String?) -> String {
        var lines: [String] = []
        lines.append("LifeLog（iPhone の版 \(phoneBuild)" + (watchBuild.map { "・時計の版 \($0)" } ?? "") + "）の実機の確かめで、動かなかったものがあります。")
        for (i, f) in failed.enumerated() {
            lines.append("\(i + 1). " + f.title)
            lines.append("   確かめ方: " + String(f.how.prefix(160)))
        }
        lines.append("どこを直せばよいか、やさしい言葉で教えてください。")
        return lines.joined(separator: "\n")
    }

    /// 試7: 自己点検の「Claude に頼む」に足す行
    static func failedLines(_ titles: [String]) -> [String] {
        guard !titles.isEmpty else { return [] }
        return ["実機の確かめで動かなかったもの: " + titles.prefix(5).joined(separator: "・") + (titles.count > 5 ? " など" : "")]
    }
}

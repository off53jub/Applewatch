import Foundation

// s37（2026-11-28）アプリ担当 S37A の決まり。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 28」（手2・手3・手4・精6）。
// 取り決め（形を変えない。どれも省ける欄）:
// - K37-1: state/waiting_for_app.json（GET /waiting）の items に `group`: "now" | "later"。later は畳んだ別の箱に出す（消さない）。無ければ今のまま
// - K37-2: state/review_queue_for_app.json（GET /review-queue）の一番上に `daily_max`（整数）。1 日に出す問いをこれ以下に。無ければ今の数。
//          daily_max があるときは、並びは母艦の順のまま（アプリは並べ替えない）
// - K37-3: state/s36_for_app.json（GET /s36）の stop.items に `recommend`: true|false。「おすすめどおり止める」で true のもの全部に
//          今の POST /s36/stop（choice stop）を 1 件ずつ送る。欄が無い（true が 1 つも無い）ときはボタンを出さない
// - K37-4（精6）: 知らせの taskFound・promise のうち、仕事のもの（職場の会話・仕事の台帳から来たもの）は出さない。
//          設定「仕事のタスク・約束も知らせる」（初めはオフ）で戻せる。帳・一覧・台帳には今までどおり入る（知らせだけ止める）

// MARK: - K37-1 操作待ちの「あとでいいもの」

enum S37AWaiting {
    /// later か（"later" のときだけ。大文字・前後の空白は見ない）
    static func isLater(_ group: String?) -> Bool {
        (group ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "later"
    }

    /// まだのものを、今要るもの・あとでいいものに分ける（どちらも届いた順。group が無ければ全部「今」）
    static func split(_ open: [S26UWaitingItem]) -> (now: [S26UWaitingItem], later: [S26UWaitingItem]) {
        (open.filter { !isLater($0.group) }, open.filter { isLater($0.group) })
    }
}

// MARK: - K37-2 確かめの問いの 1 日の数

enum S37AReview {
    /// 母艦の daily_max（0 以上の整数だけ。おかしな値は無いのと同じ）
    static func dailyMax(_ feed: ReviewQueueFeed?) -> Int? {
        guard let n = feed?.daily_max, n >= 0 else { return nil }
        return n
    }

    /// 今日もう答えた・「あとで」にした数（その日の印で数える）
    static func usedToday(answered: [String: String], later: [String: String], today: String) -> Int {
        var ids: Set<String> = []
        for (id, day) in answered where day == today { ids.insert(id) }
        for (id, day) in later where day == today { ids.insert(id) }
        return ids.count
    }

    /// 1 日に出す数を daily_max 以下に（今日すでに使った分は引く）。dailyMax が無ければそのまま
    static func limited<T>(_ items: [T], dailyMax: Int?, used: Int) -> [T] {
        guard let dailyMax else { return items }
        let left = max(0, dailyMax - max(0, used))
        return left >= items.count ? items : Array(items.prefix(left))
    }

    /// daily_max があるときの列: 同じ人か・期限だけで落とし、母艦の順のまま（並べ替えない）
    static func mothershipOrder(_ items: [ReviewItem], samePersonAsk: Bool, today: String) -> [ReviewItem] {
        items.filter { (samePersonAsk || !S24AskRules.samePersonKinds.contains($0.kind))
            && S24AskRules.alive(expires: $0.expires, today: today) }
    }
}

// MARK: - K37-3 おすすめどおり止める

enum S37AStop {
    /// おすすめ（recommend が true）の候補（並びはそのまま）
    static func recommended(_ candidates: [S36AStopItem]) -> [S36AStopItem] {
        candidates.filter { $0.recommend == true }
    }

    /// ボタンを出すか（recommend の欄が無い・true が 1 つも無いときは出さない）
    static func showsBulk(_ candidates: [S36AStopItem]) -> Bool { !recommended(candidates).isEmpty }

    /// 確かめの文（件数と題の一覧。多いときは titleLimit 件まで並べて「ほか N 件」）
    static let titleLimit = 15

    static func confirmTitle(_ items: [S36AStopItem]) -> String { "おすすめの \(items.count) 件を止めますか？" }

    static func confirmMessage(_ items: [S36AStopItem]) -> String {
        var lines: [String] = []
        for item in items.prefix(titleLimit) { lines.append("・" + item.title) }
        if items.count > titleLimit { lines.append("ほか \(items.count - titleLimit) 件") }
        lines.append("1 件ずつ家の PC に伝えます。あとで 1 件ずつ戻せます。")
        return lines.joined(separator: "\n")
    }

    /// 送ったあとの 1 行（画面の中だけに出す。知らせにはしない）
    static func resultNote(sent: Int, failed: Int) -> String {
        if failed == 0 { return "おすすめの \(sent) 件を止めると伝えました。" }
        if sent == 0 { return "\(failed) 件とも伝えられませんでした（家の PC につながっていないかもしれません）。" }
        return "止めると伝えた \(sent) 件・伝えられなかった \(failed) 件。伝えられなかったものは候補に残っています。"
    }
}

// MARK: - K37-4（精6）仕事のタスク・約束の知らせ

enum S37AWorkNotice {
    /// 設定「仕事のタスク・約束も知らせる」（初めはオフ）
    static let key = "s37a.workNotice"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// 仕事のものか: 仕事の印（work が true＝職場の会話・仕事の時間に拾った・仕事に入れた）か、仕事のまとめ（仕事の台帳）の宿題。
    /// 印の無い古いもの（work が nil）は、知らせでは仕事とみなさない（LINE・手で書いたもの・写真を止めないため）
    static func isWork(_ item: TaskBook.Item) -> Bool {
        item.work == true || item.digestDay != nil
    }

    /// 知らせに出すもの（オンなら全部。オフなら仕事のものを外す）
    static func notifiable(_ items: [TaskBook.Item], workOn: Bool) -> [TaskBook.Item] {
        workOn ? items : items.filter { !isWork($0) }
    }

    /// 約束の知らせ（家の PC から。userInfo の ids）を止めるか: オフで、ids が全部わかっていて、全部が仕事のもの。
    /// 写しにまだ無い id があるときは止めない（仕事以外を落とさないため）
    static func silencesPromise(ids: [String], workIDs: Set<String>, knownIDs: Set<String>, workOn: Bool) -> Bool {
        guard !workOn, !ids.isEmpty else { return false }
        return ids.allSatisfy { knownIDs.contains($0) && workIDs.contains($0) }
    }

    /// 約束の知らせの ids（userInfo["ids"]。文字の列だけ）
    static func promiseIDs(_ userInfo: [AnyHashable: Any]) -> [String] {
        (userInfo["ids"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    // 家の PC から届いた約束の写しの id（仕事のもの・全部）。知らせを受ける所（主の糸でなくてもよい）から読むので、鍵をかけて持つ
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: Set<String> = []
    nonisolated(unsafe) private static var work: Set<String> = []

    static func remember(_ items: [PromiseItem]) {
        let all = Set(items.map(\.id))
        let w = Set(items.filter { $0.work == true }.map(\.id))
        lock.withLock {
            known = all
            work = w
        }
    }

    static func snapshot() -> (known: Set<String>, work: Set<String>) {
        lock.withLock { (known, work) }
    }
}

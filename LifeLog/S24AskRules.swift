import Foundation
import UserNotifications

// s24（2026-11-24）の決まり（通信しない・画面を持たない・テストする部分）。案は母艦の docs/system-proposal-2026-11-13.md の「追記 13」。
// 溜めない: タスクの候補を 1 日 3 件に（本人の困りごと）・問いの全体の上限（減1）・問いの並び（減2）・期限（減3）・数を出さない（減4）・
// 約束の知らせ（減5）・見つけた知らせを夜に 1 通（減6）・知らせ全体の上限（減7）・開いた数（減8）・やることの棚（減9）・
// 「今週は聞かないで」（減10）・急ぎの知らせ（急3・取り決め C1）・同じ人か（当1・C4）・時計に出す知らせ（形6）・題の印（形7）。
// 動きは S24Book.swift、画面は S24Views.swift。しきい値はどれも仮。

// MARK: - 設定の名前（UserDefaults）

enum S24AskSettings {
    /// 減1 本人に聞く問いの、全部を合わせた 1 日の上限（仮 3。設定で 1〜10）
    static let questionCapKey = "s24.questionCap"
    static let questionCapDefault = 3
    /// 減5 約束の知らせ（取り決め C5。初めはオフ。台帳と一覧の材料は残す）
    static let promiseNoticeKey = "s24.promiseNotice"
    /// 減6 「頼まれごとを見つけた」を夜の 1 通にまとめる（初めはオン）
    static let foundNightKey = "s24.foundNight"
    /// 減7 知らせ全体の 1 日の上限（初めはオン。数は仮 5）
    static let dailyCapOnKey = "s24.dailyCapOn"
    /// 減10 「今週は聞かないで」の終わり（1970 からの秒。0 か無ければ止めていない）
    static let quietUntilKey = "s24.quietUntil"
    /// 当1 「同じ人か」の問いを出す（取り決め C4。初めはオフ）
    static let samePersonAskKey = "s24.samePersonAsk"
    /// 形6 時計を震わせるのは録音・期限・急ぎだけ（ほかは静かに届ける。初めはオン）
    static let watchQuietKey = "s24.watchQuiet"
    /// 形7 知らせの題の頭に種類の印（初めはオン）
    static let marksKey = "s24.marks"
    /// 本人の困りごと: タスクの候補を「今日の候補」3 件に絞る（初めはオン。オフで前のように全部並べる）
    static let candidateTodayKey = "s24.candidateToday"

    static let defaults: [String: Bool] = [promiseNoticeKey: false, foundNightKey: true, dailyCapOnKey: true, samePersonAskKey: false,
                                           watchQuietKey: true, marksKey: true, candidateTodayKey: true]

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaults[key] ?? false
    }

    static var questionCap: Int {
        let saved = UserDefaults.standard.object(forKey: questionCapKey) as? Int ?? questionCapDefault
        return S24AskRules.clampCap(saved)
    }

    static var quietUntil: Date? {
        let t = UserDefaults.standard.double(forKey: quietUntilKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}

// MARK: - 本人の困りごと・減6 タスクの候補

enum S24TaskRules {
    /// 片方のモデルだけが拾った候補（たぶん違う）を静かに閉じるまでの日数（仮 2）
    static let weakDays: Double = 2
    /// 候補の残る日数（仮 3。前は 7）
    static let candidateDays: Double = 3
    /// 1 日に見せる候補の数（仮 3）
    static let dailyShow = 3
    /// 本人の発話とみなす近さ（秒。仮 120）
    static let ownSpeechWindow: TimeInterval = 120
    /// 対象が特定できない言い方（これだけのもの・これより短いもの）
    static let vagueWhats: Set<String> = ["確認", "確認する", "対応", "対応する", "やる", "やっておく", "検討", "検討する", "連絡", "連絡する",
                                          "準備", "準備する", "調べる", "見る", "考える", "送る", "返事", "返事する", "相談", "相談する"]
    static let vagueMinLength = 4

    /// 「たぶん違う」に畳む候補か。会話から拾ったもので、片方のモデルだけが拾ったか、母艦と同じ条件に足りないもの。
    /// 両方が拾ったもの・★・議事録・写真・手で書いた・1 日のまとめから来たものは今まで通り
    nonisolated static func isWeak(_ item: TaskBook.Item) -> Bool {
        guard item.state == .candidate, item.source == .conversation else { return false }
        if item.agreed == true { return false }
        return item.agreed == false || item.weakReason != nil
    }

    /// 母艦と同じ見つける条件（主語が本人・対象が特定できる・本人の発話）に足りない所。足りていれば nil。
    /// 主語は言語モデルへの頼み方（Summarizer.tasks の「本人に関わる」）で見ているので、ここでは対象と本人の発話を見る
    nonisolated static func ownerCheck(what: String, selfSpokeNear: Bool) -> String? {
        let s = what.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selfSpokeNear { return "notOwn" }
        if s.count < vagueMinLength || vagueWhats.contains(s) { return "vague" }
        return nil
    }

    /// その時刻の前後に本人の行があるか
    nonisolated static func selfSpoke(near time: Date, selfTimes: [Date], window: TimeInterval = ownSpeechWindow) -> Bool {
        selfTimes.contains { abs($0.timeIntervalSince(time)) <= window }
    }

    /// 「たぶん違う」のまま weakDays たったもの（拾った時刻・最後に触った時刻のどちらからも）
    nonisolated static func weakExpired(_ items: [TaskBook.Item], now: Date, days: Double = weakDays) -> [TaskBook.Item] {
        let limit = now.addingTimeInterval(-days * 86400)
        return items.filter { isWeak($0) && max($0.said, $0.updated) < limit }
    }

    /// 今日の候補を選ぶ。saved は "yyyy-MM-dd|id,id,…"（今日すでに見せたもの。答えたものも入ったまま＝1 日に見せるのは cap 件まで）。
    /// strong は、たぶん違うを除いた候補（見せたい順）。返すのは、今日見せる id（まだ候補のもの）と覚えておく文
    nonisolated static func todayPicks(strong: [TaskBook.Item], saved: String?, day: String,
                                       cap: Int = dailyShow) -> (ids: [String], save: String) {
        var picked: [String] = []
        if let saved, saved.hasPrefix(day + "|") {
            picked = saved.dropFirst(day.count + 1).split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
        let alive = Set(strong.map(\.id))
        for item in strong where picked.count < cap && !picked.contains(item.id) { picked.append(item.id) }
        let show = picked.filter { alive.contains($0) }
        return (show, day + "|" + picked.joined(separator: ","))
    }

    /// 候補を 3 つに分ける: 今日の候補（ids の順）・残り（畳む）・たぶん違う（畳む）
    nonisolated static func split(_ candidates: [TaskBook.Item], today ids: [String])
        -> (today: [TaskBook.Item], rest: [TaskBook.Item], weak: [TaskBook.Item]) {
        let weak = candidates.filter { isWeak($0) }
        let strong = candidates.filter { !isWeak($0) }
        var today: [TaskBook.Item] = []
        for id in ids { if let hit = strong.first(where: { $0.id == id }) { today.append(hit) } }
        let shown = Set(today.map(\.id))
        return (today, strong.filter { !shown.contains($0.id) }, weak)
    }

    /// 夜の 1 通の時刻（仮 20:30）。今日の時刻を過ぎていれば明日
    static let nightMinutes = 20 * 60 + 30

    nonisolated static func nightSlot(after now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(nightMinutes * 60))
        return today > now.addingTimeInterval(30) ? today : today.addingTimeInterval(86400)
    }

    /// 夜の 1 通の題と文（数は出さない。3 件まで並べる）。並べるものが無ければ nil
    nonisolated static func nightNotice(_ items: [TaskBook.Item]) -> (title: String, body: String)? {
        let shown = items.filter { !isWeak($0) && ($0.state == .candidate || $0.state == .open) }
        guard !shown.isEmpty else { return nil }
        var lines: [String] = []
        for item in shown.prefix(3) {
            var note = ""
            if let from = item.from, !from.isEmpty { note = "（" + from + "）" }
            lines.append("・" + item.what + note)
        }
        if shown.count > 3 { lines.append("ほかにもあります（タスクの「今日の候補」で）") }
        return ("今日見つけた頼まれごと", lines.joined(separator: "\n"))
    }

    /// 夜の 1 通にためる id（同じ日のものだけ。saved は "yyyy-MM-dd|id,id,…"）
    nonisolated static func addNight(_ ids: [String], saved: String?, day: String, keep: Int = 30) -> (ids: [String], save: String) {
        var list: [String] = []
        if let saved, saved.hasPrefix(day + "|") {
            list = saved.dropFirst(day.count + 1).split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
        for id in ids where !list.contains(id) { list.append(id) }
        list = Array(list.suffix(keep))
        return (list, day + "|" + list.joined(separator: ","))
    }
}

// MARK: - 減1・減7・減10・形6・形7 知らせの道

enum S24NoticeRules {
    /// 知らせの種類（形7 の印・形6 の時計・減7 の別枠・減10 の止め方を決める）
    enum Lane: String, CaseIterable {
        /// 録音が止まった系（別枠・時計にも出す・止めない）
        case recording
        /// 期限（別枠・時計にも出す・止めない）
        case due
        /// 家の PC からの急ぎ（取り決め C1。別枠・時計にも出す・止めない）
        case urgent
        /// 本人に聞く問い（減1 の上限・減10 で止める）
        case question
        /// それ以外の便り（減7 の上限・減10 で止める）
        case letter
    }

    /// 知らせ全体の 1 日の上限（仮 5。録音・期限・急ぎは別枠）
    static let dailyCap = 5

    static let recordingIDs: Set<String> = ["phone-stopped", "watch-silent", "watch-not-recording", "not-recording", "stopped",
                                            "watch-battery", "stall", "pc-silent", "watch-open-after-update", "s23-resumed"]
    static let recordingPrefixes: [String] = ["fresh-"]
    static let dueCategories: Set<String> = ["taskDue"]
    static let duePrefixes: [String] = ["tasks-due-", "signExpiry-"]

    /// 名前・カテゴリ（と、家の PC からの知らせなら中身）から種類を決める
    static func lane(identifier id: String, category: String, userInfo: [AnyHashable: Any] = [:]) -> Lane {
        if S24Urgent.isUrgent(userInfo) { return .urgent }
        if recordingIDs.contains(id) || recordingPrefixes.contains(where: { id.hasPrefix($0) }) { return .recording }
        if dueCategories.contains(category) || duePrefixes.contains(where: { id.hasPrefix($0) }) { return .due }
        if S23NoticeCatalog.entry(identifier: id, category: category)?.question == true { return .question }
        return .letter
    }

    /// 別枠（上限に数えない・止めない）か
    static func isPriority(_ lane: Lane) -> Bool { lane == .recording || lane == .due || lane == .urgent }

    /// 形7 題の頭の印（急ぎは家の PC が題を書くので付けない）
    static func mark(_ lane: Lane) -> String? {
        switch lane {
        case .recording: "録音"
        case .due: "期限"
        case .question: "問い"
        case .letter: "便り"
        case .urgent: nil
        }
    }

    /// 印を付けた題（もう印があれば足さない。何度通しても同じ）
    static func marked(_ title: String, lane: Lane) -> String {
        guard let mark = mark(lane) else { return title }
        if title.hasPrefix("【") { return title }
        return "【" + mark + "】" + title
    }

    /// 形6 時計を震わせないか（録音・期限・急ぎ以外は静かに届ける。iPhone の通知センターには残る）
    static func quietOnWatch(_ lane: Lane) -> Bool { !isPriority(lane) }

    /// 入口で決めたこと
    enum Decision: Equatable {
        /// そのまま出す
        case pass
        /// 出さない（問いは箱に残る。理由は tally に）
        case drop(String)
        /// 便りに回す（減7）
        case hold
    }

    /// 入口で決める。asked は今日すでに出した問いの数、shown は今日すでに出した別枠でない知らせの数（すぐ出すものだけ数える）
    static func decide(lane: Lane, immediate: Bool, asked: Int, shown: Int, questionCap: Int, dailyCapOn: Bool,
                       quiet: Bool) -> Decision {
        if isPriority(lane) { return .pass }
        if quiet { return .drop("quiet") }
        if lane == .question {
            if asked >= questionCap { return .drop("questionCap") }
            if dailyCapOn, immediate, shown >= dailyCap { return .drop("dailyCap") }
            return .pass
        }
        if dailyCapOn, immediate, shown >= dailyCap { return .hold }
        return .pass
    }
}

// MARK: - 減1・減2・減3・減4・当1 問い

enum S24AskRules {
    /// 「同じ人か」の問いの種類（母艦の確かめ待ちの kind）
    static let samePersonKinds: Set<String> = ["voice_pair"]

    /// 上限は 1〜10
    static func clampCap(_ n: Int) -> Int { max(1, min(10, n)) }

    /// 減3 期限（"yyyy-MM-dd"）が過ぎていないか。無い・読めないものは生きている
    static func alive(expires: String?, today: String) -> Bool {
        guard let e = expires?.trimmingCharacters(in: .whitespaces), e.count == 10 else { return true }
        return e >= today
    }

    /// 減2 「1 つの答えで直る行が多い順」。数（impact）があるものを多い順に先へ、無いものは今の順のまま後ろに
    static func byImpact<T>(_ items: [T], impact: (T) -> Int?) -> [T] {
        var known: [(offset: Int, n: Int, item: T)] = []
        var unknown: [T] = []
        for (i, item) in items.enumerated() {
            if let n = impact(item), n > 0 { known.append((i, n, item)) } else { unknown.append(item) }
        }
        known.sort { $0.n != $1.n ? $0.n > $1.n : $0.offset < $1.offset }
        return known.map(\.item) + unknown
    }

    /// 確かめ待ちの列（当1 で同じ人かを外し、減3 で期限を見て、減2 で並べる）
    static func reviewItems(_ items: [ReviewItem], samePersonAsk: Bool, today: String) -> [ReviewItem] {
        let kept = items.filter { (samePersonAsk || !samePersonKinds.contains($0.kind)) && alive(expires: $0.expires, today: today) }
        return byImpact(kept) { $0.impact }
    }

    /// 減1・減4 タブの数字: 今日の上限を超えない（今日すでに聞いた分は引く）
    static func badge(_ base: Int, cap: Int, asked: Int) -> Int {
        max(0, min(base, cap - asked))
    }

    /// 今日あと何問か
    static func left(cap: Int, asked: Int) -> Int { max(0, cap - asked) }

    /// その日の印の集まり（saved は "yyyy-MM-dd|a,b,…"。日が変われば空から。同じ印は 1 つ）
    static func daySet(adding keys: [String], saved: String?, day: String, keep: Int = 200) -> (ids: [String], save: String) {
        var list: [String] = []
        if let saved, saved.hasPrefix(day + "|") {
            list = saved.dropFirst(day.count + 1).split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
        for raw in keys where !raw.isEmpty {
            let key = raw.replacingOccurrences(of: ",", with: "_")
            if !list.contains(key) { list.append(key) }
        }
        list = Array(list.suffix(keep))
        return (list, day + "|" + list.joined(separator: ","))
    }
}

// MARK: - 減10 今週は聞かないで

enum S24Quiet {
    static let days: Double = 7

    static func active(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    static func until(from now: Date) -> Date { now.addingTimeInterval(days * 86400) }
}

// MARK: - 急3 家の PC からの急ぎ（取り決め C1）

enum S24Urgent {
    static let kind = "urgent"

    /// 中身が {"lifelog": {"kind": "urgent", "key": …}} か
    static func isUrgent(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let info = userInfo["lifelog"] as? [String: Any] else { return false }
        return (info["kind"] as? String) == kind
    }

    static func key(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let info = userInfo["lifelog"] as? [String: Any], let key = info["key"] as? String, !key.isEmpty else { return nil }
        return key
    }
}

// MARK: - 減8 開いた数

enum S24Opened {
    /// 知らせそのものを押した（ボタンではない）か
    static func isOpen(action: String) -> Bool { action == S23TapRules.defaultAction }

    /// 同じ知らせを 2 回数えない印
    static func key(identifier: String, date: Date) -> String { NoticeBundle.key(identifier: identifier, date: date) }
}

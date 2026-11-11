import Foundation
import Observation
import SwiftUI
import PhotosUI
import UIKit
import UserNotifications
import ImageIO
import Vision

/// 頼まれごと帳。仕事で頼まれたこと・引き受けたことを1か所にため、済むまで追いかける。
/// 2026-11-07 から、仕事以外（家族・友だち・お店などとの会話）のやること・約束も同じ帳に入れ、`work` で「仕事」と「仕事以外」に分ける。
/// 会話（仕事中・仕事以外・★を付けた会話）・議事録の宿題から拾ったものは「確かめ待ち」に入り、本人が「入れる」と決めたものだけ帳に載る。
/// ★の近くで拾ったもの・手で書いたものは、はじめから帳に載る。写真から読み取ったものは確かめ待ち。
/// 中身は `tasks.json` に端末ごとに持つ（同期はしない）。iPhone はドライブの「頼まれごと帳」と同期フォルダの「頼まれごと帳.json」にも写す。
@MainActor
@Observable
final class TaskBook {
    enum State: String, Codable {
        /// 拾ったが、まだ本人が確かめていない
        case candidate
        /// まだ済んでいない
        case open
        case done
        /// 頼まれごとではなかった（同じものをまた出さないよう、印だけ残す）
        case rejected
    }

    /// 「違う」にした理由（2026-11-10）。数がたまれば、次にどこを直すかが分かる
    enum RejectReason: String, CaseIterable, Identifiable {
        /// AI・音声アシスタント・アプリ・機械に向けて言ったこと
        case machine
        /// もう済んでいる
        case finished
        /// 自分のことではない（ほかの人のやること）
        case notMine
        /// 話題・感想・報告だけ
        case topic
        case other
        /// 確かめ待ちのまま7日たった（自動で片づけた。学びには使わない）
        case expired
        /// 知らせの「違う」を押した
        case notice
        /// 確かめ待ちを「全部違う」にした
        case bulk

        var id: String { rawValue }

        var label: String {
            switch self {
            case .machine: "機械に言ったこと"
            case .finished: "もう済んでいる"
            case .notMine: "自分のことではない"
            case .topic: "話題・感想・報告だけ"
            case .other: "そのほか"
            case .expired: "7日そのまま（自動）"
            case .notice: "知らせから「違う」"
            case .bulk: "まとめて「違う」"
            }
        }

        /// 本人が選べる理由
        static var choices: [RejectReason] { [.machine, .finished, .notMine, .topic, .other] }
    }

    enum Source: String, Codable {
        case conversation, mark, minutes, manual, photo, summary

        var label: String {
            switch self {
            case .conversation: "会話から"
            case .mark: "★から"
            case .minutes: "議事録から"
            case .manual: "手で書いた"
            case .photo: "写真から"
            case .summary: "1日のまとめから"
            }
        }
    }

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        var what: String
        /// 頼んだ人
        var from: String? = nil
        /// 期限の言い方（「来週の頭まで」など、聞いたまま）
        var dueText: String? = nil
        /// 期限の日（その日の0時）
        var due: Date? = nil
        /// 言われた時刻（手で書いたときは書いた時刻）
        var said: Date
        /// 拾った会話の日（DayView で開く）
        var day: String? = nil
        var place: String? = nil
        /// 根拠の発言・もとの文字
        var quote: String? = nil
        /// その場面の音声（▶︎で聞く）
        var audio: String? = nil
        var offset: TimeInterval? = nil
        var source: Source
        var state: State
        /// 仕事のものか（仕事中に拾った・仕事に入れた）。false は仕事以外。nil（古いもの）は仕事とみなす（isWork）
        var work: Bool? = nil
        /// 自分用のメモ
        var memo: String? = nil
        var doneAt: Date? = nil
        var updated: Date = .now
        /// 種類（無ければ、頼んだ人がいるか・拾ったものなら「頼まれた」、手で書いたものは「自分で」）
        var kind: Kind? = nil
        /// まだのものの進み具合（無ければ未着手）
        var progress: Progress? = nil
        /// 急ぎ・大事
        var urgent: Bool? = nil
        /// 期限を延ばした回数
        var postponed: Int? = nil
        /// 期限の時刻（0時からの分。無ければ日付だけ。2026-11-06）
        var dueTime: Int? = nil
        /// 繰り返し（済みにしたら、次の回を作る。2026-11-06）
        var repeats: Repeat? = nil
        /// iPhone のリマインダーに送ったときの、その項目の id
        var reminderID: String? = nil
        /// 2つの言語モデルが両方拾った（true）・片方だけ（false）・見比べていない（nil）。2026-11-06
        var agreed: Bool? = nil
        /// 確かめ待ちから、本人が採った・却下した（頼まれごとの候補の学びに使う。2026-11-06。前の記録には無い）
        var fromCandidate: Bool? = nil
        /// 「違う」にした理由（RejectReason の名前。2026-11-10。前の記録には無い。知らない名前でも読めるよう、文字のまま持つ）
        var rejectReason: String? = nil
        /// ほかの入り口でも見つかった（「仕事のまとめ 2026-11-10」など。2026-11-10）
        var alsoIn: String? = nil

        /// 入り口の言い方。仕事のまとめの宿題は「1日のまとめ」と同じ印（summary）なので、文で見分ける
        var originLabel: String {
            digestDay != nil ? "仕事のまとめから（チャットで来た頼み）" : source.label
        }

        /// 仕事のまとめの宿題なら、そのまとめの日（quote の「仕事のまとめ（yyyy-MM-dd）の宿題」から読む）
        var digestDay: String? {
            guard source == .summary, let quote, quote.hasPrefix("仕事のまとめ（") else { return nil }
            let rest = quote.dropFirst("仕事のまとめ（".count)
            guard let end = rest.firstIndex(of: "）") else { return nil }
            let day = String(rest[..<end])
            return day.count == 10 ? day : nil
        }

        /// 時刻まで入れた期限
        var dueMoment: Date? {
            guard let due else { return nil }
            return dueTime.map { due.addingTimeInterval(TimeInterval($0 * 60)) } ?? due
        }

        var kindOrDefault: Kind {
            if let kind { return kind }
            return source == .manual && from == nil ? .mine : .asked
        }

        /// 相手を待っているもの（人に頼んだもの・「待ち」にしたもの）
        var isWaiting: Bool { progress == .waiting || (kindOrDefault == .delegated && progress != .started) }

        /// 仕事のものか。印の無い古いもの（work が nil）は仕事とみなす（ほぼ仕事の時間に拾ったもの。2026-11-07）
        nonisolated var isWork: Bool { work ?? true }
    }

    /// タスクタブの「仕事｜仕事以外｜全部」（2026-11-07）
    enum Scope: String, CaseIterable, Identifiable {
        case work, life, all

        nonisolated var id: String { rawValue }

        nonisolated var label: String {
            switch self {
            case .work: "仕事"
            case .life: "仕事以外"
            case .all: "全部"
            }
        }

        nonisolated func includes(_ item: Item) -> Bool {
            switch self {
            case .work: item.isWork
            case .life: !item.isWork
            case .all: true
            }
        }
    }

    /// その方のものだけにする（並びはそのまま）
    nonisolated static func filter(_ items: [Item], _ scope: Scope) -> [Item] {
        scope == .all ? items : items.filter { scope.includes($0) }
    }

    /// 1つの方の、ページごとの一覧
    struct Lists {
        var candidates: [Item]
        var todo: [Item]
        var waiting: [Item]
        var open: [Item]
        var done: [Item]
        /// まだのもの・確かめ待ちの数（切り替えの数字）
        var count: Int { open.count + candidates.count }
    }

    func lists(_ scope: Scope) -> Lists {
        let open = Self.filter(self.open, scope)
        return Lists(candidates: Self.filter(candidates, scope), todo: open.filter { !$0.isWaiting },
                     waiting: open.filter(\.isWaiting), open: open, done: Self.filter(done, scope))
    }

    /// 繰り返し
    enum Repeat: String, Codable, CaseIterable, Identifiable {
        case daily, weekdays, weekly, monthly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: "毎日"
            case .weekdays: "平日"
            case .weekly: "毎週"
            case .monthly: "毎月"
            }
        }

        /// 次の回の期限の日（from はいまの期限の日か、無ければ今日）
        func next(after from: Date, calendar: Calendar = .current) -> Date {
            let day = calendar.startOfDay(for: from)
            switch self {
            case .daily:
                return calendar.date(byAdding: .day, value: 1, to: day) ?? day
            case .weekdays:
                var next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                while calendar.isDateInWeekend(next) { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next }
                return next
            case .weekly:
                return calendar.date(byAdding: .day, value: 7, to: day) ?? day
            case .monthly:
                return calendar.date(byAdding: .month, value: 1, to: day) ?? day
            }
        }
    }

    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// ほかの人から頼まれた・引き受けた
        case asked
        /// 自分でやると決めた
        case mine
        /// 本人がほかの人に頼んだ（相手の返事・結果を待つ）
        case delegated
        /// 会う・連絡するなどの約束
        case promise

        var id: String { rawValue }

        var label: String {
            switch self {
            case .asked: "頼まれた"
            case .mine: "自分で"
            case .delegated: "人に頼んだ"
            case .promise: "約束"
            }
        }

        /// 相手の欄の名前
        var partyLabel: String {
            switch self {
            case .asked: "頼んだ人"
            case .mine: "関わる人"
            case .delegated: "頼んだ相手"
            case .promise: "約束した相手"
            }
        }

        var symbol: String {
            switch self {
            case .asked: "tray.and.arrow.down"
            case .mine: "person"
            case .delegated: "arrow.turn.up.right"
            case .promise: "handshake"
            }
        }

        /// 言語モデルの答え（asked / mine / delegated / promise）から
        nonisolated static func parse(_ text: String) -> Kind? {
            Kind(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    enum Progress: String, Codable, CaseIterable, Identifiable {
        case started, waiting

        var id: String { rawValue }

        var label: String {
            switch self {
            case .started: "進行中"
            case .waiting: "待ち"
            }
        }
    }

    /// タスクタブの並び
    enum Bucket: Int, CaseIterable, Comparable {
        case late, today, week, later, someday

        var title: String {
            switch self {
            case .late: "期限切れ"
            case .today: "今日"
            case .week: "今週（7日以内）"
            case .later: "それより先"
            case .someday: "期限なし"
            }
        }

        static func < (a: Bucket, b: Bucket) -> Bool { a.rawValue < b.rawValue }
    }

    private(set) var items: [Item] = []
    /// 中身が変わるたびに増える（知らせとドライブの写しを作り直す目安）
    private(set) var version = 0

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("tasks.json")

    /// 確かめ待ち（新しいものから）
    /// 確かめ待ち。2つの言語モデルが両方拾ったものを先に（2026-11-06）、その中は新しい順
    var candidates: [Item] {
        // 採用・却下から学んだら、採りそうな順（2026-11-06）
        if let weights = TaskLearning.weights {
            return items.filter { $0.state == .candidate }.sorted { a, b in
                let x = TaskLearning.acceptChance(a, weights: weights) ?? 0, y = TaskLearning.acceptChance(b, weights: weights) ?? 0
                return x != y ? x > y : a.said > b.said
            }
        }
        return items.filter { $0.state == .candidate }.sorted { a, b in
            let x = a.agreed == true ? 0 : a.agreed == false ? 2 : 1
            let y = b.agreed == true ? 0 : b.agreed == false ? 2 : 1
            return x != y ? x < y : a.said > b.said
        }
    }
    /// まだ済んでいないもの（期限の近い順。期限の無いものは後ろに、言われた順）
    var open: [Item] { items.filter { $0.state == .open }.sorted(by: Self.dueOrder) }
    /// 済んだもの（30日以内・新しいものから）
    var done: [Item] {
        let since = Date.now.addingTimeInterval(-30 * 86400)
        return items.filter { $0.state == .done && ($0.doneAt ?? $0.updated) >= since }
            .sorted { ($0.doneAt ?? $0.updated) > ($1.doneAt ?? $1.updated) }
    }

    /// やるもの（待っているもの以外のまだのもの）
    var todo: [Item] { open.filter { !$0.isWaiting } }
    /// 相手を待っているもの（期限の近い順）
    var waiting: [Item] { open.filter(\.isWaiting) }

    /// 期限で分ける（急ぎは同じ並びの中で前に）
    nonisolated static func bucket(_ item: Item, now: Date = .now, calendar: Calendar = .current) -> Bucket {
        guard let due = item.due else { return .someday }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch days {
        case ..<0: return .late
        case 0: return .today
        case 1...7: return .week
        default: return .later
        }
    }

    nonisolated static func grouped(_ items: [Item], now: Date = .now) -> [(bucket: Bucket, items: [Item])] {
        let groups = Dictionary(grouping: items) { bucket($0, now: now) }
        return Bucket.allCases.compactMap { b in
            guard let list = groups[b], !list.isEmpty else { return nil }
            let sorted = list.sorted { x, y in
                let ux = x.urgent == true, uy = y.urgent == true
                return ux != uy ? ux : dueOrder(x, y)
            }
            return (b, sorted)
        }
    }

    /// 相手ごと（相手の無いものは除く。名前の順）
    nonisolated static func byPerson(_ items: [Item]) -> [(person: String, items: [Item])] {
        let named = items.filter { !($0.from ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        let groups = Dictionary(grouping: named) { $0.from!.trimmingCharacters(in: .whitespaces) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted(by: dueOrder)) }
    }

    /// 延ばした先の期限（今日から days 日後の0時）
    nonisolated static func postponedDue(days: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
    }

    /// 「来週」＝次の月曜（今日が月曜なら7日後）
    nonisolated static func nextWeekDays(now: Date = .now, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: now)  // 1 = 日曜
        let toMonday = (9 - weekday) % 7
        return toMonday == 0 ? 7 : toMonday
    }

    nonisolated static func dueOrder(_ a: Item, _ b: Item) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?): return x == y ? a.said < b.said : x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.said < b.said
        }
    }

    init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        } else {
            // 読めないファイルは上書きせず、脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("tasks-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    /// 足す。同じ日の・まだ生きている・前に「違う」にした、よく似たものがあれば足さない。足したものを返す。
    @discardableResult
    func add(_ new: [Item]) -> [Item] {
        var added: [Item] = []
        for item in new {
            let what = item.what.trimmingCharacters(in: .whitespacesAndNewlines)
            // 言語モデルが、頼んだ文の書き方をそのまま返したものは入れない（2026-11-10。本人が手で書いたものは見ない）
            guard !what.isEmpty, item.source == .manual || !Self.isPromptEcho(what) else { continue }
            let duplicate = (items + added).contains { old in
                let comparable = old.state == .candidate || old.state == .open || old.state == .rejected
                    || (old.day != nil && old.day == item.day)
                return comparable && Self.similar(old.what, what)
            }
            guard !duplicate else { continue }
            var copy = item
            copy.what = what
            added.append(copy)
        }
        guard !added.isEmpty else { return [] }
        items += added
        save()
        return added
    }

    /// 言語モデルに渡した「書き方」の文（「やること（何を・どうする、を短く）」など）が、そのまま返ってきたものか（2026-11-10）。
    /// 中身の無いものなので、帳には入れない
    nonisolated static func isPromptEcho(_ what: String) -> Bool {
        let s: String = what.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole: Set<String> = ["やること", "やること・頼んだこと・約束", "...", "…"]
        if whole.contains(s) { return true }
        let parts: [String] = ["何を・どうする、を短く", "分からなければ空）", "無ければ空）", "期限があれば添える", "まだ残っていそうなもの"]
        return parts.contains { s.contains($0) }
    }

    /// 期限の言い方を整える（2026-11-10）。空・「なし」「未定」など・頼んだ文の書き方がそのまま返ってきたものは nil
    nonisolated static func cleanDue(_ text: String) -> String? {
        let s: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let none: Set<String> = ["", "なし", "無し", "特になし", "期限なし", "未定", "不明", "空", "-", "—", "null"]
        guard !none.contains(s), !s.contains("分からなければ空"), !s.contains("無ければ空") else { return nil }
        return s
    }

    func update(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        var copy = item
        copy.updated = .now
        if items[i].state == .candidate && copy.state != .candidate { copy.fromCandidate = true }
        items[i] = copy
        save()
    }

    func set(_ id: String, _ state: State) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let wasDone = items[i].state == .done
        if items[i].state == .candidate && state != .candidate { items[i].fromCandidate = true }
        items[i].state = state
        items[i].doneAt = state == .done ? .now : nil
        items[i].updated = .now
        // 繰り返しのものは、済みにしたら次の回を作る
        if state == .done, !wasDone, let next = Self.nextRepeat(of: items[i]) { items.append(next) }
        save()
    }

    /// 「違う」にして、理由を残す（2026-11-10）
    func reject(_ id: String, reason: RejectReason) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        // 自動で片づけたものは、本人が決めたものではないので学びに使わない
        if items[i].state == .candidate && reason != .expired { items[i].fromCandidate = true }
        items[i].state = .rejected
        items[i].rejectReason = reason.rawValue
        items[i].doneAt = nil
        items[i].updated = .now
        save()
    }

    /// 確かめ待ちを、まとめて「違う」にする。数を返す（2026-11-10）
    @discardableResult
    func rejectAll(_ ids: [String], reason: RejectReason) -> Int {
        var n = 0
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .candidate else { continue }
            if reason != .expired { items[i].fromCandidate = true }
            items[i].state = .rejected
            items[i].rejectReason = reason.rawValue
            items[i].updated = .now
            n += 1
        }
        if n > 0 { save() }
        return n
    }

    /// 確かめ待ちのまま7日たったもの（拾った時刻・最後に触った時刻のどちらからも7日）
    nonisolated static func expired(_ items: [Item], now: Date = .now, days: Double = 7) -> [Item] {
        let limit = now.addingTimeInterval(-days * 86400)
        return items.filter { $0.state == .candidate && max($0.said, $0.updated) < limit }
    }

    /// 確かめ待ちのまま7日たったものを、静かに片づける（「違う」にして、理由は「7日そのまま」。学びには使わない）
    @discardableResult
    func expireCandidates(now: Date = .now) -> Int {
        rejectAll(Self.expired(items, now: now).map(\.id), reason: .expired)
    }

    /// ほかの入り口でも見つかったことを残す。確かめ待ちなら「やる」に入れる（2026-11-10）
    func confirm(_ id: String, alsoIn: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].state == .candidate {
            items[i].state = .open
            items[i].fromCandidate = true
        }
        items[i].alsoIn = alsoIn
        items[i].updated = .now
        save()
    }

    /// 期限の手がかりになる言葉があるか（日付・曜日・「明日」「来週」「〜まで」「15時」など。2026-11-10）。
    /// 1日のまとめの「やること」は、これがあるものだけ確かめ待ちに入れる
    nonisolated static func hasDueCue(_ text: String) -> Bool {
        let words: [String] = ["今日", "きょう", "明日", "あした", "あす", "明後日", "あさって", "今週", "来週", "再来週", "週末",
                               "今月", "来月", "月末", "月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜",
                               "まで", "締め切り", "締切", "〆切", "期限", "午前", "午後", "朝イチ", "夕方", "今夜", "今晩"]
        if words.contains(where: { text.contains($0) }) { return true }
        let patterns: [String] = ["[0-9０-９]{1,2}[/／月][0-9０-９]{1,2}", "[0-9０-９]{1,2}時", "[0-9０-９]{1,2}:[0-9]{2}", "[0-9０-９]{1,2}日"]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// 繰り返しのものの、次の回（期限は次の日付・時刻は同じ・済みや延期は消す）
    static func nextRepeat(of item: Item, now: Date = .now) -> Item? {
        guard let rule = item.repeats else { return nil }
        var next = item
        next.id = UUID().uuidString
        next.state = .open
        next.doneAt = nil
        next.postponed = nil
        next.progress = nil
        next.reminderID = nil
        next.said = now
        next.updated = now
        // 前の期限が過ぎていたら、今日から数える
        let base = max(item.due ?? now, Calendar.current.startOfDay(for: now))
        next.due = rule.next(after: base)
        return next
    }

    /// 期限を今日から days 日後に延ばす
    func postpone(_ id: String, days: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].due = Self.postponedDue(days: days)
        items[i].postponed = (items[i].postponed ?? 0) + 1
        items[i].updated = .now
        save()
    }

    /// 進み具合を変える（nil で未着手に戻す）
    func setProgress(_ id: String, _ progress: Progress?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].progress = progress
        items[i].updated = .now
        save()
    }

    func setUrgent(_ id: String, _ urgent: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].urgent = urgent ? true : nil
        items[i].updated = .now
        save()
    }

    /// 手で書いたものを取り消す（拾ったものは「違う」にして印を残す）
    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        version += 1
        // 済んで・違うにして半年たったものは捨てる
        let old = Date.now.addingTimeInterval(-180 * 86400)
        items.removeAll { ($0.state == .done || $0.state == .rejected) && $0.updated < old }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    // MARK: - 似ているか

    /// 比べるための形（空白・句読点・「〜する」の揺れを除く）
    nonisolated static func key(_ text: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        var s = String(String.UnicodeScalarView(text.unicodeScalars.filter { !drop.contains($0) }))
        for tail in ["しておきます", "しておく", "ておきます", "ておく", "します", "ました", "ます", "する"]
            where s.hasSuffix(tail) && s.count > tail.count + 1 {
            s = String(s.dropLast(tail.count))
            break
        }
        return s
    }

    /// 同じ頼まれごとらしいか（片方がもう片方を含むか、2文字ずつの重なりが6割以上）
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        let x = key(a), y = key(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        if min(x.count, y.count) >= 4 && (x.contains(y) || y.contains(x)) { return true }
        func grams(_ s: String) -> Set<String> {
            let c = Array(s)
            guard c.count >= 2 else { return [s] }
            return Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
        }
        let g = grams(x), h = grams(y)
        return Double(g.intersection(h).count) / Double(g.union(h).count) >= 0.6
    }

    nonisolated static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 「2026-11-05」→ その日の0時（読めなければ nil）
    nonisolated static func dueDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 10 else { return nil }
        return dayFormat.date(from: trimmed)
    }
}

// MARK: - 拾う・知らせる・写す

extension Pipeline {
    static let taskRemindKey = "taskRemind"
    /// 知らせる時刻（0時からの分）。朝8時と18時
    static let taskMorningKey = "taskMorning"
    static let taskEveningKey = "taskEvening"
    private static let taskScannedKey = "taskScanned"
    private static let taskNotifyPrefix = "tasks-"
    private static let taskBookHashKey = "taskBookWritten"

    static var taskRemindOn: Bool { UserDefaults.standard.object(forKey: taskRemindKey) as? Bool ?? true }
    /// 期限に時刻があるものを、1時間前に知らせる（2026-11-10。初めはオン）
    static let taskDueHourKey = "taskDueHour"
    static var taskDueHourOn: Bool { UserDefaults.standard.object(forKey: taskDueHourKey) as? Bool ?? true }

    /// 期限の1時間前に知らせるもの（時刻のある・まだの・人を待っていないもの。近い順に10件まで）と、知らせる時刻
    static func dueHourNotices(_ open: [TaskBook.Item], now: Date, limit: Int = 10) -> [(at: Date, item: TaskBook.Item)] {
        var out: [(at: Date, item: TaskBook.Item)] = []
        for item in open where item.state == .open && item.dueTime != nil && !item.isWaiting {
            guard let moment = item.dueMoment else { continue }
            let at = moment.addingTimeInterval(-3600)
            guard at > now.addingTimeInterval(30), at < now.addingTimeInterval(7 * 86400) else { continue }
            out.append((at, item))
        }
        return Array(out.sorted { $0.at < $1.at }.prefix(limit))
    }

    /// 期限の1時間前の知らせの文（「・資料を送る（Aさんから）\n15:00 まで」）
    static func dueHourBody(_ item: TaskBook.Item) -> String {
        var notes: [String] = []
        if let from = item.from, !from.isEmpty {
            switch item.kindOrDefault {
            case .delegated: notes.append(from + "へ")
            case .promise: notes.append(from + "と")
            case .asked, .mine: notes.append(from + "から")
            }
        }
        var body = "・" + item.what + (notes.isEmpty ? "" : "（" + notes.joined(separator: "・") + "）")
        if let moment = item.dueMoment { body += "\n" + taskClock.string(from: moment) + " まで" }
        return body
    }

    /// 休みの日（土日・祝日・有休など）は何も知らせない（2026-11-06 に土日で始め、2026-11-07 から休みの日全部。名前はそのまま）
    static let taskWeekendOffKey = "taskWeekendOff"
    static var taskWeekendOff: Bool { UserDefaults.standard.bool(forKey: taskWeekendOffKey) }
    /// タスクタブの数字を、期限切れ（今日までを含む）だけにする（2026-11-06。既定は確かめ待ちも足す）
    static let taskBadgeLateOnlyKey = "taskBadgeLateOnly"
    static var taskMorning: Int { UserDefaults.standard.object(forKey: taskMorningKey) as? Int ?? 8 * 60 }
    static var taskEvening: Int { UserDefaults.standard.object(forKey: taskEveningKey) as? Int ?? 18 * 60 }

    private static let taskClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 仕事の時間か（職場にいた時間か、休みでない日の8時〜19時。職場の場所を登録していなくても拾えるように）。
    /// 休みの日（土日・祝日・有休など）の8〜19時は、職場にいなければ仕事の時間とみなさない（2026-11-07）
    func taskTime(_ time: Date) -> Bool {
        if isWorkTime(time) { return true }
        let hour = Calendar.current.component(.hour, from: time)
        return hour >= 8 && hour < 19 && !isDayOff(time)
    }

    /// ★の無い仕事以外の会話からも拾うか（2026-11-09 から初めはオフ。外ればかりだったため）
    static let lifeAutoKey = "taskLifeAuto"
    static var lifeAuto: Bool { UserDefaults.standard.bool(forKey: lifeAutoKey) }

    /// 仕事以外の会話を見る数（無料枠を使い切らないように。1回に2つ・1日に10まで。2026-11-07）
    static let taskLifePerRun = 2
    static let taskLifePerDay = 10
    private static let taskLifeCountKey = "taskLifeCount"

    /// 今日あといくつ仕事以外の会話を見てよいか（saved は「yyyy-MM-dd|数」）
    static func taskLifeLeft(saved: String?, today: String) -> Int {
        guard let saved, saved.hasPrefix(today + "|"), let used = Int(saved.dropFirst(today.count + 1)) else { return taskLifePerDay }
        return max(0, taskLifePerDay - used)
    }

    /// 閉じた会話（直近3日）から、やること・約束を拾う。
    /// 仕事の時間の会話（ほかの人の行があるもの）と★を付けた会話は1回に3つまで。
    /// 仕事以外の会話は★を付けたものだけ（2026-11-09。★の無い仕事以外の会話から拾った13件が、すべて「違う」だったため。
    /// 前は1回に2つ・1日に10まで見ていた）。
    /// 仕事の時間の会話は「職場の会話は端末内で」のとき外に送らない。仕事以外の会話は、ほかの仕事以外の会話と同じ扱い。
    /// 同じ会話は1回だけ見る（言語モデルが使えなかったときは、次の機会にやり直す）。
    func findTasks() async {
        guard let key = llmKey else { return }
        var scanned = UserDefaults.standard.stringArray(forKey: Self.taskScannedKey) ?? []
        defer { UserDefaults.standard.set(Array(scanned.suffix(800)), forKey: Self.taskScannedKey) }
        let today = TaskBook.dayFormat.string(from: .now)
        var lifeUsed = Self.taskLifePerDay - Self.taskLifeLeft(saved: UserDefaults.standard.string(forKey: Self.taskLifeCountKey),
                                                               today: today)
        defer { UserDefaults.standard.set(today + "|" + String(lifeUsed), forKey: Self.taskLifeCountKey) }
        var budget = 3
        var lifeBudget = min(Self.taskLifePerRun, Self.taskLifePerDay - lifeUsed)
        var found: [TaskBook.Item] = []
        scan: for day in recordedDays().prefix(3) {
            for c in conversations(on: day) where c.closed && c.media == nil {
                guard budget > 0 || lifeBudget > 0 else { break scan }
                let id = day + "|" + String(Int(c.start.timeIntervalSince1970))
                guard !scanned.contains(id) else { continue }
                let lines = c.lines.filter { $0.media == nil }
                let marks = lines.filter { $0.marked == true }
                let work = taskTime(c.start)
                // ほかの人の行が無い会話（ひとりごと）は、★が無ければ見ない
                let others = lines.contains { $0.speakerID != SpeakerLabeler.selfID }
                // 仕事以外の会話は、本人も話しているものだけ（周りの人どうしの話・テレビは見ない）
                let selfSpoke = lines.contains { $0.speakerID == SpeakerLabeler.selfID }
                let workTalk = work && others && lines.count >= 3
                // ★の無い仕事以外の会話は見ない（2026-11-09）。lifeAuto をオンにしたときだけ前のように見る
                let lifeTalk = Self.lifeAuto && !work && others && selfSpoke && lines.count >= 4
                guard !marks.isEmpty || workTalk || lifeTalk else {
                    scanned.append(id)
                    continue
                }
                // ★の無い仕事以外の会話は、仕事以外の分の上限で数える（足りなければ次の機会に）
                let life = marks.isEmpty && !work
                if life {
                    guard lifeBudget > 0 else { continue }
                    lifeBudget -= 1
                    lifeUsed += 1
                } else {
                    guard budget > 0 else { continue }
                    budget -= 1
                }
                let transcript = lines.map { line in
                    Self.taskClock.string(from: line.time) + " " + (line.speaker.map { "[\($0)] " } ?? "") + line.promptText
                }.joined(separator: "\n")
                let result: [Summarizer.FoundTask]
                do {
                    result = try await Summarizer.$sensitive.withValue(work) {
                        try await Summarizer.tasks(transcript, day: day, apiKey: key)
                    }
                } catch {
                    break scan
                }
                scanned.append(id)
                var items = taskItems(result, in: c, lines: lines, marks: marks, day: day, work: work)
                // もとの会話に根拠が見つからない頼まれごとは、帳に直接入れず確かめ待ちにする（2026-11-06）
                let said = lines.map(\.text)
                for i in items.indices where items[i].source == .conversation
                    && Grounding.unsupported(items[i].what + " " + (items[i].quote ?? ""), in: said) {
                    items[i].state = .candidate
                    Tally.add("ground.flagged")
                }
                // もう1つの言語モデル（iPhone の中）にも拾わせ、両方が拾ったものを先に出す（2026-11-06）
                if MultiModel.secondOpinionOK, !Summarizer.$sensitive.withValue(work, operation: { Summarizer.usesLocal(apiKey: key) }),
                   let second = try? await Summarizer.$forceLocal.withValue(true, operation: {
                       try await Summarizer.tasks(transcript, day: day, apiKey: key)
                   }) {
                    let others = second.map { $0.what + " " + $0.quote }
                    for i in items.indices where items[i].source == .conversation {
                        items[i].agreed = MultiModel.agrees(items[i].what + " " + (items[i].quote ?? ""), with: others)
                    }
                    Tally.add("second.ran")
                    Tally.add("task.agreed", items.filter { $0.agreed == true }.count)
                    Tally.add("task.alone", items.filter { $0.agreed == false }.count)
                } else if !items.isEmpty, !MultiModel.secondOpinionOK {
                    Tally.add("second.skipped")
                }
                found += items
            }
        }
        let added = tasks.add(found)
        // 相手か期限が分かるもの・★のものがあるときだけ知らせる。無いものは黙って確かめ待ちへ（2026-11-10）
        guard Self.worthNotice(added), let notice = Self.foundNotice(added) else { return }
        Self.notifyTasks(title: notice.title, body: notice.body, ids: added.map(\.id))
    }

    /// 新しく帳に入ったものの知らせの題と文（2026-11-10）。入ったものが無ければ nil。
    /// はじめから帳に入ったものを先に、3件まで。相手と期限が分かっていれば添える（開かなくても、だれの・いつまでの話か分かるように）
    static func foundNotice(_ added: [TaskBook.Item]) -> TaskNotice? {
        guard !added.isEmpty else { return nil }
        let checks: [TaskBook.Item] = added.filter { $0.state == .candidate }
        let opened: [TaskBook.Item] = added.filter { $0.state != .candidate }
        var body: String = opened.isEmpty ? "" : "帳に \(opened.count) 件入れました。"
        if !checks.isEmpty { body += "確かめてほしいものが \(checks.count) 件あります。" }
        let lifeCount: Int = added.filter { !$0.isWork }.count
        if lifeCount > 0 { body += "（うち仕事以外 \(lifeCount) 件）" }
        for item in (opened + checks).prefix(3) {
            var notes: [String] = []
            if let from = item.from, !from.isEmpty {
                switch item.kindOrDefault {
                case .delegated: notes.append(from + "へ")
                case .promise: notes.append(from + "と")
                case .asked, .mine: notes.append(from + "から")
                }
            }
            if let due = item.due {
                notes.append(taskDueFormat.string(from: due) + "まで")
            } else if let dueText = item.dueText, !dueText.isEmpty {
                notes.append(dueText)
            }
            body += "\n・" + item.what + (notes.isEmpty ? "" : "（" + notes.joined(separator: "・") + "）")
        }
        if added.count > 3 { body += "\nほか \(added.count - 3) 件" }
        let title: String = lifeCount == added.count ? "やること・約束を見つけました" : "頼まれごとを見つけました"
        return TaskNotice(title: title, body: body)
    }

    /// 拾ったものを帳の形にする。★の前後2分で拾ったものははじめから帳に、★の近くで何も拾えなければ「★を付けたところ」を確かめ待ちに。
    private func taskItems(_ found: [Summarizer.FoundTask], in c: ConversationLog.Conversation,
                           lines: [ConversationLog.Line], marks: [ConversationLog.Line],
                           day: String, work: Bool) -> [TaskBook.Item] {
        var items: [TaskBook.Item] = []
        var coveredMarks = Set<Date>()
        for f in found {
            let quote = f.quote.isEmpty ? nil : f.quote
            let head = quote.map { String($0.prefix(8)) }
            func atTime(_ line: ConversationLog.Line) -> Bool {
                !f.time.isEmpty && Self.taskClock.string(from: line.time) == f.time
            }
            func quoted(_ line: ConversationLog.Line) -> Bool {
                guard let head else { return false }
                return line.text.contains(head)
            }
            // 時刻と発言が合う行 → 発言が合う行 → 時刻が合う行
            let line = lines.first { atTime($0) && (head == nil || quoted($0)) }
                ?? lines.first { quoted($0) }
                ?? lines.first { atTime($0) }
            let said = line?.time ?? c.start
            let nearMark = marks.first { abs($0.time.timeIntervalSince(said)) <= 120 }
            if let nearMark { coveredMarks.insert(nearMark.time) }
            var from = f.from.isEmpty ? nil : f.from
            // 本人が頼んだものの話し手は本人なので、話し手から相手は決めない
            if from == nil, TaskBook.Kind.parse(f.kind) != .delegated,
               let speaker = line?.speaker, line?.speakerID != SpeakerLabeler.selfID, !speaker.hasPrefix("人物") {
                from = speaker
            }
            items.append(TaskBook.Item(what: f.what, from: from, dueText: TaskBook.cleanDue(f.dueText),
                                       due: TaskBook.dueDate(f.dueDay), said: said, day: day, place: c.place,
                                       quote: quote, audio: line?.audio, offset: line?.offset,
                                       source: nearMark != nil ? .mark : .conversation,
                                       state: nearMark != nil ? .open : .candidate, work: work,
                                       kind: TaskBook.Kind.parse(f.kind)))
        }
        for mark in marks where !coveredMarks.contains(mark.time) {
            // 近い★は1つにまとめる
            guard !items.contains(where: { $0.source == .mark && abs($0.said.timeIntervalSince(mark.time)) <= 120 }) else { continue }
            let around = lines.filter { abs($0.time.timeIntervalSince(mark.time)) <= 60 }
            let text = around.map { ($0.speaker.map { "[\($0)] " } ?? "") + $0.text }.joined(separator: " ")
            items.append(TaskBook.Item(what: "★を付けたところ（\(Self.taskClock.string(from: mark.time))）",
                                       said: mark.time, day: day, place: c.place,
                                       quote: text.count > 160 ? String(text.prefix(160)) + "…" : text,
                                       audio: mark.audio, offset: mark.offset, source: .mark, state: .candidate, work: work))
        }
        return items
    }

    /// 議事録の宿題のうち、自分の（担当が自分か空の）ものを確かめ待ちに入れる。
    /// 入れたら、会話から拾ったときと同じように知らせる（2026-11-10。前は黙って入れていた）
    func addMinuteTasks(_ todos: [Summarizer.Minutes.Todo], of c: ConversationLog.Conversation, day: String, title: String) {
        let mine = todos.filter { $0.who.isEmpty || $0.who.contains(SpeakerLabeler.selfName) || $0.who.contains("本人") }
        guard !mine.isEmpty else { return }
        let added: [TaskBook.Item] = tasks.add(mine.map { todo in
            TaskBook.Item(what: todo.what, dueText: TaskBook.cleanDue(todo.due), said: c.start, day: day,
                          place: c.place, quote: "議事録「\(title)」の宿題", source: .minutes, state: .candidate, work: true)
        })
        guard let notice = Self.foundNotice(added) else { return }
        Self.notifyTasks(title: notice.title, body: notice.body, ids: added.map(\.id))
        tasksChanged()
    }

    /// 写真の文字を読み取り（iPhone の中で）、やることを拾って確かめ待ちに入れる。結果の一文を返す。
    /// work は、拾ったものを仕事に入れるか（タスクタブで開いている方。2026-11-07）
    func addTasks(fromPhoto image: UIImage, work: Bool) async -> String {
        let text = await Self.recognizeText(image)
        guard !text.isEmpty else { return "文字を読み取れませんでした。明るいところで、まっすぐ撮ってみてください。" }
        let now = Date.now
        var found: [Summarizer.FoundTask] = []
        if let key = llmKey {
            // 職場のメモかもしれないので、端末内で作る設定のときは外に送らない
            found = (try? await Summarizer.$sensitive.withValue(true) {
                try await Summarizer.tasks(fromText: text, today: TaskBook.dayFormat.string(from: now), apiKey: key)
            }) ?? []
        }
        let quote = text.count > 400 ? String(text.prefix(400)) + "…" : text
        let items: [TaskBook.Item]
        if found.isEmpty {
            // 拾えなければ、読み取った文字を1件にして、本人に直してもらう
            let first = text.split(separator: "\n").first.map(String.init) ?? text
            items = [TaskBook.Item(what: String(first.prefix(60)), said: now, quote: quote, source: .photo, state: .candidate,
                                   work: work)]
        } else {
            items = found.map { f in
                TaskBook.Item(what: f.what, from: f.from.isEmpty ? nil : f.from, dueText: TaskBook.cleanDue(f.dueText),
                              due: TaskBook.dueDate(f.dueDay), said: now,
                              quote: f.quote.isEmpty ? quote : f.quote, source: .photo, state: .candidate, work: work,
                              kind: TaskBook.Kind.parse(f.kind))
            }
        }
        let added = tasks.add(items)
        return added.isEmpty ? "読み取りましたが、もう帳にあるものでした。" : "\(added.count) 件を確かめ待ちに入れました。"
    }

    /// 画像の文字を、iPhone の中で読み取る（日本語と英語）
    nonisolated static func recognizeText(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        // perform は読み終わるまで戻らない（結果は request に入る）
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// 帳が変わったら呼ぶ（知らせを頼み直す）
    func tasksChanged() {
        // 確かめ待ちのまま7日たったものは、静かに片づける（2026-11-10）
        tasks.expireCandidates()
        Task { await scheduleTaskReminders() }
        // 済みにしたタスクと同じ家の PC のやることも、済みにする（2026-11-10。1つの一覧にしたので）
        Task { await mothership.followAppDone(tasks.items, pc: homePC) }
    }

    /// 朝夕の知らせの題と文
    struct TaskNotice: Equatable {
        var title: String
        var body: String
    }

    /// 朝夕の知らせの文を作る（2026-11-07）。出すものが無ければ nil。
    /// 出勤日は仕事と仕事以外の両方（数は「仕事 ○ 件・仕事以外 ○ 件」と分ける）。
    /// 休みの日（offDay）は仕事以外だけ。休み明けの出勤日の朝（afterOff）は、休みのあいだ止めていた仕事の分もまとめて、5件まで並べる。
    /// end はその日の終わり（これより前が期限のものを「今日までのもの・過ぎたもの」に数える）。
    static func taskNotice(open: [TaskBook.Item], candidates: [TaskBook.Item], end: Date, morning: Bool,
                           offDay: Bool, afterOff: Bool) -> TaskNotice? {
        let shown = offDay ? TaskBook.filter(open, .life) : open
        let checks = offDay ? TaskBook.filter(candidates, .life) : candidates
        guard !shown.isEmpty || !checks.isEmpty else { return nil }
        let mine = shown.filter { !$0.isWaiting }
        let late = mine.filter { ($0.due ?? .distantFuture) < end }
        // 人に頼んで、期限を過ぎても済んでいないもの（相手に確かめる）
        let follow = shown.filter { $0.isWaiting && ($0.due ?? .distantFuture) < end }
        var body: String
        if offDay {
            body = "仕事以外 まだ \(mine.count) 件"
        } else {
            let work = mine.filter(\.isWork).count
            body = "まだ 仕事 \(work) 件・仕事以外 \(mine.count - work) 件"
        }
        if !late.isEmpty { body += "（今日までのもの・過ぎたもの \(late.count) 件）" }
        if !checks.isEmpty { body += "・確かめ待ち \(checks.count) 件" }
        let catchUp = afterOff && morning && !offDay
        let urgentFirst = late.sorted { ($0.urgent == true) && ($1.urgent != true) }
        for item in (urgentFirst + mine.filter { !late.contains($0) }).prefix(catchUp ? 5 : 3) {
            // 先の日の知らせなので「明日まで」ではなく日付で
            body += "\n・" + item.what + (item.due.map { "（" + taskDueFormat.string(from: $0) + "まで）" } ?? "")
        }
        for item in follow.prefix(2) {
            body += "\n・確かめる: " + item.what + (item.from.map { "（" + $0 + "へ）" } ?? "")
        }
        if offDay, open.contains(where: { $0.isWork }) { body += "\n仕事の分は、休み明けの朝に知らせます。" }
        let title: String
        if offDay {
            title = morning ? "今日のやること（仕事以外）" : "まだ済んでいないこと（仕事以外）"
        } else if catchUp {
            title = "休み明けの頼まれごと（休みのあいだの分も）"
        } else {
            title = morning ? "今日の頼まれごと" : "まだ済んでいない頼まれごと"
        }
        return TaskNotice(title: title, body: body)
    }

    /// 朝と夕方（既定は8時と18時）に、まだ済んでいない頼まれごとを知らせる。7日先まで iOS に頼んでおき、帳が変わるたびに頼み直す。
    /// 休みの日（土日・祝日・有休など）は仕事以外の分だけ、休み明けの出勤日の朝に仕事の分もまとめて出す（2026-11-07）。
    func scheduleTaskReminders() async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.taskNotifyPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        let open = tasks.open
        let candidates = tasks.candidates
        // 期限に時刻があるものは、その1時間前に1件ずつ知らせる（2026-11-10）
        if Self.taskDueHourOn {
            for (at, item) in Self.dueHourNotices(open, now: .now) {
                let content = UNMutableNotificationContent()
                content.title = "もうすぐ期限です"
                content.body = Self.dueHourBody(item)
                content.sound = .default
                content.categoryIdentifier = NoticeActions.dueCategory
                content.userInfo = ["ids": [item.id]]
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                try? await center.add(UNNotificationRequest(
                    identifier: NoticeActions.duePrefix + item.id, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
                NoticeStats.countOnce(NoticeActions.dueCategory, key: item.id + "|" + String(Int(at.timeIntervalSince1970)))
            }
        }
        guard Self.taskRemindOn, !open.isEmpty || !candidates.isEmpty else { return }
        let cal = Calendar.current
        let now = Date.now
        let today = cal.startOfDay(for: now)
        // 前の日から7日先まで、休みの日か（休み明けを見分けるため前の日も）
        var off: [Int: Bool] = [:]
        for offset in -1..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            off[offset] = isDayOff(day)
        }
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let offDay = off[offset] ?? cal.isDateInWeekend(day)
            // 「休みの日は知らせない」のときは、休みの日は何も出さない
            if Self.taskWeekendOff, offDay { continue }
            let afterOff = !offDay && off[offset - 1] == true
            for (minutes, morning) in [(Self.taskMorning, true), (Self.taskEvening, false)] {
                // 朝は「昨日と今日」に今日の三つと確かめ待ちの数が入るので、出さない（2026-11-09）。休み明けの朝のまとめは今までどおり
                if morning, MorningBrief.isOn, !afterOff { continue }
                let at = day.addingTimeInterval(TimeInterval(minutes * 60))
                guard at > now.addingTimeInterval(30) else { continue }
                let end = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                guard let notice = Self.taskNotice(open: open, candidates: candidates, end: end, morning: morning,
                                                   offDay: offDay, afterOff: afterOff) else { continue }
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                content.sound = .default
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                try? await center.add(UNNotificationRequest(
                    identifier: Self.taskNotifyPrefix + String(Int(at.timeIntervalSince1970)), content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
    }

    /// 知らせるほどのものか（2026-11-10）。相手か期限が分かるもの・★で拾ったもの・議事録の宿題が1つでもあれば知らせる
    static func worthNotice(_ added: [TaskBook.Item]) -> Bool {
        added.contains { item in
            item.source == .mark || item.source == .minutes || !(item.from ?? "").isEmpty
                || item.due != nil || !(item.dueText ?? "").isEmpty
        }
    }

    /// 「見つけました」の知らせ。ids は、ボタン（入れる・違う）で動かす頼まれごと
    private static func notifyTasks(title: String, body: String, ids: [String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NoticeActions.foundCategory
        content.userInfo = ["ids": ids]
        NoticeStats.count(NoticeActions.foundCategory, "sent")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: NoticePresenter.taskFoundID, content: content, trigger: nil))
    }

    private static let taskDueFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        return f
    }()

    /// 「今日まで」「明日まで」「11/7(金)まで」「2日過ぎ」
    static func taskDueText(_ due: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: due)).day ?? 0
        switch days {
        case ..<0: return "\(-days)日過ぎ"
        case 0: return "今日まで"
        case 1: return "明日まで"
        default: return taskDueFormat.string(from: due) + "まで"
        }
    }

    /// 帳が変わっていたら、ドライブの「頼まれごと帳」と同期フォルダの「頼まれごと帳.json」に写す
    func writeTaskBook() async {
        guard email != nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(tasks.items) else { return }
        // 件数と最後に変えた時刻が前に写したときと同じなら書かない（期限の「あと何日」は日が変わったら書き直す）
        let stamp = "\(tasks.items.count)|\(tasks.items.map(\.updated).max()?.timeIntervalSince1970 ?? 0)|"
            + TaskBook.dayFormat.string(from: .now)
        guard UserDefaults.standard.string(forKey: Self.taskBookHashKey) != stamp else { return }
        do {
            try await writeTaskBookFiles(taskParagraphs(), json: json)
            UserDefaults.standard.set(stamp, forKey: Self.taskBookHashKey)
        } catch {
            diagnostics.problem("頼まれごと帳をドライブに書けませんでした: \(error.localizedDescription)")
        }
    }

    private func taskParagraphs() -> [(text: String, style: String?)] {
        Self.taskBookParagraphs(open: tasks.open, candidates: tasks.candidates, done: tasks.done)
    }

    /// ドライブの「頼まれごと帳」の中身。「仕事」と「仕事以外」の見出しで分け、その中を まだ・確かめ待ち・済み に（2026-11-07）
    static func taskBookParagraphs(open: [TaskBook.Item], candidates: [TaskBook.Item],
                                   done: [TaskBook.Item]) -> [(text: String, style: String?)] {
        var p: [(text: String, style: String?)] = [("頼まれごと帳", "HEADING_1"),
                                                  ("アプリが自動で書き直します（ここを直してもアプリには戻りません）。", nil)]
        func line(_ item: TaskBook.Item) -> String {
            var text = "・" + item.what
            if let due = item.due { text += "（" + Self.taskDueText(due) + "）" } else if let d = item.dueText { text += "（" + d + "）" }
            var notes: [String] = [item.kindOrDefault.label]
            if let progress = item.progress { notes.append(progress.label) }
            if let from = item.from { notes.append(from) }
            notes.append(Self.taskDueFormat.string(from: item.said) + " " + item.source.label)
            if let memo = item.memo, !memo.isEmpty { notes.append("メモ: " + memo) }
            return text + " — " + notes.joined(separator: "・")
        }
        for scope in [TaskBook.Scope.work, .life] {
            let still = TaskBook.filter(open, scope)
            let checks = TaskBook.filter(candidates, scope)
            let finished = TaskBook.filter(done, scope)
            p.append((scope.label, "HEADING_2"))
            p.append(("まだ（\(still.count) 件）", "HEADING_3"))
            p += still.map { (line($0), nil) }
            if !checks.isEmpty {
                p.append(("確かめ待ち（\(checks.count) 件）", "HEADING_3"))
                p += checks.map { (line($0), nil) }
            }
            if !finished.isEmpty {
                p.append(("済み（30日以内）", "HEADING_3"))
                p += finished.map { (line($0), nil) }
            }
        }
        return p
    }

    /// その人とのこれまでのやり取り（その人の声の行がある会話か、見出しの相手にその名前がある会話。新しいものから limit 件）
    func history(of person: SpeakerLabeler.Person, limit: Int = 30) -> [(day: String, conversation: ConversationLog.Conversation)] {
        var result: [(day: String, conversation: ConversationLog.Conversation)] = []
        let name = person.displayName
        for day in recordedDays() {
            for c in conversations(on: day).reversed() where c.media == nil {
                let spoke = c.lines.contains { $0.speakerID == person.id }
                    || (person.isNamed && c.people.contains { Self.sameName($0, name) })
                if spoke { result.append((day, c)) }
                if result.count >= limit { return result }
            }
        }
        return result
    }
}

private extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - アプリを開いているときの知らせ（2026-11-10）

/// 「頼まれごとを見つけました」の知らせを、アプリを開いているときにも画面の上に出す。
/// iOS は、これが無いと、開いているアプリの知らせを出さない（通知センターにも残らない）。
/// 出すのはこの知らせだけ。ほかの知らせ（朝夕のまとめ・録音が止まった など）は、今までどおり開いているあいだは出さない。
final class NoticePresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoticePresenter()
    /// 「見つけました」の知らせの名前（同じ名前で出し直すので、古いものは置き換わる）
    static let taskFoundID = "taskFound"
    /// 開いているあいだも出す知らせ
    static let shownWhileOpen: Set<String> = [taskFoundID]

    /// 知らせの名前から、開いているあいだの出し方を決める（期限の1時間前の知らせも出す。2026-11-10）
    static func options(for identifier: String) -> UNNotificationPresentationOptions {
        shownWhileOpen.contains(identifier) || identifier.hasPrefix(NoticeActions.duePrefix)
            || identifier.hasPrefix(AppFeeds.noticePrefix) ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.options(for: notification.request.identifier))
    }

    /// 知らせのボタン・知らせそのものを押されたとき（2026-11-10。中身は NoticeActions.swift）
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let content = request.content
        guard !content.categoryIdentifier.isEmpty, let action = NoticeActions.action(for: response.actionIdentifier) else {
            completionHandler()
            return
        }
        let ids: [String] = content.userInfo["ids"] as? [String] ?? []
        let pending = NoticeActions.Pending(action: action, ids: ids, identifier: request.identifier, title: content.title,
                                            body: content.body, category: content.categoryIdentifier)
        Task { @MainActor in
            NoticeActions.receive(pending)
            completionHandler()
        }
    }
}

// MARK: - 画面

/// タスクタブ。下のタブから開く（自分の NavigationStack を持つ）。
struct TasksTab: View {
    var body: some View {
        NavigationStack { TaskBookView() }
    }
}

/// やることの画面。上で「仕事｜仕事以外｜全部」、その下で「やる」「待ち」「人」「済み」を切り替える。右上の＋で書き足す・写真から読み取る。
/// 頼まれごと・自分でやること・人に頼んだこと・約束を、1か所で追いかける。
struct TaskBookView: View {
    enum Page: String, CaseIterable, Identifiable {
        case todo = "やる", waiting = "待ち", people = "人", done = "済み"
        var id: String { rawValue }
    }

    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()
    @State private var page = Page.todo
    /// 仕事｜仕事以外｜全部（最後に選んだものを覚える。2026-11-07）
    @AppStorage("taskScope") private var scope = TaskBook.Scope.all
    @State private var editing: TaskBook.Item?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var reading = false
    @State private var note: String?
    @State private var showSettings = false
    /// 仕事のまとめを取り込む画面（2026-11-08）
    @State private var importingDigest = false
    /// 「違う」の理由を選んでいるもの（2026-11-10）
    @State private var rejecting: TaskBook.Item?
    /// 「全部違う」にするもの（2026-11-10）
    @State private var rejectingAll: [String]?
    /// 期限に時刻があるものを1時間前に知らせる（Pipeline.taskDueHourKey と同じ名前）
    @AppStorage("taskDueHour") private var dueHourOn = true
    /// Pipeline.taskRemindKey などと同じ名前
    @AppStorage("taskRemind") private var remindOn = true
    @AppStorage("taskMorning") private var morning = 8 * 60
    @AppStorage("taskEvening") private var evening = 18 * 60
    @AppStorage("taskWeekendOff") private var weekendOff = false
    @AppStorage("taskBadgeLateOnly") private var badgeLateOnly = false
    /// ★の無い仕事以外の会話からも拾う（2026-11-09 から初めはオフ）
    @AppStorage(Pipeline.lifeAutoKey) private var lifeAuto = false

    var body: some View {
        let book = pipeline.tasks
        let lists = book.lists(scope)
        List {
            Section {
                Picker("仕事か", selection: $scope) {
                    ForEach(TaskBook.Scope.allCases) { s in Text(scopeTitle(s, book)).tag(s) }
                }
                .pickerStyle(.segmented)
                Picker("見る", selection: $page) {
                    ForEach(Page.allCases) { p in Text(title(p, lists)).tag(p) }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowSeparator(.hidden)
            if let note {
                Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            if reading {
                Section { HStack { ProgressView(); Text("写真の文字を読み取っています…") } }
            }
            switch page {
            case .todo: todoPage(lists)
            case .waiting: waitingPage(lists)
            case .people: peoplePage(lists)
            case .done: donePage(lists)
            }
        }
        .navigationTitle("タスク")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("知らせの設定", systemImage: "bell") { showSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("書き足す", systemImage: "square.and.pencil") {
                        editing = TaskBook.Item(what: "", said: .now, source: .manual, state: .open, work: newIsWork())
                    }
                    Button("人に頼んだことを書く", systemImage: "arrow.turn.up.right") {
                        editing = TaskBook.Item(what: "", said: .now, source: .manual, state: .open, work: newIsWork(),
                                                kind: .delegated)
                    }
                    Button("写真を撮って読み取る", systemImage: "camera") { takingPhoto = true }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button("写真から読み取る", systemImage: "photo") { choosingPhoto = true }
                    // 職場の Claude の「この日に何があったか」の答え（2026-11-08）
                    Button("仕事のまとめを取り込む", systemImage: "doc.text") { importingDigest = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onDisappear { player.stop() }
        .onChange(of: book.version) { pipeline.tasksChanged() }
        .onChange(of: remindOn) { pipeline.tasksChanged() }
        .onChange(of: morning) { pipeline.tasksChanged() }
        .onChange(of: evening) { pipeline.tasksChanged() }
        .onChange(of: weekendOff) { pipeline.tasksChanged() }
        .onChange(of: dueHourOn) { pipeline.tasksChanged() }
        .confirmationDialog("どう違いましたか", isPresented: Binding(get: { rejecting != nil }, set: { if !$0 { rejecting = nil } }),
                            titleVisibility: .visible, presenting: rejecting) { item in
            ForEach(TaskBook.RejectReason.choices) { reason in
                Button(reason.label) {
                    withAnimation { pipeline.tasks.reject(item.id, reason: reason) }
                    rejecting = nil
                }
            }
            Button("やめる", role: .cancel) { rejecting = nil }
        } message: { _ in
            Text("理由の数は「済み」のいちばん下の「入り口ごとの数」に出ます。")
        }
        .alert("確かめ待ちを全部「違う」にしますか", isPresented: Binding(get: { rejectingAll != nil }, set: { if !$0 { rejectingAll = nil } })) {
            Button("全部違う", role: .destructive) {
                if let ids = rejectingAll { withAnimation { _ = pipeline.tasks.rejectAll(ids, reason: .bulk) } }
                rejectingAll = nil
            }
            Button("やめる", role: .cancel) { rejectingAll = nil }
        } message: {
            Text("\(rejectingAll?.count ?? 0) 件を「違う」にします。同じものはもう出しません。")
        }
        .sheet(item: $editing) { item in
            NavigationStack {
                TaskEditView(item: item) { saved in
                    if pipeline.tasks.items.contains(where: { $0.id == saved.id }) {
                        pipeline.tasks.update(saved)
                    } else {
                        pipeline.tasks.add([saved])
                    }
                    editing = nil
                } onDelete: {
                    if item.source == .manual {
                        pipeline.tasks.delete(item.id)
                    } else {
                        pipeline.tasks.set(item.id, .rejected)
                    }
                    editing = nil
                }
            }
        }
        .sheet(isPresented: $importingDigest) {
            NavigationStack {
                WorkDigestImportView { note = $0 }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section {
                        Toggle("朝と夕方に知らせる", isOn: $remindOn)
                        if remindOn {
                            DatePicker("朝", selection: timeBinding($morning), displayedComponents: .hourAndMinute)
                            DatePicker("夕方", selection: timeBinding($evening), displayedComponents: .hourAndMinute)
                            Toggle("休みの日は何も知らせない", isOn: $weekendOff)
                        }
                        Toggle("期限に時刻があるものは1時間前に知らせる", isOn: $dueHourOn)
                        Toggle("タブの数字は期限切れだけ", isOn: $badgeLateOnly)
                        Toggle("★の無い仕事以外の会話からも拾う", isOn: $lifeAuto)
                    } footer: {
                        Text("まだ済んでいないものの数（仕事と仕事以外に分けて）と、期限の近いもの、期限を過ぎた「人に頼んだこと」を知らせます。休みの日（土日・カレンダーの祝日・「有休」「休み」などの終日の予定）は仕事以外の分だけを知らせ、仕事の分は休み明けの朝にまとめて知らせます。カレンダーを使っていなければ、休みの日は土日だけです。\n朝の「昨日と今日」を知らせるときは、朝の知らせはそちらにまとめます（休み明けの朝は今までどおり）。\n仕事中（職場にいた時間か、休みでない日の8〜19時）の会話と、時計の★を付けた会話からは仕事のものを拾います。仕事以外の会話からは、★を付けたものだけ拾います（「★の無い仕事以外の会話からも拾う」で前のように）。頼まれた瞬間に★を押すと、確実に入ります。ドライブの「頼まれごと帳」にも写します。")
                    }
                }
                .navigationTitle("知らせ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showSettings = false } }
                }
            }
            .presentationDetents([.medium])
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            guard let photoItem else { return }
            Task {
                if let data = try? await photoItem.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await read(image)
                }
                self.photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                takingPhoto = false
                if let image { Task { await read(image) } }
            }
            .ignoresSafeArea()
        }
    }

    /// 家の PC のやることのうち、アプリのタスクと重ならないもの（その方の分）
    private func homeExtra(_ s: TaskBook.Scope) -> [MothershipTodo] {
        pipeline.mothership.extra(s, tasks: pipeline.tasks.items)
    }

    private func title(_ p: Page, _ book: TaskBook.Lists) -> String {
        switch p {
        case .todo: let n = book.todo.count + book.candidates.count + homeExtra(scope).count; return n > 0 ? "やる \(n)" : "やる"
        case .waiting: return book.waiting.isEmpty ? "待ち" : "待ち \(book.waiting.count)"
        case .people, .done: return p.rawValue
        }
    }

    /// 「仕事 5」「仕事以外 2」「全部 7」（まだのもの・確かめ待ちの数）
    private func scopeTitle(_ s: TaskBook.Scope, _ book: TaskBook) -> String {
        let n = book.lists(s).count + homeExtra(s).count
        return n > 0 ? "\(s.label) \(n)" : s.label
    }

    /// 手で足すもの・写真から拾うものを、仕事に入れるか（開いている方。「全部」のときは、今が仕事の時間なら仕事）
    private func newIsWork() -> Bool {
        switch scope {
        case .work: true
        case .life: false
        case .all: pipeline.taskTime(.now)
        }
    }

    // MARK: ページ

    @ViewBuilder
    private func todoPage(_ book: TaskBook.Lists) -> some View {
        // 今日の三つ（期限を過ぎた・今日までのもの、家の PC が選んだもの。朝の「昨日と今日」と同じ選び方。2026-11-09）。
        // 押すと「解き方」（手順・だいたいの時間・送る文の下書き。2026-11-10）
        let three = pipeline.todayThree()
        if !three.isEmpty {
            Section {
                ForEach(Array(three.enumerated()), id: \.offset) { i, pick in
                    TodayPickRow(number: i + 1, pick: pick)
                }
            } header: {
                Text("今日の三つ")
            } footer: {
                if three.contains(where: \.hasHowTo) { Text("押すと、解き方が出ます。") }
            }
        }
        if !book.candidates.isEmpty {
            Section {
                ForEach(book.candidates) { item in
                    TaskRow(item: item, player: player) { editing = item }
                    HStack(spacing: 20) {
                        Button("入れる", systemImage: "plus.circle") { change(item.id, .open) }
                        Button("直して入れる", systemImage: "pencil") {
                            var copy = item
                            copy.state = .open
                            editing = copy
                        }
                        // 違う理由を選ぶ（2026-11-10。数がたまれば、次にどこを直すかが分かる）
                        Button("違う", systemImage: "xmark", role: .destructive) { rejecting = item }
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                }
            } header: {
                HStack {
                    Text("確かめてほしい（\(book.candidates.count) 件）")
                    Spacer()
                    if book.candidates.count >= 2 {
                        Button("全部違う", role: .destructive) { rejectingAll = book.candidates.map(\.id) }
                            .font(.caption)
                    }
                }
            } footer: {
                Text("会話・議事録・写真・1日のまとめから拾ったものです。合っていれば「入れる」、違えば「違う」（同じものはもう出しません）。7日そのままのものは、自動で片づけます。")
            }
        }
        // アプリのタスクと、家の PC が拾ったやることを、1つの一覧に混ぜる（2026-11-10。同じものらしければアプリのタスクだけ）
        let apps = Dictionary(uniqueKeysWithValues: TaskBook.grouped(book.todo).map { ($0.bucket, $0.items) })
        let homes = Dictionary(grouping: homeExtra(scope)) { OneTaskList.bucket($0, now: .now) }
        let buckets = TaskBook.Bucket.allCases.filter { apps[$0] != nil || homes[$0] != nil }
        if buckets.isEmpty {
            Section { Text("今やることはありません").foregroundStyle(.secondary) }
        }
        ForEach(buckets, id: \.self) { bucket in
            let mine = apps[bucket] ?? []
            let others = MothershipBook.sorted(homes[bucket] ?? [])
            // 期限の無いものは、家の PC の分を新しいものから8件まで（続きは一覧で）
            let shown = bucket == .someday ? Array(others.prefix(8)) : others
            Section {
                ForEach(mine) { openRow($0) }
                ForEach(shown) { MothershipRow(item: $0) }
                if shown.count < others.count {
                    NavigationLink("ほかに \(others.count - shown.count) 件") { MothershipListView(scope: scope) }
                }
            } header: {
                Text("\(bucket.title)（\(mine.count + others.count)）")
                    .foregroundStyle(bucket == .late ? Color.red : Color.secondary)
            }
        }
        // 職場の Claude の答えを取り込んだ「仕事のまとめ」（2026-11-08。仕事以外だけを見ているときは出さない）
        if scope != .life {
            Section {
                NavigationLink {
                    WorkDigestListView()
                } label: {
                    LabeledContent {
                        Text(pipeline.workDigests.entries.isEmpty ? "写真・貼り付けから" : "\(pipeline.workDigests.entries.count) 件")
                    } label: {
                        Label("仕事のまとめ", systemImage: "doc.text")
                    }
                }
            }
        }
        Section {
            EmptyView()
        } footer: {
            let home = pipeline.mothership.export == nil ? ""
                : "\n家の PC が会話・LINE・メモから拾ったものも、同じ一覧に入っています（押すとくわしく。左へ払うと「済み」「違う」）。"
            Text("○で済み。右へ払うと「明日に」「来週に」、左へ払うと「済み」「待ち」。急ぎ（!）は同じ並びの中で上に出ます。" + home)
        }
    }

    @ViewBuilder
    private func waitingPage(_ book: TaskBook.Lists) -> some View {
        if book.waiting.isEmpty {
            Section {
                Text("待っているものはありません").foregroundStyle(.secondary)
            } footer: {
                Text("人に頼んだこと（会話から拾ったもの・＋の「人に頼んだことを書く」）と、左へ払って「待ち」にしたものがここに並びます。")
            }
        } else {
            Section {
                ForEach(book.waiting) { openRow($0) }
            } footer: {
                Text("期限を過ぎたものは、朝の知らせで「確かめる」に出します。返事が来たら○で済みに。")
            }
        }
    }

    @ViewBuilder
    private func peoplePage(_ book: TaskBook.Lists) -> some View {
        let people = TaskBook.byPerson(book.open)
        if people.isEmpty {
            Section {
                Text("相手の分かるものはまだありません").foregroundStyle(.secondary)
            } footer: {
                Text("頼んだ人・頼んだ相手・約束した相手が分かるものを、人ごとにまとめます。")
            }
        }
        ForEach(people, id: \.person) { group in
            Section {
                ForEach(group.items) { openRow($0) }
            } header: {
                Text("\(group.person)（\(summary(group.items))）")
            }
        }
    }

    @ViewBuilder
    private func donePage(_ book: TaskBook.Lists) -> some View {
        if book.done.isEmpty {
            Section { Text("30日以内に済んだものはありません").foregroundStyle(.secondary) }
        } else {
            Section {
                ForEach(book.done) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            change(item.id, .open)
                        } label: {
                            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                        }
                        .buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.what).strikethrough().foregroundStyle(.secondary)
                            if let at = item.doneAt {
                                Text(at.formatted(date: .abbreviated, time: .shortened) + " に済み")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("済み（30日以内・\(book.done.count) 件）")
            } footer: {
                Text("✓を押すと、まだに戻します。")
            }
        }
        // 入り口ごとの「残した・捨てた」と、知らせの数（2026-11-10）
        Section {
            NavigationLink {
                TaskScoreView()
            } label: {
                Label("入り口ごとの数", systemImage: "chart.bar")
            }
        }
    }

    /// 「頼まれた 2・約束 1」
    private func summary(_ items: [TaskBook.Item]) -> String {
        TaskBook.Kind.allCases.compactMap { kind in
            let n = items.filter { $0.kindOrDefault == kind }.count
            return n > 0 ? "\(kind.label) \(n)" : nil
        }.joined(separator: "・")
    }

    /// まだのもの1行。○で済み、払って延ばす・待ちにする。
    private func openRow(_ item: TaskBook.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                change(item.id, .done)
            } label: {
                Image(systemName: "circle").font(.title3)
            }
            .buttonStyle(.borderless)
            TaskRow(item: item, player: player) { editing = item }
        }
        .swipeActions(edge: .trailing) {
            Button("済み") { change(item.id, .done) }.tint(.green)
            if item.isWaiting {
                Button("やるに戻す") { withAnimation { pipeline.tasks.setProgress(item.id, .started) } }.tint(.blue)
            } else {
                Button("待ち") { withAnimation { pipeline.tasks.setProgress(item.id, .waiting) } }.tint(.purple)
            }
        }
        .swipeActions(edge: .leading) {
            Button("明日に") { withAnimation { pipeline.tasks.postpone(item.id, days: 1) } }.tint(.orange)
            Button("来週に") { withAnimation { pipeline.tasks.postpone(item.id, days: TaskBook.nextWeekDays()) } }.tint(.indigo)
        }
        .contextMenu {
            Button(item.urgent == true ? "急ぎを外す" : "急ぎにする", systemImage: "exclamationmark") {
                pipeline.tasks.setUrgent(item.id, item.urgent != true)
            }
            Menu("進み具合") {
                Button("未着手") { pipeline.tasks.setProgress(item.id, nil) }
                ForEach(TaskBook.Progress.allCases) { p in
                    Button(p.label) { pipeline.tasks.setProgress(item.id, p) }
                }
            }
            Button("直す", systemImage: "pencil") { editing = item }
        }
    }

    private func change(_ id: String, _ state: TaskBook.State) {
        withAnimation { pipeline.tasks.set(id, state) }
    }

    private func read(_ image: UIImage) async {
        reading = true
        let work = newIsWork()
        note = await pipeline.addTasks(fromPhoto: image, work: work)
        reading = false
    }

    /// 0時からの分 ⇄ 今日のその時刻
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

/// 頼まれごと1件。押すと直す。音声があれば▶︎でその場面を聞ける。
struct TaskRow: View {
    @Environment(Pipeline.self) private var pipeline
    let item: TaskBook.Item
    let player: ClipPlayer
    var onEdit: () -> Void

    private static let said: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) H:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: onEdit) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if item.urgent == true {
                        Image(systemName: "exclamationmark").foregroundStyle(.red).fontWeight(.bold)
                    }
                    Text(item.what).foregroundStyle(.primary).multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.borderless)
            HStack(spacing: 6) {
                let kind = item.kindOrDefault
                Label(kind.label, systemImage: kind.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(kind == .delegated ? Color.purple : kind == .promise ? Color.teal : Color.secondary)
                if let progress = item.progress {
                    Text(progress.label).foregroundStyle(progress == .waiting ? Color.purple : Color.blue)
                }
                if let n = item.postponed, n > 0 {
                    Text("延期\(n)回").foregroundStyle(n >= 3 ? Color.red : Color.secondary)
                }
                if !item.isWork {
                    Label("仕事以外", systemImage: "house").labelStyle(.titleAndIcon).foregroundStyle(.green)
                }
            }
            .font(.caption)
            HStack(spacing: 6) {
                if let due = item.due {
                    let text = Pipeline.taskDueText(due)
                    Text(text).foregroundStyle(text.hasSuffix("過ぎ") || text == "今日まで" ? Color.red : Color.orange)
                } else if let dueText = item.dueText {
                    Text(dueText).foregroundStyle(.orange)
                }
                if let from = item.from {
                    switch item.kindOrDefault {
                    case .asked: Text(from + "から")
                    case .delegated: Text(from + "へ")
                    case .mine, .promise: Text(from + "と")
                    }
                }
                Text(Self.said.string(from: item.said) + "・" + item.originLabel)
            }
            .font(.caption).foregroundStyle(.secondary)
            // ほかの入り口でも見つかった（会話で拾ったものが、仕事のまとめにもあった など。2026-11-10）
            if let also = item.alsoIn, !also.isEmpty {
                Label(also + "にもありました", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.teal)
            }
            if let quote = item.quote, !quote.isEmpty {
                Text("「\(quote)」").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let memo = item.memo, !memo.isEmpty {
                Text("メモ: " + memo).font(.caption)
            }
            HStack(spacing: 16) {
                if let audio = item.audio {
                    let key = "task-" + item.id
                    Button {
                        Task {
                            let start = max(0, (item.offset ?? 0) - 3)
                            await player.toggle(key, at: start, until: start + 20) {
                                await pipeline.archive.playableURL(for: audio)
                            }
                        }
                    } label: {
                        if player.loading == key {
                            ProgressView()
                        } else {
                            Label(player.playing == key ? "止める" : "その場面を聞く",
                                  systemImage: player.playing == key ? "stop.circle.fill" : "play.circle")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                if let day = item.digestDay {
                    // 仕事のまとめの宿題は、元のまとめを開く（2026-11-10）
                    NavigationLink("仕事のまとめを開く") {
                        if let entry = pipeline.workDigests.sorted.first(where: { $0.day == day }) {
                            WorkDigestDetailView(entry: entry)
                        } else {
                            Text("このまとめは、もうありません。").foregroundStyle(.secondary)
                        }
                    }
                } else if let day = item.day {
                    NavigationLink("記録を開く") { DayView(day: day) }
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

/// 頼まれごとを書く・直す
struct TaskEditView: View {
    @State var item: TaskBook.Item
    var onSave: (TaskBook.Item) -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hasDue = false
    @State private var due = Date.now
    @State private var hasTime = false
    @State private var time = Date.now
    @State private var reminderNote: String?

    var body: some View {
        Form {
            Section("やること") {
                TextField("何を・どうする", text: $item.what, axis: .vertical)
                Picker("種類", selection: Binding(get: { item.kindOrDefault }, set: { item.kind = $0 })) {
                    ForEach(TaskBook.Kind.allCases) { Text($0.label).tag($0) }
                }
                TextField(item.kindOrDefault.partyLabel, text: Binding(get: { item.from ?? "" },
                                                                    set: { item.from = $0.isEmpty ? nil : $0 }))
                Picker("進み具合", selection: Binding(get: { item.progress?.rawValue ?? "" },
                                                  set: { item.progress = TaskBook.Progress(rawValue: $0) })) {
                    Text("未着手").tag("")
                    ForEach(TaskBook.Progress.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("急ぎ・大事", isOn: Binding(get: { item.urgent == true }, set: { item.urgent = $0 ? true : nil }))
                // 印の無い古いものは仕事とみなす（2026-11-07）
                Toggle("仕事のこと", isOn: Binding(get: { item.isWork }, set: { item.work = $0 }))
            }
            Section("期限") {
                Toggle("期限がある", isOn: $hasDue)
                if hasDue {
                    DatePicker("期限の日", selection: $due, displayedComponents: .date)
                    Toggle("時刻もある", isOn: $hasTime)
                    if hasTime {
                        DatePicker("期限の時刻", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }
                Picker("繰り返し", selection: Binding(get: { item.repeats?.rawValue ?? "" },
                                                 set: { item.repeats = TaskBook.Repeat(rawValue: $0) })) {
                    Text("しない").tag("")
                    ForEach(TaskBook.Repeat.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if let dueText = item.dueText {
                    Text("聞いた言い方: \(dueText)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(item.reminderID == nil ? "iPhone のリマインダーに送る" : "リマインダーに送り直す") {
                    applyDue()
                    Task {
                        do {
                            item.reminderID = try await RemindersExport.send(item)
                            reminderNote = "リマインダーに入れました。"
                        } catch {
                            reminderNote = "入れられませんでした: \(error.localizedDescription)"
                        }
                    }
                }
                if let reminderNote { Text(reminderNote).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("リマインダーでは、期限の時刻に知らせが来ます。場所で知らせるのは、リマインダーの側で設定してください。")
            }
            Section("メモ") {
                TextField("自分用のメモ", text: Binding(get: { item.memo ?? "" },
                                                  set: { item.memo = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }
            if let quote = item.quote, !quote.isEmpty {
                Section("もとの言葉") { Text(quote).font(.callout) }
            }
            if !item.what.isEmpty || item.source != .manual {
                Section {
                    Button(item.source == .manual ? "取り消す" : "やることではなかった", role: .destructive) { onDelete() }
                }
            }
        }
        .navigationTitle(item.source == .manual && item.what.isEmpty ? "書き足す" : item.kindOrDefault.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("決める") {
                    applyDue()
                    onSave(item)
                }
                .disabled(item.what.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            hasDue = item.due != nil
            due = item.due ?? .now
            hasTime = item.dueTime != nil
            time = item.dueMoment ?? .now
        }
    }

    /// 画面の期限（日と時刻）を項目に入れる
    private func applyDue() {
        item.due = hasDue ? Calendar.current.startOfDay(for: due) : nil
        if hasDue && hasTime {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            item.dueTime = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        } else {
            item.dueTime = nil
        }
    }
}

/// カメラで1枚撮る
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPick(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onPick(nil) }
    }
}

/// 人の画面の「これまでのやり取り」。会話の日時・見出し・要点と、その人からの頼まれごと。
struct PersonHistorySection: View {
    @Environment(Pipeline.self) private var pipeline
    let person: SpeakerLabeler.Person
    @State private var history: [(day: String, conversation: ConversationLog.Conversation)] = []
    @State private var showAll = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) H:mm"
        return f
    }()

    var body: some View {
        let asked = pipeline.tasks.items.filter { item in
            (item.state == .open || item.state == .done) && item.from.map { Pipeline.sameName($0, person.displayName) } == true
        }
        Section {
            ForEach(asked.prefix(5)) { item in
                Label {
                    Text(item.what).strikethrough(item.state == .done)
                } icon: {
                    Image(systemName: item.state == .done ? "checkmark.circle.fill" : "circle")
                }
                .font(.callout)
            }
            if history.isEmpty {
                Text("まだありません").foregroundStyle(.secondary)
            }
            ForEach(Array((showAll ? history : Array(history.prefix(8))).enumerated()), id: \.offset) { _, entry in
                NavigationLink {
                    DayView(day: entry.day)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.time.string(from: entry.conversation.start)
                             + (entry.conversation.place.map { "・" + $0 } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.conversation.title ?? "（見出しなし）").font(.callout)
                        ForEach(entry.conversation.points.prefix(2), id: \.self) { point in
                            Text("・" + point).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            if history.count > 8 && !showAll {
                Button("ほか \(history.count - 8) 件も出す") { showAll = true }
            }
        } header: {
            Text("これまでのやり取り")
        } footer: {
            Text("この人と話した会話（新しいものから30件）と、この人からの頼まれごとです。押すとその日の記録を開きます。")
        }
        .task(id: person.id) {
            history = pipeline.history(of: person)
        }
    }
}

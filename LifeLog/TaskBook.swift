import Foundation
import Observation
import SwiftUI
import PhotosUI
import UIKit
import UserNotifications
import ImageIO
import Vision

/// 頼まれごと帳。仕事で頼まれたこと・引き受けたことを1か所にため、済むまで追いかける。
/// 会話（仕事中と★を付けた会話）・議事録の宿題から拾ったものは「確かめ待ち」に入り、本人が「入れる」と決めたものだけ帳に載る。
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
        /// 仕事中に拾った
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

        var kindOrDefault: Kind {
            if let kind { return kind }
            return source == .manual && from == nil ? .mine : .asked
        }

        /// 相手を待っているもの（人に頼んだもの・「待ち」にしたもの）
        var isWaiting: Bool { progress == .waiting || (kindOrDefault == .delegated && progress != .started) }
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
    var candidates: [Item] { items.filter { $0.state == .candidate }.sorted { $0.said > $1.said } }
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
            guard !what.isEmpty else { continue }
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

    func update(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        var copy = item
        copy.updated = .now
        items[i] = copy
        save()
    }

    func set(_ id: String, _ state: State) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = state
        items[i].doneAt = state == .done ? .now : nil
        items[i].updated = .now
        save()
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
    static var taskMorning: Int { UserDefaults.standard.object(forKey: taskMorningKey) as? Int ?? 8 * 60 }
    static var taskEvening: Int { UserDefaults.standard.object(forKey: taskEveningKey) as? Int ?? 18 * 60 }

    private static let taskClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 仕事の時間か（職場にいた時間か、平日の8時〜19時。職場の場所を登録していなくても拾えるように）
    private func taskTime(_ time: Date) -> Bool {
        if isWorkTime(time) { return true }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: time)
        return !cal.isDateInWeekend(time) && hour >= 8 && hour < 19
    }

    /// 閉じた会話（直近3日）のうち、仕事の時間の会話と★を付けた会話から、頼まれごとを拾う。1回に3つまで。
    /// 同じ会話は1回だけ見る（言語モデルが使えなかったときは、次の機会にやり直す）。
    func findTasks() async {
        guard let key = llmKey else { return }
        var scanned = UserDefaults.standard.stringArray(forKey: Self.taskScannedKey) ?? []
        defer { UserDefaults.standard.set(Array(scanned.suffix(800)), forKey: Self.taskScannedKey) }
        var budget = 3
        var found: [TaskBook.Item] = []
        scan: for day in recordedDays().prefix(3) {
            for c in conversations(on: day) where c.closed && c.media == nil {
                let id = day + "|" + String(Int(c.start.timeIntervalSince1970))
                guard !scanned.contains(id) else { continue }
                let lines = c.lines.filter { $0.media == nil }
                let marks = lines.filter { $0.marked == true }
                let work = taskTime(c.start)
                // ほかの人の行が無い会話（ひとりごと）は、★が無ければ見ない
                let others = lines.contains { $0.speakerID != SpeakerLabeler.selfID }
                guard !marks.isEmpty || (work && others && lines.count >= 3) else {
                    scanned.append(id)
                    continue
                }
                guard budget > 0 else { break scan }
                budget -= 1
                let transcript = lines.map { line in
                    Self.taskClock.string(from: line.time) + " " + (line.speaker.map { "[\($0)] " } ?? "") + line.text
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
                found += taskItems(result, in: c, lines: lines, marks: marks, day: day, work: work)
            }
        }
        let added = tasks.add(found)
        guard !added.isEmpty else { return }
        let waiting = added.filter { $0.state == .candidate }.count
        let opened = added.count - waiting
        var body = opened > 0 ? "帳に \(opened) 件入れました。" : ""
        if waiting > 0 { body += "確かめてほしいものが \(waiting) 件あります。" }
        body += "\n・" + added.prefix(3).map(\.what).joined(separator: "\n・")
        Self.notifyTasks(title: "頼まれごとを見つけました", body: body)
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
            items.append(TaskBook.Item(what: f.what, from: from, dueText: f.dueText.isEmpty ? nil : f.dueText,
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

    /// 議事録の宿題のうち、自分の（担当が自分か空の）ものを確かめ待ちに入れる
    func addMinuteTasks(_ todos: [Summarizer.Minutes.Todo], of c: ConversationLog.Conversation, day: String, title: String) {
        let mine = todos.filter { $0.who.isEmpty || $0.who.contains(SpeakerLabeler.selfName) || $0.who.contains("本人") }
        guard !mine.isEmpty else { return }
        tasks.add(mine.map { todo in
            TaskBook.Item(what: todo.what, dueText: todo.due.isEmpty ? nil : todo.due, said: c.start, day: day,
                          place: c.place, quote: "議事録「\(title)」の宿題", source: .minutes, state: .candidate, work: true)
        })
    }

    /// 写真の文字を読み取り（iPhone の中で）、やることを拾って確かめ待ちに入れる。結果の一文を返す。
    func addTasks(fromPhoto image: UIImage) async -> String {
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
            items = [TaskBook.Item(what: String(first.prefix(60)), said: now, quote: quote, source: .photo, state: .candidate)]
        } else {
            items = found.map { f in
                TaskBook.Item(what: f.what, from: f.from.isEmpty ? nil : f.from, dueText: f.dueText.isEmpty ? nil : f.dueText,
                              due: TaskBook.dueDate(f.dueDay), said: now,
                              quote: f.quote.isEmpty ? quote : f.quote, source: .photo, state: .candidate,
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
        Task { await scheduleTaskReminders() }
    }

    /// 朝と夕方（既定は8時と18時）に、まだ済んでいない頼まれごとを知らせる。7日先まで iOS に頼んでおき、帳が変わるたびに頼み直す。
    func scheduleTaskReminders() async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.taskNotifyPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        let open = tasks.open
        let waiting = tasks.candidates.count
        guard Self.taskRemindOn, !open.isEmpty || waiting > 0 else { return }
        let cal = Calendar.current
        let now = Date.now
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { continue }
            for (minutes, morning) in [(Self.taskMorning, true), (Self.taskEvening, false)] {
                let at = day.addingTimeInterval(TimeInterval(minutes * 60))
                guard at > now.addingTimeInterval(30) else { continue }
                let end = day.addingTimeInterval(86400)
                let mine = open.filter { !$0.isWaiting }
                let late = mine.filter { ($0.due ?? .distantFuture) < end }
                // 人に頼んで、期限を過ぎても済んでいないもの（相手に確かめる）
                let follow = open.filter { $0.isWaiting && ($0.due ?? .distantFuture) < end }
                var body = "まだ \(mine.count) 件" + (late.isEmpty ? "" : "（今日までのもの・過ぎたもの \(late.count) 件）")
                if waiting > 0 { body += "・確かめ待ち \(waiting) 件" }
                let urgentFirst = late.sorted { ($0.urgent == true) && ($1.urgent != true) }
                for item in (urgentFirst + mine.filter { !late.contains($0) }).prefix(3) {
                    // 先の日の知らせなので「明日まで」ではなく日付で
                    body += "\n・" + item.what + (item.due.map { "（" + Self.taskDueFormat.string(from: $0) + "まで）" } ?? "")
                }
                for item in follow.prefix(2) {
                    body += "\n・確かめる: " + item.what + (item.from.map { "（" + $0 + "へ）" } ?? "")
                }
                let content = UNMutableNotificationContent()
                content.title = morning ? "今日の頼まれごと" : "まだ済んでいない頼まれごと"
                content.body = body
                content.sound = .default
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                try? await center.add(UNNotificationRequest(
                    identifier: Self.taskNotifyPrefix + String(Int(at.timeIntervalSince1970)), content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
    }

    private static func notifyTasks(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "taskFound", content: content, trigger: nil))
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
        p.append(("まだ（\(tasks.open.count) 件）", "HEADING_2"))
        p += tasks.open.map { (line($0), nil) }
        if !tasks.candidates.isEmpty {
            p.append(("確かめ待ち（\(tasks.candidates.count) 件）", "HEADING_2"))
            p += tasks.candidates.map { (line($0), nil) }
        }
        if !tasks.done.isEmpty {
            p.append(("済み（30日以内）", "HEADING_2"))
            p += tasks.done.map { (line($0), nil) }
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

// MARK: - 画面

/// タスクタブ。下のタブから開く（自分の NavigationStack を持つ）。
struct TasksTab: View {
    var body: some View {
        NavigationStack { TaskBookView() }
    }
}

/// やることの画面。「やる」「待ち」「人」「済み」で切り替える。右上の＋で書き足す・写真から読み取る。
/// 頼まれごと・自分でやること・人に頼んだこと・約束を、1か所で追いかける。
struct TaskBookView: View {
    enum Page: String, CaseIterable, Identifiable {
        case todo = "やる", waiting = "待ち", people = "人", done = "済み"
        var id: String { rawValue }
    }

    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()
    @State private var page = Page.todo
    @State private var editing: TaskBook.Item?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var reading = false
    @State private var note: String?
    @State private var showSettings = false
    /// Pipeline.taskRemindKey などと同じ名前
    @AppStorage("taskRemind") private var remindOn = true
    @AppStorage("taskMorning") private var morning = 8 * 60
    @AppStorage("taskEvening") private var evening = 18 * 60

    var body: some View {
        let book = pipeline.tasks
        List {
            Section {
                Picker("見る", selection: $page) {
                    ForEach(Page.allCases) { p in Text(title(p, book)).tag(p) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let note {
                Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            if reading {
                Section { HStack { ProgressView(); Text("写真の文字を読み取っています…") } }
            }
            switch page {
            case .todo: todoPage(book)
            case .waiting: waitingPage(book)
            case .people: peoplePage(book)
            case .done: donePage(book)
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
                        editing = TaskBook.Item(what: "", said: .now, source: .manual, state: .open, work: true)
                    }
                    Button("人に頼んだことを書く", systemImage: "arrow.turn.up.right") {
                        editing = TaskBook.Item(what: "", said: .now, source: .manual, state: .open, work: true,
                                                kind: .delegated)
                    }
                    Button("写真を撮って読み取る", systemImage: "camera") { takingPhoto = true }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button("写真から読み取る", systemImage: "photo") { choosingPhoto = true }
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
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section {
                        Toggle("朝と夕方に知らせる", isOn: $remindOn)
                        if remindOn {
                            DatePicker("朝", selection: timeBinding($morning), displayedComponents: .hourAndMinute)
                            DatePicker("夕方", selection: timeBinding($evening), displayedComponents: .hourAndMinute)
                        }
                    } footer: {
                        Text("まだ済んでいないものの数と、期限の近いもの、期限を過ぎた「人に頼んだこと」を知らせます。仕事中（職場にいた時間か平日の8〜19時）の会話と、時計の★を付けた会話から拾います。頼まれた瞬間に★を押すと、確実に入ります。ドライブの「頼まれごと帳」にも写します。")
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

    private func title(_ p: Page, _ book: TaskBook) -> String {
        switch p {
        case .todo: let n = book.todo.count + book.candidates.count; return n > 0 ? "やる \(n)" : "やる"
        case .waiting: return book.waiting.isEmpty ? "待ち" : "待ち \(book.waiting.count)"
        case .people, .done: return p.rawValue
        }
    }

    // MARK: ページ

    @ViewBuilder
    private func todoPage(_ book: TaskBook) -> some View {
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
                        Button("違う", systemImage: "xmark", role: .destructive) { change(item.id, .rejected) }
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                }
            } header: {
                Text("確かめてほしい（\(book.candidates.count) 件）")
            } footer: {
                Text("会話・議事録・写真から拾ったものです。合っていれば「入れる」、違えば「違う」（同じものはもう出しません）。")
            }
        }
        let groups = TaskBook.grouped(book.todo)
        if groups.isEmpty {
            Section { Text("今やることはありません").foregroundStyle(.secondary) }
        }
        ForEach(groups, id: \.bucket) { group in
            Section {
                ForEach(group.items) { openRow($0) }
            } header: {
                Text("\(group.bucket.title)（\(group.items.count)）")
                    .foregroundStyle(group.bucket == .late ? Color.red : Color.secondary)
            }
        }
        let box = pipeline.suggestions
        if !box.waiting.isEmpty {
            Section("こんなのあったけど、どう？") {
                ForEach(box.waiting.prefix(3)) { SuggestionRow(item: $0) }
                if box.waiting.count > 3 || !box.kept.isEmpty {
                    NavigationLink("すべて見る（まだ \(box.waiting.count) 件・残している \(box.kept.count) 件）") {
                        SuggestionsView()
                    }
                }
            }
        }
        Section {
            EmptyView()
        } footer: {
            Text("○で済み。右へ払うと「明日に」「来週に」、左へ払うと「済み」「待ち」。急ぎ（!）は同じ並びの中で上に出ます。")
        }
    }

    @ViewBuilder
    private func waitingPage(_ book: TaskBook) -> some View {
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
    private func peoplePage(_ book: TaskBook) -> some View {
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
    private func donePage(_ book: TaskBook) -> some View {
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
        note = await pipeline.addTasks(fromPhoto: image)
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
                Text(Self.said.string(from: item.said) + "・" + item.source.label)
            }
            .font(.caption).foregroundStyle(.secondary)
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
                if let day = item.day {
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
            }
            Section("期限") {
                Toggle("期限がある", isOn: $hasDue)
                if hasDue {
                    DatePicker("期限の日", selection: $due, displayedComponents: .date)
                }
                if let dueText = item.dueText {
                    Text("聞いた言い方: \(dueText)").font(.caption).foregroundStyle(.secondary)
                }
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
                    item.due = hasDue ? Calendar.current.startOfDay(for: due) : nil
                    onSave(item)
                }
                .disabled(item.what.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            hasDue = item.due != nil
            due = item.due ?? .now
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

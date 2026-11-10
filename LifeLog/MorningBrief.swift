import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// 朝の「昨日と今日」（2026-11-09。前の「朝の読み上げ」を作り替えた）。
/// 本人の希望で、声の読み上げはやめ、昨日どんなことがあったか（1日のまとめの流れ・決まったこと・★・体調）と、
/// 今日の三つ（期限を過ぎた・今日までのタスク、母艦が選んだ「今日の三つ」）を、短い行で1通にまとめる。
/// 朝に別々に来ていた知らせ（朝の読み上げ・昨日の点検・タスクの朝の知らせ・聞いて直す）も、これ1通にした。
/// 言語モデルは使わない（決まった形で作るので、職場の中身も外に出ない）。
/// 夜の聞き直しの終わりと、5時を過ぎてアプリを開いたとき（まだ作っていなければ）に作る。
/// 作った文は UserDefaults（morningBriefRecord）に日付つきで1つだけ残す。
enum MorningBrief {
    static let onKey = "morningBriefOn"
    static let timeKey = "morningBriefTime"
    static let noticeID = "morning-brief"
    /// 今日の三つの数
    static let picks = 3
    /// 昨日の流れを出す行の数
    static let flowLines = 4

    /// 知らせるか（初めはオン）
    static var isOn: Bool { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
    /// 知らせる時刻（0時からの分。初めは7時）
    static var minutes: Int { UserDefaults.standard.object(forKey: timeKey) as? Int ?? 7 * 60 }

    struct EventLine: Equatable {
        /// 「10:00」
        var time: String
        var title: String
        var people: [String] = []
    }

    /// 今日の三つの1つ
    struct Pick: Equatable, Identifiable {
        var text: String
        /// 「期限切れ」「今日まで」「急ぎ」や、家の PC が書いたわけ
        var why: String
        /// 解き方の手順（家の PC が今の様子と照らして選んだときだけ。2026-11-10）
        var how: [String] = []
        /// だいたいの時間（分）
        var minutes: Int? = nil
        /// 送る文の下書き
        var draft: String? = nil
        /// 当たるアプリのタスク（あれば。済みにするのはこちら）
        var taskID: String? = nil
        /// 家の PC のやることの id（家の PC で済みにできるものだけ）
        var homeID: String? = nil

        var id: String { text }
        /// 解き方があるか
        var hasHowTo: Bool { !how.isEmpty || minutes != nil || draft != nil }
    }

    struct Input: Equatable {
        /// その朝の日
        var date: Date
        /// 昨日の1日のまとめの流れ（そのまま）
        var flow: [String] = []
        var decisions: [String] = []
        /// 昨日★を付けた行の数
        var marks: Int = 0
        /// 昨日の体調（睡眠・歩数の一文。ヘルスケアが使えなければ nil）
        var health: String? = nil
        var three: [Pick] = []
        var events: [EventLine] = []
        /// 気をつけること（1つずつ短い文）
        var checks: [String] = []
    }

    /// 「11/8(日)」（calendar の時間帯で）
    static func dayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "M/d(E)"
        return f.string(from: date)
    }

    /// 「10:00」
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: date), m = calendar.component(.minute, from: date)
        return String(format: "%d:%02d", h, m)
    }

    /// 1日のまとめの流れの1行を、短くする。
    /// 「06:28〜11:01　ダンス練習（自宅　サピ、ほか8人と）：練習計画／…」→「6:28〜11:01 ダンス練習（自宅　サピ、ほか8人と）」
    static func flowLine(_ text: String, limit: Int = 44) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 全角の「：」から後ろ（細かい話題）は落とす。時刻の「:」は半角なので残る
        if let colon = s.firstIndex(of: "：") { s = String(s[..<colon]) }
        // 時刻の頭の0（「06:28」→「6:28」）
        s = s.replacingOccurrences(of: "(^|〜)0([0-9]:)", with: "$1$2", options: .regularExpression)
        // 時刻のあとの全角の空白は1つの半角に
        if let range = s.range(of: "^[0-9:〜]+　", options: .regularExpression) {
            s.replaceSubrange(range, with: s[range].replacingOccurrences(of: "　", with: " "))
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > limit { s = String(s.prefix(limit - 1)) + "…" }
        return s
    }

    /// 長い文を limit 文字までに
    static func short(_ text: String, limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }

    /// 知らせと画面に出す文（行ごと）
    static func card(_ input: Input, calendar: Calendar = .current) -> String {
        var lines: [String] = []
        let yesterday = calendar.date(byAdding: .day, value: -1, to: input.date) ?? input.date
        var past: [String] = input.flow.prefix(flowLines).map { "・" + flowLine($0) }
        if let decision = input.decisions.first, !decision.isEmpty {
            past.append("・決まったこと: " + decision.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var extra: [String] = []
        if input.marks > 0 { extra.append("★ \(input.marks) か所") }
        if let health = input.health, !health.isEmpty { extra.append(health) }
        if !extra.isEmpty { past.append("・" + extra.joined(separator: "／")) }
        if !past.isEmpty {
            lines.append("昨日 " + dayLabel(yesterday, calendar: calendar))
            lines += past
        }
        if !input.three.isEmpty {
            lines.append("今日の三つ")
            for (i, pick) in input.three.prefix(picks).enumerated() {
                lines.append("\(i + 1). " + pick.text + (pick.why.isEmpty ? "" : "（\(pick.why)）"))
            }
            // 解き方があれば、最初の一歩だけ1行で（2026-11-10）
            if let step = input.three.prefix(picks).compactMap({ $0.how.first }).first {
                lines.append("まず: " + short(step, limit: 40))
            }
        }
        if let first = input.events.first {
            var line = "予定: " + first.time + " " + first.title
            if !first.people.isEmpty {
                line += "（" + first.people.prefix(3).map { WatchInfo.politeName($0) }.joined(separator: "、") + "）"
            }
            if input.events.count > 1 { line += " ほか\(input.events.count - 1)件" }
            lines.append(line)
        }
        if !input.checks.isEmpty { lines.append(input.checks.joined(separator: "・")) }
        if lines.isEmpty { lines.append(dayLabel(input.date, calendar: calendar) + "。昨日の記録と今日のやることはまだありません。") }
        return lines.joined(separator: "\n")
    }

    /// 今日の三つを選ぶ。期限を過ぎた・今日までのタスク（急ぎを先に）→ 家の PC が選んだもの → 急ぎ → 今週まで
    /// → 家の PC のやることで14日以内に足されたもの（期限の近い順・新しい順。recent）。
    /// chosen（家の PC が今の様子と照らして選んだ。2026-11-10）なら、家の PC が選んだものを先にする。
    /// 家の PC が「アプリのタスク」としたもの（origin "app"）は、まだのタスクに当たるときだけ入れる。
    /// 休みの日は仕事のものを入れない（仕事の印の付いた家の PC のものも）。同じらしいものは1つ
    static func pickThree(open: [TaskBook.Item], mothership: [MothershipExport.Three], mothershipWork: Set<String>,
                          recent: [MothershipTodo] = [], dayOff: Bool, now: Date, chosen: Bool = false,
                          calendar: Calendar = .current) -> [Pick] {
        let items = tasksToRead(open, dayOff: dayOff)
        func sorted(_ list: [TaskBook.Item]) -> [TaskBook.Item] {
            list.sorted { a, b in
                if (a.urgent == true) != (b.urgent == true) { return a.urgent == true }
                return (a.dueMoment ?? .distantFuture) < (b.dueMoment ?? .distantFuture)
            }
        }
        var picks: [Pick] = []
        func add(_ pick: Pick) {
            guard picks.count < Self.picks, !picks.contains(where: { TaskBook.similar($0.text, pick.text) }) else { return }
            picks.append(pick)
        }
        func addTask(_ item: TaskBook.Item, _ why: String) {
            add(Pick(text: item.what, why: why, taskID: item.id))
        }
        func addHome(_ three: MothershipExport.Three) {
            var pick = Pick(text: three.text, why: three.why ?? "", how: three.how ?? [], minutes: three.minutes,
                            draft: three.draft)
            if three.isAppTask {
                // アプリのタスク: 元の文で、まだのタスクを探す（無ければ、もう済んだ・休みの日の仕事なので入れない）。
                // id は家の PC の印なので、家の PC には済みを送らない（homeID は付けない）
                guard let task = OneTaskList.match(three.itemText ?? three.text, in: items) else { return }
                pick.taskID = task.id
            } else {
                if dayOff && (mothershipWork.contains(three.id) || three.work == true) { return }
                if three.origin == nil || three.origin == "todo" { pick.homeID = three.id }
                pick.taskID = OneTaskList.match(three.text, in: items)?.id
            }
            add(pick)
        }
        let bucket = { (item: TaskBook.Item) in TaskBook.bucket(item, now: now, calendar: calendar) }
        if chosen { for three in mothership { addHome(three) } }
        for item in sorted(items.filter { bucket($0) == .late }) { addTask(item, "期限切れ") }
        for item in sorted(items.filter { bucket($0) == .today }) { addTask(item, "今日まで") }
        if !chosen { for three in mothership { addHome(three) } }
        for item in sorted(items.filter { $0.urgent == true }) { addTask(item, "急ぎ") }
        for item in sorted(items.filter { bucket($0) == .week }) { addTask(item, "今週") }
        let fresh = TaskBook.dayFormat.string(from: now.addingTimeInterval(-14 * 86400))
        for todo in recent where (todo.added ?? "") >= fresh && !(dayOff && todo.work == true) {
            let added = todo.added.map { String($0.suffix(5)).replacingOccurrences(of: "-", with: "/") } ?? ""
            add(Pick(text: todo.text, why: added + " に足した", homeID: todo.id))
        }
        return picks
    }

    /// 読む頼まれごと。休みの日は仕事以外だけ（印の無い古いものは仕事とみなす。2026-11-07）
    static func tasksToRead(_ items: [TaskBook.Item], dayOff: Bool) -> [TaskBook.Item] {
        dayOff ? TaskBook.filter(items, .life) : items
    }
}

/// 作った朝の「昨日と今日」（1つだけ持つ）
struct MorningBriefRecord: Codable, Equatable {
    /// どの日の朝の分か（yyyy-MM-dd）
    var day: String
    var text: String
    var made: Date
    /// 前の日の1日のまとめが入っているか（まだ無いときに作ったら、まとめができたあとで作り直す）
    var hadSummary: Bool? = nil
    /// 家の PC の1日のまとめを使ったか（2026-11-10。使っていなくて、あとから届いたら作り直す）
    var fromHome: Bool? = nil
    /// 使った家の PC の「今日の三つ」の作った時刻（2026-11-10。新しく選び直されたら作り直す）
    var planAt: String? = nil
    /// 言語モデルでまとめたか（2026-11-09 からは使わない。前の記録を読むために残す）
    var usedModel: Bool? = nil
}

@MainActor
@Observable
final class MorningBriefStore {
    static let shared = MorningBriefStore()
    static let key = "morningBriefRecord"

    private(set) var current: MorningBriefRecord?
    /// 作っている最中か
    var making = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            current = try? JSONDecoder().decode(MorningBriefRecord.self, from: data)
        }
    }

    func save(_ record: MorningBriefRecord) {
        current = record
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

private let briefDayKey: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

extension Pipeline {
    /// 夜の聞き直しの終わりに呼ぶ。昼より後なら次の日の朝の分、昼より前ならその日の分を作る
    func makeMorningBriefAtNight() async {
        let cal = Calendar.current
        let now = Date.now
        let today = cal.startOfDay(for: now)
        let target = cal.component(.hour, from: now) >= 12 ? (cal.date(byAdding: .day, value: 1, to: today) ?? today) : today
        await makeMorningBrief(for: target)
    }

    /// アプリを開いたときに呼ぶ。5時を過ぎていて、今日の分がまだ（か、前の日のまとめができる前に作った）なら作る
    func morningBriefOnActive() {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: .now)
        defer { pushWatchInfo() }
        guard hour >= 5, hour < 22 else { return }
        Task { await makeMorningBrief(for: cal.startOfDay(for: .now)) }
    }

    /// その日の朝の分を作る必要があるか
    func needsMorningBrief(for day: Date) -> Bool {
        let key = briefDayKey.string(from: day)
        guard let current = MorningBriefStore.shared.current, current.day == key else { return true }
        // 家の PC が今日の三つを選び直したら作り直す（2026-11-10）
        if let export = mothership.export, export.chosenFromSituation(day: key),
           let at = export.plan?.generatedAt, at != current.planAt { return true }
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day) else { return false }
        let yesterdayKey = briefDayKey.string(from: yesterday)
        // 家の PC の1日のまとめがあとから届いたら作り直す（2026-11-10）
        if current.fromHome != true, mothership.daySummary(yesterdayKey) != nil { return true }
        // 前の日のまとめが無いときに作ったなら、まとめができていれば作り直す
        guard current.hadSummary != true else { return false }
        return daySummary(yesterdayKey) != nil
    }

    /// 朝の分を作って残し、知らせを頼み、時計にも送る。force なら作り直す
    func makeMorningBrief(for day: Date, force: Bool = false) async {
        let store = MorningBriefStore.shared
        guard !store.making, force || needsMorningBrief(for: day) else { return }
        store.making = true
        defer { store.making = false }
        let start = Calendar.current.startOfDay(for: day)
        await mothership.refresh(homePC)
        let (input, hadSummary) = await morningBriefInput(for: start)
        let key = briefDayKey.string(from: start)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: start) ?? start
        let fromHome = mothership.daySummary(briefDayKey.string(from: yesterday)) != nil
        let chosen = mothership.export?.chosenFromSituation(day: key) ?? false
        let planAt = chosen ? mothership.export?.plan?.generatedAt : nil
        store.save(MorningBriefRecord(day: key, text: MorningBrief.card(input), made: .now,
                                      hadSummary: hadSummary, fromHome: fromHome, planAt: planAt))
        await scheduleMorningBriefNotice()
        pushWatchInfo(force: true)
    }

    /// 今日の三つ（タスクの「やる」の上にも出す）
    func todayThree(on day: Date = .now) -> [MorningBrief.Pick] {
        let items = mothership.export?.items ?? []
        let workIDs = Set(items.filter { $0.work == true }.map(\.id))
        let ids = Set(items.map(\.id))
        // 家の PC が今の様子と照らして選んだ日（2026-11-10）は、選んだものを全部（アプリのタスク・決めごと・新しいことも）。
        // そうでなければ前と同じく、家の PC のやることにあるものだけ（決めごとの期限切れなどは、アプリで済みにできないので出さない）
        let chosen = mothership.export?.chosenFromSituation(day: briefDayKey.string(from: day)) ?? false
        let threes = chosen ? mothership.todayThree : mothership.todayThree.filter { ids.contains($0.id) }
        var picks = MorningBrief.pickThree(open: tasks.todo, mothership: threes, mothershipWork: workIDs,
                                           recent: mothership.open(.all), dayOff: isDayOff(day), now: day, chosen: chosen)
        // 家の PC で済みにできるのは、家の PC のやることにあるものだけ
        for i in picks.indices {
            if let id = picks[i].homeID, !ids.contains(id) { picks[i].homeID = nil }
        }
        return picks
    }

    /// 材料を集める。hadSummary は前の日の1日のまとめがあったか
    func morningBriefInput(for start: Date) async -> (input: MorningBrief.Input, hadSummary: Bool) {
        let cal = Calendar.current
        var input = MorningBrief.Input(date: start)
        // 昨日
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: start) ?? start
        let yesterday = briefDayKey.string(from: yesterdayStart)
        let summary = daySummary(yesterday)
        if let summary {
            input.flow = summary.flow
            input.decisions = Array(summary.decisions.prefix(2))
        }
        // 家の PC の1日のまとめがあれば、昨日の流れはそちらから（2026-11-10。無ければアプリのまとめのまま）
        let home = mothership.daySummary(yesterday)
        if let home, !home.flow.isEmpty {
            input.flow = home.flow
            if !home.decisions.isEmpty { input.decisions = Array(home.decisions.prefix(2)) }
        }
        input.marks = conversations(on: yesterday).flatMap(\.lines).filter { $0.marked == true }.count
        input.health = await health.dayLine(yesterdayStart)
        // 今日の三つ（朝の時刻で選ぶ）
        let morning = start.addingTimeInterval(TimeInterval(MorningBrief.minutes * 60))
        input.three = todayThree(on: max(morning, .now))
        // 今日の予定
        let events = calendar.dayEvents(from: start, to: start.addingTimeInterval(24 * 3600))
            .filter { cal.isDate($0.start, inSameDayAs: start) }
        for event in events.prefix(8) {
            input.events.append(MorningBrief.EventLine(time: MorningBrief.clock(event.start, calendar: cal),
                                                       title: event.title.isEmpty ? "予定" : event.title,
                                                       people: Array(eventPeople(event).all.prefix(3))))
        }
        // 気をつけること（前は別に知らせていた「昨日の点検」もここに。2026-11-09）
        let dayOff = isDayOff(start)
        let waiting = MorningBrief.tasksToRead(tasks.candidates, dayOff: dayOff).count
        if waiting > 0 { input.checks.append("確かめ待ち \(waiting) 件") }
        if pendingCount > 0 { input.checks.append("文字起こし待ち \(pendingCount) 件") }
        if let check = morningCheckLine(for: yesterdayStart) { input.checks.append(check) }
        return (input, summary != nil || home != nil)
    }

    /// 朝の「昨日と今日」の知らせを、決めた時刻（初めは7時）に頼む。もう過ぎていれば頼まない。iPad では出さない（二重にならないように）
    func scheduleMorningBriefNotice() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [MorningBrief.noticeID, ReviewNudge.noticeID])
        guard MorningBrief.isOn, UIDevice.current.userInterfaceIdiom != .pad,
              let record = MorningBriefStore.shared.current,
              let day = briefDayKey.date(from: record.day) else { return }
        let at = day.addingTimeInterval(TimeInterval(MorningBrief.minutes * 60))
        guard at > Date.now.addingTimeInterval(30) else { return }
        let content = UNMutableNotificationContent()
        content.title = "昨日と今日"
        content.body = record.text
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        try? await center.add(UNNotificationRequest(
            identifier: MorningBrief.noticeID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}

// MARK: - 画面

/// 「今日」の「昨日と今日」（今日か明日の分があるときだけ）
struct MorningBriefSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let store = MorningBriefStore.shared
        let today = briefDayKey.string(from: .now)
        if let record = store.current, record.day >= today {
            Section {
                Text(record.text)
                    .font(.callout)
                // 今日の三つの解き方（家の PC が手順・下書きを付けたものだけ。2026-11-10）
                if record.day == today {
                    let three = pipeline.todayThree()
                    ForEach(Array(three.enumerated()), id: \.offset) { i, pick in
                        if pick.hasHowTo { TodayPickRow(number: i + 1, pick: pick) }
                    }
                }
                Button {
                    Task { await pipeline.makeMorningBrief(for: Calendar.current.startOfDay(for: .now), force: true) }
                } label: {
                    if store.making {
                        ProgressView()
                    } else {
                        Label("今日の分を作り直す", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.making)
            } header: {
                Text(record.day == today ? "昨日と今日" : "昨日と今日（明日の分）")
            } footer: {
                Text(record.made.formatted(date: .abbreviated, time: .shortened) + " に作りました")
            }
        }
    }
}

/// 設定の「朝に「昨日と今日」を知らせる」と時刻
struct MorningBriefSettingsRows: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(MorningBrief.onKey) private var on = true
    @AppStorage(MorningBrief.timeKey) private var minutes = 7 * 60

    var body: some View {
        Toggle("朝に「昨日と今日」を知らせる", isOn: $on)
            .onChange(of: on) { Task { await pipeline.scheduleMorningBriefNotice(); pipeline.tasksChanged() } }
        if on {
            DatePicker("朝の知らせの時刻", selection: time, displayedComponents: .hourAndMinute)
                .onChange(of: minutes) { Task { await pipeline.scheduleMorningBriefNotice() } }
        }
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes * 60))
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
        }
    }
}

/// 今日の三つの1行（タスクの「やる」の上と、「今日」の「昨日と今日」）。押すと「解き方」（2026-11-10）
struct TodayPickRow: View {
    let number: Int
    let pick: MorningBrief.Pick
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    if !pick.why.isEmpty {
                        Text(pick.why).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    if let first = pick.how.first {
                        Text("まず: " + first).font(.caption).foregroundStyle(.blue).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if pick.hasHowTo {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showing) {
            NavigationStack { PickHowToView(pick: pick) }
                .presentationDetents([.medium, .large])
        }
    }
}

/// 「解き方」: 手順・だいたいの時間・送る文の下書き（コピーできる）と、当たるタスク
struct PickHowToView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let pick: MorningBrief.Pick
    @State private var copied = false

    var body: some View {
        let task: TaskBook.Item? = pick.taskID.flatMap { id in pipeline.tasks.items.first { $0.id == id } }
        let home: MothershipTodo? = pick.homeID.flatMap { id in pipeline.mothership.export?.items.first { $0.id == id } }
        Form {
            Section {
                Text(pick.text).font(.headline)
                if !pick.why.isEmpty { Text(pick.why).foregroundStyle(.secondary) }
            } header: {
                Text("やること")
            }
            if !pick.how.isEmpty {
                Section("解き方") {
                    ForEach(Array(pick.how.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1).").foregroundStyle(.secondary)
                            Text(step)
                        }
                    }
                }
            }
            if let minutes = pick.minutes {
                Section {
                    LabeledContent("かかる時間", value: "だいたい \(minutes) 分")
                }
            }
            if let draft = pick.draft {
                Section {
                    Text(draft).textSelection(.enabled)
                    Button(copied ? "コピーしました" : "下書きをコピー", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = draft
                        copied = true
                    }
                } header: {
                    Text("送る文の下書き")
                } footer: {
                    Text("送る前に、中身を確かめて直してください。")
                }
            }
            if let task, task.state == .open {
                Section {
                    Text(task.what)
                    if let due = task.due { LabeledContent("期限", value: Pipeline.taskDueText(due)) }
                    Button("このタスクを済みにする", systemImage: "checkmark.circle") {
                        pipeline.tasks.set(task.id, .done)
                        pipeline.tasksChanged()
                        dismiss()
                    }
                } header: {
                    Text("タスク")
                }
            } else if let home {
                Section {
                    Button("済みにする", systemImage: "checkmark.circle") {
                        Task { await pipeline.mothership.markDone(home, pc: pipeline.homePC) }
                        dismiss()
                    }
                }
            }
            if !pick.hasHowTo {
                Section {
                    Text("解き方はまだありません。家の PC が今の様子と照らして選んだ日に出ます。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("解き方")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
        }
    }
}

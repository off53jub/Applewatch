import Foundation
import UIKit
import WatchConnectivity

/// 時計の画面に出す中身（2026-11-07）。iPhone が作って、時計の設定（applicationContext）と一緒に送る。
/// まだの頼まれごと（今日まで・過ぎたものが先。15件まで）・12時間以内の次の予定（会う人と前回の話）・
/// さっき閉じた会話・iPhone の様子・朝の読み上げ。送るのは時計だけで、クラウドには送らない。
/// 時計の側（LifeLogWatch/WatchBoard.swift）も同じ名前の形で読む。形を変えるときは両方を直す。
struct WatchInfo: Codable, Equatable {
    struct TaskItem: Codable, Equatable {
        var id: String
        var what: String
        /// 「今日まで」「2日過ぎ」など
        var due: String? = nil
        /// 頼んだ人
        var from: String? = nil
        /// 今日までのもの・過ぎたもの
        var late: Bool = false
        /// 期限を過ぎたもの・相手を待っているもの（文字盤の数に使う。違えば省く。2026-11-07）
        var overdue: Bool? = nil
        var waiting: Bool? = nil
    }

    struct Event: Codable, Equatable {
        var title: String
        var start: Double
        var end: Double
        var people: [String] = []
        /// 会う前のおさらい（前回話したこと。300文字まで）
        var brief: String? = nil
        var place: String? = nil
    }

    struct Talk: Codable, Equatable {
        var start: Double
        var end: Double
        var title: String? = nil
        var points: [String] = []
        var people: [String] = []
        var place: String? = nil
    }

    struct Status: Codable, Equatable {
        /// iPhone の文字起こし待ちの数
        var pending: Int
        /// 最後に文字起こしを進めた時刻
        var processed: Double? = nil
    }

    struct Brief: Codable, Equatable {
        /// どの日の朝の分か（yyyy-MM-dd）
        var day: String
        var text: String
    }

    /// 作った時刻
    var made: Double
    var tasks: [TaskItem] = []
    /// まだの頼まれごとの数（15件より多くても数える）
    var openCount: Int = 0
    var next: Event? = nil
    var last: Talk? = nil
    var status: Status
    var morning: Brief? = nil
    /// 今日までの頼まれごとの数と、そのうち期限を過ぎた数（相手を待っているものは数えない。15件より多くても数える。
    /// 文字盤に出す。2026-11-07。WidgetBridge.taskCounts）
    var dueCount: Int? = nil
    var overdueCount: Int? = nil

    /// 時計に送る applicationContext の名前
    static let contextKey = "watchInfo"
    /// 送る大きさの上限（applicationContext は小さく保つ）
    static let maxBytes = 32_000
    static let maxTasks = 15
    static let maxBrief = 300
    static let maxPoints = 3

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        return f
    }()

    /// 長い文を n 文字に縮める（縮めたら最後を「…」に）
    static func clip(_ text: String, _ n: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > n, n > 1 else { return trimmed }
        return String(trimmed.prefix(n - 1)) + "…"
    }

    /// 時計に出す頼まれごと。まだのものだけ、期限切れ・今日まで → 今週 → それより先 → 期限なしの順（同じ並びの中は急ぎが先）
    static func taskItems(_ items: [TaskBook.Item], now: Date, calendar: Calendar = .current,
                          limit: Int = maxTasks) -> [TaskItem] {
        let open = items.filter { $0.state == .open }
        let ordered = TaskBook.grouped(open, now: now).flatMap { $0.items }
        return ordered.prefix(limit).map { item in
            let bucket = TaskBook.bucket(item, now: now, calendar: calendar)
            return TaskItem(id: item.id, what: clip(item.what, 80),
                            due: dueLabel(item, now: now, calendar: calendar),
                            from: item.from.map { clip($0, 20) },
                            late: bucket == .late || bucket == .today,
                            overdue: bucket == .late ? true : nil,
                            waiting: item.isWaiting ? true : nil)
        }
    }

    /// 期限の言い方（「今日 15:00まで」「明日まで」「11/9(月)まで」「2日過ぎ」）。期限の日が無ければ、聞いたままの言い方
    static func dueLabel(_ item: TaskBook.Item, now: Date, calendar: Calendar = .current) -> String? {
        guard let due = item.due else {
            guard let said = item.dueText, !said.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return clip(said, 20)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: due)).day ?? 0
        if days < 0 { return "\(-days)日過ぎ" }
        let head: String
        switch days {
        case 0: head = "今日"
        case 1: head = "明日"
        default: head = dayLabel.string(from: due)
        }
        let time = item.dueTime.map { String(format: " %d:%02d", $0 / 60, $0 % 60) } ?? ""
        return head + time + "まで"
    }

    /// 並びが毎回同じになるように JSON にする
    static func encode(_ info: WatchInfo) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(info)
    }

    /// 上限（既定 32KB）に収まるまで、長いものから縮めて JSON にする。どうしても収まらなければ nil
    static func capped(_ info: WatchInfo, limit: Int = maxBytes) -> Data? {
        var info = info
        guard var data = encode(info) else { return nil }
        while data.count > limit {
            if let morning = info.morning, morning.text.count > 400 {
                info.morning?.text = clip(morning.text, 400)
            } else if let brief = info.next?.brief, brief.count > 120 {
                info.next?.brief = clip(brief, 120)
            } else if let last = info.last, last.points.count > 1 {
                info.last?.points = Array(last.points.prefix(1))
            } else if info.tasks.count > 3 {
                info.tasks.removeLast()
            } else if let morning = info.morning, morning.text.count > 100 {
                info.morning?.text = clip(morning.text, 100)
            } else if info.next?.brief != nil {
                info.next?.brief = nil
            } else if info.last != nil {
                info.last = nil
            } else if !info.tasks.isEmpty {
                info.tasks.removeLast()
            } else if info.morning != nil {
                info.morning = nil
            } else if info.next != nil {
                info.next = nil
            } else {
                return nil
            }
            guard let smaller = encode(info) else { return nil }
            data = smaller
        }
        return data
    }

    /// 名前に「さん」などが付いていなければ「さん」を付ける（読み上げ・時計の表示用。記録の名前は変えない）
    static func politeName(_ name: String) -> String {
        let honorifics = ["さん", "くん", "君", "ちゃん", "さま", "様", "先生", "先輩", "氏", "部長", "課長", "社長"]
        if name == SpeakerLabeler.selfName || honorifics.contains(where: { name.hasSuffix($0) }) { return name }
        return name + "さん"
    }
}

/// 時計に送った中身と、送った時刻（Pipeline の外に持つ。2026-11-07）
@MainActor
final class WatchInfoState {
    static let shared = WatchInfoState()
    var sentAt = Date.distantPast
    /// 前に送った中身（作った時刻を除いて比べる）
    var lastKey: Data?
    var loop: Task<Void, Never>?
    /// 次の予定のおさらい（同じ予定なら30分は作り直さない）
    var briefFor = ""
    var briefAt = Date.distantPast
    var briefText: String?
}

/// 会った日の言い方（おさらい用）
private let watchBriefDate: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ja_JP")
    f.dateFormat = "M/d(E)"
    return f
}()

private let watchDayKey: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

extension Pipeline {
    /// 時計のアプリとのやりとりを用意する（init から1回だけ呼ぶ）。
    /// 時計の「済み」と「聞く」を受け、時計に送る中身を1分ごとに確かめて、変わっていたら送る。
    func setUpWatchApp() {
        receiver.onTaskDone = { [weak self] id in self?.watchTaskDone(id) }
        // 時計の様子（録音中か）が届いたら、iPhone のウィジェットも出し直す（2026-11-07。WidgetBridge.swift）
        receiver.onWatchContext = { [weak self] in self?.updateWidgets() }
        receiver.onQuestion = { [weak self] question in
            guard let self else { return "iPhone の LifeLog の準備ができていません。" }
            return await self.answerFromWatch(question)
        }
        startWatchInfo()
    }

    /// 1分ごとに、時計に送る中身が変わっていないか確かめる
    func startWatchInfo() {
        let state = WatchInfoState.shared
        guard state.loop == nil else { return }
        state.loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                self?.pushWatchInfo()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// 時計に中身を送る。変わっていなければ送らない。force でなければ1分に1回まで（間に合わなかった分は次の確かめで送る）
    func pushWatchInfo(force: Bool = false) {
        // iPhone のウィジェットの中身も確かめる（時計が無くても。変わったときだけ書く。2026-11-07。WidgetBridge.swift）
        updateWidgets()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let state = WatchInfoState.shared
        guard force || Date.now.timeIntervalSince(state.sentAt) >= 59 else { return }
        let info = buildWatchInfo()
        var compare = info
        compare.made = 0
        let key = WatchInfo.encode(compare)
        guard force || key != state.lastKey else { return }
        guard let data = WatchInfo.capped(info) else { return }
        state.lastKey = key
        state.sentAt = .now
        receiver.sendWatchInfo(data)
    }

    /// 時計に出す中身を作る
    func buildWatchInfo(now: Date = .now) -> WatchInfo {
        let open = tasks.open
        var info = WatchInfo(made: now.timeIntervalSince1970,
                             status: WatchInfo.Status(pending: pendingCount,
                                                      processed: diagnostics.runs.last?.start.timeIntervalSince1970))
        info.tasks = WatchInfo.taskItems(open, now: now)
        info.openCount = open.count
        let counts = WidgetBridge.taskCounts(open, now: now)
        info.dueCount = counts.due
        info.overdueCount = counts.overdue
        info.next = nextEventForWatch(now: now)
        info.last = lastTalkForWatch()
        let today = watchDayKey.string(from: now)
        if let brief = MorningBriefStore.shared.current, brief.day >= today {
            info.morning = WatchInfo.Brief(day: brief.day, text: brief.text)
        }
        return info
    }

    /// 12時間以内の次の予定（始まって10分までのものも含む）
    private func nextEventForWatch(now: Date) -> WatchInfo.Event? {
        let events = calendar.dayEvents(from: now, to: now.addingTimeInterval(12 * 3600))
            .filter { $0.start >= now.addingTimeInterval(-10 * 60) && $0.start <= now.addingTimeInterval(12 * 3600) }
        guard let event = events.first else { return nil }
        let found = eventPeople(event)
        let state = WatchInfoState.shared
        let key = event.title + "|\(Int(event.start.timeIntervalSince1970))"
        if state.briefFor != key || now.timeIntervalSince(state.briefAt) > 30 * 60 {
            state.briefFor = key
            state.briefAt = now
            state.briefText = meetingNote(for: found.known, before: now).map { WatchInfo.clip($0, WatchInfo.maxBrief) }
        }
        return WatchInfo.Event(title: WatchInfo.clip(event.title.isEmpty ? "予定" : event.title, 60),
                               start: event.start.timeIntervalSince1970, end: event.end.timeIntervalSince1970,
                               people: Array(found.all.prefix(6)).map { WatchInfo.clip($0, 20) },
                               brief: state.briefText, place: event.location.map { WatchInfo.clip($0, 40) })
    }

    /// 予定で会う人。all は参加者の名前と、予定名に入っている名前を付けた人。known は名前を付けた人だけ（おさらいに使う）
    func eventPeople(_ event: CalendarLink.Event) -> (all: [String], known: [String]) {
        let named = people.filter { $0.isNamed && !$0.isSelf && $0.hidden != true }
        let known = named.map(\.displayName).filter { name in
            let key = Self.nameKey(name)
            return event.attendees.contains { Self.sameName($0, name) }
                || (key.count >= 2 && event.title.contains(key))
        }
        var all = known
        for name in event.attendees where !all.contains(where: { Self.sameName($0, name) }) { all.append(name) }
        return (all, known)
    }

    /// 会う人それぞれと前回話した閉じた会話の、日付・見出し・要点（会う前のおさらいと同じ選び方）。前に話していなければ nil
    func meetingNote(for names: [String], before: Date) -> String? {
        guard !names.isEmpty else { return nil }
        var wanted = Set(names)
        var last: [String: ConversationLog.Conversation] = [:]
        search: for day in recordedDays().prefix(60) {
            for c in conversations(on: day).reversed() where c.closed && c.media == nil && c.start < before {
                for name in c.people where wanted.contains(name) {
                    last[name] = c
                    wanted.remove(name)
                }
                if wanted.isEmpty { break search }
            }
        }
        var parts: [String] = []
        for name in names {
            guard let c = last[name] else { continue }
            var text = "\(WatchInfo.politeName(name))：前回 \(watchBriefDate.string(from: c.start))"
            if let title = c.title, !title.isEmpty { text += "「\(title)」" }
            for point in c.points.prefix(2) { text += "\n・" + point }
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// いちばん新しい、閉じた会話（テレビ・動画は除く）
    private func lastTalkForWatch() -> WatchInfo.Talk? {
        let hidden = Set(people.filter { $0.hidden == true }.map(\.displayName))
        for day in recordedDays().prefix(3) {
            let closed = conversations(on: day).filter { $0.closed && $0.media == nil }
            guard let c = closed.max(by: { $0.end < $1.end }) else { continue }
            let names = c.people.filter { $0 != SpeakerLabeler.selfName && !hidden.contains($0) }
            return WatchInfo.Talk(start: c.start.timeIntervalSince1970, end: c.end.timeIntervalSince1970,
                                  title: c.title.map { WatchInfo.clip($0, 60) },
                                  points: c.points.prefix(WatchInfo.maxPoints).map { WatchInfo.clip($0, 120) },
                                  people: Array(names.prefix(6)), place: c.place.map { WatchInfo.clip($0, 40) })
        }
        return nil
    }

    /// 時計で「済み」を押した。まだの頼まれごとだけ済みにする（確かめ待ちなどは変えない）
    func watchTaskDone(_ id: String) {
        if let item = tasks.items.first(where: { $0.id == id }), item.state == .open {
            tasks.set(id, .done)
            tasksChanged()
        }
        pushWatchInfo(force: true)
    }

    /// 時計の「聞く」に、「記録に質問する」と同じしかたで答える（職場の会話の扱いも同じ）
    func answerFromWatch(_ question: String) async -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "質問が空でした。" }
        // 時計に起こされて裏で答えるときも、答え終わるまで続けさせてもらう
        let background = UIApplication.shared.beginBackgroundTask(withName: "watchAsk")
        defer {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        do {
            let answer = try await ask(q)
            let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "記録に見つかりませんでした。" : WatchInfo.clip(text, 800)
        } catch {
            return "答えられませんでした: " + error.localizedDescription
        }
    }
}

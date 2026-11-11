import Foundation

/// iPhone のウィジェット（ロック画面・ホーム画面の「LifeLog の様子」）に出す中身を作る（2026-11-07）。
/// 録音しているか（iPhone・時計）・今日までと期限切れの頼まれごと・次の予定・最後に文字にした時刻・家の PC とつながるか。
/// 時計に送る中身を確かめるとき（1分ごと）・録音を始めた/止めたとき・時計の様子が届いたときに updateWidgets を呼ぶ。
/// 中身は App Group の WidgetState（Shared/Widget）。変わったときだけ書き、ウィジェットには多くても1分に1回、読み直してもらう。
/// App Group が使えない入れ方（署名なしの IPA）では何も書かない（ウィジェットは「—」を出す）。
enum WidgetBridge {
    /// 時計からこれより長く知らせが無ければ、録音中でも「届いていません」にする
    /// （時計は5分ごとに知らせ、録音の帳簿は同じ様子を15分に1回だけ残すので、少し長めに待つ）
    static let watchQuietAfter: TimeInterval = 30 * 60

    /// 今日までの頼まれごとの数・そのうち期限を過ぎた数・まだのもの全部の数。
    /// 今日まで・期限切れは、朝の読み上げ・頼まれごとの知らせと同じく、相手を待っているものを数えない（全部の数には入れる）
    static func taskCounts(_ items: [TaskBook.Item], now: Date,
                           calendar: Calendar = .current) -> (due: Int, overdue: Int, open: Int) {
        var due = 0
        var overdue = 0
        var open = 0
        for item in items where item.state == .open {
            open += 1
            guard !item.isWaiting else { continue }
            switch TaskBook.bucket(item, now: now, calendar: calendar) {
            case .late:
                due += 1
                overdue += 1
            case .today:
                due += 1
            default:
                break
            }
        }
        return (due, overdue, open)
    }

    /// ウィジェットに出す頼まれごとの文（今日まで・期限を過ぎたもの。無ければ期限の近いまだのもの。急ぎを先に。3件・30字まで）。
    /// todo は人を待っているもの以外のまだのもの（期限の近い順）
    static func taskTitles(_ todo: [TaskBook.Item], now: Date, calendar: Calendar = .current) -> [String] {
        let soon: [TaskBook.Item] = todo.filter { item in
            let bucket = TaskBook.bucket(item, now: now, calendar: calendar)
            return bucket == .late || bucket == .today
        }
        let picked: [TaskBook.Item] = (soon.isEmpty ? todo : soon)
            .sorted { a, b in (a.urgent == true) != (b.urgent == true) ? a.urgent == true : TaskBook.dueOrder(a, b) }
        return picked.prefix(3).map { WatchInfo.clip($0.what, 30) }
    }

    /// 時計が録音中か（時計から一度も知らせが無ければ nil）と、録音中のはずなのに知らせが途絶えているか
    static func watchState(_ last: RecordingLedger.State?, now: Date) -> (recording: Bool?, quiet: Bool?) {
        guard let last else { return (nil, nil) }
        let quiet: Bool? = last.recording && now.timeIntervalSince(last.at) > watchQuietAfter ? true : nil
        return (last.recording, quiet)
    }

    /// 出す予定: これから始まるもの（始まって10分までのものを含む。時計の「次の予定」と同じ）。
    /// これからのものが無ければ、今やっているもの。終わったものは出さない
    static func nextEvent(_ events: [CalendarLink.Event], now: Date) -> WidgetState.Event? {
        let alive = events.filter { $0.end > now }.sorted { $0.start < $1.start }
        guard let event = alive.first(where: { $0.start >= now.addingTimeInterval(-10 * 60) }) ?? alive.first else { return nil }
        return WidgetState.Event(title: WatchInfo.clip(event.title.isEmpty ? "予定" : event.title, 40),
                                 start: event.start, end: event.end)
    }
}

extension Pipeline {
    /// iPhone のウィジェットの中身を確かめて、変わっていれば書く（読み直しは多くても1分に1回）
    func updateWidgets() {
        WidgetPublisher.shared.publish(widgetState(), kind: WidgetState.phoneKind)
    }

    /// iPhone のウィジェットに出す中身
    func widgetState(now: Date = .now) -> WidgetState {
        var state = WidgetState(updated: now)
        state.phoneRecording = isRecording
        let watch = WidgetBridge.watchState(ledger.lastState, now: now)
        state.watchRecording = watch.recording
        state.watchQuiet = watch.quiet
        let counts = WidgetBridge.taskCounts(tasks.items, now: now)
        state.tasksDue = counts.due
        state.tasksOverdue = counts.overdue
        state.tasksOpen = counts.open
        // 「LifeLog のやること」（2026-11-10）
        state.taskTitles = WidgetBridge.taskTitles(tasks.todo, now: now)
        state.tasksChecking = tasks.candidates.count
        // 「LifeLog のいいこと帳」（2026-11-12。GoodMore.swift）
        let goodWeek = GoodWidgetCounts.thisWeek(good.data?.weeks, now: now)
        state.goodThanks = goodWeek?.thanks
        state.goodPraise = goodWeek?.praise
        state.nextEvent = WidgetBridge.nextEvent(calendar.dayEvents(from: now, to: now.addingTimeInterval(12 * 3600)), now: now)
        state.lastProcessed = ledger.chunks.lazy.compactMap(\.transcribed).max()
        state.pcOK = homePC.isConfigured ? homePC.downSince == nil : nil
        return state
    }
}

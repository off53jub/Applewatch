import Foundation

/// iPhone・時計のアプリが書き、ウィジェット（文字盤・ロック画面・ホーム画面）が読む中身（2026-11-07）。
/// App Group（group.com.off53jub.lifelog）の UserDefaults に1つだけ置く。iPhone と時計は別の入れ物なので、それぞれで書く。
/// 項目は足すだけにする（古いウィジェットが読めなくならないよう、どれも省けるようにしておく）。
struct WidgetState: Codable, Equatable {
    struct Event: Codable, Equatable {
        var title: String
        var start: Date
        var end: Date?

        /// 終わりの時刻（分からなければ、始まりの1時間後とみなす）
        var until: Date { end ?? start.addingTimeInterval(3600) }
    }

    var updated: Date = .now
    /// iPhone で録音しているか
    var phoneRecording: Bool?
    /// 時計で録音しているか
    var watchRecording: Bool?
    /// 今日までの頼まれごとの数と、そのうち期限を過ぎた数
    var tasksDue: Int?
    var tasksOverdue: Int?
    /// 次の予定
    var nextEvent: Event?
    /// 最後に文字にした時刻
    var lastProcessed: Date?
    /// 家の PC とつながるか（使っていなければ nil）
    var pcOK: Bool?
    /// 時計から iPhone に送っていない録音の数（時計だけ）
    var watchUnsent: Int?
    /// まだの頼まれごとの数（期限の無いものも入れた全部。2026-11-07）
    var tasksOpen: Int?
    /// 時計は録音中のはずなのに、30分より長く知らせが届いていない（iPhone だけ。2026-11-07）
    var watchQuiet: Bool?
    /// 今日まで（期限を過ぎたものを含む）の頼まれごとの文。無ければ、期限の近いまだのもの。3件まで（iPhone だけ。2026-11-10）
    var taskTitles: [String]?
    /// 確かめ待ちの数（iPhone だけ。2026-11-10）
    var tasksChecking: Int?
    /// 今週のお礼・ほめ言葉の数（iPhone だけ。いいこと帳のウィジェット用。2026-11-12）
    var goodThanks: Int?
    var goodPraise: Int?

    static let suiteName = "group.com.off53jub.lifelog"
    static let key = "widgetState"
    /// iPhone のロック画面・ホーム画面の「LifeLog の様子」の種類の名前（kind）
    static let phoneKind = "com.off53jub.lifelog.status"
    /// iPhone の「LifeLog のやること」の種類の名前（2026-11-10。「LifeLog の様子」と同じ中身を読む）
    static let tasksKind = "com.off53jub.lifelog.tasks"
    /// iPhone の「LifeLog のいいこと帳」の種類の名前（2026-11-12。同じ中身を読む）
    static let goodKind = "com.off53jub.lifelog.good"
    /// 時計の文字盤の LifeLog の種類の名前。前からある「開くボタン」と同じ（変えると文字盤から消える）
    static let watchKind = "com.off53jub.lifelog.watch.launcher"
    /// ウィジェットが自分で中身を読み直すまでの長さ（アプリからの読み直しが届かなかったとき用）
    static let refreshAfter: TimeInterval = 3600

    /// App Group が使えない入れ方（署名なしの IPA など）では nil
    static var defaults: UserDefaults? {
        // 入れ物が無いまま suiteName で開くと、アプリの中だけの別の入れ物になる（ウィジェットからは読めない）ので使わない
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil else { return nil }
        return UserDefaults(suiteName: suiteName)
    }

    static func load() -> WidgetState? { load(from: defaults) }

    static func load(from defaults: UserDefaults?) -> WidgetState? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetState.self, from: data)
    }

    /// 変わったときだけ書く。書いたら true
    @discardableResult
    func save() -> Bool { save(to: Self.defaults) }

    /// 変わったときだけ書く（書いた時刻 updated だけの違いは、変わったとみなさない）。書いたら true
    @discardableResult
    func save(to defaults: UserDefaults?) -> Bool {
        guard let defaults else { return false }
        var old = Self.load(from: defaults)
        old?.updated = updated
        guard old != self else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    /// old からの変わり方が、最後に文字にした時刻と送っていない数だけか（読み直しを急がない）
    func isMinorChange(from old: WidgetState) -> Bool {
        var new = self
        var old = old
        new.updated = old.updated
        new.lastProcessed = nil
        old.lastProcessed = nil
        new.watchUnsent = nil
        old.watchUnsent = nil
        return new == old
    }

    /// タイムラインの項目の時刻: 今と、次の予定の始まり・終わりと、次の0時（日付の言い方が変わる）。
    /// now より前のものは除き、古い順に並べる
    func timelineDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        var dates: Set<Date> = [now]
        if let event = nextEvent {
            dates.insert(event.start)
            dates.insert(event.until)
        }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            dates.insert(midnight)
        }
        return dates.filter { $0 >= now }.sorted()
    }

    /// ウィジェットを選ぶ画面と、読み込み中に出す見本
    static var sample: WidgetState {
        let now = Date.now
        var state = WidgetState(updated: now)
        state.phoneRecording = true
        state.watchRecording = true
        state.tasksDue = 2
        state.tasksOverdue = 1
        state.tasksOpen = 5
        state.nextEvent = Event(title: "打ち合わせ", start: now.addingTimeInterval(30 * 60), end: now.addingTimeInterval(90 * 60))
        state.lastProcessed = now.addingTimeInterval(-5 * 60)
        state.pcOK = true
        state.watchUnsent = 0
        state.goodThanks = 3
        state.goodPraise = 2
        return state
    }
}

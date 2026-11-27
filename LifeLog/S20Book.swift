import Foundation
import Observation
import UserNotifications

/// s20 の写しと端末の中の印（2026-11-21）。決まりは S20Rules.swift、画面は S20*Views.swift。
/// 読む（家の PC の GET。母艦が作った写し。features に名前があるときだけ。無いときは前の写しか空のまま）:
/// - 確かめ待ちの列（GET /review-queue・"reviewq"）← 母艦の state/review_queue_for_app.json（次3・体11〜15）
/// - 検品表（GET /feature-check・"featcheck"）← state/audit/feature_check_for_app.json（次1・体26）
/// - 実機の確かめ（GET /device-checks・"devchecks"）← state/device_checks.json（次16・体8）
/// - 面談の 1 枚（GET /interview-sheet・"interview"）← 次20 の印刷できる html（体25）
/// - 休日の札（GET /holiday-tags・"holidaytags"）← state/holiday/tags.json（体4・体23。無くても動く）
/// 送る（MothershipOutbox にためて、家の PC につながったときに送る）:
/// - 確かめ待ちの答え（POST /feedback の kind "review" → inbox/app_feedback.jsonl）
/// - 検品表の答え（POST /feature-answer → inbox/feature_answers.jsonl）
/// - 時間を選んで消した分（POST /records/<日>/forget {from,to}。"forget"。家の PC の records と音声のその時間だけ）
@MainActor
@Observable
final class S20Book {
    static let shared = S20Book()

    private(set) var review: ReviewQueueFeed?
    private(set) var features: FeatureCheckFeed?
    private(set) var deviceChecks: DeviceChecksFeed?
    /// 札（日付 → 札の言葉）
    private(set) var holidayTags: [String: [String]] = [:]
    private(set) var interviewFile: URL?
    /// 答えた id（端末の中だけ。14 日で流れるので、古いものは捨てる）
    private(set) var answered: [String: String] = [:]
    /// 「あとで」にした id → その日
    private(set) var later: [String: String] = [:]
    /// 検品表で答えた id → 続けるか
    private(set) var featureAnswers: [String: Bool] = [:]
    /// 通知の履歴（体19）と、止めた種類
    private(set) var notices: [NoticeLogEntry] = []
    private(set) var muted: Set<String> = []
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var fetching = false
    /// 確かめ待ちのカードを出した時刻（答えるまでの秒を数える。体38）
    @ObservationIgnored var cardShownAt: Date?

    private static let every: TimeInterval = 30 * 60
    private static let answeredKey = "s20.reviewAnswered"
    private static let laterKey = "s20.reviewLater"
    private static let featureAnswersKey = "s20.featureAnswers"
    private static let mutedKey = "s20.noticeMuted"
    private static let noticesFile = URL.applicationSupportDirectory.appendingPathComponent("s20-notices.json")
    static let heldKey = "s20.digestHeld"

    private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("app-feed-\(name).json")
    }

    init() {
        let d = UserDefaults.standard
        answered = d.dictionary(forKey: Self.answeredKey) as? [String: String] ?? [:]
        later = d.dictionary(forKey: Self.laterKey) as? [String: String] ?? [:]
        featureAnswers = d.dictionary(forKey: Self.featureAnswersKey) as? [String: Bool] ?? [:]
        muted = Set(d.stringArray(forKey: Self.mutedKey) ?? [])
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.url("reviewq")) { review = try? decoder.decode(ReviewQueueFeed.self, from: data) }
        if let data = try? Data(contentsOf: Self.url("featcheck")) { features = try? decoder.decode(FeatureCheckFeed.self, from: data) }
        if let data = try? Data(contentsOf: Self.url("devchecks")) { deviceChecks = try? decoder.decode(DeviceChecksFeed.self, from: data) }
        if let data = try? Data(contentsOf: Self.url("holidaytags")) { holidayTags = Self.parseTags(data) }
        let sheet = URL.applicationSupportDirectory.appendingPathComponent("interview-sheet.html")
        if FileManager.default.fileExists(atPath: sheet.path) { interviewFile = sheet }
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: Self.noticesFile),
           let list = try? isoDecoder.decode([NoticeLogEntry].self, from: data) {
            notices = NoticeHistoryRules.pruned(list, now: .now)
        }
    }

    // MARK: 確かめ待ち（体11〜15）

    /// いま見せるもの
    /// 「同じ人か」は設定でだけ出す（取り決め C4）・答えで直る行の多い順（2026-11-24。s24 の 当1・減2。S24Rules.swift）
    func openItems(now: Date = .now) -> [ReviewItem] {
        let visible = ReviewRules.visible(review?.items ?? [], answered: Set(answered.keys), later: later, now: now)
        let kept = S24AskRules.reviewItems(visible, samePersonAsk: S24AskSettings.isOn(S24AskSettings.samePersonAskKey),
                                           today: ReviewRules.dayKey(now))
        // 発言も声も無い「この声は誰？」は後ろへ（消さない。2026-11-25。s26 の S26V）
        return S26VVoice.order(kept)
    }

    /// 確かめ待ちの数（「今日」・時計の文字盤に出す）
    var waitingCount: Int { openItems().count }

    func done(for id: String) -> ReviewDone? { review?.done?.first { $0.id == id } }

    /// 答える（yes・no・選んだもの・文）。答えは母艦へ送る列にためる
    func answer(_ item: ReviewItem, _ value: String, now: Date = .now) {
        guard let body = ReviewRules.answerBody(id: item.id, answer: value, at: now) else { return }
        MothershipOutbox.enqueue(path: "feedback", body: body, now: now)
        answered[item.id] = ReviewRules.dayKey(now)
        later[item.id] = nil
        trimAnswered(now: now)
        UserDefaults.standard.set(answered, forKey: Self.answeredKey)
        UserDefaults.standard.set(later, forKey: Self.laterKey)
        Tally.add("s20.review.answered")
        // 1 日 3 問（仮）の上限に入れる（知らせで聞いた同じ問いは 2 回数えない。2026-11-24。s24 の 減1）
        S24Gate.noteAnswered(key: "q:" + item.id, now: now)
        // 「この人物N はだれ」の答えを端末の人の名前付け・まとめに届ける（s29。S29NBook.swift。前は母艦へ送るだけだった）
        S29NReviewApply.apply(item, value, now: now)
        if let shown = cardShownAt { noteAnswerSeconds(now.timeIntervalSince(shown)) }
        cardShownAt = now
    }

    /// 「あとで」（今日は出さない。明日また出る）
    func postpone(_ item: ReviewItem, now: Date = .now) {
        later[item.id] = ReviewRules.dayKey(now)
        UserDefaults.standard.set(later, forKey: Self.laterKey)
        Tally.add("s20.review.later")
        cardShownAt = now
    }

    private func trimAnswered(now: Date) {
        let oldest = ReviewRules.dayKey(now.addingTimeInterval(-Double(ReviewRules.lifeDays + 7) * 86400))
        answered = answered.filter { $0.value >= oldest }
        later = later.filter { $0.value >= oldest }
    }

    // MARK: 検品表（体26）

    func answerFeature(_ id: String, keep: Bool, now: Date = .now) {
        guard let body = FeatureCheckRules.answerBody(id: id, keep: keep, at: now) else { return }
        MothershipOutbox.enqueue(path: "feature-answer", body: body, now: now)
        featureAnswers[id] = keep
        UserDefaults.standard.set(featureAnswers, forKey: Self.featureAnswersKey)
        Tally.add(keep ? "s20.feature.keep" : "s20.feature.stop")
    }

    // MARK: 通知の履歴と止めた種類（体19）

    func noteNotice(id: String, kind: String, title: String, held: Bool, at: Date = .now) {
        notices.append(NoticeLogEntry(id: id, kind: kind, title: String(title.prefix(60)), at: at, held: held))
        notices = NoticeHistoryRules.pruned(notices, now: at)
        saveNotices()
        bumpUX { $0.notifShown += 1 }
    }

    func noteOpened(id: String) {
        // 履歴に無い知らせ（時刻を決めて頼んだもの・家の PC から届いたもの）も、開いた数には数える
        // （2026-11-24。s24 の 減8。前は履歴にあるものだけ数えていて、ほとんど 0 だった）
        bumpUX { $0.notifOpened += 1 }
        guard let i = notices.lastIndex(where: { $0.id == id }) else { return }
        notices[i].opened = true
        saveNotices()
    }

    func setMuted(_ kind: String, _ on: Bool) {
        if on { muted.insert(kind) } else { muted.remove(kind) }
        UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
        if on {
            Tally.add("s20.notice.muted")
            bumpUX { if !$0.muted.contains(kind) { $0.muted.append(kind) } }
        }
    }

    private func saveNotices() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(notices) { try? data.write(to: Self.noticesFile, options: .atomic) }
    }

    // MARK: 体験の数字（体38。端末の中だけ。diag の detail で家の PC へ）

    func noteAnswerSeconds(_ seconds: Double) {
        bumpUX { UXMetrics.addAnswer(&$0, seconds: seconds) }
    }

    private func bumpUX(_ change: (inout UXMetrics.Day) -> Void) {
        let key = UXMetrics.key + "." + ReviewRules.dayKey(.now)
        var day = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode(UXMetrics.Day.self, from: $0) }
            ?? UXMetrics.Day()
        change(&day)
        if let data = try? JSONEncoder().encode(day) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 今日の体験の数字（diag の detail に足す）
    nonisolated static func todayUX(now: Date = .now) -> [String: Any] {
        let key = UXMetrics.key + "." + ReviewRules.dayKey(now)
        guard let data = UserDefaults.standard.data(forKey: key),
              let day = try? JSONDecoder().decode(UXMetrics.Day.self, from: data) else { return [:] }
        return UXMetrics.detail(day)
    }

    // MARK: 家の PC から読む

    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching else { return }
        let names = ["reviewq", "featcheck", "devchecks", "interview", "holidaytags"]
        guard names.contains(where: { pc.features.contains($0) }) else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        let decoder = JSONDecoder()
        if pc.features.contains("reviewq"), let body = try? await pc.appFeed("review-queue", feature: "reviewq"),
           let feed = try? decoder.decode(ReviewQueueFeed.self, from: body), feed.available != false {
            review = feed
            try? body.write(to: Self.url("reviewq"), options: .atomic)
        }
        if pc.features.contains("featcheck"), let body = try? await pc.appFeed("feature-check", feature: "featcheck"),
           let feed = try? decoder.decode(FeatureCheckFeed.self, from: body) {
            features = feed
            try? body.write(to: Self.url("featcheck"), options: .atomic)
        }
        if pc.features.contains("devchecks"), let body = try? await pc.appFeed("device-checks", feature: "devchecks"),
           let feed = try? decoder.decode(DeviceChecksFeed.self, from: body) {
            deviceChecks = feed
            try? body.write(to: Self.url("devchecks"), options: .atomic)
        }
        if pc.features.contains("holidaytags"), let body = try? await pc.appFeed("holiday-tags", feature: "holidaytags") {
            let tags = Self.parseTags(body)
            if !tags.isEmpty {
                holidayTags = tags
                try? body.write(to: Self.url("holidaytags"), options: .atomic)
            }
        }
        if pc.features.contains("interview"), let body = try? await pc.appFeed("interview-sheet", feature: "interview"),
           !body.isEmpty {
            let file = URL.applicationSupportDirectory.appendingPathComponent("interview-sheet.html")
            try? body.write(to: file, options: .atomic)
            interviewFile = file
        }
    }

    /// 札（{日付: [{tag, confidence…}]}・_meta は読まない）→ 日付 → 札の言葉
    nonisolated static func parseTags(_ data: Data) -> [String: [String]] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for (day, value) in object where HomeFeeds.isDay(day) {
            guard let list = value as? [[String: Any]] else { continue }
            var tags: [String] = []
            for row in list {
                if let tag = row["tag"] as? String, !tag.isEmpty, !tags.contains(tag) { tags.append(String(tag.prefix(20))) }
            }
            if !tags.isEmpty { out[day] = tags }
        }
        return out
    }

    #if DEBUG && targetEnvironment(simulator)
    /// 画面の確かめ用（DemoData）
    func installDemo(review: ReviewQueueFeed, features: FeatureCheckFeed, checks: DeviceChecksFeed, tags: [String: [String]],
                     notices: [NoticeLogEntry]) {
        self.review = review
        self.features = features
        deviceChecks = checks
        holidayTags = tags
        self.notices = notices
    }
    #endif
}

// MARK: - 次10 寝ているあいだ・体37 一緒にいる人といるあいだ、録音を休む

enum S20Hold {
    /// いま休むか（Pipeline.updateHold から呼ぶ。どちらも既定はオフ）
    static func holding(now: Date = .now) -> Bool {
        let d = UserDefaults.standard
        let sleep = SleepPauseRules.shouldHold(
            enabled: d.bool(forKey: SleepPauseRules.enabledKey), now: now,
            start: d.object(forKey: SleepPauseRules.startKey) as? Int ?? SleepPauseRules.defaultStart,
            end: d.object(forKey: SleepPauseRules.endKey) as? Int ?? SleepPauseRules.defaultEnd,
            focusSince: d.double(forKey: SleepPauseRules.focusSinceKey))
        let person = PersonPauseRules.holding(until: d.double(forKey: PersonPauseRules.untilKey), now: now)
        return sleep || person
    }

    /// 休む理由（画面に出す）
    static func reason(now: Date = .now) -> String? {
        let d = UserDefaults.standard
        if PersonPauseRules.holding(until: d.double(forKey: PersonPauseRules.untilKey), now: now) {
            let until = Date(timeIntervalSince1970: d.double(forKey: PersonPauseRules.untilKey))
            return until.formatted(date: .omitted, time: .shortened) + " まで、一緒にいる人のために休んでいます"
        }
        if holding(now: now) { return "寝ている時間なので休んでいます" }
        return nil
    }

    /// 呼ぶと、休むかを確かめ直す（Pipeline が入れる）
    @MainActor static var changed: (@MainActor () -> Void)?
}

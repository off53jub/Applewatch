import CoreLocation
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

// s23（2026-11-23）の動き。決まりは S23Rules.swift、画面は S23Screens.swift。
// - 知らせを押したら、その質問の画面へ（知2〜知7）。質問の知らせに「あとで」（知12）。答えそびれた質問（知13）。押したのに答えなかった数（知11）
// - 知らせの文に「押すと、…」「長押しで選べます」（知8・知9）。NoticeGate.add と、直に頼む所で通す
// - 何人でしたか（続5）・約束の出し方ごとの数（続6）・場所の質問の切り替え（場1〜場6）・版（届4・届8）・確かめの自動の ○（試1）

// MARK: - 設定の名前（UserDefaults）

enum S23Settings {
    /// 場2 同じ名前を 2 回選んだ所の近くでは、聞かずに入れる（初めはオフ: 間違えると記録の場所の名前が黙って変わるため）
    static let placeAutoKey = "s23.placeAuto"
    /// 場3 いる最中ではなく、出たときに聞く（初めはオフ＝今のまま。出たあとのほうが答えやすいかは仮説）
    static let placeOnLeaveKey = "s23.placeOnLeave"
    /// 場4 夜にまとめて「今日の名前の無い場所」（初めはオン。1 日 1 通・あるときだけ）
    static let placesNightKey = "s23.placesNight"
    /// 場6 答えが少なければ、聞く条件を絞る（初めはオン。14 日で 10 回以上聞いて 3 割より少ないときだけ効く。仮）
    static let placeTightenKey = "s23.placeTighten"
    /// 続5 会話のあとに「何人でしたか？」（初めはオン。1 日 2 回まで・10 分より長い会話だけ）
    static let headcountKey = "s23.headcount"
    /// 届4 GitHub のリリースで新しい版を確かめる（初めはオン。6 時間に 1 回。送るものは無い・読むだけ）
    static let versionCheckKey = "s23.versionCheck"
    /// 届8 版を上げた翌朝の 1 通（初めはオン）
    static let versionMorningKey = "s23.versionMorning"
    /// 試5 今日の 1 つ（初めはオン）
    static let tryTodayKey = "s23.tryToday"

    static let defaults: [String: Bool] = [placeAutoKey: false, placeOnLeaveKey: false, placesNightKey: true, placeTightenKey: true,
                                           headcountKey: true, versionCheckKey: true, versionMorningKey: true, tryTodayKey: true]

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaults[key] ?? false
    }
}

// MARK: - 場所（場1〜場6）

enum S23Places {
    private static let ignoredKey = "s23.placeIgnored"
    private static let answersKey = "s23.placeAnswers"
    private static let autoKey = "s23.placeAutoNamed"
    private static let lastAskKey = "s23.lastAsk"

    private static func load(_ key: String) -> [S23PlacePoint] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([S23PlacePoint].self, from: data)) ?? []
    }

    private static func save(_ list: [S23PlacePoint], _ key: String, keep: Int = 100) {
        if let data = try? JSONEncoder().encode(Array(list.suffix(keep))) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 場1 覚えなくていい所
    static var ignored: [S23PlacePoint] { load(ignoredKey) }

    static func ignore(latitude: Double, longitude: Double, now: Date = .now) {
        var list = ignored
        list.append(S23PlacePoint(latitude: latitude, longitude: longitude, at: now))
        save(list, ignoredKey)
        Tally.add("s23.place.ignored")
    }

    static func clearIgnored() { UserDefaults.standard.removeObject(forKey: ignoredKey) }

    static func isIgnored(latitude: Double, longitude: Double) -> Bool {
        S23PlaceRules.isIgnored(ignored, latitude: latitude, longitude: longitude)
    }

    /// 場2 答えた名前の控え（位置と名前だけ。端末の中だけ）
    static func noteAnswer(name: String, latitude: Double, longitude: Double, now: Date = .now) {
        var list = load(answersKey)
        list.append(S23PlacePoint(latitude: latitude, longitude: longitude, name: name, at: now))
        save(list, answersKey, keep: 300)
    }

    /// 場2 聞かずに入れる名前（オフなら nil）
    static func autoName(latitude: Double, longitude: Double) -> String? {
        guard S23Settings.isOn(S23Settings.placeAutoKey) else { return nil }
        return S23PlaceRules.autoName(load(answersKey), latitude: latitude, longitude: longitude)
    }

    static func noteAuto(name: String, latitude: Double, longitude: Double, now: Date = .now) {
        var list = load(autoKey)
        list.append(S23PlacePoint(latitude: latitude, longitude: longitude, name: name, at: now))
        save(list, autoKey, keep: 30)
        Tally.add("s23.place.auto")
    }

    /// 聞かずに入れた名前（新しい順。あとで直せるように見せる）
    static var autoNamed: [S23PlacePoint] { load(autoKey).reversed() }

    /// 場5 いちばん新しく聞いた所の着いた時刻（答える画面で、そのときの会話と写真を出す）
    static func noteAsk(latitude: Double, longitude: Double, arrival: Date) {
        UserDefaults.standard.set([latitude, longitude, arrival.timeIntervalSince1970], forKey: lastAskKey)
    }

    static func arrival(latitude: Double?, longitude: Double?) -> Date? {
        guard let latitude, let longitude, let saved = UserDefaults.standard.array(forKey: lastAskKey) as? [Double],
              saved.count == 3 else { return nil }
        let d = CLLocation(latitude: saved[0], longitude: saved[1]).distance(from: CLLocation(latitude: latitude, longitude: longitude))
        return d < 80 ? Date(timeIntervalSince1970: saved[2]) : nil
    }

    /// 場6 聞いた数・答えた数（14 日）
    static func counts(now: Date = .now) -> S23PlaceRules.Counts { S23PlaceRules.counts(Tally.sums(days: 14, now: now)) }

    /// 場6 いま絞っているか
    static func tightened(now: Date = .now) -> Bool {
        guard S23Settings.isOn(S23Settings.placeTightenKey) else { return false }
        let c = counts(now: now)
        return S23PlaceRules.shouldTighten(asked: c.asked - c.cancelled, answered: c.answered)
    }

    /// 場6 聞くまでいる長さ（絞っているときは 60 分。いつもは 30 分）
    static func askAfter(now: Date = .now) -> TimeInterval {
        tightened(now: now) ? S23PlaceRules.tightAskAfter : PlaceAssistRules.askAfter
    }

    /// 場3 出たときに聞く
    static var askOnLeave: Bool { S23Settings.isOn(S23Settings.placeOnLeaveKey) }
}

// MARK: - 帳（数・答え・覚えておくもの）

@MainActor
@Observable
final class S23Book {
    static let shared = S23Book()
    /// LifeLogApp が入れる（弱く持つ）
    static weak var pipeline: Pipeline?
    private static var timer: Timer?

    /// 知13 答えそびれた質問
    private(set) var missed: [S23MissedQuestion] = []
    /// 続5 答えた人数
    private(set) var headcounts: [S23Headcount] = []
    /// 届4 GitHub のリリースの番号
    private(set) var releaseBuild: Int?
    /// 届4 「この版は知らせなくていい」にした番号
    private(set) var dismissedBuild: Int = 0
    /// 知11 開いた・答えた・閉じた数（種類|できごと → 数）
    private(set) var tapStats: [String: Int] = [:]
    /// 試1 数から自動で ○ にした確かめ
    private(set) var autoChecks: [String] = []

    private static let missedKey = "s23.missed"
    private static let headcountsKey = "s23.headcounts"
    private static let askedHeadKey = "s23.headcountAsked"
    private static let releaseKey = "s23.releaseBuild"
    private static let releaseAtKey = "s23.releaseCheckedAt"
    private static let dismissedKey = "s23.dismissedBuild"
    private static let tapStatsKey = "s23.tapStats"
    private static let autoChecksKey = "s23.autoChecks"
    private static let buildSeenKey = "s23.buildSeen"
    private static let upgradedDayKey = "s23.upgradedDay"
    private static let morningSentKey = "s23.morningSentFor"
    private static let nightSentKey = "s23.placesNightDay"

    init() {
        let d = UserDefaults.standard
        let decoder = JSONDecoder()
        if let data = d.data(forKey: Self.missedKey) { missed = (try? decoder.decode([S23MissedQuestion].self, from: data)) ?? [] }
        if let data = d.data(forKey: Self.headcountsKey) { headcounts = (try? decoder.decode([S23Headcount].self, from: data)) ?? [] }
        releaseBuild = d.object(forKey: Self.releaseKey) as? Int
        dismissedBuild = d.integer(forKey: Self.dismissedKey)
        tapStats = d.dictionary(forKey: Self.tapStatsKey) as? [String: Int] ?? [:]
        autoChecks = d.stringArray(forKey: Self.autoChecksKey) ?? []
    }

    /// LifeLogApp の起動で 1 回だけ呼ぶ。live でなければ（テスト・画面の自動確認）見回りを動かさない
    static func install(_ pipeline: Pipeline, live: Bool) {
        self.pipeline = pipeline
        guard live, timer == nil else { return }
        shared.noteBuild()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in S23Book.shared.tick() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            S23Book.shared.tick()
        }
    }

    /// 5 分ごと（裏で録音しているあいだも動く）とアプリが前に出たとき
    func tick(now: Date = .now) {
        guard let pipeline = Self.pipeline else { return }
        checkHeadcount(pipeline, now: now)
        checkPlacesNight(now: now)
        autoMarkChecks()
        checkMorning(now: now)
        Task { await checkRelease(now: now) }
    }

    // MARK: 知11 押したあと

    func noteTap(_ kind: String, _ event: String) {
        tapStats[kind + "|" + event, default: 0] += 1
        UserDefaults.standard.set(tapStats, forKey: Self.tapStatsKey)
        Tally.add("s23.tap." + event)
    }

    // MARK: 知13 答えそびれた質問

    func noteQuestion(_ request: UNNotificationRequest, now: Date = .now) {
        let content = request.content
        guard let entry = S23NoticeCatalog.entry(identifier: request.identifier, category: content.categoryIdentifier),
              entry.question else { return }
        var at = now
        if let calendar = request.trigger as? UNCalendarNotificationTrigger, let next = calendar.nextTriggerDate() { at = next }
        if let interval = request.trigger as? UNTimeIntervalNotificationTrigger { at = now.addingTimeInterval(interval.timeInterval) }
        let q = S23MissedQuestion(id: request.identifier, category: content.categoryIdentifier, title: String(content.title.prefix(80)),
                                  body: String(content.body.prefix(160)), info: S23MissedRules.info(content.userInfo), at: at)
        missed = S23MissedRules.adding(missed, q, now: now)
        saveMissed()
    }

    /// 答えた（ボタン・画面・どちらでも）
    func answeredQuestion(id: String) {
        guard missed.contains(where: { $0.id == id }) else { return }
        missed.removeAll { $0.id == id }
        saveMissed()
    }

    func answeredQuestions(prefix: String) {
        guard missed.contains(where: { $0.id.hasPrefix(prefix) }) else { return }
        missed.removeAll { $0.id.hasPrefix(prefix) }
        saveMissed()
    }

    func dueMissed(now: Date = .now) -> [S23MissedQuestion] {
        S23MissedRules.due(S23MissedRules.pruned(missed, now: now), now: now)
    }

    private func saveMissed() {
        if let data = try? JSONEncoder().encode(missed) { UserDefaults.standard.set(data, forKey: Self.missedKey) }
    }

    // MARK: 続5 何人でしたか

    func answerHeadcount(start: Double, day: String, count: Int) {
        guard let row = S23HeadcountRules.row(day: day, start: Date(timeIntervalSince1970: start), count: count) else { return }
        headcounts = S23HeadcountRules.adding(headcounts, row)
        if let data = try? JSONEncoder().encode(headcounts) { UserDefaults.standard.set(data, forKey: Self.headcountsKey) }
        Tally.add("s23.headcount.answered")
        answeredQuestion(id: "s23-count-" + String(Int(start)))
        // 家の PC へ POST /headcount（features に "headcount" があるときだけ送る。無いあいだはためておく。#104）
        if let body = S23HeadcountRules.postBody(day: day, start: Date(timeIntervalSince1970: start), count: count) {
            MothershipOutbox.enqueue(path: "headcount", body: body)
            if let pc = Self.pipeline?.homePC { Task { await MothershipOutbox.send(pc) } }
        }
    }

    func headcount(start: Date) -> Int? {
        let iso = ISO8601DateFormatter().string(from: start)
        return headcounts.last { $0.start == iso }?.count
    }

    private func checkHeadcount(_ pipeline: Pipeline, now: Date) {
        guard S23Settings.isOn(S23Settings.headcountKey), MeetingMode.active == nil else { return }
        let defaults = UserDefaults.standard
        let today = HolidayRules.dayKey(now)
        var asked = defaults.dictionary(forKey: Self.askedHeadKey) as? [String: String] ?? [:]
        asked = asked.filter { $0.value >= HolidayRules.dayKey(now.addingTimeInterval(-2 * 86400)) }
        let askedToday = asked.values.filter { $0 == today }.count
        let day = ReviewRules.dayKey(now)
        for talk in pipeline.conversations(on: day).reversed() {
            let key = String(Int(talk.start.timeIntervalSince1970))
            var others = 0
            for line in talk.lines where line.media == nil && line.speakerID != nil && line.speakerID != SpeakerLabeler.selfID {
                others += 1
            }
            guard S23HeadcountRules.due(on: true, closed: talk.closed, start: talk.start, end: talk.end, media: talk.media != nil,
                                        otherLines: others, alreadyAsked: asked[key] != nil, askedToday: askedToday, now: now)
            else { continue }
            asked[key] = today
            defaults.set(asked, forKey: Self.askedHeadKey)
            S23Notices.postHeadcount(start: talk.start, end: talk.end, day: day)
            return
        }
    }

    // MARK: 場4 夜の名前の無い場所

    private func checkPlacesNight(now: Date) {
        guard S23Settings.isOn(S23Settings.placesNightKey), S23PlaceRules.isNightHour(now) else { return }
        let today = HolidayRules.dayKey(now)
        guard UserDefaults.standard.string(forKey: Self.nightSentKey) != today else { return }
        let stays = S23PlaceRules.today(CheckupBook.shared.unknownStays(now: now), now: now)
            .filter { !S23Places.isIgnored(latitude: $0.latitude, longitude: $0.longitude) }
        guard !stays.isEmpty else { return }
        UserDefaults.standard.set(today, forKey: Self.nightSentKey)
        S23Notices.postPlacesNight(count: stays.count, day: today)
    }

    // MARK: 試1 数から自動で ○

    func autoMarkChecks(now: Date = .now) {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        var same = false
        if case .same = S22Rules.watchVersion(phone: AppBuild.current, watch: detail["watchBuild"] as? String) { same = true }
        let passed = S23CheckRules.autoPassed(sums: Tally.sums(days: 35, now: now), notice: NoticeStats.values,
                                              watchSame: same, done: Checklist.done)
        guard !passed.isEmpty else { return }
        for id in passed { Checklist.mark(id, ok: true) }
        autoChecks = Array((autoChecks + passed).suffix(100))
        UserDefaults.standard.set(autoChecks, forKey: Self.autoChecksKey)
        Tally.add("s23.check.auto", passed.count)
    }

    /// 試6 時計の版が古いか
    static var watchOld: Bool {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        return S22Rules.needsWatchUpdate(S22Rules.watchVersion(phone: AppBuild.current, watch: detail["watchBuild"] as? String))
            && PCDiag.watchSeenAt != nil
    }

    // MARK: 届4・届8 版

    /// いまより新しい版の番号（同期の相手・時計・GitHub のリリース。分からなければ nil）
    var newerBuild: Int? {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        let watch: Int? = (detail["watchBuild"] as? String).flatMap { Int($0) }
        let peers: [Int?] = AppBuild.peers.values.map { Optional($0) }
        return S23VersionRules.newer(current: AppBuild.current, candidates: peers + [watch, releaseBuild])
    }

    /// 「今日」に出すか（この版は要らないにしたものは出さない）
    var newerToShow: Int? {
        guard let b = newerBuild, b > dismissedBuild else { return nil }
        return b
    }

    func dismissBuild(_ build: Int) {
        dismissedBuild = build
        UserDefaults.standard.set(build, forKey: Self.dismissedKey)
    }

    /// TestFlight を開く（入っていなければ TestFlight のページ）
    func openTestFlight() {
        Tally.add("s23.version.openTestFlight")
        guard let app = URL(string: "itms-beta://") else { return }
        UIApplication.shared.open(app) { ok in
            guard !ok, let web = URL(string: "https://testflight.apple.com/") else { return }
            Task { @MainActor in UIApplication.shared.open(web) }
        }
    }

    /// GitHub のリリース（公開の場所）の名前から、いちばん新しいビルドの番号を読む。6 時間に 1 回まで。送るものは無い
    private func checkRelease(now: Date) async {
        guard S23Settings.isOn(S23Settings.versionCheckKey) else { return }
        let d = UserDefaults.standard
        let last = d.double(forKey: Self.releaseAtKey)
        guard now.timeIntervalSince1970 - last > 6 * 3600 else { return }
        d.set(now.timeIntervalSince1970, forKey: Self.releaseAtKey)
        guard let url = URL(string: "https://api.github.com/repos/off53jub/Applewatch/releases/latest") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let got = try? await URLSession.shared.data(for: request),
              (got.1 as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: got.0)) as? [String: Any],
              let tag = object["tag_name"] as? String, let build = S23VersionRules.build(fromTag: tag) else { return }
        releaseBuild = build
        d.set(build, forKey: Self.releaseKey)
    }

    /// 起動のたびに版を見る。前と違えば、上げた日を覚える（届8）
    func noteBuild(now: Date = .now) {
        let d = UserDefaults.standard
        let current = AppBuild.current
        guard current > 0 else { return }
        let seen = d.object(forKey: Self.buildSeenKey) as? Int
        d.set(current, forKey: Self.buildSeenKey)
        if let seen, seen != current { d.set(ReviewRules.dayKey(now), forKey: Self.upgradedDayKey) }
    }

    private func checkMorning(now: Date) {
        guard S23Settings.isOn(S23Settings.versionMorningKey) else { return }
        let d = UserDefaults.standard
        let build = AppBuild.current
        let day = d.string(forKey: Self.upgradedDayKey)
        guard S23VersionRules.morningDue(upgradedDay: day, sentFor: d.object(forKey: Self.morningSentKey) as? Int, build: build,
                                         now: now), let day else { return }
        d.set(build, forKey: Self.morningSentKey)
        // 上げた日からの数で、動いたもの（機能の一覧）と、まだのもの（確かめてほしいこと）
        let days = Tally.days(5, now: now).filter { $0.key >= day }
        var sums: [String: Int] = [:]
        for (_, counts) in days { for (k, v) in counts { sums[k, default: 0] += v } }
        let ran = FeatureProof.features.filter { f in f.keys.contains { (sums[$0] ?? 0) > 0 } }.map(\.name)
        let notYet = Checklist.remaining.map(\.title)
        let text = S23VersionRules.morningText(build: build, ran: ran, notYet: notYet)
        S23Notices.post(id: "s23-version-\(build)", title: text.title, body: text.body)
        Tally.add("s23.version.morning")
    }

    // MARK: 家の PC への様子（どれも省ける）

    func diagState(now: Date = .now) -> [String: Any] {
        var out: [String: Any] = [:]
        let since = ReviewRules.dayKey(now.addingTimeInterval(-14 * 86400))
        let recent = headcounts.filter { $0.day >= since }
        if !recent.isEmpty { out["headcounts"] = recent.map { ["day": $0.day, "start": $0.start, "count": $0.count] } }
        if !autoChecks.isEmpty { out["deviceChecksAuto"] = autoChecks.suffix(40).map { ["id": $0, "result": "ok", "source": "auto"] } }
        if !tapStats.isEmpty { out["noticeTaps"] = tapStats }
        return out
    }
}

// MARK: - 知らせ

@MainActor
enum S23Notices {
    nonisolated static let countCategory = S23NoticeCatalog.s23CountCategory

    // MARK: 知8・知9 文に「押すと」「長押しで」を足す（知13 の控えも、ここで取る）

    /// NoticeGate.add の入口で通す。文を足した知らせを返す
    nonisolated static func prepared(_ request: UNNotificationRequest) -> UNNotificationRequest {
        let content = request.content
        guard let entry = S23NoticeCatalog.entry(identifier: request.identifier, category: content.categoryIdentifier) else {
            return request
        }
        let body = S23NoticeCatalog.decorate(body: content.body, entry: entry)
        let out: UNNotificationRequest
        if body == content.body {
            out = request
        } else if let copy = content.mutableCopy() as? UNMutableNotificationContent {
            copy.body = body
            out = UNNotificationRequest(identifier: request.identifier, content: copy, trigger: request.trigger)
        } else {
            out = request
        }
        if entry.question {
            Task { @MainActor in S23Book.shared.noteQuestion(out) }
        }
        return out
    }

    /// 直に頼む知らせ（NoticeGate を通らないもの）の文に足す
    nonisolated static func decorate(_ content: UNMutableNotificationContent, id: String) {
        // 題の頭の印・時計を震わせない（2026-11-24。s24 の 形6・形7。S24Book.swift）
        S24Gate.style(content, id: id)
        guard let entry = S23NoticeCatalog.entry(identifier: id, category: content.categoryIdentifier) else { return }
        content.body = S23NoticeCatalog.decorate(body: content.body, entry: entry)
    }

    // MARK: 知12 カテゴリに「あとで」・続5 のカテゴリ

    nonisolated static func categories(_ base: Set<UNNotificationCategory>) -> Set<UNNotificationCategory> {
        var out: Set<UNNotificationCategory> = []
        for category in base {
            guard S23TapRules.laterCategories.contains(category.identifier) else {
                out.insert(category)
                continue
            }
            var actions = category.actions
            let have = Set(actions.map(\.identifier))
            guard !have.contains(S23TapRules.laterAction) else {
                out.insert(category)
                continue
            }
            for later in S23TapRules.laterActionsToAdd(existing: actions.count) {
                actions.append(UNNotificationAction(identifier: later.id, title: later.title, options: []))
            }
            out.insert(UNNotificationCategory(identifier: category.identifier, actions: actions,
                                              intentIdentifiers: category.intentIdentifiers, options: category.options))
        }
        let counts = S23TapRules.countActions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) }
        if !out.contains(where: { $0.identifier == countCategory }) {
            out.insert(UNNotificationCategory(identifier: countCategory, actions: counts, intentIdentifiers: [], options: []))
        }
        return out
    }

    // MARK: 押したとき（TaskBook.swift の didReceive から 1 行で呼ぶ）

    /// s23 で受けるなら、受けて true（completion はこちらで呼ぶ）。受けないものは false（今までどおり）
    nonisolated static func receive(_ response: UNNotificationResponse, completion: @escaping () -> Void) -> Bool {
        let request = response.notification.request
        let content = request.content
        let action = response.actionIdentifier
        // 質問の知らせのボタンを押した（ここでは受けない分も）: 答えそびれの控えから外す
        if action != S23TapRules.defaultAction, action != S23TapRules.laterAction, action != S23TapRules.tonightAction {
            let id = request.identifier
            Task { @MainActor in S23Book.shared.answeredQuestion(id: id) }
        }
        guard let tap = S23TapRules.tap(identifier: request.identifier, category: content.categoryIdentifier, action: action,
                                        userInfo: content.userInfo) else { return false }
        let identifier = request.identifier
        let date = response.notification.date
        let copy = content.mutableCopy() as? UNMutableNotificationContent
        NoticeGate.noteShown(identifier: identifier, category: content.categoryIdentifier, date: date)
        Task { @MainActor in
            perform(tap, identifier: identifier, content: copy ?? UNMutableNotificationContent())
            completion()
        }
        return true
    }

    /// 動かす（知らせ・知らせの履歴・答えそびれた質問から）
    static func perform(_ tap: S23Tap, identifier: String, content: UNMutableNotificationContent) {
        let pipeline = S23Book.pipeline
        let kind = NoticeBundle.kind(identifier: identifier, category: content.categoryIdentifier)
        let present = S23Present.shared
        // ほかのシート（知らせの画面）が出ていれば、閉じてから出す（シートは 1 つずつしか出せない）
        let busy: Bool = pipeline?.noticeRoute != nil
        if busy { pipeline?.noticeRoute = nil }
        func show(_ block: @escaping @MainActor () -> Void) {
            guard busy else { return block() }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                block()
            }
        }
        func open(_ sheet: S23Sheet.Kind) {
            S23Book.shared.noteTap(kind, "opened")
            let item = S23Sheet(kind: sheet, noticeKind: kind, noticeID: identifier)
            show { present.sheet = item }
        }
        switch tap {
        case .snooze(let value):
            let seconds = S23TapRules.snoozeSeconds(value, now: .now)
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
            Tally.add("s23.snooze." + (value == nil ? "tonight" : "hour"))
        case .who(let key):
            open(.who(key: key))
        case .knowMe(let id, let kind, let day):
            open(.knowMe(id: id, kind: kind, day: day, text: content.body))
        case .review(let id):
            open(.review(id: id, fallback: content.body))
        case .holidayPlace(let name, let lat, let lon, let day):
            // 開いた数は答える画面が数える（PlaceAskSheet の onAppear）
            let target = PlaceAskTarget(candidates: [name], latitude: lat, longitude: lon, holidayDay: day, kind: kind,
                                        noticeID: identifier)
            show { S22Present.shared.placeAsk = target }
        case .holidayNote:
            open(.note(title: content.title, info: S23MissedRules.info(content.userInfo)))
        case .tasks(let ids):
            NoticeStats.count(content.categoryIdentifier.isEmpty ? NoticeRoute.kind(of: identifier) : content.categoryIdentifier,
                              NoticeActions.Action.open.rawValue)
            // 下に置くタブ: 知らせのタスクが全部仕事のものなら仕事タブ（2026-11-27。s30。タスクタブは仕事以外だけ。S30TTabs.swift）
            pipeline?.openRoute(.tab(S30TTabs.tab(forTasks: ids, in: pipeline?.tasks.items ?? [])))
            open(.tasks(ids: ids))
        case .promises(let ids):
            Tally.add("s23.promise.notice.open")
            PromiseInbox.shared.poke()
            pipeline?.openRoute(.tab(.today))
            open(.promises(ids: ids))
        case .status(let id):
            open(.status(id: id))
        case .headcount(let start, let day, let count):
            if let count {
                S23Book.shared.answerHeadcount(start: start, day: day, count: count)
            } else {
                open(.headcount(start: start, day: day))
            }
        case .tab(let tab):
            pipeline?.openRoute(.tab(tab))
        case .placesNight:
            open(.placesNight)
        case .checklist:
            Tally.add("s23.version.morning.opened")
            open(.checklist)
        }
    }

    /// 知13: 答えそびれた質問の、答える画面（一覧から押して開く）
    enum Destination {
        case sheet(S23Sheet)
        case place(PlaceAskTarget)
    }

    static func destination(for q: S23MissedQuestion) -> Destination? {
        let info = S23MissedRules.userInfo(q.info)
        let kind = NoticeBundle.kind(identifier: q.id, category: q.category)
        if q.category == PlaceAssistRules.askCategory {
            return .place(PlaceAskTarget(candidates: info["cands"] as? [String] ?? [], latitude: info["lat"] as? Double,
                                         longitude: info["lon"] as? Double, kind: kind, noticeID: q.id))
        }
        guard let tap = S23TapRules.tap(identifier: q.id, category: q.category, action: S23TapRules.defaultAction, userInfo: info)
        else { return nil }
        func sheet(_ k: S23Sheet.Kind) -> Destination { .sheet(S23Sheet(kind: k, noticeKind: kind, noticeID: q.id)) }
        switch tap {
        case .who(let key): return sheet(.who(key: key))
        case .knowMe(let id, let k, let day): return sheet(.knowMe(id: id, kind: k, day: day, text: q.body))
        case .review(let id): return sheet(.review(id: id, fallback: q.body))
        case .holidayPlace(let name, let lat, let lon, let day):
            return .place(PlaceAskTarget(candidates: [name], latitude: lat, longitude: lon, holidayDay: day, kind: kind, noticeID: q.id))
        case .holidayNote: return sheet(.note(title: q.title, info: q.info))
        case .headcount(let start, let day, _): return sheet(.headcount(start: start, day: day))
        default: return nil
        }
    }

    // MARK: 出す

    static func post(id: String, title: String, body: String, category: String = "", info: [String: Any] = [:],
                     passive: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        if passive { content.interruptionLevel = .passive } else { content.sound = .default }
        NoticeGate.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// 続5 何人でしたか（名前・中身は出さない。時刻だけ）
    static func postHeadcount(start: Date, end: Date, day: String) {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        post(id: "s23-count-" + String(Int(start.timeIntervalSince1970)),
             title: "さっき（\(f.string(from: start))〜\(f.string(from: end))）は何人でしたか？",
             body: "自分も入れた人数です。", category: countCategory,
             info: ["start": start.timeIntervalSince1970, "day": day], passive: true)
        Tally.add("s23.headcount.asked")
    }

    /// 場4 夜にまとめて
    static func postPlacesNight(count: Int, day: String) {
        post(id: "s23-places-" + day, title: "今日の名前の無い場所が \(count) か所あります",
             body: "地図を見ながら、1 画面で続けて答えられます。", passive: true)
        Tally.add("s23.placesNight.sent")
    }
}

// MARK: - 画面を出す所（アプリの根の .s23Root で受ける）

struct S23Sheet: Identifiable {
    enum Kind {
        case who(key: String)
        case knowMe(id: String, kind: String, day: String?, text: String)
        case review(id: String, fallback: String)
        case note(title: String, info: [String: S23InfoValue])
        case tasks(ids: [String])
        case promises(ids: [String])
        case status(id: String)
        case headcount(start: Double, day: String)
        case placesNight
        case checklist
        case missed
    }

    let id = UUID()
    let kind: Kind
    /// 数えるときの種類（知11）
    var noticeKind: String = ""
    var noticeID: String = ""
}

@MainActor
@Observable
final class S23Present {
    static let shared = S23Present()
    var sheet: S23Sheet?
    /// いま出している画面（シートでも、一覧から押して開いたものでも）
    @ObservationIgnored var current: S23Sheet?
    /// いま出している画面で答えたか（閉じたときに「答えずに閉じた」を数える。知11）
    @ObservationIgnored var answered = false

    func shown(_ sheet: S23Sheet) {
        current = sheet
        answered = false
    }

    /// 画面で答えた（知11・知13）
    func markAnswered() {
        guard let current, !answered else { return }
        answered = true
        Tally.add("s23.sheet.answered")
        if !current.noticeKind.isEmpty { S23Book.shared.noteTap(current.noticeKind, "answered") }
        if !current.noticeID.isEmpty { S23Book.shared.answeredQuestion(id: current.noticeID) }
    }

    /// 閉じた
    func closed(_ sheet: S23Sheet) {
        guard current?.id == sheet.id else { return }
        if !answered, !sheet.noticeKind.isEmpty { S23Book.shared.noteTap(sheet.noticeKind, "closed") }
        answered = false
        current = nil
    }
}

// MARK: - 試1・試5・試6・試7 確かめてほしいこと（s23 の分と、今日の 1 つ）

enum S23Checks {
    /// s23 で足した動き（Checklist.items の先頭に入る。id は変えない）
    static let items: [Checklist.Item] = [
        Checklist.Item(id: "s23-tap-sheets", since: "2026-11-23", title: "知らせを押すと、その質問の画面が開く",
                       how: "「誰と話しましたか？」「確かめ待ち ○×」「自分を知る」の知らせそのものを押す。その問いだけの画面が開き、答えると 1 行で何が変わるかが出れば OK。"),
        Checklist.Item(id: "s23-later", since: "2026-11-23", title: "質問の知らせの「あとで」",
                       how: "確かめ待ち ○× の知らせを長押しして「あとで（1 時間後）」を押す。1 時間後に同じ知らせがもう一度来れば OK。"),
        Checklist.Item(id: "s23-headcount", since: "2026-11-23", title: "会話のあとの「何人でしたか？」",
                       how: "10 分より長い会話のあと、知らせを長押しして人数を押す。アプリを開かずに消えれば OK。"),
        Checklist.Item(id: "s23-place-forget", since: "2026-11-23", title: "「ここは覚えなくていい」",
                       how: "「ここは、どこですか？」を押して開いた画面で「ここは覚えなくていい」を押す。次にそこへ行っても聞かれなければ OK。"),
        Checklist.Item(id: "s23-places-night", since: "2026-11-23", title: "夜の「今日の名前の無い場所」",
                       how: "名前の無い所に 30 分いた日の 21 時ごろ、知らせを押す。地図と一緒に並び、続けて名前を付けられれば OK。"),
        Checklist.Item(id: "s23-version-banner", since: "2026-11-23", title: "「新しい版があります」と TestFlight",
                       how: "新しい版が出たあと「今日」を開く。「新しい版があるようです」が出て、「TestFlight を開く」で TestFlight が開けば OK。"),
        Checklist.Item(id: "s23-version-morning", since: "2026-11-23", title: "版を上げた翌朝の 1 通",
                       how: "アプリを新しくした次の朝 7 時より後に「版 ○ で動いたもの・まだのもの」が来て、押すとこの一覧が開けば OK。"),
        Checklist.Item(id: "s23-missed", since: "2026-11-23", title: "答えそびれた質問に答える",
                       how: "知らせの履歴の「答えそびれた質問」を開き、1 つ押して答える。一覧から消えれば OK。"),
    ]

    /// 試5: 今日の 1 つ（時計の版が古いあいだは、時計がらみを外す）
    @MainActor
    static func todayItem(now: Date = .now) -> Checklist.Item? {
        var left = Checklist.remaining
        if S23Book.watchOld { left = left.filter { !S23CheckRules.watchItems.contains($0.id) } }
        guard let id = S23CheckRules.pickToday(left.map(\.id), day: ReviewRules.dayKey(now)) else { return nil }
        return left.first { $0.id == id }
    }

    /// 試7: 動かなかったもの
    static func failed() -> [Checklist.Item] {
        let done = Checklist.done
        return Checklist.items.filter { done[$0.id] == "ng" }
    }

    /// 試7: 「Claude に頼む」の文
    static func askClaudeText(_ items: [Checklist.Item]) -> String {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        return S23CheckRules.askClaudeText(failed: items.map { (title: $0.title, how: $0.how) }, phoneBuild: AppBuild.current,
                                           watchBuild: detail["watchBuild"] as? String)
    }
}

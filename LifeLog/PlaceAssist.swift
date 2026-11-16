import CoreLocation
import Foundation
import MapKit
import UserNotifications

/// 着いたときの場所まわり（2026-11-16。強化案 91・104。88 の「着いたら 1 回だけ細かく測る」は Places.swift）。
/// - 91 30 分いたら手首で聞く: 自宅・職場・確かな場所以外に 30 分いたら、「ここは？」と候補を最大 3 つ、静かな通知で出す。
///   通知は iPhone が出し、Apple Watch に自動で写る（時計側の作りは足していない）。ボタンを押すと、その名前を位置で覚える（PlaceNames.swift）。
///   会議モード中は出さない・1 日 3 回まで・設定で切れる（初めはオン）。
/// - 104 着いたら知らせる: 「〇〇で買う」などのやること、その場所・その場所によく一緒に行く相手との約束を、着いたときに 1 通だけ知らせる。
///   1 日 3 通まで・同じ場所は 1 日 1 回・設定で切れる（初めはオン）。
/// 「着いた」は、位置の立ち寄り（CLVisit）の知らせと、大きく動いたときの位置から分かる。どちらも位置を残す設定がオンのときだけ。
/// 通知の文には、場所の名前とやることの文だけを入れる（会話の中身は入れない）。

// MARK: - 決まり（通信しない・テストする部分）

enum PlaceAssistRules {
    static let askKey = "placeAsk"
    static let remindKey = "placeRemind"
    static var askOn: Bool { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }
    static var remindOn: Bool { UserDefaults.standard.object(forKey: remindKey) as? Bool ?? true }

    static let askCategory = "placeAsk"
    static let askPrefix = "placeask-"
    static let remindPrefix = "placeremind-"
    /// 着いてから、この秒数いたら聞く
    static let askAfter: TimeInterval = 1800
    /// 離れたとみなす距離（m）。聞く前に離れたら、聞かない
    static let leftDistance: Double = 300
    static let askDailyCap = 3
    static let remindDailyCap = 3
    static let candidateLimit = 3
    static let titlesKey = "placeAskTitles"
    static let countsKey = "placeAssistCounts"
    static let pendingKey = "placeAskPending"
    static let remindedKey = "placeRemindedKeys"

    /// 着いてから 30 分たつ時刻。もう過ぎていれば、1 分後
    static func fireDate(arrival: Date, now: Date) -> Date {
        let target: Date = arrival.addingTimeInterval(askAfter)
        let soon: Date = now.addingTimeInterval(60)
        return target > soon ? target : soon
    }

    /// 聞くか（自宅・職場・確かな場所ではない・会議中ではない・1 日の上限の中）
    static func shouldAsk(on: Bool, known: Bool, meeting: Bool, askedToday: Int, cap: Int = askDailyCap) -> Bool {
        on && !known && !meeting && askedToday < cap
    }

    /// 候補（本人が前に直した名前・行ったお店の候補・近くの施設・地名の順。同じ名前は 1 つ。最大 3 つ。ボタンに入る長さに切る）
    static func candidates(fixed: [String], shop: [String], nearby: [String], area: String?, limit: Int = candidateLimit) -> [String] {
        var all: [String] = []
        all.append(contentsOf: fixed)
        all.append(contentsOf: shop)
        all.append(contentsOf: nearby)
        if let area { all.append(area) }
        var out: [String] = []
        var keys: [String] = []
        for raw in all {
            guard var name = PlaceNameRules.clean(raw) else { continue }
            if name.count > 24 { name = String(name.prefix(24)) }
            let key: String = ShopGuess.normalize(name)
            guard !key.isEmpty, !keys.contains(key) else { continue }
            keys.append(key)
            out.append(name)
            if out.count >= limit { break }
        }
        return out
    }

    static func actionID(_ index: Int) -> String { "ask\(index)" }

    /// 押されたボタンの名前から、何番目の候補か（違う名前なら nil）
    static func index(of actionID: String) -> Int? {
        guard actionID.hasPrefix("ask"), let n = Int(actionID.dropFirst(3)), n >= 0, n < candidateLimit else { return nil }
        return n
    }

    /// 通知のボタンの名前（候補の数だけ）
    static func savedTitles() -> [String] {
        UserDefaults.standard.stringArray(forKey: titlesKey) ?? []
    }

    static func askNotificationCategory() -> UNNotificationCategory {
        var actions: [UNNotificationAction] = []
        for (i, title) in savedTitles().prefix(candidateLimit).enumerated() {
            actions.append(UNNotificationAction(identifier: actionID(i), title: title, options: []))
        }
        return UNNotificationCategory(identifier: askCategory, actions: actions, intentIdentifiers: [], options: [])
    }

    // MARK: 1 日の数

    /// 今日の数（日が変わった分は数えない）
    static func count(_ saved: [String: Int], kind: String, day: String) -> Int {
        saved[kind + "|" + day] ?? 0
    }

    /// 1 つ足す（今日の分だけ残す）
    static func bumped(_ saved: [String: Int], kind: String, day: String) -> [String: Int] {
        var next: [String: Int] = [:]
        for (key, value) in saved where key.hasSuffix("|" + day) { next[key] = value }
        next[kind + "|" + day, default: 0] += 1
        return next
    }

    // MARK: 着いたら知らせる（104）

    /// 知らせるやること。まだ済んでいないもののうち、場所の名前が文に入っているもの・その場所によく一緒に行く相手に頼まれた（頼んだ）もの。
    /// 場所の名前は 2 文字以上のものだけ見る（短い名前の誤りを避ける）。最大 limit 件
    static func matchTasks(placeNames: [String], companions: [String], tasks: [TaskBook.Item], limit: Int = 3) -> [TaskBook.Item] {
        var names: [String] = []
        for name in placeNames {
            let key: String = ShopGuess.normalize(name)
            if key.count >= 2, !names.contains(key) { names.append(key) }
        }
        var people: [String] = []
        for person in companions {
            let key: String = PagesFeeds.nameKey(person)
            if !key.isEmpty { people.append(key) }
        }
        var out: [TaskBook.Item] = []
        for task in tasks where task.state == .open {
            let what: String = ShopGuess.normalize(task.what)
            var hit = false
            for key in names where what.contains(key) { hit = true }
            if !hit, let from = task.from, !from.isEmpty, people.contains(PagesFeeds.nameKey(from)) { hit = true }
            if hit { out.append(task) }
            if out.count >= limit { break }
        }
        return out
    }

    static func remindBody(_ tasks: [TaskBook.Item]) -> String {
        var lines: [String] = []
        for task in tasks {
            var text: String = task.what.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 40 { text = String(text.prefix(40)) + "…" }
            lines.append("・" + text)
        }
        return lines.joined(separator: "\n")
    }

    /// 同じ場所を 1 日 1 回にするための印
    static func remindKey(day: String, place: String) -> String { day + "|" + ShopGuess.normalize(place) }
}

// MARK: - 動かす

@MainActor
final class PlaceAssist {
    static let shared = PlaceAssist()

    private weak var pipeline: Pipeline?

    func attach(_ pipeline: Pipeline) {
        self.pipeline = pipeline
        pipeline.places.onVisitEvent = { [weak self] raw in self?.visit(raw) }
        pipeline.places.onSample = { [weak self] location in self?.moved(to: location) }
    }

    // MARK: 知らせを受ける

    private func visit(_ raw: RawVisit) {
        guard let pipeline, pipeline.places.isOn else { return }
        let here = CLLocation(latitude: raw.latitude, longitude: raw.longitude)
        if raw.departure == .distantFuture {
            let arrival: Date = raw.arrival == .distantPast ? .now : raw.arrival
            let accuracy: Double = max(raw.accuracy, 0)
            remindIfNeeded(near: here, accuracy: accuracy)
            Task { await askLater(arrival: arrival, here: here, accuracy: accuracy) }
        } else {
            cancelAskIfLeft(here)
        }
    }

    private func moved(to location: CLLocation) {
        cancelAskIfLeft(location)
        remindIfNeeded(near: location, accuracy: max(location.horizontalAccuracy, 0))
    }

    // MARK: 知っている場所か

    /// 登録した場所・本人が直した名前・本人が決めた立ち寄りの名前（確かな場所）。名前の一覧（近い順ではない）
    private func knownNames(near here: CLLocation, accuracy: Double) -> [String] {
        guard let pipeline else { return [] }
        var out: [String] = []
        if let place = pipeline.places.registeredPlace(near: here, accuracy: accuracy) { out.append(place.name) }
        out.append(contentsOf: PlaceNameBook.shared.names(near: here))
        for v in pipeline.shopVisits.visits where v.state == .confirmed && v.location.distance(from: here) < 100 {
            if let name = v.confirmedName, !out.contains(name) { out.append(name) }
        }
        return out
    }

    private func isKnown(_ here: CLLocation, accuracy: Double) -> Bool {
        !knownNames(near: here, accuracy: accuracy).isEmpty
    }

    // MARK: 30 分いたら聞く（91）

    private func today() -> String { PCJSON.dayString(.now) }

    private func savedCount(_ kind: String) -> Int {
        let saved: [String: Int] = UserDefaults.standard.dictionary(forKey: PlaceAssistRules.countsKey) as? [String: Int] ?? [:]
        return PlaceAssistRules.count(saved, kind: kind, day: today())
    }

    private func bump(_ kind: String) {
        let saved: [String: Int] = UserDefaults.standard.dictionary(forKey: PlaceAssistRules.countsKey) as? [String: Int] ?? [:]
        UserDefaults.standard.set(PlaceAssistRules.bumped(saved, kind: kind, day: today()), forKey: PlaceAssistRules.countsKey)
    }

    private func nearbyNames(_ here: CLLocation) async -> [String] {
        let request = MKLocalPointsOfInterestRequest(center: here.coordinate, radius: 120)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        var scored: [(String, Double)] = []
        for item in response.mapItems {
            guard let name = item.name, !name.isEmpty else { continue }
            let d: Double = item.placemark.location.map { here.distance(from: $0) } ?? 999
            scored.append((name, d))
        }
        scored.sort { $0.1 < $1.1 }
        return scored.prefix(3).map { $0.0 }
    }

    private func askLater(arrival: Date, here: CLLocation, accuracy: Double) async {
        guard let pipeline else { return }
        let known: Bool = isKnown(here, accuracy: accuracy)
        guard PlaceAssistRules.shouldAsk(on: PlaceAssistRules.askOn, known: known, meeting: MeetingMode.active != nil,
                                         askedToday: savedCount("ask")) else { return }
        var shop: [String] = []
        if let v = pipeline.shopVisits.visits.last(where: { $0.location.distance(from: here) < 150 && abs($0.arrival.timeIntervalSince(arrival)) < 3600 }) {
            shop = v.candidates.compactMap { $0.name }
        }
        let fixed: [String] = PlaceNameBook.shared.names(near: here)
        let nearby: [String] = await nearbyNames(here)
        var area: String? = pipeline.places.cachedAreaName(near: here)
        if area == nil { area = await pipeline.places.areaNameFor(here) }
        let list: [String] = PlaceAssistRules.candidates(fixed: fixed, shop: shop, nearby: nearby, area: area)
        guard !list.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        await clearAsk(center)
        UserDefaults.standard.set(list, forKey: PlaceAssistRules.titlesKey)
        center.setNotificationCategories(NoticeActions.categories())
        let content = UNMutableNotificationContent()
        content.title = "ここは、どこですか？"
        content.body = "30 分ほどいます。名前を教えてもらうと、次から使います。"
        content.categoryIdentifier = PlaceAssistRules.askCategory
        content.interruptionLevel = .passive
        content.userInfo = ["lat": here.coordinate.latitude, "lon": here.coordinate.longitude, "cands": list]
        let fire: Date = PlaceAssistRules.fireDate(arrival: arrival, now: .now)
        let id: String = PlaceAssistRules.askPrefix + String(Int(arrival.timeIntervalSince1970))
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(60, fire.timeIntervalSinceNow), repeats: false))
        do {
            try await center.add(request)
        } catch {
            return
        }
        UserDefaults.standard.set(["lat": here.coordinate.latitude, "lon": here.coordinate.longitude], forKey: PlaceAssistRules.pendingKey)
        bump("ask")
        Tally.add("placeask.scheduled")
    }

    /// 出す前の「ここは？」と、出したあとの「ここは？」を消す（ボタンの名前を入れ替えるので、1 つだけにする）
    private func clearAsk(_ center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ids: [String] = pending.map { $0.identifier }.filter { $0.hasPrefix(PlaceAssistRules.askPrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        let delivered = await center.deliveredNotifications()
        let shown: [String] = delivered.map { $0.request.identifier }.filter { $0.hasPrefix(PlaceAssistRules.askPrefix) }
        if !shown.isEmpty { center.removeDeliveredNotifications(withIdentifiers: shown) }
    }

    /// 聞く前に離れた（立ち寄りの「出た」・大きく動いた）ら、聞かない
    private func cancelAskIfLeft(_ here: CLLocation) {
        guard let saved = UserDefaults.standard.dictionary(forKey: PlaceAssistRules.pendingKey) as? [String: Double],
              let lat = saved["lat"], let lon = saved["lon"] else { return }
        guard CLLocation(latitude: lat, longitude: lon).distance(from: here) > PlaceAssistRules.leftDistance else { return }
        UserDefaults.standard.removeObject(forKey: PlaceAssistRules.pendingKey)
        Task {
            await clearAsk(UNUserNotificationCenter.current())
            Tally.add("placeask.cancelled")
        }
    }

    /// 会議が始まったとき、まだ出していない「ここは？」を取り消す（会議モード中は出さない）
    func meetingStarted() {
        UserDefaults.standard.removeObject(forKey: PlaceAssistRules.pendingKey)
        Task { await clearAsk(UNUserNotificationCenter.current()) }
    }

    /// 通知のボタンが押された（候補の名前を、位置で覚える）
    func answered(actionID: String, candidates: [String], latitude: Double?, longitude: Double?) {
        guard let index = PlaceAssistRules.index(of: actionID), candidates.indices.contains(index),
              let latitude, let longitude else { return }
        let name: String = candidates[index]
        PlaceNameBook.shared.fix(name: name, latitude: latitude, longitude: longitude, source: "watch")
        // 「行ったお店」にこの立ち寄りがあれば、その名前も本人が決めたものにする
        if let pipeline, pipeline.shopVisits.isOn {
            let here = CLLocation(latitude: latitude, longitude: longitude)
            if let v = pipeline.shopVisits.visits.last(where: { $0.location.distance(from: here) < 150 && $0.state != .confirmed }) {
                pipeline.shopVisits.setName(v.id, name)
            }
        }
        UserDefaults.standard.removeObject(forKey: PlaceAssistRules.pendingKey)
        Tally.add("placeask.answered")
    }

    // MARK: 着いたら知らせる（104）

    private func remindIfNeeded(near here: CLLocation, accuracy: Double) {
        guard PlaceAssistRules.remindOn, let pipeline, MeetingMode.active == nil,
              savedCount("remind") < PlaceAssistRules.remindDailyCap else { return }
        let names: [String] = knownNames(near: here, accuracy: accuracy)
        guard let first = names.first else { return }
        let day: String = today()
        let key: String = PlaceAssistRules.remindKey(day: day, place: first)
        var done: [String] = UserDefaults.standard.stringArray(forKey: PlaceAssistRules.remindedKey) ?? []
        guard !done.contains(key) else { return }

        // その場所によく一緒に行く相手（母艦の場所のページの「誰と」）
        var companions: [String] = []
        let keys: [String] = names.map { PagesFeeds.nameKey($0) }
        for page in PagesBook.shared.places where keys.contains(PagesFeeds.nameKey(page.name)) {
            companions.append(contentsOf: page.with)
        }
        let tasks: [TaskBook.Item] = PlaceAssistRules.matchTasks(placeNames: names, companions: companions, tasks: pipeline.tasks.items)
        guard !tasks.isEmpty else { return }

        done.append(key)
        UserDefaults.standard.set(Array(done.suffix(40)), forKey: PlaceAssistRules.remindedKey)
        bump("remind")
        let content = UNMutableNotificationContent()
        content.title = first + "で、やることがあります"
        content.body = PlaceAssistRules.remindBody(tasks)
        content.sound = .default
        content.userInfo = ["ids": tasks.map { $0.id }]
        let request = UNNotificationRequest(identifier: PlaceAssistRules.remindPrefix + String(abs(key.hashValue)), content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        UNUserNotificationCenter.current().add(request)
        Tally.add("placeremind.shown")
    }
}

import Foundation

// s20（2026-11-21）の決まり。画面から切り離した、確かめられる部分だけをここに置く（テストは LifeLogTests/S20DesignTests.swift）。
// しきい値はどれも「仮」（データがたまったら測り直す）。番号は母艦に出した 体1〜体38・次1〜次22。

// MARK: - 体1・体2 確かさ（意味の色の割り当て）

/// 画面に出すものの確かさ。色は DesignKit.swift の `Certainty.color`（意味の色）で決める
enum Certainty: String, CaseIterable, Codable, Sendable {
    /// 確か（本人が決めた・数えた事実）＝文字色
    case fact
    /// 見立て（仮）＝薄い文字＋点線の枠
    case guess
    /// 確かめ待ち＝差し色の細い枠
    case waiting
    /// 止まっている・注意＝琥珀
    case stopped
    /// 危ない＝くすんだ赤
    case danger
    /// よかった＝くすんだ緑（使う所を絞る）
    case good

    var label: String {
        switch self {
        case .fact: "確か"
        case .guess: "見立て（仮）"
        case .waiting: "確かめ待ち"
        case .stopped: "止まっている"
        case .danger: "危ない"
        case .good: "よかった"
        }
    }

    var symbol: String {
        switch self {
        case .fact: "checkmark.seal"
        case .guess: "questionmark.circle.dashed"
        case .waiting: "hand.raised"
        case .stopped: "pause.circle"
        case .danger: "exclamationmark.triangle"
        case .good: "sparkles"
        }
    }

    /// 自信の段（母艦の tiers_for_app の tier: auto 黙って入れる・tentative 仮・ask 聞く）から
    static func from(tier: String?) -> Certainty {
        switch tier {
        case "auto", "final": .fact
        case "ask": .waiting
        default: .guess
        }
    }

    /// 見立ての台帳の status（confirmed 確かめられた・alive まだ生きている・weakened 弱まった・unknown 分からない）から
    static func from(hypothesisStatus status: String) -> Certainty {
        switch status {
        case "confirmed": .fact
        case "weakened": .stopped
        case "unknown": .waiting
        default: .guess
        }
    }

    /// 施策の様子（live 動いている・broken 壊れている・retire_candidate 止める候補・unused 使われていない）から
    static func from(settleStatus status: String) -> Certainty {
        switch status {
        case "live": .good
        case "broken": .danger
        case "retire_candidate", "unused": .stopped
        default: .guess
        }
    }
}

// MARK: - 体4 札の小さな絵

enum TagIcons {
    /// 言葉の一部 → SF Symbols の名前（上から順に見る）
    static let table: [(keys: [String], symbol: String)] = [
        (["ラーメン", "らーめん", "麺"], "fork.knife"),
        (["ドライブ", "車", "レンタカー"], "car.fill"),
        (["ゴルフ"], "figure.golf"),
        (["ダンス", "踊"], "figure.dance"),
        (["映画", "シネマ"], "film"),
        (["ゲーム", "麻雀", "雀魂", "スプラ"], "gamecontroller.fill"),
        (["競馬", "馬"], "figure.equestrian.sports"),
        (["飲み会", "お酒", "居酒屋", "飲み"], "wineglass.fill"),
        (["カラオケ"], "music.mic"),
        (["写真"], "photo.on.rectangle.angled"),
        (["遠出", "旅", "県外"], "map.fill"),
        (["電車", "駅"], "tram.fill"),
        (["会議", "打ち合わせ"], "person.3.fill"),
        (["仕事", "職場"], "briefcase.fill"),
        (["家族", "実家"], "house.fill"),
        (["買い物", "服"], "bag.fill"),
    ]
    static let fallback = "tag"

    static func symbol(for tag: String) -> String {
        for row in table where row.keys.contains(where: { tag.contains($0) }) { return row.symbol }
        return fallback
    }
}

// MARK: - 体28 1 日の帯で範囲を選ぶ

enum BandRules {
    /// 指でなぞった範囲は、この分で切りそろえる（仮）
    static let snapMinutes = 5
    /// いちばん短い範囲（分）
    static let shortestMinutes = 5

    /// 帯の上の位置（0〜width）→ 時刻（snap 分で切りそろえる）
    static func time(atX x: Double, width: Double, dayStart: Date, dayEnd: Date, snap: Int = snapMinutes) -> Date {
        guard width > 0, dayEnd > dayStart else { return dayStart }
        let ratio = min(max(x / width, 0), 1)
        let raw = dayStart.timeIntervalSince1970 + ratio * dayEnd.timeIntervalSince(dayStart)
        let step = Double(max(1, snap)) * 60
        let snapped = (raw / step).rounded() * step
        return Date(timeIntervalSince1970: min(max(snapped, dayStart.timeIntervalSince1970), dayEnd.timeIntervalSince1970))
    }

    /// なぞり始めと終わりの位置から範囲（逆向きでもよい。短すぎるときは、いちばん短い長さに広げる）
    static func range(fromX a: Double, toX b: Double, width: Double, dayStart: Date, dayEnd: Date,
                      snap: Int = snapMinutes) -> ClosedRange<Date> {
        var from = time(atX: min(a, b), width: width, dayStart: dayStart, dayEnd: dayEnd, snap: snap)
        var to = time(atX: max(a, b), width: width, dayStart: dayStart, dayEnd: dayEnd, snap: snap)
        let shortest = Double(shortestMinutes) * 60
        if to.timeIntervalSince(from) < shortest {
            to = min(from.addingTimeInterval(shortest), dayEnd)
            if to.timeIntervalSince(from) < shortest { from = max(dayStart, to.addingTimeInterval(-shortest)) }
        }
        return from...to
    }

    /// 時刻 → 帯の上の位置
    static func x(of time: Date, width: Double, dayStart: Date, dayEnd: Date) -> Double {
        let span = dayEnd.timeIntervalSince(dayStart)
        guard span > 0 else { return 0 }
        return min(max(time.timeIntervalSince(dayStart) / span, 0), 1) * width
    }

    /// 範囲の言い方（「10:05〜11:30（85 分）」）
    static func label(_ range: ClosedRange<Date>, calendar: Calendar = .current) -> String {
        func hm(_ d: Date) -> String {
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let minutes = Int((range.upperBound.timeIntervalSince(range.lowerBound) / 60).rounded())
        return "\(hm(range.lowerBound))〜\(hm(range.upperBound))（\(minutes) 分）"
    }
}

// MARK: - 体29 消すときの安心

enum ForgetRules {
    /// 消す前に取り消せる秒数
    static let undoSeconds = 30

    /// 消すものの言い方（何が消えるか）
    static func summary(lines: Int, conversations: Int, audio: Int) -> String {
        var parts: [String] = []
        parts.append("文字 \(lines) 行")
        if conversations > 0 { parts.append("会話 \(conversations) 件") }
        parts.append("録音 \(audio) 個")
        return parts.joined(separator: "・")
    }

    /// 家の PC に送る消す頼み（POST /records/<日>/forget）の中身
    static func pcBody(from: Date, to: Date, timeZone: TimeZone = .current) -> Data? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        let object: [String: String] = ["from": f.string(from: from), "to": f.string(from: to)]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - 体16・体17 便り（1 日 2 回）と通知の 3 行の型

enum NoticeDigestRules {
    /// 朝の便り（0 時からの分。仮）
    static let morningMinutes = 7 * 60 + 30
    /// 夕の便り（仮）
    static let eveningMinutes = 19 * 60
    /// 便りに回したものを残す数
    static let keep = 40
    static let morningID = "digest-morning"
    static let eveningID = "digest-evening"

    /// すぐ出すもの（急ぎ）か。束ねない知らせ（ボタンのあるもの・録音が止まった）と、期限・約束・署名の期限
    static func isUrgent(identifier: String, category: String) -> Bool {
        if NoticeBundle.isExempt(identifier: identifier, category: category) { return true }
        let urgentPrefixes = ["tasks-due-", "signExpiry-", "digest-", NoticeBundle.bundleID]
        return urgentPrefixes.contains { identifier.hasPrefix($0) }
    }

    /// 次の便りの時刻（now より後のいちばん近い朝か夕）
    static func nextSlot(after now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        let candidates: [Date] = [
            start.addingTimeInterval(Double(morningMinutes) * 60),
            start.addingTimeInterval(Double(eveningMinutes) * 60),
            start.addingTimeInterval(86400 + Double(morningMinutes) * 60),
        ]
        return candidates.first { $0 > now } ?? candidates[2]
    }

    /// いちばん近い過ぎた便りの時刻（これより後にためたものが、次の便りに入る）
    static func previousSlot(before now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        let candidates: [Date] = [
            start.addingTimeInterval(-86400 + Double(eveningMinutes) * 60),
            start.addingTimeInterval(Double(morningMinutes) * 60),
            start.addingTimeInterval(Double(eveningMinutes) * 60),
        ]
        return candidates.last { $0 <= now } ?? candidates[0]
    }

    /// 便りが朝か（時刻から）
    static func isMorning(_ slot: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: slot) < 12
    }

    /// 便りの 3 行（何が起きたか／なぜか／押すとどうなるか）
    static func digest(titles: [String], morning: Bool) -> (title: String, body: String) {
        let what = (morning ? "朝の便り" : "夕方の便り") + "：\(titles.count) 件"
        var shown: [String] = []
        for t in titles.reversed() where !t.isEmpty && !shown.contains(t) {
            shown.append(t)
            if shown.count >= 3 { break }
        }
        let list = shown.joined(separator: "・") + (titles.count > shown.count ? " など" : "")
        return NoticeText.make(what: what, why: list.isEmpty ? "急ぎでない知らせをまとめました" : list,
                               tap: "知らせの履歴を開きます")
    }
}

/// 通知の文の型（体17）: 1 行め＝何が起きたか（題）、2 行め＝なぜか、3 行め＝押すとどうなるか
enum NoticeText {
    static func make(what: String, why: String, tap: String) -> (title: String, body: String) {
        (String(what.prefix(60)), String(why.prefix(120)) + "\n押すと: " + String(tap.prefix(40)))
    }
}

// MARK: - 体19 通知の履歴

struct NoticeLogEntry: Codable, Equatable, Identifiable {
    var id: String
    /// 種類（NoticeBundle.kind）
    var kind: String
    var title: String
    var at: Date
    /// 便りに回した
    var held: Bool = false
    /// 押して開いた
    var opened: Bool? = nil
}

enum NoticeHistoryRules {
    /// 残す日数
    static let keepDays = 7
    static let limit = 300

    /// 「この種類はもう要らない」にした種類なら出さない（急ぎは止めない）
    static func shouldDrop(kind: String, muted: Set<String>, urgent: Bool) -> Bool {
        !urgent && muted.contains(kind)
    }

    static func pruned(_ list: [NoticeLogEntry], now: Date) -> [NoticeLogEntry] {
        let oldest = now.addingTimeInterval(-Double(keepDays) * 86400)
        return Array(list.filter { $0.at >= oldest }.suffix(limit))
    }

    /// 種類の言い方
    static func kindLabel(_ kind: String) -> String {
        let names: [String: String] = [
            "taskFound": "頼まれごとを見つけた", "taskDue": "期限の前", "tasks": "朝夕の頼まれごと", "brief": "朝のまとめ",
            "signExpiry": "署名の期限", "fresh": "止まっているかも", "proposal": "提案", "promise": "会話のあとの約束",
            "bundle": "まとめた知らせ", "digest": "便り", "knowme": "自分を知る", "holiday": "休日",
        ]
        if let name = names[kind] { return name }
        for (key, name) in names where kind.hasPrefix(key) { return name }
        return kind
    }
}

// MARK: - 体31 場面のセット

enum LifeScene: String, CaseIterable, Identifiable, Codable, Sendable {
    case usual, holiday, meeting, travel
    var id: String { rawValue }

    var label: String {
        switch self {
        case .usual: "ふだん"
        case .holiday: "休日"
        case .meeting: "会議"
        case .travel: "旅行"
        }
    }

    var symbol: String {
        switch self {
        case .usual: "sun.max"
        case .holiday: "beach.umbrella"
        case .meeting: "person.3"
        case .travel: "airplane"
        }
    }

    var note: String {
        switch self {
        case .usual: "平日の初めの形。休日の促しは止め、知らせはその場で。"
        case .holiday: "休日の知らせ・一言・映画館で休む・写真を入れ、急ぎでない知らせは朝夕の便りに。"
        case .meeting: "会議のあいだ、急ぎでない知らせを便りに回す。会議モードは別のボタンで始める。"
        case .travel: "時計の外出モード・電池の見張り・写真と場所を入れ、知らせは便りに。"
        }
    }
}

/// 場面のセットで変えるスイッチ（どれも前からある設定の名前。ここに無い設定は変えない）
enum SceneKey: String, CaseIterable, Sendable {
    case noticeDigest = "s20.noticeDigest"
    case recordNudge = "holiday.recordNudge"
    case checkup = "holiday.checkup"
    case awayMode = "holiday.awayMode"
    case lowBattery = "holiday.lowBattery"
    case placeAfter = "holiday.placeAfter"
    case payNote = "holiday.payNote"
    case venueHold = "holiday.venueHold"
    case best = "holiday.best"
    case dayPhotos = "dayPhotosOn"
    case places = "places"
    case stopAlerts = "stopAlerts"
    case batterySaver = "chunkBatterySaver"

    var label: String {
        switch self {
        case .noticeDigest: "急ぎでない知らせを朝夕の便りに"
        case .recordNudge: "家を出たら録音の促し"
        case .checkup: "家を出たら点検"
        case .awayMode: "時計の外出モード"
        case .lowBattery: "時計の電池が少ないとき知らせる"
        case .placeAfter: "滞在のあと「さっきの所は？」"
        case .payNote: "払ったあとに一言"
        case .venueHold: "映画館・ライブでは録音を休む"
        case .best: "夜に「今日いちばんよかった瞬間」"
        case .dayPhotos: "会話の横に写真"
        case .places: "場所を記録する"
        case .stopAlerts: "録音が止まったら知らせる"
        case .batterySaver: "電池が少ないときは区切りを 5 分に"
        }
    }
}

enum SceneSets {
    static let currentKey = "s20.scene"

    /// 場面ごとに変えるスイッチと値（ここに無いスイッチは、そのまま）
    static func values(for scene: LifeScene) -> [SceneKey: Bool] {
        switch scene {
        case .usual:
            [.noticeDigest: false, .recordNudge: false, .awayMode: false, .venueHold: false, .stopAlerts: true]
        case .holiday:
            [.noticeDigest: true, .checkup: true, .placeAfter: true, .payNote: true, .venueHold: true, .best: true,
             .dayPhotos: true, .places: true, .stopAlerts: true]
        case .meeting:
            [.noticeDigest: true, .recordNudge: false, .stopAlerts: true]
        case .travel:
            [.noticeDigest: true, .awayMode: true, .lowBattery: true, .placeAfter: true, .dayPhotos: true, .places: true,
             .batterySaver: true]
        }
    }

    /// いまの設定がその場面とそろっているか（読めた値だけで比べる）
    static func matches(_ scene: LifeScene, read: (SceneKey) -> Bool?) -> Bool {
        values(for: scene).allSatisfy { key, value in read(key) == value }
    }
}

// MARK: - 次10 寝ているあいだは録音を休む

enum SleepPauseRules {
    static let enabledKey = "s20.sleepPause"
    static let startKey = "s20.sleepPauseStart"
    static let endKey = "s20.sleepPauseEnd"
    /// 集中モード（睡眠）がオンになった時刻（ショートカットの「LifeLog の睡眠で休む」から。0 ならオフ）
    static let focusSinceKey = "s20.sleepFocusSince"
    /// 集中モードの印は、これより長くは信じない（オフを伝え忘れても、朝には戻る。仮）
    static let focusLongest: TimeInterval = 14 * 3600
    /// 初めの時刻（0 時からの分。仮）
    static let defaultStart = 0 * 60 + 30
    static let defaultEnd = 6 * 60 + 30

    /// その分（0 時からの分）が休む時間の中か（日をまたいでもよい）
    static func inWindow(minute: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }

    /// 休むか（設定がオンのときだけ）。集中モードの印があればそれを先に、無ければ時刻で
    static func shouldHold(enabled: Bool, now: Date, start: Int, end: Int, focusSince: Double,
                           calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        if focusSince > 0 {
            let age = now.timeIntervalSince1970 - focusSince
            if age >= 0 && age < focusLongest { return true }
        }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        return inWindow(minute: (c.hour ?? 0) * 60 + (c.minute ?? 0), start: start, end: end)
    }
}

// MARK: - 体37 一緒にいる人に見せる 1 枚（その人といるあいだ休む）

enum PersonPauseRules {
    static let untilKey = "s20.personPauseUntil"
    /// 選べる長さ（分）
    static let choices: [Int] = [30, 60, 180]

    static func holding(until: Double, now: Date) -> Bool { until > now.timeIntervalSince1970 }
}

// MARK: - 次15 電車の中の印

enum TrainRules {
    /// 乗り物の動き（「電車・車で」）で、車につないでおらず、駅の近く（場所・場面の名前に駅・電車・線）なら電車
    static func isTrain(movement: String?, inCar: Bool, place: String?, scene: String?) -> Bool {
        guard !inCar, movement == "電車・車で" else { return false }
        let hints = ["駅", "電車", "線", "地下鉄", "メトロ"]
        let text = (place ?? "") + " " + (scene ?? "")
        return hints.contains { text.contains($0) }
    }
}

// MARK: - 次3・体11〜15 確かめ待ちの列

/// 母艦の state/review_queue_for_app.json（M が作る）。家の PC の GET /review-queue（features の "reviewq"）で届く
struct ReviewQueueFeed: Codable, Equatable {
    var version: Int? = nil
    var available: Bool? = nil
    var generated_at: String? = nil
    var items: [ReviewItem]? = nil
    /// 前に答えたものが何を直したか（体14。母艦が返すときだけ）
    var done: [ReviewDone]? = nil
}

struct ReviewItem: Codable, Equatable, Identifiable {
    struct Evidence: Codable, Equatable {
        var text: String
        var ref: String? = nil
    }

    /// 体12 声を聞いて選ぶ（家の PC の音の道。無ければ文だけで聞く）
    struct Clip: Codable, Equatable {
        var label: String
        /// 家の PC の道（例 "voice/clip?audio=…&start=…"）
        var path: String
    }

    var id: String
    /// ramen・with_people・kanojo・name・place など
    var kind: String
    var question: String
    /// yesno・pick・text
    var answer: String
    var choices: [String]? = nil
    var evidence: [Evidence]? = nil
    /// この日を過ぎたら流す（14 日）
    var expires: String? = nil
    var group: String? = nil
    var clips: [Clip]? = nil
}

struct ReviewDone: Codable, Equatable {
    var id: String
    /// この答えで直った行の数
    var changed: Int? = nil
    var note: String? = nil
}

enum ReviewRules {
    /// 流れるまでの日数（母艦と同じ 14 日）
    static let lifeDays = 14
    /// 1 枚にかける目安の秒
    static let secondsPerCard = 3
    /// まとめて答える組の大きさの下限
    static let groupMin = 2

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 見せるもの: 流れていない・答えていないもの。「あとで」にしたものは今日は出さない（明日また出す）
    static func visible(_ items: [ReviewItem], answered: Set<String>, later: [String: String], now: Date,
                        calendar: Calendar = .current) -> [ReviewItem] {
        let today = dayKey(now, calendar: calendar)
        return items.filter { item in
            if answered.contains(item.id) { return false }
            if let expires = item.expires, expires < today { return false }
            if later[item.id] == today { return false }
            return true
        }
    }

    /// あと何日で流れるか（流れる日が分からなければ nil。今日なら 0）
    static func daysLeft(_ item: ReviewItem, now: Date, calendar: Calendar = .current) -> Int? {
        guard let expires = item.expires else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let end = f.date(from: expires) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: end).day ?? 0
        return max(0, days)
    }

    /// 似たもの（同じ group、無ければ同じ種類で同じ問い）の組。groupMin 以上のものだけ
    static func groups(_ items: [ReviewItem]) -> [[ReviewItem]] {
        var order: [String] = []
        var byKey: [String: [ReviewItem]] = [:]
        for item in items where item.answer == "yesno" {
            let key = item.group.map { "g:" + $0 } ?? ("q:" + item.kind + "|" + item.question)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.compactMap { byKey[$0] }.filter { $0.count >= groupMin }
    }

    /// 種類の言い方
    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "ramen": "ラーメン"
        case "with_people": "一緒にいた人"
        case "kanojo": "「彼女」の確かめ"
        case "name": "名前の候補"
        case "place": "場所"
        case "voice": "声"
        case "deadline", "request": "依頼と期限"
        default: kind
        }
    }

    /// 体14: 答えで何が変わったか（返ってきた数があるときだけ。0 や無いときは nil）
    static func changedLine(_ done: ReviewDone?) -> String? {
        guard let n = done?.changed, n > 0 else { return nil }
        return "この答えで \(n) 行が直りました"
    }

    /// 答えの 1 行（家の PC の POST /feedback → 母艦の inbox/app_feedback.jsonl）
    static func answerBody(id: String, answer: String, at: Date, timeZone: TimeZone = .current) -> Data? {
        guard HomeFeeds.isID(id), !answer.isEmpty, answer.count <= 200 else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        let object: [String: String] = ["kind": "review", "id": id, "answer": answer, "at": f.string(from: at)]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - 次1・体26 検品表

/// 母艦の state/audit/feature_check_for_app.json（家の PC の GET /feature-check。features の "featcheck"）
struct FeatureCheckFeed: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var group: String? = nil
        var alive: Bool? = nil
        var used: Int? = nil
        var hit: Double? = nil
        /// keep・stop・watch
        var suggest: String? = nil
    }

    var generated_at: String? = nil
    var items: [Item]? = nil
}

enum FeatureCheckRules {
    /// 通信簿の段（A よく使う・B ときどき・C 使っていない・× 動いていない）
    static func grade(_ item: FeatureCheckFeed.Item) -> String {
        if item.alive == false { return "×" }
        let used = item.used ?? 0
        if used >= 10 { return "A" }
        if used >= 2 { return "B" }
        return "C"
    }

    static func certainty(_ item: FeatureCheckFeed.Item) -> Certainty {
        switch grade(item) {
        case "×": .danger
        case "C": .stopped
        case "A": .good
        default: .fact
        }
    }

    /// 答えの 1 行（POST /feature-answer → 母艦の inbox/feature_answers.jsonl）
    static func answerBody(id: String, keep: Bool, at: Date, timeZone: TimeZone = .current) -> Data? {
        guard HomeFeeds.isID(id) else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        let object: [String: Any] = ["id": id, "keep": keep, "at": f.string(from: at)]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - 次16・体8 実機の確かめ（母艦の state/device_checks.json。GET /device-checks・"devchecks"）

struct DeviceChecksFeed: Codable, Equatable {
    struct Check: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        /// true ○・false ×・nil まだ分からない
        var ok: Bool? = nil
        var note: String? = nil
        var day: String? = nil
    }

    var generated_at: String? = nil
    var checks: [Check]? = nil
}

// MARK: - 体8 録音の丸 3 つ

enum CaptureDot: String, CaseIterable, Identifiable {
    case watch, phone, plaud
    var id: String { rawValue }

    var label: String {
        switch self {
        case .watch: "時計"
        case .phone: "iPhone"
        case .plaud: "PLAUD"
        }
    }

    var symbol: String {
        switch self {
        case .watch: "applewatch"
        case .phone: "iphone"
        case .plaud: "waveform.badge.mic"
        }
    }
}

enum CaptureDotState: Equatable {
    /// 録っている
    case on
    /// 休んでいる（休む場所・寝ている・止めた）
    case resting(String)
    /// 止まっている（録るはずなのに）
    case stopped(String)
    /// 分からない
    case unknown

    var certainty: Certainty {
        switch self {
        case .on: .good
        case .resting: .guess
        case .stopped: .stopped
        case .unknown: .guess
        }
    }
}

// MARK: - 体38 体験の数字

enum UXMetrics {
    static let key = "s20.ux"

    struct Day: Codable, Equatable {
        var answerSeconds: [Double] = []
        var notifShown = 0
        var notifOpened = 0
        var muted: [String] = []
    }

    /// 答えるまでの秒（長すぎるもの＝置きっぱなしは数えない。仮 60 秒）
    static func addAnswer(_ day: inout Day, seconds: Double) {
        guard seconds > 0, seconds <= 60 else { return }
        day.answerSeconds.append((seconds * 10).rounded() / 10)
        if day.answerSeconds.count > 200 { day.answerSeconds.removeFirst(day.answerSeconds.count - 200) }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// diag の detail に足す（どれも省略できる）
    static func detail(_ day: Day) -> [String: Any] {
        var out: [String: Any] = [:]
        if let m = median(day.answerSeconds) { out["uxAnswerSeconds"] = m }
        if day.notifShown > 0 {
            out["uxNotifShown"] = day.notifShown
            out["uxNotifOpened"] = day.notifOpened
        }
        if !day.muted.isEmpty { out["uxNotifMuted"] = day.muted }
        return out
    }
}

// MARK: - 体10 朝と夜

enum DayPart: Equatable {
    case morning, day, night

    /// 朝 5〜11 時・夜 19〜翌 4 時（仮）
    static func of(_ date: Date, calendar: Calendar = .current) -> DayPart {
        let h = calendar.component(.hour, from: date)
        if h >= 5 && h < 11 { return .morning }
        if h >= 19 || h < 4 { return .night }
        return .day
    }

    var greeting: String {
        switch self {
        case .morning: "おはようございます"
        case .day: "今日"
        case .night: "おつかれさまでした"
        }
    }
}

// MARK: - 体32 アップデートのあとの案内

enum WhatsNew {
    static let seenKey = "s20.whatsNewSeen"
    /// 版が変わったら、初めて開いたときに 1 画面で出す（2026-11-22 に s21。s21 の 使4）
    static let version = "s21"

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        /// その場で入り切りするスイッチ（無ければ見せるだけ）
        let key: String?
        /// スイッチの初めの値（まだ触っていないとき）
        var defaultOn: Bool = false
    }

    /// 今回の分（s21 から 3 つ・s18〜s20 から 3 つ。新しいものが上）
    static let items: [Item] = [
        Item(id: "shake", title: "振って「いまの画面が変」", detail: "iPhone を振ると、その画面の名前とひとことを家の PC に送ります（s21）",
             symbol: "iphone.radiowaves.left.and.right", key: S21Book.shakeKey, defaultOn: true),
        Item(id: "sleepChunks", title: "寝ている時間は時計の区切りを 5 分に", detail: "1:00〜6:00 で充電していないとき、時計の電池を守ります（s21）",
             symbol: "moon.stars", key: S21Watch.sleepChunksKey, defaultOn: true),
        Item(id: "workoutGuard", title: "時計の強い守り（ワークアウト扱い）", detail: "画面が消えても録音を止めにくくします。電池を多く使います（s21・初めはオフ）",
             symbol: "figure.walk.motion", key: S21Watch.workoutGuardKey),
        Item(id: "digest", title: "知らせを朝夕の便りに", detail: "急ぎでない知らせを 1 日 2 回にまとめます（s20）",
             symbol: "envelope.badge", key: SceneKey.noticeDigest.rawValue),
        Item(id: "sleep", title: "寝ているあいだは録音を休む", detail: "時刻か、集中モード（睡眠）で休みます（s20）",
             symbol: "moon.zzz", key: SleepPauseRules.enabledKey),
        Item(id: "holiday", title: "休日の一言", detail: "夜に「今日いちばんよかった瞬間」をたずねます（s19）",
             symbol: "sparkles", key: HolidaySettings.bestKey),
    ]
}

// MARK: - 体8 録音の丸 3 つの決め方

enum CaptureRules {
    /// 時計の様子がこれより古ければ「分からない」（仮）
    static let watchFresh: TimeInterval = 45 * 60
    /// PLAUD の取り込みがこれより古ければ「止まっているかも」（仮。家の PC の新しさの見張りが無いとき）
    static let plaudFresh: TimeInterval = 36 * 3600

    static func watch(recording: Bool?, resting: Bool?, held: Bool, seen: Date?, now: Date) -> CaptureDotState {
        guard let seen, now.timeIntervalSince(seen) < watchFresh, let recording else {
            return seen == nil ? .unknown : .stopped("時計から 45 分以上、知らせが届いていません")
        }
        if !recording { return .resting("時計の録音は止めてあります") }
        if held { return .resting("録音を休む場所にいるので書いていません") }
        if resting == true { return .resting("静かなので書くのを休んでいます") }
        return .on
    }

    static func phone(recording: Bool, held: Bool) -> CaptureDotState {
        if !recording { return .resting("iPhone の録音は止めてあります") }
        return held ? .resting("録音を休む場所にいるので書いていません") : .on
    }

    static func plaud(last: Date?, stale: Bool?, now: Date) -> CaptureDotState {
        if stale == true { return .stopped("家の PC が PLAUD の取り込みが止まっていると言っています") }
        guard let last else { return .unknown }
        return now.timeIntervalSince(last) < plaudFresh ? .on : .stopped("PLAUD の取り込みが 36 時間ありません")
    }

    /// 直し方（止まっている・分からないとき）
    static func fix(_ dot: CaptureDot, _ state: CaptureDotState) -> String? {
        switch (dot, state) {
        case (_, .on), (_, .resting): return nil
        case (.watch, _): return "時計の LifeLog を開いて、録音のボタンを押してください。iPhone を近くに置くと届きます。"
        case (.phone, _): return "下の「録音を始める」を押してください。"
        case (.plaud, _): return "PLAUD のアプリを開いて同期し、家の PC の取り込みを確かめてください。"
        }
    }
}

// MARK: - 体3・体24 数とふり返りの物語

enum StoryRules {
    /// お店の名前からラーメンらしいか（端末の中の粗い見立て。正しい杯数は母艦が数える）
    static func isRamen(_ name: String) -> Bool {
        ["ラーメン", "らーめん", "拉麺", "中華そば", "つけ麺", "麺", "家系", "二郎"].contains { name.contains($0) }
    }

    /// 期間（月・年）の始まりと終わり
    static func range(month: Bool, containing date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let comps: Set<Calendar.Component> = month ? [.year, .month] : [.year]
        let start = calendar.date(from: calendar.dateComponents(comps, from: date)) ?? date
        let end = calendar.date(byAdding: month ? .month : .year, value: 1, to: start) ?? date
        return (start, end)
    }

    /// 物語の 1 枚の言葉（数が 0 なら出さない）
    static func pages(conversations: Int, people: Int, places: Int, ramen: Int, holidays: Int, recordedHours: Int) -> [(title: String, value: String, note: String)] {
        var out: [(title: String, value: String, note: String)] = []
        if conversations > 0 { out.append(("話した", "\(conversations)", "回の会話")) }
        if people > 0 { out.append(("会った人", "\(people)", "人（名前のある人）")) }
        if places > 0 { out.append(("行った所", "\(places)", "か所")) }
        if ramen > 0 { out.append(("ラーメン", "\(ramen)", "杯（見立て。正しくは母艦）")) }
        if holidays > 0 { out.append(("休日", "\(holidays)", "日")) }
        if recordedHours > 0 { out.append(("録った時間", "\(recordedHours)", "時間")) }
        return out
    }
}

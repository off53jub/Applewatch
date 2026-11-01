import Contacts
import CoreMotion
import EventKit
import Foundation
import Observation

/// カレンダーの予定。会話の見出し、聞き取りのヒント（予定名・参加者・場所）、職場かどうかの判断、
/// 1日の「過ごし方」の区切りに使う。iPhone のカレンダーに入っているものはすべて読める
/// （Google カレンダーも、iPhone の設定で Google アカウントを足せば読める）。
@MainActor
@Observable
final class CalendarLink {
    var enabled = UserDefaults.standard.bool(forKey: "calendarOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "calendarOn") }
    }
    /// 職場の予定が入っているカレンダー（ここの予定の時間は職場とみなす）
    var workCalendars = Set(UserDefaults.standard.stringArray(forKey: "workCalendars") ?? []) {
        didSet { UserDefaults.standard.set(Array(workCalendars), forKey: "workCalendars") }
    }
    /// 使わないカレンダー（家族の共有カレンダーなど、本人の予定ではないもの）
    var ignoredCalendars = Set(UserDefaults.standard.stringArray(forKey: "ignoredCalendars") ?? []) {
        didSet { UserDefaults.standard.set(Array(ignoredCalendars), forKey: "ignoredCalendars") }
    }
    private(set) var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    struct Event {
        let title: String
        let attendees: [String]
        let isWork: Bool
        var start: Date = .distantPast
        var end: Date = .distantPast
        /// 予定の場所（無ければ nil）
        var location: String? = nil
    }

    @ObservationIgnored private let store = EKEventStore()

    func requestAccess() async {
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
        if authorized { enabled = true }
    }

    var calendars: [EKCalendar] {
        guard authorized else { return [] }
        return store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    /// アカウント（iCloud・Google など）ごとのカレンダー
    var calendarsByAccount: [(account: String, calendars: [EKCalendar])] {
        let groups = Dictionary(grouping: calendars) { $0.source?.title ?? "その他" }
        return groups.map { ($0.key, $0.value) }.sorted { $0.account < $1.account }
    }

    /// Google のアカウントのカレンダーが iPhone に入っているか
    var hasGoogle: Bool {
        calendars.contains { cal in
            let title = cal.source?.title.lowercased() ?? ""
            return title.contains("gmail") || title.contains("google")
        }
    }

    /// 1日の中の予定（終日の予定・使わないカレンダーの予定・12時間より長い予定は除く）。始まりの順。
    func dayEvents(from start: Date, to end: Date) -> [Event] {
        events(from: start, to: end)
            .filter { $0.end.timeIntervalSince($0.start) <= 12 * 3600 }
            .sorted { $0.start < $1.start }
    }

    /// その時間に重なる予定（終日の予定は除く）。いちばん長く重なるものから。
    func events(from start: Date, to end: Date) -> [Event] {
        guard enabled, authorized else { return [] }
        let end = max(end, start.addingTimeInterval(60))
        let use = ignoredCalendars.isEmpty ? nil
            : store.calendars(for: .event).filter { !ignoredCalendars.contains($0.calendarIdentifier) }
        if use?.isEmpty == true { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: use)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { overlap($0, start, end) > overlap($1, start, end) }
            .map { e in
                let attendees = (e.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { p -> String? in
                    guard let name = p.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") else { return nil }
                    return name
                }
                let location = e.location?.split(separator: "\n").first
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                return Event(title: e.title ?? "", attendees: attendees,
                             isWork: workCalendars.contains(e.calendar.calendarIdentifier),
                             start: e.startDate, end: e.endDate,
                             location: location?.isEmpty == false ? location : nil)
            }
    }

    func event(at time: Date) -> Event? { events(from: time, to: time).first }

    /// その時間に職場の予定があれば職場（職場のカレンダーを選んでいなければ nil）
    func context(at time: Date) -> SpeakerLabeler.Context? {
        guard !workCalendars.isEmpty, let event = event(at: time) else { return nil }
        return event.isWork ? .work : nil
    }

    private func overlap(_ e: EKEvent, _ start: Date, _ end: Date) -> TimeInterval {
        min(e.endDate, end).timeIntervalSince(max(e.startDate, start))
    }
}

/// 移動の様子（歩いている・乗り物・止まっている）。iPhone の動きから分かる。
@MainActor
@Observable
final class MotionLink {
    enum Movement: String {
        case stationary, walking, running, cycling, vehicle

        /// 見出しに添える言葉（止まっているときは何も付けない）
        var label: String? {
            switch self {
            case .stationary: nil
            case .walking: "歩きながら"
            case .running: "走りながら"
            case .cycling: "自転車で"
            case .vehicle: "電車・車で"
            }
        }

        /// 録音の無い時間を「過ごし方」に入れるときの名前
        var activityTitle: String? {
            switch self {
            case .stationary: nil
            case .walking: "歩いて移動"
            case .running: "ランニング"
            case .cycling: "自転車で移動"
            case .vehicle: "電車・車で移動"
            }
        }
    }

    var enabled = UserDefaults.standard.bool(forKey: "motionOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "motionOn") }
    }
    var available: Bool { CMMotionActivityManager.isActivityAvailable() }
    private(set) var authorized = CMMotionActivityManager.authorizationStatus() == .authorized

    @ObservationIgnored private let manager = CMMotionActivityManager()

    /// 許可を聞く（直近の動きを1回読むと聞かれる）
    func requestAccess() async {
        _ = await activities(from: .now.addingTimeInterval(-60), to: .now)
        authorized = CMMotionActivityManager.authorizationStatus() == .authorized
        if authorized { enabled = true }
    }

    /// その時間でいちばん長かった動き。分からなければ nil。
    func movement(from start: Date, to end: Date) async -> Movement? {
        guard enabled, available else { return nil }
        let shares = await shares(from: start, to: end)
        return shares.max { $0.value < $1.value }.map(\.key)
    }

    /// その時間に、止まっていない動き（歩く・乗り物など）が続いたところ。15分以上のものだけ、時刻順。
    func trips(from start: Date, to end: Date) async -> [(start: Date, end: Date, movement: Movement)] {
        guard enabled, available, end > start else { return [] }
        let list = await activities(from: start, to: end)
        var result: [(start: Date, end: Date, movement: Movement)] = []
        for (i, a) in list.enumerated() where a.confidence != .low {
            let from = max(a.startDate, start)
            let to = min(i + 1 < list.count ? list[i + 1].startDate : end, end)
            guard to > from else { continue }
            let kind: Movement? = a.automotive ? .vehicle : a.cycling ? .cycling : a.running ? .running
                : a.walking ? .walking : nil
            guard let kind else { continue }
            // 同じ動きが5分以内に続いていたら、つなげる
            if let last = result.last, last.movement == kind, from.timeIntervalSince(last.end) <= 300 {
                result[result.count - 1].end = to
            } else {
                result.append((from, to, kind))
            }
        }
        return result.filter { $0.end.timeIntervalSince($0.start) >= 15 * 60 }
    }

    /// その時間のうち、止まっていた割合（0〜1）。分からなければ nil。
    func stillness(from start: Date, to end: Date) async -> Double? {
        guard enabled, available else { return nil }
        let shares = await shares(from: start, to: end)
        let total = shares.values.reduce(0, +)
        guard total > 0 else { return nil }
        return (shares[.stationary] ?? 0) / total
    }

    private func shares(from start: Date, to end: Date) async -> [Movement: TimeInterval] {
        let list = await activities(from: start.addingTimeInterval(-600), to: end)
        var result: [Movement: TimeInterval] = [:]
        for (i, a) in list.enumerated() where a.confidence != .low {
            let from = max(a.startDate, start)
            let to = min(i + 1 < list.count ? list[i + 1].startDate : end, end)
            guard to > from else { continue }
            let kind: Movement? = a.automotive ? .vehicle : a.cycling ? .cycling : a.running ? .running
                : a.walking ? .walking : a.stationary ? .stationary : nil
            if let kind { result[kind, default: 0] += to.timeIntervalSince(from) }
        }
        return result
    }

    private func activities(from start: Date, to end: Date) async -> [CMMotionActivity] {
        guard available else { return [] }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { list, _ in
                continuation.resume(returning: list ?? [])
            }
        }
    }
}

/// 寝ているあいだ。寝る時間帯に iPhone がずっと止まっていたら、寝ているとみなす。
/// （ヘルスケアの睡眠は、アプリの署名に特別な許可が要り、Sideloadly では入れられないため使わない）
@MainActor
@Observable
final class SleepGuess {
    var enabled = UserDefaults.standard.bool(forKey: "sleepOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "sleepOn") }
    }
    /// 寝る時間帯（時）。例: 0〜7 なら 0:00〜6:59
    var startHour = UserDefaults.standard.object(forKey: "sleepStart") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(startHour, forKey: "sleepStart") }
    }
    var endHour = UserDefaults.standard.object(forKey: "sleepEnd") as? Int ?? 7 {
        didSet { UserDefaults.standard.set(endHour, forKey: "sleepEnd") }
    }

    func inWindow(_ time: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: time)
        return startHour <= endHour ? (startHour..<endHour).contains(hour)
            : hour >= startHour || hour < endHour
    }

    /// 寝ていたか。時間帯の中で、動きが分かるときはほとんど止まっていたこと、分からないときは時間帯だけで決める。
    func isAsleep(from start: Date, to end: Date, motion: MotionLink) async -> Bool {
        guard enabled, inWindow(start) else { return false }
        guard let still = await motion.stillness(from: start, to: end) else { return true }
        return still >= 0.9
    }
}

/// 連絡先の名前。会話で「さいとうさん」「斉藤さん」と呼ばれた名前と読みが同じ人を連絡先から探し、
/// 連絡先の書き方（「齋藤」など）を聞き取りと誤変換直しのヒントにする。
/// 連絡先をまるごと外に送ることはしない。会話に出てきた名前と読みが合った人の名前だけを、ヒントとして使う。
@MainActor
@Observable
final class ContactsLink {
    var enabled = UserDefaults.standard.bool(forKey: "contactsOn") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "contactsOn")
            names = nil
        }
    }
    private(set) var authorized = ContactsLink.isAuthorized

    /// 読み込んだ名前の数（画面に出す）
    private(set) var count = 0

    struct Name: Sendable {
        /// 連絡先の書き方
        let written: String
        /// 読み（ローマ字。長音はそろえてある）
        let reading: String
    }

    @ObservationIgnored private var names: [Name]?
    @ObservationIgnored private var loadedAt = Date.distantPast

    nonisolated private static var isAuthorized: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized || status == .limited
    }

    func requestAccess() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        authorized = Self.isAuthorized
        if authorized { enabled = true }
    }

    /// 呼ばれ方の後ろに付く言葉
    nonisolated static let honorifics = ["さん", "くん", "君", "ちゃん", "さま", "様", "先生", "先輩", "氏", "部長", "課長", "社長"]

    /// 文の中で「〇〇さん」などと呼ばれた名前のうち、読みが連絡先の人の姓・名と同じものの、連絡先での書き方。
    func mentioned(in texts: [String]) async -> [String] {
        guard enabled, authorized else { return [] }
        let called = Set(texts.flatMap { Self.called(in: $0) }.map(Self.reading).filter { $0.count >= 2 })
        guard !called.isEmpty else { return [] }
        let names = await load()
        var result: [String] = []
        for name in names where called.contains(name.reading) && !result.contains(name.written) {
            result.append(name.written)
            if result.count >= 8 { break }
        }
        return result
    }

    /// 連絡先の姓・名・ニックネームと、その読み。6時間ごとに読み直す。
    private func load() async -> [Name] {
        if let names, loadedAt.timeIntervalSinceNow > -6 * 3600 { return names }
        let loaded = await Task.detached(priority: .utility) { () -> [Name] in
            let keys = [CNContactFamilyNameKey, CNContactGivenNameKey, CNContactPhoneticFamilyNameKey,
                        CNContactPhoneticGivenNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
            var result: [Name] = []
            var seen = Set<String>()
            func add(_ written: String, _ phonetic: String) {
                let written = written.trimmingCharacters(in: .whitespaces)
                guard !written.isEmpty, written.count <= 8 else { return }
                // ふりがなが無ければ、書き方から読みを推し量る
                let reading = ContactsLink.reading(phonetic.isEmpty ? written : phonetic)
                guard reading.count >= 2, seen.insert(written + "|" + reading).inserted else { return }
                result.append(Name(written: written, reading: reading))
            }
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: request) { contact, _ in
                add(contact.familyName, contact.phoneticFamilyName)
                add(contact.givenName, contact.phoneticGivenName)
                add(contact.nickname, "")
            }
            return result
        }.value
        names = loaded
        loadedAt = .now
        count = loaded.count
        return loaded
    }

    /// 文の中の「〇〇さん」などの〇〇（ひらがなも含む）
    nonisolated static func called(in text: String) -> [String] {
        let string = text as CFString
        guard let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: CFStringGetLength(string)),
                                                      kCFStringTokenizerUnitWord, Locale(identifier: "ja_JP") as CFLocale)
        else { return [] }
        var tokens: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            tokens.append((text as NSString).substring(with: NSRange(location: r.location, length: r.length)))
        }
        var names: [String] = []
        for (i, token) in tokens.enumerated() {
            for suffix in honorifics {
                var name: String?
                if token == suffix, i > 0 {
                    name = tokens[i - 1]
                } else if token.hasSuffix(suffix), token.count > suffix.count {
                    name = String(token.dropLast(suffix.count))
                }
                if let name, (1...8).contains(name.count), !names.contains(name),
                   name.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }) {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// 名前の読み（ローマ字）。「さとう」「サトウ」「佐藤」が同じになるよう、長音（ou・oo・uu）をそろえる。
    nonisolated static func reading(_ text: String) -> String {
        var r = TranscriptCheck.reading(text)
        for (long, short) in [("ou", "o"), ("oo", "o"), ("uu", "u")] {
            r = r.replacingOccurrences(of: long, with: short)
        }
        return r
    }
}

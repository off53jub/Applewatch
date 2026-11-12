import Foundation
import Observation
import UserNotifications

/// いいこと帳の足し（2026-11-12）。
/// ・本人の「違う」「当たり」「外れ」を端末に残して、違うものをすぐ隠し、家の PC（POST /good/feedback。features の "goodfb"）へ送る。
/// ・毎晩 21:30 に「今夜の3つ」を知らせる。
/// ・ウィジェットに今週のお礼・ほめ言葉の数を出す。
/// どれも記録にあったことの並べ替えだけで、励ましの言葉は作らない。

// MARK: - 「違う」「当たり」

@MainActor
@Observable
final class GoodFeedbackBook {
    /// 1件の答え。kind は "word"（お礼・ほめ言葉）か "laugh"（ウケたかも）、verdict は "wrong" か "right"
    struct Item: Codable, Equatable {
        var id: String
        var day: String
        var time: String
        var kind: String
        var verdict: String
    }

    static let shared = GoodFeedbackBook()
    /// 家の PC が受け取る数（これより古い答えから捨てる）
    nonisolated static let maxItems = 2000
    private static let sentKey = "goodFeedbackSentHash"

    private(set) var items: [Item] = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var uploading = false

    /// 読み込んでから使う（読む前に保存すると、前の答えを消してしまうため、init で必ず読む）
    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("good-feedback.json"),
         defaults: UserDefaults = .standard) {
        self.url = url
        self.defaults = defaults
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    /// 違うと答えた id の集まり
    var wrongIDs: Set<String> { Set(items.lazy.filter { $0.verdict == "wrong" }.map(\.id)) }

    func isWrong(_ id: String) -> Bool { verdict(id) == "wrong" }

    /// この id への答え（無ければ nil）
    func verdict(_ id: String) -> String? { items.last { $0.id == id }?.verdict }

    /// 答えを残す（同じものへの前の答えは置き換える）。pc を渡せば、すぐ家の PC にも送る
    func mark(day: String, time: String, kind: String, text: String, verdict: String, pc: HomePC?) {
        items = Self.adding(Item(id: Self.id(day: day, time: time, kind: kind, text: text), day: day, time: time,
                                 kind: kind, verdict: verdict), to: items)
        save()
        GoodNightly.rescheduleLast(hidden: wrongIDs)  // 違うと答えたものを、今夜の知らせからも外す
        if let pc { Task { await uploadToPC(pc) } }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(items) { try? data.write(to: url, options: .atomic) }
    }

    /// 家の PC へ、答えの全部を送る（変わったときだけ。「goodfb」を持つ PC だけ）
    func uploadToPC(_ pc: HomePC) async {
        guard !uploading, pc.features.contains("goodfb") else { return }
        let key = Self.contentKey(items)
        let sent = defaults.string(forKey: Self.sentKey)
        guard sent != key, !(items.isEmpty && sent == nil), let body = Self.body(items) else { return }
        uploading = true
        defer { uploading = false }
        if (try? await pc.postGoodFeedback(body)) != nil {
            defaults.set(key, forKey: Self.sentKey)
        }
    }

    // MARK: 純粋な部分（テストする）

    /// 答えの id。日・時刻・種類・言葉で決める（言葉は120字まで。家の PC は200字までを受け取る）
    nonisolated static func id(day: String, time: String, kind: String, text: String) -> String {
        "\(day)|\(time)|\(kind)|\(String(text.prefix(120)))"
    }

    /// 答えを足す。同じ id への前の答えは消し、多すぎれば古いものから捨てる
    nonisolated static func adding(_ item: Item, to old: [Item], max: Int = maxItems) -> [Item] {
        var result = old.filter { $0.id != item.id }
        result.append(item)
        if result.count > max { result.removeFirst(result.count - max) }
        return result
    }

    /// 家の PC に送る中身 {"items": [...]}
    nonisolated static func body(_ items: [Item]) -> Data? {
        let rows: [[String: String]] = items.map {
            ["id": $0.id, "day": $0.day, "time": $0.time, "kind": $0.kind, "verdict": $0.verdict]
        }
        return try? JSONSerialization.data(withJSONObject: ["items": rows], options: .sortedKeys)
    }

    /// 送ったあとに変わったかを見分ける印（件数と、中身の FNV-1a。プロセスが変わっても同じ値になる）
    nonisolated static func contentKey(_ items: [Item]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for item in items {
            for byte in "\(item.id)\t\(item.verdict)\n".utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
        }
        return "\(items.count)-\(String(hash, radix: 16))"
    }
}

// MARK: - 毎晩 21:30 の知らせ

enum GoodNightly {
    /// 設定の入れ物の名前（既定は入）
    static let enabledKey = "goodNightlyOn"
    static let noticeID = "good-tonight"
    static let hour = 21
    static let minute = 30

    /// 前に使った中身（答えを残したときに入れ直すため）
    @MainActor private static var last: GoodThings?

    static var isOn: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// 知らせを入れ直す。中身が更新されるたびに呼ぶ。今夜の3つが無い・設定が切れている・21:30 を過ぎたときは取り下げる
    @MainActor
    static func reschedule(_ data: GoodThings, hidden: Set<String>, now: Date = .now) {
        last = data
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [noticeID])
        guard isOn, isFresh(generatedAt: data.generated_at, now: now),
              let at = fireDate(now: now) else { return }
        let rows = lines(data.tonight, day: dayKey(now), hidden: hidden)
        guard !rows.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "今日のいいこと帳"
        content.body = rows.joined(separator: "\n")
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        center.add(UNNotificationRequest(identifier: noticeID, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    /// 前に使った中身で入れ直す（「違う」と答えたとき）
    @MainActor
    static func rescheduleLast(hidden: Set<String>) {
        if let last { reschedule(last, hidden: hidden) }
    }

    /// 今日の 21:30。もう過ぎていれば nil
    nonisolated static func fireDate(now: Date, calendar: Calendar = .current) -> Date? {
        guard let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now), at > now.addingTimeInterval(30) else { return nil }
        return at
    }

    /// 知らせの文の並び（多くて3つ。「違う」と答えたお礼・ほめ言葉は外す）。記録にあった言葉をそのまま並べる
    nonisolated static func lines(_ tonight: [GoodThings.Tonight]?, day: String, hidden: Set<String>) -> [String] {
        var result: [String] = []
        for item in tonight ?? [] {
            if item.kind == "お礼" || item.kind == "ほめ言葉" {
                guard !hidden.contains(GoodFeedbackBook.id(day: day, time: item.time, kind: "word", text: item.text)) else { continue }
                result.append("\(item.time) \(item.kind)「\(String(item.text.prefix(40)))」")
            } else {
                result.append("\(item.time) \(item.kind): \(String(item.text.prefix(40)))")
            }
            if result.count == 3 { break }
        }
        return result
    }

    /// 中身が今日のものか（母艦が作った日が今日でなければ、昨日の3つになってしまうので知らせない）
    nonisolated static func isFresh(generatedAt: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let generatedAt, generatedAt.count >= 10 else { return false }
        return String(generatedAt.prefix(10)) == dayKey(now, calendar: calendar)
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - ウィジェット

enum GoodWidgetCounts {
    /// 今週のお礼とほめ言葉の数。いちばん新しい週が今週でなければ（古い写しのとき）nil
    static func thisWeek(_ weeks: [GoodThings.Week]?, now: Date, calendar: Calendar = .current) -> (thanks: Int, praise: Int)? {
        guard let week = weeks?.first else { return nil }
        let parts = week.start.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = calendar.date(byAdding: .day, value: 7, to: start),
              start <= now, now < end else { return nil }
        return (week.thanks, week.praise)
    }
}

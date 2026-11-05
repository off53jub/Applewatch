import Foundation
import UserNotifications

/// この IPA の署名の期限（Sideloadly などで無料の Apple ID で入れた署名は7日）。
/// 期限を過ぎるとアプリが起動しなくなり、録音も文字起こしも止まる（記録は消えない）。
/// 期限の1日前と3時間前に知らせ、家の PC（`Watch-Freshness.ps1`）にも同期フォルダの
/// 「アプリの状態（端末）.json」で伝えて LINE でも知らせてもらう（2026-11-05）。
enum Provisioning {
    /// 署名の期限。TestFlight・App Store で入れたとき（embedded.mobileprovision が無い）は nil。
    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return expiry(in: data)
    }()

    /// mobileprovision（署名付きの plist）の中の ExpirationDate
    static func expiry(in data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            return nil
        }
        return dict["ExpirationDate"] as? Date
    }

    /// 期限まで、これより短ければ画面と自己点検で知らせる
    static let warnBefore: TimeInterval = 36 * 3600

    /// 期限が近い（または過ぎた）か
    static func isNear(now: Date = .now) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) < warnBefore
    }

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) H:mm"
        return f
    }()

    static func text(_ date: Date) -> String { format.string(from: date) }

    /// 「11/12(木) 10:00（あと6日）」の形。期限が分からなければ nil。
    static func expiryText(now: Date = .now) -> String? {
        guard let expiry else { return nil }
        return text(expiry) + "（" + remaining(expiry.timeIntervalSince(now)) + "）"
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "過ぎています" }
        let hours = Int(seconds / 3600)
        if hours >= 48 { return "あと\(hours / 24)日" }
        if hours >= 1 { return "あと\(hours)時間" }
        return "あと\(max(1, Int(seconds / 60)))分"
    }

    @MainActor private static var scheduled = false

    /// 期限の30日前・7日前・1日前・3時間前の知らせを iOS に頼む（起動ごとに1回。過ぎた時刻は頼まない）。
    /// 30日前と7日前は、1年の署名（有料の個人チーム）のため（2026-11-06）
    @MainActor static func scheduleRemindersOnce() async {
        guard !scheduled else { return }
        scheduled = true
        let center = UNUserNotificationCenter.current()
        let ids = ["signExpiry-30d", "signExpiry-7d", "signExpiry-24h", "signExpiry-3h"]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard let expiry else { return }
        for (id, hours) in zip(ids, [30 * 24.0, 7 * 24.0, 24.0, 3.0]) {
            let at = expiry.addingTimeInterval(-hours * 3600)
            guard at.timeIntervalSinceNow > 60 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "LifeLog の署名がもうすぐ切れます"
            content.body = "\(text(expiry)) に切れると、アプリが起動しなくなり録音が止まります。Sideloadly で入れ直してください（記録は消えません）。"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSinceNow, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}

/// 家の PC が読む、アプリの動き具合（会話の中身・人の名前は入れない）。
/// 同期フォルダの「アプリの状態（端末）.json」。名前に「-」を入れないので、端末どうしの同期では読まない。
struct AppStatus: Codable {
    let device: String
    /// iPhone / iPad
    let kind: String
    let written: Date
    let version: String
    /// 署名の期限（分からなければ nil）
    let signExpires: Date?
    let recording: Bool
    /// 文字起こし待ちの区切りの数
    let pending: Int
    /// 最後に処理した時刻
    let lastProcessed: Date?

    static func fileName(device: String) -> String { "アプリの状態（\(device)）.json" }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}

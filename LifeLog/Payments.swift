import Foundation
import UserNotifications

/// PayPay の明細（2026-11-08）。行ったお店の答え合わせと、立ち寄りの記録が無い日の「払ったお店」に使う。
///
/// - PayPay には個人向けに明細を取る口が無く、払うたびのメールも無い。なので、本人が PayPay のアプリから書き出した
///   明細（CSV）を、月に1回くらいここで読み込む。読み込むたびに、前の分と同じ支払い（取引番号）は重ねない。
/// - 残すのは「支払い」だけで、時刻・金額・払った先だけ。払った手段（カードの番号の下4桁など）は残さない。
/// - 中身は `payments.json` に端末ごとに持つ（同期はしない）。
struct Payment: Codable, Identifiable, Equatable {
    /// 取引番号（無ければ時刻と金額と払った先から作る）
    var id: String
    var time: Date
    /// 円
    var amount: Int
    /// 払った先（明細の「取引先」）
    var shop: String
}

enum PayPayCSV {
    /// 明細の CSV から「支払い」を取り出す。見出しの行で列を探すので、列の並びが変わっても読める。読めなければ nil
    static func parse(_ data: Data, timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo")!) -> [Payment]? {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows = rows(text)
        guard let header = rows.first else { return nil }
        func column(_ name: String) -> Int? { header.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name) } }
        guard let dateCol = column("取引日"), let outCol = column("出金金額"), let kindCol = column("取引内容"),
              let shopCol = column("取引先") else { return nil }
        let numberCol = column("取引番号")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        var result: [Payment] = []
        for row in rows.dropFirst() {
            guard row.count > max(dateCol, outCol, kindCol, shopCol) else { continue }
            guard row[kindCol].trimmingCharacters(in: .whitespaces) == "支払い" else { continue }
            guard let time = f.date(from: row[dateCol].trimmingCharacters(in: .whitespaces)) else { continue }
            let digits = row[outCol].filter(\.isNumber)
            guard let amount = Int(digits), amount > 0 else { continue }
            let shop = row[shopCol].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shop.isEmpty else { continue }
            var id = numberCol.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespaces) : nil } ?? ""
            if id.isEmpty || id == "-" { id = "\(Int(time.timeIntervalSince1970))-\(amount)-\(shop)" }
            result.append(Payment(id: id, time: time, amount: amount, shop: shop))
        }
        return result
    }

    /// CSV の行（"" で囲まれた中のカンマ・改行・"" を正しく扱う）
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text).makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\r\n", "\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

enum PaymentMatch {
    /// 着く少し前（レジの前に払うことがある）
    static let before: TimeInterval = 5 * 60
    /// 出たあとに支払いの時刻が付くことがある
    static let after: TimeInterval = 10 * 60
    /// 出た時刻が分からないときに見る長さ
    static let openSpan: TimeInterval = 3 * 3600

    /// その立ち寄りのあいだの支払い（いちばん時刻が近いもの）
    static func payment(for v: ShopVisit, in payments: [Payment]) -> Payment? {
        let start = v.arrival.addingTimeInterval(-before)
        let end = (v.departure ?? v.arrival.addingTimeInterval(openSpan)).addingTimeInterval(after)
        let middle = v.arrival.addingTimeInterval((v.departure ?? v.arrival).timeIntervalSince(v.arrival) / 2)
        return payments.filter { $0.time >= start && $0.time <= end }
            .min { abs($0.time.timeIntervalSince(middle)) < abs($1.time.timeIntervalSince(middle)) }
    }

    struct Score: Equatable {
        /// 推測と払った先が同じ
        var hit = 0
        /// 推測と払った先が違う
        var miss = 0
        /// 支払いがあったのに、推測できていなかった
        var none = 0
    }

    /// 推測（本人が決める前）と支払いの答え合わせ
    static func score(_ visits: [ShopVisit], payments: [Payment]) -> Score {
        var s = Score()
        for v in visits where v.state != .notShop {
            guard let paid = payment(for: v, in: payments) else { continue }
            guard let guessed = v.guess?.name else { s.none += 1; continue }
            if ShopGuess.sameShop(guessed, paid.shop) { s.hit += 1 } else { s.miss += 1 }
        }
        return s
    }

    /// 立ち寄りの記録と重ならない支払い（新しい順）
    static func unmatched(_ payments: [Payment], visits: [ShopVisit]) -> [Payment] {
        let used = Set(visits.compactMap { payment(for: $0, in: payments)?.id })
        return payments.filter { !used.contains($0.id) }.sorted { $0.time > $1.time }
    }
}

@MainActor
@Observable
final class PaymentBook {
    private(set) var payments: [Payment] = []
    /// 最後に読み込んだ時刻
    private(set) var importedAt: Date? = UserDefaults.standard.object(forKey: PaymentBook.importedKey) as? Date

    nonisolated private static let importedKey = "paymentsImportedAt"
    nonisolated static let reminderID = "payments-monthly"
    @ObservationIgnored private var loaded = false
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("payments.json")

    init() {
        load()
    }

    var latest: Date? { payments.map(\.time).max() }

    private func load() {
        defer { loaded = true }
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([Payment].self, from: data) {
            payments = saved
        } else {
            // 読めないファイルは上書きせず、脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("payments-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    private func save() {
        guard loaded, let data = try? JSONEncoder().encode(payments) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// 明細を読み込む。足した数を返す（読めなければ nil）
    func importCSV(_ data: Data, now: Date = .now) -> Int? {
        guard let parsed = PayPayCSV.parse(data) else { return nil }
        let added = Self.merged(payments, parsed)
        let count = added.count - payments.count
        payments = added
        save()
        importedAt = now
        UserDefaults.standard.set(now, forKey: Self.importedKey)
        Self.scheduleMonthlyReminder()
        return count
    }

    /// 前の分に、新しい支払いだけを足す（取引番号で見分ける。古い順）
    nonisolated static func merged(_ old: [Payment], _ new: [Payment]) -> [Payment] {
        var seen = Set(old.map(\.id))
        var result = old
        for p in new where !seen.contains(p.id) {
            seen.insert(p.id)
            result.append(p)
        }
        return result.sorted { $0.time < $1.time }
    }

    func removeAll() {
        payments = []
        save()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
    }

    /// 毎月1日の20時に「明細を読み込む日です」と知らせる（一度読み込んだあとから）
    nonisolated static func scheduleMonthlyReminder() {
        let content = UNMutableNotificationContent()
        content.title = "PayPay の明細を読み込む日です"
        content.body = "PayPay の取引履歴から先月の分を書き出して、LifeLog の「行ったお店」で読み込むと、お店の答え合わせができます。"
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(day: 1, hour: 20), repeats: true)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger))
    }
}

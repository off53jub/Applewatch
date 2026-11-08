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
    /// どこから来たか（2026-11-09）。nil＝PayPay の明細・"card-mail"＝カードの利用速報メール・"tap"＝ウォレットでかざした
    var source: String? = nil
    /// カードの名前（「PayPayカード ゴールド（Visa）」・ウォレットのカード名。番号は持たない。2026-11-09）
    var card: String? = nil
}

extension Payment {
    static let cardMail = "card-mail"
    static let tap = "tap"

    /// お店の名前として使えるか（空や「JCB国内加盟店」のような大まかな名前は使わない）
    var hasShop: Bool { !PaymentMerge.isGeneric(shop) }

    /// 見出しに添える出どころ
    var via: String {
        switch source {
        case nil: "PayPay"
        case .some(Payment.cardMail): "カード"
        default: "かざした"
        }
    }
}

/// PayPay の明細・カードの利用速報メール・ウォレットでかざした記録を1つに並べる（2026-11-09）
enum PaymentMerge {
    /// かざした記録と利用速報メールを同じ支払いとみなす時刻の差
    static let window: TimeInterval = 15 * 60
    /// PayPay の支払いにカードを使ったとき、PayPay の明細と利用速報メールを同じとみなす時刻の差
    static let payPayWindow: TimeInterval = 10 * 60

    private static func key(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.uppercased().filter { !$0.isWhitespace }
    }

    /// 空・「国内加盟店」のような、お店の名前にならないもの
    static func isGeneric(_ shop: String) -> Bool {
        let k = key(shop)
        return k.isEmpty || k.contains("加盟店") || k == "PAYPAY"
    }

    static func isPayPay(_ shop: String) -> Bool { key(shop).hasPrefix("PAYPAY") }

    /// 3つを1つに（古い順）。同じ支払いは1件にする:
    /// - 利用速報メールの払った先が「PayPay」で、同じ金額の PayPay の明細が近くにあれば、明細のほうを残す（PayPay にカードを使った分）
    /// - かざした記録は、近くの同じ金額の利用速報メールと1件にする（時刻はかざした方・名前は分かる方）
    static func combine(paypay: [Payment], mail: [Payment], taps: [Payment]) -> [Payment] {
        var mails = mail.filter { m in
            !(isPayPay(m.shop) && paypay.contains { $0.amount == m.amount && abs($0.time.timeIntervalSince(m.time)) <= payPayWindow })
        }
        var used = Set<Int>()
        var loose: [Payment] = []
        for t in taps.sorted(by: { $0.time < $1.time }) {
            let near = mails.indices.filter { i in
                !used.contains(i) && abs(mails[i].time.timeIntervalSince(t.time)) <= window
                    && (t.amount == 0 || t.amount == mails[i].amount)
            }
            guard let i = near.min(by: { abs(mails[$0].time.timeIntervalSince(t.time)) < abs(mails[$1].time.timeIntervalSince(t.time)) }) else {
                loose.append(t)
                continue
            }
            used.insert(i)
            mails[i].time = t.time
            if !mails[i].hasShop && t.hasShop { mails[i].shop = t.shop }
        }
        return (paypay + mails + loose).sorted { $0.time < $1.time }
    }
}

/// ウォレットでかざしたときの記録（2026-11-09）。ショートカットの「取引」オートメーションから「支払いを記録」で届く。
/// 足すだけのファイル（card-taps.jsonl）に1行ずつ書く。読み込む前に上書きすることが無い。
enum CardTap {
    static let url = URL.applicationSupportDirectory.appendingPathComponent("card-taps.jsonl")
    /// 足したあとに画面を読み直す（アプリが動いていれば）
    @MainActor static var added: (() -> Void)?

    /// 「¥1,234」「1,234円」「1234.00」などから円を取り出す（読めなければ 0）
    static func yen(_ text: String?) -> Int {
        guard let text else { return 0 }
        let t = text.precomposedStringWithCompatibilityMapping
        let whole = t.split(separator: ".", maxSplits: 1).first.map(String.init) ?? t
        return Int(String(whole.filter(\.isNumber).prefix(9))) ?? 0
    }

    static func make(shop: String?, amount: String?, card: String?, at time: Date) -> Payment {
        let shopText = String((shop ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let cardText = String((card ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return Payment(id: "tap-" + UUID().uuidString, time: time, amount: yen(amount), shop: shopText,
                       source: Payment.tap, card: cardText.isEmpty ? nil : cardText)
    }

    static func append(_ p: Payment) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(p)
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: url, options: .atomic)
        }
    }

    /// 読めない行は飛ばす
    static func read(_ data: Data) -> [Payment] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Payment.self, from: Data($0)) }
    }
}

/// 家の PC から届く、カードの利用速報メールの支払い（2026-11-09。GET /card）
enum CardMailExport {
    /// {"available": true, "items": [{"id","time","amount","shop","card"}]}。available でなければ nil
    static func parse(_ data: Data) -> [Payment]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["available"] as? Bool == true, let items = obj["items"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty, let timeText = item["time"] as? String,
                  let time = iso.date(from: timeText), let amount = item["amount"] as? Int, amount > 0 else { return nil }
            let shop = (item["shop"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let card = (item["card"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
            return Payment(id: "mail-" + id, time: time, amount: amount, shop: String(shop.prefix(100)),
                           source: Payment.cardMail, card: card)
        }
    }
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
        return payments.filter { $0.hasShop && $0.time >= start && $0.time <= end }
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
    /// カードの利用速報メールの支払い（家の PC から。端末に写しを置く。2026-11-09）
    private(set) var mail: [Payment] = []
    /// ウォレットでかざした記録（2026-11-09）
    private(set) var taps: [Payment] = []
    /// PayPay の明細・利用速報メール・かざした記録を1つにしたもの（同じ支払いは1件。答え合わせと見出しはこちらを使う）
    private(set) var all: [Payment] = []
    private(set) var mailFetchedAt: Date?
    private(set) var mailError: String?
    @ObservationIgnored private var mailLoaded = false
    @ObservationIgnored private var fetching = false
    private static let mailURL = URL.applicationSupportDirectory.appendingPathComponent("card-mail.json")
    private static let mailEvery: TimeInterval = 30 * 60

    init() {
        load()
        loadMail()
        reloadTaps()
    }

    /// かざした記録を読み直す（ショートカットから足されたあと・アプリを開いたとき）
    func reloadTaps() {
        taps = (try? Data(contentsOf: CardTap.url)).map(CardTap.read) ?? []
        rebuild()
    }

    private func rebuild() {
        all = PaymentMerge.combine(paypay: payments, mail: mail, taps: taps)
    }

    private func loadMail() {
        defer { mailLoaded = true }
        guard let data = try? Data(contentsOf: Self.mailURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        mail = (try? decoder.decode([Payment].self, from: data)) ?? []
    }

    /// 家の PC から、カードの利用速報メールの支払いを読み直す（30分に1回まで）
    func refreshMail(_ pc: HomePC, force: Bool = false) async {
        guard mailLoaded, !fetching, pc.features.contains("card") else { return }
        if !force, let mailFetchedAt, Date.now.timeIntervalSince(mailFetchedAt) < Self.mailEvery { return }
        fetching = true
        defer { fetching = false }
        do {
            let data = try await pc.cardMail()
            mailFetchedAt = .now
            guard let parsed = CardMailExport.parse(data) else {
                mailError = "カードの利用速報が、まだ家の PC に届いていません"
                return
            }
            mail = parsed.sorted { $0.time < $1.time }
            mailError = nil
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(mail) { try? data.write(to: Self.mailURL, options: .atomic) }
            rebuild()
        } catch {
            mailError = "家の PC から読めませんでした"
        }
    }

    var latest: Date? { payments.map(\.time).max() }

    private func load() {
        defer { loaded = true }
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([Payment].self, from: data) {
            payments = saved
            rebuild()
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
        rebuild()
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
        rebuild()
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

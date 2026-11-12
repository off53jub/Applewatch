import Foundation
import SwiftUI
import UserNotifications

/// クラウドに送ったものの一覧（2026-11-06）。Groq・OpenAI・Claude（家の PC 経由。2026-11-13）に送った音声（文字起こし）と文（言語モデル）を、
/// 時刻・送り先・何のためか・職場の会話か・大きさで残す（中身は残さない）。新しいファイル cloud-log.json（90日分）。
/// 毎月1日に、前の月の件数を知らせる（費用と上限の見張り）。
enum CloudLog {
    struct Entry: Codable, Identifiable {
        var id: Date { at }
        let at: Date
        /// 「Groq（文字起こし）」など
        let service: String
        /// 何のためか（区切りの名前・「言語モデル」など）
        let what: String
        /// 職場の会話か（分からなければ nil）
        let work: Bool?
        /// 送った大きさ（音声はバイト、文は文字数）
        let size: Int
    }

    private static let lock = NSLock()
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("cloud-log.json")
    private static let keep: TimeInterval = 90 * 24 * 3600

    static func load() -> [Entry] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }
    }

    /// 1件足す（どの糸からでも呼べる）
    static func add(service: String, what: String, work: Bool?, size: Int) {
        lock.withLock {
            var list: [Entry] = []
            if let data = try? Data(contentsOf: url) {
                // 読めないファイルは上書きせずに脇によける（読む前に保存しない）
                guard let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
                    let aside = url.deletingLastPathComponent().appendingPathComponent("cloud-log-unreadable.json")
                    try? FileManager.default.removeItem(at: aside)
                    try? FileManager.default.moveItem(at: url, to: aside)
                    return
                }
                list = decoded
            }
            let old = Date.now.addingTimeInterval(-keep)
            list.removeAll { $0.at < old }
            list.append(Entry(at: .now, service: service, what: what, work: work, size: size))
            try? JSONEncoder().encode(list).write(to: url, options: .atomic)
        }
    }

    /// 送り先ごとの件数（その月）
    static func counts(_ entries: [Entry], month: Date) -> [(service: String, count: Int, work: Int)] {
        let cal = Calendar.current
        let inMonth = entries.filter { cal.isDate($0.at, equalTo: month, toGranularity: .month) }
        let grouped = Dictionary(grouping: inMonth, by: \.service)
        return grouped.keys.sorted().map { key in
            let list = grouped[key] ?? []
            return (key, list.count, list.filter { $0.work == true }.count)
        }
    }

    /// OpenAI の文字起こしの費用の目安（米ドル）。送った音声の大きさから長さを推し量る（32kbps として 1分 0.006 ドル）
    static func openAICost(_ entries: [Entry]) -> Double {
        let bytes = entries.filter { $0.service.hasPrefix("OpenAI") }.reduce(0) { $0 + $1.size }
        let minutes = Double(bytes) * 8 / 32_000 / 60
        return minutes * 0.006
    }

    /// ドライブの量を「3.2GB / 15GB（21%）」の形に
    static func quotaText(_ quota: (used: Int64, limit: Int64?)) -> String {
        let gb = { (b: Int64) in String(format: "%.1fGB", Double(b) / 1_073_741_824) }
        guard let limit = quota.limit, limit > 0 else { return gb(quota.used) + " 使用" }
        return gb(quota.used) + " / " + gb(limit) + "（\(Int(Double(quota.used) / Double(limit) * 100))%）"
    }

    /// 毎月1日に、前の月の件数・費用の目安・ドライブの使っている量を知らせる（1回だけ）
    @MainActor
    static func notifyMonthlyIfDue(quota: () async -> (used: Int64, limit: Int64?)?) async {
        let cal = Calendar.current
        guard cal.component(.day, from: .now) == 1,
              let last = cal.date(byAdding: .month, value: -1, to: .now) else { return }
        let key = Self.monthKey(last)
        guard UserDefaults.standard.string(forKey: "cloudMonthly") != key else { return }
        UserDefaults.standard.set(key, forKey: "cloudMonthly")
        let entries = load().filter { cal.isDate($0.at, equalTo: last, toGranularity: .month) }
        let counts = counts(entries, month: last)
        var body = counts.isEmpty ? "クラウドには送っていません" : counts.map {
            "\($0.service) \($0.count) 件" + ($0.work > 0 ? "（うち職場 \($0.work)）" : "")
        }.joined(separator: "・")
        let cost = openAICost(entries)
        if cost > 0 { body += "。OpenAI の費用の目安 \(String(format: "%.2f", cost)) ドル" }
        if let quota = await quota() {
            body += "。ドライブ " + quotaText(quota)
            if let limit = quota.limit, limit > 0, Double(quota.used) / Double(limit) > 0.8 {
                body += "（8割を超えました。空けるか、容量を足してください）"
            }
        }
        body += "。Groq の無料枠の残りは Groq の画面で確かめてください。"
        let content = UNMutableNotificationContent()
        content.title = "先月クラウドに送ったもの"
        content.body = body
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cloud-monthly", content: content, trigger: nil))
    }

    static func monthKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }
}

/// クラウドに送ったものの一覧の画面
struct CloudLogView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var entries: [CloudLog.Entry] = []
    @State private var monthOffset = 0
    @State private var quota: String?

    var body: some View {
        let month = Calendar.current.date(byAdding: .month, value: -monthOffset, to: .now) ?? .now
        let inMonth = entries.filter { Calendar.current.isDate($0.at, equalTo: month, toGranularity: .month) }
            .sorted { $0.at > $1.at }
        List {
            Section {
                Picker("月", selection: $monthOffset) {
                    Text("今月").tag(0)
                    Text("先月").tag(1)
                    Text("先々月").tag(2)
                }
                .pickerStyle(.segmented)
                ForEach(CloudLog.counts(entries, month: month), id: \.service) { row in
                    LabeledContent(row.service, value: "\(row.count) 件" + (row.work > 0 ? "（職場 \(row.work)）" : ""))
                }
                let cost = CloudLog.openAICost(inMonth)
                if cost > 0 { LabeledContent("OpenAI の費用の目安", value: String(format: "%.2f ドル", cost)) }
                if let quota { LabeledContent("ドライブの使っている量", value: quota) }
            } footer: {
                Text("送った時刻・送り先・何のためかだけを残します（中身は残しません。90日分）。「Claude（家の PC 経由）」は、家の PC を通して Claude に頼んだものです（鍵は PC の中だけ）。「職場の会話も Claude で」がオン（初め）のあいだは、職場の会話も Claude に送ります。職場の会話を外に送らないようにするには、その設定をオフにして、「言語モデル」の設定で「職場の会話は端末内で」を選んでください。")
            }
            Section("送ったもの") {
                if inMonth.isEmpty { Text("ありません").foregroundStyle(.secondary) }
                ForEach(inMonth.prefix(200)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.at.formatted(date: .abbreviated, time: .shortened))　\(entry.service)")
                        Text(entry.what + (entry.work == true ? "・職場" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("クラウドに送ったもの")
        .onAppear { entries = CloudLog.load() }
        .task {
            if let q = await pipeline.driveQuota() { quota = CloudLog.quotaText(q) }
        }
    }
}

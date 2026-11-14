import SwiftUI

/// 「記録」→「お金」（2026-11-12）。前は「人と場所」→「行ったお店」のいちばん下にあった支払いを、ここにまとめた。
/// 今月の合計・日ごとの支払い・明細の読み込み。残すのは時刻・金額・払った先・カードの名前だけ（PaymentBook と同じ）。
struct MoneyView: View {
    @Environment(Pipeline.self) private var pipeline

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）"
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    /// 日ごとに出すのは、この日数まで（それより前は月の合計だけ）
    static let shownDays = 14

    var body: some View {
        let all: [Payment] = pipeline.payments.all
        let calendar = Calendar.current
        let monthStart: Date = calendar.dateInterval(of: .month, for: .now)?.start ?? calendar.startOfDay(for: .now)
        let month: [Payment] = all.filter { $0.time >= monthStart }
        let total: Int = month.reduce(0) { $0 + max(0, $1.amount) }
        let since: Date = calendar.date(byAdding: .day, value: -Self.shownDays, to: calendar.startOfDay(for: .now)) ?? .distantPast
        let groups: [Date: [Payment]] = Dictionary(grouping: all.filter { $0.time >= since }) { calendar.startOfDay(for: $0.time) }
        let days: [Date] = groups.keys.sorted(by: >)
        List {
            Section {
                LabeledContent("今月", value: "\(total.formatted())円・\(month.count) 件")
            } footer: {
                Text("PayPay の明細・カードの利用速報・ウォレットでかざした記録を合わせた数です（同じ支払いは1件）。")
            }
            if all.isEmpty {
                Section {
                    Text("まだ支払いの記録がありません。下の「PayPay の明細」から読み込むか、カードの利用速報・ウォレットの記録をつなぐと、ここに日ごとに並びます。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(days, id: \.self) { day in
                Section(Self.dayFormatter.string(from: day)) {
                    ForEach((groups[day] ?? []).sorted { $0.time > $1.time }) { p in
                        row(p)
                    }
                }
            }
            // PayPay の取引履歴のスクショから（2026-11-14。強化案 28。OneTimelineViews.swift）
            PayPayShotSection()
            PaymentSection()
        }
        .navigationTitle("お金")
        .countsOpen("money")
    }

    private func row(_ p: Payment) -> some View {
        HStack {
            Text(Self.clock.string(from: p.time)).font(.caption).foregroundStyle(.secondary)
            if p.hasShop {
                Text(p.shop)
            } else if let guess = PaymentMatch.placeGuessLabel(for: p, visits: pipeline.shopVisits.visits) {
                // 店名の無いかざした記録には、そのころいた場所からの推測を添える（表示だけ）
                Text(guess).foregroundStyle(.secondary)
            } else {
                Text("（店名なし）")
            }
            Text(p.via).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(p.amount > 0 ? "\(p.amount.formatted())円" : "").font(.callout.monospacedDigit())
        }
    }
}

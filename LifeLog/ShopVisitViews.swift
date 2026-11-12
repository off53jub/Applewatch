import CoreLocation
import SwiftUI
import UIKit

/// 行ったお店（2026-11-08）。立ち寄りを日ごとに出し、推測（たぶん）を本人が決める。下に設定。「記録」→「場所」から開く。
struct ShopVisitsView: View {
    @Environment(Pipeline.self) private var pipeline

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）"
        return f
    }()

    var body: some View {
        let book = pipeline.shopVisits
        let days = Self.days(book.visits)
        List {
            if book.isOn && pipeline.places.authorization != .authorizedAlways {
                Section {
                    Text("お店に寄ったことを知るには、設定アプリ →「LifeLog」→「位置情報」を「常に」にしてください。「正確な位置情報」もオンにすると、当たりやすくなります。")
                    Button("設定を開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            if days.isEmpty {
                Section {
                    Text(book.isOn ? "まだありません。お店に3分以上いて出ると、ここに出ます。" : "下のスイッチをオンにすると、寄ったお店をここに出します。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(days) { group in
                Section(Self.dayFormatter.string(from: group.day)) {
                    ForEach(group.visits) { visit in
                        NavigationLink {
                            ShopVisitDetailView(visitID: visit.id)
                        } label: {
                            ShopVisitRow(visit: visit, paid: book.paid(visit))
                        }
                    }
                }
            }
            // 支払い（PayPay の明細・カード・ウォレット）は「記録」→「お金」に移した（2026-11-12。MoneyViews.swift）
            ShopVisitSettings()
        }
        .navigationTitle("行ったお店")
        .countsOpen("shopVisits")
        .onAppear { book.refreshCounts() }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let visits: [ShopVisit]
        var id: Date { day }
    }

    /// 日ごと（新しい日から。日の中も新しい順）
    private static func days(_ visits: [ShopVisit]) -> [DayGroup] {
        let calendar = Calendar.current
        let groups: [Date: [ShopVisit]] = Dictionary(grouping: visits) { calendar.startOfDay(for: $0.arrival) }
        let keys: [Date] = groups.keys.sorted(by: >)
        return keys.map { key in
            let list: [ShopVisit] = (groups[key] ?? []).sorted { $0.arrival > $1.arrival }
            return DayGroup(day: key, visits: list)
        }
    }
}

private enum ShopTime {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    static func range(_ v: ShopVisit) -> String {
        let start = clock.string(from: v.arrival)
        guard let end = v.departure else { return start + "〜（いる途中）" }
        return start + "〜" + clock.string(from: end)
    }
}

private struct ShopVisitRow: View {
    let visit: ShopVisit
    var paid: Payment? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ShopTime.range(visit)).font(.caption).foregroundStyle(.secondary)
            switch visit.state {
            case .confirmed:
                Text(visit.confirmedName ?? "")
            case .notShop:
                Text("お店ではない").foregroundStyle(.secondary)
            case .guessed:
                HStack(spacing: 6) {
                    Text("たぶん")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                    Text(visit.guess?.name ?? "（名前は消えました）")
                }
                let others = visit.candidates.filter { $0.id != visit.guessID }.compactMap(\.name).prefix(2)
                if !others.isEmpty {
                    Text("ほかに: " + others.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                }
            case .waiting:
                Text(visit.departure == nil ? "いる途中" : "まだ調べていません").foregroundStyle(.secondary)
            }
            if let paid {
                Text("PayPay: \(paid.shop)　\(paid.amount.formatted())円").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 1回の立ち寄り。合っている・ほかの候補・名前を入れる・お店ではない
private struct ShopVisitDetailView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let visitID: String
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        let book = pipeline.shopVisits
        if let visit = book.visits.first(where: { $0.id == visitID }) {
            List {
                Section {
                    LabeledContent("時間", value: ShopTime.range(visit))
                    LabeledContent("いまの答え", value: answer(visit))
                    if visit.skippedAudio == true {
                        Text("仕事の時間（または職場）なので、会話は読んでいません。").font(.caption).foregroundStyle(.secondary)
                    } else if let n = visit.linesRead, n > 0 {
                        Text("この時間の会話 \(n) 行も手がかりにしました（iPhone の中だけで読みました）。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if visit.state == .guessed, visit.guess?.name != nil {
                    Section {
                        Button("合っている") { book.confirm(visitID) }
                    }
                }
                if let paid = book.paid(visit), visit.state != .confirmed || visit.confirmedName != paid.shop {
                    Section {
                        Button("「\(paid.shop)」にする") { book.setName(visitID, paid.shop) }
                    } header: {
                        Text("PayPay の支払い")
                    } footer: {
                        Text("\(ShopTime.clock.string(from: paid.time)) に \(paid.amount.formatted())円。読み込んだ明細の中で、この立ち寄りの時間にあった支払いです。")
                    }
                }
                let named = visit.candidates.filter { $0.name != nil }
                if !named.isEmpty {
                    Section {
                        ForEach(named) { c in
                            Button {
                                book.choose(visitID, candidate: c.id)
                            } label: {
                                CandidateRow(candidate: c, chosen: visit.state == .confirmed && visit.confirmedID == c.id,
                                             best: visit.state == .guessed && visit.guessID == c.id)
                            }
                            .tint(.primary)
                        }
                    } header: {
                        Text("候補（押すとそのお店にします）")
                    } footer: {
                        Text("点数は、近さと、その時間の会話に出た名前や言葉（「ご注文」「レシート」など）から付けています。")
                    }
                }
                Section {
                    Button("名前を入れる") {
                        typed = visit.confirmedName ?? ""
                        typing = true
                    }
                    Button("お店ではない") { book.markNotShop(visitID) }
                    if visit.state == .confirmed || visit.state == .notShop {
                        Button("決めたのを取り消す") { book.undo(visitID) }
                    }
                    Button("この立ち寄りを消す", role: .destructive) {
                        book.remove(visitID)
                        dismiss()
                    }
                }
            }
            .navigationTitle("立ち寄り")
            .alert("お店の名前", isPresented: $typing) {
                TextField("お店の名前", text: $typed)
                Button("決める") { book.setName(visitID, typed) }
                Button("キャンセル", role: .cancel) {}
            }
        } else {
            Text("この立ち寄りはありません").foregroundStyle(.secondary)
        }
    }

    private func answer(_ v: ShopVisit) -> String {
        switch v.state {
        case .confirmed: return v.confirmedName ?? ""
        case .notShop: return "お店ではない"
        case .guessed: return v.guess?.name.map { "たぶん " + $0 } ?? "分かりません"
        case .waiting: return "まだ分かりません"
        }
    }
}

private struct CandidateRow: View {
    let candidate: ShopCandidate
    let chosen: Bool
    let best: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name ?? "")
                let source = candidate.source == .google ? "Google" : (candidate.source == .apple ? "Apple の地図" : "前に決めた")
                let detail = "\(candidate.kind.label)・\(Int(candidate.distance.rounded())) m・\(source)"
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let clues = candidate.clues, !clues.isEmpty {
                    Text(clues.joined(separator: "・")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if chosen {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            } else if best {
                Text("たぶん").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// 設定（オン・オフ、Google のキー、回数の上限）
private struct ShopVisitSettings: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var keyText = ""

    var body: some View {
        let book = pipeline.shopVisits
        Section {
            Toggle("行ったお店を推測する", isOn: Binding(get: { book.isOn }, set: { book.isOn = $0 }))
        } header: {
            Text("設定")
        } footer: {
            Text("iPhone が「しばらくここにいた」と知らせてくる所（3分以上。自宅・会社など登録した場所は除く）で、近くのお店と、その時間の会話から、どのお店にいたかを推測します。位置情報を「常に」にする必要があり、電池を少し多く使います。\n\n近くのお店を調べるため、立ち寄った位置を Apple に送ります。下に Google のキーを入れたときだけ、Apple の答えがはっきりしないときに Google にも位置を送ります。会話は iPhone の中だけで読み、どこにも送りません。仕事の時間・職場の会話は読みません。")
        }
        Section {
            if book.hasGoogleKey {
                LabeledContent("Google のキー", value: "入れてあります")
                Button("キーを消す", role: .destructive) { book.saveGoogleKey("") }
            } else {
                SecureField("Google Places API のキー", text: $keyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("キーを保存") {
                    book.saveGoogleKey(keyText)
                    keyText = ""
                }
                .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Stepper("1日 \(book.dayCap) 回まで", value: Binding(get: { book.dayCap }, set: { book.dayCap = $0 }),
                    in: 0...200, step: 5)
            Stepper("1か月 \(book.monthCap) 回まで", value: Binding(get: { book.monthCap }, set: { book.monthCap = $0 }),
                    in: 0...3000, step: 50)
            LabeledContent("今日 Google に聞いた回数", value: "\(book.googleCalls.day) 回")
            LabeledContent("今月 Google に聞いた回数", value: "\(book.googleCalls.month) 回")
        } header: {
            Text("Google（なくてもよい）")
        } footer: {
            Text("キーはこの iPhone のキーチェーンにだけ置きます。Google は毎月の無料の分を超えると料金がかかるので、回数に上限を付けています。上限に達したら Google には聞かず、Apple の答えだけで推測します。Google の候補の名前と位置は30日で消します（決めたお店の名前は残ります）。")
        }
    }
}

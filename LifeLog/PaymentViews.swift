import SwiftUI
import UniformTypeIdentifiers

/// 「記録」→「お金」の中の PayPay の明細（2026-11-08。2026-11-12 までは「行ったお店」の中）。読み込み・答え合わせ・立ち寄りの無い支払い
struct PaymentSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var picking = false
    @State private var message = ""
    @State private var confirmRemove = false

    var body: some View {
        let book = pipeline.payments
        let score = PaymentMatch.score(pipeline.shopVisits.visits, payments: book.all)
        Section {
            Button("明細（CSV）を読み込む") { picking = true }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if !book.payments.isEmpty {
                LabeledContent("読み込んだ支払い", value: "\(book.payments.count) 件")
                if let latest = book.latest {
                    LabeledContent("いちばん新しい支払い", value: latest.formatted(date: .abbreviated, time: .omitted))
                }
                Button("読み込んだ明細を消す", role: .destructive) { confirmRemove = true }
            }
        } header: {
            Text("PayPay の明細")
        } footer: {
            Text("PayPay には、払うたびに自動で知らせを受け取る口がありません。月に1回くらい、PayPay のアプリの取引履歴から明細（CSV）を書き出して、ここで読み込んでください（毎月1日に知らせます）。同じ支払いは重ねません。")
        }
        Section {
            LabeledContent("カードの利用速報", value: "\(book.mail.count) 件")
            if let error = book.mailError { Text(error).font(.footnote).foregroundStyle(.secondary) }
            LabeledContent("ウォレットでかざした記録", value: "\(book.taps.count) 件")
            if score.hit + score.miss + score.none > 0 {
                LabeledContent("推測の答え合わせ", value: "当たり \(score.hit)・外れ \(score.miss)・推測なし \(score.none)")
            }
            if !book.all.isEmpty {
                NavigationLink("払ったお店（立ち寄りの記録が無い分）") { UnmatchedPaymentsView() }
            }
        } header: {
            Text("カードとウォレット")
        } footer: {
            Text("カードの利用速報: PayPay カードの利用速報メールを、Google の中の小さな仕組み（Apps Script）が読み、家の PC を通ってここに届きます（30分ごと）。\n\nウォレットでかざした記録: ショートカットの「オートメーション」→「取引」でカードを選び、動作に LifeLog の「支払いを記録」を入れて、店・金額・カードに「ショートカットの入力」の「販売者」「金額」「カードまたはパス」を入れてください。「すぐに実行」にすると、かざすたびに残ります。\n\n同じ支払いは1件にまとめます。立ち寄りの時間にあった支払いの払った先を、そのお店の名前として見出しに使い、推測が当たっていたかを数えます。残すのは時刻・金額・払った先・カードの名前だけで（番号は残しません）、この iPhone の中だけに置きます。")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
            message = Self.read(result, into: book)
        }
        .confirmationDialog("読み込んだ明細を消しますか？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("消す", role: .destructive) { book.removeAll() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この iPhone の中の支払いの記録が消えます。立ち寄りと、決めたお店の名前は消えません。")
        }
    }

    private static func read(_ result: Result<URL, Error>, into book: PaymentBook) -> String {
        guard case .success(let url) = result else { return "ファイルを開けませんでした。" }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return "ファイルを読めませんでした。" }
        guard let added = book.importCSV(data) else {
            return "PayPay の明細の形ではありませんでした（「取引日」「出金金額」「取引内容」「取引先」の列が要ります）。"
        }
        return added > 0 ? "支払いを \(added) 件足しました。" : "新しい支払いはありませんでした（もう読み込んだ分です）。"
    }
}

/// 立ち寄りの記録と重ならない支払い（日ごと）。立ち寄りを記録する前の日や、ネットの支払いも入る
struct UnmatchedPaymentsView: View {
    @Environment(Pipeline.self) private var pipeline

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日（E）"
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    var body: some View {
        let list = PaymentMatch.unmatched(pipeline.payments.all, visits: pipeline.shopVisits.visits)
        let calendar = Calendar.current
        let groups = Dictionary(grouping: list) { calendar.startOfDay(for: $0.time) }
        let days = groups.keys.sorted(by: >)
        List {
            if list.isEmpty {
                Text("ありません。").foregroundStyle(.secondary)
            }
            ForEach(days, id: \.self) { day in
                Section(Self.dayFormatter.string(from: day)) {
                    ForEach(groups[day] ?? []) { p in
                        HStack {
                            Text(Self.clock.string(from: p.time)).font(.caption).foregroundStyle(.secondary)
                            if p.hasShop {
                                Text(p.shop)
                            } else if let guess = PaymentMatch.placeGuessLabel(for: p, visits: pipeline.shopVisits.visits) {
                                // 店名の無いかざした記録に、そのころいた場所からの推測を添える（表示だけ。記録には書かない。2026-11-12）
                                Text(guess).foregroundStyle(.secondary)
                            } else {
                                Text("（店名なし）")
                            }
                            Text(p.via).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(p.amount > 0 ? "\(p.amount.formatted())円" : "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("払ったお店")
        .countsOpen("unmatchedPayments")
    }
}

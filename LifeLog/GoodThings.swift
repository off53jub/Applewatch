import Foundation
import Observation
import SwiftUI

/// いいこと帳（2026-11-12）。記録に本当にあったお礼・ほめ言葉・済ませた頼まれごと・ウケたかもの場面を並べる。
/// 作るのは母艦（D:\Lifelog の scripts/Build-GoodThings.py。家の PC の記録を読む）。家の PC が GET /good で渡す。
/// アプリは読んで見せるだけ。励ましの言葉は作らない（言語モデルも使わない）。端末に写しを置き、PC につながらないときも見せる。
struct GoodThings: Codable, Equatable {
    struct Week: Codable, Equatable {
        var start: String
        var thanks: Int
        var praise: Int
        /// 笑いの音の印が1日も無い週は nil（11/2 より前）
        var laughs: Int?
        var done: Int
        var own: Int
    }
    struct Word: Codable, Equatable, Hashable {
        var time: String
        var kind: String
        var who: String
        var text: String
        var place: String
    }
    struct Done: Codable, Equatable, Hashable {
        var time: String
        var what: String
    }
    struct Day: Codable, Equatable, Identifiable {
        var day: String
        var words: [Word]
        var done: [Done]
        var laughs: [String]
        var id: String { day }
    }
    var available: Bool
    var generated_at: String? = nil
    var weeks: [Week]? = nil
    var days: [Day]? = nil
    var reason: String? = nil
}

@MainActor
@Observable
final class GoodBook {
    private(set) var data: GoodThings?
    private(set) var fetchedAt: Date?
    private(set) var error: String?
    @ObservationIgnored private var fetching = false
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("good-things.json")
    private static let every: TimeInterval = 30 * 60

    init() {
        if let saved = try? Data(contentsOf: Self.url) { data = try? JSONDecoder().decode(GoodThings.self, from: saved) }
    }

    var thisWeek: GoodThings.Week? { data?.weeks?.first }

    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.features.contains("good") else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return }
        fetching = true
        defer { fetching = false }
        do {
            let body = try await pc.goodThings()
            fetchedAt = .now
            let got = try JSONDecoder().decode(GoodThings.self, from: body)
            guard got.available else {
                error = got.reason ?? "家の PC にいいこと帳がまだありません"
                return
            }
            data = got
            error = nil
            try? body.write(to: Self.url, options: .atomic)
        } catch {
            self.error = "家の PC から読めませんでした"
        }
    }
}

struct GoodThingsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = pipeline.good
        List {
            if let weeks = book.data?.weeks, !weeks.isEmpty {
                Section {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.weekTitle(week.start, current: index == 0)).font(.subheadline.bold())
                            Text(Self.weekLine(week)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("週ごと")
                } footer: {
                    Text("比べる相手は、前の週の自分です。家の PC に記録が届いた日だけを数えます。")
                }
            }
            ForEach(book.data?.days ?? []) { day in
                Section(Self.dayTitle(day.day)) {
                    ForEach(day.words, id: \.self) { word in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(word.time)  \(word.kind) — \(word.who)\(word.place.isEmpty ? "" : "・\(word.place)")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("「\(word.text)」")
                        }
                    }
                    ForEach(day.done, id: \.self) { done in
                        Label("\(done.time)  \(done.what)", systemImage: "checkmark.circle")
                    }
                    if !day.laughs.isEmpty {
                        Label("ウケたかも（仮）\(day.laughs.count) 場面: \(day.laughs.prefix(12).joined(separator: "・"))",
                              systemImage: "face.smiling")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if let error = book.error { Text(error).foregroundStyle(.secondary) }
                if book.data == nil && book.error == nil { Text("まだ読み込んでいません") }
            } footer: {
                Text("記録に本当にあったことだけを並べています。お礼・ほめ言葉は、自分が話した直後に相手の行に出た言葉です。話し手の名前は声からの自動の聞き分けなので、違うことがあります。「ウケたかも」は、自分が話した直後に笑いの音が聞こえたところで、誰の笑いかは分かりません（仮）。")
            }
        }
        .navigationTitle("いいこと帳")
        .refreshable { await book.refresh(pipeline.homePC, force: true) }
        .task { await book.refresh(pipeline.homePC) }
    }

    static func weekLine(_ w: GoodThings.Week) -> String {
        var parts = ["お礼 \(w.thanks)", "ほめ言葉 \(w.praise)"]
        if let laughs = w.laughs { parts.append("ウケたかも \(laughs)") }
        parts += ["済ませた \(w.done)", "自分の発言 \(w.own) 行"]
        return parts.joined(separator: "・")
    }

    static func weekTitle(_ start: String, current: Bool) -> String {
        let parts = start.split(separator: "-")
        let text = parts.count == 3 ? "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)〜" : start
        return current ? text + "（今週）" : text
    }

    static func dayTitle(_ day: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) else { return day }
        f.dateFormat = "M/d（E）"
        return f.string(from: date)
    }
}

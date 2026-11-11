import Foundation
import Observation
import SwiftUI

/// いいこと帳（2026-11-12）。記録に本当にあったお礼・ほめ言葉・済ませた頼まれごと・ウケたかもの場面を並べる。
/// 作るのは母艦（D:\Lifelog の scripts/Build-GoodThings.py。家の PC の記録を読む）。家の PC が GET /good で渡す。
/// アプリは読んで見せるだけ。励ましの言葉は作らない（言語モデルも使わない）。端末に写しを置き、PC につながらないときも見せる。
/// 先月との比べ・初めて・頼られた・今夜の3つ・「違う」「当たり」・21:30 の知らせ・ウィジェットは GoodMore.swift（2026-11-12）。
struct GoodThings: Codable, Equatable {
    struct Week: Codable, Equatable {
        var start: String
        var thanks: Int
        var praise: Int
        /// 笑いの音の印が1日も無い週は nil（11/2 より前）
        var laughs: Int?
        var done: Int
        var own: Int
        /// 頼られた回数（母艦が数えていなければ nil。2026-11-12）
        var consulted: Int? = nil
    }
    /// 今月と先月の数（数えていないものは nil。2026-11-12）
    struct Month: Codable, Equatable {
        struct Counts: Codable, Equatable {
            var thanks: Int? = nil
            var praise: Int? = nil
            var done: Int? = nil
            var consulted: Int? = nil
            var own: Int? = nil
        }
        var this: Counts? = nil
        var last: Counts? = nil
    }
    /// 初めて話した人・初めての場所（2026-11-12）
    struct First: Codable, Equatable, Hashable {
        var day: String
        var kind: String
        var text: String
    }
    /// 今夜の3つ（21:30 の知らせに使う。2026-11-12）
    struct Tonight: Codable, Equatable, Hashable {
        var kind: String
        var text: String
        var time: String
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
        /// 本人が笑いだと確かめた時刻（2026-11-12）
        var laughs_ok: [String]? = nil
        var id: String { day }
    }
    var available: Bool
    var generated_at: String? = nil
    var weeks: [Week]? = nil
    var days: [Day]? = nil
    var month: Month? = nil
    var firsts: [First]? = nil
    var tonight: [Tonight]? = nil
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
        await GoodFeedbackBook.shared.uploadToPC(pc)  // 「違う」「当たり」を母艦へ（変わったときだけ。GoodMore.swift）
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
            GoodNightly.reschedule(got, hidden: GoodFeedbackBook.shared.wrongIDs)  // 21:30 の知らせを入れ直す
        } catch {
            self.error = "家の PC から読めませんでした"
        }
    }
}

struct GoodThingsView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(GoodNightly.enabledKey) private var nightlyOn = true

    var body: some View {
        let book = pipeline.good
        let feedback = GoodFeedbackBook.shared
        List {
            Section {
                Toggle("毎晩 21:30 に、今夜の3つを知らせる", isOn: $nightlyOn)
                    .onChange(of: nightlyOn) { _, _ in
                        if let data = book.data { GoodNightly.reschedule(data, hidden: feedback.wrongIDs) }
                    }
            } footer: {
                Text("その日にあったお礼・ほめ言葉・済ませたこと・頼られたことのうち、多くて3つを並べます。何も無い日は知らせません。")
            }
            if let compare = Self.monthLines(book.data?.month), !compare.isEmpty {
                Section {
                    ForEach(compare, id: \.self) { Text($0).font(.subheadline) }
                } header: {
                    Text("先月との比べ")
                } footer: {
                    Text("今月と先月の数を並べただけです。")
                }
            }
            if let firsts = book.data?.firsts, !firsts.isEmpty {
                Section("初めて") {
                    ForEach(firsts, id: \.self) { first in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.dayTitle(first.day))  \(first.kind)").font(.caption).foregroundStyle(.secondary)
                            Text(first.text)
                        }
                    }
                }
            }
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
                    ForEach(day.words.filter { !feedback.isWrong(GoodFeedbackBook.id(day: day.day, time: $0.time, kind: "word", text: $0.text)) },
                            id: \.self) { word in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(word.time)  \(word.kind) — \(word.who)\(word.place.isEmpty ? "" : "・\(word.place)")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("「\(word.text)」")
                        }
                        // 違うときは左へなぞるか長押しで「違う」。押すとすぐ見えなくなる
                        .swipeActions(edge: .trailing) {
                            Button("違う", role: .destructive) {
                                feedback.mark(day: day.day, time: word.time, kind: "word", text: word.text,
                                              verdict: "wrong", pc: pipeline.homePC)
                            }
                        }
                        .contextMenu {
                            Button("違う", systemImage: "xmark.circle") {
                                feedback.mark(day: day.day, time: word.time, kind: "word", text: word.text,
                                              verdict: "wrong", pc: pipeline.homePC)
                            }
                        }
                    }
                    ForEach(day.done, id: \.self) { done in
                        Label("\(done.time)  \(done.what)", systemImage: "checkmark.circle")
                    }
                    let laughs = day.laughs.filter { !feedback.isWrong(GoodFeedbackBook.id(day: day.day, time: $0, kind: "laugh", text: "")) }
                    if !laughs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("ウケたかも（仮）\(laughs.count) 場面。時刻を押すと、当たりか外れかを残せます", systemImage: "face.smiling")
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(laughs.prefix(12), id: \.self) { time in
                                    laughMenu(day: day, time: time, feedback: feedback)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                if let error = book.error { Text(error).foregroundStyle(.secondary) }
                if book.data == nil && book.error == nil { Text("まだ読み込んでいません") }
            } footer: {
                Text("記録に本当にあったことだけを並べています。お礼・ほめ言葉は、自分が話した直後に相手の行に出た言葉です。話し手の名前は声からの自動の聞き分けなので、違うことがあります。違うものは「違う」で消せます。「ウケたかも」は、自分が話した直後に笑いの音が聞こえたところで、誰の笑いかは分かりません（仮）。")
            }
        }
        .navigationTitle("いいこと帳")
        .refreshable { await book.refresh(pipeline.homePC, force: true) }
        .task {
            await book.refresh(pipeline.homePC)
            pipeline.updateWidgets()  // ウィジェットの今週の数（GoodMore.swift）
        }
    }

    /// ウケたかもの1場面の時刻。押すと「当たり」「外れ」を選べる
    private func laughMenu(day: GoodThings.Day, time: String, feedback: GoodFeedbackBook) -> some View {
        let confirmed = (day.laughs_ok ?? []).contains(time)
        let verdict = feedback.verdict(GoodFeedbackBook.id(day: day.day, time: time, kind: "laugh", text: ""))
        return Menu {
            Button("当たり", systemImage: "checkmark.circle") {
                feedback.mark(day: day.day, time: time, kind: "laugh", text: "", verdict: "right", pc: pipeline.homePC)
            }
            Button("外れ", systemImage: "xmark.circle") {
                feedback.mark(day: day.day, time: time, kind: "laugh", text: "", verdict: "wrong", pc: pipeline.homePC)
            }
        } label: {
            Text(time + (verdict == "right" || confirmed ? " 当たり" : ""))
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: Capsule())
        }
    }

    static func weekLine(_ w: GoodThings.Week) -> String {
        var parts = ["お礼 \(w.thanks)", "ほめ言葉 \(w.praise)"]
        if let laughs = w.laughs { parts.append("ウケたかも \(laughs)") }
        if let consulted = w.consulted { parts.append("頼られた \(consulted)") }
        parts += ["済ませた \(w.done)", "自分の発言 \(w.own) 行"]
        return parts.joined(separator: "・")
    }

    /// 先月との比べの行（「お礼　今月 5・先月 3」）。数えていない項目は出さない。どちらも無ければ nil
    static func monthLines(_ month: GoodThings.Month?) -> [String]? {
        guard let month, month.this != nil || month.last != nil else { return nil }
        let rows: [(String, KeyPath<GoodThings.Month.Counts, Int?>)] = [
            ("お礼", \.thanks), ("ほめ言葉", \.praise), ("済ませた", \.done), ("頼られた", \.consulted), ("自分の発言", \.own)]
        var lines: [String] = []
        for row in rows {
            let now: Int? = month.this?[keyPath: row.1]
            let before: Int? = month.last?[keyPath: row.1]
            guard now != nil || before != nil else { continue }
            let nowText = now.map { String($0) } ?? "—"
            let beforeText = before.map { String($0) } ?? "—"
            lines.append("\(row.0)　今月 \(nowText)・先月 \(beforeText)")
        }
        return lines
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

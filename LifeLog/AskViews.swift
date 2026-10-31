import SwiftUI

// MARK: - 記録を探す・記録に質問する

extension Pipeline {
    struct Hit: Identifiable {
        let id = UUID()
        let day: String
        let line: ConversationLog.Line
        let heading: String
    }

    struct Answer {
        let text: String
        let sources: [Hit]
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 言葉で記録を探す（新しい順、最大200件）。空白で区切ると、すべてを含む行。名前でも探せる。
    func search(_ query: String) -> [Hit] {
        let terms = query.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
        guard !terms.isEmpty else { return [] }
        var hits: [Hit] = []
        for day in recordedDays() {
            for c in conversations(on: day).reversed() {
                for line in c.lines.reversed() {
                    let text = (line.speaker ?? "") + " " + line.text + " " + (line.original ?? "")
                    guard terms.allSatisfy({ text.localizedCaseInsensitiveContains($0) }) else { continue }
                    hits.append(Hit(day: day, line: line, heading: c.title ?? ""))
                    if hits.count >= 200 { return hits }
                }
            }
        }
        return hits
    }

    /// 記録から探して、質問に答える（Groq の無料枠）。
    /// 1. 小さいモデルで、質問から探す言葉・人・期間を取り出す。
    /// 2. その期間の会話を、言葉や人がよく出てくる順に、決まった量まで集める。
    /// 3. 大きいモデルで、集めた記録だけをもとに答える。
    func ask(_ question: String) async throws -> Answer {
        guard let key = settings.groqKey else {
            throw CloudTranscriber.Failure.rejected("「サービスと API キーの設定」で Groq の API キーを入れてください。")
        }
        let label = DateFormatter()
        label.locale = Locale(identifier: "ja_JP")
        label.dateFormat = "yyyy-MM-dd(E)"
        let named = people.filter { $0.isNamed && !$0.isSelf }.map(\.displayName)
        let plan = try await Summarizer.plan(question, today: label.string(from: .now), people: named, apiKey: key)

        let days = recordedDays()
        let today = Self.keyFormatter.string(from: .now)
        let to = plan.to ?? today
        let from = plan.from
            ?? Self.keyFormatter.string(from: .now.addingTimeInterval(-60 * 24 * 3600))
        var scored: [(score: Int, day: String, conversation: ConversationLog.Conversation)] = []
        for day in days where day >= from && day <= to {
            for c in conversations(on: day) {
                let text = ([c.title ?? ""] + c.points + c.lines.map { ($0.speaker ?? "") + $0.text })
                    .joined(separator: "\n")
                var score = plan.keywords.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
                score += plan.people.filter { c.people.contains($0) }.count * 3
                if plan.keywords.isEmpty && plan.people.isEmpty { score = 1 }
                if score > 0 { scored.append((score, day, c)) }
            }
        }
        scored.sort { a, b in
            a.score != b.score ? a.score > b.score : (a.day, a.conversation.start) > (b.day, b.conversation.start)
        }

        // 1分あたりの上限に収まるよう、渡すのは6,000文字まで
        let budget = 6_000
        var material = ""
        for item in scored where material.count < budget {
            let c = item.conversation
            let place = c.place.map { " " + $0 } ?? ""
            let people = c.people.isEmpty ? "" : " " + c.people.joined(separator: "、") + "と"
            var block = "[\(item.day) \(Self.minuteFormatter.string(from: c.start))〜\(Self.minuteFormatter.string(from: c.end))\(place)\(people)] \(c.title ?? "")\n"
            block += c.points.map { "・" + $0 + "\n" }.joined()
            let lines = c.lines.map { line in
                Self.minuteFormatter.string(from: line.time) + " " + (line.speaker.map { "[\($0)] " } ?? "") + line.text
            }
            var picked = lines
            if lines.joined().count > 1_500, !plan.keywords.isEmpty {
                // 長い会話は、言葉が出てくる行とその前後2行だけ
                var keep = Set<Int>()
                for (i, line) in c.lines.enumerated() where plan.keywords.contains(where: { line.text.contains($0) }) {
                    for j in max(0, i - 2)...min(c.lines.count - 1, i + 2) { keep.insert(j) }
                }
                picked = keep.isEmpty ? Array(lines.prefix(10)) : keep.sorted().map { lines[$0] }
            }
            block += picked.joined(separator: "\n") + "\n\n"
            material += String(block.prefix(budget - material.count))
        }
        guard !material.isEmpty else {
            return Answer(text: "その期間の記録に見つかりませんでした。", sources: [])
        }

        let result = try await Summarizer.answer(question, material: material, apiKey: key)
        // 根拠の「yyyy-MM-dd HH:mm」を、記録の行に結びつける
        var sources: [Hit] = []
        for source in result.sources {
            let day = String(source.prefix(10))
            let minute = String(source.suffix(5))
            for c in conversations(on: day) {
                if let line = c.lines.first(where: { Self.minuteFormatter.string(from: $0.time) == minute }) {
                    sources.append(Hit(day: day, line: line, heading: c.title ?? ""))
                    break
                }
            }
        }
        return Answer(text: result.text, sources: sources)
    }
}

/// 記録の1行（日付・時刻・話者・本文）。押すとその日の記録を開く。
struct HitRow: View {
    let hit: Pipeline.Hit

    var body: some View {
        NavigationLink {
            DayView(day: hit.day)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(hit.day + " " + hit.line.time.formatted(date: .omitted, time: .shortened))
                    if hit.line.marked == true { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if let speaker = hit.line.speaker { Text(speaker).bold() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(hit.line.text)
                if !hit.heading.isEmpty {
                    Text(hit.heading).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SearchView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var query = ""
    @State private var hits: [Pipeline.Hit] = []
    @State private var searched = false

    var body: some View {
        List(hits) { HitRow(hit: $0) }
            .overlay {
                if searched && hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if !searched {
                    ContentUnavailableView("言葉や名前で探す", systemImage: "magnifyingglass",
                                           description: Text("空白で区切ると、すべてを含む行を探します。行を押すと、その日の記録が開き、そこから音声も聞けます。"))
                }
            }
            .searchable(text: $query, prompt: "言葉・名前")
            .onSubmit(of: .search) { run() }
            .onChange(of: query) { if query.count >= 2 { run() } else { hits = []; searched = false } }
            .navigationTitle("記録を探す")
    }

    private func run() {
        hits = pipeline.search(query)
        searched = true
    }
}

struct AskView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var question = ""
    @State private var answer: Pipeline.Answer?
    @State private var asked = ""
    @State private var working = false
    @State private var error = ""

    var body: some View {
        Form {
            Section {
                TextField("例: 先週田中さんと何を決めた？", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                Button(working ? "探しています…" : "質問する") { run() }
                    .disabled(working || question.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("記録から関係のありそうな会話を集めて、Groq の無料枠の言語モデルが答えます（記録に無いことは答えません）。期間を言わなければ直近60日から探します。")
            }
            if !error.isEmpty {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            if let answer {
                Section(asked) {
                    Text(answer.text).textSelection(.enabled)
                }
                if !answer.sources.isEmpty {
                    Section("もとにした記録") {
                        ForEach(answer.sources) { HitRow(hit: $0) }
                    }
                }
            }
        }
        .navigationTitle("記録に質問する")
    }

    private func run() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true
        error = ""
        Task {
            do {
                answer = try await pipeline.ask(q)
                asked = q
                question = ""
            } catch {
                self.error = "答えられませんでした: \(error.localizedDescription)"
            }
            working = false
        }
    }
}

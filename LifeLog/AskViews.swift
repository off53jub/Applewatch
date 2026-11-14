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
        /// いっしょに材料にした仕事のまとめの日（新しい日から。2026-11-10）
        var digestDays: [String] = []
        /// 材料にしたまとめの行のうち、答えの文と言葉が重なるもの（答えに使われたらしい行。2026-11-10）
        var digestUsed: [UsedDigestLine] = []
    }

    /// 答えに使われたらしい、仕事のまとめの1行
    struct UsedDigestLine: Identifiable, Equatable {
        let day: String
        let heading: String
        let text: String
        var id: String { day + "|" + heading + "|" + text }
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
        // 索引で探せる言葉（2文字以上）なら索引から。見つけた行が今の記録と合うか確かめる
        refreshSearchIndex()
        if let found = searchIndex.search(terms) {
            var hits: [Hit] = []
            var loaded: [String: [ConversationLog.Conversation]] = [:]
            for item in found {
                let list = loaded[item.day] ?? conversations(on: item.day)
                loaded[item.day] = list
                guard let c = list.first(where: { $0.lines.contains { $0.time == item.time } }),
                      let line = c.lines.first(where: { $0.time == item.time }) else { continue }
                let text = (line.speaker ?? "") + " " + line.text + " " + (line.original ?? "")
                guard terms.allSatisfy({ text.localizedCaseInsensitiveContains($0) }),
                      !hits.contains(where: { $0.line.time == line.time && $0.day == item.day }) else { continue }
                hits.append(Hit(day: item.day, line: line, heading: c.title ?? ""))
            }
            return hits
        }
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
        guard let key = llmKey else {
            throw CloudTranscriber.Failure.rejected("「サービスと API キーの設定」で Groq の API キーを入れるか、iPhone の中の言語モデルを使えるようにしてください。")
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
        // 期間を言わなかったときは、直近60日に加えて、索引で言葉が見つかった前の日も探す
        var found = Set<String>()
        if plan.from == nil {
            refreshSearchIndex()
            for keyword in plan.keywords {
                for hit in searchIndex.search([keyword], limit: 300) ?? [] { found.insert(hit.day) }
            }
        }
        // 家の PC の索引で、意味の近い発言も探す（言葉が一致しなくても見つかる。2026-11-07）
        let near = await semanticSearch(question, from: plan.from, to: plan.to, k: 40)
        var nearTalks = Set<String>()
        for hit in near {
            found.insert(hit.day)
            if let c = conversations(on: hit.day).first(where: { $0.lines.contains { $0.time == hit.line.time } }) {
                nearTalks.insert(hit.day + "|" + String(c.start.timeIntervalSince1970))
            }
        }
        var scored: [(score: Int, day: String, conversation: ConversationLog.Conversation)] = []
        for day in days where (day >= from && day <= to) || found.contains(day) {
            for c in conversations(on: day) {
                let text = ([c.title ?? ""] + c.points + c.lines.map { ($0.speaker ?? "") + $0.text })
                    .joined(separator: "\n")
                var score = plan.keywords.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
                score += plan.people.filter { c.people.contains($0) }.count * 3
                if plan.keywords.isEmpty && plan.people.isEmpty { score = 1 }
                // 意味の近い発言のある会話は、先に読む
                if nearTalks.contains(day + "|" + String(c.start.timeIntervalSince1970)) { score += 6 }
                if score > 0 { scored.append((score, day, c)) }
            }
        }
        scored.sort { a, b in
            a.score != b.score ? a.score > b.score : (a.day, a.conversation.start) > (b.day, b.conversation.start)
        }

        // 仕事のまとめも材料にする（2026-11-10、本人の決定。職場の中身なので、職場の会話と同じ設定に従う）
        let digestEntries: [WorkDigest.Entry] = workDigests.sorted
        let anyDay: Bool = plan.from == nil
        // 家の PC の索引で、意味の近いまとめの行も探す（言葉が一致しなくても入る。2026-11-10。PC が読める版のときだけ）
        var nearDigest: Set<String> = []
        if !digestEntries.isEmpty {
            nearDigest = await semanticDigestKeys(question, from: plan.from, to: plan.to)
        }
        let probe = Self.workDigestMaterial(digestEntries, keywords: plan.keywords, people: plan.people,
                                            from: from, to: to, anyDay: anyDay, budget: 200, near: nearDigest)
        // 職場の会話・仕事のまとめが入るときは、設定によって端末内の言語モデルで答える（そのときは渡す量を減らす）
        let work = !probe.days.isEmpty || scored.prefix(10).contains { isWorkTime($0.conversation.start) }
        let local = Summarizer.$sensitive.withValue(work) { Summarizer.usesLocal(apiKey: key) }
        // 1分あたりの上限に収まるよう、渡すのは6,000文字まで（端末内なら1,800文字）
        let budget = local ? 1_800 : 6_000
        // まとめは全体の4割まで（会話が1つも無ければ全部）。残りを会話に使う
        let digestBudget: Int = scored.isEmpty ? budget : budget * 2 / 5
        let digest = Self.workDigestMaterial(digestEntries, keywords: plan.keywords, people: plan.people,
                                             from: from, to: to, anyDay: anyDay, budget: digestBudget, near: nearDigest)
        var material = digest.text
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
            if lines.joined().count > 1_500, !plan.keywords.isEmpty || !near.isEmpty {
                // 長い会話は、言葉が出てくる行・意味の近い行と、その前後2行だけ
                var keep = Set<Int>()
                for (i, line) in c.lines.enumerated() where plan.keywords.contains(where: { line.text.contains($0) })
                    || near.contains(where: { $0.day == item.day && $0.line.time == line.time }) {
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

        let hasDigest: Bool = !digest.days.isEmpty
        let result = try await Summarizer.$sensitive.withValue(work) {
            try await Summarizer.answer(question, material: material, digest: hasDigest, apiKey: key)
        }
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
        let used: [UsedDigestLine] = Self.digestLinesUsed(answer: result.text, lines: digest.lines)
            .map { UsedDigestLine(day: $0.day, heading: $0.heading, text: $0.text) }
        return Answer(text: result.text, sources: sources, digestDays: digest.days, digestUsed: used)
    }
}

/// 「記録に質問する」の答えの「役に立った」「外れ」の数（2026-11-10）。端末の中の数だけ（質問や答えの文は残さない）
enum AskFeedback {
    private static let goodKey = "askFeedback.good"
    private static let badKey = "askFeedback.bad"

    static func record(_ good: Bool) {
        let key = good ? goodKey : badKey
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }

    static var counts: (good: Int, bad: Int) {
        (UserDefaults.standard.integer(forKey: goodKey), UserDefaults.standard.integer(forKey: badKey))
    }
}

/// 仕事のまとめで見つかった1行（日付・見出し・本文）。押すと、そのまとめを開く。
struct DigestHitRow: View {
    @Environment(Pipeline.self) private var pipeline
    let hit: Pipeline.DigestHit

    var body: some View {
        let entry: WorkDigest.Entry? = pipeline.workDigests.entries.first { $0.id == hit.entryID }
        let caption: String = Pipeline.workDigestDayTitle(hit.day) + (hit.heading.isEmpty ? "" : "・" + hit.heading)
            + (hit.source.isEmpty ? "" : "・" + hit.source)
        NavigationLink {
            if let entry {
                WorkDigestDetailView(entry: entry)
            } else {
                Text("このまとめは、もうありません。").foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Text(hit.text)
            }
        }
    }
}

/// 記録の1行（日付・時刻・話者・本文）。押すとその日の記録を開く。
struct HitRow: View {
    let hit: Pipeline.Hit

    var body: some View {
        NavigationLink {
            // 見つけた行を探しやすいよう、会話ごとの見方で開く
            ConversationsView(day: hit.day)
                .navigationTitle(hit.day)
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

struct AskView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var question = ""
    @State private var answer: Pipeline.Answer?
    @State private var asked = ""
    @State private var working = false
    @State private var error = ""
    /// この答えに「役に立った」（true）・「外れ」（false）を押したか
    @State private var voted: Bool?
    /// 母艦から探す（2026-11-13。AskMothership.swift）。オフなら今までのまま
    @AppStorage(MothershipAsk.toggleKey) private var fromMothership = false
    /// 「母艦も探す」を自分で切り替えたことがあるか（2026-11-15。強化案 48）。無ければ、家の PC が askmother を出しているときはオン
    @AppStorage("askFromMothershipChosen") private var motherChosen = false
    @AppStorage(ClaudeRoute.useKey) private var useClaude = true
    @AppStorage(ClaudeRoute.workKey) private var forWork = true
    @State private var motherAnswer: MothershipAnswer?

    private func vote(_ good: Bool) {
        AskFeedback.record(good)
        voted = good
    }

    var body: some View {
        Form {
            Section {
                TextField("例: 先週田中さんと何を決めた？", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                Button(working ? "探しています…" : "質問する") { run() }
                    .disabled(working || question.trimmingCharacters(in: .whitespaces).isEmpty)
                Toggle("母艦も探す（LINE・PLAUD・写真・予定・お金も）", isOn: motherOn)
                    .disabled(!motherUsable)
            } footer: {
                if motherOn.wrappedValue {
                    Text("家の PC が、母艦の LINE・PLAUD・予定・写真・体調・場所・1日と週のまとめ・仕事のまとめ・お金の記録を、言葉と意味の両方で探します。人・欲しい物・決めたことの質問なら、欲しい物リスト・決めごと・人のノートの合うところも読みます。Claude が見つかったものだけをもとに答えます（1分ほどかかります）。")
                } else {
                    Text(plainFooter)
                }
            }
            if !error.isEmpty {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            if let motherAnswer {
                MothershipAnswerSections(question: asked, answer: motherAnswer)
            }
            if let answer {
                Section {
                    Text(answer.text).textSelection(.enabled)
                } header: {
                    Text(asked)
                } footer: {
                    // 役に立ったか（2026-11-10。数はタスクの「済み」→「入り口ごとの数」に出る）
                    HStack(spacing: 20) {
                        if let voted {
                            Text(voted ? "「役に立った」にしました" : "「外れ」にしました")
                        } else {
                            Button("役に立った", systemImage: "hand.thumbsup") { vote(true) }
                            Button("外れ", systemImage: "hand.thumbsdown") { vote(false) }
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
                if answer.sources.isEmpty && answer.digestUsed.isEmpty && motherUsable && !working {
                    // iPhone の記録で見つからなかったときは、母艦からも探せる（2026-11-13。AskMothership.swift）
                    Section {
                        Button("母艦（LINE・写真・予定・お金も）からも探す") { runMothership(asked) }
                    }
                }
                if !answer.digestUsed.isEmpty {
                    Section {
                        ForEach(answer.digestUsed) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Pipeline.workDigestDayTitle(line.day) + (line.heading.isEmpty ? "" : "・" + line.heading))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(line.text)
                            }
                        }
                    } header: {
                        Text("答えに使われたらしい、まとめの行")
                    } footer: {
                        Text("答えの文と言葉がよく重なる行です。")
                    }
                }
                if !answer.sources.isEmpty {
                    Section("もとにした記録") {
                        ForEach(answer.sources) { HitRow(hit: $0) }
                    }
                }
                let digests: [WorkDigest.Entry] = pipeline.workDigests.sorted.filter { answer.digestDays.contains($0.day) }
                if !digests.isEmpty {
                    Section {
                        ForEach(digests) { entry in
                            NavigationLink {
                                WorkDigestDetailView(entry: entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Pipeline.workDigestDayTitle(entry.day)).font(.caption).foregroundStyle(.secondary)
                                    WorkDigestRow(entry: entry)
                                }
                            }
                        }
                    } header: {
                        Text("いっしょに読んだ仕事のまとめ")
                    } footer: {
                        Text("質問に合うところを、材料として渡したまとめです（答えに使われたとは限りません）。")
                    }
                }
            }
        }
        .navigationTitle("記録に質問する")
        .countsOpen("ask")
    }

    private var motherUsable: Bool {
        MothershipAsk.usable(features: pipeline.homePC.features, useClaude: useClaude, forWork: forWork)
    }

    /// 母艦も探すか。自分で切り替えたことが無ければ、使えるとき（家の PC が askmother を出しているとき）はオン
    private var motherOn: Binding<Bool> {
        Binding<Bool>(
            get: {
                guard motherUsable else { return false }
                let chosen: Bool = motherChosen || UserDefaults.standard.object(forKey: MothershipAsk.toggleKey) != nil
                return chosen ? fromMothership : true
            },
            set: { (on: Bool) in
                fromMothership = on
                motherChosen = true
            }
        )
    }

    private var motherBlocked: String? {
        MothershipAsk.blocked(features: pipeline.homePC.features, useClaude: useClaude, forWork: forWork)
    }

    /// 今までの「記録に質問する」の説明（母艦から探せないときは、そのわけも）
    private var plainFooter: String {
        let base: String = "記録から関係のありそうな会話を集めて、Groq の無料枠の言語モデルが答えます（記録に無いことは答えません）。期間を言わなければ直近60日から探します。取り込んだ「仕事のまとめ」も、質問に合うところをいっしょに読みます（職場の会話と同じ設定に従います）。"
        guard let why = motherBlocked else { return base }
        return base + "\n母艦から探す: " + why
    }

    /// 母艦から探す（今までの答えは消す）
    private func runMothership(_ q: String) {
        guard !q.isEmpty else { return }
        working = true
        error = ""
        Task {
            do {
                let got: MothershipAnswer = try await pipeline.askMothership(q)
                motherAnswer = got
                answer = nil
                asked = q
                voted = nil
                question = ""
            } catch {
                self.error = "母艦から答えられませんでした: \(error.localizedDescription)"
            }
            working = false
        }
    }

    private func run() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if motherOn.wrappedValue {
            runMothership(q)
            return
        }
        motherAnswer = nil
        working = true
        error = ""
        Task {
            do {
                answer = try await pipeline.ask(q)
                asked = q
                voted = nil
                question = ""
            } catch {
                self.error = "答えられませんでした: \(error.localizedDescription)"
            }
            working = false
        }
    }
}

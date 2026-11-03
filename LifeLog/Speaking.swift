import Foundation
import SwiftUI

/// 話し方の振り返り。記録の自分の行から、話す割合・速さ・口ぐせ・質問の数を数え、相手ごと・場面ごと・週ごとに見る。
/// 数えるのは iPhone の中だけ（無料）。「ひとことで振り返る」だけ言語モデルを使う。
/// 文字起こしは「えー」「あの」などを書かないことがあるので、口ぐせの数は目安。
struct SpeakStats {
    var conversations = 0
    /// 自分の行・文字数と、話していた時間の見積もり（次の行までの間。1行20秒まで）
    var selfLines = 0
    var selfChars = 0
    var selfSeconds: Double = 0
    /// 会話全体の文字数（テレビなどの行は除く）
    var totalChars = 0
    var fillers = 0
    var questions = 0
    /// 心拍が上がっていた会話の数（ヘルスケアが使えるときだけ数える）
    var tense = 0

    var share: Double? { totalChars > 0 ? Double(selfChars) / Double(totalChars) : nil }
    /// 1分あたりの文字数
    var speed: Double? { selfSeconds >= 30 ? Double(selfChars) / (selfSeconds / 60) : nil }
    /// 1,000文字あたりの口ぐせ
    var fillerRate: Double? { selfChars >= 200 ? Double(fillers) * 1_000 / Double(selfChars) : nil }
    /// 会話1つあたりの質問
    var questionRate: Double? { conversations > 0 ? Double(questions) / Double(conversations) : nil }

    static func + (a: SpeakStats, b: SpeakStats) -> SpeakStats {
        SpeakStats(conversations: a.conversations + b.conversations, selfLines: a.selfLines + b.selfLines,
                   selfChars: a.selfChars + b.selfChars, selfSeconds: a.selfSeconds + b.selfSeconds,
                   totalChars: a.totalChars + b.totalChars, fillers: a.fillers + b.fillers,
                   questions: a.questions + b.questions, tense: a.tense + b.tense)
    }

    /// 口ぐせ（長いものから数える）
    static let fillerWords = ["えーっと", "えっと", "えーと", "えー", "あのー", "あの、", "なんか", "まあ", "うーん", "その、"]
    private static let fillerPattern = try! NSRegularExpression(
        pattern: fillerWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))

    static func fillerCount(_ text: String) -> Int {
        fillerPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// 問いかけの文か（「？」、または「ですか」「ますか」「かな」などで終わる）
    static func isQuestion(_ text: String) -> Bool {
        if text.contains("？") || text.contains("?") { return true }
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: "。、 　"))
        return ["ですか", "ますか", "でしょうか", "かな", "かね", "の？", "だっけ", "ません？"].contains { t.hasSuffix($0) }
    }

    /// 1つの会話の数（テレビ・動画の会話は数えない）
    static func of(_ c: ConversationLog.Conversation) -> SpeakStats? {
        guard c.media == nil else { return nil }
        let lines = c.lines.filter { $0.media == nil }
        guard !lines.isEmpty else { return nil }
        var s = SpeakStats(conversations: 1)
        for (i, line) in lines.enumerated() {
            s.totalChars += line.text.count
            guard line.speakerID == SpeakerLabeler.selfID || line.speaker == SpeakerLabeler.selfName else { continue }
            s.selfLines += 1
            s.selfChars += line.text.count
            let next = i + 1 < lines.count ? lines[i + 1].time.timeIntervalSince(line.time) : Double(line.text.count) / 7
            s.selfSeconds += min(20, max(0.5, next))
            s.fillers += fillerCount(line.text)
            if isQuestion(line.text) { s.questions += 1 }
        }
        if c.tense == true { s.tense = 1 }
        return s
    }
}

extension Pipeline {
    struct SpeakingReport {
        var recent = SpeakStats()
        var before = SpeakStats()
        var work = SpeakStats()
        var other = SpeakStats()
        var people: [(name: String, stats: SpeakStats)] = []
        var weeks: [(label: String, stats: SpeakStats)] = []
    }

    /// 直近 days 日の会話から数える。recent は直近7日、before はその前。
    func speakingReport(days: Int = 56) -> SpeakingReport {
        var report = SpeakingReport()
        let now = Date.now
        var byPerson: [String: SpeakStats] = [:]
        var byWeek: [Date: SpeakStats] = [:]
        let calendar = Calendar(identifier: .gregorian)
        for day in recordedDays().prefix(days) {
            for c in conversations(on: day) where c.closed {
                guard let s = SpeakStats.of(c), s.selfLines > 0 else { continue }
                if now.timeIntervalSince(c.start) < 7 * 86400 { report.recent = report.recent + s } else { report.before = report.before + s }
                if isWorkTime(c.start) { report.work = report.work + s } else { report.other = report.other + s }
                for name in c.people where !name.hasPrefix("人物") {
                    byPerson[name] = (byPerson[name] ?? SpeakStats()) + s
                }
                // 月曜はじまりの週
                let weekday = calendar.component(.weekday, from: c.start)
                if let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: calendar.startOfDay(for: c.start)) {
                    byWeek[monday] = (byWeek[monday] ?? SpeakStats()) + s
                }
            }
        }
        report.people = byPerson.map { ($0.key, $0.value) }.sorted { $0.stats.conversations > $1.stats.conversations }
        let label = DateFormatter()
        label.locale = Locale(identifier: "ja_JP")
        label.dateFormat = "M/d〜"
        report.weeks = byWeek.sorted { $0.key > $1.key }.prefix(8).map { (label.string(from: $0.key), $0.value) }
        return report
    }

    /// 数字から、ひとことの振り返りを作る（言語モデル）
    func speakingAdvice(_ report: SpeakingReport) async throws -> [String] {
        guard let key = llmKey else {
            throw CloudTranscriber.Failure.rejected("Groq のキーを入れるか、iPhone の中の言語モデルを使えるようにしてください。")
        }
        var text = "直近7日: " + SpeakingView.summary(report.recent) + "\n"
        text += "その前の7週: " + SpeakingView.summary(report.before) + "\n"
        text += "職場: " + SpeakingView.summary(report.work) + "\n職場以外: " + SpeakingView.summary(report.other) + "\n"
        for item in report.people.prefix(8) { text += "\(item.name)と: " + SpeakingView.summary(item.stats) + "\n" }
        return try await Summarizer.speaking(text, apiKey: key)
    }
}

/// 話し方の振り返りの画面
struct SpeakingView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var report = Pipeline.SpeakingReport()
    @State private var advice: [String] = []
    @State private var thinking = false
    @State private var note: String?

    /// 「話す割合 35%・速さ 1分 310 文字・口ぐせ 千字に 12・質問 会話1つに 1.5」
    static func summary(_ s: SpeakStats) -> String {
        var parts: [String] = []
        if let share = s.share { parts.append("話す割合 \(Int((share * 100).rounded()))%") }
        if let speed = s.speed { parts.append("速さ 1分 \(Int(speed.rounded())) 文字") }
        if let filler = s.fillerRate { parts.append("口ぐせ 千字に \(Int(filler.rounded()))") }
        if let q = s.questionRate { parts.append(String(format: "質問 会話1つに %.1f", q)) }
        if s.tense > 0 { parts.append("心拍が上がった会話 \(s.tense)") }
        parts.append("会話 \(s.conversations)")
        return parts.joined(separator: "・")
    }

    var body: some View {
        List {
            Section {
                row("直近7日", report.recent)
                row("その前（7週）", report.before)
            } header: {
                Text("自分の話し方")
            } footer: {
                Text("「話す割合」は会話の文字のうち自分の分、「速さ」は自分が話していた時間（次の行までの間）あたりの文字数、「口ぐせ」は「えー」「あの」「なんか」「まあ」などの数、「質問」は「？」や「ですか」で終わる自分の文です。文字起こしは口ぐせを書かないことがあるので、目安として見てください。")
            }
            Section("場面ごと") {
                row("職場", report.work)
                row("職場以外", report.other)
            }
            if !report.people.isEmpty {
                Section("相手ごと（よく話した順）") {
                    ForEach(report.people.prefix(12), id: \.name) { row($0.name, $0.stats) }
                }
            }
            if !report.weeks.isEmpty {
                Section("週ごと") {
                    ForEach(report.weeks, id: \.label) { row($0.label, $0.stats) }
                }
            }
            Section {
                Button(thinking ? "考えています…" : "ひとことで振り返る") {
                    thinking = true
                    Task {
                        do {
                            advice = try await pipeline.speakingAdvice(report)
                            note = nil
                        } catch {
                            note = error.localizedDescription
                        }
                        thinking = false
                    }
                }
                .disabled(thinking)
                ForEach(advice, id: \.self) { Text("・" + $0) }
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("上の数字だけを言語モデルに渡して、良かったところ・気をつけるとよいところ・次に試すことを短く返してもらいます（会話の中身は渡しません）。")
            }
        }
        .navigationTitle("話し方の振り返り")
        .onAppear { report = pipeline.speakingReport() }
    }

    private func row(_ label: String, _ s: SpeakStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            Text(s.conversations > 0 ? Self.summary(s) : "まだありません").font(.caption).foregroundStyle(.secondary)
        }
    }
}

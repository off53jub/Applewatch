import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// AI からの質問と、わかったこと帳（2026-11-05 本人の希望）。
/// 1日の記録のうち、AI が「合っているか分からない・あいまい」と思ったところを、夜に5つまで本人に聞く。
/// 答えは「わかったこと」として残し、次からの見出し・要点・1日のまとめ・頼まれごと・質問づくりの AI に、関係するものだけ渡す。
/// 答えた会話は、見出しと要点（と、その日の1日のまとめ）を作り直す。名前の付け替え・声の統合は自動ではしない。
/// 中身は `asks.json` に端末ごとに持つ（同期はしない）。iPhone はドライブの「わかったこと帳」と同期フォルダの「わかったこと帳.json」にも写す。
@MainActor
@Observable
final class AskBook {
    enum Kind: String, Codable, CaseIterable {
        /// 何をしていたか・何の集まりか・何の話か
        case what
        /// 聞き間違いらしい言葉
        case word
        /// だれのことか・だれが話していたか
        case who
        /// 決まったこと・やることが合っているか
        case decision

        var label: String {
            switch self {
            case .what: "何をしていたか"
            case .word: "言葉"
            case .who: "だれのことか"
            case .decision: "決まったこと"
            }
        }

        var icon: String {
            switch self {
            case .what: "figure.walk"
            case .word: "character.bubble"
            case .who: "person.fill.questionmark"
            case .decision: "checkmark.seal"
            }
        }
    }

    enum State: String, Codable {
        case open
        case answered
        /// 分からない（飛ばした）
        case skipped
        /// 的外れな質問だった
        case wrong
    }

    struct Question: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        let day: String
        let kind: Kind
        let question: String
        /// 質問の対象の言葉（記録の書き方のまま）
        var subject: String? = nil
        var choices: [String] = []
        /// 根拠の記録の文
        var quote: String? = nil
        var time: Date? = nil
        var place: String? = nil
        var audio: String? = nil
        var offset: TimeInterval? = nil
        /// どの会話の質問か（会話の始まり）
        var conversation: Date? = nil
        var state: State = .open
        var answer: String? = nil
        var asked: Date = .now
        var answeredAt: Date? = nil
    }

    struct Fact: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        /// AI に渡す1行（「〔11/3(火) 18:47・大久保駅近く〕何の集まり？ → ダンスの練習」の形）
        var text: String
        let kind: Kind
        let day: String
        /// この記録に関係するかを見る手がかりの言葉
        var words: [String]
        /// もとの質問
        var question: String? = nil
        var added: Date = .now
    }

    private struct Store: Codable {
        var questions: [Question] = []
        var facts: [Fact] = []
    }

    private(set) var questions: [Question] = []
    private(set) var facts: [Fact] = []
    /// 中身が変わるたびに増える（ドライブの写しを作り直す目安）
    private(set) var version = 0

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("asks.json")

    /// まだ答えていない質問（新しい日から、聞いた順）
    var open: [Question] {
        questions.filter { $0.state == .open }.sorted { $0.day != $1.day ? $0.day > $1.day : $0.asked < $1.asked }
    }
    /// 答えた・飛ばした質問（7日以内・新しいものから）
    var recent: [Question] {
        let since = Date.now.addingTimeInterval(-7 * 86400)
        return questions.filter { $0.state != .open && ($0.answeredAt ?? $0.asked) >= since }
            .sorted { ($0.answeredAt ?? $0.asked) > ($1.answeredAt ?? $1.asked) }
    }

    init() {
        if let data = try? Data(contentsOf: Self.url) {
            if let saved = try? JSONDecoder().decode(Store.self, from: data) {
                questions = saved.questions
                facts = saved.facts
            } else {
                // 読めないファイルは上書きせず、脇に置く
                let aside = Self.url.deletingLastPathComponent().appendingPathComponent("asks-unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: Self.url, to: aside)
            }
        }
        shareFacts()
    }

    /// 足す。同じ日によく似た質問がある・もう分かっている言葉の質問は足さない。足したものを返す。
    @discardableResult
    func add(_ new: [Question]) -> [Question] {
        var added: [Question] = []
        let known = Set(facts.flatMap(\.words))
        for q in new {
            let text = q.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let duplicate = (questions + added).contains { $0.day == q.day && TaskBook.similar($0.question, text) }
            let settled = q.kind != .what && q.kind != .decision && (q.subject.map { known.contains($0) } ?? false)
            guard !duplicate, !settled else { continue }
            let copy = Question(id: q.id, day: q.day, kind: q.kind, question: text, subject: q.subject, choices: q.choices,
                            quote: q.quote, time: q.time, place: q.place, audio: q.audio, offset: q.offset,
                            conversation: q.conversation, asked: q.asked)
            added.append(copy)
        }
        guard !added.isEmpty else { return [] }
        questions += added
        save()
        return added
    }

    /// 答える。わかったことを1つ足して返す。
    @discardableResult
    func answer(_ id: String, _ text: String) -> Fact? {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, let i = questions.firstIndex(where: { $0.id == id }) else { return nil }
        questions[i].state = .answered
        questions[i].answer = answer
        questions[i].answeredAt = .now
        let q = questions[i]
        facts.removeAll { $0.question == q.id }
        let fact = Fact(text: Self.factText(q, answer: answer), kind: q.kind, day: q.day,
                        words: Self.words(of: q, answer: answer), question: q.id)
        facts.append(fact)
        save()
        return fact
    }

    func set(_ id: String, _ state: State) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[i].state = state
        questions[i].answeredAt = state == .open ? nil : .now
        if state == .open {
            questions[i].answer = nil
            facts.removeAll { $0.question == id }
        }
        save()
    }

    func updateFact(_ fact: Fact) {
        guard let i = facts.firstIndex(where: { $0.id == fact.id }) else { return }
        facts[i] = fact
        save()
    }

    func deleteFact(_ id: String) {
        facts.removeAll { $0.id == id }
        save()
    }

    private func save() {
        // 答えた質問とわかったことはずっと、まだ・飛ばした質問は60日まで残す
        let since = Date.now.addingTimeInterval(-60 * 86400)
        questions = questions.filter { $0.state == .answered || $0.asked >= since }
        version += 1
        shareFacts()
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(Store(questions: questions, facts: facts)) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// 言語モデルに渡せるよう、わかったことを渡しておく
    private func shareFacts() {
        KnownFacts.shared.set(facts.sorted { $0.added < $1.added }.map { .init(text: $0.text, words: $0.words) })
    }

    // MARK: - 形をそろえる

    nonisolated static let factDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) H:mm"
        return f
    }()

    /// 「〔11/3(火) 18:47・大久保駅近く〕何の集まり？ → ダンスの練習」
    nonisolated static func factText(_ q: Question, answer: String) -> String {
        var head: [String] = []
        if let time = q.time { head.append(factDate.string(from: time)) } else { head.append(q.day) }
        if let place = q.place { head.append(place) }
        let subject = q.subject.map { "（「\($0)」）" } ?? ""
        return "〔\(head.joined(separator: "・"))〕\(q.question)\(subject) → \(answer)"
    }

    /// 関係するかを見る言葉: 質問の対象・答え・根拠の文の、名前や固有名詞らしいもの
    nonisolated static func words(of q: Question, answer: String) -> [String] {
        var list: [String] = []
        for w in (q.subject.map { [$0] } ?? []) + keywords(answer) + keywords(q.quote ?? "")
        where !list.contains(w) && w.count >= 2 && w.count <= 20 {
            list.append(w)
        }
        return Array(list.prefix(12))
    }

    private nonisolated static let common: Set<String> = ["今日", "明日", "昨日", "時間", "本人", "自分", "会話", "記録", "感じ",
                                                          "大丈夫", "一緒", "最近", "今回", "前回", "場合", "予定", "メンバー"]

    /// カタカナ2文字以上・漢字2文字以上・英字3文字以上の言葉
    nonisolated static func keywords(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[ァ-ヶー]{2,}|[一-龠々]{2,}|[A-Za-z][A-Za-z0-9]{2,}") else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range)
            if !common.contains(w) && !out.contains(w) { out.append(w) }
        }
        return out
    }
}

// MARK: - 質問を作る・知らせる・写す

extension Pipeline {
    static let askOnKey = "askOn"
    /// 聞く時刻（0時からの分）。夜21時
    static let askTimeKey = "askTime"
    private static let askedDaysKey = "askedDays"
    private static let askNotifyID = "askQuestions"
    private static let askBookHashKey = "askBookWritten"
    /// 1日に聞く数（2026-11-05 本人決定）
    static let askPerDay = 5

    static var askOn: Bool { UserDefaults.standard.object(forKey: askOnKey) as? Bool ?? true }
    static var askTime: Int { UserDefaults.standard.object(forKey: askTimeKey) as? Int ?? 21 * 60 }

    private static let askClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func minuteOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// さかのぼって聞く日数（昨日・一昨日…の分も聞く。2026-11-05 本人の希望）
    static let askBackDays = 7

    /// 夜（既定21時）を過ぎたら、その日の記録から AI に質問を作らせる（1日ぶん5つまで）。
    /// まだ聞いていない前の日（7日前まで）も、新しい日から1回に1日ずつ作る。夜より前に作った分は、夜に知らせる。
    /// 言語モデルが使えなければ次の機会にやり直す。now は「前の日の分も聞く」を押したとき（知らせない・まだの質問が多くても作る）。
    /// 作った日と数を返す（作る日が無ければ nil）。
    @discardableResult
    func makeQuestions(now pressed: Bool = false) async -> (day: String, count: Int)? {
        guard Self.askOn || pressed, let key = llmKey, asks.open.count < (pressed ? 25 : 10) else { return nil }
        var done = UserDefaults.standard.stringArray(forKey: Self.askedDaysKey) ?? []
        let now = Date.now
        let today = TaskBook.dayFormat.string(from: now)
        let recorded = Set(recordedDays())
        var candidates: [String] = Self.minuteOfDay(now) >= Self.askTime ? [today] : []
        for back in 1...Self.askBackDays {
            if let d = Calendar.current.date(byAdding: .day, value: -back, to: now) { candidates.append(TaskBook.dayFormat.string(from: d)) }
        }
        var picked: String?
        for day in candidates where !done.contains(day) && recorded.contains(day) {
            let convs = conversations(on: day).filter { $0.closed && $0.media == nil && !$0.lines.isEmpty }
            if convs.contains(where: { $0.title != nil }) { picked = day; break }
            // 聞けるものが無い前の日は、もう見ない
            if day != today { done.append(day) }
        }
        UserDefaults.standard.set(Array(done.suffix(60)), forKey: Self.askedDaysKey)
        guard let day = picked else { return nil }
        let convs = conversations(on: day).filter { $0.closed && $0.media == nil && !$0.lines.isEmpty }
        let material = questionMaterial(convs, summary: daySummary(day))
        let asked = asks.questions.suffix(80).map(\.question)
        let work = convs.contains { isWorkTime($0.start) }
        let drafts: [Summarizer.AskDraft]
        do {
            drafts = try await Summarizer.$sensitive.withValue(work) {
                try await Summarizer.questions(material, day: day, asked: asked, count: Self.askPerDay, apiKey: key)
            }
        } catch {
            return nil
        }
        done.append(day)
        UserDefaults.standard.set(Array(done.suffix(60)), forKey: Self.askedDaysKey)
        // 答えても記録が変わらない質問（短い言葉の意味・1回しか出てこない言葉・行の少ない声）は外す（2026-11-09）
        let texts = convs.flatMap(\.lines).filter { $0.media == nil }.map(\.text)
        let unnamed = Self.unnamedLineCounts(convs)
        let useful = drafts.filter { Summarizer.keepsQuestion($0, lines: texts, unnamedLines: unnamed) }
        Tally.add("ask.dropped", drafts.count - useful.count)
        let added = asks.add(useful.prefix(Self.askPerDay).map { question(from: $0, day: day, in: convs) })
        guard !added.isEmpty else { return (day, 0) }
        if !pressed { notifyQuestions(asks.open.count, label: day == today ? "今日まで" : "これまで") }
        asksChanged()
        return (day, added.count)
    }

    /// 名前の無い声（「人物N」）ごとの、その日の行の数（放送の行は数えない）
    nonisolated static func unnamedLineCounts(_ convs: [ConversationLog.Conversation]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in convs.flatMap(\.lines) where line.media == nil {
            guard let name = line.speaker, name.hasPrefix("人物") else { continue }
            counts[name, default: 0] += 1
        }
        return counts
    }

    /// 質問を作るために渡す、その日の記録（会話ごとの見出し・要点と、文字起こしの頭）
    private func questionMaterial(_ convs: [ConversationLog.Conversation], summary: Summarizer.Day?) -> String {
        let clock = Self.askClock
        let per = max(300, 5_000 / max(1, convs.count))
        var text = ""
        // 「だれか」を聞いてよい声（その日によく話した名前の無い声だけ。2026-11-09）
        let many = Self.unnamedLineCounts(convs).filter { $0.value >= Summarizer.askWhoMinLines }
            .sorted { $0.value > $1.value }.prefix(8)
        text += "行の多い名前の無い声: " + (many.isEmpty ? "なし" : many.map { "\($0.key)（\($0.value) 行）" }.joined(separator: "、")) + "\n"
        if let summary {
            if !summary.decisions.isEmpty { text += "1日のまとめの「決まったこと」: " + summary.decisions.joined(separator: "／") + "\n" }
            if !summary.todos.isEmpty { text += "1日のまとめの「やること」: " + summary.todos.joined(separator: "／") + "\n" }
            text += "\n"
        }
        for c in convs {
            let place = c.place.map { "・" + $0 } ?? ""
            let people = c.people.isEmpty ? "" : "（\(c.people.joined(separator: "、"))と）"
            text += "## \(clock.string(from: c.start))〜\(clock.string(from: c.end))\(place)\(people) \(c.title ?? "（見出しなし）")\n"
            text += c.points.map { "要点: " + $0 + "\n" }.joined()
            var body = ""
            for line in c.lines where line.media == nil {
                let unsure = line.isUncertain ? "（聞き取りが不確か）" : ""
                let row = clock.string(from: line.time) + " " + (line.speaker.map { "[\($0)] " } ?? "") + unsure + line.text + "\n"
                if body.count + row.count > per { break }
                body += row
            }
            text += body + "\n"
        }
        return String(text.prefix(6_000))
    }

    /// AI の質問を、記録の行（音声・場所）とつなぐ
    private func question(from d: Summarizer.AskDraft, day: String, in convs: [ConversationLog.Conversation]) -> AskBook.Question {
        let head = d.quote.isEmpty ? nil : String(d.quote.prefix(8))
        func atTime(_ line: ConversationLog.Line) -> Bool { !d.time.isEmpty && Self.askClock.string(from: line.time) == d.time }
        func quoted(_ line: ConversationLog.Line) -> Bool { head.map { line.text.contains($0) } ?? false }
        var hit: (conv: ConversationLog.Conversation, line: ConversationLog.Line)?
        for rule in 0..<3 {
            for c in convs {
                if let line = c.lines.first(where: { l in
                    guard l.media == nil else { return false }
                    switch rule {
                    case 0: return atTime(l) && (head == nil || quoted(l))
                    case 1: return quoted(l)
                    default: return atTime(l)
                    }
                }) {
                    hit = (c, line)
                    break
                }
            }
            if hit != nil { break }
        }
        var conv = hit?.conv
        if conv == nil, let minute = Self.minute(d.time) {
            conv = convs.first { Self.minuteOfDay($0.start) <= minute && minute <= Self.minuteOfDay($0.end) }
        }
        return AskBook.Question(day: day, kind: d.kind, question: d.question,
                                subject: d.subject.isEmpty ? nil : d.subject, choices: d.choices,
                                quote: d.quote.isEmpty ? nil : d.quote, time: hit?.line.time ?? conv?.start,
                                place: conv?.place, audio: hit?.line.audio, offset: hit?.line.offset,
                                conversation: conv?.start)
    }

    /// 「18:47」→ 0時からの分
    private static func minute(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// 質問ができたことを知らせる。聞く時刻より前に作ったときは、その時刻に知らせる。
    private func notifyQuestions(_ count: Int, label: String) {
        let content = UNMutableNotificationContent()
        content.title = "AI から \(count) つ質問があります"
        content.body = "\(label)の記録で、合っているか分からないところです。答えると、見出しやまとめが正しくなり、次からも覚えておきます。"
        content.sound = .default
        var trigger: UNNotificationTrigger?
        if Self.minuteOfDay(.now) < Self.askTime {
            var c = DateComponents()
            c.hour = Self.askTime / 60
            c.minute = Self.askTime % 60
            trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.askNotifyID, content: content, trigger: trigger))
    }

    /// 答える。答えた会話は、見出しと要点（と1日のまとめ）を、答えを手がかりに作り直す。
    func answerQuestion(_ q: AskBook.Question, with text: String) {
        guard asks.answer(q.id, text) != nil else { return }
        if let start = q.conversation { markResummarize(start: start, day: q.day) }
        asksChanged()
    }

    /// 言葉の質問の答えを、これからの聞き取りの誤変換として登録する（本人が押したときだけ）
    func registerFix(from q: AskBook.Question) {
        guard q.kind == .word, let wrong = q.subject, let right = q.answer, wrong != right, right.count <= 20 else { return }
        vocabulary.addFix(wrong: wrong, right: right, group: q.time.map { isWorkTime($0) } == true ? .work : .always)
    }

    func asksChanged() {
        Task { await writeAskBook() }
    }

    /// ドライブの「わかったこと帳」と、同期フォルダの「わかったこと帳.json」（PC が読む）に写す。変わっていなければ書かない。
    func writeAskBook() async {
        guard email != nil, UIDevice.current.userInterfaceIdiom != .pad else { return }
        struct Copy: Codable {
            let facts: [AskBook.Fact]
            let questions: [AskBook.Question]
        }
        let answered = asks.questions.filter { $0.state == .answered }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(Copy(facts: asks.facts, questions: answered)) else { return }
        let stamp = "\(asks.facts.count)|\(answered.count)|\(asks.version)"
        guard UserDefaults.standard.string(forKey: Self.askBookHashKey) != stamp else { return }
        var p: [(text: String, style: String?)] = [("わかったこと帳", "HEADING_1"),
                                                  ("アプリの「AI からの質問」に答えたことです。アプリが自動で書き直します（ここを直してもアプリには戻りません）。", nil)]
        p.append(("わかったこと（\(asks.facts.count) 件）", "HEADING_2"))
        p += asks.facts.sorted { $0.added > $1.added }.map { ("・" + $0.text, nil) }
        do {
            try await writeAskBookFiles(p, json: json)
            UserDefaults.standard.set(stamp, forKey: Self.askBookHashKey)
        } catch {
            diagnostics.problem("わかったこと帳をドライブに書けませんでした: \(error.localizedDescription)")
        }
    }
}

// MARK: - 画面

/// AI からの質問に答える
struct QuestionsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()
    @State private var showRecent = false
    @State private var making = false
    @State private var madeNote: String?
    @AppStorage("askOn") private var askOn = true
    @AppStorage("askTime") private var askTime = 21 * 60

    var body: some View {
        let book = pipeline.asks
        List {
            if book.open.isEmpty {
                Section {
                    Text("今は質問がありません").foregroundStyle(.secondary)
                } footer: {
                    Text("夜（下の時刻）を過ぎると、その日の記録から、AI が合っているか分からないところを\(Pipeline.askPerDay)つまで聞きます。")
                }
            }
            ForEach(book.open) { q in
                Section {
                    QuestionRow(question: q, player: player)
                } header: {
                    Label("\(q.day.suffix(5).replacingOccurrences(of: "-", with: "/"))・\(q.kind.label)", systemImage: q.kind.icon)
                }
            }
            Section {
                Button {
                    Task { await makePast() }
                } label: {
                    if making {
                        HStack { ProgressView(); Text("記録を読んで質問を作っています…") }
                    } else {
                        Label("前の日の分も聞く（\(Pipeline.askBackDays)日前まで）", systemImage: "calendar.badge.clock")
                    }
                }
                .disabled(making)
                if let madeNote { Text(madeNote).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("押すたびに、まだ聞いていない日を新しい日から1日ずつ読み、\(Pipeline.askPerDay)つまで質問を作ります。押さなくても、処理のたびに少しずつ作ります。")
            }
            if !book.recent.isEmpty {
                Section {
                    DisclosureGroup("答えたもの（7日以内・\(book.recent.count) 件）", isExpanded: $showRecent) {
                        ForEach(book.recent) { q in
                            AnsweredRow(question: q)
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    FactsView()
                } label: {
                    LabeledContent("わかったこと帳", value: "\(book.facts.count) 件")
                }
            } footer: {
                Text("答えたことは「わかったこと」として残り、次からの見出し・要点・1日のまとめ・頼まれごと探しで、関係するときに AI が使います。答えた会話は、見出しと要点（とその日のまとめ）を作り直します。名前の付け替えや声のまとめは、答えても自動ではしません。")
            }
            Section {
                Toggle("夜に質問する", isOn: $askOn)
                if askOn {
                    DatePicker("時刻", selection: Binding(
                        get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(askTime * 60)) },
                        set: { date in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                            askTime = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                        }), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("知らせ")
            } footer: {
                Text("この時刻を過ぎたら、その日の記録から質問を作って知らせます（1日\(Pipeline.askPerDay)つまで）。夜にアプリが動いていなかった日は、次の日に作り、この時刻に知らせます。")
            }
        }
        .navigationTitle("AI からの質問")
        .onDisappear { player.stop() }
        .onChange(of: book.version) { pipeline.asksChanged() }
    }

    private func makePast() async {
        making = true
        defer { making = false }
        guard pipeline.llmKey != nil else {
            madeNote = "言語モデルが使えないので作れません（設定の Groq のキーか、iPhone の中の言語モデル）。"
            return
        }
        if let made = await pipeline.makeQuestions(now: true) {
            let day = made.day.suffix(5).replacingOccurrences(of: "-", with: "/")
            madeNote = made.count > 0 ? "\(day) の分を \(made.count) つ作りました。" : "\(day) の分は、聞きたいことがありませんでした。もう一度押すと、その前の日を読みます。"
        } else if pipeline.asks.open.count >= 25 {
            madeNote = "まだ答えていない質問が多いので、先に答えてください。"
        } else {
            madeNote = "\(Pipeline.askBackDays)日前までの分は、もう聞き終わっているか、記録がありません。読めなかったときは、少し待ってからもう一度押してください。"
        }
    }
}

/// 質問1つ。候補を押すか、書いて答える。
private struct QuestionRow: View {
    @Environment(Pipeline.self) private var pipeline
    let question: AskBook.Question
    let player: ClipPlayer
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question).font(.body)
            if let quote = question.quote {
                Text("「\(quote)」").font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack(spacing: 6) {
                if let time = question.time { Text(AskBook.factDate.string(from: time)) }
                if let place = question.place { Text(place) }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                if let audio = question.audio {
                    let key = "ask-" + question.id
                    Button {
                        Task {
                            let start = max(0, (question.offset ?? 0) - 3)
                            await player.toggle(key, at: start, until: start + 20) {
                                await pipeline.archive.playableURL(for: audio)
                            }
                        }
                    } label: {
                        if player.loading == key {
                            ProgressView()
                        } else {
                            Label(player.playing == key ? "止める" : "その場面を聞く",
                                  systemImage: player.playing == key ? "stop.circle.fill" : "play.circle")
                        }
                    }
                }
                NavigationLink("記録を開く") { DayView(day: question.day) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            if !question.choices.isEmpty {
                // 候補を押すと、そのまま答えになる
                FlowChoices(choices: question.choices) { choice in
                    withAnimation { pipeline.answerQuestion(question, with: choice) }
                }
            }
            HStack {
                TextField("書いて答える", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("答える", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 20) {
                Button("分からない") { withAnimation { pipeline.asks.set(question.id, .skipped) } }
                Button("的外れな質問") { withAnimation { pipeline.asks.set(question.id, .wrong) } }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func send() {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        withAnimation { pipeline.answerQuestion(question, with: answer) }
        text = ""
    }
}

/// 答えの候補のボタン（折り返して並べる）
private struct FlowChoices: View {
    let choices: [String]
    var onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(choices, id: \.self) { choice in
                Button(choice) { onPick(choice) }
                    .buttonStyle(.bordered)
                    .font(.callout)
            }
        }
    }
}

/// 答えた・飛ばした質問。取り消すと、また聞く質問に戻る。
private struct AnsweredRow: View {
    @Environment(Pipeline.self) private var pipeline
    let question: AskBook.Question
    @State private var registered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.question).font(.callout)
            switch question.state {
            case .answered: Text("→ " + (question.answer ?? "")).font(.callout).foregroundStyle(.blue)
            case .skipped: Text("分からない").font(.caption).foregroundStyle(.secondary)
            case .wrong: Text("的外れな質問").font(.caption).foregroundStyle(.secondary)
            case .open: EmptyView()
            }
            HStack(spacing: 20) {
                Button("取り消す") { withAnimation { pipeline.asks.set(question.id, .open) } }
                if question.state == .answered, question.kind == .word, let wrong = question.subject,
                   let right = question.answer, wrong != right, right.count <= 20 {
                    Button(registered ? "登録しました" : "「\(wrong)」→「\(right)」をこれからも直す") {
                        pipeline.registerFix(from: question)
                        registered = true
                    }
                    .disabled(registered)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }
}

/// わかったこと帳。直す・消す。
struct FactsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var editing: AskBook.Fact?
    @State private var draft = ""

    var body: some View {
        let facts = pipeline.asks.facts.sorted { $0.added > $1.added }
        List {
            if facts.isEmpty {
                Text("まだありません。「AI からの質問」に答えると、ここにたまります。").foregroundStyle(.secondary)
            }
            Section {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fact.text).font(.callout)
                        Text(fact.kind.label + "・" + AskBook.factDate.string(from: fact.added) + " に答えた")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("消す", role: .destructive) {
                            pipeline.asks.deleteFact(fact.id)
                            pipeline.asksChanged()
                        }
                        Button("直す") {
                            draft = fact.text
                            editing = fact
                        }
                    }
                }
            } footer: {
                Text("AI は、記録に出てくる言葉と関係するものだけを、確かなこととして使います。間違っていたら、左にずらして直すか消してください。ドライブの「わかったこと帳」にも写します。")
            }
        }
        .navigationTitle("わかったこと帳")
        .alert("わかったことを直す", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("わかったこと", text: $draft)
            Button("直す") {
                if var fact = editing {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        fact.text = text
                        fact.words = Array(Set(fact.words + AskBook.keywords(text))).sorted()
                        pipeline.asks.updateFact(fact)
                        pipeline.asksChanged()
                    }
                }
                editing = nil
            }
            Button("やめる", role: .cancel) { editing = nil }
        }
    }
}

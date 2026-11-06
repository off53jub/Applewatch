import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// 朝の読み上げ（2026-11-07）。前の日の1日のまとめ・今日の予定（会う人と前回の話）・今日までと期限を過ぎた頼まれごと・
/// 点検で気になったこと（文字起こし待ちなど）を、声で読める8つまでの短い文にする。
/// 夜の聞き直しの終わりと、5時を過ぎてアプリを開いたとき（まだ作っていなければ）に作る。
/// 言語モデルは短くまとめ直すのにだけ使う。職場の中身が入るときは、外のサービスに送らない設定のときだけ使い、
/// そうでなければ言語モデルを使わずに決まった形の文で作る。
/// 作った文は UserDefaults（morningBriefRecord）に日付つきで1つだけ残す。
enum MorningBrief {
    static let onKey = "morningBriefOn"
    static let timeKey = "morningBriefTime"
    static let maxSentences = 8
    static let noticeID = "morning-brief"

    /// 知らせるか（初めはオン）
    static var isOn: Bool { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
    /// 知らせる時刻（0時からの分。初めは7時）
    static var minutes: Int { UserDefaults.standard.object(forKey: timeKey) as? Int ?? 7 * 60 }

    struct EventLine: Equatable {
        /// 「10時」「13時30分」
        var time: String
        var title: String
        var people: [String] = []
        /// 前回の話（1文。無ければ nil）
        var note: String? = nil
    }

    struct Input: Equatable {
        /// その朝の日
        var date: Date
        var yesterdayTopics: [String] = []
        var yesterdayDecisions: [String] = []
        var yesterdayTodos: [String] = []
        var events: [EventLine] = []
        var dueToday: [String] = []
        var overdue: [String] = []
        /// 点検で気になったこと（1つずつ文になっているもの）
        var checks: [String] = []
    }

    private static let dateLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）"
        return f
    }()

    /// 文の終わりの「。」を除いた形（つなげて読むため）
    static func bare(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, "。．.！!？?".contains(last) { s.removeLast() }
        return s
    }

    /// 「10時」「13時30分」
    static func spokenTime(_ date: Date, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: date), m = calendar.component(.minute, from: date)
        return m == 0 ? "\(h)時" : "\(h)時\(m)分"
    }

    /// 言語モデルを使わずに作る形。8文まで
    static func template(_ input: Input) -> String {
        var s: [String] = ["おはようございます、今日は\(dateLabel.string(from: input.date))です。"]
        // 予定
        if input.events.isEmpty {
            s.append("今日の予定は、カレンダーに入っていません。")
        } else {
            s.append("今日の予定は\(input.events.count)件です。")
            for event in input.events.prefix(2) {
                var line = event.time + "から" + bare(event.title)
                if !event.people.isEmpty {
                    line += "、" + event.people.prefix(3).map(WatchInfo.politeName).joined(separator: "、") + "と"
                }
                s.append(line + "。")
                if let note = event.note, !bare(note).isEmpty { s.append(bare(note) + "。") }
            }
        }
        // 頼まれごと
        if !input.dueToday.isEmpty || !input.overdue.isEmpty {
            var line = "頼まれごとは、今日までが\(input.dueToday.count)件"
            if !input.overdue.isEmpty { line += "、期限を過ぎたものが\(input.overdue.count)件" }
            s.append(line + "です。")
            if let first = (input.overdue + input.dueToday).first { s.append("まず「\(bare(first))」から。") }
        }
        // 前の日
        if !input.yesterdayTopics.isEmpty {
            s.append("昨日は、" + input.yesterdayTopics.prefix(3).map(bare).joined(separator: "、") + "の話をしました。")
        }
        if let decision = input.yesterdayDecisions.first {
            s.append("決まったことは、" + bare(decision) + "。")
        }
        // 点検
        for check in input.checks { s.append(bare(check) + "。") }
        return s.prefix(maxSentences).joined()
    }

    /// 言語モデルに渡す材料（箇条書き）
    static func material(_ input: Input) -> String {
        var lines: [String] = ["今日の日付: " + dateLabel.string(from: input.date)]
        if input.events.isEmpty {
            lines.append("今日の予定: なし")
        } else {
            lines.append("今日の予定:")
            for event in input.events.prefix(6) {
                var line = "・" + event.time + "から " + event.title
                if !event.people.isEmpty { line += "（会う人: " + event.people.prefix(4).joined(separator: "、") + "）" }
                if let note = event.note { line += "（前回: " + note + "）" }
                lines.append(line)
            }
        }
        if !input.overdue.isEmpty {
            lines.append("期限を過ぎた頼まれごと:")
            lines += input.overdue.prefix(5).map { "・" + $0 }
        }
        if !input.dueToday.isEmpty {
            lines.append("今日までの頼まれごと:")
            lines += input.dueToday.prefix(5).map { "・" + $0 }
        }
        if !input.yesterdayTopics.isEmpty { lines.append("昨日の話題: " + input.yesterdayTopics.prefix(5).joined(separator: "、")) }
        if !input.yesterdayDecisions.isEmpty {
            lines.append("昨日決まったこと:")
            lines += input.yesterdayDecisions.prefix(3).map { "・" + $0 }
        }
        if !input.yesterdayTodos.isEmpty {
            lines.append("昨日出たやること:")
            lines += input.yesterdayTodos.prefix(3).map { "・" + $0 }
        }
        if !input.checks.isEmpty {
            lines.append("気をつけること:")
            lines += input.checks.map { "・" + $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// 文に分ける（「。」「！」「？」と改行で区切る）
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            if ch == "\n" {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { result.append(t) }
                current = ""
                continue
            }
            current.append(ch)
            if "。！？!?".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { result.append(t) }
                current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { result.append(t) }
        return result
    }

    /// 言語モデルの答えを、読み上げる形に整える（頭の「・」や番号を除き、8文まで）。使えなければ nil
    static func tidy(_ text: String) -> String? {
        // 「記録に見つかりませんでした」などの答えは使わない
        guard !text.contains("見つかりませんでした") else { return nil }
        let bullets: Set<Character> = ["・", "-", "*", "•", "●", "◆", "■", " ", "　"]
        let parts = sentences(text).map { part -> String in
            var out = part
            while let first = out.first, bullets.contains(first) { out.removeFirst() }
            // 頭の番号（「1.」「２）」など）
            if let range = out.range(of: "^[0-9０-９]+[.)．）、]\\s*", options: .regularExpression) {
                out.removeSubrange(range)
            }
            out = out.trimmingCharacters(in: .whitespaces)
            if let last = out.last, !"。！？!?".contains(last) { out += "。" }
            return out
        }.filter { $0.count >= 2 }
        // 1文だけの答えは、まとめになっていないとみなす
        guard parts.count >= 2 else { return nil }
        return parts.prefix(maxSentences).joined()
    }

    /// 通知に出す、はじめの2文
    static func headline(_ text: String) -> String {
        sentences(text).prefix(2).joined()
    }
}

/// 作った朝の読み上げ（1つだけ持つ）
struct MorningBriefRecord: Codable, Equatable {
    /// どの日の朝の分か（yyyy-MM-dd）
    var day: String
    var text: String
    var made: Date
    /// 前の日の1日のまとめが入っているか（まだ無いときに作ったら、まとめができたあとで作り直す）
    var hadSummary: Bool? = nil
    /// 言語モデルでまとめたか
    var usedModel: Bool? = nil
}

@MainActor
@Observable
final class MorningBriefStore {
    static let shared = MorningBriefStore()
    static let key = "morningBriefRecord"

    private(set) var current: MorningBriefRecord?
    /// 作っている最中か
    var making = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            current = try? JSONDecoder().decode(MorningBriefRecord.self, from: data)
        }
    }

    func save(_ record: MorningBriefRecord) {
        current = record
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// 文を日本語の声で読み上げる（iPhone）。録音の音の設定を変えないよう、読み上げは自分の音の設定で鳴らす
@MainActor
@Observable
final class BriefReader: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = BriefReader()
    private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = false
    }

    func toggle(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            speaking = false
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        synthesizer.speak(utterance)
        speaking = true
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

private let briefDayKey: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private let briefNoteDate: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ja_JP")
    f.dateFormat = "M月d日"
    return f
}()

extension Pipeline {
    /// 夜の聞き直しの終わりに呼ぶ。昼より後なら次の日の朝の分、昼より前ならその日の分を作る
    func makeMorningBriefAtNight() async {
        let cal = Calendar.current
        let now = Date.now
        let today = cal.startOfDay(for: now)
        let target = cal.component(.hour, from: now) >= 12 ? (cal.date(byAdding: .day, value: 1, to: today) ?? today) : today
        await makeMorningBrief(for: target)
    }

    /// アプリを開いたときに呼ぶ。5時を過ぎていて、今日の分がまだ（か、前の日のまとめができる前に作った）なら作る
    func morningBriefOnActive() {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: .now)
        defer { pushWatchInfo() }
        guard hour >= 5, hour < 22 else { return }
        Task { await makeMorningBrief(for: cal.startOfDay(for: .now)) }
    }

    /// その日の朝の分を作る必要があるか
    func needsMorningBrief(for day: Date) -> Bool {
        let key = briefDayKey.string(from: day)
        guard let current = MorningBriefStore.shared.current, current.day == key else { return true }
        // 前の日のまとめが無いときに作ったなら、まとめができていれば作り直す
        guard current.hadSummary != true,
              let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day) else { return false }
        return daySummary(briefDayKey.string(from: yesterday)) != nil
    }

    /// 朝の読み上げを作って残し、知らせを頼み、時計にも送る。force なら作り直す
    func makeMorningBrief(for day: Date, force: Bool = false) async {
        let store = MorningBriefStore.shared
        guard !store.making, force || needsMorningBrief(for: day) else { return }
        store.making = true
        defer { store.making = false }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let (input, work, hadSummary) = morningBriefInput(for: start)
        var text = MorningBrief.template(input)
        var usedModel = false
        // 言語モデルで短くまとめ直す。職場の中身が入るときは、外のサービスに送らない設定のときだけ
        if let key = llmKey {
            let staysInside = Summarizer.$sensitive.withValue(true) { Summarizer.usesLocal(apiKey: key) }
            if !work || staysInside {
                let question = "この材料を、朝に声で読み上げる文にしてください。です・ます調の短い文を8つまで、1つの文は40文字くらいまで。"
                    + "今日の予定、期限を過ぎた・今日までの頼まれごと、昨日のこと、気をつけること、の順に。"
                    + "材料に無いことは足さず、記号や箇条書きは使わないでください。"
                let material = MorningBrief.material(input)
                let result = try? await Summarizer.$sensitive.withValue(work) {
                    try await Summarizer.answer(question, material: material, apiKey: key)
                }
                if let result, let tidy = MorningBrief.tidy(result.text) {
                    text = tidy
                    usedModel = true
                }
            }
        }
        store.save(MorningBriefRecord(day: briefDayKey.string(from: start), text: text, made: .now,
                                      hadSummary: hadSummary, usedModel: usedModel))
        await scheduleMorningBriefNotice()
        pushWatchInfo(force: true)
    }

    /// 材料を集める。work は職場の中身が入るか、hadSummary は前の日の1日のまとめがあったか
    func morningBriefInput(for start: Date) -> (input: MorningBrief.Input, work: Bool, hadSummary: Bool) {
        let cal = Calendar.current
        var input = MorningBrief.Input(date: start)
        var work = false
        // 前の日
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: start) ?? start
        let yesterday = briefDayKey.string(from: yesterdayStart)
        let summary = daySummary(yesterday)
        if let summary {
            input.yesterdayTopics = Array(summary.topics.prefix(5))
            input.yesterdayDecisions = Array(summary.decisions.prefix(3))
            input.yesterdayTodos = Array(summary.todos.prefix(3))
            if conversations(on: yesterday).contains(where: { isWorkTime($0.start) }) { work = true }
        }
        // 今日の予定
        let events = calendar.dayEvents(from: start, to: start.addingTimeInterval(24 * 3600))
            .filter { cal.isDate($0.start, inSameDayAs: start) }
        for event in events.prefix(8) {
            if event.isWork || isWorkTime(event.start) { work = true }
            let found = eventPeople(event)
            input.events.append(MorningBrief.EventLine(time: MorningBrief.spokenTime(event.start, calendar: cal),
                                                       title: event.title.isEmpty ? "予定" : event.title,
                                                       people: Array(found.all.prefix(4)),
                                                       note: lastTalkNote(for: found.known, before: .now)))
        }
        // 頼まれごと（その日までのもの・過ぎたもの。人に頼んで待っているものは除く）
        for item in tasks.todo {
            switch TaskBook.bucket(item, now: start, calendar: cal) {
            case .late:
                input.overdue.append(item.what)
            case .today:
                input.dueToday.append(item.what)
            default:
                continue
            }
            if item.work == true { work = true }
        }
        // 点検
        if pendingCount > 0 { input.checks.append("iPhone に文字起こし待ちが\(pendingCount)件あります") }
        let waiting = tasks.candidates.count
        if waiting > 0 { input.checks.append("頼まれごとの確かめ待ちが\(waiting)件あります") }
        return (input, work, summary != nil)
    }

    /// 会う人と前回話したことを1文で（「田中さんとは、前回11月5日に「見積もりの件」を話しました」）
    private func lastTalkNote(for names: [String], before: Date) -> String? {
        for day in recordedDays().prefix(60) {
            for c in conversations(on: day).reversed() where c.closed && c.media == nil && c.start < before {
                guard let name = names.first(where: { c.people.contains($0) }) else { continue }
                let when = briefNoteDate.string(from: c.start)
                if let title = c.title, !title.isEmpty {
                    return "\(WatchInfo.politeName(name))とは、前回\(when)に「\(MorningBrief.bare(title))」を話しました"
                }
                return "\(WatchInfo.politeName(name))とは、前回\(when)に話しました"
            }
        }
        return nil
    }

    /// 朝の読み上げの知らせを、決めた時刻（初めは7時）に頼む。もう過ぎていれば頼まない。iPad では出さない（二重にならないように）
    func scheduleMorningBriefNotice() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [MorningBrief.noticeID])
        guard MorningBrief.isOn, UIDevice.current.userInterfaceIdiom != .pad,
              let record = MorningBriefStore.shared.current,
              let day = briefDayKey.date(from: record.day) else { return }
        let at = day.addingTimeInterval(TimeInterval(MorningBrief.minutes * 60))
        guard at > Date.now.addingTimeInterval(30) else { return }
        let content = UNMutableNotificationContent()
        content.title = "朝の読み上げ"
        content.body = MorningBrief.headline(record.text)
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        try? await center.add(UNNotificationRequest(
            identifier: MorningBrief.noticeID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}

// MARK: - 画面

/// 「今日」の朝の読み上げ（今日か明日の分があるときだけ）
struct MorningBriefSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let store = MorningBriefStore.shared
        let reader = BriefReader.shared
        let today = briefDayKey.string(from: .now)
        if let record = store.current, record.day >= today {
            Section {
                Text(record.text)
                    .font(.callout)
                Button {
                    reader.toggle(record.text)
                } label: {
                    Label(reader.speaking ? "止める" : "読み上げる",
                          systemImage: reader.speaking ? "stop.circle" : "speaker.wave.2")
                }
                Button {
                    Task { await pipeline.makeMorningBrief(for: Calendar.current.startOfDay(for: .now), force: true) }
                } label: {
                    if store.making {
                        ProgressView()
                    } else {
                        Label("今日の分を作り直す", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.making)
            } header: {
                Text(record.day == today ? "朝の読み上げ" : "朝の読み上げ（明日の分）")
            } footer: {
                Text(record.made.formatted(date: .abbreviated, time: .shortened) + " に作りました"
                     + (record.usedModel == true ? "（言語モデルで短くしました）" : ""))
            }
        }
    }
}

/// 設定の「朝の読み上げを知らせる」と時刻
struct MorningBriefSettingsRows: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(MorningBrief.onKey) private var on = true
    @AppStorage(MorningBrief.timeKey) private var minutes = 7 * 60

    var body: some View {
        Toggle("朝の読み上げを知らせる", isOn: $on)
            .onChange(of: on) { Task { await pipeline.scheduleMorningBriefNotice() } }
        if on {
            DatePicker("朝の読み上げの時刻", selection: time, displayedComponents: .hourAndMinute)
                .onChange(of: minutes) { Task { await pipeline.scheduleMorningBriefNotice() } }
        }
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes * 60))
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
        }
    }
}

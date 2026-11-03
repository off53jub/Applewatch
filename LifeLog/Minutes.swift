import SwiftUI
import UIKit

/// 会議の議事録。職場の予定の時間の長い会話（または選んだ会話）を、議題ごとの要点・決まったこと・宿題・次回の
/// 議事録にして、ドライブの「議事録 日付 時刻 予定名」というドキュメントに書く。
/// 職場の会話は、「職場の会話は端末内で」のとき iPhone の中の言語モデルで作る（外に送らない）。
extension Pipeline {
    static let autoMinutesKey = "autoMinutes"
    /// 職場の予定の時間の会話は、自動で議事録を作る（初めはオン）
    static var autoMinutesOn: Bool { UserDefaults.standard.object(forKey: autoMinutesKey) as? Bool ?? true }
    /// 自動で作る会議の長さと、文字の量の下限
    private static let minutesMinimum: TimeInterval = 15 * 60
    private static let minutesCharacters = 1_500

    private static let minutesDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) H:mm"
        return f
    }()
    private static let minutesTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()
    private static let minutesName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    /// 自動で議事録を作る会議か（職場の予定と重なる、15分以上の、文字の多い会話）
    func isMeeting(_ c: ConversationLog.Conversation) -> Bool {
        guard c.closed, c.media == nil, c.minutes == nil, c.end.timeIntervalSince(c.start) >= Self.minutesMinimum,
              c.lines.reduce(0, { $0 + $1.text.count }) >= Self.minutesCharacters else { return false }
        guard let event = calendar.events(from: c.start, to: c.end).first else { return false }
        return event.isWork || (isWorkTime(c.start) && !event.attendees.isEmpty)
    }

    /// まだ議事録の無い会議を、1つだけ議事録にする（長い処理なので、アプリを開いているか充電中のときだけ）。
    func writePendingMinutes() async {
        guard Self.autoMinutesOn, summariesOn, llmKey != nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let charging = [.charging, .full].contains(UIDevice.current.batteryState)
        guard UIApplication.shared.applicationState == .active || charging else { return }
        for day in recordedDays().prefix(7) {
            for c in conversations(on: day) where isMeeting(c) {
                _ = await writeMinutes(for: c, day: day)
                return
            }
        }
    }

    /// 会話の議事録を作って、ドキュメントに書く。書いたドキュメントの名前か、できなかった理由を返す。
    func writeMinutes(for c: ConversationLog.Conversation, day: String) async -> Result<String, Error> {
        guard let key = llmKey else {
            return .failure(CloudTranscriber.Failure.rejected("Groq のキーを入れるか、iPhone の中の言語モデルを使えるようにしてください。"))
        }
        let lines = c.lines.filter { $0.media == nil }
        let transcript = lines.map { line in
            Self.minutesTime.string(from: line.time) + " " + (line.speaker.map { "[\($0)] " } ?? "") + line.text
        }.joined(separator: "\n")
        let event = calendar.events(from: c.start, to: c.end).first
        var attendees = [SpeakerLabeler.selfName] + c.people.filter { !$0.hasPrefix("人物") }
        for name in event?.attendees ?? [] where !attendees.contains(where: { Self.sameName($0, name) }) { attendees.append(name) }
        let range = Self.minutesTime.string(from: c.start) + "〜" + Self.minutesTime.string(from: c.end)
        let made: Summarizer.Minutes
        do {
            made = try await Summarizer.$sensitive.withValue(isWorkTime(c.start)) {
                try await Summarizer.minutes(transcript, timeRange: range, event: event?.title, attendees: attendees, apiKey: key)
            }
        } catch {
            return .failure(error)
        }

        let title = (event?.title).flatMap { $0.isEmpty ? nil : $0 } ?? c.title ?? "会議"
        let name = "議事録 " + Self.minutesName.string(from: c.start) + " " + title
        var body = "日時: " + Self.minutesDay.string(from: c.start) + "〜" + Self.minutesTime.string(from: c.end) + "\n"
        if let place = c.place { body += "場所: " + place + "\n" }
        body += "出席者: " + attendees.joined(separator: "、") + "（声で分かった人と予定の参加者）\n"
        if !made.purpose.isEmpty { body += "目的: " + made.purpose + "\n" }
        body += "\n"
        for topic in made.topics {
            body += "● " + topic.title + "\n" + topic.points.map { "・" + $0 + "\n" }.joined()
        }
        if !made.decisions.isEmpty {
            body += "\n◆ 決まったこと\n" + made.decisions.map { "・" + $0 + "\n" }.joined()
        }
        if !made.todos.isEmpty {
            body += "\n◆ 宿題\n" + made.todos.map { todo in
                "・" + (todo.who.isEmpty ? "" : todo.who + "：") + todo.what + (todo.due.isEmpty ? "" : "（\(todo.due)まで）") + "\n"
            }.joined()
        }
        if !made.next.isEmpty { body += "\n◆ 次回\n・" + made.next + "\n" }
        body += "\n（文字起こしは「\(day)」のドキュメントの \(range) の会話。自動で作った議事録なので、聞き間違いや抜けがあります）\n"
        do {
            try await writeDocument(heading: "議事録　" + title, body: body, name: name)
        } catch {
            return .failure(error)
        }
        markMinutes(name, start: c.start, day: day)
        return .success(name)
    }
}

/// その日の会話から、議事録を作る会話を選ぶ画面
struct MinutesView: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String
    @State private var list: [ConversationLog.Conversation] = []
    @State private var working: Date?
    @State private var notes: [Date: String] = [:]
    @AppStorage("autoMinutes") private var auto = true

    var body: some View {
        List {
            Section {
                Toggle("職場の予定の会話は自動で作る", isOn: $auto)
            } footer: {
                Text("職場のカレンダーの予定（または職場にいた時間の参加者のいる予定）と重なる、15分以上の会話を、アプリを開いたときか充電中に1つずつ議事録にします。ドライブの「LifeLog」に「議事録 日付 時刻 予定名」のドキュメントを作ります。「職場の会話は端末内で」にしていれば、iPhone の中の言語モデルで作り、外に送りません。")
            }
            Section("この日の会話（5分以上）") {
                ForEach(list, id: \.start) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ConversationLog.headingText(c)).font(.callout)
                        if let name = c.minutes { Text("作った: " + name).font(.caption).foregroundStyle(.secondary) }
                        if let note = notes[c.start] { Text(note).font(.caption).foregroundStyle(.secondary) }
                        if working == c.start {
                            HStack { ProgressView(); Text("作っています…（長い会議は数分かかります）").font(.caption) }
                        } else {
                            Button(c.minutes == nil ? "議事録を作る" : "作り直す") { make(c) }
                                .disabled(working != nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("議事録")
        .onAppear { reload() }
    }

    private func reload() {
        list = pipeline.conversations(on: day).filter { $0.closed && $0.media == nil && $0.end.timeIntervalSince($0.start) >= 300 }
    }

    private func make(_ c: ConversationLog.Conversation) {
        working = c.start
        Task {
            switch await pipeline.writeMinutes(for: c, day: day) {
            case .success(let name): notes[c.start] = "ドライブの「\(name)」に書きました。"
            case .failure(let error): notes[c.start] = "作れませんでした: \(error.localizedDescription)"
            }
            working = nil
            reload()
        }
    }
}

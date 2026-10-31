import Foundation

/// 文字起こしの行を「会話」にまとめる。話が3分以上途切れたら1つの会話の終わりとみなし、
/// その会話の頭に「時刻・場所・相手・見出し」と要点を差し込む。日が変わったら、前の日の
/// ドキュメントの先頭に1日のまとめを付ける。会話の中身はアプリの中にも日ごとの JSON で残す。
@MainActor
final class ConversationLog {
    struct Line: Codable {
        let time: Date
        let speaker: String?
        let text: String
        /// 聞き直し用の音声ファイル名と、その中での位置（秒）。古い記録には無い。
        var audio: String? = nil
        var offset: TimeInterval? = nil
        /// 言語モデルで直す前の文字起こし（直していなければ nil）
        var original: String? = nil
    }

    struct Conversation: Codable {
        var start: Date
        var end: Date
        /// ドキュメントの中で、この会話の最初の行が始まる位置。見出しはここに差し込む。
        var docIndex: Int
        var lines: [Line] = []
        var title: String?
        var points: [String] = []
        var place: String?
        /// 人物ノートに書き足したか（この項目が無かったころの記録は nil）
        var notesWritten: Bool?
        var closed = false

        var people: [String] {
            var seen: [String] = []
            for name in lines.compactMap(\.speaker) where name != SpeakerLabeler.selfName && !seen.contains(name) {
                seen.append(name)
            }
            return seen
        }
    }

    struct Day: Codable {
        var conversations: [Conversation] = []
        var summaryWritten = false
    }

    /// これだけ話が途切れたら、別の会話とみなす
    static let gap: TimeInterval = 180
    /// 短すぎる会話（テレビの音や独り言など）には見出しを付けない
    private static let minimumCharacters = 80

    private let docs: GoogleDocs
    /// 要約に使う Groq のキー。nil なら見出しは時刻と相手だけにする。
    var apiKey: () -> String? = { nil }
    /// その時刻にいた場所の名前（場所の記録がオフなら nil）
    var placeName: (Date) async -> String? = { _ in nil }

    init(docs: GoogleDocs) {
        self.docs = docs
    }

    private static let dir: URL = {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("days", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - 追記

    /// 行をドキュメントに追記し、会話として記録する。
    func append(_ lines: [Line], text: String, day: String) async throws {
        guard let first = lines.first else { return }
        await closeOpenConversations(before: first.time, day: day)

        var log = load(day)
        if log.conversations.last?.closed ?? true {
            let index = try await docs.endIndex(day: day)
            log.conversations.append(Conversation(start: first.time, end: first.time, docIndex: index))
            save(log, day: day)
        }
        try await docs.append(text, day: day)
        log.conversations[log.conversations.count - 1].lines += lines
        log.conversations[log.conversations.count - 1].end = lines.last?.time ?? first.time
        save(log, day: day)
    }

    /// しばらく何も話していなければ、続いている会話を閉じる。
    /// 録音中の区切り（最長5分）にまだ続きがあるかもしれないので、その分も待つ。
    func closeIdle(now: Date, waiting: TimeInterval) async {
        await closeOpenConversations(before: now.addingTimeInterval(-waiting), day: nil)
    }

    private func closeOpenConversations(before time: Date, day: String?) async {
        for openDay in days() {
            var log = load(openDay)
            guard let i = log.conversations.indices.last, !log.conversations[i].closed else { continue }
            let conversation = log.conversations[i]
            let sameDay = day == nil || day == openDay
            guard !sameDay || time.timeIntervalSince(conversation.end) > Self.gap else { continue }
            if let closed = await close(conversation, day: openDay) {
                log.conversations[i] = closed
                save(log, day: openDay)
            }
        }
    }

    /// 見出しと要点を会話の頭に差し込む。差し込めなかったら nil（次の機会にやり直す）。
    private func close(_ conversation: Conversation, day: String) async -> Conversation? {
        var result = conversation
        result.closed = true
        result.place = await placeName(conversation.start)
        let transcript = conversation.lines.map { line in
            (line.speaker.map { "[\($0)] " } ?? "") + line.text
        }.joined(separator: "\n")
        guard transcript.count >= Self.minimumCharacters else { return result }

        let range = "\(timeFormatter.string(from: conversation.start))〜\(timeFormatter.string(from: conversation.end))"
        if let key = apiKey() {
            if let summary = try? await Summarizer.conversation(transcript, timeRange: range, apiKey: key) {
                result.title = summary.title
                result.points = summary.points
            }
        }
        var heading = range
        if let place = result.place { heading += "　" + place }
        if !conversation.people.isEmpty { heading += "　" + conversation.people.joined(separator: "、") + "と" }
        if let title = result.title, !title.isEmpty { heading += "　" + title }
        let body = result.points.map { "・" + $0 + "\n" }.joined()
        do {
            try await docs.insert(heading: heading, body: body, at: conversation.docIndex, style: "HEADING_2", day: day)
            return result
        } catch {
            return nil
        }
    }

    // MARK: - 不具合の後始末

    /// 誤変換を直す処理が「1行目の直した文」のような見本の文を返し、本文が置き換わってしまった行を、
    /// 残しておいた元の文に戻す。名前の無い声が「Speaker 4」と出ていたのも「人物4」に戻す。
    /// アプリの記録とドキュメントの両方を直し、最後に「人物ノート - Speaker …」を片付ける。一度だけ動く。
    func repairBrokenLines() async {
        let doneKey = "repair-placeholder-lines"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        for day in days() {
            var log = load(day)
            var fixes: [(find: String, replace: String)] = []
            var renamed: [String: String] = [:]
            for c in log.conversations.indices {
                for l in log.conversations[c].lines.indices {
                    let line = log.conversations[c].lines[l]
                    let broken = line.original != nil
                        && line.text.range(of: #"^\d+\s*行目の直した文"#, options: .regularExpression) != nil
                    var speaker = line.speaker
                    if let name = speaker, name.hasPrefix("Speaker ") {
                        speaker = "人物" + name.dropFirst("Speaker ".count)
                        renamed[name] = speaker
                    }
                    guard broken || speaker != line.speaker else { continue }
                    let text = broken ? line.original ?? line.text : line.text
                    if broken {
                        let head = clock.string(from: line.time) + "  " + (line.speaker.map { "[\($0)] " } ?? "")
                        fixes.append((find: head + line.text, replace: head + text))
                    }
                    log.conversations[c].lines[l] = Line(
                        time: line.time, speaker: speaker, text: text, audio: line.audio,
                        offset: line.offset, original: broken ? nil : line.original)
                }
            }
            guard !fixes.isEmpty || !renamed.isEmpty else { continue }
            // 見出しの「Speaker 4と」も直すので、括弧なしで置き換える（「Speaker 41」も「人物41」になる）
            fixes += renamed.map { (find: $0.key, replace: $0.value) }
            do {
                try await docs.replaceAll(fixes, day: day)
            } catch {
                // 通信できないときは次の機会にやり直す
                return
            }
            save(log, day: day)
        }
        guard (try? await docs.trashFiles(namedWithPrefix: Self.notePrefix + "Speaker ")) != nil else { return }
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    // MARK: - 人物ノート

    /// 名前を付けた相手ごとに「人物ノート - 名前」というドキュメントを作り、
    /// 閉じた会話を新しい順に書き足す。「人物3」のように名前の無い人は書かない。
    func writePeopleNotes() async {
        for day in days() {
            var log = load(day)
            for i in log.conversations.indices {
                let c = log.conversations[i]
                guard c.closed, c.notesWritten != true else { continue }
                let total = c.lines.reduce(0) { $0 + $1.text.count }
                for name in c.people where !name.hasPrefix("人物") && !name.hasPrefix("Speaker ")
                    && total >= Self.minimumCharacters {
                    let note = Self.note(for: name, in: c, day: day)
                    do {
                        try await docs.insert(heading: note.heading, body: note.body, at: 1,
                                              style: "HEADING_3", day: Self.notePrefix + name)
                    } catch {
                        // 通信できないときは次の機会にやり直す
                        return
                    }
                }
                log.conversations[i].notesWritten = true
                save(log, day: day)
            }
        }
    }

    static let notePrefix = "人物ノート - "

    private static let noteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) HH:mm"
        return f
    }()

    private static let noteTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func note(for name: String, in c: Conversation, day: String) -> (heading: String, body: String) {
        var heading = noteDateFormatter.string(from: c.start) + "〜" + noteTimeFormatter.string(from: c.end)
        if let place = c.place { heading += "　" + place }
        if let title = c.title, !title.isEmpty { heading += "　" + title }
        var body = ""
        let others = c.people.filter { $0 != name }
        if !others.isEmpty { body += "一緒にいた人: " + others.joined(separator: "、") + "\n" }
        if !c.points.isEmpty {
            body += c.points.map { "・" + $0 + "\n" }.joined()
        } else {
            // 要約が無いときは、その人の発言を少しだけ載せる
            body += c.lines.filter { $0.speaker == name }.prefix(3).map { "「" + $0.text + "」\n" }.joined()
        }
        body += "（\(day) のドキュメント）\n\n"
        return (heading, body)
    }

    // MARK: - 1日のまとめ

    /// 今日より前で、会話がすべて閉じていて、まだまとめを付けていない日に、まとめを付ける。
    func writeDailySummaries(today: String) async {
        guard let key = apiKey() else { return }
        for day in days() where day < today {
            var log = load(day)
            guard !log.summaryWritten, !log.conversations.isEmpty,
                  log.conversations.allSatisfy(\.closed) else { continue }
            guard log.conversations.contains(where: { $0.title != nil }) else {
                log.summaryWritten = true
                save(log, day: day)
                continue
            }
            // 1日の流れのために、見出しの無い短い会話も時刻と場所だけは渡す
            let overview = log.conversations.map { c in
                let place = c.place.map { "・" + $0 } ?? ""
                let people = c.people.isEmpty ? "" : "（\(c.people.joined(separator: "、"))と）"
                let head = "\(timeFormatter.string(from: c.start))〜\(timeFormatter.string(from: c.end))\(place)\(people) \(c.title ?? "（短い会話）")"
                return ([head] + c.points.map { "  ・" + $0 }).joined(separator: "\n")
            }.joined(separator: "\n")
            guard let summary = try? await Summarizer.day(overview, apiKey: key) else { continue }

            let people = Array(NSOrderedSet(array: log.conversations.flatMap(\.people))) as? [String] ?? []
            var body = ""
            func section(_ name: String, _ items: [String]) {
                guard !items.isEmpty else { return }
                body += name + "\n" + items.map { "・" + $0 + "\n" }.joined()
            }
            section("1日の流れ", summary.flow)
            body += "会った人: " + (people.isEmpty ? "なし" : people.joined(separator: "、")) + "\n"
            section("決まったこと", summary.decisions)
            section("やること", summary.todos)
            section("話題", summary.topics)
            body += "\n"
            do {
                try await docs.insert(heading: "1日のまとめ", body: body, at: 1, style: "HEADING_1", day: day)
                log.summaryWritten = true
                save(log, day: day)
            } catch {
                continue
            }
        }
    }

    // MARK: - アプリで見る

    func recordedDays() -> [String] { days().reversed() }

    func conversations(on day: String) -> [Conversation] { load(day).conversations }

    // MARK: - 保存

    private func days() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func load(_ day: String) -> Day {
        guard let data = try? Data(contentsOf: Self.dir.appendingPathComponent(day + ".json")),
              let log = try? JSONDecoder().decode(Day.self, from: data) else { return Day() }
        return log
    }

    private func save(_ log: Day, day: String) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: Self.dir.appendingPathComponent(day + ".json"), options: .atomic)
    }
}

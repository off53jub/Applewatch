import Foundation

/// 文字起こしの行を「会話」にまとめる。話が3分以上途切れたら1つの会話の終わりとみなし、
/// その会話の頭に「時刻・場所・相手・見出し」と要点を差し込む。日が変わったら、前の日の
/// ドキュメントの先頭に1日のまとめを付ける。会話の中身はアプリの中にも日ごとの JSON で残す。
@MainActor
final class ConversationLog {
    struct Line: Codable {
        let time: Date
        var speaker: String?
        var text: String
        /// 聞き直し用の音声ファイル名と、その中での位置（秒）。古い記録には無い。
        var audio: String? = nil
        var offset: TimeInterval? = nil
        /// 言語モデルで直す前の文字起こし（直していなければ nil）
        var original: String? = nil
        /// 話者の聞き分けでの、その人の番号（自分は "me"）。古い記録には無い。
        var speakerID: String? = nil
        /// 時計やアプリで「印」を付けたところ
        var marked: Bool? = nil
        /// 聞き取りの確からしさ（0〜1。2つの聞き取りの合い方など）。分からなければ nil
        var confidence: Double? = nil

        /// 手で文字を直した行（夜の聞き直しでも変えない）
        var checked: Bool? = nil

        /// 会話ではなく、テレビ・CM・ドラマ・動画・ラジオ・放送の声だった行なら、その種類（話した人の名前にもなる）
        var media: String? = nil
        /// 放送の行と見分ける前の、話した人の名前と番号（見分け違いを戻すため）
        var heardSpeaker: String? = nil
        var heardSpeakerID: String? = nil
        /// その行のあいだ聞こえていた背景の音（音楽・電車・拍手・笑い・テレビ）
        var sound: String? = nil

        /// 確からしさが低く、聞き直して確かめたほうがよい行
        var isUncertain: Bool { checked != true && (confidence ?? 1) < 0.45 }
    }

    /// 行の文字の直し
    struct TextChange {
        let line: Line
        let text: String
        /// 直したあとの確からしさ
        let confidence: Double?
        /// 手で直したか
        let manual: Bool
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// ドキュメントに書く1行（改行なし）。例: 「14:05:12  ★ [田中] じゃあ来週の…」
    static func docLine(_ line: Line) -> String {
        clock.string(from: line.time) + "  " + (line.marked == true ? "★ " : "")
            + (line.speaker.map { "[\($0)] " } ?? "") + line.text
    }

    /// 印の前後これだけの行に「★」を付ける
    static let markSpan: TimeInterval = 60

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
        /// テレビ・動画・ラジオ・音楽を流していた（会話ではない）なら、その種類
        var media: String?
        /// 番組名・動画の題名
        var program: String?
        /// その時間のカレンダーの予定
        var event: String?
        /// 移動の様子（「歩きながら」など）
        var movement: String?
        /// 端末間の同期で、どちらが新しいかを決める番号。中身が変わるたびに1つ増える（以前の記録は nil で、0 とみなす）
        var rev: Int?

        /// 話した相手。テレビや動画の声は相手に数えない。
        var people: [String] {
            guard media == nil else { return [] }
            var seen: [String] = []
            for name in lines.filter({ $0.media == nil }).compactMap(\.speaker)
            where name != SpeakerLabeler.selfName && !seen.contains(name) {
                seen.append(name)
            }
            return seen
        }
    }

    struct Day: Codable {
        var conversations: [Conversation] = []
        var summaryWritten = false
        /// 1日のまとめの中身（週のまとめに使う）
        var summary: Summarizer.Day?
        /// 消した会話（端末間の同期で、ほかの端末にも消したと伝える）。会話の始まりの時刻と、消したときの番号。
        var removed: [Removed]?
    }

    struct Removed: Codable {
        let start: Date
        let rev: Int
    }

    /// 端末間の同期で、ほかの端末に渡す1日分（閉じた会話だけ）
    struct SyncDay: Codable {
        var conversations: [Conversation]
        var removed: [Removed]
        var summaryWritten: Bool
        var summary: Summarizer.Day?
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
    /// その時間のカレンダーの予定（名前と、要約に渡す説明）
    var eventInfo: (Date, Date) async -> (name: String, detail: String)? = { _, _ in nil }
    /// その時間の移動の様子
    var movementName: (Date, Date) async -> String? = { _, _ in nil }
    /// 会話の書き方をそろえるときの「正しい書き方の候補」（登録した言葉・人の名前・人ごとの言葉）
    var spellingHints: (Conversation) async -> [String] = { _ in [] }
    /// その日の過ごし方（1日のまとめの「1日の流れ」に使う）
    var dayActivities: (String) async -> [Activity] = { _ in [] }
    /// テレビや動画だった会話で、名前の無い声として覚えてしまった番号（忘れてもらう）
    var forgetVoices: @MainActor (Set<String>) async -> Void = { _ in }

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
        // 続いている会話はこの端末のもの（ほかの端末からは閉じた会話しか来ない）
        if log.conversations.lastIndex(where: { !$0.closed }) == nil {
            let index = try await docs.endIndex(day: day)
            log.conversations.append(Conversation(start: first.time, end: first.time, docIndex: index))
            save(log, day: day)
            log = load(day)
        }
        try await docs.append(text, day: day)
        // 書いているあいだに同期で会話が増えていてもよいように、読み直してから足す
        log = load(day)
        guard let i = log.conversations.lastIndex(where: { !$0.closed }) else { return }
        log.conversations[i].lines += lines
        log.conversations[i].end = lines.last?.time ?? first.time
        save(log, day: day)
    }

    /// しばらく何も話していなければ、続いている会話を閉じる。
    /// 録音中の区切り（最長5分）にまだ続きがあるかもしれないので、その分も待つ。
    func closeIdle(now: Date, waiting: TimeInterval) async {
        await closeOpenConversations(before: now.addingTimeInterval(-waiting), day: nil)
    }

    /// 閉じたばかりの会話（話者のまとめ直しに使う）。受け取ったら空にする。
    private var justClosed: [Conversation] = []

    func takeClosed() -> [Conversation] {
        defer { justClosed = [] }
        return justClosed
    }

    private func closeOpenConversations(before time: Date, day: String?) async {
        for openDay in days() {
            let log = load(openDay)
            // 続いている会話（この端末のもの）。ほかの端末の会話が後ろに並んでいることもある
            guard let i = log.conversations.lastIndex(where: { !$0.closed }) else { continue }
            let conversation = log.conversations[i]
            let sameDay = day == nil || day == openDay
            guard !sameDay || time.timeIntervalSince(conversation.end) > Self.gap else { continue }
            if let closed = await close(conversation, day: openDay) {
                // 閉じているあいだに同期で増えた会話も残すよう、読み直してから置き換える
                var fresh = load(openDay)
                guard let j = fresh.conversations.firstIndex(where: { $0.start == conversation.start && !$0.closed })
                else { continue }
                // 見出しはもう差し込んだので、閉じた版を必ず残す（二重に差し込まないように）
                var closed = closed
                closed.rev = fresh.conversations[j].rev
                fresh.conversations[j] = closed
                save(fresh, day: openDay)
                justClosed.append(closed)
                // 会話全体を見て、同じ名前や言葉の書き方をそろえる
                if let key = apiKey() { await unifySpelling(closed, day: openDay, apiKey: key) }
            }
        }
    }

    /// 見出しと要点を会話の頭に差し込む。差し込めなかったら nil（次の機会にやり直す）。
    private func close(_ conversation: Conversation, day: String) async -> Conversation? {
        var result = conversation
        result.closed = true
        result.place = await placeName(conversation.start)
        let event = await eventInfo(conversation.start, conversation.end)
        result.event = event?.name
        result.movement = await movementName(conversation.start, conversation.end)
        // テレビ・CM・ドラマ・放送の声だった行を見分けて、[テレビ] などの名前にする（相手には数えない）
        if let key = apiKey() { result = await tagBroadcast(result, day: day, apiKey: key) }
        let transcript = result.lines.map { line in
            (line.speaker.map { "[\($0)] " } ?? "") + line.text
        }.joined(separator: "\n")
        guard transcript.count >= Self.minimumCharacters else { return result }

        let range = "\(timeFormatter.string(from: conversation.start))〜\(timeFormatter.string(from: conversation.end))"
        if let key = apiKey() {
            let total = max(1, conversation.lines.reduce(0) { $0 + $1.text.count })
            let mine = conversation.lines.filter { $0.speakerID == SpeakerLabeler.selfID || $0.speaker == SpeakerLabeler.selfName }
                .reduce(0) { $0 + $1.text.count }
            if let summary = try? await Summarizer.conversation(transcript, timeRange: range,
                                                                selfShare: Double(mine) / Double(total),
                                                                event: event?.detail, apiKey: key) {
                result.title = summary.title
                result.points = summary.points
                result.media = summary.media
                result.program = summary.program
            }
        }
        if let media = result.media {
            // 番組や動画の声は話し相手ではないので、名前の無い声を「テレビ」などにし、覚えた声は忘れる
            var fixes: [(find: String, replace: String)] = []
            var forget: Set<String> = []
            for i in result.lines.indices {
                let line = result.lines[i]
                guard let id = line.speakerID, id != SpeakerLabeler.selfID,
                      line.speaker?.hasPrefix("人物") == true else { continue }
                forget.insert(id)
                result.lines[i].speaker = media
                result.lines[i].speakerID = nil
                fixes.append((find: Self.docLine(line), replace: Self.docLine(result.lines[i])))
            }
            if !fixes.isEmpty { try? await docs.replaceAll(fixes, day: day) }
            if !forget.isEmpty { await forgetVoices(forget) }
        }
        let heading = Self.headingText(result)
        let body = result.points.map { "・" + $0 + "\n" }.joined()
        do {
            try await docs.insert(heading: heading, body: body, at: conversation.docIndex,
                                  before: conversation.lines.first.map(Self.docLine), style: "HEADING_2", day: day)
            return result
        } catch {
            return nil
        }
    }

    // MARK: - テレビ・放送の行

    /// 会話の中の、テレビ・CM・ドラマ・動画・ラジオ・電車や駅の放送・店内放送の声だった行を見分け、
    /// 話した人を [テレビ] [CM] などにする（元の人は heardSpeaker に残す）。自分・名前を付けた人・手で直した行は変えない。
    private func tagBroadcast(_ c: Conversation, day: String, apiKey: String) async -> Conversation {
        var result = c
        func judgeable(_ line: Line) -> Bool {
            line.media == nil && line.checked != true && line.speakerID != SpeakerLabeler.selfID
                && (line.speaker == nil || line.speaker?.hasPrefix("人物") == true)
        }
        guard c.lines.contains(where: judgeable),
              c.lines.reduce(0, { $0 + $1.text.count }) >= 20 else { return c }
        // 場所と移動の様子（家なら動画やテレビ、電車なら車内の放送が多い）
        let settingText = [c.place, c.movement].compactMap { $0 }.joined(separator: "・")
            .trimmingCharacters(in: .whitespaces)
        let setting = settingText.isEmpty ? nil : settingText
        var flagged: [Int: String] = [:]
        // 長い会話は150行ずつ（前後のつながりも見られるよう、判定しない行もいっしょに渡す）
        for from in stride(from: 0, to: c.lines.count, by: 150) {
            let range = from..<min(c.lines.count, from + 150)
            let texts = range.map { i -> String in
                let line = c.lines[i]
                return (line.speaker.map { "[\($0)] " } ?? "") + line.text + (line.sound.map { "（背景: \($0)）" } ?? "")
            }
            let judge = Set(range.filter { judgeable(c.lines[$0]) }.map { $0 - from })
            guard !judge.isEmpty,
                  let found = try? await Summarizer.broadcast(texts, judge: judge, setting: setting, apiKey: apiKey) else { continue }
            for (i, kind) in found { flagged[from + i] = kind }
        }
        guard !flagged.isEmpty else { return c }
        var fixes: [(find: String, replace: String)] = []
        for (i, kind) in flagged {
            let line = result.lines[i]
            result.lines[i].media = kind
            result.lines[i].heardSpeaker = line.speaker
            result.lines[i].heardSpeakerID = line.speakerID
            result.lines[i].speaker = kind
            result.lines[i].speakerID = nil
            fixes.append((find: Self.docLine(line), replace: Self.docLine(result.lines[i])))
        }
        try? await docs.replaceAll(fixes, day: day)
        // 放送の声としか出てこなかった名前の無い声は、覚えている声から忘れる
        var forget = Set<String>()
        for id in Set(c.lines.compactMap(\.speakerID)) where id != SpeakerLabeler.selfID {
            let lines = c.lines.indices.filter { c.lines[$0].speakerID == id }
            if lines.allSatisfy({ flagged[$0] != nil }) { forget.insert(id) }
        }
        if !forget.isEmpty { await forgetVoices(forget) }
        return result
    }

    // MARK: - 書き方をそろえる

    /// 会話の中で、同じ名前や言葉が行によって違う字で書かれていたら、1つの書き方にそろえる。
    /// そろえる先は会話の中にある書き方か登録した言葉だけで、読みが同じものだけ置き換える。手で直した行は変えない。
    /// 直した行の元の文は「直す前」として残る。
    private func unifySpelling(_ c: Conversation, day: String, apiKey: String) async {
        guard c.media == nil else { return }
        let lines = c.lines.filter { $0.checked != true }
        guard lines.reduce(0, { $0 + $1.text.count }) >= Self.minimumCharacters else { return }
        let hints = await spellingHints(c)
        let all = lines.map(\.text).joined(separator: "\n")
        guard let pairs = try? await Summarizer.unify(String(all.prefix(6_000)), title: c.title, hints: hints, apiKey: apiKey)
        else { return }
        let safe = pairs.filter { pair in
            all.contains(pair.wrong)
                && (all.contains(pair.right) || hints.contains(pair.right))
                && Self.soundsSame(pair.wrong, pair.right)
        }
        guard !safe.isEmpty else { return }
        var changes: [TextChange] = []
        for line in lines {
            var text = line.text
            for pair in safe { text = text.replacingOccurrences(of: pair.wrong, with: pair.right) }
            if text != line.text {
                changes.append(TextChange(line: line, text: text, confidence: line.confidence, manual: false))
            }
        }
        _ = try? await editText(changes, day: day)
    }

    /// 読み（ローマ字。長音はそろえる）が同じか、ほとんど同じか
    static func soundsSame(_ a: String, _ b: String) -> Bool {
        let x = Array(ContactsLink.reading(a)), y = Array(ContactsLink.reading(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...y.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (x[i - 1] == y[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[y.count] <= max(1, min(x.count, y.count) / 6)
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

    /// 声が無いところに書かれてしまった「ご清聴ありがとうございました」などの行を、アプリとドキュメントから消す。
    /// 1つの会話で同じ文（8文字以上）が3回以上ある行も消す。一度だけ動く。
    func removeFillerLines() async {
        let doneKey = "repair-filler-lines"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        for day in days() {
            var log = load(day)
            var fixes: [(find: String, replace: String)] = []
            for c in log.conversations.indices {
                var counts: [String: Int] = [:]
                for line in log.conversations[c].lines where line.text.count >= 8 { counts[line.text, default: 0] += 1 }
                let drop: (Line) -> Bool = { CloudTranscriber.isFiller($0.text) || (counts[$0.text] ?? 0) >= 3 }
                for line in log.conversations[c].lines where drop(line) {
                    // ドキュメントでは行の中身を消す（空の行が残る）
                    fixes.append((find: Self.docLine(line), replace: ""))
                }
                log.conversations[c].lines.removeAll(where: drop)
            }
            guard !fixes.isEmpty else { continue }
            do {
                try await docs.replaceAll(fixes, day: day)
            } catch {
                return
            }
            save(log, day: day)
        }
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    // MARK: - 記録の掃除

    /// ドキュメントに書く会話の見出し（例: 「14:05〜14:40　会社　田中と　来週の段取り」）
    static func headingText(_ c: Conversation) -> String {
        var heading = "\(minuteFormatter.string(from: c.start))〜\(minuteFormatter.string(from: c.end))"
        if let place = c.place { heading += "　" + place }
        if let movement = c.movement { heading += "（\(movement)）" }
        if let event = c.event, !event.isEmpty { heading += "　〔\(event)〕" }
        if let media = c.media {
            heading += "　［\(media)］" + (c.program.map { "「\($0)」" } ?? "")
        } else if !c.people.isEmpty {
            heading += "　" + c.people.joined(separator: "、") + "と"
        }
        if let title = c.title, !title.isEmpty { heading += "　" + title }
        return heading
    }

    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// ドキュメントの文字を消したあと、まだ見出しを付けていない会話の位置をずらす。
    private static func shifted(_ index: Int, removing ranges: [Range<Int>]) -> Int {
        var result = index
        for range in ranges {
            if range.upperBound <= index {
                result -= range.count
            } else if range.lowerBound < index {
                result -= index - range.lowerBound
            }
        }
        return max(1, result)
    }

    private static let trashURL = URL.applicationSupportDirectory.appendingPathComponent("trash.json")
    private static let trashKeep: TimeInterval = 30 * 24 * 3600

    /// 消した行（新しい順。30日より前のものは捨てる）
    /// 書かなかった行を「消した行」に入れておく（あとで戻せる）。
    func addToTrash(_ items: [Junk.TrashItem]) {
        guard !items.isEmpty else { return }
        saveTrash(items + trash())
    }

    func trash() -> [Junk.TrashItem] {
        guard let data = try? Data(contentsOf: Self.trashURL),
              let items = try? JSONDecoder().decode([Junk.TrashItem].self, from: data) else { return [] }
        return items.filter { $0.removed.timeIntervalSinceNow > -Self.trashKeep }.sorted { $0.removed > $1.removed }
    }

    private func saveTrash(_ items: [Junk.TrashItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.trashURL, options: .atomic)
    }

    /// 消す候補を探す。only を渡すとその日だけ。
    func findJunk(custom: [String], flagged: Set<String> = [], only: [String]? = nil) -> [Junk.Candidate] {
        let customKeys = Set(custom.map(Junk.normalized).filter { !$0.isEmpty })
        var result: [Junk.Candidate] = []
        for day in only ?? days() {
            let lines = load(day).conversations.flatMap(\.lines).sorted { $0.time < $1.time }
            let streak = Junk.streaks(lines)
            for (i, line) in lines.enumerated() {
                guard let kind = Junk.kind(of: line.text, custom: customKeys) ?? (streak.contains(i) ? .streak : nil)
                        ?? (flagged.contains(Junk.key(line)) ? .unheard : nil)
                else { continue }
                result.append(Junk.Candidate(day: day, line: line, kind: kind,
                                             before: i > 0 ? lines[i - 1].text : nil,
                                             after: i + 1 < lines.count ? lines[i + 1].text : nil))
            }
        }
        return result
    }

    /// 音声ファイルごとの行（照らし直し用。古い日から）
    func linesByAudio() -> [(day: String, audio: String, lines: [Line])] {
        var result: [(day: String, audio: String, lines: [Line])] = []
        for day in days() {
            let lines = load(day).conversations.flatMap(\.lines).filter { $0.audio != nil && $0.offset != nil }
            let groups = Dictionary(grouping: lines) { $0.audio ?? "" }
            for (audio, group) in groups.sorted(by: { $0.key < $1.key }) {
                result.append((day, audio, group.sorted { $0.time < $1.time }))
            }
        }
        return result
    }

    /// 行をアプリの記録とドキュメントから行ごと消し、30日間とっておく。
    /// 会話の行がすべて消えるときは、ドキュメントの見出しと要点も消す。
    func remove(_ items: [(line: Line, kind: Junk.Kind)], day: String) async throws {
        guard !items.isEmpty else { return }
        let keys = Set(items.map { Junk.key($0.line) })
        let emptied = load(day).conversations.filter { c in
            c.closed && !c.lines.isEmpty && c.lines.allSatisfy { keys.contains(Junk.key($0)) }
        }
        let ranges = try await docs.deleteParagraphs(items.map { Self.docLine($0.line) },
                                                     headings: emptied.map(Self.headingText), day: day)
        // 消しているあいだに書き足された分も残すよう、読み直してから直す
        var log = load(day)
        let emptiedStarts = Set(emptied.map(\.start))
        for c in log.conversations.indices {
            log.conversations[c].lines.removeAll { keys.contains(Junk.key($0)) }
            if !log.conversations[c].closed {
                log.conversations[c].docIndex = Self.shifted(log.conversations[c].docIndex, removing: ranges)
            }
        }
        // 行がすべて消えた会話は消し、ほかの端末にも消したと伝える
        for c in log.conversations where emptiedStarts.contains(c.start) && c.lines.isEmpty {
            log.removed = (log.removed ?? []) + [Removed(start: c.start, rev: (c.rev ?? 0) + 1)]
        }
        log.conversations.removeAll { emptiedStarts.contains($0.start) && $0.lines.isEmpty }
        save(log, day: day)
        saveTrash(trash() + items.map { Junk.TrashItem(day: day, line: $0.line, kind: $0.kind, removed: .now) })
    }

    /// 消した行を元の位置に戻す。
    func restore(_ item: Junk.TrashItem) async throws {
        let all = load(item.day).conversations.flatMap(\.lines).sorted { $0.time < $1.time }
        let next = all.first { $0.time > item.line.time }
        let previous = all.last { $0.time <= item.line.time }
        let inserted = try await docs.insertLine(Self.docLine(item.line), before: next.map(Self.docLine),
                                                 after: previous.map(Self.docLine), day: item.day)
        var log = load(item.day)
        for c in log.conversations.indices where !log.conversations[c].closed && log.conversations[c].docIndex > inserted.at {
            log.conversations[c].docIndex += inserted.length
        }
        if let c = log.conversations.lastIndex(where: { $0.start <= item.line.time }) ?? log.conversations.indices.first {
            var lines = log.conversations[c].lines
            lines.insert(item.line, at: lines.firstIndex { $0.time > item.line.time } ?? lines.count)
            log.conversations[c].lines = lines
            log.conversations[c].start = min(log.conversations[c].start, item.line.time)
            log.conversations[c].end = max(log.conversations[c].end, item.line.time)
        } else {
            var conversation = Conversation(start: item.line.time, end: item.line.time, docIndex: inserted.at, lines: [item.line])
            conversation.closed = true
            log.conversations.append(conversation)
        }
        save(log, day: item.day)
        saveTrash(trash().filter { $0.id != item.id })
    }

    /// 前に行の中身だけ消したときに残った空の段落を詰める。一度だけ動く。
    func removeBlankLines() async {
        let doneKey = "repair-blank-lines"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        for day in days() {
            do {
                let ranges = try await docs.deleteParagraphs([], day: day)
                guard !ranges.isEmpty else { continue }
                var log = load(day)
                for c in log.conversations.indices where !log.conversations[c].closed {
                    log.conversations[c].docIndex = Self.shifted(log.conversations[c].docIndex, removing: ranges)
                }
                save(log, day: day)
            } catch {
                return
            }
        }
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    // MARK: - 文字の手直し

    /// 行の文字を直す（アプリの記録とドキュメントの両方）。いちばん最初の文は original に残す。直した行の数を返す。
    @discardableResult
    func editText(_ changes: [TextChange], day: String) async throws -> Int {
        guard !changes.isEmpty else { return 0 }
        // 先にドキュメントを直す
        let current = load(day).conversations.flatMap(\.lines)
        var fixes: [(find: String, replace: String)] = []
        var edited: [String: Line] = [:]
        for change in changes {
            let key = Junk.key(change.line)
            guard edited[key] == nil, let old = current.first(where: { Junk.key($0) == key }),
                  old.text != change.text else { continue }
            var new = old
            new.text = change.text
            if new.original == nil { new.original = old.text }
            new.confidence = change.confidence
            if change.manual { new.checked = true }
            edited[key] = new
            fixes.append((find: Self.docLine(old), replace: Self.docLine(new)))
        }
        guard !fixes.isEmpty else { return 0 }
        try await docs.replaceAll(fixes, day: day)
        // 直しているあいだに書き足された分も残すよう、読み直してから当てる
        var log = load(day)
        for c in log.conversations.indices {
            for l in log.conversations[c].lines.indices {
                if let new = edited[Junk.key(log.conversations[c].lines[l])] { log.conversations[c].lines[l] = new }
            }
        }
        save(log, day: day)
        return fixes.count
    }

    // MARK: - 話者の手直し

    /// match に当たる行の話者を name（番号 id）にし、ドキュメントの同じ行も直す。直した行の数を返す。
    /// renaming を渡すと、会話の見出しの「〇〇と」も置き換える（人の名前を付け替えたとき）。
    @discardableResult
    func relabel(to id: String, name: String, renaming: String? = nil,
                 where match: (Line) -> Bool) async throws -> Int {
        var changed = 0
        for day in days() {
            var log = load(day)
            var fixes: [(find: String, replace: String)] = []
            let before = changed
            for c in log.conversations.indices {
                for l in log.conversations[c].lines.indices {
                    let line = log.conversations[c].lines[l]
                    guard match(line), line.speakerID != id || line.speaker != name else { continue }
                    log.conversations[c].lines[l].speaker = name
                    log.conversations[c].lines[l].speakerID = id
                    log.conversations[c].lines[l].media = nil
                    if line.speaker != name {
                        fixes.append((find: Self.docLine(line), replace: Self.docLine(log.conversations[c].lines[l])))
                    }
                    changed += 1
                }
            }
            // この日に直した行が無ければ、ドキュメントには触らない
            guard !fixes.isEmpty || changed > before else { continue }
            if let old = renaming, old != name {
                // 見出しは「A、Bと」の形
                for (a, b) in [("　", "と"), ("　", "、"), ("、", "と"), ("、", "、")] {
                    fixes.append((find: a + old + b, replace: a + name + b))
                }
            }
            if !fixes.isEmpty { try await docs.replaceAll(fixes, day: day) }
            save(log, day: day)
        }
        return changed
    }

    // MARK: - 印

    /// 印の前後1分の行に「★」を付け、ドキュメントの同じ行も直す。
    /// まだ書き終わっていない時間帯（settled より後）にかかる印は、そのまま返して次の機会に回す。
    func applyMarks(_ marks: [Date], settled: Date) async -> [Date] {
        var remaining: [Date] = []
        var byDay: [String: [Date]] = [:]
        for mark in marks {
            if mark.addingTimeInterval(Self.markSpan) >= settled {
                remaining.append(mark)
            } else {
                byDay[Self.dayFormatter.string(from: mark), default: []].append(mark)
            }
        }
        for (day, list) in byDay {
            var log = load(day)
            var fixes: [(find: String, replace: String)] = []
            for c in log.conversations.indices {
                for l in log.conversations[c].lines.indices {
                    let line = log.conversations[c].lines[l]
                    guard line.marked != true,
                          list.contains(where: { abs(line.time.timeIntervalSince($0)) <= Self.markSpan }) else { continue }
                    log.conversations[c].lines[l].marked = true
                    fixes.append((find: Self.docLine(line), replace: Self.docLine(log.conversations[c].lines[l])))
                }
            }
            do {
                if !fixes.isEmpty { try await docs.replaceAll(fixes, day: day) }
                save(log, day: day)
            } catch {
                // 通信できないときは次の機会にやり直す
                remaining += list
            }
        }
        return remaining
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
                let media = c.media.map { "［\($0)\(c.program.map { "「\($0)」" } ?? "")を流していた］" } ?? ""
                let head = "\(timeFormatter.string(from: c.start))〜\(timeFormatter.string(from: c.end))\(place)\(people)\(media) \(c.title ?? "（短い会話）")"
                return ([head] + c.points.map { "  ・" + $0 }).joined(separator: "\n")
            }.joined(separator: "\n")
            guard var summary = try? await Summarizer.day(overview, apiKey: key) else { continue }
            // 1日の流れは、アプリの「過ごし方」と同じ塊にする（何時から何時まで何をしていて、その中で何をしたか）
            let activities = await dayActivities(day)
            if !activities.isEmpty {
                summary = Summarizer.Day(flow: activities.map(\.flowLine), decisions: summary.decisions,
                                         todos: summary.todos, topics: summary.topics)
            }

            let people = Array(NSOrderedSet(array: log.conversations.flatMap(\.people))) as? [String] ?? []
            var body = ""
            func section(_ name: String, _ items: [String]) {
                guard !items.isEmpty else { return }
                body += name + "\n" + items.map { "・" + $0 + "\n" }.joined()
            }
            section("1日の流れ", summary.flow)
            // 時計やアプリで印を付けたところ（会話ごとに、続いた行は1つにまとめる）
            var marked: [String] = []
            for c in log.conversations {
                var last: Date?
                for line in c.lines where line.marked == true {
                    defer { last = line.time }
                    if let last, line.time.timeIntervalSince(last) <= Self.markSpan * 2, !marked.isEmpty {
                        marked[marked.count - 1] += " " + line.text
                        continue
                    }
                    marked.append(timeFormatter.string(from: line.time) + "　" + (line.speaker.map { "[\($0)] " } ?? "") + line.text)
                }
            }
            section("★ 印を付けたところ", marked.map { $0.count > 120 ? String($0.prefix(120)) + "…" : $0 })
            body += "会った人: " + (people.isEmpty ? "なし" : people.joined(separator: "、")) + "\n"
            section("決まったこと", summary.decisions)
            section("やること", summary.todos)
            section("話題", summary.topics)
            body += "\n"
            do {
                try await docs.insert(heading: "1日のまとめ", body: body, at: 1, style: "HEADING_1", day: day)
                log.summaryWritten = true
                log.summary = summary
                save(log, day: day)
            } catch {
                continue
            }
        }
    }

    // MARK: - 週のまとめ

    /// 月曜になったら、先週（月〜日）のまとめを「週のまとめ 2026-10-26〜2026-11-01」というドキュメントに書く。
    /// その週の1日のまとめがそろうまで待つ。
    func writeWeeklySummary(today: String) async {
        guard let key = apiKey(), let todayDate = Self.dayFormatter.date(from: today) else { return }
        let calendar = Calendar(identifier: .gregorian)
        // 日曜=1 … 土曜=7。今週の月曜から7日前が先週の月曜
        let sinceMonday = (calendar.component(.weekday, from: todayDate) + 5) % 7
        guard let lastMonday = calendar.date(byAdding: .day, value: -sinceMonday - 7, to: todayDate) else { return }
        let week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: lastMonday) }
        let keys = week.map { Self.dayFormatter.string(from: $0) }
        let doneKey = "week-" + keys[0]
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let recorded = Set(days())
        let present = keys.filter(recorded.contains)
        guard !present.isEmpty else { return }
        let logs = present.map { load($0) }
        guard logs.allSatisfy({ $0.summaryWritten || $0.conversations.isEmpty }) else { return }

        let label = DateFormatter()
        label.locale = Locale(identifier: "ja_JP")
        label.dateFormat = "M/d(E)"
        let budget = 7_000 / present.count
        var material = ""
        var marked: [String] = []
        for (day, log) in zip(present, logs) {
            guard let date = Self.dayFormatter.date(from: day) else { continue }
            var part = "## " + label.string(from: date) + "\n"
            if let summary = log.summary {
                part += "流れ: " + summary.flow.joined(separator: "／") + "\n"
                if !summary.decisions.isEmpty { part += "決まったこと: " + summary.decisions.joined(separator: "／") + "\n" }
                if !summary.todos.isEmpty { part += "やること: " + summary.todos.joined(separator: "／") + "\n" }
            } else {
                for c in log.conversations where c.title != nil {
                    let people = c.people.isEmpty ? "" : "（\(c.people.joined(separator: "、"))と）"
                    part += timeFormatter.string(from: c.start) + " " + (c.place ?? "") + people + " " + (c.title ?? "") + "\n"
                }
            }
            let people = Array(NSOrderedSet(array: log.conversations.flatMap(\.people))) as? [String] ?? []
            if !people.isEmpty { part += "会った人: " + people.joined(separator: "、") + "\n" }
            material += String(part.prefix(budget)) + "\n"
            for c in log.conversations {
                for line in c.lines where line.marked == true {
                    marked.append(label.string(from: date) + " " + timeFormatter.string(from: line.time) + "　" + line.text)
                }
            }
        }
        guard let summary = try? await Summarizer.week(material, apiKey: key) else { return }

        var body = ""
        func section(_ name: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            body += name + "\n" + items.map { "・" + $0 + "\n" }.joined()
        }
        section("1週間の流れ", summary.flow)
        section("よく話した人", summary.people)
        section("決まったこと", summary.decisions)
        section("やること（残っていそうなもの）", summary.todos)
        section("話題", summary.topics)
        section("★ 印を付けたところ", marked.prefix(15).map { $0.count > 100 ? String($0.prefix(100)) + "…" : $0 })
        body += "\n"
        let title = "週のまとめ（\(label.string(from: week[0]))〜\(label.string(from: week[6]))）"
        do {
            try await docs.insert(heading: title, body: body, at: 1, style: "HEADING_1",
                                  day: "週のまとめ " + keys[0] + "〜" + keys[6])
            UserDefaults.standard.set(true, forKey: doneKey)
        } catch {
            // 通信できないときは次の機会にやり直す
        }
    }

    // MARK: - アプリで見る

    func recordedDays() -> [String] { days().reversed() }

    func conversations(on day: String) -> [Conversation] { load(day).conversations }

    /// 条件に合う行の時刻（すべての日）
    func lineTimes(where match: (Line) -> Bool) -> [Date] {
        days().flatMap { day in load(day).conversations.flatMap { $0.lines.filter(match).map(\.time) } }
    }

    /// 1日のまとめの中身（まだ付けていなければ nil）
    func summary(on day: String) -> Summarizer.Day? { load(day).summary }

    // MARK: - 保存

    func days() -> [String] {
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

    /// この端末で記録を変えたときの書き込み。
    /// - 中身の変わった会話は番号（rev）を1つ増やす（端末間の同期で、新しいほうを残すため）。
    /// - 読んだあとに同期で新しい版が入っていたら、そちらを残す。
    /// - 読んだあとに同期で増えた会話は、消したと書いていない限り残す（古い読み込みで上書きして消さないように）。
    private func save(_ log: Day, day: String) {
        let old = load(day)
        var tombs: [Date: Int] = [:]
        for r in (old.removed ?? []) + (log.removed ?? []) { tombs[r.start] = max(tombs[r.start] ?? 0, r.rev) }
        var previous: [Date: Conversation] = [:]
        for c in old.conversations where previous[c.start] == nil { previous[c.start] = c }

        var result: [Conversation] = []
        var starts = Set<Date>()
        for var c in log.conversations {
            starts.insert(c.start)
            if let prev = previous[c.start] {
                let prevRev = prev.rev ?? 0, rev = c.rev ?? 0
                if rev < prevRev {
                    result.append(prev)
                    continue
                }
                if !Self.sameContent(prev, c) { c.rev = max(prevRev, rev) + 1 }
            } else if let tomb = tombs[c.start], (c.rev ?? 0) <= tomb {
                // 一度消した会話を戻した
                c.rev = tomb + 1
            } else if c.rev == nil {
                c.rev = 1
            }
            result.append(c)
        }
        for prev in old.conversations where !starts.contains(prev.start) {
            if let tomb = tombs[prev.start], tomb > (prev.rev ?? 0) { continue }
            result.append(prev)
        }
        var out = log
        out.conversations = Self.sortedByStart(result)
        out.removed = tombs.isEmpty ? nil : tombs.map { Removed(start: $0.key, rev: $0.value) }.sorted { $0.start < $1.start }
        out.summaryWritten = log.summaryWritten || old.summaryWritten
        out.summary = log.summary ?? old.summary
        write(out, day: day)
    }

    private func write(_ log: Day, day: String) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: Self.dir.appendingPathComponent(day + ".json"), options: .atomic)
    }

    /// 始まりの順に並べる（同じ時刻どうしは元の順のまま）
    private static func sortedByStart(_ list: [Conversation]) -> [Conversation] {
        list.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    private static let canonical: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// 番号（rev）を除いた中身の書き出し
    private static func content(_ c: Conversation) -> Data {
        var c = c
        c.rev = nil
        return (try? canonical.encode(c)) ?? Data()
    }

    private static func sameContent(_ a: Conversation, _ b: Conversation) -> Bool { content(a) == content(b) }

    // MARK: - 端末間の同期

    /// その日の記録ファイルを最後に書いた時刻（同期で、変わっていない日を飛ばすため）
    func modified(_ day: String) -> Date? {
        let url = Self.dir.appendingPathComponent(day + ".json")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// ほかの端末に渡す、その日の閉じた会話と、消した会話と、1日のまとめ。
    func syncPayload(_ day: String) -> SyncDay {
        let log = load(day)
        return SyncDay(conversations: log.conversations.filter(\.closed), removed: log.removed ?? [],
                       summaryWritten: log.summaryWritten, summary: log.summary)
    }

    /// ほかの端末の1日分を合わせる。会話ごとに番号（rev）の大きいほうを残し、同じなら中身で決める（どちらの端末でも同じ結果になるように）。
    /// この端末で続いている会話には触らない。変わったら true。
    @discardableResult
    func mergeRemote(_ remote: SyncDay, day: String) -> Bool {
        var log = load(day)
        var changed = false
        var tombs: [Date: Int] = [:]
        for r in log.removed ?? [] { tombs[r.start] = max(tombs[r.start] ?? 0, r.rev) }
        for r in remote.removed where r.rev > (tombs[r.start] ?? 0) {
            tombs[r.start] = r.rev
            changed = true
        }
        for rc in remote.conversations where rc.closed {
            if let i = log.conversations.firstIndex(where: { $0.start == rc.start }) {
                let lc = log.conversations[i]
                guard lc.closed else { continue }
                let lr = lc.rev ?? 0, rr = rc.rev ?? 0
                if rr > lr {
                    log.conversations[i] = rc
                    changed = true
                } else if rr == lr {
                    let a = Self.content(lc), b = Self.content(rc)
                    if a != b && a.lexicographicallyPrecedes(b) {
                        log.conversations[i] = rc
                        changed = true
                    }
                }
            } else if (rc.rev ?? 0) > (tombs[rc.start] ?? -1) {
                log.conversations.append(rc)
                changed = true
            }
        }
        let before = log.conversations.count
        log.conversations.removeAll { c in
            guard c.closed, let tomb = tombs[c.start] else { return false }
            return tomb > (c.rev ?? 0)
        }
        if log.conversations.count != before { changed = true }
        if remote.summaryWritten && !log.summaryWritten {
            log.summaryWritten = true
            changed = true
        }
        if log.summary == nil, let summary = remote.summary {
            log.summary = summary
            changed = true
        }
        guard changed else { return false }
        log.conversations = Self.sortedByStart(log.conversations)
        log.removed = tombs.isEmpty ? nil : tombs.map { Removed(start: $0.key, rev: $0.value) }.sorted { $0.start < $1.start }
        write(log, day: day)
        return true
    }
}

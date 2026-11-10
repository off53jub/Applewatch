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
        /// 騒がしいところ（周りの音が大きい・声が雑音に埋もれている区切り）で聞き取った行
        var noisy: Bool? = nil
        /// 家の PC の多数決で食い違った行の、モデルごとの文（答え合わせでモデルの当たりやすさを学ぶため）
        var votes: [String: String]? = nil
        /// 書き換えた履歴（古い順・5つまで）。前の文・書き換えた仕組み・時刻。直す画面から前の文に戻せる（2026-11-06）
        var history: [Edit]? = nil
        /// 時計のこすれ・風の音が強かった行（聞き取りの重みを下げる。2026-11-06）
        var rubbed: Bool? = nil
        /// 音声の中で、この行が終わる位置（秒）。PC の言葉ごとの時刻などで分かったときだけ（2026-11-06。前の記録には無い）
        var end: TimeInterval? = nil
        /// 2つの声のモデルで話し手が食い違った行の、もう片方のモデルが言う人の番号（2026-11-06。前の記録には無い）
        var speakerDoubt: String? = nil

        /// 書き換え1回分
        struct Edit: Codable, Hashable {
            let at: Date
            /// 書き換えた仕組み（「言語モデルの直し」「夜の聞き直し」「手で直した」など）
            let by: String
            /// 書き換える前の文
            let from: String
        }

        static let historyLimit = 5

        /// 履歴に1回分を足す（古いものから捨てて、historyLimit つまで）
        static func adding(_ edit: Edit, to history: [Edit]?) -> [Edit] {
            Array(((history ?? []) + [edit]).suffix(historyLimit))
        }

        /// 確からしさが低く、聞き直して確かめたほうがよい行
        var isUncertain: Bool {
            guard checked != true else { return false }
            // 答え合わせで学んだ「文字が違っている見込み」があれば、それで決める（2026-11-06。MultiModel の Calibration）
            if let chance = Calibration.wrongChance(self) { return chance >= 0.5 }
            return (confidence ?? 1) < Self.uncertainBelow
        }

        /// 確かめたほうがよい行の線（初めは 0.45。答え合わせが30問たまったら、当たる値に自動で寄せる。2026-11-06）
        static var uncertainBelow: Double {
            let saved = UserDefaults.standard.double(forKey: "uncertainBelow")
            return saved > 0 ? saved : 0.45
        }

        /// 言語モデルに渡す文。自信の低い行には「聞き取りが不確か」と添える（要約・タスク・議事録で信じすぎないように）
        var promptText: String { isUncertain ? text + "（聞き取りが不確か）" : text }
    }

    /// 行の文字の直し
    struct TextChange {
        let line: Line
        let text: String
        /// 直したあとの確からしさ
        let confidence: Double?
        /// 手で直したか
        let manual: Bool
        /// 書き換えた仕組み（履歴に残す。nil なら「手で直した」か「自動の直し」）
        var by: String? = nil
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
        /// あとから見出しを作ろうとして、作れる中身が無かった（もうやり直さない）
        var titleSkipped: Bool?
        /// 手で文字を直したので、見出しと要点を作り直す
        var resummarize: Bool?
        /// 会話のあいだの心拍（平均と最大。ヘルスケアが使えるときだけ）
        var heartRate: Int?
        var heartRateMax: Int?
        /// ふだんより心拍がはっきり上がっていた（緊張・興奮していたかもしれない）
        var tense: Bool?
        /// 議事録を作ったドキュメントの名前
        var minutes: String?
        /// 場面（電車・車・店・職場など）。PC の音の分類と iPhone の背景の音の多数決（2026-11-06。前の記録には無い）
        var scene: String? = nil

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
        /// まとめのあとで見出しが増えたので、まとめを書き足す
        var summaryStale: Bool?
        /// 文字を直して会話の見出しを作り直したので、1日のまとめも作り直す（書き足しではなく置き換える）
        var redoSummary: Bool?
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
        /// 送った端末のアプリの版（2026-11-06。これより前のアプリは送らないので nil）
        var build: Int? = nil
    }

    /// これだけ話が途切れたら、別の会話とみなす
    /// 本人が会話をつないだ・分けたところから学ぶ（ConversationGap。90〜600秒。2026-11-06）
    static var gap: TimeInterval { ConversationGap.current }
    /// 画面で1つに見せる会話どうしの、間の長さの上限
    private static let sameTalkGap: TimeInterval = 900
    /// 短すぎる会話（テレビの音や独り言など）には見出しを付けない
    private static let minimumCharacters = 80
    /// あとから見出しを作るとき、1回に読む文字数の上限（無料枠を使い切らないように）
    private static let fillBudget = 12_000

    // MARK: - 長い会話の区切り（2026-11-09）

    /// これだけ続いた会話は、短い間（longTalkPause）でも区切る
    static let longTalk: TimeInterval = 30 * 60
    /// 長く続いた会話を区切る間の長さ（前の行を話し終えてから次の行まで）
    static let longTalkPause: TimeInterval = 20
    /// 1つの会話の長さの上限（これを超えたら、間が無くても区切る）
    static let longestTalk: TimeInterval = 60 * 60

    /// 行を話していた長さ（秒）。音声の中の終わりの位置が分からなければ、文字数から見積もる
    static func spokenLength(_ line: Line) -> TimeInterval {
        if let end = line.end, let offset = line.offset, end > offset { return end - offset }
        return Double(line.text.count) * 0.17
    }

    /// start に始まり、最後の行（last。時刻は lastTime）まで続いた会話を、next の行の前で閉じるか（長い会話のときだけ）。
    /// 30分を超えたら20秒の間で、60分に届いたら間が無くても閉じる。
    static func endsLongTalk(start: Date, last: Line?, lastTime: Date, next: Date) -> Bool {
        if next.timeIntervalSince(start) >= longestTalk { return true }
        guard lastTime.timeIntervalSince(start) >= longTalk else { return false }
        let silence = next.timeIntervalSince(lastTime) - (last.map(spokenLength) ?? 0)
        return silence >= longTalkPause
    }

    /// 届いた行を、長い会話の区切りで分ける。openStart は続いている会話の始まり（無ければ nil）。
    static func segments(_ lines: [Line], openStart: Date?) -> [[Line]] {
        var parts: [[Line]] = []
        var current: [Line] = []
        var start = openStart
        for line in lines {
            if let s = start, let prev = current.last,
               endsLongTalk(start: s, last: prev, lastTime: prev.time, next: line.time) {
                parts.append(current)
                current = []
                start = line.time
            }
            if start == nil { start = line.time }
            current.append(line)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// 届いた行が、続いている会話（openStart に始まった）より前の時間のものか。
    /// 会話の始まりより、会話の切れ目の長さ（gap）を超えて前に終わっていれば、別の会話とみなす
    /// （時計にたまっていた音声が、あとから届いたときなど。2026-11-10）。
    static func isLate(_ lines: [Line], openStart: Date, gap: TimeInterval) -> Bool {
        guard let last = lines.map(\.time).max() else { return false }
        return openStart.timeIntervalSince(last) > gap
    }

    /// 行を足したあとの、会話の終わりの時刻。後ろへだけ動かす（前の時間の行を足しても、前には戻さない）。
    static func extendedEnd(_ end: Date, adding lines: [Line]) -> Date {
        max(end, lines.map(\.time).max() ?? end)
    }

    /// 見出しが無く、長さの上限より長い、閉じた会話（前の記録。分け直して見出しを付ける）
    static func needsLongSplit(_ c: Conversation) -> Bool {
        c.closed && c.title == nil && c.media == nil && c.lines.count >= 2
            && c.end.timeIntervalSince(c.start) > longestTalk
    }

    /// 長い会話を分ける所（分けた後ろの会話の、最初の行の時刻。古い順）
    static func longCuts(_ lines: [Line]) -> [Date] {
        let sorted = lines.sorted { $0.time < $1.time }
        var seen = Set<Date>()
        return segments(sorted, openStart: nil).dropFirst().compactMap(\.first?.time)
            .filter { $0 > (sorted.first?.time ?? .distantPast) && seen.insert($0).inserted }
    }

    /// 見出しが無いまま長すぎる前の会話を、「分ける」と同じしかたで1時間以内に分ける（見出しと要点は作り直しで付く）。
    /// 本人が分けたのではないので、区切りの学びには入れない。分けた数を返す。
    func splitLongConversations() async -> Int {
        var made = 0
        for day in days() {
            for c in load(day).conversations where Self.needsLongSplit(c) {
                var start = c.start
                for cut in Self.longCuts(c.lines) {
                    if Task.isCancelled { return made }
                    guard await split(start: start, at: cut, day: day) != nil else { break }
                    start = cut
                    made += 1
                }
            }
        }
        return made
    }

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
    /// その時刻は職場か（職場の会話は、設定によって端末内の言語モデルだけでまとめる）
    var isWork: (Date) -> Bool = { _ in false }
    /// その時間の心拍（平均・最大・ふだんよりはっきり高いか）。ヘルスケアが使えなければ nil
    var heartInfo: (Date, Date) async -> (average: Int, max: Int, tense: Bool)? = { _, _ in nil }
    /// その日の体調の一文（睡眠・歩数）。ヘルスケアが使えなければ nil
    var healthLine: (Date) async -> String? = { _ in nil }

    /// 会話・日の中に職場の会話があるか
    private func sensitive(_ list: [Conversation]) -> Bool { list.contains { isWork($0.start) } }

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
    /// 長く続いた会話は、届いた行の途中でも区切る（長い会話の区切り。2026-11-09）。
    func append(_ lines: [Line], text: String, day: String) async throws {
        guard let first = lines.first else { return }
        // 続いている会話より前の時間の行が遅れて届いたら（時計にたまっていた音声など）、続いている会話を先に閉じて、
        // 別の会話として書く。そのまま足すと、会話の終わりが始まりより前になっていた（時刻の逆転。2026-11-10）
        let late = load(day).conversations.last(where: { !$0.closed })
            .map { Self.isLate(lines, openStart: $0.start, gap: Self.gap) } ?? false
        await closeOpenConversations(before: first.time, day: day, force: late)
        let openStart = load(day).conversations.last(where: { !$0.closed })?.start
        let parts = Self.segments(lines, openStart: openStart)
        guard parts.count > 1 else {
            try await appendPart(lines, text: text, day: day)
            return
        }
        for (n, part) in parts.enumerated() {
            guard let head = part.first else { continue }
            // 前の分で長くなった会話を閉じてから、続きを新しい会話として書く
            if n > 0 { await closeOpenConversations(before: head.time, day: day) }
            try await appendPart(part, text: part.map { Self.docLine($0) + "\n" }.joined(), day: day)
        }
    }

    private func appendPart(_ lines: [Line], text: String, day: String) async throws {
        guard let first = lines.first else { return }
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
        // 終わりは後ろへだけ動かす（前の時間の行が混ざっていても、前には戻さない。2026-11-10）
        log.conversations[i].end = Self.extendedEnd(log.conversations[i].end, adding: lines)
        save(log, day: day)
    }

    /// しばらく何も話していなければ、続いている会話を閉じる。
    /// 録音中の区切り（短めで最長2分、ふつうで最長5分）にまだ続きがあるかもしれないので、その分も待つ。
    func closeIdle(now: Date, waiting: TimeInterval) async {
        await closeOpenConversations(before: now.addingTimeInterval(-waiting), day: nil)
    }

    /// 閉じたばかりの会話（話者のまとめ直しに使う）。受け取ったら空にする。
    private var justClosed: [Conversation] = []

    func takeClosed() -> [Conversation] {
        defer { justClosed = [] }
        return justClosed
    }

    /// force: 同じ日の続いている会話を、間が空いていなくても閉じる（前の時間の行が遅れて届いたとき）
    private func closeOpenConversations(before time: Date, day: String?, force: Bool = false) async {
        for openDay in days() {
            let log = load(openDay)
            // 続いている会話（この端末のもの）。ほかの端末の会話が後ろに並んでいることもある
            guard let i = log.conversations.lastIndex(where: { !$0.closed }) else { continue }
            let conversation = log.conversations[i]
            let sameDay = day == nil || day == openDay
            guard force || !sameDay || time.timeIntervalSince(conversation.end) > Self.gap
                    || Self.endsLongTalk(start: conversation.start, last: conversation.lines.last,
                                         lastTime: conversation.end, next: time) else { continue }
            let work = isWork(conversation.start)
            if let closed = await Summarizer.$sensitive.withValue(work, operation: { await close(conversation, day: openDay) }) {
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
                if let key = apiKey() {
                    await Summarizer.$sensitive.withValue(work) { await unifySpelling(closed, day: openDay, apiKey: key) }
                }
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
        result.movement = Self.refinedMovement(await movementName(conversation.start, conversation.end), lines: conversation.lines)
        if let heart = await heartInfo(conversation.start, conversation.end) {
            result.heartRate = heart.average
            result.heartRateMax = heart.max
            result.tense = heart.tense ? true : nil
        }
        // テレビ・CM・ドラマ・放送の声だった行を見分けて、[テレビ] などの名前にする（相手には数えない）
        if let key = apiKey() { result = await tagBroadcast(result, day: day, apiKey: key) }
        let transcript = result.lines.map { line in
            (line.speaker.map { "[\($0)] " } ?? "") + line.promptText
        }.joined(separator: "\n")
        guard transcript.count >= Self.minimumCharacters else { return result }

        let range = "\(timeFormatter.string(from: conversation.start))〜\(timeFormatter.string(from: conversation.end))"
        if let key = apiKey() {
            if let summary = try? await Summarizer.conversation(transcript, timeRange: range,
                                                                selfShare: Self.selfShare(conversation),
                                                                event: event?.detail, apiKey: key) {
                result.title = summary.title
                result.points = summary.points
                result.media = summary.media
                result.program = summary.program
                Tally.add("title.made")
            } else {
                // 作れなかった数も数える（無料枠切れなどで続けて作れない日が、成績表で分かるように。2026-11-10）
                Tally.add("title.failed")
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

    /// 会話の文字のうち、自分が話した割合
    private static func selfShare(_ c: Conversation) -> Double {
        let total = max(1, c.lines.reduce(0) { $0 + $1.text.count })
        let mine = c.lines.filter { $0.speakerID == SpeakerLabeler.selfID || $0.speaker == SpeakerLabeler.selfName }
            .reduce(0) { $0 + $1.text.count }
        return Double(mine) / Double(total)
    }

    // MARK: - 見出しの穴埋め

    /// 閉じたのに、見出しが付いていない会話か。
    private static func needsTitle(_ c: Conversation) -> Bool {
        // 作り直しを待っている会話（分けた後ろの会話など）は、作り直しのほうで見出しを付ける（二重に付けない）
        // 長すぎる会話は、先に分け直してから見出しを付ける（2026-11-09）
        c.closed && c.title == nil && c.media == nil && c.titleSkipped != true && c.resummarize != true
            && !needsLongSplit(c) && c.lines.reduce(0) { $0 + $1.text.count } >= minimumCharacters
    }

    /// 無料枠が足りずに見出しを作れなかった会話に、あとから見出しと要点を付ける。
    /// 新しい日から少しずつ進め、作れなければやめて次の機会にやり直す。
    func fillMissingTitles() async {
        guard let key = apiKey() else { return }
        var budget = Self.fillBudget
        for day in days().reversed() {
            for c in load(day).conversations where Self.needsTitle(c) {
                guard budget > 0 else { return }
                let transcript = c.lines.map { line in
                    (line.speaker.map { "[\($0)] " } ?? "") + line.promptText
                }.joined(separator: "\n")
                budget -= transcript.count
                let range = "\(timeFormatter.string(from: c.start))〜\(timeFormatter.string(from: c.end))"
                let event = await eventInfo(c.start, c.end)
                guard let summary = try? await Summarizer.$sensitive.withValue(isWork(c.start), operation: {
                    try await Summarizer.conversation(transcript, timeRange: range, selfShare: Self.selfShare(c),
                                                      event: event?.detail, apiKey: key)
                }) else {
                    Tally.add("title.fillFailed")
                    return
                }
                Tally.add("title.filled")
                await applyTitle(summary, to: c, day: day)
            }
        }
    }

    private func applyTitle(_ summary: Summarizer.Conversation, to c: Conversation, day: String) async {
        var updated = c
        if summary.title.isEmpty {
            updated.titleSkipped = true
        } else {
            updated.title = summary.title
            updated.points = summary.points
            updated.media = summary.media
            updated.program = summary.program
            // ドキュメントには時刻・場所だけの見出しが入っているので、それを置き換えて要点を足す
            try? await docs.replaceAll([(find: Self.headingText(c), replace: Self.headingText(updated))], day: day)
            if let first = c.lines.first {
                try? await docs.insertLines(updated.points.map { "・" + $0 }, before: Self.docLine(first), day: day)
            }
        }
        // 書いているあいだに記録が変わっていてもよいように、読み直してから置き換える
        var log = load(day)
        guard let i = log.conversations.firstIndex(where: { $0.start == c.start }),
              log.conversations[i].title == nil else { return }
        updated.lines = log.conversations[i].lines
        updated.rev = log.conversations[i].rev
        log.conversations[i] = updated
        if log.summaryWritten { log.summaryStale = true }
        save(log, day: day)
    }

    // MARK: - 画面で見るときのまとまり

    /// 間が短く、場所と相手が同じ会話を1つのまとまりにする（画面で見るときだけ。記録とドキュメントは会話ごとのまま）。
    static func grouped(_ list: [Conversation]) -> [[Conversation]] {
        var groups: [[Conversation]] = []
        for c in list {
            if let group = groups.last, continues(group, with: c) {
                groups[groups.count - 1].append(c)
            } else {
                groups.append([c])
            }
        }
        return groups
    }

    private static func continues(_ group: [Conversation], with c: Conversation) -> Bool {
        guard let last = group.last, let end = group.map(\.end).max(),
              c.start.timeIntervalSince(end) <= sameTalkGap, c.media == last.media else { return false }
        if let a = group.compactMap(\.place).last, let b = c.place, a != b { return false }
        if let a = group.compactMap(\.event).last, let b = c.event, a != b { return false }
        let before = Set(group.flatMap(\.people)), now = Set(c.people)
        return before.isEmpty || now.isEmpty || !before.isDisjoint(with: now)
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
            // 書き換えすぎ（3割より多く変わる）行は使わない
            if text != line.text, Summarizer.isSmallFix(line.text, text) {
                changes.append(TextChange(line: line, text: text, confidence: line.confidence, manual: false,
                                          by: "表記のそろえ"))
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

    /// 乗り物に乗っていたとき、背景の音で電車か車かを見分ける（行の2割以上で聞こえていた音）
    static func refinedMovement(_ movement: String?, lines: [Line]) -> String? {
        guard movement == MotionLink.Movement.vehicle.label, !lines.isEmpty else { return movement }
        let train = lines.filter { $0.sound == "電車" }.count
        let car = lines.filter { $0.sound == "車" }.count
        let enough = max(1, lines.count / 5)
        if train >= enough && train > car { return "電車で" }
        if car >= enough && car > train { return "車で" }
        return movement
    }

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
            new.history = Line.adding(.init(at: .now, by: change.by ?? (change.manual ? "手で直した" : "自動の直し"),
                                            from: old.text), to: old.history)
            new.confidence = change.confidence
            if change.manual { new.checked = true }
            edited[key] = new
            fixes.append((find: Self.docLine(old), replace: Self.docLine(new)))
        }
        guard !fixes.isEmpty else { return 0 }
        try await docs.replaceAll(fixes, day: day)
        // 直しているあいだに書き足された分も残すよう、読み直してから当てる
        var log = load(day)
        let manual = changes.contains(where: \.manual)
        for c in log.conversations.indices {
            for l in log.conversations[c].lines.indices {
                if let new = edited[Junk.key(log.conversations[c].lines[l])] {
                    log.conversations[c].lines[l] = new
                    // 手で直した閉じた会話は、見出しと要点をあとで作り直す
                    if manual && log.conversations[c].closed { log.conversations[c].resummarize = true }
                }
            }
        }
        save(log, day: day)
        return fixes.count
    }

    // MARK: - 会話をつなぐ・分ける（本人が押したとき。2026-11-06）

    /// 閉じた会話を、そのすぐ前の閉じた会話とつなぐ。つないだ2つの間の長さ（秒）を返す（区切りの学びに使う）。
    /// 後ろの会話の見出しはドキュメントから消し、つないだ会話の見出しと要点・1日のまとめは、あとで作り直す。
    func joinWithPrevious(start: Date, day: String) async -> TimeInterval? {
        let closed = load(day).conversations.filter(\.closed).sorted { $0.start < $1.start }
        guard let k = closed.firstIndex(where: { $0.start == start }), k > 0 else { return nil }
        let prev = closed[k - 1], cur = closed[k]
        let gap = max(0, cur.start.timeIntervalSince(prev.end))
        // 2つの見出しを消し、つないだ会話の見出し（前の見出しと要点のまま・時間だけ広げる）を入れ直す。
        // あとで作り直せたら置き換わる（作り直せなくても見出しは残る）
        _ = try? await docs.deleteParagraphs([], headings: [Self.headingText(prev), Self.headingText(cur)], day: day)
        var joined = prev
        joined.lines = (prev.lines + cur.lines).sorted { $0.time < $1.time }
        joined.end = max(prev.end, cur.end)
        try? await docs.insert(heading: Self.headingText(joined), body: joined.points.map { "・" + $0 + "\n" }.joined(),
                               at: joined.docIndex, before: joined.lines.first.map(Self.docLine), style: "HEADING_2", day: day)
        // 消しているあいだに変わっていてもよいように、読み直してから直す
        var log = load(day)
        guard let i = log.conversations.firstIndex(where: { $0.start == prev.start }),
              let j = log.conversations.firstIndex(where: { $0.start == cur.start }) else { return nil }
        let later = log.conversations[j]
        var merged = log.conversations[i]
        merged.lines = (merged.lines + later.lines).sorted { $0.time < $1.time }
        merged.end = max(merged.end, later.end)
        merged.resummarize = true
        merged.minutes = merged.minutes ?? later.minutes
        merged.scene = merged.scene ?? later.scene
        log.conversations[i] = merged
        log.removed = (log.removed ?? []) + [Removed(start: later.start, rev: (later.rev ?? 0) + 1)]
        log.conversations.remove(at: j)
        log.redoSummary = true
        save(log, day: day)
        return gap
    }

    /// 閉じた会話を、その行の前で2つに分ける。分けた所の、前の行との間の長さ（秒。前の行の長さは文字数で見積もる）を返す。
    /// 前の見出しはドキュメントから消し、2つの会話の見出しと要点・1日のまとめは、あとで作り直す。
    func split(start: Date, at time: Date, day: String) async -> TimeInterval? {
        guard let c = load(day).conversations.first(where: { $0.start == start && $0.closed }),
              let k = c.lines.firstIndex(where: { $0.time == time }), k > 0 else { return nil }
        let before = c.lines[k - 1]
        let spoken = before.end.flatMap { end in before.offset.map { end - $0 } } ?? Double(before.text.count) * 0.17
        let gap = max(0, time.timeIntervalSince(before.time) - spoken)
        // 元の見出しを消し、2つの会話の見出しをすぐ入れ直す（前は元の見出しと要点のまま、後ろは時間と相手だけ）。
        // あとで作り直せたら置き換わる
        _ = try? await docs.deleteParagraphs([], headings: [Self.headingText(c)], day: day)
        var head = c
        head.lines = Array(c.lines[..<k])
        head.end = head.lines.last?.time ?? head.start
        var tail = Conversation(start: time, end: max(c.end, time), docIndex: c.docIndex)
        tail.lines = Array(c.lines[k...])
        tail.closed = true
        tail.place = c.place
        try? await docs.insert(heading: Self.headingText(head), body: head.points.map { "・" + $0 + "\n" }.joined(),
                               at: head.docIndex, before: head.lines.first.map(Self.docLine), style: "HEADING_2", day: day)
        try? await docs.insert(heading: Self.headingText(tail), body: "",
                               at: tail.docIndex, before: tail.lines.first.map(Self.docLine), style: "HEADING_2", day: day)
        var log = load(day)
        guard let i = log.conversations.firstIndex(where: { $0.start == start }),
              let cut = log.conversations[i].lines.firstIndex(where: { $0.time == time }), cut > 0 else { return nil }
        var first = log.conversations[i]
        let lines = first.lines
        first.lines = Array(lines[..<cut])
        first.end = first.lines.last?.time ?? first.start
        first.resummarize = true
        var second = Conversation(start: time, end: max(c.end, time), docIndex: first.docIndex)
        second.lines = Array(lines[cut...])
        second.closed = true
        second.place = first.place
        second.scene = first.scene
        second.resummarize = true
        // 人物ノートと議事録は、元の会話で済んでいれば、分けた後ろの会話でもう一度作らない
        second.notesWritten = first.notesWritten
        second.minutes = first.minutes
        log.conversations[i] = first
        log.conversations.append(second)
        log.redoSummary = true
        save(log, day: day)
        return gap
    }

    /// 本人が AI の質問に答えた会話の見出しと要点を、あとで作り直す（閉じた会話だけ）
    func markResummarize(start: Date, day: String) {
        var log = load(day)
        guard let i = log.conversations.firstIndex(where: { $0.start == start }), log.conversations[i].closed else { return }
        log.conversations[i].resummarize = true
        save(log, day: day)
    }

    /// 議事録を作った会話に、そのドキュメントの名前を記す
    /// 会話に場面を記す（2026-11-06）
    func setScene(_ scene: String, start: Date, day: String) {
        var log = load(day)
        guard let i = log.conversations.firstIndex(where: { $0.start == start }) else { return }
        log.conversations[i].scene = scene
        save(log, day: day)
    }

    /// 2つの声のモデルで話し手が食い違った行に印を付ける（2026-11-06。記録の話し手は変えない）
    func markSpeakerDoubt(_ other: String, time: Date, day: String) {
        var log = load(day)
        for i in log.conversations.indices {
            guard let k = log.conversations[i].lines.firstIndex(where: { $0.time == time }) else { continue }
            guard log.conversations[i].lines[k].speakerDoubt != other else { return }
            log.conversations[i].lines[k].speakerDoubt = other
            save(log, day: day)
            return
        }
    }

    func setMinutes(_ name: String, start: Date, day: String) {
        var log = load(day)
        guard let i = log.conversations.firstIndex(where: { $0.start == start }) else { return }
        log.conversations[i].minutes = name
        save(log, day: day)
    }

    // MARK: - 直したあとのまとめ直し

    /// 見出しと要点を作り直す会話の数と、1日のまとめを作り直す日の数
    func resummarizeCounts() -> (conversations: Int, days: Int) {
        var conversations = 0, days = 0
        for day in self.days() {
            let log = load(day)
            let count = log.conversations.filter { $0.resummarize == true }.count
            conversations += count
            if count > 0 || log.redoSummary == true { days += 1 }
        }
        return (conversations, days)
    }

    /// 手で文字を直した会話の見出しと要点を作り直し、ドキュメントの見出しも置き換える。
    /// その日の会話がそろったら、1日のまとめも作り直して置き換える（今日の分は日が変わってから）。
    /// skipping の日（まだ直している途中の日）は飛ばす。作り直した会話の数を返す。
    func resummarize(today: String, skipping: Set<String> = []) async -> Int {
        guard let key = apiKey() else { return 0 }
        var budget = Self.fillBudget
        var done = 0
        for day in days().reversed() where !skipping.contains(day) {
            for c in load(day).conversations where c.resummarize == true {
                guard budget > 0 else { return done }
                let transcript = c.lines.filter { $0.media == nil }.map { line in
                    (line.speaker.map { "[\($0)] " } ?? "") + line.text
                }.joined(separator: "\n")
                var summary: Summarizer.Conversation?
                if c.closed && transcript.count >= Self.minimumCharacters {
                    budget -= transcript.count
                    let range = "\(timeFormatter.string(from: c.start))〜\(timeFormatter.string(from: c.end))"
                    let event = await eventInfo(c.start, c.end)
                    guard let made = try? await Summarizer.$sensitive.withValue(isWork(c.start), operation: {
                        try await Summarizer.conversation(transcript, timeRange: range, selfShare: Self.selfShare(c),
                                                          event: event?.detail, apiKey: key)
                    }) else { return done }
                    summary = made
                }
                guard await replaceTitle(summary, of: c, day: day) else { return done }
                if summary != nil { done += 1 }
            }
            let log = load(day)
            if log.redoSummary == true, day < today, log.conversations.allSatisfy(\.closed),
               !log.conversations.contains(where: { $0.resummarize == true }) {
                guard budget > 0, await redoDailySummary(day, key: key) else { return done }
                budget -= 3_000
            }
        }
        return done
    }

    /// 作り直した見出しと要点を当てる。summary が nil（短い会話など）なら印を外すだけ。
    private func replaceTitle(_ summary: Summarizer.Conversation?, of c: Conversation, day: String) async -> Bool {
        var updated = c
        updated.resummarize = nil
        if let summary, !summary.title.isEmpty {
            updated.title = summary.title
            updated.points = summary.points
        }
        let changed = updated.title != c.title || updated.points != c.points
        if changed {
            do {
                // 前の見出しを要点ごと消して、新しい見出しを会話の最初の行の前に入れる
                _ = try await docs.deleteParagraphs([], headings: [Self.headingText(c)], day: day)
                try await docs.insert(heading: Self.headingText(updated), body: updated.points.map { "・" + $0 + "\n" }.joined(),
                                      at: c.docIndex, before: c.lines.first.map(Self.docLine), style: "HEADING_2", day: day)
            } catch {
                return false
            }
        }
        // 書いているあいだに記録が変わっていてもよいように、読み直してから置き換える
        var log = load(day)
        guard let i = log.conversations.firstIndex(where: { $0.start == c.start }) else { return true }
        log.conversations[i].resummarize = nil
        if changed {
            log.conversations[i].title = updated.title
            log.conversations[i].points = updated.points
            if log.summaryWritten { log.redoSummary = true }
        }
        save(log, day: day)
        return true
    }

    /// 1日のまとめを作り直し、ドキュメントの先頭のまとめ（あとから書き足した分も）を置き換える。
    /// 家の PC のまとめを載せた日は、ドキュメントは置き換えず、中身（週のまとめに使う）だけ作り直す（2026-11-10）
    private func redoDailySummary(_ day: String, key: String) async -> Bool {
        guard let made = await dailySummary(load(day), day: day, key: key) else { return false }
        if !HomeSummaryLog.isWritten(day) {
            do {
                _ = try await docs.deleteDaySummary(day: day)
                try await docs.insert(heading: "1日のまとめ", body: made.body, at: 1, style: "HEADING_1", day: day)
            } catch {
                return false
            }
        }
        var log = load(day)
        log.summary = made.summary
        log.summaryWritten = true
        log.summaryStale = nil
        log.redoSummary = nil
        save(log, day: day)
        return true
    }

    // MARK: - 話者の手直し

    /// match に当たる行の話者を name（番号 id）にし、ドキュメントの同じ行も直す。直した行の数を返す。
    /// renaming を渡すと、会話の見出しの「〇〇と」も置き換える（人の名前を付け替えたとき）。
    /// 記録はいつも直す。ドキュメントを直せなかった日は、直しを覚えて次の機会にやり直す（docError に最初のエラー）。
    @discardableResult
    func relabel(to id: String, name: String, renaming: String? = nil,
                 where match: (Line) -> Bool) async -> (count: Int, docError: Error?) {
        var changed = 0
        var docError: Error?
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
            if !fixes.isEmpty { await fixDoc(fixes, day: day, error: &docError) }
            save(log, day: day)
        }
        return (changed, docError)
    }

    /// match に当たる行を、テレビ・動画・ラジオなどの放送の行（kind）にし、ドキュメントの同じ行も直す。
    /// 夜の見分けと同じく、元の名前と番号は heardSpeaker / heardSpeakerID に残す。直した行の数を返す。
    /// 記録はいつも直す。ドキュメントを直せなかった日は、直しを覚えて次の機会にやり直す（docError に最初のエラー）。
    /// dropping を渡すと、会話の見出しの「〇〇と」からその名前を外す（名前を付けた人を放送の声にしたとき。2026-11-09）。
    @discardableResult
    func markMedia(_ kind: String, dropping name: String? = nil,
                   where match: (Line) -> Bool) async -> (count: Int, docError: Error?) {
        var changed = 0
        var docError: Error?
        for day in days() {
            var log = load(day)
            var fixes: [(find: String, replace: String)] = []
            for c in log.conversations.indices {
                for l in log.conversations[c].lines.indices {
                    let line = log.conversations[c].lines[l]
                    guard line.media == nil, match(line) else { continue }
                    log.conversations[c].lines[l].media = kind
                    log.conversations[c].lines[l].heardSpeaker = line.speaker
                    log.conversations[c].lines[l].heardSpeakerID = line.speakerID
                    log.conversations[c].lines[l].speaker = kind
                    log.conversations[c].lines[l].speakerID = nil
                    fixes.append((find: Self.docLine(line), replace: Self.docLine(log.conversations[c].lines[l])))
                    changed += 1
                }
            }
            guard !fixes.isEmpty else { continue }
            if let name, !name.isEmpty { fixes += Self.headingFixes(dropping: name) }
            await fixDoc(fixes, day: day, error: &docError)
            save(log, day: day)
        }
        return (changed, docError)
    }

    /// 見出しの相手（「　A、Bと」の形）から name を外す置き換え。ほかの人が残るときは「、」をつめ、name だけなら「　nameと」ごと外す。
    static func headingFixes(dropping name: String) -> [(find: String, replace: String)] {
        [("、" + name + "と", "と"), ("　" + name + "、", "　"), ("、" + name + "、", "、"), ("　" + name + "と", "")]
    }

    // MARK: - ドキュメントの直しのやり直し（2026-11-08）

    /// ドキュメントに当てられなかった直し（日ごと）。記録の中はもう直っている。端末ごとのファイルで、同期しない。
    private static let docFixesURL = URL.applicationSupportDirectory.appendingPathComponent("doc-fixes.json")

    /// まだドキュメントに当てていない直し（日 → 直し）
    func pendingDocFixes() -> [String: DocFixQueue] {
        guard let data = try? Data(contentsOf: Self.docFixesURL),
              let value = try? JSONDecoder().decode([String: DocFixQueue].self, from: data) else { return [:] }
        return value
    }

    private func savePendingDocFixes(_ value: [String: DocFixQueue]) {
        if value.isEmpty {
            try? FileManager.default.removeItem(at: Self.docFixesURL)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: Self.docFixesURL, options: .atomic)
    }

    /// その日のドキュメントに直しを当てる。前に当てられなかった直しがあれば、それを先に当てる
    /// （名前を2回直したとき、順に当てないと合わない）。当てられなければ覚えておき、error が空なら入れる。
    /// 前の日で失敗していれば（error がある）、この日は送らずに覚えるだけにする。
    private func fixDoc(_ fixes: [(find: String, replace: String)], day: String, error: inout Error?) async {
        let new = fixes.map { DocFix(find: $0.find, replace: $0.replace) }
        if error != nil {
            var pending = pendingDocFixes()
            pending[day] = DocFixQueue(fixes: (pending[day]?.fixes ?? []) + new, failures: pending[day]?.failures ?? 0)
            savePendingDocFixes(pending)
            return
        }
        if let failed = await applyDocFixes(new, day: day) { error = failed }
    }

    /// 覚えている直しと new を、その日のドキュメントに当てる。失敗したらエラーを返す（直しは覚えたまま）。
    private func applyDocFixes(_ new: [DocFix], day: String) async -> Error? {
        let snapshot = pendingDocFixes()[day]
        let tried = (snapshot?.fixes ?? []) + new
        guard !tried.isEmpty else { return nil }
        var failure: Error?
        do {
            try await docs.replaceAll(tried.map { (find: $0.find, replace: $0.replace) }, day: day)
        } catch {
            failure = error
        }
        // 待っているあいだに、同じ日の直しが足されたかもしれないので、読み直して合わせる
        var pending = pendingDocFixes()
        pending[day] = DocFixQueue.after(tried: tried, snapshot: snapshot?.fixes ?? [], now: pending[day],
                                         failed: failure != nil, failures: snapshot?.failures ?? 0)
        savePendingDocFixes(pending)
        return failure
    }

    /// 前に当てられなかったドキュメントの直しを、日の順にやり直す。失敗したら（止められたときも）そこでやめる。
    func retryDocFixes() async {
        for day in pendingDocFixes().keys.sorted() {
            if Task.isCancelled { return }
            if await applyDocFixes([], day: day) != nil { return }
        }
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
    /// 前に書いた日でも、中身が残っていない日や、あとから見出しが増えた日は、見出しがそろってから書き足す。
    func writeDailySummaries(today: String) async {
        guard let key = apiKey() else { return }
        for day in days() where day < today {
            var log = load(day)
            guard !log.conversations.isEmpty, log.conversations.allSatisfy(\.closed) else { continue }
            let again = log.summaryWritten
            if again {
                guard log.summary == nil || log.summaryStale == true,
                      !log.conversations.contains(where: { Self.needsTitle($0) }) else { continue }
            }
            guard log.conversations.contains(where: { $0.title != nil }) else {
                if !again {
                    log.summaryWritten = true
                    save(log, day: day)
                }
                continue
            }
            guard let made = await dailySummary(log, day: day, key: key) else { continue }
            let summary = made.summary, body = made.body
            // ドキュメントにまとめがある日は、二重に書かない（見出しが増えた日だけ、書き足した分として入れる）。
            // 家の PC のまとめを載せた日は、ドキュメントには書かず、中身（週のまとめに使う）だけ残す（2026-11-10）
            let home = HomeSummaryLog.isWritten(day)
            var exists = home
            if again && !home { exists = (try? await docs.hasParagraph("1日のまとめ", day: day)) ?? true }
            do {
                if !home && (!exists || log.summaryStale == true) {
                    try await docs.insert(heading: exists ? "1日のまとめ（あとから書き足した分）" : "1日のまとめ",
                                          body: body, at: 1, style: "HEADING_1", day: day)
                }
                log.summaryWritten = true
                log.summaryStale = nil
                log.summary = summary
                save(log, day: day)
            } catch {
                continue
            }
        }
    }

    /// 家の PC が作った1日のまとめで、その日のドキュメントの先頭の「1日のまとめ」（あとから書き足した分も）を置き換える（2026-11-10）。
    /// 言語モデルは使わない。書けたら true
    func writeHomeSummary(day: String, body: String) async -> Bool {
        do {
            _ = try await docs.deleteDaySummary(day: day)
            try await docs.insert(heading: "1日のまとめ", body: body, at: 1, style: "HEADING_1", day: day)
            return true
        } catch {
            return false
        }
    }

    /// 1日のまとめの中身と、ドキュメントに書く本文。作れなければ nil。
    private func dailySummary(_ log: Day, day: String, key: String) async -> (summary: Summarizer.Day, body: String)? {
        await Summarizer.$sensitive.withValue(sensitive(log.conversations)) {
            await makeDailySummary(log, day: day, key: key)
        }
    }

    private func makeDailySummary(_ log: Day, day: String, key: String) async -> (summary: Summarizer.Day, body: String)? {
        // 1日の流れのために、見出しの無い短い会話も時刻と場所だけは渡す
        let overview = log.conversations.map { c in
            let place = c.place.map { "・" + $0 } ?? ""
            let people = c.people.isEmpty ? "" : "（\(c.people.joined(separator: "、"))と）"
            let media = c.media.map { "［\($0)\(c.program.map { "「\($0)」" } ?? "")を流していた］" } ?? ""
            let head = "\(timeFormatter.string(from: c.start))〜\(timeFormatter.string(from: c.end))\(place)\(people)\(media) \(c.title ?? "（短い会話）")"
            return ([head] + c.points.map { "  ・" + $0 }).joined(separator: "\n")
        }.joined(separator: "\n")
        guard var summary = try? await Summarizer.day(overview, apiKey: key) else { return nil }
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
        if let dayStart = Self.dayFormatter.date(from: day), let health = await healthLine(dayStart) {
            body += "体調: " + health + "\n"
        }
        let tense = log.conversations.filter { $0.tense == true }
        if !tense.isEmpty {
            section("心拍が上がっていた会話", tense.map { c in
                "\(timeFormatter.string(from: c.start))〜\(timeFormatter.string(from: c.end))　\(c.title ?? "")（最大 \(c.heartRateMax ?? 0)）"
            })
        }
        section("決まったこと", summary.decisions)
        section("やること", summary.todos)
        section("話題", summary.topics)
        body += "\n"
        return (summary, body)
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
        let work = sensitive(logs.flatMap(\.conversations))
        guard let summary = try? await Summarizer.$sensitive.withValue(work, operation: {
            try await Summarizer.week(material, apiKey: key)
        }) else { return }

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

    // MARK: - 月のまとめ

    /// 月が変わったら、先月のまとめを「月のまとめ 2026-10」というドキュメントに書く。
    /// その月の1日のまとめがそろうまで待つ。よく話した人と数字は記録から数え、流れ・決まったこと・やること・話題は言語モデルにまとめてもらう。
    func writeMonthlySummary(today: String) async {
        guard let key = apiKey(), let todayDate = Self.dayFormatter.date(from: today) else { return }
        let calendar = Calendar(identifier: .gregorian)
        guard let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: todayDate)),
              let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) else { return }
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "yyyy-MM"
        let month = monthFormatter.string(from: lastMonth)
        let doneKey = "month-" + month
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let present = days().filter { $0.hasPrefix(month + "-") }
        guard !present.isEmpty else { return }
        let logs = present.map { load($0) }
        guard logs.allSatisfy({ $0.summaryWritten || $0.conversations.isEmpty }) else { return }

        let label = DateFormatter()
        label.locale = Locale(identifier: "ja_JP")
        label.dateFormat = "M/d(E)"
        let budget = max(150, 9_000 / present.count)
        var material = ""
        var marked: [String] = []
        var talks: [String: (count: Int, days: Set<String>)] = [:]
        var conversationCount = 0
        var talkSeconds: TimeInterval = 0
        for (day, log) in zip(present, logs) {
            guard let date = Self.dayFormatter.date(from: day) else { continue }
            var part = "## " + label.string(from: date) + "\n"
            if let summary = log.summary {
                part += "流れ: " + summary.flow.joined(separator: "／") + "\n"
                if !summary.decisions.isEmpty { part += "決まったこと: " + summary.decisions.joined(separator: "／") + "\n" }
                if !summary.todos.isEmpty { part += "やること: " + summary.todos.joined(separator: "／") + "\n" }
            } else {
                for c in log.conversations where c.title != nil {
                    part += timeFormatter.string(from: c.start) + " " + (c.place ?? "") + " " + (c.title ?? "") + "\n"
                }
            }
            let people = Array(NSOrderedSet(array: log.conversations.flatMap(\.people))) as? [String] ?? []
            if !people.isEmpty { part += "会った人: " + people.joined(separator: "、") + "\n" }
            material += String(part.prefix(budget)) + "\n"
            for c in log.conversations where c.media == nil {
                conversationCount += 1
                talkSeconds += c.end.timeIntervalSince(c.start)
                for name in c.people where !name.hasPrefix("人物") {
                    var entry = talks[name] ?? (0, [])
                    entry.count += 1
                    entry.days.insert(day)
                    talks[name] = entry
                }
                for line in c.lines where line.marked == true {
                    marked.append(label.string(from: date) + " " + timeFormatter.string(from: line.time) + "　" + line.text)
                }
            }
        }
        let work = sensitive(logs.flatMap(\.conversations))
        guard let summary = try? await Summarizer.$sensitive.withValue(work, operation: {
            try await Summarizer.month(material, apiKey: key)
        }) else { return }

        var body = ""
        func section(_ name: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            body += name + "\n" + items.map { "・" + $0 + "\n" }.joined()
        }
        section("数字", ["記録のある日 \(present.count) 日", "会話 \(conversationCount) 回",
                         String(format: "話していた時間 約 %.0f 時間", talkSeconds / 3600)])
        section("1か月の流れ", summary.flow)
        section("よく話した人", talks.sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }.prefix(10)
            .map { "\($0.key)：会話 \($0.value.count) 回（\($0.value.days.count) 日）" })
        section("決まったこと", summary.decisions)
        section("やること（残っていそうなもの）", summary.todos)
        section("話題", summary.topics)
        section("★ 印を付けたところ", marked.prefix(15).map { $0.count > 100 ? String($0.prefix(100)) + "…" : $0 })
        body += "\n"
        let title = "月のまとめ（\(Calendar(identifier: .gregorian).component(.year, from: lastMonth))年\(Calendar(identifier: .gregorian).component(.month, from: lastMonth))月）"
        do {
            try await docs.insert(heading: title, body: body, at: 1, style: "HEADING_1", day: "月のまとめ " + month)
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

    /// 声の番号ごとの、すべての日の行の数（名前の無い声の整理に使う。2026-11-09）
    func speakerLineCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for day in days() {
            for line in load(day).conversations.flatMap(\.lines) {
                if let id = line.speakerID { counts[id, default: 0] += 1 }
            }
        }
        return counts
    }

    /// 同じ音声の区切りの中で別の声とされた2人（番号の小さい順の組。すべての日）。別の人なので、まとめない
    func voicesHeardTogether() -> Set<[String]> {
        var pairs = Set<[String]>()
        for day in days() {
            let lines = load(day).conversations.flatMap(\.lines).filter { $0.audio != nil && $0.speakerID != nil }
            for (_, group) in Dictionary(grouping: lines, by: { $0.audio ?? "" }) {
                let ids = Array(Set(group.compactMap(\.speakerID))).sorted()
                for a in ids.indices { for b in ids.indices where a < b { pairs.insert([ids[a], ids[b]]) } }
            }
        }
        return pairs
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

    /// 読んだ日の記録。ファイルを書いた時刻が同じなら読み直さない（5分ごとの処理で、全部の日を何度も読むため）。
    /// 覚えるのはファイルの大きさで cacheLimit まで。超えたら、長く使っていない日から忘れる。
    private var cache: [String: (modified: Date, bytes: Int, used: Int, log: Day)] = [:]
    private var cacheUse = 0
    private static let cacheLimit = 48 * 1024 * 1024

    /// ファイルから読んだ回数と、かかった時間（診断に出す。覚えていた分は数えない）
    private(set) var loadStats = (files: 0, bytes: 0, seconds: 0.0)

    private func load(_ day: String) -> Day {
        let url = Self.dir.appendingPathComponent(day + ".json")
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        cacheUse += 1
        if let modified, let hit = cache[day], hit.modified == modified {
            cache[day]?.used = cacheUse
            return hit.log
        }
        let started = Date()
        guard let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode(Day.self, from: data) else {
            cache[day] = nil
            return Day()
        }
        loadStats.files += 1
        loadStats.bytes += data.count
        loadStats.seconds += Date().timeIntervalSince(started)
        if let modified { remember(day, log, modified: modified, bytes: data.count) }
        return log
    }

    private func remember(_ day: String, _ log: Day, modified: Date, bytes: Int) {
        cache[day] = (modified, bytes, cacheUse, log)
        var total = cache.values.reduce(0) { $0 + $1.bytes }
        while total > Self.cacheLimit, cache.count > 1,
              let oldest = cache.filter({ $0.key != day }).min(by: { $0.value.used < $1.value.used }) {
            total -= oldest.value.bytes
            cache[oldest.key] = nil
        }
    }

    /// 覚えている日の数と大きさ（診断に出す）
    var cacheStats: (days: Int, bytes: Int) { (cache.count, cache.values.reduce(0) { $0 + $1.bytes }) }

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
        let url = Self.dir.appendingPathComponent(day + ".json")
        cache[day] = nil
        guard let data = try? JSONEncoder().encode(log),
              (try? data.write(to: url, options: .atomic)) != nil,
              let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return }
        cacheUse += 1
        remember(day, log, modified: modified, bytes: data.count)
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
                       summaryWritten: log.summaryWritten, summary: log.summary, build: AppBuild.current)
    }

    /// ほかの端末の1日分を合わせる。会話ごとに番号（rev）の大きいほうを残し、同じなら中身で決める（どちらの端末でも同じ結果になるように）。
    /// この端末で続いている会話には触らない。変わったら true。
    /// 送ってきた端末の版が知らない項目（SyncFill の一覧にあるものだけ）は、手元の値で埋める（2026-11-06）。myBuild は使っていない（前の呼び方のため残す）
    @discardableResult
    func mergeRemote(_ remote: SyncDay, day: String, myBuild: Int = AppBuild.current) -> Bool {
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
                let taken = SyncFill.filledConversation(rc, keeping: lc, senderBuild: remote.build)
                if rr > lr {
                    log.conversations[i] = taken
                    changed = true
                } else if rr == lr {
                    let a = Self.content(lc), b = Self.content(taken)
                    if a != b && a.lexicographicallyPrecedes(b) {
                        log.conversations[i] = taken
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

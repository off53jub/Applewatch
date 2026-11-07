import Foundation
import Observation
import SwiftUI

// 毎朝の「聞いて直す」（2026-11-07）。
// あなた向けの Whisper の学び直し（家の PC）は、材料（手で直した行・答え合わせで答えた行）が300個たまると始まる。
// 早くためるため、毎朝、自信の低い行（確からしさが低い・家の PC のモデルが食い違った）で聞き直しの音声がある行を
// 10行ほど選び、▶ で聞いて「直す・合っている・飛ばす」で答えてもらう。
// - 「直す」は、記録の「文字を直す」と同じ直し（Pipeline.editLine。手で直した行になり、夜に材料として送られる）。
// - 「合っている」は、答え合わせの「文字は合っている」と同じく、記録は変えずに正しい文が分かった行として残し、夜に材料として送る。
// 中身は新しいファイル `review-nudge.json`（端末ごと・同期しない）と、行の所の音の切り出し `review-clips/`。
// 言語モデルは使わない（職場の会話の扱いの設定には関わらない）。

/// 「聞いて直す」の選び方と、画面・朝の読み上げ・知らせの文
enum ReviewNudge {
    /// 1日に出す行の数
    static let perDay = 10
    /// これより前の行は選ばない（iPhone の中の音声は26時間で消えるので、新しい行ほど聞きやすい）
    static let window: TimeInterval = 72 * 3600
    /// 1つの会話から選ぶ行の上限
    static let maxPerConversation = 3
    /// 1行にかかる時間の目安（秒）。10行で3分ほど
    static let secondsPerLine = 18.0
    /// 朝に知らせるか（初めはオン）
    static let noticeKey = "reviewNudgeNotice"
    static var noticeOn: Bool { UserDefaults.standard.object(forKey: noticeKey) as? Bool ?? true }
    /// 朝の読み上げを知らせない設定のときに、これだけを知らせる通知の印
    static let noticeID = "review-nudge"
    /// 直したところを誤変換の一覧にも足すか（この画面では初めはオフ。前に選んだほうを覚える）
    static let addFixKey = "reviewNudgeAddFix"
    /// 朝の読み上げの中で、この1文を見分ける言葉
    static let briefMark = "聞いて直す"

    /// 選んだわけ
    enum Reason: String, Codable {
        /// 確からしさが低い（記録で「？」の行）
        case low
        /// 家の PC のモデルが食い違った
        case votes

        /// 知らない値は「確からしさが低い」として読む（あとの版で増えても、ファイルを読めなくしない）
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Reason(rawValue: raw) ?? .low
        }
    }

    /// 答え
    enum Answer: String, Codable {
        case fixed, ok, skipped

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Answer(rawValue: raw) ?? .skipped
        }
    }

    /// 選んだ1行と、その答え
    struct Item: Codable, Identifiable, Equatable {
        /// 日と行の時刻（答え合わせの問いと同じ形。同じ行を2度選ばないのに使う）
        var id: String
        /// どの日の組か（yyyy-MM-dd）
        var setDay: String
        /// 行のある日（yyyy-MM-dd）と、選んだときの会話の始まり
        var day: String
        var talk: Date
        var time: Date
        /// 選んだときの文と話した人
        var text: String
        var speaker: String? = nil
        /// 聞き直しの音声の名前と、その中での行の位置・終わり（秒）
        var audio: String
        var offset: TimeInterval
        var end: TimeInterval? = nil
        var confidence: Double? = nil
        /// 家の PC のモデルごとの文（食い違った行だけ）
        var votes: [String: String]? = nil
        var noisy: Bool? = nil
        var reasons: [Reason] = []
        /// 会話の見出しと場所（画面に出すだけ）
        var title: String? = nil
        var place: String? = nil
        var answer: Answer? = nil
        /// 正しい文（直した文か、合っていた文）
        var right: String? = nil
        var answered: Date? = nil
        /// 切り出して残した音（review-clips の中の名前）と、元の音声の中での始まり・終わり（秒）
        var clip: String? = nil
        var clipFrom: TimeInterval? = nil
        var clipTo: TimeInterval? = nil

        var isAnswered: Bool { answer != nil }
    }

    /// 選ぶ候補（行と、先に選ぶ度合い）
    struct Candidate {
        var item: Item
        var score: Double
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let captionTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d（E）HH:mm"
        return f
    }()

    private static let statusTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// 行の印（答え合わせの問いの id と同じ形）
    static func itemID(day: String, time: Date) -> String { day + "|" + String(Int(time.timeIntervalSince1970)) }

    // MARK: 選ぶ

    /// 家の PC のモデルの文が食い違っているか（空白・句読点の違いは見ない）
    static func votesDisagree(_ line: ConversationLog.Line) -> Bool {
        let texts = Set((line.votes ?? [:]).values.map { String(AnswerKey.normalized($0)) }.filter { !$0.isEmpty })
        guard !texts.isEmpty else { return false }
        return texts.count >= 2 || !texts.contains(String(AnswerKey.normalized(line.text)))
    }

    /// 選ぶわけ（無ければ空。手で直した行・テレビなどの行は選ばない）
    static func reasons(_ line: ConversationLog.Line) -> [Reason] {
        guard line.checked != true, line.media == nil else { return [] }
        var out: [Reason] = []
        if line.isUncertain { out.append(.low) }
        if votesDisagree(line) { out.append(.votes) }
        return out
    }

    /// 材料にできる行か。音声が無い・短すぎる（4文字より短い）行と、音声の区間が長すぎる行は選ばない
    /// （家の PC は30秒より長い材料を受け付けない。終わりの分からない行は、夜に送るときと同じく文字数で長さを見積もるので80文字まで）
    static func usable(_ line: ConversationLog.Line) -> Bool {
        guard line.media == nil, line.checked != true, line.audio != nil, let offset = line.offset else { return false }
        guard AnswerKey.normalized(line.text).count >= 4 else { return false }
        if let end = line.end { return end - offset >= 0.5 && end - offset <= 25 }
        return line.text.count <= 80
    }

    /// 先に選ぶ度合い。文字が違っている見込み（学んだ重みがあればそれ、無ければ 1 − 確からしさ）に、
    /// モデルが食い違った行と、iPhone の中に音声が残っている行（ネットが無くても聞ける）を足す
    static func score(confidence: Double?, chance: Double?, votes: Bool, local: Bool) -> Double {
        var s = chance ?? (1 - min(1, max(0, confidence ?? 0.6)))
        if votes { s += 0.15 }
        if local { s += 0.1 }
        return s
    }

    /// 選んだ1行を作る（音声と位置が無ければ nil）
    static func item(_ line: ConversationLog.Line, id: String, day: String, conversation c: ConversationLog.Conversation,
                     reasons: [Reason]) -> Item? {
        guard let audio = line.audio, let offset = line.offset else { return nil }
        return Item(id: id, setDay: "", day: day, talk: c.start, time: line.time, text: line.text, speaker: line.speaker,
                    audio: audio, offset: offset, end: line.end, confidence: line.confidence, votes: line.votes,
                    noisy: line.noisy, reasons: reasons, title: c.title, place: c.place)
    }

    /// 度合いの高い順に count 行まで選ぶ（1つの会話から perConversation 行まで）。時刻の順に並べて返す
    static func pick(_ candidates: [Candidate], count: Int,
                     perConversation: Int = ReviewNudge.maxPerConversation) -> [Item] {
        let ordered = candidates.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.item.time > b.item.time
        }
        var picked: [Item] = []
        var taken = Set<String>()
        var perTalk: [String: Int] = [:]
        for candidate in ordered where picked.count < count {
            let item = candidate.item
            let talk = item.day + "|" + String(item.talk.timeIntervalSince1970)
            guard !taken.contains(item.id), perTalk[talk, default: 0] < perConversation else { continue }
            taken.insert(item.id)
            perTalk[talk, default: 0] += 1
            picked.append(item)
        }
        return picked.sorted { $0.time < $1.time }
    }

    /// いま答える行（押して選んだ行がまだなら、それ。無ければ、まだ答えていない最初の行）
    static func current(in items: [Item], chosen: String?) -> Item? {
        if let chosen, let item = items.first(where: { $0.id == chosen && !$0.isAnswered }) { return item }
        return items.first { !$0.isAnswered }
    }

    /// 答えたあとに進む行（後ろのまだの行。無ければ前のまだの行。どれも答えたら nil）
    static func next(in items: [Item], after id: String) -> Item? {
        let first = items.first(where: { !$0.isAnswered })
        guard let i = items.firstIndex(where: { $0.id == id }) else { return first }
        return items[(i + 1)...].first(where: { !$0.isAnswered }) ?? first
    }

    // MARK: 片付ける

    /// 夜に材料として送ったか（「直す」「合っている」の行だけ。PC に送った印は sendPersonalSamples と同じ形）
    static func isSent(_ item: Item, _ sent: Set<String>) -> Bool {
        guard item.answer == .ok || item.answer == .fixed, let right = item.right else { return false }
        return sent.contains(PersonalMaterial.sampleID(audio: item.audio, offset: item.offset, right: right))
    }

    /// 残すものと、消す音。答えなかった前の日の行は捨てる（また選ばれることがある）。飛ばした行は14日、答えた行は30日で捨てる。
    /// 飛ばした行と、材料として送り終えた行の音はもう要らない
    static func pruned(_ items: [Item], today: String, now: Date, sent: Set<String>) -> (items: [Item], removedClips: [String]) {
        var kept: [Item] = []
        var removed: [String] = []
        for var item in items {
            let age = item.answered.map { now.timeIntervalSince($0) } ?? 0
            let drop: Bool
            switch item.answer {
            case nil: drop = item.setDay != today
            case .skipped?: drop = age > 14 * 86400
            case .fixed?, .ok?: drop = age > 30 * 86400
            }
            if drop {
                if let clip = item.clip { removed.append(clip) }
                continue
            }
            if let clip = item.clip, item.answer == .skipped || isSent(item, sent) {
                removed.append(clip)
                item.clip = nil
                item.clipFrom = nil
                item.clipTo = nil
            }
            kept.append(item)
        }
        return (kept, removed)
    }

    /// 「合っている」と答えた行を、正しい文が分かっている行（答え合わせの答えと同じ形）にする
    static func truth(_ item: Item) -> AnswerKey.Truth? {
        guard item.answer == .ok, let right = item.right?.trimmingCharacters(in: .whitespacesAndNewlines),
              !right.isEmpty else { return nil }
        return AnswerKey.Truth(right: right, votes: item.votes, noisy: item.noisy == true, audio: item.audio,
                               offset: item.offset, end: item.end, time: item.time)
    }

    // MARK: 音

    /// 切り出す所（行の1.5秒前から、終わりの1秒後まで。終わりが分からなければ16.5秒後まで）。
    /// 夜に送る材料の区間（Benchmark.span）がいつも中に入る。duration は元の音声の長さ（分からなければ 0）
    static func clipWindow(offset: TimeInterval, end: TimeInterval?, duration: TimeInterval) -> (from: TimeInterval, to: TimeInterval)? {
        let from = max(0, offset - 1.5)
        var to = end.map { max($0, offset) + 1.0 } ?? (offset + 16.5)
        if duration > 0 { to = min(to, duration) }
        return to > from + 0.5 ? (from, to) : nil
    }

    static func clipName(_ id: String) -> String {
        id.replacingOccurrences(of: "|", with: "_").replacingOccurrences(of: "/", with: "_") + ".m4a"
    }

    /// 聞く所の終わり（秒）。終わりが分かればそこまで、分からなければ文字数から見積もり、同じ音声の次の行の頭で止める
    static func stop(offset: TimeInterval, end: TimeInterval?, next: TimeInterval?, chars: Int) -> TimeInterval {
        if let end, end > offset { return end }
        let guess = offset + min(15, max(2.5, Double(chars) * 0.17 + 1.0))
        if let next, next > offset + 0.5 { return min(next, guess) }
        return guess
    }

    // MARK: 文

    /// 何分ほどか（1分から）
    static func minutes(for count: Int) -> Int { max(1, Int((Double(count) * secondsPerLine / 60).rounded())) }

    /// 「今日」の入口の文
    static func entryTitle(total: Int, left: Int) -> String {
        left >= total ? "今日の聞いて直す（\(total)行・\(minutes(for: total))分ほど）"
            : "今日の聞いて直す（あと \(left) 行・\(minutes(for: left))分ほど）"
    }

    /// 朝の読み上げの1文（0行なら nil）
    static func briefSentence(count: Int) -> String? {
        count > 0 ? "今日の\(briefMark)は\(count)行、\(minutes(for: count))分ほどです。" : nil
    }

    /// 朝の知らせの1行（0行なら nil）
    static func noticeLine(count: Int) -> String? {
        count > 0 ? "今日の\(briefMark): \(count)行（\(minutes(for: count))分ほど）" : nil
    }

    /// 朝の読み上げを知らせないときの、ひとりで出す知らせの本文
    static func noticeBody(count: Int) -> String {
        "\(count)行・\(minutes(for: count))分ほどです。自信の低い行を聞いて、直すか「合っている」を押すと、あなた向けの Whisper の材料がたまります。"
    }

    static func reasonText(_ reasons: [Reason]) -> String {
        reasons.map { $0 == .low ? "確からしさが低い" : "モデルが食い違った" }.joined(separator: "・")
    }

    /// 画面の行の頭（日時・場所・見出し）
    static func caption(_ item: Item) -> String {
        ([captionTime.string(from: item.time)] + [item.place, item.title].compactMap { $0 }.filter { !$0.isEmpty })
            .joined(separator: "・")
    }

    /// 一覧の行の下の文（日時と答え）
    static func status(_ item: Item) -> String {
        let when = statusTime.string(from: item.time)
        switch item.answer {
        case .fixed?: return when + "・直した"
        case .ok?: return when + "・合っている"
        case .skipped?: return when + "・飛ばした"
        case nil: return when + "・まだ"
        }
    }

    /// 前後の行の文（話した人つき）
    static func say(_ line: ConversationLog.Line) -> String {
        (line.speaker.map { "[\($0)] " } ?? "") + line.text
    }

    /// ほかのモデルの聞き取り（今の文と違うものを3つまで。押すと直す欄に入れる）
    static func alternatives(_ votes: [String: String]?, current: String) -> [String] {
        var seen: Set<String> = [String(AnswerKey.normalized(current))]
        var out: [String] = []
        for key in (votes ?? [:]).keys.sorted() {
            guard let text = votes?[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let plain = String(AnswerKey.normalized(text))
            guard !plain.isEmpty, seen.insert(plain).inserted else { continue }
            out.append(text)
            if out.count >= 3 { break }
        }
        return out
    }
}

/// 家の PC にたまった、あなた向けの Whisper の材料（2026-11-07）。
/// 数は家の PC の /train-status に聞けたときだけ新しくする（夜に送ったあと・「聞いて直す」と自己点検を開いたとき）
enum PersonalMaterial {
    /// 送った材料の印（sendPersonalSamples。「音声の名前|始まりの秒|文」）
    static let sentKey = "personalSent"
    static let countKey = "personalCount"
    static let modelKey = "personalModel"
    static let needKey = "personalNeed"
    static let atKey = "personalCountAt"
    static let missedKey = "personalCountMissed"
    /// 学び直しに要る数（家の PC の train_personal.py の MIN_SAMPLES と同じ）
    static let need = 300
    /// これより前に数えた数は出さない
    static let freshFor: TimeInterval = 24 * 3600

    struct Status: Equatable {
        var count: Int
        var need: Int
        var model: Bool
        var at: Date

        /// 学び直しまで、あと何個か
        var left: Int { max(0, need - count) }
    }

    /// 送った材料の印（夜に送るときと同じ形。同じ行を2度送らないのに使う）
    static func sampleID(audio: String, offset: TimeInterval, right: String) -> String {
        audio + "|" + String(format: "%.1f", Benchmark.span(offset: offset, chars: right.count).start) + "|" + right
    }

    static func sentIDs() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? []) }

    /// 家の PC に聞けた数を覚える
    @discardableResult
    static func note(count: Int, model: Bool, need: Int, at date: Date = .now) -> Status {
        let d = UserDefaults.standard
        d.set(count, forKey: countKey)
        d.set(model, forKey: modelKey)
        d.set(need, forKey: needKey)
        d.set(date, forKey: atKey)
        return Status(count: count, need: need, model: model, at: date)
    }

    /// 家の PC に聞けなかった（つながらない・PC が古い）。次に聞けるまで数を出さない
    static func noteMissed(at date: Date = .now) {
        UserDefaults.standard.set(date, forKey: missedKey)
    }

    /// 最後に家の PC に聞けた数（24時間より前か、そのあとつながらなかったら nil）
    static func latest(now: Date = .now) -> Status? {
        let d = UserDefaults.standard
        guard let at = d.object(forKey: atKey) as? Date, now.timeIntervalSince(at) <= freshFor else { return nil }
        if let missed = d.object(forKey: missedKey) as? Date, missed > at { return nil }
        let need = d.integer(forKey: needKey)
        return Status(count: d.integer(forKey: countKey), need: need > 0 ? need : Self.need,
                      model: d.bool(forKey: modelKey), at: at)
    }

    /// しばらく聞いていないか（自己点検を開いたときに聞き直すか決める）
    static func isStale(now: Date = .now, after: TimeInterval = 600) -> Bool {
        let d = UserDefaults.standard
        let last = [d.object(forKey: atKey) as? Date, d.object(forKey: missedKey) as? Date].compactMap { $0 }.max()
        return last.map { now.timeIntervalSince($0) > after } ?? true
    }

    /// 自己点検の文
    static func text(_ s: Status) -> String {
        s.left == 0 ? "\(s.count) 個・学び直せる数です（\(s.need) 個から）"
            : "\(s.count) 個・学び直しまであと \(s.left) 個（\(s.need) 個から）"
    }
}

/// 選んだ行・答え・切り出した音の帳（`review-nudge.json`。端末ごと・同期しない）
@MainActor
@Observable
final class ReviewNudgeBox {
    private(set) var items: [ReviewNudge.Item] = []
    /// 音を切り出している最中（二重に切り出さない）
    @ObservationIgnored var preparing = false
    /// 選べる行が無かった日と時刻（開くたびに記録を読み直さないよう、20分は選び直さない）
    @ObservationIgnored private var emptyScan: (day: String, at: Date)?

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("review-nudge.json")
    /// 行の所の音の切り出し（今日の組の行はネットが無くても聞けるように、答えた行は夜に材料として送るまで）
    static let clipDir: URL = {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("review-clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private struct Saved: Codable {
        var items: [ReviewNudge.Item] = []
    }

    init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            items = saved.items
        } else {
            // 読めないファイルは上書きせず、脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("review-nudge-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    /// その日の組（時刻の順）
    func items(for day: String) -> [ReviewNudge.Item] {
        items.filter { $0.setDay == day }.sorted { $0.time < $1.time }
    }

    func add(_ new: [ReviewNudge.Item]) {
        let known = Set(items.map(\.id))
        let fresh = new.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        items += fresh
        save()
    }

    func answer(_ id: String, as answer: ReviewNudge.Answer, right: String?, at date: Date = .now) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].answer = answer
        items[i].right = right
        items[i].answered = date
        // 飛ばした行の音は、もう要らない
        if answer == .skipped { dropClip(at: i) }
        save()
    }

    /// 答えを取り消す（もう一度答える）
    func reopen(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].answer = nil
        items[i].right = nil
        items[i].answered = nil
        save()
    }

    func setClip(_ id: String, name: String, from: TimeInterval, to: TimeInterval) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].clip = name
        items[i].clipFrom = from
        items[i].clipTo = to
        save()
    }

    /// 選び直してよいか（選べる行が無かったときは、20分は選び直さない）
    func mayScan(_ day: String, now: Date) -> Bool {
        guard let last = emptyScan, last.day == day else { return true }
        return now.timeIntervalSince(last.at) >= 20 * 60
    }

    func noteEmptyScan(_ day: String, now: Date) { emptyScan = (day, now) }

    /// 古いものを捨て、要らなくなった音を消す
    func prune(today: String, now: Date, sent: Set<String>) {
        let result = ReviewNudge.pruned(items, today: today, now: now, sent: sent)
        for name in result.removedClips {
            try? FileManager.default.removeItem(at: Self.clipDir.appendingPathComponent(name))
        }
        if result.items != items {
            items = result.items
            save()
        }
        // どの行にも付いていない音（切り出しているあいだに行が無くなったものなど）も消す
        let used = Set(items.compactMap(\.clip))
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.clipDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where !used.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func dropClip(at i: Int) {
        if let name = items[i].clip {
            try? FileManager.default.removeItem(at: Self.clipDir.appendingPathComponent(name))
        }
        items[i].clip = nil
        items[i].clipFrom = nil
        items[i].clipTo = nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(items: items)) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// 画面に出す、その行の今の記録と前後の行
struct ReviewNudgeContext {
    var before: ConversationLog.Line?
    var line: ConversationLog.Line?
    var after: ConversationLog.Line?
    /// 聞く所の終わり（秒）
    var stop: TimeInterval?
}

// MARK: - 選ぶ・答える・材料にする

extension Pipeline {
    /// 今日の組。まだ選んでいなければ、直近3日の閉じた会話の自信の低い行から選んで残す（その日のあいだは変えない）
    @discardableResult
    func prepareReviewNudge(now: Date = .now) -> [ReviewNudge.Item] {
        let today = ReviewNudge.dayKey(now)
        reviewNudge.prune(today: today, now: now, sent: PersonalMaterial.sentIDs())
        let current = reviewNudge.items(for: today)
        guard current.isEmpty, reviewNudge.mayScan(today, now: now) else { return current }
        let picked = ReviewNudge.pick(reviewNudgeCandidates(now: now), count: ReviewNudge.perDay)
        guard !picked.isEmpty else {
            reviewNudge.noteEmptyScan(today, now: now)
            return []
        }
        reviewNudge.add(picked.map { item -> ReviewNudge.Item in
            var copy = item
            copy.setDay = today
            return copy
        })
        // 今日の組の行の音を切り出しておく（ネットが無くても聞ける・音声が消えても夜に材料として送れる）
        Task { await prepareReviewClips() }
        return reviewNudge.items(for: today)
    }

    /// 選べる行。直近3日の閉じた会話（テレビ・動画は除く）の、聞き直しの音声がある自信の低い行。
    /// 前に出した行（includeOpen が false なら、答えた行だけ）と、答え合わせに出した行は選ばない。職場の会話の行も選ぶ（本人の決定）
    func reviewNudgeCandidates(now: Date = .now, includeOpen: Bool = true) -> [ReviewNudge.Candidate] {
        let since = now.addingTimeInterval(-ReviewNudge.window)
        var taken = Set(reviewNudge.items.filter { includeOpen || $0.isAnswered }.map(\.id))
        taken.formUnion(answerKey.samples.map(\.id))
        var out: [ReviewNudge.Candidate] = []
        for day in recordedDays().prefix(4) {
            for c in conversations(on: day) where c.closed && c.media == nil && c.end >= since {
                for line in c.lines where line.time >= since && line.time <= now {
                    let id = ReviewNudge.itemID(day: day, time: line.time)
                    guard !taken.contains(id), ReviewNudge.usable(line) else { continue }
                    let reasons = ReviewNudge.reasons(line)
                    // 聞き直しの音声がある行だけ（iPhone の中か、ドライブに上げてあるもの）
                    guard !reasons.isEmpty, let audio = line.audio, archive.canPlay(audio),
                          let item = ReviewNudge.item(line, id: id, day: day, conversation: c, reasons: reasons) else { continue }
                    let score = ReviewNudge.score(confidence: line.confidence, chance: Calibration.wrongChance(line),
                                                  votes: reasons.contains(.votes),
                                                  local: Storage.keptAudio(named: audio) != nil)
                    out.append(ReviewNudge.Candidate(item: item, score: score))
                }
            }
        }
        return out
    }

    /// その日の「聞いて直す」のまだ答えていない行の数。今日の分はここで選んで残す（まだなら）。明日の分は数えるだけ
    func reviewNudgeCount(for day: Date, now: Date = .now) -> Int {
        let key = ReviewNudge.dayKey(day)
        let today = ReviewNudge.dayKey(now)
        if key == today { return prepareReviewNudge(now: now).filter { !$0.isAnswered }.count }
        guard key > today else { return 0 }
        return ReviewNudge.pick(reviewNudgeCandidates(now: now, includeOpen: false), count: ReviewNudge.perDay).count
    }

    /// 終わったあとに「続けてもう10行」。足した数を返す
    @discardableResult
    func addMoreReviewNudge(now: Date = .now) -> Int {
        let today = ReviewNudge.dayKey(now)
        let picked = ReviewNudge.pick(reviewNudgeCandidates(now: now), count: ReviewNudge.perDay)
        guard !picked.isEmpty else { return 0 }
        reviewNudge.add(picked.map { item -> ReviewNudge.Item in
            var copy = item
            copy.setDay = today
            return copy
        })
        Task { await prepareReviewClips() }
        return picked.count
    }

    /// 今日のまだの行のうち、記録から無くなった行（会話を消した・テレビの行になった）は飛ばし、
    /// ほかの画面や家の PC で手で直した行は「直した」にする（どちらも数えない）
    func settleReviewNudge(now: Date = .now) {
        for item in reviewNudge.items(for: ReviewNudge.dayKey(now)) where !item.isAnswered {
            let line = currentLine(MisheardBox.Ref(day: item.day, time: item.time, text: item.text))
            if let line, line.media == nil {
                if line.checked == true { reviewNudge.answer(item.id, as: .fixed, right: line.text) }
            } else {
                reviewNudge.answer(item.id, as: .skipped, right: nil)
            }
        }
    }

    /// その行の今の記録と、前後の行・聞く所の終わり
    func reviewNudgeContext(_ item: ReviewNudge.Item) -> ReviewNudgeContext {
        var context = ReviewNudgeContext()
        for c in conversations(on: item.day) {
            guard let i = c.lines.firstIndex(where: { $0.time == item.time && $0.text == item.text })
                    ?? c.lines.firstIndex(where: { $0.time == item.time }) else { continue }
            let line = c.lines[i]
            context.line = line
            context.before = i > 0 ? c.lines[i - 1] : nil
            context.after = i + 1 < c.lines.count ? c.lines[i + 1] : nil
            let following = c.lines[(i + 1)...].first(where: { $0.audio == line.audio })
            let next = following?.offset
            context.stop = ReviewNudge.stop(offset: line.offset ?? item.offset, end: line.end, next: next, chars: line.text.count)
            return context
        }
        return context
    }

    /// 「直す」: 記録の「文字を直す」と同じ直し（記録とドキュメントの行が直り、手で直した行になる）。直せなければ理由を返す
    func fixReviewNudge(_ item: ReviewNudge.Item, to text: String, addFix: Bool) async -> String? {
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return nil }
        guard let line = currentLine(MisheardBox.Ref(day: item.day, time: item.time, text: item.text)) else {
            // 記録から無くなった行は飛ばす
            reviewNudge.answer(item.id, as: .skipped, right: nil)
            return nil
        }
        guard new != line.text else {
            // 記録がもうその文になっている（ほかの画面で直した・夜の聞き直しで変わった）。手で直した行なら「直した」、
            // そうでなければ記録は変えずに「合っている」として残す（どちらも材料になる）
            if line.checked == true {
                reviewNudge.answer(item.id, as: .fixed, right: new)
                Task { await cutReviewClip(item.id) }
            } else {
                confirmReviewNudge(item, text: new)
            }
            return nil
        }
        let fix = addFix ? Self.changedPart(from: line.text, to: new) : nil
        if let failure = await editLine(line, to: new, addFix: fix) { return failure }
        reviewNudge.answer(item.id, as: .fixed, right: new)
        Tally.add("review.fixed")
        Task { await cutReviewClip(item.id) }
        return nil
    }

    /// 「合っている」: 記録は変えずに、正しい文が分かった行として残す（答え合わせの「文字は合っている」と同じ）
    func confirmReviewNudge(_ item: ReviewNudge.Item, text: String) {
        let right = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !right.isEmpty else { return }
        reviewNudge.answer(item.id, as: .ok, right: right)
        Tally.add("review.ok")
        Task { await cutReviewClip(item.id) }
    }

    /// 「飛ばす」: 聞き取れない・答えられない（材料にしない）
    func skipReviewNudge(_ item: ReviewNudge.Item) {
        reviewNudge.answer(item.id, as: .skipped, right: nil)
        Tally.add("review.skipped")
    }

    /// 「合っている」と答えた行（夜に材料として送る）。あとで記録の画面で手で直した行は、手で直した行のほうだけ送る
    /// （同じ行を2つの文で送らない）
    func reviewNudgeTruths() -> [AnswerKey.Truth] {
        reviewNudge.items.compactMap { item -> AnswerKey.Truth? in
            guard let truth = ReviewNudge.truth(item) else { return nil }
            let line = currentLine(MisheardBox.Ref(day: item.day, time: item.time, text: item.text))
            if line?.checked == true { return nil }
            return truth
        }
    }

    /// 答えたときに切り出して残した、その行の所の音（夜に送るときと「聞く」に使う）
    func reviewNudgeClip(audio: String, offset: TimeInterval) -> (url: URL, from: TimeInterval, to: TimeInterval)? {
        for item in reviewNudge.items where item.audio == audio && abs(item.offset - offset) < 0.05 {
            guard let name = item.clip, let from = item.clipFrom, let to = item.clipTo else { continue }
            let url = ReviewNudgeBox.clipDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return (url, from, to) }
        }
        return nil
    }

    /// ここで答えて、まだ家の PC に送っていない材料の数
    func reviewNudgeUnsent() -> Int {
        let sent = PersonalMaterial.sentIDs()
        return reviewNudge.items.filter { ($0.answer == .ok || $0.answer == .fixed) && !ReviewNudge.isSent($0, sent) }.count
    }

    /// まだ切り出していない行の音を切り出す（今日の組のまだの行と、直した・合っていた行）
    func prepareReviewClips() async {
        guard !reviewNudge.preparing else { return }
        reviewNudge.preparing = true
        defer { reviewNudge.preparing = false }
        let today = ReviewNudge.dayKey(.now)
        let ids = reviewNudge.items.filter { item in
            item.clip == nil && (item.answer == .fixed || item.answer == .ok || (item.answer == nil && item.setDay == today))
        }.map(\.id)
        for id in ids { await cutReviewClip(id) }
    }

    /// 1行の所の音を切り出して残す（iPhone の中の音声は26時間で消えるので、夜に材料として送れるように）
    func cutReviewClip(_ id: String) async {
        guard let item = reviewNudge.items.first(where: { $0.id == id }), item.clip == nil,
              let url = await archive.playableURL(for: item.audio) else { return }
        guard let window = ReviewNudge.clipWindow(offset: item.offset, end: item.end, duration: AudioClip.duration(of: url)),
              let temp = await AudioClip.extract(url, from: window.from, to: window.to) else { return }
        let name = ReviewNudge.clipName(id)
        let dest = ReviewNudgeBox.clipDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return
        }
        reviewNudge.setClip(id, name: name, from: window.from, to: window.to)
    }

    /// 家の PC にたまった材料の数を聞く（つながるときだけ。聞けなければ nil で、数は出さない）
    @discardableResult
    func refreshPersonalCount() async -> PersonalMaterial.Status? {
        guard homePC.shouldTry else { return nil }
        if homePC.version == nil { _ = try? await homePC.hello() }
        guard (homePC.version ?? 0) >= 4 else {
            PersonalMaterial.noteMissed()
            return nil
        }
        do {
            let status = try await homePC.trainStatus()
            return PersonalMaterial.note(count: status.count, model: status.model, need: status.need)
        } catch {
            PersonalMaterial.noteMissed()
            return nil
        }
    }
}

// MARK: - 画面

/// 「今日」の上のほうに出す入口（まだ答えていない行があるときだけ）
struct ReviewNudgeEntry: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let items = pipeline.reviewNudge.items(for: ReviewNudge.dayKey(.now))
        let left = items.filter { !$0.isAnswered }.count
        if left > 0 {
            Section {
                NavigationLink {
                    ReviewNudgeView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(ReviewNudge.entryTitle(total: items.count, left: left), systemImage: "ear")
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var caption: String {
        if let material = PersonalMaterial.latest() {
            return "学び直しの材料 \(material.count) / \(material.need) 個（家の PC）。聞いて直すと増えます。"
        }
        return "自信の低い行を聞いて、直すか「合っている」を押すと、あなた向けの Whisper の材料になります。"
    }
}

/// 今日の聞いて直す。1行ずつ ▶ で聞いて「直す・合っている・飛ばす」で答える
struct ReviewNudgeView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var player = ClipPlayer()
    /// 一覧で押して選んだ行（無ければ、まだ答えていない最初の行）
    @State private var chosen: String?
    @State private var context = ReviewNudgeContext()
    @State private var text = ""
    @State private var working = false
    @State private var note: String?
    /// 一度 ▶ を押したら、次の行からは自動で流す
    @State private var autoPlay = false
    /// 家の PC に聞いた材料の数（つながったときだけ）
    @State private var material: PersonalMaterial.Status?
    @State private var unsent = 0
    @State private var sent: Set<String> = []
    @State private var moreNote: String?
    @AppStorage(ReviewNudge.addFixKey) private var addFix = false
    @FocusState private var typing: Bool

    var body: some View {
        let today = pipeline.reviewNudge.items(for: ReviewNudge.dayKey(.now))
        let current = ReviewNudge.current(in: today, chosen: chosen)
        List {
            if today.isEmpty {
                Section {
                    Text("今は聞いて直す行がありません。確からしさの低い行や、家の PC のモデルが食い違った行で、音声が残っているものを、毎朝10行ほど選びます。")
                        .foregroundStyle(.secondary)
                }
            } else if let current {
                card(current, in: today)
            } else {
                finished(today)
            }
            if !today.isEmpty {
                listSection(today, current: current)
            }
            materialSection()
        }
        .navigationTitle("今日の聞いて直す")
        .task {
            pipeline.prepareReviewNudge()
            pipeline.settleReviewNudge()
            refreshCounts()
            await pipeline.prepareReviewClips()
        }
        .task {
            material = await pipeline.refreshPersonalCount()
        }
        .task(id: current?.id) {
            await load(current)
        }
        .onDisappear { player.stop() }
    }

    // MARK: 1行

    @ViewBuilder
    private func card(_ item: ReviewNudge.Item, in today: [ReviewNudge.Item]) -> some View {
        let number = (today.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
        let key = "nudge-" + item.id
        let shown = context.line?.text ?? item.text
        let speaker = context.line?.speaker ?? item.speaker
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = typed != shown
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(ReviewNudge.caption(item)).font(.caption).foregroundStyle(.secondary)
                Text(ReviewNudge.reasonText(item.reasons)).font(.caption2).foregroundStyle(.orange)
                if let before = context.before {
                    Text("前: " + ReviewNudge.say(before)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text((speaker.map { "[\($0)] " } ?? "") + shown)
                if let after = context.after {
                    Text("後: " + ReviewNudge.say(after)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Button {
                autoPlay = true
                Task { await play(item) }
            } label: {
                if player.loading == key {
                    ProgressView()
                } else {
                    Label(player.playing == key ? "止める" : "聞く",
                          systemImage: player.playing == key ? "stop.circle.fill" : "play.circle")
                }
            }
            let others = ReviewNudge.alternatives(item.votes, current: shown)
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ほかのモデルの聞き取り（押すと下の欄に入ります）").font(.caption).foregroundStyle(.secondary)
                    ForEach(others, id: \.self) { other in
                        Button(other) { text = other }
                            .buttonStyle(.bordered)
                            .font(.callout)
                    }
                }
            }
            TextField("本当に言ったこと", text: $text, axis: .vertical)
                .focused($typing)
            if edited, let part = Pipeline.changedPart(from: shown, to: typed) {
                Toggle("「\(part.wrong)」→「\(part.right)」を誤変換の一覧にも足す", isOn: $addFix)
            }
            if working {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("直しています…").foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    Button("直す") { fix(item, to: typed) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!edited || typed.isEmpty)
                    Button("合っている") { confirm(item, shown) }
                        .buttonStyle(.bordered)
                        .disabled(edited)
                    Button("飛ばす") { skip(item) }
                        .buttonStyle(.bordered)
                }
                if edited {
                    Button("元の文に戻す") { text = shown }
                        .font(.caption)
                }
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("\(number) / \(today.count)")
        } footer: {
            Text("▶ で聞いて、違っていれば欄の文を直して「直す」、そのままで正しければ「合っている」、聞き取れなければ「飛ばす」。直した行は、記録の「文字を直す」と同じく、記録とドキュメントも直ります。直した行と「合っている」行は、夜に家の PC に、あなた向けの Whisper の材料として送ります。")
        }
    }

    // MARK: 終わり・一覧・材料

    @ViewBuilder
    private func finished(_ today: [ReviewNudge.Item]) -> some View {
        let fixed = today.filter { $0.answer == .fixed }.count
        let ok = today.filter { $0.answer == .ok }.count
        let skipped = today.filter { $0.answer == .skipped }.count
        Section {
            Label("今日の分は終わりました", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("直した \(fixed) 行・合っている \(ok) 行・飛ばした \(skipped) 行")
            Button("続けてもう\(ReviewNudge.perDay)行") {
                let added = pipeline.addMoreReviewNudge()
                moreNote = added > 0 ? nil : "今は、ほかに聞いて直す行がありません。"
                chosen = nil
            }
            if let moreNote {
                Text(moreNote).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text("直した行と「合っている」行は、夜に充電しているとき（夜の聞き直しのあと）、家の PC に材料として送ります。")
        }
    }

    @ViewBuilder
    private func listSection(_ today: [ReviewNudge.Item], current: ReviewNudge.Item?) -> some View {
        let answered = today.filter(\.isAnswered).count
        Section {
            ForEach(today) { item in
                Button {
                    if !item.isAnswered { chosen = item.id }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Self.icon(item, current: current?.id))
                            .foregroundStyle(item.isAnswered ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.right ?? item.text).foregroundStyle(.primary).lineLimit(2)
                            Text(ReviewNudge.status(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    if item.answer == .ok || item.answer == .skipped, !ReviewNudge.isSent(item, sent) {
                        Button("取り消す") {
                            pipeline.reviewNudge.reopen(item.id)
                            chosen = item.id
                            refreshCounts()
                        }
                    }
                }
            }
        } header: {
            Text("今日の \(today.count) 行（答えた \(answered)）")
        } footer: {
            Text("「合っている」「飛ばす」は、左へ払うと取り消せます（材料として送る前だけ）。直した行は、記録の「文字を直す」の「変更の履歴」から戻せます。")
        }
    }

    @ViewBuilder
    private func materialSection() -> some View {
        Section {
            if let material {
                LabeledContent("家の PC にたまった材料", value: "\(material.count) 個")
                let line: String = material.left == 0
                    ? "学び直せる数です（\(material.need) 個から）。学び直しは、家の PC が決めた時間に動きます。"
                    : "あと \(material.left) 個で、あなた向けの Whisper を学び直せます（\(material.need) 個から）。"
                Text(line).font(.callout)
            }
            if unsent > 0 {
                LabeledContent("ここで答えて、まだ送っていない材料", value: "\(unsent) 個")
            }
        } header: {
            Text("学び直しの材料")
        } footer: {
            let line: String = pipeline.homePC.isConfigured
                ? "材料の数は、家の PC につながったときだけ出します。答えた行は、夜に充電しているとき（夜の聞き直しのあと）家の PC に送ります。"
                : "家の PC を使っていないので、材料は送りません（直した行は、記録とドキュメントが直ります）。"
            Text(line)
        }
    }

    // MARK: 動き

    private func load(_ item: ReviewNudge.Item?) async {
        note = nil
        guard let item else {
            context = ReviewNudgeContext()
            return
        }
        context = pipeline.reviewNudgeContext(item)
        text = context.line?.text ?? item.text
        if autoPlay { await play(item) }
    }

    private func play(_ item: ReviewNudge.Item) async {
        let key = "nudge-" + item.id
        let stop = context.stop ?? ReviewNudge.stop(offset: item.offset, end: item.end, next: nil, chars: item.text.count)
        if let clip = pipeline.reviewNudgeClip(audio: item.audio, offset: item.offset) {
            await player.toggle(key, at: item.offset - clip.from, until: stop - clip.from) { clip.url }
        } else {
            await player.toggle(key, at: item.offset, until: stop) { await pipeline.archive.playableURL(for: item.audio) }
        }
    }

    private func fix(_ item: ReviewNudge.Item, to new: String) {
        player.stop()
        typing = false
        working = true
        Task {
            let failure = await pipeline.fixReviewNudge(item, to: new, addFix: addFix)
            working = false
            note = failure
            if failure == nil { advance(after: item) }
        }
    }

    private func confirm(_ item: ReviewNudge.Item, _ shown: String) {
        player.stop()
        typing = false
        pipeline.confirmReviewNudge(item, text: shown)
        advance(after: item)
    }

    private func skip(_ item: ReviewNudge.Item) {
        player.stop()
        typing = false
        pipeline.skipReviewNudge(item)
        advance(after: item)
    }

    /// 次のまだの行へ。全部答えたら、朝の知らせの「聞いて直す」の1行を外す（まだ知らせる前なら）
    private func advance(after item: ReviewNudge.Item) {
        let today = pipeline.reviewNudge.items(for: ReviewNudge.dayKey(.now))
        chosen = ReviewNudge.next(in: today, after: item.id)?.id
        refreshCounts()
        if !today.contains(where: { !$0.isAnswered }) {
            Task { await pipeline.scheduleMorningBriefNotice() }
        }
    }

    private func refreshCounts() {
        sent = PersonalMaterial.sentIDs()
        unsent = pipeline.reviewNudgeUnsent()
    }

    private static func icon(_ item: ReviewNudge.Item, current: String?) -> String {
        switch item.answer {
        case .fixed?: return "pencil.circle.fill"
        case .ok?: return "checkmark.circle.fill"
        case .skipped?: return "forward.circle"
        case nil: return item.id == current ? "play.circle" : "circle"
        }
    }
}

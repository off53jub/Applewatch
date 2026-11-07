import CryptoKit
import Foundation
import UIKit

// 記録を家の PC に送り、PC で直した分を iPhone に戻す（docs/v7-plan.md の 5。2026-11-07）。LifeLog PC の版 7 から。
// - 送る: POST /records/<日>。端末間の同期と同じ中身（ConversationLog.SyncDay。閉じた会話だけ）を、日時の決まり
//   （ISO 8601・UTC・ミリ秒）で JSON にする。PC とつながったときに10分に1回まで、前に送ってから変わった日だけ
//   （日ごとの記録の更新時刻と中身の SHA-256 を UserDefaults に残す）。初めは60日さかのぼって、1回に5日ずつ。
//   職場の会話も送る（家の PC の中だけなので外に出ない）。iPad は送らない（同期で iPhone が両方の分を持つので）。
//   職場の会話には印を付ける（2026-11-07。版 9）: 中身に "work": [職場の会話の start, …] を足す（日時の書き方は会話と同じ）。
//   職場かどうかは、アプリが職場の会話を外に出さない決まりで使っている判断（isWorkTime＝ConversationLog の isWork）と同じ。
//   PC は、この印の付いた会話を、PC から Claude に見せる道具や母艦への写しから外す。印を付ける前に送った日は、一度だけ送り直す。
// - 戻す: GET /edits?after= → 当てる → POST /edits/ack → 当てた日を早めに送り直す（PC は送り直すまで、当てた直しを
//   次の直しの「直す前」にする）。GET は1回に500件までで続きの印が無いので、最後の番号のあとを0件になるまで聞く。
//   同じ時刻の行が2つあると、どちらを直すか決められないので当てない（PC でも直せないようにしてある）。
//   文は手で直したのと同じに当てる（行の履歴には「PC で直した」）。話し手は、アプリで1行の話し手を直すときと同じしかた
//   （fixSpeaker の「この行だけ」。その行の声もその人の声として覚える）。名前のある人を作る・まとめる・名前を変えることはしない
//   （登録に無い名前なら当てない。「人物N」も作らない）。今の文と話し手が PC の「直す前」と違えば当てない。
// - 行の音声の名前（Line.audio）は、PC の仕事の名前（HomePC.enqueueJob の url.lastPathComponent）と同じ
//   （どちらも文字起こし待ちの区切りのファイル名のまま。時計の区切りも、名前を直してから両方に使う）。違わないので audioNames は付けない。

// MARK: - PC で直した1つ

/// PC で直した1つ（GET /edits の edits の1つ）
struct PCEdit: Decodable {
    /// 直す前（PC が見ていた記録）の文と話し手
    struct Base: Decodable {
        let text: String
        let speaker: String?
        let speakerID: String?
    }

    let id: Int
    let day: String
    /// 行の時刻（iPhone が送った記録の時刻。ミリ秒まで）
    let time: Date
    /// "text"（文を直す）か "speaker"（話し手を変える）
    let kind: String
    let base: Base
    let text: String?
    /// 話し手の名前か「自分」
    let speaker: String?
    let speakerID: String?
    let created: Date?
}

/// 当てた結果（POST /edits/ack の results の1つ）
struct PCEditResult: Codable, Equatable {
    let id: Int
    /// applied（当てた）・skipped（当てなかった）・failed（当てられなかった）
    let status: String
    let reason: String?

    static func applied(_ id: Int) -> PCEditResult { PCEditResult(id: id, status: "applied", reason: nil) }
    static func skipped(_ id: Int, _ reason: String) -> PCEditResult { PCEditResult(id: id, status: "skipped", reason: reason) }
    static func failed(_ id: Int, _ reason: String) -> PCEditResult { PCEditResult(id: id, status: "failed", reason: reason) }

    private enum CodingKeys: String, CodingKey { case id, status, reason }

    /// 理由が無いときも null で書く（決まりの形）
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encode(reason, forKey: .reason)
    }
}

/// 1つの直しをどうするか（PCEdits.plan が決める。記録はまだ変えない）
enum PCEditPlan: Equatable {
    /// 文をこれにする
    case text(String)
    /// 話し手をこの人（番号）にする
    case speaker(String)
    /// もうそうなっている（当てたことにする）
    case already
    /// 当てない（理由）
    case skip(String)
    /// 当てられない（理由）
    case fail(String)
}

// MARK: - 直しの当て方

enum PCEdits {
    /// 行の直した履歴に残す名前
    static let by = "PC で直した"
    static let changedFirst = "iPhone の記録が先に変わっていました"
    static let lineMissing = "iPhone の記録にその行がありません"
    static let unknownPerson = "その名前の人が iPhone の登録にいません（PC からは人を作りません）"
    static let samePeople = "同じ名前の人が iPhone に何人かいます"
    static let noSelf = "iPhone に「自分」がまだいません"
    static let sameTimeLines = "同じ時刻の行が iPhone に2つあるので、どちらか決められません"
    /// GET /edits が1回に返す数の上限（続きがあるかの印は無いので、0件になるまで聞く）
    static let pageSize = 500
    /// 一時的に当てられなかった（通信やドキュメント）ときに、何回目で「当てられなかった」にするか
    static let retries = 3

    enum Match: Equatable {
        case found(String)
        case missing
        case ambiguous
    }

    /// 話し手の名前（と、分かれば番号）から、登録の人を探す。新しく作らない
    static func person(named name: String, id: String?, in people: [SpeakerLabeler.Person]) -> Match {
        if name == SpeakerLabeler.selfName {
            return people.contains(where: \.isSelf) ? .found(SpeakerLabeler.selfID) : .missing
        }
        if let id, let person = people.first(where: { $0.id == id }), !person.isSelf, person.displayName == name {
            return .found(person.id)
        }
        let same = people.filter { !$0.isSelf && $0.displayName == name }
        if same.count == 1, let only = same.first { return .found(only.id) }
        return same.isEmpty ? .missing : .ambiguous
    }

    /// 今の行が、PC の「直す前」と同じか（PC が番号を書いていなければ、名前だけで見る）
    static func matchesBase(_ line: ConversationLog.Line, _ base: PCEdit.Base) -> Bool {
        guard line.text == base.text, line.speaker == base.speaker else { return false }
        guard let id = base.speakerID else { return true }
        return line.speakerID == id
    }

    /// 日の名前（yyyy-MM-dd）か。記録のファイルの名前に使うので、ほかの形は使わない
    static func isDayName(_ day: String) -> Bool {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// 直したあとの文（改行は空白にし、前後の空白を除く。記録の1行は1行のまま）
    static func cleaned(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 直しをどうするか決める（記録はまだ変えない）
    static func plan(_ edit: PCEdit, line: ConversationLog.Line?, people: [SpeakerLabeler.Person]) -> PCEditPlan {
        guard let line else { return .skip(lineMissing) }
        switch edit.kind {
        case "text":
            let text = cleaned(edit.text ?? "")
            guard !text.isEmpty else { return .fail("直したあとの文が空です") }
            if line.text == text { return .already }
            return matchesBase(line, edit.base) ? .text(text) : .skip(changedFirst)
        case "speaker":
            let name = (edit.speaker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .fail("話し手の名前がありません") }
            switch person(named: name, id: edit.speakerID, in: people) {
            case .found(let id):
                if line.speakerID == id, line.speaker == name { return .already }
                return matchesBase(line, edit.base) ? .speaker(id) : .skip(changedFirst)
            case .missing:
                return .skip(name == SpeakerLabeler.selfName ? noSelf : unknownPerson)
            case .ambiguous:
                return .skip(samePeople)
            }
        default:
            return .fail("知らない直しの種類です")
        }
    }

    /// その日の会話から、時刻（差が 1ms 未満）の行を全部、同じ音声の次の行（声を切り出す終わり）と一緒に探す
    static func matches(_ time: Date, in conversations: [ConversationLog.Conversation])
        -> [(line: ConversationLog.Line, next: ConversationLog.Line?)] {
        var found: [(line: ConversationLog.Line, next: ConversationLog.Line?)] = []
        for c in conversations {
            for (i, line) in c.lines.enumerated() where PCJSON.sameTime(line.time, time) {
                let next = c.lines[(i + 1)...].first(where: { $0.audio == line.audio })
                found.append((line: line, next: next))
            }
        }
        return found
    }

    /// その時刻の行が1つだけなら、その行（無い・2つ以上なら nil。同じ時刻の行が2つあると、どちらを直すか決められない）
    static func find(_ time: Date, in conversations: [ConversationLog.Conversation])
        -> (line: ConversationLog.Line, next: ConversationLog.Line?)? {
        let found = matches(time, in: conversations)
        return found.count == 1 ? found.first : nil
    }

    /// 次に聞く番号（GET /edits?after=）。片づいていない直し（当てられなかった・PC に伝えられなかった）があれば、その手前まで
    static func nextAfter(current: Int, fetched: [Int], open: [Int]) -> Int {
        if let first = open.min() { return max(0, first - 1) }
        return max(current, fetched.max() ?? current)
    }

    static var statusText: String { PCEditStore.load().statusText }
}

/// 直しのやり取りの覚え書き（UserDefaults の pcEdits）
struct PCEditStore: Codable {
    /// ここまでの番号は片づいた（GET /edits?after=）
    var after = 0
    /// 当てたが、まだ PC に伝えられていない結果
    var pending: [PCEditResult] = []
    /// 一時的に当てられなかった回数（番号ごと）
    var attempts: [String: Int] = [:]
    /// 数（画面に出す）
    var applied = 0
    var skipped = 0
    var failed = 0
    var lastAt: Date?
    var lastError: String?

    private static let key = "pcEdits"

    static func load() -> PCEditStore {
        guard let data = UserDefaults.standard.data(forKey: key),
              let store = try? JSONDecoder().decode(PCEditStore.self, from: data) else { return PCEditStore() }
        return store
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// 一時的に当てられなかった。retries 回目なら「当てられなかった」にする（それまでは nil。次の機会にやり直す）
    mutating func retry(_ id: Int, reason: String) -> PCEditResult? {
        let key = String(id)
        let count = (attempts[key] ?? 0) + 1
        attempts[key] = count
        return count >= PCEdits.retries ? .failed(id, reason) : nil
    }

    /// 新しく片づいた結果を数える
    mutating func count(_ result: PCEditResult) {
        switch result.status {
        case "applied": applied += 1
        case "skipped": skipped += 1
        default: failed += 1
        }
    }

    var statusText: String {
        var text = "当てた \(applied)・当てなかった \(skipped)・当てられなかった \(failed)"
        if let lastAt { text += "・最後に確かめた " + PCDiag.clock(lastAt) }
        if let lastError { text += "・" + lastError }
        return text
    }
}

/// GET /edits の答え（読めない直しがあっても、ほかは読む）
private struct PCEditsReply: Decodable {
    struct Item: Decodable {
        let id: Int?
        let edit: PCEdit?

        init(from decoder: Decoder) throws {
            id = try? decoder.container(keyedBy: Keys.self).decode(Int.self, forKey: .id)
            edit = try? PCEdit(from: decoder)
        }

        private enum Keys: String, CodingKey { case id }
    }

    let edits: [Item]
}

private struct PCEditsAck: Encodable {
    let results: [PCEditResult]
}

// MARK: - 送る中身

/// POST /records/<日> の中身。同期と同じ1日分（SyncDay）に、職場の会話の印（work）を足したもの（2026-11-07。版 9）。
/// 同期の形（SyncDay）は変えない（同期のファイルには work を入れない）。
struct PCRecordsBody: Encodable {
    let day: ConversationLog.SyncDay
    /// 職場の会話の start（会話の start と同じ書き方で JSON にする）。職場の会話が無ければ空
    let work: [Date]

    private enum Keys: String, CodingKey { case work }

    func encode(to encoder: Encoder) throws {
        // 1日分の項目をそのまま書いてから、同じ入れ物に work を足す
        try day.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(work, forKey: .work)
    }

    /// 1日分と、その時刻が職場かを見る関数から作る（閉じた会話のうち、職場の時刻に始まったもの）
    static func make(_ day: ConversationLog.SyncDay, isWork: (Date) -> Bool) -> PCRecordsBody {
        PCRecordsBody(day: day, work: day.conversations.map(\.start).filter(isWork))
    }
}

// MARK: - 記録の送り方

enum PCRecords {
    /// 1回に送る日の数（初めの60日分も、これずつ）
    static let perRound = 5
    /// 初めてのときに、さかのぼる日数
    static let backfillDays = 60
    /// やり取りの間隔（10分に1回まで）
    static let every: TimeInterval = 10 * 60
    /// 1日分の大きさの上限（PC は 8MiB まで受け取る）
    static let maxBytes = 8 * 1024 * 1024
    /// PC の直しを当てた日を送り直せていないときは、次のやり取りを早める（PC は送り直すまで、当てた直しを次の直しの「直す前」にする）
    static let soon: TimeInterval = 60

    /// 日 → 送ったときの、その日の記録の更新時刻
    private static let sentKey = "pcRecordsSent"
    /// 日 → 送った中身の SHA-256
    private static let hashKey = "pcRecordsHash"
    private static let atKey = "pcRecordsAt"
    private static let resultKey = "pcRecordsResult"
    /// 送る中身の版（2 = 職場の会話の印つき。2026-11-07）
    static let format = 2
    private static let formatKey = "pcRecordsFormat"

    /// 中身の版が上がったら、前に送った日を全部「送り直す日」にする（送った時刻を、どの更新時刻とも合わない値にする）
    static func resendAll(_ sent: [String: Double]) -> [String: Double] { sent.mapValues { _ in -1 } }

    /// 職場の会話の印を付ける前に送った日を、一度だけ送り直す
    static func upgradeFormatIfNeeded() {
        guard UserDefaults.standard.integer(forKey: formatKey) < format else { return }
        let sent = sentStamps
        if !sent.isEmpty { UserDefaults.standard.set(resendAll(sent), forKey: sentKey) }
        UserDefaults.standard.set(format, forKey: formatKey)
    }

    /// この端末が記録を送り、直しを当てるか（iPad は送らない）
    @MainActor static var isSender: Bool { UIDevice.current.userInterfaceIdiom != .pad }

    static func isDue(lastTried: Date, now: Date, soon: Bool = false) -> Bool {
        now.timeIntervalSince(lastTried) >= (soon ? Self.soon : every)
    }

    /// 送る日（新しい日から。first の日＝PC の直しを当てた日は、いつも先に）。前に送った日は、そのあと変わったものだけ。
    /// まだ送っていない日は、oldest（60日前）より新しいものだけ
    static func daysToSend(days: [String], stamps: [String: Double], sent: [String: Double], oldest: String,
                           first: Set<String> = []) -> [String] {
        days.filter { day in
            if first.contains(day) { return true }
            if let done = sent[day] { return done != (stamps[day] ?? 0) }
            return day >= oldest
        }
        .sorted { a, b in
            let aFirst = first.contains(a), bFirst = first.contains(b)
            return aFirst != bFirst ? aFirst : a > b
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static var sentStamps: [String: Double] {
        UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Double] ?? [:]
    }

    static var sentHashes: [String: String] {
        UserDefaults.standard.dictionary(forKey: hashKey) as? [String: String] ?? [:]
    }

    static func save(sent: [String: Double], hashes: [String: String]) {
        UserDefaults.standard.set(sent, forKey: sentKey)
        UserDefaults.standard.set(hashes, forKey: hashKey)
    }

    static func note(posted: Int, problem: String?, now: Date) {
        if posted > 0 { UserDefaults.standard.set(now, forKey: atKey) }
        UserDefaults.standard.set(problem.map { "送れませんでした: " + $0 } ?? "", forKey: resultKey)
    }

    static var statusText: String {
        var text = "送った日 \(sentStamps.count) 日"
        if let at = UserDefaults.standard.object(forKey: atKey) as? Date { text += "・最後 " + PCDiag.clock(at) }
        if let result = UserDefaults.standard.string(forKey: resultKey), !result.isEmpty { text += "・" + result }
        return text
    }
}

// MARK: - やり取り

extension Pipeline {
    /// 記録と直しを家の PC とやり取りする（直しを先に当ててから、当てた日も含めて変わった日を送る）。deadline までに収める
    func exchangePCRecords(until deadline: Date?) async {
        guard PCRecords.isSender, homePC.shouldTry else { return }
        let link = PCLinkState.shared
        guard !link.recordsBusy else { return }
        link.recordsBusy = true
        defer { link.recordsBusy = false }
        link.recordsTried = .now
        // 裏で起こされたばかりだと、PC にできること（features）をまだ聞いていない
        if homePC.version == nil {
            guard (try? await homePC.hello()) != nil else { return }
        }
        var edited: Set<String> = []
        // 直しはドキュメントも直すので、Google にログインしているときだけ。
        // 裏で文字起こしの列が動いているあいだは、書き足しと重ならないよう次の機会に
        if homePC.features.contains("edits"), email != nil, !(deadline != nil && isQueueRunning) {
            edited = await pullPCEdits(until: deadline)
        }
        if homePC.features.contains("records") { await pushPCRecords(until: deadline, first: edited) }
    }

    /// PC の直しを受け取って当て、結果を PC に伝える。PC は1回に500件までしか返さず、続きがあるかの印も無いので、
    /// 返ってきた最後の番号のあとを、0件になるまで続けて聞く（10回まで。残りは次の機会に）。直した日を返す
    private func pullPCEdits(until deadline: Date?) async -> Set<String> {
        var edited: Set<String> = []
        for _ in 0..<10 {
            let page = await pullPCEditsPage(until: deadline)
            edited.formUnion(page.edited)
            // 0件だった・片づかない直しがあった・PC に伝えられなかったら、ここまで
            guard page.fetched > 0, page.finished else { break }
        }
        if !edited.isEmpty { recordsChangedByPC() }
        return edited
    }

    /// 1回分（500件まで）。fetched は受け取った数、finished は全部を当て終えて PC に伝えられたか（続きを聞いてよいか）
    private func pullPCEditsPage(until deadline: Date?) async -> (edited: Set<String>, fetched: Int, finished: Bool) {
        var store = PCEditStore.load()
        let reply: PCEditsReply
        do {
            let data = try await homePC.getJSONData("edits", query: [URLQueryItem(name: "after", value: String(store.after))],
                                                    timeout: 10)
            reply = try PCJSON.decoder().decode(PCEditsReply.self, from: data)
        } catch {
            store.lastError = "PC の直しを受け取れませんでした: " + HomePC.describe(error)
            store.save()
            return ([], 0, false)
        }
        let items = reply.edits.compactMap { item -> (id: Int, edit: PCEdit?)? in
            guard let id = item.id else { return nil }
            return (id: id, edit: item.edit)
        }.sorted { $0.id < $1.id }
        // PC がもう返してこない結果（伝わっていた）は、覚えておかない。続きの回に出てくる番号（今回の最後より大きい）は残す
        let fetched = Set(items.map(\.id))
        let last = items.last?.id
        store.pending.removeAll { result in !fetched.contains(result.id) && (last.map { result.id <= $0 } ?? true) }
        store.attempts = store.attempts.filter { entry in
            guard let id = Int(entry.key) else { return false }
            return fetched.contains(id) || (last.map { id > $0 } ?? false)
        }
        guard !items.isEmpty else {
            store.lastAt = .now
            store.save()
            return ([], 0, true)
        }

        var results: [PCEditResult] = []
        var open: [Int] = []
        var edited: Set<String> = []
        var registered: [SpeakerLabeler.Person]?
        var stopped = false
        let failedReason = "iPhone の記録を直せませんでした（通信やドキュメント）"
        for item in items {
            // 前に当てたが、PC に伝えられていなかった結果は、そのまま伝える
            if let done = store.pending.first(where: { $0.id == item.id }) {
                results.append(done)
                continue
            }
            if stopped || deadline.map({ Date.now > $0 }) == true {
                open.append(item.id)
                continue
            }
            guard let edit = item.edit, PCEdits.isDayName(edit.day) else {
                let result = PCEditResult.failed(item.id, "直しの中身を読めませんでした")
                store.count(result)
                store.pending.append(result)
                results.append(result)
                continue
            }
            // 話し手の直しは声も覚えるので時間がかかる。裏で残りの時間が少ないときは、これと残りを次の機会に
            if edit.kind == "speaker", let deadline, deadline.timeIntervalSinceNow < 10 {
                open.append(item.id)
                stopped = true
                continue
            }
            if edit.kind == "speaker", registered == nil {
                // 裏で起こされたときは、人の一覧をまだ読んでいないことがある
                await reloadPeople()
                registered = people
            }
            let candidates = PCEdits.matches(edit.time, in: conversations(on: edit.day))
            let found = candidates.first
            var outcome: PCEditResult?
            // 同じ時刻の行が2つあると、どちらを直すか決められない（PC でも直せないようにしてある）
            let plan = candidates.count > 1 ? PCEditPlan.skip(PCEdits.sameTimeLines)
                : PCEdits.plan(edit, line: found?.line, people: registered ?? [])
            switch plan {
            case .already:
                outcome = .applied(edit.id)
            case .skip(let reason):
                outcome = .skipped(edit.id, reason)
            case .fail(let reason):
                outcome = .failed(edit.id, reason)
            case .text(let text):
                if let line = found?.line, await applyPCText(text, to: line, day: edit.day) {
                    edited.insert(edit.day)
                    outcome = .applied(edit.id)
                } else {
                    outcome = store.retry(edit.id, reason: failedReason)
                }
            case .speaker(let target):
                if let line = found?.line {
                    // アプリで1行の話し手を直すときと同じ（この行だけ。声もその人の声として覚える）
                    await waitForQueue()
                    await fixSpeaker(of: line, next: found?.next, to: target, scope: .line)
                }
                if PCEdits.find(edit.time, in: conversations(on: edit.day))?.line.speakerID == target {
                    edited.insert(edit.day)
                    outcome = .applied(edit.id)
                } else {
                    outcome = store.retry(edit.id, reason: failedReason)
                }
            }
            guard let result = outcome else {
                // 一時的に当てられなかった（たいてい通信が切れている）。これと残りは次の機会に
                open.append(edit.id)
                stopped = true
                continue
            }
            store.count(result)
            store.pending.append(result)
            results.append(result)
            Tally.add("edits." + result.status)
        }
        store.save()

        if !results.isEmpty {
            do {
                let body = try JSONEncoder().encode(PCEditsAck(results: results))
                _ = try await homePC.postJSONData("edits/ack", body: body, timeout: 10)
                let acked = Set(results.map(\.id))
                store.pending.removeAll { acked.contains($0.id) }
                for id in acked { store.attempts[String(id)] = nil }
                store.lastError = nil
            } catch {
                store.lastError = "PC に結果を伝えられませんでした: " + HomePC.describe(error)
                open += results.map(\.id)
            }
        }
        store.after = PCEdits.nextAfter(current: store.after, fetched: items.map(\.id), open: open)
        store.lastAt = .now
        store.save()
        return (edited, items.count, open.isEmpty)
    }

    /// 文を当てる（手で直したのと同じ。履歴には「PC で直した」）。当たったら true
    private func applyPCText(_ text: String, to line: ConversationLog.Line, day: String) async -> Bool {
        let change = ConversationLog.TextChange(line: line, text: text, confidence: 1, manual: true, by: PCEdits.by)
        guard let fixed = try? await editTextFromPC([change], day: day) else { return false }
        if fixed > 0 { return true }
        // 待っているあいだに同じ文になっていれば、当たったことにする
        return PCEdits.find(line.time, in: conversations(on: day))?.line.text == text
    }

    /// 変わった日の記録を PC に送る（1回に5日まで。first の日を先に）
    private func pushPCRecords(until deadline: Date?, first: Set<String>) async {
        let now = Date.now
        PCRecords.upgradeFormatIfNeeded()
        var sent = PCRecords.sentStamps
        var hashes = PCRecords.sentHashes
        let days = recordedDays()
        var stamps: [String: Double] = [:]
        for day in days { stamps[day] = dayModified(day)?.timeIntervalSince1970 ?? 0 }
        // PC の直しを当てた日を送り直せなかったら、次のやり取りを早める（PC は送り直すまで、当てた直しを次の直しの「直す前」にする）
        defer { PCLinkState.shared.recordsSoon = first.contains { sent[$0] != stamps[$0] } }
        let start = Calendar.current.date(byAdding: .day, value: -(PCRecords.backfillDays - 1), to: now) ?? now
        let list = PCRecords.daysToSend(days: days, stamps: stamps, sent: sent, oldest: PCJSON.dayString(start), first: first)
        guard !list.isEmpty else { return }
        let encoder = PCJSON.encoder()
        var posted = 0
        var looked = 0
        var problem: String?
        for day in list {
            guard posted < PCRecords.perRound, looked < PCRecords.perRound * 3 else { break }
            if let deadline, Date.now > deadline { break }
            looked += 1
            let stamp = stamps[day] ?? 0
            let payload = recordsPayload(day)
            // 閉じた会話がまだ無い日（朝の今日など）は、閉じてから送る
            if payload.conversations.isEmpty, payload.removed.isEmpty, sent[day] == nil { continue }
            // 職場の会話の印を足す（判断はアプリが職場の会話を外に出さない決まりと同じ）
            let body = PCRecordsBody.make(payload) { self.isWorkTime($0) }
            guard let data = try? encoder.encode(body) else {
                Tally.add("records.unencodable")
                sent[day] = stamp
                continue
            }
            let hash = PCRecords.hash(data)
            // 続いている会話だけが変わった日など、送る中身が前と同じなら送らない
            if hashes[day] == hash {
                sent[day] = stamp
                continue
            }
            guard data.count <= PCRecords.maxBytes else {
                Tally.add("records.tooBig")
                sent[day] = stamp
                hashes[day] = hash
                continue
            }
            do {
                _ = try await homePC.postJSONData("records/" + day, body: data, timeout: 30)
                sent[day] = stamp
                hashes[day] = hash
                posted += 1
                PCRecords.save(sent: sent, hashes: hashes)
            } catch {
                problem = HomePC.describe(error)
                break
            }
        }
        PCRecords.save(sent: sent, hashes: hashes)
        if posted > 0 { Tally.add("records.sent", posted) }
        PCRecords.note(posted: posted, problem: problem, now: now)
    }
}

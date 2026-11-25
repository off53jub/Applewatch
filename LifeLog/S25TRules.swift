import Foundation

// s25（2026-11-24）の A1 の決まり（決まった入力から決まった出力だけ。通信しない・画面を持たない）。
// 案は母艦の docs/system-proposal-2026-11-13.md の「追記 14」（連2・連4・連6・活5・活7・仕5・片5）と「追記 15」（大8・大9・大10）。
// 担当どうしの取り決めは K1（LINE のタスク）・K2（下書き）・K3（LINE の共有）・K7（耳打ち）・K8（検索）。
// 動きは S25TBook.swift、画面は S25TViews.swift。テストは LifeLogTests/S25TTests.swift。しきい値はどれも仮。

// MARK: - 共通

enum S25TText {
    /// 前後の空白を取り、空なら nil
    static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// n 文字に縮める（縮めたら最後を「…」に）
    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > n, n > 1 else { return t }
        return String(t.prefix(n - 1)) + "…"
    }

    /// "YYYY-MM-DD" か
    static func isDay(_ s: String?) -> Bool {
        guard let s, s.count == 10 else { return false }
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        return p.count == 3 && p[0].count == 4 && p[1].count == 2 && p[2].count == 2 && p.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// "YYYY-MM-DD" をその日の 0 時に（読めなければ nil）
    static func date(_ day: String?, calendar: Calendar = .current) -> Date? {
        guard let day, isDay(day) else { return nil }
        let p = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// 名前の比べ方（空白・さん・くん・ちゃん・様を除く）。2 文字以上なら頭が合えば同じ（「田中」と「田中太郎」）
    static func sameName(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            var t = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
            for tail in ["さん", "くん", "君", "ちゃん", "様", "さま"] where t.hasSuffix(tail) && t.count > tail.count {
                t.removeLast(tail.count)
            }
            return t.lowercased()
        }
        let x = key(a), y = key(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard min(x.count, y.count) >= 2 else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }
}

// MARK: - 連2・仕5 LINE のタスク候補（取り決め K1）

/// GET /line-tasks の 1 行（母艦の state/line_tasks_for_app.json）
struct S25TLineTask: Equatable, Sendable {
    var id: String
    var text: String
    var who: String?
    var due: String?
    var day: String
    var work: Bool
    var evidence: String?
    var expires: String
}

enum S25TLineTasks {
    /// 根拠の引用は 8 字まで（K1。本文全部は入れない）
    static let evidenceMax = 8
    static let textMax = 80
    /// 1 回に取り込む数（仮）
    static let importMax = 20
    /// アプリの中の id の頭（同じ行を 2 回入れない）
    static let idPrefix = "line-"

    /// 形が合わない行は落とす。期限（expires）の過ぎたものも落とす。evidence は 8 字までに切る
    static func decode(_ data: Data, today: String) -> [S25TLineTask] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if (root["available"] as? Bool) == false { return [] }
        guard let rows = root["items"] as? [Any] else { return [] }
        var out: [S25TLineTask] = []
        var seen = Set<String>()
        for case let row as [String: Any] in rows {
            guard let id = S25TText.trimmed(row["id"] as? String), let text = S25TText.trimmed(row["text"] as? String),
                  let day = row["day"] as? String, S25TText.isDay(day),
                  let expires = row["expires"] as? String, S25TText.isDay(expires), expires >= today,
                  seen.insert(id).inserted else { continue }
            let due = (row["due"] as? String).flatMap { S25TText.isDay($0) ? $0 : nil }
            let evidence = S25TText.trimmed(row["evidence"] as? String).map { String($0.prefix(evidenceMax)) }
            out.append(S25TLineTask(id: id, text: S25TText.clip(text, textMax), who: S25TText.trimmed(row["who"] as? String),
                                    due: due, day: day, work: (row["work"] as? Bool) ?? false, evidence: evidence,
                                    expires: expires))
        }
        return out
    }

    /// 仕5: 職場の候補は「だれから・いつまで」の両方があるものだけ（会話・LINE とも）。仕事以外はそのまま
    static func workOK(work: Bool, who: String?, due: Date?, dueText: String?) -> Bool {
        guard work else { return true }
        let hasWho = S25TText.trimmed(who) != nil
        let hasDue = due != nil || S25TText.trimmed(dueText) != nil
        return hasWho && hasDue
    }

    /// 帳に入れる候補にする（もう帳にある id・仕5 に足りないものは入れない）。said はその日の 12 時（仮）
    static func candidates(_ rows: [S25TLineTask], existingIDs: Set<String>, calendar: Calendar = .current) -> [TaskBook.Item] {
        var out: [TaskBook.Item] = []
        for row in rows.prefix(importMax) {
            let id = idPrefix + row.id
            guard !existingIDs.contains(id) else { continue }
            let due = S25TText.date(row.due, calendar: calendar)
            guard workOK(work: row.work, who: row.who, due: due, dueText: nil) else { continue }
            let said = S25TText.date(row.day, calendar: calendar)?.addingTimeInterval(12 * 3600) ?? .now
            var item = TaskBook.Item(what: row.text, from: row.who, due: due, said: said, day: row.day,
                                     quote: row.evidence.map { "LINE「" + $0 + "」" }, source: .line, state: .candidate,
                                     work: row.work)
            item.id = id
            out.append(item)
        }
        return out
    }

    /// 今日の候補 3 件の中で、LINE から来たものを会話から拾ったものより先に（同じ源の中は今の順のまま）
    static func lineFirst(_ items: [TaskBook.Item]) -> [TaskBook.Item] {
        items.filter { $0.source == .line } + items.filter { $0.source != .line }
    }
}

// MARK: - 大8 下書きの棚（取り決め K2）

struct S25TDraft: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// reply・calendar・settle・report・other
    var kind: String
    var title: String
    var body: String
    var to: String? = nil
    var when: String? = nil
    var evidence: String? = nil
    var expires: String
    var source: String
}

enum S25TDrafts {
    static let kinds = ["reply", "calendar", "settle", "report", "other"]
    /// 棚に出す数（仮 3）
    static let shelfMax = 3
    static let bodyMax = 4000
    /// 答え（app_feedback の kind "draft" の value）
    static let actions = ["sent", "edited", "dropped"]

    /// 形が合わない行・期限の過ぎた行は落とす。知らない kind は other に
    static func decode(_ data: Data, today: String) -> [S25TDraft] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if (root["available"] as? Bool) == false { return [] }
        guard let rows = root["items"] as? [Any] else { return [] }
        var out: [S25TDraft] = []
        var seen = Set<String>()
        for case let row as [String: Any] in rows {
            guard let id = S25TText.trimmed(row["id"] as? String), let title = S25TText.trimmed(row["title"] as? String),
                  let body = S25TText.trimmed(row["body"] as? String),
                  let expires = row["expires"] as? String, S25TText.isDay(expires), expires >= today,
                  seen.insert(id).inserted else { continue }
            let raw = (row["kind"] as? String) ?? "other"
            out.append(S25TDraft(id: id, kind: kinds.contains(raw) ? raw : "other", title: S25TText.clip(title, 60),
                                 body: String(body.prefix(bodyMax)), to: S25TText.trimmed(row["to"] as? String),
                                 when: S25TText.trimmed(row["when"] as? String),
                                 evidence: S25TText.trimmed(row["evidence"] as? String).map { S25TText.clip($0, 80) },
                                 expires: expires, source: S25TText.trimmed(row["source"] as? String) ?? ""))
        }
        return out
    }

    /// 家の PC が Google カレンダーを直す下書き（2026-11-25。母艦 Sync-LineCalendar.py）。押すと家の PC が直す
    static let calendarFixSource = "line-calendar"

    static func isCalendarFix(_ d: S25TDraft) -> Bool { d.source == calendarFixSource }

    /// 棚に出すもの: 答えたものを除き、カレンダーを直す下書き → 精算 → 返事 → 予定 → 報告 → そのほかの順（同じ種類は届いた順）。shelfMax まで
    static func shelf(_ drafts: [S25TDraft], handled: Set<String>, limit: Int = shelfMax) -> [S25TDraft] {
        let order = ["settle", "reply", "calendar", "report", "other"]
        func rank(_ d: S25TDraft) -> Int {
            if isCalendarFix(d) { return -1 }
            return order.firstIndex(of: d.kind) ?? order.count
        }
        let alive = drafts.enumerated().filter { !handled.contains($0.element.id) }
        let sorted = alive.sorted { a, b in
            let x = rank(a.element), y = rank(b.element)
            return x != y ? x < y : a.offset < b.offset
        }
        return Array(sorted.prefix(limit).map(\.element))
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "reply": "返事"
        case "calendar": "予定"
        case "settle": "精算"
        case "report": "報告"
        default: "下書き"
        }
    }

    /// 送る文（宛先・日時は頭に添える。本文はそのまま）
    static func shareText(_ d: S25TDraft) -> String {
        var head: [String] = []
        if let to = d.to { head.append("宛先: " + to) }
        if let when = d.when { head.append("日時: " + when) }
        return head.isEmpty ? d.body : head.joined(separator: "\n") + "\n\n" + d.body
    }
}

// MARK: - 連6 LINE の「トーク履歴を送信」を家の PC へ（取り決め K3）

enum S25TLineShare {
    /// 家の PC が受ける大きさ（1 MB まで）。JSON の包みの分を少し残す
    static let maxBytes = 1_000_000 - 4_096
    static let nameMax = 40
    static let cutNote = "（前の分は大きすぎるので省きました）"

    /// 相手の名前: 1 行目の「[LINE] ◯◯とのトーク履歴」→ ファイル名 →「LINE」。ファイル名に使えない文字は _ に
    static func name(text: String, fileName: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let fromText = strip(first)
        let stem = (fileName as NSString).deletingPathExtension
        let raw = fromText ?? strip(stem) ?? S25TText.trimmed(stem) ?? "LINE"
        return safe(raw)
    }

    private static func strip(_ line: String) -> String? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\u{FEFF}", with: "")
        guard s.contains("トーク") else { return nil }
        if s.hasPrefix("[LINE]") { s = String(s.dropFirst(6)) }
        for tail in ["とのトーク履歴", "のトーク履歴", "とのトーク", "のトーク", "トーク履歴"] where s.hasSuffix(tail) {
            s = String(s.dropLast(tail.count))
            break
        }
        return S25TText.trimmed(s)
    }

    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = String(s.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        let t = cleaned.trimmingCharacters(in: .whitespaces)
        return String((t.isEmpty ? "LINE" : t).prefix(nameMax))
    }

    /// 1 MB に収める: 大きければ 1 行目（題）を残し、古い（前の）行から落として、新しい側を残す
    static func capped(_ text: String, maxBytes: Int = maxBytes) -> (text: String, cut: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        let lines = text.components(separatedBy: "\n")
        let head = (lines.first ?? "") + "\n" + cutNote + "\n"
        var budget = maxBytes - head.utf8.count
        var kept: [String] = []
        for line in lines.dropFirst().reversed() {
            let n = line.utf8.count + 1
            if n > budget { break }
            budget -= n
            kept.append(line)
        }
        return (head + kept.reversed().joined(separator: "\n"), true)
    }

    /// LINE の書き出しらしいか（題か日付の行がある。違っても送れるが、画面で一言添える）
    static func looksLikeLine(_ text: String) -> Bool {
        let head = String(text.prefix(400))
        return head.contains("[LINE]") || head.contains("トーク履歴")
    }

    /// POST /line/share の体
    static func body(name: String, text: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["name": name, "text": text], options: [])
    }
}

// MARK: - 大10 耳打ち（取り決め K7。初めはオフ）

struct S25TWhisper: Codable, Equatable, Sendable {
    var person: String
    var lastTalk: String? = nil
    var promises: [String] = []
}

enum S25TWhisperRules {
    /// 設定の名前（初めはオフ）
    static let onKey = "s25t.whisper"
    /// 聞く間（秒。仮 2 分）
    static let every: TimeInterval = 120
    /// 時計に出しておく長さ（秒。仮 10 分）
    static let keep: TimeInterval = 600
    static let promisesMax = 3

    /// GET /whisper-now の答え（{} か、person の無いものは nil）
    static func decode(_ data: Data) -> S25TWhisper? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let person = S25TText.trimmed(root["person"] as? String) else { return nil }
        let promises = (root["promises"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(S25TText.trimmed) }
        return S25TWhisper(person: S25TText.clip(person, 20),
                           lastTalk: S25TText.trimmed(root["last_talk"] as? String).map { S25TText.clip($0, 80) },
                           promises: Array(promises.prefix(promisesMax)).map { S25TText.clip($0, 40) })
    }

    /// いま聞きに行くか: オン・録音中（iPhone か時計）・前に聞いてから every たった
    static func shouldAsk(on: Bool, recording: Bool, lastAsked: Date?, now: Date) -> Bool {
        guard on, recording else { return false }
        guard let lastAsked else { return true }
        return now.timeIntervalSince(lastAsked) >= every
    }

    /// 時計に出し直すか（相手が変わったときだけ。同じ相手なら出し直さない＝1 回だけ）
    static func changed(previous: String?, now: S25TWhisper?) -> Bool {
        guard let now else { return false }
        guard let previous else { return true }
        return !S25TText.sameName(previous, now.person)
    }

    /// まだ出しておくか
    static func alive(shownAt: Date?, now: Date) -> Bool {
        guard let shownAt else { return false }
        return now.timeIntervalSince(shownAt) < keep
    }
}

// MARK: - 連4 会う前の準備に LINE の要点

enum S25TPrepLine {
    static let linesMax = 3
    static let chars = 80

    /// prep_for_app.json の省ける "line"。文・文の並び・{"summary", "lines"|"points"} のどれでも読む。無ければ空
    static func lines(_ raw: Any?) -> [String] {
        var out: [String] = []
        if let s = raw as? String {
            out = [s]
        } else if let list = raw as? [Any] {
            out = list.compactMap { $0 as? String }
        } else if let obj = raw as? [String: Any] {
            if let s = obj["summary"] as? String { out.append(s) }
            out += ((obj["lines"] ?? obj["points"]) as? [Any] ?? []).compactMap { $0 as? String }
        }
        return Array(out.compactMap(S25TText.trimmed).prefix(linesMax)).map { S25TText.clip($0, chars) }
    }
}

/// prep の "line" を、形を決めずに読む（文・並び・物のどれでも）
struct S25TPrepLineField: Decodable, Equatable {
    var lines: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            lines = S25TPrepLine.lines(s)
        } else if let list = try? c.decode([String].self) {
            lines = S25TPrepLine.lines(list)
        } else if let obj = try? c.decode(Obj.self) {
            var raw: [String: Any] = [:]
            if let s = obj.summary { raw["summary"] = s }
            if let l = obj.lines ?? obj.points { raw["lines"] = l }
            lines = S25TPrepLine.lines(raw)
        } else {
            lines = []
        }
    }

    private struct Obj: Decodable {
        var summary: String?
        var lines: [String]?
        var points: [String]?
    }
}

// MARK: - 活5・活7 家の PC の検索の口（取り決め K8）

struct S25TSearchHit: Equatable, Identifiable, Sendable {
    var id: String
    var source: String
    var day: String
    var time: String
    var label: String
    var text: String
}

enum S25TSearch {
    /// 新しい口（家の PC にまだ無い。PR に形を書く。無ければ 404 で静かに「まだ」と出す）
    static let path = "mother-search"
    static let queryMax = 100
    static let k = 20

    static func body(query: String, person: String? = nil, sources: [String]? = nil, days: Int? = nil, k: Int = k) -> Data? {
        var b: [String: Any] = ["query": String(query.prefix(queryMax)), "k": k]
        if let person { b["person"] = person }
        if let sources { b["sources"] = sources }
        if let days { b["days"] = days }
        return try? JSONSerialization.data(withJSONObject: b, options: [])
    }

    /// {"hits": [{"source","day","time","label","text"}]}（形の合わない行は落とす。day の無い行も落とす）
    static func decode(_ data: Data) -> [S25TSearchHit]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if (root["available"] as? Bool) == false { return nil }
        guard let rows = root["hits"] as? [Any] else { return nil }
        var out: [S25TSearchHit] = []
        for (i, any) in rows.enumerated() {
            guard let row = any as? [String: Any], let text = S25TText.trimmed(row["text"] as? String),
                  let day = row["day"] as? String, day.count >= 7 else { continue }
            let source = (row["source"] as? String) ?? ""
            let label = S25TText.trimmed(row["label"] as? String) ?? MothershipAsk.label(source)
            out.append(S25TSearchHit(id: "\(i)-" + day, source: source, day: day, time: (row["time"] as? String) ?? "",
                                     label: label, text: S25TText.clip(text, 240)))
        }
        return out
    }
}

/// 活7 話した相手の時系列（会話と LINE を 1 本に）
struct S25TTimelineRow: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case talk, line }
    var kind: Kind
    /// 並べる鍵（"YYYY-MM-DD HH:MM"。時刻が無ければ "YYYY-MM-DD"）
    var key: String
    var day: String
    var time: String
    var text: String
    var id: String { kind.rawValue + "|" + key + "|" + String(text.prefix(20)) }
}

enum S25TTimeline {
    static let rowsMax = 40

    /// 新しいものから。同じ時刻なら会話を先に
    static func merge(talks: [(day: String, time: String, text: String)], line: [S25TSearchHit],
                      limit: Int = rowsMax) -> [S25TTimelineRow] {
        var rows: [S25TTimelineRow] = talks.map {
            S25TTimelineRow(kind: .talk, key: key($0.day, $0.time), day: $0.day, time: $0.time, text: $0.text)
        }
        rows += line.map { S25TTimelineRow(kind: .line, key: key($0.day, $0.time), day: $0.day, time: $0.time, text: $0.text) }
        let sorted = rows.enumerated().sorted { a, b in
            if a.element.key != b.element.key { return a.element.key > b.element.key }
            if a.element.kind != b.element.kind { return a.element.kind == .talk }
            return a.offset < b.offset
        }
        return Array(sorted.prefix(limit).map(\.element))
    }

    static func key(_ day: String, _ time: String) -> String {
        let t = time.trimmingCharacters(in: .whitespaces)
        // PLAUD の「+00:01:02」のような録音からの時間は並べるのに使わない
        guard t.count >= 4, t.count <= 5, t.contains(":"), !t.hasPrefix("+") else { return day }
        return day + " " + (t.count == 4 ? "0" + t : t)
    }
}

// MARK: - 片5 30 日触っていない設定は「くわしい」の奥へ

enum S25TSettingsFold {
    /// 触った数を数え始めた日（s24 の 形2）。ここから 30 日たつまでは何も奥へ入れない（仮）
    static let countingSince = "2026-11-24"
    static let days = 30

    /// 出すもの・奥へ入れるもの（どちらも元の並び）。初めから変えてあるものはいつも出す。
    /// 探しているあいだ（searching）は全部出す
    static func split(_ ids: [String], sums: [String: Int], changed: Set<String>, today: String,
                      searching: Bool) -> (shown: [String], deep: [String]) {
        guard !searching, let passed = S24Entries.daysBetween(countingSince, today), passed >= days else { return (ids, []) }
        var shown: [String] = []
        var deep: [String] = []
        for id in ids {
            if changed.contains(id) || (sums[S24Settings.tallyName(id)] ?? 0) > 0 { shown.append(id) } else { deep.append(id) }
        }
        return (shown, deep)
    }
}

// MARK: - 大9 この声は誰？（1 日 3 問の中で）と、会ったその場の 1 タップ

struct S25TVoiceCandidate: Equatable, Sendable {
    var id: String
    var named: Bool
    var isSelf: Bool
    var hidden: Bool
    var seconds: Double
    var lastHeard: Date
    var hasSample: Bool
}

enum S25TVoice {
    /// 聞く声の長さの下限（秒。仮 2 分）
    static let minSeconds: Double = 120
    /// 最後に聞こえてからの日数（仮 7 日）
    static let recentDays: Double = 7

    /// 名前の無い声から 1 つ（長く話した順）。今日の問いが上限に来ていたら出さない
    static func pick(_ people: [S25TVoiceCandidate], asked: Int, cap: Int, skipped: Set<String>, now: Date) -> String? {
        guard asked < cap else { return nil }
        let since = now.addingTimeInterval(-recentDays * 86400)
        return people
            .filter { !$0.named && !$0.isSelf && !$0.hidden && $0.hasSample && $0.seconds >= minSeconds && $0.lastHeard >= since
                && !skipped.contains($0.id) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
            .first?.id
    }

    /// 会ったその場で声を足す先: 同じ名前の人がいればその人（足す）、いなければ nil（新しく登録する）
    static func target(name: String, people: [(id: String, name: String?)]) -> String? {
        people.first { p in p.name.map { S25TText.sameName($0, name) } == true }?.id
    }
}

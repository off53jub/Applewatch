import Foundation
import Observation
import UIKit
import UserNotifications

/// 仕事のまとめ（2026-11-08）。職場の Claude に「この日に何があったか」を聞いた答えを、
/// スクリーンショット・写真（iPhone の中で文字を読み取る）か、文字の貼り付けで取り込んで、日ごとに残す。
/// 中身は `work-digests.json` に端末ごとに持つ（同期はしない。新しいファイルなので、前からの保存形式は変えていない）。
/// 「自分の宿題」は、頼まれごと帳の「やる」（仕事）に入れる。iPhone はドライブの「仕事のまとめ」と同期フォルダの「仕事のまとめ.json」にも写す。
/// 取り込み（文字の読み取り・見出しの分け方・宿題の取り出し）には言語モデルを使わない。
/// 2026-11-10 から、本人の決定で「記録に質問する」の材料には渡す（職場の中身なので、職場の会話と同じ設定に従う。
/// 前は「言語モデルには一切渡さない」決まりだった）。「記録」の検索でも探せる（こちらは言語モデルを使わない）。
@MainActor
@Observable
final class WorkDigest {
    /// どこから取り込んだか
    enum Source: String, Codable {
        case photo, paste

        var label: String {
            switch self {
            case .photo: "写真から"
            case .paste: "貼り付け"
            }
        }
    }

    /// 決まった形の答えを、見出しごとに分けたもの
    struct Sections: Codable, Equatable {
        var decided: [String] = []
        var homework: [String] = []
        var others: [String] = []
        var topics: [String] = []
        var checks: [String] = []
        /// 【よく出た言葉】（2026-11-10。言葉だけ・1つずつ。前の版で保存したものには無いので nil）。
        /// 「言葉の登録」の候補に出すだけで、自動では登録しない
        var words: [String]? = nil
        /// 【出どころ】（2026-11-10。どのチーム・チャネル・チャットの話か、そこにいた人。1行に1つ。
        /// 前の版で保存したものには無いので nil）。見せるだけで、人の帳には何も足さない
        var sources: [String]? = nil

        var isEmpty: Bool {
            decided.isEmpty && homework.isEmpty && others.isEmpty && topics.isEmpty && checks.isEmpty
                && (words ?? []).isEmpty && (sources ?? []).isEmpty
        }

        /// 画面とドライブに並べる順（中身のある見出しだけ）
        var lists: [(title: String, items: [String])] {
            let all: [(title: String, items: [String])] = [
                ("出どころ", sources ?? []),
                ("決まったこと", decided), ("自分の宿題", homework), ("ほかの人の動き", others),
                ("気になる話題", topics), ("あとで確かめること", checks), ("よく出た言葉", words ?? []),
            ]
            return all.filter { !$0.items.isEmpty }
        }
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        /// その日（yyyy-MM-dd）
        var day: String
        /// 取り込んだ文字（本人が直したあとのもの・まるごと）
        var text: String
        /// 見出しごとに分けたもの（決まった形で無ければ nil）
        var sections: Sections? = nil
        var source: Source
        var addedAt: Date = .now
    }

    private(set) var entries: [Entry] = []
    /// 中身が変わるたびに増える
    private(set) var version = 0

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("work-digests.json")

    /// 読み込んでから使う（読む前に保存しない。頼まれごと帳と同じ形）
    init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            // 読めないファイルは上書きせず、脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("work-digests-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    /// 新しい日から、同じ日の中は新しく取り込んだものから
    var sorted: [Entry] {
        entries.sorted { a, b in a.day != b.day ? a.day > b.day : a.addedAt > b.addedAt }
    }

    /// 日ごと（新しい日から）
    var byDay: [(day: String, entries: [Entry])] {
        var out: [(day: String, entries: [Entry])] = []
        for entry in sorted {
            if let last = out.last, last.day == entry.day {
                out[out.count - 1].entries.append(entry)
            } else {
                out.append((entry.day, [entry]))
            }
        }
        return out
    }

    /// 足す。同じ日に同じ文がもうあれば足さずに nil（同じ日に何回取り込んでもよいが、まったく同じものは1つだけ）
    @discardableResult
    func add(day: String, text: String, sections: Sections?, source: Source, now: Date = .now) -> Entry? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let key = WorkDigestParser.compact(body)
        let same = entries.contains { $0.day == day && WorkDigestParser.compact($0.text) == key }
        guard !same else { return nil }
        let entry = Entry(day: day, text: body, sections: sections, source: source, addedAt: now)
        entries.append(entry)
        save()
        return entry
    }

    func delete(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func save() {
        version += 1
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}

// MARK: - 文を読む

/// 職場の Claude の答え（決まった形）を読む。写真の読み取りの崩れ（余計な空白・「・」の揺れ・全角の数字）に強くする。
/// 形が崩れていたり、見出しが欠けていたりしても、読めたところだけ返す。
enum WorkDigestParser {
    enum Part: String, CaseIterable {
        case date, decided, homework, others, topics, checks, words, sources
    }

    /// 見出しの言い方（長いものを先に）
    static let names: [(part: Part, aliases: [String])] = [
        (.date, ["日付", "日にち"]),
        // 「出典」は入れない（ふつうの文の行「出典: …」を見出しと読み違えるので）
        (.sources, ["出どころ", "出所", "抜粋元", "抜粋もと"]),
        (.decided, ["決まったこと", "決まった事", "きまったこと"]),
        (.homework, ["自分の宿題", "じぶんの宿題", "わたしの宿題", "私の宿題", "宿題"]),
        (.others, ["ほかの人の動き", "他の人の動き", "外の人の動き", "ほかの人"]),
        (.topics, ["気になる話題", "気になった話題", "気になること"]),
        (.checks, ["あとで確かめること", "後で確かめること", "あとで確認すること", "後で確認すること", "あとで確かめる"]),
        // 「言葉」「用語」だけの短い言い方は入れない（ふつうの文の行を見出しと読み違えるので）
        (.words, ["よく出た言葉", "よく出たことば", "よく出てきた言葉", "よく出る言葉", "よくでた言葉", "頻出語"]),
    ]

    /// 見出しの前のかっこ（【 が [ や（ に読まれることもある）
    static let openers: Set<Character> = ["【", "[", "［", "〔", "「", "『", "(", "（", "<", "＜", "《", "〈", "■", "◆", "▼", "#", "＃"]
    /// 見出しの後ろのかっこ・区切り
    static let closers: Set<Character> = ["】", "]", "］", "〕", "」", "』", ")", "）", ">", "＞", "》", "〉", ":", "：", "|", "｜"]
    /// 箇条書きの印（「・」の読み違いも含む）
    static let bullets: Set<Character> = ["・", "･", "•", "·", "‧", "∙", "⋅", "●", "○", "◦", "▪", "▫", "■", "□", "◆", "◇",
                                          "-", "−", "‐", "–", "—", "*", "＊", ".", "。", "、", "‣", "⁃", "→"]
    /// 「なし」だけの行（項目にしない）
    static let nothing: Set<String> = ["なし", "無し", "特になし", "特に無し", "とくになし", "ありません", "特にありません", "とくにありません",
                                       "ない", "特にない", "-", "—", "ー", "－", "なし。", "特になし。"]

    struct Parsed: Equatable {
        /// 【日付】の日（yyyy-MM-dd。見つからなければ nil）
        var day: String?
        var sections = WorkDigest.Sections()
        /// 見出しが1つでも見つかったか
        var found = false
        /// 【自分の宿題】の箇条書きの前に書かれていた前置きの文（2026-11-10。まとめには残すが、タスクにはしない。保存しない）
        var homeworkLead: [String] = []

        /// タスクにする宿題（前置きの文を除いたもの）
        var homeworkTasks: [String] {
            sections.homework.filter { !homeworkLead.contains($0) }
        }
    }

    /// 自分の宿題1件を分けたもの
    struct Homework: Equatable {
        var what: String
        var from: String? = nil
        var dueText: String? = nil
    }

    // MARK: 整える

    /// 全角の数字・記号を半角に（「／」はそのまま。区切りに使うので）
    static func halfWidth(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0xFF10 && v <= 0xFF19, let s = Unicode.Scalar(v - 0xFF10 + 0x30) {
                out.unicodeScalars.append(s)
            } else if v == 0xFF0D {
                out.unicodeScalars.append("-")
            } else if v == 0xFF0E {
                out.unicodeScalars.append(".")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// 空白を全部除いた形（同じ文かを比べる）
    static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// 日本語の字のあいだの余計な空白を除き、続く空白を1つにする（読み取りの癖）
    static func tidy(_ text: String) -> String {
        let chars: [Character] = Array(text.trimmingCharacters(in: .whitespaces))
        var out = ""
        for i in chars.indices {
            let c = chars[i]
            guard c.isWhitespace else {
                out.append(c)
                continue
            }
            guard let prev = out.last, i + 1 < chars.count else { continue }
            let next = chars[i + 1]
            if next.isWhitespace || prev.isWhitespace { continue }
            // 両側が日本語の字（英数字でない）なら、空白は読み取りの癖
            if !prev.isASCII && !next.isASCII { continue }
            // かっこ・句読点の前後の空白も除く
            if "（）「」【】、。・／：".contains(next) || "（）「」【】、。・／：".contains(prev) { continue }
            out.append(" ")
        }
        return out
    }

    /// 保存する前に整える（行の前後の空白を除き、続く空行を1つに）
    static func clean(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: 見出し・箇条書き

    /// 見出しの行なら、どの見出しかと、同じ行の残り（空白を除いたもの）
    static func header(_ line: String) -> (part: Part, rest: String)? {
        var s = Substring(compact(line))
        var opened = false
        while let c = s.first, openers.contains(c) {
            s = s.dropFirst()
            opened = true
        }
        for entry in names {
            for alias in entry.aliases where s.hasPrefix(alias) {
                var rest = s.dropFirst(alias.count)
                let closed = rest.first.map { closers.contains($0) } ?? false
                // かっこで始まるか、かっこ・区切りで閉じるか、見出しだけの行（ふつうの文の行と見分ける）
                guard opened || closed || rest.isEmpty else { continue }
                while let c = rest.first, closers.contains(c) { rest = rest.dropFirst() }
                return (entry.part, String(rest))
            }
        }
        return nil
    }

    /// 箇条書きの行なら、印を除いた中身
    static func bulletBody(_ line: String) -> String? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return nil }
        if bullets.contains(first) {
            var rest = Substring(s)
            while let c = rest.first, bullets.contains(c) || c.isWhitespace { rest = rest.dropFirst() }
            return String(rest)
        }
        // 「1.」「2)」「３、」のような番号
        let half = halfWidth(s)
        let digits = half.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let after = half.dropFirst(digits.count)
        guard let mark = after.first, ".)）、:".contains(mark) else { return nil }
        // 「11/8」「1.5倍」のようなものは番号にしない
        let tail = after.dropFirst()
        if let n = tail.first, n.isASCII && n.isNumber { return nil }
        return String(tail).trimmingCharacters(in: .whitespaces)
    }

    // MARK: 読む

    static func parse(_ text: String, today: Date = .now) -> Parsed {
        var result = Parsed()
        var current: Part? = nil
        // 今の見出しの項目（続きの行をつなげるため、箇条書きの印があったか）
        var items: [String] = []
        var bulleted = false

        func flush() {
            guard let part = current, part != .date else {
                items = []
                return
            }
            let kept: [String] = items.map { tidy($0) }.filter { !$0.isEmpty && !nothing.contains($0) }
            switch part {
            case .decided: result.sections.decided += kept
            case .homework: result.sections.homework += kept
            case .others: result.sections.others += kept
            case .topics: result.sections.topics += kept
            case .checks: result.sections.checks += kept
            case .words:
                let found: [String] = words((result.sections.words ?? []) + kept)
                if !found.isEmpty { result.sections.words = found }
            case .sources:
                // 同じ行は1つだけ（重なったスクショをつなぐと、同じ行が2回出る）
                var all: [String] = result.sections.sources ?? []
                for item in kept {
                    let key: String = compact(item)
                    if !all.contains(where: { compact($0) == key }) { all.append(item) }
                }
                if !all.isEmpty { result.sections.sources = all }
            case .date: break
            }
            items = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let h = header(line) {
                flush()
                result.found = true
                current = h.part
                bulleted = false
                if h.part == .date {
                    if result.day == nil { result.day = day(in: h.rest, today: today, needYear: false) }
                } else if !h.rest.isEmpty {
                    if let body = bulletBody(h.rest) {
                        items.append(body)
                        bulleted = true
                    } else {
                        items.append(h.rest)
                    }
                }
                continue
            }
            guard let part = current else { continue }
            if part == .date {
                // 日付が次の行に書かれていることもある
                if result.day == nil { result.day = day(in: line, today: today, needYear: false) }
                continue
            }
            if let body = bulletBody(line) {
                // 初めの印より前に書かれた文（前置き）は、1つにまとめる。宿題の前置きは、タスクにしない目印を付ける
                if !bulleted, !items.isEmpty, part != .words, part != .sources {
                    let lead: String = items.dropFirst().reduce(items[0]) { join($0, $1) }
                    if isLead(lead) {
                        items = [lead]
                        if part == .homework { result.homeworkLead.append(tidy(lead)) }
                    }
                }
                items.append(body)
                bulleted = true
            } else if bulleted, part != .words, let last = items.last {
                // 印の無い行は、前の項目の続き（長い行が折り返されたもの）。言葉は1行に1つなので、つながない
                items[items.count - 1] = join(last, line)
            } else {
                items.append(line)
            }
        }
        flush()
        if result.day == nil {
            // 見出しが読めなくても、年の付いた日付があればそれを使う
            for raw in text.components(separatedBy: .newlines) {
                if let d = day(in: raw, today: today, needYear: true) {
                    result.day = d
                    break
                }
            }
        }
        return result
    }

    /// 【よく出た言葉】の行を、言葉1つずつにする。「、」「／」で並べてあれば分け、後ろの説明（かっこ・「：」の後ろ）は落とす。
    /// 長すぎるもの（文になっているもの）と同じ言葉は入れない。多すぎるときは先の 30 個まで
    static func words(_ items: [String]) -> [String] {
        // 半角の「/」では分けない（CI/CD のような言葉があるので）
        let separators: Set<Character> = ["、", ",", "，", "／", ";", "；"]
        let notes: Set<Character> = ["（", "(", "：", ":", "＝", "=", "→", "…"]
        var out: [String] = []
        var seen: Set<String> = []
        for item in items {
            for piece in item.split(whereSeparator: { separators.contains($0) }) {
                var word = String(piece.prefix { !notes.contains($0) })
                word = word.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "「」『』\"'。・")))
                guard !word.isEmpty, word.count <= 30, !word.contains("<"), !word.contains(">"),
                      !nothing.contains(word) else { continue }
                let key = compact(word).lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                out.append(word)
                if out.count >= 30 { return out }
            }
        }
        return out
    }

    /// 箇条書きの前に書かれた、前置きの文か（2026-11-10）。文になっている（「。」がある）か、「：」で終わるもの。
    /// 頼んだ人・期限の付いた宿題（「…（Aさんから／11/10まで）」）は前置きにしない
    static func isLead(_ text: String) -> Bool {
        let s: String = tidy(text)
        guard let last = s.last else { return false }
        guard s.contains("。") || last == "：" || last == ":" else { return false }
        let parts: Homework = homework(s)
        return parts.from == nil && parts.dueText == nil
    }

    /// 折り返された行をつなぐ（英数字どうしなら空白を入れる）
    static func join(_ a: String, _ b: String) -> String {
        guard let x = a.last, let y = b.first else { return a + b }
        return x.isASCII && y.isASCII && (x.isLetter || x.isNumber) && (y.isLetter || y.isNumber) ? a + " " + b : a + b
    }

    // MARK: 日付

    private static let fullDate = try? NSRegularExpression(
        pattern: "(20[0-9]{2})[-/／.年]([0-9]{1,2})[-/／.月]([0-9]{1,2})")
    private static let shortDate = try? NSRegularExpression(pattern: "([0-9]{1,2})[/／月]([0-9]{1,2})")

    /// 文の中の日付を「yyyy-MM-dd」に。needYear が false なら、年の無い「11/8」「11月8日」も今年として読む
    static func day(in text: String, today: Date = .now, needYear: Bool) -> String? {
        let s = compact(halfWidth(text))
        let range = NSRange(s.startIndex..., in: s)
        if let m = fullDate?.firstMatch(in: s, range: range) {
            let y = number(s, m, 1), mo = number(s, m, 2), d = number(s, m, 3)
            return dayString(year: y, month: mo, day: d)
        }
        guard !needYear, let m = shortDate?.firstMatch(in: s, range: range) else { return nil }
        let year = Calendar(identifier: .gregorian).component(.year, from: today)
        return dayString(year: year, month: number(s, m, 1), day: number(s, m, 2))
    }

    private static func number(_ s: String, _ m: NSTextCheckingResult, _ i: Int) -> Int {
        guard let r = Range(m.range(at: i), in: s) else { return 0 }
        return Int(s[r]) ?? 0
    }

    /// あり得る日だけ（2月30日などは nil）
    static func dayString(year: Int, month: Int, day: Int) -> String? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let comps = DateComponents(year: year, month: month, day: day)
        guard let date = cal.date(from: comps), cal.component(.day, from: date) == day,
              cal.component(.month, from: date) == month else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: 宿題

    /// 「資料を送る（Aさんから／11/10まで）」→ やること・頼んだ人・期限の言い方
    static func homework(_ item: String) -> Homework {
        let s = tidy(item)
        guard let last = s.last, last == "）" || last == ")",
              let open = s.lastIndex(where: { $0 == "（" || $0 == "(" }) else { return Homework(what: s) }
        let what = tidy(String(s[..<open]))
        let inner = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        var from: String? = nil
        var due: String? = nil
        var other: [String] = []
        for piece in pieces(inner) {
            if piece.hasSuffix("から") {
                let who = tidy(String(piece.dropLast(2)))
                if from == nil, !isPlaceholder(who) { from = who }
            } else if piece.hasSuffix("まで") || day(in: piece, needYear: false) != nil {
                if due == nil, !isPlaceholder(String(piece.dropLast(piece.hasSuffix("まで") ? 2 : 0))) { due = piece }
            } else if !isPlaceholder(piece) {
                other.append(piece)
            }
        }
        // かっこの中が頼んだ人・期限でなければ、そのまま残す
        guard from != nil || due != nil, !what.isEmpty else {
            return Homework(what: s)
        }
        let rest = other.isEmpty ? "" : "（" + other.joined(separator: "・") + "）"
        return Homework(what: what + rest, from: from, dueText: due)
    }

    /// かっこの中を「／」「、」などで分ける。「Aさんから/11/10まで」のように「/」で続いたものは「から」の後ろで分ける
    static func pieces(_ inner: String) -> [String] {
        let strong: Set<Character> = ["／", "、", ",", "，", ";", "；", "|", "｜", "・"]
        var out: [String] = []
        for part in inner.split(whereSeparator: { strong.contains($0) }) {
            var p = tidy(String(part))
            while let r = p.range(of: "から"), r.upperBound < p.endIndex {
                let head = String(p[..<r.upperBound])
                var tail = Substring(p[r.upperBound...])
                while let c = tail.first, c == "/" || c.isWhitespace { tail = tail.dropFirst() }
                out.append(tidy(head))
                p = tidy(String(tail))
            }
            if !p.isEmpty { out.append(p) }
        }
        return out
    }

    /// 「誰」「いつ」「不明」「?」など、決まった形の書きかけ
    static func isPlaceholder(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let empty: Set<String> = ["", "誰", "だれ", "いつ", "不明", "?", "？", "未定", "なし", "-", "—", "…", "..."]
        return empty.contains(t)
    }

    /// 期限の言い方から日（その日の0時）。「11/10まで」「2026-11-10」「11月10日」。読めなければ nil。
    /// 年の無いものは、まとめの日の年（まとめの日より60日以上前になるなら次の年）
    static func dueDate(_ dueText: String, digestDay: String, calendar: Calendar = .current) -> Date? {
        let base = TaskBook.dayFormat.date(from: digestDay) ?? .now
        let full = day(in: dueText, today: base, needYear: true)
        let found = full ?? day(in: dueText, today: base, needYear: false)
        guard let text = found, var date = TaskBook.dayFormat.date(from: text) else { return nil }
        if full == nil, date < base.addingTimeInterval(-60 * 86400),
           let next = calendar.date(byAdding: .year, value: 1, to: date) {
            date = next
        }
        return calendar.startOfDay(for: date)
    }
}

// MARK: - 取り込む・写す

extension Pipeline {
    private static let workDigestHashKey = "workDigestWritten"

    /// 仕事のまとめを1つ取り込む。「自分の宿題」は頼まれごと帳の「やる」（仕事）に入れる。結果の一文を返す。
    /// 取り込みには言語モデルを使わない。箇条書きの前に書かれた前置きの文は、タスクにしない（2026-11-10）
    @discardableResult
    func importWorkDigest(day: String, text: String, source: WorkDigest.Source, now: Date = .now) -> String {
        let cleaned = WorkDigestParser.clean(text)
        guard !cleaned.isEmpty else { return "文字がありません。" }
        let parsed = WorkDigestParser.parse(cleaned, today: now)
        let sections: WorkDigest.Sections? = parsed.found ? parsed.sections : nil
        guard workDigests.add(day: day, text: cleaned, sections: sections, source: source, now: now) != nil else {
            return "同じ日に、同じまとめがもう入っています。"
        }
        let homework: [String] = parsed.found ? parsed.homeworkTasks : []
        let skipped: Int = (sections?.homework ?? []).count - homework.count
        let items = Self.workDigestTasks(homework, day: day, now: now)
        let added = tasks.add(items)
        if !added.isEmpty { tasksChanged() }
        Task { await writeWorkDigests() }
        scheduleWorkDigestReminder(now: now)  // 今日のまとめを入れたら、退勤の頃の知らせは出さない
        var note = "\(Self.workDigestDayTitle(day)) の仕事のまとめを入れました。"
        if !added.isEmpty {
            note += "自分の宿題 \(added.count) 件を、タスクの「やる」に入れました。"
        } else if !items.isEmpty {
            note += "自分の宿題は、もうタスクにあるものでした。"
        }
        if skipped > 0 { note += "宿題の前に書かれた前置きの文は、タスクにしていません。" }
        return note
    }

    /// 「自分の宿題」→ 頼まれごと帳の「やる」（仕事）。同じ日の・よく似たものは帳の add が足さない。
    /// 職場の Claude がもう選んだものなので、確かめ待ちを通さない（2026-11-09。前は確かめ待ちに入れていた）
    static func workDigestTasks(_ homework: [String], day: String, now: Date = .now) -> [TaskBook.Item] {
        // 言われた時刻は、その日の18時（今日のまとめなら今）
        let start = TaskBook.dayFormat.date(from: day) ?? now
        let said = min(start.addingTimeInterval(18 * 3600), now)
        var out: [TaskBook.Item] = []
        for line in homework {
            let h = WorkDigestParser.homework(line)
            guard !h.what.isEmpty else { continue }
            let due: Date? = h.dueText.flatMap { WorkDigestParser.dueDate($0, digestDay: day) }
            let item = TaskBook.Item(what: h.what, from: h.from, dueText: h.dueText, due: due, said: said, day: day,
                                     quote: "仕事のまとめ（\(day)）の宿題: " + line, source: .summary, state: .open,
                                     work: true, kind: h.from != nil ? .asked : nil)
            out.append(item)
        }
        return out
    }

    private static let workDigestDayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日(E)"
        return f
    }()

    /// 「11月8日(日)」
    static func workDigestDayTitle(_ day: String) -> String {
        guard let date = TaskBook.dayFormat.date(from: day) else { return day }
        return workDigestDayFormat.string(from: date)
    }

    /// 変わっていたら、ドライブの「仕事のまとめ」と同期フォルダの「仕事のまとめ.json」に写す（iPhone だけ。頼まれごと帳と同じ）
    func writeWorkDigests() async {
        guard email != nil, UIDevice.current.userInterfaceIdiom != .pad else { return }
        let entries = workDigests.sorted
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(entries) else { return }
        let latest: Double = entries.map(\.addedAt).max()?.timeIntervalSince1970 ?? 0
        let stamp = "\(entries.count)|\(latest)"
        guard UserDefaults.standard.string(forKey: Self.workDigestHashKey) != stamp else { return }
        do {
            try await writeWorkDigestFiles(Self.workDigestParagraphs(workDigests.byDay), json: json)
            UserDefaults.standard.set(stamp, forKey: Self.workDigestHashKey)
        } catch {
            diagnostics.problem("仕事のまとめをドライブに書けませんでした: \(error.localizedDescription)")
        }
    }

    /// ドライブの「仕事のまとめ」の中身（新しい日から。日の見出しの下に、取り込んだ文をそのまま）
    static func workDigestParagraphs(_ days: [(day: String, entries: [WorkDigest.Entry])],
                                     limit: Int = 200) -> [(text: String, style: String?)] {
        var p: [(text: String, style: String?)] = [
            ("仕事のまとめ", "HEADING_1"),
            ("職場の Claude の答えを、アプリに取り込んだものです。アプリが自動で書き直します（ここを直してもアプリには戻りません）。", nil),
        ]
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        var count = 0
        for group in days {
            guard count < limit else { break }
            p.append((group.day + " " + workDigestDayTitle(group.day), "HEADING_2"))
            for entry in group.entries {
                guard count < limit else { break }
                count += 1
                if group.entries.count > 1 {
                    p.append((clock.string(from: entry.addedAt) + " に取り込み（" + entry.source.label + "）", "HEADING_3"))
                }
                for line in entry.text.components(separatedBy: .newlines) where !line.isEmpty {
                    p.append((line, nil))
                }
            }
        }
        return p
    }
}

// MARK: - 探す・質問の材料にする（2026-11-10）

extension Pipeline {
    /// 仕事のまとめで見つかった1行
    struct DigestHit: Identifiable, Equatable {
        let entryID: String
        let index: Int
        let day: String
        /// 見出し（決まった形でないまとめは空）
        let heading: String
        let text: String
        var id: String { entryID + "|" + String(index) }
    }

    /// まとめを、見出しつきの行にする。決まった形でないまとめは、取り込んだ文を1行ずつ（見出しは空。【日付】の行は入れない）
    static func workDigestLines(_ entry: WorkDigest.Entry) -> [(heading: String, text: String)] {
        var out: [(heading: String, text: String)] = []
        if let sections = entry.sections, !sections.isEmpty {
            for list in sections.lists {
                for item in list.items { out.append((list.title, item)) }
            }
            return out
        }
        for raw in entry.text.components(separatedBy: .newlines) {
            let line: String = WorkDigestParser.tidy(raw)
            guard !line.isEmpty, WorkDigestParser.header(line)?.part != .date else { continue }
            out.append(("", line))
        }
        return out
    }

    /// 仕事のまとめを言葉で探す（渡した順＝新しい日から）。空白で区切った言葉は、すべてを含む行。見出しの言葉でも見つかる。
    /// 同じ日の同じ行（取り込み直したもの）は1つだけ。言語モデルは使わない
    static func searchWorkDigests(_ query: String, in entries: [WorkDigest.Entry], limit: Int = 50) -> [DigestHit] {
        let terms: [String] = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        var out: [DigestHit] = []
        var seen: Set<String> = []
        for entry in entries {
            for (n, line) in workDigestLines(entry).enumerated() {
                let hay: String = line.heading + " " + line.text
                guard terms.allSatisfy({ hay.localizedCaseInsensitiveContains($0) }) else { continue }
                guard seen.insert(entry.day + "|" + WorkDigestParser.compact(line.text)).inserted else { continue }
                out.append(DigestHit(entryID: entry.id, index: n, day: entry.day, heading: line.heading, text: line.text))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// 「記録に質問する」に渡す、仕事のまとめの抜き出し（渡した順＝新しい日から）。
    /// 手がかり（探す言葉・人）があれば、それを含む行だけ。「仕事のまとめ」と見出しの言葉も見るので、「仕事」「宿題」と聞けばその行が当たる。
    /// 期間を言わなかった質問（anyDay）なら、前の日のまとめからも探す。
    /// 手がかりが無いときは、期間を言った質問だけ、その期間のまとめをまるごと（期間も手がかりも無い質問には入れない）。
    /// days は、材料に入れたまとめの日（新しい日から・重なりなし）
    static func workDigestMaterial(_ entries: [WorkDigest.Entry], keywords: [String], people: [String],
                                   from: String, to: String, anyDay: Bool, budget: Int) -> (text: String, days: [String]) {
        let cues: [String] = (keywords + people).filter { !$0.isEmpty }
        var text = ""
        var days: [String] = []
        var seen: Set<String> = []
        for entry in entries {
            // 残りが少ないときは、見出しだけの切れはしを入れない
            guard budget - text.count >= 40 else { break }
            let inRange: Bool = entry.day >= from && entry.day <= to
            let wanted: Bool = cues.isEmpty ? (!anyDay && inRange) : (anyDay || inRange)
            guard wanted else { continue }
            var block = ""
            var heading: String? = nil
            for line in workDigestLines(entry) {
                if !cues.isEmpty {
                    let hay: String = "仕事のまとめ " + line.heading + " " + line.text
                    guard cues.contains(where: { hay.localizedCaseInsensitiveContains($0) }) else { continue }
                }
                guard seen.insert(entry.day + "|" + WorkDigestParser.compact(line.text)).inserted else { continue }
                if heading != line.heading {
                    heading = line.heading
                    if !line.heading.isEmpty { block += "【" + line.heading + "】\n" }
                }
                block += "・" + line.text + "\n"
            }
            guard !block.isEmpty else { continue }
            let piece: String = "[" + entry.day + " 仕事のまとめ]\n" + block + "\n"
            text += String(piece.prefix(budget - text.count))
            if !days.contains(entry.day) { days.append(entry.day) }
        }
        return (text, days)
    }
}

// MARK: - 退勤の頃の知らせ（2026-11-10）

/// 「今日のまとめを取り込みましたか」の知らせ。職場の行を書いた日で、その日のまとめがまだ無いときだけ、決めた時刻に1回出す。
/// まとめは職場の PC の前でしか作れないので、帰る前に気づけるようにする。中身（職場の文）は知らせに入れない。
enum WorkDigestReminder {
    static let noticeID = "work-digest-reminder"
    /// 知らせるか（設定。無ければ知らせる）
    static let onKey = "workDigest.reminder"
    /// 知らせる時刻（0時からの分。無ければ 17:30）
    static let minuteKey = "workDigest.reminderMinute"
    static let defaultMinute = 17 * 60 + 30

    /// 今日の知らせを出す時刻。出さないとき（設定がオフ・今日は職場の行が無い・もう取り込んだ・時刻を過ぎた）は nil
    static func time(now: Date, workedToday: Bool, hasDigest: Bool, on: Bool, minute: Int,
                     calendar: Calendar = .current) -> Date? {
        guard on, workedToday, !hasDigest else { return nil }
        let m = min(max(minute, 0), 24 * 60 - 1)
        guard let at = calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: now),
              at > now.addingTimeInterval(30) else { return nil }
        return at
    }

    /// 設定の時刻（0時からの分）を、今日のその時刻に
    static func date(minute: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let m = min(max(minute, 0), 24 * 60 - 1)
        return calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: now) ?? now
    }

    /// 時刻を、0時からの分に
    static func minute(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 17) * 60 + (parts.minute ?? 30)
    }
}

extension Pipeline {
    /// 退勤の頃の知らせを用意し直す（前のものを消してから。iPhone だけ）。
    /// アプリを開いたとき・その日はじめて職場の行を書いたとき・まとめを取り込んだとき・設定を変えたときに呼ぶ
    func scheduleWorkDigestReminder(now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [WorkDigestReminder.noticeID])
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let defaults = UserDefaults.standard
        let on: Bool = defaults.object(forKey: WorkDigestReminder.onKey) as? Bool ?? true
        let minute: Int = defaults.object(forKey: WorkDigestReminder.minuteKey) as? Int ?? WorkDigestReminder.defaultMinute
        let today: String = TaskBook.dayFormat.string(from: now)
        let worked: Bool = (Tally.sums(days: 1, now: now)["work.lines"] ?? 0) > 0
        let has: Bool = workDigests.entries.contains { $0.day == today }
        guard let at = WorkDigestReminder.time(now: now, workedToday: worked, hasDigest: has, on: on, minute: minute) else { return }
        let content = UNMutableNotificationContent()
        content.title = "仕事のまとめ"
        content.body = "今日のまとめを取り込みましたか。職場の Claude に聞いた答えを、写真か貼り付けで入れられます。"
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        center.add(UNNotificationRequest(identifier: WorkDigestReminder.noticeID, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// 職場の行を書いたとき（その日の1回目だけ、知らせを用意する。アプリを開かない日でも出るように）
    func workDigestReminderOnWork(at time: Date, now: Date = .now) {
        let today: String = TaskBook.dayFormat.string(from: now)
        guard workDigestReminderDay != today, TaskBook.dayFormat.string(from: time) == today else { return }
        workDigestReminderDay = today
        scheduleWorkDigestReminder(now: now)
    }
}

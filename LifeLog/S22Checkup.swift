import Foundation

/// s22（2026-11-22）の自己点検の決まり（楽1〜4。決まった入力から決まった出力だけ。docs/s22-app.md）。
/// 画面は S22Views.swift の S22CheckupTopSection。テストは LifeLogTests/S22Tests.swift。しきい値と言葉の当てはめはどれも仮。

/// 楽2 自己点検の各行の印。**A2（デザイン）が丸の信号の色付けに使う名前**（赤は self_ だけ・wait は灰色）。
enum CheckupFix: String, CaseIterable, Sendable {
    /// 自分で直せる（本人が動く。許可・入れ直す・開く・充電など）
    case self_ = "self"
    /// 待てば直る（混んでいる・回数の上限・送っている途中など）
    case wait
    /// Claude に頼む（落ちた・分からないエラーなど）
    case askClaude

    var label: String {
        switch self {
        case .self_: "自分で直せる"
        case .wait: "待てば直る"
        case .askClaude: "Claude に頼む"
        }
    }

    var symbol: String {
        switch self {
        case .self_: "hand.raised"
        case .wait: "hourglass"
        case .askClaude: "bubble.left.and.text.bubble.right"
        }
    }

    /// 並べる順（本人が動くものが先）
    var order: Int {
        switch self {
        case .self_: 0
        case .askClaude: 1
        case .wait: 2
        }
    }
}

/// 自己点検の 1 行（DiagnosticItem と最近のエラーを同じ形にしたもの）
struct CheckupRow: Equatable, Sendable {
    var section: String
    var label: String
    var value: String
    var ok: Bool?
    /// 最近のエラーの時刻（ほかの行は nil）
    var time: Date? = nil
}

enum S22Checkup {
    static let errorSection = "最近のエラー"

    // MARK: 楽2 印

    /// 行の印（言葉で当てはめる。仮）。許可の行はいつも自分で直せる
    static func fix(section: String, label: String, value: String) -> CheckupFix {
        if section == "許可" { return .self_ }
        let text = label + " " + value
        let selfWords = ["許可", "設定でオン", "入れ直す", "Sideloadly", "ログインしていない", "キーが無い", "低電力モード",
                         "一度開く", "開くと新しく", "充電", "空き容量", "オンに", "つなぎ直", "ログインが切れ", "更新して",
                         "新しくして", "時計の LifeLog を"]
        if selfWords.contains(where: { text.contains($0) }) { return .self_ }
        let raw = value.lowercased()
        let waitWords = ["しばらく", "待ち", "待って", "混ん", "送っている途中", "届くまで", "上限", "回数を", "429",
                         "resource_exhausted", "rate", "quota", "unavailable", "503", "502", "500", "timed out",
                         "タイムアウト", "時間切れ", "つながりません", "接続できません", "つながりませんでした", "offline",
                         "オフライン", "上げる前の音声", "返事待ち", "まだ送っていない"]
        if waitWords.contains(where: { text.contains($0) || raw.contains($0) }) { return .wait }
        return .askClaude
    }

    static func fix(_ row: CheckupRow) -> CheckupFix { fix(section: row.section, label: row.label, value: row.value) }

    // MARK: 楽1 いまやること 3 つ

    struct Focus: Identifiable, Equatable, Sendable {
        /// まとめた種類（同じ種類はまとめる）
        let id: String
        let title: String
        let fix: CheckupFix
        /// まとめた行の数
        let count: Int
        let latest: Date?
    }

    struct FocusList: Equatable, Sendable {
        var top: [Focus]
        /// 3 つの外に残った種類の数
        var others: Int
        /// 7 日より前なので畳んだエラーの数
        var folded: Int
    }

    /// ok でない行を、同じ種類でまとめて大事な順に limit 個。7 日より前のエラーは畳む
    static func focus(_ rows: [CheckupRow], now: Date, limit: Int = 3, foldAfter: TimeInterval = 7 * 86400) -> FocusList {
        var order: [String] = []
        var groups: [String: (title: String, fix: CheckupFix, count: Int, latest: Date?)] = [:]
        var folded = 0
        for row in rows where row.ok == false {
            if let time = row.time, now.timeIntervalSince(time) > foldAfter {
                folded += 1
                continue
            }
            let friendly = friendlyError(row.value).short
            let isError = row.section == errorSection
            let key = isError ? "e:" + friendly : "r:" + row.section + "/" + row.label
            let title = isError ? friendly : row.label + ": " + friendly
            if var g = groups[key] {
                g.count += 1
                if let t = row.time, g.latest.map({ t > $0 }) ?? true { g.latest = t }
                groups[key] = g
            } else {
                order.append(key)
                let mark: CheckupFix = isError ? Self.fix(section: row.section, label: row.label, value: row.value + " " + friendly)
                    : Self.fix(row)
                groups[key] = (title, mark, 1, row.time)
            }
        }
        let all = order.compactMap { key -> Focus? in
            guard let g = groups[key] else { return nil }
            return Focus(id: key, title: g.title, fix: g.fix, count: g.count, latest: g.latest)
        }
        let sorted = all.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.fix.order != y.fix.order { return x.fix.order < y.fix.order }
            if x.count != y.count { return x.count > y.count }
            return a.offset < b.offset
        }.map(\.element)
        return FocusList(top: Array(sorted.prefix(max(0, limit))), others: max(0, sorted.count - limit), folded: folded)
    }

    // MARK: 楽4 エラーの文をやさしく

    /// 生の文（英語・JSON）を日本語の 1 行に。元の文は detail（「詳しく」に畳む）。やさしくできなければ short は元のまま・detail は nil
    static func friendlyError(_ raw: String) -> (short: String, detail: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (text, nil) }
        let lower = text.lowercased()
        let who = service(lower)
        func has(_ code: String) -> Bool { lower.range(of: "(^|[^0-9])" + code + "([^0-9]|$)", options: .regularExpression) != nil }
        var short: String?
        if has("429") || lower.contains("resource_exhausted") || lower.contains("ratelimit") || lower.contains("rate limit")
            || lower.contains("quota") {
            short = who + "の使える回数を一時的に超えました（しばらくすると戻ります）"
        } else if has("401") || lower.contains("unauthenticated") || lower.contains("invalid_grant") || lower.contains("invalid credentials") {
            short = who + "のログインが切れました（設定からつなぎ直してください）"
        } else if has("403") || lower.contains("permission_denied") || lower.contains("forbidden") {
            short = who + "に断られました（許可が足りないかもしれません）"
        } else if has("500") || has("502") || has("503") || has("504") || lower.contains("unavailable")
                    || lower.contains("internal error") || lower.contains("backenderror") {
            short = who + "が混んでいます（待てば直ります）"
        } else if lower.contains("timed out") || has("-1001") || lower.contains("timeout") {
            short = "時間切れでした（電波の良い所で、もう一度試します）"
        } else if lower.contains("offline") || has("-1009") || lower.contains("not connected to the internet") {
            short = "ネットにつながっていませんでした"
        } else if has("-1004") || lower.contains("could not connect") {
            short = who + "につながりませんでした"
        } else if has("-1003") || lower.contains("hostname could not be found") {
            short = who + "の住所が見つかりませんでした"
        } else if text.hasPrefix("{") || text.hasPrefix("[") || mostlyEnglish(text) {
            short = who + "から英語のエラーが返りました（詳しくに元の文）"
        }
        guard let short else { return (text, nil) }
        // 日本語の前置き（「ドライブに書けませんでした: {…}」）は残す
        if let colon = text.range(of: ": "), text.distance(from: text.startIndex, to: colon.lowerBound) <= 40 {
            let head = String(text[..<colon.lowerBound])
            if !mostlyEnglish(head) && !head.hasPrefix("{") { return (head + ": " + short, text) }
        }
        return (short, text)
    }

    private static func service(_ lower: String) -> String {
        if lower.contains("google") || lower.contains("drive") || lower.contains("docs") || lower.contains("ドライブ") { return "Google " }
        if lower.contains("groq") { return "Groq " }
        if lower.contains("anthropic") || lower.contains("claude") { return "Claude " }
        if lower.contains("elevenlabs") { return "ElevenLabs " }
        if lower.contains("家の pc") || lower.contains("lifelog pc") { return "家の PC " }
        return "相手"
    }

    /// 半分より多くが英字（日本語の文でない）
    static func mostlyEnglish(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard letters.count >= 12 else { return false }
        let ascii = letters.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        return Double(ascii) / Double(letters.count) > 0.5
    }

    // MARK: 楽3 「Claude に頼む」の文（共有シートに渡すだけ。言語モデルは呼ばない）

    /// いまの様子を 1 つの文に。秘密・人名・会話の中身・場所の名前は入れない（scrub で消す）
    static func askClaudeText(_ list: FocusList, phoneBuild: Int, watchBuild: String?, names: [String]) -> String {
        var lines: [String] = []
        lines.append("LifeLog（iPhone の版 \(phoneBuild)" + (watchBuild.map { "・時計の版 \($0)" } ?? "") + "）の自己点検で、気になる所があります。")
        if list.top.isEmpty { lines.append("・（いまは気になる所はありません）") }
        for (i, item) in list.top.enumerated() {
            let times = item.count > 1 ? "（\(item.count) 回）" : ""
            lines.append("\(i + 1). [\(item.fix.label)] " + String(scrub(item.title, names: names).prefix(120)) + times)
        }
        if list.others > 0 { lines.append("ほかに \(list.others) 種類あります。") }
        if list.folded > 0 { lines.append("7 日より前のエラー \(list.folded) 個は畳みました。") }
        lines.append("直し方を、やさしい言葉で教えてください。自分で直せないものは、どのファイルを見ればよいかも教えてください。")
        lines.append("（会話の中身・人の名前・場所の名前・鍵は入れていません）")
        return lines.joined(separator: "\n")
    }

    /// 人名・場所の名前・メールアドレス・住所・長い鍵らしい文字・「」の中を消す
    static func scrub(_ text: String, names: [String]) -> String {
        var out = text
        for name in names.filter({ $0.count >= 2 }).sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: name, with: "（名前）")
        }
        let patterns: [(String, String)] = [
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "（メール）"),
            ("https?://[^\\s」）)]+", "（住所）"),
            ("[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}", "（住所）"),
            ("[A-Za-z0-9_\\-]{24,}", "（鍵らしい文字）"),
            ("「[^」]*」", "「…」"),
        ]
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }
}

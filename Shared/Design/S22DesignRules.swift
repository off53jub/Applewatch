import Foundation

// s22 のデザインの決まり（見6〜見21。2026-11-22。docs/s22-design.md）。
// 決まった入力から決まった出力になる純粋な関数だけ（色や画面は LifeLog/S22DesignKit.swift・LifeLog/DesignKit.swift）。
// テストは LifeLogTests/S22DesignTests.swift。しきい値はどれも仮（データがたまったら測り直す）。

// MARK: - 見7 直し方の印から色の意味へ

/// 自己点検の 1 行の色の意味。赤は「本人が動くもの」だけ・待てば直るものは灰色
enum LLTone: String, CaseIterable, Sendable {
    /// 良い（くすんだ緑）
    case ok
    /// 本人が動く（くすんだ赤）
    case act
    /// 待てば直る（灰色）
    case wait
    /// Claude に頼む（琥珀。外の AI に渡るもの）
    case claude
    /// 気をつけたい・直し方が分からない（琥珀）
    case warn
    /// 分からない（点線の灰色）
    case unknown

    /// 画面と読み上げの言葉
    var label: String {
        switch self {
        case .ok: "良い"
        case .act: "自分で直す"
        case .wait: "待てば直る"
        case .claude: "Claude に頼む"
        case .warn: "気をつけたい"
        case .unknown: "まだ分からない"
        }
    }

    /// 強さ（信号の丸は、中の行のいちばん強いものの色にする）
    var weight: Int {
        switch self {
        case .act: 5
        case .warn: 4
        case .claude: 3
        case .wait: 2
        case .ok: 1
        case .unknown: 0
        }
    }

    /// A1 の直し方の印（CheckupFix の名前。self_・wait・askClaude など）から色の意味を決める。
    /// 名前は文字で受ける（合流の前でも組み立てられるように）。知らない名前・nil は「気をつけたい」
    static func forFix(_ raw: String?) -> LLTone {
        guard let raw else { return .warn }
        let key = raw.lowercased().filter { $0.isLetter }
        switch key {
        case "self", "you", "me", "user", "own", "manual": return .act
        case "wait", "waiting", "auto", "later": return .wait
        case "askclaude", "claude", "ask": return .claude
        default: return .warn
        }
    }

    /// ok の値（良い・気をつけたい・どちらでもない）と直し方の印から、1 行の色の意味
    static func of(ok: Bool?, fix: String?) -> LLTone {
        switch ok {
        case true?: return .ok
        case false?: return forFix(fix)
        case nil: return .unknown
        }
    }

    /// 直し方の印がまだ無いとき（A1 の印とつなぐ前）の控えめな見立て（仮）。
    /// 許可・端末の設定は本人が動く・待ち/遅れ/届くは待てば直る。ほかは分からない（nil）
    static func guessFix(section: String, label: String) -> String? {
        if ["許可", "端末", "設定"].contains(section) { return "self_" }
        if ["待ち", "遅れ", "届く", "届いた", "送って", "残っている"].contains(where: { label.contains($0) }) { return "wait" }
        return nil
    }
}

// MARK: - 見6 自己点検を 6 つの丸の信号に

enum LLSignal: String, CaseIterable, Identifiable, Sendable {
    case device, recording, watch, homePC, latency, people
    var id: String { rawValue }

    var label: String {
        switch self {
        case .device: "端末"
        case .recording: "録音"
        case .watch: "時計"
        case .homePC: "家の PC"
        case .latency: "文字になるまで"
        case .people: "人"
        }
    }

    var symbol: String {
        switch self {
        case .device: "iphone"
        case .recording: "waveform"
        case .watch: "applewatch"
        case .homePC: "desktopcomputer"
        case .latency: "text.bubble"
        case .people: "person.2"
        }
    }

    /// 自己点検の 1 行が、どの信号に入るか（節と見出しから）。どれにも入らない行（学んだ値・精度の物差しなど）は nil
    static func of(section: String, label: String) -> LLSignal? {
        switch section {
        case "端末", "許可": return .device
        case "時計": return .watch
        case "文字になるまで", "処理": return .latency
        case "人": return .people
        case "状態":
            if label.contains("時計") { return .watch }
            if label.contains("同期") || label.contains("控え") { return .device }
            return .recording
        case "設定":
            if label.contains("家の PC") { return .homePC }
            if label.contains("マイク") || label.contains("音がしない") || label.contains("声の無い") || label.contains("待機") {
                return .recording
            }
            return .device
        default:
            if section.contains("家の PC") || section.contains("PC") { return .homePC }
            return nil
        }
    }

    /// 信号の色: 中の行のいちばん強い色の意味（行が無ければ「まだ分からない」）
    static func tone(of tones: [LLTone]) -> LLTone {
        tones.max { $0.weight < $1.weight } ?? .unknown
    }
}

// MARK: - 見8 「文字になるまで」を 1 本の横棒に

enum LatencyBarRules {
    struct Segment: Equatable, Sendable {
        let name: String
        let seconds: Double
        /// 棒の中の幅（0〜1。足すと 1）
        let fraction: Double
    }

    /// 区間の名前（録音の終わり→iPhone→PC の待ち→PC の作業→記録）
    static let names = ["時計→iPhone", "iPhone→PC", "PC の待ち", "PC の作業", "記録に入れる"]

    /// 分かる区間だけを並べる（0 秒・分からない区間は棒に出さない）。全部分からなければ空
    static func segments(_ values: [Double?]) -> [Segment] {
        let pairs = zip(names, values).compactMap { name, v -> (String, Double)? in
            guard let v, v.isFinite, v >= 0.05 else { return nil }
            return (name, v)
        }
        let total = pairs.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return pairs.map { Segment(name: $0.0, seconds: $0.1, fraction: $0.1 / total) }
    }

    /// いちばん長い区間の名前（棒で差し色にする）
    static func slowest(_ segments: [Segment]) -> String? {
        segments.max { $0.seconds < $1.seconds }?.name
    }
}

// MARK: - 見10 相づち・言い淀みを畳む

enum FillerRules {
    /// 相づち・言い淀みの言葉（長いものから当てる）
    static let words: [String] = [
        "そうですね", "そうそう", "なるほど", "えっと", "えーと", "あのー", "うーん", "ふーん", "そっか", "そうか",
        "はいはい", "うんうん", "ええ", "えー", "あの", "その", "うん", "はい", "ああ", "あー", "まあ", "まぁ",
        "なんか", "へー", "ほう", "おお", "そう", "ね", "ん", "え", "あ", "う", "お", "ま",
    ].sorted { $0.count > $1.count }

    private static let ignored: Set<Character> = ["、", "。", "，", "．", ",", ".", "・", "…", "‥", "！", "？", "!", "?",
                                                  " ", "　", "ー", "〜", "~", "っ", "ッ"]

    /// 伸ばす音・小さい「っ」・句読点を除いた形（「えっと」→「えと」。words もこの形にそろえて比べる）
    static func strip(_ text: String) -> String { text.filter { !ignored.contains($0) } }

    private static let stripped: [String] = Array(Set(words.map(strip))).filter { !$0.isEmpty }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }

    /// えー・あの・うん だけの行か（中身のある言葉が 1 つでもあれば false。12 文字より長い行は畳まない）
    static func isFiller(_ text: String) -> Bool {
        var rest = Substring(strip(text))
        guard !rest.isEmpty, text.count <= 12 else { return false }
        while !rest.isEmpty {
            guard let word = stripped.first(where: { rest.hasPrefix($0) }) else { return false }
            rest = rest.dropFirst(word.count)
        }
        return true
    }

    /// 行の並びを、畳むまとまり（続いた相づちの行）と、そのまま出す行に分ける。
    /// 返すのは [(先頭の行の番号, 行の数, 畳むか)]。1 行だけの相づちも畳む（「相づち 1 行」）
    static func groups(_ texts: [String]) -> [(start: Int, count: Int, folded: Bool)] {
        var out: [(start: Int, count: Int, folded: Bool)] = []
        for (i, t) in texts.enumerated() {
            let f = isFiller(t)
            if f, let last = out.last, last.folded, last.start + last.count == i {
                out[out.count - 1].count += 1
            } else {
                out.append((i, 1, f))
            }
        }
        return out
    }
}

// MARK: - 見11 長い会話の話題の変わり目（言葉の重なり・0 円・仮）

enum TopicRules {
    /// これより短い会話には線を引かない
    static let minLines = 12
    /// 前と後ろで比べる行の数
    static let window = 4
    /// 重なりがこれより小さく、会話の中のふつうの重なりのこれだけ倍より小さい所で線を引く（仮）
    static let absoluteBelow = 0.08
    static let relativeBelow = 0.35

    /// 中身の言葉（漢字・カタカナ・英数字の 2 文字ずつ）。ひらがなは助詞が多いので数えない
    static func grams(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var run: [Character] = []
        func flush() {
            if run.count >= 2 { for i in 0..<(run.count - 1) { out.insert(String(run[i...(i + 1)])) } }
            run = []
        }
        for c in text {
            if isContent(c) { run.append(c) } else { flush() }
        }
        flush()
        return out
    }

    private static func isContent(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        if (0x4E00...0x9FFF).contains(v) || v == 0x3005 { return true }  // 漢字・々
        if (0x30A1...0x30FA).contains(v) || v == 0x30FC { return true }  // カタカナ・ー
        return c.isASCII && (c.isLetter || c.isNumber)
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// 線を引く所（その行の前に線）。短い会話・中身の言葉が少ない会話では空
    static func breaks(_ texts: [String]) -> [Int] {
        let n = texts.count
        let w = window
        guard n >= minLines else { return [] }
        let g = texts.map(grams)
        var sims: [Int: Double] = [:]
        for i in w...(n - w) {
            let before = g[(i - w)..<i].reduce(into: Set<String>()) { $0.formUnion($1) }
            let after = g[i..<(i + w)].reduce(into: Set<String>()) { $0.formUnion($1) }
            guard before.count >= 3, after.count >= 3 else { continue }
            sims[i] = overlap(before, after)
        }
        guard sims.count >= 3 else { return [] }
        let mean = sims.values.reduce(0, +) / Double(sims.count)
        var out: [Int] = []
        for i in sims.keys.sorted() {
            guard let s = sims[i], s < absoluteBelow, s <= mean * relativeBelow else { continue }
            // 谷の底だけ（両どなりより下）
            if let l = sims[i - 1], l < s { continue }
            if let r = sims[i + 1], r < s { continue }
            if let last = out.last, i - last < 2 * w { continue }
            out.append(i)
        }
        return out
    }
}

// MARK: - 見12 読む画面の行間と 1 行の字数

enum ReadingRules {
    /// 1 行の字数の目安（日本語で 35〜40 字。仮）
    static let charsPerLine = 38.0
    /// 行間（本文の大きさに足す pt）
    static let lineSpacing = 5.0

    /// 読む欄のいちばん広い幅。iPad など広い画面（regular）だけ絞る（iPhone は nil＝画面の幅のまま）
    static func maxWidth(regular: Bool, fontSize: Double) -> Double? {
        regular ? charsPerLine * fontSize + 72 : nil  // 72 は吹き出しの余白と人の丸の分
    }
}

// MARK: - 見13 人の丸いアイコン（頭文字と色は名前から決まる。名前は変えない）

enum AvatarRules {
    /// 色の数（DesignKit の LLAvatar.palette と同じ数）
    static let paletteCount = 8

    /// 頭文字: 「人物12」は番号・英字は大文字 1 字・ほかは最初の 1 字。名前は変えない（出すだけ）
    static func initial(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("人物") {
            let digits = trimmed.dropFirst(2).prefix { $0.isNumber }
            if !digits.isEmpty { return String(digits.prefix(3)) }
        }
        guard let first = trimmed.first else { return "?" }
        return first.isASCII ? String(first).uppercased() : String(first)
    }

    /// 色の番号（名前の文字から決まる。同じ名前はいつも同じ色。FNV-1a）
    static func colorIndex(_ name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            hash ^= scalar.value
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(paletteCount))
    }
}

// MARK: - 見14 前の写し ○分前

enum CopyAgeRules {
    /// 「前の写し 12 分前」。まだ一度も読めていなければ「まだ写しがありません」
    static func text(_ at: Date?, now: Date = .now) -> String {
        guard let at else { return "まだ写しがありません" }
        let s = max(0, now.timeIntervalSince(at))
        if s < 60 { return "前の写し たったいま" }
        if s < 3600 { return "前の写し \(Int(s / 60)) 分前" }
        if s < 86400 { return "前の写し \(Int(s / 3600)) 時間前" }
        return "前の写し \(Int(s / 86400)) 日前"
    }

    /// 古い写し（半日より前）か（琥珀で出す）
    static func isStale(_ at: Date?, now: Date = .now) -> Bool {
        guard let at else { return true }
        return now.timeIntervalSince(at) > 12 * 3600
    }
}

// MARK: - 見15・見18 1 日の帯（光る所・ロック画面の小さい版）

struct BandSpan: Equatable, Hashable, Sendable {
    var start: Date
    var end: Date
}

enum BandGlow {
    /// 新しく届いた所: 前に無かった会話は全部、前からある会話は伸びた所だけ
    static func fresh(old: [BandSpan], new: [BandSpan]) -> [BandSpan] {
        var out: [BandSpan] = []
        for span in new {
            if let same = old.first(where: { abs($0.start.timeIntervalSince(span.start)) < 1 }) {
                if span.end.timeIntervalSince(same.end) >= 1 { out.append(BandSpan(start: same.end, end: span.end)) }
            } else if !old.contains(span) {
                out.append(span)
            }
        }
        return out
    }

    /// 光っている長さ（秒）
    static let seconds = 1.6
}

enum BandSlots {
    /// 1 日を 30 分ごとの 48 こまに
    static let count = 48

    /// こまの中身を 1 文字ずつ: 0 何も無い・1 録れた・2 会話（会話が先）。ウィジェットに渡す
    static func encode(talks: [BandSpan], recorded: [BandSpan], dayStart: Date) -> String {
        let step = 86400.0 / Double(count)
        var slots = [Character](repeating: "0", count: count)
        func mark(_ spans: [BandSpan], _ c: Character) {
            for s in spans {
                let a = max(0, Int(s.start.timeIntervalSince(dayStart) / step))
                let b = min(count - 1, Int(max(0, s.end.timeIntervalSince(dayStart) - 1) / step))
                guard a < count, b >= 0, a <= b else { continue }
                for i in a...b where slots[i] < c { slots[i] = c }
            }
        }
        mark(recorded, "1")
        mark(talks, "2")
        return String(slots)
    }

    /// 読む（知らない文字は 0。長さが違えば 48 にそろえる）
    static func decode(_ text: String?) -> [Int] {
        let chars = Array(text ?? "")
        return (0..<count).map { i in i < chars.count ? (Int(String(chars[i])) ?? 0) : 0 }
    }

    /// いまのこまの番号
    static func index(of date: Date, dayStart: Date) -> Int {
        min(count - 1, max(0, Int(date.timeIntervalSince(dayStart) / (86400.0 / Double(count)))))
    }
}

// MARK: - 見19 md の表を「1 行 1 カード」に

enum MarkdownBlocks {
    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)
        /// 表: 見出しの列と、行ごとの値
        case table(headers: [String], rows: [[String]])
        case rule
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            // 表（見出しの行のすぐ下に |---| の行）
            if t.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let headers = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i])
                    if row.count < headers.count { row += Array(repeating: "", count: headers.count - row.count) }
                    rows.append(Array(row.prefix(max(headers.count, 1))))
                    i += 1
                }
                out.append(.table(headers: headers, rows: rows))
                continue
            }
            if t.isEmpty {
                flush()
            } else if t.hasPrefix("#") {
                flush()
                let level = t.prefix { $0 == "#" }.count
                out.append(.heading(level: min(level, 3), text: t.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if t == "---" || t == "***" {
                flush()
                out.append(.rule)
            } else if let bullet = ["- ", "* ", "・"].first(where: { t.hasPrefix($0) }) {
                flush()
                out.append(.bullet(String(t.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(t)
            }
            i += 1
        }
        flush()
        return out
    }
}

// MARK: - 見20 朝・昼・夜で地の色をわずかに変える

enum LLDayTint {
    /// 設定の名前（初めはオン。省ける）
    static let key = "llDayTint"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    enum Part: String, Sendable { case morning, day, evening, night }

    /// 朝 5〜10 時・昼 11〜16 時・夕方 17〜19 時・夜 20〜4 時
    static func part(hour: Int) -> Part {
        switch hour {
        case 5...10: .morning
        case 11...16: .day
        case 17...19: .evening
        default: .night
        }
    }

    /// 地の色（暗い画面の基本は #0B1220・明るい画面は #F3F6FB。切っているときは基本のまま）
    static func bgHex(hour: Int, dark: Bool, enabled: Bool) -> UInt32 {
        guard enabled else { return dark ? 0x0B1220 : 0xF3F6FB }
        switch (part(hour: hour), dark) {
        case (.morning, true): return 0x0D1526
        case (.day, true): return 0x0B1220
        case (.evening, true): return 0x0F1224
        case (.night, true): return 0x080E1A
        case (.morning, false): return 0xF5F7FA
        case (.day, false): return 0xF3F6FB
        case (.evening, false): return 0xF2F3FA
        case (.night, false): return 0xEEF2F9
        }
    }
}

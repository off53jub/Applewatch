import Foundation

/// 漢数字で書かれた金額・数量・日付を、算用数字にそろえる（「千二百円」→「1200円」、「三億五千万円」→「3億5000万円」）。
/// 単位の付いた数だけを変える（「一人」「一番」「一緒」などの言葉は変えない）。仕事の数字（金額・株数・割合）を探しやすくする。
enum NumberStyle {
    private static let digits: [Character: Int] = ["〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                                   "六": 6, "七": 7, "八": 8, "九": 9]
    private static let small: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let large: [Character] = ["万", "億", "兆"]
    /// 数のあとに続けば変える単位（長いものから）
    private static let units = ["パーセント", "ポイント", "万円", "億円", "兆円", "ドル", "ユーロ", "円", "株", "銘柄", "枚",
                                "件", "社", "%", "倍", "年", "か月", "ヶ月", "月", "日", "時", "分", "秒", "歳", "回",
                                "個", "台", "本", "通", "部", "階", "番目", "位", "割", "キロ", "メートル"]

    /// 単位が続いても数ではない言い回し
    private static let idioms = ["四六時中", "五分五分", "一個人", "三日坊主", "一件落着", "一枚岩", "一分一秒",
                                 "一日一善", "一年中", "一日中", "七転八倒", "千載一遇", "百発百中"]

    static func normalize(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            // 決まった言い回し（「四六時中」「五分五分」など）はそのまま
            if let idiom = idioms.first(where: { chars[i...].starts(with: $0) }) {
                out += idiom
                i += idiom.count
                continue
            }
            // 漢数字の続き（数字・十百千・万億兆）を取る
            var j = i
            while j < chars.count, digits[chars[j]] != nil || small[chars[j]] != nil || large.contains(chars[j]) { j += 1 }
            if j > i, let unit = unitAfter(chars, j), let number = convert(Array(chars[i..<j])),
               !(i > 0 && isWordChar(chars[i - 1])), !isWord(String(chars[i..<j]), unit: unit) {
                out += number
                i = j
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// 数ではなく言葉として使うもの（「十分」「一時的」「一部」「一本化」「一通り」など）
    private static func isWord(_ number: String, unit: String) -> Bool {
        if number == "十" && unit == "分" { return true }
        return number == "一" && ["時", "部", "本", "通"].contains(unit)
    }

    private static func unitAfter(_ chars: [Character], _ j: Int) -> String? {
        let rest = String(chars[j..<min(chars.count, j + 5)])
        return units.first { rest.hasPrefix($0) }
    }

    /// 前が漢字・かなの語の途中（「統一」「同一」の「一」など）なら変えない
    private static func isWordChar(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        let v = scalar.value
        // 単位の字（「年」「円」など）のすぐあとは、続けて数が来てよい（「2026年三月」）
        if units.contains(where: { $0.last == c }) { return false }
        let kanji = (0x4E00...0x9FFF).contains(v) && digits[c] == nil && small[c] == nil && !large.contains(c)
        return kanji || (0x30A0...0x30FF).contains(v)
    }

    /// 「三億五千万」→「3億5000万」。読めなければ nil
    static func convert(_ chars: [Character]) -> String? {
        var parts: [(value: Int, scale: Character?)] = []
        var group = 0, current = -1
        var sawAny = false
        for c in chars {
            if let d = digits[c] {
                // 「二〇二六」のような並べ書きは、前の数字に続ける
                current = current >= 0 ? current * 10 + d : d
                sawAny = true
            } else if let s = small[c] {
                group += (current < 0 ? 1 : current) * s
                current = -1
                sawAny = true
            } else if large.contains(c) {
                let value = group + max(current, 0)
                guard value > 0 || sawAny else { return nil }
                parts.append((value == 0 ? 1 : value, c))
                group = 0
                current = -1
                sawAny = false
            }
        }
        let tail = group + max(current, 0)
        if sawAny { parts.append((tail, nil)) }
        guard !parts.isEmpty else { return nil }
        // 単位だけ（「万円」の「万」だけ）は変えない
        if parts.count == 1, parts[0].scale != nil, chars.count == 1 { return nil }
        return parts.map { "\($0.value)" + ($0.scale.map(String.init) ?? "") }.joined()
    }
}

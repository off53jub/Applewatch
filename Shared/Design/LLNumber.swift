import Foundation

/// 数を人が読む形にする（s22 の 見5。2026-11-22）。
/// 「12792.0 分」→「約 9 日」・「0.0 秒」は出さない・大きい数に桁区切り（12,345）。
/// 決まった入力から決まった出力になる純粋な関数だけ（テストは LifeLogTests/S22DesignTests.swift）。
/// 自己点検・様子・ふり返りの画面は、出すときにここを通す（もとの数を作る所は変えない。家の PC が読む形を崩さないため）。
enum LLNumber {
    // MARK: 長さ

    /// 秒を読める長さに。0.05 秒より短い（「0.0 秒」など）・負・数でないときは nil（出さない）
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0.05 else { return nil }
        if seconds < 1 { return "1 秒未満" }
        if seconds < 10 {
            let r = (seconds * 10).rounded() / 10
            return r == r.rounded() ? "\(Int(r)) 秒" : String(format: "%.1f 秒", r)
        }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        if total < 600 {
            let m = total / 60, s = total % 60
            return s == 0 ? "\(m) 分" : "\(m) 分 \(s) 秒"
        }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "約 \(minutes) 分" }
        if minutes < 24 * 60 {
            // 10 分きざみ（「約 3 時間 20 分」）
            let ten = Int((Double(minutes) / 10).rounded()) * 10
            if ten >= 24 * 60 { return "約 1 日" }
            let h = ten / 60, m = ten % 60
            return m == 0 ? "約 \(h) 時間" : "約 \(h) 時間 \(m) 分"
        }
        let hours = Int((seconds / 3600).rounded())
        if hours < 72 {
            let d = hours / 24, h = hours % 24
            return h == 0 ? "約 \(d) 日" : "約 \(d) 日 \(h) 時間"
        }
        return "約 \(count(Int((seconds / 86400).rounded()))) 日"
    }

    /// 分を読める長さに（「12792 分」→「約 9 日」）
    static func minutes(_ minutes: Double) -> String? { duration(minutes * 60) }

    // MARK: 数

    /// 桁区切り（12345 → 12,345）。言語の設定に左右されない
    static func count(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// 大きさ（1000 を 1 KB とする。前の「%.1f MB」と同じ数え方）
    static func bytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if bytes < 1000 { return "1 KB 未満" }
        if b < 1e6 { return "\(Int((b / 1e3).rounded())) KB" }
        if b < 1e9 { return b < 1e7 ? String(format: "%.1f MB", b / 1e6) : "\(count(Int((b / 1e6).rounded()))) MB" }
        return String(format: "%.1f GB", b / 1e9)
    }

    /// 割合（0〜1）を「81.5%」に。整数になるときは小数を付けない
    static func percent(_ ratio: Double) -> String? {
        guard ratio.isFinite else { return nil }
        let p = (ratio * 1000).rounded() / 10
        return p == p.rounded() ? "\(Int(p))%" : String(format: "%.1f%%", p)
    }

    /// 画面に出す 1 つの値: 数字だけなら桁区切り、文ならその中の読めない数を直す
    static func display(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.count <= 18, trimmed.allSatisfy(\.isASCII), let n = Int(trimmed) { return count(n) }
        return humanize(value)
    }

    // MARK: 文の中の数

    /// 単位の付いた長さ: 前が数字・小数点・「時間」「分」でない数＋秒/分（「3分の1」の分は除く）
    private static let durationPattern = try? NSRegularExpression(
        pattern: #"(?<![0-9.,間分])([0-9]+(?:\.[0-9]+)?)\s?(秒|分)(?![の0-9])"#)
    /// 桁区切りを付ける数（4 桁以上で、数を数える単位が続くもの。年・時刻・版の数は変えない）
    private static let countPattern = try? NSRegularExpression(
        pattern: #"(?<![0-9.,:/\-A-Za-z])([0-9]{4,})(?![0-9.:/\-A-Za-z])(\s?)(個|件|回|行|人|語|文字|字|杯|歩|通|枚|区切り|ファイル|KB)"#)

    /// 文の中の、人が読めない数を直す: 「12792.0 分」→「約 9 日」・「0.0 秒」→「1 秒未満」・「12345 個」→「12,345 個」。
    /// 読める数（「30 秒」「9時間40分」「13:10」「2026年」）はそのまま
    static func humanize(_ text: String) -> String {
        var out = text
        if let re = durationPattern {
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let number = ns.substring(with: m.range(at: 1))
                let unit = ns.substring(with: m.range(at: 2))
                guard let v = Double(number) else { continue }
                let seconds = unit == "分" ? v * 60 : v
                // 小数があるか、60 以上（「90 分」「600 秒」）のときだけ直す
                guard number.contains(".") || v >= 60 else { continue }
                let readable = duration(seconds) ?? "1 秒未満"
                out = (out as NSString).replacingCharacters(in: m.range, with: readable)
            }
        }
        if let re = countPattern {
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard let n = Int(ns.substring(with: m.range(at: 1))) else { continue }
                let rest = ns.substring(with: m.range(at: 2)) + ns.substring(with: m.range(at: 3))
                out = (out as NSString).replacingCharacters(in: m.range, with: count(n) + rest)
            }
        }
        return out
    }
}

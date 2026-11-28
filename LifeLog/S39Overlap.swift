import Foundation

/// s39（2026-11-29）: iPhone と iPad が同じ部屋で同時に録ったときの、同じ発言の見分け方。
/// 端末どうしの同期（ConversationLog.mergeRemote）で、相手の会話を取り込むときに、手元にもう同じ発言がある行を除く。
/// 家の PC（pc/s39overlap.py）も同じ見分け方で、端末ごとに届いた記録を 1 日にまとめる。数字はどれも仮（docs/s39-two-devices.md）。
/// 決まった入力から決まった出力だけ（テストは LifeLogTests/S39OverlapTests.swift）。
enum S39Overlap {
    /// 仮: 同じ発言とみなす時刻の差（秒）
    static let window: TimeInterval = 30
    /// 仮: 同じ発言とみなす似ている度合い（0〜1）
    static let similarityMin = 0.6
    /// 仮: 「短い方が長い方にそのまま入っている」を同じとみなす、短い方の文字数の下限
    static let containMin = 4

    struct Item: Sendable {
        let time: Date
        let text: String
    }

    /// 全角・半角と大文字・小文字をそろえ、空白・句読点・記号を除いた文字（1 文字ずつ）
    static func norm(_ text: String) -> [Unicode.Scalar] {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let scalars = Array(folded.unicodeScalars)
        return scalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                true
            default:
                false
            }
        }
    }

    private static func grams(_ s: [Unicode.Scalar]) -> [String: Int] {
        var out: [String: Int] = [:]
        guard s.count >= 2 else { return out }
        for i in 0..<(s.count - 1) {
            var gram = String.UnicodeScalarView()
            gram.append(s[i])
            gram.append(s[i + 1])
            out[String(gram), default: 0] += 1
        }
        return out
    }

    private static func contains(_ long: [Unicode.Scalar], _ short: [Unicode.Scalar]) -> Bool {
        guard !short.isEmpty, short.count <= long.count else { return false }
        for start in 0...(long.count - short.count) where long[start] == short[0] {
            if Array(long[start..<(start + short.count)]) == short { return true }
        }
        return false
    }

    /// 似ている度合い（0〜1）。正規化した文の 2 文字ずつの重なり（Dice）。短い方（containMin 文字以上）が長い方に入っていれば 1
    static func similarity(_ a: String, _ b: String) -> Double {
        similarity(norm(a), norm(b))
    }

    static func similarity(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= containMin, contains(long, short) { return 1 }
        let ga = grams(a), gb = grams(b)
        let total = ga.values.reduce(0, +) + gb.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let both = ga.reduce(0) { $0 + min($1.value, gb[$1.key] ?? 0) }
        return 2 * Double(both) / Double(total)
    }

    /// 2 行が同じ発言か（時刻が window 以内で、似ている度合いが similarityMin 以上）
    static func isSame(_ a: Item, _ b: Item) -> Bool {
        abs(a.time.timeIntervalSince(b.time)) <= window && similarity(a.text, b.text) >= similarityMin
    }

    /// remote のうち、local にもう同じ発言がある行の番号
    static func duplicates(remote: [Item], local: [Item]) -> Set<Int> {
        guard !remote.isEmpty, !local.isEmpty else { return [] }
        let sorted = local.map { (time: $0.time, norm: norm($0.text)) }.sorted { $0.time < $1.time }
        var out: Set<Int> = []
        for (i, item) in remote.enumerated() {
            let n = norm(item.text)
            guard !n.isEmpty else { continue }
            let from = item.time.addingTimeInterval(-window), to = item.time.addingTimeInterval(window)
            // window の始まりを二分探索で探す
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid].time < from { lo = mid + 1 } else { hi = mid }
            }
            var j = lo
            while j < sorted.count, sorted[j].time <= to {
                if similarity(n, sorted[j].norm) >= similarityMin {
                    out.insert(i)
                    break
                }
                j += 1
            }
        }
        return out
    }

    /// part が whole の行（時刻と文が同じ）だけでできていて、whole より少ない（重なりを除いて短くなった写し）か
    static func isTrimmedCopy(_ part: [Item], of whole: [Item]) -> Bool {
        guard part.count < whole.count else { return false }
        var pool: [String: Int] = [:]
        for item in whole { pool["\(item.time.timeIntervalSince1970)|\(item.text)", default: 0] += 1 }
        for item in part {
            let key = "\(item.time.timeIntervalSince1970)|\(item.text)"
            guard let n = pool[key], n > 0 else { return false }
            pool[key] = n - 1
        }
        return true
    }
}

/// s39: どの端末が家の PC に記録を送るか（決まった入力から決まった出力だけ）
enum S39Send {
    /// iPhone はいつも送る。iPad は「読むだけ」を切ったときだけ（既定は読むだけ＝送らない）
    static func isSender(isPad: Bool, isReader: Bool) -> Bool { !isPad || !isReader }
}

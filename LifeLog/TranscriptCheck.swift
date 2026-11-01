import Foundation

/// クラウドの文字起こし（Whisper）を、端末内の文字起こしと照らし合わせる。
///
/// Whisper は日本語と決めて渡すと、小さな雑音・寝息・外国語の動画などにも、もっともらしい日本語の文を作って書いてしまう。
/// 端末内の文字起こしはこうした文を作らない（何も出さないか、音に近い切れ端を出す）ので、
/// 同じ時間に端末内でも似た音（読み）が聞き取れていない行は、実際には話されていないとみなして捨てる。
/// 漢字とかなの違いで外れないよう、両方をローマ字の読みにしてから比べる。
enum TranscriptCheck {
    /// 行の前後これだけの端末内の文字起こしと比べる（時刻のずれを見込む）
    static let slack: TimeInterval = 5
    /// クラウドの行の読みのうち、端末内にも出てくる割合がこれ未満なら捨てる
    static let minimumAgreement = 0.25

    /// 端末内と合う行だけを残す。
    static func agreeing(_ cloud: [CloudTranscriber.Line], with local: [Transcriber.Line],
                         duration: TimeInterval) -> [CloudTranscriber.Line] {
        let ok = agrees(cloud, with: local, duration: duration)
        return cloud.indices.filter { ok[$0] }.map { cloud[$0] }
    }

    /// 行ごとに、端末内と合うか。
    static func agrees(_ cloud: [CloudTranscriber.Line], with local: [Transcriber.Line],
                       duration: TimeInterval) -> [Bool] {
        // 読みが短すぎる行（「はい」など）は比べようがないので、端末内で何か聞こえていれば残す
        agreement(cloud, with: local, duration: duration).map { $0.map { $0 >= minimumAgreement } ?? !local.isEmpty }
    }

    /// 行ごとに、読み（ローマ字の3文字の並び）のうち、同じころの端末内の聞き取りにも出てくる割合（0〜1）。
    /// 2つの聞き取りがどれだけ合っているか（確からしさの目安）に使う。読みが短すぎる行は nil。
    static func agreement(_ cloud: [CloudTranscriber.Line], with local: [Transcriber.Line],
                          duration: TimeInterval) -> [Double?] {
        let localReadings = local.map { (offset: $0.offset, grams: trigrams(reading($0.text))) }
        let all = localReadings.reduce(into: Set<String>()) { $0.formUnion($1.grams) }
        return cloud.enumerated().map { i, line in
            let grams = trigrams(reading(line.text))
            guard grams.count >= 3 else { return nil }
            var nearby = all
            if let start = line.offset {
                let end = cloud[(i + 1)...].lazy.compactMap(\.offset).first ?? duration
                nearby = localReadings
                    .filter { $0.offset >= start - slack && $0.offset <= max(start, end) + slack }
                    .reduce(into: Set<String>()) { $0.formUnion($1.grams) }
            }
            let shared = grams.filter(nearby.contains).count
            return Double(shared) / Double(grams.count)
        }
    }

    /// 行ごとに、同じ時間に端末内の聞き取りが聞き取った文（言語モデルに見比べてもらう用）。
    static func alternatives(_ lines: [CloudTranscriber.Line], with local: [Transcriber.Line],
                             duration: TimeInterval) -> [String] {
        lines.enumerated().map { i, line in
            guard let start = line.offset else { return "" }
            let end = lines[(i + 1)...].lazy.compactMap(\.offset).first ?? duration
            return local.filter { $0.offset >= start - 1 && $0.offset < max(start + 0.5, end - 0.2) }
                .map(\.text).joined()
        }
    }

    /// 2つの文の読みがどれだけ同じか（0〜1）。夜の聞き直しで、どちらが端末内の聞き取りに近いかを比べるのに使う。
    static func similarity(_ a: String, _ b: String) -> Double? {
        let x = trigrams(reading(a)), y = trigrams(reading(b))
        guard x.count >= 3, !y.isEmpty else { return nil }
        return Double(x.filter(y.contains).count) / Double(x.count)
    }

    /// 日本語の文を、ローマ字の読み（小文字の英字だけ）にする。
    static func reading(_ text: String) -> String {
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        guard let tokenizer = CFStringTokenizerCreate(nil, string, range, kCFStringTokenizerUnitWord,
                                                      Locale(identifier: "ja_JP") as CFLocale) else { return "" }
        var result = ""
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                result += latin
            } else {
                let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let piece = (text as NSString).substring(with: NSRange(location: token.location, length: token.length))
                result += piece.applyingTransform(.toLatin, reverse: false) ?? piece
            }
        }
        return String(result.lowercased().filter { $0.isASCII && $0.isLetter })
    }

    private static func trigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 3 else { return [] }
        return Set((0...(chars.count - 3)).map { String(chars[$0..<($0 + 3)]) })
    }
}

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
        let localReadings = local.map { (offset: $0.offset, grams: trigrams(reading($0.text))) }
        let all = localReadings.reduce(into: Set<String>()) { $0.formUnion($1.grams) }
        return cloud.enumerated().filter { i, line in
            let grams = trigrams(reading(line.text))
            // 読みが短すぎる行（「はい」など）は比べようがないので、端末内で何か聞こえていれば残す
            guard grams.count >= 3 else { return !local.isEmpty }
            var nearby = all
            if let start = line.offset {
                let end = cloud[(i + 1)...].lazy.compactMap(\.offset).first ?? duration
                nearby = localReadings
                    .filter { $0.offset >= start - slack && $0.offset <= max(start, end) + slack }
                    .reduce(into: Set<String>()) { $0.formUnion($1.grams) }
            }
            let shared = grams.filter(nearby.contains).count
            return Double(shared) / Double(grams.count) >= minimumAgreement
        }.map(\.element)
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

import Foundation

/// 記録の掃除。声が無いところに書かれた決まり文句、同じ短い文の連打、壊れた行、自分で決めた言葉だけの行を見つける。
/// 消した行は30日間とっておき、間違えたら戻せる。
enum Junk {
    enum Kind: String, CaseIterable, Codable, Identifiable {
        case filler, streak, broken, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .filler: "決まり文句"
            case .streak: "同じ文の連打"
            case .broken: "壊れた行"
            case .custom: "自分で足した言葉"
            }
        }

        var detail: String {
            switch self {
            case .filler: "「ご清聴ありがとうございました」「チャンネル登録」など、声の無いところに書かれがちな文"
            case .streak: "同じ短い文が3回以上続いたところ（区切りをまたいでも数えます）"
            case .broken: "「3行目の直した文」など、誤変換直しの不具合で残った行"
            case .custom: "下の「消したい言葉」だけの行"
            }
        }
    }

    struct Candidate: Identifiable {
        let id = UUID()
        let day: String
        let line: ConversationLog.Line
        let kind: Kind
        /// 前後の行（確かめる用）
        let before: String?
        let after: String?
    }

    /// 消した行（30日間とっておく）
    struct TrashItem: Codable, Identifiable {
        var id = UUID()
        let day: String
        let line: ConversationLog.Line
        let kind: Kind
        let removed: Date
    }

    /// 連打とみなす回数と、文の長さ（記号を除く）。「はい」「うん」のような短い相づちは数えない。
    static let streakCount = 3
    static let streakLength = 5...40
    /// 連打のあいだに挟まってよい別の行の数と、間の時間
    static let streakSkip = 1
    static let streakGap: TimeInterval = 300

    /// 比べるときは、空白と句読点・記号を除く
    static func normalized(_ text: String) -> String {
        let drop = Set(" 　。、，．,.!！?？…・「」『』()（）~〜♪\"'")
        return String(text.filter { !drop.contains($0) })
    }

    private static let brokenPattern = try! NSRegularExpression(pattern: #"\d+\s*行目の直し"#)

    static func isBroken(_ text: String) -> Bool {
        brokenPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 1行だけで分かる種類（連打以外）
    static func kind(of text: String, custom: Set<String>) -> Kind? {
        if isBroken(text) { return .broken }
        if CloudTranscriber.isFiller(text) { return .filler }
        let key = normalized(text)
        if !key.isEmpty && custom.contains(key) { return .custom }
        return nil
    }

    /// 時刻順の行のうち、連打に当たる行の番号。
    static func streaks(_ lines: [ConversationLog.Line]) -> Set<Int> {
        var result = Set<Int>()
        // 同じ文ごとに、出てきた位置を集める
        var positions: [String: [Int]] = [:]
        for (i, line) in lines.enumerated() {
            let key = normalized(line.text)
            guard streakLength.contains(key.count) else { continue }
            positions[key, default: []].append(i)
        }
        for list in positions.values where list.count >= streakCount {
            // 近くに続いて出てくるものを1つの連なりにまとめる
            var run = [list[0]]
            func flush() { if run.count >= streakCount { result.formUnion(run) } }
            for i in list.dropFirst() {
                let previous = run[run.count - 1]
                if i - previous <= streakSkip + 1,
                   lines[i].time.timeIntervalSince(lines[previous].time) <= streakGap {
                    run.append(i)
                } else {
                    flush()
                    run = [i]
                }
            }
            flush()
        }
        return result
    }

    static func key(_ line: ConversationLog.Line) -> String {
        "\(line.time.timeIntervalSince1970)|\(line.text)"
    }
}

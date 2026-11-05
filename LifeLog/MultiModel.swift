import Foundation
import UIKit

/// 複数のモデルで決める（2026-11-06）。文字起こしの多数決（家の PC）と同じ考えを、ほかにも広げる。
/// - 言語モデルのセカンドオピニオン: Groq で作ったものを、iPhone の中の言語モデルでも作って見比べる
///   （頼まれごと・議事録・誤変換の直し）。片方だけが言ったものは「要確認」に回す。
///   iPhone の中の言語モデルは電池を使うので、充電中かアプリを開いているときだけ。
/// - 割れやすい言葉: 多数決でモデルが何度も割れる言葉を、言葉の登録の候補にする。
/// - 確からしさの束ね: 多数決の合い方・騒がしさ・こすれなどを、答え合わせで学んだ重みで1つにまとめる。
enum MultiModel {
    /// セカンドオピニオンを取ってよいか（iPhone の中の言語モデルが使え、充電中かアプリを開いている）
    @MainActor
    static var secondOpinionOK: Bool {
        guard LocalModel.isUsable, UserDefaults.standard.object(forKey: "secondOpinion") as? Bool ?? true else { return false }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let charging = [.charging, .full].contains(UIDevice.current.batteryState)
        return charging || UIApplication.shared.applicationState == .active
    }

    /// 2つの文の近さ（2文字ずつの組の重なり。0〜1）。空白と句読点は除く
    static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> Set<String> {
            let chars = Array(s.filter { !$0.isWhitespace && !$0.isPunctuation })
            guard chars.count >= 2 else { return Set(chars.map(String.init)) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let x = grams(a), y = grams(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// list の中に、text と同じことを言っているもの（近さ 0.35 以上）があるか
    static func agrees(_ text: String, with list: [String], limit: Double = 0.35) -> Bool {
        list.contains { similarity(text, $0) >= limit }
    }

    /// 片方のモデルだけが言ったものに付ける印
    static let unsureMark = "（要確認：片方のモデルだけ）"
}

// MARK: - 割れやすい言葉

/// 多数決でモデルが割れた言葉の組（「田中」と「たなか」など）を数え、何日も割れるものを登録の候補にする。
/// 中身は UserDefaults の splitWords（言葉の組 → 出た日の一覧）。登録は本人が押したときだけ。
enum SplitWords {
    struct Pair: Identifiable, Equatable {
        /// 多数決で選ばれた書き方と、ほかのモデルの書き方
        let chosen: String
        let other: String
        let days: Int
        var id: String { chosen + "|" + other }
    }

    private static let key = "splitWords"
    private static let dismissedKey = "splitWordsDismissed"
    /// 何日割れたら候補にするか
    static let needDays = 3

    /// モデルごとの文から、選ばれた文とほかの文で違う所を、前後の漢字・カタカナ・英数字まで広げて取り出す（2〜12文字）。
    /// 例: 「今日は齋藤さんと会議」と「今日は斉藤さんと会議」→（齋藤, 斉藤）
    static func pairs(chosen: String, votes: [String: String]) -> [(chosen: String, other: String)] {
        func isWordChar(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { s in
                (0x4E00...0x9FFF).contains(s.value) || (0x30A0...0x30FF).contains(s.value) || s.value == 0x3005
                    || CharacterSet.alphanumerics.contains(s) && s.value < 0x3000
            }
        }
        var result: [(chosen: String, other: String)] = []
        let a = Array(chosen)
        for other in Set(votes.values) where !other.isEmpty && other != chosen {
            let b = Array(other)
            var prefix = 0
            while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
            // 言葉の切れ目まで広げる（両方の文で同じだけ）
            while prefix > 0, isWordChar(a[prefix - 1]) { prefix -= 1 }
            while suffix > 0, isWordChar(a[a.count - suffix]) { suffix -= 1 }
            let x = String(a[prefix..<(a.count - suffix)]), y = String(b[prefix..<(b.count - suffix)])
            guard (2...12).contains(x.count), (1...12).contains(y.count), x != y,
                  x.allSatisfy(isWordChar), !result.contains(where: { $0.chosen == x && $0.other == y }) else { continue }
            result.append((x, y))
        }
        return result
    }

    /// その日の、食い違った行（モデルごとの文が残っている行）を数える
    static func count(day: String, lines: [ConversationLog.Line]) {
        var store = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        for line in lines {
            guard let votes = line.votes else { continue }
            for pair in pairs(chosen: line.text, votes: votes) {
                let id = pair.chosen + "|" + pair.other
                var days = store[id] ?? []
                if !days.contains(day) { days.append(day) }
                store[id] = Array(days.suffix(30))
            }
        }
        // 多くなりすぎたら、1日しか出ていない組を捨てる
        if store.count > 2000 { store = store.filter { $0.value.count > 1 } }
        UserDefaults.standard.set(store, forKey: key)
    }

    /// 登録の候補（何日も割れた組。まだ見ていないもの。日数の多い順）
    static func candidates(known: Set<String>) -> [Pair] {
        let store = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        return store.compactMap { id, days -> Pair? in
            let parts = id.components(separatedBy: "|")
            guard parts.count == 2, days.count >= needDays, !dismissed.contains(id),
                  !known.contains(parts[0]), !known.contains(parts[1]) else { return nil }
            return Pair(chosen: parts[0], other: parts[1], days: days.count)
        }.sorted { $0.days > $1.days }
    }

    static func dismiss(_ pair: Pair) {
        var list = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        list.append(pair.id)
        UserDefaults.standard.set(Array(list.suffix(500)), forKey: dismissedKey)
    }
}

// MARK: - 確からしさを束ねる

/// 行の手がかり（多数決の合い方・騒がしさ・こすれ・モデルが割れたか・文の長さ）から「文字が違っている見込み」を出す。
/// 重みは答え合わせ（文字を答えた問い）で学ぶ（ロジスティック回帰）。30問たまるまでは使わない。
enum Calibration {
    static let key = "calibrationWeights"

    /// 手がかり（頭は定数項の 1）
    static func features(confidence: Double?, noisy: Bool, rubbed: Bool, split: Bool, length: Int) -> [Double] {
        [1, confidence ?? 0.8, noisy ? 1 : 0, rubbed ? 1 : 0, split ? 1 : 0, min(Double(length), 60) / 60]
    }

    static func probability(_ x: [Double], weights: [Double]) -> Double {
        let z = zip(x, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return 1 / (1 + exp(-z))
    }

    /// 学ぶ（勾配を下る。少ないデータで暴れないよう、重みを小さく保つ）
    static func train(_ data: [(x: [Double], wrong: Bool)], steps: Int = 800, rate: Double = 0.5) -> [Double]? {
        guard data.count >= 30, data.contains(where: \.wrong), data.contains(where: { !$0.wrong }) else { return nil }
        var w = [Double](repeating: 0, count: data[0].x.count)
        for _ in 0..<steps {
            var grad = [Double](repeating: 0, count: w.count)
            for (x, wrong) in data {
                let err = probability(x, weights: w) - (wrong ? 1 : 0)
                for i in w.indices { grad[i] += err * x[i] }
            }
            for i in w.indices { w[i] -= rate * (grad[i] / Double(data.count) + 0.01 * w[i]) }
        }
        return w
    }

    /// 学んだ重み（読み込んだものを覚えておく。行を出すたびに読まないように）
    nonisolated(unsafe) private static var cache: [Double]?? = nil
    static var weights: [Double]? {
        if let cache { return cache }
        let loaded = UserDefaults.standard.array(forKey: key) as? [Double]
        cache = .some(loaded)
        return loaded
    }

    static func save(_ weights: [Double]) {
        UserDefaults.standard.set(weights, forKey: key)
        cache = .some(weights)
    }

    /// 学んだ重みがあれば、その行の文字が違っている見込み（0〜1）
    static func wrongChance(_ line: ConversationLog.Line) -> Double? {
        guard let w = weights else { return nil }
        let x = features(confidence: line.confidence, noisy: line.noisy == true, rubbed: line.rubbed == true,
                         split: line.votes != nil, length: line.text.count)
        guard x.count == w.count else { return nil }
        return probability(x, weights: w)
    }
}

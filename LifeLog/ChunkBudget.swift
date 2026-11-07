import Foundation

/// 区切りごとに使うクラウドの回数を、区切りを短くした分だけ増やしすぎない（2026-11-07。docs/v8-latency.md の 4）。
///
/// 区切りを短く（長くても2分）すると、区切りの数が4倍ほどになる。区切りごとに1回呼ぶもの
/// （食い違った行のクラウドの票・騒がしい所の補い＝Groq の Whisper、誤変換の直し＝言語モデル）は、
/// 回数の上限（1日・1分あたりの回数）や、頼むたびに付く決まった分の文字（指示の文）がそのまま増える。
/// そこで短めの区切りのあいだは、1時間に使う回数に上限を置く（ふつうの区切りでは上限なし＝今までどおり）。
/// 上限を超えた区切りは、そのクラウドを使わずに進める（誤変換の直しは、夜の聞き直しで確からしさの低い行をもう一度直す）。
/// 数えるのはアプリが動いているあいだだけ（入れ直したら数え直す）。
@MainActor
enum ChunkBudget {
    enum Kind: String {
        /// クラウドの Whisper（食い違った行の票・騒がしい所の補い）
        case cloud
        /// 誤変換の直し（言語モデル）
        case correct
    }

    /// 1時間に使う回数の上限（nil は上限なし）。5分の区切りなら多くても1時間に十数回なので、その2倍ほど
    static func perHour(_ kind: Kind, length: ChunkCutter.Length = ChunkCutter.length) -> Int? {
        switch length {
        case .normal: return nil
        case .short: return 30
        }
    }

    private static var used: [Kind: [Date]] = [:]

    /// 1回使ってよいか。よければ数に入れて true（上限で見送ったら、効き目の数に残す）
    static func take(_ kind: Kind, now: Date = .now) -> Bool {
        let recent = (used[kind] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard allowed(recentCount: recent.count, limit: perHour(kind)) else {
            used[kind] = recent
            Tally.add("budget." + kind.rawValue)
            return false
        }
        used[kind] = recent + [now]
        return true
    }

    nonisolated static func allowed(recentCount: Int, limit: Int?) -> Bool {
        guard let limit else { return true }
        return recentCount < limit
    }
}

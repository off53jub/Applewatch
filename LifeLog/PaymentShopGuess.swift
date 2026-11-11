import Foundation

/// 店名の無い「ウォレットでかざした記録」に、場所からの推測を添える（2026-11-12）。
/// 見せるだけ。推測を支払いの記録（payments.json・taps）には書かない。
extension PaymentMatch {
    /// かざした時刻の前後に、立ち寄りの時間を広げて見る長さ（10分）
    static let guessWindow: TimeInterval = 10 * 60

    /// 店名の無いかざした記録か（かざした記録で、店名が空・「加盟店」のような大まかな名前）
    static func needsPlaceGuess(_ p: Payment) -> Bool {
        p.source == Payment.tap && !p.hasShop
    }

    /// その時刻の前後10分に、本人がいたお店の名前（決めた名前、無ければ推測の名前）。
    /// 立ち寄りの時間（着いた〜出た。まだいるなら今まで）と、時刻の前後10分が重なるものから、
    /// いちばん時刻が近いものを選ぶ。「お店ではない」にしたもの・名前の無いものは使わない。
    static func placeGuess(at time: Date, visits: [ShopVisit]) -> String? {
        let from = time.addingTimeInterval(-guessWindow)
        let to = time.addingTimeInterval(guessWindow)
        var best: (name: String, gap: TimeInterval, confirmed: Bool)?
        for v in visits where v.state != .notShop {
            let name: String?
            switch v.state {
            case .confirmed: name = v.confirmedName
            case .guessed: name = v.guess?.name
            case .waiting, .notShop: name = nil
            }
            guard let shop = name?.trimmingCharacters(in: .whitespacesAndNewlines), !shop.isEmpty else { continue }
            let end = v.departure ?? .distantFuture
            guard v.arrival <= to, end >= from else { continue }
            // 時刻が立ち寄りの中なら 0、外なら近いほうの端までの秒
            let gap: TimeInterval = time < v.arrival ? v.arrival.timeIntervalSince(time)
                : time > end ? time.timeIntervalSince(end) : 0
            let confirmed = v.state == .confirmed
            if let b = best {
                if gap < b.gap || (gap == b.gap && confirmed && !b.confirmed) { best = (shop, gap, confirmed) }
            } else {
                best = (shop, gap, confirmed)
            }
        }
        return best?.name
    }

    /// 画面に出す「たぶん◯◯（場所から）」。店名の無いかざした記録で、推測できたときだけ
    static func placeGuessLabel(for p: Payment, visits: [ShopVisit]) -> String? {
        guard needsPlaceGuess(p), let name = placeGuess(at: p.time, visits: visits) else { return nil }
        return "たぶん" + name + "（場所から）"
    }
}

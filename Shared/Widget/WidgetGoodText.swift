import Foundation

/// いいこと帳のウィジェットに出す短い文（2026-11-12）。数は記録にあったものを数えただけで、言葉は添えない。
extension WidgetText {
    /// 今週のお礼とほめ言葉の数。分からなければ「—」
    static func goodWeek(_ state: WidgetState?) -> (thanks: String, praise: String) {
        (state?.goodThanks.map { String($0) } ?? unknown, state?.goodPraise.map { String($0) } ?? unknown)
    }

    /// 1行（「お礼 3・ほめ言葉 2」）
    static func goodWeekLine(_ state: WidgetState?) -> String {
        let week = goodWeek(state)
        return "お礼 \(week.thanks)・ほめ言葉 \(week.praise)"
    }
}

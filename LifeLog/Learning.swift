import Foundation

/// 直した記録から、勘で決めた値を学ぶ（2026-11-06）。
/// どれも、十分にたまるまでは今の値のまま。1回に動かす量と、全体で動かせる幅に上限がある。

/// 話者の聞き分けの「近さの線」を、本人の手直しから少しずつ合わせる。
/// - 名前のある人（自分も）に付いていた行を、別の人に直した → 別の人を同じ人にしすぎ（線を厳しく）
/// - 「人物N」や話者なしの行を、名前のある人に直した → 分かるはずの人を逃している（線をゆるく）
enum SpeakerTuning {
    struct Fix: Codable, Equatable {
        let at: Date
        /// 直す前に付いていたのが、名前のある人だったか
        let wasNamed: Bool
        /// 直した先が、名前のある人か
        let toNamed: Bool
    }

    private static let logKey = "speakerFixLog"
    static let shiftKey = "speakerAcceptShift"
    /// 1回に動かす量と、動かせる幅
    static let step = 0.01, limit = 0.04
    /// 学び始めるのに要る直しの数（直近30日）
    static let need = 10

    /// いまのずらし量（足すとゆるく、引くと厳しく）
    static var shift: Float { Float(UserDefaults.standard.double(forKey: shiftKey)) }

    static var fixes: [Fix] {
        guard let data = UserDefaults.standard.data(forKey: logKey) else { return [] }
        return (try? JSONDecoder().decode([Fix].self, from: data)) ?? []
    }

    static func record(wasNamed: Bool, toNamed: Bool, at date: Date = .now) {
        // 人物N どうしの付け替えは、線の良し悪しが分からないので数えない
        guard wasNamed || toNamed else { return }
        let list = Array((fixes + [Fix(at: date, wasNamed: wasNamed, toNamed: toNamed)]).suffix(300))
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: logKey) }
    }

    /// 次のずらし量（直近30日の直しで、片方に3割以上偏っていたら 0.01 だけ動かす）
    static func nextShift(current: Double, fixes: [Fix], now: Date = .now) -> Double {
        let recent = fixes.filter { now.timeIntervalSince($0.at) < 30 * 86400 }
        let wrong = recent.filter(\.wasNamed).count
        let missed = recent.filter { !$0.wasNamed && $0.toNamed }.count
        let total = wrong + missed
        guard total >= need else { return current }
        let lean = Double(missed - wrong) / Double(total)
        var next = current
        if lean > 0.3 { next += step } else if lean < -0.3 { next -= step }
        return (min(limit, max(-limit, next)) * 100).rounded() / 100
    }

    /// 学ぶ。変えたら true（同じ日には1回だけ）
    @discardableResult
    static func tune(now: Date = .now) -> Bool {
        let dayKey = "speakerTunedDay"
        let today = String(Int(now.timeIntervalSince1970 / 86400))
        guard UserDefaults.standard.string(forKey: dayKey) != today else { return false }
        UserDefaults.standard.set(today, forKey: dayKey)
        let current = UserDefaults.standard.double(forKey: shiftKey)
        let next = nextShift(current: current, fixes: fixes, now: now)
        guard next != current else { return false }
        UserDefaults.standard.set(next, forKey: shiftKey)
        return true
    }
}

/// 頼まれごとの候補を、本人の採用・却下から学ぶ（30件から）。確かめ待ちの並びを「採りそうな順」にする。
/// 消したり隠したりはしない（並べ替えだけ）。
enum TaskLearning {
    private static let key = "taskWeights"

    static func features(_ item: TaskBook.Item) -> [Double] {
        [1,
         item.agreed == true ? 1 : 0,
         item.agreed == false ? 1 : 0,
         item.work == true ? 1 : 0,
         item.due != nil || item.dueText != nil ? 1 : 0,
         item.from != nil ? 1 : 0,
         item.source == .conversation ? 1 : 0,
         min(Double((item.quote ?? "").count), 120) / 60]
    }

    /// 学ぶ材料（確かめ待ちから、本人が採った・却下したもの）
    static func examples(_ items: [TaskBook.Item]) -> [(x: [Double], wrong: Bool)] {
        items.filter { $0.fromCandidate == true && $0.state != .candidate }
            .map { (x: features($0), wrong: $0.state == .rejected) }
    }

    static var weights: [Double]? {
        guard let w = UserDefaults.standard.array(forKey: key) as? [Double], w.count == features(.blank).count else { return nil }
        return w
    }

    /// 学ぶ。学べたら true
    @discardableResult
    static func train(_ items: [TaskBook.Item]) -> Bool {
        guard let w = Calibration.train(examples(items)) else { return false }
        UserDefaults.standard.set(w, forKey: key)
        return true
    }

    /// 採りそうな見込み（0〜1）。学ぶ前は nil
    static func acceptChance(_ item: TaskBook.Item, weights: [Double]? = TaskLearning.weights) -> Double? {
        guard let weights else { return nil }
        return 1 - Calibration.probability(features(item), weights: weights)
    }
}

extension TaskBook.Item {
    /// 学ぶ材料の長さを決めるための空の候補
    static var blank: TaskBook.Item {
        TaskBook.Item(what: "", said: .distantPast, source: .manual, state: .candidate)
    }
}

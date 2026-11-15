import Foundation

/// 名前の無い「人物N」を、押さなくても自動でまとめる（2026-11-16。強化案 71）。
/// 家の PC の「別の日にまたがる組」（voices.py。声の特徴の日の平均を引いた近さ）のうち、点の高いものだけ。
/// - なぜ: 人物N は 1 日に 91〜206 人増え、「同じ人かも」を押した数は 0。押す前提では片づかない。
///   日をまたぐ組は、名前のある人と自分を区切りごとに分けた仮の人物N で測ると 0.98〜1.00 が同じ人だった（docs/s7-voices-2026-11-15.md）。
/// - まとめるのは、組の全員が、いまも名前が無く・自分でなく・記録に出さない人でなく・登録や手直しで覚えた声も無い人だけ。
///   名前のある人には触らない・名前は付けない。会話ごとの自動のまとめ（consolidateSpeakers）と同じ mergePerson(automatic: true)
///   なので、merges.json に残り、まとめた先の人の画面から戻せる（「自動でまとめた」と出る）。
/// - 1 回に perPass 組まで・every に 1 回まで。設定の「同じ人かも」の切り替えで止められる（初めはオン）。
enum SamePersonAuto {
    /// 自動でまとめる点の下限（PC の組の下限 0.65 より高く）
    static let minScore = 0.70
    static let perPass = 5
    static let every: TimeInterval = 60 * 60
    static let onKey = "samePersonAutoMerge"
    static let lastKey = "samePersonAutoMergedAt"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: onKey) }
    }

    /// 自動でまとめてよい組（点の高い順に limit まで）。eligible は、まとめてよい人の番号
    /// （名前が無い・自分でない・記録に出さない人でない・覚えた声が無い）
    static func candidates(_ groups: [SamePersonGroup], answered: Set<String>, eligible: Set<String>,
                           limit: Int = perPass) -> [SamePersonGroup] {
        var out: [SamePersonGroup] = []
        for g in SamePersonRules.visible(groups, answered: answered, unnamed: eligible) {
            guard (g.days?.count ?? 0) >= 2, g.score >= minScore else { continue }
            out.append(g)
            if out.count >= limit { break }
        }
        return out
    }

    /// 前に回してから every たったか
    static func due(last: Date?, now: Date = .now) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= every
    }
}

extension Pipeline {
    /// 自動でまとめてよい人の番号（名前が無い・自分でない・記録に出さない人でない・登録や手直しで覚えた声が無い）
    var autoMergeableVoiceIDs: Set<String> {
        Set(people.filter { !$0.isNamed && !$0.isSelf && $0.hidden != true && $0.pinnedCount == 0 }.map(\.id))
    }

    /// 家の PC の日をまたぐ組のうち、点の高いものを自動でまとめる。まとめた組の数を返す
    @discardableResult
    func autoMergeSamePerson(now: Date = .now) async -> Int {
        guard SamePersonAuto.isOn, speakerLabelsOn, homePC.shouldTry,
              SamePersonAuto.due(last: UserDefaults.standard.object(forKey: SamePersonAuto.lastKey) as? Date, now: now)
        else { return 0 }
        UserDefaults.standard.set(now, forKey: SamePersonAuto.lastKey)
        let book = SamePersonBook.shared
        await book.refresh(homePC)
        let list = SamePersonAuto.candidates(book.groups, answered: book.answered, eligible: autoMergeableVoiceIDs)
        var merged = 0
        for group in list {
            // まとめる直前にも確かめ直す（前の組をまとめているあいだに、名前が付いたり消えたりすることがある）
            let eligible = autoMergeableVoiceIDs
            guard group.people.allSatisfy({ eligible.contains($0.id) }) else { continue }
            let plan = SamePersonRules.mergePlan(group)
            guard !plan.target.isEmpty, !plan.sources.isEmpty else { continue }
            for source in plan.sources {
                await mergePerson(source, into: plan.target, automatic: true)
            }
            book.markAnswered(group.id)
            Tally.add("sameperson.auto")
            merged += 1
        }
        return merged
    }
}

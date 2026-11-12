import Foundation

/// 会う前のおさらいの足し（2026-11-12）。
/// - 知らせる時刻を設定にした（初めは予定の30分前。前は10分前で、読む時間が足りなかった）。
/// - 会う人ごとに、残っている頼まれごと・約束・返事待ちと、最近話した話題（直近3つの会話の見出し）を足した。
/// 知らせの本文は長いと切れるので、1人ぶんを短く保つ。
extension Pipeline {
    static let meetingBriefLeadKey = "meetingBriefLeadMinutes"
    static let meetingBriefLeadDefault = 30
    /// 選べる分
    static let meetingBriefLeadChoices = [10, 15, 30, 45, 60]

    /// 予定のこれだけ前（分）に知らせる
    static var meetingBriefLeadMinutes: Int {
        let saved = UserDefaults.standard.object(forKey: meetingBriefLeadKey) as? Int ?? meetingBriefLeadDefault
        return meetingBriefLeadChoices.contains(saved) ? saved : meetingBriefLeadDefault
    }

    /// 長い文を切る（末尾に「…」）
    static func briefClip(_ text: String, _ limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }

    /// その人との、残っている頼まれごと・約束・返事待ちの行（無ければ空）。
    /// 頼まれごと = その人が頼んだ、まだのもの。待ち = その人に頼んだもの・約束・「待ち」にしたもの、
    /// 母艦のやることで「その人の返事を待っている」（waiting_for）もの。
    static func promiseLines(name: String, tasks: [TaskBook.Item], home: [MothershipTodo], perLine: Int = 2) -> [String] {
        let theirs = tasks.filter { $0.state == .open && $0.from.map { sameName($0, name) } == true }
        let asked = theirs.filter { !$0.isWaiting && $0.kindOrDefault != .promise }
        var waiting = theirs.filter { $0.isWaiting || $0.kindOrDefault == .promise }.map(\.what)
        waiting += home.filter { $0.waitingFor.map { sameName($0, name) } == true }.map(\.text)
        var seen = Set<String>()
        waiting = waiting.filter { seen.insert(TaskBook.key($0)).inserted }
        var lines: [String] = []
        if !asked.isEmpty {
            lines.append("頼まれごと \(asked.count) 件: " + asked.prefix(perLine).map { briefClip($0.what, 18) }.joined(separator: "・"))
        }
        if !waiting.isEmpty {
            lines.append("約束・返事待ち \(waiting.count) 件: " + waiting.prefix(perLine).map { briefClip($0, 18) }.joined(separator: "・"))
        }
        return lines
    }

    /// 最近話した話題の行。見出しが空のものは飛ばし、同じ見出しは1回だけ。新しい順に3つまで
    static func topicsLine(titles: [String?], limit: Int = 3) -> String? {
        var seen = Set<String>()
        let shown = titles.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(limit)
            .map { briefClip($0, 18) }
        return shown.isEmpty ? nil : "最近の話題: " + shown.joined(separator: "／")
    }
}

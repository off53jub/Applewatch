import SwiftUI

/// 効いているかを数で見る（2026-11-10）。
/// 頼まれごとの入り口ごとの「入れた・違う・確かめ待ち」と「違う」の理由、知らせを出した数・開いた数、
/// 「記録に質問する」の答えの「役に立った・外れ」を、1つの画面に出す。どれも端末の中の数だけで、どこにも送らない。
enum TaskScore {
    struct Row: Identifiable, Equatable {
        var title: String
        var total = 0
        /// まだ・済み（はじめから帳に入ったもの・確かめ待ちから入れたもの）
        var kept = 0
        var rejected = 0
        /// 確かめ待ちのまま
        var waiting = 0
        /// 「違う」の理由（RejectReason の名前 → 数。前の記録の理由なしは "none"）
        var reasons: [String: Int] = [:]

        var id: String { title }

        /// 決着の付いたもののうち、残した割合（0〜100。決着が1つも無ければ nil）
        var keptPercent: Int? {
            let n = kept + rejected
            guard n > 0 else { return nil }
            return Int((Double(kept) / Double(n) * 100).rounded())
        }
    }

    /// 入り口の並び（この順に出す。知らないものは後ろ）
    static let order: [String] = ["会話から", "★から", "議事録から", "写真から", "1日のまとめから",
                                  "仕事のまとめから（チャットで来た頼み）", "手で書いた"]

    /// 入り口ごとに数える。since より前に拾ったものは数えない（nil なら全部）
    static func rows(_ items: [TaskBook.Item], since: Date? = nil) -> [Row] {
        var map: [String: Row] = [:]
        for item in items {
            if let since, item.said < since { continue }
            let title: String = item.originLabel
            var row: Row = map[title] ?? Row(title: title)
            row.total += 1
            switch item.state {
            case .open, .done:
                row.kept += 1
            case .rejected:
                row.rejected += 1
                row.reasons[item.rejectReason ?? "none", default: 0] += 1
            case .candidate:
                row.waiting += 1
            }
            map[title] = row
        }
        return map.values.sorted { a, b in
            let x: Int = order.firstIndex(of: a.title) ?? order.count
            let y: Int = order.firstIndex(of: b.title) ?? order.count
            return x != y ? x < y : a.title < b.title
        }
    }

    static func reasonLabel(_ raw: String) -> String {
        TaskBook.RejectReason(rawValue: raw)?.label ?? "理由なし（前のもの）"
    }

    /// 「機械に言ったこと 3・もう済んでいる 1」（多い順）
    static func reasonText(_ reasons: [String: Int]) -> String {
        reasons.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { reasonLabel($0.key) + " \($0.value)" }
            .joined(separator: "・")
    }
}

struct TaskScoreView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var recent = true

    var body: some View {
        let since: Date? = recent ? Date.now.addingTimeInterval(-30 * 86400) : nil
        let rows: [TaskScore.Row] = TaskScore.rows(pipeline.tasks.items, since: since)
        let answers = AskFeedback.counts
        List {
            Section {
                Picker("期間", selection: $recent) {
                    Text("30日").tag(true)
                    Text("全部").tag(false)
                }
                .pickerStyle(.segmented)
            }
            Section {
                if rows.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.title)
                            Spacer()
                            if let p = row.keptPercent {
                                Text("残した \(p)%").foregroundStyle(p < 30 ? Color.red : Color.secondary)
                            }
                        }
                        Text("全部 \(row.total)・入れた/済み \(row.kept)・違う \(row.rejected)・確かめ待ち \(row.waiting)")
                            .font(.caption).foregroundStyle(.secondary)
                        if !row.reasons.isEmpty {
                            Text("違う: " + TaskScore.reasonText(row.reasons)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("頼まれごとの入り口ごと")
            } footer: {
                Text("「残した」は、決着の付いたもの（入れた・済み・違う）のうち、帳に残したものの割合です。低い入り口は、拾い方を直すか止める目安になります。「7日そのまま（自動）」は本人が決めたものではないので、拾い方の学びには使っていません。")
            }
            Section {
                ForEach(NoticeStats.rows()) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title)
                        Text("出した \(r.sent)・知らせから開いた \(r.opened)・ボタンを押した \(r.buttons)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("知らせ")
            } footer: {
                Text("2026-11-10 から数えています。「期限の1時間前」は、用意した数です（その前に済みにしたものも入ります）。")
            }
            Section {
                LabeledContent("役に立った", value: "\(answers.good)")
                LabeledContent("外れ", value: "\(answers.bad)")
            } header: {
                Text("記録に質問する")
            } footer: {
                Text("答えの下の「役に立った」「外れ」を押した数です。")
            }
        }
        .navigationTitle("数で見る")
    }
}

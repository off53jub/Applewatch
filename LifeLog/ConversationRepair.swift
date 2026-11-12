import Foundation

/// 終わりが始まりより前になってしまった古い会話の手直し（2026-11-12）。
/// 作るときの穴は塞いであるが、すでに残っている記録が13個ほどある。日の記録を読んだときに、終わりの時刻だけを直す。
/// 他の項目（行・見出し・要点・番号 rev など）には触らない。
extension ConversationLog {
    /// end < start の会話の end を、max(start, 最後の行の時刻) にする。直した数も返す。
    nonisolated static func repairedEnds(_ log: Day) -> (log: Day, fixed: Int) {
        var out = log
        var fixed = 0
        for i in out.conversations.indices where out.conversations[i].end < out.conversations[i].start {
            let start = out.conversations[i].start
            let last = out.conversations[i].lines.map(\.time).max() ?? start
            out.conversations[i].end = max(start, last)
            fixed += 1
        }
        return (out, fixed)
    }
}

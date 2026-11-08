import Foundation

/// ドキュメントの1行の直し（find を replace に置き換える）。2026-11-08
struct DocFix: Codable, Equatable {
    let find: String
    let replace: String
}

/// ある日のドキュメントに、まだ当てていない直し（当てる順）。記録の中はもう直っている。2026-11-08
/// 話者の名前の直し・テレビの行の直しで、Google に断られた・時間切れ・iOS に止められたときに覚えて、次の機会にやり直す。
struct DocFixQueue: Codable, Equatable {
    var fixes: [DocFix]
    /// 続けて失敗した回数（giveUp 回でやめる。ドキュメントが消された日などで、いつまでも送らないように）
    var failures: Int = 0

    static let giveUp = 20

    /// 当て終わった（または失敗した）あとに残すもの。
    /// - tried: 当てようとした直し（snapshot のあとに、そのとき新しく足した分）
    /// - snapshot: 当て始めたときに覚えていた直し
    /// - now: 当て終わって読み直した、覚えている直し（待っているあいだに足された分があれば、snapshot のうしろに付いている）
    static func after(tried: [DocFix], snapshot: [DocFix], now: DocFixQueue?, failed: Bool, failures: Int) -> DocFixQueue? {
        let current = now?.fixes ?? []
        let added = current.starts(with: snapshot) ? Array(current.dropFirst(snapshot.count))
            : current.filter { !snapshot.contains($0) }
        if failed {
            let count = failures + 1
            guard count < giveUp else { return added.isEmpty ? nil : DocFixQueue(fixes: added) }
            return DocFixQueue(fixes: tried + added.filter { !tried.contains($0) }, failures: count)
        }
        return added.isEmpty ? nil : DocFixQueue(fixes: added)
    }
}

extension Error {
    /// iOS に止められた・自分で止めた（cancelled）。エラーとして出さない（あとでやり直すので）。
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let url = self as? URLError, url.code == .cancelled { return true }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

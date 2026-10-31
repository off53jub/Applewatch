import Foundation

/// iPhone と時計の両方で同じ時間帯を録っていたら、30秒ごとに聞き取りの良いほうの文だけを残す。
///
/// 文字起こしした行はいったんここに溜め、両方の区切りがそろった時間帯（frontier より前）から
/// 書き出し待ち（outbox）に移す。書き出しに失敗しても outbox に残るので、次の機会に書き直せる。
@MainActor
final class Merger {
    struct Heard: Codable {
        var line: ConversationLog.Line
        /// この行が終わる時刻（次の行の始まりか、区切りの終わり）
        let end: Date
        let fromWatch: Bool
        /// 聞き取れた量と確からしさ。文字数 × 確からしさ（0〜1）
        let weight: Double
    }

    static let window: TimeInterval = 30
    /// 今まで使っていたほうを、相手がこの倍率より良いときだけ乗り換える（細かく行き来しないように）
    private static let switchRatio = 1.2

    private struct State: Codable {
        var held: [Heard] = []
        var outbox: [ConversationLog.Line] = []
        /// 書き出した30秒枠（[始まり, 終わり] の番号の組）。遅れて届いた区切りの同じ枠は捨てる。
        var written: [[Int]] = []
        /// 最後に書き出した行（つなぎ目で同じ話を二度書かないため）
        var lastStart: Date?
        var lastEnd: Date?
        var lastFromWatch: Bool?
    }

    private var state: State
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("merge.json")

    init() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
    }

    var outbox: [ConversationLog.Line] { state.outbox }
    var hasHeld: Bool { !state.held.isEmpty }

    /// 1つの区切りの行を足す。アプリが途中で終わって同じ区切りをもう一度文字起こししたときは足さない。
    func add(_ heard: [Heard]) {
        guard let name = heard.first?.line.audio else { return }
        let known = state.held.contains { $0.line.audio == name } || state.outbox.contains { $0.audio == name }
        guard !known else { return }
        state.held += heard
        save()
    }

    /// frontier より前の枠を、良いほうを選んで outbox に移す。
    func release(before frontier: Date) {
        let limit = Self.index(frontier)
        let ready = state.held.filter { Self.index($0.line.time) < limit }
        guard !ready.isEmpty else { return }
        state.held.removeAll { Self.index($0.line.time) < limit }

        var out: [ConversationLog.Line] = []
        let windows = Dictionary(grouping: ready) { Self.index($0.line.time) }
        for w in windows.keys.sorted() {
            // 先に書いた枠に、もう片方が遅れて届いたら捨てる（もう書いてあるので）
            guard !isWritten(w), let items = windows[w] else { continue }
            let phone = items.filter { !$0.fromWatch }
            let watch = items.filter { $0.fromWatch }
            let pick: [Heard]
            if phone.isEmpty || watch.isEmpty {
                pick = phone.isEmpty ? watch : phone
            } else {
                let phoneScore = phone.reduce(0) { $0 + $1.weight }
                let watchScore = watch.reduce(0) { $0 + $1.weight }
                let current = state.lastFromWatch ?? false
                let (mine, other) = current ? (watchScore, phoneScore) : (phoneScore, watchScore)
                let stay = mine * Self.switchRatio >= other
                pick = (stay == current) ? watch : phone
            }
            for heard in pick.sorted(by: { $0.line.time < $1.line.time }) {
                // 片方から乗り換えたところで、前の行と同じ時間にかぶる行は飛ばす（同じ話を二度書かない）
                if let fromWatch = state.lastFromWatch, fromWatch != heard.fromWatch,
                   let start = state.lastStart, let end = state.lastEnd,
                   heard.line.time >= start, heard.line.time < end.addingTimeInterval(-1) {
                    continue
                }
                out.append(heard.line)
                state.lastStart = heard.line.time
                state.lastEnd = heard.end
                state.lastFromWatch = heard.fromWatch
            }
            markWritten(w)
        }
        state.outbox += out
        state.outbox.sort { $0.time < $1.time }
        // 2日より前の枠は覚えておかなくてよい
        let old = Self.index(.now.addingTimeInterval(-2 * 24 * 3600))
        state.written.removeAll { $0[1] < old }
        save()
    }

    /// outbox の先頭から count 行を書き出し終えた
    func sent(_ count: Int) {
        state.outbox.removeFirst(min(count, state.outbox.count))
        save()
    }

    private static func index(_ time: Date) -> Int {
        Int((time.timeIntervalSince1970 / window).rounded(.down))
    }

    private func isWritten(_ w: Int) -> Bool {
        state.written.contains { $0[0] <= w && w <= $0[1] }
    }

    private func markWritten(_ w: Int) {
        guard !isWritten(w) else { return }
        if let i = state.written.firstIndex(where: { $0[1] == w - 1 }) {
            state.written[i][1] = w
        } else {
            state.written.append([w, w])
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

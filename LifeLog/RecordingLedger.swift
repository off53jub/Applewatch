import Foundation
import Observation

/// 録音の帳簿（2026-11-06）。区切りごとの「届いた・文字にした・壊れていた」と、時計の様子
/// （録音中・静かで休み・充電中・電池・録音を休む場所）を14日分残す。新しいファイル recordings.json（端末ごと・同期しない）。
/// - 抜けの地図: 1日のうち、何も録れていなかった時間（10分以上）とその理由
/// - 数の照合: 届いた区切り・文字にした区切り・壊れた区切り・まだ待っている区切りの数
/// - 毎朝の点検・文字起こし待ちの滞留・時計の電池の先回りに使う
@MainActor
@Observable
final class RecordingLedger {
    /// 区切り1つ
    struct Chunk: Codable, Equatable {
        let name: String
        let start: Date
        /// 長さが分かれば、終わり
        var end: Date? = nil
        /// "watch"（時計）・"phone"（iPhone）・"import"（取り込み）
        let source: String
        var received: Date? = nil
        var transcribed: Date? = nil
        /// 書いた行の数
        var lines: Int? = nil
        var broken: Bool? = nil
    }

    /// 時計とこの端末の様子（変わったときと、15分ごとに残す）
    struct State: Codable, Equatable {
        let at: Date
        var recording: Bool
        /// 時計が静かで書くのを休んでいる
        var resting: Bool
        var charging: Bool? = nil
        /// 0〜1
        var battery: Double? = nil
        var lowPower: Bool? = nil
        /// 録音を休む場所（家など）にいる
        var held: Bool? = nil
    }

    /// 録れていなかった時間
    struct Gap: Equatable, Identifiable {
        let start: Date
        let end: Date
        let reason: String
        var id: Date { start }
        var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    }

    /// 1日の帯の1こま（地図に出す）
    struct Span: Equatable {
        enum Kind: Equatable { case recorded, quiet, held, gap }
        let start: Date
        let end: Date
        let kind: Kind
    }

    private struct Store: Codable {
        var chunks: [Chunk] = []
        var states: [State] = []
    }

    static let keepDays = 14
    /// これより短い抜けは地図に赤く出さない
    static let minimumGap: TimeInterval = 10 * 60
    /// 時計から知らせが無いとみなす長さ
    static let silentWatch: TimeInterval = 20 * 60

    private(set) var chunks: [Chunk] = []
    private(set) var states: [State] = []

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("recordings.json")

    init() {
        // 読めないファイルは、上書きせずに脇によける（読む前に保存しない）
        if let data = try? Data(contentsOf: Self.url) {
            if let store = try? JSONDecoder().decode(Store.self, from: data) {
                chunks = store.chunks
                states = store.states
            } else {
                let aside = Self.url.deletingLastPathComponent().appendingPathComponent("recordings-unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: Self.url, to: aside)
            }
        }
    }

    private func save() {
        let old = Date.now.addingTimeInterval(-Double(Self.keepDays) * 24 * 3600)
        chunks.removeAll { $0.start < old }
        states.removeAll { $0.at < old }
        guard let data = try? JSONEncoder().encode(Store(chunks: chunks, states: states)) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    static func source(of url: URL) -> String {
        Storage.isFromWatch(url) ? "watch" : Storage.isImported(url) ? "import" : "phone"
    }

    private func upsert(_ url: URL, _ change: (inout Chunk) -> Void) {
        let name = url.lastPathComponent
        guard let start = Storage.startDate(of: url) else { return }
        if let i = chunks.lastIndex(where: { $0.name == name }) {
            change(&chunks[i])
        } else {
            var chunk = Chunk(name: name, start: start, end: nil, source: Self.source(of: url))
            change(&chunk)
            chunks.append(chunk)
        }
        save()
    }

    /// 時計から区切りが届いた
    func received(_ url: URL, at time: Date) { upsert(url) { $0.received = time } }

    /// 文字にした（長さと、書いた行の数）
    func transcribed(_ url: URL, duration: TimeInterval, lines: Int) {
        upsert(url) {
            $0.transcribed = .now
            $0.lines = lines
            if duration > 0 { $0.end = $0.start.addingTimeInterval(duration) }
        }
    }

    /// 壊れていて読めなかった
    func broken(_ url: URL) { upsert(url) { $0.broken = true } }

    /// もう文字にした区切りか（送り直されてきた区切りを二重に処理しないため）
    func isTranscribed(_ name: String) -> Bool { chunks.contains { $0.name == name && $0.transcribed != nil } }

    /// 様子を残す。前と同じなら、15分に1回だけ（電池は1%より大きく変わったとき）
    func note(_ state: State) {
        if let last = states.last,
           last.recording == state.recording, last.resting == state.resting, last.charging == state.charging,
           last.lowPower == state.lowPower, last.held == state.held,
           abs((last.battery ?? -1) - (state.battery ?? -1)) < 0.01,
           state.at.timeIntervalSince(last.at) < 15 * 60 {
            return
        }
        states.append(state)
        save()
    }

    /// いちばん新しい様子
    var lastState: State? { states.last }

    // MARK: - 抜けの地図

    /// その日（0時から24時、今日なら今まで）の帯と、録れていなかった時間
    func map(for dayStart: Date, now: Date = .now) -> (spans: [Span], gaps: [Gap]) {
        let dayEnd = min(dayStart.addingTimeInterval(24 * 3600), now)
        guard dayEnd > dayStart else { return ([], []) }
        let recorded = chunks.compactMap { c -> (Date, Date)? in
            guard c.source != "import", c.broken != true else { return nil }
            // 長さが分からない区切りは、いまの設定のいちばん長い区切りとみなす（短めなら2分20秒・ふつうなら5分20秒）
            let end = c.end ?? c.start.addingTimeInterval(ChunkCutter.longest)
            return end > dayStart && c.start < dayEnd ? (c.start, end) : nil
        }
        // その日と、その前の日の様子だけ（理由を決めるのに前の様子も見る）
        let nearby = states.filter { $0.at >= dayStart.addingTimeInterval(-24 * 3600) && $0.at <= dayEnd }
        let spans = Self.spans(from: dayStart, to: dayEnd, recorded: recorded, states: nearby)
        let gaps = Self.gaps(spans, states: nearby)
        return (spans, gaps)
    }

    /// 帯を作る。録れている時間 > 録音を休む場所 > 静かで休み > 抜け の順に決める
    nonisolated static func spans(from start: Date, to end: Date, recorded: [(Date, Date)], states: [State]) -> [Span] {
        // 1分ごとに決めて、同じものをつなげる
        let step: TimeInterval = 60
        var kinds: [Span.Kind] = []
        var t = start
        let sortedStates = states.sorted { $0.at < $1.at }
        var stateIndex = -1
        while t < end {
            let mid = t.addingTimeInterval(step / 2)
            while stateIndex + 1 < sortedStates.count, sortedStates[stateIndex + 1].at <= mid { stateIndex += 1 }
            let state = stateIndex >= 0 ? sortedStates[stateIndex] : nil
            // 知らせが来てから長くたっている様子は使わない
            let fresh = state.map { mid.timeIntervalSince($0.at) <= silentWatch } ?? false
            if recorded.contains(where: { $0.0 <= mid && mid < $0.1 }) {
                kinds.append(.recorded)
            } else if state?.held == true {
                kinds.append(.held)
            } else if fresh, state?.recording == true, state?.resting == true {
                kinds.append(.quiet)
            } else {
                kinds.append(.gap)
            }
            t = t.addingTimeInterval(step)
        }
        var spans: [Span] = []
        for (i, kind) in kinds.enumerated() {
            let from = start.addingTimeInterval(Double(i) * step)
            let to = min(end, from.addingTimeInterval(step))
            if let last = spans.last, last.kind == kind {
                spans[spans.count - 1] = Span(start: last.start, end: to, kind: kind)
            } else {
                spans.append(Span(start: from, end: to, kind: kind))
            }
        }
        return spans
    }

    /// 10分以上の抜けと、その理由
    nonisolated static func gaps(_ spans: [Span], states: [State]) -> [Gap] {
        spans.filter { $0.kind == .gap && $0.end.timeIntervalSince($0.start) >= minimumGap }
            .map { Gap(start: $0.start, end: $0.end, reason: reason(from: $0.start, to: $0.end, states: states)) }
    }

    /// 抜けの理由を、その前後の時計の様子から決める
    nonisolated static func reason(from start: Date, to end: Date, states: [State]) -> String {
        let sorted = states.sorted { $0.at < $1.at }
        let before = sorted.last { $0.at <= start }
        let inside = sorted.filter { $0.at > start && $0.at < end }
        let around = (before.map { [$0] } ?? []) + inside
        if around.contains(where: { $0.charging == true }) { return "時計の充電中" }
        if let battery = (inside.last ?? before)?.battery, battery <= 0.05 { return "時計の電池切れ" }
        if let before, !before.recording, start.timeIntervalSince(before.at) < 24 * 3600 { return "時計の録音が止まっていた" }
        if around.contains(where: { $0.recording == false }) { return "時計の録音が止まっていた" }
        if inside.isEmpty, before.map({ start.timeIntervalSince($0.at) > silentWatch }) ?? true {
            return "時計から知らせが無かった（iPhone から離れていた・時計のアプリが止まっていた）"
        }
        if around.contains(where: { $0.lowPower == true }) { return "時計が低電力モードでまとめて送るあいだ" }
        return "分からない（録っていたが届いていない・捨てた区切りなど）"
    }

    // MARK: - 数の照合

    struct Counts: Equatable {
        var watchReceived = 0
        var phoneRecorded = 0
        var transcribed = 0
        var broken = 0
        var waiting = 0
        var lines = 0
    }

    /// その日に始まった区切りの数
    func counts(for dayStart: Date) -> Counts {
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)
        var counts = Counts()
        for c in chunks where c.start >= dayStart && c.start < dayEnd && c.source != "import" {
            if c.source == "watch" { counts.watchReceived += 1 } else { counts.phoneRecorded += 1 }
            if c.broken == true {
                counts.broken += 1
            } else if c.transcribed != nil {
                counts.transcribed += 1
                counts.lines += c.lines ?? 0
            } else {
                counts.waiting += 1
            }
        }
        return counts
    }

    // MARK: - 時計の電池の先回り

    /// 直近2時間の電池の減り方から、残り 10% になる時刻を予想する（充電中・減っていない・分からないなら nil）
    nonisolated static func batteryEmpty(states: [State], now: Date = .now) -> Date? {
        let recent = states.filter { now.timeIntervalSince($0.at) <= 2 * 3600 && $0.at <= now }
            .sorted { $0.at < $1.at }
        guard let last = recent.last, last.charging != true, let level = last.battery else { return nil }
        // 最後に充電していたあと
        let since = recent.lastIndex { $0.charging == true }.map { recent.index(after: $0) } ?? recent.startIndex
        let samples = recent[since...].compactMap { s in s.battery.map { (s.at, $0) } }
        guard let first = samples.first, last.at.timeIntervalSince(first.0) >= 30 * 60 else { return nil }
        let used = first.1 - level
        guard used > 0.01 else { return nil }
        let perSecond = used / last.at.timeIntervalSince(first.0)
        let left = level - 0.10
        guard left > 0 else { return last.at }
        return last.at.addingTimeInterval(left / perSecond)
    }

    // MARK: - 毎朝の点検

    /// 毎朝の点検の一文。「昨日の点検: 録れていない時間 42分（13:10〜13:40 時計の充電中 ほか）・…」
    nonisolated static func reportLine(gaps: [Gap], counts: Counts, uncertain: Int, unnamedVoices: Int) -> String {
        let clock = Date.FormatStyle(date: .omitted, time: .shortened)
        let missing = gaps.reduce(0) { $0 + $1.minutes }
        var parts: [String] = []
        if let longest = gaps.max(by: { $0.minutes < $1.minutes }) {
            parts.append("録れていない時間 \(missing)分（いちばん長いのは \(longest.start.formatted(clock))〜\(longest.end.formatted(clock)) \(longest.reason)）")
        } else {
            parts.append("録れていない時間 0分")
        }
        parts.append("壊れた区切り \(counts.broken)")
        if counts.waiting > 0 { parts.append("まだ文字にしていない区切り \(counts.waiting)") }
        parts.append("自信の低い行 \(uncertain)")
        parts.append("名前の無い声 \(unnamedVoices)人")
        return parts.joined(separator: "・")
    }
}

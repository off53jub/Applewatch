import Foundation
import Observation
import SwiftUI

/// 1日の正本（2026-11-15。強化案 57）。母艦が PLAUD の文を土台に、アプリの行から話し手と時刻を重ねて1本にしたもの
/// （母艦の scripts/Build-Canonical.py。形の正本は母艦の docs/scripts.md）。家の PC の GET /canonical?day=（features の "canonical"）で
/// 読み、1日の画面（DayView）の「正本で見る」で見せる。読むだけ（アプリの記録は変えない）。日ごとに端末に写しを置く（同期しない）。

struct CanonicalLine: Codable, Equatable, Identifiable {
    /// 並びの番号（同じ時刻の行もあるので）
    var id: Int
    /// "HH:MM:SS"
    var time: String
    /// "plaud"（PLAUD の文）・"app"（アプリの行）
    var source: String
    var speaker: String? = nil
    /// "app"・"line"（当たったアプリの行から）・"turn"（同じ PLAUD の話し手からの推定）・"mixed"
    var speakerHow: String? = nil
    var plaudSpeaker: String? = nil
    var text: String

    var isPlaud: Bool { source == "plaud" }

    /// 話し手の出し方（推定は「?」をつける）
    var who: String {
        if let speaker {
            return speakerHow == "turn" ? speaker + "?" : speaker
        }
        if let plaudSpeaker { return "PLAUD " + plaudSpeaker }
        return "話し手不明"
    }
}

/// 1日の正本の、ひとつの時（"09"）の行
struct CanonicalHour: Identifiable, Equatable {
    var id: String
    var lines: [CanonicalLine]
}

struct CanonicalDay: Codable, Equatable {
    var day: String
    var generated_at: String? = nil
    var lines: [CanonicalLine] = []
    var fetched: Date? = nil

    var plaudCount: Int {
        var n = 0
        for l in lines where l.isPlaud { n += 1 }
        return n
    }

    var speakerCount: Int {
        var n = 0
        for l in lines where l.speaker != nil { n += 1 }
        return n
    }
}

enum CanonicalRules {
    static let lineLimit = 12000
    static let recentDays = 14
    static let sources: [String] = ["plaud", "app"]
    static let hows: [String] = ["app", "line", "turn", "mixed"]

    private struct RawLine: Decodable {
        var time: String?
        var source: String?
        var speaker: LossyRow<String>?
        var speaker_how: LossyRow<String>?
        var plaud_speaker: LossyRow<String>?
        var text: String?
    }

    private struct RawDay: Decodable {
        var available: Bool?
        var day: String?
        var generated_at: String?
        var lines: [LossyRow<RawLine>]?
    }

    /// "HH:MM:SS" か
    static func isClock(_ text: String?) -> Bool {
        guard let text, text.count == 8 else { return false }
        let chars: [Character] = Array(text)
        guard chars[2] == ":", chars[5] == ":" else { return false }
        let digits: [Character] = [chars[0], chars[1], chars[3], chars[4], chars[6], chars[7]]
        for ch in digits where !(ch.isASCII && ch.isNumber) { return false }
        guard let h = Int(String(chars[0...1])), let m = Int(String(chars[3...4])), let s = Int(String(chars[6...7])) else {
            return false
        }
        return h < 24 && m < 60 && s < 60
    }

    /// GET /canonical の答え。読めない・{"available": false}・違う日なら nil（前の写しのままにする）
    static func decode(_ data: Data, day: String) -> CanonicalDay? {
        guard let raw = try? JSONDecoder().decode(RawDay.self, from: data), raw.available == true else { return nil }
        guard raw.day == day else { return nil }
        var lines: [CanonicalLine] = []
        for row in raw.lines ?? [] {
            guard let r = row.value, let time = r.time, isClock(time),
                  let source = r.source, sources.contains(source),
                  let text = MothershipFeeds.cut(r.text, 600) else { continue }
            var line = CanonicalLine(id: lines.count, time: time, source: source, text: text)
            line.speaker = MothershipFeeds.cut(r.speaker?.value, 20)
            if let how = r.speaker_how?.value, hows.contains(how), line.speaker != nil { line.speakerHow = how }
            line.plaudSpeaker = MothershipFeeds.cut(r.plaud_speaker?.value, 20)
            lines.append(line)
            if lines.count >= lineLimit { break }
        }
        return CanonicalDay(day: day, generated_at: raw.generated_at, lines: sortedByTime(lines))
    }

    /// 時刻の順（同じ時刻は元の並びのまま）。番号は並べたあとの順に振り直す
    static func sortedByTime(_ lines: [CanonicalLine]) -> [CanonicalLine] {
        var keyed: [CanonicalLine] = lines
        keyed.sort { a, b in a.time != b.time ? a.time < b.time : a.id < b.id }
        var out: [CanonicalLine] = []
        for (i, l) in keyed.enumerated() {
            var copy = l
            copy.id = i
            out.append(copy)
        }
        return out
    }

    /// 時（"09"）ごとのまとまり
    static func hours(_ lines: [CanonicalLine]) -> [CanonicalHour] {
        var out: [CanonicalHour] = []
        for l in lines {
            let h: String = String(l.time.prefix(2))
            if let last = out.last, last.id == h {
                out[out.count - 1].lines.append(l)
            } else {
                out.append(CanonicalHour(id: h, lines: [l]))
            }
        }
        return out
    }
}

// MARK: - 読み込み

@MainActor
@Observable
final class CanonicalBook {
    static let shared = CanonicalBook()

    private(set) var days: [String: CanonicalDay] = [:]
    /// 新しい分を読めなかった日
    private(set) var stale: Set<String> = []
    @ObservationIgnored private var tried: [String: Date] = [:]

    nonisolated static let folder = "canonical"
    private static let again: TimeInterval = 60

    private static func dayURL(_ day: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(day + ".json")
    }

    private static func readDay(_ day: String) -> CanonicalDay? {
        guard let data = try? Data(contentsOf: dayURL(day)) else { return nil }
        return try? JSONDecoder().decode(CanonicalDay.self, from: data)
    }

    private static func writeDay(_ value: CanonicalDay) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let dir = URL.applicationSupportDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dayURL(value.day), options: .atomic)
    }

    func day(_ day: String) -> CanonicalDay? { days[day] }

    /// その日の写しを読み、家の PC から読み直す（同じ日は1分に1回まで）
    func refresh(day: String, pc: HomePC, force: Bool = false) async {
        if days[day] == nil, let saved = Self.readDay(day) { days[day] = saved }
        guard pc.isConfigured, OneTimeline.isRecent(day, now: .now) else { return }
        if !force, let at = tried[day], Date.now.timeIntervalSince(at) < Self.again { return }
        tried[day] = .now
        guard pc.shouldTry, pc.features.contains("canonical") else {
            stale.insert(day)
            return
        }
        do {
            let data = try await pc.getJSONData("canonical", query: [URLQueryItem(name: "day", value: day)], timeout: 20)
            if var parsed = CanonicalRules.decode(data, day: day) {
                parsed.fetched = .now
                days[day] = parsed
                Self.writeDay(parsed)
                stale.remove(day)
                Tally.add("canonical.fetched")
            } else {
                stale.insert(day)
            }
        } catch {
            stale.insert(day)
        }
        prune()
    }

    private func prune() {
        let dir = URL.applicationSupportDirectory.appendingPathComponent(Self.folder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasSuffix(".json") {
            let d = String(name.dropLast(5))
            if !OneTimeline.isRecent(d, now: .now) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                days.removeValue(forKey: d)
            }
        }
    }
}

// MARK: - 画面

/// 1日の正本の1行
struct CanonicalLineRow: View {
    let line: CanonicalLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(line.who).font(.caption.bold())
                Spacer(minLength: 0)
                Text(line.isPlaud ? "PLAUD" : "アプリ")
                    .font(.caption2)
                    .foregroundStyle(line.isPlaud ? Color.accentColor : Color.secondary)
            }
            Text(line.text).font(.callout)
        }
        .padding(.vertical, 1)
    }
}

/// 1日の画面の「正本で見る」
struct CanonicalDayView: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String

    var body: some View {
        let book = CanonicalBook.shared
        let value: CanonicalDay? = book.day(day)
        let groups: [CanonicalHour] = CanonicalRules.hours(value?.lines ?? [])
        List {
            if let value {
                Section {
                    Text("PLAUD のある時間は PLAUD の文に、アプリの行から話し手と時刻を重ねました。PLAUD の無い時間はアプリの行です。「?」の付いた話し手は推定です。")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("行", value: "\(value.lines.count)（PLAUD \(value.plaudCount)・アプリ \(value.lines.count - value.plaudCount)）")
                    LabeledContent("話し手が分かる行", value: "\(value.speakerCount)")
                    if book.stale.contains(day), let fetched = value.fetched {
                        Text("家の PC につながらないので、" + HomeFeeds.clock(fetched) + " に読んだ分を出しています。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(groups) { group in
                Section(group.id + ":00") {
                    ForEach(group.lines) { line in
                        CanonicalLineRow(line: line)
                    }
                }
            }
        }
        .overlay {
            if value == nil {
                ContentUnavailableView("この日の正本はまだありません", systemImage: "text.document",
                                       description: Text("家の PC が母艦の正本を配るのは直近 14 日の分です。母艦が作るまで、少し待ってください。"))
            }
        }
        .task(id: day) { await book.refresh(day: day, pc: pipeline.homePC) }
        .refreshable { await book.refresh(day: day, pc: pipeline.homePC, force: true) }
    }
}

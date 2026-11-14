import Foundation

/// 録り方の実験（2026-11-15。強化案 47。iPhone と時計の両方で使う）。
///
/// 音質（32kbps と 48kbps）と区切りの長さ（45秒＝「短め」と 300秒＝「ふつう」）を1日ずつ変えて、
/// 拾えた割合・人物N・時計の電池を母艦（scripts/Build-RecordingExperiment.py）が組ごとに並べる。決めるのは本人。
/// - 設定「録り方の実験」（初めはオン・いつでも止められる）。
/// - 新しい版を iPhone で初めて開いた次の日から4日間: 1日目 32kbps・45秒／2日目 48kbps・45秒／3日目 32kbps・300秒／4日目 48kbps・300秒。
///   終わったら元（32kbps・設定の区切りの長さ。初めは短め＝45秒）に戻る（設定の値そのものは変えない）。
/// - 会議モードのあいだは会議モードが優先（実験の組を使わない。時計は今までどおり 48kbps）。
/// - 時計の「電池が少ないときは5分に」は実験より優先（電池を守る）。その日の組の記録は予定の組のまま。
/// - 始まりの日とオンオフは、iPhone が区切りの長さの設定と一緒に時計に送る（時計は自分で始まりの日を決めない）。
/// - 区切りの長さは今までの2つ（短め・ふつう）のどちらかなので、家の PC・送り待ちの区切りは何も変わらない（PC は長さを前提にしていない）。
enum RecordingExperiment {
    /// その日の組
    struct Combo: Equatable, Sendable {
        /// 何日目か（1〜4）
        let day: Int
        /// 音質（bps）
        let bitrate: Int
        /// 区切りの長さ
        let length: ChunkCutter.Length

        /// 「32kbps・45秒」
        var label: String { "\(bitrate / 1000)kbps・\(Int(length.minimum))秒" }
    }

    /// 設定「録り方の実験」（iPhone と時計の UserDefaults。時計には iPhone から届く）
    static let onKey = "recExpOn"
    /// 1日目（yyyy-MM-dd）。iPhone が新しい版を初めて開いたときに、次の日を入れる
    static let startKey = "recExpStart"
    /// 会議モードか（時計は WatchSender が、iPhone は Pipeline.setMeeting が書く）
    static let meetingKey = "meetingOn"
    static let days = 4
    static let defaultBitrate = 32_000
    static let meetingBitrate = 48_000

    /// 4日分の組（順番は約束のとおり）
    static let plan: [(bitrate: Int, length: ChunkCutter.Length)] = [
        (bitrate: 32_000, length: .short), (bitrate: 48_000, length: .short),
        (bitrate: 32_000, length: .normal), (bitrate: 48_000, length: .normal),
    ]

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: onKey) }
    }

    static var start: String? {
        get { UserDefaults.standard.string(forKey: startKey) }
        set { UserDefaults.standard.set(newValue, forKey: startKey) }
    }

    static var meetingNow: Bool { UserDefaults.standard.bool(forKey: meetingKey) }

    // MARK: 決まり（決まった入力から決まった出力だけ）

    /// "2026-11-15"
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts: [Int] = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 初めて開いた日の次の日（1日目）
    static func firstDay(after now: Date, calendar: Calendar = .current) -> String {
        let next: Date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        return dayKey(next, calendar: calendar)
    }

    /// その日の組。実験がオフ・始まりの日が無い・4日の外・会議モードなら nil（いつもの録り方）
    static func combo(on: Bool, start: String?, meeting: Bool, now: Date, calendar: Calendar = .current) -> Combo? {
        guard on, !meeting, let start, let first = date(start, calendar: calendar) else { return nil }
        let today: Date = calendar.startOfDay(for: now)
        guard let offset = calendar.dateComponents([.day], from: first, to: today).day, offset >= 0, offset < days else {
            return nil
        }
        let entry = plan[offset]
        return Combo(day: offset + 1, bitrate: entry.bitrate, length: entry.length)
    }

    /// 実験が終わったか（始まりの日から4日たった）
    static func finished(start: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let start, let first = date(start, calendar: calendar) else { return false }
        let offset: Int = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day ?? 0
        return offset >= days
    }

    /// 使う区切りの長さ（その日の組があれば組の長さ、無ければ設定の長さ）
    static func length(base: ChunkCutter.Length, combo: Combo?) -> ChunkCutter.Length {
        combo?.length ?? base
    }

    /// 使う音質。meetingRate は会議モードのときの音質（時計は 48kbps。iPhone は今までどおり 32kbps）
    static func bitrate(combo: Combo?, meeting: Bool, meetingRate: Int) -> Int {
        if let combo { return combo.bitrate }
        return meeting ? meetingRate : defaultBitrate
    }

    // MARK: いまの値（この端末の設定から）

    static func current(now: Date = .now) -> Combo? {
        combo(on: isOn, start: start, meeting: meetingNow, now: now)
    }

    /// 時計の録音の音質（会議モードは 48kbps）
    static func watchBitrate(now: Date = .now) -> Int {
        bitrate(combo: current(now: now), meeting: meetingNow, meetingRate: meetingBitrate)
    }

    // MARK: iPhone と時計のあいだ

    /// iPhone が時計に送る設定に入れる（始まりの日が無ければ、ここで次の日を入れる）
    static func addSettings(to context: inout [String: Any], now: Date = .now) {
        if start == nil { start = firstDay(after: now) }
        context[onKey] = isOn
        context[startKey] = start ?? ""
    }

    /// 時計が iPhone から届いた設定を読む
    static func readSettings(_ context: [String: Any]) {
        if let on = context[onKey] as? Bool { isOn = on }
        if let first = context[startKey] as? String, date(first) != nil { start = first }
    }
}

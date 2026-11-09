import Foundation

/// 位置の記録を、ドライブの「LifeLog/位置」に1日1ファイルで書き出す（2026-11-09）。
///
/// - Google マップのタイムラインは iPhone の中にしか無く、自動で書き出せない。そこで、このアプリが受け取っている位置
///   （大きく動いたときの点。「行ったお店」がオンなら立ち寄りも）を、母艦（家の PC の D:\Lifelog）に渡す。
/// - 形は Google マップの新しい書き出し（semanticSegments）に合わせる。母艦の Process-TimelineInbox.ps1 がそのまま読む。
///   点は「次の点までそこにいた」滞在と、点から点への移動にする。立ち寄りは滞在にする。
/// - 書くのは終わった日だけ（次の日の1時を過ぎてから）。一度書いた日は書き直さない。
/// - 位置の点は端末に7日しか残らないので、さかのぼりは6日まで。iPhone だけで動かす（iPad と二重に書かない）。
enum LocationExport {
    /// 書いた日の印（UserDefaults）
    static let doneKey = "locationExportedDays"
    /// ドライブのフォルダの名前（LifeLog フォルダの中）
    static let folderName = "位置"
    /// さかのぼる日数（位置の点は7日で消えるので、それより短く）
    static let backDays = 6

    struct Point: Equatable, Sendable {
        var time: Date
        var latitude: Double
        var longitude: Double
        var accuracy: Double
        /// 登録した場所・前に調べた地名（分からなければ nil）
        var name: String? = nil
    }

    struct Stay: Equatable, Sendable {
        var start: Date
        var end: Date
        var latitude: Double
        var longitude: Double
        var name: String? = nil
    }

    static func fileName(_ day: String) -> String { "lifelog-location-\(day).json" }

    /// 書く日（古い順）。今日から backDays 日前〜昨日のうち、終わった日（次の日の1時を過ぎた日）で、まだ書いていない日
    static func dueDays(now: Date, done: Set<String>, calendar: Calendar = .current) -> [String] {
        let today = calendar.startOfDay(for: now)
        var result: [String] = []
        for back in stride(from: backDays, through: 1, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day),
                  let ready = calendar.date(byAdding: .hour, value: 1, to: next), now >= ready else { continue }
            let key = HealthExport.dayKey(day, calendar: calendar)
            if !done.contains(key) { result.append(key) }
        }
        return result
    }

    /// 母艦の取り込みが読む形（Google の新しい書き出しと同じ: { semanticSegments: [...] }）。点も立ち寄りも無ければ nil
    static func json(day: String, points: [Point], stays: [Stay], dayEnd: Date, calendar: Calendar = .current) -> Data? {
        let points = points.sorted { $0.time < $1.time }
        guard !points.isEmpty || !stays.isEmpty else { return nil }
        var segments: [[String: Any]] = []
        for (i, p) in points.enumerated() {
            let next = i + 1 < points.count ? points[i + 1] : nil
            // 次の点まで（最後の点はその日の終わりまで）そこにいた
            segments.append(visit(start: p.time, end: next?.time ?? dayEnd, latitude: p.latitude, longitude: p.longitude,
                                  name: p.name, calendar: calendar))
            if let next {
                let meters = distance(p.latitude, p.longitude, next.latitude, next.longitude)
                segments.append([
                    "startTime": HealthExport.stamp(p.time, calendar: calendar),
                    "endTime": HealthExport.stamp(next.time, calendar: calendar),
                    "activity": [
                        "start": ["latLng": latLng(p.latitude, p.longitude)],
                        "end": ["latLng": latLng(next.latitude, next.longitude)],
                        "distanceMeters": Int(meters.rounded()),
                        "topCandidate": ["type": "移動"],
                    ] as [String: Any],
                ])
            }
        }
        for s in stays.sorted(by: { $0.start < $1.start }) {
            segments.append(visit(start: s.start, end: s.end, latitude: s.latitude, longitude: s.longitude,
                                  name: s.name ?? "立ち寄り", calendar: calendar))
        }
        let object: [String: Any] = ["source": "LifeLog", "day": day, "semanticSegments": segments]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func visit(start: Date, end: Date, latitude: Double, longitude: Double, name: String?,
                              calendar: Calendar) -> [String: Any] {
        var top: [String: Any] = ["placeLocation": ["latLng": latLng(latitude, longitude)]]
        if let name, !name.isEmpty { top["semanticType"] = name }
        return [
            "startTime": HealthExport.stamp(start, calendar: calendar),
            "endTime": HealthExport.stamp(max(start, end), calendar: calendar),
            "visit": ["topCandidate": top],
        ]
    }

    /// Google の書き出しと同じ書き方（例: "35.689500°, 139.691700°"）
    static func latLng(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.6f°, %.6f°", latitude, longitude)
    }

    /// 2点のあいだの距離（m。地球を球とみなす）
    static func distance(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lng2 - lng1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

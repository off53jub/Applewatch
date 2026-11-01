import Foundation

/// 1日の「過ごし方」：何をしていたかの長い時間の塊（例: 12:00〜16:00 ダンスの練習）。
/// 会話（話が3分途切れたら区切る細かい単位）を、用事・場所・カレンダーの予定ごとにまとめ直したもの。
/// 会話の記録とは別のファイルに保存する（作り直しても会話の記録には触らない）。
struct Activity: Codable, Identifiable {
    enum Kind: String, Codable {
        /// 録音した会話から
        case recorded
        /// カレンダーの予定だけ（その時間の録音は無い）
        case plan
        /// 移動（その時間の録音は無い）
        case move
    }

    var start: Date
    var end: Date
    var title: String
    var kind: Kind
    var place: String?
    var people: [String]
    /// その中でしたこと
    var did: [String]
    /// 重なったカレンダーの予定
    var event: String?
    /// この塊に入る会話の、最初と最後の会話の始まり
    var first: Date?
    var last: Date?
    /// 会話の数
    var count: Int

    var id: String { "\(kind.rawValue)-\(start.timeIntervalSince1970)" }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var timeRange: String { Self.clock.string(from: start) + "〜" + Self.clock.string(from: end) }

    /// 「4時間」「1時間20分」「35分」
    var length: String {
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        if minutes < 60 { return "\(minutes)分" }
        return minutes % 60 == 0 ? "\(minutes / 60)時間" : "\(minutes / 60)時間\(minutes % 60)分"
    }

    /// 場所・相手・予定を1行にしたもの
    var detail: String {
        var parts: [String] = []
        if let place { parts.append(place) }
        if !people.isEmpty { parts.append(people.joined(separator: "、") + "と") }
        if let event, event != title { parts.append("〔\(event)〕") }
        return parts.joined(separator: "　")
    }

    /// ドキュメントの「1日の流れ」に書く1行
    var flowLine: String {
        var line = timeRange + "　"
        switch kind {
        case .recorded: line += title
        case .plan: line += "〔予定〕" + title + "（録音なし）"
        case .move: line += title
        }
        let info = self.detail
        if !info.isEmpty { line += "（\(info)）" }
        if !did.isEmpty { line += "：" + did.joined(separator: "／") }
        return line
    }
}

/// 過ごし方の保存（日ごとの JSON。会話の記録の days とは別のフォルダ）
enum ActivityStore {
    struct Saved: Codable {
        var activities: [Activity]
        /// 何から作ったか（会話や予定が変わったら作り直す）
        var basis: String
        /// 言語モデルで区切ったか（できなかったときは、次に開いたときにやり直す）
        var smart: Bool
    }

    private static let dir: URL = {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("activities", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load(_ day: String) -> Saved? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(day + ".json")) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved, day: String) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: dir.appendingPathComponent(day + ".json"), options: .atomic)
    }
}

/// 会話とカレンダーの予定から、過ごし方の塊を作る。
enum ActivityBuilder {
    typealias Conversation = ConversationLog.Conversation

    /// 塊のもとにする会話のまとまり（見出しの無い短い会話が続くところは、1つにまとめて渡す）
    private struct Unit {
        var indices: [Int]
    }

    /// これだけ録音が途切れたら、別の塊にする（言語モデルが使えないとき）
    private static let longGap: TimeInterval = 30 * 60
    /// 予定の始まり・終わりがこれだけ近ければ、塊の時刻を予定に合わせる
    private static let snap: TimeInterval = 45 * 60

    /// 作り直すかどうかの目印
    static func basis(_ conversations: [Conversation], events: [CalendarLink.Event]) -> String {
        var text = conversations.map { c in
            "\(Int(c.start.timeIntervalSince1970))-\(Int(c.end.timeIntervalSince1970))-\(c.title ?? "")-\(c.place ?? "")"
        }.joined(separator: ",")
        text += "|" + events.map { "\($0.title)@\(Int($0.start.timeIntervalSince1970))-\(Int($0.end.timeIntervalSince1970))" }
            .joined(separator: ",")
        // 長くなるので短い目印にする（FNV-1a）
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "\(conversations.count)-" + String(hash, radix: 16)
    }

    /// 録音した会話を塊にまとめる。apiKey があれば言語モデルで区切り、したことをまとめる。
    /// smart は言語モデルで区切れたか。
    static func recorded(_ conversations: [Conversation], events: [CalendarLink.Event], previous: [Activity]?,
                         apiKey: String?) async -> (activities: [Activity], smart: Bool) {
        let list = conversations.filter { !$0.lines.isEmpty }.sorted { $0.start < $1.start }
        guard !list.isEmpty else { return ([], true) }
        let units = makeUnits(list)
        var blocks: [(from: Int, to: Int, title: String)]?
        if let apiKey {
            blocks = try? await Summarizer.activityBlocks(
                units.enumerated().map { describe($0.element, number: $0.offset, in: list) }.joined(separator: "\n"),
                count: units.count,
                events: events.map { describe($0) }.joined(separator: "\n"),
                previous: previous?.filter { $0.kind == .recorded }.map { $0.timeRange + " " + $0.title }.joined(separator: "\n"),
                apiKey: apiKey)
        }
        let smart = blocks != nil
        let groups = blocks ?? simpleBlocks(units, in: list)

        var result: [Activity] = groups.map { group in
            let indices = units[group.from...group.to].flatMap(\.indices)
            let convs = indices.map { list[$0] }
            return Activity(start: convs[0].start, end: convs.map(\.end).max() ?? convs[0].end,
                            title: group.title.isEmpty ? fallbackTitle(convs) : group.title,
                            kind: .recorded, place: mainPlace(convs), people: people(convs),
                            did: fallbackDid(convs), event: nil,
                            first: convs.first?.start, last: convs.last?.start, count: convs.count)
        }
        // カレンダーの予定と重なる塊は、予定名を添え、始まり・終わりが近ければ予定の時刻に合わせる
        let raw = result.map { (start: $0.start, end: $0.end) }
        for i in result.indices {
            guard let event = bestEvent(for: raw[i], in: events) else { continue }
            result[i].event = event.title
            let earliest = i > 0 ? raw[i - 1].end : .distantPast
            let latest = i + 1 < raw.count ? raw[i + 1].start : .distantFuture
            if event.start < raw[i].start, raw[i].start.timeIntervalSince(event.start) <= snap {
                result[i].start = max(event.start, earliest)
            }
            if event.end > raw[i].end, event.end.timeIntervalSince(raw[i].end) <= snap {
                result[i].end = min(event.end, latest)
            }
            if result[i].place == nil, let location = event.location { result[i].place = location }
        }
        // 塊ごとに、その中でしたことをまとめる
        if let apiKey, smart {
            let pieces = result.indices.map { i in
                let convs = list.filter { c in
                    guard let first = result[i].first, let last = result[i].last else { return false }
                    return c.start >= first && c.start <= last
                }
                return (header: "\(i). \(result[i].timeRange) \(result[i].title)", body: Self.material(convs))
            }
            if let did = try? await Summarizer.activityDetails(pieces, apiKey: apiKey) {
                for i in result.indices where i < did.count && !did[i].isEmpty { result[i].did = did[i] }
            }
        }
        return (result, smart)
    }

    /// 録音の無い時間の、カレンダーの予定と移動を足して、時刻順にする。
    static func addUnrecorded(_ recorded: [Activity], events: [CalendarLink.Event],
                              trips: [(start: Date, end: Date, title: String)], until: Date) -> [Activity] {
        var result = recorded
        var covered = recorded.map { (start: $0.start, end: $0.end) }
        for event in events where event.start < until && event.end.timeIntervalSince(event.start) >= 15 * 60 {
            let length = event.end.timeIntervalSince(event.start)
            let overlap = covered.reduce(0.0) { sum, c in
                sum + max(0, min(c.end, event.end).timeIntervalSince(max(c.start, event.start)))
            }
            // 録音した塊と大きく重なる予定は、その塊に名前を添えてあるので足さない
            guard overlap < length * 0.3 else { continue }
            for piece in subtract((event.start, min(event.end, until)), covered) where piece.1.timeIntervalSince(piece.0) >= 10 * 60 {
                result.append(Activity(start: piece.0, end: piece.1, title: event.title, kind: .plan,
                                       place: event.location, people: Array(event.attendees.prefix(4)), did: [],
                                       event: nil, first: nil, last: nil, count: 0))
                covered.append((piece.0, piece.1))
            }
        }
        for trip in trips {
            for piece in subtract((trip.start, min(trip.end, until)), covered) where piece.1.timeIntervalSince(piece.0) >= 15 * 60 {
                result.append(Activity(start: piece.0, end: piece.1, title: trip.title, kind: .move,
                                       place: nil, people: [], did: [], event: nil, first: nil, last: nil, count: 0))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: - 中身

    private static func makeUnits(_ list: [Conversation]) -> [Unit] {
        var units: [Unit] = []
        for (i, c) in list.enumerated() {
            if let last = units.last?.indices.last, isMinor(list[last]), isMinor(c),
               list[last].place == c.place, c.start.timeIntervalSince(list[last].end) <= 10 * 60 {
                units[units.count - 1].indices.append(i)
            } else {
                units.append(Unit(indices: [i]))
            }
        }
        return units
    }

    /// 見出しの無い短い会話
    private static func isMinor(_ c: Conversation) -> Bool { c.title == nil && c.media == nil }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 言語モデルに渡す1行（例: 「3. 12:05〜12:40｜スタジオ｜田中と｜〔ダンス〕｜振り付けの確認」）
    private static func describe(_ unit: Unit, number: Int, in list: [Conversation]) -> String {
        let convs = unit.indices.map { list[$0] }
        let start = convs[0].start, end = convs.map(\.end).max() ?? convs[0].end
        var parts = ["\(number). " + clock.string(from: start) + "〜" + clock.string(from: end)]
        parts.append(mainPlace(convs) ?? "")
        let who = people(convs)
        parts.append(who.isEmpty ? "" : who.joined(separator: "、") + "と")
        if let event = convs.compactMap(\.event).first { parts.append("〔\(event)〕") }
        if let movement = convs.compactMap(\.movement).first { parts.append("（\(movement)）") }
        let topics = convs.compactMap { c -> String? in
            if let media = c.media { return "［\(media)を流していた］" + (c.program ?? "") }
            return c.title
        }
        if topics.isEmpty {
            let text = convs.flatMap(\.lines).map(\.text).joined(separator: " ")
            parts.append("短い会話\(convs.count > 1 ? " \(convs.count) 件" : ""):「" + String(text.prefix(30)) + "」")
        } else {
            parts.append(topics.prefix(4).joined(separator: "／"))
        }
        return parts.joined(separator: "｜")
    }

    private static func describe(_ event: CalendarLink.Event) -> String {
        clock.string(from: event.start) + "〜" + clock.string(from: event.end) + " " + event.title
            + (event.location.map { "（\($0)）" } ?? "")
    }

    /// 塊の中の会話の見出しと要点（したことをまとめる材料）
    private static func material(_ convs: [Conversation]) -> String {
        var lines: [String] = []
        for c in convs {
            if let media = c.media {
                lines.append("・［\(media)を流していた］" + (c.program ?? ""))
            } else if let title = c.title {
                lines.append("・" + title + (c.points.isEmpty ? "" : "：" + c.points.joined(separator: "／")))
            }
        }
        if lines.isEmpty {
            // 見出しの無い短い会話だけなら、発言を少しだけ
            lines = convs.flatMap(\.lines).prefix(8).map { "・「" + String($0.text.prefix(40)) + "」" }
        }
        return lines.joined(separator: "\n")
    }

    /// 言語モデルが使えないときの区切り方：長く途切れたとき・場所や予定が変わったとき
    private static func simpleBlocks(_ units: [Unit], in list: [Conversation]) -> [(from: Int, to: Int, title: String)] {
        var blocks: [(from: Int, to: Int, title: String)] = []
        for (u, unit) in units.enumerated() {
            let c = list[unit.indices[0]]
            if let last = blocks.last {
                let previous = list[units[last.to].indices.last ?? 0]
                let gap = c.start.timeIntervalSince(previous.end)
                let movedPlace = c.place != nil && previous.place != nil && c.place != previous.place
                let changedEvent = c.event != previous.event
                if gap < longGap, !movedPlace, !changedEvent {
                    blocks[blocks.count - 1].to = u
                    continue
                }
            }
            blocks.append((u, u, ""))
        }
        return blocks
    }

    private static func fallbackTitle(_ convs: [Conversation]) -> String {
        if let event = convs.compactMap(\.event).first { return event }
        if let title = convs.compactMap(\.title).first { return title }
        if let place = mainPlace(convs) { return place + "にいた" }
        return "会話"
    }

    private static func fallbackDid(_ convs: [Conversation]) -> [String] {
        var seen = Set<String>()
        let titles = convs.compactMap { c -> String? in
            if let media = c.media { return "［\(media)］" + (c.program ?? "") }
            return c.title
        }
        return Array(titles.filter { seen.insert($0).inserted }.prefix(5))
    }

    /// いちばん長くいた場所
    private static func mainPlace(_ convs: [Conversation]) -> String? {
        var time: [String: TimeInterval] = [:]
        for c in convs {
            guard let place = c.place else { continue }
            time[place, default: 0] += max(60, c.end.timeIntervalSince(c.start))
        }
        return time.max { $0.value < $1.value }?.key
    }

    private static func people(_ convs: [Conversation]) -> [String] {
        var seen: [String] = []
        for name in convs.flatMap(\.people) where !seen.contains(name) { seen.append(name) }
        // 名前の無い声は数だけにする
        let named = seen.filter { !$0.hasPrefix("人物") }
        let unnamed = seen.count - named.count
        return Array(named.prefix(5)) + (unnamed > 0 ? ["ほか\(unnamed)人"] : [])
    }

    /// 塊といちばん重なる予定（塊か予定の短いほうの半分以上重なるもの）
    private static func bestEvent(for range: (start: Date, end: Date), in events: [CalendarLink.Event]) -> CalendarLink.Event? {
        var best: (event: CalendarLink.Event, overlap: TimeInterval)?
        for event in events {
            let overlap = min(event.end, range.end).timeIntervalSince(max(event.start, range.start))
            let shorter = min(max(range.end.timeIntervalSince(range.start), 5 * 60), event.end.timeIntervalSince(event.start))
            guard overlap > 0, overlap >= shorter * 0.5 else { continue }
            if overlap > best?.overlap ?? 0 { best = (event, overlap) }
        }
        return best?.event
    }

    /// range から covered の時間を除いた残り
    private static func subtract(_ range: (Date, Date), _ covered: [(start: Date, end: Date)]) -> [(Date, Date)] {
        var pieces = [range]
        for c in covered {
            pieces = pieces.flatMap { p -> [(Date, Date)] in
                if c.end <= p.0 || c.start >= p.1 { return [p] }
                var out: [(Date, Date)] = []
                if c.start > p.0 { out.append((p.0, c.start)) }
                if c.end < p.1 { out.append((c.end, p.1)) }
                return out
            }
        }
        return pieces
    }
}

import Foundation
import SwiftUI

/// 会う前の一枚に、行き先と、前にそこへ行った日（2026-11-16。強化案 138）。
/// 行き先は、同じ題の予定の「場所」（カレンダー）。前に行った日は、母艦の場所のページ（行った場所）から。
/// 道のりは「地図アプリで開く」ボタン（押したときだけ、行き先の文字を地図アプリに渡す。アプリからは送らない）。
/// 予定に場所が無ければ、何も出さない。

struct PrepWhere: Equatable {
    var location: String
    /// 場所のページ（行った場所）が見つかったとき
    var placeID: String?
    var lastDay: String?
    var visits: Int
    var mapURL: URL?
}

enum PrepWhereRules {
    /// 地図アプリに渡す住所（行き先の文字。経路は電車・徒歩などを地図アプリが選ぶ）
    static func mapURL(_ location: String) -> URL? {
        guard let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), !encoded.isEmpty else { return nil }
        return URL(string: "http://maps.apple.com/?daddr=" + encoded + "&dirflg=r")
    }

    /// 場所の文字に合う場所のページ。名前（2 文字以上）が場所の文字に含まれるか、場所の文字が名前に含まれ、合うものが 1 つのときだけ
    static func matchPlace(_ location: String, in places: [PlacePage]) -> PlacePage? {
        let key: String = PagesFeeds.nameKey(location)
        guard key.count >= 2 else { return nil }
        var hits: [PlacePage] = []
        for page in places {
            let name: String = PagesFeeds.nameKey(page.name)
            guard name.count >= 2 else { continue }
            if key.contains(name) || name.contains(key) { hits.append(page) }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 同じ題の予定（無ければ最初の予定）の場所と、前に行った日。場所の文字が無ければ nil
    static func make(title: String, locations: [(title: String, location: String?)], places: [PlacePage]) -> PrepWhere? {
        var chosen: String?
        for e in locations where e.title == title {
            if let l = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { chosen = l; break }
        }
        if chosen == nil {
            for e in locations {
                if let l = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { chosen = l; break }
            }
        }
        guard let location = chosen else { return nil }
        let cut: String = location.count > 60 ? String(location.prefix(60)) : location
        let page: PlacePage? = matchPlace(cut, in: places)
        return PrepWhere(location: cut, placeID: page?.id, lastDay: page?.last_day, visits: page?.visits ?? 0, mapURL: mapURL(cut))
    }
}

/// 「次の予定の前に」の行き先の行
struct PrepWhereRows: View {
    @Environment(Pipeline.self) private var pipeline
    let item: PrepItem
    @State private var info: PrepWhere?

    var body: some View {
        Group {
            if let info {
                Label(info.location, systemImage: "mappin.and.ellipse")
                    .font(.callout)
                if let page = PagesBook.shared.places.first(where: { $0.id == info.placeID }), let day = info.lastDay {
                    NavigationLink {
                        PlacePageView(place: page)
                    } label: {
                        Text("前にここへ行った日: " + AppFeeds.monthDay(day) + "（\(info.visits) 回）").font(.callout)
                    }
                }
                if let url = info.mapURL {
                    Link("道のりを地図アプリで開く", destination: url)
                        .font(.callout)
                }
            }
        }
        .task(id: item.id) { info = load() }
    }

    private func load() -> PrepWhere? {
        guard let start = AppFeeds.parseTime(item.start) else { return nil }
        let events = pipeline.calendar.events(from: start.addingTimeInterval(-3600), to: start.addingTimeInterval(3600))
        var rows: [(title: String, location: String?)] = []
        for e in events { rows.append((title: e.title, location: e.location)) }
        return PrepWhereRules.make(title: item.title, locations: rows, places: PagesBook.shared.places)
    }
}

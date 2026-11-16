import CoreLocation
import MapKit
import SwiftUI

/// 地図の画面（2026-11-16。強化案 103）。1 日の道のりと行った所を地図で見て、点を押すと、その時の会話・支払い・写真へ。
/// 道のりは、端末に残っている位置の点（7 日分。大きく動いたときと、着いたときの細かい測り）をつないだもの。
/// 点は、行ったお店の立ち寄り・名前なしの所（30 分以上）・会話の始まり。位置は端末の中だけで使い、どこにも送らない。

// MARK: - 決まり（通信しない・テストする部分）

enum MapRules {
    static let days = 7

    /// offset 日前の 0 時から翌 0 時まで
    static func window(offset: Int, now: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        let start: Date = calendar.startOfDay(for: now)
        let from: Date = calendar.date(byAdding: .day, value: -max(0, offset), to: start) ?? start
        let to: Date = calendar.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86400)
        return (from, to)
    }

    /// 近すぎる点（minGap m 未満）を飛ばして、線を軽くする。最後の点は残す
    static func thinned(_ coords: [CLLocationCoordinate2D], minGap: Double = 25) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        var last: CLLocation?
        for c in coords {
            let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
            if let last, last.distance(from: here) < minGap { continue }
            out.append(c)
            last = here
        }
        if let end = coords.last, let tail = out.last, tail.latitude != end.latitude || tail.longitude != end.longitude {
            out.append(end)
        }
        return out
    }

    /// 全部の点が入る地図の範囲（1 点だけなら、その周り約 500 m）。点が無ければ nil
    static func rect(for coords: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard !coords.isEmpty else { return nil }
        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        let pad: Double = max(rect.width, rect.height) * 0.25
        let minSide: Double = 1000 * MKMapPointsPerMeterAtLatitude(coords[0].latitude)
        let padded: MKMapRect = rect.insetBy(dx: -pad, dy: -pad)
        let w: Double = max(padded.width, minSide)
        let h: Double = max(padded.height, minSide)
        return MKMapRect(x: padded.midX - w / 2, y: padded.midY - h / 2, width: w, height: h)
    }

    /// 時間の窓（その前後 10 分を足す。短い立ち寄りでも前後の会話・支払いが入る）
    static func moment(from: Date, to: Date, margin: TimeInterval = 600) -> (lo: Date, hi: Date) {
        let end: Date = max(from, to)
        return (from.addingTimeInterval(-margin), end.addingTimeInterval(margin))
    }

    /// 窓にかかる日の名前（日をまたぐときは 2 つ）
    static func days(lo: Date, hi: Date) -> [String] {
        var out: [String] = [PCJSON.dayString(lo)]
        let end: String = PCJSON.dayString(hi)
        if !out.contains(end) { out.append(end) }
        return out
    }
}

struct MapMark: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let title: String
    let from: Date
    let to: Date
    let symbol: String
    let tint: Color
}

// MARK: - 地図

struct PlaceMapView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var offset = 0
    @State private var camera: MapCameraPosition = .automatic
    @State private var path: [CLLocationCoordinate2D] = []
    @State private var marks: [MapMark] = []
    @State private var selected: MapMark?

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            Picker("日", selection: $offset) {
                ForEach(0..<MapRules.days, id: \.self) { i in
                    Text(label(i)).tag(i)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            Map(position: $camera) {
                if path.count >= 2 {
                    MapPolyline(coordinates: path).stroke(Color.blue, lineWidth: 3)
                }
                ForEach(marks) { mark in
                    Annotation(mark.title, coordinate: mark.coordinate, anchor: .bottom) {
                        Button {
                            selected = mark
                        } label: {
                            Image(systemName: mark.symbol)
                                .font(.caption)
                                .foregroundStyle(Color.white)
                                .padding(6)
                                .background(mark.tint, in: Circle())
                        }
                    }
                }
            }
            .overlay {
                if path.isEmpty && marks.isEmpty {
                    ContentUnavailableView("この日の位置はありません", systemImage: "map",
                                           description: Text("位置は 7 日分だけ端末に残ります。場所の記録がオフだと残りません。"))
                }
            }
        }
        .navigationTitle("地図")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("placeMap")
        .task(id: offset) { build() }
        .sheet(item: $selected) { mark in
            NavigationStack {
                MomentView(from: mark.from, to: mark.to, title: mark.title)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("閉じる") { selected = nil }
                        }
                    }
            }
        }
    }

    private func label(_ i: Int) -> String {
        if i == 0 { return "今日" }
        if i == 1 { return "昨日" }
        let day: Date = MapRules.window(offset: i, now: .now).from
        return Self.dayLabel.string(from: day)
    }

    /// 選んだ日の道のりと点を作る（描くたびにではなく、日を変えたときだけ）
    private func build() {
        let window = MapRules.window(offset: offset, now: .now)
        var line: [CLLocationCoordinate2D] = []
        for p in pipeline.places.points(from: window.from, to: window.to) {
            line.append(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
        }
        line = MapRules.thinned(line)

        var list: [MapMark] = []
        for v in pipeline.shopVisits.visits where v.arrival >= window.from && v.arrival < window.to {
            let name: String = pipeline.shopVisits.name(for: v) ?? "立ち寄り"
            list.append(MapMark(id: "v-" + v.id, coordinate: CLLocationCoordinate2D(latitude: v.latitude, longitude: v.longitude),
                                title: name, from: v.arrival, to: v.departure ?? v.arrival.addingTimeInterval(1800),
                                symbol: "cart.fill", tint: Color.orange))
        }
        for s in UnnamedStayBook.shared.stays where s.arrival >= window.from && s.arrival < window.to {
            list.append(MapMark(id: "u-" + s.id, coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude),
                                title: "名前なし（\(s.minutes) 分）", from: s.arrival, to: s.departure,
                                symbol: "questionmark", tint: Color.gray))
        }
        let day: String = PCJSON.dayString(window.from)
        for c in pipeline.conversations(on: day) {
            guard let point = pipeline.places.fixPoint(at: c.start) else { continue }
            let title: String = (c.title?.isEmpty == false ? c.title : nil) ?? c.place ?? "会話"
            list.append(MapMark(id: "c-" + String(Int(c.start.timeIntervalSince1970)),
                                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                                title: title, from: c.start, to: c.end, symbol: "bubble.left.fill", tint: Color.blue))
        }
        var all: [CLLocationCoordinate2D] = line
        for m in list { all.append(m.coordinate) }
        path = line
        marks = list
        if let rect = MapRules.rect(for: all) { camera = .rect(rect) }
    }
}

// MARK: - その時（会話・支払い・写真）

struct MomentView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.displayScale) private var displayScale
    let from: Date
    let to: Date
    let title: String
    @State private var talks: [ConversationLog.Conversation] = []
    @State private var pays: [Payment] = []
    @State private var photos: [DayPhoto] = []
    @State private var loaded = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    var body: some View {
        List {
            Section {
                Text(Self.clock.string(from: from) + "〜" + Self.clock.string(from: max(from, to)))
                    .font(.subheadline.monospacedDigit())
            }
            Section("会話") {
                if talks.isEmpty {
                    Text(loaded ? "この時間の会話はありません" : "探しています…").foregroundStyle(.secondary)
                }
                ForEach(talks, id: \.start) { c in
                    NavigationLink {
                        ConversationsView(day: PCJSON.dayString(c.start), range: c.start.addingTimeInterval(-1)...c.start.addingTimeInterval(1))
                            .navigationTitle("会話")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.clock.string(from: c.start) + "　" + ((c.title?.isEmpty == false ? c.title : nil) ?? "（見出しなし）"))
                            if !c.people.isEmpty {
                                Text(c.people.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !pays.isEmpty {
                Section("支払い") {
                    ForEach(pays) { p in
                        LabeledContent(p.shop, value: PagesFeeds.yen(p.amount))
                    }
                    NavigationLink("お金の画面を開く") { MoneyView() }
                }
            }
            if !photos.isEmpty {
                Section("写真") {
                    ConversationPhotoStrip(photos: photos)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("moment")
        .task(id: from) { await load() }
    }

    private func load() async {
        let span = MapRules.moment(from: from, to: to)
        var found: [ConversationLog.Conversation] = []
        for day in MapRules.days(lo: span.lo, hi: span.hi) {
            for c in pipeline.conversations(on: day) where c.end >= span.lo && c.start <= span.hi { found.append(c) }
        }
        found.sort { $0.start < $1.start }
        talks = found
        pays = pipeline.payments.all.filter { $0.time >= span.lo && $0.time <= span.hi }
        let shots: [Date: [DayPhoto]] = await DayPhotos.load([(start: from, end: max(from, to))], scale: displayScale)
        var all: [DayPhoto] = []
        for list in shots.values { all.append(contentsOf: list) }
        photos = all
        loaded = true
    }
}

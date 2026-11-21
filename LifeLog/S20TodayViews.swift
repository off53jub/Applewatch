import MapKit
import Photos
import SwiftUI

// 「今日」の上の段（s20 の 体7〜10・体27。2026-11-21）。大事な 3 つ（録音の状態・今日の三つ・確かめ待ちの数）だけを上に置き、
// ほかのカードは畳む。朝は予定と三つ、夜はふり返りと一言を上に出す。休日は地図・写真・食べた物の顔にする。

/// いちばん上: あいさつ・録音の丸 3 つ・確かめ待ちの数
struct TodayHeroSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var picked: CaptureDot?

    var body: some View {
        let now = Date.now
        let part = DayPart.of(now)
        let waiting = S20Book.shared.waitingCount
        let pause = S20Hold.reason(now: now)
        Section {
            VStack(alignment: .leading, spacing: LL.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.greeting).font(.title3.weight(.bold)).foregroundStyle(LL.text)
                        Text(now.formatted(.dateTime.month().day().weekday(.wide).locale(LL.ja)))
                            .font(.caption).foregroundStyle(LL.dim)
                    }
                    Spacer()
                    if DayOffCache.isOff(pipeline, now) {
                        CertaintyBadge(certainty: .good, text: "休日")
                    }
                }
                HStack(spacing: LL.Space.s) {
                    ForEach(CaptureDot.allCases) { dot in
                        let state = dotState(dot, now: now)
                        Button {
                            picked = dot
                        } label: {
                            CaptureDotView(dot: dot, state: state)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let pause {
                    Label(pause, systemImage: "moon.zzz").font(.caption).foregroundStyle(LL.dim)
                }
                if waiting > 0 {
                    NavigationLink {
                        ReviewDeckView()
                    } label: {
                        HStack {
                            Label("確かめ待ち", systemImage: "hand.raised")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text("\(waiting)").font(.title3.weight(.bold)).monospacedDigit()
                            Text("件・1 枚 3 秒").font(.caption).foregroundStyle(LL.dim)
                        }
                        .padding(LL.Space.m)
                        .background(LL.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: LL.Radius.small))
                        .overlay(RoundedRectangle(cornerRadius: LL.Radius.small).strokeBorder(LL.accent, lineWidth: LL.Stroke.thin))
                    }
                    .accessibilityLabel("確かめ待ち \(waiting) 件。押すと答えるカードを開きます")
                }
            }
            .padding(.vertical, LL.Space.xs)
        }
        .task {
            if part == .morning { await OneYearAgoBook.shared.load(pipeline) }
        }
        .sheet(item: $picked) { dot in
            CaptureDotSheet(dot: dot, state: dotState(dot, now: .now)) { picked = nil }
                .presentationDetents([.medium])
        }
    }

    private func dotState(_ dot: CaptureDot, now: Date) -> CaptureDotState {
        switch dot {
        case .watch:
            let s = pipeline.ledger.lastState
            return CaptureRules.watch(recording: s?.recording ?? (pipeline.isWatchRecording ? true : nil), resting: s?.resting,
                                      held: pipeline.recordingHeld, seen: s?.at, now: now)
        case .phone:
            return CaptureRules.phone(recording: pipeline.isRecording, held: pipeline.recordingHeld)
        case .plaud:
            let item = pipeline.appFeeds.freshness.first { $0.key == "plaud_audio" }
            return CaptureRules.plaud(last: item.flatMap { AppFeeds.parseTime($0.last_ok) }, stale: item?.stale, now: now)
        }
    }
}

/// 丸 1 つ（録っているあいだはゆっくり息をする）
struct CaptureDotView: View {
    let dot: CaptureDot
    let state: CaptureDotState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let color = state.certainty.color
        VStack(spacing: LL.Space.xs) {
            ZStack {
                Circle().fill(color.opacity(0.16)).frame(width: 44, height: 44)
                    .scaleEffect(state == .on && breathe ? 1.12 : 1)
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: LL.Stroke.bold,
                                                                 dash: state == .unknown ? LL.Stroke.dash : []))
                    .frame(width: 44, height: 44)
                Image(systemName: dot.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
            }
            Text(dot.label).font(.caption2.weight(.medium)).foregroundStyle(LL.text)
            Text(stateWord).font(.caption2).foregroundStyle(LL.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LL.Space.s)
        .background(LL.surface2, in: RoundedRectangle(cornerRadius: LL.Radius.small))
        .onAppear {
            guard !reduceMotion, state == .on else { return }
            withAnimation(LL.Motion.breathe) { breathe = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(dot.label) \(stateWord)。押すと理由と直し方")
    }

    private var stateWord: String {
        switch state {
        case .on: "録っている"
        case .resting: "休み"
        case .stopped: "止まっている"
        case .unknown: "分からない"
        }
    }
}

/// 丸を押したとき: 止まった理由と直し方（実機の確かめの ○× も）
struct CaptureDotSheet: View {
    let dot: CaptureDot
    let state: CaptureDotState
    let onClose: () -> Void

    var body: some View {
        let checks = S20Book.shared.deviceChecks?.checks ?? []
        NavigationStack {
            LLList {
                Section {
                    HStack(spacing: LL.Space.m) {
                        CaptureDotView(dot: dot, state: state).frame(width: 96)
                        VStack(alignment: .leading, spacing: LL.Space.xs) {
                            CertaintyBadge(certainty: state.certainty, text: reasonTitle)
                            Text(reason).font(.callout)
                        }
                    }
                    if let fix = CaptureRules.fix(dot, state) {
                        Label(fix, systemImage: "wrench.and.screwdriver").font(.callout).foregroundStyle(LL.accent)
                    }
                } header: {
                    LLHeader(title: "いまの様子", symbol: dot.symbol)
                }
                if !checks.isEmpty {
                    Section {
                        ForEach(checks) { c in
                            HStack {
                                Image(systemName: c.ok == true ? "checkmark.circle.fill" : c.ok == false ? "xmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(c.ok == true ? LL.good : c.ok == false ? LL.danger : LL.dim)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.callout)
                                    if let note = c.note { Text(note).font(.caption).foregroundStyle(LL.dim) }
                                }
                                Spacer()
                                if let day = c.day { Text(AppFeeds.monthDay(day)).font(.caption).foregroundStyle(LL.dim).monospacedDigit() }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        LLHeader(title: "実機の確かめ（家の PC が自動で ○×）", symbol: "checklist")
                    }
                }
            }
            .navigationTitle(dot.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
            }
        }
    }

    private var reasonTitle: String {
        switch state {
        case .on: "録っている"
        case .resting: "休み"
        case .stopped: "止まっている"
        case .unknown: "分からない"
        }
    }

    private var reason: String {
        switch state {
        case .on: "いま録っています。"
        case .resting(let why): why
        case .stopped(let why): why
        case .unknown: "まだ様子が届いていません。"
        }
    }
}

// MARK: - 体9 休日の顔

/// 休日は、地図・写真・食べた物を上に（夜の青のまま）
struct HolidayFaceSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var photos: [UIImage] = []
    @State private var stepsLine: String?

    var body: some View {
        let now = Date.now
        if DayOffCache.isOff(pipeline, now) {
            let start = Calendar.current.startOfDay(for: now)
            let points = pipeline.places.points(from: start, to: now)
            let food = pipeline.shopVisits.visits.filter { $0.arrival >= start }.compactMap { pipeline.shopVisits.name(for: $0) }
            let tags = S20Book.shared.holidayTags[ReviewRules.dayKey(now)] ?? []
            Section {
                if points.count >= 2 {
                    DayTrailMap(points: points).frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: LL.Radius.small))
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                if !photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: LL.Radius.chip))
                            }
                        }
                    }
                    .accessibilityLabel("今日の写真 \(photos.count) 枚")
                }
                if !food.isEmpty {
                    Label(food.prefix(4).joined(separator: "・"), systemImage: "fork.knife").font(.callout)
                }
                if let stepsLine { Label(stepsLine, systemImage: "figure.walk").font(.callout).foregroundStyle(LL.dim) }
                if !tags.isEmpty {
                    TagRow(tags: tags, certainty: .guess)
                    WhyButton(info: WhyInfo(title: "過ごし方の札", reason: "母艦が場所・食べた物・写真・会話から付けた見立て（仮）です。",
                                            evidence: tags, fix: "違っていたら、夜の「一言」で本当の過ごし方を残してください。"))
                }
                if points.count < 2 && photos.isEmpty && food.isEmpty && tags.isEmpty {
                    Text("出かけると、通った道・撮った写真・食べた物がここに並びます。").font(.footnote).foregroundStyle(LL.dim)
                }
            } header: {
                LLHeader(title: "今日の休日", symbol: "beach.umbrella")
            }
            .task {
                stepsLine = await pipeline.health.dayLine(start)
                guard DayPhotos.isShown else { return }
                var out: [UIImage] = []
                for asset in DayPhotos.assets(in: start...now, limit: 8) {
                    if let image = await DayPhotos.image(asset, size: CGSize(width: 160, height: 160), network: false) { out.append(image) }
                }
                photos = out
            }
        }
    }
}

/// 通った道の線
struct DayTrailMap: View {
    let points: [LocationExport.Point]

    var body: some View {
        let path: [CLLocationCoordinate2D] = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(interactionModes: []) {
            MapPolyline(coordinates: path).stroke(LL.accent, lineWidth: 3)
            if let last = path.last {
                Annotation("", coordinate: last) {
                    Circle().fill(LL.accent).frame(width: 10, height: 10).overlay(Circle().stroke(LL.bg, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .accessibilityLabel("今日通った道の地図")
    }
}

// MARK: - 体27 1 年前の今日（朝だけ）

/// 1 年前の今日の写真 1 枚と一言（その日の会話の見出し）。「今日」の上の段が開いたときに 1 日 1 回読む
@MainActor
@Observable
final class OneYearAgoBook {
    static let shared = OneYearAgoBook()
    private(set) var image: UIImage?
    private(set) var line: String?
    private(set) var loadedDay = ""

    static func target(_ now: Date) -> Date { Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now }

    func load(_ pipeline: Pipeline, now: Date = .now) async {
        let today = ReviewRules.dayKey(now)
        guard loadedDay != today else { return }
        loadedDay = today
        let target = Self.target(now)
        line = pipeline.conversations(on: ReviewRules.dayKey(target)).compactMap(\.title).first
        let start = Calendar.current.startOfDay(for: target)
        image = nil
        if DayPhotos.isShown, let asset = DayPhotos.assets(in: start...start.addingTimeInterval(86399), limit: 1).first {
            image = await DayPhotos.image(asset, size: CGSize(width: 200, height: 200), network: false)
        }
    }
}

struct OneYearAgoSection: View {
    var body: some View {
        let book = OneYearAgoBook.shared
        if book.image != nil || book.line != nil {
            Section {
                HStack(spacing: LL.Space.m) {
                    if let image = book.image {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: LL.Radius.small))
                    }
                    VStack(alignment: .leading, spacing: LL.Space.xs) {
                        Text(OneYearAgoBook.target(.now).formatted(.dateTime.year().month().day().locale(LL.ja)))
                            .font(.caption).foregroundStyle(LL.dim)
                        Text(book.line ?? "この日に撮った写真").font(.callout).lineLimit(3)
                    }
                }
                .accessibilityElement(children: .combine)
            } header: {
                LLHeader(title: "1 年前の今日", symbol: "clock.arrow.circlepath")
            }
        }
    }
}

// MARK: - 体7 ほかは畳む

/// 「ほかのカード」を開く・閉じる行
struct TodayMoreRow: View {
    @Binding var open: Bool

    var body: some View {
        Section {
            Button {
                withAnimation(LL.Motion.state) { open.toggle() }
            } label: {
                HStack {
                    Label(open ? "ほかのカードを畳む" : "ほかのカード（予定の前・約束・答え合わせ・返事・下書き）",
                          systemImage: open ? "chevron.up" : "square.stack")
                        .font(.callout)
                    Spacer()
                }
            }
            .tint(LL.accent)
        }
    }
}

/// 休みの日かを 10 分覚えておく（カレンダーを何度も読まないように）
@MainActor
enum DayOffCache {
    private static var cache: [String: (off: Bool, at: Date)] = [:]

    static func isOff(_ pipeline: Pipeline, _ date: Date) -> Bool {
        let key = ReviewRules.dayKey(date)
        if let c = cache[key], Date.now.timeIntervalSince(c.at) < 600 { return c.off }
        let off = pipeline.isDayOff(date)
        cache[key] = (off, .now)
        return off
    }
}

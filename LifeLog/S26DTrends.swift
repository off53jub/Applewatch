import HealthKit
import SwiftUI
import UIKit

// s26 の 絵4（グラフの形をそろえる）と 絵5 のアプリの分（月の 1 枚を絵に。人の名前なし）。A3・S26D。2026-11-25。
// 体（歩数）・声（話した回数）・お金（支払い）・録れた時間・体重を、同じ線・同じ「ふだんの帯」・同じ目盛り（LLTrendChart）で並べる。
// 体重は A1 が読む種類に体重を足して readsVersion を 4 にしたあと（K1）だけ読む。それより前は何も出さない。
// 読むだけで、ヘルスケアにも家の PC にも何も書かない。

// MARK: - 線の種類

enum S26DSeriesKind: String, CaseIterable, Identifiable, Sendable {
    case recorded, talks, steps, money, weight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recorded: "録れた時間"
        case .talks: "声（話した回数）"
        case .steps: "体（歩数）"
        case .money: "お金（支払い）"
        case .weight: "体重"
        }
    }

    var unit: String {
        switch self {
        case .recorded: "時間"
        case .talks: "回"
        case .steps: "歩"
        case .money: "円"
        case .weight: "kg"
        }
    }

    var symbol: String {
        switch self {
        case .recorded: "waveform"
        case .talks: "person.wave.2"
        case .steps: "figure.walk"
        case .money: "yensign.circle"
        case .weight: "scalemass"
        }
    }

    /// 0 から目盛りを取るか（体重だけは値のまわり）
    var zeroBased: Bool { self != .weight }
    var digits: Int { self == .recorded || self == .weight ? 1 : 0 }

    var footnote: String {
        switch self {
        case .recorded: "iPhone と時計で録れた時間の合計。今日はまだ途中です。"
        case .talks: "その日に会話として分かれた数。"
        case .steps: "ヘルスケアの歩数（読む許可があるときだけ）。"
        case .money: "PayPay の明細・カードの利用速報・かざした記録の合計（届いた分だけ）。"
        case .weight: "ヘルスケアのその日の最後の体重。体重計か手で入れた日だけ点が出ます。"
        }
    }
}

struct S26DSeries: Identifiable, Equatable {
    let kind: S26DSeriesKind
    var points: [LLTrendPoint]
    var id: String { kind.rawValue }
}

// MARK: - ヘルスケア（歩数・体重を日ごとに。読むだけ）

enum S26DHealth {
    private static let store = HKHealthStore()

    /// 体重を読んでよいか（A1 が readsVersion を 4 にして許可を聞いたあと）
    @MainActor
    static func weightReady(_ health: HealthLink) -> Bool {
        health.enabled && health.available && UserDefaults.standard.integer(forKey: HealthLink.readsVersionKey) >= 4
    }

    /// 日ごとの値（sum は合計・そうでなければその日の最後の値）
    static func daily(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date, sum: Bool) async -> [Date: Double] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let options: HKStatisticsOptions = sum ? .cumulativeSum : .mostRecent
            let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: predicate,
                                                    options: options, anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, results, _ in
                var out: [Date: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let quantity: HKQuantity? = sum ? stats.sumQuantity() : stats.mostRecentQuantity()
                    if let value = quantity?.doubleValue(for: unit), value.isFinite {
                        out[Calendar.current.startOfDay(for: stats.startDate)] = value
                    }
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }
}

// MARK: - 読み込み

@MainActor
enum S26DTrendLoader {
    /// days 日ぶん（今日を含む）。数の無い種類は返さない
    static func load(_ pipeline: Pipeline, days: Int = S26DTrendRules.days, now: Date = .now) async -> [S26DSeries] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var starts: [Date] = []
        for back in (0..<max(1, days)).reversed() {
            if let d = cal.date(byAdding: .day, value: -back, to: today) { starts.append(d) }
        }
        guard let first = starts.first else { return [] }
        let end = today.addingTimeInterval(86400)

        var recorded: [LLTrendPoint] = []
        var talks: [LLTrendPoint] = []
        var money: [LLTrendPoint] = []
        let payments: [Payment] = pipeline.payments.all.filter { $0.time >= first && $0.time < end }
        for d in starts {
            var seconds = 0.0
            for s in pipeline.ledger.map(for: d).spans where s.kind == .recorded { seconds += s.end.timeIntervalSince(s.start) }
            recorded.append(LLTrendPoint(day: d, value: (seconds / 360).rounded() / 10))
            talks.append(LLTrendPoint(day: d, value: Double(pipeline.conversations(on: ReviewRules.dayKey(d)).count)))
            let next = d.addingTimeInterval(86400)
            var yen = 0
            for p in payments where p.time >= d && p.time < next { yen += max(0, p.amount) }
            money.append(LLTrendPoint(day: d, value: Double(yen)))
            await Task.yield()
        }

        var out: [S26DSeries] = []
        if recorded.contains(where: { $0.value > 0 }) { out.append(S26DSeries(kind: .recorded, points: recorded)) }
        if talks.contains(where: { $0.value > 0 }) { out.append(S26DSeries(kind: .talks, points: talks)) }

        let health = pipeline.health
        if health.enabled && health.available {
            let steps = await S26DHealth.daily(.stepCount, unit: .count(), from: first, to: end, sum: true)
            let points = starts.compactMap { d in steps[d].map { LLTrendPoint(day: d, value: $0.rounded()) } }
            if !points.isEmpty { out.append(S26DSeries(kind: .steps, points: points)) }
        }
        if !payments.isEmpty { out.append(S26DSeries(kind: .money, points: money)) }
        if S26DHealth.weightReady(health) {
            let kg = await S26DHealth.daily(.bodyMass, unit: .gramUnit(with: .kilo), from: first, to: end, sum: false)
            let points = starts.compactMap { d in kg[d].map { LLTrendPoint(day: d, value: ($0 * 10).rounded() / 10) } }
            if !points.isEmpty { out.append(S26DSeries(kind: .weight, points: points)) }
        }
        return out
    }
}

// MARK: - 画面: 同じ形の線

/// 1 つの線（見出し・直近 7 日の平均・グラフ）
struct S26DTrendCard: View {
    let series: S26DSeries

    var body: some View {
        let values = series.points.map(\.value)
        VStack(alignment: .leading, spacing: LL.Space.s) {
            Text(S26DTrendRules.summary(values, unit: series.kind.unit, digits: series.kind.digits))
                .font(LL.TypeScale.note).foregroundStyle(LL.dim)
            LLTrendChart(points: series.points, unit: series.kind.unit, zeroBased: series.kind.zeroBased, digits: series.kind.digits)
        }
        .padding(.vertical, LL.Space.xs)
    }
}

struct S26DTrendsView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var series: [S26DSeries] = []
    @State private var loaded = false

    var body: some View {
        LLList {
            if !loaded {
                Section { HStack { ProgressView(); Text("並べています…").foregroundStyle(LL.dim) } }
            } else if series.isEmpty {
                Section { LLEmpty(title: "まだ線にできる数がありません", symbol: "chart.xyaxis.line",
                                  detail: "録音・会話・支払い・ヘルスケアの数がたまると、ここに同じ形の線で並びます。") }
            }
            ForEach(series) { s in
                Section {
                    S26DTrendCard(series: s)
                } header: {
                    LLHeader(title: s.kind.title, symbol: s.kind.symbol, trailing: s.kind.unit)
                } footer: {
                    Text(s.kind.footnote)
                }
            }
            if loaded && !series.isEmpty {
                Section {
                    Text("線は 1 日 1 点。灰色の帯は、この 14 日の「ふだん」（真ん中の半分）です。目盛りは数なら 0 から、体重は値のまわりだけ。")
                        .font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            }
        }
        .navigationTitle("同じ形の線（14 日）")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s26dTrends")
        .task {
            series = await S26DTrendLoader.load(pipeline)
            loaded = true
        }
    }
}

// MARK: - 絵5 月の 1 枚（人の名前なし・人に見せられる絵）

struct S26DTile: Identifiable, Equatable {
    let title: String
    let value: String
    let unit: String
    var id: String { title }
}

enum S26DMonthRules {
    /// 「2026 年 11 月」
    static func title(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0) 年 \(c.month ?? 0) 月"
    }

    /// 1 枚に載せる数（名前・お金・場所の名前は載せない）
    static func tiles(recordedHours: Double, talks: Int, stepsPerDay: Double?, ramen: Int) -> [S26DTile] {
        var out: [S26DTile] = [
            S26DTile(title: "録れた時間", value: S26DTrendRules.number(recordedHours, digits: 1), unit: "時間"),
            S26DTile(title: "会話", value: S26DTrendRules.number(Double(talks), digits: 0), unit: "回"),
        ]
        if let stepsPerDay { out.append(S26DTile(title: "歩数（1 日）", value: S26DTrendRules.number(stepsPerDay, digits: 0), unit: "歩")) }
        out.append(S26DTile(title: "ラーメン（仮）", value: "\(max(0, ramen))", unit: "杯"))
        return out
    }
}

/// 絵にする 1 枚（暗い画面の色で描く）
struct S26DMonthCard: View {
    let title: String
    let tiles: [S26DTile]
    let line: [LLTrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.m) {
            Text(title).font(LL.TypeScale.screenTitle).foregroundStyle(LL.text)
            // 絵にするとき（ImageRenderer）にも描けるよう、Lazy でない Grid で 2 列に
            Grid(horizontalSpacing: LL.Space.s, verticalSpacing: LL.Space.s) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { i in
                    GridRow {
                        tile(tiles[i])
                        if i + 1 < tiles.count {
                            tile(tiles[i + 1])
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            if line.count > 1 {
                Text("録れた時間（日ごと）").font(LL.TypeScale.note).foregroundStyle(LL.dim)
                LLTrendChart(points: line, unit: "時間", digits: 1)
            }
            HStack {
                Spacer()
                Text("LifeLog").font(LL.TypeScale.tag).foregroundStyle(LL.dim)
            }
        }
        .padding(LL.Space.xl)
        .background(LL.surface, in: RoundedRectangle(cornerRadius: LL.Radius.big))
    }

    private func tile(_ t: S26DTile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t.title).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(t.value).font(LL.TypeScale.number).foregroundStyle(LL.text)
                Text(t.unit).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LL.Space.m)
        .background(LL.surface2, in: RoundedRectangle(cornerRadius: LL.Radius.small))
    }
}

struct S26DMonthSheetView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var tiles: [S26DTile] = []
    @State private var line: [LLTrendPoint] = []
    @State private var image: Image?
    @State private var loaded = false

    private var title: String { S26DMonthRules.title(.now) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LL.Space.l) {
                if loaded {
                    S26DMonthCard(title: title, tiles: tiles, line: line)
                    Text("人の名前・お金・お店や場所の名前は載せていません。ラーメンはお店の名前からの見立て（仮）です。")
                        .font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    if let image {
                        // 送るかどうかは本人が押して決める（外へ送る所は本人が押す形）
                        ShareLink(item: image, preview: SharePreview(title, image: image)) {
                            Label("絵にして共有", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(LLPillButtonStyle(filled: true))
                    }
                } else {
                    HStack { ProgressView(); Text("数えています…").foregroundStyle(LL.dim) }
                }
            }
            .padding(LL.Space.l)
        }
        .llScreen()
        .navigationTitle("月の 1 枚")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s26dMonth")
        .task { await load() }
    }

    private func load() async {
        let cal = Calendar.current
        let month = StoryRules.range(month: true, containing: .now)
        let days = max(1, (cal.dateComponents([.day], from: month.start, to: cal.startOfDay(for: .now)).day ?? 0) + 1)
        let series = await S26DTrendLoader.load(pipeline, days: days)
        let rec = series.first { $0.kind == .recorded }?.points ?? []
        let talks = series.first { $0.kind == .talks }?.points ?? []
        let steps = series.first { $0.kind == .steps }?.points.map(\.value) ?? []
        let ramen = pipeline.shopVisits.visits.filter {
            $0.arrival >= month.start && $0.arrival < month.end && StoryRules.isRamen(pipeline.shopVisits.name(for: $0) ?? "")
        }.count
        tiles = S26DMonthRules.tiles(recordedHours: rec.reduce(0) { $0 + $1.value },
                                     talks: Int(talks.reduce(0) { $0 + $1.value }),
                                     stepsPerDay: S26DTrendRules.mean(steps), ramen: ramen)
        line = rec
        loaded = true
        image = render()
    }

    /// 1 枚を絵に（暗い画面の色・3 倍の細かさ）
    private func render() -> Image? {
        let card = S26DMonthCard(title: title, tiles: tiles, line: line)
            .frame(width: 390)
            .padding(LL.Space.l)
            .background(Color(llHex: 0x0B1220))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let ui = renderer.uiImage else { return nil }
        return Image(uiImage: ui)
    }
}

// MARK: - ふり返りの入口

/// 「ふり返り」に置く 2 つの入口（LookBackViews.swift から 1 行で読む）
struct S26DLookBackLinks: View {
    var body: some View {
        Section {
            NavigationLink {
                S26DTrendsView()
            } label: {
                Label("同じ形の線（体・声・お金・録れた時間）", systemImage: "chart.xyaxis.line")
            }
            NavigationLink {
                S26DMonthSheetView()
            } label: {
                Label("月の 1 枚（人の名前なし）", systemImage: "photo.on.rectangle")
            }
        } header: {
            LLHeader(title: "線と 1 枚", symbol: "chart.xyaxis.line")
        }
    }
}

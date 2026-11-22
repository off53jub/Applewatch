import Charts
import SwiftUI
import UIKit
import WebKit

// ふり返り（s20 の 体3・体23〜26・次1・次20。2026-11-21）

/// 「ふり返り」のいちばん上: 数を小さなグラフで（体3）と、物語・雑誌のページ・面談の 1 枚・検品表の入口
struct S20LookBackSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var recorded: [MiniPoint] = []
    @State private var talks: [MiniPoint] = []
    @State private var ramenMonth = 0

    var body: some View {
        let lastHoliday = Self.lastHoliday(pipeline)
        Section {
            HStack(spacing: LL.Space.s) {
                StatTile(title: "録音・7 日", value: MiniBars.short(recorded.reduce(0) { $0 + $1.value }), unit: "時間",
                         points: recorded)
                StatTile(title: "会話・7 日", value: "\(Int(talks.reduce(0) { $0 + $1.value }))", unit: "回", points: talks)
                StatTile(title: "ラーメン・今月", value: "\(ramenMonth)", unit: "杯", certainty: .guess)
            }
            .fixedSize(horizontal: false, vertical: true)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
            LLHeader(title: "数で見る", symbol: "chart.bar")
        } footer: {
            Text("ラーメンは立ち寄ったお店の名前からの見立て（仮）です。正しい杯数は母艦が数えます。")
        }
        .task { await load() }
        Section {
            if let lastHoliday {
                NavigationLink {
                    HolidayMagazineView(day: lastHoliday)
                } label: {
                    Label("休日のページ（" + lastHoliday.formatted(.dateTime.month().day().weekday().locale(LL.ja)) + "）", systemImage: "book.pages")
                }
            }
            NavigationLink { StoryView(month: true) } label: { Label("今月の物語", systemImage: "text.book.closed") }
            NavigationLink { StoryView(month: false) } label: { Label("今年の物語", systemImage: "books.vertical") }
            NavigationLink { InterviewSheetView() } label: { Label("面談の 1 枚（A4）", systemImage: "doc.richtext") }
            NavigationLink { FeatureReportView() } label: { Label("検品表（通信簿）", systemImage: "checklist.checked") }
        } header: {
            LLHeader(title: "ふり返りの本", symbol: "book")
        }
    }

    /// 直近の休日（今日を含む 14 日）
    static func lastHoliday(_ pipeline: Pipeline, now: Date = .now) -> Date? {
        for back in 0..<14 {
            guard let d = Calendar.current.date(byAdding: .day, value: -back, to: now) else { continue }
            if DayOffCache.isOff(pipeline, d) { return Calendar.current.startOfDay(for: d) }
        }
        return nil
    }

    private func load() async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var rec: [MiniPoint] = []
        var tk: [MiniPoint] = []
        for back in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let spans = pipeline.ledger.map(for: d).spans
            var seconds = 0.0
            for s in spans where s.kind == .recorded { seconds += s.end.timeIntervalSince(s.start) }
            let label = d.formatted(.dateTime.weekday(.narrow).locale(LL.ja))
            rec.append(MiniPoint(id: 6 - back, label: label, value: (seconds / 360).rounded() / 10))
            tk.append(MiniPoint(id: 6 - back, label: label, value: Double(pipeline.conversations(on: ReviewRules.dayKey(d)).count)))
            await Task.yield()
        }
        recorded = rec
        talks = tk
        let month = StoryRules.range(month: true, containing: .now)
        ramenMonth = pipeline.shopVisits.visits.filter {
            $0.arrival >= month.start && $0.arrival < month.end && StoryRules.isRamen(pipeline.shopVisits.name(for: $0) ?? "")
        }.count
    }
}

// MARK: - 体23 休日のまとめを雑誌の 1 ページのように

struct HolidayMagazineView: View {
    @Environment(Pipeline.self) private var pipeline
    let day: Date
    @State private var photos: [UIImage] = []
    @State private var health: String?

    var body: some View {
        let end = min(day.addingTimeInterval(86400), .now)
        let key = ReviewRules.dayKey(day)
        let points = pipeline.places.points(from: day, to: end)
        let food = pipeline.shopVisits.visits.filter { $0.arrival >= day && $0.arrival < end }
            .compactMap { pipeline.shopVisits.name(for: $0) }
        let notes = HolidayBook.shared.notes.filter { $0.day == key }
        let tags = S20Book.shared.holidayTags[key] ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: LL.Space.l) {
                VStack(alignment: .leading, spacing: LL.Space.xs) {
                    Text(day.formatted(.dateTime.weekday(.wide).locale(LL.ja))).font(.caption.weight(.semibold)).foregroundStyle(LL.accent)
                        .textCase(.uppercase)
                    Text(day.formatted(.dateTime.month().day().locale(LL.ja))).font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(LL.text)
                    if let best = notes.first(where: { $0.kind == "best" }) {
                        Text("「" + best.text + "」").font(.title3.weight(.semibold)).foregroundStyle(LL.text)
                    }
                    if !tags.isEmpty { TagRow(tags: tags, certainty: .guess) }
                }
                if points.count >= 2 {
                    DayTrailMap(points: points).frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: LL.Radius.card))
                }
                if !photos.isEmpty {
                    let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { i, image in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(minWidth: 0, maxWidth: .infinity).frame(height: i == 0 ? 160 : 100).clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: LL.Radius.card))
                }
                if !food.isEmpty {
                    LLCard {
                        LLHeader(title: "食べた物", symbol: "fork.knife")
                        ForEach(Array(food.enumerated()), id: \.offset) { _, f in
                            Label(f, systemImage: TagIcons.symbol(for: f) == TagIcons.fallback ? "fork.knife" : TagIcons.symbol(for: f))
                                .font(.callout)
                        }
                    }
                }
                if !notes.isEmpty {
                    LLCard {
                        LLHeader(title: "一言", symbol: "quote.bubble")
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.text).font(.callout)
                                Text(n.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(LL.dim)
                            }
                        }
                    }
                }
                if let health {
                    Label(health, systemImage: "figure.walk").font(.callout).foregroundStyle(LL.dim)
                }
                if points.count < 2 && photos.isEmpty && food.isEmpty && notes.isEmpty {
                    LLEmpty(title: "この日のページはまだ白紙です", symbol: "book.pages",
                            detail: "出かけて場所・写真・食べた物・一言が残ると、ページになります。")
                }
            }
            .padding(LL.Space.l)
        }
        .llScreen()
        .navigationTitle("休日のページ")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("holidayMagazine")
        .task {
            health = await pipeline.health.dayLine(day)
            guard DayPhotos.isShown else { return }
            var out: [UIImage] = []
            for asset in DayPhotos.assets(in: day...end, limit: 7) {
                if let image = await DayPhotos.image(asset, size: CGSize(width: 400, height: 400), network: false) { out.append(image) }
            }
            photos = out
        }
    }
}

// MARK: - 体24 月と年のふり返りを物語に

struct StoryView: View {
    @Environment(Pipeline.self) private var pipeline
    let month: Bool
    @State private var pages: [(title: String, value: String, note: String)] = []
    @State private var loading = true

    var body: some View {
        let range = StoryRules.range(month: month, containing: .now)
        ScrollView {
            LazyVStack(spacing: LL.Space.l) {
                VStack(spacing: LL.Space.s) {
                    Text(month ? range.start.formatted(.dateTime.year().month(.wide).locale(LL.ja)) : range.start.formatted(.dateTime.year().locale(LL.ja)))
                        .font(.caption.weight(.semibold)).foregroundStyle(LL.accent)
                    Text(month ? "今月の物語" : "今年の物語").font(.largeTitle.weight(.heavy)).foregroundStyle(LL.text)
                    Text("下へめくって進みます").font(.caption).foregroundStyle(LL.dim)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                if loading {
                    // 骨組み（2026-11-22。s22 の 見14）
                    LLSkeletonRows(count: 3).padding(.horizontal, LL.Space.l)
                } else if pages.isEmpty {
                    LLEmpty(title: "まだ物語になるほど記録がありません", symbol: "text.book.closed")
                }
                ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                    VStack(spacing: LL.Space.s) {
                        Text(page.title).font(.headline).foregroundStyle(LL.dim)
                        Text(LLNumber.display(page.value)).font(.system(size: 64, weight: .heavy, design: .rounded)).monospacedDigit()
                            .foregroundStyle(i == 0 ? LL.accent : LL.text)
                        Text(page.note).font(.callout).foregroundStyle(LL.dim)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(LL.surface, in: RoundedRectangle(cornerRadius: LL.Radius.big))
                    .overlay(RoundedRectangle(cornerRadius: LL.Radius.big).strokeBorder(LL.line, lineWidth: LL.Stroke.hair))
                    .scrollTransition { content, phase in
                        content.opacity(phase.isIdentity ? 1 : 0.4).scaleEffect(phase.isIdentity ? 1 : 0.94)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(LL.Space.l)
        }
        .llScreen()
        .navigationTitle(month ? "今月" : "今年")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen(month ? "storyMonth" : "storyYear")
        .task { await load(range) }
    }

    private func load(_ range: (start: Date, end: Date)) async {
        let startKey = ReviewRules.dayKey(range.start)
        let endKey = ReviewRules.dayKey(range.end)
        var conversations = 0, hours = 0.0, holidays = 0
        var people = Set<String>(), places = Set<String>()
        let named = Set(pipeline.people.filter { $0.isNamed && !$0.isSelf }.map(\.id))
        for day in pipeline.recordedDays() where day >= startKey && day < endKey {
            let list = pipeline.conversations(on: day)
            conversations += list.count
            for c in list {
                hours += c.end.timeIntervalSince(c.start) / 3600
                if let p = c.place { places.insert(p) }
                for id in c.lines.compactMap(\.speakerID) where named.contains(id) { people.insert(id) }
            }
            await Task.yield()
        }
        var d = range.start
        while d < min(range.end, .now) {
            if DayOffCache.isOff(pipeline, d) { holidays += 1 }
            d = d.addingTimeInterval(86400)
        }
        let ramen = pipeline.shopVisits.visits.filter {
            $0.arrival >= range.start && $0.arrival < range.end && StoryRules.isRamen(pipeline.shopVisits.name(for: $0) ?? "")
        }.count
        pages = StoryRules.pages(conversations: conversations, people: people.count, places: places.count, ramen: ramen,
                                 holidays: holidays, recordedHours: Int(hours))
        loading = false
    }
}

// MARK: - 体25 面談の 1 枚（次20 の html を A4 で印刷・共有）

struct InterviewSheetView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let file = S20Book.shared.interviewFile
        Group {
            if let file {
                HTMLFileView(url: file)
                    .clipShape(RoundedRectangle(cornerRadius: LL.Radius.small))
                    .padding(LL.Space.m)
                    .llShadow()
                    .llScreen()
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: file) { Label("共有", systemImage: "square.and.arrow.up") }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("印刷", systemImage: "printer") { Self.printA4(file) }
                        }
                    }
            } else {
                LLList {
                    Section {
                        LLEmpty(title: "面談の 1 枚はまだ届いていません", symbol: "doc.richtext",
                                detail: "母艦が実績帳から四半期の成果を A4 1 枚にすると、家の PC を通してここに届きます。")
                    }
                }
            }
        }
        .navigationTitle("面談の 1 枚")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("interviewSheet")
        .task { await S20Book.shared.refresh(pipeline.homePC) }
    }

    /// A4 で印刷する（共有シートの「プリント」と同じ）
    static func printA4(_ url: URL) {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "面談の1枚"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
        controller.present(animated: true)
    }
}

struct HTMLFileView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        // 紙の 1 枚として白い地に出す（中の html は印刷用の黒い文字）
        let view = WKWebView()
        view.isOpaque = true
        view.backgroundColor = .white
        view.scrollView.backgroundColor = .white
        // 文として読み込む（ファイルの道で読むと、シミュレーターで白いままのことがあった。2026-11-21）
        if let html = try? String(contentsOf: url, encoding: .utf8) {
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

// MARK: - 次1・体26 検品表を通信簿に

struct FeatureReportView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var filter = "all"

    var body: some View {
        let book = S20Book.shared
        let items = book.features?.items ?? []
        let shown = items.filter { filter == "all" || $0.group == filter || (filter == "stop" && $0.suggest == "stop") }
        LLList {
            Section {
                HStack(spacing: LL.Space.s) {
                    ForEach(["A", "B", "C", "×"], id: \.self) { g in
                        let n = items.filter { FeatureCheckRules.grade($0) == g }.count
                        VStack(spacing: 2) {
                            Text(g).font(.title2.weight(.heavy))
                                .foregroundStyle(g == "×" ? LL.danger : g == "C" ? LL.warn : g == "A" ? LL.good : LL.text)
                            Text("\(n)").font(.caption).foregroundStyle(LL.dim).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LL.Space.s)
                        .background(LL.surface2, in: RoundedRectangle(cornerRadius: LL.Radius.small))
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                Picker("見る", selection: $filter) {
                    Text("全部").tag("all")
                    Text("s18").tag("s18")
                    Text("s19").tag("s19")
                    Text("s20").tag("s20")
                    Text("候補").tag("stop")
                }
                .pickerStyle(.segmented)
            } header: {
                LLHeader(title: "通信簿（週 1 回・母艦）", symbol: "checklist.checked",
                         trailing: book.features?.generated_at.map { String($0.prefix(10)) })
            } footer: {
                Text("A よく使う・B ときどき・C 2 週間ほぼ使っていない・× 動いていない。「止める」と答えても、すぐには止めません（母艦が週 1 回まとめます）。")
            }
            if items.isEmpty {
                Section {
                    LLEmpty(title: "検品表はまだ届いていません", symbol: "checklist",
                            detail: "母艦が 134 個の働きを週 1 回確かめると、家の PC を通してここに届きます。")
                }
            }
            Section {
                ForEach(shown) { item in
                    FeatureRow(item: item, answer: book.featureAnswers[item.id]) { keep in book.answerFeature(item.id, keep: keep) }
                }
            }
        }
        .navigationTitle("検品表")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("featureReport")
        .refreshable { await book.refresh(pipeline.homePC, force: true) }
    }
}

private struct FeatureRow: View {
    let item: FeatureCheckFeed.Item
    let answer: Bool?
    let onAnswer: (Bool) -> Void

    var body: some View {
        let grade = FeatureCheckRules.grade(item)
        let c = FeatureCheckRules.certainty(item)
        HStack(spacing: LL.Space.m) {
            Text(grade).font(.headline.weight(.heavy)).frame(width: 30, height: 30)
                .foregroundStyle(c == .fact ? LL.text : c.color)
                .background(c.color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout).lineLimit(2)
                HStack(spacing: LL.Space.s) {
                    if let g = item.group { Text(g) }
                    Text("使った \(item.used ?? 0) 回").monospacedDigit()
                    if let hit = item.hit { Text("当たり \(Int((hit * 100).rounded()))%").monospacedDigit() }
                    if item.suggest == "stop" { Text("止める候補").foregroundStyle(LL.warn) }
                }
                .font(.caption2).foregroundStyle(LL.dim)
            }
            Spacer()
            if let answer {
                Text(answer ? "続ける" : "止める").font(.caption.weight(.semibold)).foregroundStyle(answer ? LL.good : LL.warn)
            } else {
                Menu {
                    Button("続ける", systemImage: "checkmark") { onAnswer(true) }
                    Button("止める", systemImage: "pause") { onAnswer(false) }
                } label: {
                    Text("答える").font(.caption.weight(.semibold))
                }
                .tint(LL.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

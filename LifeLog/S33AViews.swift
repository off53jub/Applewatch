import SwiftUI

// s33（2026-11-27）アプリ担当 S33A の画面。決まりは S33ARules.swift、動きは S33ABook.swift。
// - 強15 どこ？（S33AWhereView）: 設定のいちばん上（S33ASettingsTopSection）と、今日タブの右上（S33AWhereButton）から
// - 強5・強16・強6 設定の奥（S33ADeepView）: 畳む候補・畳んだもの・今日の並び・問いのふた・家の PC の棚（副業の稼働・経費の候補・
//   仮説ボード・定期の仕事の棚卸し・効いたか・C の空き）
// - 強27 くわしい設定の「時計」（S33AWatchSection）
// - K33-1 の画面: 今日の「止まっているもの」1 行（S33ATodaySection）・ラーメンの 1 押し（S33ARamenSection）・操作待ちに足す行
//   （S33AWaitingRows）・ふり返りの「暮らし」（S33ALifeSection）・仕事タブの話し方と出す前のチェック（S33AWorkSection）・
//   人のページの話のネタ（S33ASmallTalkSection）・「寝かせた N 件」（S33ASleptRow）
// どれも中身が無ければ出さない。新しい知らせ・問いは足さない。職場の中身は時計・ウィジェット・通知に出さない。

extension Notification.Name {
    /// どこ？で別のタブ・画面へ行くとき、開いている設定のシートを閉じる（SettingsGear が受ける）
    static let s33aLeave = Notification.Name("s33a.leave")
}

// MARK: - 強15 どこ？

/// 今日タブの右上の「どこ？」
struct S33AWhereButton: View {
    @State private var show = false

    var body: some View {
        Button("どこ？", systemImage: "magnifyingglass") {
            show = true
            Tally.add("s33a.where.today")
        }
        .accessibilityLabel("どこ？（画面と機能を探す）")
        .sheet(isPresented: $show) {
            NavigationStack {
                S33AWhereView { show = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("閉じる") { show = false } }
                    }
            }
            .llRoot()
        }
    }
}

/// 設定のいちばん上の「どこ？」
struct S33ASettingsTopSection: View {
    var body: some View {
        Section {
            NavigationLink {
                S33AWhereView(onLeave: nil)
            } label: {
                Label("どこ？（画面と機能を探す）", systemImage: "magnifyingglass")
            }
        }
    }
}

struct S33AWhereView: View {
    @Environment(Pipeline.self) private var pipeline
    /// 別のタブ・画面へ行くときに、この画面を出しているシートを閉じる（nil なら設定のシートを閉じる知らせだけ）
    let onLeave: (() -> Void)?
    @State private var query = ""

    var body: some View {
        let hits = S33AWhere.search(query)
        LLList {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(S33AWhere.toc()) { group in
                    Section {
                        ForEach(group.entries) { row($0) }
                    } header: {
                        LLHeader(title: group.place, symbol: "list.bullet")
                    }
                }
            } else if hits.isEmpty {
                Section {
                    LLEmpty(title: "見つかりませんでした", symbol: "magnifyingglass",
                            detail: "ほかの言い方でも探せます（例: 体重・ラーメン・用語・操作待ち・経費）。")
                }
            } else {
                Section {
                    ForEach(hits) { row($0) }
                } header: {
                    Text("\(hits.count) 件")
                }
            }
        }
        .searchable(text: $query, prompt: "画面や機能の名前（例: 仕事のまとめ・声の名前）")
        .navigationTitle("どこ？")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s33aWhere")
    }

    @ViewBuilder
    private func row(_ e: S33AWhereEntry) -> some View {
        if case .view(let key) = e.target {
            NavigationLink {
                S33AWhereDestination(key: key)
                    .onAppear { Tally.add("s33a.where.go") }
            } label: {
                LLRow(title: e.name, detail: e.place)
            }
        } else {
            Button {
                go(e.target)
            } label: {
                HStack {
                    LLRow(title: e.name, detail: e.place)
                    Spacer()
                    Image(systemName: "arrow.up.forward").foregroundStyle(LL.dim)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func go(_ target: S33AWhereTarget) {
        Tally.add("s33a.where.go")
        NotificationCenter.default.post(name: .s33aLeave, object: nil)
        onLeave?()
        let p = pipeline
        // シートが閉じてから開く（シートの上にシートは出せない）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            switch target {
            case .tab(let t):
                p.openRoute(.tab(t))
            case .records(let page):
                if page == S30TTabs.RecordsPage.lookBack.rawValue {
                    p.openRoute(.tab(.lookBack))
                } else {
                    UserDefaults.standard.set(page, forKey: S30TTabs.recordsPageKey)
                    p.openRoute(.tab(.records))
                }
            case .screen(let raw):
                if let s = NoticeScreen(rawValue: raw) { p.openRoute(.screen(s)) }
            case .link(let text):
                if let url = URL(string: text), let route = NoticeRoute.route(url: url) { p.openRoute(route) }
            case .view:
                break
            }
        }
    }
}

/// どこ？から押して開く画面
struct S33AWhereDestination: View {
    let key: String

    var body: some View {
        switch key {
        case "s26uWaiting": S26UWaitingView()
        case "workDigest": WorkDigestListView()
        case "naming": S29NPileView()
        case "vocabulary": VocabularyView()
        case "misheard": MisheardView()
        case "ask": AskView()
        case "search": UnifiedSearchView()
        case "shopVisits": ShopVisitsView()
        case "s33Life": S33ALifeView()
        case "speaking": SpeakingView()
        case "facts": FactsView()
        case "trends": S26DTrendsView()
        case "knowMe": KnowMeView()
        case "briefCompare": BriefCompareView()
        case "listenQuality": ListenQualityView()
        case "recordingMap": RecordingMapView()
        case "accuracy": AccuracyView()
        case "hypotheses": HypothesesView()
        case "s26uMachine": S26UMachineView()
        case "detailedSettings": DetailedSettingsView()
        case "watchUpdate": S22WatchUpdateView()
        case "dataEntry": S26ASettingsView()
        case "s33Deep": S33ADeepView()
        case "s34Fixed": S34AFixedView()  // s34（S34AViews.swift）
        case "s34WorkPhoto": S34APhotoSettingsView()
        case "s36Prompt", "s36Numbers", "s36AskWork", "s36Stop", "s36Tabs": S36AWhereScreen(key: key)  // s36（S36AViews.swift）
        default: LLList { Section { LLEmpty(title: "この画面はまだ開けません", symbol: "questionmark") } }
        }
    }
}

// MARK: - K33-1 今日: 止まっているもの

struct S33ATodaySection: View {
    var body: some View {
        let book = S33ABook.shared
        if book.offered, let feed = book.feed, let line = S33ARules.stoppedLine(feed.stopped) {
            Section {
                NavigationLink {
                    S33AStoppedView(list: feed.stopped)
                } label: {
                    LLRow(title: line, role: .wait)
                }
            }
        }
    }
}

struct S33AStoppedView: View {
    let list: [S33AStopped]

    var body: some View {
        LLList {
            Section {
                ForEach(Array(list.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: LL.Space.xs) {
                        Text(s.source).font(LL.TypeScale.cardTitle)
                        if let missing = s.missing, !missing.isEmpty {
                            Text("欠けているもの: " + missing).font(LL.TypeScale.detail)
                        }
                        if let last = s.lastOK, !last.isEmpty {
                            Text("最後に中身があった日: " + last).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                        }
                        if let why = s.why, !why.isEmpty { Text(why).font(LL.TypeScale.note).foregroundStyle(LL.dim) }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("家の PC の見張りが「あるはずの中身」が欠けた日を数えたものです。直す手順は、本人の操作待ちに届きます。")
            }
        }
        .navigationTitle("止まっているもの")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s33aStopped")
    }
}

// MARK: - 強22 ラーメンの 1 押し

struct S33ARamenSection: View {
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        let book = S33ABook.shared
        if book.offered {
            Section {
                Button {
                    guard !busy else { return }
                    busy = true
                    Task {
                        let ok = await book.markRamen()
                        busy = false
                        note = ok ? "印を付けました（" + Date.now.formatted(date: .omitted, time: .shortened) + "）" : "いまは付けられませんでした"
                        if ok { LLHaptic.done.play() }
                    }
                } label: {
                    Label(book.ramenRecently() ? "もう 1 杯（印を送る）" : "ラーメン食べた（印を送る）", systemImage: "fork.knife")
                }
                .disabled(busy)
                if let note { Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim) }
                if let line = S33ARules.ramenLine(book.feed?.ramen, marks: book.ramenThisYear) {
                    Text(line).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            } header: {
                LLHeader(title: "ラーメン", symbol: "fork.knife")
            } footer: {
                Text("押すかどうかは自由です。押した時刻と、そのときの場所（分からなければ空）だけを家の PC に送ります。")
            }
        }
    }
}

// MARK: - K33-1 操作待ちに足す行（S26UWaitingView の中）

struct S33AWaitingRows: View {
    /// 今ある操作待ちの id（同じものは出さない）
    let known: Set<String>

    var body: some View {
        ForEach(S33ABook.shared.extraWaiting(known: known)) { item in
            Section {
                if let how = item.how, !how.isEmpty { Text(how).font(LL.TypeScale.detail) }
                if let since = item.since, !since.isEmpty {
                    Text("いつから: " + since).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            } header: {
                HStack(spacing: LL.Space.xs) {
                    LLToneMark(tone: .act)
                    Text(item.title).font(LL.TypeScale.section).foregroundStyle(LL.text).textCase(nil)
                }
            }
        }
    }
}

extension S33ABook {
    /// K33-1 の操作待ちのうち、今ある操作待ちに無いもの
    func extraWaiting(known: Set<String>) -> [S33AWaiting] {
        guard offered, let feed else { return [] }
        return feed.waiting.filter { !known.contains($0.id) }
    }
}

// MARK: - 記録のふり返りの「暮らし」

struct S33ALifeSection: View {
    var body: some View {
        let book = S33ABook.shared
        let month = Calendar.current.component(.month, from: .now)
        if book.offered, let feed = book.feed, feed.hasLife(month: month) {
            Section {
                NavigationLink {
                    S33ALifeView()
                } label: {
                    LLRow(title: "暮らし", detail: S33ALifeView.summary(feed, month: month), symbol: "house")
                }
            } header: {
                Text("暮らし")
            }
        }
    }
}

struct S33ALifeView: View {
    static func summary(_ feed: S33AFeed, month: Int) -> String {
        var parts: [String] = []
        if !feed.car.isEmpty { parts.append("車 \(feed.car.count) 回") }
        if month == 12, feed.year != nil { parts.append("年のまとめ") }
        if !feed.wishes.isEmpty { parts.append("欲しい物の候補 \(feed.wishes.count)") }
        if let k = feed.promisesKept, let kept = k.a { parts.append("約束の棚 \(kept)") }
        if let a = feed.askCheck, let s = a.a, let t = a.b { parts.append("答え合わせ \(s)/\(t)") }
        return parts.joined(separator: "・")
    }

    var body: some View {
        let book = S33ABook.shared
        let month = Calendar.current.component(.month, from: .now)
        LLList {
            if let feed = book.feed {
                if !feed.car.isEmpty {
                    Section {
                        ForEach(Array(feed.car.enumerated()), id: \.offset) { _, c in
                            LLRow(title: carTitle(c), detail: carDetail(c), value: S33ARules.yenText(c.yen))
                        }
                    } header: {
                        LLHeader(title: "車", symbol: "car")
                    }
                }
                if month == 12, let year = feed.year, !year.sections.isEmpty {
                    ForEach(Array(year.sections.enumerated()), id: \.offset) { _, part in
                        Section {
                            ForEach(Array(part.lines.enumerated()), id: \.offset) { _, line in Text(line) }
                        } header: {
                            LLHeader(title: part.title, symbol: "calendar")
                        }
                    }
                }
                if !feed.wishes.isEmpty {
                    Section {
                        ForEach(Array(feed.wishes.enumerated()), id: \.offset) { _, w in
                            LLRow(title: w.text, detail: [w.day, w.said].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・"))
                        }
                    } header: {
                        LLHeader(title: "欲しい物の候補", symbol: "sparkles")
                    } footer: {
                        Text("口に出した「作りたい・直したい」から拾った候補です。やることには入れていません。")
                    }
                }
                if feed.promisesKept != nil || feed.askCheck != nil {
                    Section {
                        if let k = feed.promisesKept {
                            LLRow(title: "約束の棚", value: k.a.map { "残す \($0)" })
                            if let closed = k.b { LLRow(title: "閉じた約束", value: "\(closed)") }
                        }
                        if let a = feed.askCheck, let s = a.a, let t = a.b {
                            LLRow(title: "記録に質問する の答え合わせ", detail: feed.askCheckWeek, value: "\(s)/\(t)")
                        }
                    } header: {
                        LLHeader(title: "数", symbol: "number")
                    }
                }
            } else {
                Section { LLEmpty(title: "まだ届いていません", symbol: "house") }
            }
        }
        .navigationTitle("暮らし")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s33aLife")
        .onAppear { S33ABook.shared.opened() }
    }

    private func carTitle(_ c: S33ACar) -> String {
        let route = [c.from, c.to].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " → ")
        return route.isEmpty ? S33ARules.dayText(c.day) : S33ARules.dayText(c.day) + "　" + route
    }

    private func carDetail(_ c: S33ACar) -> String? {
        var parts: [String] = []
        if let h = S33ARules.numText(c.hours) { parts.append(h + " 時間") }
        if let s = c.station, !s.isEmpty { parts.append(s) }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

// MARK: - 仕事タブ: 話し方・出す前のチェック（AI の理解の近く）・人のページ: 話のネタ

struct S33AWorkSection: View {
    var body: some View {
        let book = S33ABook.shared
        if book.offered, let feed = book.feed {
            if let sp = feed.speaking, !sp.meetings.isEmpty {
                Section {
                    ForEach(Array(sp.meetings.prefix(8).enumerated()), id: \.offset) { _, m in
                        LLRow(title: m.title, detail: meetingDetail(m), value: S33ARules.percentText(m.myShare))
                    }
                } header: {
                    LLHeader(title: "会議での自分の話し方", symbol: "waveform", trailing: sp.week)
                } footer: {
                    Text("右の数は自分が話した割合（見立て）。話し手の見分けが職場で当たるようになるまでは目安です。")
                }
            }
            if !feed.reviewRules.isEmpty {
                Section {
                    ForEach(Array(feed.reviewRules.prefix(5).enumerated()), id: \.offset) { _, r in
                        LLRow(title: r.check ?? r.type, detail: r.check == nil ? nil : r.type, value: r.count.map { "\($0) 回" })
                    }
                } header: {
                    LLHeader(title: "出す前のチェック", symbol: "checklist")
                } footer: {
                    Text("前に受けた指摘を型に分けたものです。資料を出す前に見る 5 行。")
                }
            }
        }
    }

    private func meetingDetail(_ m: S33ASpeaking.Meeting) -> String? {
        var parts: [String] = []
        if let o = m.overlaps, o > 0 { parts.append("かぶせた \(o) 回") }
        if let l = m.longRuns, l > 0 { parts.append("長く話した \(l) 回") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

struct S33ASmallTalkSection: View {
    let personID: String

    var body: some View {
        let book = S33ABook.shared
        if book.offered, let talk = book.feed?.smallTalk.first(where: { $0.personID == personID }) {
            Section {
                ForEach(Array(talk.lines.enumerated()), id: \.offset) { _, line in Text(line) }
            } header: {
                LLHeader(title: "話のネタ", symbol: "bubble.left.and.bubble.right", trailing: talk.updated.map { S33ARules.dayText($0) })
            } footer: {
                Text("前に話したこと・好きなもの・最近の出来事を、自分の記録から 3 行。会う前に見る用です。")
            }
        }
    }
}

// MARK: - 強6 寝かせた N 件（直すタブ）

struct S33ASleptRow: View {
    var body: some View {
        let snap = S33ACap.snapshot()
        if let line = S33ACap.sleptLine(snap.counts, allotted: snap.allotted) {
            Section {
                NavigationLink {
                    S33ADeepView()
                } label: {
                    LLRow(title: line, detail: "あふれた分は寝かせています（消していません）", symbol: "moon.zzz")
                }
            }
        }
    }
}

// MARK: - 強27 時計の版（くわしい設定の「時計」）

struct S33AWatchSection: View {
    var body: some View {
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        let watch = detail["watchBuild"] as? String
        let state = S33AWatch.compare(phone: AppBuild.current, watch: watch)
        Section {
            LLRow(title: "iPhone の版", value: "\(AppBuild.current)")
            LLRow(title: "時計の版", value: watch ?? "分からない")
            if let line = S33AWatch.line(state) {
                LLRow(title: line, role: state == .watchOlder ? LLRole.act : LLRole.wait)
                if state == .watchOlder {
                    ForEach(Array(S33AWatch.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                            Text("\(i + 1)").font(LL.TypeScale.tag).foregroundStyle(LL.accent)
                            Text(step).font(LL.TypeScale.detail)
                        }
                    }
                }
                NavigationLink("ほかの手順") { S22WatchUpdateView() }
            }
        } header: {
            Text("時計")
        } footer: {
            Text("版が違っても知らせはしません。ここに出るだけです。")
        }
    }
}

// MARK: - 設定の奥

/// くわしい設定のいちばん上: 使われ方・畳む候補・問いのふた・家の PC の棚
struct S33ADeepLinkSection: View {
    var body: some View {
        Section {
            NavigationLink {
                S33ADeepView()
            } label: {
                Label("使われ方・畳む候補・問いのふた", systemImage: "rectangle.compress.vertical")
            }
        } footer: {
            Text("30 日開かれていない画面とカード・今日の並び・問いの数の上限と、家の PC の棚（副業・経費・仮説ボードなど）。")
        }
    }
}

struct S33ADeepView: View {
    @AppStorage(S33ACap.onKey) private var capOn = true
    @AppStorage(S33ACap.totalKey) private var capTotal = S33ACap.defaultTotal
    @AppStorage(S33ACap.wordsKey) private var capWords = S33ACap.defaultWords
    @State private var foldBook = S24FoldBook.shared

    var body: some View {
        let book = S33ABook.shared
        let uses = book.cardUses()
        let cards = S33AFold.cardCandidates(uses: uses, hidden: book.hiddenCards, countedDays: book.cardCountedDays)
        let screens = foldBook.unusedCandidates()
        LLList {
            foldSection(cards: cards, screens: screens)
            foldedSection(book: book)
            orderSection(book: book, uses: uses)
            capSection()
            if book.offered, let feed = book.feed, feed.hasDeep {
                S33AShelfSections(feed: feed)
            }
        }
        .navigationTitle("使われ方と畳む")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s33aDeep")
        .onAppear { S33ABook.shared.opened() }
    }

    @ViewBuilder
    private func foldSection(cards: [S24Today.Card], screens: [String]) -> some View {
        Section {
            if cards.isEmpty && screens.isEmpty {
                Text("いまはありません（数え始めて 30 日たってから出ます）").foregroundStyle(LL.dim)
            }
            ForEach(cards) { card in
                HStack {
                    LLRow(title: S33AOrder.title(card), detail: "今日のカード")
                    Spacer()
                    Button("畳む") { S33ABook.shared.hide(card) }.buttonStyle(.bordered)
                }
            }
            ForEach(screens, id: \.self) { key in
                HStack {
                    LLRow(title: S24Entry.all.first(where: { $0.key == key })?.title ?? key, detail: "ふり返り・記録の入口")
                    Spacer()
                    Button("畳む") { foldBook.fold([key]) }.buttonStyle(.bordered)
                }
            }
        } header: {
            LLHeader(title: "30 日開かれていない（畳む候補）", symbol: "rectangle.compress.vertical")
        } footer: {
            Text("畳むのは押したときだけです。畳んだものは今日タブ・一覧から隠れ、下の「畳んだもの」から戻せます。")
        }
    }

    @ViewBuilder
    private func foldedSection(book: S33ABook) -> some View {
        let cards = S33AOrder.foldable.filter { book.hiddenCards.contains($0) }
        let screens = foldBook.folded.sorted()
        if !cards.isEmpty || !screens.isEmpty {
            Section {
                ForEach(cards) { card in
                    HStack {
                        LLRow(title: S33AOrder.title(card), detail: "今日のカード")
                        Spacer()
                        Button("戻す") { book.unhide(card) }.buttonStyle(.bordered)
                    }
                }
                ForEach(screens, id: \.self) { key in
                    HStack {
                        LLRow(title: S24Entry.all.first(where: { $0.key == key })?.title ?? key, detail: "ふり返り・記録の入口")
                        Spacer()
                        Button("戻す") { foldBook.unfold(key) }.buttonStyle(.bordered)
                    }
                }
            } header: {
                LLHeader(title: "畳んだもの", symbol: "tray")
            }
        }
    }

    @ViewBuilder
    private func orderSection(book: S33ABook, uses: [S24Today.Card: Int]) -> some View {
        Section {
            ForEach(book.pinnedCards) { card in
                HStack {
                    LLRow(title: S33AOrder.title(card), detail: "上に出す")
                    Spacer()
                    Button { book.movePin(card, up: true) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        .accessibilityLabel(S33AOrder.title(card) + "を上へ")
                    Button { book.movePin(card, up: false) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        .accessibilityLabel(S33AOrder.title(card) + "を下へ")
                    Button { book.togglePin(card) } label: { Image(systemName: "pin.slash") }.buttonStyle(.borderless)
                        .accessibilityLabel(S33AOrder.title(card) + "を上から外す")
                }
            }
            ForEach(S33AOrder.foldable.filter { !book.pinnedCards.contains($0) && !book.hiddenCards.contains($0) }) { card in
                Button {
                    book.togglePin(card)
                } label: {
                    LLRow(title: S33AOrder.title(card), detail: "30 日で \(uses[card] ?? 0) 回", symbol: "pin")
                }
                .buttonStyle(.plain)
            }
        } header: {
            LLHeader(title: "今日の並び", symbol: "arrow.up.arrow.down")
        } footer: {
            Text("ふだんは、30 日でよく押したカード 3 つを上に出します。ここで「上に出す」を選ぶと、そちらが先です（選んだ順）。")
        }
    }

    @ViewBuilder
    private func capSection() -> some View {
        let snap = S33ACap.snapshot()
        Section {
            Toggle("問いの山にふたをする", isOn: $capOn)
            if capOn {
                Stepper("合わせて \(capTotal) 件まで", value: $capTotal, in: S33ACap.totalRange, step: 5)
                Stepper("言葉の候補は \(capWords) 語まで", value: $capWords, in: S33ACap.wordsRange, step: 5)
            }
            ForEach(S33ACap.Kind.allCases, id: \.self) { k in
                let n = snap.counts[k] ?? 0
                let shown = snap.allotted[k] ?? 0
                LLRow(title: k.title, value: n > shown ? "\(shown) / \(n)" : "\(n)")
            }
            if let line = S33ACap.sleptLine(snap.counts, allotted: snap.allotted) {
                Text(line).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        } header: {
            LLHeader(title: "問いの山のふた（仮）", symbol: "square.stack")
        } footer: {
            Text("確かめ待ち・仕事の確かめ・話し手の疑い・言葉の候補を、種類の順に 1 件ずつ配って見せます。あふれた分は寝かせるだけで、消しません。数はそれぞれの画面を開いたときのものです。")
        }
    }
}

/// 家の PC の棚（副業の稼働・経費の候補・仮説ボード・定期の仕事の棚卸し・効いたか・C の空き）
struct S33AShelfSections: View {
    let feed: S33AFeed

    var body: some View {
        if let side = feed.sideHours, !side.days.isEmpty {
            Section {
                LLRow(title: "今月の合計", value: S33ARules.minutesText(side.totalMinutes))
                if side.overlapDays > 0 {
                    LLRow(title: "本業の時間に重なった日", value: "\(side.overlapDays) 日", role: .act)
                }
                ForEach(Array(side.days.suffix(7).reversed().enumerated()), id: \.offset) { _, d in
                    LLRow(title: S33ARules.dayText(d.day), detail: d.overlapWork ? "本業の時間に重なり" : nil, value: S33ARules.minutesText(d.minutes))
                }
            } header: {
                LLHeader(title: "副業の稼働", symbol: "clock", trailing: side.month)
            }
        }
        if !feed.expenses.isEmpty {
            Section {
                ForEach(Array(feed.expenses.prefix(30).enumerated()), id: \.offset) { _, e in
                    LLRow(title: e.shop, detail: [e.day.map { S33ARules.dayText($0) }, e.why].compactMap { $0 }.joined(separator: "・"),
                          value: S33ARules.yenText(e.amount))
                }
            } header: {
                LLHeader(title: "経費の候補", symbol: "yensign.circle", trailing: "\(feed.expenses.count) 件")
            } footer: {
                Text("確定申告の前に 1 回まとめて確かめる用です（毎回は聞きません）。")
            }
        }
        if !feed.bets.isEmpty {
            Section {
                ForEach(Array(feed.bets.enumerated()), id: \.offset) { _, b in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(b.name).font(LL.TypeScale.cardTitle)
                            Spacer()
                            if let alive = b.alive {
                                S24RoleLabel(text: alive ? "仮説は生きている" : "やめる条件に当たった", role: alive ? LLRole.wait : LLRole.act)
                            }
                        }
                        if let h = b.hypothesis, !h.isEmpty { Text("仮説: " + h).font(LL.TypeScale.detail) }
                        if let s = b.stopIf, !s.isEmpty { Text("やめる条件: " + s).font(LL.TypeScale.note).foregroundStyle(LL.dim) }
                        if let month = betMonth(b) { Text(month).font(LL.TypeScale.note).foregroundStyle(LL.dim) }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                LLHeader(title: "仮説ボード", symbol: "flag.checkered")
            } footer: {
                Text("続けるか畳むかは、本人が決めます。")
            }
        }
        if let tasks = feed.tasks {
            Section {
                if let total = tasks.total { LLRow(title: "動いている定期の仕事", value: "\(total) 本") }
                ForEach(Array(tasks.stopCandidates.prefix(20).enumerated()), id: \.offset) { _, c in
                    LLRow(title: c.name, detail: [c.why, c.lastRead.map { "最後に読まれた " + $0 }].compactMap { $0 }.joined(separator: "・"),
                          value: S33ARules.numText(c.cpuSeconds).map { $0 + " 秒" })
                }
            } header: {
                LLHeader(title: "定期の仕事の棚卸し（止める候補）", symbol: "list.bullet.rectangle")
            } footer: {
                Text("止めるのは本人が決めます。右の数は使った CPU の秒。")
            }
        }
        if !feed.effects.isEmpty {
            Section {
                ForEach(Array(feed.effects.enumerated()), id: \.offset) { _, e in
                    LLRow(title: e.bundle, detail: [e.metric, S33ARules.diffText(now: e.now, prev: e.prev)].compactMap { $0 }.joined(separator: "・"),
                          value: S33ARules.numText(e.now))
                }
            } header: {
                LLHeader(title: "効いたか（前の週と）", symbol: "chart.line.uptrend.xyaxis")
            }
        }
        if let disk = feed.disk {
            Section {
                LLRow(title: "C の空き", value: [S33ARules.numText(disk.freeGB).map { $0 + " GB" }, S33ARules.percentText(disk.freePct)]
                    .compactMap { $0 }.joined(separator: "・"), role: (disk.freePct ?? 100) < 9 ? LLRole.act : nil)
                ForEach(Array(disk.growth.enumerated()), id: \.offset) { _, g in
                    LLRow(title: g.what, value: S33ARules.numText(g.gb).map { "+" + $0 + " GB" })
                }
            } header: {
                LLHeader(title: "C ドライブ", symbol: "internaldrive")
            }
        }
    }

    private func betMonth(_ b: S33ABet) -> String? {
        var parts: [String] = []
        if let s = S33ARules.yenText(b.stake) { parts.append("今月 賭け " + s) }
        if let p = S33ARules.yenText(b.payout) { parts.append("払戻 " + p) }
        if let r = b.runs { parts.append("\(r) 回") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

// MARK: - 強11 体重計の案内（体重が無いときだけ。S26AViews の体重の節）

struct S33AScaleHint: View {
    var body: some View {
        Text("体重計を使うと、乗るだけでここに入ります").font(LL.TypeScale.note).foregroundStyle(LL.dim)
    }
}

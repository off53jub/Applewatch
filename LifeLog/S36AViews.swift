import SwiftUI
import UIKit

// s36（2026-11-28）アプリ担当 S36A の画面。決まりは S36ARules.swift、動きは S36ABook.swift。
// - 大2 仕事タブ: 「職場の Claude への頼み方」（置く文を 1 回・毎日の 1 語）・テストケースと不具合と台帳の数（見込みは「仮」）・
//   仕事のことを聞く（大4。家の PC が "askwork" を持つときだけ）。どれも中身が無ければ出さない
// - 大3 下の入口: 今日・仕事・タスク・人 の 4 つと「奥」（S36ADeepTab）。奥は前の入口（直す・記録・ふり返り）と、どこ？の目次の
//   全部の画面を名前で探せる一覧（消していない・今の画面へ行ける）。止める候補の 1 画面（S36AStopView）も奥の中
// - 大3 設定のいちばん上の「よく使う設定」（K36-1 の nav.settings_top。無ければ出さない）
// - K36-2 取り込む画面の写真の種類（S36APhotoKindSection。家の PC が "workphoto30" を持つときだけ）
// 知らせ・問いは足さない。職場の中身は時計・ウィジェット・通知に出さない。顧客名と人名を伏せる設定（S27W）に従う。

@MainActor private var s36: S36ABook { S36ABook.shared }
@MainActor private func masked(_ text: String) -> String { S27WBook.shared.t(text) }

// MARK: - 大3 下の入口の名前と絵

/// 新しい下の入口の名前と絵（名前は UI テストがタブを探す文字でもある）
struct S36ATabLabel: View {
    let tab: AppTab

    var body: some View {
        let item = S36ATabs.item(tab)
        Label(item.title, systemImage: item.symbol)
    }
}

/// 「人」の入口（記録の「人」と同じ画面。記録の切り替えの「人」も残してある）
struct S36APeopleTab: View {
    var body: some View {
        NavigationStack {
            PeoplePage()
                .settingsGear()
                .countsOpen("s36aPeople")
        }
    }
}

// MARK: - 大3 奥

/// 奥の入口。奥の一覧から前の入口（直す・記録）を開いたときは、その画面をこの入口の中に出す（上に「奥の一覧へ」）
struct S36ADeepTab: View {
    @Environment(Pipeline.self) private var pipeline
    let fixCount: Int

    var body: some View {
        switch S36ATabs.deepPage(pipeline.tab) {
        case .fix:
            FixTab()
                .safeAreaInset(edge: .top, spacing: 0) { S36ABackBar(title: "直す") }
        case .records:
            RecordsView()
                .safeAreaInset(edge: .top, spacing: 0) { S36ABackBar(title: "記録") }
        case .list:
            NavigationStack {
                S36ADeepList(fixCount: fixCount)
                    .settingsGear()
            }
        }
    }
}

/// 奥の中で前の入口を見ているときの、上の 1 行
struct S36ABackBar: View {
    @Environment(Pipeline.self) private var pipeline
    let title: String

    var body: some View {
        HStack {
            Button {
                pipeline.tab = .deep
            } label: {
                Label("奥の一覧へ", systemImage: "chevron.backward")
            }
            .accessibilityIdentifier("s36a.deep.back")
            Spacer()
            Text("奥 › " + title).font(LL.TypeScale.note).foregroundStyle(LL.dim)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// 奥の一覧: 前の入口・止める候補・どこ？の目次の全部（名前で探せる）・下の入口の切り替え
struct S36ADeepList: View {
    @Environment(Pipeline.self) private var pipeline
    let fixCount: Int
    @State private var query = ""
    @AppStorage(S36ATabs.onKey) private var tabsOn = true

    var body: some View {
        let hits = S33AWhere.search(query)
        LLList {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    moved("直す", detail: "確かめ待ち・名前付け・言葉の登録", symbol: "tray.full", badge: fixCount, id: "s36a.deep.fix") {
                        pipeline.tab = .fix
                    }
                    moved("記録", detail: "日ごと・人・場所・お金", symbol: "books.vertical", badge: 0, id: "s36a.deep.records") {
                        pipeline.tab = .records
                    }
                    moved("ふり返り", detail: "数の小さなグラフ・物語・月の 1 枚", symbol: "clock.arrow.circlepath", badge: 0,
                          id: "s36a.deep.lookBack") {
                        pipeline.openRoute(.tab(.lookBack))
                    }
                } header: {
                    LLHeader(title: "前の入口", symbol: "square.grid.2x2")
                } footer: {
                    Text("下の入口を 今日・仕事・タスク・人 の 4 つにして、ほかはここにまとめました（消した画面はありません）。")
                }
                if s36.offered, s36.feed?.stop != nil {
                    Section {
                        NavigationLink {
                            S36AStopView()
                        } label: {
                            LLRow(title: "止める候補", detail: "1 件ずつ「止める」「残す」を選べます",
                                  value: s36.candidates.isEmpty ? nil : "\(s36.candidates.count) 件")
                        }
                        .accessibilityIdentifier("s36a.deep.stop")
                    }
                }
                ForEach(S33AWhere.toc()) { group in
                    Section {
                        ForEach(group.entries) { S36AWhereRow(entry: $0) }
                    } header: {
                        LLHeader(title: group.place, symbol: "list.bullet")
                    }
                }
                Section {
                    Toggle("下の入口を 4 つ＋奥にする", isOn: $tabsOn)
                        .onChange(of: tabsOn) { Tally.add(tabsOn ? "s36a.tabs.on" : "s36a.tabs.off") }
                } footer: {
                    Text("切ると前の 5 つ（今日・タスク・仕事・直す・記録）に戻ります。初めはオンです。")
                }
            } else if hits.isEmpty {
                Section {
                    LLEmpty(title: "見つかりませんでした", symbol: "magnifyingglass",
                            detail: "ほかの言い方でも探せます（例: 直す・体重・ラーメン・用語・止める）。")
                }
            } else {
                Section {
                    ForEach(hits) { S36AWhereRow(entry: $0) }
                } header: {
                    Text("\(hits.count) 件")
                }
            }
        }
        .searchable(text: $query, prompt: "画面や機能の名前（例: 直す・仕事のまとめ・声の名前）")
        .navigationTitle("奥")
        .countsOpen("s36aDeep")
        .onAppear { s36.opened() }
    }

    private func moved(_ title: String, detail: String, symbol: String, badge: Int, id: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                LLRow(title: title, detail: detail, value: badge > 0 ? "\(badge)" : nil, symbol: symbol)
                Image(systemName: "chevron.forward").foregroundStyle(LL.dim)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// どこ？の目次の 1 行（奥と、設定のよく使う設定から）。押して開く画面は進む・タブとシートは切り替える
struct S36AWhereRow: View {
    @Environment(Pipeline.self) private var pipeline
    let entry: S33AWhereEntry
    /// 設定のシートの中から開くとき（シートを閉じてから切り替える）
    var inSheet = false

    var body: some View {
        if case .view(let key) = entry.target {
            NavigationLink {
                S33AWhereDestination(key: key)
                    .onAppear { Tally.add("s36a.where.go") }
            } label: {
                LLRow(title: entry.name, detail: entry.place)
            }
        } else {
            Button {
                S36AGo.open(entry.target, pipeline: pipeline, fromSheet: inSheet)
            } label: {
                HStack {
                    LLRow(title: entry.name, detail: entry.place)
                    Spacer()
                    Image(systemName: "arrow.up.forward").foregroundStyle(LL.dim)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

@MainActor
enum S36AGo {
    /// 目次の行の行き先へ（シートの中からは、シートを閉じてから）
    static func open(_ target: S33AWhereTarget, pipeline: Pipeline, fromSheet: Bool) {
        Tally.add("s36a.where.go")
        if fromSheet { NotificationCenter.default.post(name: .s33aLeave, object: nil) }
        let go: () -> Void = {
            switch target {
            case .tab(let t):
                pipeline.openRoute(.tab(t))
            case .records(let page):
                if page == S30TTabs.RecordsPage.lookBack.rawValue {
                    pipeline.openRoute(.tab(.lookBack))
                } else if page == S30TTabs.RecordsPage.people.rawValue, S36ATabs.isOn {
                    pipeline.openRoute(.tab(.people))
                } else {
                    UserDefaults.standard.set(page, forKey: S30TTabs.recordsPageKey)
                    pipeline.openRoute(.tab(.records))
                }
            case .screen(let raw):
                if let s = NoticeScreen(rawValue: raw) { pipeline.openRoute(.screen(s)) }
            case .link(let text):
                if let url = URL(string: text), let route = NoticeRoute.route(url: url) { pipeline.openRoute(route) }
            case .view:
                break
            }
        }
        if fromSheet {
            // シートが閉じてから開く（シートの上にシートは出せない）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { go() }
        } else {
            go()
        }
    }
}

// MARK: - 大3 設定のいちばん上「よく使う設定」

struct S36ASettingsTopSection: View {
    var body: some View {
        let rows: [S33AWhereEntry] = s36.offered ? S36ARules.settingsTop(s36.feed?.nav, in: S33AWhere.entries) : []
        if !rows.isEmpty {
            Section {
                ForEach(rows) { S36AWhereRow(entry: $0, inSheet: true) }
            } header: {
                LLHeader(title: "よく使う設定", symbol: "star")
            } footer: {
                Text("このアプリで開いた回数の多いものです（家の PC が数えました）。")
            }
        }
    }
}

/// 下の入口の切り替えだけの画面（どこ？から）
struct S36ATabsSettingsView: View {
    @AppStorage(S36ATabs.onKey) private var tabsOn = true

    var body: some View {
        LLList {
            Section {
                Toggle("下の入口を 4 つ＋奥にする", isOn: $tabsOn)
            } footer: {
                Text("オン: " + S36ATabs.afterTitles.joined(separator: "・") + "。オフ: " + S36ATabs.beforeTitles.joined(separator: "・")
                     + "（前の形）。初めはオンです。")
            }
        }
        .navigationTitle("下の入口")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 大3 止める候補

struct S36AStopView: View {
    @State private var confirming: S36AStopItem?
    @State private var busy: String?
    @State private var note: String?
    /// 「おすすめどおり止める」の確かめに見せている一覧（2026-11-28。s37 の K37-3）
    @State private var bulk: [S36AStopItem]?

    var body: some View {
        let list = s36.candidates
        let done = s36.settled
        LLList {
            if let note {
                Section { Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim) }
            }
            if list.isEmpty {
                Section {
                    LLEmpty(title: "いま選ぶものはありません", symbol: "checkmark.circle",
                            detail: "家の PC が「開かれない画面のための作り物」や Claude の頼みを見つけると、ここに出ます。")
                }
            } else {
                // おすすめ（recommend が true）があるときだけ出す。欄が無ければ出さない（2026-11-28。s37 の K37-3。S37ARules.swift）
                if S37AStop.showsBulk(list) {
                    let picks = S37AStop.recommended(list)
                    Section {
                        Button("おすすめどおり止める（\(picks.count) 件）", systemImage: "pause.circle.fill") {
                            Tally.add("s37a.stop.bulk.open")
                            bulk = picks
                        }
                        .disabled(!s36.stopOffered || busy != nil)
                        .accessibilityIdentifier("s37a.stop.bulk")
                    } footer: {
                        Text("止めても困らない見込みのものを、家の PC がおすすめしています。押すと、止めるものの一覧を見せてから伝えます。")
                    }
                }
                Section {
                    ForEach(list) { row($0) }
                } header: {
                    LLHeader(title: "止める候補", symbol: "pause.circle", trailing: "\(list.count) 件")
                } footer: {
                    Text(s36.stopOffered
                         ? "止めるのは、ここで「止める」を押したものだけです。家の PC が次の回に止め、戻す口も残します。答えないものは何もしません。「残す」を押したものは、次から出しません。"
                         : "家の PC がまだ答えを受けられないので、押せません（家の PC を新しくすると押せます）。")
                }
            }
            if !done.isEmpty {
                Section("答えたもの") {
                    ForEach(done) { item in
                        LLRow(title: item.title, detail: S36ARules.stateLabel(item, answered: s36.answered))
                    }
                }
            }
        }
        .navigationTitle("止める候補")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s36aStop")
        .confirmationDialog(confirming.map { "「" + $0.title + "」を止めますか？" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { item in
            Button("止める", role: .destructive) { send(item, "stop") }
            Button("やめる", role: .cancel) { confirming = nil }
        } message: { item in
            Text(whatStops(item))
        }
        .alert(bulk.map(S37AStop.confirmTitle) ?? "",
               isPresented: Binding(get: { bulk != nil }, set: { if !$0 { bulk = nil } }), presenting: bulk) { items in
            Button("\(items.count) 件を止める", role: .destructive) { sendBulk(items) }
            Button("やめる", role: .cancel) { bulk = nil }
        } message: { items in
            Text(S37AStop.confirmMessage(items))
        }
    }

    /// おすすめのものに、今の POST /s36/stop（choice stop）を 1 件ずつ送る。結果は画面の中の 1 行だけ（知らせにしない）
    private func sendBulk(_ items: [S36AStopItem]) {
        bulk = nil
        guard !items.isEmpty else { return }
        busy = "bulk"
        Tally.add("s37a.stop.bulk.send")
        Task {
            var sent = 0
            var failed = 0
            for item in items {
                note = "伝えています… \(sent + failed + 1)/\(items.count)"
                if await s36.answer(item, choice: "stop") { sent += 1 } else { failed += 1 }
            }
            busy = nil
            Tally.add("s37a.stop.bulk.sent", sent)
            if failed > 0 { Tally.add("s37a.stop.bulk.failed", failed) }
            note = S37AStop.resultNote(sent: sent, failed: failed)
            if sent > 0 { LLHaptic.done.play() }
        }
    }

    private func row(_ item: S36AStopItem) -> some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(LL.TypeScale.cardTitle)
                Spacer(minLength: LL.Space.s)
                Text(S36ARules.kindLabel(item.kind)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if let why = item.why, !why.isEmpty {
                Text("止まるもの: " + why).font(LL.TypeScale.detail)
            }
            if let saves = item.saves, !saves.isEmpty {
                Text("軽くなるもの: " + saves).font(LL.TypeScale.detail).foregroundStyle(LL.dim)
            }
            HStack(spacing: LL.Space.m) {
                Button("止める", systemImage: "pause.circle") { confirming = item }
                Button("残す", systemImage: "checkmark.circle") { send(item, "keep") }
                if busy == item.id { ProgressView() }
            }
            .buttonStyle(.borderless)
            .disabled(!s36.stopOffered || busy != nil)
        }
        .padding(.vertical, 2)
    }

    private func whatStops(_ item: S36AStopItem) -> String {
        var lines: [String] = []
        if let why = item.why, !why.isEmpty { lines.append("止まるもの: " + why) }
        if let saves = item.saves, !saves.isEmpty { lines.append("軽くなるもの: " + saves) }
        lines.append("あとで戻せます。")
        return lines.joined(separator: "\n")
    }

    private func send(_ item: S36AStopItem, _ choice: String) {
        confirming = nil
        busy = item.id
        Task {
            let ok = await s36.answer(item, choice: choice)
            busy = nil
            note = ok
                ? (choice == "stop" ? "「" + item.title + "」を止めると伝えました。" : "「" + item.title + "」を残すと伝えました。")
                : "いまは伝えられませんでした（家の PC につながっていないかもしれません）。"
            if ok { LLHaptic.done.play() }
        }
    }
}

// MARK: - 大2・大4 仕事タブ

/// 仕事タブに足すもの（頼み方・数・仕事のことを聞く）。中身が無ければ何も出さない
struct S36AWorkSections: View {
    var body: some View {
        S36APromptSection()
        S36ANumbersSection()
        S36AAskWorkSection()
    }
}

struct S36APromptSection: View {
    @State private var note: String?

    var body: some View {
        if s36.hasPromptPlace {
            let daily: String? = s36.dailyPrompt()
            Section {
                switch s36.setupBand {
                case .first?:
                    LLRow(title: "まず 1 回、置く文を職場の Claude に置いてください", detail: "置くまでは、今までの長い頼み方を写します", role: .act)
                case .changed?:
                    LLRow(title: "頼み方が新しくなりました。置き直してください", detail: "置く文をコピーして、前の分と入れ替えてください", role: .act)
                case nil:
                    EmptyView()
                }
                Button("置く文をコピー（最初に 1 回）", systemImage: "doc.on.doc") {
                    if let text = s36.setupCopied() {
                        UIPasteboard.general.string = text
                        note = "置く文をコピーしました。職場の Claude のプロジェクトの指示などに貼ってください。"
                    }
                }
                .accessibilityIdentifier("s36a.prompt.setup")
                Button("毎日の 1 語をコピー", systemImage: "text.badge.checkmark") {
                    if let daily {
                        UIPasteboard.general.string = daily
                        note = "コピーしました。職場の Claude に貼ってください。"
                        Tally.add("s36a.daily.copy")
                    }
                }
                .disabled(daily == nil)
                .accessibilityIdentifier("s36a.prompt.daily")
                if let daily {
                    Text(masked(daily)).font(LL.TypeScale.note).foregroundStyle(LL.dim).lineLimit(3)
                }
                if let line = S36ARules.refsLine(s36.feed?.prompt) {
                    Text(line).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
                if let note { Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim) }
            } header: {
                LLHeader(title: "職場の Claude への頼み方", symbol: "text.bubble")
            } footer: {
                Text("置く文は 1 回だけ、職場の Claude に置きます。毎日は短い 1 語を貼るだけで、いつものまとめに【済んだ番号】が付いて返ってきます（「済」の番号だけ台帳で閉じます・戻せます）。ほかのコピーのボタンも、置いたあとはこの 1 語を写します。")
            }
        }
    }
}

struct S36ANumbersSection: View {
    var body: some View {
        let feed: S36AFeed? = s36.offered ? s36.feed : nil
        let cases = S36ARules.casesLine(feed?.cases)
        let bugs = S36ARules.bugsLine(feed?.bugs)
        let ledger = S36ARules.ledgerLine(feed?.ledger)
        if cases != nil || bugs != nil || ledger != nil || s36.tableNote != nil {
            Section {
                if let cases {
                    VStack(alignment: .leading, spacing: LL.Space.xs) {
                        Text("テストケース " + cases).font(LL.TypeScale.cardTitle).monospacedDigit()
                        if let eta = S36ARules.etaLine(feed?.cases) {
                            Text(masked(eta)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                        }
                    }
                    .accessibilityIdentifier("s36a.cases")
                    let missing = feed?.cases?.evidenceMissing ?? []
                    if !missing.isEmpty {
                        NavigationLink {
                            S36ARefListView(title: "エビデンスの抜け", rows: missing)
                        } label: {
                            LLRow(title: "エビデンスの抜け", value: "\(missing.count) 件", role: .act)
                        }
                    }
                    let areas = feed?.cases?.byArea ?? []
                    if !areas.isEmpty {
                        DisclosureGroup("区分ごと（\(areas.count)）") {
                            ForEach(Array(areas.enumerated()), id: \.offset) { _, a in
                                Text(masked(S36ARules.areaLine(a))).font(LL.TypeScale.detail).monospacedDigit()
                            }
                        }
                    }
                }
                if let bugs {
                    NavigationLink {
                        S36ABugListView(bugs: feed?.bugs ?? S36ABugs())
                    } label: {
                        LLRow(title: "不具合", detail: bugs)
                    }
                }
                if let ledger {
                    LLRow(title: "仕事の台帳", detail: ledger)
                }
                if let note = s36.tableNote {
                    Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            } header: {
                LLHeader(title: "テストと不具合の数", symbol: "tablecells", trailing: feed?.cases?.asOf.map { AppFeeds.monthDay($0) + " 時点" })
            } footer: {
                Text("表と一覧の写真から家の PC が数えたものです。終わる見込みは仮で、材料が 3 日分そろうまでは出しません。14 日動かない項目は、柱の中の「古い」の箱に畳みます（消していません）。")
            }
        }
    }
}

struct S36ARefListView: View {
    let title: String
    let rows: [S36ARef]

    var body: some View {
        LLList {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        if !r.ref.isEmpty { Text(r.ref).font(LL.TypeScale.note).foregroundStyle(LL.dim).monospacedDigit() }
                        Text(masked(r.text))
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct S36ABugListView: View {
    let bugs: S36ABugs

    var body: some View {
        let open = bugs.items.filter { !S36ARules.isClosed($0.state) }
        let closed = bugs.items.filter { S36ARules.isClosed($0.state) }
        LLList {
            if bugs.items.isEmpty {
                Section { LLEmpty(title: "一覧の行はまだありません", symbol: "ladybug") }
            }
            if !open.isEmpty {
                Section("開いている") { ForEach(Array(open.enumerated()), id: \.offset) { _, b in row(b) } }
            }
            if !closed.isEmpty {
                Section("閉じた") { ForEach(Array(closed.enumerated()), id: \.offset) { _, b in row(b) } }
            }
        }
        .navigationTitle("不具合")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s36aBugs")
    }

    private func row(_ b: S36ABug) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(masked(b.text))
            let parts: [String] = [b.ref, b.state ?? "", b.who.map(masked) ?? "", b.day.map { AppFeeds.monthDay($0) } ?? ""]
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                Text(parts.joined(separator: "・")).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
    }
}

/// 大4: 仕事のことを聞く（家の PC が "askwork" を持つときだけ）
struct S36AAskWorkSection: View {
    var body: some View {
        if s36.has(S36ARules.featureAskWork) {
            Section {
                NavigationLink {
                    AskView(scope: "work")
                } label: {
                    Label("仕事のことを聞く", systemImage: "questionmark.bubble")
                }
                .accessibilityIdentifier("s36a.askwork")
            } footer: {
                Text("「あの件は誰待ち？」「先週の定例で決まったことは？」に、出どころ（日・だれ・まとめか声か）付きで答えます。")
            }
        }
    }
}

// MARK: - K36-2 取り込む画面の写真の種類

struct S36APhotoKindSection: View {
    @Binding var kind: S36APhotoKind

    var body: some View {
        Section {
            Picker("写真の種類", selection: $kind) {
                ForEach(S36APhotoKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("s36a.photoKind")
        } header: {
            Text("写真の種類")
        } footer: {
            Text(kind.isDigest
                 ? "いつものまとめです（初めはこれ）。"
                 : "「\(kind.label)」は、まとめとは別に写真だけを家の PC へ送ります（まとめには入れません）。家の PC が表の行を 1 行ずつ写して数えます。")
        }
    }
}

// MARK: - どこ？から押して開く画面（S33AWhereDestination から）

struct S36AWhereScreen: View {
    let key: String

    var body: some View {
        switch key {
        case "s36Prompt", "s36Numbers":
            LLList {
                S36APromptSection()
                S36ANumbersSection()
                if !s36.hasPromptPlace && S36ARules.casesLine(s36.feed?.cases) == nil {
                    Section { LLEmpty(title: "家の PC からまだ届いていません", symbol: "tray", detail: "届くと、仕事タブにも出ます。") }
                }
            }
            .navigationTitle("頼み方と数")
            .navigationBarTitleDisplayMode(.inline)
        case "s36AskWork": AskView(scope: "work")
        case "s36Stop": S36AStopView()
        case "s36Tabs": S36ATabsSettingsView()
        default: LLList { Section { LLEmpty(title: "この画面はまだ開けません", symbol: "questionmark") } }
        }
    }
}

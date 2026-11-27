import SwiftUI
import UIKit

// s30（2026-11-27）仕事タブ（S30W）の画面。入口は S30WTab（K30-3。タブ担当 S30T が ContentView から呼ぶだけ）。
// ひな形（母艦の reports/work-mock2.html）の並びを上から:
//   状況の 1 枚 → 数字のタイル 3 つ → 節目の道のり → 今日の一手 3 つ →（自分のタスク（仕事）＝タスクの帳の work の分）→
//   相手を待っている 3 つ → 柱ごとの状況（押すと開く）→ この案件の外に見える話 → 仕事のまとめ・前の一覧（S27WHomeView）。
// 右上の＋で仕事のまとめを取り込む（WorkDigestImportView）。保存のあと家の PC へ送り、上に作り直しの帯を出す（S30WBook）。
// report が無いとき（前の形）は、同じ画面に規則で並べる（「機械の並べ方」と小さく書く）。決まりは S30WRules.swift。
// 守1〜守4 は s27 のまま（ウィジェット・通知に中身を出さない・Face ID の鍵（S27WGate）・伏せる切り替え・日と出どころ）。
// 色だけに頼らない: どの色にも文字の札（急ぎ・自分の番…）を添える。

@MainActor private var book: S27WBook { S27WBook.shared }
@MainActor private var s30: S30WBook { S30WBook.shared }
@MainActor private func todayKey() -> String { ReviewRules.dayKey(.now) }

@MainActor
private enum S30WFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d H:mm"
        return f
    }()
}

extension S30WProjectState {
    var color: Color {
        switch self {
        case .ok: LL.good
        case .caution: LL.warn
        case .stuck: LL.danger
        }
    }
}

// MARK: - 入口（K30-3）

/// 仕事タブ（NavigationStack の根）。右上に＋（仕事のまとめを取り込む）と歯車
struct S30WTab: View {
    var body: some View {
        NavigationStack {
            S30WHomeView()
                .settingsGear()
        }
    }
}

/// 自分のタスク（仕事）のシートと「違う」の理由（一覧の中の Section ではなく、画面の根に付ける）
@MainActor
@Observable
final class S30WTaskSheets {
    var editing: TaskBook.Item?
    var replyDraft: TaskReply.Draft?
    var rejecting: TaskBook.Item?
    let player = ClipPlayer()
}

struct S30WHomeView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var importing = false
    @State private var note: String?
    @State private var sheets = S30WTaskSheets()

    var body: some View {
        let today = todayKey()
        let screen: S30WScreen? = screenNow(today)
        LLList {
            S30WBandSection(note: note) { note = nil }
            if let screen {
                S30WUpperSections(screen: screen, today: today)
            } else {
                S30WNoBoardSection()
            }
            S30WTasksSection(sheets: sheets)
            if let screen {
                S30WLowerSections(screen: screen, today: today)
            }
            S30WLastSection(screen: screen)
        }
        .modifier(S27WGate())
        .navigationTitle("仕事")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("仕事のまとめを取り込む", systemImage: "plus") { importing = true }
            }
        }
        .sheet(isPresented: $importing) {
            NavigationStack {
                WorkDigestImportView { note = $0 }
            }
        }
        .modifier(S30WTaskSheetsModifier(sheets: sheets))
        .refreshable { await book.refresh(force: true) }
        .task {
            await book.loadCopy()
            s30.noteFeatures(pipeline.homePC.features)
            if let b = book.board { s30.prune(b) }
        }
        .onAppear {
            book.opened()
            Tally.add("s30w.open")
        }
        .onChange(of: book.fetchedAt) {
            if let b = book.board { s30.prune(b) }
        }
        .countsOpen("s30w")
    }

    private func screenNow(_ today: String) -> S30WScreen? {
        guard book.offered, let board = book.board else { return nil }
        return S30WRules.screen(board, done: Set(book.localDoneIDs), restored: s30.restoredIDs, today: today)
    }
}

// MARK: - 帯（作り直し）・取り込みの一文

private struct S30WBandSection: View {
    let note: String?
    let clearNote: () -> Void

    var body: some View {
        if let band = s30.visibleBand() {
            Section {
                S30WBandRow(band: band)
            }
        }
        if let note {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                    Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    Spacer(minLength: LL.Space.s)
                    Button(action: clearNote) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("閉じる")
                }
            }
        }
    }
}

private struct S30WBandRow: View {
    let band: S30WBand

    var body: some View {
        let title = S30WRules.bandTitle(band)
        let detail = S30WRules.bandDetail(band, clock: S30WFormat.time.string(from: band.at))
        HStack(alignment: .top, spacing: LL.Space.s) {
            if band.working {
                ProgressView()
            } else {
                Image(systemName: symbol).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(LL.TypeScale.cardTitle).foregroundStyle(LL.text)
                }
                Text(detail).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            Spacer(minLength: LL.Space.s)
            if !band.working {
                Button { s30.dismissBand() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("閉じる")
            }
        }
    }

    private var symbol: String {
        switch band {
        case .done(_, let ok): ok ? "checkmark.circle" : "exclamationmark.triangle"
        case .late: "clock"
        default: "info.circle"
        }
    }

    private var color: Color {
        switch band {
        case .done(_, let ok): ok ? LL.good : LL.warn
        case .late: LL.warn
        default: LL.dim
        }
    }
}

/// 写しがまだ無い・家の PC に仕事の口が無いとき（下の自分のタスクと仕事のまとめは使える）
private struct S30WNoBoardSection: View {
    var body: some View {
        Section {
            if !book.offered {
                LLEmpty(title: "家の PC に仕事の口がまだありません", symbol: "briefcase",
                        detail: "家の PC の LifeLog PC が新しくなると、ここに案件のいまの状況が出ます。下の自分のタスクと仕事のまとめは、このままでも使えます。")
            } else {
                LLEmpty(title: "まだ材料がありません", symbol: "briefcase",
                        detail: "家の PC が仕事の台帳を配りはじめると、ここに出ます。つながらないときは前に届いた分を見せます。")
            }
        }
    }
}

// MARK: - 上の段（状況の 1 枚・タイル・道のり・今日の一手）

private struct S30WUpperSections: View {
    let screen: S30WScreen
    let today: String

    var body: some View {
        S30WStampSection(screen: screen)
        ForEach(screen.cards) { card in
            S30WCardSection(card: card, ruled: screen.cardsRuled)
        }
        if !screen.tiles.isEmpty {
            S30WTilesSection(tiles: screen.tiles)
        }
        if !screen.road.isEmpty {
            S30WRoadSection(marks: screen.road, ruled: screen.roadRuled, unfirm: screen.anyUnfirm)
        }
        S30WStepsSection(steps: screen.next3, count: screen.mineCount, ruled: screen.next3Ruled)
    }
}

/// 「11/27 6:30 に書き直した分・状況の文は Claude が書いたもの・受け取った …」
private struct S30WStampSection: View {
    let screen: S30WScreen

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: LL.Space.xs) {
                Text(stamp).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                if book.offline {
                    S24RoleLabel(text: "家の PC につながらないので、前に届いた分を見せています", role: .wait)
                        .font(LL.TypeScale.note)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private var stamp: String {
        var parts: [String] = []
        if let w = S27WRules.date(screen.writtenAt) {
            parts.append(S30WFormat.stamp.string(from: w) + " に書き直した分")
        } else if let a = screen.asOf, HomeFeeds.isDay(a) {
            parts.append(AppFeeds.monthDay(a) + " の分")
        }
        if screen.hasReport {
            parts.append(screen.byClaude ? "状況の文は Claude が書いたもの" : "状況の文は規則で書いたもの")
        } else {
            parts.append("機械の並べ方（前の形の材料から並べています）")
        }
        if let at = book.fetchedAt { parts.append("受け取った " + S30WFormat.stamp.string(from: at)) }
        if book.maskOn { parts.append("顧客名と人名を伏せています") }
        return parts.joined(separator: "・")
    }
}

/// 状況の 1 枚（今どこ・動いた・引っかかり・根拠の発言）
private struct S30WCardSection: View {
    let card: S30WCard
    let ruled: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: LL.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                    Text(book.t(card.name)).font(LL.TypeScale.screenTitle).foregroundStyle(LL.text)
                    Spacer(minLength: LL.Space.s)
                    if let state = card.state {
                        S30WBadge(text: state.label, color: state.color)
                    }
                }
                if let client = card.client, !client.isEmpty {
                    Text(book.t(client)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
                S30WSayRow(key: "今どこ", text: card.now)
                S30WSayRow(key: "動いた", text: card.moved)
                S30WSayRow(key: "引っかかり", text: card.snag)
                if ruled {
                    Text("機械の並べ方（届いている数と日から）").font(LL.TypeScale.tag).foregroundStyle(LL.dim)
                }
            }
            .padding(.vertical, LL.Space.xs)
            if !card.evidence.isEmpty {
                NavigationLink {
                    S30WItemsView(title: "根拠の発言", items: card.evidence)
                } label: {
                    Text("根拠の発言 \(card.evidence.count) 件を見る").font(LL.TypeScale.note).foregroundStyle(LL.accent)
                }
            }
        }
    }
}

private struct S30WSayRow: View {
    let key: String
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                Text(key).font(LL.TypeScale.tag).foregroundStyle(LL.dim)
                    .frame(minWidth: 64, alignment: .leading)
                Text(book.t(text)).font(LL.TypeScale.detail).foregroundStyle(LL.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// 色の地に文字の札（順調・注意・急ぎ…）
struct S30WBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(LL.TypeScale.tag)
            .foregroundStyle(LL.bg)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, LL.Space.s)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}

// MARK: 数字のタイル 3 つ

private struct S30WTilesSection: View {
    let tiles: [S30WTile]

    var body: some View {
        Section {
            LLAdaptiveStack(spacing: LL.Space.s) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    S30WTileView(tile: tile)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: LL.Space.xs, leading: 0, bottom: LL.Space.xs, trailing: 0))
    }
}

private struct S30WTileView: View {
    let tile: S30WTile

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(tile.value).font(LL.TypeScale.number).foregroundStyle(tile.tone?.color ?? LL.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let unit = tile.unit {
                    Text(unit).font(LL.TypeScale.tag).foregroundStyle(LL.dim)
                }
            }
            Text(book.t(tile.label)).font(LL.TypeScale.note).foregroundStyle(LL.dim).lineLimit(3)
            if tile.spark.count >= 2 {
                MiniBars(points: points, height: 22)
            }
            Spacer(minLength: 0)
        }
        .padding(LL.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LL.surface, in: RoundedRectangle(cornerRadius: LL.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: LL.Radius.small).strokeBorder(LL.line, lineWidth: LL.Stroke.hair))
        .accessibilityElement(children: .combine)
    }

    private var points: [MiniPoint] {
        var out: [MiniPoint] = []
        for (i, v) in tile.spark.enumerated() { out.append(MiniPoint(id: i, label: "\(i + 1)", value: v)) }
        return out
    }
}

// MARK: 節目の道のり

private struct S30WRoadSection: View {
    let marks: [S30WRoadMark]
    let ruled: Bool
    let unfirm: Bool

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(marks) { m in
                        S30WRoadPointView(mark: m).frame(width: S30WRoadPointView.width)
                    }
                }
                .background(alignment: .top) {
                    Rectangle().fill(LL.line).frame(height: 2)
                        .padding(.horizontal, S30WRoadPointView.width / 2)
                        .padding(.top, 9)
                }
                .padding(.vertical, LL.Space.xs)
            }
            if unfirm {
                Text("「?」はまだ確定していない日です。").font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        } header: {
            LLHeader(title: "節目の道のり", symbol: "flag", trailing: ruled ? "機械の並べ方（届いた節目から）" : "会話から拾った日付")
        }
    }
}

private struct S30WRoadPointView: View {
    static let width: CGFloat = 76
    let mark: S30WRoadMark

    var body: some View {
        VStack(spacing: LL.Space.xs) {
            marker.frame(width: 20, height: 20)
            Text(label).font(LL.TypeScale.tag).foregroundStyle(LL.text)
            if !mark.title.isEmpty {
                Text(book.t(mark.title)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        mark.isToday ? "今日" : AppFeeds.monthDay(mark.day) + (mark.firm ? "" : "?")
    }

    private var color: Color { mark.daysLeft <= 1 ? LL.danger : LL.accent }

    @ViewBuilder
    private var marker: some View {
        if mark.isToday {
            Circle().fill(LL.text).frame(width: 10, height: 10)
        } else if mark.firm {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10).rotationEffect(.degrees(45))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(LL.surface)
                RoundedRectangle(cornerRadius: 2).strokeBorder(color, lineWidth: LL.Stroke.bold)
            }
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(45))
        }
    }
}

// MARK: 今日の一手（3 つだけ）

private struct S30WStepsSection: View {
    let steps: [S30WStep]
    let count: Int
    let ruled: Bool

    var body: some View {
        Section {
            if steps.isEmpty {
                Text("自分の番のものは届いていません").foregroundStyle(LL.dim)
            }
            ForEach(Array(steps.enumerated()), id: \.element.id) { n, step in
                S30WStepRow(number: n + 1, step: step)
            }
        } header: {
            LLHeader(title: "今日の一手（3 つだけ）", symbol: "hand.point.up.left", trailing: "自分の番 \(count) 件から")
        } footer: {
            Text(ruled ? "機械の並べ方: 急ぎ → 期限の近い順 → 古い順。丸を押すと済みにします（家の PC にも伝えます）。"
                       : "丸を押すと済みにします（家の PC にも伝えます）。")
        }
    }
}

private struct S30WStepRow: View {
    let number: Int
    let step: S30WStep

    var body: some View {
        let done = book.isDone(step.item)
        HStack(alignment: .top, spacing: LL.Space.s) {
            Text("\(number)")
                .font(LL.TypeScale.tag)
                .foregroundStyle(LL.bg)
                .frame(width: 24, height: 24)
                .background(step.state.color, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LL.Space.xs) {
                Text(book.t(step.item.text))
                    .font(LL.TypeScale.body)
                    .foregroundStyle(done ? LL.dim : LL.text)
                    .strikethrough(done)
                S30WTags(main: step.why, mainColor: step.state.color, rest: step.pillar.map { [book.t($0)] } ?? [])
                S30WMeta(item: step.item)
            }
            Spacer(minLength: LL.Space.s)
            S30WDoneButton(item: step.item)
        }
        .padding(.vertical, 2)
        .s30wItemMenu(step.item)
    }
}

private struct S30WDoneButton: View {
    let item: S27WItem

    var body: some View {
        let done = book.isDone(item)
        Button {
            book.setDone(item, done: !done)
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .foregroundStyle(done ? LL.good : LL.accent)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(done ? "済みを戻す" : "済みにする")
    }
}

// MARK: - 自分のタスク（仕事）（タスクの帳の work == true。行・済み・押した先はタスクの部品のまま）

private struct S30WTasksSection: View {
    @Environment(Pipeline.self) private var pipeline
    let sheets: S30WTaskSheets
    @State private var expanded = false
    @State private var showWaiting = false
    @State private var showHome = false

    var body: some View {
        let lists = pipeline.tasks.lists(.work)
        let todo = Self.ordered(lists.todo)
        let picks = pipeline.tasks.todayCandidates().filter(\.isWork)
        let home = MothershipBook.sorted(pipeline.mothership.extra(.work, tasks: pipeline.tasks.items))
        let fold = S27WMap.fold(todo.count, expanded: expanded, limit: S30WRules.taskFold)
        Section {
            ForEach(picks) { candidateRow($0) }
            if todo.isEmpty && picks.isEmpty {
                Text("仕事のやることはありません").foregroundStyle(LL.dim)
            }
            ForEach(todo.prefix(fold.shown)) { openRow($0) }
            if todo.count > S30WRules.taskFold {
                Button(expanded ? "畳む" : "あと \(fold.hidden) 件を見る", systemImage: expanded ? "chevron.up" : "chevron.down") {
                    withAnimation { expanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(LL.TypeScale.note)
            }
            if !lists.waiting.isEmpty {
                DisclosureGroup("人に頼んで待っている \(lists.waiting.count) 件", isExpanded: $showWaiting) {
                    ForEach(lists.waiting) { openRow($0) }
                }
            }
            if !home.isEmpty {
                DisclosureGroup("家の PC が拾った仕事のやること \(home.count) 件", isExpanded: $showHome) {
                    ForEach(home) { MothershipRow(item: $0) }
                }
            }
            Button("仕事のタスクを書き足す", systemImage: "square.and.pencil") {
                sheets.editing = TaskBook.Item(what: "", said: .now, source: .manual, state: .open, work: true)
            }
            .buttonStyle(.borderless)
        } header: {
            LLHeader(title: "自分のタスク（仕事）", symbol: "checklist", trailing: todo.isEmpty ? nil : "\(todo.count)")
        } footer: {
            Text("タスクの帳の仕事の分です。○で済み、押すと直せます。確かめ待ちは「入れる」か「違う」で。")
        }
    }

    /// 期限で分けた並び（期限切れ → 今日 → 7 日以内 → それより先 → 期限なし。同じ並びの中は急ぎが上）
    private static func ordered(_ items: [TaskBook.Item]) -> [TaskBook.Item] {
        var out: [TaskBook.Item] = []
        for group in TaskBook.grouped(items) { out.append(contentsOf: group.items) }
        return out
    }

    @ViewBuilder
    private func candidateRow(_ item: TaskBook.Item) -> some View {
        TaskRow(item: item, player: sheets.player) { sheets.editing = item }
        HStack(spacing: LL.Space.l) {
            Button("入れる", systemImage: "plus.circle") { change(item.id, .open) }
            Button("違う", systemImage: "xmark", role: .destructive) { sheets.rejecting = item }
        }
        .buttonStyle(.borderless)
        .font(LL.TypeScale.detail)
    }

    private func openRow(_ item: TaskBook.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                change(item.id, .done)
            } label: {
                Image(systemName: "circle").imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("済みにする")
            TaskRow(item: item, player: sheets.player) { sheets.editing = item }
        }
        .swipeActions(edge: .trailing) {
            Button("済み") { change(item.id, .done) }.tint(LL.good)
        }
    }

    private func change(_ id: String, _ state: TaskBook.State) {
        // 頼まれごとをいま済みにしたときだけ、返事の下書きを出す（タスクタブと同じ）
        let before = pipeline.tasks.items.first { $0.id == id }
        withAnimation { pipeline.tasks.set(id, state) }
        if state == .done, let before, before.state != .done, let draft = TaskReply.draft(for: before) {
            sheets.replyDraft = draft
        }
    }
}

/// 自分のタスク（仕事）の直す画面・返事の下書き・「違う」の理由と、帳が変わったときの知らせの頼み直し（タスクタブと同じ）
private struct S30WTaskSheetsModifier: ViewModifier {
    @Environment(Pipeline.self) private var pipeline
    let sheets: S30WTaskSheets

    func body(content: Content) -> some View {
        @Bindable var sheets = sheets
        content
            .onChange(of: pipeline.tasks.version) { pipeline.tasksChanged() }
            .sheet(item: $sheets.editing) { item in
                NavigationStack {
                    TaskEditView(item: item) { saved in
                        if pipeline.tasks.items.contains(where: { $0.id == saved.id }) {
                            pipeline.tasks.update(saved)
                        } else {
                            pipeline.tasks.add([saved])
                        }
                        sheets.editing = nil
                    } onDelete: {
                        if item.source == .manual {
                            pipeline.tasks.delete(item.id)
                        } else {
                            pipeline.tasks.set(item.id, .rejected)
                        }
                        sheets.editing = nil
                    }
                }
            }
            .sheet(item: $sheets.replyDraft) { draft in
                NavigationStack { TaskReplySheet(draft: draft) }
                    .presentationDetents([.medium])
            }
            .confirmationDialog("どう違いましたか", isPresented: rejectingShown, titleVisibility: .visible,
                                presenting: sheets.rejecting) { item in
                ForEach(TaskBook.RejectReason.choices) { reason in
                    Button(reason.label) {
                        withAnimation { pipeline.tasks.reject(item.id, reason: reason) }
                        sheets.rejecting = nil
                    }
                }
                Button("やめる", role: .cancel) { sheets.rejecting = nil }
            }
            .onDisappear { sheets.player.stop() }
    }

    private var rejectingShown: Binding<Bool> {
        Binding(get: { sheets.rejecting != nil }, set: { if !$0 { sheets.rejecting = nil } })
    }
}

// MARK: - 下の段（相手待ち・柱・外）

private struct S30WLowerSections: View {
    let screen: S30WScreen
    let today: String
    /// 押して開け閉めした柱（急ぎの柱は初めから開いている。押すと逆になる）
    @State private var toggled: Set<String> = []

    var body: some View {
        S30WWaitingSection(steps: screen.waiting3, count: screen.waitingCount, ruled: screen.waitingRuled)
        ForEach(Array(screen.pillars.enumerated()), id: \.element.id) { n, p in
            S30WPillarSection(pillar: p, first: n == 0, count: screen.pillars.count, ruled: screen.pillarsRuled,
                              expanded: (p.state == .urgent) != toggled.contains(p.id), today: today) {
                withAnimation {
                    if toggled.contains(p.id) {
                        toggled.remove(p.id)
                    } else {
                        toggled.insert(p.id)
                    }
                }
            }
        }
        if !screen.outside.isEmpty {
            S30WOutsideSection(rows: screen.outside, ruled: screen.outsideRuled)
        }
    }
}

private struct S30WWaitingSection: View {
    let steps: [S30WStep]
    let count: Int
    let ruled: Bool

    var body: some View {
        Section {
            if steps.isEmpty {
                Text("相手を待っているものは届いていません").foregroundStyle(LL.dim)
            }
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: LL.Space.s) {
                    S27WPip(state: step.state, size: 10).padding(.top, 6)
                    VStack(alignment: .leading, spacing: LL.Space.xs) {
                        Text(book.t(step.item.text)).font(LL.TypeScale.detail).foregroundStyle(LL.text)
                        S30WTags(main: step.why, mainColor: step.state.color, rest: step.pillar.map { [book.t($0)] } ?? [])
                        S30WMeta(item: step.item)
                    }
                }
                .padding(.vertical, 2)
                .s30wItemMenu(step.item)
            }
        } header: {
            LLHeader(title: "相手を待っているもの（大事な 3 つ）", symbol: "hourglass", trailing: "全 \(count) 件")
        } footer: {
            if ruled { Text("機械の並べ方: 期限の近い順 → 長く待っている順。") }
        }
    }
}

// MARK: 柱ごとの状況

private struct S30WPillarSection: View {
    let pillar: S30WPillarView
    let first: Bool
    let count: Int
    let ruled: Bool
    let expanded: Bool
    let today: String
    let toggle: () -> Void

    var body: some View {
        Section {
            Button(action: toggle) {
                S30WPillarSummary(pillar: pillar, expanded: expanded)
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "畳みます" : "中身を開きます")
            if expanded {
                S30WPillarInner(pillar: pillar, today: today)
            }
        } header: {
            if first {
                LLHeader(title: "柱ごとの状況（\(count) つ）", symbol: "square.grid.3x2",
                         trailing: ruled ? "機械の並べ方（言葉で分けた）" : "押すと中身")
            }
        }
    }
}

private struct S30WPillarSummary: View {
    let pillar: S30WPillarView
    var expanded = false
    var chevron = true

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.s) {
            HStack(spacing: LL.Space.s) {
                Circle().fill(pillar.state.color).frame(width: 10, height: 10)
                Text(book.t(pillar.name)).font(LL.TypeScale.cardTitle).foregroundStyle(LL.text)
                Spacer(minLength: LL.Space.s)
                S30WBadge(text: S30WRules.pillarLabel(pillar.state), color: pillar.state.color)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(LL.TypeScale.note)
                        .foregroundStyle(LL.dim)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            if let line = pillar.line, !line.isEmpty {
                Text(book.t(line)).font(LL.TypeScale.detail).foregroundStyle(LL.text).multilineTextAlignment(.leading)
            }
            if !pillar.open.isEmpty {
                S27WStateBar(counts: pillar.counts)
                S27WMapText.legend(pillar.counts).font(LL.TypeScale.note)
            }
        }
        .padding(.vertical, LL.Space.xs)
        .contentShape(Rectangle())
    }
}

/// 柱を開いた中（上から 6 つ・あと N 件・6 日以上の数・最近決まったこと・済んだかも・古い）
private struct S30WPillarInner: View {
    let pillar: S30WPillarView
    let today: String

    var body: some View {
        S30WSubhead(title: "開いている件（上から \(S30WRules.pillarTop) つ）")
        if pillar.open.isEmpty {
            Text("開いているものはありません").font(LL.TypeScale.note).foregroundStyle(LL.dim)
        }
        ForEach(pillar.open.prefix(S30WRules.pillarTop)) { item in
            S30WItemLine(item: item, today: today)
        }
        if pillar.hidden > 0 {
            NavigationLink {
                S30WPillarScreen(id: pillar.id)
            } label: {
                Text("あと \(pillar.hidden) 件（この柱の全部）").font(LL.TypeScale.note).foregroundStyle(LL.accent)
            }
        }
        if pillar.oldCount > 0 {
            Text("\(S27WMap.oldDays) 日以上そのまま: \(pillar.oldCount) 件。話に出なくなったものは「古い」の箱へ下がります（自動・戻せる）。")
                .font(LL.TypeScale.note).foregroundStyle(LL.dim)
        }
        if !pillar.decided.isEmpty {
            S30WSubhead(title: "最近決まったこと")
            ForEach(pillar.decided.prefix(3)) { item in S30WDecidedLine(item: item) }
        }
        if !pillar.autoDone.isEmpty {
            S30WAutoBox(title: "済んだかも", symbol: "checkmark.circle", items: pillar.autoDone)
        }
        if !pillar.autoOld.isEmpty {
            S30WAutoBox(title: "古い", symbol: "clock", items: pillar.autoOld)
        }
    }
}

/// 柱の全部（「あと N 件」から）
struct S30WPillarScreen: View {
    let id: String

    var body: some View {
        let today = todayKey()
        let pillar = pillarNow(today)
        LLList {
            if let pillar {
                S30WPillarFull(pillar: pillar, today: today)
            } else {
                Section { LLEmpty(title: "この柱は届いている分にありません", symbol: "square.grid.3x2") }
            }
        }
        .navigationTitle(pillar.map { book.t($0.name) } ?? "柱")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await book.refresh(force: true) }
        .onAppear { Tally.add("s30w.pillar.open") }
    }

    private func pillarNow(_ today: String) -> S30WPillarView? {
        guard let board = book.board else { return nil }
        let screen = S30WRules.screen(board, done: Set(book.localDoneIDs), restored: s30.restoredIDs, today: today)
        return screen.pillars.first { $0.id == id }
    }
}

private struct S30WPillarFull: View {
    let pillar: S30WPillarView
    let today: String

    var body: some View {
        Section {
            S30WPillarSummary(pillar: pillar, chevron: false)
        }
        Section {
            if pillar.open.isEmpty {
                Text("開いているものはありません").foregroundStyle(LL.dim)
            }
            ForEach(pillar.open) { item in S30WItemLine(item: item, today: today) }
        } header: {
            LLHeader(title: "開いている件", symbol: "list.bullet", trailing: "\(pillar.open.count)")
        }
        if !pillar.autoDone.isEmpty {
            Section {
                ForEach(pillar.autoDone) { item in S30WAutoRow(item: item) }
            } header: {
                LLHeader(title: "済んだかも（後の話で済んだと分かったもの）", symbol: "checkmark.circle", trailing: "\(pillar.autoDone.count)")
            } footer: {
                Text("機械が閉じたものです。まだ済んでいなければ「戻す」で開いている件に戻します（この iPhone が覚えます）。")
            }
        }
        if !pillar.autoOld.isEmpty {
            Section {
                ForEach(pillar.autoOld) { item in S30WAutoRow(item: item) }
            } header: {
                LLHeader(title: "古い（しばらく話に出ていないもの）", symbol: "clock", trailing: "\(pillar.autoOld.count)")
            } footer: {
                Text("まだ生きている話なら「戻す」で開いている件に戻します（この iPhone が覚えます）。")
            }
        }
        if !pillar.decided.isEmpty {
            Section {
                ForEach(pillar.decided.prefix(30)) { item in S30WDecidedLine(item: item) }
            } header: {
                LLHeader(title: "決まったこと", symbol: "checkmark.seal", trailing: "\(pillar.decided.count)")
            }
        }
    }
}

/// 柱の中の項目 1 行（四角・文・札・日と出どころ）
private struct S30WItemLine: View {
    let item: S27WItem
    let today: String

    var body: some View {
        let state = S27WMap.state(item, today: today)
        HStack(alignment: .top, spacing: LL.Space.s) {
            S27WPip(state: state, old: S27WMap.isOld(item), size: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: LL.Space.xs) {
                Text(book.t(item.text)).font(LL.TypeScale.detail).foregroundStyle(item.isMaybe ? LL.dim : LL.text)
                S30WTags(main: S30WRules.pillarLabel(state), mainColor: state.color, rest: S30WRules.itemTags(item))
                S30WMeta(item: item)
            }
        }
        .padding(.vertical, 2)
        .s30wItemMenu(item)
    }
}

private struct S30WDecidedLine: View {
    let item: S27WItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
            Text(AppFeeds.monthDay(item.day ?? "")).font(LL.TypeScale.rowNumber).foregroundStyle(LL.good)
                .frame(minWidth: 44, alignment: .leading)
            Text(book.t(item.text)).font(LL.TypeScale.detail).foregroundStyle(item.isMaybe ? LL.dim : LL.text)
        }
        .s30wItemMenu(item)
    }
}

/// 「済んだかも」「古い」の箱（畳んである。戻せる）
private struct S30WAutoBox: View {
    let title: String
    let symbol: String
    let items: [S27WItem]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(items) { item in S30WAutoRow(item: item) }
        } label: {
            Label("\(title) \(items.count) 件", systemImage: symbol)
                .font(LL.TypeScale.note)
                .foregroundStyle(LL.dim)
        }
    }
}

private struct S30WAutoRow: View {
    let item: S27WItem

    var body: some View {
        HStack(alignment: .top, spacing: LL.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.t(item.text)).font(LL.TypeScale.detail).foregroundStyle(LL.dim)
                if let why = item.autoWhy, !why.isEmpty {
                    Text(book.t(why)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
                S30WMeta(item: item)
            }
            Spacer(minLength: LL.Space.s)
            Button("戻す") {
                withAnimation { s30.restore(item.id) }
            }
            .buttonStyle(.borderless)
            .font(LL.TypeScale.note)
            .accessibilityLabel("開いている件に戻す")
        }
    }
}

// MARK: この案件の外に見える話

private struct S30WOutsideSection: View {
    let rows: [S30WOutsideRow]
    let ruled: Bool

    var body: some View {
        Section {
            ForEach(rows) { row in
                NavigationLink {
                    S30WItemsView(title: row.label, items: row.items)
                } label: {
                    LabeledContent(book.t(row.label)) {
                        Text("\(row.items.count) 件")
                    }
                }
            }
        } header: {
            LLHeader(title: "この案件の外に見える話", symbol: "building.2", trailing: ruled ? "機械の並べ方" : "分け直しの候補")
        } footer: {
            Text("柱と案件の分け方が違うときは、Claude に「これは違う」と伝えると、前提のファイルを直して次の作り直しから変わります。")
        }
    }
}

// MARK: - いちばん下（仕事のまとめ・前の一覧）

private struct S30WLastSection: View {
    @Environment(Pipeline.self) private var pipeline
    let screen: S30WScreen?

    var body: some View {
        let count = pipeline.workDigests.entries.count
        Section {
            NavigationLink {
                WorkDigestListView()
            } label: {
                LabeledContent {
                    Text(count == 0 ? "写真・貼り付けから" : "\(count) 件")
                } label: {
                    Label("仕事のまとめ", systemImage: "doc.text")
                }
            }
            .accessibilityIdentifier("s30w.digests")
            if book.offered {
                NavigationLink {
                    S27WHomeView()
                } label: {
                    LLRow(title: "前の一覧", detail: detail, symbol: "list.bullet.rectangle")
                }
            }
        } footer: {
            Text("右上の＋で仕事のまとめを取り込めます。家の PC がすぐ作り直せるときは、取り込んだすぐあとに上の画面が新しくなります。")
        }
    }

    private var detail: String? {
        guard let screen else { return nil }
        return "開いている \(screen.openTotal) 件・トピック \(screen.topicCount) 個"
    }
}

// MARK: - 項目の一覧（根拠の発言・外の話）

struct S30WItemsView: View {
    let title: String
    let items: [S27WItem]

    var body: some View {
        LLList {
            Section {
                if items.isEmpty {
                    Text("届いている分にありません").foregroundStyle(LL.dim)
                }
                ForEach(items) { item in S27WItemRow(item: item, canDone: true) }
            } footer: {
                Text("押したままにすると、元を開く・文をコピーができます。")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s30w.items.open") }
    }
}

// MARK: - 小さな部品

private struct S30WSubhead: View {
    let title: String

    var body: some View {
        Text(title)
            .font(LL.TypeScale.tag)
            .foregroundStyle(LL.dim)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 札を折り返して並べる（いちばん前は状態の色の札）
private struct S30WTags: View {
    let main: String?
    var mainColor: Color = LL.dim
    var rest: [String] = []

    var body: some View {
        if main != nil || !rest.isEmpty {
            FlowLayout(spacing: LL.Space.xs) {
                if let main {
                    S30WTag(text: main, color: mainColor)
                }
                ForEach(rest, id: \.self) { tag in S30WTag(text: tag, color: nil) }
            }
        }
    }
}

private struct S30WTag: View {
    let text: String
    let color: Color?

    var body: some View {
        Text(text)
            .font(LL.TypeScale.tag)
            .foregroundStyle(color ?? LL.dim)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: LL.Radius.chip).strokeBorder(color ?? LL.line, lineWidth: LL.Stroke.thin))
    }
}

/// 守4 日と出どころ（「11/24 15:30・会話・見本さん」。伏せるときは名前を伏せる）
private struct S30WMeta: View {
    let item: S27WItem

    var body: some View {
        let meta = S27WRules.meta(item, mask: book.activeMask)
        if !meta.isEmpty {
            Text(meta).font(LL.TypeScale.note).foregroundStyle(LL.dim)
        }
        S31AVoiceMark(item: item)  // s31 声でも話していた候補（S31AViews.swift）
    }
}

private extension View {
    /// 押したまま: 元を開く・文をコピー（S27WItemRow と同じ）
    func s30wItemMenu(_ item: S27WItem) -> some View {
        contextMenu {
            if let url = S27WRules.openable(item.link) {
                Link(destination: url) { Label("元を開く", systemImage: "arrow.up.right.square") }
            }
            Button("文をコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
        }
    }
}

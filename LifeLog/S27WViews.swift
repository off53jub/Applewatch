import LocalAuthentication
import PhotosUI
import SwiftUI
import UIKit

// s27（2026-11-25）の A の画面:「仕事」— 出社前の 1 枚（場2）・きのうから動いたもの（場4）・自分が止めている 3 つ（動7）・
// 案件のカード（場1・場3・案9・案6）・案件の中身・人（人2・人5・人8）・他の案件（他2）・副業（材8）・確かめ（守6）・
// 引く（場7）・次の会議の案件の 1 枚（場8）・社内のお知らせを入れる（他3・初めはオフ）。
// 入口は「今日」の上のほうの 1 行と lifelog://work（K6）だけ（タブは足さない。本人が場所を決めていないので、いちばん小さい形）。
// 守1: ここの中身はウィジェット・通知に出さない。守2: Face ID の設定がオンなら開くときに確かめる・伏せる切り替え。
// 守3: 人を数や順位で並べない（人ごとの数は、その人の画面の中だけ）。守4: どの項目にも日と出どころ・「たぶん」。
// 決まりは S27WRules.swift、動きは S27WBook.swift。

@MainActor private var book: S27WBook { S27WBook.shared }

@MainActor
private enum S27WFormat {
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

    static func today() -> String { ReviewRules.dayKey(.now) }
}

// MARK: - 「今日」の 1 行（入口）

struct S27WTodaySection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        if book.offered, let board = book.board {
            Section {
                Button {
                    Tally.add("s27w.today.tap")
                    pipeline.openRoute(.work(.home))
                } label: {
                    HStack {
                        LLRow(title: S27WRules.todayLine(board), detail: detail(board), symbol: "briefcase")
                        Image(systemName: "chevron.right").font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detail(_ board: S27WBoard) -> String? {
        let stuck = board.today.stuckByMe.filter { !book.isDone($0) }.count
        let confirm = book.openConfirm.count
        var parts: [String] = []
        if stuck > 0 { parts.append("自分が止めている \(stuck)") }
        if confirm > 0 { parts.append("確かめ \(confirm)") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

// MARK: - 場8 次の会議の案件の 1 枚（「次の予定の前に」の近く）

struct S27WPrepSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        if book.offered, let board = book.board, let meeting = S27WRules.nextMeeting(board.today.meetings),
           let prep = meeting.prep, !prep.isEmpty {
            Section {
                S27WMeetingLine(meeting: meeting)
                S27WItemGroup(title: "前回決まったこと", items: prep.lastDecided)
                S27WItemGroup(title: "まだ決まっていないこと", items: prep.open)
                S27WItemGroup(title: "自分の宿題", items: prep.myHomework, canDone: true)
                if !prep.ask.isEmpty {
                    S27WLines(title: "この会議で聞くこと", lines: prep.ask.map { book.t($0) })
                }
                if let pid = meeting.projectID {
                    Button("案件の中身を開く", systemImage: "briefcase") { pipeline.openRoute(.work(.project(pid))) }
                        .buttonStyle(.borderless)
                }
            } header: {
                LLHeader(title: "次の会議の前に（案件）", symbol: "person.3")
            }
            .onAppear { Tally.add("s27w.prep.shown") }
        }
    }
}

// MARK: - 入口（シートの中）

struct S27WRootView: View {
    let link: S27WLink

    var body: some View {
        Group {
            switch link {
            case .home: S27WHomeView()
            case .project(let id): S27WProjectView(id: id)
            case .person(let id): S27WPersonView(id: id)
            case .confirm: S27WConfirmView()
            case .notice: S27WNoticeImportView()
            }
        }
        .modifier(S27WGate())
        .onAppear { book.opened() }
    }
}

/// 守2: Face ID の設定（開くときに Face ID）がオンなら、仕事の画面を開くときにも確かめる。
/// 裏から戻ったときは、アプリ全体の鍵（AppLock）が確かめるので、ここでは重ねて聞かない
struct S27WGate: ViewModifier {
    @AppStorage(AppLock.key) private var lockOn = false
    @State private var open = false
    @State private var asking = false
    @State private var failure: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if !lockOn || open {
            content
        } else {
            VStack(spacing: LL.Space.l) {
                Image(systemName: "lock.fill").font(LL.TypeScale.number).foregroundStyle(LL.accent)
                Text("仕事の画面は鍵がかかっています").font(LL.TypeScale.cardTitle)
                Button("Face ID で開く") { unlock() }
                    .buttonStyle(.borderedProminent)
                if let failure {
                    Text(failure).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LL.bg.ignoresSafeArea())
            .onAppear { unlock() }
        }
    }

    private func unlock() {
        guard !asking else { return }
        asking = true
        let context = LAContext()
        context.localizedCancelTitle = "やめる"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "仕事の画面を開くために確かめます") { ok, error in
            Task { @MainActor in
                asking = false
                if ok {
                    open = true
                    failure = nil
                } else {
                    failure = error?.localizedDescription
                }
            }
        }
    }
}

// MARK: - 仕事の画面

struct S27WHomeView: View {
    @State private var query = ""
    @State private var results: [S27WAnswer]?
    @State private var fromPC = false
    @State private var searching = false

    var body: some View {
        LLList {
            if !book.offered {
                Section {
                    LLEmpty(title: "家の PC に仕事の口がまだありません", symbol: "briefcase",
                            detail: "家の PC の LifeLog PC が新しくなると、ここに仕事のいまの状態が出ます。")
                }
            } else if let board = book.board {
                S27WCopySection(board: board)
                if let results {
                    S27WAnswersSection(query: query, answers: results, fromPC: fromPC)
                }
                // 2026-11-26 作り直し: 案件 → トピック → 課題の地図（S27WMapViews.swift）。前の案件の並び・他の案件の箱はここから外した。
                // 同じ日の夜、本人「長すぎてどこにあるかわからなかった」→ いちばん上へ。下の一覧は 3 件ずつに畳む（S27WItemGroup）
                S27WGroupsSection(board: board)
                S27WMorningSection(today: board.today)
                S27WStuckSection(items: board.today.stuckByMe)
                S27WDiffSection(diff: board.diff)
                S27WConfirmEntrySection()
                S27WSideSection(side: board.side, projects: S27WRules.sortedByMoved(board.projects, kind: "side"))
                S27WPeopleSection(people: S27WRules.sortedPeople(board.people))
            } else {
                Section {
                    LLEmpty(title: "まだ材料がありません", symbol: "briefcase",
                            detail: "家の PC が仕事の台帳を配りはじめると、ここに出ます。つながらないときは前に届いた分を見せます。")
                }
            }
            S27WScreenSettingsSection()
        }
        .navigationTitle("仕事")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "案件・人・チケット番号で引く")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: query) { _, q in
            if q.trimmingCharacters(in: .whitespaces).isEmpty { results = nil }
        }
        .refreshable { await book.refresh(force: true) }
        .countsOpen("work")
    }

    private func runSearch() {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty, !searching else { return }
        searching = true
        Task {
            let found = await book.ask(q)
            results = found.answers
            fromPC = found.fromPC
            searching = false
        }
    }
}

/// 写しの新しさ（つながらないときは前の写しだと分かるように）
private struct S27WCopySection: View {
    let board: S27WBoard

    var body: some View {
        Section {
            if book.offline {
                S24RoleLabel(text: "家の PC につながらないので、前に届いた分を見せています", role: .wait)
            }
            Text(stamp).font(LL.TypeScale.note).foregroundStyle(LL.dim)
        }
    }

    private var stamp: String {
        var parts: [String] = []
        if let at = book.fetchedAt { parts.append("受け取った: " + S27WFormat.stamp.string(from: at)) }
        if let asOf = board.asOf { parts.append(AppFeeds.monthDay(asOf) + " の分") }
        if book.maskOn { parts.append("顧客名と人名を伏せています") }
        return parts.isEmpty ? "家の PC から届いた分" : parts.joined(separator: "・")
    }
}

// MARK: 場7 引いた答え

private struct S27WAnswersSection: View {
    let query: String
    let answers: [S27WAnswer]
    let fromPC: Bool

    var body: some View {
        Section {
            if answers.isEmpty {
                Text("見つかりませんでした").foregroundStyle(LL.dim)
            }
            ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                S27WAnswerRow(answer: answer)
            }
        } header: {
            LLHeader(title: "「" + query + "」", symbol: "magnifyingglass", trailing: fromPC ? "家の PC から" : "この iPhone に届いている分から")
        }
    }
}

private struct S27WAnswerRow: View {
    let answer: S27WAnswer

    var body: some View {
        if let pid = answer.projectID, book.board?.project(pid) != nil {
            NavigationLink { S27WProjectView(id: pid) } label: { content }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            Text(book.t(answer.name)).font(LL.TypeScale.cardTitle)
            if let status = answer.statusLine, !status.isEmpty {
                Text(book.t(status)).font(LL.TypeScale.detail)
            }
            if let decided = answer.lastDecided {
                Text("最後に決まったこと").font(LL.TypeScale.tag).foregroundStyle(LL.dim)
                S27WItemRow(item: decided)
            }
            if !answer.open.isEmpty {
                Text("開いているもの \(answer.open.count) 件").font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
    }
}

// MARK: 場2 出社前の 1 枚

private struct S27WMorningSection: View {
    let today: S27WToday
    @State private var copied = false

    var body: some View {
        Section {
            S27WItemGroup(title: "今日の宿題", items: today.homework, canDone: true, emptyText: "今日の宿題はありません")
            if today.meetings.isEmpty {
                S27WSubhead(title: "今日の会議", note: "ありません")
            } else {
                S27WSubhead(title: "今日の会議")
                ForEach(Array(today.meetings.enumerated()), id: \.offset) { _, m in
                    S27WMeetingLine(meeting: m)
                }
            }
            S27WItemGroup(title: "自分が待たせている", items: today.waitingOnMe, emptyText: "ありません")
            S27WItemGroup(title: "相手を待っている", items: today.waitingOnOthers, emptyText: "ありません")
            if !today.standup.isEmpty {
                S27WLines(title: "朝会で言う 3 行", lines: today.standup.map { book.t($0) })
                Button(copied ? "コピーしました" : "3 行をコピー", systemImage: "doc.on.doc") {
                    // 貼る先は職場の道具なので、伏せる切り替えに関係なく元の文をコピーする
                    UIPasteboard.general.string = today.standup.joined(separator: "\n")
                    copied = true
                    Tally.add("s27w.standup.copy")
                }
                .buttonStyle(.borderless)
            }
        } header: {
            LLHeader(title: "出社前の 1 枚", symbol: "sun.horizon")
        }
    }
}

private struct S27WMeetingLine: View {
    let meeting: S27WMeeting

    var body: some View {
        let start = S27WRules.date(meeting.start).map { S27WFormat.time.string(from: $0) } ?? "時刻が分からない"
        let end = S27WRules.date(meeting.end).map { "〜" + S27WFormat.time.string(from: $0) } ?? "〜"
        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
            Text(start + end).font(LL.TypeScale.rowNumber).foregroundStyle(LL.dim)
            Text(book.t(meeting.title)).font(LL.TypeScale.body)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 動7 自分が止めている 3 つ

private struct S27WStuckSection: View {
    let items: [S27WItem]

    var body: some View {
        let list = S27WRules.stuck(items.filter { !book.isDone($0) })
        if !list.isEmpty {
            Section {
                ForEach(list) { item in S27WItemRow(item: item, canDone: true) }
            } header: {
                LLHeader(title: "自分が止めている 3 つ", symbol: "hand.raised")
            } footer: {
                Text("自分が動く番の宿題・返事を、古い順に 3 つまで。今日の三つとは別にしていません（材料です）。")
            }
        }
    }
}

// MARK: 場4 きのうから動いたもの

private struct S27WDiffSection: View {
    let diff: S27WDiff?

    var body: some View {
        Section {
            if let diff, !diff.isEmpty {
                S27WItemGroup(title: "新しく決まった", items: diff.decided)
                S27WItemGroup(title: "新しい宿題・未決", items: diff.added)
                S27WItemGroup(title: "閉じた", items: diff.closed)
            } else {
                Text("前の勤務日から動いたものはありません").foregroundStyle(LL.dim)
            }
        } header: {
            LLHeader(title: "きのうから動いたもの", symbol: "arrow.triangle.2.circlepath",
                     trailing: diff?.since.map { AppFeeds.monthDay($0) + " から" })
        }
    }
}

// MARK: 守6 確かめの入口

private struct S27WConfirmEntrySection: View {
    var body: some View {
        let count = book.openConfirm.count
        if count > 0 {
            Section {
                NavigationLink { S27WConfirmView() } label: {
                    LLRow(title: "確かめ \(count) 件（まとめて 1 回）",
                          detail: "案件のまとめ・人の所属など。答えないものは機械の候補のまま動きます。", symbol: "checkmark.seal")
                }
            }
        }
    }
}

// MARK: 場1 案件のカード

struct S27WProjectCard: View {
    let project: S27WProject

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(book.name(project)).font(LL.TypeScale.cardTitle).foregroundStyle(LL.text)
                Spacer(minLength: LL.Space.s)
                S27WSignalChip(signal: project.signalKind)
            }
            if let client = book.client(project) {
                Text(client).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if let status = project.statusLine, !status.isEmpty {
                Text(book.t(status)).font(LL.TypeScale.detail).foregroundStyle(LL.text)
            }
            Text(S27WRules.countsLine(project)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            if let m = project.milestone {
                Label(S27WRules.milestoneLine(m, today: S27WFormat.today()), systemImage: "flag")
                    .font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if !project.people.isEmpty {
                Text(peopleLine).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
        .padding(.vertical, 2)
    }

    private var peopleLine: String {
        var names: [String] = []
        for ref in project.people.prefix(3) { names.append(book.name(ref)) }
        return "主な相手: " + names.joined(separator: "、")
    }
}

/// 案件の信号（色と形の両方で分かるように。赤・オレンジは色の役割のまま）
struct S27WSignalChip: View {
    let signal: S27WSignal

    var body: some View {
        if let role = signal.role {
            LLRoleChip(text: signal.label, role: role)
        } else {
            let color: Color = signal == .green ? LL.good : LL.dim
            Label(signal.label, systemImage: signal.symbol)
                .labelStyle(.titleAndIcon)
                .font(LL.TypeScale.tag)
                .foregroundStyle(color)
                .padding(.horizontal, LL.Space.s)
                .padding(.vertical, 2)
                .background(color.opacity(0.14), in: Capsule())
                .accessibilityLabel(signal.label)
        }
    }
}

// MARK: 副業

private struct S27WSideSection: View {
    let side: S27WSide?
    let projects: [S27WProject]

    var body: some View {
        if side != nil || !projects.isEmpty {
            Section {
                if let side {
                    let role: LLRole = side.status == "moved" ? .machine : (side.status == "stopped" ? .wait : .ask)
                    LLRow(title: "副業の件: " + S27WRules.sideStatusLabel(side.status),
                          detail: side.lastDay.map { "最後に動いた日 " + AppFeeds.monthDay($0) }, role: role)
                    ForEach(side.items) { item in S27WItemRow(item: item) }
                }
                ForEach(projects) { p in
                    NavigationLink { S27WProjectView(id: p.id) } label: { S27WProjectCard(project: p) }
                }
            } header: {
                LLHeader(title: "副業", symbol: "house")
            } footer: {
                Text("本業の案件とは混ぜずに、別の段に出しています。")
            }
        }
    }
}

// MARK: 人2 人の一覧（名前の順だけ。数・順位は出さない＝守3）

private struct S27WPeopleSection: View {
    let people: [S27WPerson]

    var body: some View {
        if !people.isEmpty {
            Section {
                ForEach(people) { p in
                    NavigationLink { S27WPersonView(id: p.id) } label: {
                        LLRow(title: book.name(p), detail: S27WPersonLine.text(p), symbol: "person")
                    }
                }
            } header: {
                LLHeader(title: "人", symbol: "person.2")
            } footer: {
                Text("名前の順です。人ごとの数は、その人の画面の中だけに出します。")
            }
        }
    }
}

private enum S27WPersonLine {
    @MainActor
    static func text(_ p: S27WPerson) -> String {
        var parts: [String] = [S27WRules.orgLabel(book.org(p))]
        if let team = book.team(p) { parts.append(team) }
        if let role = book.role(p) { parts.append(role) }
        return parts.joined(separator: "・")
    }
}

// MARK: - 項目の行（守4: 日と出どころ・たぶん）

struct S27WItemRow: View {
    let item: S27WItem
    var canDone = false

    var body: some View {
        let done = book.isDone(item)
        let meta = S27WRules.meta(item, mask: book.activeMask)
        let chips = S27WRules.chips(item)
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                if canDone && item.isHomework {
                    Button {
                        book.setDone(item, done: !done)
                    } label: {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? LL.good : LL.accent)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(done ? "済みを戻す" : "済みにする")
                }
                Text(book.t(item.text))
                    .font(LL.TypeScale.body)
                    .foregroundStyle(done || item.isMaybe ? LL.dim : LL.text)
                    .strikethrough(done)
            }
            if !meta.isEmpty {
                Text(meta).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            S31AVoiceMark(item: item)  // s31 声でも話していた候補（S31AViews.swift）
            if !chips.isEmpty {
                S27WChips(chips: chips)
            }
        }
        .contextMenu {
            if let url = S27WRules.openable(item.link) {
                Link(destination: url) { Label("元を開く", systemImage: "arrow.up.right.square") }
            }
            Button("文をコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
        }
    }
}

private struct S27WChips: View {
    let chips: [String]

    var body: some View {
        HStack(spacing: LL.Space.xs) {
            ForEach(chips, id: \.self) { chip in
                S27WChip(text: chip)
            }
        }
    }
}

private struct S27WChip: View {
    let text: String

    var body: some View {
        if text == "たぶん" {
            CertaintyBadge(certainty: .guess, text: text)
        } else if text == "自分の番" {
            LLRoleChip(text: text, role: .act)
        } else if text == "相手待ち" {
            LLRoleChip(text: text, role: .wait)
        } else {
            Text(text)
                .font(LL.TypeScale.tag)
                .foregroundStyle(LL.dim)
                .padding(.horizontal, LL.Space.s)
                .padding(.vertical, 2)
                .background(LL.surface2, in: Capsule())
        }
    }
}

/// 小見出しと項目の行
private struct S27WItemGroup: View {
    let title: String
    let items: [S27WItem]
    var canDone = false
    var emptyText: String?
    /// 長い一覧は初めの数件だけ（2026-11-26。本人「長すぎてどこにあるかわからなかった」）
    @State private var expanded = false

    var body: some View {
        if !items.isEmpty {
            let fold = S27WMap.fold(items.count, expanded: expanded)
            S27WSubhead(title: title, note: "\(items.count)")
            ForEach(items.prefix(fold.shown)) { item in S27WItemRow(item: item, canDone: canDone) }
            if items.count > S27WMap.foldLimit {
                Button(expanded ? "畳む" : "あと \(fold.hidden) 件を見る",
                       systemImage: expanded ? "chevron.up" : "chevron.down") {
                    withAnimation { expanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(LL.TypeScale.note)
            }
        } else if let emptyText {
            S27WSubhead(title: title, note: emptyText)
        }
    }
}

private struct S27WSubhead: View {
    let title: String
    var note: String?

    var body: some View {
        HStack {
            Text(title).font(LL.TypeScale.section).foregroundStyle(LL.text)
            Spacer()
            if let note { Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct S27WLines: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            Text(title).font(LL.TypeScale.section)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text("・" + line).font(LL.TypeScale.detail)
            }
        }
    }
}

// MARK: - 案件の中身

struct S27WProjectView: View {
    let id: String
    @State private var editing = false
    @State private var pasting = false

    var body: some View {
        LLList {
            if let p = book.board?.project(id) {
                S27WProjectBody(project: p, paste: { pasting = true })
            } else {
                Section { LLEmpty(title: "この案件は届いている分にありません", symbol: "briefcase") }
            }
        }
        .navigationTitle(book.board?.project(id).map { book.name($0) } ?? "案件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if book.board?.project(id) != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if S27WRules.canEdit(id) {
                            Button("名前・顧客・種類を直す", systemImage: "pencil") { editing = true }
                        }
                        Button("数を貼る", systemImage: "number") { pasting = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("この案件の操作")
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                if let p = book.board?.project(id) { S27WEditProjectSheet(project: p) }
            }
            .llRoot()
        }
        .sheet(isPresented: $pasting) {
            NavigationStack { S27WNumbersSheet(projectID: id) }
                .llRoot()
        }
        .onAppear { Tally.add("s27w.project.open") }
    }
}

private struct S27WProjectBody: View {
    let project: S27WProject
    let paste: () -> Void

    var body: some View {
        Section {
            HStack {
                S27WSignalChip(signal: project.signalKind)
                Spacer()
                Text(S27WRules.projectKindLabel(book.field(project.id, "kind") ?? project.kind))
                    .font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if let client = book.client(project) {
                LLRow(title: "顧客", value: client)
            }
            if let status = project.statusLine, !status.isEmpty {
                Text(book.t(status)).font(LL.TypeScale.body)
            }
            Text(S27WRules.countsLine(project)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            if let m = project.milestone {
                Label(S27WRules.milestoneLine(m, today: S27WFormat.today()), systemImage: "flag")
            }
        } header: {
            LLHeader(title: "いまの状況", symbol: "briefcase")
        }
        S27WProgressSection(progress: project.progress, paste: paste)
        let open = project.items.filter { $0.kind != "decided" }
        Section {
            if open.isEmpty { Text("開いているものはありません").foregroundStyle(LL.dim) }
            ForEach(open) { item in S27WItemRow(item: item, canDone: true) }
        } header: {
            LLHeader(title: "開いているもの", symbol: "tray", trailing: open.isEmpty ? nil : "\(open.count)")
        }
        if !project.risk.isEmpty {
            Section {
                ForEach(Array(project.risk.enumerated()), id: \.offset) { _, r in
                    S24RoleLabel(text: book.t(r), role: .act)
                }
            } header: {
                LLHeader(title: "リスクの芽", symbol: "exclamationmark.triangle")
            } footer: {
                Text("同じ未決が何度も出た・期限が延びた、などから機械が拾った印です（しきい値は仮）。")
            }
        }
        if !project.conflicts.isEmpty {
            Section {
                ForEach(Array(project.conflicts.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: LL.Space.s) {
                        Text("前").font(LL.TypeScale.tag).foregroundStyle(LL.dim)
                        S27WItemRow(item: c.a)
                        Text("あと").font(LL.TypeScale.tag).foregroundStyle(LL.dim)
                        S27WItemRow(item: c.b)
                    }
                }
            } header: {
                LLHeader(title: "決まったことの食い違い", symbol: "arrow.left.arrow.right")
            } footer: {
                Text("どちらが正しいかは決めていません。両方の発言と日を並べています。")
            }
        }
        S27WTeamSection(project: project)
        if !project.heard.isEmpty {
            Section {
                ForEach(Array(project.heard.enumerated()), id: \.offset) { _, h in S27WHeardRow(heard: h) }
            } header: {
                LLHeader(title: "聞いた話", symbol: "ear")
            }
        }
        if !project.timeline.isEmpty {
            Section {
                ForEach(project.timeline) { item in S27WItemRow(item: item) }
            } header: {
                LLHeader(title: "年表（新しい 30 件）", symbol: "clock.arrow.circlepath")
            } footer: {
                Text("どの項目にも、日と出どころを付けています。根拠の言葉が記録に無いものは「たぶん」です。")
            }
        }
    }
}

/// 案6 進みの線（数が 2 つ以上あるときだけ）と、数を貼る口
private struct S27WProgressSection: View {
    let progress: [S27WProgress]
    let paste: () -> Void

    var body: some View {
        let series = S27WRules.series(progress)
        Section {
            ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: LL.Space.xs) {
                    Text(book.t(s.label)).font(LL.TypeScale.section)
                    LLTrendChart(points: points(s))
                }
            }
            Button("数を貼る（会議で言った数・表の数）", systemImage: "number") { paste() }
                .buttonStyle(.borderless)
        } header: {
            LLHeader(title: "進み", symbol: "chart.xyaxis.line")
        } footer: {
            Text(series.isEmpty ? "数がまだ 2 つそろっていないので、線は出していません。" : "会議で言った数と、貼った数からの線です。")
        }
    }

    private func points(_ s: S27WRules.Series) -> [LLTrendPoint] {
        var out: [LLTrendPoint] = []
        for p in s.points {
            if let day = S27WRules.day(p.day) { out.append(LLTrendPoint(day: day, value: p.value)) }
        }
        return out
    }
}

/// 人8 体制の図（だれが何の担当か。直すのは人の画面から）
private struct S27WTeamSection: View {
    let project: S27WProject

    var body: some View {
        if !project.people.isEmpty {
            Section {
                ForEach(Array(project.people.enumerated()), id: \.offset) { _, ref in
                    if book.board?.person(ref.id) != nil {
                        NavigationLink { S27WPersonView(id: ref.id) } label: { row(ref) }
                    } else {
                        row(ref)
                    }
                }
            } header: {
                LLHeader(title: "人と担当", symbol: "person.3")
            } footer: {
                Text("会話から起こした表です。違っていれば、人の画面の「直す」から直せます。")
            }
        }
    }

    private func row(_ ref: S27WPersonRef) -> some View {
        LLRow(title: book.name(ref), value: ref.role.map { book.t($0) })
    }
}

private struct S27WHeardRow: View {
    let heard: S27WHeard

    var body: some View {
        let fresh = S27WRules.freshness(day: heard.day, old: heard.old, today: S27WFormat.today())
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(book.t(heard.text)).font(LL.TypeScale.body).foregroundStyle(fresh == .fresh ? LL.text : LL.dim)
                if fresh == .old { CertaintyBadge(certainty: .stopped, text: "古い") }
            }
            Text(S27WRules.heardMeta(heard, mask: book.activeMask)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
        }
    }
}

// MARK: - 人の中身（人2・人5。数はこの画面の中だけ＝守3）

struct S27WPersonView: View {
    let id: String
    @State private var editing = false

    var body: some View {
        LLList {
            if let p = book.board?.person(id) {
                S27WPersonBody(person: p)
            } else {
                Section { LLEmpty(title: "この人は届いている分にありません", symbol: "person") }
            }
        }
        .navigationTitle(book.board?.person(id).map { book.name($0) } ?? "人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if book.board?.person(id) != nil && S27WRules.canEdit(id) {
                ToolbarItem(placement: .primaryAction) {
                    Button("直す") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                if let p = book.board?.person(id) { S27WEditPersonSheet(person: p) }
            }
            .llRoot()
        }
        .onAppear { Tally.add("s27w.person.open") }
    }
}

private struct S27WPersonBody: View {
    let person: S27WPerson

    var body: some View {
        Section {
            LLRow(title: "所属", value: S27WRules.orgLabel(book.org(person)))
            if let team = book.team(person) { LLRow(title: "チーム", value: team) }
            if let role = book.role(person) { LLRow(title: "役割", value: role) }
            if let last = person.lastTalk {
                LLRow(title: "最後に話した日", value: AppFeeds.monthDay(last))
            }
            if person.quiet == true {
                S24RoleLabel(text: "しばらく話していません（仮 2 週間）", role: .ask)
            }
            if book.edits[person.id] != nil {
                Text("直した欄は家の PC に送りました（反映を待つあいだは、この端末で直した値を見せます）。")
                    .font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        } header: {
            LLHeader(title: "この人", symbol: "person")
        }
        Section {
            LLRow(title: "自分が動く番", value: "\(person.ball.me)", role: person.ball.me > 0 ? LLRole.act : nil)
            LLRow(title: "相手の返事待ち", value: "\(person.ball.them)", role: person.ball.them > 0 ? LLRole.wait : nil)
        } header: {
            LLHeader(title: "自分とのあいだのボール", symbol: "arrow.left.arrow.right")
        }
        S27WPersonRecentSection(person: person)
        if !person.theirHomework.isEmpty {
            Section {
                ForEach(person.theirHomework) { item in S27WItemRow(item: item) }
            } header: {
                LLHeader(title: "この人が抱えている宿題", symbol: "tray")
            }
        }
        if !person.promises.mine.isEmpty || !person.promises.theirs.isEmpty {
            Section {
                if !person.promises.mine.isEmpty {
                    S27WSubhead(title: "自分が言ったこと")
                    ForEach(person.promises.mine) { item in S27WItemRow(item: item, canDone: true) }
                }
                if !person.promises.theirs.isEmpty {
                    S27WSubhead(title: "この人が言ったこと")
                    ForEach(person.promises.theirs) { item in S27WItemRow(item: item) }
                }
            } header: {
                LLHeader(title: "まだ済んでいない約束", symbol: "handshake")
            }
        }
        if !person.expertIn.isEmpty {
            Section {
                Text(person.expertIn.map { book.t($0) }.joined(separator: "、"))
            } header: {
                LLHeader(title: "よく話している話題", symbol: "lightbulb")
            } footer: {
                Text("聞くときの手がかりです。詳しさの点数ではありません。")
            }
        }
    }
}

private struct S27WPersonRecentSection: View {
    let person: S27WPerson

    var body: some View {
        let recent = Array(person.recent.prefix(S27WRules.recentLimit))
        let projects = person.projects.compactMap { book.board?.project($0) }
        if !recent.isEmpty || !projects.isEmpty {
            Section {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, r in
                    LLRow(title: book.t(r.title), detail: r.day.map { AppFeeds.monthDay($0) })
                }
                ForEach(projects) { p in
                    NavigationLink { S27WProjectView(id: p.id) } label: { LLRow(title: book.name(p), symbol: "briefcase") }
                }
            } header: {
                LLHeader(title: "最近の案件と話", symbol: "clock")
            }
        }
    }
}

// MARK: - 人8 直す口（K4 の work_edit）

private struct S27WEditPersonSheet: View {
    let person: S27WPerson
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var team = ""
    @State private var role = ""
    @State private var org = "unknown"
    @State private var note: String?

    var body: some View {
        LLForm {
            Section {
                TextField("名前", text: $name)
                TextField("チーム", text: $team)
                TextField("役割", text: $role)
                Picker("所属", selection: $org) {
                    ForEach(S27WRules.orgs, id: \.self) { Text(S27WRules.orgLabel($0)).tag($0) }
                }
            } footer: {
                Text("直した欄だけを家の PC に送ります。人をまとめたり、名前を勝手に変えたりはしません。")
            }
            if let note { Text(note).foregroundStyle(LL.dim) }
        }
        .navigationTitle("人を直す")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("送る") { save() } }
        }
        .onAppear {
            name = book.field(person.id, "name") ?? person.name
            team = book.field(person.id, "team") ?? person.team ?? ""
            role = book.field(person.id, "role") ?? person.role ?? ""
            org = book.field(person.id, "org") ?? person.org ?? "unknown"
            if !S27WRules.orgs.contains(org) { org = "unknown" }
        }
    }

    private func save() {
        var old: [String: String] = ["name": person.name, "team": person.team ?? "", "role": person.role ?? ""]
        old["org"] = person.org ?? "unknown"
        let new: [String: String] = ["name": name, "team": team, "role": role, "org": org]
        let changes = S27WRules.changed(old: old, new: new)
        if changes.isEmpty {
            dismiss()
        } else if book.edit(id: person.id, changes: changes) {
            dismiss()
        } else {
            note = "送れる形になっていません（名前は空にできません）。"
        }
    }
}

private struct S27WEditProjectSheet: View {
    let project: S27WProject
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var client = ""
    @State private var kind = "mine"
    @State private var note: String?

    var body: some View {
        LLForm {
            Section {
                TextField("案件の名前", text: $name)
                TextField("顧客", text: $client)
                Picker("種類", selection: $kind) {
                    ForEach(S27WRules.projectKinds, id: \.self) { Text(S27WRules.projectKindLabel($0)).tag($0) }
                }
            } footer: {
                Text("直した欄だけを家の PC に送ります。案件をまとめるのは「確かめ」の答えで決めます。")
            }
            if let note { Text(note).foregroundStyle(LL.dim) }
        }
        .navigationTitle("案件を直す")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("送る") { save() } }
        }
        .onAppear {
            name = book.field(project.id, "name") ?? project.name
            client = book.field(project.id, "client") ?? project.client ?? ""
            kind = book.field(project.id, "kind") ?? project.kind
            if !S27WRules.projectKinds.contains(kind) { kind = "mine" }
        }
    }

    private func save() {
        let old: [String: String] = ["name": project.name, "client": project.client ?? "", "kind": project.kind]
        let new: [String: String] = ["name": name, "client": client, "kind": kind]
        let changes = S27WRules.changed(old: old, new: new)
        if changes.isEmpty {
            dismiss()
        } else if book.edit(id: project.id, changes: changes) {
            dismiss()
        } else {
            note = "送れる形になっていません（名前は空にできません）。"
        }
    }
}

// MARK: - 案6 数を貼る（K4 の work_numbers）

private struct S27WNumbersSheet: View {
    let projectID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var note: String?

    var body: some View {
        LLForm {
            Section {
                TextEditor(text: $text).frame(minHeight: 200)
                PasteButton(payloadType: String.self) { strings in
                    let pasted = strings.joined(separator: "\n")
                    Task { @MainActor in text = text.isEmpty ? pasted : text + "\n" + pasted }
                }
            } header: {
                Text("会議で言った数・表の数")
            } footer: {
                Text("ケースの消化・NG・残り などを、そのまま貼ってください。家の PC が数を拾って線にします（週に 1 回くらいで十分です）。")
            }
            if let note { Text(note).foregroundStyle(LL.dim) }
        }
        .navigationTitle("数を貼る")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("送る") {
                    if book.pasteNumbers(projectID: projectID, text: text) {
                        dismiss()
                    } else {
                        note = "送れませんでした（空か、長すぎます）。"
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

// MARK: - 守6 まとめて 1 回の確かめ（K3 → K4 の work_confirm）

struct S27WConfirmView: View {
    @State private var picks: [String: String] = [:]
    @State private var note: String?

    var body: some View {
        let items = book.openConfirm
        LLList {
            if items.isEmpty {
                Section { LLEmpty(title: "いま確かめることはありません", symbol: "checkmark.seal") }
            } else {
                Section {
                    Button("機械の候補のままで、全部よい", systemImage: "checkmark.circle") {
                        for item in items {
                            if let d = item.defaultValue, picks[item.id] == nil { picks[item.id] = d }
                        }
                    }
                    if let note { Text(note).foregroundStyle(LL.dim) }
                } footer: {
                    Text("選んだものだけを、最後に 1 回で送ります。答えないものは機械の候補のまま動きます（人・案件を勝手にまとめません）。")
                }
            }
            ForEach(items) { item in
                S27WConfirmRow(item: item, pick: picks[item.id]) { value in
                    picks[item.id] = picks[item.id] == value ? nil : value
                }
            }
        }
        .navigationTitle("確かめ（まとめて 1 回）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("送る（\(picks.count)）") {
                    let sent = book.answerConfirm(picks)
                    picks = [:]
                    note = "\(sent) 件を送りました。"
                }
                .disabled(picks.isEmpty)
            }
        }
        .onAppear { Tally.add("s27w.confirm.open") }
    }
}

private struct S27WConfirmRow: View {
    let item: S27WConfirmItem
    let pick: String?
    let choose: (String) -> Void

    var body: some View {
        Section {
            Text(book.t(item.question)).font(LL.TypeScale.body)
            ForEach(Array(item.evidence.prefix(3).enumerated()), id: \.offset) { _, e in
                Text("・" + book.t(e)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            ForEach(item.choices, id: \.value) { choice in
                Button {
                    choose(choice.value)
                } label: {
                    HStack {
                        Image(systemName: pick == choice.value ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(pick == choice.value ? LL.accent : LL.dim)
                        Text(book.t(choice.label)).foregroundStyle(LL.text)
                        if item.defaultValue == choice.value {
                            Spacer()
                            CertaintyBadge(certainty: .guess, text: "機械の候補")
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text(book.t(item.title))
        }
    }
}

// MARK: - 他3 社内のお知らせを入れる（初めはオフ。K4 の work_notice）

struct S27WNoticeImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var reading: String?
    @State private var note: String?

    var body: some View {
        @Bindable var b = book
        LLForm {
            Section {
                Toggle("社内のお知らせを入れる", isOn: $b.noticeOn)
            } footer: {
                Text("初めはオフです。入れる前に、会社の決まりで持ち出してよい範囲かを確かめてください。入れた文は家の PC の中だけに置き、「他の案件」の聞いた話になります。")
            }
            if book.noticeOn {
                Section {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .images) {
                        Label("スクショ・写真を選ぶ", systemImage: "photo.on.rectangle")
                    }
                    Button("コピーした画像を読み取る", systemImage: "doc.on.clipboard") { pasteImages() }
                    PasteButton(payloadType: String.self) { strings in
                        let pasted = strings.joined(separator: "\n")
                        Task { @MainActor in add(pasted) }
                    }
                    if let reading { HStack { ProgressView(); Text(reading) } }
                } header: {
                    Text("読み取る")
                } footer: {
                    Text("文字の読み取りは iPhone の中で行います。")
                }
                Section {
                    TextEditor(text: $text).frame(minHeight: 220)
                } header: {
                    Text("お知らせの文（直せます）")
                }
            }
            if let note { Text(note).foregroundStyle(LL.dim) }
        }
        .navigationTitle("社内のお知らせを入れる")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("送る") { send() }
                    .disabled(!book.noticeOn || reading != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: photoItems) {
            let picked = photoItems
            guard !picked.isEmpty else { return }
            Task { await load(picked) }
        }
        .onAppear {
            if let pending = book.pendingNotice {
                book.pendingNotice = nil
                add(pending)
            }
        }
    }

    private func send() {
        if book.sendNotice(text) {
            note = "送りました。"
            text = ""
        } else {
            note = "送れませんでした（オフか、空か、長すぎます）。"
        }
    }

    private func add(_ piece: String) {
        let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        text = text.isEmpty ? p : text + "\n" + p
    }

    private func pasteImages() {
        let board = UIPasteboard.general
        if board.hasImages, let images = board.images, !images.isEmpty {
            Task { await read(images) }
        } else {
            note = "コピーした画像がありません。"
        }
    }

    private func load(_ picked: [PhotosPickerItem]) async {
        reading = "写真を読み込んでいます…"
        var images: [UIImage] = []
        for item in picked {
            let data: Data? = try? await item.loadTransferable(type: Data.self)
            if let data, let image = UIImage(data: data) { images.append(image) }
        }
        photoItems = []
        await read(images)
    }

    private func read(_ images: [UIImage]) async {
        var texts: [String] = []
        for (n, image) in images.enumerated() {
            reading = "文字を読み取っています…（\(n + 1)/\(images.count)）"
            let found = await Pipeline.recognizeText(image)
            if !found.isEmpty { texts.append(found) }
        }
        reading = nil
        if texts.isEmpty {
            note = "文字を読み取れませんでした。"
        } else {
            add(texts.joined(separator: "\n"))
        }
    }
}

// MARK: - 設定（仕事の画面の下と、設定の「ふだん」。家の PC が仕事の口を持っているときだけ）

struct S27WScreenSettingsSection: View {
    var body: some View {
        @Bindable var b = book
        Section {
            Toggle("顧客名と人名を伏せる", isOn: $b.maskOn)
            Toggle("社内のお知らせを入れる", isOn: $b.noticeOn)
            if book.noticeOn {
                NavigationLink { S27WNoticeImportView() } label: { Label("社内のお知らせを入れる", systemImage: "square.and.arrow.down") }
            }
        } header: {
            LLHeader(title: "仕事の画面の設定", symbol: "gearshape")
        } footer: {
            Text("どちらも初めはオフ。伏せると「人1」「顧客1」のように見せます（1 文字の名前は伏せません・仮）。設定の「開くときに Face ID」がオンなら、仕事の画面を開くときにも確かめます。ウィジェットには数だけを出します。")
        }
    }
}

struct S27WSettingsSection: View {
    var body: some View {
        if book.offered {
            Section {
                // 設定はシートの中なので、もう 1 枚シートを重ねずに押して進む
                NavigationLink { S27WRootView(link: .home) } label: {
                    Label("仕事の画面を開く", systemImage: "briefcase")
                }
            }
            S27WScreenSettingsSection()
        }
    }
}

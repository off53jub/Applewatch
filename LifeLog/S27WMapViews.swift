import SwiftUI

// 仕事の画面の作り直し（2026-11-26）の画面。案件の一覧（仕事の画面の中）→ 案件の中（トピックの並び・状態ごとの板）
// → トピックの中（課題・宿題・未決を状態ごとに・決まったこと）。決まりは S27WMap.swift。
// 色だけに頼らない: どの色にも名前と形（S27WState.symbol）を添え、四角の並びは読み上げで数を言う。

@MainActor private var book: S27WBook { S27WBook.shared }

@MainActor private func today() -> String { ReviewRules.dayKey(.now) }

@MainActor private var done: Set<String> { Set(book.localDoneIDs) }

extension S27WState {
    var color: Color {
        switch self {
        case .urgent: LL.danger
        case .mine: LL.warn
        case .theirs: LL.accent
        case .unknown: LL.dim
        case .calm: LL.good
        }
    }
}

// MARK: - 小さな部品

/// 四角 1 つ（項目かトピック 1 つ）。長くそのままのものは中を薄くして縁だけ
struct S27WPip: View {
    let state: S27WState
    var old = false
    var size: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(state.color.opacity(old ? 0.35 : 1))
            .overlay {
                if old { RoundedRectangle(cornerRadius: size / 4).strokeBorder(state.color, lineWidth: 1.5) }
            }
            .frame(width: size, height: size)
    }
}

struct S27WPipGrid: View {
    let pips: [(state: S27WState, old: Bool)]
    var size: CGFloat = 12
    let spoken: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size), spacing: 4, alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(pips.indices, id: \.self) { i in S27WPip(state: pips[i].state, old: pips[i].old, size: size) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// 状態ごとの割合の帯
struct S27WStateBar: View {
    let counts: [S27WState: Int]

    var body: some View {
        let shown = S27WState.allCases.filter { counts[$0, default: 0] > 0 }
        let total = max(1, shown.reduce(0) { $0 + counts[$1, default: 0] })
        GeometryReader { geo in
            let gaps = CGFloat(max(0, shown.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(shown, id: \.self) { s in
                    Rectangle().fill(s.color)
                        .frame(width: max(3, (geo.size.width - gaps) * CGFloat(counts[s, default: 0]) / CGFloat(total)))
                }
                if shown.isEmpty { Rectangle().fill(LL.line) }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(S27WMapText.spoken(counts))
    }
}

enum S27WMapText {
    /// 「■ 急ぎ 1　■ 自分の番 20 …」（数の無い状態は出さない）
    @MainActor static func legend(_ counts: [S27WState: Int], states: [S27WState] = S27WState.allCases) -> Text {
        var t = Text("")
        for s in states where counts[s, default: 0] > 0 {
            let mark = Text(Image(systemName: "square.fill")).foregroundStyle(s.color)
            let label = Text(" \(s.label) ").foregroundStyle(LL.dim)
            let n = Text("\(counts[s, default: 0])").foregroundStyle(LL.text).bold()
            t = Text("\(t)\(mark)\(label)\(n)　")
        }
        return t
    }

    static func spoken(_ counts: [S27WState: Int]) -> String {
        S27WState.allCases.filter { counts[$0, default: 0] > 0 }.map { "\($0.label) \(counts[$0, default: 0]) 件" }.joined(separator: "、")
    }

    static func kinds(_ c: S27WKindCounts) -> String {
        "課題 \(c.issue)・宿題 \(c.homework)・未決 \(c.open)・決まった \(c.decided)"
    }

    static func milestone(_ m: S27WMilestone, today: String) -> String {
        let left = S27WRules.days(from: today, to: m.day) ?? m.daysLeft ?? 0
        return AppFeeds.monthDay(m.day) + "　" + (left == 0 ? "今日" : "あと \(left) 日")
    }
}

struct S27WStateLabel: View {
    let state: S27WState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(LL.TypeScale.tag)
            .foregroundStyle(state == .unknown ? LL.dim : state.color)
            .padding(.horizontal, LL.Space.s)
            .padding(.vertical, 2)
            .background(state.color.opacity(0.14), in: Capsule())
    }
}

// MARK: - 仕事の画面の中の「案件」

struct S27WGroupsSection: View {
    let board: S27WBoard

    var body: some View {
        let t = today()
        let groups = S27WMap.sortedGroups(S27WMap.groups(board.projects), today: t, done: done)
        let mine = groups.filter { $0.section == .mine }
        let rest = groups.filter { $0.section != .mine }
        Section {
            if mine.isEmpty { Text("自分の案件はまだありません").foregroundStyle(LL.dim) }
            ForEach(mine) { g in
                NavigationLink { S27WGroupView(groupID: g.id) } label: { S27WGroupCard(group: g) }
            }
        } header: {
            LLHeader(title: "自分の案件", symbol: "briefcase", trailing: mine.isEmpty ? nil : "\(mine.count)")
        } footer: {
            Text("色: 赤＝急ぎ（はっきりした期限が明日まで）・橙＝自分の番・青＝相手待ち・灰＝番が未定・緑＝落ち着いた。四角 1 つが 1 トピック。決め方は仮。")
        }
        if !rest.isEmpty {
            Section {
                ForEach(rest) { g in
                    NavigationLink { S27WGroupView(groupID: g.id) } label: { S27WGroupCard(group: g) }
                }
            } header: {
                LLHeader(title: "ほかの部署・まだ分けていない", symbol: "building.2")
            }
        }
    }
}

struct S27WGroupCard: View {
    let group: S27WGroup

    var body: some View {
        let t = today()
        let topicCounts = S27WMap.topicTally(group, today: t, done: done)
        let open = S27WMap.groupOpenItems(group, done: done)
        let itemCounts = S27WMap.tally(open, today: t)
        VStack(alignment: .leading, spacing: LL.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(book.t(group.name)).font(.title3.weight(.bold)).foregroundStyle(LL.text)
                Spacer(minLength: LL.Space.s)
                S27WStateLabel(state: S27WMap.groupState(group, today: t, done: done))
            }
            if let client = group.client, group.section == .mine {
                Text(book.t(client)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if let m = S27WMap.milestones(group, today: t).first {
                Label {
                    Text("\(Text(S27WMapText.milestone(m, today: t)).bold())\(Text("　" + book.t(m.title)).foregroundStyle(LL.dim))")
                } icon: {
                    Image(systemName: "flag.fill").foregroundStyle(LL.accent)
                }
                .font(LL.TypeScale.detail)
                .lineLimit(1)
            }
            if group.topics.count > 1 {
                S27WPipGrid(pips: S27WMap.sortedTopics(group.topics, today: t, done: done).map { (S27WMap.topicState($0, today: t, done: done), false) },
                            size: 16, spoken: "トピック \(group.topics.count)。" + S27WMapText.spoken(topicCounts))
                Text("\(Text("トピック \(group.topics.count)　").foregroundStyle(LL.dim))\(S27WMapText.legend(topicCounts))")
                    .font(LL.TypeScale.note)
            }
            if !open.isEmpty {
                Text("開いている \(open.count) 件は、だれの番か").font(LL.TypeScale.note).foregroundStyle(LL.dim)
                S27WStateBar(counts: itemCounts)
            }
            Text(S27WMapText.kinds(S27WMap.kindCounts(group, done: done))).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            if let d = S27WMap.lastDecided(group) {
                Text(AppFeeds.monthDay(d.day ?? "") + " 決まった: " + book.t(d.text))
                    .font(LL.TypeScale.note).foregroundStyle(LL.dim).lineLimit(2)
            }
        }
        .padding(.vertical, LL.Space.xs)
    }
}

// MARK: - 案件の中

struct S27WGroupView: View {
    let groupID: String
    @State private var boardMode = false
    @State private var filter: S27WState?

    var body: some View {
        let t = today()
        let group = book.board.flatMap { b in S27WMap.groups(b.projects).first { $0.id == groupID } }
        LLList {
            if let g = group {
                S27WGroupBody(group: g, today: t, boardMode: $boardMode, filter: $filter)
            } else {
                Section { LLEmpty(title: "この案件は届いている分にありません", symbol: "briefcase") }
            }
        }
        .navigationTitle(group.map { book.t($0.name) } ?? "案件")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await book.refresh(force: true) }
        .onAppear { Tally.add("s27w.group.open") }
    }
}

private struct S27WGroupBody: View {
    let group: S27WGroup
    let today: String
    @Binding var boardMode: Bool
    @Binding var filter: S27WState?

    var body: some View {
        let open = S27WMap.groupOpenItems(group, done: done)
        let itemCounts = S27WMap.tally(open, today: today)
        let topicCounts = S27WMap.topicTally(group, today: today, done: done)
        let kinds = S27WMap.kindCounts(group, done: done)
        let stones = S27WMap.milestones(group, today: today)
        let topics = S27WMap.sortedTopics(group.topics, today: today, done: done)
        if !stones.isEmpty {
            Section {
                ForEach(stones, id: \.day) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(S27WMapText.milestone(m, today: today)).font(LL.TypeScale.cardTitle).foregroundStyle(LL.accent)
                        Text(book.t(m.title)).font(LL.TypeScale.detail).foregroundStyle(LL.text)
                    }
                }
            } header: {
                LLHeader(title: "道のり（次の節目）", symbol: "flag")
            }
        }
        Section {
            HStack(spacing: LL.Space.s) {
                tile(kinds.issue, "課題")
                tile(kinds.homework, "宿題")
                tile(kinds.open, "未決")
                tile(kinds.decided, "決まった", color: LL.good)
            }
            if !open.isEmpty {
                VStack(alignment: .leading, spacing: LL.Space.s) {
                    Text("開いている \(open.count) 件は、だれの番か").font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    S27WStateBar(counts: itemCounts)
                    S27WMapText.legend(itemCounts).font(LL.TypeScale.note)
                }
            }
        } header: {
            LLHeader(title: "いまの数", symbol: "square.grid.2x2")
        }
        Section {
            Picker("見せ方", selection: $boardMode) {
                Text("並べて見る").tag(false)
                Text("状態ごとの板").tag(true)
            }
            .pickerStyle(.segmented)
            if !boardMode {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LL.Space.xs) {
                        chip(nil, "すべて \(group.topics.count)")
                        ForEach(S27WState.allCases.filter { topicCounts[$0, default: 0] > 0 }, id: \.self) { s in
                            chip(s, "\(s.label) \(topicCounts[s, default: 0])")
                        }
                    }
                }
                ForEach(topics.filter { filter == nil || S27WMap.topicState($0, today: today, done: done) == filter }) { p in
                    topicLink(p)
                }
            }
        } header: {
            LLHeader(title: "トピック", symbol: "list.bullet", trailing: "\(group.topics.count)")
        } footer: {
            Text("小さい四角 1 つが開いている 1 件。うすい四角は \(S27WMap.oldDays) 日以上そのまま（決め方は仮）。")
        }
        if boardMode {
            ForEach(S27WState.allCases.filter { topicCounts[$0, default: 0] > 0 }, id: \.self) { s in
                Section {
                    ForEach(topics.filter { S27WMap.topicState($0, today: today, done: done) == s }) { p in topicLink(p) }
                } header: {
                    Label("\(s.label)　\(topicCounts[s, default: 0])", systemImage: s.symbol)
                        .font(LL.TypeScale.section).foregroundStyle(s == .unknown ? LL.dim : s.color)
                }
            }
        }
    }

    private func topicLink(_ p: S27WProject) -> some View {
        NavigationLink { S27WTopicView(id: p.id, isTop: p.id == group.topID) } label: {
            S27WTopicRow(project: p, isTop: p.id == group.topID, today: today)
        }
    }

    private func tile(_ n: Int, _ label: String, color: Color = LL.text) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(LL.TypeScale.number).foregroundStyle(color)
            Text(label).font(LL.TypeScale.note).foregroundStyle(LL.dim)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ s: S27WState?, _ text: String) -> some View {
        let on = filter == s
        return Button {
            filter = s
        } label: {
            HStack(spacing: 4) {
                if let s { Image(systemName: "square.fill").foregroundStyle(s.color) }
                Text(text)
            }
            .font(LL.TypeScale.note)
            .foregroundStyle(on ? LL.text : LL.dim)
            .padding(.horizontal, LL.Space.s)
            .padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(on ? LL.text : LL.line, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct S27WTopicRow: View {
    let project: S27WProject
    var isTop = false
    let today: String

    var body: some View {
        let open = S27WMap.sortedItems(S27WMap.openItems(project, done: done), today: today)
        let st = S27WMap.topicState(project, today: today, done: done)
        let counts = S27WMap.tally(open, today: today)
        HStack(alignment: .top, spacing: LL.Space.s) {
            RoundedRectangle(cornerRadius: 2).fill(st.color).frame(width: 4)
            VStack(alignment: .leading, spacing: LL.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isTop ? "案件全体の話" : book.name(project)).font(LL.TypeScale.cardTitle).foregroundStyle(LL.text)
                    Spacer(minLength: LL.Space.s)
                    if let last = project.lastMoved {
                        Text(AppFeeds.monthDay(last)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    }
                }
                if open.isEmpty {
                    Label("開いているものは無い", systemImage: S27WState.calm.symbol).font(LL.TypeScale.note).foregroundStyle(LL.good)
                } else {
                    S27WPipGrid(pips: open.map { (S27WMap.state($0, today: today), S27WMap.isOld($0)) }, size: 12,
                                spoken: S27WMapText.spoken(counts))
                    S27WMapText.legend(counts).font(LL.TypeScale.note)
                }
                if let m = project.milestone, (S27WRules.days(from: today, to: m.day) ?? -1) >= 0 {
                    Label(S27WMapText.milestone(m, today: today), systemImage: "flag").font(LL.TypeScale.note).foregroundStyle(LL.accent)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - トピックの中

struct S27WTopicView: View {
    let id: String
    var isTop = false

    var body: some View {
        let t = today()
        LLList {
            if let p = book.board?.project(id) {
                S27WTopicBody(project: p, today: t)
            } else {
                Section { LLEmpty(title: "このトピックは届いている分にありません", symbol: "list.bullet") }
            }
        }
        .navigationTitle(isTop ? "案件全体の話" : (book.board?.project(id).map { book.name($0) } ?? "トピック"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s27w.topic.open") }
    }
}

private struct S27WTopicBody: View {
    let project: S27WProject
    let today: String

    var body: some View {
        let open = S27WMap.sortedItems(S27WMap.openItems(project, done: done), today: today)
        let counts = S27WMap.tally(open, today: today)
        let decided = S27WMap.decided(project)
        let closed = project.items.filter { S27WMap.openKinds.contains($0.kind ?? "") && book.isDone($0) }
        Section {
            HStack {
                S27WStateLabel(state: S27WMap.topicState(project, today: today, done: done))
                Spacer()
                if let last = project.lastMoved {
                    Text("最後に動いた日 " + AppFeeds.monthDay(last)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            }
            if let line = project.statusLine, !line.isEmpty {
                Text(book.t(line)).font(LL.TypeScale.detail).foregroundStyle(LL.text)
            }
            if let m = project.milestone {
                Label(S27WRules.milestoneLine(m, today: today), systemImage: "flag").font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if !open.isEmpty {
                S27WStateBar(counts: counts)
                S27WMapText.legend(counts).font(LL.TypeScale.note)
            }
        }
        ForEach(S27WState.allCases.filter { counts[$0, default: 0] > 0 }, id: \.self) { s in
            Section {
                ForEach(open.filter { S27WMap.state($0, today: today) == s }) { i in
                    HStack(alignment: .top, spacing: LL.Space.s) {
                        S27WPip(state: s, old: S27WMap.isOld(i), size: 10).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kindLabel(i.kind)).font(LL.TypeScale.tag).foregroundStyle(LL.dim)
                            S27WItemRow(item: i, canDone: true)
                        }
                    }
                }
            } header: {
                Label("\(s.label)　\(counts[s, default: 0])", systemImage: s.symbol)
                    .font(LL.TypeScale.section).foregroundStyle(s == .unknown ? LL.dim : s.color)
            }
        }
        if !closed.isEmpty {
            Section {
                ForEach(closed) { i in S27WItemRow(item: i, canDone: true) }
            } header: {
                LLHeader(title: "済んだ", symbol: "checkmark.circle", trailing: "\(closed.count)")
            }
        }
        if !decided.isEmpty {
            Section {
                ForEach(decided.prefix(20)) { d in
                    HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                        Text(AppFeeds.monthDay(d.day ?? "")).font(LL.TypeScale.rowNumber).foregroundStyle(LL.good)
                            .frame(minWidth: 44, alignment: .leading)
                        Text(book.t(d.text)).font(LL.TypeScale.detail).foregroundStyle(d.isMaybe ? LL.dim : LL.text)
                    }
                }
            } header: {
                LLHeader(title: "決まったこと", symbol: "checkmark.seal", trailing: "\(decided.count)")
            }
        }
        if !project.heard.isEmpty {
            Section {
                ForEach(project.heard.indices, id: \.self) { n in
                    let h = project.heard[n]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.t(h.text)).font(LL.TypeScale.detail).foregroundStyle(LL.text)
                        Text(AppFeeds.monthDay(h.day ?? "")).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    }
                }
            } header: {
                LLHeader(title: "聞いた話", symbol: "ear")
            }
        }
        Section {
            NavigationLink { S27WProjectView(id: project.id) } label: {
                LLRow(title: "人・数・名前を直す（前の画面）", symbol: "slider.horizontal.3")
            }
        }
    }

    private func kindLabel(_ k: String?) -> String {
        switch k {
        case "issue": "課題"
        case "homework": "宿題"
        default: "未決"
        }
    }
}

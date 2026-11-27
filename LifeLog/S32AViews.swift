import SwiftUI
import UIKit

// s32（2026-11-27）アプリ担当 S32A の画面。決まりは S32ARules.swift、動きは S32ABook.swift。
// - 仕事のまとめの一覧の上: 週の台帳・土台・AI からの質問の頼み方をコピー（S32APromptButtons。K32-1）
// - 仕事タブの項目（今日の一手・相手待ち・柱の中・根拠の一覧）: 押したままのメニューに「違う…」（S32AFixMenu。K32-3）と、
//   押したあとの「伝えました」の 1 行（S32AFixMark）。項目の文の中の glossary の言葉は押せる（S32AItemText → 言葉カード）
// - 仕事タブのいちばん下: 「AI の理解」（畳んである。S32AKnowSection。K32-2）
// 新しい問い・知らせは足さない。色だけに頼らない（「仮」「詰まり」「ひっくり返った」の文字を添える）。伏せる切り替え（守2）に従う。

@MainActor private var book: S27WBook { S27WBook.shared }
@MainActor private var fixes: S32ABook { S32ABook.shared }

// MARK: - K32-1 頼み方のボタン（仕事のまとめの一覧の上）

/// 週の台帳・土台・AI からの質問の頼み方をコピーするボタン（Section の中に行として並ぶ）
struct S32APromptButtons: View {
    let onCopied: (String) -> Void

    var body: some View {
        let today: String = TaskBook.dayFormat.string(from: .now)
        let quiz: String? = S32APrompt.quiz(day: today, quiz: book.board?.know?.quiz)
        Button("週の台帳を頼む（チケット・ケース）", systemImage: "list.number") {
            UIPasteboard.general.string = S32APrompt.ledger(day: today)
            Tally.add("s32a.prompt.ledger")
            onCopied("週の台帳の頼み方をコピーしました。週に 1 回、職場の Claude に貼って、答えを取り込んでください。")
        }
        Button("土台を頼む（言葉・体制・仕組み・番号の決まり・自分の役割。1 回だけ）", systemImage: "square.stack.3d.up") {
            UIPasteboard.general.string = S32APrompt.base(day: today)
            Tally.add("s32a.prompt.base")
            onCopied("土台の頼み方をコピーしました。1 回だけ、職場の Claude に貼って、答えを取り込んでください。")
        }
        let quizTitle: String = quiz == nil ? "AI からの質問を頼む（まだ届いていません）" : "AI からの質問を頼む"
        Button(quizTitle, systemImage: "questionmark.bubble") {
            guard let quiz else { return }
            UIPasteboard.general.string = quiz
            Tally.add("s32a.prompt.quiz")
            onCopied("家の AI からの質問をコピーしました。職場の Claude に貼って、答えを取り込んでください。あなたが答える必要はありません。")
        }
        .disabled(quiz == nil)
    }
}

// MARK: - K32-3 1 押しの「違う」

/// 押したままのメニューに入れる「違う…」（直したものは「戻す」）
struct S32AFixMenu: View {
    let item: S27WItem

    var body: some View {
        if let fix = fixes.fix(for: item.id) {
            Button("「" + fix.what.label + "」を戻す（この iPhone の見え方だけ）", systemImage: "arrow.uturn.backward") {
                fixes.undo(item.id)
            }
        } else if HomeFeeds.isID(item.id) {
            Menu("違う…", systemImage: "hand.raised") {
                Menu(S32AFixKind.project.label, systemImage: S32AFixKind.project.symbol) {
                    ForEach(projectChoices) { p in
                        Button(book.name(p)) { fixes.send(item, what: .project, value: p.id, valueName: book.name(p)) }
                    }
                    Button("どれか分からない") { fixes.send(item, what: .project) }
                }
                Menu(S32AFixKind.person.label, systemImage: S32AFixKind.person.symbol) {
                    ForEach(personChoices) { p in
                        Button(book.name(p)) { fixes.send(item, what: .person, value: p.id, valueName: book.name(p)) }
                    }
                    Button("だれか分からない") { fixes.send(item, what: .person) }
                }
                ForEach([S32AFixKind.term, .done, .notmine], id: \.self) { kind in
                    Button(kind.label, systemImage: kind.symbol) { fixes.send(item, what: kind) }
                }
            }
        }
    }

    private var projectChoices: [S27WProject] {
        let all: [S27WProject] = book.board?.projects ?? []
        return Array(all.filter { $0.id != item.projectID && HomeFeeds.isID($0.id) }.prefix(S32ARules.choiceLimit))
    }

    private var personChoices: [S27WPerson] {
        let all: [S27WPerson] = book.board?.people ?? []
        return Array(all.filter { $0.name != item.who && HomeFeeds.isID($0.id) }.prefix(S32ARules.choiceLimit))
    }
}

/// 押したあとの 1 行（「伝えました: 案件が違う」・戻す）
struct S32AFixMark: View {
    let item: S27WItem

    var body: some View {
        if let fix = fixes.fix(for: item.id) {
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                Label(book.t(S32ARules.fixLine(fix)), systemImage: fix.what.symbol)
                    .font(LL.TypeScale.note)
                    .foregroundStyle(LL.warn)
                Spacer(minLength: LL.Space.s)
                Button("戻す") {
                    withAnimation { fixes.undo(item.id) }
                }
                .buttonStyle(.borderless)
                .font(LL.TypeScale.note)
                .accessibilityLabel("見え方を戻す")
            }
        }
    }
}

// MARK: - 言葉を押せる文

private struct S32ATermPick: Identifiable {
    let term: S32ATerm
    var id: String { term.term }
}

/// 項目の文（glossary の言葉は押せる・押すと言葉カード）。「違う」を押したものは薄く、済んだ／自分の番でないものは取り消し線
struct S32AItemText: View {
    let item: S27WItem
    var font: Font = LL.TypeScale.detail
    var color: Color = LL.text
    var strike = false
    @State private var picked: S32ATermPick?

    var body: some View {
        let shown: String = book.t(item.text)
        let fix: S32AFix? = fixes.fix(for: item.id)
        let terms: [S32ATerm] = book.board?.know?.glossary ?? []
        let linked: AttributedString? = S32ARules.linked(shown, terms: terms.map(\.term))
        Group {
            if let linked {
                Text(linked)
            } else {
                Text(shown)
            }
        }
        .font(font)
        .foregroundStyle(fix != nil ? LL.dim : color)
        .strikethrough(strike || (fix?.what.hides ?? false))
        .environment(\.openURL, OpenURLAction { url in
            guard let i = S32ARules.termIndex(url), terms.indices.contains(i) else { return .systemAction }
            picked = S32ATermPick(term: terms[i])
            Tally.add("s32a.term.open")
            return .handled
        })
        .sheet(item: $picked) { pick in
            NavigationStack {
                S32ATermCard(term: pick.term, inSheet: true)
            }
        }
    }
}

/// 言葉カード（解1）
struct S32ATermCard: View {
    let term: S32ATerm
    var inSheet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let samples: [S27WItem] = book.board.map { S32ARules.items($0, ids: term.sampleIDs) } ?? []
        LLList {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                    Text(book.t(term.term)).font(LL.TypeScale.cardTitle).foregroundStyle(LL.text)
                    Spacer(minLength: LL.Space.s)
                    if !term.isFirm { S30WBadge(text: "仮", color: LL.warn) }
                }
                Text(term.meaning.map { book.t($0) } ?? "意味はまだ分かっていません")
                    .font(LL.TypeScale.body)
                    .foregroundStyle(term.meaning == nil ? LL.dim : LL.text)
                if let team = term.team {
                    LabeledContent("どのチーム・仕組み", value: book.t(team))
                }
                if let days = term.days {
                    LabeledContent("出た日", value: "\(days) 日")
                }
            } footer: {
                Text(term.isFirm ? "職場の Claude の答え（土台）から。"
                                 : "仮: 家の AI が前後の文から書いた下書きです。違っていたら、項目を押したままにして「違う…」→「言葉が違う」で伝えられます。")
            }
            if !term.voiceSays.isEmpty {
                Section("声ではこう言っていた") {
                    ForEach(Array(term.voiceSays.prefix(5).enumerated()), id: \.offset) { row in
                        Text("「" + book.t(row.element) + "」").font(LL.TypeScale.detail).foregroundStyle(LL.text)
                    }
                }
            }
            if !samples.isEmpty {
                Section("最近出た話") {
                    ForEach(samples.prefix(5)) { item in S27WItemRow(item: item) }
                }
            }
        }
        .navigationTitle(book.t(term.term))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

// MARK: - K32-2 AI の理解（仕事タブのいちばん下・畳む）

struct S32AKnowSection: View {
    @State private var open = false

    var body: some View {
        if book.offered, let board = book.board {
            Section {
                DisclosureGroup(isExpanded: $open) {
                    if let know = board.know {
                        S32AKnowRows(know: know)
                    } else {
                        Text("まだ届いていません。家の AI が言葉・人・仕組みの理解を作ると、ここに出ます。")
                            .font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    }
                } label: {
                    Label("AI の理解", systemImage: "brain.head.profile")
                        .font(LL.TypeScale.body)
                        .foregroundStyle(LL.text)
                }
                .accessibilityIdentifier("s32a.know")
            } footer: {
                Text("家の AI が、この案件をどう分かっているかです。違っていたら、項目を押したままにして「違う…」で伝えられます。「仮」は AI の下書きです。")
            }
            .onChange(of: open) {
                if open { Tally.add("s32a.know.open") }
            }
        }
    }
}

private struct S32AKnowRows: View {
    let know: S32AKnow

    var body: some View {
        if let guide = know.guide {
            VStack(alignment: .leading, spacing: 2) {
                Label("手引き: " + S32ARules.guideLine(guide), systemImage: "book.closed")
                    .font(LL.TypeScale.note).foregroundStyle(LL.dim)
                if guide.stale == true {
                    Text("古い: 今週は作り直せなかったので、前の版を使っています").font(LL.TypeScale.note).foregroundStyle(LL.warn)
                }
            }
        }
        if !know.glossary.isEmpty {
            NavigationLink { S32AGlossaryView() } label: {
                LLRow(title: "言葉", detail: S32ARules.glossaryLine(know.glossary), symbol: "character.book.closed")
            }
        }
        if !know.org.isEmpty {
            NavigationLink { S32AOrgView() } label: {
                LLRow(title: "人とチームの地図", detail: orgDetail, symbol: "person.3")
            }
        }
        if let systems = know.systems, !systems.isEmpty {
            NavigationLink { S32ASystemsView() } label: {
                LLRow(title: "仕組みの図", detail: "箱 \(systems.nodes.count)・矢印 \(systems.edges.count)" + (systems.stuck.isEmpty ? "" : "・詰まり \(systems.stuck.count)"),
                      symbol: "point.3.connected.trianglepath.dotted")
            }
        }
        if !know.numbering.isEmpty {
            NavigationLink { S32ANumberingView() } label: {
                LLRow(title: "番号の早見", detail: numberingDetail, symbol: "number")
            }
        }
        if !know.decisions.isEmpty {
            NavigationLink { S32ADecisionsView() } label: {
                LLRow(title: "決まったことの台帳", detail: decisionsDetail, symbol: "checkmark.seal")
            }
        }
        if !know.threads.isEmpty {
            NavigationLink { S32AThreadsView() } label: {
                LLRow(title: "話題の糸", detail: "\(know.threads.count) 本（日をまたいだ同じ話）", symbol: "link")
            }
        }
        if let card = know.scorecard, !card.rows.isEmpty {
            NavigationLink { S32AScoreView() } label: {
                LLRow(title: "通信簿", detail: (card.week.map { $0 + " の週" } ?? "この週") + "・前の週との差", symbol: "chart.bar")
            }
        }
        if let quiz = know.quiz, !quiz.questions.isEmpty {
            Text("AI からの質問 \(min(quiz.questions.count, S32APrompt.quizLimit)) 個: 仕事のまとめの「AI からの質問を頼む」で、職場の Claude に聞けます（あなたが答える必要はありません）。")
                .font(LL.TypeScale.note).foregroundStyle(LL.dim)
        }
    }

    private var orgDetail: String {
        let teams = S32ARules.orgGroups(know.org).filter { $0.team != S32ARules.noTeam }.count
        let draft = know.org.filter { !$0.isFirm }.count
        return "\(know.org.count) 人・\(teams) チーム" + (draft > 0 ? "（仮 \(draft)）" : "")
    }

    private var numberingDetail: String {
        let longest: Int? = know.numbering.compactMap(\.days).max()
        return "\(know.numbering.count) 件" + (longest.map { "・いちばん長いもの \($0) 日" } ?? "")
    }

    private var decisionsDetail: String {
        let flipped = know.decisions.filter(\.flipped).count
        return "\(know.decisions.count) 件" + (flipped > 0 ? "・ひっくり返った \(flipped)" : "")
    }
}

// MARK: 言葉

struct S32AGlossaryView: View {
    @State private var query = ""

    var body: some View {
        let all: [S32ATerm] = (book.board?.know?.glossary ?? []).sorted { a, b in
            (a.days ?? 0) != (b.days ?? 0) ? (a.days ?? 0) > (b.days ?? 0) : a.term < b.term
        }
        let shown: [S32ATerm] = query.isEmpty ? all : all.filter {
            $0.term.localizedCaseInsensitiveContains(query) || ($0.meaning ?? "").localizedCaseInsensitiveContains(query)
        }
        LLList {
            Section {
                if shown.isEmpty { Text("当てはまる言葉がありません").foregroundStyle(LL.dim) }
                ForEach(shown) { term in
                    NavigationLink { S32ATermCard(term: term) } label: { S32ATermRow(term: term) }
                }
            } footer: {
                Text("出た日の多い順。「仮」は家の AI の下書き（職場の Claude の答えから来たものは付きません）。")
            }
        }
        .searchable(text: $query, prompt: "言葉・意味で探す")
        .navigationTitle("言葉")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s32a.glossary.open") }
    }
}

private struct S32ATermRow: View {
    let term: S32ATerm

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                Text(book.t(term.term)).font(LL.TypeScale.body).foregroundStyle(LL.text)
                if !term.isFirm { S30WBadge(text: "仮", color: LL.warn) }
                Spacer(minLength: LL.Space.s)
                if let days = term.days {
                    Text("\(days) 日").font(LL.TypeScale.rowNumber).foregroundStyle(LL.dim)
                }
            }
            Text(term.meaning.map { book.t($0) } ?? "意味はまだ分かっていません")
                .font(LL.TypeScale.note).foregroundStyle(LL.dim).lineLimit(2)
        }
    }
}

// MARK: 人とチームの地図

struct S32AOrgView: View {
    var body: some View {
        let groups = S32ARules.orgGroups(book.board?.know?.org ?? [])
        LLList {
            if groups.isEmpty {
                Section { Text("届いている分にありません").foregroundStyle(LL.dim) }
            }
            ForEach(groups, id: \.team) { group in
                Section {
                    ForEach(Array(group.people.enumerated()), id: \.offset) { row in
                        S32AOrgRow(person: row.element)
                    }
                } header: {
                    LLHeader(title: group.team == S32ARules.noTeam ? group.team : book.t(group.team), symbol: "person.3",
                             trailing: "\(group.people.count) 人")
                }
            }
        }
        .navigationTitle("人とチームの地図")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s32a.org.open") }
    }
}

private struct S32AOrgRow: View {
    let person: S32AOrgPerson

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                Text(name).font(LL.TypeScale.body).foregroundStyle(LL.text)
                if !person.isFirm { S30WBadge(text: "仮", color: LL.warn) }
                Spacer(minLength: LL.Space.s)
                if let with = S32ARules.withMeLabel(person.withMe) {
                    Text(with).font(LL.TypeScale.note).foregroundStyle(LL.accent)
                }
            }
            Text(person.role.map { book.t($0) } ?? "役割はまだ分かっていません")
                .font(LL.TypeScale.detail).foregroundStyle(person.role == nil ? LL.dim : LL.text)
            if let last = person.last {
                Text("最近: " + (HomeFeeds.isDay(last) ? AppFeeds.monthDay(last) : book.t(last)))
                    .font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
    }

    private var name: String {
        book.maskOn ? (book.mask.person(person.name) ?? person.name) : person.name
    }
}

// MARK: 仕組みの図

struct S32ASystemsView: View {
    var body: some View {
        let systems: S32ASystems = book.board?.know?.systems ?? S32ASystems()
        let stuck: Set<String> = Set(systems.stuck)
        let lone: [S32ANode] = S32ARules.loneNodes(systems)
        LLList {
            if !systems.edges.isEmpty {
                Section {
                    ForEach(Array(systems.edges.enumerated()), id: \.offset) { row in
                        S32AEdgeRow(edge: row.element, systems: systems, stuck: stuck)
                    }
                } header: {
                    LLHeader(title: "つながり（箱と矢印）", symbol: "arrow.right", trailing: "\(systems.edges.count)")
                } footer: {
                    Text("縁の太い赤い箱が、いま詰まっているところです（「詰まり」と書いてあります）。")
                }
            }
            if !lone.isEmpty {
                Section {
                    ForEach(Array(lone.enumerated()), id: \.offset) { row in
                        HStack(spacing: LL.Space.s) {
                            S32ABox(name: book.t(row.element.name), stuck: stuck.contains(row.element.id))
                            if let team = row.element.team {
                                Text(book.t(team)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                            }
                        }
                    }
                } header: {
                    LLHeader(title: "つながりがまだ分からない箱", symbol: "square.dashed")
                }
            }
            if systems.isEmpty {
                Section { Text("届いている分にありません").foregroundStyle(LL.dim) }
            }
        }
        .navigationTitle("仕組みの図")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s32a.systems.open") }
    }
}

private struct S32AEdgeRow: View {
    let edge: S32AEdge
    let systems: S32ASystems
    let stuck: Set<String>

    var body: some View {
        let from = S32ABox(name: book.t(S32ARules.nodeName(edge.from, in: systems)), stuck: stuck.contains(edge.from))
        let to = S32ABox(name: book.t(S32ARules.nodeName(edge.to, in: systems)), stuck: stuck.contains(edge.to))
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LL.Space.s) {
                    from
                    Image(systemName: "arrow.right").foregroundStyle(LL.dim)
                    to
                }
                VStack(alignment: .leading, spacing: LL.Space.xs) {
                    from
                    Image(systemName: "arrow.down").foregroundStyle(LL.dim)
                    to
                }
            }
            if let what = edge.what, !what.isEmpty {
                Text(book.t(what)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.t(S32ARules.edgeLine(edge, in: systems)))
    }
}

private struct S32ABox: View {
    let name: String
    let stuck: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(LL.TypeScale.detail).foregroundStyle(LL.text).lineLimit(2)
            if stuck {
                Text("詰まり").font(LL.TypeScale.tag).foregroundStyle(LL.danger)
            }
        }
        .padding(.horizontal, LL.Space.s)
        .padding(.vertical, LL.Space.xs)
        .background(LL.surface2, in: RoundedRectangle(cornerRadius: LL.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: LL.Radius.small)
            .strokeBorder(stuck ? LL.danger : LL.line, lineWidth: stuck ? LL.Stroke.bold : LL.Stroke.thin))
    }
}

// MARK: 番号の早見

struct S32ANumberingView: View {
    var body: some View {
        let list: [S32ANumber] = S32ARules.numberingSorted(book.board?.know?.numbering ?? [])
        LLList {
            Section {
                if list.isEmpty { Text("届いている分にありません").foregroundStyle(LL.dim) }
                ForEach(Array(list.enumerated()), id: \.offset) { row in
                    S32ANumberRow(number: row.element)
                }
            } footer: {
                Text("何日もまたいでいる番号から。状態と担当は届いた台帳・話から。")
            }
        }
        .navigationTitle("番号の早見")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s32a.numbering.open") }
    }
}

private struct S32ANumberRow: View {
    let number: S32ANumber

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                Text(number.no).font(LL.TypeScale.rowNumber).foregroundStyle(LL.text)
                if let state = number.state {
                    Text(book.t(state)).font(LL.TypeScale.note).foregroundStyle(LL.accent)
                }
                Spacer(minLength: LL.Space.s)
                if let days = number.days {
                    Text("\(days) 日またぐ").font(LL.TypeScale.note).foregroundStyle(days >= 3 ? LL.warn : LL.dim)
                }
            }
            if let what = number.what {
                Text(book.t(what)).font(LL.TypeScale.detail).foregroundStyle(LL.text)
            }
            if let owner = number.owner {
                Text("担当: " + book.t(owner)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if let why = number.why {
                Text("止まっているわけ: " + book.t(why)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
    }
}

// MARK: 決まったことの台帳

struct S32ADecisionsView: View {
    @State private var query = ""

    var body: some View {
        let all: [S32ADecision] = S32ARules.decisionsSorted(book.board?.know?.decisions ?? [])
        let shown: [S32ADecision] = S32ARules.searchDecisions(all, query: query)
        LLList {
            Section {
                if shown.isEmpty { Text("当てはまる決まったことがありません").foregroundStyle(LL.dim) }
                ForEach(Array(shown.enumerated()), id: \.offset) { row in
                    S32ADecisionRow(decision: row.element, all: all)
                }
            } footer: {
                Text("新しい日から。「ひっくり返った」は、あとの決定で変わったものです。")
            }
        }
        .searchable(text: $query, prompt: "決まったことを探す")
        .navigationTitle("決まったことの台帳")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s32a.decisions.open") }
    }
}

private struct S32ADecisionRow: View {
    let decision: S32ADecision
    let all: [S32ADecision]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                if let day = decision.day {
                    Text(AppFeeds.monthDay(day)).font(LL.TypeScale.rowNumber).foregroundStyle(LL.good)
                }
                if decision.flipped { S30WBadge(text: "ひっくり返った", color: LL.warn) }
                if S32ARules.flipsOther(decision, in: all) { S30WBadge(text: "前の決定を変えた", color: LL.accent) }
            }
            Text(book.t(decision.text)).font(LL.TypeScale.detail)
                .foregroundStyle(decision.flipped ? LL.dim : LL.text)
                .strikethrough(decision.flipped)
            if let newer = S32ARules.flippedText(decision, in: all) {
                Text("→ " + book.t(newer)).font(LL.TypeScale.note).foregroundStyle(LL.text)
            }
            if let who = decision.who {
                Text("決めた人: " + (book.maskOn ? (book.mask.person(who) ?? who) : who)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if let why = decision.why {
                Text("わけ: " + book.t(why)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
    }
}

// MARK: 話題の糸

struct S32AThreadsView: View {
    var body: some View {
        let threads: [S32AThread] = book.board?.know?.threads ?? []
        LLList {
            Section {
                if threads.isEmpty { Text("届いている分にありません").foregroundStyle(LL.dim) }
                ForEach(Array(threads.enumerated()), id: \.offset) { row in
                    let items: [S27WItem] = book.board.map { S32ARules.items($0, ids: row.element.items) } ?? []
                    if items.isEmpty {
                        S32AThreadRow(thread: row.element)
                    } else {
                        NavigationLink {
                            S30WItemsView(title: book.t(row.element.title), items: items)
                        } label: {
                            S32AThreadRow(thread: row.element)
                        }
                    }
                }
            } footer: {
                Text("チケット・番号・言葉を鍵に、日をまたいだ同じ話を 1 本にしたものです。")
            }
        }
        .navigationTitle("話題の糸")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s32a.threads.open") }
    }
}

private struct S32AThreadRow: View {
    let thread: S32AThread

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                Text(book.t(thread.title)).font(LL.TypeScale.body).foregroundStyle(LL.text)
                Spacer(minLength: LL.Space.s)
                if let state = thread.state {
                    Text(book.t(state)).font(LL.TypeScale.note).foregroundStyle(LL.accent)
                }
            }
            Text(detail).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            if !thread.keys.isEmpty {
                Text("鍵: " + thread.keys.prefix(6).map { book.t($0) }.joined(separator: "・"))
                    .font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let days = thread.days { parts.append("\(days) 日") }
        if let last = thread.lastDay { parts.append("最後 " + AppFeeds.monthDay(last)) }
        if let n = thread.itemCount { parts.append("項目 \(n)") }
        return parts.isEmpty ? "日をまたいだ話" : parts.joined(separator: "・")
    }
}

// MARK: 通信簿

struct S32AScoreView: View {
    var body: some View {
        let card: S32AScorecard = book.board?.know?.scorecard ?? S32AScorecard()
        LLList {
            Section {
                if card.rows.isEmpty { Text("届いている分にありません").foregroundStyle(LL.dim) }
                ForEach(Array(card.rows.enumerated()), id: \.offset) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                            Text(book.t(row.element.label)).font(LL.TypeScale.body).foregroundStyle(LL.text)
                            Spacer(minLength: LL.Space.s)
                            Text(S32ARules.valueText(row.element)).font(LL.TypeScale.rowNumber).foregroundStyle(LL.text)
                        }
                        if let detail = row.element.detail {
                            Text(book.t(detail)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                        }
                        if let diff = S32ARules.diffText(row.element) {
                            Text(diff).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                LLHeader(title: card.week.map { $0 + " の週" } ?? "この週", symbol: "chart.bar")
            } footer: {
                Text("AI が仕事をどこまで分かっているかの数です（週に 1 回）。どの手が効いたかを見るためのもので、あなたがすることはありません。")
            }
        }
        .navigationTitle("通信簿")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Tally.add("s32a.score.open") }
    }
}

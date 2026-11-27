import SwiftUI
import UIKit

// s34（2026-11-27）アプリ担当 S34A の画面。決まりは S34ARules.swift、動きは S34ABook.swift。
// - 仕事タブ（開いたときだけ出す。知らせ・問いは足さない）:
//   円5 テストの進みの 1 行（S34ATestsSection・いちばん上）・円2 職場の Claude に貼る 1 つの文（S34APromptSection）・
//   円3 止まっている話の次の一手と下書き（S34ANudgesSection・下書きはコピーできる）・円4 会議の前の 1 枚（S34APrepSection。
//   今日タブの「次の会議の前に」のすぐ後ろにも同じものを足す）
// - 点検の「自動で直した数」の 1 枚（S34ACheckSection → S34AFixedView。数だけ）
// - 設定の「写真から仕事のまとめを拾う」のスイッチと説明（S34APhotoSettingsSection。初めはオフ）
// どれも中身が無ければ出さない。職場の中身は時計・ウィジェット・通知に出さない。顧客名と人名を伏せる設定（S27W）に従う。

@MainActor private var workBook: S27WBook { S27WBook.shared }

// MARK: - 円5 テストの進み（仕事タブの上）

struct S34ATestsSection: View {
    var body: some View {
        let book = S34ABook.shared
        if book.offered, let line = S34ARules.testsLine(book.feed?.tests) {
            Section {
                VStack(alignment: .leading, spacing: LL.Space.xs) {
                    Text(line).font(LL.TypeScale.cardTitle).foregroundStyle(LL.text).monospacedDigit()
                    if let finish = S34ARules.finishLine(book.feed?.tests) {
                        Text(finish).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                    }
                }
                .accessibilityIdentifier("s34a.tests")
            } header: {
                LLHeader(title: "テストの進み", symbol: "checklist.checked", trailing: S34ARules.left(book.feed?.tests).map { "残り \($0)" })
            }
        }
    }
}

// MARK: - 円2 職場の Claude に貼る 1 つの文

struct S34APromptSection: View {
    @State private var note: String?

    var body: some View {
        let book = S34ABook.shared
        let today = ReviewRules.dayKey(.now)
        if book.usesFeedPrompt(day: today) {
            Section {
                Button("職場の Claude に貼る文をコピー（今日）", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = book.promptText(day: today)
                    note = "コピーしました。職場の Claude に貼って、答えを撮るか取り込んでください。"
                    Tally.add("s34a.prompt.copy")
                }
                if let note {
                    Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            } footer: {
                Text(partsText(book.feed?.prompt?.parts ?? []))
            }
        }
    }

    private func partsText(_ parts: [String]) -> String {
        let head = "今日のまとめの頼みに、機械が毎日入れ替える分を足した 1 つの文です。"
        guard !parts.isEmpty else { return head }
        return head + "入っているもの: " + parts.prefix(6).joined(separator: "・")
    }
}

// MARK: - 円3 止まっている話の次の一手

struct S34ANudgesSection: View {
    @State private var copied: String?

    var body: some View {
        let book = S34ABook.shared
        let list = S34ANudgeRules.sorted(book.feed?.nudges ?? [])
        if book.offered, !list.isEmpty {
            Section {
                ForEach(list) { n in
                    S34ANudgeRow(nudge: n, copied: copied == n.id) {
                        UIPasteboard.general.string = n.draft
                        copied = n.id
                        Tally.add("s34a.nudge.copy")
                    }
                }
            } header: {
                LLHeader(title: "止まっている話の次の一手", symbol: "arrow.turn.down.right", trailing: "\(list.count) 件")
            } footer: {
                Text("相手待ちが長いものに、だれに何を聞けば動くかと、短い文の下書きです。送るのは自分で（ここからは送りません）。")
            }
        }
    }
}

private struct S34ANudgeRow: View {
    let nudge: S34ANudge
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            Text(workBook.t(nudge.topic)).font(LL.TypeScale.cardTitle).foregroundStyle(LL.text)
            if let meta = S34ANudgeRules.meta(nudge) {
                Text(workBook.t(meta)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if let next = nudge.next, !next.isEmpty {
                Label(workBook.t(next), systemImage: "arrow.right.circle")
                    .font(LL.TypeScale.note)
            }
            if let draft = nudge.draft, !draft.isEmpty {
                Text(workBook.t(draft))
                    .font(LL.TypeScale.note)
                    .foregroundStyle(LL.dim)
                    .padding(LL.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LL.bg)
                Button(copied ? "コピーしました" : "下書きをコピー", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                    .buttonStyle(.borderless)
                    .font(LL.TypeScale.note)
            }
        }
        .padding(.vertical, LL.Space.xs)
    }
}

// MARK: - 円4 会議の前の 1 枚

struct S34APrepSection: View {
    var body: some View {
        let book = S34ABook.shared
        let list = S34APrepRules.upcoming(book.feed?.prep ?? [], now: .now)
        if book.offered, !list.isEmpty {
            ForEach(Array(list.prefix(3).enumerated()), id: \.offset) { _, p in
                Section {
                    S34APrepLines(title: "前回決まったこと", lines: p.lastDecided)
                    S34APrepLines(title: "自分の宿題の進み", lines: p.myTasks)
                    S34APrepLines(title: "聞かれそうなこと", lines: p.likelyAsked)
                    S34APrepLines(title: "出す前の自己点検", lines: p.selfCheck)
                } header: {
                    LLHeader(title: "会議の前の 1 枚: " + workBook.t(p.meeting), symbol: "doc.text.magnifyingglass",
                             trailing: S34APrepRules.whenText(p.at, now: .now))
                }
            }
        }
    }
}

private struct S34APrepLines: View {
    let title: String
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: LL.Space.xs) {
                Text(title).font(LL.TypeScale.tag).foregroundStyle(LL.dim)
                ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                    Label(workBook.t(line), systemImage: "circle.fill")
                        .labelStyle(S34ADotLabel())
                        .font(LL.TypeScale.note)
                }
            }
            .padding(.vertical, LL.Space.xs)
        }
    }
}

private struct S34ADotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
            Text("・").foregroundStyle(LL.dim)
            configuration.title
        }
    }
}

// MARK: - 点検の「自動で直した数」の 1 枚

struct S34ACheckSection: View {
    var body: some View {
        let book = S34ABook.shared
        let voice = S34AVoiceRules.line(S34AVoiceBook.shared.marks)
        let head: String? = book.offered ? book.feed.flatMap { S34ARules.fixedHeadline($0) } : nil
        if head != nil || voice != nil {
            Section {
                NavigationLink {
                    S34AFixedView()
                } label: {
                    LLRow(title: head ?? "自動で足した声の見本", detail: detail(voice), symbol: "wand.and.stars")
                }
            } header: {
                Text("自動で直した数")
            } footer: {
                Text("本人に聞かずに機械が直した・解いた・切り替えた数です（中身は家の PC の側に、元に戻せる形で控えてあります）。")
            }
        }
    }

    private func detail(_ voice: String?) -> String? {
        var rows: [String] = []
        if S34ABook.shared.offered, let feed = S34ABook.shared.feed {
            for line in S34ARules.fixedLines(feed).prefix(2) { rows.append(line.title + " " + line.value) }
        }
        if let voice { rows.append("声の見本 " + voice) }
        return rows.isEmpty ? nil : rows.joined(separator: "\n")
    }
}

struct S34AFixedView: View {
    var body: some View {
        let book = S34ABook.shared
        let lines: [S34ALine] = book.feed.map { S34ARules.fixedLines($0) } ?? []
        LLList {
            S34AVoiceSection()  // 自6・自7 家の PC が集めた声の見本（S34AVoice.swift）
            if !book.offered || lines.isEmpty {
                Section {
                    LLEmpty(title: "まだ届いていません", symbol: "wand.and.stars",
                            detail: "家の PC が新しくなり、週 1 回の数が届くと、ここに出ます。")
                }
            } else {
                Section {
                    ForEach(lines) { line in
                        LLRow(title: line.title, value: line.value)
                    }
                } header: {
                    LLHeader(title: S34ARules.fixedHeadline(book.feed ?? S34AFeed()) ?? "自動で直した数", symbol: "wand.and.stars")
                } footer: {
                    Text("どれも仮の印つきで、元に戻せます。本人が前に答えたもの・手で直したものは上書きしていません。数が落ちたものは機械が自分で戻します。")
                }
                if let at = book.fetchedAt {
                    Section {
                        Text("受け取った " + at.formatted(date: .abbreviated, time: .shortened))
                            .font(LL.TypeScale.note).foregroundStyle(LL.dim)
                        if book.offline {
                            S24RoleLabel(text: "家の PC につながらないので、前に届いた分を見せています", role: .wait)
                                .font(LL.TypeScale.note)
                        }
                    }
                }
            }
        }
        .navigationTitle("自動で直した数")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { book.opened() }
        .countsOpen("s34aFixed")
    }
}

// MARK: - 円1 写真から仕事のまとめを拾う（設定）

struct S34APhotoSettingsSection: View {
    @AppStorage(S34APhotoScan.onKey) private var on = false
    @State private var note: String?

    var body: some View {
        let scan = S34APhotoScan.shared
        Section {
            Toggle("写真から仕事のまとめを拾う", isOn: $on)
                .onChange(of: on) { _, value in
                    if value {
                        Task { note = await scan.turnedOn() }
                    } else {
                        scan.turnedOff()
                        note = nil
                    }
                }
            if on && !DayPhotos.isAllowed {
                S24RoleLabel(text: "写真の許可が無いので、何もしていません（iPhone の設定 → LifeLog → 写真）", role: .wait)
                    .font(LL.TypeScale.note)
            } else if on {
                Text(statusText(scan)).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if let note {
                Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        } header: {
            Text("仕事のまとめ")
        } footer: {
            HelpNote("職場の Claude の答えの画面を撮るだけで、仕事のまとめに入ります。見出し（【日付】【決まったこと】【自分の宿題】【会議】など）が 2 つ以上写っている写真だけを拾い、文字は iPhone の中で読みます。読んだ文字だけを、取り込んだときと同じ道で家の PC に送ります（写真そのものは送りません・同じ写真は 2 回読みません・ほかの写真の文字はその場で捨てます）。自分の宿題はタスクには入れません（取り込みの画面から入れたときだけ入ります）。アプリが前にあるときと、充電中だけ見ます。知らせは出しません。初めはオフ。入れたときに写真の許可がまだなら、そのとき 1 回だけ聞きます。")
        }
    }

    private func statusText(_ scan: S34APhotoScan) -> String {
        if scan.running { return "写真を見ています…" }
        guard let at = scan.foundAt else { return "まだ拾ったまとめはありません（撮ってから 2 分ほどで見ます）。" }
        return "拾ったまとめ \(scan.found) 件・最後 " + at.formatted(date: .abbreviated, time: .shortened)
    }
}

/// どこ？から開く
struct S34APhotoSettingsView: View {
    var body: some View {
        LLList {
            S34APhotoSettingsSection()
        }
        .navigationTitle("写真から仕事のまとめ")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s34aWorkPhoto")
    }
}

// MARK: - 自6・自7 家の PC が集めた声の見本（S34AVoice.swift）

struct S34AVoiceSection: View {
    @AppStorage(S34AVoiceBook.onKey) private var on = true
    @State private var asking = false
    @State private var note: String?

    var body: some View {
        let book = S34AVoiceBook.shared
        Section {
            Toggle("家の PC が集めた声の見本を足す", isOn: $on)
            if let line = S34AVoiceRules.line(book.marks) {
                LLRow(title: "足した見本", value: line)
            } else {
                Text(book.running ? "足しています…" : "まだ足した見本はありません").font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
            if book.selfCardDone {
                S24RoleLabel(text: "自分の声は家・職場・外の見本がそろったので、3 通り録る操作は要りません", role: .machine)
                    .font(LL.TypeScale.note)
            }
            if !book.marks.isEmpty {
                Button("自動で足した見本だけを外す", systemImage: "arrow.uturn.backward", role: .destructive) { asking = true }
            }
            if let note {
                Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        } header: {
            Text("自動で足した声の見本")
        } footer: {
            HelpNote("家の PC が確かな場面（家でひとり・PLAUD でいちばん近くて多い声・予定の相手が 1 人・出席者の分かる会議）から集めた声の見本を、自分と名前のある人の声に「自動」の印で足します。本人が録った声・手直しした声・付けた名前は変えません。今の声から遠い見本は足しません。自分 15 個・ほかの人 1 人 5 個まで（仮）。話し手の聞き分けがオンのとき、アプリが前にあるか充電中に 6 時間に 1 回。外すと、自動で足した分だけを外し、もう足しません。")
        }
        .alert("自動で足した見本を外しますか？", isPresented: $asking) {
            Button("外す", role: .destructive) {
                Task {
                    let n = await book.removeAll()
                    on = false
                    note = "\(n) 個を外しました。もう足しません（上のスイッチで戻せます）。"
                }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("本人が録った声と手直しした声は残ります。外した見本は、もう一度足すことはありません。")
        }
    }
}

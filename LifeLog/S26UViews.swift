import AVFoundation
import SwiftUI
import UIKit

// s26（2026-11-25）の A2 の画面。決まりは S26URules.swift、動きは S26UBook.swift。
// 軽1（色と印の説明・「?」の 2 行）・軽3（よく変える 3 つ）・軽4（答える山）・軽5（操作待ち）・軽9（機械がしたこと）・
// 軽10（自己点検で本人が何もできない行を畳む）・軽11（すきまの 1 件）。

// MARK: - 軽1 各画面の「?」

struct S26UHelpButton: ViewModifier {
    let screen: String
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if !S26UHelp.of(screen).isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("この画面の説明", systemImage: "questionmark.circle") { show = true }
                    }
                }
            }
            .sheet(isPresented: $show) {
                S26UHelpSheet(screen: screen) { show = false }
                    .presentationDetents([.medium])
            }
    }
}

extension View {
    /// 画面の左上に「?」（2 行の説明と色の意味）。2026-11-25。s26 の 軽1
    func s26uHelp(_ screen: String) -> some View { modifier(S26UHelpButton(screen: screen)) }
}

struct S26UHelpSheet: View {
    let screen: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            LLList {
                Section {
                    ForEach(Array(S26UHelp.of(screen).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                } header: {
                    LLHeader(title: "この画面", symbol: "questionmark.circle")
                }
                S26UColorLegendSection()
            }
            .navigationTitle("説明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
            }
        }
    }
}

/// 色の意味（赤＝本人が動く・オレンジ＝今日はお休み・明日また動く など）
struct S26UColorLegendSection: View {
    var body: some View {
        Section {
            ForEach(S26UHelp.legend, id: \.color) { row in
                HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                    LLToneMark(tone: row.tone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.color).font(.callout.weight(.semibold))
                        Text(row.meaning).font(.caption).foregroundStyle(LL.dim)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                Image(systemName: "circle.fill").foregroundStyle(LL.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("青").font(.callout.weight(.semibold))
                    Text("ふつう（押せる所・いまの選び）").font(.caption).foregroundStyle(LL.dim)
                }
            }
        } header: {
            LLHeader(title: "色の意味", symbol: "paintpalette")
        }
    }
}

// MARK: - 軽3・軽5・軽11 「今日」の小さな列

/// 「今日」の上の 3 枚のすぐ下: よく変える 3 つ（畳んだ並びのときだけ）・すきまの 1 件・本人の操作待ち（あるときだけ）
struct S26UTodaySection: View {
    @Environment(Pipeline.self) private var pipeline
    /// 「今日は上の 3 枚だけ」（s24 の 形1）か
    let fold: Bool
    @AppStorage(S26UQuick.key) private var quickOn = true

    var body: some View {
        let book = S26UBook.shared
        if fold {
            if quickOn { S26UQuickSection() } else { S24QuickSettingsSection() }
        }
        if let gap = book.gapNow() {
            Section {
                Button {
                    Tally.add("s26u.gap.opened")
                    pipeline.tab = .tasks
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gap.text).font(.callout).foregroundStyle(LL.text)
                        Text(gapNote(gap)).font(.caption).foregroundStyle(LL.dim)
                    }
                }
            } header: {
                LLHeader(title: "すきまに 1 件", symbol: "clock.badge.checkmark")
            }
        }
        if book.waitingOpen > 0 {
            Section {
                NavigationLink {
                    S26UWaitingView()
                } label: {
                    LabeledContent {
                        Text("\(book.waitingOpen) 件")
                    } label: {
                        Label("本人の操作待ち", systemImage: "hand.point.up.left")
                    }
                }
            }
        }
    }

    private func gapNote(_ gap: S26UGapTask) -> String {
        var parts: [String] = []
        if let minutes = gap.minutes, minutes > 0 { parts.append("\(minutes) 分ほど") }
        if let to = PCJSON.date(gap.to) { parts.append(to.formatted(date: .omitted, time: .shortened) + " までのすきま") }
        parts.append("押すとタスクを開きます")
        return parts.joined(separator: "・")
    }
}

/// よく変える 3 つ（録り方の組・場面・スイッチ。数の多い順。数が無いうちは「仮」）
struct S26UQuickSection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(SceneSets.currentKey) private var scene = ""
    @State private var version = 0
    @State private var note: String?
    @State private var pending: (id: String, on: Bool)?

    var body: some View {
        let entries = S22SettingEntry.all
        let pick = S26UQuick.top(switches: entries.map(\.id), sums: Tally.sums(days: S26UQuick.days))
        Section {
            ForEach(pick.ids, id: \.self) { id in
                row(id, entries: entries)
            }
            if let note {
                Label(note, systemImage: "checkmark.circle").font(.caption).foregroundStyle(LL.good)
            }
        } header: {
            Text(pick.provisional ? "よく変える設定（仮）" : "よく変える設定")
        } footer: {
            Text("設定を開いて変えていたものの多い順です（30 日）。コントロールセンターにも「録り方の組を替える」を置けます。")
        }
        .id(version)
        .confirmationDialog(pendingTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button(pending?.on == true ? "オンにする" : "オフにする") {
                if let pending, let entry = entries.first(where: { $0.id == pending.id }) { apply(entry, pending.on) }
                pending = nil
            }
            Button("やめる", role: .cancel) { pending = nil }
        }
    }

    @ViewBuilder
    private func row(_ id: String, entries: [S22SettingEntry]) -> some View {
        switch id {
        case S26UQuick.preset:
            presetRow()
        case S26UQuick.scene:
            sceneRow()
        default:
            if let entry = entries.first(where: { $0.id == id }) {
                let on = entry.get(pipeline)
                Toggle(entry.label, isOn: Binding(get: { on }, set: { ask(entry, $0) })).font(.callout)
            }
        }
    }

    private func presetRow() -> some View {
        let current = pipeline.currentPreset
        return HStack(spacing: LL.Space.s) {
            ForEach(S21Preset.allCases) { preset in
                Button {
                    let count = pipeline.applyPreset(preset)
                    LLHaptic.done.play()
                    note = "「\(preset.label)」にしました（\(count) 個のスイッチ）"
                    version += 1
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: preset.symbol)
                        Text(preset.label).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(current == preset ? LL.accent : LL.dim)
                .accessibilityLabel(preset.label + (current == preset ? "（いまの組）" : ""))
            }
        }
    }

    private func sceneRow() -> some View {
        Menu {
            ForEach(LifeScene.allCases) { s in
                Button {
                    let count = pipeline.applyScene(s)
                    LLHaptic.done.play()
                    note = "\(s.label)にしました（\(count) 個のスイッチ）"
                    version += 1
                } label: {
                    Label(s.label, systemImage: s.symbol)
                }
            }
        } label: {
            LabeledContent {
                Text(LifeScene(rawValue: scene)?.label ?? "選んでいない")
            } label: {
                Label("場面のセット", systemImage: "square.grid.2x2")
            }
        }
    }

    private var pendingTitle: String {
        guard let pending, let entry = S22SettingEntry.all.first(where: { $0.id == pending.id }) else { return "" }
        return entry.label + "\n" + (S22Rules.switchImpact(entry.id, turningOn: pending.on) ?? "")
    }

    private func ask(_ entry: S22SettingEntry, _ on: Bool) {
        if S22Rules.switchImpact(entry.id, turningOn: on) != nil {
            pending = (entry.id, on)
        } else {
            apply(entry, on)
        }
    }

    private func apply(_ entry: S22SettingEntry, _ on: Bool) {
        entry.set(pipeline, on)
        Tally.add(S24Settings.tallyName(entry.id))
        Tally.add("s26u.quick")
        version += 1
    }
}

// MARK: - 軽4 答える山

/// 「直す」のいちばん上: 答える山への入口（今日の分の数）
struct S26UPileEntrySection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(S24AskSettings.questionCapKey) private var cap = S24AskSettings.questionCapDefault

    var body: some View {
        let cards = S26UPileSource.cards(pipeline)
        let left = S24AskRules.left(cap: S24AskRules.clampCap(cap), asked: S24Gate.counts().asked)
        let split = S26UPile.split(cards, left: left)
        Section {
            NavigationLink {
                S26UPileView()
            } label: {
                LabeledContent {
                    Text(cards.isEmpty ? "なし" : split.today.isEmpty ? "今日の分は済み" : "今日 \(split.today.count) 枚")
                        .foregroundStyle(cards.isEmpty || split.today.isEmpty ? LL.dim : LL.accent)
                } label: {
                    Label("答える山（○×）", systemImage: "square.stack.3d.down.right")
                }
            }
        } footer: {
            Text("確かめ待ち・聞いて直す・AI からの質問・自分を知るを 1 つの山に。1 枚 3 秒、右に払うと「はい」です。1 日に聞くのは全部で \(S24AskRules.clampCap(cap)) 問（仮）まで。")
        }
    }
}

/// 山の中身を集める（画面のたびに読む。どれも中の写しを読むだけ）
@MainActor
enum S26UPileSource {
    static func cards(_ pipeline: Pipeline, now: Date = .now) -> [S26UPile.Card] {
        let today = ReviewRules.dayKey(now)
        var groups: [S26UPile.Kind: [S26UPile.Card]] = [:]
        // 発言も声も無い「この声は誰？」は答えられないので山に出さない（確かめ待ちの画面には後ろに残る。s26 の S26V）
        groups[.review] = S26VVoice.forPile(S20Book.shared.openItems(now: now))
            .map { S26UPile.Card(kind: .review, id: $0.id, impact: $0.impact) }
        groups[.listen] = pipeline.reviewNudge.items(for: today).filter { !$0.isAnswered }
            .map { S26UPile.Card(kind: .listen, id: $0.id) }
        groups[.ask] = pipeline.asks.open.filter { !$0.choices.isEmpty }.map { S26UPile.Card(kind: .ask, id: $0.id) }
        groups[.know] = KnowMeBook.shared.openQuestions.filter { $0.draft != nil }.map { S26UPile.Card(kind: .know, id: $0.id) }
        return S26UPile.merge(groups)
    }
}

struct S26UPileView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(S24AskSettings.questionCapKey) private var cap = S24AskSettings.questionCapDefault
    @AppStorage(S26UPile.autoPlayKey) private var autoPlay = true
    @State private var offset: CGSize = .zero
    @State private var showMore = false
    @State private var toast: String?
    @State private var player = ClipPlayer()
    @State private var version = 0

    var body: some View {
        let cards = S26UPileSource.cards(pipeline)
        let left = S24AskRules.left(cap: S24AskRules.clampCap(cap), asked: S24Gate.counts().asked)
        let split = S26UPile.split(cards, left: left)
        let shown = showMore ? cards : split.today
        LLList {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(shown.count)").font(.largeTitle.weight(.bold)).monospacedDigit()
                    Text("枚").foregroundStyle(LL.dim)
                    Spacer()
                    if !shown.isEmpty {
                        Text("目安 \(S26UPile.minutes(shown.count)) 分").font(.caption).foregroundStyle(LL.dim)
                    }
                }
                Text("右に払うと「はい・合っている」、左は「いいえ・とばす」。1 日に聞くのは全部で \(S24AskRules.clampCap(cap)) 問（仮）までです。")
                    .font(.footnote).foregroundStyle(LL.dim)
                Toggle("音を自動で鳴らす", isOn: $autoPlay).font(.callout)
            } header: {
                LLHeader(title: "答える山", symbol: "square.stack.3d.down.right")
            }
            if let first = shown.first {
                Section {
                    card(first, rest: shown.count - 1)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                        .listRowBackground(Color.clear)
                    if let toast {
                        Label(toast, systemImage: "checkmark.circle").font(.caption).foregroundStyle(LL.good)
                    }
                }
            } else {
                Section {
                    if split.more.isEmpty {
                        LLEmpty(title: "答えるものはありません", symbol: "checkmark.circle",
                                detail: "確かめ待ち・聞いて直す・AI からの質問・自分を知るが、ここに 1 つの山で届きます。")
                    } else {
                        LLEmpty(title: "今日の分は済みました", symbol: "checkmark.circle",
                                detail: "残りは \(split.more.count) 枚。答えなくても、期限が来れば静かに閉じます。")
                        Button("続けて答える（\(split.more.count) 枚）") { showMore = true }
                    }
                }
            }
            Section {
                NavigationLink("確かめ待ちを全部（まとめて答える）") { ReviewDeckView() }
                NavigationLink("聞いて直す（文を直す）") { ReviewNudgeView() }
                NavigationLink("AI からの質問") { QuestionsView() }
                NavigationLink("自分を知る") { KnowMeView() }
            } header: {
                Text("1 つずつの画面")
            } footer: {
                Text("文で答えるもの・直すものは、こちらの画面で。")
            }
        }
        .id(version)
        .navigationTitle("答える")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s26uPile")
        .s26uHelp("s26uPile")
        .task(id: shown.first?.id) {
            guard autoPlay, let first = shown.first else { return }
            await autoSound(first)
        }
    }

    // MARK: 1 枚

    private func card(_ c: S26UPile.Card, rest: Int) -> some View {
        VStack(alignment: .leading, spacing: LL.Space.m) {
            HStack {
                Label(c.kind.label, systemImage: c.kind.symbol).font(.caption.weight(.semibold)).foregroundStyle(LL.accent)
                Spacer()
                if rest > 0 { Text("あと \(rest) 枚").font(.caption2).foregroundStyle(LL.dim) }
            }
            Text(question(c)).font(.title3.weight(.semibold)).foregroundStyle(LL.text)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = detail(c) {
                Text(detail).font(.callout).foregroundStyle(LL.dim).fixedSize(horizontal: false, vertical: true)
            }
            // 話し手を聞く問いは、発言 3 つ → 声 → 名前のボタン（確かめ待ちの画面と同じ部品。2026-11-25。s26 の S26V）
            if c.kind == .review, let item = reviewItem(c.id), S26VVoice.isVoiceAsk(item) {
                S26VVoiceBlock(item: item)
            }
            buttons(c)
        }
        .padding(LL.Space.l)
        .background(LL.surface, in: RoundedRectangle(cornerRadius: LL.Radius.big))
        .overlay(RoundedRectangle(cornerRadius: LL.Radius.big).strokeBorder(swipeColor, lineWidth: LL.Stroke.bold))
        .offset(x: offset.width)
        .rotationEffect(.degrees(Double(offset.width) / 30))
        .gesture(swipe(c))
        .animation(LL.Motion.state, value: offset)
        .id(c.kind.rawValue + c.id)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "はい") { answer(c, yes: true) }
        .accessibilityAction(named: "いいえ") { answer(c, yes: false) }
    }

    private var swipeColor: Color {
        if offset.width > 40 { return LL.good }
        if offset.width < -40 { return LL.danger }
        return LL.accent
    }

    private func swipe(_ c: S26UPile.Card) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { offset = $0.translation }
            .onEnded { value in
                if swipeable(c), let yes = S26UPile.swipe(Double(value.translation.width)) { answer(c, yes: yes) }
                offset = .zero
            }
    }

    @ViewBuilder
    private func buttons(_ c: S26UPile.Card) -> some View {
        switch c.kind {
        case .review:
            if let item = reviewItem(c.id), S22Rules.answerStyle(answer: item.answer, choices: item.choices) == "pick" {
                FlowLayout(spacing: LL.Space.s) {
                    ForEach(item.choices ?? [], id: \.self) { choice in
                        Button(choice) { pickReview(item, choice) }.buttonStyle(LLPillButtonStyle())
                    }
                }
            } else if let item = reviewItem(c.id), !S22Rules.isYesNo(answer: item.answer, choices: item.choices) {
                NavigationLink("開いて答える") { ReviewDeckView() }
            } else {
                yesNo(c, yes: "はい", no: "いいえ")
            }
        case .listen:
            HStack(spacing: LL.Space.m) {
                Button("聞く", systemImage: "play.circle") { Task { await play(c, force: true) } }
                    .buttonStyle(LLPillButtonStyle(tint: LL.dim))
                NavigationLink("直す") { ReviewNudgeView() }
            }
            yesNo(c, yes: "合っている", no: "とばす")
        case .ask:
            if let q = askQuestion(c.id) {
                FlowLayout(spacing: LL.Space.s) {
                    ForEach(q.choices, id: \.self) { choice in
                        Button(choice) { answerAsk(q, choice, card: c) }.buttonStyle(LLPillButtonStyle())
                    }
                }
                NavigationLink("ほかの答え・分からない") { QuestionsView() }.font(.callout)
            }
        case .know:
            HStack(spacing: LL.Space.m) {
                Button("このままでよい") { answer(c, yes: true) }.buttonStyle(LLPillButtonStyle(tint: LL.good, filled: true))
                NavigationLink("直して答える") { KnowMeView() }
            }
        }
    }

    private func yesNo(_ c: S26UPile.Card, yes: String, no: String) -> some View {
        HStack(spacing: LL.Space.m) {
            Button {
                answer(c, yes: false)
            } label: {
                Label(no, systemImage: "xmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(LLPillButtonStyle(tint: LL.danger))
            Button {
                answer(c, yes: true)
            } label: {
                Label(yes, systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(LLPillButtonStyle(tint: LL.good, filled: true))
        }
    }

    // MARK: 中身

    private func reviewItem(_ id: String) -> ReviewItem? { S20Book.shared.openItems().first { $0.id == id } }
    private func nudgeItem(_ id: String) -> ReviewNudge.Item? { pipeline.reviewNudge.items.first { $0.id == id } }
    private func askQuestion(_ id: String) -> AskBook.Question? { pipeline.asks.open.first { $0.id == id } }
    private func knowQuestion(_ id: String) -> KnowQuestion? { KnowMeBook.shared.openQuestions.first { $0.id == id } }

    private func question(_ c: S26UPile.Card) -> String {
        switch c.kind {
        case .review: return reviewItem(c.id)?.question ?? ""
        case .listen: return "この文で合っていますか？"
        case .ask: return askQuestion(c.id)?.question ?? ""
        case .know: return knowQuestion(c.id)?.text ?? ""
        }
    }

    private func detail(_ c: S26UPile.Card) -> String? {
        switch c.kind {
        case .review: return nil
        case .listen: return nudgeItem(c.id).map { "「\($0.text)」" }
        case .ask: return askQuestion(c.id)?.quote
        case .know: return knowQuestion(c.id)?.draft.map { "下書き: " + $0 }
        }
    }

    /// 払えるもの（はい・いいえで答えられるもの）
    private func swipeable(_ c: S26UPile.Card) -> Bool {
        switch c.kind {
        case .review:
            guard let item = reviewItem(c.id) else { return false }
            return S22Rules.isYesNo(answer: item.answer, choices: item.choices)
        case .listen, .know: return true
        case .ask: return false
        }
    }

    // MARK: 答える

    private func answer(_ c: S26UPile.Card, yes: Bool) {
        let today = ReviewRules.dayKey(.now)
        switch c.kind {
        case .review:
            guard let item = reviewItem(c.id) else { return }
            // 1 日 3 問の数えは S20Book が入れる
            S20Book.shared.answer(item, yes ? "yes" : "no")
        case .listen:
            guard let item = nudgeItem(c.id) else { return }
            if yes { pipeline.confirmReviewNudge(item, text: item.text) } else { pipeline.skipReviewNudge(item) }
            S24Gate.noteAnswered(key: c.askKey)
        case .know:
            guard let q = knowQuestion(c.id) else { return }
            if yes { KnowMeBook.shared.draftOK(q, day: today) } else { KnowMeBook.shared.skip(q, day: today) }
            S24Gate.noteAnswered(key: c.askKey)
        case .ask:
            return
        }
        done(yes ? "はい" : "いいえ")
    }

    private func pickReview(_ item: ReviewItem, _ choice: String) {
        S20Book.shared.answer(item, choice)
        done(choice)
    }

    private func answerAsk(_ q: AskBook.Question, _ choice: String, card: S26UPile.Card) {
        pipeline.answerQuestion(q, with: choice)
        S24Gate.noteAnswered(key: card.askKey)
        done(choice)
    }

    private func done(_ word: String) {
        LLHaptic.done.play()
        Tally.add("s26u.pile.answered")
        withAnimation(LL.Motion.fade) { toast = "「\(word)」で答えました" }
        version += 1
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(LL.Motion.fade) { toast = nil }
        }
    }

    // MARK: 音

    private func autoSound(_ c: S26UPile.Card) async {
        guard c.kind == .listen else { return }
        await play(c, force: false)
    }

    /// 聞いて直すの行の所の音（切り出して残した音があれば、それを。無ければ元の音声。ReviewNudgeView と同じ）
    private func play(_ c: S26UPile.Card, force: Bool) async {
        guard let item = nudgeItem(c.id) else { return }
        let key = "pile-" + item.id
        if !force, player.playing == key { return }
        let context = pipeline.reviewNudgeContext(item)
        let stop = context.stop ?? ReviewNudge.stop(offset: item.offset, end: item.end, next: nil, chars: item.text.count)
        if let clip = pipeline.reviewNudgeClip(audio: item.audio, offset: item.offset) {
            await player.toggle(key, at: item.offset - clip.from, until: stop - clip.from) { clip.url }
        } else {
            await player.toggle(key, at: item.offset, until: stop) { await pipeline.archive.playableURL(for: item.audio) }
        }
    }
}

// MARK: - 軽5（K5）本人の操作待ち

struct S26UWaitingView: View {
    @Environment(\.openURL) private var openURL
    @State private var copied: String?

    var body: some View {
        let order = S26UFeeds.waitingOrder(S26UBook.shared.waiting)
        let known = Set(S26UBook.shared.waiting.map(\.id))
        let extra = S33ABook.shared.extraWaiting(known: known)
        LLList {
            if order.open.isEmpty && extra.isEmpty {
                Section {
                    LLEmpty(title: "いまは操作待ちはありません", symbol: "checkmark.circle",
                            detail: "機械ではできず、本人の操作が要るもの（許可・入れ直し・登録など）が、ここに 1 件ずつ届きます。")
                }
            }
            ForEach(order.open) { item in
                Section {
                    ForEach(Array((item.steps ?? []).enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(LL.accent)
                            Text(step).font(.callout)
                        }
                    }
                    if let url = S26UFeeds.openable(item.link) {
                        Button("開く", systemImage: "arrow.up.forward.square") {
                            Tally.add("s26u.waiting.open")
                            openURL(url)
                        }
                    }
                    if let copy = item.copy, !copy.isEmpty {
                        Button(copied == item.id ? "コピーしました" : "貼る文字をコピー", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = copy
                            copied = item.id
                            Tally.add("s26u.waiting.copy")
                            LLHaptic.done.play()
                        }
                        Text(copy).font(.caption.monospaced()).foregroundStyle(LL.dim).lineLimit(3).textSelection(.enabled)
                    }
                } header: {
                    HStack(spacing: LL.Space.xs) {
                        LLToneMark(tone: .act)
                        Text(item.title).font(.subheadline.weight(.bold)).foregroundStyle(LL.text).textCase(nil)
                    }
                }
            }
            // 家の PC の /s33 の操作待ち（2026-11-27。s33 の K33-1。S33AViews.swift）
            S33AWaitingRows(known: known)
            if !order.done.isEmpty {
                Section {
                    ForEach(order.done) { item in
                        Label(item.title, systemImage: "checkmark.circle").foregroundStyle(LL.dim)
                    }
                } header: {
                    Text("済んだもの（機械が確かめました）")
                }
            }
        }
        .navigationTitle("本人の操作待ち")
        .countsOpen("s26uWaiting")
        .s26uHelp("s26uWaiting")
        .refreshable {
            if let pipeline = S26UBook.pipeline { await S26UBook.shared.refresh(pipeline) }
        }
    }
}

// MARK: - 軽9（K4）機械がしたこと

struct S26UMachineView: View {
    @State private var confirm: S26UMachineAction?

    var body: some View {
        let book = S26UBook.shared
        let list = S26UFeeds.machineOrder(book.machine)
        LLList {
            if list.isEmpty {
                Section {
                    LLEmpty(title: "まだ届いていません", symbol: "gearshape.2",
                            detail: "機械が自動で閉じたタスク・自動の直し・自動で付けた名前が、家の PC からここに届きます。")
                }
            } else {
                Section {
                    ForEach(list) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(action.kindLabel).font(.caption.weight(.semibold)).foregroundStyle(LL.accent)
                                Spacer()
                                if let at = action.at.flatMap(PCJSON.date) {
                                    Text(at.formatted(.dateTime.month().day().hour().minute())).font(.caption2).foregroundStyle(LL.dim)
                                }
                            }
                            Text(action.what).font(.callout)
                            if book.undone[action.id] != nil {
                                Label("戻すよう頼みました（次の回に母艦が戻します）", systemImage: "arrow.uturn.backward")
                                    .font(.caption).foregroundStyle(LL.good)
                            } else if action.canUndo {
                                Button("戻す", systemImage: "arrow.uturn.backward") { confirm = action }
                                    .font(.callout)
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("「戻す」は家の PC を通して母艦に伝え、次の回に母艦が元に戻します。すぐには変わりません。")
                }
            }
        }
        .navigationTitle("機械がしたこと")
        .countsOpen("s26uMachine")
        .s26uHelp("s26uMachine")
        .confirmationDialog(confirm.map { "「\($0.what)」を戻しますか？" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button("戻す") {
                if let confirm { book.undo(confirm) }
                confirm = nil
            }
            Button("やめる", role: .cancel) { confirm = nil }
        }
        .refreshable {
            if let pipeline = S26UBook.pipeline { await S26UBook.shared.refresh(pipeline) }
        }
    }
}

/// 設定（点検・設定のどちらも）のいちばん上: 本人の操作待ち・機械がしたこと（届いているときだけ）
struct S26USettingsTopSection: View {
    var body: some View {
        let book = S26UBook.shared
        // s33 の操作待ちだけのときも出す（2026-11-27。K33-1）
        let anyWaiting = !book.waiting.isEmpty || book.waitingOpen > 0
        if anyWaiting || !book.machine.isEmpty {
            Section {
                if anyWaiting {
                    NavigationLink {
                        S26UWaitingView()
                    } label: {
                        LabeledContent {
                            Text(book.waitingOpen > 0 ? "\(book.waitingOpen) 件" : "なし")
                                .foregroundStyle(book.waitingOpen > 0 ? LL.danger : LL.dim)
                        } label: {
                            Label("本人の操作待ち", systemImage: "hand.point.up.left")
                        }
                    }
                }
                if !book.machine.isEmpty {
                    NavigationLink {
                        S26UMachineView()
                    } label: {
                        LabeledContent {
                            Text("\(book.machine.count) 件")
                        } label: {
                            Label("機械がしたこと（戻せる）", systemImage: "gearshape.2")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 軽10 自己点検で本人が何もできない行を畳む

/// 自己点検の下に置く「機械が見ている行」（畳んだ行。消していない）
struct S26UFoldedCheckSection: View {
    let items: [DiagnosticItem]

    var body: some View {
        if !items.isEmpty {
            Section {
                DisclosureGroup("機械が見ている行（\(items.count)）") {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            LLToneMark(tone: LLTone.of(ok: item.ok, fix: S22Checkup.fix(section: item.section, label: item.label, value: item.value).rawValue))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.section + " / " + item.label).font(.caption).foregroundStyle(LL.dim)
                                Text(LLNumber.display(item.value)).font(.callout)
                            }
                        }
                    }
                }
            } footer: {
                Text("待てば直るか、Claude と機械が見ている行です。本人がすることは無いので、上の一覧から外しました（設定の「本人が何もできない行は畳む」で戻せます）。")
            }
        }
    }
}

enum S26UCheckFold {
    /// 上に出す行と、畳む行
    static func split(_ items: [DiagnosticItem], on: Bool) -> (shown: [DiagnosticItem], folded: [DiagnosticItem]) {
        guard on else { return (items, []) }
        var shown: [DiagnosticItem] = []
        var folded: [DiagnosticItem] = []
        for item in items {
            let fix = S22Checkup.fix(section: item.section, label: item.label, value: item.value)
            if S26UCheckRows.folds(ok: item.ok, fix: fix) { folded.append(item) } else { shown.append(item) }
        }
        return (shown, folded)
    }
}

// MARK: - 切り替え（くわしい設定のいちばん下。どれも画面の表示だけで、初めはオン）

struct S26USwitchesSection: View {
    @AppStorage(S26UQuick.key) private var quick = true
    @AppStorage(S26UPile.key) private var pile = true
    @AppStorage(S26UCheckRows.key) private var fold = true

    var body: some View {
        Section {
            Toggle("「今日」に、よく変える設定 3 つ", isOn: $quick)
            Toggle("「直す」の答えるものを 1 つの山に", isOn: $pile)
            Toggle("自己点検で、本人が何もできない行は畳む", isOn: $fold)
        } header: {
            LLHeader(title: "見せ方（s26）", symbol: "rectangle.3.group")
        } footer: {
            Text("どれも画面の並びだけです。切ると前の並びに戻ります（消したものはありません）。")
        }
    }
}

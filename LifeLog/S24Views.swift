import SwiftUI

// s24（2026-11-24）の画面: 今日の 1 問（形3）・よく触る設定（形2）・入口の「ほか」（形5・減12）・色の役割（形8）。
// 決まりは S24Rules.swift と Shared/Design/S24DesignRules.swift。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 13」。

// MARK: - 形8 色の役割

extension LLRole {
    /// 赤＝いま本人が動く・青＝機械が進めている・オレンジ＝待てば戻る（s26 の 絵2 で灰から替えた）・問いは文字の色のまま
    var color: Color {
        switch self {
        case .act: LL.danger
        case .machine: LL.accent
        case .wait: LL.warn
        case .ask: LL.text
        }
    }

    var symbol: String {
        switch self {
        case .act: "hand.point.up.left.fill"
        case .machine: "gearshape.2"
        case .wait: "hourglass"
        case .ask: "questionmark.circle"
        }
    }
}

/// 色の役割つきの 1 行（色と形の両方で分かるように）
struct S24RoleLabel: View {
    let text: String
    let role: LLRole

    var body: some View {
        Label {
            Text(text).foregroundStyle(role == .ask ? LL.text : role.color)
        } icon: {
            Image(systemName: role.symbol).foregroundStyle(role.color)
        }
        .accessibilityLabel(role.label + "。" + text)
    }
}

// MARK: - 形5・減12 畳んだ画面の帳

@MainActor
@Observable
final class S24FoldBook {
    static let shared = S24FoldBook()

    /// 本人が畳んだ画面の名前（減12。戻せる）
    private(set) var folded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: S24Entries.foldedKey) ?? [])

    func fold(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        folded.formUnion(keys)
        save()
        Tally.add("s24.fold", keys.count)
    }

    func unfold(_ key: String) {
        guard folded.remove(key) != nil else { return }
        save()
        Tally.add("s24.unfold")
    }

    func unfoldAll() {
        guard !folded.isEmpty else { return }
        folded.removeAll()
        save()
        Tally.add("s24.unfoldAll")
    }

    private func save() {
        UserDefaults.standard.set(folded.sorted(), forKey: S24Entries.foldedKey)
    }

    /// 減12 の候補（入口のある画面のうち、30 日で 1 回も開かれていないもの。その画面を数え始めて 30 日たってから）
    func unusedCandidates(now: Date = .now) -> [String] {
        S24Entries.unusedCandidates(S24Entry.all.map { (key: $0.key, since: $0.since) },
                                    sums30: Tally.sums(days: S24Entries.unusedDays, now: now),
                                    today: ReviewRules.dayKey(now), folded: folded)
    }

    /// 減12 をいま出すか（出すときは、出した日を残す＝1 回だけ）
    func offer(now: Date = .now) -> [String] {
        let defaults = UserDefaults.standard
        let today = ReviewRules.dayKey(now)
        guard today >= S24Entries.offerFrom, !defaults.bool(forKey: S24Entries.answeredKey) else { return [] }
        let candidates = unusedCandidates(now: now)
        guard S24Entries.shouldOffer(today: today, offeredDay: defaults.string(forKey: S24Entries.offeredDayKey),
                                     answered: false, candidates: candidates) else { return [] }
        if defaults.string(forKey: S24Entries.offeredDayKey) == nil {
            defaults.set(today, forKey: S24Entries.offeredDayKey)
            Tally.add("s24.unusedOffered")
        }
        return candidates
    }

    /// 減12 に答えた（畳む・今はしない）
    func answerOffer(fold keys: [String]?) {
        UserDefaults.standard.set(true, forKey: S24Entries.answeredKey)
        if let keys { fold(keys) } else { Tally.add("s24.unusedKept") }
    }
}

// MARK: - 形5 入口の一覧（畳める画面）

@MainActor
struct S24Entry: Identifiable {
    let key: String
    let title: String
    let symbol: String
    /// どの一覧にあるか（lookBack・records）
    let list: String
    /// 開いた数を数え始めた日（画面の数えは 2026-11-06 から・s20 の画面は 11-21・数える印を足したものは 11-24）
    let since: String
    let open: @MainActor () -> AnyView

    var id: String { key }

    /// 畳める入口（ここに無い画面は今までどおり）。key は画面を開いた数の名前（"screen." + key）と同じ
    static let all: [S24Entry] = [
        S24Entry(key: "goodThings", title: "いいこと帳", symbol: "hand.thumbsup", list: "lookBack", since: "2026-11-06") { AnyView(GoodThingsView()) },
        S24Entry(key: "speaking", title: "話し方の振り返り", symbol: "person.wave.2", list: "lookBack", since: "2026-11-06") { AnyView(SpeakingView()) },
        S24Entry(key: "briefCompare", title: "朝のまとめ 比べる", symbol: "rectangle.split.2x1", list: "lookBack", since: "2026-11-13") {
            AnyView(BriefCompareView())
        },
        S24Entry(key: "workWeek", title: "週のまとめ（週報の下書き）", symbol: "calendar", list: "lookBack", since: "2026-11-24") {
            AnyView(WorkWeekView().countsOpen("workWeek"))
        },
        S24Entry(key: "workThreads", title: "案件ごと", symbol: "point.3.connected.trianglepath.dotted", list: "lookBack", since: "2026-11-24") {
            AnyView(WorkThreadsView().countsOpen("workThreads"))
        },
        S24Entry(key: "taskScore", title: "タスクを数で見る", symbol: "chart.bar", list: "lookBack", since: "2026-11-24") {
            AnyView(TaskScoreView().countsOpen("taskScore"))
        },
        S24Entry(key: "facts", title: "わかったこと帳", symbol: "lightbulb", list: "lookBack", since: "2026-11-24") { AnyView(FactsView().countsOpen("facts")) },
        S24Entry(key: "ask", title: "記録に質問する", symbol: "questionmark.bubble", list: "records", since: "2026-11-06") { AnyView(AskView()) },
        S24Entry(key: "unifiedSearch", title: "探す（人・場所・日・言葉・質問）", symbol: "magnifyingglass", list: "records", since: "2026-11-21") {
            AnyView(UnifiedSearchView())
        },
        S24Entry(key: "dayBand", title: "1 日の帯で選ぶ（消す・書き出す・印）", symbol: "slider.horizontal.below.rectangle", list: "records", since: "2026-11-21") {
            AnyView(DayBandView(day: Date.now))
        },
    ]

    static func of(_ key: String) -> S24Entry? { all.first { $0.key == key } }

    /// その一覧で、いま出す入口と「ほか」に入れる入口（available はいま使える入口。元の並び）
    static func split(list: String, available: Set<String>) -> (shown: Set<String>, other: [String]) {
        let keys = all.filter { $0.list == list && available.contains($0.key) }.map(\.key)
        let sums = Tally.sums(days: S24Entries.unusedDays)
        var opens: [String: Int] = [:]
        for key in keys { opens[key] = sums["screen." + key] ?? 0 }
        let result = S24Entries.split(keys, opens: opens, folded: S24FoldBook.shared.folded, limitOn: S24Entries.limitOn)
        return (Set(result.shown), result.other)
    }
}

/// 一覧のいちばん下の「ほか」（畳んだ入口。消していない・戻せる）
struct S24OtherSection: View {
    let other: [String]
    @State private var open = false

    var body: some View {
        let book = S24FoldBook.shared
        if !other.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $open) {
                    ForEach(other, id: \.self) { key in
                        if let entry = S24Entry.of(key) {
                            NavigationLink {
                                entry.open()
                            } label: {
                                Label(entry.title, systemImage: entry.symbol)
                            }
                            .swipeActions {
                                if book.folded.contains(key) {
                                    Button("戻す") { book.unfold(key) }.tint(LL.accent)
                                }
                            }
                            .contextMenu {
                                if book.folded.contains(key) {
                                    Button("元の場所に戻す", systemImage: "arrow.uturn.backward") { book.unfold(key) }
                                }
                            }
                        }
                    }
                    if !book.folded.isEmpty {
                        Button("畳んだ画面を全部元の場所に戻す", systemImage: "arrow.uturn.backward") { book.unfoldAll() }
                            .font(.callout)
                    }
                } label: {
                    Label("ほか", systemImage: "square.stack")
                }
            } footer: {
                Text("あまり開かない入口をここに畳んでいます（消していません）。畳んだものは、左にすべらせると元の場所に戻せます。設定の「入口は 5 つまで」で前の並びに戻せます。")
            }
        }
    }
}

// MARK: - 形3 今日の 1 問

struct S24TodayAskSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var foldOffer: [String] = []
    @State private var version = 0

    var body: some View {
        let review = S20Book.shared.openItems().map { (id: $0.id, question: $0.question) }
        let know = KnowMeBook.shared.openQuestions.map { (id: $0.id, text: $0.text) }
        let missed = S23Book.shared.dueMissed().count
        let ask = S24Today.pickAsk(foldOffer: foldOffer, review: review, know: know, missed: missed)
        Section {
            switch ask {
            case .fold(let keys):
                VStack(alignment: .leading, spacing: 8) {
                    let names = keys.compactMap { S24Entry.of($0)?.title }
                    S24RoleLabel(text: "30 日開かなかった画面（" + names.joined(separator: "・") + "）を「ほか」に畳みますか？", role: .ask)
                        .font(.callout)
                    HStack(spacing: 12) {
                        Button("畳む") {
                            S24FoldBook.shared.answerOffer(fold: keys)
                            foldOffer = []
                        }
                        .buttonStyle(LLPillButtonStyle(filled: true))
                        Button("今はしない") {
                            S24FoldBook.shared.answerOffer(fold: nil)
                            foldOffer = []
                        }
                        .buttonStyle(LLPillButtonStyle(tint: LL.dim))
                    }
                    Text("1 回だけ聞きます。畳んだ画面は、その一覧のいちばん下の「ほか」から開けて、元の場所に戻せます。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            case .review(_, let question):
                NavigationLink {
                    ReviewDeckView()
                } label: {
                    S24RoleLabel(text: question, role: .ask).font(.callout)
                }
            case .know(_, let text):
                NavigationLink {
                    KnowMeView()
                } label: {
                    S24RoleLabel(text: text, role: .ask).font(.callout)
                }
            case .missed:
                Button {
                    S23Present.shared.sheet = S23Sheet(kind: .missed)
                } label: {
                    S24RoleLabel(text: "答えそびれた質問があります", role: .ask).font(.callout)
                }
            case .nothing:
                // ほかに聞くことが無いときだけ、名前の無い声の「この声は誰？」（1 日 3 問の中。2026-11-24。s25 の 大9）
                S25TVoiceAskRow()
            }
        } header: {
            Text("今日の 1 問")
        }
        .id(version)
        .onAppear { foldOffer = S24FoldBook.shared.offer() }
    }
}

// MARK: - 形2 よく触る設定を「今日」から

/// 「くわしい設定」で触った設定を数える（開いたときと閉じた・ほかの画面に移ったときの違いを数える）
struct S24CountsTouches: ViewModifier {
    @Environment(Pipeline.self) private var pipeline
    @State private var before: [String: Bool] = [:]

    func body(content: Content) -> some View {
        content
            .onAppear { before = snapshot() }
            .onDisappear {
                for id in S24Settings.changed(before: before, after: snapshot()) {
                    Tally.add(S24Settings.tallyName(id))
                }
                before = [:]
            }
    }

    private func snapshot() -> [String: Bool] {
        var out: [String: Bool] = [:]
        for entry in S22SettingEntry.all { out[entry.id] = entry.get(pipeline) }
        return out
    }
}

extension View {
    func s24CountsTouches() -> some View { modifier(S24CountsTouches()) }
}

/// 「今日」の小さな列: よく触る 3 つ（数がまだ無いうちは初めの 3 つで「仮」）
struct S24QuickSettingsSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var version = 0
    @State private var pending: (id: String, on: Bool)?

    var body: some View {
        let entries = S22SettingEntry.all
        let pick = S24Settings.top(entries.map(\.id), sums: Tally.sums(days: S24Settings.days))
        let shown = pick.ids.compactMap { id in entries.first { $0.id == id } }
        if !shown.isEmpty {
            Section {
                ForEach(shown) { entry in
                    let on = entry.get(pipeline)
                    Toggle(entry.label, isOn: Binding(get: { on }, set: { ask(entry, $0) }))
                        .font(.callout)
                }
            } header: {
                Text(pick.provisional ? "よく触る設定（仮）" : "よく触る設定")
            } footer: {
                if pick.provisional {
                    Text("「くわしい設定」で触った数がたまると、よく触る 3 つに入れ替わります（いまは初めに決めた 3 つ）。")
                }
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
    }

    private var pendingTitle: String {
        guard let pending, let entry = S22SettingEntry.all.first(where: { $0.id == pending.id }) else { return "" }
        return entry.label + "\n" + (S22Rules.switchImpact(entry.id, turningOn: pending.on) ?? "")
    }

    /// 電池と速さに効くスイッチは見込みを出してから（設定を探すと同じ）
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
        Tally.add("s24.quickSetting")
        version += 1
    }
}

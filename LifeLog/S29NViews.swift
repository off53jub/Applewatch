import SwiftUI

// s29（2026-11-27）名前付けを軽くする（S29N）の画面。決まりは S29NRules.swift、動きは S29NBook.swift。
// - 声24 「直す」の名前付けの入口を 1 つの山に（前の 4 つの入口は山の「もっと見る」へ）。1 日 3 件（仮）まで
// - 声20 答えは 3 つのボタン（たぶん ◯◯さん・別の人・知らない人）。名前を打つのは最後の手段。発言 3 つと声を最初から見せる
// - 声18 届いていない人の数を下に 1 行・声21 もう聞かない人は設定の奥から戻す・声23 「今から ◯◯さんと」
// 新しい知らせは作らない。

// MARK: - 「直す」の入口

struct S29NPileEntrySection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = S29NBook.shared
        let today = book.todayCards()
        let all = book.result.cards.count
        Section {
            NavigationLink {
                S29NPileView()
            } label: {
                LabeledContent {
                    Text(today.isEmpty ? (all == 0 ? "なし" : "今日の分は済み") : "今日 \(today.count) 件")
                        .foregroundStyle(today.isEmpty ? LL.dim : LL.accent)
                } label: {
                    Label("名前を付ける声", systemImage: "person.wave.2")
                }
            }
            S29NWithNowRow()
        } footer: {
            Text("名前を付けてほしい声を 1 つの山にしました。よく話す声から 1 日 \(S29NSettings.daily) 件（仮）まで。7 日で \(S29NSettings.minDays) 日以上・合計 \(S29NSettings.minSeconds / 60) 分以上（仮）の声だけを聞きます。")
        }
    }
}

// MARK: - 名前付けの山

struct S29NPileView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var showMore = false
    @State private var note: String?
    @State private var working = false
    @State private var player = ClipPlayer()

    var body: some View {
        let book = S29NBook.shared
        let today = book.todayCards()
        let all = book.result.cards
        let shown = showMore ? all : today
        LLList {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(shown.count)").font(.largeTitle.weight(.bold)).monospacedDigit()
                    Text("件").foregroundStyle(LL.dim)
                    Spacer()
                    if book.refreshing { ProgressView() }
                }
                Text("よく話す声から順に聞きます。答えは 3 つのボタンから。1 日に聞くのは全部で \(S24AskSettings.questionCap) 問（仮）までです。")
                    .font(.footnote).foregroundStyle(LL.dim)
                if let note {
                    Label(note, systemImage: "checkmark.circle").font(.caption).foregroundStyle(LL.good)
                }
            } header: {
                LLHeader(title: "名前を付ける声", symbol: "person.wave.2")
            }
            if let first = shown.first {
                Section {
                    S29NCardView(card: first, guess: book.guesses[first.id], rest: shown.count - 1, player: player,
                                 working: $working) { text in
                        withAnimation(LL.Motion.fade) { note = text }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    if all.isEmpty {
                        LLEmpty(title: book.refreshing ? "数えています…" : "今日は聞くことはありません", symbol: "checkmark.circle",
                                detail: "よく話す声（7 日で \(S29NSettings.minDays) 日以上・合計 \(S29NSettings.minSeconds / 60) 分以上・仮）に名前の無いものがあれば、ここに出ます。それ以外の声は聞きません。")
                    } else {
                        LLEmpty(title: "今日の分は済みました", symbol: "checkmark.circle",
                                detail: "残りは \(all.count) 件。明日また、よく話す声から出します。")
                        Button("続けて答える（\(all.count) 件）") { showMore = true }
                    }
                }
            }
            Section {
                S29NWithNowRow()
            } footer: {
                Text("会う前に押すと、その時間の声はその人を先に考えます（\(S29NSettings.withNowHours) 時間・仮）。知らせは出しません。")
            }
            Section {
                NavigationLink("声を聞いて直す（ひとこまごと）") { VoiceReviewView() }
                NavigationLink("○× でまとめて") { S21VoiceQuickReviewView() }
                NavigationLink("今日の人物N を整理") { UnnamedVoicesView(day: ReviewRules.dayKey(.now)) }
                NavigationLink("話した相手（全部の声）") { PeopleView() }
                NavigationLink("しぼり・もう聞かない人") { S29NSettingsView() }
            } header: {
                Text("もっと見る")
            } footer: {
                S29NOthersLine(result: book.result)
            }
        }
        .navigationTitle("名前を付ける")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s29nPile")
        .onDisappear { player.stop() }
        .task {
            await SamePersonBook.shared.refresh(pipeline.homePC)
            await S29NBook.shared.refresh(pipeline)
        }
        .refreshable {
            await SamePersonBook.shared.refresh(pipeline.homePC, force: true)
            await S29NBook.shared.refresh(pipeline, force: true)
        }
    }
}

/// 声18: 届いていない人・もう聞かない人・外した声の数（1 行）
struct S29NOthersLine: View {
    let result: S29NPile.Result

    var body: some View {
        let others = result.below + result.noMaterial
        Text("その他の人 \(others) 人（よく話す声に届かない・発言の無い声。聞きません）・もう聞かない人 \(result.quiet) 人・通りすがりやテレビで外した声 \(result.skipped) 人")
            .font(.caption).foregroundStyle(LL.dim)
    }
}

// MARK: - 1 件

struct S29NCardView: View {
    @Environment(Pipeline.self) private var pipeline
    let card: S29NCard
    let guess: S29NClue?
    let rest: Int
    let player: ClipPlayer
    @Binding var working: Bool
    var onDone: (String) -> Void
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.m) {
            HStack {
                Label(card.kind == .group ? "同じ人らしい声" : card.kind == .selfVoice ? "自分の声" : "名前の無い声",
                      systemImage: card.kind == .selfVoice ? "person.crop.circle" : "person.wave.2")
                    .font(.caption.weight(.semibold)).foregroundStyle(LL.accent)
                Spacer()
                if rest > 0 { Text("あと \(rest) 件").font(.caption2).foregroundStyle(LL.dim) }
            }
            if card.kind == .selfVoice {
                selfVoice
            } else {
                voice
            }
        }
        .padding(LL.Space.l)
        .background(LL.surface, in: RoundedRectangle(cornerRadius: LL.Radius.big))
        .overlay(RoundedRectangle(cornerRadius: LL.Radius.big).strokeBorder(LL.accent, lineWidth: LL.Stroke.bold))
        .disabled(working)
        .sheet(isPresented: $picking) {
            NavigationStack {
                S29NPersonPicker(card: card) { text in
                    picking = false
                    onDone(text)
                }
            }
        }
    }

    // MARK: 声14 自分の声を録る

    private var selfVoice: some View {
        VStack(alignment: .leading, spacing: LL.Space.s) {
            Text("自分の声の見本が足りません").font(.title3.weight(.semibold)).foregroundStyle(LL.text)
            Text("自分の声が決まると、残りの声が相手だと分かりやすくなります。静かな所で 20 秒ずつ、ふだんの声・小声・会議の声を録ってください（全部で 3 分ほど）。")
                .font(.callout).foregroundStyle(LL.dim).fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                VoiceEnrollView()
                    .onDisappear { S29NBook.shared.openedSelfVoice(card) }
            } label: {
                Label("自分の声を録る（3 分）", systemImage: "mic").frame(maxWidth: .infinity)
            }
            .buttonStyle(LLPillButtonStyle(tint: LL.good, filled: true))
            Button("あとで") { S29NBook.shared.postpone(card) }
                .font(.callout).foregroundStyle(LL.dim)
        }
    }

    // MARK: 声20 3 つのボタン

    private var voice: some View {
        VStack(alignment: .leading, spacing: LL.Space.s) {
            Text(card.kind == .group ? "この声は、だれですか（\(card.members.count) つの声を同じ人とみてまとめました）" : "この声は、だれですか")
                .font(.title3.weight(.semibold)).foregroundStyle(LL.text).fixedSize(horizontal: false, vertical: true)
            Text(labels).font(.caption).foregroundStyle(LL.dim)
            Text("7 日で \(card.days) 日・\(max(1, Int(card.seconds / 60))) 分・\(card.lines) 行").font(.caption).foregroundStyle(LL.dim)
            Text("この声の発言").font(.caption.weight(.semibold)).foregroundStyle(LL.dim)
            ForEach(Array(card.quotes.enumerated()), id: \.offset) { i, q in
                quoteRow(q, index: i)
            }
            if let guess {
                Button {
                    run {
                        if let target = guess.target {
                            return await S29NBook.shared.answer(card, target: target, pipeline: pipeline)
                        }
                        return await S29NBook.shared.answer(card, name: guess.name, pipeline: pipeline)
                    }
                } label: {
                    Label(S29NGuess.title(guess.name), systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(LLPillButtonStyle(tint: LL.good, filled: true))
                Text(guess.reasons.prefix(3).joined(separator: "・")).font(.caption2).foregroundStyle(LL.dim)
            }
            HStack(spacing: LL.Space.s) {
                Button {
                    player.stop()
                    picking = true
                } label: {
                    Label("別の人", systemImage: "person.2").frame(maxWidth: .infinity)
                }
                .buttonStyle(LLPillButtonStyle())
                Button {
                    run { await S29NBook.shared.answerUnknown(card, pipeline: pipeline) }
                } label: {
                    Label("知らない人", systemImage: "nosign").frame(maxWidth: .infinity)
                }
                .buttonStyle(LLPillButtonStyle(tint: LL.dim))
            }
            HStack {
                Button("あとで") {
                    player.stop()
                    S29NBook.shared.postpone(card)
                }
                if card.kind == .group {
                    Spacer()
                    Button("この中に別の人がいる") {
                        run { await S29NBook.shared.answerSplit(card, pipeline: pipeline) }
                    }
                }
            }
            .font(.callout).foregroundStyle(LL.dim)
            Text("「知らない人」は、この声をもう聞きません（設定の奥から戻せます）。まとめた人は、その人の画面から戻せます。")
                .font(.caption2).foregroundStyle(LL.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var labels: String {
        let names = card.members.prefix(4).map { "人物" + $0 }
        let more = card.members.count > 4 ? " ほか \(card.members.count - 4)" : ""
        return names.joined(separator: "・") + more
    }

    @ViewBuilder
    private func quoteRow(_ q: S29NQuote, index: Int) -> some View {
        let key = "s29n-\(card.id)-\(index)"
        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
            if let audio = q.audio, let offset = q.offset {
                Button {
                    Task {
                        var stop: TimeInterval = offset + 8
                        if let e = q.end, e > offset { stop = e + 0.5 }
                        await player.toggle(key, at: offset, until: stop) {
                            await pipeline.archive.playableURL(for: audio)
                        }
                    }
                } label: {
                    Image(systemName: player.playing == key ? "speaker.wave.2.fill"
                          : player.loading == key ? "arrow.down.circle" : "play.circle")
                        .foregroundStyle(LL.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("声 \(index + 1) を聞く")
            } else {
                Image(systemName: "speaker.slash").foregroundStyle(LL.dim)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(S26VVoice.when(q.time)).font(.caption2).monospacedDigit().foregroundStyle(LL.dim)
                Text("「\(q.text)」").font(.callout).foregroundStyle(LL.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run(_ work: @escaping () async -> String) {
        player.stop()
        working = true
        Task {
            let text = await work()
            working = false
            LLHaptic.done.play()
            onDone(text)
        }
    }
}

// MARK: - 「別の人」（今いる人から選ぶ。名前を打つのは最後の手段）

struct S29NPersonPicker: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let card: S29NCard
    var onDone: (String) -> Void
    @State private var typed = ""
    @State private var working = false

    var body: some View {
        let members = Set(card.members)
        let choices = S29NGuess.choices(pipeline.people).filter { !members.contains($0.id) }
        LLList {
            Section {
                if choices.isEmpty {
                    Text("名前のある人がまだいません。下で名前を打ってください。").foregroundStyle(LL.dim)
                }
                ForEach(choices) { p in
                    Button {
                        go { await S29NBook.shared.answer(card, target: p.id, pipeline: pipeline) }
                    } label: {
                        LabeledContent(p.displayName) {
                            Text("\(p.minutes) 分").foregroundStyle(LL.dim)
                        }
                    }
                }
            } header: {
                Text("だれの声ですか")
            }
            Section {
                TextField("名前", text: $typed)
                Button("この名前にする") {
                    go { await S29NBook.shared.answer(card, name: typed, pipeline: pipeline) }
                }
                .disabled(S29NGuess.typedName(typed) == nil)
            } header: {
                Text("名前を打つ（最後の手段）")
            } footer: {
                Text("同じ名前の人がいれば、その人にまとめます。")
            }
        }
        .disabled(working)
        .navigationTitle("別の人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
        }
    }

    private func go(_ work: @escaping () async -> String) {
        working = true
        Task {
            let text = await work()
            working = false
            onDone(text)
        }
    }
}

// MARK: - 声23 今から ◯◯さんと

struct S29NWithNowRow: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(S29NWithNow.key) private var raw = ""
    @State private var picking = false

    var body: some View {
        let entry = S29NWithNow.decode(raw.isEmpty ? nil : raw)
        if S29NWithNow.active(entry, now: .now), let entry {
            HStack {
                Label("今 \(names(entry.ids)) と（\(Self.clock(entry.end)) まで）", systemImage: "person.2.wave.2")
                    .font(.callout)
                Spacer()
                Button("やめる") {
                    raw = ""
                    Tally.add("s29n.withNow.stop")
                }
                .font(.callout)
            }
        } else {
            Button {
                picking = true
            } label: {
                Label("今から ◯◯さんと（\(S29NSettings.withNowHours) 時間）", systemImage: "person.2.wave.2")
            }
            .sheet(isPresented: $picking) {
                NavigationStack { S29NWithNowPicker() }
            }
        }
    }

    private func names(_ ids: [String]) -> String {
        var out: [String] = []
        for id in ids {
            if let p = pipeline.people.first(where: { $0.id == id }) { out.append(p.displayName + "さん") }
        }
        return out.isEmpty ? "選んだ人" : out.joined(separator: "・")
    }

    static func clock(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}

struct S29NWithNowPicker: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    @AppStorage(S29NWithNow.key) private var raw = ""
    @State private var chosen: [String] = []

    var body: some View {
        let people = S29NGuess.choices(pipeline.people).filter { !$0.isSelf }
        LLList {
            Section {
                if people.isEmpty {
                    Text("名前のある人がまだいません。").foregroundStyle(LL.dim)
                }
                ForEach(people) { p in
                    Button {
                        if let i = chosen.firstIndex(of: p.id) { chosen.remove(at: i) } else { chosen.append(p.id) }
                    } label: {
                        HStack {
                            Text(p.displayName).foregroundStyle(LL.text)
                            Spacer()
                            if chosen.contains(p.id) { Image(systemName: "checkmark").foregroundStyle(LL.accent) }
                        }
                    }
                }
            } header: {
                Text("だれと会いますか")
            } footer: {
                Text("押した時間（\(S29NSettings.withNowHours) 時間・仮）の声は、選んだ人を先に考えます。名前は自動では変えません。")
            }
        }
        .navigationTitle("今から会う人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("今から") {
                    if let e = S29NWithNow.make(ids: chosen, now: .now, hours: S29NSettings.withNowHours),
                       let text = S29NWithNow.encode(e) {
                        raw = text
                        Tally.add("s29n.withNow.start")
                    }
                    dismiss()
                }
                .disabled(chosen.isEmpty)
            }
        }
    }
}

// MARK: - 設定の奥: しぼり・もう聞かない人を戻す

extension S29NSettingsView {
    /// "2026-11-27|12|まとめた" → "11/27　人物12: まとめた"
    static func linkedText(_ row: String) -> String {
        let parts = row.split(separator: "|").map(String.init)
        guard parts.count == 3 else { return row }
        let d = parts[0].split(separator: "-")
        let day = d.count == 3 ? "\(Int(d[1]) ?? 0)/\(Int(d[2]) ?? 0)" : parts[0]
        return day + "　人物" + parts[1] + ": " + parts[2]
    }
}

struct S29NSettingsView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(S29NSettings.pileKey) private var pileOn = true
    @AppStorage(S29NSettings.reviewLinkKey) private var linkOn = true
    @AppStorage(S29NSettings.minDaysKey) private var minDays = S29NSettings.minDaysDefault
    @AppStorage(S29NSettings.minSecondsKey) private var minSeconds = S29NSettings.minSecondsDefault
    @AppStorage(S29NSettings.dailyKey) private var daily = S29NSettings.dailyDefault
    @AppStorage(S29NSettings.withNowHoursKey) private var hours = S29NSettings.withNowHoursDefault
    @State private var working = false

    var body: some View {
        let quiet = pipeline.people.filter { $0.quiet == true }
        let linked = (UserDefaults.standard.stringArray(forKey: S29NReviewApply.linkedKey) ?? []).reversed()
        LLForm {
            Section {
                Toggle("名前付けの入口を 1 つの山にする", isOn: $pileOn)
                Stepper("7 日のうち \(S29NSettings.clampDays(minDays)) 日以上", value: $minDays, in: 1...7)
                Stepper("合計 \(S29NSettings.clampSeconds(minSeconds) / 60) 分以上", value: $minSeconds, in: 60...1800, step: 60)
                Stepper("1 日に \(S29NSettings.clampDaily(daily)) 件まで", value: $daily, in: 1...3)
                Stepper("「今から ◯◯さんと」は \(hours) 時間", value: $hours, in: 1...6)
            } header: {
                Text("名前付けの山（数はどれも仮）")
            } footer: {
                Text("よく話す声だけを聞きます。届かない声は「その他の人」として聞きません。数を変えると、次に山を数え直すときから効きます。")
            }
            Section {
                if quiet.isEmpty {
                    Text("ありません").foregroundStyle(LL.dim)
                }
                ForEach(quiet) { p in
                    LabeledContent(p.displayName) {
                        Button("戻す") {
                            working = true
                            Task {
                                await S29NBook.shared.unquiet(p.id, pipeline: pipeline)
                                working = false
                            }
                        }
                    }
                }
            } header: {
                Text("もう聞かない人（\(quiet.count)）")
            } footer: {
                Text("「知らない人」と答えた声です。戻すと、また名前付けの山に出ることがあります。記録の行はそのままです。")
            }
            Section {
                Toggle("確かめ待ちの「この人物N はだれ」の答えを、人の名前に届ける", isOn: $linkOn)
                ForEach(Array(linked.prefix(10)), id: \.self) { row in
                    Text(Self.linkedText(row)).font(.caption).foregroundStyle(LL.dim)
                }
            } footer: {
                Text("答えのときだけ、その声に名前を付けるか、同じ名前の人にまとめます（その人の画面から戻せます）。前は母艦へ送るだけで、端末の人には届いていませんでした。")
            }
        }
        .disabled(working)
        .navigationTitle("名前付けの山")
        .onChange(of: minDays) { _, _ in Task { await S29NBook.shared.refresh(pipeline, force: true) } }
        .onChange(of: daily) { _, _ in Task { await S29NBook.shared.refresh(pipeline, force: true) } }
        .onChange(of: minSeconds) { _, _ in Task { await S29NBook.shared.refresh(pipeline, force: true) } }
    }
}

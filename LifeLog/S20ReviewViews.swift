import AVFoundation
import SwiftUI

// 確かめ待ちを 1 つの列で答える（s20 の 次3・体11〜15。2026-11-21）。
// 母艦の state/review_queue_for_app.json を家の PC から受け、カードを左右に払って ○×。1 枚 3 秒・根拠は 1 タップ。
// 「分からない」「あとで」をいつも置き、14 日で流れることを見せる。答えは家の PC → 母艦の inbox/app_feedback.jsonl（kind "review"）。

struct ReviewDeckView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var offset: CGSize = .zero
    @State private var showEvidence = false
    @State private var toast: String?
    @State private var text = ""
    @State private var lastAnswered: [String] = []

    var body: some View {
        let book = S20Book.shared
        let items = book.openItems()
        let groups = ReviewRules.groups(items)
        let seconds: Int = items.count * ReviewRules.secondsPerCard
        let minutes: Int = max(1, (seconds + 59) / 60)
        LLList {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(items.count)").font(.largeTitle.weight(.bold)).monospacedDigit()
                    Text("枚").foregroundStyle(LL.dim)
                    Spacer()
                    Text("目安 \(minutes) 分")
                        .font(.caption).foregroundStyle(LL.dim)
                }
                Text("右に払うと「はい」、左に払うと「いいえ」。答えないものは \(ReviewRules.lifeDays) 日で流れます。")
                    .font(.footnote).foregroundStyle(LL.dim)
                // 母艦が 1 日の数を決めているとき（2026-11-28。s37 の K37-2）
                if let cap = S37AReview.dailyMax(book.review) {
                    Text("1 日 \(cap) 問まで（母艦の決まり・効きの大きい順）。残りは明日に回します。")
                        .font(.footnote).foregroundStyle(LL.dim)
                }
            } header: {
                LLHeader(title: "確かめ待ち", symbol: "hand.raised")
            }
            if let first = items.first {
                Section {
                    card(first, count: items.count)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                        .listRowBackground(Color.clear)
                    if let toast {
                        Label(toast, systemImage: "checkmark.circle").font(.caption).foregroundStyle(LL.good)
                            .transition(.opacity)
                    }
                }
            } else {
                Section {
                    LLEmpty(title: "確かめ待ちはありません", symbol: "checkmark.circle",
                            detail: "母艦が確かめたいこと（ラーメン・一緒にいた人・名前の候補・場所など）が、ここに 1 つの列で届きます。")
                }
            }
            // 体13 似たものはまとめて答える
            if !groups.isEmpty {
                Section {
                    ForEach(groups, id: \.first?.id) { group in
                        BatchRow(group: group) { value in
                            for item in group { book.answer(item, value) }
                            LLHaptic.done.play()
                            show("\(group.count) 件をまとめて答えました")
                        }
                    }
                } header: {
                    LLHeader(title: "似たものをまとめて", symbol: "square.stack.3d.up")
                }
            }
            // 体14 答えたら何が変わったか（返ってきた数だけ）
            let changes: [String] = (book.review?.done ?? []).compactMap { ReviewRules.changedLine($0) }
            if !changes.isEmpty {
                Section {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(LL.good)
                    }
                } header: {
                    LLHeader(title: "答えで直ったもの", symbol: "sparkles")
                }
            }
        }
        .navigationTitle("確かめる")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("reviewDeck")
        .onAppear { book.cardShownAt = .now }
        .refreshable { await book.refresh(pipeline.homePC, force: true) }
    }

    private func card(_ item: ReviewItem, count: Int) -> some View {
        let days = ReviewRules.daysLeft(item, now: .now)
        return VStack(alignment: .leading, spacing: LL.Space.m) {
            HStack {
                CertaintyBadge(certainty: .waiting, text: ReviewRules.kindLabel(item.kind))
                Spacer()
                if let days {
                    Text(days == 0 ? "今日で流れます" : "あと \(days) 日で流れます")
                        .font(.caption2).foregroundStyle(days <= 2 ? LL.warn : LL.dim)
                }
            }
            Text(item.question).font(.title3.weight(.semibold)).foregroundStyle(LL.text)
                .fixedSize(horizontal: false, vertical: true)
            // 話し手を聞く問いは、発言 3 つ → 声 → 名前のボタンの順で、根拠を閉じずに見せる（2026-11-25。s26 の S26V）
            if S26VVoice.isVoiceAsk(item) {
                S26VVoiceBlock(item: item)
            } else if let clips = item.clips, !clips.isEmpty {
                ClipChooser(clips: clips)
            }
            if !S26VVoice.isVoiceAsk(item), let evidence = item.evidence, !evidence.isEmpty {
                Button {
                    withAnimation(LL.Motion.fade) { showEvidence.toggle() }
                } label: {
                    Label(showEvidence ? "根拠を閉じる" : "根拠を見る（\(evidence.count)）", systemImage: "text.quote")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                if showEvidence {
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.text).font(.callout).foregroundStyle(LL.dim)
                            if let ref = e.ref { Text(ref).font(.caption2).foregroundStyle(LL.dim.opacity(0.8)) }
                        }
                        .certainty(.guess)
                    }
                }
            }
            answerButtons(item)
            HStack {
                Button("分からない") { answer(item, "unsure") }
                    .buttonStyle(LLPillButtonStyle(tint: LL.dim))
                Spacer()
                Button("あとで") {
                    S20Book.shared.postpone(item)
                    LLHaptic.confirm.play()
                    show("あとで（明日また出ます）")
                }
                .buttonStyle(LLPillButtonStyle(tint: LL.dim))
            }
            if count > 1 {
                Text("あと \(count - 1) 枚").font(.caption2).foregroundStyle(LL.dim).frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(LL.Space.l)
        .background(LL.surface, in: RoundedRectangle(cornerRadius: LL.Radius.big))
        .overlay(RoundedRectangle(cornerRadius: LL.Radius.big).strokeBorder(swipeColor, lineWidth: LL.Stroke.bold))
        .llShadow()
        .offset(x: offset.width)
        .rotationEffect(.degrees(Double(offset.width) / 30))
        .gesture(swipe(item))
        .animation(LL.Motion.state, value: offset)
        .id(item.id)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "はい") { answer(item, "yes") }
        .accessibilityAction(named: "いいえ") { answer(item, "no") }
    }

    private var swipeColor: Color {
        if offset.width > 40 { return LL.good }
        if offset.width < -40 { return LL.danger }
        return LL.accent
    }

    @ViewBuilder
    private func answerButtons(_ item: ReviewItem) -> some View {
        // 知らない answer の形でも choices があれば選ぶ形で出す（kind number など。2026-11-22。s22 の 確19。S22Rules）
        switch S22Rules.answerStyle(answer: item.answer, choices: item.choices) {
        case "pick":
            FlowLayout(spacing: LL.Space.s) {
                ForEach(item.choices ?? [], id: \.self) { choice in
                    Button(choice) { answer(item, choice) }.buttonStyle(LLPillButtonStyle())
                }
            }
        case "text":
            HStack {
                TextField(S23ReviewRules.placeholder(kind: item.kind), text: $text).textFieldStyle(.roundedBorder)
                Button("送る") {
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    answer(item, value)
                    text = ""
                }
                .buttonStyle(LLPillButtonStyle(filled: true))
            }
            // 聞き取りの答え合わせ（gold_noisy）は、合っていれば「そのまま」（2026-11-23。s23。家の PC #104 に合わせる）
            if S23ReviewRules.keepAsIs(kind: item.kind) {
                Button("そのまま（合っている）") { answer(item, S23ReviewRules.keepValue) }
                    .buttonStyle(LLPillButtonStyle(tint: LL.good))
            }
        default:
            HStack(spacing: LL.Space.m) {
                Button {
                    answer(item, "no")
                } label: {
                    Label("いいえ", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(LLPillButtonStyle(tint: LL.danger))
                Button {
                    answer(item, "yes")
                } label: {
                    Label("はい", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(LLPillButtonStyle(tint: LL.good, filled: true))
            }
        }
    }

    private func swipe(_ item: ReviewItem) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { offset = $0.translation }
            .onEnded { value in
                if !S22Rules.isYesNo(answer: item.answer, choices: item.choices) {
                    offset = .zero
                    return
                }
                if value.translation.width > 110 {
                    answer(item, "yes")
                } else if value.translation.width < -110 {
                    answer(item, "no")
                }
                offset = .zero
            }
    }

    private func answer(_ item: ReviewItem, _ value: String) {
        S20Book.shared.answer(item, value)
        LLHaptic.done.play()
        showEvidence = false
        let word = value == "yes" ? "はい" : value == "no" ? "いいえ" : value == "unsure" ? "分からない" : value
        show("「\(word)」を送る列に入れました")
    }

    private func show(_ text: String) {
        withAnimation(LL.Motion.fade) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(LL.Motion.fade) { if toast == text { toast = nil } }
        }
    }
}

/// 体13: 同じ問いをまとめて
private struct BatchRow: View {
    let group: [ReviewItem]
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.s) {
            HStack {
                CertaintyBadge(certainty: .waiting, text: ReviewRules.kindLabel(group[0].kind))
                Text("\(group.count) 件").font(.caption).foregroundStyle(LL.dim).monospacedDigit()
            }
            Text(group[0].question).font(.callout).lineLimit(2)
            HStack {
                Button("全部いいえ") { onAnswer("no") }.buttonStyle(LLPillButtonStyle(tint: LL.danger))
                Button("全部はい") { onAnswer("yes") }.buttonStyle(LLPillButtonStyle(tint: LL.good, filled: true))
            }
        }
        .padding(.vertical, LL.Space.xs)
    }
}

/// 体12: 声は「聞いて選ぶ」（5 秒の音 2 つ。家の PC から取ってくる）
struct ClipChooser: View {
    @Environment(Pipeline.self) private var pipeline
    let clips: [ReviewItem.Clip]
    @State private var player: AVAudioPlayer?
    @State private var playing: String?
    @State private var problem: String?

    /// ほかのファイル（S23Screens の確かめ待ちの 1 問）からも使う（2026-11-23。s23）
    init(clips: [ReviewItem.Clip]) { self.clips = clips }

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            HStack(spacing: LL.Space.s) {
                ForEach(clips.prefix(2), id: \.path) { clip in
                    Button {
                        Task { await play(clip) }
                    } label: {
                        Label(clip.label, systemImage: playing == clip.path ? "speaker.wave.2.fill" : "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LLPillButtonStyle())
                }
            }
            if let problem { Text(problem).font(.caption2).foregroundStyle(LL.warn) }
        }
    }

    private func play(_ clip: ReviewItem.Clip) async {
        problem = nil
        do {
            // 「voice/clip?audio=…&start=…」の形なら、道と問いに分ける
            let parts = clip.path.split(separator: "?", maxSplits: 1).map(String.init)
            let query: [URLQueryItem] = parts.count > 1 ? (URLComponents(string: "?" + parts[1])?.queryItems ?? []) : []
            let data = try await pipeline.homePC.getJSONData(parts.first ?? clip.path, query: query, timeout: 15)
            let p = try AVAudioPlayer(data: data)
            player = p
            playing = clip.path
            p.play()
            try? await Task.sleep(for: .seconds(min(6, p.duration + 0.3)))
            if playing == clip.path { playing = nil }
        } catch {
            problem = "音を取ってこられませんでした（家の PC につながるときに）"
        }
    }
}

/// 「直す」の上に置く入口
struct ReviewDeckEntrySection: View {
    var body: some View {
        let count = S20Book.shared.waitingCount
        Section {
            NavigationLink {
                ReviewDeckView()
            } label: {
                HStack {
                    Label("確かめる（○×）", systemImage: "hand.raised")
                    Spacer()
                    // 溜まった数は出さない（2026-11-24。s24 の 減4）
                    Text(count > 0 ? "あります" : "なし").foregroundStyle(count > 0 ? LL.accent : LL.dim)
                }
            }
        } footer: {
            Text("ラーメン・一緒にいた人・名前の候補・場所などを 1 つの列で。1 枚 3 秒、\(ReviewRules.lifeDays) 日で流れます。")
        }
    }
}

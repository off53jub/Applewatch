import SwiftUI

// 「直す」タブ（2026-11-12。前の「確認箱」）。記録を正しくするために本人が答えるものを、大事な順に1か所に並べる。
// 上は「今たまっているもの」（無くなれば消える）、下は「いつでも開けるもの」。タブの数字は上の合計（タスクの候補は「タスク」の数字に入るので入れない）。

extension Pipeline {
    /// 「直す」にたまっているものの数（大事な順）。reviewCount は声の見直しの数（記録をひととおり見るので、呼ぶ側が数えておく）
    func fixParts(reviewCount: Int) -> [(name: String, count: Int)] {
        let week = AnswerKey.weekKey(.now)
        let samples = answerKey.samples(of: week)
        let answers = samples.isEmpty ? AnswerKey.perWeek : samples.filter { !$0.isAnswered }.count
        return [
            ("AI からの質問", asks.open.count),
            ("名前を付ける候補の声", newVoices.open.count),
            ("職場の自分の声", selfCandidateCount),
            ("見直したい声", reviewCount),
            ("名前を付けてほしい声", namelessVoiceCount),
            ("割れやすい言葉", splitWordCandidates().count),
            ("聞き間違いかも", misheardCount),
            ("今週の答え合わせ", answers),
        ]
    }

    /// 職場の自分の声の確認（家の PC が対応しているときだけ。AppFeeds.swift）
    var selfCandidateCount: Int {
        homePC.features.contains("selfcand") ? appFeeds.visibleCandidates.count : 0
    }

    /// 30秒以上話したのに名前の無い声（テレビ・動画・大勢の場らしい声は除く）
    var namelessVoiceCount: Int {
        guard speakerLabelsOn else { return 0 }
        let skip = broadcastLike().union(crowdLike())
        return people.filter { !$0.isNamed && !$0.isSelf && $0.hidden != true && $0.seconds >= 30 && !skip.contains($0.id) }.count
    }
}

/// 「直す」タブ
struct FixTab: View {
    var body: some View {
        NavigationStack {
            FixView()
                .settingsGear()
        }
    }
}

struct FixView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var reviewCount = 0

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let day = Self.dayFormatter.string(from: .now)
        let parts = pipeline.fixParts(reviewCount: reviewCount)
        let count = { (name: String) in parts.first { $0.name == name }?.count ?? 0 }
        let total = parts.reduce(0) { $0 + $1.count }
        let todayIDs = Set(pipeline.conversations(on: day).flatMap(\.lines).compactMap(\.speakerID))
        let unnamedToday = pipeline.people.filter { !$0.isNamed && !$0.isSelf && todayIDs.contains($0.id) }.count
        List {
            if total == 0 {
                Section {
                    ContentUnavailableView("今は直すものはありません", systemImage: "checkmark.circle",
                                           description: Text("AI からの質問・名前を付ける声・聞き間違いなどがたまると、ここに大事な順に並びます。下の「いつでも」からは、いつでも開けます。"))
                }
            } else {
                Section {
                    Text("1日に上から5つまでで十分です（5分ほど）。残りは明日に回して大丈夫です。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            // タスクの候補は「タスク」タブで片づける（ここからは移るだけ）
            if !pipeline.tasks.candidates.isEmpty {
                Section {
                    Button {
                        pipeline.tab = .tasks
                    } label: {
                        LabeledContent {
                            Text("\(pipeline.tasks.candidates.count) 件")
                        } label: {
                            Label("タスクの候補は「タスク」で", systemImage: "checklist")
                        }
                    }
                }
            }
            if count("AI からの質問") > 0 {
                Section("AI からの質問（\(count("AI からの質問"))）") {
                    NavigationLink("答える") { QuestionsView() }
                }
            }
            NewVoicesSection()
            if count("職場の自分の声") > 0 {
                Section("職場の自分の声の確認（\(count("職場の自分の声"))）") {
                    NavigationLink("聞いて答える") { SelfCandidatesView() }
                }
            }
            if reviewCount > 0 || unnamedToday > 0 {
                Section("見直したい声（\(reviewCount)）") {
                    if reviewCount > 0 { NavigationLink("声を聞いて直す") { VoiceReviewView() } }
                    if unnamedToday > 0 { NavigationLink("今日の人物Nを整理（\(unnamedToday) 人）") { UnnamedVoicesView(day: day) } }
                }
            }
            if count("名前を付けてほしい声") > 0 {
                Section("名前を付けてほしい声（\(count("名前を付けてほしい声")) 人）") {
                    NavigationLink("話した相手を開く") { PeopleView() }
                }
            }
            SplitWordsSection()
            if count("聞き間違いかも") > 0 {
                Section("聞き間違いかも（\(count("聞き間違いかも"))）") {
                    NavigationLink("直す・そのまま") { MisheardView() }
                }
            }
            if count("今週の答え合わせ") > 0 {
                Section("今週の答え合わせ（あと \(count("今週の答え合わせ")) 問）") {
                    NavigationLink("答える（5分ほど）") { AnswerKeyView() }
                }
            }
            Section {
                NavigationLink {
                    ReviewNudgeView()
                } label: {
                    Label("今日の聞いて直す・学び直しの材料", systemImage: "ear")
                }
                NavigationLink {
                    QuestionsView()
                } label: {
                    Label("AI からの質問・わかったこと帳", systemImage: "lightbulb")
                }
                NavigationLink {
                    AnswerKeyView()
                } label: {
                    Label("答え合わせ（週5分）・聞き取りの数字", systemImage: "checkmark.seal")
                }
                NavigationLink {
                    VocabularyView()
                } label: {
                    let v = pipeline.vocabulary
                    LabeledContent {
                        Text("\(v.words(in: .work).count + v.words(in: .other).count + v.words(in: .always).count) 語")
                    } label: {
                        Label("聞き取ってほしい言葉", systemImage: "character.book.closed")
                    }
                }
                if pipeline.speakerLabelsOn {
                    NavigationLink {
                        VoiceEnrollView()
                    } label: {
                        LabeledContent {
                            Text(pipeline.hasSelfVoice ? "登録済み" : "未登録")
                        } label: {
                            Label("自分の声", systemImage: "person.crop.circle")
                        }
                    }
                }
            } header: {
                Text("いつでも")
            }
        }
        .navigationTitle("直す")
        .countsOpen("confirmBox")
        .task(id: pipeline.people.flatMap(\.samples)) { reviewCount = pipeline.voiceReview().count }
    }
}

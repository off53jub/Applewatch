import SwiftUI

/// 「ふり返り」（2026-11-12）。前は「今日」の途中・「記録」の上・「タスク」の奥に分かれていた、
/// 自分をふり返る画面（いいこと帳・話し方・仕事の週・案件・タスクの数・わかったこと）を1か所にまとめた。
/// 2026-11-27（s30）から下のタブではなく、「記録」の上の切り替えの「ふり返り」（ContentView の RecordsView。NavigationStack と歯車は記録のもの）
struct LookBackPage: View {
    @Environment(Pipeline.self) private var pipeline
    /// 引き算の版（時間の家計簿・緊張した場面・話題の糸は「ほかのふり返り」へ。初めはオン。2026-11-24。s25 の 大1）
    @AppStorage(S25USimple.key) private var simple = true

    var body: some View {
        let book = pipeline.good
        let hasGood = pipeline.homePC.features.contains("good") || book.data != nil
        let hasWork = !pipeline.workDigests.entries.isEmpty
        LLList {
            // 数を小さなグラフで・物語・休日のページ・検品表（2026-11-21。s20 の 体3・体23〜26。S20LookBackViews.swift。面談の 1 枚は s30 で外した）
            S20LookBackSection()
            S26DLookBackLinks()  // 同じ形の線・月の 1 枚（2026-11-25。s26 の 絵4・絵5。S26DTrends.swift）
            S33ALifeSection()  // 暮らし（車・年のまとめ・欲しい物・約束の棚・答え合わせ。2026-11-27。s33 の K33-1。S33AViews.swift）
            // 今週のふり返り・見立ての台帳・使われ方の数（2026-11-13。施策 2・3・1。MothershipFeeds.swift。写しがあるときだけ）
            WeeklyLookBackSection()
            if simple {
                S25UMoreLookBackLink()
            } else {
                TimeLedgerSection()  // 時間の家計簿（2026-11-15。強化案 60。DraftActions.swift。写しがあるときだけ）
                // 緊張した場面（心拍が上がった時刻と会話。2026-11-15。強化案 52。CoachTension.swift。写しがあるときだけ）
                TensionLookBackSection()
                // 話題の糸（2026-11-15。強化案 54。PagesFeeds.swift。写しがあるときだけ）
                ThreadsLookBackSection()
            }
            // 入口は 5 つまで・使わない画面は「ほか」に（2026-11-24。s24 の 形5・減12。S24Views.swift。消さない・戻せる）
            let entries = S24Entry.split(list: "lookBack", available: available(hasGood: hasGood, hasWork: hasWork))
            let shown: Set<String> = entries.shown
            if !hasGood || shown.contains("goodThings") || shown.contains("speaking") {
                Section {
                    if hasGood {
                        if shown.contains("goodThings") {
                            NavigationLink {
                                GoodThingsView()
                            } label: {
                                LabeledContent {
                                    if let w = book.thisWeek { Text("今週 お礼 \(w.thanks)・ほめ言葉 \(w.praise)") }
                                } label: {
                                    Label("いいこと帳", systemImage: "hand.thumbsup")
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("いいこと帳", systemImage: "hand.thumbsup")
                            Text("家の PC の LifeLog PC がいいこと帳を作れるようになると、ここから開けます（お礼・ほめ言葉・済ませたこと）。")
                                .font(.caption).foregroundStyle(LL.dim)
                        }
                    }
                    if shown.contains("speaking") {
                        NavigationLink {
                            SpeakingView()
                        } label: {
                            Label("話し方の振り返り", systemImage: "person.wave.2")
                        }
                    }
                } header: {
                    Text("自分")
                }
            }

            // 同じ日の朝のまとめを2つの作り手で比べる（2026-11-13。施策 5。両方そろった日があるときだけ）
            if shown.contains("briefCompare") {
                Section("朝のまとめ") {
                    BriefCompareLink()
                }
            }

            if !hasWork || shown.contains("workWeek") || shown.contains("workThreads") || shown.contains("taskScore") {
                Section {
                    if hasWork {
                        if shown.contains("workWeek") {
                            NavigationLink {
                                WorkWeekView().countsOpen("workWeek")
                            } label: {
                                Label("週のまとめ（週報の下書き）", systemImage: "calendar")
                            }
                        }
                        if shown.contains("workThreads") {
                            NavigationLink {
                                WorkThreadsView().countsOpen("workThreads")
                            } label: {
                                Label("案件ごと", systemImage: "point.3.connected.trianglepath.dotted")
                            }
                        }
                    } else {
                        Text("「仕事」タブで仕事のまとめを取り込むと、週のまとめと案件ごとの流れが読めます。")
                            .font(.callout).foregroundStyle(LL.dim)
                    }
                    if shown.contains("taskScore") {
                        NavigationLink {
                            TaskScoreView().countsOpen("taskScore")
                        } label: {
                            Label("タスクを数で見る", systemImage: "chart.bar")
                        }
                    }
                } header: {
                    Text("仕事とタスク")
                }
            }

            if shown.contains("facts") {
                Section {
                    NavigationLink {
                        FactsView().countsOpen("facts")
                    } label: {
                        LabeledContent {
                            Text("\(pipeline.asks.facts.count) 件")
                        } label: {
                            Label("わかったこと帳", systemImage: "lightbulb")
                        }
                    }
                } header: {
                    Text("覚えたこと")
                } footer: {
                    Text("AI からの質問に答えたことが、ここにたまります。")
                }
            }
            S24OtherSection(other: entries.other)
        }
        .navigationTitle("ふり返り")
        .countsOpen("lookBack")
        .s26uHelp("lookBack")
    }

    /// いま開ける入口（形5 の数に入れるもの）
    private func available(hasGood: Bool, hasWork: Bool) -> Set<String> {
        var keys: Set<String> = ["speaking", "taskScore", "facts"]
        if hasGood { keys.insert("goodThings") }
        if !pipeline.mothershipFeeds.compare.isEmpty { keys.insert("briefCompare") }
        if hasWork { keys.formUnion(["workWeek", "workThreads"]) }
        return keys
    }
}

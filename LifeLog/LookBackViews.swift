import SwiftUI

/// 「ふり返り」タブ（2026-11-12）。前は「今日」の途中・「記録」の上・「タスク」の奥に分かれていた、
/// 自分をふり返る画面（いいこと帳・話し方・仕事の週・案件・タスクの数・わかったこと）を1か所にまとめた。
struct LookBackTab: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = pipeline.good
        let hasGood = pipeline.homePC.features.contains("good") || book.data != nil
        let hasWork = !pipeline.workDigests.entries.isEmpty
        NavigationStack {
            List {
                Section {
                    if hasGood {
                        NavigationLink {
                            GoodThingsView()
                        } label: {
                            LabeledContent {
                                if let w = book.thisWeek { Text("今週 お礼 \(w.thanks)・ほめ言葉 \(w.praise)") }
                            } label: {
                                Label("いいこと帳", systemImage: "hand.thumbsup")
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("いいこと帳", systemImage: "hand.thumbsup")
                            Text("家の PC の LifeLog PC がいいこと帳を作れるようになると、ここから開けます（お礼・ほめ言葉・済ませたこと）。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        SpeakingView()
                    } label: {
                        Label("話し方の振り返り", systemImage: "person.wave.2")
                    }
                } header: {
                    Text("自分")
                }

                Section {
                    if hasWork {
                        NavigationLink {
                            WorkWeekView()
                        } label: {
                            Label("週のまとめ（週報の下書き）", systemImage: "calendar")
                        }
                        NavigationLink {
                            WorkThreadsView()
                        } label: {
                            Label("案件ごと", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    } else {
                        Text("「タスク」の上の「仕事のまとめ」に取り込むと、週のまとめと案件ごとの流れが読めます。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        TaskScoreView()
                    } label: {
                        Label("タスクを数で見る", systemImage: "chart.bar")
                    }
                } header: {
                    Text("仕事とタスク")
                }

                Section {
                    NavigationLink {
                        FactsView()
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
            .navigationTitle("ふり返り")
            .countsOpen("lookBack")
            .settingsGear()
        }
    }
}

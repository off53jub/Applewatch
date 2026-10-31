import SwiftUI

struct ContentView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        @Bindable var settings = pipeline.settings
        NavigationStack {
            List {
                Section("Google ドライブ") {
                    if let email = pipeline.email {
                        LabeledContent("ログイン中", value: email)
                        Button("ログアウト", role: .destructive) { pipeline.signOut() }
                    } else {
                        Button("Google でログイン") { Task { await pipeline.signIn() } }
                    }
                }

                Section {
                    Text(pipeline.watchStatus)
                    Toggle("待機モード", isOn: Binding(
                        get: { pipeline.standbyOn },
                        set: { pipeline.standbyOn = $0 }))
                    Toggle("録音が止まったら知らせる", isOn: Binding(
                        get: { pipeline.stopAlertsOn },
                        set: { pipeline.stopAlertsOn = $0 }))
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text((pipeline.standbyOn
                         ? "無音を流してアプリを起こしておき、時計の録音を5分ごとにすぐ文字起こしします。電池を少し多く使います。アプリを上にスワイプして終わらせたときや iPhone を再起動したときは、一度開くと戻ります。"
                         : "時計の録音は、アプリを開いたときや充電中にまとめて文字起こしします。")
                         + "\n\n時計で録音中は「★ 印」ボタン（またはダブルタップ）で、大事なところの前後1分に印を付けられます。")
                }

                Section {
                    Toggle("高精度で文字起こし", isOn: $settings.useCloud)
                        .disabled(!settings.hasAPIKey)
                    Toggle("誤変換を言語モデルで直す", isOn: Binding(
                        get: { pipeline.correctionOn },
                        set: { pipeline.correctionOn = $0 }))
                        .disabled(settings.groqKey == nil)
                    NavigationLink("サービスと API キーの設定") {
                        TranscriptionSettingsView(settings: settings)
                    }
                } header: {
                    Text("文字起こし")
                } footer: {
                    if !settings.hasAPIKey {
                        Text("API キーを登録すると、クラウドの高精度モデルで文字起こしできます（Groq なら1日16時間まで無料）。オフのときは iPhone の中だけで無料で文字起こしします。")
                    } else if settings.useCloud && !settings.isUnderLimit {
                        Text("今月の上限に達したので、端末内の文字起こしに戻っています。")
                    } else if settings.provider.dollarsPerMinute > 0 {
                        Text("\(settings.provider.name)・今月 \(settings.usedMinutesThisMonth) 分 / 上限 \(settings.monthlyLimitMinutes) 分")
                    } else {
                        Text(settings.provider.name)
                    }
                }

                Section {
                    Toggle("話している人を聞き分ける", isOn: Binding(
                        get: { pipeline.speakerLabelsOn },
                        set: { pipeline.speakerLabelsOn = $0 }))
                    if pipeline.speakerLabelsOn {
                        NavigationLink {
                            VoiceEnrollView()
                        } label: {
                            LabeledContent("自分の声", value: pipeline.hasSelfVoice ? "登録済み" : "未登録")
                        }
                        NavigationLink {
                            PeopleView()
                        } label: {
                            let others = pipeline.people.filter { !$0.isSelf }
                            let waiting = others.filter { !$0.isNamed && $0.seconds >= 30 }.count
                            LabeledContent("話した相手",
                                           value: waiting > 0 ? "\(others.count) 人（名前待ち \(waiting)）" : "\(others.count) 人")
                        }
                    }
                } header: {
                    Text("話者")
                } footer: {
                    Text("iPhone の中だけで声の特徴を比べ、文字起こしの行に「[自分]」「[人物1]」などを付けます（無料）。違っていたら「これまでの記録」で行を長押しして直すと、その声を覚えて次から正確になります。場所の一覧で職場を決めておくと、職場の人と職場以外の人を分けて照らし合わせます。名前を付けた人は、ドライブの「LifeLog」フォルダに「人物ノート - 名前」ができます。")
                }

                Section {
                    Toggle("会話ごとの見出しと1日のまとめ", isOn: Binding(
                        get: { pipeline.summariesOn },
                        set: { pipeline.summariesOn = $0 }))
                        .disabled(settings.groqKey == nil)
                    Toggle("場所を記録する", isOn: Binding(
                        get: { pipeline.places.isOn },
                        set: { pipeline.places.isOn = $0 }))
                    if pipeline.places.isOn {
                        NavigationLink {
                            PlacesView()
                        } label: {
                            LabeledContent("登録した場所", value: "\(pipeline.places.places.count) か所")
                        }
                    }
                } header: {
                    Text("会話のまとめ")
                } footer: {
                    if settings.groqKey == nil {
                        Text("話が3分途切れるごとに、ドキュメントに「時刻・場所・相手」の見出しを付けます。Groq の API キーを登録すると、見出しに内容の要約が付き、翌日には前の日の先頭に「1日のまとめ」が入ります（無料）。")
                    } else {
                        Text("話が3分途切れるごとに、ドキュメントに「時刻・場所・相手・内容」の見出しと要点を付けます。日が変わると、前の日の先頭に「1日のまとめ」が入ります。Groq の無料枠を使います。")
                    }
                }

                Section {
                    Button {
                        Task { await pipeline.toggleRecording() }
                    } label: {
                        Label(pipeline.isRecording ? "録音を止める" : "録音を始める",
                              systemImage: pipeline.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                    }
                    .tint(pipeline.isRecording ? .red : .accentColor)
                    Button {
                        pipeline.addMark()
                    } label: {
                        Label("今のところに印を付ける", systemImage: "star")
                    }
                    if let mark = pipeline.lastMark {
                        Text("\(mark.formatted(date: .omitted, time: .shortened)) に印を付けました（前後1分の行に★）")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("文字起こし待ち", value: "\(pipeline.pendingCount) 件")
                    if !pipeline.lastEngine.isEmpty {
                        LabeledContent("直近の文字起こし", value: pipeline.lastEngine)
                    }
                    if !pipeline.message.isEmpty {
                        Text(pipeline.message).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("5分ごとに区切って文字起こしし、ドライブの「LifeLog」フォルダの日付のドキュメントに追記します。")
                }

                Section {
                    NavigationLink("これまでの記録") { HistoryView() }
                    NavigationLink("記録を探す") { SearchView() }
                    NavigationLink("記録に質問する") { AskView() }
                    Toggle("音声をドライブにも保存", isOn: Binding(
                        get: { pipeline.audioBackupOn },
                        set: { pipeline.audioBackupOn = $0 }))
                    if pipeline.audioBackupOn && pipeline.backupPending > 0 {
                        LabeledContent("ドライブに上げる前", value: "\(pipeline.backupPending) 件")
                    }
                } footer: {
                    Text(pipeline.audioBackupOn
                         ? "文字起こしを日ごと・会話ごとに見られ、行を押すとその場面の音声が流れます。音声は Wi-Fi のときにドライブの「LifeLog/音声」に上げ、古い分はドライブから取ってきて流します。"
                         : "文字起こしを日ごと・会話ごとに見られます。直近1日ぶんは、行を押すとその場面の音声が流れます。")
                }

                if !pipeline.lastLines.isEmpty {
                    Section("最近の発言") {
                        ForEach(Array(pipeline.lastLines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                    }
                }
            }
            .navigationTitle("LifeLog")
        }
    }
}

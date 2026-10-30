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

                Section("Apple Watch") {
                    Text(pipeline.watchStatus)
                }

                Section {
                    Toggle("高精度で文字起こし", isOn: $settings.useCloud)
                        .disabled(!settings.hasAPIKey)
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
                    Button {
                        Task { await pipeline.toggleRecording() }
                    } label: {
                        Label(pipeline.isRecording ? "録音を止める" : "録音を始める",
                              systemImage: pipeline.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                    }
                    .tint(pipeline.isRecording ? .red : .accentColor)
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

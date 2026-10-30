import SwiftUI

struct ContentView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
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
                    Button {
                        Task { await pipeline.toggleRecording() }
                    } label: {
                        Label(pipeline.isRecording ? "録音を止める" : "録音を始める",
                              systemImage: pipeline.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                    }
                    .tint(pipeline.isRecording ? .red : .accentColor)
                    LabeledContent("文字起こし待ち", value: "\(pipeline.pendingCount) 件")
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

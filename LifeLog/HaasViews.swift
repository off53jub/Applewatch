import SwiftUI

/// iPhone 内の Haas-ja：モデルのダウンロード、オン・オフ、直近の音声で試す。
struct HaasView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        let haas = pipeline.haas
        Form {
            Section {
                switch haas.state {
                case .notDownloaded:
                    Button("モデルをダウンロード（約620MB）") { Task { await haas.download() } }
                case .downloading(let progress):
                    ProgressView(value: progress) { Text("ダウンロードしています… \(Int(progress * 100))%") }
                case .preparing:
                    HStack {
                        ProgressView()
                        Text("この iPhone 用に準備しています（数十秒〜数分）")
                    }
                case .ready:
                    Toggle("Haas-ja で文字起こし", isOn: Binding(get: { haas.enabled }, set: { haas.enabled = $0 }))
                case .failed(let reason):
                    Text("うまくいきませんでした: \(reason)").foregroundStyle(.secondary)
                    Button("もう一度ダウンロード") { Task { await haas.download() } }
                }
            } footer: {
                Text("Third Intelligence の日本語の音声認識 Haas-ja-v1.0 を、iPhone の Neural Engine で動かします（無料・通信なし）。Whisper と違い、雑音や外国語の動画にもっともらしい文を作る癖がほとんどありません。オンのあいだは、クラウドの高精度より先にこちらを使います。動かせなかった区切りは、いつもの方法で文字にします。")
            }

            if haas.state == .ready {
                Section {
                    Button(testing ? "試しています…" : "直近の音声で試す") {
                        testing = true
                        Task {
                            testResult = await haas.testRecent()
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if !testResult.isEmpty {
                        Text(testResult).font(.callout).textSelection(.enabled)
                    }
                } footer: {
                    Text("いちばん新しい区切り（最長5分）を文字にして、かかった時間を出します。")
                }

                Section {
                    Button("モデルを消す", role: .destructive) { Task { await haas.remove() } }
                }
            }
        }
        .navigationTitle("Haas-ja（iPhone 内）")
    }
}

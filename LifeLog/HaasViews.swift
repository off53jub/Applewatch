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
                    Text("いちばん新しい区切り（最長2〜5分）を文字にして、かかった時間を出します。")
                }

                Section {
                    Button("モデルを消す", role: .destructive) { Task { await haas.remove() } }
                }
            }
        }
        .navigationTitle("Haas-ja（iPhone 内）")
    }
}

/// 家の PC（LifeLog PC）：宛先と合言葉、モバイル通信、多数決、つながるか試す。
struct HomePCView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var key = ""
    @State private var result = ""
    @State private var working = false

    var body: some View {
        @Bindable var pc = pipeline.homePC
        Form {
            Section {
                Toggle("家の PC で文字起こし", isOn: $pc.enabled)
                TextField("宛先（例: my-pc.tail1234.ts.net:47615）", text: $pc.address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(pc.hasKey ? "合言葉（入力済み）" : "合言葉", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { saveKey() }
                if !key.isEmpty {
                    Button("合言葉を保存", action: saveKey)
                }
                Toggle("モバイル通信でも送る", isOn: $pc.useCellular)
            } footer: {
                Text("PC で LifeLogPC.exe を起動すると、宛先（〜.ts.net の名前）と合言葉が表示されます。Tailscale の名前なので、外にいるときもモバイル通信で届きます。送るのは声のあった区切りだけで、1つ約1.2MB です。PC が切れているときは、iPhone 内の Haas-ja かいつもの方法で文字にします。")
            }

            // 家の Wi-Fi にいるとき、時計から PC に直接送る（2026-11-07。WatchDirect.swift・LifeLogWatch/WatchPC.swift）
            Section {
                Toggle("時計から家の PC に直接送る", isOn: $pc.watchDirect)
                // いまの道（PC の外の道があるか。2026-11-07。WatchDirect.swift）
                if let route = pc.watchRouteText {
                    Text(route).font(.caption).foregroundStyle(.secondary)
                }
                TextField("家の中の住所（例: 192.168.1.20）", text: $pc.homeAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let problem = pc.homeAddressProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("時計から直接")
            } footer: {
                Text("時計で録った区切りを iPhone を待たずに家の PC にも送り、早く文字にしてもらいます（iPhone にも今までどおり送ります。PC は同じ区切りを二重には文字にしません）。PC で Tailscale の Funnel（外の道）をオンにしていれば、家の外でも送れます（宛先と時計用の合言葉は、iPhone が PC に聞いて時計に渡します）。外の道が無いときは家の Wi-Fi にいるときだけ送ります。時計には Tailscale が無いので、上の宛先とは別に、PC の家の中の住所を入れます（PC で LifeLogPC.exe を起動したときの画面の「時計から直接送るとき…」の行に出る 192.168.… の番号）。合言葉は時計の中の鍵の保管場所（キーチェーン）に置きます。時計の電池は、送る量が増える分だけ少し早く減ります。時計が低電力モードのときと、電池が20%より少ないときは送りません。")
            }

            Section {
                Toggle("食い違った行はクラウドにも聞く", isOn: $pc.cloudVote)
            } header: {
                Text("多数決")
            } footer: {
                Text("新しい LifeLog PC は、Haas-ja・ReazonSpeech・Whisper large-v3 の3つで声の区間ごとに文字にし、読みがいちばん合う文を選びます。3つが食い違った行は、オンにすると「高精度で文字起こし」のクラウド（Groq など）にも聞いてもう1票にします（その区切りの分だけ無料枠を使います）。それでも食い違う行は、ほかのモデルの文を候補にして言語モデルに見比べてもらい、記録では「？」付きになります。外にいて PC に届かなかった区切りは、夜の聞き直しで PC の3つのモデルで書き直します。")
            }

            // 実機の様子・見えない通知・PC で記録を直す（PC の版 7 から。2026-11-07。PCDiag.swift）
            PCLinkSection()

            Section {
                Button(working ? "試しています…" : "つながるか試す") {
                    run { await pipeline.homePC.testConnection() }
                }
                Button("直近の音声で試す") {
                    run { await pipeline.homePC.testRecent() }
                }
                if !result.isEmpty {
                    Text(result).font(.callout).textSelection(.enabled)
                }
                if !pc.lastResult.isEmpty {
                    Text(pc.lastResult).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(working)
        }
        .navigationTitle("家の PC")
    }

    private func saveKey() {
        pipeline.homePC.setKey(key)
        key = ""
    }

    private func run(_ action: @escaping () async -> String) {
        if !key.isEmpty { saveKey() }
        working = true
        Task {
            result = await action()
            working = false
        }
    }
}

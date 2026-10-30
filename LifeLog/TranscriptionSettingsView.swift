import SwiftUI

/// 高精度（クラウド）文字起こしのサービス・API キー・聞き取ってほしい言葉・月の上限を決める画面。
struct TranscriptionSettingsView: View {
    @Bindable var settings: TranscriptionSettings
    @State private var keyInput = ""

    var body: some View {
        Form {
            Section {
                Picker("サービス", selection: $settings.provider) {
                    ForEach(CloudTranscriber.Provider.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("使うサービス")
            } footer: {
                switch settings.provider {
                case .groq:
                    Text("Whisper large-v3 で文字起こしします。無料枠（1日8時間分）を使い切ったら次点の large-v3-turbo（こちらも8時間分）に、それも使い切ったら端末内の文字起こしに切り替わります。")
                case .openai:
                    Text("gpt-transcribe で文字起こしします。ChatGPT の有料プランとは別に、使った分だけ請求されます。")
                }
            }

            Section {
                if settings.hasAPIKey {
                    LabeledContent("API キー", value: "登録済み")
                    Button("API キーを消す", role: .destructive) { settings.setAPIKey("") }
                } else {
                    SecureField(settings.provider.keyHint, text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存") {
                        settings.setAPIKey(keyInput)
                        keyInput = ""
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("キーを作るページを開く", destination: settings.provider.consoleURL)
                }
            } header: {
                Text("API キー")
            } footer: {
                Text("キーはこの iPhone のキーチェーンにだけ保存します。")
            }

            Section {
                TextField("1行に1語（例: 人名、社名、専門用語）", text: $settings.keywordText, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("聞き取ってほしい言葉")
            } footer: {
                Text("よく出てくる名前や言葉を書いておくと、その表記で書き起こされやすくなります。")
            }

            if settings.provider.dollarsPerMinute > 0 {
                Section {
                    Stepper(value: $settings.monthlyLimitMinutes, in: 500...20_000, step: 500) {
                        LabeledContent("月の上限", value: "\(settings.monthlyLimitMinutes) 分")
                    }
                    LabeledContent("目安", value: price(minutes: settings.monthlyLimitMinutes))
                    LabeledContent("今月の使用", value: "\(settings.usedMinutesThisMonth) 分（\(price(minutes: settings.usedMinutesThisMonth))）")
                } header: {
                    Text("使いすぎ防止")
                } footer: {
                    Text("上限に達したら、月が変わるまで端末内の文字起こし（無料）に戻ります。料金は1分 $\(settings.provider.dollarsPerMinute, specifier: "%.4f")、円は1ドル150円で計算した目安です。")
                }
            }
        }
        .navigationTitle("高精度文字起こし")
    }

    private func price(minutes: Int) -> String {
        let dollars = settings.dollars(minutes: minutes)
        return String(format: "$%.2f（約 %@ 円）", dollars,
                      (dollars * 150).formatted(.number.precision(.fractionLength(0))))
    }
}

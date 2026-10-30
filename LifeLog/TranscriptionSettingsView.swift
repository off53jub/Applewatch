import SwiftUI

/// 高精度（OpenAI）文字起こしの API キー・聞き取ってほしい言葉・月の上限を決める画面。
struct TranscriptionSettingsView: View {
    @Bindable var settings: TranscriptionSettings
    @State private var keyInput = ""

    var body: some View {
        Form {
            Section {
                if settings.hasAPIKey {
                    LabeledContent("API キー", value: "登録済み")
                    Button("API キーを消す", role: .destructive) { settings.setAPIKey("") }
                } else {
                    SecureField("sk-…", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存") {
                        settings.setAPIKey(keyInput)
                        keyInput = ""
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("OpenAI の API キー")
            } footer: {
                Text("platform.openai.com で作ったキーを貼り付けます。キーはこの iPhone のキーチェーンにだけ保存します。ChatGPT の有料プランとは別に、使った分だけ請求されます。")
            }

            Section {
                TextField("1行に1語（例: 人名、社名、専門用語）", text: $settings.keywordText, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("聞き取ってほしい言葉")
            } footer: {
                Text("よく出てくる名前や言葉を書いておくと、その表記で書き起こされやすくなります。")
            }

            Section {
                Stepper(value: $settings.monthlyLimitMinutes, in: 500...20_000, step: 500) {
                    LabeledContent("月の上限", value: "\(settings.monthlyLimitMinutes) 分")
                }
                LabeledContent("目安", value: Self.price(minutes: settings.monthlyLimitMinutes))
                LabeledContent("今月の使用", value: "\(settings.usedMinutesThisMonth) 分（\(Self.price(minutes: settings.usedMinutesThisMonth))）")
            } header: {
                Text("使いすぎ防止")
            } footer: {
                Text("上限に達したら、月が変わるまで端末内の文字起こし（無料）に戻ります。料金は1分 $\(CloudTranscriber.dollarsPerMinute, specifier: "%.4f")、円は1ドル150円で計算した目安です。")
            }
        }
        .navigationTitle("高精度文字起こし")
    }

    private static func price(minutes: Int) -> String {
        let dollars = TranscriptionSettings.dollars(minutes: minutes)
        return String(format: "$%.2f（約 %@ 円）", dollars,
                      (dollars * 150).formatted(.number.precision(.fractionLength(0))))
    }
}

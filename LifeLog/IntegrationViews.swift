import SwiftUI

/// 周りの声を減らす・聞き直すときの雑音を減らす。
struct NoiseSettingsView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage("denoisePlayback") private var denoise = true

    var body: some View {
        @Bindable var filter = pipeline.officeFilter
        Form {
            Section {
                Picker("使うとき", selection: $filter.mode) {
                    ForEach(OfficeFilter.Mode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("自分の声よりずっと小さい声を外す", isOn: $filter.byLoudness)
                Toggle("自分とやりとりの無い声を外す", isOn: $filter.byExchange)
                LabeledContent("覚えた自分の声（iPhone）", value: filter.selfLevelText(watch: false))
                LabeledContent("覚えた自分の声（時計）", value: filter.selfLevelText(watch: true))
                LabeledContent("これまでに外した行", value: "\(filter.dropped) 行")
                NavigationLink("外した行を見る・戻す") { CleanupView() }
            } header: {
                Text("周りの人の声を書かない")
            } footer: {
                Text("自分の声の大きさを話すたびに覚え、それより14dB以上小さく入った声（遠くの席の声）と、名前の無い声で前後3分に自分が一度も話していないもの（周りの雑談）を記録に書きません。名前を付けた人の声は、やりとりが無くても残します。外した行は「記録の掃除」の「消した行」に30日間残り、そこから戻せます。「職場にいるときだけ」は、職場にした場所・職場のカレンダーの予定・平日8〜19時で決めます。")
            }

            Section {
                Toggle("聞き直すときに雑音を減らす", isOn: $denoise)
            } footer: {
                Text("記録の行や声のひとこまを鳴らすときだけ、空調やファン、走行音のようなずっと鳴っている雑音を減らし、聞きやすい大きさにそろえます。録音そのものは変えないので、文字起こしには影響しません。周りの話し声のような雑音はあまり減りません。")
            }
        }
        .navigationTitle("周りの声と雑音")
    }
}

/// カレンダー・移動の様子・睡眠との連携。
struct IntegrationsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        @Bindable var calendar = pipeline.calendar
        @Bindable var motion = pipeline.motion
        @Bindable var sleep = pipeline.sleep
        Form {
            Section {
                if calendar.authorized {
                    Toggle("カレンダーを使う", isOn: $calendar.enabled)
                } else {
                    Button("カレンダーを使えるようにする") { Task { await calendar.requestAccess() } }
                }
                if calendar.authorized && calendar.enabled {
                    NavigationLink("職場のカレンダーを選ぶ（\(calendar.workCalendars.count)）") { WorkCalendarsView() }
                }
            } header: {
                Text("カレンダー")
            } footer: {
                Text("会話の時間に予定があれば、見出しに〔予定名〕を付け、要約の参考にします。予定名と参加者の名前は、聞き取りと誤変換直しのヒントにもなります（予定名は誤変換直しのときに Groq に送られます）。職場のカレンダーを選ぶと、その予定の時間は職場とみなします。")
            }

            Section {
                if !motion.available {
                    Text("この iPhone では使えません").foregroundStyle(.secondary)
                } else if motion.authorized {
                    Toggle("移動の様子を使う", isOn: $motion.enabled)
                } else {
                    Button("移動の様子を使えるようにする") { Task { await motion.requestAccess() } }
                }
            } header: {
                Text("移動の様子")
            } footer: {
                Text("iPhone の動きから、歩いている・電車や車に乗っている・止まっている、が分かります。会話の見出しに「（歩きながら）」「（電車・車で）」のように添えます。")
            }

            Section {
                Toggle("寝ているあいだを見分ける", isOn: $sleep.enabled)
                if sleep.enabled {
                    Picker("寝る時間帯の始まり", selection: $sleep.startHour) {
                        ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                    }
                    Picker("終わり", selection: $sleep.endHour) {
                        ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                    }
                }
            } header: {
                Text("睡眠")
            } footer: {
                Text("寝る時間帯に iPhone がほとんど動いていなければ、寝ているとみなします（移動の様子がオフなら時間帯だけで決めます）。寝ているあいだは端末内の文字起こしだけで済ませて電池を節約し、近くではっきり話した長めの文だけを書きます。ヘルスケアの睡眠の記録は、アプリに特別な許可が要り Sideloadly では入れられないため、使っていません。")
            }
        }
        .navigationTitle("カレンダー・移動・睡眠")
    }
}

/// 職場の予定が入っているカレンダーを選ぶ。
private struct WorkCalendarsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let link = pipeline.calendar
        List {
            ForEach(link.calendars, id: \.calendarIdentifier) { cal in
                Button {
                    if link.workCalendars.contains(cal.calendarIdentifier) {
                        link.workCalendars.remove(cal.calendarIdentifier)
                    } else {
                        link.workCalendars.insert(cal.calendarIdentifier)
                    }
                } label: {
                    HStack {
                        Circle().fill(Color(cgColor: cal.cgColor)).frame(width: 10, height: 10)
                        Text(cal.title)
                        Spacer()
                        if link.workCalendars.contains(cal.calendarIdentifier) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .tint(.primary)
            }
        }
        .navigationTitle("職場のカレンダー")
    }
}

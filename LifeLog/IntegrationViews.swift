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
                NavigationLink("外しすぎた行をまとめて戻す") { OverRemovedView() }
            } header: {
                Text("周りの人の声を書かない")
            } footer: {
                Text("自分の声の大きさを話すたびに覚え、それより14dB以上小さく入った名前の無い声（遠くの席の声）と、名前の無い声で前後3分に自分が一度も話していないもの（周りの雑談）を記録に書きません。名前を付けた人の声は、小さくても・やりとりが無くても残します。外した行は「記録の掃除」の「消した行」に30日間残り、そこから戻せます。「職場にいるときだけ」は、職場にした場所にいるときと、職場のカレンダーの予定の最中だけです（時刻だけでは決めません）。")
            }

            Section {
                Toggle("騒がしい所はクラウドでも聞いて補う", isOn: Binding(
                    get: { pipeline.noisyAssistOn },
                    set: { pipeline.noisyAssistOn = $0 }))
                NavigationLink("場所ごとの周りの音と聞き取りの成績") { ListenQualityView() }
            } header: {
                Text("騒がしい所")
            } footer: {
                Text("区切りごとに周りの音の大きさと、声との差を測り、飲食店や駅のように騒がしい区切りは次のようにします。\n・Haas-ja で書いたあと、クラウドの Whisper（「高精度で文字起こし」がオンのとき）でも聞き、Haas-ja が何も書かなかった声のところを補います。\n・クラウドの文が iPhone の中の聞き取りと合わなくても、声のあるところなら残します（騒がしいと iPhone の中の聞き取りも崩れるため）。\n・こうして書いた行は、記録で「？」の付いた、確かめたほうがよい行になり、時刻の下に🔊の印が付きます。\nいちばん効くのは、iPhone をテーブルの上に置いて、相手との間にマイク（画面の下の端）を向けることです。時計と iPhone の両方で録っていれば、聞き取りの良いほうを1文ごとに選びます。")
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

/// カレンダー・連絡先・移動の様子・睡眠との連携。
struct IntegrationsView: View {
    @Environment(Pipeline.self) private var pipeline
    /// Pipeline.meetingBriefKey と同じ名前
    @AppStorage("meetingBrief") private var meetingBrief = true

    var body: some View {
        @Bindable var calendar = pipeline.calendar
        @Bindable var contacts = pipeline.contacts
        @Bindable var motion = pipeline.motion
        @Bindable var sleep = pipeline.sleep
        @Bindable var health = pipeline.health
        Form {
            Section {
                if calendar.authorized {
                    Toggle("カレンダーを使う", isOn: $calendar.enabled)
                } else {
                    Button("カレンダーを使えるようにする") { Task { await calendar.requestAccess() } }
                }
                if calendar.authorized && calendar.enabled {
                    LabeledContent("Google カレンダー", value: calendar.hasGoogle ? "読めています" : "まだ iPhone に入っていません")
                    NavigationLink("使うカレンダー・職場のカレンダー") { CalendarsView() }
                    Toggle("会う前のおさらいを通知する", isOn: $meetingBrief)
                        .onChange(of: meetingBrief) { Task { await pipeline.scheduleMeetingBriefs(force: true) } }
                }
            } header: {
                Text("カレンダー")
            } footer: {
                Text("""
                    Google カレンダーは、iPhone の「設定」→「アプリ」→「カレンダー」→「カレンダーアカウント」→「アカウントを追加」→「Google」で、ふだんの Google アカウントを足して「カレンダー」をオンにすると読めるようになります（LifeLog の側で Google の設定を足す必要はありません）。
                    予定は、記録の「過ごし方」の区切りと名前（12:00〜16:00 ダンス、など）、会話の見出しの〔予定名〕、要約の参考に使います。予定名・場所・参加者の名前は、聞き取りと誤変換直しのヒントにもなります（そのときは Groq に送られます）。職場のカレンダーを選ぶと、その予定の時間は職場とみなします。
                    「会う前のおさらい」は、予定の10分前に、その予定で会う名前を付けた人（参加者の名前か、予定名に入っている名前）と、前回話した会話の見出しと要点を通知します。前に話した会話が無い人は出しません。通知はロック画面にも出ます。
                    """)
            }

            Section {
                if contacts.authorized {
                    Toggle("連絡先の名前を使う", isOn: $contacts.enabled)
                    if contacts.enabled && contacts.count > 0 {
                        LabeledContent("読み込んだ名前", value: "\(contacts.count) 個")
                    }
                } else {
                    Button("連絡先を使えるようにする") { Task { await contacts.requestAccess() } }
                }
            } header: {
                Text("連絡先")
            } footer: {
                Text("会話で「さいとうさん」「斉藤くん」のように呼ばれた名前と読みが同じ人を連絡先から探し、連絡先での書き方（「齋藤」など）を聞き取りと誤変換直しのヒントにします。ふりがなを入れてある人ほど正確です。連絡先そのものは外に送りません。読みが合った人の名前だけが、ヒントとして Groq やクラウドの文字起こしに渡ります。")
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
                if health.enabled {
                    Toggle("ヘルスケアを使う", isOn: $health.enabled)
                } else {
                    Button("ヘルスケアを使えるようにする") { Task { await health.requestAccess() } }
                }
                if !health.note.isEmpty { Text(health.note).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("ヘルスケア")
            } footer: {
                Text("Apple Watch の睡眠・心拍・歩数を読みます（書きません）。寝ているかを睡眠の記録で見分け、会話のあいだ心拍がふだん（安静時心拍）より平均で20以上か最大で30以上高ければ、記録の見出しに ♥︎ を付けます。1日のまとめに睡眠と歩数、心拍が上がっていた会話を入れ、「話し方の振り返り」にも数えます。署名にヘルスケアの許可が要るので、TestFlight で入れたときに使えます（署名なしの IPA を Sideloadly で入れたときは使えないことがあります）。")
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
        .navigationTitle("カレンダー・連絡先・移動・睡眠")
    }
}

/// 使うカレンダーと、職場の予定が入っているカレンダーを選ぶ。アカウント（iCloud・Google など）ごとに並べる。
private struct CalendarsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let link = pipeline.calendar
        List {
            ForEach(link.calendarsByAccount, id: \.account) { group in
                Section(group.account) {
                    ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                        let id = cal.calendarIdentifier
                        let used = !link.ignoredCalendars.contains(id)
                        HStack {
                            Circle().fill(Color(cgColor: cal.cgColor)).frame(width: 10, height: 10)
                            Text(cal.title).foregroundStyle(used ? Color.primary : Color.secondary)
                            Spacer()
                            if used {
                                Button {
                                    if link.workCalendars.contains(id) {
                                        link.workCalendars.remove(id)
                                    } else {
                                        link.workCalendars.insert(id)
                                    }
                                } label: {
                                    Text("職場")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(link.workCalendars.contains(id) ? Color.accentColor : Color.secondary.opacity(0.15),
                                                    in: Capsule())
                                        .foregroundStyle(link.workCalendars.contains(id) ? Color.white : Color.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            Toggle("使う", isOn: Binding(
                                get: { !link.ignoredCalendars.contains(id) },
                                set: { on in
                                    if on { link.ignoredCalendars.remove(id) } else { link.ignoredCalendars.insert(id) }
                                }))
                            .labelsHidden()
                        }
                    }
                }
            }
        }
        .overlay {
            if link.calendars.isEmpty {
                ContentUnavailableView("カレンダーがありません", systemImage: "calendar")
            }
        }
        .navigationTitle("カレンダー")
        .safeAreaInset(edge: .bottom) {
            Text("右のスイッチを切ったカレンダー（家族の共有カレンダーなど、自分の予定ではないもの）は使いません。「職場」を付けたカレンダーの予定の時間は、職場とみなします。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .background(.bar)
        }
    }
}

/// 夜の充電中の聞き直し。
struct NightlyView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        Form {
            Section {
                if let progress = pipeline.nightlyProgress {
                    HStack {
                        ProgressView()
                        Text(progress.total > 0 ? "聞き直しています… \(progress.done) / \(progress.total)" : "準備しています…")
                    }
                } else {
                    Button("今すぐ聞き直す") { Task { await pipeline.runNightly(force: true) } }
                }
                if !pipeline.nightlyResult.isEmpty {
                    Text(pipeline.nightlyResult).font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text("夜（22時〜6時）に充電しているとき、iPhone に残っている1日分の音声を聞き直します。その日に出た名前・話題・予定の言葉をヒントにし、Haas-ja で書けていなかった区切り（電池優先のときなど）は Haas-ja で書き直して、前より良くなった行だけ差し替えます。確かさの低い行は、2つの聞き取りを見比べて直します。手で直した行は変えず、差し替えた行の元の文は「直す前」として残ります。")
            }
        }
        .navigationTitle("夜の聞き直し")
    }
}

/// ロック画面・コントロールセンター・アクションボタン・時計の文字盤から使う方法。
struct ShortcutsHelpView: View {
    var body: some View {
        Form {
            Section("ロック画面・コントロールセンター") {
                Text("コントロールセンターを開いて左上の「＋」→「コントロールを追加」で「LifeLog」を探すと、「録音を始める・止める」と「印を付ける」があります。ロック画面の下の2つのボタンも、ロック画面を長押し→「カスタマイズ」から同じものに替えられます。")
            }
            Section("アクションボタン") {
                Text("設定アプリ →「アクションボタン」で「ショートカット」を選び、「LifeLog」の「iPhone の録音を始める・止める」を選びます（「コントロール」の「LifeLog 録音」でも同じです）。")
            }
            Section("Apple Watch の文字盤") {
                Text("文字盤を長押し →「編集」→ コンプリケーションの欄で「LifeLog」を選ぶと、文字盤から1回押すだけで LifeLog を開けます。")
            }
            Section {
                Text("「録音を始める・止める」は、LifeLog を開かず、ロックしたまま（Face ID なし）で動きます。iOS の決まりで、こうして始めた録音のあいだは、ロック画面と Dynamic Island に「LifeLog 録音中」が出ます（そこからも止められます）。この表示は8時間で iOS に消されることがあるので、録音中に LifeLog を開くと出し直します。録音が止まったときは、いつもの通知で知らせます。")
                    .foregroundStyle(.secondary)
                Text("「印を付ける」は、押すと LifeLog が開いて動きます。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ほかの場所から使う")
    }
}

/// 外しすぎた行をまとめて戻す（2026-11-05）。
/// 「周りの声」として外した行のうち、直した決まり（名前のある人は外さない・職場と分かっているときだけ外す）なら残っていた行を、件数を見てから戻す。
struct OverRemovedView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var items: [Junk.TrashItem] = []
    @State private var loaded = false
    @State private var running = false
    @State private var done = 0
    @State private var result: String?
    @State private var showAll = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) H:mm"
        return f
    }()

    var body: some View {
        List {
            Section {
                if !loaded {
                    ProgressView()
                } else if items.isEmpty {
                    Text("戻す行はありません").foregroundStyle(.secondary)
                } else {
                    LabeledContent("戻す行", value: "\(items.count) 行・\(Set(items.map(\.day)).count) 日")
                    if running {
                        ProgressView(value: Double(done), total: Double(max(1, items.count))) {
                            Text("戻しています… \(done) / \(items.count)")
                        }
                    } else {
                        Button("記録とドキュメントに戻す", systemImage: "arrow.uturn.backward") {
                            Task { await run() }
                        }
                    }
                }
                if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("「周りの声」として外した行のうち、名前を付けた人の声と、登録した職場にいない・仕事の予定の最中でもないときの声です（11/5 に、この2つは外さない決まりに直しました）。戻した会話は、見出しと要点を作り直します。1行ずつドキュメントに入れるので、多いと時間がかかります。途中で止まっても、もう一度押せば続きから戻します。")
            }
            if !items.isEmpty {
                Section {
                    ForEach(showAll ? items : Array(items.prefix(30))) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.line.text).font(.callout).lineLimit(3)
                            Text(Self.time.string(from: item.line.time) + (item.line.speaker.map { "・" + $0 } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if items.count > 30 && !showAll {
                        Button("ほか \(items.count - 30) 行も見る") { showAll = true }
                    }
                } header: {
                    Text("戻す行（古い順）")
                }
            }
        }
        .navigationTitle("外しすぎた行を戻す")
        .task {
            items = pipeline.overRemoved()
            loaded = true
        }
    }

    private func run() async {
        running = true
        done = 0
        let made = await pipeline.restoreOverRemoved(items) { count in done = count }
        running = false
        result = "\(made.done) 行を戻しました。" + (made.error.map { "途中で止まりました（\($0)）。もう一度押すと続きから戻します。" } ?? "")
        items = pipeline.overRemoved()
    }
}

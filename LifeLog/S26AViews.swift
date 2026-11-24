import SwiftUI

// s26（2026-11-25）の A1 の画面（決まりは S26ARules.swift・動きは S26ABook.swift）。
// 設定は「くわしい設定」の 1 行から開く。問い・知らせは足さない（減13）。

/// くわしい設定に置く入口
struct S26ASettingsLinkSection: View {
    var body: some View {
        Section {
            NavigationLink {
                S26ASettingsView()
            } label: {
                Label("取るデータと入口（体重・端末の合図・曲など）", systemImage: "square.stack.3d.up")
            }
        } footer: {
            Text("体重と体の記録・せきといびきの数・充電や階の合図・食事の写真の時刻・名刺・曲・予定で録り方・実績のカレンダー・iPhone の検索。")
        }
    }
}

struct S26ASettingsView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(S26ASettings.bodySoundsKey) private var bodySounds = true
    @AppStorage(S26ASettings.songsHeardKey) private var songsHeard = false
    @AppStorage(S26ASettings.songsPlayedKey) private var songsPlayed = false
    @AppStorage(S26ASettings.deviceSignalsKey) private var deviceSignals = true
    @AppStorage(S26ASettings.floorsKey) private var floors = true
    @AppStorage(S26ASettings.mealsKey) private var meals = true
    @AppStorage(S26ASettings.cardsKey) private var cards = true
    @AppStorage(S26ASettings.meetingAutoKey) private var meetingAuto = false
    @AppStorage(S26ASettings.actualKey) private var actual = false
    @AppStorage(S26ASettings.spotlightKey) private var spotlight = true
    @AppStorage(S26ASettings.nameDictKey) private var nameDict = true
    @AppStorage(S26ASettings.fastSendKey) private var fastSend = true
    @AppStorage(S26ASettings.benchKey) private var bench = true
    @State private var weight: (kg: Double, at: Date)?
    @State private var weightText = ""
    @State private var note: String?

    var body: some View {
        LLList {
            weightSection
            bodySection
            signalsSection
            meetingSection
            linkSection
            measureSection
        }
        .navigationTitle("取るデータと入口")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("s26aSettings")
        .task { weight = await pipeline.health.latestWeight() }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d H:mm"
        return f
    }()

    // 集1
    private var weightSection: some View {
        Section {
            LabeledContent("いちばん新しい体重", value: weight.map { String(format: "%.1f kg（%@）", $0.kg, Self.clock.string(from: $0.at)) } ?? "まだありません")
            HStack {
                TextField("体重（kg）", text: $weightText)
                    .keyboardType(.decimalPad)
                Button("入れる") {
                    let value = Double(weightText.replacingOccurrences(of: ",", with: "."))
                    if let value, S26AWeightBook.add(value) {
                        weightText = ""
                        note = String(format: "%.1f kg を残しました。", value)
                        Task { weight = await pipeline.health.latestWeight() }
                    } else {
                        note = "20〜300 kg の数で入れてください。"
                    }
                }
                .disabled(weightText.isEmpty)
            }
            if let note { Text(note).font(.caption).foregroundStyle(LL.dim) }
        } header: {
            Text("体重（集1）")
        } footer: {
            HelpNote("体重・体脂肪・BMI と、呼吸数・血中酸素・手首の温度・最大酸素摂取量・階段・日光・音の大きさは、ヘルスケアから読んで毎日の書き出しに入れます（無い日は書きません）。ヘルスケアの許可は、次にアプリを開いたときに 1 回だけ聞きます。ここで入れた体重はヘルスケアには書かず、ヘルスケアに体重が無い日だけ書き出しに使います。ショートカットの「体重を入れる」でも入れられます。")
        }
    }

    // 集3・集4・集5
    private var bodySection: some View {
        Section {
            Toggle("せき・いびきを数える", isOn: $bodySounds)
            Toggle("その場で流れていた曲を引く", isOn: $songsHeard)
            Toggle("ミュージックで聴いた曲を残す", isOn: $songsPlayed)
                .onChange(of: songsPlayed) { _, on in
                    guard on, !S26AMusic.authorized else { return }
                    Task {
                        if !(await S26AMusic.requestAccess()) { note = "ミュージックの許可が無いので、聴いた曲は残せません（iPhone の設定 → LifeLog で変えられます）。" }
                    }
                }
            let c = S26ABodySounds.counts(on: HealthExport.dayKey(.now))
            LabeledContent("今日", value: "せき \(c.coughs ?? 0) 回・いびき \(String(format: "%.0f", c.snoreMinutes ?? 0)) 分（夜の分は朝の日）")
        } header: {
            Text("体の音と曲（集3・集4・集5）")
        } footer: {
            HelpNote("せき・いびき（初めはオン）: 録音の音の種類を見分けたときに、数だけ数えます（文や音は残しません）。声の無い夜の区切りは、充電中だけ見ます。強さ 0.5 以上（仮）。\n流れていた曲（初めはオフ）: 録音に音楽が 6 秒以上続いたところの 10 秒を、Apple の曲の照合（ShazamKit）に聞きます。1 日 30 回まで（仮）。Apple の開発者サイトで、アプリの ID に ShazamKit を有効にしないと、引けずに何もしません。\n聴いた曲（初めはオフ）: ミュージックで再生中の曲名と歌手を、アプリが動いているあいだ 1 分ごとに見ます。ほかの音楽アプリの分は読めません。")
        }
    }

    // 集12・集13・集10・集16・集19
    private var signalsSection: some View {
        let today = S26ASignalsStore.shared.today()
        return Section {
            Toggle("充電・朝に最初に使った時刻・集中モード", isOn: $deviceSignals)
            Toggle("何階にいたか（気圧）", isOn: $floors)
            Toggle("食事の写真の時刻と場所", isOn: $meals)
            Toggle("名刺の文字", isOn: $cards)
            LabeledContent("今日の合図", value: todayLine(today))
            NavigationLink("アプリの使用時間・集中モードの作り方") { AppUsageHowToView() }
        } header: {
            Text("端末の合図（集10・集12・集13・集16・集19）")
        } footer: {
            HelpNote("終わった日の分を、ヘルスケアと同じフォルダに 1 日 1 ファイル（lifelog-signals-日付.json）で書き、母艦が取り込みます。どれも初めはオン。\n充電と画面を開いた時刻は、アプリが動いているあいだに分かった分です（ショートカットの「充電器」のオートメーションで「充電の合図」を呼ぶと、止まっていても残ります）。4 時より前は「朝に最初に使った」に数えません（仮）。\n階: 3 分の中で 3m（仮）変わったら 1 階。天気の気圧の変わりは捨てます。\n食事の写真・名刺: 新しく撮った写真を iPhone の中で見分けます。写真そのものは送りません。名刺は文字だけ（20 行まで）。\nアプリの使用時間と集中モード: iPhone は外へ出す道を用意していないので、ショートカットのオートメーション（「アプリを開いた記録」か「アプリの使用時間を足す」）から入れます。")
        }
    }

    private func todayLine(_ d: S26ADaySignals) -> String {
        var bits: [String] = []
        if let first = d.firstUse { bits.append("最初 " + MorningBrief.clock(first)) }
        if !d.charge.isEmpty { bits.append("充電 \(d.charge.count)") }
        if !d.floors.isEmpty { bits.append("階 \(d.floors.count)") }
        if !d.meals.isEmpty { bits.append("食事 \(d.meals.count)") }
        if !d.cards.isEmpty { bits.append("名刺 \(d.cards.count)") }
        if !d.songs.isEmpty { bits.append("曲 \(d.songs.count)") }
        if !d.focus.isEmpty { bits.append("集中 \(d.focus.count)") }
        if !d.screenTime.isEmpty { bits.append("アプリ \(d.screenTime.count)") }
        return bits.isEmpty ? "まだありません" : bits.joined(separator: "・")
    }

    // 聞16・結3
    private var meetingSection: some View {
        Section {
            Toggle("会議・面談の予定のあいだは精度優先", isOn: $meetingAuto)
            if S26AMeetingAuto.isActive { Text("いま予定のあいだなので精度優先です。終わったら元に戻します。").font(.caption).foregroundStyle(LL.dim) }
            Toggle("「実績」のカレンダーに書く", isOn: $actual)
                .onChange(of: actual) { _, on in if on { S26AActualCalendar.turnedOn() } }
            if actual && !S26AActualCalendar.authorized {
                Text("カレンダーの許可が要ります（設定の「カレンダー」から許可してください）。").font(.caption).foregroundStyle(LL.dim)
            }
        } header: {
            Text("予定とカレンダー（聞16・結3）")
        } footer: {
            HelpNote("精度優先（初めはオフ）: 予定の名前に「会議」「面談」「打ち合わせ」「定例」「MTG」などがある・職場のカレンダーで相手がいる予定の 2 分前（仮）から終わりまで、「録り方の組」の精度優先にし、終わったら前の録り方に戻します。高精度の文字起こしのお金と電池が増えることがあります。\n実績（初めはオフ）: 終わった日の、3 分以上の会話（相手と見出し）と 10 分以上いたお店を、「実績」という別のカレンダーに書きます（オンにした日の 7 日前から）。ふつうのカレンダーで過去が見えます。消すときはカレンダーごと消せます。")
        }
    }

    // 軽7・聞12・結5・軽8
    private var linkSection: some View {
        Section {
            Toggle("iPhone の検索に人・日・会話・場所を載せる", isOn: $spotlight)
            Toggle("人の名前の読みの辞書を聞き取りに使う", isOn: $nameDict)
            LabeledContent("辞書の名前", value: "\(S26ANameDict.shared.names.count) 件")
            Toggle("小さい区切りはすぐ家の PC に送る", isOn: $fastSend)
            Button("朝のまとめと次の予定を聞く", systemImage: "headphones") {
                Task { MorningSpeaker.shared.toggle(await S26AEar.script()) }
            }
        } header: {
            Text("入口とつながり（軽7・軽8・聞12・結5）")
        } footer: {
            HelpNote("検索（初めはオン）: 人・直近 60 日・行った場所・直近 14 日の会話の見出しを、6 時間ごとに iPhone の検索に載せます。押すとその画面が開きます。「開くときに Face ID」がオンなら、会話の見出しは載せません。Siri には、ショートカットの「人のページを開く」で頼めます。\n名前の辞書（初めはオン）: 人のページの名前と別名・前後 14 日の予定の相手から読みを作り、「〇〇さん」と呼ばれた名前の書き方を聞き取りと直しのヒントにします。\nすぐ送る（初めはオン）: 700KB（仮）より小さい区切りは、アプリが動いているあいだ、その場の通信で家の PC に送ります。だめなら今までどおり裏の転送で送ります。\n耳で: 朝の「昨日と今日」（今日の三つつき）と次の予定の前の一枚を読み上げます。車の CarPlay の画面は、Apple の許可が要るのでまだありません。")
        }
    }

    // 聞10
    private var measureSection: some View {
        Section {
            Toggle("端末の中の音声認識を答え合わせで測る", isOn: $bench)
            if let r = S26ABenchRules.rates(S26ABench.shared.rows) {
                LabeledContent("端末の中（SpeechAnalyzer）", value: String(format: "誤り %.0f%%", r.device * 100))
                LabeledContent("いまの記録の文", value: String(format: "誤り %.0f%%（%d 行）", r.app * 100, r.count))
            } else {
                Text("まだ測っていません（答え合わせで答えた行を、充電中に 1 日 8 個まで）。").font(.caption).foregroundStyle(LL.dim)
            }
        } header: {
            Text("測る（聞10）")
        } footer: {
            HelpNote("測るだけで、切り替えません。答え合わせで答えた行の音声を、iPhone の中の音声認識（iOS 26 の SpeechAnalyzer）でもう一度聞き、正しい文との違いを、いま記録に入っている文と並べます。端末の側は区切りの中でいちばん合う所で比べるので、やや甘めです（仮）。")
        }
    }
}

// MARK: - 結9 lifelog:// のリンクから開く画面

struct S26ALinkView: View {
    @Environment(Pipeline.self) private var pipeline
    let link: S26ALink

    var body: some View {
        content
            .onAppear { Tally.add("s26a.link." + kind) }
    }

    private var kind: String {
        switch link {
        case .person: "person"
        case .day: "day"
        case .talk: "talk"
        case .task: "task"
        case .drafts: "drafts"
        case .waiting: "waiting"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch link {
        case .person(let name):
            person(name)
        case .day(let day):
            DayView(day: day)
                .navigationTitle(day)
                .navigationBarTitleDisplayMode(.inline)
        case .talk(let id):
            talk(id)
        case .task(let id):
            task(id)
        case .drafts:
            LLList { S25TDraftShelfSection() }
                .navigationTitle("下書きの棚")
                .navigationBarTitleDisplayMode(.inline)
        case .waiting:
            missing("操作待ちの案内は、まだこの版にありません。")
        }
    }

    @ViewBuilder
    private func person(_ name: String) -> some View {
        if let page = PagesBook.shared.page(named: name) {
            PersonPageView(page: page)
                .navigationTitle(page.name)
                .navigationBarTitleDisplayMode(.inline)
        } else if let voice = pipeline.people.first(where: { $0.isNamed && !$0.isSelf && S25TText.sameName($0.displayName, name) }) {
            PersonView(id: voice.id)
        } else {
            missing("「\(name)」さんのページは、まだこの iPhone にありません（家の PC の人のページが届くと開けます）。")
        }
    }

    @ViewBuilder
    private func talk(_ id: String) -> some View {
        if let moment = S26ALink.talkMoment(id) {
            if let time = moment.time {
                ConversationsView(day: moment.day, range: time.addingTimeInterval(-10 * 60)...time.addingTimeInterval(10 * 60))
                    .navigationTitle(moment.day)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                DayView(day: moment.day)
                    .navigationTitle(moment.day)
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            missing("この会話は、この iPhone の記録からは開けません。")
        }
    }

    @ViewBuilder
    private func task(_ id: String) -> some View {
        if let item = pipeline.tasks.items.first(where: { $0.id == id }) {
            TaskEditView(item: item) { saved in
                pipeline.tasks.update(saved)
                pipeline.tasksChanged()
                pipeline.noticeRoute = nil
            } onDelete: {
                if item.source == .manual {
                    pipeline.tasks.delete(item.id)
                } else {
                    pipeline.tasks.set(item.id, .rejected)
                }
                pipeline.tasksChanged()
                pipeline.noticeRoute = nil
            }
        } else {
            missing("このタスクは、アプリのタスクの中に見つかりませんでした（家の PC のやることかもしれません）。")
        }
    }

    private func missing(_ text: String) -> some View {
        LLList {
            Section {
                Text(text)
                Button("タスクを開く", systemImage: "checklist") {
                    pipeline.noticeRoute = nil
                    pipeline.tab = .tasks
                }
                Button("記録を開く", systemImage: "books.vertical") {
                    pipeline.noticeRoute = nil
                    pipeline.tab = .records
                }
            }
        }
        .navigationTitle("リンク")
        .navigationBarTitleDisplayMode(.inline)
    }
}

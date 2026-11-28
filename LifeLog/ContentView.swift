import Combine
import SwiftUI

/// 画面の下の5つのタブ（2026-11-12 に組み替え）。「何をしに開いたか」でタブを分ける。
/// 2026-11-27（s30。S30TTabs.swift）から: 今日（録る・今を見る）｜タスク（仕事以外のやること）｜仕事（案件の状況・仕事のタスク・仕事のまとめ。S30WTab）｜
/// 直す（記録を正しくする答え）｜記録（探す・読む。日ごと・人・場所・お金と、前のふり返りタブの中身の「ふり返り」）。
/// 設定と点検は、どのタブでも右上の歯車から開く。前は 今日・タスク・直す・記録・ふり返り（その前は 今日・タスク・ライブ・記録・人と場所）。
struct ContentView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage("taskBadgeLateOnly") private var badgeLateOnly = false
    /// 声の見直しの数（記録をひととおり見るので、声のひとこまが変わったときだけ数え直す）
    @State private var reviewCount = 0
    /// 初めての入口・アップデートのあとの案内（2026-11-21。s20）
    @State private var firstRun: FirstRun?
    /// 振った（「いまの画面が変」。2026-11-22。s21 の 使10）
    @State private var shook: S21ShakeTarget?
    /// 下の入口を 今日・仕事・タスク・人 ＋ 奥 にする（2026-11-28。s36 の 大3。初めはオン・奥の一覧の下で前の 5 つに戻せる。S36ARules.swift）
    @AppStorage(S36ATabs.onKey) private var newTabs = true

    /// 今日までのもの・過ぎたもの（待っているものは除く）
    private var lateTasks: Int {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86400)
        // 家の PC のやることも、アプリのタスクと重ならないものだけ1回数える（2026-11-10。1つの一覧にした）
        let home = pipeline.mothership.extra(.all, tasks: pipeline.tasks.items)
            .filter { (MothershipExport.dueDate($0.due) ?? .distantFuture) < end }.count
        return pipeline.tasks.todo.filter { ($0.due ?? .distantFuture) < end }.count + home
    }

    var body: some View {
        let fixCount = pipeline.fixBadge(reviewCount: reviewCount)  // 今日やる分だけ（FixViews.swift。2026-11-13）
        tabs(fixCount: fixCount)
        // 前のふり返り（lookBack）を直に選んだものも、記録の「ふり返り」へ（知らせ・リンクは openRoute で同じにしている）
        .onChange(of: pipeline.tab) {
            if pipeline.tab == .lookBack { pipeline.openRoute(.tab(.lookBack)) }
        }
        // すべての日を読むので、1 日ごとに譲る（2026-11-16。途中で声が変わったら数え直し）
        .task(id: pipeline.people.flatMap(\.samples)) {
            if let count = await pipeline.voiceReviewCount() { reviewCount = count }
            await S29NBook.shared.refresh(pipeline)  // 名前付けの山の数（s29。10 分に 1 回まで）
        }
        // 知らせ・ショートカット・ウィジェットから開く画面（2026-11-10。NoticeActions.swift）。タブの切り替えはシートにしない
        .sheet(item: Binding(get: { pipeline.noticeRoute }, set: { pipeline.noticeRoute = $0 })) { route in
            NavigationStack {
                Group {
                    switch route {
                    case .tab:
                        EmptyView()
                    case .digestImport(let text):
                        WorkDigestImportView(initialText: text)
                    case .screen(let screen):
                        NoticeScreenView(screen: screen)
                    case .note(let title, let body):
                        NoticeNoteView(title: title, text: body)
                    case .link(let link):
                        S26ALinkView(link: link)  // lifelog://person/… など（2026-11-25。s26 の 結9。S26AViews.swift）
                    case .work(let link):
                        S27WRootView(link: link)  // 仕事の画面（2026-11-25。s27 の 場1・K6。S27WViews.swift）
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { pipeline.noticeRoute = nil } }
                }
            }
        }
        .onAppear {
            // 取り込む画面は仕事タブの上に開く（2026-11-27。s30。S30TTabs.open）
            if let text = DigestInbox.take() { pipeline.openRoute(.digestImport(text)) }
            // アップデートのあとの案内 1 枚・初めての入口（2026-11-21。s20 の 体32・体35。画面の自動確認では出さない）
            guard !ProcessInfo.processInfo.arguments.contains("-screenshotDemo"),
                  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            if !UserDefaults.standard.bool(forKey: "s20.onboarded") && pipeline.email == nil && pipeline.recordedDays().isEmpty {
                firstRun = .onboarding
            } else if UserDefaults.standard.string(forKey: WhatsNew.seenKey) != WhatsNew.version {
                firstRun = .whatsNew
            }
        }
        .sheet(item: $firstRun) { kind in
            NavigationStack {
                switch kind {
                case .onboarding: OnboardingView { firstRun = nil }
                case .whatsNew: WhatsNewView { firstRun = nil }
                }
            }
            .environment(pipeline)
            .llRoot()
        }
        // 振って「いまの画面が変」（2026-11-22。s21 の 使10。S21Views.swift）
        .onReceive(NotificationCenter.default.publisher(for: .llShake)) { _ in
            guard firstRun == nil, pipeline.noticeRoute == nil, shook == nil else { return }
            shook = S21ShakeTarget(screen: ScreenTracker.current)
        }
        .sheet(item: $shook) { target in
            NavigationStack {
                S21ShakeSheet(screen: target.screen) { shook = nil }
            }
            .environment(pipeline)
            .llRoot()
        }
    }

    /// 下の入口。新しい形（s36 の 大3）は 今日・仕事・タスク・人 ＋ 奥（直す・記録・ふり返りは奥の中。S36AViews.swift）。
    /// 前の形は 今日・タスク・仕事・直す・記録（2026-11-27。s30。S30TTabs.swift）。前のふり返り（lookBack）が選ばれても記録を見せる
    @ViewBuilder
    private func tabs(fixCount: Int) -> some View {
        let taskBadge: Int = (badgeLateOnly ? 0 : pipeline.tasks.todayCandidates().count) + lateTasks
        if newTabs {
            TabView(selection: Binding(get: { S36ATabs.shown(pipeline.tab, on: true) },
                                       set: { pipeline.tab = S36ATabs.selected($0, current: pipeline.tab, on: true) })) {
                Tab(value: AppTab.today) { TodayView() } label: { S36ATabLabel(tab: .today) }
                Tab(value: AppTab.work) { S30WTab() } label: { S36ATabLabel(tab: .work) }
                Tab(value: AppTab.tasks) { TasksTab() } label: { S36ATabLabel(tab: .tasks) }
                    .badge(taskBadge)
                Tab(value: AppTab.people) { S36APeopleTab() } label: { S36ATabLabel(tab: .people) }
                Tab(value: AppTab.deep) { S36ADeepTab(fixCount: fixCount) } label: { S36ATabLabel(tab: .deep) }
                    .badge(fixCount)
            }
        } else {
            TabView(selection: Binding(get: { S36ATabs.shown(pipeline.tab, on: false) }, set: { pipeline.tab = $0 })) {
                Tab(value: AppTab.today) { TodayView() } label: { S30TTabLabel(tab: .today) }
                Tab(value: AppTab.tasks) { TasksTab() } label: { S30TTabLabel(tab: .tasks) }
                    // 確かめ待ちは「今日の候補」（3 件まで・仮）だけを数える（2026-11-24。s24 の 減4）。
                    // 仕事のタスクも今までどおり数える（仕事タブには数字を付けないので、外すと見落とす。2026-11-27。s30。docs/s30-t.md）
                    .badge(taskBadge)
                Tab(value: AppTab.work) { S30WTab() } label: { S30TTabLabel(tab: .work) }  // 仕事タブの中身は S30W 担当（S30WViews.swift）
                Tab(value: AppTab.fix) { FixTab() } label: { S30TTabLabel(tab: .fix) }
                    .badge(fixCount)
                // 記録の上の切り替えに「ふり返り」を入れた（前のふり返りタブの中身。2026-11-27。s30）
                Tab(value: AppTab.records) { RecordsView() } label: { S30TTabLabel(tab: .records) }
            }
        }
    }

    enum FirstRun: String, Identifiable {
        case onboarding, whatsNew
        var id: String { rawValue }
    }
}

/// 知らせから開く画面（シートの中身）
private struct NoticeScreenView: View {
    let screen: NoticeScreen

    var body: some View {
        switch screen {
        case .questions: QuestionsView()
        case .goodThings: GoodThingsView()
        case .money: MoneyView()
        case .cloudLog: CloudLogView()
        case .reviewNudge: ReviewNudgeView()
        case .diagnostics: DiagnosticsView()
        case .homePC: HomePCView()
        case .proposals: ProposalsView()
        case .notices: NoticeHistoryView()
        }
    }
}

/// 知らせの文を読み直す（会う前の1枚。2026-11-12）
private struct NoticeNoteView: View {
    @Environment(Pipeline.self) private var pipeline
    let title: String
    let text: String

    var body: some View {
        LLList {
            Section {
                Text(text).textSelection(.enabled)
            } header: {
                Text(title)
            } footer: {
                Text("知らせで届いた文です。頼まれごと・約束はタスクで片づけられます。")
            }
            Section {
                Button("タスクを開く", systemImage: "checklist") {
                    pipeline.noticeRoute = nil
                    pipeline.tab = .tasks
                }
            }
        }
        .navigationTitle("会う前の1枚")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - どのタブにも置く歯車

/// 右上の歯車で設定（点検と設定）を開く（2026-11-12。前は「今日」と「記録」にだけあった）
struct SettingsGear: ViewModifier {
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("設定", systemImage: "gearshape") { show = true }
                }
            }
            .sheet(isPresented: $show) {
                SettingsView { show = false }
            }
            // どこ？から別のタブ・画面へ行くときは閉じる（2026-11-27。s33 の 強15。S33AViews.swift）
            .onReceive(NotificationCenter.default.publisher(for: .s33aLeave)) { _ in show = false }
    }
}

extension View {
    func settingsGear() -> some View { modifier(SettingsGear()) }
}

/// 長い説明は畳んでおき、押したときだけ出す（2026-11-12。設定と「今日」の説明が長すぎて、中身が下に押し出されていた）
struct HelpNote: View {
    let text: String
    @State private var open = false

    init(_ text: String) { self.text = text }

    var body: some View {
        if open {
            Text(text)
        } else {
            Button {
                withAnimation { open = true }
            } label: {
                Label("説明を読む", systemImage: "info.circle")
            }
            .font(.footnote)
        }
    }
}

// MARK: - 今日

/// 2026-11-13（施策 16）: 答えが先。いちばん上に今日の三つと提案1つ、次に「次の予定の前に」「夜の10秒」「気をつけること」（どれも、あるときだけ）。
/// 録る・印・会議・ライブ字幕は、画面の下の1行にまとめた（どこまでめくっても見えるので、録音はいつも1回押すだけ）。
/// 今日の会話・最近の発言・いまの様子は、畳んだ「今日の記録」の中に移した（なくした働きは無い）
private struct TodayView: View {
    @Environment(Pipeline.self) private var pipeline
    /// 文字がとても大きいときは、下の帯を縦に積む（2026-11-22。s22。文字最大で横にはみ出していた）
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showLive = false
    /// iPad の「読むだけ」で録音ボタンを押した時刻（ボタンの下に 15 秒だけ知らせる。2026-11-29）
    @State private var readerTapAt: Date?
    @State private var showHelp = false
    /// 「今日の記録」を開いているか（いつもは畳む）
    @AppStorage("todayRecordOpen") private var recordOpen = false
    /// ほかのカードを開いているか（いつもは畳む。2026-11-21。s20 の 体7）
    @AppStorage("todayMoreOpen") private var moreOpen = false
    /// 上の 3 枚（録れているか・今日の三つ・今日の 1 問）だけにして、ほかは畳む（2026-11-24。s24 の 形1。初めはオン・設定で戻せる）
    @AppStorage(S24Today.foldKey) private var todayFold = true

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let today = Self.dayFormatter.string(from: .now)
        // 最近の発言が変わる（書き足される）たびに読み直す
        // body-read-ok: 今日の 1 日だけ（アプリが書いたあとは中の写しを使い、ファイルは書いた時刻を見るだけ）
        let talks = pipeline.conversations(on: today)
        let part = DayPart.of(.now)
        NavigationStack {
            LLList {
                // 2026-11-21（s20 の 体7〜10）: 上は大事な 3 つ（録音の丸 3 つ・今日の三つ・確かめ待ちの数）。ほかのカードは畳む。
                // 朝は予定の前と朝のまとめ・1 年前の今日、夜は夜の10秒と今日の問いを上に出す。休日は休日の顔（S20TodayViews.swift）。
                // 2026-11-24（s24 の 形1）: 上は 3 枚（録れているか・今日の三つ・今日の 1 問）と、あるときだけの「気をつけること」。
                // ほかは「ほかのカード」に畳む（設定の「今日は上の 3 枚だけ」を切ると前の並び。並びは S24Today.layout）
                // 2026-11-27（s33 の 強16）: 本人の並び → よく使う 3 つを上・30 日使われないカードは「ほか」へ・畳んだカードは出さない（S33ARules.swift）
                let layout = S33ABook.shared.layout(S24Today.layout(fold: todayFold, part: part))
                ForEach(layout.top) { card($0, talks: talks) }
                S27WTodaySection()  // 「仕事: 宿題 N・会議 N」の 1 行（2026-11-25。s27 の 場2。S27WViews.swift）
                S33ATodaySection()  // 止まっているもの 1 行（2026-11-27。s33 の K33-1。あるときだけ。S33AViews.swift）
                // よく触る設定 3 つ（2026-11-24。s24 の 形2。S24Views.swift）
                // 2026-11-25（s26 の 軽3・軽5・軽11）: よく変える 3 つ（組・場面も）・すきまの 1 件・本人の操作待ち（S26UViews.swift）
                S26UTodaySection(fold: todayFold)
                TodayMoreRow(open: $moreOpen, detail: todayFold
                             ? "休日の顔・予定の前・朝のまとめ・夜の10秒・約束・答え合わせ・返事・下書き・電池 など"
                             : "予定の前・約束・答え合わせ・返事・下書き")
                if moreOpen {
                    ForEach(layout.more) { card($0, talks: talks) }
                    S33ARamenSection()  // ラーメンの 1 押し（2026-11-27。s33 の 強22。家の PC が s33 を持つときだけ。S33AViews.swift）
                }
                recordGroup(today: today, talks: talks)
            }
            .navigationTitle("今日")
            .countsOpen("today")
            .s26uHelp("today")  // 「?」の 2 行と色の意味（2026-11-25。s26 の 軽1）
            .onAppear { S22Launch.todayShown() }  // 開いてから今日の画面まで（2026-11-22。s22 の 楽21）
            .safeAreaInset(edge: .bottom, spacing: 0) { recordBar() }
            // どこ？（画面と機能を探す。2026-11-27。s33 の 強15。S33AViews.swift）
            .toolbar { ToolbarItem(placement: .topBarTrailing) { S33AWhereButton() } }
            // 「使い方」は下の帯へ（2026-11-22。s22 の 見21。片手で届く所）。歯車はどのタブでも右上のまま
            .settingsGear()
            .sheet(isPresented: $showHelp) { TodayHelpView { showHelp = false } }
            .fullScreenCover(isPresented: $showLive) { LiveView { showLive = false } }
        }
    }

    /// 「今日」のカード 1 枚。押した数を数える（今日の並びに使う。2026-11-27。s33 の 強16。S33ABook.cardTapped）
    private func card(_ kind: S24Today.Card, talks: [ConversationLog.Conversation]) -> some View {
        cardBody(kind, talks: talks)
            .simultaneousGesture(TapGesture().onEnded { S33ABook.cardTapped(kind) })
    }

    /// 「今日」のカード 1 枚の中身（中身が無いカードは何も出さない。並びは S24Today.layout。2026-11-24。s24 の 形1）
    @ViewBuilder
    private func cardBody(_ kind: S24Today.Card, talks: [ConversationLog.Conversation]) -> some View {
        switch kind {
        case .hero: TodayHeroSection(talks: talks)
        case .holiday: HolidayFaceSection()
        // (a) 今日の三つと提案1つ（MothershipFeeds.swift）
        case .answer: TodayAnswerCard()
        // 今日の 1 問（聞く物が無ければ「今日は聞くことはありません」。s24 の 形3。S24Views.swift）
        case .ask: S24TodayAskSection()
        // (d) 困ったことがあるときだけ
        case .alerts: alerts()
        case .pcFeature: PCFeatureNotice()
        // いま話したことは約○分で文字に・電池の先回り（2026-11-22。s22 の 楽7・楽19。S22Views.swift）
        case .s22: S22TodaySection()
        // 新しい版・今日の 1 つの確かめ・答えそびれた質問（2026-11-23。s23 の 届4・試5・知13。S23Screens.swift）
        case .s23: S23TodaySection()
        case .prep:
            PrepCardSection()
            S27WPrepSection()  // 次の会議の案件の 1 枚（2026-11-25。s27 の 場8。S27WViews.swift）
            S34APrepSection()  // 会議の前の 1 枚（2026-11-27。s34 の 円4。S34AViews.swift。あるときだけ）
        // 朝の「昨日と今日」（2026-11-09。MorningBrief.swift）
        case .morningBrief: MorningBriefSection()
        case .oneYearAgo: OneYearAgoSection()
        // (c) 夜の10秒（20時から翌朝まで、まだ答えていない日だけ）
        case .nightMood: NightMoodSection()
        // 朝の気分の 1 タップ・今日の問い（2026-11-19。s18。KnowMeViews.swift。あるときだけ）
        case .knowMe: KnowMeTodaySection()
        case .promises: PromisesSection()  // 会話のあとの約束（2026-11-13。Promises.swift。無いときは何も出さない）
        case .checkups: CheckupsSection()  // 1日1分の答え合わせ（2026-11-16。強化案 136。Checkups.swift。問があるときだけ）
        case .replies: RepliesSection()  // 返事・メールの下書き（2026-11-15。強化案 58。DraftActions.swift。無いときは何も出さない）
        // 家の PC が書いている途中の下書き（仮。記録には入れない。2026-11-07。Drafts.swift）
        case .draft: DraftSection()
        case .record: EmptyView()  // 今日の記録はいつも最後（recordGroup）
        }
    }

    /// 録る・印・会議・ライブ字幕を1行に（録音のボタンを大きく。ほかの3つは小さなボタン）
    private func recordBar() -> some View {
        VStack(spacing: 6) {
            // 確かめ待ちと使い方も、親指の届く下に（2026-11-22。s22 の 見21。S22TodayViews.swift）
            TodayReachRow(showHelp: $showHelp)
            let rowLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
            rowLayout {
                recordButton()
                HStack(spacing: 10) {
                Button {
                    pipeline.addMark()
                    LLHaptic.confirm.play()
                } label: {
                    Image(systemName: "star")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("今のところに印を付ける")
                meetingButton()
                Button {
                    showLive = true
                } label: {
                    Image(systemName: pipeline.liveOn ? "captions.bubble.fill" : "captions.bubble")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(pipeline.liveOn ? "ライブ字幕（オン）" : "ライブ字幕")
                }
            }
            .controlSize(.large)  // 親指で押しやすい大きさ（s22 の 見21）
            if let line = barNote() {
                Text(line).font(.caption).foregroundStyle(LL.dim).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func recordButton() -> some View {
        let on: Bool = pipeline.isRecording
        return Button {
            Task {
                await pipeline.toggleRecording()
                // iPad の「読むだけ」では録音が始まらない。知らせの文は畳んだ「今日の記録」の中にしか出ないので、ボタンの下にも出す
                if !pipeline.isRecording && S22Device.isReader {
                    let tap = Date.now
                    readerTapAt = tap
                    Task {
                        try? await Task.sleep(for: .seconds(15))
                        if readerTapAt == tap { readerTapAt = nil }
                    }
                }
                // 振動の型（2026-11-21。s20 の 体21）
                (pipeline.isRecording ? LLHaptic.started : LLHaptic.stopped).play()
            }
        } label: {
            Label(on ? "録音を止める" : "録音を始める", systemImage: on ? "stop.circle.fill" : "record.circle")
                .font(.headline)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.7)  // 大きいボタンでも 1 行に（s22 の 見21。2 行に折れていた）
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(on ? LL.danger : LL.accent)
        .accessibilityLabel(on ? "iPhone の録音を止める" : "iPhone で録音を始める")
    }

    private func meetingButton() -> some View {
        let inMeeting: Bool = pipeline.meeting != nil
        return Button {
            pipeline.setMeeting(!inMeeting)
        } label: {
            Image(systemName: inMeeting ? "person.3.fill" : "person.3")
        }
        .buttonStyle(.bordered)
        .tint(inMeeting ? LL.warn : LL.accent)
        .accessibilityLabel(inMeeting ? "会議モードを終える" : "会議モードを始める")
    }

    /// 下の1行の小さな文（会議中・印を付けた直後だけ）
    private func barNote() -> String? {
        if let tap = readerTapAt, Date.now.timeIntervalSince(tap) < 15 {
            return "iPad は読むだけです。録音は iPhone と時計で（くわしい設定で切れます）"
        }
        if let meeting = pipeline.meeting {
            let title: String = meeting.title.map { "・" + $0 } ?? ""
            return "会議モード中（" + meeting.start.formatted(date: .omitted, time: .shortened) + " から" + title + "）"
        }
        if let mark = pipeline.lastMark, Date.now.timeIntervalSince(mark) < 600 {
            return mark.formatted(date: .omitted, time: .shortened) + " に印を付けました（前後1分の行に★）"
        }
        return nil
    }

    /// 困ったこと（署名の期限・録音を休む場所・止まっているかも・ログインしていない）。無ければ何も出さない
    @ViewBuilder
    private func alerts() -> some View {
        let sign: String? = Provisioning.isNear() ? Provisioning.expiryText() : nil
        // 止まっているかも（2026-11-12。AppFeeds.swift）。家の PC が対応しているときだけ
        let stale: [FreshItem] = pipeline.homePC.features.contains("fresh") ? pipeline.appFeeds.staleItems : []
        let held = pipeline.recordingHeld
        let noLogin = pipeline.email == nil
        // 家の PC と 6 時間やり取りできていない（2026-11-15。強化案 38。PCSilence.swift）
        let pcQuiet: String? = PCSilence.todayLine(configured: pipeline.homePC.isConfigured, last: PCSilence.lastContactNow(), now: .now)
        // 期限が3日以内の決めごと（2026-11-15。強化案 61。PagesFeeds.swift）
        let decisionsDue: [DecisionItem] = PagesBook.shared.dueSoon()
        // 時計の版が iPhone より古いまま 24 時間（仮）。知らせは増やさずここだけ（2026-11-24。s25 の 堅3。S25UViews.swift）
        let watchLag: String? = S25UBook.watchLagLine()
        if sign != nil || held || !stale.isEmpty || noLogin || pcQuiet != nil || !decisionsDue.isEmpty || watchLag != nil {
            // 色の役割は 3 つ: 赤＝いま本人が動く・青＝機械が進めている・灰＝待てば直る（2026-11-24。s24 の 形8。S24Alerts.role）
            Section("気をつけること") {
                DecisionDueRows(items: decisionsDue)
                if let pcQuiet {
                    S24RoleLabel(text: pcQuiet, role: S24Alerts.role(.pcQuiet))
                }
                if let watchLag { S25UWatchLagRow(text: watchLag) }
                if let sign {
                    // 無料の署名は7日で切れ、切れるとアプリが起動しなくなって録音が止まる
                    S24RoleLabel(text: "署名の期限 \(sign)。切れる前に Sideloadly で入れ直してください（記録は消えません）",
                                 role: S24Alerts.role(.signExpiry))
                }
                if held {
                    S24RoleLabel(text: "録音を休む場所にいるので、書くのを休んでいます（出れば戻ります）", role: S24Alerts.role(.held))
                }
                ForEach(stale) { item in
                    S24RoleLabel(text: AppFeeds.freshLine(item), role: S24Alerts.role(.stale))
                }
                if noLogin {
                    S24RoleLabel(text: "右上の歯車（設定）で Google にログインすると、ドキュメントに書き始めます。", role: S24Alerts.role(.noLogin))
                }
            }
        }
    }

    /// 今日の記録（今日の会話・最近の発言・いまの様子）。いつもは畳んでおく
    private func recordGroup(today: String, talks: [ConversationLog.Conversation]) -> some View {
        let summary: String = "会話 \(talks.count)・時計 \(pipeline.watchStatusNow)・待ち \(pipeline.pendingCount)"
        return Section {
            DisclosureGroup(isExpanded: $recordOpen) {
                talkRows(today: today, talks: talks)
                recentRows()
                Text("いまの状態").font(.caption.bold()).foregroundStyle(LL.dim)
                statusRows()
            } label: {
                LabeledContent("今日の記録", value: summary)
            }
        }
    }

    @ViewBuilder
    private func talkRows(today: String, talks: [ConversationLog.Conversation]) -> some View {
        if talks.isEmpty {
            Text("今日の会話はまだありません。録音すると、話の切れ目ごとにここに出ます。").foregroundStyle(LL.dim)
        } else {
            NavigationLink {
                DayView(day: today)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日の会話").font(.caption.bold()).foregroundStyle(LL.dim)
                    ForEach(Array(talks.suffix(8).reversed().enumerated()), id: \.offset) { _, c in
                        Text(ConversationLog.headingText(c))
                            .font(.callout)
                            .lineLimit(2)
                    }
                    if talks.count > 8 {
                        Text("ほか \(talks.count - 8) 件").font(.caption).foregroundStyle(LL.dim)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentRows() -> some View {
        let lines: [String] = Array(pipeline.lastLines.suffix(8).reversed())
        if !lines.isEmpty {
            Text("最近の発言").font(.caption.bold()).foregroundStyle(LL.dim)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout)
            }
        }
    }

    /// いまの様子（時計・マイク・待ち・抜け）
    @ViewBuilder
    private func statusRows() -> some View {
        LabeledContent("時計", value: pipeline.watchStatusNow)
        // iPhone で録っているマイク（外付けのマイクをつないだとき。2026-11-07。MicInput.swift）
        if pipeline.isRecording {
            LabeledContent("iPhone のマイク", value: MicRoute.shared.text)
        }
        if let last = pipeline.watchDelays.entries.last {
            NavigationLink {
                WatchDelayView()
            } label: {
                LabeledContent("時計の遅れ", value: LLNumber.humanize("直近 " + WatchDelayLog.text(last.arrival)))
            }
        }
        LabeledContent("文字起こし待ち", value: LLNumber.count(pipeline.pendingCount) + " 件")
        NavigationLink {
            RecordingMapView()
        } label: {
            let gaps = pipeline.ledger.map(for: Calendar.current.startOfDay(for: .now)).gaps
            LabeledContent("録音の抜け（今日）", value: gaps.isEmpty ? "なし" : "\(gaps.reduce(0) { $0 + $1.minutes })分")
        }
        if !pipeline.lastEngine.isEmpty {
            LabeledContent("直近の文字起こし", value: pipeline.lastEngine)
        }
        if !pipeline.message.isEmpty {
            Text(pipeline.message).foregroundStyle(LL.dim)
        }
    }
}

// 「今日」の使い方（前は画面の途中に長い説明として出していたもの）
private struct TodayHelpView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            LLList {
                Section("下のタブ") {
                    Text("今日: いちばん上に今日の三つと提案。録る・印・会議・ライブ字幕は画面の下の1行です。今日の会話といまの状態は「今日の記録」を開くと出ます。困ったことがあるときだけ「気をつけること」が出ます。")
                    Text("タスク: 仕事以外のやること・約束。タブの数字は仕事の分も入れた数です。")
                    Text("仕事: 案件の状況・仕事のタスク。職場の Claude の答え（仕事のまとめ）もここから取り込みます。")
                    Text("直す: AI からの質問・名前を付ける声・聞き間違いなど、答えると記録が正しくなるもの。タブの数字がたまっている数です。")
                    Text("記録: 言葉や名前で探す・日ごとに読む。上の切り替えで、人・場所・お金と、ふり返り（数のグラフ・物語・いいこと帳・話し方など）も見られます。")
                    Text("設定と点検は、どのタブでも右上の歯車から開きます。")
                }
                Section("印と会議モード") {
                    Text("時計で録音中は、時計の「★ 印」ボタン（またはダブルタップ）でも印を付けられます。会議モードは時計の「会議」ボタンでも始められます（予定の参加者と題名を聞き取りのヒントにし、時計の音質を上げ、終わったらすぐ議事録にします）。")
                }
                Section("ライブ字幕") {
                    Text("オンにしている間だけ、iPhone のマイクの声を話の切れ目ごとに iPhone 内の Haas-ja で文字にして流します（モデルを入れていなければ Groq）。字幕は仮で、記録にはいつも通り区切りごとの文字起こしが書かれます。アプリを閉じて10分たつと自動でオフになります。")
                }
                Section("直す") {
                    Text("1日に上から5つまでで十分です（5分ほど）。残りは明日に回して大丈夫です。直すほど、聞き分けと聞き取りが正確になります。")
                }
                // 2026-11-15（強化案 48）: 迷ったときの早見
                Section("こういうときはこれ") {
                    Text("あとで正確に残したい会話 → 会議モード（仕事でもプライベートでも）")
                    Text("記録のどこかに書いてあることを聞きたい → 記録に質問する（家の PC の記録も探す）")
                    Text("人・欲しい物・決めたことを聞きたい → 記録に質問する（欲しい物リスト・決めごと・人のノートも読みます）")
                    Text("何日もまたいで考えてほしいこと → Claude Code に聞く")
                    Text("払った記録を残したい → ウォレットのショートカット。PayPay はスクショ")
                    Text("あとで見返したい瞬間 → 時計の「★ 印」")
                }
            }
            .navigationTitle("使い方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
            }
        }
    }
}

// MARK: - ライブ字幕（「今日」のボタンから全画面で開く）

private struct LiveView: View {
    @Environment(Pipeline.self) private var pipeline
    let onClose: () -> Void
    @State private var visible = false

    var body: some View {
        let live = pipeline.live
        NavigationStack {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { pipeline.liveOn },
                    set: { on in Task { await pipeline.setLive(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ライブ字幕").font(.headline)
                        Text(statusText(live)).font(.caption).foregroundStyle(LL.dim)
                    }
                }
                .padding()
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(live.lines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(line.time.formatted(date: .omitted, time: .shortened))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(LL.dim)
                                    // ライブの文は仮（2026-11-06）。タスク・要約・記録には使わず、記録には多数決のあとの確定した文が入る
                                    Text("仮").font(.caption2).padding(.horizontal, 4)
                                        .background(LL.dim.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                    Text(line.text).font(.title3).foregroundStyle(.primary.opacity(0.8))
                                }
                                .id(line.id)
                            }
                        }
                        .padding()
                    }
                    .overlay {
                        if live.lines.isEmpty {
                            ContentUnavailableView(
                                "ライブ字幕", systemImage: "captions.bubble",
                                description: Text("オンにしている間だけ、iPhone のマイクの声を話の切れ目ごとに iPhone 内の Haas-ja で文字にして、ここに流します（モデルを入れていなければ Groq）。記録にはいつも通り区切りごとの文字起こしが書かれます。アプリを閉じて10分たつと自動でオフになります。"))
                        }
                    }
                    .onChange(of: live.lines.count) {
                        if let last = live.lines.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("ライブ字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる", action: onClose) }
                if !live.lines.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("消す", systemImage: "trash") { live.clear() }
                    }
                }
            }
        }
        // ライブを見ている間は画面を消さない
        .onAppear { visible = true; keepAwake() }
        .onDisappear { visible = false; keepAwake() }
        .onChange(of: pipeline.liveOn) { keepAwake() }
    }

    private func statusText(_ live: LiveTranscriber) -> String {
        guard pipeline.liveOn else { return "オフ" }
        if !live.status.isEmpty { return live.status }
        if live.waiting > 0 { return "文字にしています…" }
        return live.hearing ? "聞いています…" : "声を待っています"
    }

    private func keepAwake() {
        UIApplication.shared.isIdleTimerDisabled = visible && pipeline.liveOn
    }
}

// MARK: - 記録

/// 探す・読む。上の切り替えで 日ごと｜人｜場所｜お金（2026-11-12。前の「人と場所」タブと、行ったお店の奥の支払いをここにまとめた）｜
/// ふり返り（2026-11-27。s30 で前のふり返りタブを統合。切り替えは 1 段のまま右に足し、検索は今どおり「日ごと」の上）
struct RecordsView: View {
    /// 日ごと｜人｜場所｜お金｜ふり返り（2026-11-27。s30 で前のふり返りタブの中身を右に足した。S30TTabs.swift）
    typealias Page = S30TTabs.RecordsPage

    /// 最後に見ていた切り替えを覚える（知らせ・リンクで前のふり返りを開いたときは「ふり返り」が入る）
    @AppStorage(S30TTabs.recordsPageKey) private var page = Page.days

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case .days: DaysPage()
                case .people: PeoplePage()
                case .places: PlacesPage()
                case .money: MoneyView()
                case .lookBack: LookBackPage()  // 数の小さなグラフ・物語・休日のページ・検品表・月の 1 枚など（LookBackViews.swift）
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("見る", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .settingsGear()
        }
    }
}

/// 日ごと（と、言葉や名前で探す）
private struct DaysPage: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var days: [String] = []
    @State private var query = ""
    @State private var hits: [Pipeline.Hit] = []
    /// 意味で探す（家の PC の索引。2026-11-07。前は入口の無い「記録を探す」の画面にあった）
    @AppStorage("searchByMeaning") private var byMeaning = false
    @State private var searching = false

    private var meaningOn: Bool { byMeaning && pipeline.homePC.features.contains("semantic") }

    var body: some View {
        LLList {
            if query.count >= 2 {
                if pipeline.homePC.features.contains("semantic") {
                    Toggle("意味で探す（家の PC。検索を押したとき）", isOn: $byMeaning)
                }
                if searching { ProgressView() }
                // タスクも探す（2026-11-06）
                let tasks = pipeline.tasks.items.filter { item in
                    item.what.localizedCaseInsensitiveContains(query)
                        || (item.quote ?? "").localizedCaseInsensitiveContains(query)
                        || (item.from ?? "").localizedCaseInsensitiveContains(query)
                }
                if !tasks.isEmpty {
                    Section("タスク") {
                        ForEach(tasks.prefix(10)) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.what)
                                Text([item.from, item.due.map { Pipeline.taskDueText($0) }, item.state == .done ? "済み" : nil]
                                    .compactMap { $0 }.joined(separator: "・"))
                                    .font(.caption).foregroundStyle(LL.dim)
                            }
                        }
                    }
                }
                // 仕事のまとめも探す（2026-11-10。行を探すだけで、言語モデルは使わない）
                let digests: [Pipeline.DigestHit] = Pipeline.searchWorkDigests(query, in: pipeline.workDigests.sorted, limit: 10)
                if !digests.isEmpty {
                    Section("仕事のまとめ") {
                        ForEach(digests) { DigestHitRow(hit: $0) }
                    }
                }
                if hits.isEmpty && tasks.isEmpty && digests.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(hits) { HitRow(hit: $0) }
                }
            } else {
                // 本人が畳んだ入口は「ほか」へ（2026-11-24。s24 の 減12。S24Views.swift。戻せる）
                let entries = S24Entry.split(list: "records", available: ["ask", "unifiedSearch", "dayBand"])
                if !entries.shown.isEmpty {
                    Section {
                        if entries.shown.contains("ask") {
                            NavigationLink {
                                AskView()
                            } label: {
                                Label("記録に質問する", systemImage: "questionmark.bubble")
                            }
                        }
                        // 探す窓を 1 つに・1 日の帯で選ぶ（2026-11-21。s20 の 体28〜30・次11・次12。S20RecordViews.swift）
                        if entries.shown.contains("unifiedSearch") {
                            NavigationLink {
                                UnifiedSearchView()
                            } label: {
                                Label("探す（人・場所・日・言葉・質問）", systemImage: "magnifyingglass")
                            }
                        }
                        if entries.shown.contains("dayBand") {
                            NavigationLink {
                                DayBandView(day: Date.now)
                            } label: {
                                Label("1 日の帯で選ぶ（消す・書き出す・印）", systemImage: "slider.horizontal.below.rectangle")
                            }
                        }
                    }
                }
                S24OtherSection(other: entries.other)
                Section("日ごと") {
                    if days.isEmpty {
                        Text("文字起こしが終わると、ここに日ごとに出てきます。").foregroundStyle(LL.dim)
                    }
                    ForEach(days, id: \.self) { day in
                        NavigationLink(day) { DayView(day: day) }
                    }
                }
                // アプリの記録が無く、PLAUD の写しだけがある日（2026-11-13。HomeFeeds.swift。読むだけ）
                let plaudOnly = pipeline.homeFeeds.fillOnlyDays(recorded: days)
                if !plaudOnly.isEmpty {
                    Section {
                        ForEach(plaudOnly, id: \.self) { day in
                            NavigationLink(day) { PlaudOnlyDayView(day: day) }
                        }
                    } header: {
                        Text("PLAUD だけの日")
                    } footer: {
                        Text("アプリの記録が無い日の、PLAUD の文字起こしです（読むだけ）。")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "言葉や名前で探す")
        .onSubmit(of: .search) { run() }
        .onChange(of: query) {
            if query.count < 2 { hits = [] } else if !meaningOn { hits = pipeline.search(query) }
        }
        .onChange(of: byMeaning) { if query.count >= 2 { run() } }
        .navigationTitle("記録")
        .countsOpen("recordsDays")  // 開いた回数（2026-11-13。施策 17）
        .s26uHelp("recordsDays")
        .onAppear { days = pipeline.recordedDays() }
        .refreshable { days = pipeline.recordedDays() }
        // ほかの端末から記録が届いたら出し直す
        .onChange(of: pipeline.recordsVersion) { days = pipeline.recordedDays() }
    }

    /// 探す。意味で探すときは、検索を押したときと切り替えたときだけ家の PC に聞く
    private func run() {
        guard query.count >= 2 else { return }
        guard meaningOn else {
            hits = pipeline.search(query)
            return
        }
        let asked = query
        searching = true
        Task {
            let found = await pipeline.semanticSearch(asked)
            searching = false
            guard asked == query else { return }
            hits = found
        }
    }
}

/// 人（話した相手。聞き分けが切なら、入れる所だけ）
struct PeoplePage: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        if pipeline.speakerLabelsOn {
            PeopleView()
        } else {
            LLList {
                PeoplePagesSection()  // 人のページ（2026-11-15。強化案 53。聞き分けが切でも見られる）
                // 切り替えは設定（くわしい設定の「話者」）だけに置く（2026-11-13。施策 18。同じものへの入口は1つ）
                Section {
                    LabeledContent("話している人を聞き分ける", value: "オフ")
                    NavigationLink("設定で切り替える") { DetailedSettingsView() }
                } footer: {
                    Text("オンにすると、記録の行に「[自分]」「[人物1]」などを付け、ここに話した相手が並びます（iPhone の中だけで比べます）。")
                }
            }
            .navigationTitle("人")
        }
    }
}

/// 場所（登録した場所・行ったお店）
private struct PlacesPage: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let week = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        LLList {
            Section {
                if pipeline.places.isOn {
                    NavigationLink {
                        PlacesView()
                    } label: {
                        LabeledContent("登録した場所", value: "\(pipeline.places.places.count) か所")
                    }
                } else {
                    // 切り替えは設定（くわしい設定の「会話のまとめ」）だけに置く（2026-11-13。施策 18）
                    LabeledContent("場所を記録する", value: "オフ")
                    NavigationLink("設定で切り替える") { DetailedSettingsView() }
                }
            } footer: {
                Text("職場にした場所では、職場の人の声と職場の言葉で照らし合わせます。")
            }
            Section {
                // 1 日の道のりと行った所を地図で（2026-11-16。強化案 103。PlaceMapViews.swift）
                NavigationLink {
                    PlaceMapView()
                } label: {
                    Label("地図で見る", systemImage: "map")
                }
            }
            PlacePagesSection()  // 行った場所のページ（2026-11-15。強化案 55。PagesFeeds.swift。写しがあるときだけ）
            Section {
                // 行ったお店（2026-11-08。ShopVisitViews.swift）
                NavigationLink {
                    ShopVisitsView()
                } label: {
                    let n = pipeline.shopVisits.visits.filter { $0.arrival >= week }.count
                    LabeledContent("行ったお店", value: pipeline.shopVisits.isOn ? "この7日で \(n) 件" : "オフ")
                }
            } footer: {
                Text("お店で払ったものは、上の「お金」に並びます。")
            }
        }
        .navigationTitle("場所")
    }
}

// MARK: - 設定

/// 歯車から開く。上の切り替えで「点検」（毎日見る・調子を確かめる）と「設定」（ふだん触らない）に分ける（2026-11-12。前は1本の長い一覧）
private struct SettingsView: View {
    enum Part: String, CaseIterable, Identifiable {
        case check = "点検", setup = "設定"
        var id: String { rawValue }
    }

    @Environment(Pipeline.self) private var pipeline
    /// 最後に開いた方を覚える
    @AppStorage("settingsPart") private var part = Part.check
    private let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }
    @AppStorage(AppLock.key) private var appLock = false
    @AppStorage(ClaudeRoute.useKey) private var useClaude = true
    @AppStorage(ClaudeRoute.workKey) private var claudeForWork = true
    /// 引き算の版（設定・点検を少なく見せる。初めはオン。2026-11-24。s25 の 大1。S25UViews.swift）
    @AppStorage(S25USimple.key) private var simple = true

    var body: some View {
        NavigationStack {
            LLList {
                S33ASettingsTopSection()  // どこ？（画面と機能を探す。2026-11-27。s33 の 強15。S33AViews.swift）
                S36ASettingsTopSection()  // よく使う設定（K36-1 の nav.settings_top。無ければ出さない。2026-11-28。s36 の 大3。S36AViews.swift）
                Section {
                    Picker("見る", selection: $part) {
                        ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                // 本人の操作待ち・機械がしたこと（届いているときだけ。2026-11-25。s26 の 軽5・軽9。S26UViews.swift）
                S26USettingsTopSection()
                if part == .check {
                    checkPage()
                } else {
                    everydayPage()
                }
            }
            .navigationTitle(part == .check ? "点検" : "設定")
            .countsOpen("settings")  // 開いた回数（2026-11-13。施策 17）
            .s26uHelp("settings")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
                }
            }
        }
    }

    /// 点検（毎日見るもの・調子が悪いとき）
    @ViewBuilder
    private func checkPage() -> some View {
        S34ACheckSection()  // 自動で直した数の 1 枚（2026-11-27。s34。S34AViews.swift。あるときだけ）
        if simple {
            // 引き算の版: 自己点検・聞き取りの成績・報告の棚と「ほかの点検」だけ（ほかは S25UMoreCheckView。消していない）
            S25UCheckMainSection()
        } else {
            fullCheckPage()
        }
    }

    /// s24 までの点検の並び
    @ViewBuilder
    private func fullCheckPage() -> some View {
        Section {
            NavigationLink("自己点検（実機で動いたか・画面を開いた回数も）") { DiagnosticsView() }
            NavigationLink("聞き取りの成績") { ListenQualityView() }
            NavigationLink("録音の抜けと数の照合") { RecordingMapView() }
            if !pipeline.watchDelays.entries.isEmpty {
                NavigationLink("時計の遅れ") { WatchDelayView() }
            }
            NavigationLink("クラウドに送ったもの") { CloudLogView() }
        } header: {
            Text("調子")
        } footer: {
            Text("調子が悪いときは「自己点検」から。")
        }
        // 時計の声から自分の声・見直したい声を ○× で（2026-11-22。s21 の 使7・使8）
        S21CheckSection()
        // 報告の棚・いつも録れない所・時計の LifeLog を新しくする（2026-11-22。s22 の 楽5・楽10・楽20。S22Views.swift）
        S22CheckSection()
        // 実機でまだ確かめていない新しい動き（2026-11-10。Checklist.swift。前は「今日」に出していた）
        ChecklistSection()
        // 精度の通信簿・あまり開かれていない画面（2026-11-13。施策 12・21。MothershipFeeds.swift）
        MothershipCheckSection()
        // 反映の見張り（2026-11-14。強化案 34。OneTimelineViews.swift）
        ReflectionCheckSection()
        // 入れた施策の様子・Claude の費用（2026-11-15。強化案 36・37。SettleFeeds.swift）
        SettleCheckSection()
        SettingsBackupSection()
    }

    /// 設定の「ふだん」（本人がふだん触るものだけ。2026-11-13。施策 18）と、ほかの全部の入口「くわしい設定」
    @ViewBuilder
    private func everydayPage() -> some View {
        if simple {
            // 引き算の版: 場面のセット・設定を探す・Face ID と Claude・くわしい設定と「ほかの設定」だけ（ほかは S25UMoreSettingsView）
            S20SettingsSection(showRest: false)
            S22SettingsEntrySection()
            S27WSettingsSection()  // 仕事の画面（伏せる・社内のお知らせ。2026-11-25。s27 の 守2・他3）
            S34APhotoSettingsSection()  // 写真から仕事のまとめを拾う（初めはオフ。2026-11-27。s34 の 円1。S34AViews.swift）
            Section {
                Toggle("開くときに Face ID", isOn: $appLock)
                Toggle("Claude を使う", isOn: $useClaude)
                    .onChange(of: useClaude) { _, _ in ClaudeRoute.resetPauses() }
            } header: {
                Text("ふだん")
            } footer: {
                Text("Face ID をオンにすると、アプリが前に出るたびに確かめるまで記録を隠します（録音と文字起こしは続きます）。")
            }
            S25USimpleSection(simple: $simple)
            detailedLink()
        } else {
            fullEverydayPage()
        }
    }

    private func detailedLink() -> some View {
        Section {
            NavigationLink {
                DetailedSettingsView()
            } label: {
                Label("くわしい設定", systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text("Google ドライブ・同期・Apple Watch・文字起こし・話者・言語モデル・音声・ほかのアプリとつなぐ、など。")
        }
    }
}

/// 控えと掃除（点検のいちばん下。引き算の版では「ほかの点検」の中。2026-11-24 に SettingsView から分けた）
struct SettingsBackupSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var exportNote: String?

    var body: some View {
        Section {
            NavigationLink("登録の控え") { BackupView() }
            NavigationLink("記録の掃除") { CleanupView() }
            Button("今年の分を書き出す") {
                exportNote = "書き出しています…"
                Task {
                    do {
                        let names = try await pipeline.exportYear(Calendar.current.component(.year, from: .now))
                        exportNote = "ドライブの「控え」に置きました: " + names.joined(separator: "、")
                    } catch {
                        exportNote = "書き出せませんでした: \(error.localizedDescription)"
                    }
                }
            }
            .disabled(pipeline.email == nil)
            if let exportNote { Text(exportNote).font(.caption).foregroundStyle(LL.dim) }
        } header: {
            Text("控えと掃除")
        } footer: {
            HelpNote("人・声・言葉の登録は毎日「登録の控え」に残しています。書き出しは、その年の会話・人・タスクを Markdown（読む用）と JSON（プログラム用・中身の説明つき）にします。年が変わると前の年の分を自動で書き出します。")
        }
    }

}

extension SettingsView {
    /// s24 までの設定の並び（設定の「ふだん」と「くわしい設定」の入口）
    @ViewBuilder
    fileprivate func fullEverydayPage() -> some View {
        // 場面のセット・見た目・寝ているあいだ・知らせ・説明（2026-11-21。s20 の 体31〜37。S20SettingsViews.swift）
        S20SettingsSection()
        // 設定を探す・変えた所だけ・初めに戻す（2026-11-22。s22 の 楽8・楽9。S22Views.swift）
        S22SettingsEntrySection()
        // 電池優先・早さ優先・精度優先（2026-11-22。s21 の 使1。S21Views.swift）
        S21PresetSection()
        Section {
            Toggle("開くときに Face ID", isOn: $appLock)
            // 朝の「昨日と今日」の知らせと時刻（MorningBrief.swift）
            MorningBriefSettingsRows()
            // 夜の10秒の知らせと時刻（初めはオフ。MothershipFeeds.swift）
            NightMoodSettingsRows()
            // Claude（家の PC 経由。Claude.swift）
            Toggle("Claude を使う", isOn: $useClaude)
                .onChange(of: useClaude) { _, _ in ClaudeRoute.resetPauses() }
            Toggle("職場の会話も Claude で", isOn: $claudeForWork)
                .disabled(!useClaude)
                .onChange(of: claudeForWork) { _, _ in ClaudeRoute.resetPauses() }
        } header: {
            Text("ふだん")
        } footer: {
            Text("Face ID をオンにすると、アプリが前に出るたびに確かめるまで記録を隠します（録音と文字起こしは続きます）。")
        }
        // 休日の知らせ・時計の外出モード・映画館で休む（2026-11-21。s19。Holiday.swift）
        HolidaySettingsSection()
        // 写真から仕事のまとめを拾う（初めはオフ。2026-11-27。s34 の 円1。S34AViews.swift）
        S34APhotoSettingsSection()
        // 引き算の版に戻すスイッチ（2026-11-24。s25 の 大1）
        S25USimpleSection(simple: $simple)
        detailedLink()
    }
}

/// くわしい設定（ふだん触らないもの。2026-11-13 に「設定」から分けた。記録の「人」「場所」の切り替えも、ここが入口）
struct DetailedSettingsView: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage("morningCheck") private var morningCheck = true
    @AppStorage(Storage.japanTimeKey) private var japanTime = false
    @AppStorage("secondOpinion") private var secondOpinion = false
    @AppStorage(Summarizer.pcLLMKey) private var pcLLMForWork = false
    /// LocalModel.modeKey と同じ名前
    @AppStorage("localModelMode") private var localModelMode = LocalModel.Mode.fallback.rawValue
    @AppStorage(Pipeline.autoAsideKey) private var autoAside = true

    var body: some View {
        LLList {
            S33ADeepLinkSection()  // 使われ方・畳む候補・問いのふた・家の PC の棚（2026-11-27。s33。S33AViews.swift）
            sections(pipeline.settings)
            S26USwitchesSection()  // s26 の見せ方の切り替え（2026-11-25。S26UViews.swift）
        }
        .navigationTitle("くわしい設定")
        .countsOpen("detailedSettings")
        .s24CountsTouches()  // 触った設定を数える（2026-11-24。s24 の 形2。S24Views.swift）
    }

    @ViewBuilder
    private func sections(_ source: TranscriptionSettings) -> some View {
        @Bindable var settings = source
                // 守り（2026-11-06）
                Section {
                    Toggle("毎朝、前の日の点検を知らせる", isOn: $morningCheck)
                    Toggle("もう1つの言語モデルでも見比べる（充電中か開いているとき）", isOn: $secondOpinion)
                    // 2026-11-06
                    Toggle("職場の会話は、家の PC の言語モデルで作る（PC に Ollama があるとき）", isOn: $pcLLMForWork)
                    NavigationLink("有料の票（ElevenLabs）") { PaidVoteView() }
                    Toggle("日付と時刻を日本時間で（海外にいるとき）", isOn: $japanTime)
                    if japanTime != Storage.japanTimeApplied {
                        Text("アプリを一度終えて開き直すと変わります。").font(.caption).foregroundStyle(LL.warn)
                    }
                } header: {
                    Text("守り")
                } footer: {
                    Text("Face ID と朝の知らせは、「設定」のいちばん上の「ふだん」にあります。")
                }

                Section("Google ドライブ") {
                    if let email = pipeline.email {
                        LabeledContent("ログイン中", value: email)
                        Button("ログアウト", role: .destructive) { pipeline.signOut() }
                    } else {
                        Button("Google でログイン") { Task { await pipeline.signIn() } }
                    }
                }

                Section {
                    Toggle("iPhone と iPad で同じ記録にする", isOn: Binding(
                        get: { pipeline.sync.isOn },
                        set: { pipeline.sync.isOn = $0 }))
                    if pipeline.sync.isOn {
                        LabeledContent("最後に合わせた時刻",
                                       value: pipeline.sync.lastSynced?.formatted(date: .abbreviated, time: .shortened) ?? "まだ")
                        if !pipeline.sync.lastReceived.isEmpty {
                            LabeledContent("前回ほかの端末から届いたもの", value: pipeline.sync.lastReceived)
                        }
                        Button(pipeline.sync.running ? "合わせています…" : "今すぐ合わせる") {
                            Task { await pipeline.syncNow() }
                        }
                        .disabled(pipeline.sync.running || pipeline.email == nil)
                        if let problem = pipeline.sync.problem {
                            Text(problem).font(.footnote).foregroundStyle(LL.danger)
                        }
                        // 版が古い相手を外す・戻す（2026-11-22。s21 の 使9）
                        S21SyncPeersRows()
                    }
                } header: {
                    Text("iPhone と iPad の同期")
                } footer: {
                    HelpNote("同じ Google アカウントでログインした iPhone と iPad で、記録・話した相手（名前と登録した声）・言葉の登録・場所を、ドライブの「LifeLog/同期」フォルダを通して合わせます。アプリを開いたときと、文字起こしのあと（3分おきまで）に合わせます。\n「ここでは録音を休む」と、自動で覚えた声は端末ごとのままです。1日のまとめ・人物ノート・週のまとめ・AI 向けの索引は、iPhone が両方の分をまとめて書きます。\n初めて合わせる前に、今の記録と登録をアプリの中に一度だけ控えておきます。")
                }

                // 時計の版（iPhone と時計の版を並べる。違えば 1 行と手順。知らせはしない。2026-11-27。s33 の 強27。S33AViews.swift）
                S33AWatchSection()

                Section {
                    Toggle("待機モード", isOn: Binding(
                        get: { pipeline.standbyOn },
                        set: { pipeline.standbyOn = $0 }))
                    Toggle("録音が止まったら知らせる", isOn: Binding(
                        get: { pipeline.stopAlertsOn },
                        set: { pipeline.stopAlertsOn = $0 }))
                    Toggle("音がしないあいだは書かない", isOn: Binding(
                        get: { pipeline.skipSilence },
                        set: { pipeline.skipSilence = $0 }))
                    // 時計の区切りのうち、物音だけで声らしい音の無いものは送らない（2026-11-16。VoiceGate）
                    Toggle("時計で声の無い区切りは送らない", isOn: Binding(
                        get: { pipeline.dropNoVoice },
                        set: { pipeline.dropNoVoice = $0 }))
                    Picker("区切りの長さ", selection: Binding(
                        get: { pipeline.chunkLength },
                        set: { pipeline.chunkLength = $0 })) {
                        ForEach(ChunkCutter.Length.allCases, id: \.self) { length in
                            Text(length.label).tag(length)
                        }
                    }
                    // 時計の電池が少ないあいだは、自動で5分の区切りにする（2026-11-07）
                    if pipeline.chunkLength == .short {
                        Toggle("電池が少ないときは5分に", isOn: Binding(
                            get: { pipeline.chunkBatterySaver },
                            set: { pipeline.chunkBatterySaver = $0 }))
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pipeline.standbyOn
                             ? "時計が録音しているあいだだけ無音を流してアプリを起こしておき、時計の録音を区切りごとにすぐ文字起こしします。電池を少し多く使います。"
                             : "時計の録音は、アプリを開いたときや充電中にまとめて文字起こしします。")
                        HelpNote("「音がしないあいだは書かない」をオンにすると、時計と iPhone で1分続けて静かなときは録音ファイルに書かず、音がしたらその2.5秒前から書き始めます（マイクは聞き続けます）。無音を送ったり文字にしたりしないぶん、電池が長持ちします。\n「区切りの長さ」は、録音を区切って送る長さです。短め（初め）は45秒を過ぎた話の切れ目で区切り、長くても2分で区切るので、文字になるまでが早くなります。ふつうは今までどおり5分ほどで区切ります（送る回数が少ないぶん、時計の電池が少し長持ちします）。どちらも次の区切りから変わります。\n「電池が少ないときは5分に」をオンにすると（初めはオン）、時計の電池が 30% より少ないときと低電力モードのあいだは、短めの設定でも時計が自動で5分ごとに区切ります。電池が 35% まで戻るか充電を始めると、短めに戻ります。いま5分にしているかは、時計の画面と自己点検に出ます。時計の設定は、時計と iPhone がつながったときに伝わります。")
                    }
                }

                // 録り方の実験（2026-11-15。強化案 47。RecordingExperimentViews.swift）
                RecordingExperimentSection()

                // 時計の守りと実験（寝ている時間の 5 分・強い守り・便りが途切れたら・直接送るの実験・振って送る。2026-11-22。s21）
                S21WatchSettingsSection()
                // 1 時間ごとの実験・袖でこもった音・電車の 3 問・誰と話した？・iPad は読むだけ（2026-11-22。s22。S22Views.swift）
                S22WatchSettingsSection()
                // 録音が止まらない（音が止んだら戻す・電話・見回り・肩代わり・前の動きに戻す・中断の練習。2026-11-23。s23。S23Resume.swift）
                S23RecSettingsSection()

                // 外付けマイク（2026-11-07。MicViews.swift）
                MicSettingsSection()

                // 会話の横に、その時間に撮った写真を出す（2026-11-07。DayPhotos.swift）
                DayPhotoSettingsSection()

                // 取るデータと入口（体重・端末の合図・曲・予定で録り方・実績・検索。2026-11-25。s26 の A1。S26AViews.swift）
                S26ASettingsLinkSection()

                Section {
                    NavigationLink {
                        HomePCView()
                    } label: {
                        LabeledContent("家の PC（多数決）", value: pipeline.homePC.isConfigured ? "使用中" : "オフ")
                    }
                    NavigationLink {
                        HaasView()
                    } label: {
                        LabeledContent("iPhone 内の Haas-ja", value: pipeline.haas.isUsable ? "使用中" : "オフ")
                    }
                    Toggle("高精度で文字起こし", isOn: $settings.useCloud)
                        .disabled(!settings.hasAPIKey)
                    Toggle("誤変換を言語モデルで直す", isOn: Binding(
                        get: { pipeline.correctionOn },
                        set: { pipeline.correctionOn = $0 }))
                        .disabled(pipeline.llmKey == nil)
                    NavigationLink("サービスと API キーの設定") {
                        TranscriptionSettingsView(settings: settings)
                    }
                } header: {
                    Text("文字起こし")
                } footer: {
                    if !settings.hasAPIKey {
                        Text("API キーを登録すると、クラウドの高精度モデルで文字起こしできます（Groq なら無料）。")
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
                        Picker("聞き分けの厳しさ", selection: Binding(
                            get: { pipeline.speakerStrictness },
                            set: { pipeline.speakerStrictness = $0 })) {
                            ForEach(SpeakerLabeler.Strictness.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle("食い違った声を自動で外す", isOn: $autoAside)
                        // 名前付けの山のしぼり・もう聞かない人を戻す（2026-11-27。s29 の 声18・声21。S29NViews.swift）
                        NavigationLink("名前付けの山・もう聞かない人") { S29NSettingsView() }
                    }
                } header: {
                    Text("話者")
                } footer: {
                    HelpNote("iPhone の中だけで声の特徴を比べ、行に「[自分]」「[人物1]」などを付けます（無料）。別の人が同じ名前になるときは「厳しめ」、同じ人が何人にも分かれるときは「ゆるめ」にしてください。「食い違った声を自動で外す」は、覚えた声のひとこまが記録ではほかの人やテレビの行だったとき、見直しを待たずに聞き分けに使わないようにします（消さずに、人の画面から戻せます）。")
                }

                Section {
                    Toggle("会話ごとの見出しと1日のまとめ", isOn: Binding(
                        get: { pipeline.summariesOn },
                        set: { pipeline.summariesOn = $0 }))
                        .disabled(pipeline.llmKey == nil)
                    Toggle("場所を記録する", isOn: Binding(
                        get: { pipeline.places.isOn },
                        set: { pipeline.places.isOn = $0 }))
                } header: {
                    Text("会話のまとめ")
                } footer: {
                    HelpNote("話が3分途切れるごとに、ドキュメントに「時刻・場所・相手・内容」の見出しと要点を付け、日が変わると前の日の先頭に「1日のまとめ」を入れます（家の PC 経由の Claude。使えないときは Groq の無料枠か、iPhone の中の言語モデル）。家の PC が作った1日のまとめ（会話・LINE・メモをまとめたもの）が届いた日は、そちらを先頭に載せます（1日に1回・iPhone だけ。アプリのまとめは週と月のまとめに使います）。")
                }

                Section {
                    Picker("iPhone の中の言語モデル", selection: $localModelMode) {
                        ForEach(LocalModel.Mode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    LabeledContent("この iPhone", value: LocalModel.status.text)
                } header: {
                    Text("言語モデル")
                } footer: {
                    HelpNote("見出し・要点・まとめ・誤変換直し・聞き間違い探し・記録への質問は、まず家の PC を通して Claude に頼みます（下の「Claude（家の PC 経由）」。数の多い仕事は軽いモデル、まとめ・議事録・質問の答えは標準のモデル）。Claude に頼めないとき（PC につながらない・今月の上限・鍵が無い）は、今までどおり Groq、Apple の iPhone の中の言語モデル（Apple Intelligence）、家の PC の言語モデルで作ります。iPhone の中のモデルは無料で上限が無く、中身を外に送りません。Groq の大きいモデルより賢くなく、長い会話は頭と終わりだけを読むことがあります。「Groq が使えないときだけ」は、キーが無い・無料枠を使い切った・混んでいる・通信できないときの代わり。「職場の会話は端末内で」は、職場にいた時間の会話を Groq に送りません（「職場の会話も Claude で」がオンのあいだは、職場の会話も先に Claude に頼みます）。「いつも端末内で」は、Claude にも Groq にも送りません。")
                }

                // Claude（家の PC 経由。2026-11-13。Claude.swift）
                // スイッチの2つは「ふだん」にある。ここは今月使った額など
                ClaudeSettingsSection(showSwitches: false)
                PromiseSettingsLink()  // 「会話のあとに約束を知らせる」（2026-11-13。Promises.swift）

                Section {
                    Toggle("音声をドライブにも保存", isOn: Binding(
                        get: { pipeline.audioBackupOn },
                        set: { pipeline.audioBackupOn = $0 }))
                    if pipeline.audioBackupOn && pipeline.backupPending > 0 {
                        LabeledContent("ドライブに上げる前", value: "\(pipeline.backupPending) 件")
                    }
                    NavigationLink("周りの声と雑音") { NoiseSettingsView() }
                    NavigationLink("車の Bluetooth の機器") { CarDevicesView() }
                    NavigationLink("夜の聞き直し") { NightlyView() }
                    NavigationLink("ほかのアプリの音声を取り込む") { ImportView() }
                } header: {
                    Text("音声")
                } footer: {
                    Text(pipeline.audioBackupOn
                         ? "音声は Wi-Fi のときにドライブの「LifeLog/音声」に上げ、古い行もそこから取ってきて聞き直せます。"
                         : "直近1日ぶんは、記録の行を押すとその場面の音声が流れます。")
                }

                Section("ほかのアプリとつなぐ") {
                    NavigationLink("カレンダー・連絡先・移動・睡眠") { IntegrationsView() }
                    NavigationLink("ロック画面・時計の文字盤から使う") { ShortcutsHelpView() }
                    // ショートカットのオートメーションでアプリを開いた記録を残す（2026-11-13。施策 8。AppUsage.swift）
                    NavigationLink("アプリを開いた記録の使い方") { AppUsageHowToView() }
                }

    }
}

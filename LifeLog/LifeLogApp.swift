import GoogleSignIn
import SwiftUI

/// iOS が、裏での転送（家の PC に区切りを送る）の知らせを渡すためにアプリを起こしたときの受け口（2026-11-07）。
/// 家の PC からの見えない通知の宛先と、届いた通知の受け口も（中身は Push.swift。2026-11-07）
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushWake.register(application)
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == PCJobUploader.identifier else {
            completionHandler()
            return
        }
        PCJobUploader.shared.handleEvents(completion: completionHandler)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushWake.registered(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushWake.failed(error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        PushWake.receive(userInfo, completion: completionHandler)
    }
}

@main
struct LifeLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var pipeline: Pipeline
    @Environment(\.scenePhase) private var scenePhase

    /// 自動テスト（CI）で動いているときは、画面と裏の処理を動かさない
    private static let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// 画面の自動確認（CI のシミュレーターで、見本の記録を入れて全部の画面を開く）。配る IPA では常に false
    private static let demo: Bool = {
        #if DEBUG && targetEnvironment(simulator)
        return DemoData.isOn
        #else
        return false
        #endif
    }()

    init() {
        // 開いてから今日の画面が出るまでを測る（2026-11-22。s22 の 楽21。S22Book.swift）
        S22Launch.markStart()
        // 日本時間で区切る設定なら、ほかの何よりも先に時間帯を日本にする（2026-11-06）
        Storage.applyTimeZoneSetting()
        // 「控えから戻す」で選んだ控えは、登録を読む前に入れ替える
        if !Self.testing && !Self.demo { BackupKeeper.applyPendingRestore() }
        #if DEBUG && targetEnvironment(simulator)
        if Self.demo { DemoData.install() }
        // s25 の 堅6: UI テストの見本を足す（S25CUIHooks.swift。引数があるときだけ）
        if Self.demo { S25CUIHooks.afterDemoInstall() }
        #endif
        let pipeline = Pipeline()
        #if DEBUG && targetEnvironment(simulator)
        // 見本の写し（提案・話し手の疑い・自分の声の候補）を家の PC が出していることにして、画面を撮る（2026-11-13）
        if Self.demo { pipeline.homePC.features.formUnion(["selfcand", "proposals", "plaudfill", "spkdoubt"]) }
        // 2026-11-13 の施策の写しと送り（MothershipFeeds.swift）も
        if Self.demo {
            pipeline.homePC.features.formUnion(["weekly", "prep", "briefcmp", "accuracy", "unused", "feedback", "mood", "appusage"])
        }
        // 1日の年表・PayPay の写真・滞在・反映の見張り（2026-11-14。OneTimeline.swift）
        if Self.demo { pipeline.homePC.features.formUnion(["timeline", "paypayshot", "paypayrows", "livestays", "reflection"]) }
        #endif
        // 家の PC に送っている途中の区切りの知らせを受け取れるようにする
        if !Self.testing && !Self.demo { PCJobUploader.shared.start() }
        // 裏での処理は、起動が終わる前に登録しておく必要がある
        if !Self.testing && !Self.demo {
            pipeline.registerBackgroundWork()
            Pipeline.scheduleBackgroundWork()
        }
        // ロック画面・コントロールセンター・アクションボタンからの操作を受け取る
        LifeLogActions.handler = { action in await pipeline.handle(action) }
        // 自分を知る（2026-11-19。s18。KnowMe.swift）: 通知のボタンから答えを送る・録音を始める。職場と自宅の見張り
        KnowMeBook.shared.pc = pipeline.homePC
        KnowMeBook.shared.feeds = pipeline.mothershipFeeds
        KnowMeBook.shared.startRecording = { await pipeline.handle(.startRecording) }
        if !Self.testing && !Self.demo {
            KnowGeo.shared.start(pipeline)
            KnowMeBook.scheduleWeeklyTalk()
        }
        // Siri・ショートカットから記録を聞く（2026-11-06）
        Recall.recent = { pipeline.recentWords() }
        Recall.lastTalk = { pipeline.lastTalk(with: $0) }
        Recall.homework = { pipeline.todayHomework() }
        // 「記録に聞く」「朝のまとめを聞く」（2026-11-15。強化案 59。VoiceAsk.swift）
        VoiceRecall.ask = { await pipeline.voiceAnswer($0) }
        VoiceRecall.morning = { pipeline.morningSpeech() }
        // ショートカットの「仕事のまとめを取り込む」から渡された文で、取り込む画面を開く（2026-11-10。2026-11-27 の s30 から仕事タブの上に）
        DigestInbox.opened = { pipeline.openRoute(.digestImport($0)) }
        // ウォレットでかざしたとき（ショートカットの「支払いを記録」）に読み直す（2026-11-09）
        CardTap.added = {
            pipeline.payments.reloadTaps()
            // 休日は、かざした直後に「一言どうぞ」（時計にも出る。2026-11-21。s19 の 休22。Holiday.swift）
            HolidayNudges.shared.cardTapped(pipeline.payments.taps.max { $0.time < $1.time })
        }
        // 職場の会話を家の PC の言語モデルで作るとき（本人がオンにしたときだけ。2026-11-06）
        Summarizer.pcLLM = { system, prompt in try await pipeline.homePC.llm(system: system, prompt: prompt) }
        // 言語モデルの仕事を、家の PC を通して Claude に先に頼む（2026-11-13。Claude.swift。鍵は PC の中だけ）
        Summarizer.claudeLLM = { call in try await pipeline.homePC.claude(call).text }
        // 家の PC からの見えない通知で起きたときの動き（2026-11-07。Push.swift）
        PushWake.pipeline = pipeline
        // 寝ているあいだ・一緒にいる人のために休む（2026-11-21。s20 の 次10・体37。S20Book.swift）。
        // 時刻の切り替わりを拾うため、録音中は 5 分ごとに確かめ直す（裏で録音しているあいだもアプリは動いている）
        S20Hold.changed = { pipeline.updateHold() }
        // 時計に伝える設定（寝ている時間の 5 分・強い守り）が変わったら送り直す（2026-11-22。s21。S21Book.swift）
        S21Book.settingsChanged = { pipeline.receiver.sendSettings(skipSilence: pipeline.skipSilence, held: pipeline.recordingHeld) }
        // s22（2026-11-22。S22Book.swift）: 5 分ごとの見回り（電池の見本・ウィジェットの答え・電車の 3 問・誰と話した？）
        S22Book.install(pipeline, live: !Self.testing && !Self.demo)
        // s23（2026-11-23。S23Notices.swift）: 5 分ごとの見回り（何人でしたか・夜の名前の無い場所・確かめの自動の ○・版）
        S23Book.install(pipeline, live: !Self.testing && !Self.demo)
        #if DEBUG && targetEnvironment(simulator)
        // s25 の 堅6: UI テストで、知らせを押したときと同じ道で画面を開く（S25CUIHooks.swift。引数があるときだけ）
        if Self.demo { S25CUIHooks.start(pipeline) }
        #endif
        // s25 の A1（2026-11-24。S25TBook.swift）: LINE のタスク候補・下書きの棚を読む・録音中の耳打ち（初めはオフ）
        S25TBook.install(pipeline, live: !Self.testing && !Self.demo)
        // s26 の A2（2026-11-25。S26UBook.swift）: 操作待ち・機械がしたこと・すきまの 1 件を読む・時計への録り方の指図・コントロールセンター
        S26UBook.install(pipeline, live: !Self.testing && !Self.demo)
        // s26 の A1（2026-11-25。S26ABook.swift）: 端末の合図・体の音・曲・写真の食事と名刺・予定で録り方・実績・検索
        S26ABook.install(pipeline, live: !Self.testing && !Self.demo)
        // s27 の A（2026-11-25。S27WBook.swift）: 仕事の写し（GET /work・/work/confirm）を読む・ウィジェットへ数だけ
        S27WBook.install(pipeline, live: !Self.testing && !Self.demo)
        // s33 の S33A（2026-11-27。S33ABook.swift）: GET /s33 を読む・ラーメンの印・使われた数と実機で動いた印を 1 日 1 回
        S33ABook.install(pipeline, live: !Self.testing && !Self.demo)
        // s34 の S34A（2026-11-27。S34ABook.swift）: GET /s34 を読む・写真から仕事のまとめを拾う（設定でオンのときだけ）
        S34ABook.install(pipeline, live: !Self.testing && !Self.demo)
        if !Self.testing && !Self.demo {
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
                Task { @MainActor in pipeline.updateHold() }
            }
        }
        _pipeline = State(initialValue: pipeline)
    }

    var body: some Scene {
        WindowGroup {
            if Self.testing {
                Text("テスト中")
            } else {
                ContentView()
                    .environment(pipeline)
                    // 夜の青（見た目と差し色。2026-11-21。s20 の 体1・体5。DesignKit.swift）
                    .llRoot()
                    // 会話の 1 場面のカード（2026-11-22。s22 の 楽23。S22Views.swift）
                    .s22Root(pipeline)
                    // 知らせを押したあとの画面（2026-11-23。s23 の 知2〜知7。S23Screens.swift）
                    .s23Root(pipeline)
                    // LINE の「トーク履歴を送信」で受けた .txt を家の PC へ送るか（2026-11-24。s25 の 連6。S25TViews.swift）
                    .s25tRoot(pipeline)
                    // 開くときに Face ID（設定でオンにしたときだけ。録音と裏の処理は止めない）
                    .modifier(AppLock())
                    // lifelog:// はウィジェットから（2026-11-12。NoticeActions.swift の NoticeRoute.route(url:)）。ほかは Google のログイン
                    .onOpenURL { url in
                        // 共有で受けたファイル（LINE のトーク履歴の .txt。2026-11-24。s25 の 連6）
                        if url.isFileURL {
                            S25TShareBox.shared.received(url)
                        } else if let route = NoticeRoute.route(url: url) {
                            S26DWidgetUse.noteOpen(url)  // ウィジェットから開いた数（?w=。2026-11-25。s26 の 絵8）
                            pipeline.openRoute(route)
                        } else {
                            GIDSignIn.sharedInstance.handle(url)
                        }
                    }
                    // iPhone の検索（Spotlight）で押した人・日・会話を開く（2026-11-25。s26 の 軽7。S26ABook.swift）
                    .onContinueUserActivity(S26ASpotlight.activityType) { activity in
                        if let route = S26ASpotlight.route(activity) { pipeline.openRoute(route) }
                    }
                    .task {
                        guard !Self.demo else { return }
                        if let action = LifeLogActions.pending {
                            LifeLogActions.pending = nil
                            await pipeline.handle(action)
                        }
                        await pipeline.restoreSignIn()
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !Self.testing, !Self.demo else { return }
            // 開いたときに、溜まった音声の処理と、終わった会話の見出し付けを進める
            if phase == .active {
                pipeline.appBecameActive()
                pipeline.processQueue()
                S22Book.tick()  // ウィジェットの答え・電池の見本（2026-11-22。s22）
                S23Book.shared.tick()  // 何人でしたか・版など（2026-11-23。s23）
                S26DWidgetUse.countInstalled()  // 置かれているウィジェットを 1 日 1 回数える（2026-11-25。s26 の 絵8）
                S35PhotoBook.shared.opened()  // 送れなかった仕事のまとめの写真を 1 回だけ送り直す（2026-11-28。s35）
            }
            if phase == .background {
                pipeline.appMovedToBackground()
                Pipeline.scheduleBackgroundWork()
            }
        }
    }
}

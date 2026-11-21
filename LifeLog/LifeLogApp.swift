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
        // 日本時間で区切る設定なら、ほかの何よりも先に時間帯を日本にする（2026-11-06）
        Storage.applyTimeZoneSetting()
        // 「控えから戻す」で選んだ控えは、登録を読む前に入れ替える
        if !Self.testing && !Self.demo { BackupKeeper.applyPendingRestore() }
        #if DEBUG && targetEnvironment(simulator)
        if Self.demo { DemoData.install() }
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
        // ショートカットの「仕事のまとめを取り込む」から渡された文で、取り込む画面を開く（2026-11-10）
        DigestInbox.opened = { pipeline.noticeRoute = .digestImport($0) }
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
                    // 開くときに Face ID（設定でオンにしたときだけ。録音と裏の処理は止めない）
                    .modifier(AppLock())
                    // lifelog:// はウィジェットから（2026-11-12。NoticeActions.swift の NoticeRoute.route(url:)）。ほかは Google のログイン
                    .onOpenURL { url in
                        if let route = NoticeRoute.route(url: url) {
                            pipeline.openRoute(route)
                        } else {
                            GIDSignIn.sharedInstance.handle(url)
                        }
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
            }
            if phase == .background {
                pipeline.appMovedToBackground()
                Pipeline.scheduleBackgroundWork()
            }
        }
    }
}

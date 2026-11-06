import GoogleSignIn
import SwiftUI

/// iOS が、裏での転送（家の PC に区切りを送る）の知らせを渡すためにアプリを起こしたときの受け口（2026-11-07）
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == PCJobUploader.identifier else {
            completionHandler()
            return
        }
        PCJobUploader.shared.handleEvents(completion: completionHandler)
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
        // 家の PC に送っている途中の区切りの知らせを受け取れるようにする
        if !Self.testing && !Self.demo { PCJobUploader.shared.start() }
        // 裏での処理は、起動が終わる前に登録しておく必要がある
        if !Self.testing && !Self.demo {
            pipeline.registerBackgroundWork()
            Pipeline.scheduleBackgroundWork()
        }
        // ロック画面・コントロールセンター・アクションボタンからの操作を受け取る
        LifeLogActions.handler = { action in await pipeline.handle(action) }
        // Siri・ショートカットから記録を聞く（2026-11-06）
        Recall.recent = { pipeline.recentWords() }
        Recall.lastTalk = { pipeline.lastTalk(with: $0) }
        // 職場の会話を家の PC の言語モデルで作るとき（本人がオンにしたときだけ。2026-11-06）
        Summarizer.pcLLM = { system, prompt in try await pipeline.homePC.llm(system: system, prompt: prompt) }
        _pipeline = State(initialValue: pipeline)
    }

    var body: some Scene {
        WindowGroup {
            if Self.testing {
                Text("テスト中")
            } else {
                ContentView()
                    .environment(pipeline)
                    // 開くときに Face ID（設定でオンにしたときだけ。録音と裏の処理は止めない）
                    .modifier(AppLock())
                    .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
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

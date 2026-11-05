import GoogleSignIn
import SwiftUI

@main
struct LifeLogApp: App {
    @State private var pipeline: Pipeline
    @Environment(\.scenePhase) private var scenePhase

    /// 自動テスト（CI）で動いているときは、画面と裏の処理を動かさない
    private static let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        // 「控えから戻す」で選んだ控えは、登録を読む前に入れ替える
        if !Self.testing { BackupKeeper.applyPendingRestore() }
        let pipeline = Pipeline()
        // 裏での処理は、起動が終わる前に登録しておく必要がある
        if !Self.testing {
            pipeline.registerBackgroundWork()
            Pipeline.scheduleBackgroundWork()
        }
        // ロック画面・コントロールセンター・アクションボタンからの操作を受け取る
        LifeLogActions.handler = { action in await pipeline.handle(action) }
        // Siri・ショートカットから記録を聞く（2026-11-06）
        Recall.recent = { pipeline.recentWords() }
        Recall.lastTalk = { pipeline.lastTalk(with: $0) }
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
                        if let action = LifeLogActions.pending {
                            LifeLogActions.pending = nil
                            await pipeline.handle(action)
                        }
                        await pipeline.restoreSignIn()
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !Self.testing else { return }
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

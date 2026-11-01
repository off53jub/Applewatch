import GoogleSignIn
import SwiftUI

@main
struct LifeLogApp: App {
    @State private var pipeline: Pipeline
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let pipeline = Pipeline()
        // 裏での処理は、起動が終わる前に登録しておく必要がある
        pipeline.registerBackgroundWork()
        Pipeline.scheduleBackgroundWork()
        // ロック画面・コントロールセンター・アクションボタンからの操作を受け取る
        LifeLogActions.handler = { action in await pipeline.handle(action) }
        _pipeline = State(initialValue: pipeline)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pipeline)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .task {
                    if let action = LifeLogActions.pending {
                        LifeLogActions.pending = nil
                        await pipeline.handle(action)
                    }
                    await pipeline.restoreSignIn()
                }
        }
        .onChange(of: scenePhase) { _, phase in
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

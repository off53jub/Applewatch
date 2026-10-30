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
        _pipeline = State(initialValue: pipeline)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pipeline)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .task { await pipeline.restoreSignIn() }
        }
        .onChange(of: scenePhase) { _, phase in
            // 開いたときに、溜まった音声の処理と、終わった会話の見出し付けを進める
            if phase == .active { pipeline.processQueue() }
            if phase == .background { Pipeline.scheduleBackgroundWork() }
        }
    }
}

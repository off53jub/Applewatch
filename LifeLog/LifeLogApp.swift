import GoogleSignIn
import SwiftUI

@main
struct LifeLogApp: App {
    @State private var pipeline = Pipeline()
    @Environment(\.scenePhase) private var scenePhase

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
        }
    }
}

import GoogleSignIn
import SwiftUI

@main
struct LifeLogApp: App {
    @State private var pipeline = Pipeline()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pipeline)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .task { await pipeline.restoreSignIn() }
        }
    }
}

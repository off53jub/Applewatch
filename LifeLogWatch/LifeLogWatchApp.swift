import SwiftUI

@main
struct LifeLogWatchApp: App {
    @State private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(recorder)
        }
    }
}

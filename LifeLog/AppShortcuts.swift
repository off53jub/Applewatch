import AppIntents

/// ショートカット App・アクションボタン・Siri から使える操作。
struct LifeLogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleRecordingIntent(),
                    phrases: ["\(.applicationName)で録音", "\(.applicationName)の録音を始める"],
                    shortTitle: "録音を始める・止める",
                    systemImageName: "record.circle")
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["\(.applicationName)の録音をオンにする"],
                    shortTitle: "録音を始める",
                    systemImageName: "record.circle.fill")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["\(.applicationName)の録音をオフにする"],
                    shortTitle: "録音を止める",
                    systemImageName: "stop.circle")
        AppShortcut(intent: StartRecordingInAppIntent(),
                    phrases: ["\(.applicationName)を開いて録音する"],
                    shortTitle: "開いて録音を始める",
                    systemImageName: "mic.circle")
        AppShortcut(intent: MarkIntent(),
                    phrases: ["\(.applicationName)で印を付ける"],
                    shortTitle: "印を付ける",
                    systemImageName: "star.fill")
    }
}

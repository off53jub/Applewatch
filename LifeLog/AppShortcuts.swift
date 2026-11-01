import AppIntents

/// ショートカット App・アクションボタン・Siri から使える操作。
struct LifeLogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleRecordingIntent(),
                    phrases: ["\(.applicationName)で録音", "\(.applicationName)の録音を始める"],
                    shortTitle: "録音を始める・止める",
                    systemImageName: "record.circle")
        AppShortcut(intent: MarkIntent(),
                    phrases: ["\(.applicationName)で印を付ける"],
                    shortTitle: "印を付ける",
                    systemImageName: "star.fill")
    }
}

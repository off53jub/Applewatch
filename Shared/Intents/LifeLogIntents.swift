import AppIntents

/// ロック画面・コントロールセンター・アクションボタン・ショートカットから LifeLog を動かす。
/// どれも LifeLog を開いてから動かす（録音を始めるには、アプリが前に出ている必要があるため）。
/// このファイルはアプリとウィジェット（コントロール）の両方に入れる。動くのはアプリの中。
enum LifeLogAction: Sendable {
    case toggleRecording
    case mark
}

@MainActor
enum LifeLogActions {
    /// アプリが受け取る（LifeLogApp が起動時に入れる）
    static var handler: ((LifeLogAction) async -> Void)?
    /// アプリの準備ができる前に届いた操作
    static var pending: LifeLogAction?

    static func run(_ action: LifeLogAction) async {
        if let handler {
            await handler(action)
        } else {
            pending = action
        }
    }
}

struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "iPhone の録音を始める・止める"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await LifeLogActions.run(.toggleRecording)
        return .result()
    }
}

struct MarkIntent: AppIntent {
    static let title: LocalizedStringResource = "今のところに印を付ける"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await LifeLogActions.run(.mark)
        return .result()
    }
}

import ActivityKit
import AppIntents

/// ロック画面・コントロールセンター・アクションボタン・ショートカットから LifeLog を動かす。
/// 録音の開始・停止は、LifeLog を開かず、ロックしたまま（Face ID なし）で動く。
/// iOS の決まりで、こうして録音を始めたときは、録音中ずっと Live Activity（ロック画面と Dynamic Island の表示）を出す。
/// 印を付けるのは LifeLog を開いてから動かす。
/// このファイルはアプリとウィジェット（コントロール・Live Activity）の両方に入れる。動くのはアプリの中。
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

/// 録音中に出す Live Activity の中身
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 録音を始めた時刻（経過時間を出す）
        var started: Date
    }
}

/// 録音を始める・止める。録音の印として扱われるよう AudioRecordingIntent にし、
/// Live Activity のボタンから押されてもアプリの中で動くよう LiveActivityIntent にもする。
struct ToggleRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "iPhone の録音を始める・止める"
    static let description: IntentDescription? = IntentDescription("LifeLog を開かずに、iPhone の録音を始めるか止めます。ロックしたままでも動きます。")
    /// ロックを外さなくても（Face ID なしで）動く
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

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

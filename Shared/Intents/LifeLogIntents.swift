import ActivityKit
import AppIntents

/// ロック画面・コントロールセンター・アクションボタン・ショートカットから LifeLog を動かす。
/// 録音の開始・停止は、LifeLog を開かず、ロックしたまま（Face ID なし）で動く。
/// iOS の決まりで、こうして録音を始めたときは、録音中ずっと Live Activity（ロック画面と Dynamic Island の表示）を出す。
/// 印を付けるのは LifeLog を開いてから動かす。
/// このファイルはアプリとウィジェット（コントロール・Live Activity）の両方に入れる。動くのはアプリの中。
enum LifeLogAction: Sendable {
    case toggleRecording
    /// 録音していなければ始める（すでに録音中なら何もしない。ショートカットの自動化用）
    case startRecording
    /// 録音していれば止める（録音していなければ何もしない）
    case stopRecording
    /// アプリを開いて、録音していなければ始める（Live Activity が出せない iPad 用）
    case startRecordingInApp
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

/// 録音を始める。ショートカットの自動化（家に着いたとき・家を出たとき）に使う。すでに録音中なら何もしない。
struct StartRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "録音を始める（録音中なら何もしない）"
    static let description: IntentDescription? = IntentDescription("LifeLog を開かずに録音を始めます。すでに録音中なら何もしません。ショートカットの自動化に使います。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        await LifeLogActions.run(.startRecording)
        return .result()
    }
}

/// 録音を止める。録音中でなければ何もしない。
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "録音を止める（録音中でなければ何もしない）"
    static let description: IntentDescription? = IntentDescription("LifeLog を開かずに録音を止めます。録音中でなければ何もしません。ショートカットの自動化に使います。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        await LifeLogActions.run(.stopRecording)
        return .result()
    }
}

/// LifeLog を開いて録音を始める。Live Activity が出せない iPad で、上の「録音を始める」が動かないときに使う。
struct StartRecordingInAppIntent: AppIntent {
    static let title: LocalizedStringResource = "LifeLog を開いて録音を始める"
    static let description: IntentDescription? = IntentDescription("LifeLog を開いて録音を始めます。すでに録音中なら何もしません。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await LifeLogActions.run(.startRecordingInApp)
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

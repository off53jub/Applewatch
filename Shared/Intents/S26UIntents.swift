import AppIntents

/// s26（2026-11-25）の 軽3: コントロールセンターから「録り方の組を替える」（電池優先 → 早さ優先 → 精度優先 → 電池優先）。
/// 設定でいちばん変えに行っていたのが録り方の組だった（2026-11-06〜25 の実機の数）。LifeLog を開かずにアプリの中で動く
/// （録音の操作と同じく LiveActivityIntent にして、アプリの中で動かす）。ショートカットの一覧には出さない（A1 の部品と重ねない）。
/// このファイルはアプリとウィジェット（コントロール）の両方に入れる。動くのはアプリの中（S26UBook.control）。
@MainActor
enum S26UControlActions {
    static let nextPreset = "preset.next"
    /// アプリが受け取る（S26UBook.install が入れる）
    static var handler: ((String) async -> Void)?
    /// アプリの準備ができる前に届いた操作
    static var pending: String?

    static func run(_ name: String) async {
        if let handler {
            await handler(name)
        } else {
            pending = name
        }
    }
}

struct S26UNextPresetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "録り方の組を替える"
    static let description: IntentDescription? = IntentDescription("電池優先・早さ優先・精度優先を順に替えます。LifeLog を開かずに動きます。")
    static let isDiscoverable = false
    /// 設定を変えるので、ロックを外してから動く
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await S26UControlActions.run(S26UControlActions.nextPreset)
        return .result()
    }
}

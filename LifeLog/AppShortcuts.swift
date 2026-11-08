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
        AppShortcut(intent: RecentWordsIntent(),
                    phrases: ["\(.applicationName)でさっき何て言った", "\(.applicationName)の直近の記録"],
                    shortTitle: "さっき何て言った？",
                    systemImageName: "text.bubble")
        AppShortcut(intent: RecordPaymentIntent(),
                    phrases: ["\(.applicationName)に支払いを記録"],
                    shortTitle: "支払いを記録",
                    systemImageName: "creditcard")
        AppShortcut(intent: LastTalkIntent(),
                    phrases: ["\(.applicationName)で前回の話"],
                    shortTitle: "この人と前回何を話した？",
                    systemImageName: "person.bubble")
    }
}

/// 「さっき何て言った？」（2026-11-06）。直近10分の記録の最後の3行を読み上げる
struct RecentWordsIntent: AppIntent {
    static let title: LocalizedStringResource = "さっき何て言った？"
    static let description: IntentDescription? = IntentDescription("LifeLog の直近10分の記録から、最後の3行を答えます。")
    /// 記録の中身なので、ロックを外してから
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Recall.recent?() ?? "LifeLog の準備ができていません。一度アプリを開いてください。"))
    }
}

/// 「この人と前回何を話した？」（2026-11-06）
struct LastTalkIntent: AppIntent {
    static let title: LocalizedStringResource = "この人と前回何を話した？"
    static let description: IntentDescription? = IntentDescription("名前を言うと、その人と話したいちばん新しい会話の見出しと要点を答えます。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "名前")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Recall.lastTalk?(name) ?? "LifeLog の準備ができていません。一度アプリを開いてください。"))
    }
}

/// 「支払いを記録」（2026-11-09）。ショートカットの「取引」オートメーション（ウォレットでかざしたとき）から呼ぶ。
/// 時刻はこれが動いた時刻。店・金額・カードは、オートメーションの「ショートカットの入力」の「販売者」「金額」「カードまたはパス」を渡す
/// （カードによっては空で届く。空でも、払った時刻は残る）。端末の中（card-taps.jsonl）だけに置く。
struct RecordPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "支払いを記録"
    static let description: IntentDescription? = IntentDescription("ウォレットで払った時刻と、店・金額・カードを LifeLog に残します。行ったお店の答え合わせに使います。")
    static let openAppWhenRun = false

    @Parameter(title: "店")
    var shop: String?

    @Parameter(title: "金額")
    var amount: String?

    @Parameter(title: "カード")
    var card: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        try CardTap.append(CardTap.make(shop: shop, amount: amount, card: card, at: .now))
        CardTap.added?()
        return .result()
    }
}

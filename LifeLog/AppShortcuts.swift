import AppIntents
import UIKit

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
        AppShortcut(intent: HomeworkIntent(),
                    phrases: ["\(.applicationName)で今日の宿題", "\(.applicationName)の今日やること"],
                    shortTitle: "今日の宿題",
                    systemImageName: "checklist")
        AppShortcut(intent: ImportDigestIntent(),
                    phrases: ["\(.applicationName)に仕事のまとめを取り込む"],
                    shortTitle: "仕事のまとめを取り込む",
                    systemImageName: "doc.text")
    }
}

/// 「今日の宿題」（2026-11-10）。期限を過ぎた・今日までの仕事の頼まれごとと、今日の仕事のまとめの宿題を答える
struct HomeworkIntent: AppIntent {
    static let title: LocalizedStringResource = "今日の宿題"
    static let description: IntentDescription? = IntentDescription("LifeLog の頼まれごと帳から、今日までの仕事のものを5つまで答えます。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Recall.homework?() ?? "LifeLog の準備ができていません。一度アプリを開いてください。"))
    }
}

/// 「仕事のまとめを取り込む」（2026-11-10）。ショートカットの共有シートから、スクショ・写真・文を渡す。
/// 文字の読み取りは iPhone の中。アプリを開いて、取り込む画面に入れておく（中身を確かめてから「入れる」を押す）
struct ImportDigestIntent: AppIntent {
    static let title: LocalizedStringResource = "仕事のまとめを取り込む"
    static let description: IntentDescription? = IntentDescription("スクショ・写真・文を LifeLog の「仕事のまとめを取り込む」画面に入れて開きます。")
    static let openAppWhenRun = true

    @Parameter(title: "スクショ・写真")
    var images: [IntentFile]?

    @Parameter(title: "文")
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        var pieces: [String] = []
        if let text, !text.isEmpty { pieces.append(text) }
        for file in images ?? [] {
            guard let image = UIImage(data: file.data) else { continue }
            let read: String = await Pipeline.recognizeText(image)
            if !read.isEmpty { pieces.append(read) }
        }
        DigestInbox.put(pieces.joined(separator: "\n"))
        return .result()
    }
}

/// ショートカットから渡された「仕事のまとめ」の文を、アプリが取り込む画面を開くまで預かる（2026-11-10）
@MainActor
enum DigestInbox {
    /// アプリの準備ができていれば、すぐ取り込む画面を開く（Pipeline が入れる）
    static var opened: ((String) -> Void)?
    private static var waiting: String?

    static func put(_ text: String) {
        if let opened {
            opened(text)
        } else {
            waiting = text
        }
    }

    /// 預かっている文（取り出したら消す）
    static func take() -> String? {
        defer { waiting = nil }
        return waiting
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

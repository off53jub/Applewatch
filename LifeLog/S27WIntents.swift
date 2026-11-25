import AppIntents
import Foundation

// s27（2026-11-25）の A のショートカットの部品（場7・他3）。
// アプリのショートカット（AppShortcutsProvider）はもう 10 個あるので、ここのものはショートカット App の「LifeLog」の動きとして出す。
// Siri にはショートカットの名前で頼む（例:「あの件どうなった」）。仕事の中身なので、どれもロックを外してから。

/// 場7: 「あの件どうなった」— 案件名・人の名前・チケット番号で、いまの状況と最後に決まったことを返す（家の PC の /work/ask。
/// 使えないときは端末の写しの中で引く）。伏せる切り替えがオンなら、名前を伏せて返す
struct S27WAskIntent: AppIntent {
    static let title: LocalizedStringResource = "あの件どうなった"
    static let description: IntentDescription? = IntentDescription("案件の名前・人の名前・チケット番号で、仕事のいまの状況と最後に決まったことを返します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "案件・人・番号", requestValueDialog: IntentDialog("どの件ですか？"))
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        Tally.add("s27w.intent.ask")
        let book = S27WBook.shared
        guard S27WBook.pipeline != nil, book.offered else {
            let text = "仕事の記録がまだありません。家の PC の LifeLog PC が新しくなると使えます。"
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        }
        let found = await book.ask(query)
        let text = S27WRules.spoken(found.answers, mask: book.activeMask)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// 仕事の画面を開く
struct S27WOpenWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "仕事の画面を開く"
    static let description: IntentDescription? = IntentDescription("LifeLog の「仕事」の画面を開きます。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        S27WBook.pipeline?.openRoute(.work(.home))
        Tally.add("s27w.intent.open")
        return .result()
    }
}

/// 他3: 社内のお知らせを入れる（共有シートの「ショートカット」から文を渡せる）。設定でオンにするまでは入れない（初めはオフ）
struct S27WNoticeIntent: AppIntent {
    static let title: LocalizedStringResource = "社内のお知らせを入れる"
    static let description: IntentDescription? = IntentDescription("社内の週報・お知らせの文を、LifeLog の「他の案件」に入れる画面を開きます。仕事の画面の設定でオンにしたときだけ使えます。")
    static let openAppWhenRun = true

    @Parameter(title: "お知らせの文")
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        Tally.add("s27w.intent.notice")
        let book = S27WBook.shared
        if let text, !text.isEmpty { book.pendingNotice = String(text.prefix(S27WRules.textLimit)) }
        S27WBook.pipeline?.openRoute(.work(.notice))
        return .result()
    }
}

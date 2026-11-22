import AppIntents
import Foundation

// s22（2026-11-22。楽17）: Siri・アクションボタン・ショートカットから。
// アプリのショートカット（AppShortcutsProvider）は 1 つのアプリに 10 個までで、もう 10 個あるので、ここの 3 つは
// ショートカット App の「LifeLog」の動きとして出す（アクションボタンには「ショートカット」から割り当てる。Siri にはショートカットの名前で頼む）。
// 前からある「今のところに印を付ける」はアプリを開くので、開かずに印を付けるものを足した。

/// 30 分、録音を休む（一緒にいる人のために休むのと同じ仕組み。s20 の 体37）
struct S22PauseThirtyIntent: AppIntent {
    static let title: LocalizedStringResource = "30 分録音を休む"
    static let description: IntentDescription? = IntentDescription("LifeLog の録音を 30 分休みます（時計も）。30 分たつと自動で戻ります。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let until = Date.now.addingTimeInterval(30 * 60)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: PersonPauseRules.untilKey)
        S20Hold.changed?()
        Tally.add("s22.intent.pause30")
        return .result(dialog: IntentDialog(stringLiteral: until.formatted(date: .omitted, time: .shortened) + " まで録音を休みます。"))
    }
}

/// アプリを開かずに「いまの大事」の印を付ける
struct S22MarkQuietlyIntent: AppIntent {
    static let title: LocalizedStringResource = "開かずに印を付ける"
    static let description: IntentDescription? = IntentDescription("LifeLog を開かずに、いまのところに「大事」の印を付けます。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await LifeLogActions.run(.mark)
        Tally.add("s22.intent.mark")
        return .result(dialog: "印を付けました。")
    }
}

/// 今日のまとめ（会話の数・録った時間・今日までの頼まれごと・確かめ待ち・今日の三つ）を答える
struct S22TodaySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "今日のまとめ"
    static let description: IntentDescription? = IntentDescription("LifeLog の今日の会話の数・録った時間・今日までの頼まれごと・確かめ待ちの数を答えます。")
    /// 頼まれごとの頭が入るので、ロックを外してから
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Tally.add("s22.intent.today")
        let text = S22Book.pipeline?.s22TodaySummary() ?? "LifeLog の準備ができていません。一度アプリを開いてください。"
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

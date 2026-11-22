import AppIntents
import WidgetKit

/// ウィジェット「LifeLog の 1 問」の ○×（2026-11-22。s22 の 楽14）。ウィジェットの中で動き、答えを App Group にためるだけ
/// （アプリを開かない。母艦へ送るのはアプリが次に動いたとき）
struct S22WidgetAnswerIntent: AppIntent {
    static let title: LocalizedStringResource = "確かめ待ちに答える"
    static let description: IntentDescription? = IntentDescription("ウィジェットの確かめ待ちの 1 問に、はい・いいえで答えます。")
    static let isDiscoverable = false

    @Parameter(title: "問いの番号")
    var id: String

    @Parameter(title: "答え")
    var value: String

    init() {}

    init(id: String, value: String) {
        self.id = id
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        guard ["yes", "no"].contains(value), !id.isEmpty else { return .result() }
        S22WidgetAnswers.add(id: id, value: value)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetState.reviewKind)
        return .result()
    }
}

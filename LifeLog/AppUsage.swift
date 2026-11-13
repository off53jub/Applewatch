import AppIntents
import SwiftUI

/// iPhone の中の行動（施策 8。2026-11-13）。
/// スクリーンタイム（アプリごとの時間）と Safari の履歴は、Apple の決まりで、ほかのアプリからは読めない。
/// そこで、ショートカット App の「個人用オートメーション」（「アプリを開いたとき」「アプリを閉じたとき」「集中モードが入ったとき」）から
/// 「アプリを開いた記録」を呼んでもらい、時刻・アプリの名前・出来事だけを端末にためて、家の PC（POST /app-usage）経由で母艦に送る。
/// アプリの中身・見たページは取らない。

/// 出来事（家の PC に送る値と同じ）
enum AppUsageEvent: String, AppEnum {
    case open
    case close
    case focusOn = "focus_on"
    case focusOff = "focus_off"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "出来事")
    static let caseDisplayRepresentations: [AppUsageEvent: DisplayRepresentation] = [
        .open: DisplayRepresentation(title: "開いた"),
        .close: DisplayRepresentation(title: "閉じた"),
        .focusOn: DisplayRepresentation(title: "集中モードが入った"),
        .focusOff: DisplayRepresentation(title: "集中モードが切れた"),
    ]
}

/// 「アプリを開いた記録」。ショートカットのオートメーションから呼ぶ（LifeLog は開かない）
struct RecordAppUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "アプリを開いた記録"
    static let description: IntentDescription? = IntentDescription("いまの時刻と、アプリの名前・開いたか閉じたかを LifeLog に残します。家の PC につながったときに母艦へ送ります。")
    static let openAppWhenRun = false

    @Parameter(title: "アプリの名前")
    var app: String

    @Parameter(title: "出来事", default: .open)
    var event: AppUsageEvent

    @MainActor
    func perform() async throws -> some IntentResult {
        MothershipOutbox.enqueueAppUsage(app: app, event: event.rawValue)
        return .result()
    }
}

/// 設定の「アプリを開いた記録の使い方」（ショートカットのオートメーションの作り方）
struct AppUsageHowToView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        Form {
            Section {
                Text("iPhone のスクリーンタイム（アプリごとの時間）と Safari の履歴は、Apple の決まりで、ほかのアプリからは読めません。そこで、ショートカット App のオートメーションで、アプリを開いたときに LifeLog に知らせてもらいます。")
            } header: {
                Text("なぜショートカットか")
            }
            Section {
                Text("1. ショートカット App を開き、下の「オートメーション」→ 右上の「＋」")
                Text("2. 「アプリ」を選び、記録したいアプリを選ぶ。「開いている」に印を付け、「すぐに実行」を選ぶ")
                Text("3. 「新規の空のオートメーション」→「アクションを追加」で「LifeLog」を探し、「アプリを開いた記録」を選ぶ")
                Text("4. 「アプリの名前」に、そのアプリの名前を書く（例: 見本アプリ）。「出来事」は「開いた」")
                Text("5. 閉じたときも残すなら、同じものを「閉じている」で作り、「出来事」を「閉じた」にする")
            } header: {
                Text("作り方")
            } footer: {
                Text("集中モードの「入ったとき」「切れたとき」でも作れます（出来事を「集中モードが入った」「集中モードが切れた」に）。")
            }
            Section {
                LabeledContent("送る前のもの", value: "\(pipeline.mothershipFeeds.waiting) 件")
                LabeledContent("家の PC", value: pipeline.homePC.features.contains("appusage") ? "受け取れる" : "まだ受け取れない")
            } footer: {
                Text("残すのは時刻・アプリの名前・出来事だけです。端末にためて、家の PC につながったときに母艦へ送ります（家の PC がまだ受け取れないときは、ためたままにします）。")
            }
        }
        .navigationTitle("アプリを開いた記録")
        .countsOpen("appUsageHowTo")
    }
}

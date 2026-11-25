import AppIntents
import Foundation
import UserNotifications

// s26（2026-11-25）の A1 のショートカットの部品（軽7・軽8・軽12・集12・集19）。
// アプリのショートカット（AppShortcutsProvider）はもう 10 個あるので、ここのものはショートカット App の「LifeLog」の動きとして出す。
// Siri にはショートカットの名前で頼む（例:「人のページを開く」）。

/// 録り方の組（設定の「録り方の組」と同じ 3 つ）
enum S26APresetChoice: String, AppEnum {
    case battery, speed, accuracy

    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "録り方の組")
    static let caseDisplayRepresentations: [S26APresetChoice: DisplayRepresentation] = [
        .battery: DisplayRepresentation(title: "電池優先"),
        .speed: DisplayRepresentation(title: "早さ優先"),
        .accuracy: DisplayRepresentation(title: "精度優先"),
    ]

    var preset: S21Preset {
        switch self {
        case .battery: .battery
        case .speed: .speed
        case .accuracy: .accuracy
        }
    }
}

/// 軽7: 人のページを開く（Siri・ショートカット・ホーム画面から「◯◯さん」）
struct S26AOpenPersonIntent: AppIntent {
    static let title: LocalizedStringResource = "人のページを開く"
    static let description: IntentDescription? = IntentDescription("名前を言うと、LifeLog でその人のページを開きます。")
    static let openAppWhenRun = true

    @Parameter(title: "名前", requestValueDialog: IntentDialog("だれのページを開きますか？"))
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty, let p = S26ABook.pipeline {
            p.openRoute(.link(.person(n)))
            Tally.add("s26a.intent.person")
        }
        return .result()
    }
}

/// 軽12: 今日の三つを取る（文で返す。ほかの動きにつなげられる）
struct S26ATodayThreeIntent: AppIntent {
    static let title: LocalizedStringResource = "今日の三つを取る"
    static let description: IntentDescription? = IntentDescription("LifeLog の今日の三つを、1 行ずつの文で返します。")
    /// タスクの中身なので、ロックを外してから
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        Tally.add("s26a.intent.three")
        guard let p = S26ABook.pipeline else {
            let text = "LifeLog の準備ができていません。一度アプリを開いてください。"
            return .result(value: "", dialog: IntentDialog(stringLiteral: text))
        }
        let picks = p.todayThree()
        let text = picks.isEmpty ? "今日の三つはまだありません。"
            : picks.enumerated().map { "\($0.offset + 1). " + $0.element.text }.joined(separator: "\n")
        return .result(value: picks.isEmpty ? "" : text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// 軽12: ◯◯さんの最近
struct S26APersonRecentIntent: AppIntent {
    static let title: LocalizedStringResource = "この人の最近"
    static let description: IntentDescription? = IntentDescription("名前を言うと、その人と最後に話したこと・次の一言・最近の会話を 3 つまで返します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "名前")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        Tally.add("s26a.intent.recent")
        let text = S26ABook.pipeline?.s26aPersonRecent(name) ?? "LifeLog の準備ができていません。一度アプリを開いてください。"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// 軽12: メモを足す（その日の一言として残し、休日のファイルと同じ道で母艦に届く。種類は memo・仮）
struct S26AAddMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "メモを足す"
    static let description: IntentDescription? = IntentDescription("いまの時刻で、LifeLog にひとことのメモを残します（300 字まで）。")
    static let openAppWhenRun = false

    @Parameter(title: "メモ", requestValueDialog: IntentDialog("何を残しますか？"))
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .result(dialog: "メモが空でした。") }
        HolidayBook.shared.addNote(kind: "memo", day: HealthExport.dayKey(.now), text: t, ref: nil)
        return .result(dialog: "メモを残しました。")
    }
}

/// 軽12: 録り方を替える
struct S26ASetPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "録り方を替える"
    static let description: IntentDescription? = IntentDescription("LifeLog の録り方を、電池優先・早さ優先・精度優先のどれかにまとめて切り替えます。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "録り方の組", default: .battery)
    var choice: S26APresetChoice

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let p = S26ABook.pipeline else { return .result(dialog: "LifeLog の準備ができていません。一度アプリを開いてください。") }
        p.s26aApply(choice.preset)
        return .result(dialog: IntentDialog(stringLiteral: "「\(choice.preset.label)」にしました。時計には、つながったときに伝わります。"))
    }
}

/// 軽12・集1: 体重を入れる（ヘルスケアに体重が無い日の書き出しに使う。ヘルスケアには書かない）
struct S26AAddWeightIntent: AppIntent {
    static let title: LocalizedStringResource = "体重を入れる"
    static let description: IntentDescription? = IntentDescription("体重（kg）を LifeLog に残します。ヘルスケアに体重が無い日は、これを母艦に送ります。")
    static let openAppWhenRun = false

    @Parameter(title: "体重（kg）", requestValueDialog: IntentDialog("体重は何 kg ですか？"))
    var kg: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard S26AWeightBook.add(kg) else { return .result(dialog: "20〜300 kg の数で入れてください。") }
        return .result(dialog: IntentDialog(stringLiteral: String(format: "%.1f kg を残しました。", kg)))
    }
}

/// 軽8: 朝のまとめ（今日の三つつき）と、次の予定の前の一枚を耳で（自分で押したときだけ読む）
struct S26AListenDayIntent: AppIntent {
    static let title: LocalizedStringResource = "朝のまとめと次の予定を聞く"
    static let description: IntentDescription? = IntentDescription("朝の「昨日と今日」（今日の三つつき）と、次の予定の前の一枚を、日本語の声で読み上げます。通勤のイヤホン向け。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let text = await S26AEar.script()
        MorningSpeaker.shared.speak(text)
        Tally.add("s26a.intent.ear")
        return .result()
    }
}

@MainActor
enum S26AEar {
    /// 読む文（朝のまとめ → 次の予定の前の一枚。どちらも無ければその旨）
    static func script() async -> String {
        var parts: [String] = []
        if let morning = VoiceRecall.morning?() { parts.append(morning) }
        if let brief = await nextBrief() { parts.append("次の予定の前の一枚です。" + brief) }
        return parts.isEmpty ? "今日の「昨日と今日」と、次の予定の前の一枚は、まだありません。" : parts.joined(separator: "\n")
    }

    /// これから出る「会う前の1枚」の知らせ（いちばん近いもの）の文
    static func nextBrief() async -> String? {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let briefs = pending.filter { $0.identifier.hasPrefix("brief-") }
        func fireDate(_ r: UNNotificationRequest) -> Date {
            (r.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                ?? (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
        }
        guard let next = briefs.min(by: { fireDate($0) < fireDate($1) }) else { return nil }
        return S26AEarRules.briefScript(title: next.content.title, body: next.content.body)
    }
}

/// 集12: 充電の合図（ショートカットの「充電器」のオートメーションから。アプリが止まっていても残る）
struct S26AChargeIntent: AppIntent {
    static let title: LocalizedStringResource = "充電の合図"
    static let description: IntentDescription? = IntentDescription("充電器をつないだ・外した時刻を LifeLog に残します（起きた・寝た時刻の手がかり）。")
    static let openAppWhenRun = false

    @Parameter(title: "つないだ", default: true)
    var plugged: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        S26ASignalsStore.shared.addCharge(plugged ? "plugged" : "unplugged", at: .now)
        return .result()
    }
}

/// 集19: アプリの使用時間（ショートカットから。スクリーンタイムは外へ出す道が無いので、本人が組む。手間と見合うかは仮）
struct S26AScreenTimeIntent: AppIntent {
    static let title: LocalizedStringResource = "アプリの使用時間を足す"
    static let description: IntentDescription? = IntentDescription("アプリの名前と使った分を LifeLog に残します。「その日の合計」にすると、足さずに置き換えます。")
    static let openAppWhenRun = false

    @Parameter(title: "アプリの名前")
    var app: String

    @Parameter(title: "分")
    var minutes: Double

    @Parameter(title: "その日の合計", default: false)
    var total: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        S26ASignalsStore.shared.addScreen(app: app, minutes: minutes, replace: total)
        Tally.add("s26a.intent.screen")
        return .result()
    }
}

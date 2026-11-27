#if DEBUG && targetEnvironment(simulator)
import Foundation
import UserNotifications

/// s25 の 堅6（2026-11-24）: 実機の確かめを、CI のシミュレーターの UI テスト（LifeLogUITests/S25CFlows.swift）に寄せるための口。
/// シミュレーターの Debug で、起動の引数に -screenshotDemo があるときだけ動く（配る IPA・実機には、このファイルごと入らない）。
/// 中身は全部作り物（DemoData と同じ「見本」）。人の名前・会話・頼まれごとは入れない。
/// - `-s25cMoreCandidates`: 見本のタスクの候補（仕事以外）を 4 つ足す（強い候補が 5 つ＝「今日の候補」は 3 件、残りは畳む、を確かめる）。
///   2026-11-27（s30）からタスクタブは仕事以外だけなので、足すのも仕事以外にし、いちばん古い 1 つを足して畳まれる分を作る
/// - `-s25cTap <名前>`: 起動して少したってから、知らせを押したときと同じ道（S23TapRules.tap → S23Notices.perform）で画面を開く。
///   名前は下の `scenarios`（s23 の 知1 の表 S23NoticeCatalog のうち、押すと質問・様子の画面が開くもの）
enum S25CUIHooks {
    struct Scenario {
        let id: String
        let category: String
        let info: [String: Any]
    }

    /// 押す知らせの見本（名前 → 知らせの名前・カテゴリ・userInfo）。ids の "@task" は、見本の候補のいちばん目の id に置き換える
    static let scenarios: [String: Scenario] = [
        "watch-silent": Scenario(id: "watch-silent", category: "", info: [:]),
        "phone-stopped": Scenario(id: "phone-stopped", category: "", info: [:]),
        "taskFound": Scenario(id: "s25c-taskFound", category: "taskFound", info: ["ids": ["@task"]]),
        "promise": Scenario(id: "s25c-promise", category: "promise", info: ["ids": ["s25c-demo-promise"]]),
        "knowYesNo": Scenario(id: "s25c-know", category: "knowYesNo", info: ["kid": "s25c-demo-know", "kkind": "yesno"]),
        "s22review": Scenario(id: "s25c-review", category: "s22review", info: ["id": "s25c-demo-review"]),
        "holidayNote": Scenario(id: "s25c-holiday-note", category: "holidayNote", info: ["hkind": "note"]),
        "s23count": Scenario(id: "s23-count-1", category: S23NoticeCatalog.s23CountCategory,
                             info: ["start": Date.now.addingTimeInterval(-1800).timeIntervalSince1970,
                                    "day": ReviewRules.dayKey(.now)]),
        "who": Scenario(id: "s22-who-0", category: "", info: [:]),
        "placesNight": Scenario(id: "s23-places-s25c", category: "", info: [:]),
        "checklist": Scenario(id: "s23-version-s25c", category: "", info: [:]),
    ]

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func value(after name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// DemoData.install() のすぐあと（Pipeline が tasks.json を読む前）に呼ぶ
    static func afterDemoInstall() {
        guard DemoData.isOn, arguments.contains("-s25cMoreCandidates") else { return }
        let file = URL.applicationSupportDirectory.appendingPathComponent("tasks.json")
        guard let data = try? Data(contentsOf: file),
              var items = try? JSONDecoder().decode([TaskBook.Item].self, from: data) else { return }
        let said = Date.now.addingTimeInterval(-3600)
        // いちばん古い「見本の傘を返す」が今日の候補の外（「ほかの候補」）に畳まれる（S25CFlows が数えるのは残りの 3 つ）
        for (n, what) in ["見本の傘を返す", "見本の荷物を受け取る", "見本の請求書を確かめる", "見本の席を予約する"].enumerated() {
            var item = TaskBook.Item(what: what, said: said.addingTimeInterval(Double(n) * 60), source: .conversation,
                                     state: .candidate, work: false)
            item.agreed = true
            item.quote = "見本"
            items.append(item)
        }
        if let out = try? JSONEncoder().encode(items) { try? out.write(to: file, options: .atomic) }
    }

    /// LifeLogApp の init の終わり（S23Book.install のあと）に呼ぶ
    @MainActor
    static func start(_ pipeline: Pipeline) {
        guard DemoData.isOn, let name = value(after: "-s25cTap"), let scenario = scenarios[name] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var info = scenario.info
            if let ids = info["ids"] as? [String] {
                let first = pipeline.tasks.candidates.first?.id ?? pipeline.tasks.items.first?.id ?? "s25c-none"
                info["ids"] = ids.map { $0 == "@task" ? first : $0 }
            }
            let content = UNMutableNotificationContent()
            content.title = "見本の知らせ"
            content.body = "見本の知らせの文です。"
            content.categoryIdentifier = scenario.category
            content.userInfo = info
            guard let tap = S23TapRules.tap(identifier: scenario.id, category: scenario.category,
                                            action: S23TapRules.defaultAction, userInfo: info) else {
                print("S25C: 知らせ \(name) は押した先が無い")
                return
            }
            S23Notices.perform(tap, identifier: scenario.id, content: content)
        }
    }
}
#endif

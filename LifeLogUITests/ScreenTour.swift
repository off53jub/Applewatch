import XCTest

/// 全部の画面を開いて写真を撮る（2026-11-06）。
/// CI のシミュレーターで、見本の記録（作り物）を入れたアプリを起動し、下のタブと設定の一覧の行を1つずつ開く。
/// 開いたとたんに落ちたら失敗にする。写真は結果に残し、CI が一覧の画像にまとめる。
/// 危ない操作（録音・消す・送る・書く など）の行は押さない。行ごとに起動し直すので、前の操作の影響を受けない。
final class ScreenTour: XCTestCase {
    private var shot = 0

    private static let tabs = ["今日", "タスク", "ライブ", "記録", "人と場所"]
    /// 押さない行（中身を変える・外に送る・権限を求める操作）
    private static let avoid = ["録音", "印を付ける", "消す", "削除", "ログイン", "ログアウト", "書く", "送る", "戻す",
                                "まとめ直", "始める", "止める", "控えから", "取り込", "入れ直", "リセット", "初期化", "全部",
                                "直す", "まとめる", "付け替", "分ける", "選ぶ", "撮る", "許可"]

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotDemo", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        dismissAlerts()
        return app
    }

    /// 通知・位置などの許可のたずねを閉じる（許可しない）
    private func dismissAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<4 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 0.7) else { return }
            var tapped = false
            for name in ["許可しない", "Don’t Allow", "Don't Allow", "後で", "Not Now", "OK", "閉じる", "Close"] {
                let b = alert.buttons[name]
                if b.exists { b.tap(); tapped = true; break }
            }
            if !tapped, alert.buttons.count > 0 { alert.buttons.element(boundBy: 0).tap() }
        }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        shot += 1
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = String(format: "%03d %@", shot, name)
        a.lifetime = .keepAlways
        add(a)
    }

    private func alive(_ app: XCUIApplication, after name: String) -> Bool {
        if app.state == .runningForeground { return true }
        XCTFail("「\(name)」を開いたら、アプリが落ちた・閉じた")
        return false
    }

    private func openTab(_ app: XCUIApplication, _ tab: String) {
        let b = app.tabBars.buttons[tab]
        if b.waitForExistence(timeout: 15) { b.tap() }
        sleep(1)
    }

    private func openSettings(_ app: XCUIApplication) -> Bool {
        let b = app.navigationBars.buttons["設定"]
        guard b.waitForExistence(timeout: 8) else { return false }
        b.tap()
        sleep(2)
        return true
    }

    /// いま見えている一覧の行の見出し（スイッチ・入力欄の行と、危ない操作の行は除く）
    private func visibleRows(_ app: XCUIApplication) -> [String] {
        var out: [String] = []
        for cell in app.cells.allElementsBoundByIndex.prefix(60) where cell.isHittable {
            if cell.switches.count > 0 || cell.textFields.count > 0 || cell.sliders.count > 0 { continue }
            let text = cell.staticTexts.firstMatch
            let label = text.exists ? text.label : cell.label
            guard !label.isEmpty, label.count <= 40, !out.contains(label),
                  !Self.avoid.contains(where: { label.contains($0) }) else { continue }
            out.append(label)
        }
        return out
    }

    /// 開く先の候補（下に何回めくった所にあるか）
    private struct Target {
        let tab: String
        let settings: Bool
        let swipes: Int
        let row: String
    }

    private func collect(_ app: XCUIApplication, tab: String, settings: Bool, pages: Int, limit: Int) -> [Target] {
        var seen: [String] = []
        var out: [Target] = []
        for page in 0..<pages {
            for row in visibleRows(app) where !seen.contains(row) {
                seen.append(row)
                out.append(Target(tab: tab, settings: settings, swipes: page, row: row))
            }
            if out.count >= limit { break }
            app.swipeUp()
            sleep(1)
        }
        return Array(out.prefix(limit))
    }

    func testTourAllScreens() {
        var app = launch()
        var targets: [Target] = []
        // 1. 下のタブ
        for tab in Self.tabs {
            openTab(app, tab)
            guard alive(app, after: tab) else { app = launch(); continue }
            snap(app, tab)
            targets += collect(app, tab: tab, settings: false, pages: 2, limit: 10)
        }
        // 2. 設定（「今日」の右上の歯車）
        openTab(app, "今日")
        if openSettings(app), alive(app, after: "設定") {
            snap(app, "設定")
            targets += collect(app, tab: "今日", settings: true, pages: 8, limit: 40)
        }
        // 3. 行を1つずつ開く（毎回起動し直す）
        for t in targets {
            app.terminate()
            app = launch()
            openTab(app, t.tab)
            if t.settings, !openSettings(app) { continue }
            for _ in 0..<t.swipes {
                app.swipeUp()
                sleep(1)
            }
            var cell = app.cells.containing(NSPredicate(format: "label == %@", t.row)).firstMatch
            if !cell.exists { cell = app.cells.matching(NSPredicate(format: "label == %@", t.row)).firstMatch }
            guard cell.exists, cell.isHittable else { continue }
            cell.tap()
            sleep(2)
            dismissAlerts()
            let name = (t.settings ? "設定 › " : t.tab + " › ") + t.row
            guard alive(app, after: name) else { continue }
            snap(app, name)
        }
        XCTAssertGreaterThan(shot, 5, "写真が少なすぎる（画面を開けていない）")
    }
}

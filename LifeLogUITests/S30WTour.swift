import XCTest

/// s30 の仕事タブ（2026-11-27。S30WViews.swift）を撮る。見本の写しは DemoDataS30W.swift（作りもの）。
/// 下のタブの「仕事」はタブ担当（S30T）が足す。まだ無い枝では「見つからない」を撮るだけで落とさない。
/// 押すのは開く行と柱の開け閉めだけ（丸・「入れる」「違う」「戻す」・＋は押さない）。
final class S30WTour: XCTestCase {
    private var shot = 0

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotDemo", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"] + extra
        app.launch()
        dismissAlerts()
        return app
    }

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
        a.name = String(format: "s30w %03d %@", shot, name)
        a.lifetime = .keepAlways
        add(a)
    }

    private func alive(_ app: XCUIApplication, after name: String) -> Bool {
        if app.state == .runningForeground { return true }
        XCTFail("「\(name)」を開いたら、アプリが落ちた・閉じた")
        return false
    }

    /// 仕事タブを開く（無ければ「見つからない」を撮って false）
    private func openWork(_ app: XCUIApplication, place: String) -> Bool {
        let b = app.tabBars.buttons["仕事"]
        guard b.waitForExistence(timeout: 15) else {
            snap(app, place + " - 仕事タブが見つからない")
            return false
        }
        b.tap()
        sleep(2)
        return alive(app, after: place)
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        let button = app.buttons.matching(p).firstMatch
        if button.exists { return button }
        return app.staticTexts.matching(p).firstMatch
    }

    @discardableResult
    private func tapFinding(_ app: XCUIApplication, _ text: String, swipes: Int = 8, place: String) -> Bool {
        for i in 0...swipes {
            let e = element(app, containing: text)
            if e.exists && e.isHittable {
                e.tap()
                sleep(2)
                return alive(app, after: place + " › " + text)
            }
            if i < swipes {
                app.swipeUp()
                sleep(1)
            }
        }
        snap(app, place + " - 見つからない: " + text)
        return false
    }

    /// 上から下までめくって撮る
    private func scrollShots(_ app: XCUIApplication, _ place: String, pages: Int) {
        for i in 0..<pages {
            snap(app, place + " \(i + 1)")
            app.swipeUp()
            sleep(1)
        }
    }

    func testWorkTabWithReport() {
        var app = launch()
        guard openWork(app, place: "仕事") else { return }
        scrollShots(app, "仕事（報告あり）", pages: 7)
        // 根拠の発言
        app.terminate()
        app = launch()
        guard openWork(app, place: "仕事") else { return }
        if tapFinding(app, "根拠の発言", swipes: 2, place: "仕事") {
            snap(app, "仕事 › 根拠の発言")
        }
        // 柱を開く（急ぎでない柱）→ あと N 件 → 柱の全部
        app.terminate()
        app = launch()
        guard openWork(app, place: "仕事") else { return }
        if tapFinding(app, "テストの進み", place: "仕事") {
            snap(app, "仕事 - 柱を開いた")
            app.swipeUp()
            sleep(1)
            snap(app, "仕事 - 柱を開いた（下）")
            if tapFinding(app, "この柱の全部", swipes: 3, place: "仕事 - 柱") {
                scrollShots(app, "仕事 › 柱の全部", pages: 2)
            }
        }
        // 外の話・前の一覧
        for row in ["ほかの部署・社内の話", "前の一覧"] {
            app.terminate()
            app = launch()
            guard openWork(app, place: "仕事") else { return }
            if tapFinding(app, row, swipes: 12, place: "仕事") {
                snap(app, "仕事 › " + row)
            }
        }
        // 仕事のまとめの一覧（右上の＋「仕事のまとめを取り込む」と取り違えないよう、印で探す）
        app.terminate()
        app = launch()
        guard openWork(app, place: "仕事") else { return }
        let digests = app.buttons["s30w.digests"]
        for _ in 0..<12 where !(digests.exists && digests.isHittable) {
            app.swipeUp()
            sleep(1)
        }
        if digests.exists && digests.isHittable {
            digests.tap()
            sleep(2)
            if alive(app, after: "仕事 › 仕事のまとめ") { snap(app, "仕事 › 仕事のまとめ") }
        } else {
            snap(app, "仕事 - 見つからない: 仕事のまとめ")
        }
    }

    func testWorkTabWithoutReport() {
        let app = launch(["-s30wNoReport"])
        guard openWork(app, place: "仕事（機械の並べ方）") else { return }
        scrollShots(app, "仕事（機械の並べ方）", pages: 6)
        XCTAssertTrue(app.state == .runningForeground)
    }
}

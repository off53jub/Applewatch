import XCTest

/// s32 の AI の理解（2026-11-27。S32AViews.swift）を撮る。見本は DemoDataS32A.swift（作りもの）。
/// 仕事タブのいちばん下の「AI の理解」を開いて、言葉・人とチームの地図・仕組みの図・番号の早見・決まったことの台帳・話題の糸・通信簿を撮る。
/// 項目を押したままにして「違う…」のメニューを開いて撮る（中の行は押さない＝送らない）。仕事のまとめの頼み方のボタンも撮る（押さない）。
final class S32ATour: XCTestCase {
    private var shot = 0

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
        a.name = String(format: "s32a %03d %@", shot, name)
        a.lifetime = .keepAlways
        add(a)
    }

    private func alive(_ app: XCUIApplication, after name: String) -> Bool {
        if app.state == .runningForeground { return true }
        XCTFail("「\(name)」を開いたら、アプリが落ちた・閉じた")
        return false
    }

    private func openWork(_ app: XCUIApplication) -> Bool {
        let b = app.tabBars.buttons["仕事"]
        guard b.waitForExistence(timeout: 15) else {
            snap(app, "仕事タブが見つからない")
            return false
        }
        b.tap()
        sleep(2)
        return alive(app, after: "仕事")
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        let button = app.buttons.matching(p).firstMatch
        if button.exists { return button }
        return app.staticTexts.matching(p).firstMatch
    }

    @discardableResult
    private func find(_ app: XCUIApplication, _ text: String, swipes: Int) -> XCUIElement? {
        for i in 0...swipes {
            let e = element(app, containing: text)
            if e.exists && e.isHittable { return e }
            if i < swipes {
                app.swipeUp()
                sleep(1)
            }
        }
        snap(app, "見つからない: " + text)
        return nil
    }

    /// 仕事タブを開き、いちばん下の「AI の理解」を開く
    private func openKnow(_ app: XCUIApplication) -> Bool {
        guard openWork(app) else { return false }
        // 印で探し、見つからなければ字で探す（畳む行の印が出ない OS もあるので）
        var know = app.buttons["s32a.know"]
        for _ in 0..<16 {
            if know.exists && know.isHittable { break }
            let byLabel = element(app, containing: "AI の理解")
            if byLabel.exists && byLabel.isHittable {
                know = byLabel
                break
            }
            app.swipeUp()
            sleep(1)
        }
        guard know.exists && know.isHittable else {
            snap(app, "見つからない: AI の理解")
            return false
        }
        know.tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        return alive(app, after: "AI の理解")
    }

    func testKnowSection() {
        var app = launch()
        guard openKnow(app) else { return }
        snap(app, "仕事 - AI の理解（開いた）")
        for row in ["言葉", "人とチームの地図", "仕組みの図", "番号の早見", "決まったことの台帳", "話題の糸", "通信簿"] {
            app.terminate()
            app = launch()
            guard openKnow(app) else { return }
            guard let e = find(app, row, swipes: 2) else { continue }
            e.tap()
            sleep(2)
            guard alive(app, after: "AI の理解 › " + row) else { return }
            snap(app, "AI の理解 › " + row)
            if row == "言葉", let first = find(app, "打鍵", swipes: 0) {
                first.tap()
                sleep(2)
                if alive(app, after: "言葉カード") { snap(app, "AI の理解 › 言葉 › 言葉カード") }
            }
        }
    }

    func testFixMenuAndTermLink() {
        let app = launch()
        guard openWork(app) else { return }
        // 今日の一手の 1 つめを押したままにして「違う…」を開く（中の行は押さない）
        if let item = find(app, "打鍵できなかった", swipes: 4) {
            item.press(forDuration: 1.2)
            sleep(1)
            snap(app, "仕事 - 項目を押したまま")
            let wrong = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "違う")).firstMatch
            if wrong.waitForExistence(timeout: 3) {
                wrong.tap()
                sleep(1)
                snap(app, "仕事 - 違う…のメニュー")
            }
        }
        XCTAssertTrue(app.state == .runningForeground)
    }

    func testPromptButtons() {
        let app = launch()
        guard openWork(app) else { return }
        let digests = app.buttons["s30w.digests"]
        for _ in 0..<12 where !(digests.exists && digests.isHittable) {
            app.swipeUp()
            sleep(1)
        }
        guard digests.exists && digests.isHittable else {
            snap(app, "見つからない: 仕事のまとめ")
            return
        }
        digests.tap()
        sleep(2)
        if alive(app, after: "仕事のまとめ") { snap(app, "仕事のまとめ（頼み方のボタン）") }
    }
}

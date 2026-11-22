import XCTest

/// 主な 20 画面を「明るい・暗い・文字を最大」の 3 通りで撮って、1 枚に並べる材料にする（s22 見1）。
/// 同じ起動で、文字を最大にしたときに画面の外にはみ出す・つぶれる・「…」で切れた文字を数える（s22 見2。報告だけで失敗にはしない）。
/// 押すのは開く行だけ（ScreenTour と同じ。見本の記録だけ・危ない操作は押さない）。
/// CI では「画面の一覧」ジョブだけが動かす（ScreenTour のジョブは -skip-testing で外す）。
final class ScreenMatrix: XCTestCase {
    private struct Spec {
        let name: String
        let tab: String
        var settings = false
        var segment: String? = nil
        var row: String? = nil
    }

    /// 主な 20 画面（下のタブ 5・記録の切り替え 4・歯車の中 2・よく開く行 9）
    private static let specs: [Spec] = [
        Spec(name: "今日", tab: "今日"),
        Spec(name: "タスク", tab: "タスク"),
        Spec(name: "直す", tab: "直す"),
        Spec(name: "記録 日ごと", tab: "記録", segment: "日ごと"),
        Spec(name: "記録 人", tab: "記録", segment: "人"),
        Spec(name: "記録 場所", tab: "記録", segment: "場所"),
        Spec(name: "記録 お金", tab: "記録", segment: "お金"),
        Spec(name: "ふり返り", tab: "ふり返り"),
        Spec(name: "歯車 点検", tab: "今日", settings: true, segment: "点検"),
        Spec(name: "歯車 設定", tab: "今日", settings: true, segment: "設定"),
        Spec(name: "確かめる（○×）", tab: "直す", row: "確かめる（○×）"),
        Spec(name: "検品表", tab: "ふり返り", row: "検品表（通信簿）"),
        Spec(name: "今月の物語", tab: "ふり返り", row: "今月の物語"),
        Spec(name: "休日のページ", tab: "ふり返り", row: "休日のページ"),
        Spec(name: "面談の 1 枚", tab: "ふり返り", row: "面談の 1 枚"),
        Spec(name: "1 日の帯", tab: "記録", segment: "日ごと", row: "1 日の帯で選ぶ"),
        Spec(name: "見た目", tab: "今日", settings: true, segment: "設定", row: "見た目（暗い"),
        Spec(name: "言葉の一覧", tab: "今日", settings: true, segment: "設定", row: "言葉の一覧"),
        Spec(name: "守りの 1 枚", tab: "今日", settings: true, segment: "設定", row: "守りの 1 枚"),
        Spec(name: "知らせの履歴", tab: "今日", settings: true, segment: "設定", row: "知らせの便りと履歴"),
    ]

    private var shot = 0
    private var findings: [[String: String]] = []

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-screenshotDemo", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                    "-llAppearance", mode == "明" ? "light" : "dark"]
        if mode == "最大" {
            args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"]
        }
        app.launchArguments = args
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

    @discardableResult
    private func openSegment(_ app: XCUIApplication, _ name: String) -> Bool {
        let b = app.segmentedControls.buttons[name]
        guard b.waitForExistence(timeout: 5) else { return false }
        b.tap()
        sleep(1)
        return true
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        let button = app.buttons.matching(p).firstMatch
        if button.exists { return button }
        return app.staticTexts.matching(p).firstMatch
    }

    /// 下にめくりながら探して押す（見つからなければ false。撮らない）
    private func tapFinding(_ app: XCUIApplication, _ text: String, swipes: Int = 8) -> Bool {
        for i in 0...swipes {
            let e = element(app, containing: text)
            if e.exists && e.isHittable {
                e.tap()
                sleep(2)
                dismissAlerts()
                return app.state == .runningForeground
            }
            if i < swipes {
                app.swipeUp()
                sleep(1)
            }
        }
        return false
    }

    private func snap(_ app: XCUIApplication, mode: String, index: Int, name: String, reached: Bool) {
        shot += 1
        let a = XCTAttachment(screenshot: app.screenshot())
        // 一覧の画像を作る script が「モード|番号|名前|到達」と読む
        a.name = String(format: "%03d %@|%02d|%@|%d", shot, mode, index, name, reached ? 1 : 0)
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: 見2: はみ出し・つぶれ・「…」を数える（報告だけ）

    private func note(_ kind: String, mode: String, screen: String, el: XCUIElementSnapshot) {
        let label = el.label.replacingOccurrences(of: "\n", with: " ")
        findings.append(["kind": kind, "mode": mode, "screen": screen,
                         "label": String(label.prefix(40)),
                         "frame": "x \(Int(el.frame.minX))〜\(Int(el.frame.maxX)) / 幅 \(Int(el.frame.width))"])
    }

    private func scan(_ app: XCUIApplication, mode: String, screen: String) {
        guard let root = try? app.snapshot() else { return }
        let width = app.frame.width
        var seen = Set<String>()
        func walk(_ s: XCUIElementSnapshot) {
            let type = s.elementType
            let isText = type == .staticText || type == .button || type == .textField || type == .textView || type == .link
            if isText, !s.label.isEmpty, s.frame.width > 1, s.frame.height > 1 {
                let key = "\(type.rawValue)|\(s.label)|\(Int(s.frame.minX))"
                if !seen.contains(key) {
                    seen.insert(key)
                    // 横にはみ出す（縦は、めくれば見えるので数えない）
                    if s.frame.minX < -2 || s.frame.maxX > width + 2 {
                        note("はみ出し", mode: mode, screen: screen, el: s)
                    }
                    // 「…」で終わる（アプリ自身が切った文。SwiftUI の自動の省略は、読める文字が変わらないので数えられない）
                    if s.label.hasSuffix("…") || s.label.hasSuffix("...") {
                        note("省略の印", mode: mode, screen: screen, el: s)
                    }
                    // 文字があるのに幅がほぼ無い（つぶれ）
                    if type == .staticText, s.label.count >= 4, s.frame.width < 24 {
                        note("つぶれ", mode: mode, screen: screen, el: s)
                    }
                }
            }
            for c in s.children { walk(c) }
        }
        walk(root)
    }

    // MARK: 本体

    private func run(mode: String) {
        for (i, spec) in Self.specs.enumerated() {
            let app = launch(mode: mode)
            var reached = true
            openTab(app, spec.tab)
            if spec.settings, !openSettings(app) { reached = false }
            if reached, let seg = spec.segment, !openSegment(app, seg) { reached = false }
            if reached, let row = spec.row, !tapFinding(app, row) { reached = false }
            if app.state != .runningForeground {
                XCTFail("「\(spec.name)」（\(mode)）を開いたら、アプリが落ちた・閉じた")
                continue
            }
            snap(app, mode: mode, index: i + 1, name: spec.name, reached: reached)
            if reached { scan(app, mode: mode, screen: spec.name) }
            app.terminate()
        }
        if let data = try? JSONSerialization.data(withJSONObject: findings, options: [.prettyPrinted, .sortedKeys]) {
            let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            a.name = "報告|\(mode)|json"
            a.lifetime = .keepAlways
            add(a)
        }
        XCTAssertGreaterThan(shot, 10, "\(mode): 写真が少なすぎる")
    }

    func testGridLight() { run(mode: "明") }
    func testGridDark() { run(mode: "暗") }
    func testGridLargeText() { run(mode: "最大") }
}

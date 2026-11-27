import XCTest

/// s25 の 堅6（2026-11-24）: 本人が実機で確かめていたものを、CI のシミュレーターで通す（必須にはしない）。
/// 見本の記録（作り物。-screenshotDemo）で動かす。アプリ側の口は LifeLog/S25CUIHooks.swift。
/// 1. タスクの「今日の候補」が 3 件まで（強い候補のうち 3 つまでが見え、残りは「ほかの候補」に畳まれている。タスクタブは仕事以外だけ）
/// 2. 「今日」の上の 3 枚（録れているか・今日の三つ・今日の 1 問）が、この順で上に出る
/// 3. 知らせを押した先（s23 の 知1 の表のうち、質問・様子の画面が開くもの）が、その画面を開く
/// 文言で探すので、画面の言葉を変えたら、ここも直す。
final class S25CFlows: XCTestCase {
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
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "s25c " + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func openTab(_ app: XCUIApplication, _ tab: String) {
        let b = app.tabBars.buttons[tab]
        if b.waitForExistence(timeout: 15) { b.tap() }
        sleep(1)
    }

    /// 文字の見える所（一覧の行・見出し）から探す。見つかるまで下にめくる（最大 pages 回）
    private func find(_ app: XCUIApplication, _ text: String, pages: Int = 4) -> XCUIElement? {
        let e = app.staticTexts[text]
        for _ in 0...pages {
            if e.waitForExistence(timeout: 2) { return e }
            app.swipeUp()
        }
        return nil
    }

    // MARK: 1. 今日の候補は 3 件まで

    func testTodayCandidatesAreThree() {
        // s26 の C（2026-11-25）: 「今日すでに見せた候補」の覚え（s24.todayCandidates）を、この起動だけ空にする（引数の決まりの層で上書き。保存はしない）。
        //   見本の候補は起動のたびに id が変わるので、前の試し（知らせを押す 11 回の起動）が覚えた古い id で 3 件の枠が埋まり、
        //   「今日の候補」が 0 件になっていた（11/24 の main の実行で落ちた理由。仮説: 記録から読んだ。本物の候補は id が変わらないのでアプリの不具合ではない）
        let app = launch(["-s25cMoreCandidates", "-s24.todayCandidates", "s26c-reset"])
        openTab(app, "タスク")
        // 「やる」のページ（初めに開く所）。見出し「今日の候補」が出る
        XCTAssertNotNil(find(app, "今日の候補"), "タスクに「今日の候補」が出ない")
        // 強い候補は 5 つ（仕事の「見本の資料を送る」＋S25CUIHooks で足した仕事以外の 4 つ）。今日の候補は 3 件までなので、残りは畳まれる。
        // 2026-11-27（s30）からタスクタブは仕事以外だけ（仕事の「見本の資料を送る」は仕事タブ）。いちばん古い「見本の傘を返す」は
        // 「ほかの候補」に畳まれる。数えるのは新しい 3 つだけ（「見本の資料を送る」が今日の 3 件に入った日は 2 つ見える）
        let added = ["見本の荷物を受け取る", "見本の請求書を確かめる", "見本の席を予約する"]
        let shown = added.filter { app.staticTexts[$0].exists }.count
        snap(app, "今日の候補")
        XCTAssertTrue((2...3).contains(shown), "今日の候補の見え方がおかしい（足した 3 つのうち見えたのは \(shown) 件）")
        XCTAssertNotNil(find(app, "ほかの候補", pages: 3), "4 件目が「ほかの候補」に畳まれていない（3 件までになっていない）")
    }

    // MARK: 2. 「今日」の上の 3 枚

    func testTodayTopThreeCards() {
        let app = launch()
        openTab(app, "今日")
        let three = app.staticTexts["今日の三つ"]
        let ask = app.staticTexts["今日の 1 問"]
        XCTAssertTrue(three.waitForExistence(timeout: 15), "「今日の三つ」が出ない")
        XCTAssertTrue(ask.waitForExistence(timeout: 5) || find(app, "今日の 1 問", pages: 2) != nil, "「今日の 1 問」が出ない")
        // 録れているか（あいさつ・日付の 1 枚）が、今日の三つより上
        let date = Date.now.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "ja_JP")))
        let hero = app.staticTexts[date]
        if hero.exists, three.exists {
            XCTAssertLessThan(hero.frame.minY, three.frame.minY, "録れているかの 1 枚が、今日の三つより下にある")
        }
        if three.exists, ask.exists {
            XCTAssertLessThan(three.frame.minY, ask.frame.minY, "今日の三つが、今日の 1 問より下にある")
        }
        // ほかのカードは畳まれている
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ほかのカード")).firstMatch
        XCTAssertTrue(more.exists || find(app, "ほかのカード", pages: 3) != nil
                      || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ほかのカード")).count > 0,
                      "「ほかのカード」の行が無い")
        snap(app, "今日の上の 3 枚")
    }

    // MARK: 3. 知らせを押した先

    /// (S25CUIHooks の名前, 開くはずの画面の題, ほかに見えるはずの文字)
    private static let taps: [(String, String, String?)] = [
        ("watch-silent", "いまの様子", "時計から 10 分以上、録音が届いていません。"),
        ("phone-stopped", "いまの様子", "iPhone の録音が止まっています。"),
        ("taskFound", "タスク", nil),
        ("promise", "約束", nil),
        ("knowYesNo", "自分を知る", nil),
        ("s22review", "確かめ待ち", nil),
        ("holidayNote", "一言", nil),
        ("s23count", "何人でしたか？", nil),
        ("who", "誰と話しましたか？", nil),
        ("placesNight", "今日の名前の無い場所", nil),
        ("checklist", "確かめてほしいこと", nil),
    ]

    func testNoticeTapsOpenTheirScreens() {
        var failed: [String] = []
        for (name, title, text) in Self.taps {
            let app = launch(["-s25cTap", name])
            let bar = app.navigationBars[title]
            let close = app.buttons["閉じる"]
            // 知らせのシートは「閉じる」が付く（タブの画面と見分ける）
            let opened = bar.waitForExistence(timeout: 15) && close.waitForExistence(timeout: 5)
            var ok = opened
            if let text, opened {
                ok = app.staticTexts[text].waitForExistence(timeout: 5)
            }
            snap(app, "知らせ " + name)
            if !ok { failed.append(name + "→" + title) }
            app.terminate()
        }
        XCTAssertTrue(failed.isEmpty, "押しても開かなかった知らせ: " + failed.joined(separator: "・"))
    }
}

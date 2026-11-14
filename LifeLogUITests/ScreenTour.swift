import XCTest

/// 全部の画面を開いて写真を撮る（2026-11-06）。
/// CI のシミュレーターで、見本の記録（作り物）を入れたアプリを起動し、下のタブと設定の一覧の行を1つずつ開く。
/// 2026-11-12 のタブの組み替えから、「記録」の上の切り替え（日ごと・人・場所・お金）と、歯車の中の「点検」「設定」もそれぞれ開く。
/// 開いたとたんに落ちたら失敗にする。写真は結果に残し、CI が一覧の画像にまとめる。
/// 危ない操作（録音・消す・送る・書く など）の行は押さない。行ごとに起動し直すので、前の操作の影響を受けない。
final class ScreenTour: XCTestCase {
    private var shot = 0

    private static let tabs = ["今日", "タスク", "直す", "記録", "ふり返り"]
    /// 「記録」の上の切り替え（いちばん左の「日ごと」はタブを開いたときに撮る）
    private static let recordPages = ["日ごと", "人", "場所", "お金"]
    /// 歯車の中の切り替え
    private static let settingsParts = ["点検", "設定"]
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

    /// 上の切り替え（segmented）を押す。前に開いたものを覚えているので、毎回押す
    @discardableResult
    private func openSegment(_ app: XCUIApplication, _ name: String) -> Bool {
        let b = app.segmentedControls.buttons[name]
        guard b.waitForExistence(timeout: 5) else { return false }
        b.tap()
        sleep(1)
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
        /// 上の切り替え（無ければ nil）
        let segment: String?
        let swipes: Int
        let row: String
    }

    private func collect(_ app: XCUIApplication, tab: String, settings: Bool, segment: String? = nil,
                         pages: Int, limit: Int) -> [Target] {
        var seen: [String] = []
        var out: [Target] = []
        for page in 0..<pages {
            for row in visibleRows(app) where !seen.contains(row) {
                seen.append(row)
                out.append(Target(tab: tab, settings: settings, segment: segment, swipes: page, row: row))
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
            if tab == "記録" {
                // 上の切り替えを1つずつ
                for page in Self.recordPages {
                    guard openSegment(app, page) else { continue }
                    guard alive(app, after: tab + " - " + page) else { app = launch(); break }
                    snap(app, tab + " - " + page)
                    targets += collect(app, tab: tab, settings: false, segment: page, pages: 2, limit: page == "日ごと" ? 8 : 6)
                    app.swipeDown()
                    sleep(1)
                }
                continue
            }
            snap(app, tab)
            targets += collect(app, tab: tab, settings: false, pages: 2, limit: 10)
        }
        // 2. 歯車（「今日」の右上）の中の「点検」と「設定」
        for part in Self.settingsParts {
            app.terminate()
            app = launch()
            openTab(app, "今日")
            guard openSettings(app), alive(app, after: "設定") else { continue }
            openSegment(app, part)
            snap(app, "歯車 - " + part)
            targets += collect(app, tab: "今日", settings: true, segment: part, pages: part == "点検" ? 2 : 8, limit: part == "点検" ? 12 : 40)
        }
        // 3. 行を1つずつ開く（毎回起動し直す）
        for t in targets {
            app.terminate()
            app = launch()
            openTab(app, t.tab)
            if t.settings, !openSettings(app) { continue }
            if let segment = t.segment, !openSegment(app, segment) { continue }
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
            let place = t.settings ? "歯車" : t.tab
            let name = place + (t.segment.map { " - " + $0 } ?? "") + " › " + t.row
            guard alive(app, after: name) else { continue }
            snap(app, name)
        }
        XCTAssertGreaterThan(shot, 5, "写真が少なすぎる（画面を開けていない）")
    }

    // MARK: - 家の PC の写しの画面（2026-11-13）

    /// label に text を含むボタン（無ければ文字）。List の行は、中の文をつないだ名前のボタンになる
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        let button = app.buttons.matching(p).firstMatch
        if button.exists { return button }
        return app.staticTexts.matching(p).firstMatch
    }

    /// 下にめくりながら探して押す。見つからなければ、その画面を「見つからない」として撮る（落ちたときだけ失敗）
    @discardableResult
    private func tapFinding(_ app: XCUIApplication, _ text: String, swipes: Int = 6, place: String) -> Bool {
        for i in 0...swipes {
            let e = element(app, containing: text)
            if e.exists && e.isHittable {
                e.tap()
                sleep(2)
                dismissAlerts()
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

    /// 見本の写し（DemoData.installHomeFeeds）で、提案・話し手の疑い・今日の10件・PLAUD で埋めた所を開いて撮る。
    /// 押すのは開く行だけ（「受ける」「自分の声にする」などは押さない）
    func testTourHomeFeeds() {
        // 1. 今日の提案のカードと、「提案」の画面
        var app = launch()
        openTab(app, "今日")
        if tapFinding(app, "提案をすべて見る", place: "今日") {
            snap(app, "今日 › 提案")
            app.swipeUp()
            sleep(1)
            snap(app, "今日 › 提案（下）")
        }
        app.terminate()
        app = launch()
        openTab(app, "今日")
        for _ in 0..<2 {
            app.swipeUp()
            sleep(1)
        }
        snap(app, "今日 - 提案のカード")

        // 2. 直す: 職場の自分の声を10件
        app.terminate()
        app = launch()
        openTab(app, "直す")
        snap(app, "直す - 話し手の疑い・今日の10件")
        if tapFinding(app, "職場の自分の声を10件確かめる", place: "直す") {
            snap(app, "直す › 職場の自分の声（今日の10件）")
        }

        // 3. 直す: 話し手の疑い（全部と、1つ）
        app.terminate()
        app = launch()
        openTab(app, "直す")
        if tapFinding(app, "話し手の疑いをすべて見る", place: "直す") {
            snap(app, "直す › 話し手の疑い")
            if tapFinding(app, "お昼までに送ります", swipes: 2, place: "直す › 話し手の疑い") {
                snap(app, "直す › 話し手の疑い › 1つ")
            }
        }

        // 4. 記録 → 日ごと → 今日 → PLAUD で埋めた所
        app.terminate()
        app = launch()
        openTab(app, "記録")
        openSegment(app, "日ごと")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        if tapFinding(app, f.string(from: Date()), swipes: 2, place: "記録 - 日ごと") {
            if tapFinding(app, "PLAUD で埋めた所", swipes: 2, place: "記録 › 今日") {
                snap(app, "記録 › 今日 › PLAUD で埋めた所")
            }
        }

        // 5. 記録 → 日ごと → PLAUD だけの日
        app.terminate()
        app = launch()
        openTab(app, "記録")
        openSegment(app, "日ごと")
        if tapFinding(app, f.string(from: Date().addingTimeInterval(-86400)), swipes: 3, place: "記録 - 日ごと") {
            tapFinding(app, "PLAUD で埋めた所", swipes: 1, place: "記録 › PLAUD だけの日")
            snap(app, "記録 › PLAUD だけの日")
        }

        // 6. 直す: 同じ人かも・まとめて OK・夜の読み直しの聞き間違い（2026-11-13。見本は DemoData.installAccuracy。
        //    「同じ人」「まとめて OK」などのボタンは押さない。見出しの文を探して、その場所を撮るだけ）
        app.terminate()
        app = launch()
        openTab(app, "直す")
        let found = element(app, containing: "同じ人かも")
        for _ in 0..<6 where !(found.exists && found.isHittable) {
            app.swipeUp()
            sleep(1)
        }
        snap(app, "直す - 同じ人かも")
        if tapFinding(app, "直す・そのまま", swipes: 3, place: "直す") {
            snap(app, "直す › 聞き間違いかも（夜の読み直しから）")
        }
    }

    // MARK: - 2026-11-13 の施策の画面

    /// 見本の写し（DemoData.installMothershipFeeds）で、今日の上の段・下の録音の1行・今日の記録・ふり返りの週のふり返り・
    /// 見立ての台帳・朝のまとめ 比べる・点検の精度の通信簿・あまり開かれていない画面・くわしい設定・アプリを開いた記録の使い方を撮る。
    /// 押すのは開く行だけ（「やった」「役に立った」「こっちがいい」「残す」などは押さない）
    func testTourMothershipFeeds() {
        // 1. 今日: 今日の三つ・次の予定の前に・夜の10秒（上から）と、畳んだ「今日の記録」
        var app = launch()
        openTab(app, "今日")
        snap(app, "今日 - 上の段と下の録音の1行")
        app.swipeUp()
        sleep(1)
        snap(app, "今日 - 夜の10秒・気をつけること")
        if tapFinding(app, "今日の記録", swipes: 4, place: "今日") {
            snap(app, "今日 - 今日の記録を開いた")
        }
        // 2. ふり返り: 今週のふり返り → 見立ての台帳、朝のまとめ 比べる
        app.terminate()
        app = launch()
        openTab(app, "ふり返り")
        snap(app, "ふり返り - 今週のふり返り")
        if tapFinding(app, "見立ての台帳", swipes: 3, place: "ふり返り") {
            snap(app, "ふり返り › 見立ての台帳")
        }
        app.terminate()
        app = launch()
        openTab(app, "ふり返り")
        if tapFinding(app, "朝のまとめ 比べる", swipes: 5, place: "ふり返り") {
            snap(app, "ふり返り › 朝のまとめ 比べる")
            app.swipeUp()
            sleep(1)
            snap(app, "ふり返り › 朝のまとめ 比べる（下）")
        }
        // 3. 歯車 → 点検: 精度の通信簿・あまり開かれていない画面
        for row in ["精度の通信簿", "あまり開かれていない画面"] {
            app.terminate()
            app = launch()
            openTab(app, "今日")
            guard openSettings(app) else { continue }
            openSegment(app, "点検")
            if tapFinding(app, row, swipes: 4, place: "歯車 - 点検") {
                snap(app, "歯車 › 点検 › " + row)
            }
        }
        // 4. 歯車 → 設定: ふだん と くわしい設定（下へめくりながら撮る）・アプリを開いた記録の使い方
        app.terminate()
        app = launch()
        openTab(app, "今日")
        if openSettings(app) {
            openSegment(app, "設定")
            snap(app, "歯車 - 設定（ふだん）")
            if tapFinding(app, "くわしい設定", swipes: 2, place: "歯車 - 設定") {
                for i in 0..<6 {
                    snap(app, "歯車 › くわしい設定 \(i + 1)")
                    app.swipeUp()
                    sleep(1)
                }
                if tapFinding(app, "アプリを開いた記録の使い方", swipes: 3, place: "歯車 › くわしい設定") {
                    snap(app, "歯車 › くわしい設定 › アプリを開いた記録の使い方")
                }
            }
        }
    }

    // MARK: - 2026-11-14 の強化案の画面

    /// 見本の写し（DemoData.installOneTimeline）で、1日の画面の年表の行（全部・会話だけ）・PayPay のスクショの取り込み（読めた行の見本）・
    /// 点検の反映の見張りを撮る。押すのは開く行と見方の切り替えだけ（「取り込む」「スクショを選ぶ」は押さない）
    func testTourOneTimeline() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        // 1. 記録 → 日ごと → 今日: 全部（会話のあいだに年表の行）と会話だけ
        var app = launch()
        openTab(app, "記録")
        openSegment(app, "日ごと")
        if tapFinding(app, f.string(from: Date()), swipes: 2, place: "記録 - 日ごと") {
            snap(app, "記録 › 今日（全部: 年表の行つき・過ごし方）")
            if openSegment(app, "会話ごと") {
                snap(app, "記録 › 今日（全部: 年表の行つき・会話ごと）")
            }
            if openSegment(app, "会話だけ") {
                snap(app, "記録 › 今日（会話だけ）")
            }
            // 次の確かめに残さないよう、元に戻す
            _ = openSegment(app, "全部")
            _ = openSegment(app, "過ごし方")
        }
        // 2. 記録 → 日ごと → 昨日（年表の写しだけの日）
        app.terminate()
        app = launch()
        openTab(app, "記録")
        openSegment(app, "日ごと")
        if tapFinding(app, f.string(from: Date().addingTimeInterval(-86400)), swipes: 3, place: "記録 - 日ごと") {
            snap(app, "記録 › 昨日（年表の行）")
        }
        // 3. 記録 → お金 → PayPay の履歴をスクショで取り込む
        app.terminate()
        app = launch()
        openTab(app, "記録")
        if openSegment(app, "お金") {
            snap(app, "記録 - お金（スクショの入口）")
            if tapFinding(app, "PayPay の履歴をスクショで取り込む", swipes: 4, place: "記録 - お金") {
                snap(app, "記録 › お金 › PayPay のスクショ")
                app.swipeUp()
                sleep(1)
                snap(app, "記録 › お金 › PayPay のスクショ（下）")
            }
        }
        // 4. 歯車 → 点検 → 反映の見張り
        app.terminate()
        app = launch()
        openTab(app, "今日")
        if openSettings(app) {
            openSegment(app, "点検")
            if tapFinding(app, "反映の見張り", swipes: 5, place: "歯車 - 点検") {
                snap(app, "歯車 › 点検 › 反映の見張り")
            }
        }
    }
}

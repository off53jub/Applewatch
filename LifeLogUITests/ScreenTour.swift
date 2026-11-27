import XCTest

/// 全部の画面を開いて写真を撮る（2026-11-06）。
/// CI のシミュレーターで、見本の記録（作り物）を入れたアプリを起動し、下のタブと設定の一覧の行を1つずつ開く。
/// 2026-11-12 のタブの組み替えから、「記録」の上の切り替え（日ごと・人・場所・お金。2026-11-27 から ふり返り も）と、歯車の中の「点検」「設定」もそれぞれ開く。
/// 開いたとたんに落ちたら失敗にする。写真は結果に残し、CI が一覧の画像にまとめる。
/// 危ない操作（録音・消す・送る・書く など）の行は押さない。行ごとに起動し直すので、前の操作の影響を受けない。
final class ScreenTour: XCTestCase {
    private var shot = 0

    /// 下のタブ（2026-11-27。s30 から 今日・タスク・仕事・直す・記録。前のふり返りタブは「記録」の上の切り替えの「ふり返り」）
    private static let tabs = ["今日", "タスク", "仕事", "直す", "記録"]
    /// 「記録」の上の切り替え（いちばん左の「日ごと」はタブを開いたときに撮る）
    private static let recordPages = ["日ごと", "人", "場所", "お金", "ふり返り"]
    /// 歯車の中の切り替え
    private static let settingsParts = ["点検", "設定"]
    /// 押さない行（中身を変える・外に送る・権限を求める操作）
    private static let avoid = ["録音", "印を付ける", "消す", "削除", "ログイン", "ログアウト", "書く", "送る", "戻す",
                                "まとめ直", "始める", "止める", "控えから", "取り込", "入れ直", "リセット", "初期化", "全部",
                                "直す", "まとめる", "付け替", "分ける", "選ぶ", "撮る", "許可",
                                // 「合ってる？」の答えのボタン（押すと母艦に答えを返す。2026-11-15）
                                "合ってる", "違う", "わからない"]

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
                    targets += collect(app, tab: tab, settings: false, segment: page, pages: 2,
                                       limit: page == "日ごと" ? 8 : page == "ふり返り" ? 10 : 6)
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
        // 2. ふり返り（記録の上の切り替え。2026-11-27 の s30 から）: 今週のふり返り → 見立ての台帳、朝のまとめ 比べる
        app.terminate()
        app = launch()
        openTab(app, "記録")
        openSegment(app, "ふり返り")
        snap(app, "ふり返り - 今週のふり返り")
        if tapFinding(app, "見立ての台帳", swipes: 3, place: "ふり返り") {
            snap(app, "ふり返り › 見立ての台帳")
        }
        app.terminate()
        app = launch()
        openTab(app, "記録")
        openSegment(app, "ふり返り")
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

    // MARK: - 2026-11-15 の強化案の画面

    /// 見本の写し（DemoData.installSettle）で、点検の「入れた施策の様子」「Claude の費用」・直すの「合ってる？」・
    /// 設定の「録り方の実験」を撮る。押すのは開く行だけ（「合ってる」「違う」「わからない」は押さない）
    func testTourSettle() {
        // 1. 歯車 → 点検 → 入れた施策の様子・Claude の費用（毎回起動し直す）
        for row in ["入れた施策の様子", "Claude の費用"] {
            let app = launch()
            openTab(app, "今日")
            guard openSettings(app) else { continue }
            openSegment(app, "点検")
            if tapFinding(app, row, swipes: 6, place: "歯車 - 点検") {
                snap(app, "歯車 › 点検 › " + row)
                app.swipeUp()
                sleep(1)
                snap(app, "歯車 › 点検 › " + row + "（下）")
            }
            app.terminate()
        }
        // 2. 直す: 合ってる？（いちばん上の方に出る。見えるところまでめくる）
        var app = launch()
        openTab(app, "直す")
        var found = false
        for _ in 0..<4 {
            if app.staticTexts["合ってる？"].exists || app.buttons["合ってる"].exists {
                found = true
                break
            }
            app.swipeUp()
            sleep(1)
        }
        snap(app, found ? "直す - 合ってる？" : "直す - 合ってる？（見つからない）")
        // 3. 歯車 → 設定 → くわしい設定 → 録り方の実験
        app.terminate()
        app = launch()
        openTab(app, "今日")
        if openSettings(app) {
            openSegment(app, "設定")
            if tapFinding(app, "くわしい設定", swipes: 8, place: "歯車 - 設定") {
                var shown = false
                for _ in 0..<12 {
                    if app.staticTexts["録り方の実験"].exists {
                        shown = true
                        break
                    }
                    app.swipeUp()
                }
                snap(app, shown ? "歯車 › くわしい設定 › 録り方の実験" : "歯車 › くわしい設定（録り方の実験が見つからない）")
            }
        }
    }

    // MARK: - s20 のデザイン（夜の青。2026-11-21）

    /// 見た目を決めて起動する（"dark"・"light"）。設定の @AppStorage("llAppearance") に起動の引数で入れる
    private func launch(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotDemo", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP", "-llAppearance", appearance]
        app.launch()
        dismissAlerts()
        return app
    }

    /// タブ（と歯車の中の切り替え）を開いて、行を押して撮る。行が無ければ「見つからない」の写真になる
    private func s20Shot(_ appearance: String, tab: String, settings: Bool = false, segment: String? = nil,
                         row: String?, name: String, swipes: Int = 0, band: Bool = false) {
        let app = launch(appearance: appearance)
        openTab(app, tab)
        if settings { guard openSettings(app) else { return } }
        if let segment { openSegment(app, segment) }
        let place = "s20 " + (appearance == "dark" ? "暗" : "明") + " " + name
        if let row {
            if tapFinding(app, row, swipes: 6, place: place) {
                if band { s20Band(app, place: place) }
                for i in 0...swipes {
                    snap(app, place + (i == 0 ? "" : " \(i + 1)"))
                    if i < swipes {
                        app.swipeUp()
                        sleep(1)
                    }
                }
            }
        } else {
            for i in 0...swipes {
                snap(app, place + (i == 0 ? "" : " \(i + 1)"))
                if i < swipes {
                    app.swipeUp()
                    sleep(1)
                }
            }
        }
        app.terminate()
    }

    /// 1 日の帯をなぞって範囲を選び、「消す」の確かめの画面を撮る（確かめの画面の「消す」は押さない。見本の記録だけ）
    private func s20Band(_ app: XCUIApplication, place: String) {
        let band = app.descendants(matching: .any).matching(identifier: "dayBand").firstMatch
        guard band.waitForExistence(timeout: 5) else { return }
        let from = band.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.5))
        let to = band.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5))
        from.press(forDuration: 0.3, thenDragTo: to)
        sleep(1)
        snap(app, place + " - 選んだ")
        let forget = app.buttons["消す"].firstMatch
        if forget.exists && forget.isHittable {
            forget.tap()
            sleep(2)
            snap(app, place + " - 消すときの安心")
        }
    }

    /// 新しい画面と変えた画面を、暗い画面と明るい画面の両方で撮る（押すのは開く行だけ。○×・消す・場面のボタンは押さない）
    func testTourS20Design() {
        for appearance in ["dark", "light"] {
            let full = appearance == "dark"
            s20Shot(appearance, tab: "今日", row: nil, name: "今日", swipes: full ? 2 : 0)
            s20Shot(appearance, tab: "直す", row: "確かめる（○×）", name: "確かめる", swipes: full ? 1 : 0)
            s20Shot(appearance, tab: "記録", segment: "ふり返り", row: nil, name: "ふり返り")
            s20Shot(appearance, tab: "記録", segment: "ふり返り", row: "検品表（通信簿）", name: "検品表")
            s20Shot(appearance, tab: "今日", settings: true, segment: "設定", row: nil, name: "設定（場面のセット）", swipes: full ? 1 : 0)
            s20Shot(appearance, tab: "記録", segment: "日ごと", row: "1 日の帯で選ぶ", name: "1 日の帯", band: true)
            s20Shot(appearance, tab: "今日", settings: true, segment: "設定", row: "知らせの便りと履歴", name: "知らせの履歴")
            if full {
                s20Shot(appearance, tab: "記録", segment: "日ごと", row: "探す（人・場所", name: "探す")
                s20Shot(appearance, tab: "記録", segment: "ふり返り", row: "今月の物語", name: "今月の物語", swipes: 1)
                s20Shot(appearance, tab: "記録", segment: "ふり返り", row: "休日のページ", name: "休日のページ")
                s20Shot(appearance, tab: "今日", settings: true, segment: "設定", row: "見た目（暗い", name: "見た目")
                s20Shot(appearance, tab: "今日", settings: true, segment: "設定", row: "寝ているあいだは録音を休む", name: "寝ているあいだ")
                s20Shot(appearance, tab: "今日", settings: true, segment: "設定", row: "一緒にいる人に見せる", name: "一緒にいる人に")
                s20Shot(appearance, tab: "今日", settings: true, segment: "設定", row: "守りの 1 枚", name: "守りの 1 枚")
                s20Shot(appearance, tab: "今日", settings: true, segment: "設定", row: "新しく入ったもの", name: "新しく入ったもの")
                s20Shot(appearance, tab: "今日", settings: true, segment: "設定", row: "言葉の一覧", name: "言葉の一覧")
            }
        }
        XCTAssertGreaterThan(shot, 10, "s20 の写真が少なすぎる")
    }

    /// s33（2026-11-27。S33AViews.swift）: どこ？（目次と検索）・ふり返りの「暮らし」・設定の奥（畳む候補・問いのふた・家の PC の棚）を撮る。
    /// 撮影の段が 120 分の上限に近いので 1 本・起動 3 回だけ。押すのは開く行と探す欄だけ（ラーメンの印・畳む・戻すは押さない）
    func testTourS33A() {
        var app = launch()
        openTab(app, "今日")
        let whereButton = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "どこ")).firstMatch
        if whereButton.waitForExistence(timeout: 8) {
            whereButton.tap()
            sleep(2)
            if alive(app, after: "どこ？") {
                snap(app, "s33 どこ？ 目次")
                let field = app.searchFields.firstMatch
                if field.waitForExistence(timeout: 5) {
                    field.tap()
                    field.typeText("体重")
                    sleep(1)
                    snap(app, "s33 どこ？ 体重で探す")
                }
            }
        } else {
            snap(app, "s33 どこ？ - 見つからない")
        }
        app.terminate()

        app = launch()
        openTab(app, "記録")
        openSegment(app, "ふり返り")
        if tapFinding(app, "暮らし", place: "s33 ふり返り") { snap(app, "s33 暮らし") }
        app.terminate()

        app = launch()
        openTab(app, "今日")
        if openSettings(app) {
            openSegment(app, "設定")
            if tapFinding(app, "くわしい設定", place: "s33 設定"),
               tapFinding(app, "使われ方・畳む候補", place: "s33 くわしい設定") {
                snap(app, "s33 使われ方と畳む")
                app.swipeUp()
                sleep(1)
                snap(app, "s33 使われ方と畳む 2")
                app.swipeUp()
                sleep(1)
                snap(app, "s33 家の PC の棚")
            }
        }
        app.terminate()
        XCTAssertGreaterThan(shot, 2, "s33 の写真が少なすぎる")
    }

    /// s34（2026-11-27。S34AViews.swift）: 仕事タブの上（テストの進み・貼る文）と次の一手・会議の前の 1 枚、
    /// 点検の「自動で直した数」。撮影の時間の上限に近いので、起動は 1 回だけ
    func testTourS34A() {
        let app = launch()
        openTab(app, "仕事")
        sleep(2)
        if alive(app, after: "s34 仕事") { snap(app, "s34 仕事 テストの進み・貼る文") }
        // 押さずにめくって探す（下書きのコピーは押さない）
        for _ in 0..<5 {
            let e = element(app, containing: "止まっている話の次の一手")
            if e.exists && e.isHittable { break }
            app.swipeUp()
            sleep(1)
        }
        snap(app, "s34 仕事 次の一手・会議の前の 1 枚")
        if openSettings(app) {
            openSegment(app, "点検")
            snap(app, "s34 点検 自動で直した数の 1 枚")
            if tapFinding(app, "聞かずに直した", swipes: 2, place: "s34 点検") { snap(app, "s34 自動で直した数") }
        }
        app.terminate()
        XCTAssertGreaterThan(shot, 0, "s34 の写真が無い")
    }
}

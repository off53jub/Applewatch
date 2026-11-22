import XCTest
@testable import LifeLog

/// s22（2026-11-22）の決まり（Shared/Audio/S22Watch.swift・LifeLog/S22Rules.swift・LifeLog/S22Checkup.swift。docs/s22-app.md）
final class S22Tests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - 楽2 印の名前（A2 が使う）

    func testCheckupFixNames() {
        XCTAssertEqual(CheckupFix.self_.rawValue, "self")
        XCTAssertEqual(CheckupFix.wait.rawValue, "wait")
        XCTAssertEqual(CheckupFix.askClaude.rawValue, "askClaude")
        XCTAssertEqual(S22Checkup.fix(section: "許可", label: "通知", value: "未許可"), .self_)
        XCTAssertEqual(S22Checkup.fix(section: "時計", label: "時計に残っている区切り", value: "まだ送っていない 3 個（うち送っている途中 3 個）"), .wait)
        XCTAssertEqual(S22Checkup.fix(section: "時計", label: "時計のアプリの版", value: "時計 356・iPhone 366（時計の LifeLog を一度開くと新しくなります）"), .self_)
        XCTAssertEqual(S22Checkup.fix(section: "端末", label: "落ちた・固まった", value: "1 回"), .askClaude)
    }

    // MARK: - 楽1 いまやること 3 つ

    func testFocusGroupsSortsAndFolds() {
        let now = at(2026, 11, 22, 10)
        let raw = "ドライブに書けませんでした: {\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\"}}"
        var rows: [CheckupRow] = [
            CheckupRow(section: "時計", label: "時計に残っている区切り", value: "まだ送っていない 120 個（うち送っている途中 120 個）", ok: false),
            CheckupRow(section: "許可", label: "通知", value: "未許可", ok: false),
            CheckupRow(section: "端末", label: "低電力モード", value: "オフ", ok: true),
        ]
        for i in 0..<3 {
            rows.append(CheckupRow(section: S22Checkup.errorSection, label: "", value: raw, ok: false, time: now.addingTimeInterval(Double(-i) * 600)))
        }
        rows.append(CheckupRow(section: S22Checkup.errorSection, label: "", value: "古いエラー", ok: false, time: now.addingTimeInterval(-10 * 86400)))
        let list = S22Checkup.focus(rows, now: now)
        XCTAssertEqual(list.top.count, 3)
        XCTAssertEqual(list.top[0].fix, .self_)
        XCTAssertEqual(list.top[1].count, 3)
        XCTAssertEqual(list.top[1].fix, .wait)
        XCTAssertTrue(list.top[1].title.contains("使える回数"))
        XCTAssertEqual(list.folded, 1)
        XCTAssertEqual(list.others, 0)
    }

    // MARK: - 楽4 エラーの文をやさしく

    func testFriendlyError() {
        let raw = "ドライブに書けませんでした: {\"error\":{\"code\":429,\"message\":\"Quota exceeded\",\"status\":\"RESOURCE_EXHAUSTED\"}}"
        let f = S22Checkup.friendlyError(raw)
        XCTAssertEqual(f.short, "ドライブに書けませんでした: Google の使える回数を一時的に超えました（しばらくすると戻ります）")
        XCTAssertEqual(f.detail, raw)
        XCTAssertEqual(S22Checkup.friendlyError("The request timed out.").short, "時間切れでした（電波の良い所で、もう一度試します）")
        let plain = S22Checkup.friendlyError("家の PC の設定が済んでいません")
        XCTAssertEqual(plain.short, "家の PC の設定が済んでいません")
        XCTAssertNil(plain.detail)
        // 4290 のような数は 429 とみなさない
        XCTAssertNil(S22Checkup.friendlyError("区切り 4290 個").detail)
    }

    // MARK: - 楽3 Claude に頼む文

    func testAskClaudeTextHasNoSecrets() {
        let text = S22Checkup.scrub("田中さんから a@b.co と https://x.example/z と ABCDEFGHIJKLMNOPQRSTUVWXYZ012 と 192.168.1.5 と「秘密の話」",
                                    names: ["田中"])
        XCTAssertFalse(text.contains("田中"))
        XCTAssertFalse(text.contains("@"))
        XCTAssertFalse(text.contains("https"))
        XCTAssertFalse(text.contains("ABCDEFGHIJKLMNOP"))
        XCTAssertFalse(text.contains("192.168"))
        XCTAssertFalse(text.contains("秘密"))
        let list = S22Checkup.FocusList(top: [S22Checkup.Focus(id: "r:a", title: "田中さんの声: 未許可", fix: .self_, count: 2, latest: nil)],
                                        others: 1, folded: 0)
        let ask = S22Checkup.askClaudeText(list, phoneBuild: 366, watchBuild: "356", names: ["田中"])
        XCTAssertTrue(ask.contains("iPhone の版 366・時計の版 356"))
        XCTAssertTrue(ask.contains("[自分で直せる]"))
        XCTAssertTrue(ask.contains("（2 回）"))
        XCTAssertFalse(ask.contains("田中"))
    }

    // MARK: - 確4 音の大きさ

    func testLevelMeterAndSummary() {
        var meter = S22Watch.LevelMeter(rate: 100)
        let samples: [Float] = (0..<300).map { $0 % 2 == 0 ? 0.1 : -0.1 }
        samples.withUnsafeBufferPointer { meter.feed($0.baseAddress!, count: 300, tonal: 0) }
        XCTAssertEqual(meter.secondsDB.count, 3)
        for db in meter.secondsDB { XCTAssertEqual(db, -20, accuracy: 0.1) }
        XCTAssertNotNil(meter.summary())

        let levels = S22Watch.summarize(db: [-60, -50, -40, -30, -20, -100], voiced: [false, false, true, true, false, false],
                                        high: [0.1, 0.2, 0.3, 0.4, 0.5, -1])
        XCTAssertEqual(levels?.p50, -40)
        XCTAssertEqual(levels?.voicedP50, -30)
        XCTAssertEqual(levels?.json["p10"], -60)
        XCTAssertNil(S22Watch.summarize(db: [-30, -100], voiced: [true, false], high: [0.1, 0.1]))
    }

    func testLevelsTravelInMetadataAndQuery() {
        let meta: [String: Any] = ["levels": ["p10": -50.0, "p50": -30.5, "p90": -20.0], "recExp": "32k45", "tz": "Asia/Tokyo"]
        let stamp = WatchDelivery.stamp(from: meta)
        XCTAssertEqual(stamp.levels?["p50"], -30.5)
        XCTAssertEqual(stamp.recExp, "32k45")
        XCTAssertNil(WatchDelivery.stamp(from: ["recExp": "bad"]).recExp)
        XCTAssertNil(WatchDelivery.stamp(from: [:]).levels)
        let items = S22Watch.queryItems(levels: stamp.levels, recExp: "bad")
        XCTAssertEqual(items.map(\.name), ["levels"])
        XCTAssertTrue(items[0].value?.contains("\"p50\":-30.5") == true)
        XCTAssertEqual(S22Watch.queryItems(levels: nil, recExp: "48k300").map(\.value), ["48k300"])
    }

    // MARK: - 確24 1 時間ごとの入れ替え

    func testHourlyCombos() {
        let first = S22Watch.hourlyCombo(on: true, start: "2026-11-22", meeting: false, now: at(2026, 11, 22, 13), calendar: tokyo)
        XCTAssertEqual(first.map(S22Watch.label), "48k45")
        let next = S22Watch.hourlyCombo(on: true, start: "2026-11-22", meeting: false, now: at(2026, 11, 23, 13), calendar: tokyo)
        XCTAssertEqual(next.map(S22Watch.label), "32k300")
        XCTAssertNil(S22Watch.hourlyCombo(on: true, start: "2026-11-22", meeting: false, now: at(2026, 11, 30, 13), calendar: tokyo))
        XCTAssertNil(S22Watch.hourlyCombo(on: true, start: "2026-11-22", meeting: true, now: at(2026, 11, 22, 13), calendar: tokyo))
        XCTAssertNil(S22Watch.hourlyCombo(on: false, start: "2026-11-22", meeting: false, now: at(2026, 11, 22, 13), calendar: tokyo))
        var counts: [String: Int] = [:]
        for day in 0..<8 {
            for hour in 0..<24 {
                if let c = S22Watch.hourlyCombo(on: true, start: "2026-11-22", meeting: false, now: at(2026, 11, 22 + day, hour), calendar: tokyo) {
                    counts[S22Watch.label(c), default: 0] += 1
                }
            }
        }
        XCTAssertEqual(counts, ["32k45": 48, "48k45": 48, "32k300": 48, "48k300": 48])
        XCTAssertTrue(S22Watch.hourlyFinished(start: "2026-11-22", now: at(2026, 11, 30, 0), calendar: tokyo))
        XCTAssertEqual(Set(S22Watch.recExpLabels), Set(counts.keys))
    }

    // MARK: - 確31 こもり

    func testMuffled() {
        let normal = Array(repeating: 0.3, count: 6)
        XCTAssertTrue(S22Watch.isMuffled(normal + [0.05, 0.05]))
        XCTAssertFalse(S22Watch.isMuffled(normal + [0.3, 0.05]))
        XCTAssertFalse(S22Watch.isMuffled([0.3, 0.05, 0.05]))
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(S22Watch.shouldBuzz(on: false, history: normal + [0.05, 0.05], lastBuzz: nil, now: now))
        XCTAssertTrue(S22Watch.shouldBuzz(on: true, history: normal + [0.05, 0.05], lastBuzz: nil, now: now))
        XCTAssertFalse(S22Watch.shouldBuzz(on: true, history: normal + [0.05, 0.05], lastBuzz: now.addingTimeInterval(-600), now: now))
    }

    // MARK: - 楽6 あと○個・約○分

    func testBacklog() {
        XCTAssertEqual(S22Watch.backlogText(count: 120, finishedRecent: 90), "あと 120 個・約 40 分")
        XCTAssertEqual(S22Watch.backlogText(count: 120, finishedRecent: 1), "あと 120 個")
        XCTAssertNil(S22Watch.backlogText(count: 0, finishedRecent: 10))
        XCTAssertEqual(S22Watch.durationText(125 * 60), "2 時間 5 分")
        XCTAssertEqual(S22Watch.durationText(12792 * 60), "9 日")
        XCTAssertEqual(S22Watch.recentFinishes([0, 100, 1900, 2000], now: 2000).count, 2)
        var acked: [String: Double] = [:]
        for i in 0..<5 { acked = S22Watch.addingAcked(acked, name: "a\(i)", now: Double(i), limit: 3) }
        XCTAssertEqual(Set(acked.keys), ["a2", "a3", "a4"])
        XCTAssertNil(S22Watch.addingAcked(["old": 0], name: "new", now: 90_000)["old"])
    }

    // MARK: - 楽19 電池の先回り

    func testBatteryForecast() {
        let t0 = at(2026, 11, 22, 8).timeIntervalSince1970
        let samples: [[Double]] = [[t0, 1.0, 0, 0], [t0 + 3600, 0.9, 0, 0], [t0 + 7200, 0.8, 0, 0]]
        let now = Date(timeIntervalSince1970: t0 + 7200)
        let end = S22Watch.emptyAt(samples, now: now)
        XCTAssertEqual(end?.timeIntervalSince1970 ?? 0, t0 + 7200 + 8 * 3600, accuracy: 1)
        XCTAssertEqual(S22Watch.emptyText(end, now: now, calendar: tokyo), "この調子だと 18:00 に切れます")
        XCTAssertEqual(S22Watch.drainPerHour(samples, now: now) ?? 0, 10, accuracy: 0.1)
        XCTAssertNil(S22Watch.emptyAt(samples + [[t0 + 7300, 0.8, 0, 1]], now: now))
        XCTAssertNil(S22Watch.emptyAt([[t0, 0.9, 0], [t0 + 600, 0.85, 0]], now: now))
        // 充電で増えたところより後ろだけを見る
        let afterCharge: [[Double]] = [[t0 - 7200, 0.2, 0], [t0 - 3600, 0.6, 0]] + samples
        XCTAssertEqual(S22Watch.emptyAt(afterCharge, now: now)?.timeIntervalSince1970 ?? 0, t0 + 7200 + 8 * 3600, accuracy: 1)
        let late = S22Watch.emptyText(at(2026, 11, 23, 3, 10), now: at(2026, 11, 22, 22), calendar: tokyo)
        XCTAssertEqual(late, "この調子だと 明日 3:10 に切れます")
    }

    // MARK: - 楽10 時計の版

    func testWatchVersion() {
        XCTAssertEqual(S22Rules.watchVersion(phone: 366, watch: "356"), .watchOlder(watch: 356, phone: 366))
        XCTAssertEqual(S22Rules.watchVersion(phone: 366, watch: nil), .unknown)
        XCTAssertEqual(S22Rules.watchVersion(phone: 366, watch: "366"), .same(366))
        XCTAssertTrue(S22Rules.needsWatchUpdate(.unknown))
        XCTAssertFalse(S22Rules.needsWatchUpdate(.same(366)))
        XCTAssertGreaterThanOrEqual(S22Rules.watchUpdateSteps.count, 3)
    }

    // MARK: - 楽7・楽9・楽21

    func testTalkToTextAndForecast() {
        XCTAssertEqual(S22Rules.talkToTextMinutes(totalMedian: 150, chunkTypical: 75), 3)
        XCTAssertNil(S22Rules.talkToTextMinutes(totalMedian: nil, chunkTypical: 75))
        XCTAssertEqual(S22Rules.talkToTextLine(3), "いま話したことは約 3 分で文字になります")
        XCTAssertEqual(S22Rules.forecastLine(.battery, drainPerHour: 10, latencyMinutes: 5),
                       "見込み（仮）: 時計の電池 1 時間 約 8%・文字になるまで 約 8 分")
        XCTAssertTrue(S22Rules.forecastLine(.speed, drainPerHour: nil, latencyMinutes: nil).contains("早いほう"))
        XCTAssertNotNil(S22Rules.switchImpact("standbyOn", turningOn: true))
        XCTAssertNil(S22Rules.switchImpact("nothing", turningOn: true))
        XCTAssertEqual(S22Rules.launchBucket(0.5), "lt1")
        XCTAssertEqual(S22Rules.launchBucket(3), "lt4")
        XCTAssertEqual(S22Rules.launchBucket(9), "ge8")
        XCTAssertEqual(S22Rules.median([3, 1, 2]), 2)
        XCTAssertEqual(S22Rules.median([1, 2, 3, 4]), 2.5)
    }

    // MARK: - 楽23 場面のカード

    func testSceneLinesMaskNames() {
        let t = Date(timeIntervalSince1970: 1000)
        let lines: [(speaker: String?, text: String, time: Date, media: Bool)] = [
            ("さとう", "こんにちは さとうです", t, false),
            ("テレビ", "番組の声", t.addingTimeInterval(1), true),
            ("自分", "はい", t.addingTimeInterval(2), false),
            ("たなか", "さとうさん元気？", t.addingTimeInterval(3), false),
        ]
        let masked = S22Rules.sceneLines(lines, around: t.addingTimeInterval(2), selfName: "自分", names: ["さとう", "たなか"], mask: true)
        XCTAssertEqual(masked.map(\.who), ["A さん", "自分", "B さん"])
        XCTAssertFalse(masked.contains { $0.text.contains("さとう") || $0.text.contains("たなか") })
        XCTAssertTrue(masked[1].isSelf)
        let open = S22Rules.sceneLines(lines, around: t, selfName: "自分", names: [], mask: false)
        XCTAssertEqual(open.first?.who, "さとう")
        XCTAssertEqual(S22Rules.sceneLines(lines, around: t, selfName: "自分", names: [], mask: false, limit: 2).count, 2)
    }

    // MARK: - 確19 kind number

    func testNumberReviewItem() throws {
        let json = #"{"items":[{"id":"n1","kind":"number","question":"いくらでしたか？","answer":"pick","choices":["3000円","3500円"]},{"id":"n2","kind":"number","question":"何時？","answer":"choice","choices":["9時","10時"]}],"done":[{"id":"n0","changed":4}]}"#
        let feed = try JSONDecoder().decode(ReviewQueueFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.items?.count, 2)
        XCTAssertEqual(ReviewRules.kindLabel("number"), "数字の確かめ")
        for item in feed.items ?? [] { XCTAssertEqual(S22Rules.answerStyle(answer: item.answer, choices: item.choices), "pick") }
        XCTAssertEqual(S22Rules.answerStyle(answer: "yesno", choices: nil), "yesno")
        XCTAssertEqual(S22Rules.answerStyle(answer: "text", choices: ["a"]), "text")
        XCTAssertFalse(S22Rules.isYesNo(answer: "pick", choices: ["a"]))
        // 確27: done の changed は前からの形で出せる
        XCTAssertEqual(ReviewRules.changedLine(feed.done?.first), "この答えで 4 行が直りました")
    }

    // MARK: - 楽15・楽16

    func testNudges() {
        XCTAssertTrue(S22Rules.trainNudgeDue(on: true, isTrain: true, waiting: 2, lastDay: "2026-11-21", today: "2026-11-22"))
        XCTAssertFalse(S22Rules.trainNudgeDue(on: true, isTrain: true, waiting: 2, lastDay: "2026-11-22", today: "2026-11-22"))
        XCTAssertFalse(S22Rules.trainNudgeDue(on: true, isTrain: false, waiting: 2, lastDay: nil, today: "2026-11-22"))
        XCTAssertFalse(S22Rules.trainNudgeDue(on: true, isTrain: true, waiting: 0, lastDay: nil, today: "2026-11-22"))
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(S22Rules.whoNudgeDue(on: true, closed: true, end: now.addingTimeInterval(-300), unnamedLines: 5,
                                           alreadyAsked: false, askedToday: 0, now: now))
        XCTAssertFalse(S22Rules.whoNudgeDue(on: false, closed: true, end: now.addingTimeInterval(-300), unnamedLines: 5,
                                            alreadyAsked: false, askedToday: 0, now: now))
        XCTAssertFalse(S22Rules.whoNudgeDue(on: true, closed: true, end: now.addingTimeInterval(-300), unnamedLines: 5,
                                            alreadyAsked: false, askedToday: 3, now: now))
        XCTAssertFalse(S22Rules.whoNudgeDue(on: true, closed: true, end: now.addingTimeInterval(-3600), unnamedLines: 5,
                                            alreadyAsked: false, askedToday: 0, now: now))
        XCTAssertFalse(S22Rules.whoNudgeDue(on: true, closed: false, end: now.addingTimeInterval(-300), unnamedLines: 5,
                                            alreadyAsked: false, askedToday: 0, now: now))
    }

    // MARK: - 楽5 報告の棚

    func testReports() throws {
        let json = #"{"generated_at":"2026-11-22T10:00:00+09:00","reports":[{"name":"accuracy.md","title":"精度","updated_at":"2026-11-22T09:00","bytes":2048},{"name":"work-weekly.md","title":"週報","updated_at":"2026-11-22T10:00","bytes":10},{"name":"x.md","title":"職場のまとめ","updated_at":"2026-11-22T11:00"},{"name":"../secret","title":"だめ"},{"name":"battery.md","title":"電池","updated_at":"2026-11-22T10:30"}]}"#
        let feed = try JSONDecoder().decode(S22Rules.ReportsFeed.self, from: Data(json.utf8))
        XCTAssertEqual(S22Rules.visibleReports(feed).map(\.name), ["battery.md", "accuracy.md"])
        XCTAssertEqual(S22Rules.sizeText(2048), "2 KB")
        XCTAssertNil(S22Rules.sizeText(nil))
        XCTAssertFalse(S22Rules.isSafeReportName("a/b"))
    }

    // MARK: - 楽20 いつも録れない所

    func testGapPatterns() throws {
        let json = #"{"generated_at":"x","by_hour":[{"weekday":1,"hour":13,"gap_minutes":40,"days":5},{"weekday":6,"hour":2,"gap_minutes":10,"days":2},{"weekday":9,"hour":2,"gap_minutes":99,"days":1}],"by_place":[{"place":"駅","gap_minutes":30,"days":3,"lat":35.6,"lon":139.7},{"place":"店","gap_minutes":12,"days":1}]}"#
        let patterns = try JSONDecoder().decode(S22Rules.GapPatterns.self, from: Data(json.utf8))
        let grid = S22Rules.gapGrid(patterns)
        XCTAssertEqual(grid.count, 7)
        XCTAssertEqual(grid[1][13], 40)
        XCTAssertEqual(S22Rules.worstHours(patterns).first, "火 13 時 40 分（5 日）")
        XCTAssertEqual(S22Rules.worstHours(patterns).count, 2)
        XCTAssertNil(patterns.by_place[1].lat)
    }

    // MARK: - 楽11 実機の確かめ（母艦の形）

    func testDeviceChecksResult() throws {
        let json = #"{"checks":[{"id":"a","name":"x","result":"ng","fix":"開く","evidence":"0 回"},{"id":"b","name":"y","result":"ok"},{"id":"c","name":"z","ok":true}]}"#
        let feed = try JSONDecoder().decode(DeviceChecksFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.checks?.map(\.passed), [false, true, true])
        XCTAssertEqual(feed.checks?.first?.fix, "開く")
    }

    // MARK: - 楽14 ウィジェットの答え

    func testWidgetAnswers() {
        var list: [S22WidgetAnswers.Entry] = []
        list = S22WidgetAnswers.adding(list, id: "a", value: "yes", at: 1)
        list = S22WidgetAnswers.adding(list, id: "a", value: "no", at: 2)
        list = S22WidgetAnswers.adding(list, id: "b", value: "yes", at: 3)
        XCTAssertEqual(list.map(\.id), ["a", "b"])
        XCTAssertEqual(list.first?.value, "no")
        let defaults = UserDefaults(suiteName: "s22tests")!
        defaults.removePersistentDomain(forName: "s22tests")
        S22WidgetAnswers.add(id: "q1", value: "yes", defaults: defaults)
        XCTAssertEqual(S22WidgetAnswers.load(from: defaults).map(\.id), ["q1"])
        XCTAssertEqual(S22WidgetAnswers.take(defaults: defaults).count, 1)
        XCTAssertTrue(S22WidgetAnswers.load(from: defaults).isEmpty)
    }
}

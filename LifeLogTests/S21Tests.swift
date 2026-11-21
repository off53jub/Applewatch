import XCTest
@testable import LifeLog

/// s21（2026-11-22）の決まり（Shared/Audio/S21Watch.swift・LifeLog/S21Rules.swift。docs/s21-app.md）
final class S21Tests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - 精7 声の無い区切りの見本（1 割）

    func testSampleNoVoiceIsStableAndAboutOneInTen() {
        let names = (0..<2000).map { String(format: "20261122-%06d.m4a", $0 * 37) }
        let hits = names.filter { S21Watch.shouldSampleNoVoice(name: $0) }.count
        // 1 割 ± 3 割の幅（名前から決まるので毎回同じ）
        XCTAssertGreaterThan(hits, 140)
        XCTAssertLessThan(hits, 260)
        XCTAssertEqual(S21Watch.shouldSampleNoVoice(name: names[5]), S21Watch.shouldSampleNoVoice(name: names[5]))
        XCTAssertFalse(S21Watch.shouldSampleNoVoice(name: "a", every: 0))
        XCTAssertTrue(S21Watch.shouldSampleNoVoice(name: "a", every: 1))
    }

    func testSampleMemoryForgetsAfterTwoDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = ["old.m4a": now.timeIntervalSince1970 - 3 * 86400, "new.m4a": now.timeIntervalSince1970 - 3600]
        let next = S21Watch.addingSample(saved, name: "x.m4a", now: now)
        XCTAssertEqual(Set(next.keys), ["new.m4a", "x.m4a"])
    }

    func testSampleNoVoiceTravelsInMetadataAndQuery() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meta = WatchDelivery.metadata(zone: .current, cut: now, sent: now, lowPower: false, viaPC: false, sampleNoVoice: true)
        XCTAssertEqual(meta["sampleNoVoice"] as? Bool, true)
        XCTAssertTrue(WatchDelivery.stamp(from: meta).sampleNoVoice)
        let plain = WatchDelivery.metadata(zone: .current, cut: now, sent: now, lowPower: false, viaPC: false)
        XCTAssertNil(plain["sampleNoVoice"])
        XCTAssertFalse(WatchDelivery.stamp(from: plain).sampleNoVoice)
        let query = WatchDelivery.jobQuery(name: "a-w.m4a", chunkStart: nil, chunkEnd: nil, sent: now, hints: nil, weights: nil,
                                           sampleNoVoice: true)
        XCTAssertTrue(query.contains { $0.name == "sampleNoVoice" && $0.value == "1" })
        XCTAssertFalse(WatchDelivery.jobQuery(name: "a-w.m4a", chunkStart: nil, chunkEnd: nil, sent: now, hints: nil, weights: nil)
            .contains { $0.name == "sampleNoVoice" })
    }

    // MARK: - 精8 書き始めを 2.5 秒前から

    func testPreRollIsTwoAndHalfSeconds() {
        XCTAssertEqual(SilenceGate.preRoll, 2.5)
    }

    // MARK: - 電1 電池の見本に充電中を足す

    func testBatterySampleKeepsOldShapeAndAddsCharging() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let a = HolidayRules.addingSample([], time: t, level: 0.5, holding: false)
        XCTAssertEqual(a.last?.count, 3)
        let b = HolidayRules.addingSample(a, time: t.addingTimeInterval(3600), level: 0.6, holding: false, charging: true)
        XCTAssertEqual(b.last, [1_800_003_600, 0.6, 0, 1])
        // 減りの数え方は前と同じ（4 つ目があっても読める）
        let c = HolidayRules.addingSample(b, time: t.addingTimeInterval(7200), level: 0.5, holding: false, charging: false)
        XCTAssertEqual(HolidayRules.drainPerHour(c, holding: false), 10)
    }

    // MARK: - 電3 寝ている時間は 5 分

    func testSleepSaving() {
        XCTAssertTrue(S21Watch.sleepSaving(enabled: true, hour: 1, charging: false))
        XCTAssertTrue(S21Watch.sleepSaving(enabled: true, hour: 5, charging: false))
        XCTAssertFalse(S21Watch.sleepSaving(enabled: true, hour: 6, charging: false))
        XCTAssertFalse(S21Watch.sleepSaving(enabled: true, hour: 0, charging: false))
        XCTAssertFalse(S21Watch.sleepSaving(enabled: true, hour: 3, charging: true))
        XCTAssertFalse(S21Watch.sleepSaving(enabled: false, hour: 3, charging: false))
    }

    func testSettingsTravelToWatch() {
        let defaults = UserDefaults(suiteName: "s21-test-\(UUID().uuidString)")!
        var context: [String: Any] = [:]
        S21Watch.addSettings(to: &context, defaults: defaults)
        XCTAssertEqual(context[S21Watch.sleepChunksKey] as? Bool, true)
        XCTAssertEqual(context[S21Watch.workoutGuardKey] as? Bool, false)
        let watch = UserDefaults(suiteName: "s21-test-\(UUID().uuidString)")!
        S21Watch.readSettings([S21Watch.workoutGuardKey: true, S21Watch.sleepChunksKey: false], defaults: watch)
        XCTAssertTrue(watch.bool(forKey: S21Watch.workoutGuardKey))
        XCTAssertFalse(watch.bool(forKey: S21Watch.sleepChunksKey))
    }

    // MARK: - 使5 今日録れた時間

    func testRecordedSecondsAndLine() {
        let start = at(2026, 11, 22, 10, 0)
        XCTAssertEqual(S21Watch.chunkSeconds(start: start, cut: start.addingTimeInterval(75)), 75)
        XCTAssertNil(S21Watch.chunkSeconds(start: start, cut: start.addingTimeInterval(-5)))
        XCTAssertNil(S21Watch.chunkSeconds(start: start, cut: start.addingTimeInterval(3 * 3600)))
        XCTAssertNil(S21Watch.chunkSeconds(start: nil, cut: start))
        let saved = S21Watch.addingSeconds(["2026-11-21": 500], day: "2026-11-22", seconds: 60)
        XCTAssertEqual(saved, ["2026-11-22": 60])
        XCTAssertEqual(S21Watch.addingSeconds(saved, day: "2026-11-22", seconds: 30), ["2026-11-22": 90])
        XCTAssertEqual(S21Watch.durationText(8100), "2時間15分")
        XCTAssertEqual(S21Watch.durationText(59), "0分")
        let now = at(2026, 11, 22, 12)
        XCTAssertEqual(S21Watch.todayLine(recorded: 2100, delivered: at(2026, 11, 22, 10, 5), now: now, calendar: tokyo),
                       "今日 35分・最後に届いた 10:05")
        XCTAssertEqual(S21Watch.todayLine(recorded: 0, delivered: at(2026, 11, 21, 23, 40), now: now, calendar: tokyo),
                       "今日 0分・最後に届いた 11/21 23:40")
        XCTAssertEqual(S21Watch.todayLine(recorded: 0, delivered: nil, now: now, calendar: tokyo), "今日 0分・まだ届いていません")
    }

    // MARK: - 守2 落ちた・止められた記録

    func testExits() {
        let day = at(2026, 11, 22, 3)
        let t = day.timeIntervalSince1970
        var list = S21Watch.addingExit([], alive: t, relaunch: t + 30)
        XCTAssertTrue(list.isEmpty, "1 分より短いのは数えない")
        list = S21Watch.addingExit(list, alive: nil, relaunch: t + 600)
        XCTAssertTrue(list.isEmpty, "動いていた時刻が無ければ数えない")
        list = S21Watch.addingExit(list, alive: t, relaunch: t + 900)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(S21Watch.exitsOn(list, day: "2026-11-22", calendar: tokyo), 1)
        XCTAssertEqual(S21Watch.exitsOn(list, day: "2026-11-21", calendar: tokyo), 0)
        let text = S21Watch.lastExitText(list)
        XCTAssertEqual(text, "\(Int(t))|\(Int(t + 900))")
        let parsed = S21Watch.parseExit(text)
        XCTAssertEqual(parsed?.alive, Date(timeIntervalSince1970: t))
        XCTAssertNil(S21Watch.parseExit("x|y"))
        XCTAssertNil(S21Watch.parseExit("10|5"))
        let many = (0..<30).reduce([[Double]]()) { S21Watch.addingExit($0, alive: Double($1) * 1000, relaunch: Double($1) * 1000 + 100) }
        XCTAssertEqual(many.count, 20)
    }

    // MARK: - 速2 返事待ちの片付け

    func testTidyKept() {
        XCTAssertTrue(S21Watch.tidyKept(cutAge: 60, sentToPC: false, phoneHas: true), "iPhone が受け取ったと言っている")
        XCTAssertTrue(S21Watch.tidyKept(cutAge: 2 * 86400, sentToPC: true, phoneHas: false), "1 日を過ぎて PC にある")
        XCTAssertFalse(S21Watch.tidyKept(cutAge: 2 * 86400, sentToPC: false, phoneHas: false), "PC に無いものは残す")
        XCTAssertFalse(S21Watch.tidyKept(cutAge: 3600, sentToPC: true, phoneHas: false), "1 日より新しいものは待つ")
        XCTAssertFalse(S21Watch.tidyKept(cutAge: nil, sentToPC: true, phoneHas: false))
    }

    func testGotList() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(S21Rules.gotListDue(kept: 10, lastSent: nil, now: now))
        XCTAssertTrue(S21Rules.gotListDue(kept: 159, lastSent: nil, now: now))
        XCTAssertFalse(S21Rules.gotListDue(kept: 159, lastSent: now.addingTimeInterval(-600), now: now))
        XCTAssertTrue(S21Rules.gotListDue(kept: 159, lastSent: now.addingTimeInterval(-4000), now: now))
        XCTAssertFalse(S21Rules.gotListDue(kept: nil, lastSent: nil, now: now))
        let t = now.timeIntervalSince1970
        let received = ["a-w.m4a": t - 100, "b-w.m4a": t - 50, "c.m4a": t - 10, "old-w.m4a": t - 3 * 86400]
        XCTAssertEqual(S21Rules.gotListNames(received, now: now), ["b-w.m4a", "a-w.m4a"])
        XCTAssertEqual(S21Rules.gotListNames(received, now: now, limit: 1), ["b-w.m4a"])
    }

    // MARK: - 使1 3 つの組

    func testPresets() {
        let battery = S21Preset.battery.values(hasCloudKey: true)
        XCTAssertEqual(battery.chunkLength, .normal)
        XCTAssertEqual(battery.standby, false)
        XCTAssertEqual(battery.watchDirect, false)
        XCTAssertEqual(battery.dropNoVoice, true)
        let speed = S21Preset.speed.values(hasCloudKey: false)
        XCTAssertEqual(speed.chunkLength, .short)
        XCTAssertEqual(speed.watchRelay, true)
        XCTAssertEqual(S21Preset.accuracy.values(hasCloudKey: true).useCloud, true)
        XCTAssertNil(S21Preset.accuracy.values(hasCloudKey: false).useCloud, "キーが無ければ高精度は触らない")
        XCTAssertEqual(S21Preset.accuracy.values(hasCloudKey: true).dropNoVoice, false)
        // いまの設定がどの組か
        var current = S21Preset.Values(chunkLength: .normal, batterySaver: true, skipSilence: true, dropNoVoice: true, standby: false,
                                       watchDirect: false, watchRelay: true, useCloud: false, correction: true, speakers: false)
        XCTAssertEqual(S21Preset.matching(current, hasCloudKey: true), .battery)
        current.standby = true
        XCTAssertNil(S21Preset.matching(current, hasCloudKey: true))
        XCTAssertEqual(battery.count, 6)
    }

    // MARK: - 使2 進み具合の文

    func testProgressMessages() {
        XCTAssertTrue(S21Rules.isProgress("日本語モデルを確認中…"))
        XCTAssertTrue(S21Rules.isProgress("準備しています..."))
        XCTAssertFalse(S21Rules.isProgress("録音を始められませんでした: …"))
        XCTAssertFalse(S21Rules.isProgress("groq に接続できませんでした"))
        XCTAssertFalse(S21Rules.isProgress(""))
    }

    // MARK: - 使3 朝の点検

    func testMorningExtra() {
        let gaps = [(start: at(2026, 11, 21, 15, 0), end: at(2026, 11, 21, 15, 25)),
                    (start: at(2026, 11, 21, 13, 10), end: at(2026, 11, 21, 13, 40))]
        let line = S21Rules.morningExtra(recordedMinutes: 580, stalls: 2, autoResumed: 2, exits: 1, gaps: gaps, calendar: tokyo)
        XCTAssertEqual(line, "録れた時間 9時間40分・止まりかけ 2 回（自動で戻した 2 回）・時計のアプリが止められていた 1 回・録れなかった時間帯 13:10〜13:40、15:00〜15:25")
        XCTAssertEqual(S21Rules.morningExtra(recordedMinutes: 30, stalls: 0, autoResumed: nil, exits: nil, gaps: [], calendar: tokyo),
                       "録れた時間 30分")
        let four = (0..<4).map { (start: at(2026, 11, 21, 10 + $0), end: at(2026, 11, 21, 10 + $0, 20 + $0)) }
        XCTAssertTrue(S21Rules.morningExtra(recordedMinutes: 0, stalls: nil, autoResumed: nil, exits: nil, gaps: four, calendar: tokyo)
            .hasSuffix(" ほか"))
    }

    // MARK: - 使6 抜けの理由

    func testGapReasonWithStallsAndExits() {
        let s = at(2026, 11, 21, 14, 0), e = at(2026, 11, 21, 15, 0)
        XCTAssertNil(S21Rules.gapReason(start: s, end: e, stalls: [], exits: []))
        XCTAssertTrue(S21Rules.gapReason(start: s, end: e, stalls: [s.addingTimeInterval(-120)], exits: [])?.contains("止まりかけ") == true)
        XCTAssertNil(S21Rules.gapReason(start: s, end: e, stalls: [s.addingTimeInterval(-3600)], exits: []))
        XCTAssertTrue(S21Rules.gapReason(start: s, end: e, stalls: [], exits: [(alive: s.addingTimeInterval(-60), relaunch: s.addingTimeInterval(600))])?
            .contains("止められていた") == true)
        // 帳簿の抜けにも入る（充電中は充電中のまま）
        let spans = [RecordingLedger.Span(start: s, end: e, kind: .gap)]
        let gaps = RecordingLedger.gaps(spans, states: [], stalls: [s.addingTimeInterval(60)])
        XCTAssertTrue(gaps.first?.reason.contains("止まりかけ") == true)
        var charging = RecordingLedger.State(at: s, recording: true, resting: false)
        charging.charging = true
        XCTAssertEqual(RecordingLedger.gaps(spans, states: [charging], stalls: [s.addingTimeInterval(60)]).first?.reason, "時計の充電中")
    }

    // MARK: - 使7 自分の声の候補

    func testSelfCandidates() {
        var lines: [S21Rules.VoiceLine] = []
        for _ in 0..<12 { lines.append(.init(speaker: "7", audio: "20261121-100000-w.m4a", seconds: 5)) }
        for _ in 0..<20 { lines.append(.init(speaker: "8", audio: "20261121-100000-w.m4a", seconds: 2)) }
        // iPhone の区切りは数えない
        for _ in 0..<50 { lines.append(.init(speaker: "9", audio: "20261121-100000.m4a", seconds: 10)) }
        for _ in 0..<5 { lines.append(.init(speaker: "10", audio: "20261121-100000-w.m4a", seconds: 30)) }
        let picks = S21Rules.selfCandidates(lines, unnamed: ["7", "8", "9", "10"], rejected: [])
        XCTAssertEqual(picks.map(\.id), ["7", "8"], "10 行より少ない声は出さない")
        XCTAssertEqual(picks.first?.seconds, 60)
        XCTAssertEqual(S21Rules.selfCandidates(lines, unnamed: ["7", "8"], rejected: ["7"]).map(\.id), ["8"])
        XCTAssertEqual(S21Rules.selfCandidates(lines, unnamed: ["8"], rejected: []).map(\.id), ["8"], "名前のある声は出さない")
    }

    // MARK: - 使9 同期の相手から外す

    func testOlderPeers() {
        let peers = ["aaaa1111": 300, "bbbb2222": 0, "cccc3333": 420]
        XCTAssertEqual(S21Rules.olderPeers(peers, mine: 400, excluded: []).map(\.device), ["aaaa1111", "bbbb2222"])
        XCTAssertEqual(S21Rules.olderPeers(peers, mine: 400, excluded: ["bbbb2222"]).map(\.device), ["aaaa1111"])
    }

    // MARK: - 使10 振って送る

    func testShakeBody() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try XCTUnwrap(S21Rules.shakeBody(screen: "diagnostics", note: "  数が変 ", at: when,
                                                    timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["kind"], "shake")
        XCTAssertEqual(object["screen"], "diagnostics")
        XCTAssertEqual(object["note"], "数が変")
        XCTAssertEqual(object["at"], "2027-01-15T17:00:00+09:00")
        let bare = try XCTUnwrap(S21Rules.shakeBody(screen: "today", note: "", at: when))
        XCTAssertNil((try JSONSerialization.jsonObject(with: bare) as? [String: String])?["note"])
        XCTAssertNil(S21Rules.shakeBody(screen: "  ", note: nil, at: when))
    }

    // MARK: - 使11 Groq につながらない

    func testUnreachable() {
        XCTAssertTrue(S21Rules.isUnreachable("groq に接続できませんでした"))
        XCTAssertFalse(S21Rules.isUnreachable("応答がありませんでした: HTTP 500"))
    }

    // MARK: - 精5 誤変換直しの型

    func testFixKinds() {
        XCTAssertEqual(S21Rules.fixKind(original: "今日は、晴れ", fixed: "今日は晴れ。"), "marks")
        XCTAssertEqual(S21Rules.fixKind(original: "3時に会う", fixed: "4時に会う"), "number")
        XCTAssertEqual(S21Rules.fixKind(original: "あしたは会議があります", fixed: "あ"), "length")
        XCTAssertEqual(S21Rules.fixKind(original: "あいうえおかきくけこ", fixed: "さしすせそたちつてと"), "rewrite")
        XCTAssertEqual(S21Rules.fixKind(original: "さいとうさんと話した", fixed: "サイトウさんと話した"), "name")
        XCTAssertEqual(S21Rules.fixKind(original: "きょうはいい天気ですね", fixed: "きょうはいい天気ですよ"), "small")
        XCTAssertEqual(S21Rules.fixKind(original: "きょうはいい天気ですね", fixed: "今日はいい天気ですね"), "other")
        XCTAssertEqual(S21Rules.editRatio("abc", "abc"), 0)
        XCTAssertEqual(S21Rules.editRatio("", "abc"), 1)
        XCTAssertEqual(S21Rules.editRatio("kitten", "sitting"), 3.0 / 7.0, accuracy: 1e-9)
    }

    func testPreReject() {
        XCTAssertEqual(S21Rules.preReject(original: "今日は、晴れ", fixed: "今日は晴れ"), "marks")
        XCTAssertEqual(S21Rules.preReject(original: "あいうえおかきくけこ", fixed: "さしすせそたちつてと"), "rewrite")
        XCTAssertNil(S21Rules.preReject(original: "あいう", fixed: "かきく"), "短い行は弾かない")
        XCTAssertNil(S21Rules.preReject(original: "さいとうさんと話した", fixed: "サイトウさんと話した"))
        XCTAssertNil(S21Rules.preReject(original: "同じ", fixed: "同じ"))
        XCTAssertNil(S21Rules.preReject(original: "消えた行の文です", fixed: ""))
        let out = Pipeline.preFilterFixes(original: ["今日は、晴れ", "さいとうさんと話した"],
                                          fixed: ["今日は晴れ", "サイトウさんと話した"])
        XCTAssertEqual(out, ["今日は、晴れ", "サイトウさんと話した"])
        // 長さが合わなくても落ちない
        XCTAssertEqual(Pipeline.preFilterFixes(original: ["a"], fixed: ["a", "b"]), ["a", "b"])
    }

    // MARK: - 速1 待ち合わせ

    func testJobWait() {
        XCTAssertEqual(S21Rules.jobWait(accepts: false, staged: 0, maxWaiting: 3).reason, "noFeature")
        XCTAssertEqual(S21Rules.jobWait(accepts: true, staged: 3, maxWaiting: 3).reason, "busy")
        let on = S21Rules.jobWait(accepts: true, staged: 2, maxWaiting: 3)
        XCTAssertTrue(on.wait)
        XCTAssertEqual(on.reason, "on")
    }

    // MARK: - 速7 Claude を出す前に止める

    func testClaudeStart() {
        XCTAssertFalse(S21Rules.claudeStartAllowed(cancelled: true, background: false, remaining: 1000, needed: 30))
        XCTAssertTrue(S21Rules.claudeStartAllowed(cancelled: false, background: false, remaining: 0, needed: 30))
        XCTAssertFalse(S21Rules.claudeStartAllowed(cancelled: false, background: true, remaining: 10, needed: 30))
        XCTAssertTrue(S21Rules.claudeStartAllowed(cancelled: false, background: true, remaining: .greatestFiniteMagnitude, needed: 30))
        XCTAssertEqual(S21Rules.claudeNeeded(timeout: 40), 40)
        XCTAssertEqual(S21Rules.claudeNeeded(timeout: 180), 60)
        XCTAssertEqual(S21Rules.claudeNeeded(timeout: 5), 25)
    }

    // MARK: - 電2 直接送るの実験

    func testRouteExperiment() {
        let start = "2026-11-23"
        XCTAssertNil(S21Rules.route(on: true, start: start, now: at(2026, 11, 22, 12), calendar: tokyo))
        XCTAssertEqual(S21Rules.route(on: true, start: start, now: at(2026, 11, 23, 12), calendar: tokyo), .direct)
        XCTAssertEqual(S21Rules.route(on: true, start: start, now: at(2026, 11, 24, 0, 5), calendar: tokyo), .phone)
        XCTAssertEqual(S21Rules.route(on: true, start: start, now: at(2026, 11, 25, 12), calendar: tokyo), .direct)
        XCTAssertEqual(S21Rules.route(on: true, start: start, now: at(2026, 11, 26, 23), calendar: tokyo), .phone)
        XCTAssertNil(S21Rules.route(on: true, start: start, now: at(2026, 11, 27, 12), calendar: tokyo))
        XCTAssertNil(S21Rules.route(on: false, start: start, now: at(2026, 11, 24, 12), calendar: tokyo))
        XCTAssertNil(S21Rules.route(on: true, start: nil, now: at(2026, 11, 24, 12), calendar: tokyo))
        XCTAssertTrue(S21Rules.routeFinished(start: start, now: at(2026, 11, 27, 1), calendar: tokyo))
        XCTAssertFalse(S21Rules.routeFinished(start: start, now: at(2026, 11, 26, 23), calendar: tokyo))
        XCTAssertFalse(S21Rules.routeFinished(start: nil, now: at(2026, 11, 27, 1), calendar: tokyo))
        XCTAssertTrue(S21Rules.allowsDirect(nil))
        XCTAssertTrue(S21Rules.allowsDirect(.direct))
        XCTAssertFalse(S21Rules.allowsDirect(.phone))
    }

    // MARK: - 守4 便りが途切れたら

    func testStartPhoneWhenWatchQuiet() {
        XCTAssertFalse(S21Rules.shouldStartPhone(action: .notify, watchWanted: true, phoneRecording: false, held: false), "初めは知らせるだけ")
        XCTAssertTrue(S21Rules.shouldStartPhone(action: .record, watchWanted: true, phoneRecording: false, held: false))
        XCTAssertFalse(S21Rules.shouldStartPhone(action: .record, watchWanted: true, phoneRecording: true, held: false))
        XCTAssertFalse(S21Rules.shouldStartPhone(action: .record, watchWanted: true, phoneRecording: false, held: true))
        XCTAssertFalse(S21Rules.shouldStartPhone(action: .record, watchWanted: false, phoneRecording: false, held: false))
        XCTAssertEqual(S21Rules.watchQuiet, 600)
    }

    // MARK: - 守5 版のずれ

    func testBuildCheck() {
        XCTAssertEqual(S21Rules.buildCheck(phone: 450, watch: "450")?.ok, true)
        XCTAssertEqual(S21Rules.buildCheck(phone: 450, watch: "440")?.ok, false)
        XCTAssertTrue(S21Rules.buildCheck(phone: 450, watch: "440")?.text.contains("時計の LifeLog を一度開く") == true)
        XCTAssertEqual(S21Rules.buildCheck(phone: 440, watch: "450")?.ok, false)
        XCTAssertNil(S21Rules.buildCheck(phone: 450, watch: nil))
        XCTAssertNil(S21Rules.buildCheck(phone: 450, watch: "abc"))
    }
}

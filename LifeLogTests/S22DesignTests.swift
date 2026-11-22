import XCTest
@testable import LifeLog

/// s22 のデザインの決まり（見5〜見21。2026-11-22。Shared/Design/LLNumber.swift・S22DesignRules.swift・LLWatchRules.swift）
final class S22DesignTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ h: Int, _ m: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: h, minute: m))!
    }

    // MARK: - 見5 数を人が読む形に

    func testDuration() {
        XCTAssertNil(LLNumber.duration(0))
        XCTAssertNil(LLNumber.duration(0.04))
        XCTAssertNil(LLNumber.duration(-3))
        XCTAssertNil(LLNumber.duration(.nan))
        XCTAssertEqual(LLNumber.duration(0.5), "1 秒未満")
        XCTAssertEqual(LLNumber.duration(3.0), "3 秒")
        XCTAssertEqual(LLNumber.duration(3.24), "3.2 秒")
        XCTAssertEqual(LLNumber.duration(8.0), "8 秒")
        XCTAssertEqual(LLNumber.duration(45), "45 秒")
        XCTAssertEqual(LLNumber.duration(59.6), "1 分")
        XCTAssertEqual(LLNumber.duration(150), "2 分 30 秒")
        XCTAssertEqual(LLNumber.duration(1500), "約 25 分")
        XCTAssertEqual(LLNumber.duration(7200), "約 2 時間")
        XCTAssertEqual(LLNumber.duration(12000), "約 3 時間 20 分")
        XCTAssertEqual(LLNumber.duration(86399), "約 1 日")
        XCTAssertEqual(LLNumber.duration(2 * 86400 + 5 * 3600), "約 2 日 5 時間")
        // 実測の「届くまで いちばん遅い 12792.0 分」
        XCTAssertEqual(LLNumber.minutes(12792), "約 9 日")
        XCTAssertEqual(LLNumber.duration(767_520), "約 9 日")
    }

    func testCountsAndSizes() {
        XCTAssertEqual(LLNumber.count(0), "0")
        XCTAssertEqual(LLNumber.count(999), "999")
        XCTAssertEqual(LLNumber.count(1000), "1,000")
        XCTAssertEqual(LLNumber.count(12345), "12,345")
        XCTAssertEqual(LLNumber.count(1_000_000), "1,000,000")
        XCTAssertEqual(LLNumber.count(-1234), "-1,234")
        XCTAssertEqual(LLNumber.bytes(500), "1 KB 未満")
        XCTAssertEqual(LLNumber.bytes(850_000), "850 KB")
        XCTAssertEqual(LLNumber.bytes(1_500_000), "1.5 MB")
        XCTAssertEqual(LLNumber.bytes(12_300_000), "12 MB")
        XCTAssertEqual(LLNumber.bytes(2_000_000_000), "2.0 GB")
        XCTAssertEqual(LLNumber.percent(0.815), "81.5%")
        XCTAssertEqual(LLNumber.percent(0.5), "50%")
        XCTAssertEqual(LLNumber.display("12345"), "12,345")
        XCTAssertEqual(LLNumber.display("18"), "18")
        XCTAssertEqual(LLNumber.display("—"), "—")
    }

    func testHumanizeText() {
        XCTAssertEqual(LLNumber.humanize("ふつう 30 秒・いちばん遅い 12792.0 分"), "ふつう 30 秒・いちばん遅い 約 9 日")
        XCTAssertEqual(LLNumber.humanize("処理 ふつう 0.0 秒"), "処理 ふつう 1 秒未満")
        XCTAssertEqual(LLNumber.humanize("3 回・ふつう 8.0 秒・いちばん長い 10 秒"), "3 回・ふつう 8 秒・いちばん長い 10 秒")
        XCTAssertEqual(LLNumber.humanize("合わせて 90 分"), "合わせて 約 1 時間 30 分")
        XCTAssertEqual(LLNumber.humanize("返事待ち 12345 個・送っている途中 120 個"), "返事待ち 12,345 個・送っている途中 120 個")
        // 読める数はそのまま
        XCTAssertEqual(LLNumber.humanize("録れた時間 9時間40分"), "録れた時間 9時間40分")
        XCTAssertEqual(LLNumber.humanize("2026年11月22日 13:10"), "2026年11月22日 13:10")
        XCTAssertEqual(LLNumber.humanize("90分の1"), "90分の1")
        XCTAssertEqual(LLNumber.humanize("最後 11/22 03:32"), "最後 11/22 03:32")
    }

    // MARK: - 見7 直し方の印の色

    func testToneForFix() {
        XCTAssertEqual(LLTone.forFix("self_"), .act)
        XCTAssertEqual(LLTone.forFix("self"), .act)
        XCTAssertEqual(LLTone.forFix("wait"), .wait)
        XCTAssertEqual(LLTone.forFix("askClaude"), .claude)
        XCTAssertEqual(LLTone.forFix("何か"), .warn)
        XCTAssertEqual(LLTone.forFix(nil), .warn)
        XCTAssertEqual(LLTone.of(ok: true, fix: "self_"), .ok)
        XCTAssertEqual(LLTone.of(ok: false, fix: "wait"), .wait)
        XCTAssertEqual(LLTone.of(ok: nil, fix: "self_"), .unknown)
        XCTAssertEqual(LLTone.guessFix(section: "許可", label: "マイク"), "self_")
        XCTAssertEqual(LLTone.guessFix(section: "時計", label: "届くまで（直近24時間）"), "wait")
        XCTAssertNil(LLTone.guessFix(section: "人", label: "名前のある人"))
        // 赤（本人が動く）がいちばん強く、待てば直るは良いより強いが赤より弱い
        XCTAssertGreaterThan(LLTone.act.weight, LLTone.warn.weight)
        XCTAssertGreaterThan(LLTone.wait.weight, LLTone.ok.weight)
    }

    // MARK: - 見6 6 つの丸の信号

    func testSignalOfRow() {
        XCTAssertEqual(LLSignal.of(section: "端末", label: "アプリの版"), .device)
        XCTAssertEqual(LLSignal.of(section: "許可", label: "マイク"), .device)
        XCTAssertEqual(LLSignal.of(section: "状態", label: "録音"), .recording)
        XCTAssertEqual(LLSignal.of(section: "状態", label: "時計"), .watch)
        XCTAssertEqual(LLSignal.of(section: "状態", label: "同期"), .device)
        XCTAssertEqual(LLSignal.of(section: "設定", label: "家の PC"), .homePC)
        XCTAssertEqual(LLSignal.of(section: "家の PC", label: "様子を送る"), .homePC)
        XCTAssertEqual(LLSignal.of(section: "時計", label: "届くまで"), .watch)
        XCTAssertEqual(LLSignal.of(section: "文字になるまで", label: "区間ごと"), .latency)
        XCTAssertEqual(LLSignal.of(section: "処理", label: "最後の処理"), .latency)
        XCTAssertEqual(LLSignal.of(section: "人", label: "名前の無い声"), .people)
        XCTAssertNil(LLSignal.of(section: "学んだ値", label: "会話の区切り"))
        XCTAssertNil(LLSignal.of(section: "最近のエラー", label: "11/22 03:32"))
        XCTAssertEqual(LLSignal.tone(of: [.ok, .wait, .act]), .act)
        XCTAssertEqual(LLSignal.tone(of: [.ok, .unknown]), .ok)
        XCTAssertEqual(LLSignal.tone(of: [.ok, .wait]), .wait)
        XCTAssertEqual(LLSignal.tone(of: []), .unknown)
        XCTAssertEqual(LLSignal.allCases.count, 6)
    }

    func testSignalGrouping() {
        let items = [
            DiagnosticItem(section: "許可", label: "マイク", value: "未許可", ok: false),
            DiagnosticItem(section: "時計", label: "届くまで（直近24時間）", value: "ふつう 30 秒", ok: false),
            DiagnosticItem(section: "人", label: "名前のある人", value: "3 人", ok: nil),
            DiagnosticItem(section: "学んだ値", label: "会話の区切り", value: "180 秒", ok: nil),
        ]
        let groups = S22Signals.group(items) { _ in nil }
        XCTAssertEqual(groups[.device]?.tone, .act)
        XCTAssertEqual(groups[.watch]?.tone, .wait)
        XCTAssertEqual(groups[.people]?.tone, .unknown)
        XCTAssertNil(groups[.recording])
        // A1 の印があれば、そちらを使う
        let marked = S22Signals.group(items) { $0.label == "マイク" ? "askClaude" : nil }
        XCTAssertEqual(marked[.device]?.tone, .claude)
        XCTAssertEqual(marked[.device]?.bad, 1)
    }

    // MARK: - 見8 文字になるまでの横棒

    func testLatencySegments() {
        let segs = LatencyBarRules.segments([30, nil, 0, 90, 0.01])
        XCTAssertEqual(segs.map(\.name), ["時計→iPhone", "PC の作業"])
        XCTAssertEqual(segs.map(\.fraction), [0.25, 0.75])
        XCTAssertEqual(LatencyBarRules.slowest(segs), "PC の作業")
        XCTAssertTrue(LatencyBarRules.segments([nil, nil, nil, nil, nil]).isEmpty)
        XCTAssertNil(LatencyBarRules.slowest([]))
    }

    // MARK: - 見10 相づちを畳む

    func testFillers() {
        XCTAssertTrue(FillerRules.isFiller("えー"))
        XCTAssertTrue(FillerRules.isFiller("あのー、えっと"))
        XCTAssertTrue(FillerRules.isFiller("うん、うん。"))
        XCTAssertTrue(FillerRules.isFiller("はい"))
        XCTAssertTrue(FillerRules.isFiller("あー、そうそう"))
        XCTAssertFalse(FillerRules.isFiller("うん、行こう"))
        XCTAssertFalse(FillerRules.isFiller("明日"))
        XCTAssertFalse(FillerRules.isFiller(""))
        XCTAssertFalse(FillerRules.isFiller("えーえーえーえーえーえーえー"))
        let groups = FillerRules.groups(["はい", "今日は会議", "うん", "えー", "明日ね"])
        XCTAssertEqual(groups.map { "\($0.start)-\($0.count)-\($0.folded)" }, ["0-1-true", "1-1-false", "2-2-true", "4-1-false"])
    }

    // MARK: - 見11 話題の変わり目

    func testTopicBreaks() {
        let ramen = ["ラーメン二郎に行った", "二郎のラーメンは量が多い", "ラーメンの麺が太い", "ラーメンのスープが濃い",
                     "二郎のラーメンは野菜が多い", "ラーメンの量を選べる", "ラーメン二郎は行列が長い", "ラーメンをまた食べたい"]
        let meeting = ["明日の会議資料を作る", "会議資料は部長に送る", "会議の資料を直す", "会議室を予約する",
                       "会議資料の締め切り", "会議は十時から", "会議資料を印刷する", "会議のあとで部長と話す"]
        XCTAssertEqual(TopicRules.breaks(ramen + meeting), [8])
        // 短い会話・ずっと同じ話には線を引かない
        XCTAssertEqual(TopicRules.breaks(Array(ramen.prefix(6)) + Array(meeting.prefix(4))), [])
        XCTAssertEqual(TopicRules.breaks(Array(repeating: "ラーメン二郎の話", count: 16)), [])
        XCTAssertEqual(TopicRules.grams("ラーメン二郎に行った"), ["ラー", "ーメ", "メン", "ン二", "二郎"])
    }

    // MARK: - 見12 読む幅

    func testReadingWidth() {
        XCTAssertNil(ReadingRules.maxWidth(regular: false, fontSize: 17))
        XCTAssertEqual(ReadingRules.maxWidth(regular: true, fontSize: 17), 38 * 17 + 72)
    }

    // MARK: - 見13 人の丸

    func testAvatar() {
        XCTAssertEqual(AvatarRules.initial("人物12"), "12")
        XCTAssertEqual(AvatarRules.initial("Tanaka"), "T")
        XCTAssertEqual(AvatarRules.initial("さいとうさん"), "さ")
        XCTAssertEqual(AvatarRules.initial("  "), "?")
        let names = ["さいとう", "たなか", "人物3", "人物4", "母", "Ken", "やまだ", "すずき", "人物12", "ジョーダン"]
        let colors = names.map(AvatarRules.colorIndex)
        XCTAssertTrue(colors.allSatisfy { (0..<AvatarRules.paletteCount).contains($0) })
        XCTAssertGreaterThan(Set(colors).count, 2)
        // 同じ名前はいつも同じ色（前後の空白は見ない）
        XCTAssertEqual(AvatarRules.colorIndex("さいとう"), AvatarRules.colorIndex(" さいとう "))
        XCTAssertEqual(AvatarRules.paletteCount, LLAvatar.palette.count)
    }

    // MARK: - 見14 前の写し

    func testCopyAge() {
        let now = at(12)
        XCTAssertEqual(CopyAgeRules.text(nil, now: now), "まだ写しがありません")
        XCTAssertEqual(CopyAgeRules.text(now.addingTimeInterval(-30), now: now), "前の写し たったいま")
        XCTAssertEqual(CopyAgeRules.text(now.addingTimeInterval(-12 * 60), now: now), "前の写し 12 分前")
        XCTAssertEqual(CopyAgeRules.text(now.addingTimeInterval(-3 * 3600), now: now), "前の写し 3 時間前")
        XCTAssertEqual(CopyAgeRules.text(now.addingTimeInterval(-2 * 86400), now: now), "前の写し 2 日前")
        XCTAssertTrue(CopyAgeRules.isStale(now.addingTimeInterval(-13 * 3600), now: now))
        XCTAssertFalse(CopyAgeRules.isStale(now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(CopyAgeRules.isStale(nil, now: now))
    }

    // MARK: - 見15・見18 帯

    func testBandGlow() {
        let a = BandSpan(start: at(10), end: at(10, 5))
        let a2 = BandSpan(start: at(10), end: at(10, 8))
        let b = BandSpan(start: at(11), end: at(11, 2))
        XCTAssertEqual(BandGlow.fresh(old: [a], new: [a2, b]), [BandSpan(start: at(10, 5), end: at(10, 8)), b])
        XCTAssertEqual(BandGlow.fresh(old: [a, b], new: [a, b]), [])
        XCTAssertEqual(BandGlow.fresh(old: [], new: [a]), [a])
    }

    func testBandSlots() {
        let day = at(0)
        let text = BandSlots.encode(talks: [BandSpan(start: at(9), end: at(9, 40))],
                                    recorded: [BandSpan(start: at(8), end: at(10))], dayStart: day)
        XCTAssertEqual(text.count, 48)
        let slots = BandSlots.decode(text)
        XCTAssertEqual(Array(slots[15...20]), [0, 1, 1, 2, 2, 0])
        XCTAssertEqual(slots.filter { $0 != 0 }.count, 4)
        XCTAssertEqual(BandSlots.decode(nil), Array(repeating: 0, count: 48))
        XCTAssertEqual(BandSlots.decode("21x"), [2, 1, 0] + Array(repeating: 0, count: 45))
        XCTAssertEqual(BandSlots.index(of: at(12, 15), dayStart: day), 24)
        XCTAssertEqual(BandSlots.index(of: at(23, 59), dayStart: day), 47)
    }

    func testWidgetStateBandIsMinor() {
        var old = WidgetState(updated: at(9))
        old.todayBand = String(repeating: "0", count: 48)
        old.watchBattery = 0.8
        var new = old
        new.todayBand = "2" + String(repeating: "0", count: 47)
        new.watchBattery = 0.7
        XCTAssertTrue(new.isMinorChange(from: old))
        new.phoneRecording = true
        XCTAssertFalse(new.isMinorChange(from: old))
        // 新しい項目は省ける（前の形の JSON も読める）
        let decoded = try? JSONDecoder().decode(WidgetState.self, from: Data(#"{"updated": 0}"#.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.todayBand)
    }

    // MARK: - 見19 md の表

    func testMarkdownBlocks() {
        let text = """
        # 報告
        - 一つ目
        本文の行
        | 名前 | 数 | メモ |
        |---|---|---|
        | 録音 | 12345 | 多い |
        | 時計 | 3 |
        ---
        """
        let blocks = MarkdownBlocks.parse(text)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "報告"),
            .bullet("一つ目"),
            .paragraph("本文の行"),
            .table(headers: ["名前", "数", "メモ"], rows: [["録音", "12345", "多い"], ["時計", "3", ""]]),
            .rule,
        ])
        XCTAssertTrue(MarkdownBlocks.isSeparator("| :--- | ---: |"))
        XCTAssertFalse(MarkdownBlocks.isSeparator("| 名前 | 数 |"))
        XCTAssertEqual(MarkdownBlocks.parse("段落1\n段落の続き\n\n段落2"), [.paragraph("段落1\n段落の続き"), .paragraph("段落2")])
    }

    // MARK: - 見20 朝・昼・夜の地の色

    func testDayTint() {
        XCTAssertEqual(LLDayTint.part(hour: 7), .morning)
        XCTAssertEqual(LLDayTint.part(hour: 12), .day)
        XCTAssertEqual(LLDayTint.part(hour: 18), .evening)
        XCTAssertEqual(LLDayTint.part(hour: 23), .night)
        XCTAssertEqual(LLDayTint.part(hour: 3), .night)
        XCTAssertEqual(LLDayTint.bgHex(hour: 12, dark: true, enabled: true), 0x0B1220)
        XCTAssertEqual(LLDayTint.bgHex(hour: 23, dark: true, enabled: false), 0x0B1220)
        XCTAssertEqual(LLDayTint.bgHex(hour: 23, dark: false, enabled: false), 0xF3F6FB)
        XCTAssertNotEqual(LLDayTint.bgHex(hour: 7, dark: true, enabled: true), LLDayTint.bgHex(hour: 23, dark: true, enabled: true))
    }

    /// 地の色を変えても、薄い文字（LL.dim）が 4.5:1 より読みにくくならない
    func testDayTintKeepsContrast() {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ v: UInt32) -> Double {
                let c = Double(v) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
        }
        func ratio(_ a: UInt32, _ b: UInt32) -> Double {
            let la = luminance(a), lb = luminance(b)
            return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
        }
        for hour in [3, 7, 12, 18, 23] {
            XCTAssertGreaterThanOrEqual(ratio(0x8A9BB8, LLDayTint.bgHex(hour: hour, dark: true, enabled: true)), 4.5, "暗い \(hour) 時")
            XCTAssertGreaterThanOrEqual(ratio(0x55657F, LLDayTint.bgHex(hour: hour, dark: false, enabled: true)), 4.5, "明るい \(hour) 時")
        }
    }

    // MARK: - 見16・見17 時計

    func testWatchRing() {
        XCTAssertEqual(WatchRingRules.progress(recorded: 0), 0)
        XCTAssertEqual(WatchRingRules.progress(recorded: 6 * 3600), 0.5)
        XCTAssertEqual(WatchRingRules.progress(recorded: 20 * 3600), 1)
        XCTAssertEqual(WatchRingRules.display(.recorded, recorded: 8100, hoursLeft: nil, unsent: 0, waiting: nil).big, "2:15")
        XCTAssertEqual(WatchRingRules.display(.recorded, recorded: 300, hoursLeft: nil, unsent: 0, waiting: nil).big, "0:05")
        XCTAssertEqual(WatchRingRules.display(.hoursLeft, recorded: 0, hoursLeft: 6.5, unsent: 0, waiting: nil).big, "6.5")
        XCTAssertEqual(WatchRingRules.display(.hoursLeft, recorded: 0, hoursLeft: 6, unsent: 0, waiting: nil).big, "6")
        XCTAssertEqual(WatchRingRules.display(.hoursLeft, recorded: 0, hoursLeft: 12.5, unsent: 0, waiting: nil).big, "12")
        XCTAssertEqual(WatchRingRules.display(.hoursLeft, recorded: 0, hoursLeft: nil, unsent: 0, waiting: nil).big, "—")
        XCTAssertEqual(WatchRingRules.display(.unsent, recorded: 0, hoursLeft: nil, unsent: 3, waiting: nil).big, "3")
        XCTAssertEqual(WatchRingRules.display(.waiting, recorded: 0, hoursLeft: nil, unsent: 0, waiting: nil).big, "—")
        XCTAssertEqual(WatchRingRules.display(.waiting, recorded: 0, hoursLeft: nil, unsent: 0, waiting: 4).big, "4")
        XCTAssertEqual(WatchRingRules.Number.recorded.next, .hoursLeft)
        XCTAssertEqual(WatchRingRules.Number.waiting.next, .recorded)
        XCTAssertEqual(WatchRingRules.spoken(.recorded, recorded: 8100, hoursLeft: nil, unsent: 0, waiting: nil), "今日録れた時間 2 時間 15 分")
        XCTAssertEqual(WatchGaugeRules.short(hoursLeft: nil), "—")
        XCTAssertEqual(WatchGaugeRules.short(hoursLeft: 0.5), "<1h")
        XCTAssertEqual(WatchGaugeRules.short(hoursLeft: 6.7), "6h")
        XCTAssertNil(WatchGaugeRules.level(-1))
        XCTAssertEqual(WatchGaugeRules.level(1.2), 1)
    }
}

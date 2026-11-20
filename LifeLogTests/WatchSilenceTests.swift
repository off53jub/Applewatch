import XCTest
@testable import LifeLog

/// 時計の声の無い区切りを送らない（VoiceGate）と、返事待ちの控えの送り直し（WatchDelivery.resendAllowed・resendDue）を確かめる
/// （2026-11-16。docs/v20-watch-silence.md）
final class WatchSilenceTests: XCTestCase {
    private let rate = 16_000.0

    /// 決まった高さの音と倍音（声の母音に近い）
    private func harmonic(seconds: Double, f0: Double = 150, amplitude: Float = 0.1) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for k in 1...14 { v += sin(2 * Double.pi * f0 * Double(k) * t) / Double(k) }
            return Float(v) * amplitude
        }
    }

    /// 雑音（決まった種で毎回同じ）
    private func noise(seconds: Double, amplitude: Float) -> [Float] {
        var state: UInt64 = 0x1234_5678
        return (0..<Int(seconds * rate)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u = Float(Double(state >> 11) / Double(1 << 53))
            return (u * 2 - 1) * amplitude
        }
    }

    // MARK: - FFT と平坦さ

    func testFFTFindsTheRightBin() {
        let fft = RealFFT(size: 1024)
        // 1000Hz はビン 64（1ビン 15.625Hz）
        let tone = (0..<1024).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 16_000)) }
        let power = fft.power(tone)
        XCTAssertEqual(power.count, 513)
        XCTAssertEqual(power.indices.max { power[$0] < power[$1] }, 64)
        // 窓をかけた振幅 1 の正弦波: ピークは (N/4)² 付近
        XCTAssertEqual(Double(power[64]), 256 * 256, accuracy: 256 * 256 * 0.01)
    }

    func testFlatnessSeparatesNoiseFromHarmonics() {
        let fft = RealFFT(size: 1024)
        let flatNoise = VoiceGate.flatness(fft.power(Array(noise(seconds: 0.064, amplitude: 0.1).prefix(1024))), low: 20, high: 217)
        let flatVoice = VoiceGate.flatness(fft.power(Array(harmonic(seconds: 0.064).prefix(1024))), low: 20, high: 217)
        XCTAssertGreaterThan(flatNoise, 0.3)
        XCTAssertLessThan(flatVoice, VoiceGate.tonalFlatness)
        // 帯域の外を指したら平坦（声とみなさない）
        XCTAssertEqual(VoiceGate.flatness([1, 2, 3], low: 0, high: 10), 1)
    }

    // MARK: - 区切りの中の声らしいこま

    func testQuietRoomThenVoiceCountsFrames() {
        var gate = VoiceGate()
        // 静かな部屋（雑音の見積もりができる）→ 声らしい音 1 秒
        gate.feed(noise(seconds: 2, amplitude: 0.001))
        XCTAssertEqual(gate.tonalFrames, 0)
        gate.feed(harmonic(seconds: 1))
        XCTAssertGreaterThanOrEqual(gate.tonalFrames, 10)
        XCTAssertFalse(VoiceGate.shouldDrop(tonalFrames: gate.tonalFrames, enabled: true, meeting: false))
    }

    func testLoudNoiseIsNotVoice() {
        var gate = VoiceGate()
        // 静かな部屋 → 大きな物音（雑音）2 秒。音は大きいが、声らしくはない
        gate.feed(noise(seconds: 2, amplitude: 0.001))
        gate.feed(noise(seconds: 2, amplitude: 0.3))
        XCTAssertGreaterThan(gate.frames, 50)
        XCTAssertEqual(gate.tonalFrames, 0)
        XCTAssertTrue(VoiceGate.shouldDrop(tonalFrames: gate.tonalFrames, enabled: true, meeting: false))
    }

    func testQuietTonalHumIsNotLoud() {
        var gate = VoiceGate()
        // ずっと鳴っている決まった高さの音（冷蔵庫・空調）は、雑音の見積もりに入って「音がした」にならない
        gate.feed(harmonic(seconds: 3, f0: 120, amplitude: 0.01))
        XCTAssertLessThan(gate.tonalFrames, VoiceGate.minTonalFrames)
    }

    func testResetKeepsFloorButClearsCounts() {
        var gate = VoiceGate()
        gate.feed(noise(seconds: 2, amplitude: 0.001))
        gate.feed(harmonic(seconds: 0.5))
        XCTAssertGreaterThan(gate.tonalFrames, 0)
        gate.reset()
        XCTAssertEqual(gate.tonalFrames, 0)
        XCTAssertEqual(gate.frames, 0)
        // 雑音の見積もりは残るので、次の区切りの頭の声もすぐ数えられる
        gate.feed(harmonic(seconds: 0.5))
        XCTAssertGreaterThan(gate.tonalFrames, 0)
    }

    func testFeedInOddPiecesMatchesOneFeed() {
        let audio = noise(seconds: 1, amplitude: 0.001) + harmonic(seconds: 1) + noise(seconds: 1, amplitude: 0.2)
        var whole = VoiceGate()
        whole.feed(audio)
        var pieces = VoiceGate()
        var i = 0
        while i < audio.count {
            let n = min(1365, audio.count - i)
            pieces.feed(Array(audio[i..<(i + n)]))
            i += n
        }
        XCTAssertEqual(whole.tonalFrames, pieces.tonalFrames)
        XCTAssertEqual(whole.frames, pieces.frames)
        XCTAssertEqual(whole.frames, audio.count / VoiceGate.frame)
    }

    func testShouldDropRules() {
        XCTAssertTrue(VoiceGate.shouldDrop(tonalFrames: 0, enabled: true, meeting: false))
        XCTAssertTrue(VoiceGate.shouldDrop(tonalFrames: VoiceGate.minTonalFrames - 1, enabled: true, meeting: false))
        XCTAssertFalse(VoiceGate.shouldDrop(tonalFrames: VoiceGate.minTonalFrames, enabled: true, meeting: false))
        // 設定がオフ・会議モードなら捨てない
        XCTAssertFalse(VoiceGate.shouldDrop(tonalFrames: 0, enabled: false, meeting: false))
        XCTAssertFalse(VoiceGate.shouldDrop(tonalFrames: 0, enabled: true, meeting: true))
    }

    func testSettingsRoundTripAndDefault() {
        let saved = UserDefaults.standard.object(forKey: VoiceGate.enabledKey)
        defer { UserDefaults.standard.set(saved, forKey: VoiceGate.enabledKey) }
        UserDefaults.standard.removeObject(forKey: VoiceGate.enabledKey)
        XCTAssertTrue(VoiceGate.enabled, "初めはオン")
        VoiceGate.enabled = false
        var context: [String: Any] = [:]
        ChunkCutter.addSettings(to: &context)
        XCTAssertEqual(context[VoiceGate.enabledKey] as? Bool, false)
        VoiceGate.readSettings([VoiceGate.enabledKey: true])
        XCTAssertTrue(VoiceGate.enabled)
        // 項目が無ければ変えない
        VoiceGate.readSettings([:])
        XCTAssertTrue(VoiceGate.enabled)
    }

    func testDroppedCountIsPerDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let day1 = Date(timeIntervalSince1970: 1_794_700_000)
        let day2 = day1.addingTimeInterval(86400)
        let before = VoiceGate.droppedToday(now: day1, calendar: calendar)
        VoiceGate.noteDropped(now: day1, calendar: calendar)
        VoiceGate.noteDropped(now: day1, calendar: calendar)
        XCTAssertEqual(VoiceGate.droppedToday(now: day1, calendar: calendar), before + 2)
        XCTAssertEqual(VoiceGate.droppedToday(now: day2, calendar: calendar), 0)
        VoiceGate.noteDropped(now: day2, calendar: calendar)
        XCTAssertEqual(VoiceGate.droppedToday(now: day2, calendar: calendar), 1)
    }

    // MARK: - 返事待ちの控えの送り直し（タスク 79）

    func testResendAllowedWhenQueueIsShort() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(WatchDelivery.resendAllowed(queued: [], limit: 10, lastFinished: nil, now: now))
        XCTAssertTrue(WatchDelivery.resendAllowed(queued: Array(repeating: now, count: 9), limit: 10, lastFinished: nil, now: now))
    }

    func testStuckTransfersDoNotBlockResendWhileQueueMoves() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 11/12〜16 の形: 列に 26 個、どれも何時間も前に入れたまま終わらない
        let stuck: [Date?] = Array(repeating: now.addingTimeInterval(-5 * 3600), count: 26)
        // 列が動いていない（最後に終わったのが 1 時間前・終わったことが無い）なら送り直さない（列が長くなるだけ）
        XCTAssertFalse(WatchDelivery.resendAllowed(queued: stuck, limit: 10, lastFinished: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(WatchDelivery.resendAllowed(queued: stuck, limit: 10, lastFinished: nil, now: now))
        // 列が動いている（5 分前に終わった）なら、止まっているものは数えずに送り直す
        XCTAssertTrue(WatchDelivery.resendAllowed(queued: stuck, limit: 10, lastFinished: now.addingTimeInterval(-300), now: now))
        // 新しい区切りがたくさん流れているあいだは、今までどおり待つ
        let busy: [Date?] = stuck + Array(repeating: now.addingTimeInterval(-60), count: 10)
        XCTAssertFalse(WatchDelivery.resendAllowed(queued: busy, limit: 10, lastFinished: now.addingTimeInterval(-30), now: now))
        // 送り始めた時刻が読めないものは、止まっているほうに数える
        let unknown: [Date?] = Array(repeating: nil, count: 12)
        XCTAssertTrue(WatchDelivery.resendAllowed(queued: unknown, limit: 10, lastFinished: now.addingTimeInterval(-60), now: now))
    }

    func testResendDueKeepsOldScheduleAndSkipsOldChunks() {
        func due(_ ago: TimeInterval, _ count: Int, _ cutAge: TimeInterval?) -> Bool {
            WatchDelivery.resendDue(sentAgo: ago, count: count, cutAge: cutAge,
                                    resendAfter: 1800, maxResends: 3, slowResendAfter: 6 * 3600)
        }
        // 30分ごとに3回、そのあとは6時間ごと（今までどおり）
        XCTAssertFalse(due(1799, 0, 3600))
        XCTAssertTrue(due(1800, 0, 3600))
        XCTAssertTrue(due(1800, 2, 3600))
        XCTAssertFalse(due(1800, 3, 3600))
        XCTAssertTrue(due(6 * 3600, 3, 8 * 3600))
        // 3日より古い区切りは送り直さない（iPhone が覚えているのは4日）
        XCTAssertTrue(due(6 * 3600, 5, 3 * 86400 - 60))
        XCTAssertFalse(due(6 * 3600, 5, 3 * 86400 + 60))
        // 区切った時刻が分からなければ、今までどおり
        XCTAssertTrue(due(6 * 3600, 5, nil))
        XCTAssertLessThan(WatchDelivery.resendMaxAge, 4 * 86400)
    }

    // MARK: - 終わらない受け渡しを取り消す（2026-11-20）

    func testStuckTransfersPicksOnlyOldOnesOldestFirst() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let h: TimeInterval = 3600
        let queued: [(name: String, sent: Date?, cut: Date?)] = [
            ("a.m4a", now.addingTimeInterval(-1 * h), nil),        // 新しい: 取り消さない
            ("b.m4a", now.addingTimeInterval(-30 * h), nil),       // 古い
            ("c.m4a", now.addingTimeInterval(-7 * h), nil),        // 古い
            ("d.m4a", nil, now.addingTimeInterval(-50 * h)),       // 送り始めが読めない → 区切った時刻で見る
            ("e.m4a", nil, nil),                                   // どちらも無い: 取り消さない
        ]
        XCTAssertEqual(WatchDelivery.stuckTransfers(queued, now: now), ["d.m4a", "b.m4a", "c.m4a"])
        XCTAssertEqual(WatchDelivery.stuckTransfers(queued, now: now, max: 2), ["d.m4a", "b.m4a"])
        XCTAssertEqual(WatchDelivery.stuckTransfers(queued, now: now, max: 0), [])
        XCTAssertEqual(WatchDelivery.stuckTransfers([], now: now), [])
    }

    func testStuckTransferRuleIsSlowerThanResend() {
        // 送り直し（30 分）や「止まっている」の見なし（30 分）より長く待ってから取り消す
        XCTAssertGreaterThan(WatchDelivery.stuckTransferAge, WatchDelivery.staleTransferAge)
        XCTAssertGreaterThan(WatchDelivery.unstickPerPass, 0)
    }

    func testRetireOnlyWhenTooOldAndOnPC() {
        let old = WatchDelivery.resendMaxAge + 3600
        XCTAssertTrue(WatchDelivery.retireInsteadOfResend(cutAge: old, sentToPC: true))
        XCTAssertFalse(WatchDelivery.retireInsteadOfResend(cutAge: old, sentToPC: false))   // PC に無ければ送り直す
        XCTAssertFalse(WatchDelivery.retireInsteadOfResend(cutAge: 3600, sentToPC: true))   // 新しければ送り直す
        XCTAssertFalse(WatchDelivery.retireInsteadOfResend(cutAge: nil, sentToPC: true))
    }
}

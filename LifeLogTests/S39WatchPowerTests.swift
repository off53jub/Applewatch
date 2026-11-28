import AVFoundation
import XCTest
@testable import LifeLog

/// s39（2026-11-29）外出中の時計の省電力。Shared/Audio/S39WatchPower.swift・S39WatchPowerAudio.swift
final class S39WatchPowerTests: XCTestCase {
    // MARK: 設定（どれも初めはオン・戻せる）

    func testSettingsStartOnAndTravel() {
        let defaults = UserDefaults(suiteName: "s39-test-\(UUID().uuidString)")!
        var context: [String: Any] = [:]
        S39WatchPower.addSettings(to: &context, defaults: defaults)
        for key in S39WatchPower.allKeys { XCTAssertEqual(context[key] as? Bool, true, key) }
        defaults.set(false, forKey: S39WatchPower.onKey)
        S39WatchPower.addSettings(to: &context, defaults: defaults)
        XCTAssertEqual(context[S39WatchPower.onKey] as? Bool, false)
        let watch = UserDefaults(suiteName: "s39-watch-\(UUID().uuidString)")!
        S39WatchPower.readSettings(context, defaults: watch)
        XCTAssertFalse(S39WatchPower.isOn(S39WatchPower.onKey, defaults: watch))
        XCTAssertTrue(S39WatchPower.isOn(S39WatchPower.quietKey, defaults: watch))
    }

    // MARK: 外出中の判定

    func testOutOfReachNeedsAnOldQueueAndNoRecentFinish() {
        XCTAssertFalse(S39WatchPower.outOfReach(reachable: true, queued: 5, oldestQueuedAge: 3600, lastFinishedAgo: 3600))
        XCTAssertFalse(S39WatchPower.outOfReach(reachable: false, queued: 0, oldestQueuedAge: nil, lastFinishedAgo: 3600))
        XCTAssertFalse(S39WatchPower.outOfReach(reachable: false, queued: 3, oldestQueuedAge: 10 * 60, lastFinishedAgo: 3600))
        XCTAssertFalse(S39WatchPower.outOfReach(reachable: false, queued: 3, oldestQueuedAge: 3600, lastFinishedAgo: 60))
        XCTAssertTrue(S39WatchPower.outOfReach(reachable: false, queued: 3, oldestQueuedAge: 3600, lastFinishedAgo: 31 * 60))
        XCTAssertTrue(S39WatchPower.outOfReach(reachable: false, queued: 3, oldestQueuedAge: 3600, lastFinishedAgo: nil))
    }

    func testAwayWhy() {
        XCTAssertEqual(S39WatchPower.awayWhy(on: true, charging: false, phoneAway: true, outOfReach: false, lanSentAgo: nil), .phone)
        XCTAssertEqual(S39WatchPower.awayWhy(on: true, charging: false, phoneAway: false, outOfReach: true, lanSentAgo: nil), .reach)
        XCTAssertEqual(S39WatchPower.awayWhy(on: true, charging: false, phoneAway: false, outOfReach: false, lanSentAgo: nil), .home)
        // 充電中・設定がオフ・家の Wi-Fi で 30 分以内に家の PC に届いた、なら家（家の動きは変えない）
        XCTAssertEqual(S39WatchPower.awayWhy(on: true, charging: true, phoneAway: true, outOfReach: true, lanSentAgo: nil), .home)
        XCTAssertEqual(S39WatchPower.awayWhy(on: false, charging: false, phoneAway: true, outOfReach: true, lanSentAgo: nil), .home)
        XCTAssertEqual(S39WatchPower.awayWhy(on: true, charging: false, phoneAway: true, outOfReach: true, lanSentAgo: 5 * 60), .home)
        XCTAssertEqual(S39WatchPower.awayWhy(on: true, charging: false, phoneAway: true, outOfReach: false, lanSentAgo: 40 * 60), .phone)
    }

    // MARK: 3 休日は自動で外出モード

    func testHoldAwayKeepsTheOldRuleAndAddsHolidays() {
        // 「休日は自動」がオフなら前の HolidayRules.awayHold と同じ
        for mode in [false, true] { for away in [false, true] { for charging in [false, true] {
            XCTAssertEqual(S39WatchPower.holdAway(mode: mode, holidayAuto: false, holiday: true, away: away, charging: charging),
                           HolidayRules.awayHold(mode: mode, away: away, charging: charging))
        } } }
        XCTAssertTrue(S39WatchPower.holdAway(mode: false, holidayAuto: true, holiday: true, away: true, charging: false))
        XCTAssertFalse(S39WatchPower.holdAway(mode: false, holidayAuto: true, holiday: false, away: true, charging: false))
        XCTAssertFalse(S39WatchPower.holdAway(mode: false, holidayAuto: true, holiday: true, away: false, charging: false))
        XCTAssertFalse(S39WatchPower.holdAway(mode: false, holidayAuto: true, holiday: true, away: true, charging: true))
    }

    // MARK: 6 電池が少ないときは溜める

    func testLowBatteryHoldHasAGap() {
        XCTAssertFalse(S39WatchPower.lowBatteryHold(on: true, away: true, level: 0.21, charging: false, wasHolding: false))
        XCTAssertTrue(S39WatchPower.lowBatteryHold(on: true, away: true, level: 0.19, charging: false, wasHolding: false))
        XCTAssertTrue(S39WatchPower.lowBatteryHold(on: true, away: true, level: 0.23, charging: false, wasHolding: true))
        XCTAssertFalse(S39WatchPower.lowBatteryHold(on: true, away: true, level: 0.26, charging: false, wasHolding: true))
        XCTAssertFalse(S39WatchPower.lowBatteryHold(on: true, away: true, level: 0.10, charging: true, wasHolding: true))
        XCTAssertFalse(S39WatchPower.lowBatteryHold(on: true, away: false, level: 0.10, charging: false, wasHolding: false))
        XCTAssertFalse(S39WatchPower.lowBatteryHold(on: false, away: true, level: 0.10, charging: false, wasHolding: false))
        XCTAssertFalse(S39WatchPower.lowBatteryHold(on: true, away: true, level: nil, charging: false, wasHolding: false))
    }

    // MARK: 4・5・8・9・10・11・13・14

    func testGuardIsOffOnlyWhenAway() {
        XCTAssertTrue(S39WatchPower.guardWanted(recording: true, enabled: true, away: false, on: true))
        XCTAssertFalse(S39WatchPower.guardWanted(recording: true, enabled: true, away: true, on: true))
        XCTAssertTrue(S39WatchPower.guardWanted(recording: true, enabled: true, away: true, on: false))
        XCTAssertFalse(S39WatchPower.guardWanted(recording: false, enabled: true, away: false, on: true))
        XCTAssertFalse(S39WatchPower.guardWanted(recording: true, enabled: false, away: false, on: true))
    }

    func testContextIsThinnedOnlyAwayWithTheScreenOff() {
        let t = 10_000.0
        XCTAssertTrue(S39WatchPower.contextDue(urgent: false, away: false, screenOn: false, lastSent: t, now: t + 1))
        XCTAssertTrue(S39WatchPower.contextDue(urgent: false, away: true, screenOn: true, lastSent: t, now: t + 1))
        XCTAssertTrue(S39WatchPower.contextDue(urgent: true, away: true, screenOn: false, lastSent: t, now: t + 1))
        XCTAssertFalse(S39WatchPower.contextDue(urgent: false, away: true, screenOn: false, lastSent: t, now: t + 60))
        XCTAssertTrue(S39WatchPower.contextDue(urgent: false, away: true, screenOn: false, lastSent: t, now: t + 4 * 60))
        // 休んでいるあいだの 5 分ごとの知らせは必ず通る（iPhone の 10 分の見張りに引っかからない）
        XCTAssertLessThan(S39WatchPower.contextGapAway, 300)
    }

    func testDirectToPCOnlyAtHomeOrInTheRescueWindow() {
        XCTAssertTrue(S39WatchPower.directAllowed(away: false, on: true, rescueWindow: false))
        XCTAssertFalse(S39WatchPower.directAllowed(away: true, on: true, rescueWindow: false))
        XCTAssertTrue(S39WatchPower.directAllowed(away: true, on: true, rescueWindow: true))
        XCTAssertTrue(S39WatchPower.directAllowed(away: true, on: false, rescueWindow: false))
    }

    func testRetriesWaitOnlyWhenAwayAndOutOfReach() {
        let t = 50_000.0
        XCTAssertTrue(S39WatchPower.retryDue(on: true, away: false, outOfReach: true, reachable: false, lastRetry: t, now: t + 60))
        XCTAssertTrue(S39WatchPower.retryDue(on: true, away: true, outOfReach: false, reachable: false, lastRetry: t, now: t + 60))
        XCTAssertTrue(S39WatchPower.retryDue(on: true, away: true, outOfReach: true, reachable: true, lastRetry: t, now: t + 60))
        XCTAssertFalse(S39WatchPower.retryDue(on: true, away: true, outOfReach: true, reachable: false, lastRetry: t, now: t + 60))
        XCTAssertTrue(S39WatchPower.retryDue(on: true, away: true, outOfReach: true, reachable: false, lastRetry: t, now: t + 31 * 60))
    }

    func testWakeGapAndMicCheck() {
        XCTAssertEqual(S39WatchPower.wakeGap(on: true, away: false), 120)
        XCTAssertEqual(S39WatchPower.wakeGap(on: true, away: true), 600)
        XCTAssertEqual(S39WatchPower.wakeGap(on: false, away: true), 120)
        XCTAssertEqual(S39WatchPower.micCheckEvery(resting: false, on: true), 20)
        XCTAssertEqual(S39WatchPower.micCheckEvery(resting: true, on: true), 30)
        XCTAssertEqual(S39WatchPower.micCheckEvery(resting: true, on: false), 20)
        // 止まりの見つかりが 60 秒（仮）を超えない（見る間 + 届かない秒のしきい値 20）
        XCTAssertLessThanOrEqual(S39WatchPower.micCheckResting + S39WatchPower.micCheck, 60)
    }

    func testWidgetDue() {
        let t = 70_000.0
        XCTAssertTrue(S39WatchPower.widgetDue(on: true, away: false, same: true, recordingChanged: false, lastWrite: t, now: t))
        XCTAssertFalse(S39WatchPower.widgetDue(on: true, away: true, same: true, recordingChanged: false, lastWrite: 0, now: t))
        XCTAssertTrue(S39WatchPower.widgetDue(on: true, away: true, same: false, recordingChanged: true, lastWrite: t, now: t + 1))
        XCTAssertFalse(S39WatchPower.widgetDue(on: true, away: true, same: false, recordingChanged: false, lastWrite: t, now: t + 60))
        XCTAssertTrue(S39WatchPower.widgetDue(on: true, away: true, same: false, recordingChanged: false, lastWrite: t, now: t + 15 * 60))
    }

    func testLightHaptic() {
        XCTAssertTrue(S39WatchPower.lightHaptic(on: true, away: false))
        XCTAssertFalse(S39WatchPower.lightHaptic(on: true, away: true))
        XCTAssertTrue(S39WatchPower.lightHaptic(on: false, away: true))
    }

    // MARK: 2 マイクの束

    func testSlicesKeepTheOldSize() {
        XCTAssertEqual(S39WatchPower.slices(frames: 0), [])
        XCTAssertEqual(S39WatchPower.slices(frames: 4096), [0..<4096])
        // watchOS が聞かなかった（前と同じくらいの束）ときは分けない
        XCTAssertEqual(S39WatchPower.slices(frames: 4800), [0..<4800])
        XCTAssertEqual(S39WatchPower.slices(frames: 16384), [0..<4096, 4096..<8192, 8192..<12288, 12288..<16384])
        let odd = S39WatchPower.slices(frames: 16000)
        XCTAssertEqual(odd.count, 4)
        XCTAssertEqual(odd.first?.lowerBound, 0)
        XCTAssertEqual(odd.last?.upperBound, 16000)
        XCTAssertEqual(odd.reduce(0) { $0 + $1.count }, 16000)
    }

    func testTapCount() {
        var tap = S39WatchPower.TapCount()
        XCTAssertNil(tap.average(day: "2026-11-29"))
        tap.add(day: "2026-11-29", frames: 4096, rate: 48_000)
        tap.add(day: "2026-11-29", frames: 16384, rate: 48_000)
        XCTAssertEqual(tap.average(day: "2026-11-29"), 10240)
        XCTAssertEqual(tap.rate, 48_000)
        tap.add(day: "2026-11-30", frames: 100, rate: 48_000)
        XCTAssertEqual(tap.average(day: "2026-11-30"), 100)
        XCTAssertNil(tap.average(day: "2026-11-29"))
    }

    // MARK: 1 の安全の見張り

    func testLevelGapNeedsEnoughQuietSamplesAndASmallGap() {
        var gap = S39WatchPower.LevelGap()
        for _ in 0..<49 { gap.feed(rawDB: -60.5, convertedDB: -60) }
        XCTAssertFalse(gap.usable)
        gap.feed(rawDB: -60.5, convertedDB: -60)
        XCTAssertTrue(gap.usable)
        // 大きな音の束は数えない
        gap.feed(rawDB: 0, convertedDB: -10)
        XCTAssertEqual(gap.count, 50)
        var noisy = S39WatchPower.LevelGap()
        for _ in 0..<60 { noisy.feed(rawDB: -55, convertedDB: -60) }  // 高い音の雑音が多い
        XCTAssertFalse(noisy.usable)
    }

    // MARK: 電池の見本

    func testBatterySampleGetsAFifthValueWithoutChangingTheFirstFour() {
        let base = HolidayRules.addingSample([], time: Date(timeIntervalSince1970: 3600), level: 0.8, holding: true, charging: false)
        let marked = S39WatchPower.markingLast(base, saving: true)
        XCTAssertEqual(Array(marked[0].prefix(4)), base[0])
        XCTAssertEqual(marked[0].count, 5)
        XCTAssertEqual(marked[0][4], 1)
        // 4 つ揃っていない古い見本には足さない
        XCTAssertEqual(S39WatchPower.markingLast([[1, 0.5, 0]], saving: true), [[1, 0.5, 0]])
        // 前の減りの数え方は 5 つ目があっても同じ
        let samples: [[Double]] = [[0, 0.80, 1, 0, 1], [3600, 0.76, 1, 0, 1], [7200, 0.72, 1, 0, 0], [10800, 0.66, 1, 0, 0]]
        XCTAssertEqual(HolidayRules.drainPerHour(samples, holding: true), 4.7)
        XCTAssertEqual(S39WatchPower.drainPerHour(samples, saving: true), 4.0)
        XCTAssertEqual(S39WatchPower.drainPerHour(samples, saving: false), 6.0)
    }

    func testPhoneDetailCopiesOnlyWhatIsThere() {
        XCTAssertTrue(S39WatchPower.phoneDetail([:]).isEmpty)
        let detail = S39WatchPower.phoneDetail([S39WatchPower.awayWhyKey: "phone", S39WatchPower.tapFramesKey: 4800,
                                                S39WatchPower.skippedKey: ["context": 3]])
        XCTAssertEqual(detail["watchS39Away"] as? String, "phone")
        XCTAssertEqual(detail["watchS39TapFrames"] as? Int, 4800)
        XCTAssertEqual(detail["watchS39Skipped"] as? [String: Int], ["context": 3])
    }

    func testTodayCounts() {
        var saved: [String: Int] = ["2026-11-28|context": 9]
        saved = S39WatchPower.bumped(saved, "context", day: "2026-11-29")
        saved = S39WatchPower.bumped(saved, "context", day: "2026-11-29")
        saved = S39WatchPower.bumped(saved, "wake", day: "2026-11-29")
        XCTAssertEqual(S39WatchPower.todayCounts(saved, day: "2026-11-29"), ["context": 2, "wake": 1])
    }

    // MARK: 1 休んでいるあいだ変換しなくても、書く中身は前と同じ

    private static let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private static let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    /// 静か（低い小さな音）が 10 秒、そのあと声らしい音が 1.5 秒の 48kHz の音を、4096 ずつの束にする
    private func stream() -> [AVAudioPCMBuffer] {
        let rate = 48_000.0
        let total = Int(rate * 11.5)
        var out: [AVAudioPCMBuffer] = []
        var start = 0
        while start < total {
            let n = min(4096, total - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: Self.input, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            let p = buffer.floatChannelData![0]
            for i in 0..<n {
                let t = Double(start + i) / rate
                var v = 0.002 * sin(2 * .pi * 120 * t) + 0.001 * sin(2 * .pi * 650 * t)
                if t >= 10 { v += 0.2 * sin(2 * .pi * 300 * t) + 0.1 * sin(2 * .pi * 1250 * t) }
                p[i] = Float(v)
            }
            out.append(buffer)
            start += n
        }
        return out
    }

    /// 休んでいるところから流して、起きた束の番号と、起きてから書いた音（16kHz）を返す
    private func run(raw: Bool, _ buffers: [AVAudioPCMBuffer]) -> (wakeAt: Int?, written: [Float]) {
        let converter = AVAudioConverter(from: Self.input, to: Self.output)!
        var gate = SilenceGate()
        var preRoll: [AVAudioPCMBuffer] = []
        var roll = S39WatchPowerAudio.RestRoll()
        var written: [Float] = []
        var wakeAt: Int?
        func append(_ b: AVAudioPCMBuffer) {
            let p = b.floatChannelData![0]
            for i in 0..<Int(b.frameLength) { written.append(p[i]) }
        }
        for (index, buffer) in buffers.enumerated() {
            if wakeAt != nil {
                if let out = S39WatchPowerAudio.convert(buffer, with: converter, to: Self.output) { append(out) }
                continue
            }
            if raw {
                let step = gate.feed(buffer.floatChannelData![0], count: Int(buffer.frameLength), rate: 48_000, resting: true)
                roll.append(S39WatchPowerAudio.copy(buffer)!, keep: SilenceGate.preRoll)
                if step == .wake {
                    wakeAt = index
                    roll.converted(with: converter, to: Self.output).forEach(append)
                }
            } else {
                guard let out = S39WatchPowerAudio.convert(buffer, with: converter, to: Self.output) else { continue }
                let step = gate.feed(out.floatChannelData![0], count: Int(out.frameLength), rate: 16_000, resting: true)
                preRoll.append(out)
                var total = preRoll.reduce(0) { $0 + Int($1.frameLength) }
                while total > Int(SilenceGate.preRoll * 16_000), preRoll.count > 1 {
                    total -= Int(preRoll.removeFirst().frameLength)
                }
                if step == .wake {
                    wakeAt = index
                    preRoll.forEach(append)
                }
            }
        }
        return (wakeAt, written)
    }

    func testRawWhileRestingWritesTheSameSound() {
        let saved = UserDefaults.standard.object(forKey: "recordingHeld")
        UserDefaults.standard.set(false, forKey: "recordingHeld")
        defer { UserDefaults.standard.set(saved, forKey: "recordingHeld") }
        let buffers = stream()
        let old = run(raw: false, buffers)
        let new = run(raw: true, buffers)
        // 同じ束で起きる（声のはじめ＝10 秒のところの少しあと）
        XCTAssertNotNil(old.wakeAt)
        XCTAssertEqual(old.wakeAt, new.wakeAt)
        // 書いた長さの違いは、変換器の出だしの遅れ（数ミリ秒）まで
        XCTAssertLessThanOrEqual(abs(old.written.count - new.written.count), 128)
        // ずれ（変換器の遅れ・数ミリ秒）を合わせると、中身はほとんど同じ。変換器をまっさらにすると、16kHz の点の取り方が
        // 元の音の 1 点（48kHz の 1/3 点＝0.02 ミリ秒）までずれることがあるので、形の重なり（相関）で比べる
        var best: Double = 0
        for lag in -128...128 {
            var dot = 0.0, a2 = 0.0, b2 = 0.0
            for i in 400..<min(old.written.count, new.written.count - 128) where i + lag >= 400 {
                let x = Double(old.written[i]), y = Double(new.written[i + lag])
                dot += x * y
                a2 += x * x
                b2 += y * y
            }
            if a2 > 0, b2 > 0 { best = max(best, dot / (a2 * b2).squareRoot()) }
        }
        XCTAssertGreaterThan(best, 0.99)
        // 0.1 秒ごとの音の大きさも 1dB 以内（声の出だしの窓は、ずれの分だけ動く）（声の頭の 2.5 秒・そのあとの声）
        func levels(_ x: [Float]) -> [Double] {
            stride(from: 400, to: x.count - 1600, by: 1600).map { start in
                let w = x[start..<(start + 1600)]
                return 10 * log10(max(w.reduce(0) { $0 + Double($1 * $1) } / 1600, 1e-12))
            }
        }
        let a = levels(old.written), b = levels(new.written)
        for (x, y) in zip(a, b) where x > -50 { XCTAssertEqual(x, y, accuracy: 1.0) }
    }

    func testRestRollKeepsTheLast2Point5Seconds() {
        var roll = S39WatchPowerAudio.RestRoll()
        for buffer in stream().prefix(100) { roll.append(S39WatchPowerAudio.copy(buffer)!, keep: SilenceGate.preRoll) }
        XCTAssertLessThanOrEqual(roll.frames, Int(2.5 * 48_000))
        XCTAssertGreaterThan(roll.frames, Int(2.5 * 48_000) - 4096)
    }

    func testCopyKeepsTheSamples() {
        let buffer = stream()[0]
        let part = S39WatchPowerAudio.copy(buffer, range: 100..<200)!
        XCTAssertEqual(part.frameLength, 100)
        XCTAssertEqual(part.floatChannelData![0][0], buffer.floatChannelData![0][100])
        XCTAssertEqual(part.floatChannelData![0][99], buffer.floatChannelData![0][199])
        XCTAssertNil(S39WatchPowerAudio.copy(buffer, range: 0..<5000))
    }
}

import AVFoundation
import XCTest
@testable import LifeLog

/// 版 9（2026-11-07）の iPhone 側を確かめる。
/// 1. 職場の会話の印（POST /records の work）
/// 2. 夜の聞き直しで言語モデルに頼む回数（まとめ方・1晩の上限）
/// 3. 外付けマイク（マイクの選び方・2チャンネルの音の分け方・左右の大きさの手がかり）。作り物の2チャンネルの音で確かめる
@MainActor
final class V9Tests: XCTestCase {
    /// 2026-11-07T06:58:25.123Z
    private let t = Date(timeIntervalSince1970: 1_794_034_705.123)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: - 1. 職場の会話の印

    private func conversation(_ start: Date, text: String) -> ConversationLog.Conversation {
        var c = ConversationLog.Conversation(start: start, end: start.addingTimeInterval(60), docIndex: 1)
        c.lines = [ConversationLog.Line(time: start, speaker: nil, text: text)]
        c.closed = true
        return c
    }

    private func json(_ body: PCRecordsBody) throws -> [String: Any] {
        let data = try PCJSON.encoder().encode(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRecordsBodyMarksWorkConversations() throws {
        let work = t, home = t.addingTimeInterval(3600)
        let day = ConversationLog.SyncDay(conversations: [conversation(work, text: "a"), conversation(home, text: "b")],
                                          removed: [], summaryWritten: false, summary: nil, build: 200)
        let body = PCRecordsBody.make(day) { $0 == work }
        XCTAssertEqual(body.work, [work])
        let object = try json(body)
        // 職場の会話の start は、会話の start と同じ書き方（ISO 8601・UTC・ミリ秒）
        XCTAssertEqual(object["work"] as? [String], ["2026-11-07T06:58:25.123Z"])
        let conversations = try XCTUnwrap(object["conversations"] as? [[String: Any]])
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations.first?["start"] as? String, "2026-11-07T06:58:25.123Z")
        // 同期と同じ項目はそのまま残る
        XCTAssertEqual(object["build"] as? Int, 200)
        XCTAssertEqual(object["summaryWritten"] as? Bool, false)
        XCTAssertNotNil(object["removed"])
    }

    func testRecordsBodyWithoutWorkHasEmptyList() throws {
        let day = ConversationLog.SyncDay(conversations: [conversation(t, text: "a")], removed: [], summaryWritten: true,
                                          summary: nil)
        let object = try json(PCRecordsBody.make(day) { _ in false })
        XCTAssertEqual(object["work"] as? [String], [])
        XCTAssertEqual((object["conversations"] as? [[String: Any]])?.count, 1)
    }

    func testRecordsBodyDecodesBackAsSyncDay() throws {
        // PC が今までどおり SyncDay として読んでも読める（work は知らない項目として読み飛ばされる）
        let day = ConversationLog.SyncDay(conversations: [conversation(t, text: "a")], removed: [], summaryWritten: false,
                                          summary: nil)
        let data = try PCJSON.encoder().encode(PCRecordsBody.make(day) { _ in true })
        let back = try PCJSON.decoder().decode(ConversationLog.SyncDay.self, from: data)
        XCTAssertEqual(back.conversations.count, 1)
        XCTAssertEqual(back.conversations.first?.lines.first?.text, "a")
    }

    func testFormatUpgradeResendsEveryDaySentBefore() {
        let sent: [String: Double] = ["2026-08-01": 5, "2026-11-06": 9]
        let resend = PCRecords.resendAll(sent)
        XCTAssertEqual(resend, ["2026-08-01": -1, "2026-11-06": -1])
        // 60日より前の日でも、前に送った日は送り直す
        let days = PCRecords.daysToSend(days: ["2026-08-01", "2026-11-06"], stamps: ["2026-08-01": 5, "2026-11-06": 9],
                                        sent: resend, oldest: "2026-09-08")
        XCTAssertEqual(days, ["2026-11-06", "2026-08-01"])
    }

    // MARK: - 2. 夜の聞き直しで言語モデルに頼む回数

    func testNightKey() {
        let c = utc
        func at(_ day: Int, _ hour: Int) -> Date {
            c.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        XCTAssertEqual(NightBudget.night(for: at(7, 23), calendar: c), "2026-11-07")
        XCTAssertEqual(NightBudget.night(for: at(8, 3), calendar: c), "2026-11-07")
        // 昼に「今すぐ聞き直す」を押したときは、ゆうべの分に数える
        XCTAssertEqual(NightBudget.night(for: at(8, 14), calendar: c), "2026-11-07")
        XCTAssertEqual(NightBudget.night(for: at(8, 19), calendar: c), "2026-11-08")
    }

    func testBatchesAboutFiveMinutes() {
        XCTAssertTrue(NightBudget.fits(batch: 0, adding: 500))   // まとめが空なら、長い区切りも1つは入る
        XCTAssertTrue(NightBudget.fits(batch: 240, adding: 60))
        XCTAssertFalse(NightBudget.fits(batch: 240, adding: 120))
        // 1時間の録音を、区切りの長さごとにまとめたときの回数
        func calls(chunk: TimeInterval, count: Int) -> Int {
            var n = 0, seconds: TimeInterval = 0
            for _ in 0..<count {
                if !NightBudget.fits(batch: seconds, adding: chunk) {
                    n += 1
                    seconds = 0
                }
                seconds += chunk
            }
            return n + (seconds > 0 ? 1 : 0)
        }
        let fiveMinuteEra = calls(chunk: 300, count: 12)
        XCTAssertEqual(fiveMinuteEra, 12)
        // 短めの区切り（45秒〜2分）でも、5分の区切りのころと同じくらい（多くても1.5倍まで）
        XCTAssertEqual(calls(chunk: 60, count: 60), 12)
        XCTAssertLessThanOrEqual(calls(chunk: 120, count: 30), fiveMinuteEra * 3 / 2)
        XCTAssertLessThanOrEqual(calls(chunk: 45, count: 80), fiveMinuteEra * 3 / 2)
    }

    func testNightBudgetStopsAtLimitAndGivesBack() {
        let key = "nightLLMUsed"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let night = utc.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 23))!
        // （日の決め方は端末の暦。同じ時刻で数えるので、どの暦でも同じ夜になる）
        for _ in 0..<NightBudget.perNight { XCTAssertTrue(NightBudget.take(now: night)) }
        XCTAssertFalse(NightBudget.take(now: night))
        XCTAssertEqual(NightBudget.left(now: night), 0)
        NightBudget.giveBack(now: night)
        XCTAssertEqual(NightBudget.left(now: night), 1)
        // 次の夜は数え直す
        let next = night.addingTimeInterval(24 * 3600)
        XCTAssertEqual(NightBudget.used(now: next), 0)
        XCTAssertTrue(NightBudget.take(now: next))
    }

    func testPicksAcrossBatchedChunks() {
        let sure = ConversationLog.Line(time: t, speaker: nil, text: "そのまま", confidence: 0.99)
        let unsure = ConversationLog.Line(time: t.addingTimeInterval(1), speaker: nil, text: "あやしい", confidence: 0.1)
        let rewritten = ConversationLog.Line(time: t.addingTimeInterval(130), speaker: nil, text: "前の文", confidence: 0.99)
        let a = NightItem(day: "2026-11-07", audio: "a.m4a", lines: [sure, unsure], texts: ["そのまま", "あやしい"],
                          confidence: [0.99, 0.1], heard: ["", ""], words: [], work: false, seconds: 120)
        let b = NightItem(day: "2026-11-07", audio: "b.m4a", lines: [rewritten], texts: ["PC で書き直した文"],
                          confidence: [0.8], heard: [""], words: [], work: false, seconds: 120)
        let picks = NightBudget.picks([a, b])
        XCTAssertEqual(picks.map(\.item), [0, 1])
        XCTAssertEqual(picks.map(\.line), [1, 0])
    }

    // MARK: - 3. マイクの選び方

    private let builtIn = MicChoice.Port(type: .builtInMic, uid: "built", name: "iPhone マイク")
    private let usb = MicChoice.Port(type: .usbAudio, uid: "usb", name: "DJI Mic Mini 2")
    private let btMic = MicChoice.Port(type: .bluetoothHFP, uid: "bt", name: "DJI MIC MINI-1234")
    private let airpods = MicChoice.Port(type: .bluetoothHFP, uid: "pods", name: "小野の AirPods Pro")
    private let headset = MicChoice.Port(type: .headsetMic, uid: "wired", name: "ヘッドセットマイク")

    func testAutoPrefersUSBReceiver() {
        XCTAssertEqual(MicChoice.choose([builtIn, btMic, usb], mode: .auto, bluetooth: true), usb)
        XCTAssertEqual(MicChoice.choose([builtIn, usb], mode: .auto, bluetooth: false), usb)
        XCTAssertEqual(MicChoice.choose([builtIn, headset, btMic], mode: .auto, bluetooth: true), headset)
    }

    func testBluetoothOnlyWhenTurnedOn() {
        XCTAssertEqual(MicChoice.choose([builtIn, btMic], mode: .auto, bluetooth: true), btMic)
        // オフなら iOS に任せる（今までと同じ）
        XCTAssertNil(MicChoice.choose([builtIn, btMic], mode: .auto, bluetooth: false))
        // イヤホンはマイクに選ばず、iOS に任せるとイヤホンで録るので iPhone のマイクにする
        XCTAssertEqual(MicChoice.choose([builtIn, airpods], mode: .auto, bluetooth: true), builtIn)
        XCTAssertEqual(MicChoice.choose([builtIn, airpods, btMic], mode: .auto, bluetooth: true), btMic)
        XCTAssertTrue(MicChoice.looksLikeEarphones("ono's AirPods"))
        XCTAssertTrue(MicChoice.looksLikeEarphones("Galaxy Buds2"))
        XCTAssertFalse(MicChoice.looksLikeEarphones("RØDE Wireless Micro"))
    }

    func testUnpluggedFallsBackToSystemAndBuiltInOnlyMode() {
        // 外したら（外付けが無ければ）iOS に任せる＝iPhone のマイクに戻る
        XCTAssertNil(MicChoice.choose([builtIn], mode: .auto, bluetooth: false))
        // 「iPhone のマイクだけ」は、外付けがあっても iPhone のマイク
        XCTAssertEqual(MicChoice.choose([builtIn, usb, btMic], mode: .builtIn, bluetooth: true), builtIn)
    }

    func testCategoryOptions() {
        XCTAssertEqual(MicChoice.categoryOptions(mode: .builtIn, bluetooth: true), [.mixWithOthers])
        XCTAssertEqual(MicChoice.categoryOptions(mode: .auto, bluetooth: false), [.mixWithOthers])
        let bt = MicChoice.categoryOptions(mode: .auto, bluetooth: true)
        XCTAssertTrue(bt.contains(.mixWithOthers))
        XCTAssertTrue(bt.contains(.allowBluetoothA2DP))
    }

    // MARK: - 3. 作り物の2チャンネルの音

    private static let inputRate = 48_000.0

    /// 左右の大きさを決めた2チャンネルの音（440Hz の音。左右は同じ形で大きさだけ違う）
    private func stereoBuffer(left: Float, right: Float, frames: Int = 4_800, interleaved: Bool = false,
                              phase: inout Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.inputRate, channels: 2,
                                   interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        for i in 0..<frames {
            let s = Float(sin(2 * Double.pi * 440 * Double(phase + i) / Self.inputRate))
            if interleaved {
                data[0][i * 2] = s * left
                data[0][i * 2 + 1] = s * right
            } else {
                data[0][i] = s * left
                data[1][i] = s * right
            }
        }
        phase += frames
        return buffer
    }

    func testStereoSplitAveragesAndMeasuresBothSides() throws {
        for interleaved in [false, true] {
            var phase = 0
            let buffer = stereoBuffer(left: 0.4, right: 0.04, interleaved: interleaved, phase: &phase)
            let split = try XCTUnwrap(StereoSplit.split(buffer))
            XCTAssertEqual(split.mono.format.channelCount, 1)
            XCTAssertEqual(split.mono.frameLength, buffer.frameLength)
            // 平均の2乗（正弦波は振幅の2乗の半分）
            XCTAssertEqual(split.left, 0.08, accuracy: 0.002)
            XCTAssertEqual(split.right, 0.0008, accuracy: 0.0001)
            // 1チャンネルは左右の平均
            let mono = split.mono.floatChannelData![0]
            let s = Float(sin(2 * Double.pi * 440 * 100 / Self.inputRate))
            XCTAssertEqual(mono[100], s * 0.22, accuracy: 0.0005)
            // 左右の差は 20dB
            XCTAssertEqual(ChannelTrack.db(split.left) - ChannelTrack.db(split.right), 20, accuracy: 0.2)
        }
    }

    func testStereoSplitIgnoresMono() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.inputRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100
        XCTAssertNil(StereoSplit.split(buffer))
    }

    /// ChunkWriter に作り物の2チャンネルの音を流す: 前半は自分（左が大きい）、後半は相手（右が大きい）
    func testChunkWriterKeepsBothSidesAndWritesMono() throws {
        let onKey = StereoMic.onKey, swapKey = StereoMic.swapKey
        let savedOn = UserDefaults.standard.object(forKey: onKey), savedSwap = UserDefaults.standard.object(forKey: swapKey)
        defer {
            UserDefaults.standard.set(savedOn, forKey: onKey)
            UserDefaults.standard.set(savedSwap, forKey: swapKey)
        }
        UserDefaults.standard.set(true, forKey: onKey)
        UserDefaults.standard.set(false, forKey: swapKey)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v9-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("20261107-065825-v9test-\(UUID().uuidString.prefix(8)).m4a")
        defer { try? FileManager.default.removeItem(at: ChannelStore.url(for: url.lastPathComponent)) }

        let writer = ChunkWriter { _ in dir.appendingPathComponent(UUID().uuidString + ".m4a") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.inputRate, channels: 2, interleaved: false)!
        writer.prepare(from: format)
        try writer.open(url)
        var phase = 0
        // 0.1秒ずつ、3秒（自分 1.5秒 → 相手 1.5秒）
        for block in 0..<30 {
            let me = block < 15
            writer.receive(stereoBuffer(left: me ? 0.4 : 0.03, right: me ? 0.03 : 0.4, phase: &phase))
        }
        let done = try XCTUnwrap(writer.close())
        XCTAssertEqual(done.url, url)

        // 左右の大きさが残っている（録ったときの設定「左＝自分」も）
        let track = try XCTUnwrap(ChannelStore.load(url.lastPathComponent))
        XCTAssertEqual(track.selfChannel, .left)
        XCTAssertGreaterThan(track.times.count, 20)
        let first = try XCTUnwrap(track.levels(from: 0.1, to: 1.3))
        let second = try XCTUnwrap(track.levels(from: 1.7, to: 2.9))
        XCTAssertGreaterThan(first.left - first.right, 15)
        XCTAssertGreaterThan(second.right - second.left, 15)
        XCTAssertEqual(ChannelHint.side(track, from: 0.1, to: 1.3), .me)
        XCTAssertEqual(ChannelHint.side(track, from: 1.7, to: 2.9), .other)

        // ファイルは今までどおり 16kHz・1チャンネル。右（相手）の声も入っている（前は左しか書いていなかった）
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let length = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(length, 3, accuracy: 0.3)
        let read = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: read)
        let samples = read.floatChannelData![0]
        func rms(_ from: Double, _ to: Double) -> Float {
            let a = Int(from * 16_000), b = min(Int(to * 16_000), Int(read.frameLength))
            guard b > a else { return 0 }
            var sum: Float = 0
            for i in a..<b { sum += samples[i] * samples[i] }
            return (sum / Float(b - a)).squareRoot()
        }
        // 左右の平均なので、どちらの半分も（0.4+0.03）/2 の音の大きさくらい。左だけなら後半は 0.02 ほどになる
        XCTAssertGreaterThan(rms(0.3, 1.2), 0.08)
        XCTAssertGreaterThan(rms(1.8, 2.7), 0.08)
    }

    // MARK: - 3. 左右の大きさの手がかり（差の目安）

    func testSideMarginFromSimulatedLavMics() {
        // 胸元のマイク: 付けた人の声は、もう1つのマイクに 18dB 小さく入る
        let voice: Float = -20
        XCTAssertEqual(ChannelHint.side(left: voice, right: voice - 18, selfChannel: .left), .me)
        XCTAssertEqual(ChannelHint.side(left: voice - 18, right: voice, selfChannel: .left), .other)
        // 離れて付けた2人の、少し近いほうに寄った声（8dB の差）も分ける
        XCTAssertEqual(ChannelHint.side(left: voice, right: voice - 8, selfChannel: .left), .me)
        // 2人から同じくらい離れた声（テレビ・周りの人）は 2〜4dB の差 → どちらとも言わない
        XCTAssertNil(ChannelHint.side(left: -35, right: -37, selfChannel: .left))
        XCTAssertNil(ChannelHint.side(left: -35, right: -31, selfChannel: .left))
        // 5dB はまだ分けない、6dB で分ける（目安の境目）
        XCTAssertNil(ChannelHint.side(left: -30, right: -35, selfChannel: .left))
        XCTAssertEqual(ChannelHint.side(left: -30, right: -36, selfChannel: .left), .me)
        // 静かな所は見ない
        XCTAssertNil(ChannelHint.side(left: -60, right: -90, selfChannel: .left))
        // 左右を入れ替えた（右＝自分）
        XCTAssertEqual(ChannelHint.side(left: voice, right: voice - 18, selfChannel: .right), .other)
    }

    func testTrackLevelsAveragePower() {
        let track = ChannelTrack(selfChannel: .left, times: [0, 0.1], left: [-10, -40], right: [-40, -10])
        let both = try? XCTUnwrap(track.levels(from: 0, to: 0.2))
        // 強さの平均なので、大きいほうに寄る（-10dB と -40dB の平均は約 -13dB）
        XCTAssertEqual(both?.left ?? 0, -13, accuracy: 0.1)
        XCTAssertEqual(both?.right ?? 0, -13, accuracy: 0.1)
        XCTAssertNil(track.levels(from: 5, to: 6))
        XCTAssertEqual(ChannelTrack.db(0), -100)
    }

    func testTrackRoundTripsThroughStore() throws {
        let name = "v9-store-\(UUID().uuidString).m4a"
        defer { try? FileManager.default.removeItem(at: ChannelStore.url(for: name)) }
        var track = ChannelTrack(selfChannel: .right)
        track.add(at: 0, leftPower: 0.01, rightPower: 0.1)
        track.add(at: 0.085, leftPower: 0.02, rightPower: 0.2)
        ChannelStore.save(track, for: name)
        XCTAssertEqual(ChannelStore.load(name), track)
        // 空なら置かない
        ChannelStore.save(ChannelTrack(selfChannel: .left), for: name + "-empty")
        XCTAssertNil(ChannelStore.load(name + "-empty"))
    }

    func testHintAddsToSpeakerLabels() {
        let me = SpeakerLabeler.selfID
        func seg(_ id: String, _ name: String, _ i: Int) -> SpeakerLabeler.Segment {
            SpeakerLabeler.Segment(start: Double(i), end: Double(i) + 1, personID: id, name: name)
        }
        // 行ごとの左右の大きさ: 0 自分・1 相手・2 相手・3 音なし・4 自分・5 どちらとも言えない
        let track = ChannelTrack(selfChannel: .left, times: [0, 1, 2, 4, 5],
                                 left: [-20, -40, -40, -20, -30], right: [-40, -20, -20, -40, -32])
        let names: [SpeakerLabeler.Segment?] = [seg(me, "自分", 0), seg(me, "自分", 1), seg("3", "人物3", 2), nil,
                                                seg("3", "人物3", 4), seg("3", "人物3", 5)]
        let spans = (0..<6).map { (start: Double($0), end: Double($0) + 1) }
        let result = ChannelHint.apply(names, spans: spans, track: track)
        XCTAssertEqual(result.names.map { $0?.personID }, [me, "3", "3", nil, me, "3"])
        XCTAssertEqual(result.names[4]?.name, SpeakerLabeler.selfName)
        XCTAssertEqual(result.names[1]?.name, "人物3")
        XCTAssertEqual(result.me, 1)
        XCTAssertEqual(result.other, 1)
    }

    func testHintWithoutPartnerLeavesNoSpeakerAndNeedsSetting() {
        let me = SpeakerLabeler.selfID
        let names: [SpeakerLabeler.Segment?] = [SpeakerLabeler.Segment(start: 0, end: 1, personID: me, name: "自分")]
        let spans = [(start: 0.0, end: 1.0)]
        // 相手のほうが大きいのに「自分」だった行は、ほかの人がいなければ話し手なし（新しい人は作らない）
        let on = ChannelTrack(selfChannel: .left, times: [0], left: [-40], right: [-20])
        XCTAssertNil(ChannelHint.apply(names, spans: spans, track: on).names[0])
        // 設定がオフで録ったもの（selfChannel が nil）は、手がかりに使わない
        let off = ChannelTrack(selfChannel: nil, times: [0], left: [-40], right: [-20])
        XCTAssertEqual(ChannelHint.apply(names, spans: spans, track: off).names[0]?.personID, me)
    }
}

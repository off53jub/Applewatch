import XCTest
@testable import LifeLog

/// 文字になるまでを短くする（版 8。docs/v8-latency.md）の iPhone 側を確かめる（2026-11-07）。
/// 区切りの短さ・区間ごとの時間・PC の答え（待ち合わせ・下書き）の読み方・回数の上限・仮の出し方。
@MainActor
final class LatencyTests: XCTestCase {
    /// 2026-11-07T06:58:25.123Z
    private let t = Date(timeIntervalSince1970: 1_794_034_705.123)

    // MARK: - 区切りの長さ（4）

    private static let rate = 16_000.0
    private static let blockSize = 1_600

    /// 0.1秒ごとに大きさを決めて流し、切れた時刻（秒）を返す。切れなければ nil
    private func cutTime(_ cutter: inout ChunkCutter, upTo seconds: Double, amplitude: (Int) -> Float) -> Double? {
        var samples = [Float](repeating: 0, count: Self.blockSize)
        for block in 0..<Int(seconds * 10) {
            let a = amplitude(block)
            for i in samples.indices { samples[i] = i % 2 == 0 ? a : -a }
            let cut = samples.withUnsafeBufferPointer { cutter.feed($0.baseAddress!, count: Self.blockSize, rate: Self.rate) }
            if cut { return Double(block + 1) / 10 }
        }
        return nil
    }

    /// 話している音（1秒のうち 0.6秒は声・0.4秒は静か。静かな所が短いので、上限より前には切れない）
    private func talking(_ block: Int) -> Float { block % 10 < 6 ? 0.3 : 0.001 }

    func testShortCutsAtPauseAfter45Seconds() throws {
        var cutter = ChunkCutter(length: .short)
        // 60秒まで話して、そのあと静か → 0.5秒静かになった所で切る
        let at = try XCTUnwrap(cutTime(&cutter, upTo: 200) { $0 < 600 ? self.talking($0) : 0.001 })
        XCTAssertGreaterThanOrEqual(at, 59.9)
        XCTAssertLessThanOrEqual(at, 60.6)
    }

    func testShortDoesNotCutBefore45Seconds() throws {
        var cutter = ChunkCutter(length: .short)
        // 30秒のところで2秒静かでも、45秒より前には切らない
        let at = try XCTUnwrap(cutTime(&cutter, upTo: 200) { ($0 >= 300 && $0 < 320) ? 0.001 : self.talking($0) })
        XCTAssertGreaterThan(at, 45)
    }

    func testShortCutsByTwoMinutes() throws {
        var cutter = ChunkCutter(length: .short)
        // ずっと話している（短い静けさしか無い）→ 120秒を過ぎた最初の 0.2秒の静けさで切る
        let at = try XCTUnwrap(cutTime(&cutter, upTo: 300, amplitude: talking))
        XCTAssertGreaterThanOrEqual(at, 119.9)
        XCTAssertLessThanOrEqual(at, 121.1)
    }

    func testShortCutsAtMaxExtraWhenNeverQuiet() throws {
        var cutter = ChunkCutter(length: .short)
        // 100秒からは静かな所が無い → 120秒＋20秒で切る
        let at = try XCTUnwrap(cutTime(&cutter, upTo: 300) { $0 < 1_000 ? self.talking($0) : 0.3 })
        XCTAssertEqual(at, ChunkCutter.Length.short.maximum + ChunkCutter.maxExtra, accuracy: 0.25)
    }

    func testNormalKeepsFiveMinutes() throws {
        var cutter = ChunkCutter(length: .normal)
        // 今までどおり、5分たってからの静かな所で切る（60秒の静けさでは切らない）
        let at = try XCTUnwrap(cutTime(&cutter, upTo: 400) { ($0 >= 600 && $0 < 620) ? 0.001 : self.talking($0) })
        XCTAssertGreaterThanOrEqual(at, 299.9)
        XCTAssertLessThanOrEqual(at, 301.1)
    }

    func testResetUsesGivenLength() {
        var cutter = ChunkCutter(length: .normal)
        cutter.reset(length: .short)
        XCTAssertEqual(cutter.length, .short)
        XCTAssertEqual(cutter.seconds, 0)
    }

    func testScaledCountsKeepTheSameTime() {
        // 5分の区切りで3つ（15分）は、短め（目安75秒）なら 12 個
        XCTAssertEqual(ChunkCutter.scaled(3, length: .normal), 3)
        XCTAssertEqual(ChunkCutter.scaled(3, length: .short), 12)
        XCTAssertEqual(ChunkCutter.scaled(2, length: .short), 8)
        XCTAssertEqual(ChunkCutter.scaled(6, length: .short), 24)
        XCTAssertEqual(ChunkCutter.scaled(0, length: .short), 0)
    }

    // MARK: - 区間ごとの時間（1）

    private func marks(watch: Bool) -> Latency.Marks {
        Latency.Marks(watch: watch, chunkStart: t.addingTimeInterval(-90), chunkEnd: t,
                      arrived: t.addingTimeInterval(watch ? 40 : 0), sent: t.addingTimeInterval(watch ? 41 : 1),
                      received: t.addingTimeInterval(watch ? 43 : 3), started: t.addingTimeInterval(watch ? 44 : 4),
                      draftAt: nil, finished: t.addingTimeInterval(watch ? 70 : 30))
    }

    private func close(_ value: Double?, _ expected: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let value else { return XCTFail("値がありません", file: file, line: line) }
        XCTAssertEqual(value, expected, accuracy: 0.001, file: file, line: line)
    }

    func testSampleFromWatchChunk() {
        let s = Latency.sample(marks(watch: true), applied: t.addingTimeInterval(76))
        close(s.toPhone, 40)
        close(s.toPC, 3)
        close(s.pcWait, 1)
        close(s.pcWork, 26)
        close(s.toRecord, 6)
        close(s.total, 76)
    }

    func testSampleFromPhoneChunkHasNoWatchPart() {
        let s = Latency.sample(marks(watch: false), applied: t.addingTimeInterval(36))
        XCTAssertNil(s.toPhone)
        close(s.toPC, 3)
        close(s.total, 36)
    }

    func testSampleWithoutPC() {
        var m = marks(watch: false)
        m.sent = nil
        m.received = nil
        m.started = nil
        m.finished = nil
        let s = Latency.sample(m, applied: t.addingTimeInterval(20))
        XCTAssertNil(s.toPC)
        XCTAssertNil(s.pcWork)
        XCTAssertNil(s.toRecord)
        close(s.total, 20)
    }

    func testClockSkew() {
        // 少しの逆さ（PC の時計が2秒遅れ）は 0、大きく逆さ（2分）は分からないことにする
        XCTAssertEqual(Latency.span(t, t.addingTimeInterval(-2)), 0)
        XCTAssertNil(Latency.span(t, t.addingTimeInterval(-120)))
        XCTAssertNil(Latency.span(nil, t))
    }

    func testMedianAndSummary() throws {
        XCTAssertEqual(Latency.median([10, 30, 20]), 20)
        XCTAssertEqual(Latency.median([10, 20, 30, 40]), 25)
        XCTAssertNil(Latency.median([]))
        let samples = [
            Latency.Sample(at: t.addingTimeInterval(-60), toPhone: 40, toPC: 3, pcWait: 1, pcWork: 25, toRecord: 6, total: 80),
            Latency.Sample(at: t.addingTimeInterval(-120), toPhone: nil, toPC: 2, pcWait: 0, pcWork: 20, toRecord: 4, total: 30),
            Latency.Sample(at: t.addingTimeInterval(-180), toPhone: 50, toPC: nil, pcWait: nil, pcWork: nil, toRecord: nil, total: 100),
            // 24時間より前は数えない
            Latency.Sample(at: t.addingTimeInterval(-90_000), toPhone: 999, toPC: 999, pcWait: 999, pcWork: 999, toRecord: 999, total: 999),
        ]
        let s = try XCTUnwrap(Latency.summarize(samples, now: t))
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.total, 80)
        XCTAssertEqual(s.toPhone, 45)
        XCTAssertEqual(s.pcWork, 22.5)
        let json = s.json
        XCTAssertEqual(json["count"] as? Int, 3)
        XCTAssertEqual(json["total"] as? Double, 80)
        XCTAssertEqual(json["pcWork"] as? Double, 22.5)
        XCTAssertNil(Latency.summarize([], now: t))
    }

    func testSummaryLeavesOutUnknownParts() throws {
        let s = try XCTUnwrap(Latency.summarize([Latency.Sample(at: t, total: 12.34)], now: t))
        let json = s.json
        XCTAssertEqual(json["total"] as? Double, 12.3)
        XCTAssertNil(json["toPC"])
        XCTAssertNil(json["toPhone"])
        // 家の PC に送れる形（JSON にできる）
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    func testStoreFromChunkToRecord() throws {
        Latency.reset()
        let name = "20261107-155755-w.m4a"
        let start = Date.now.addingTimeInterval(-200)
        let end = start.addingTimeInterval(100)
        Latency.noteChunk(name, start: start, end: end, arrived: end.addingTimeInterval(30), watch: true)
        Latency.noteSent(name, at: end.addingTimeInterval(31))
        XCTAssertEqual(Latency.awaiting(), [name])
        Latency.notePC(name, timing: PCTiming(received: end.addingTimeInterval(33), started: end.addingTimeInterval(34),
                                              finished: end.addingTimeInterval(50)))
        // でき上がったら、下書きを見に行く相手から外れる
        XCTAssertEqual(Latency.awaiting(), [])
        Latency.noteApplied(name, at: end.addingTimeInterval(55))
        // 2回目は数えない
        Latency.noteApplied(name, at: end.addingTimeInterval(90))
        XCTAssertNil(Latency.marks(name))
        let s = try XCTUnwrap(Latency.summary())
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(try XCTUnwrap(s.toPhone), 30, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.pcWork), 16, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.total), 55, accuracy: 0.01)
        Latency.reset()
    }

    func testJobQueryHasTimes() {
        let m = Latency.Marks(watch: true, chunkStart: t.addingTimeInterval(-60), chunkEnd: t, arrived: t.addingTimeInterval(1))
        let items = HomePC.timeItems(m, sent: t.addingTimeInterval(2))
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["chunk_start"], "2026-11-07T06:57:25.123Z")
        XCTAssertEqual(values["chunk_end"], "2026-11-07T06:58:25.123Z")
        XCTAssertEqual(values["arrived"], "2026-11-07T06:58:26.123Z")
        XCTAssertEqual(values["sent"], "2026-11-07T06:58:27.123Z")
        // 分からない時刻は送らない
        XCTAssertEqual(HomePC.timeItems(nil, sent: t).map(\.name), ["sent"])
    }

    // MARK: - PC の答え（2・5）

    func testTimingReadsStringsAndNumbers() throws {
        let json = #"{"chunk_end":"2026-11-07T06:58:25.123Z","received":1794034706.5,"started":"2026-11-07T15:58:27+09:00","draft_at":null}"#
        let timing = try JSONDecoder().decode(PCTiming.self, from: Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(timing.chunkEnd).timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timing.received).timeIntervalSince1970, 1_794_034_706.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timing.started).timeIntervalSince1970, 1_794_034_707, accuracy: 0.001)
        XCTAssertNil(timing.draftAt)
        XCTAssertNil(timing.finished)
    }

    func testWaitReplyWithLeadingSpaces() throws {
        // PC は待たせているあいだ15秒ごとに空白を書き、でき上がったら答えを書いて閉じる
        let json = "     \n " + #"{"status":"done","result":{"lines":[{"start":0.5,"end":2.0,"text":"テスト"}],"seconds":1.2},"timing":{"finished":"2026-11-07T06:58:25.123Z"}}"# + "\n"
        let data = Data(json.utf8)
        XCTAssertTrue(PCResults.isDone(data))
        let reply = try XCTUnwrap(JobReply.decode(data))
        XCTAssertEqual(reply.status, "done")
        XCTAssertEqual(reply.result?.lines.first?.text, "テスト")
        XCTAssertNotNil(reply.timing?.finished)
        XCTAssertEqual(PCResults.trimmed(data).first, UInt8(ascii: "{"))
        XCTAssertEqual(PCResults.trimmed(data).last, UInt8(ascii: "}"))
        XCTAssertEqual(PCResults.trimmed(Data("   ".utf8)), Data())
    }

    func testPendingAndDraftRepliesAreNotDone() throws {
        XCTAssertFalse(PCResults.isDone(Data(#"{"status":"pending"}"#.utf8)))
        XCTAssertFalse(PCResults.isDone(Data("    ".utf8)))
        let draft = #"{"status":"working","draft":{"lines":[{"start":1,"end":3,"text":"したがき","confidence":null}],"seconds":0.4},"timing":{}}"#
        let data = Data(draft.utf8)
        XCTAssertFalse(PCResults.isDone(data))
        let reply = try XCTUnwrap(JobReply.decode(data))
        XCTAssertEqual(reply.draft?.lines.map(\.text), ["したがき"])
        XCTAssertNil(reply.result)
    }

    func testResultsPlaceSavesAndRemoves() {
        let name = "test-\(UUID().uuidString).m4a"
        XCTAssertFalse(PCResults.has(name))
        PCResults.save(Data("  {\"status\":\"done\"}".utf8), name: name)
        XCTAssertTrue(PCResults.has(name))
        XCTAssertEqual(PCResults.load(name), Data("{\"status\":\"done\"}".utf8))
        XCTAssertTrue(PCResults.url(name).lastPathComponent.hasSuffix(".m4a.json"))
        PCResults.remove(name)
        XCTAssertFalse(PCResults.has(name))
    }

    // MARK: - 回数の上限（4）

    func testBudgetOnlyForShortChunks() {
        XCTAssertNil(ChunkBudget.perHour(.cloud, length: .normal))
        XCTAssertNil(ChunkBudget.perHour(.correct, length: .normal))
        XCTAssertEqual(ChunkBudget.perHour(.cloud, length: .short), 30)
        XCTAssertTrue(ChunkBudget.allowed(recentCount: 29, limit: 30))
        XCTAssertFalse(ChunkBudget.allowed(recentCount: 30, limit: 30))
        XCTAssertTrue(ChunkBudget.allowed(recentCount: 500, limit: nil))
    }

    // MARK: - 仮（5）

    private func pcLine(_ offset: Double, _ text: String) -> HomePC.Line {
        HomePC.Line(offset: offset, end: offset + 1, text: text, confidence: nil, alternatives: [], votes: [:])
    }

    func testDraftsSetReplaceAndRemove() {
        let drafts = JobDrafts()
        let start = t
        XCTAssertTrue(drafts.set("b.m4a", start: start.addingTimeInterval(60), lines: [pcLine(0, "あと")]))
        XCTAssertTrue(drafts.set("a.m4a", start: start, lines: [pcLine(2, "さき"), pcLine(3, "  ")]))
        // 録音の古い順・空の行は出さない
        XCTAssertEqual(drafts.items.map(\.name), ["a.m4a", "b.m4a"])
        XCTAssertEqual(drafts.items.first?.lines, [JobDrafts.Line(time: start.addingTimeInterval(2), text: "さき")])
        // 同じ中身なら変わらない
        XCTAssertFalse(drafts.set("a.m4a", start: start, lines: [pcLine(2, "さき")]))
        XCTAssertTrue(drafts.set("a.m4a", start: start, lines: [pcLine(2, "さきに")]))
        // 空の下書きは入れない
        XCTAssertFalse(drafts.set("c.m4a", start: start, lines: []))
        XCTAssertTrue(drafts.remove("a.m4a"))
        XCTAssertFalse(drafts.remove("a.m4a"))
        XCTAssertEqual(drafts.items.map(\.name), ["b.m4a"])
        // 30分より前の仮は消す
        XCTAssertTrue(drafts.prune(now: .now.addingTimeInterval(JobDrafts.keepFor + 1)))
        XCTAssertTrue(drafts.items.isEmpty)
    }

    func testWatchInfoDraftIsOptionalAndDroppedFirst() throws {
        var info = WatchInfo(made: t.timeIntervalSince1970, status: WatchInfo.Status(pending: 0, processed: nil))
        // 仮が無ければ、送る JSON に項目は出ない（古い時計のアプリも困らない）
        let plain = try XCTUnwrap(WatchInfo.encode(info))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("draft"))
        info.draft = WatchInfo.Draft(start: t.timeIntervalSince1970, lines: ["したがき"])
        let data = try XCTUnwrap(WatchInfo.encode(info))
        XCTAssertEqual(try JSONDecoder().decode(WatchInfo.self, from: data).draft, info.draft)
        // 大きすぎるときは、仮から外す
        info.morning = WatchInfo.Brief(day: "2026-11-07", text: "あ")
        let capped = try XCTUnwrap(WatchInfo.capped(info, limit: plain.count + 80))
        let decoded = try JSONDecoder().decode(WatchInfo.self, from: capped)
        XCTAssertNil(decoded.draft)
        XCTAssertEqual(decoded.morning?.text, "あ")
    }

    // MARK: - もう1台のマイク（区切りが短いと候補がいくつもある）

    func testOtherMicCandidatesAreSortedByCloseness() {
        let dir = URL(fileURLWithPath: "/tmp")
        let phone = dir.appendingPathComponent("20261106-103200.m4a")
        let start = Storage.startDate(of: phone)!
        let kept = [dir.appendingPathComponent("20261106-103050-w.m4a"),
                    dir.appendingPathComponent("20261106-103210-w.m4a"),
                    dir.appendingPathComponent("20261106-103300-w.m4a"),
                    dir.appendingPathComponent("20261106-110000-w.m4a")]
        let names = AudioClip.otherMicCandidates(for: phone, start: start, fromWatch: false, in: kept).map(\.lastPathComponent)
        XCTAssertEqual(names, ["20261106-103210-w.m4a", "20261106-103300-w.m4a", "20261106-103050-w.m4a"])
        XCTAssertEqual(AudioClip.otherMic(for: phone, start: start, fromWatch: false, in: kept)?.lastPathComponent,
                       "20261106-103210-w.m4a")
    }
}

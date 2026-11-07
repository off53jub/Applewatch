import XCTest
@testable import LifeLog

/// 時計の区切りを、音声が届く前に家の PC の答えから記録に入れる（版 10。docs/v10-pc-first.md）の、
/// 選び方・名前の時刻・音声があとから届いたときの扱い・帳簿の終わり・文字になるまでの数え方を確かめる（2026-11-07）。
@MainActor
final class PCFirstTests: XCTestCase {
    /// 2026-11-07 13:54:44（この端末の時間帯。秒より細かい所は名前に入らないので付けない）
    private var base: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 7; c.hour = 13; c.minute = 54; c.second = 44
        return Calendar.current.date(from: c)!
    }

    /// 時計の区切りの、iPhone での名前（例 20261107-135444-w.m4a）
    private func watchName(_ date: Date) -> String {
        Storage.watchChunkName(from: Storage.chunkName(for: date))
    }

    private func job(_ name: String, _ status: String = "done", origin: String? = "watch") -> PCFirst.Job {
        PCFirst.Job(id: name, status: status, queued_at: nil, done_at: nil, origin: origin)
    }

    // MARK: - 名前の時刻

    func testStartDateFromWatchName() throws {
        let name = watchName(base)
        XCTAssertEqual(name, "20261107-135444-w.m4a")
        let start = try XCTUnwrap(PCFirst.startDate(name))
        XCTAssertEqual(start.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.5)
    }

    func testStartDateRejectsOtherNames() {
        // iPhone で録った区切り・取り込んだ区切り・違う形・読めない名前は、時計の区切りではない
        XCTAssertNil(PCFirst.startDate("20261107-135444.m4a"))
        XCTAssertNil(PCFirst.startDate("20261107-135444-i.m4a"))
        XCTAssertNil(PCFirst.startDate("20261107-135444-w.wav"))
        XCTAssertNil(PCFirst.startDate("abc-w.m4a"))
        XCTAssertNil(PCFirst.startDate("pending/20261107-135444-w.m4a"))
    }

    // MARK: - 一覧から選ぶ

    func testJobsDecodeListing() throws {
        let json = """
        {"jobs": [{"id": "20261107-140000-w.m4a", "status": "done", "queued_at": 1794034705.1, "done_at": 1794034720.5, "origin": "watch"},
                  {"id": "20261107-135500-w.m4a", "status": "working", "queued_at": 1794034700, "done_at": null, "origin": "watch"}]}
        """
        let jobs = try XCTUnwrap(PCFirst.jobs(from: Data(json.utf8)))
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[0].id, "20261107-140000-w.m4a")
        XCTAssertEqual(jobs[0].status, "done")
        XCTAssertEqual(jobs[0].origin, "watch")
        XCTAssertNil(jobs[1].done_at)
        // 頭の空白があっても読める・読めないものは nil
        XCTAssertEqual(PCFirst.jobs(from: Data(("  \n" + json).utf8))?.count, 2)
        XCTAssertNil(PCFirst.jobs(from: Data("{\"error\": \"x\"}".utf8)))
    }

    func testPickChoosesDoneAndNotYetTranscribedOldestFirst() {
        let now = base.addingTimeInterval(3600)
        let a = watchName(base)
        let b = watchName(base.addingTimeInterval(300))
        let c = watchName(base.addingTimeInterval(600))
        // PC の一覧は新しい順
        let jobs = [job(c), job(b), job(a)]
        XCTAssertEqual(PCFirst.pick(jobs, transcribed: [], present: [], waiting: [], now: now), [a, b, c])
    }

    func testPickSkipsWhatIsAlreadyHandled() {
        let now = base.addingTimeInterval(3600)
        let done = watchName(base)
        let transcribed = watchName(base.addingTimeInterval(300))
        let audioHere = watchName(base.addingTimeInterval(600))
        let waitingAudio = watchName(base.addingTimeInterval(900))
        let working = watchName(base.addingTimeInterval(1200))
        let failed = watchName(base.addingTimeInterval(1500))
        let phone = Storage.chunkName(for: base.addingTimeInterval(1800))
        let fromPhone = watchName(base.addingTimeInterval(2100))
        let jobs = [
            job(done), job(transcribed), job(audioHere), job(waitingAudio),
            job(working, "working"), job(failed, "failed"),
            // iPhone で録った区切り（時計の名前でない）と、iPhone から送った仕事は選ばない
            job(phone), job(fromPhone, origin: "phone"),
            // 同じ名前が2つあっても1つだけ
            job(done),
        ]
        let picked = PCFirst.pick(jobs, transcribed: [transcribed], present: [audioHere], waiting: [waitingAudio], now: now)
        XCTAssertEqual(picked, [done])
    }

    func testPickSkipsTooOldAndFutureAndKeepsLimit() {
        let now = base.addingTimeInterval(3 * 86400)
        let old = watchName(base)  // 3日前（2日より古い）
        let recent = watchName(now.addingTimeInterval(-600))
        let future = watchName(now.addingTimeInterval(3600))  // 時計の時刻が大きくずれている
        XCTAssertEqual(PCFirst.pick([job(future), job(recent), job(old)], transcribed: [], present: [], waiting: [], now: now),
                       [recent])
        // 1回に入れる数の上限（古いほうから）
        let many = (0..<5).map { watchName(now.addingTimeInterval(Double(-3000 + $0 * 300))) }
        XCTAssertEqual(PCFirst.pick(many.reversed().map { job($0) }, transcribed: [], present: [], waiting: [], now: now, limit: 2),
                       Array(many.prefix(2)))
        XCTAssertEqual(PCFirst.pick(many.map { job($0) }, transcribed: [], present: [], waiting: [], now: now, limit: 0), [])
    }

    // MARK: - 音声があとから届いたとき（二重にしない）

    func testArrivalDedupe() {
        // まだ文字にしていない → 今までどおり
        XCTAssertEqual(PCFirst.arrival(transcribed: false, pcFirst: false), .normal)
        // PC から先に入れた → 文字にし直さず、音声だけ残す
        XCTAssertEqual(PCFirst.arrival(transcribed: true, pcFirst: true), .keepAudio)
        // 音声から文字にした区切りが送り直されてきた → 今までどおり捨てる
        XCTAssertEqual(PCFirst.arrival(transcribed: true, pcFirst: false), .drop)
    }

    // MARK: - 帳簿の終わり

    func testLedgerEndFromTiming() {
        let start = base
        // PC が返した終わり（録音の始まりのあと30分以内）を使う
        XCTAssertEqual(RecordingLedger.pcFirstEnd(start: start, timingEnd: start.addingTimeInterval(287)),
                       start.addingTimeInterval(287))
        // 無い・始まりより前・長すぎるときは、始まりの5分後
        XCTAssertEqual(RecordingLedger.pcFirstEnd(start: start, timingEnd: nil), start.addingTimeInterval(300))
        XCTAssertEqual(RecordingLedger.pcFirstEnd(start: start, timingEnd: start.addingTimeInterval(-5)),
                       start.addingTimeInterval(300))
        XCTAssertEqual(RecordingLedger.pcFirstEnd(start: start, timingEnd: start.addingTimeInterval(7200)),
                       start.addingTimeInterval(300))
    }

    func testLedgerChunkWithPCFirstCountsAsRecorded() {
        // PC から先に入れた区切り（終わりが分かっている）は、抜けの地図で録れていた時間になる
        let start = base
        let spans = RecordingLedger.spans(from: start, to: start.addingTimeInterval(600),
                                          recorded: [(start, start.addingTimeInterval(300))], states: [])
        XCTAssertEqual(spans.first?.kind, .recorded)
        XCTAssertEqual(spans.first?.end, start.addingTimeInterval(300))
        // 帳簿の形は、前の形のファイルも読める（pcFirst は無ければ nil）
        let old = #"{"name":"a-w.m4a","start":0,"source":"watch"}"#
        let chunk = try? JSONDecoder().decode(RecordingLedger.Chunk.self, from: Data(old.utf8))
        XCTAssertNotNil(chunk)
        XCTAssertNil(chunk?.pcFirst)
    }

    // MARK: - 文字になるまでの数え方

    func testPCFirstSampleHasNoWatchToPhone() {
        let m = Latency.Marks(watch: true, chunkStart: base, chunkEnd: base.addingTimeInterval(300), arrived: nil,
                              received: base.addingTimeInterval(310), started: base.addingTimeInterval(311),
                              finished: base.addingTimeInterval(330), pcFirst: true)
        let s = Latency.sample(m, applied: base.addingTimeInterval(400))
        XCTAssertNil(s.toPhone)
        XCTAssertEqual(s.pcFirst, true)
        XCTAssertEqual(try XCTUnwrap(s.total), 100, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.pcWork), 19, accuracy: 0.01)
        // ふつうの区切りは今までどおり
        let normal = Latency.sample(Latency.Marks(watch: true, chunkEnd: base, arrived: base.addingTimeInterval(40)),
                                    applied: base.addingTimeInterval(60))
        XCTAssertEqual(normal.toPhone, 40)
        XCTAssertNil(normal.pcFirst)
    }

    func testPCFirstSamplesStayOutOfUsualMedians() throws {
        let now = base
        let samples = [
            Latency.Sample(at: now.addingTimeInterval(-60), toPhone: 40, total: 80),
            Latency.Sample(at: now.addingTimeInterval(-120), toPhone: 50, total: 100),
            // PC から先に入れた（ふつうの中央値に入れない）
            Latency.Sample(at: now.addingTimeInterval(-30), total: 20, pcFirst: true),
            Latency.Sample(at: now.addingTimeInterval(-40), total: 40, pcFirst: true),
            Latency.Sample(at: now.addingTimeInterval(-50), total: 60, pcFirst: true),
        ]
        let s = try XCTUnwrap(Latency.summarize(samples, now: now))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.total, 90)
        XCTAssertEqual(s.toPhone, 45)
        XCTAssertEqual(s.pcFirstCount, 3)
        XCTAssertEqual(s.pcFirstTotal, 40)
        XCTAssertEqual(s.json["pcFirstCount"] as? Int, 3)
        XCTAssertEqual(s.json["pcFirstTotal"] as? Double, 40)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(s.json))
        // PC から先に入れた区切りだけでも、まとめは出る（ふつうの数は 0）
        let only = try XCTUnwrap(Latency.summarize([Latency.Sample(at: now, total: 30, pcFirst: true)], now: now))
        XCTAssertEqual(only.count, 0)
        XCTAssertNil(only.total)
        XCTAssertEqual(only.pcFirstCount, 1)
        // 何も無ければ今までどおり nil
        XCTAssertNil(Latency.summarize([], now: now))
    }

    // MARK: - 見えない通知の中身

    func testPushJobName() {
        XCTAssertEqual(PushWake.job(from: ["lifelog": ["kind": "job", "job": "20261107-135444-w.m4a"]]), "20261107-135444-w.m4a")
        XCTAssertNil(PushWake.job(from: ["lifelog": ["kind": "job"]]))
        XCTAssertNil(PushWake.job(from: ["lifelog": ["kind": "job", "job": ""]]))
        XCTAssertNil(PushWake.job(from: [:]))
    }
}

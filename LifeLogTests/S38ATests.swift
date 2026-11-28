import XCTest
@testable import LifeLog

/// s38 の A2（S38ARules.swift）: 手7 動画からコマを選ぶ・手11 時計の版が古い 1 行・活2 開いた数・活3 朝の 1 通
final class S38ATests: XCTestCase {
    // MARK: 手7

    func testSampleTimesAreEvenAndBounded() {
        let times = S38AVideo.sampleTimes(duration: 10, cap: 30)
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times.count, 20)
        XCTAssertEqual(times[1], 0.5)
        // 長すぎる動画は前の 90 秒だけ・候補は cap の 4 倍まで
        let long = S38AVideo.sampleTimes(duration: 600, cap: 30)
        XCTAssertLessThanOrEqual(long.count, 120)
        XCTAssertLessThan(long.last ?? 0, S38AVideo.maxSeconds)
        XCTAssertTrue(S38AVideo.sampleTimes(duration: 0, cap: 30).isEmpty)
        XCTAssertTrue(S38AVideo.sampleTimes(duration: .nan, cap: 30).isEmpty)
        XCTAssertTrue(S38AVideo.sampleTimes(duration: 10, cap: 0).isEmpty)
    }

    func testSameFrameIsSkippedAndScrolledFrameIsKept() {
        let n = S38AVideo.side * S38AVideo.side
        let page = [UInt8](repeating: 255, count: n)
        XCTAssertTrue(S38AVideo.keep(previous: nil, current: page))
        XCTAssertFalse(S38AVideo.keep(previous: page, current: page))
        // 1 マスだけ少し違うだけなら同じ扱い
        var tiny = page
        tiny[0] = 200
        XCTAssertFalse(S38AVideo.keep(previous: page, current: tiny))
        // 全体の 1 割のマスが大きく変われば別のコマ
        var scrolled = page
        for i in 0..<(n / 10) { scrolled[i] = 0 }
        XCTAssertTrue(S38AVideo.keep(previous: page, current: scrolled))
        XCTAssertEqual(S38AVideo.changedFraction([1], [1, 2]), 1)
    }

    func testThinKeepsOrderAndEnds() {
        XCTAssertEqual(S38AVideo.thin([1, 2, 3], cap: 30), [1, 2, 3])
        let thinned = S38AVideo.thin(Array(0..<100), cap: 30)
        XCTAssertEqual(thinned.count, 30)
        XCTAssertEqual(thinned.first, 0)
        XCTAssertEqual(thinned.last, 99)
        XCTAssertEqual(thinned, thinned.sorted())
        XCTAssertEqual(S38AVideo.thin([5, 6, 7], cap: 1), [5])
        XCTAssertTrue(S38AVideo.thin([5, 6, 7], cap: 0).isEmpty)
    }

    func testVideoFramesFitThePhotoJobCap() {
        // 動画のコマは今の写真と同じ仕事（S35PhotoJob）に入れる: 30 枚まで・番号は順
        let jpegs: [Data] = (0..<40).map { _ in Data([0xFF, 0xD8, 0xFF, 0xD9]) }
        let job = S35PhotoJob(id: UUID().uuidString, day: "2026-11-28", photos: S38AVideo.thin(jpegs, cap: 30), cap: 30)
        XCTAssertEqual(job.count, 30)
        XCTAssertEqual(job.pieces.map(\.index), Array(0..<30))
        XCTAssertTrue(S38AVideo.summaryLine(frames: 0, skipped: 0).contains("取れません"))
        XCTAssertTrue(S38AVideo.summaryLine(frames: 12, skipped: 5).contains("5 コマは飛ばしました"))
    }

    // MARK: 手11

    func testWatchLagShowsAfterAnHourAndStaysQuiet() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(S25UWatchLag.after, 3600)
        XCTAssertTrue(S25UWatchLag.shouldShow(since: now.addingTimeInterval(-3700), now: now, watchSeen: true))
        XCTAssertFalse(S25UWatchLag.shouldShow(since: now.addingTimeInterval(-1800), now: now, watchSeen: true))
        XCTAssertFalse(S25UWatchLag.shouldShow(since: now.addingTimeInterval(-7200), now: now, watchSeen: false))
        let line = S25UWatchLag.line(phone: 460, watch: "455", hours: 3)
        XCTAssertTrue(line.contains("時計 455・iPhone 460"))
        XCTAssertTrue(line.contains("手順"))
    }

    // MARK: 活2

    func testAppOpenCountsOnlyRecentUntappedOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-300)
        XCTAssertTrue(S38AOpened.countsAsAppOpen(delivered: recent, now: now, alreadyTapped: false))
        XCTAssertFalse(S38AOpened.countsAsAppOpen(delivered: recent, now: now, alreadyTapped: true))
        XCTAssertFalse(S38AOpened.countsAsAppOpen(delivered: now.addingTimeInterval(-3600), now: now, alreadyTapped: false))
        XCTAssertFalse(S38AOpened.countsAsAppOpen(delivered: now.addingTimeInterval(60), now: now, alreadyTapped: false))
        let rows: [(id: String, date: Date, kind: String)] = [("a", recent, "tasks"), ("b", recent, "brief"),
                                                              ("old", now.addingTimeInterval(-9000), "tasks")]
        let tapped: Set<String> = [NoticeBundle.key(identifier: "b", date: recent)]
        let first = S38AOpened.fresh(delivered: rows, now: now, seen: [], tapped: tapped)
        XCTAssertEqual(first.map { $0.kind }, ["tasks"])
        // 数えた印を渡せば、アプリを開き直しても二重に数えない
        let again = S38AOpened.fresh(delivered: rows, now: now, seen: first.map { $0.key }, tapped: tapped)
        XCTAssertTrue(again.isEmpty)
    }

    func testTappedKeysReadOnlyOpenMarks() {
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: "s24.openedSeen")
        defer { if let saved { defaults.set(saved, forKey: "s24.openedSeen") } else { defaults.removeObject(forKey: "s24.openedSeen") } }
        defaults.set(["x|100|o", "y|200|a"], forKey: "s24.openedSeen")
        XCTAssertEqual(S24Book.tappedKeys(), ["x|100"])
    }

    // MARK: 活3

    func testUrgentStaysAndTheRestWaitsForMorning() {
        func holds(_ id: String, category: String = "", info: [AnyHashable: Any] = [:], immediate: Bool = true, on: Bool = true) -> Bool {
            S38AMorning.holds(identifier: id, category: category, userInfo: info, immediate: immediate, on: on)
        }
        // 急ぎ: 時計が録音していない・電池・時計が黙っている・録音が止まった
        for id in ["watch-not-recording", "watch-battery", "watch-silent", "phone-stopped", "stall"] {
            XCTAssertFalse(holds(id), id)
        }
        // 期限・家の PC からの急ぎ・ボタンのある知らせ・今の便り自身
        XCTAssertFalse(holds("tasks-due-1"))
        XCTAssertFalse(holds("0F0E", info: ["lifelog": ["kind": "urgent", "key": "k"]]))
        XCTAssertFalse(holds("taskFound", category: "taskFound"))
        XCTAssertFalse(holds(NoticeDigestRules.morningID))
        // それ以外はまとめる
        XCTAssertTrue(holds("good-tonight"))
        XCTAssertTrue(holds("night-mood"))
        // オフ・時刻を決めた知らせはそのまま
        XCTAssertFalse(holds("good-tonight", on: false))
        XCTAssertFalse(holds("good-tonight", immediate: false))
    }

    func testMorningSlotIsOnlyTheMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        // 夕方に回したものも、次の日の朝 7:30
        XCTAssertEqual(S38AMorning.nextSlot(after: at(28, 19, 30), calendar: calendar), at(29, 7, 30))
        XCTAssertEqual(S38AMorning.nextSlot(after: at(28, 6, 0), calendar: calendar), at(28, 7, 30))
        XCTAssertEqual(S38AMorning.previousSlot(before: at(28, 19, 30), calendar: calendar), at(28, 7, 30))
        XCTAssertEqual(S38AMorning.previousSlot(before: at(28, 6, 0), calendar: calendar), at(27, 7, 30))
    }

    func testMorningOneIsOnByDefault() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: S38AMorning.key)
        defer { if let saved { defaults.set(saved, forKey: S38AMorning.key) } else { defaults.removeObject(forKey: S38AMorning.key) } }
        defaults.removeObject(forKey: S38AMorning.key)
        XCTAssertTrue(S38AMorning.isOn)
        defaults.set(false, forKey: S38AMorning.key)
        XCTAssertFalse(S38AMorning.isOn)
    }
}

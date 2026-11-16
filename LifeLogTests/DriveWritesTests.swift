import XCTest
@testable import LifeLog

/// ドライブへの書き込みを減らす（2026-11-16。強化案 83。DriveWrites.swift）の、決まった答えのある所を確かめる。
@MainActor
final class DriveWritesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_800_000)

    // MARK: - 失敗の扱い

    func testCancelledAndLostConnectionAreRetryLater() {
        XCTAssertEqual(DriveRetry.kind(URLError(.cancelled)), .retryLater)
        XCTAssertEqual(DriveRetry.kind(CancellationError()), .retryLater)
        XCTAssertEqual(DriveRetry.kind(URLError(.networkConnectionLost)), .retryLater)
        XCTAssertEqual(DriveRetry.kind(URLError(.notConnectedToInternet)), .retryLater)
        XCTAssertEqual(DriveRetry.kind(URLError(.timedOut)), .retryLater)
        XCTAssertEqual(DriveRetry.kind(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)), .retryLater)
    }

    func testRateLimitIsRecognised() {
        XCTAssertEqual(DriveRetry.kind(GoogleError.http(429, "Quota exceeded for quota metric")), .rateLimited)
        XCTAssertEqual(DriveRetry.kind(GoogleError.http(403, "{\"reason\": \"userRateLimitExceeded\"}")), .rateLimited)
        XCTAssertEqual(DriveRetry.kind(GoogleError.backoff(until: now)), .rateLimited)
    }

    func testOtherErrorsStayErrors() {
        XCTAssertEqual(DriveRetry.kind(GoogleError.http(403, "insufficientPermissions")), .error)
        XCTAssertEqual(DriveRetry.kind(GoogleError.http(500, "")), .error)
        XCTAssertEqual(DriveRetry.kind(GoogleError.notSignedIn), .error)
        XCTAssertEqual(DriveRetry.kind(URLError(.badURL)), .error)
    }

    func testRetryAfterSecondsAndDate() {
        XCTAssertEqual(DriveRetry.retryAfter("120", now: now), 120)
        XCTAssertEqual(DriveRetry.retryAfter(" 5 ", now: now), 5)
        XCTAssertNil(DriveRetry.retryAfter(nil, now: now))
        XCTAssertNil(DriveRetry.retryAfter("", now: now))
        XCTAssertNil(DriveRetry.retryAfter("soon", now: now))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = f.string(from: now.addingTimeInterval(90))
        XCTAssertEqual(DriveRetry.retryAfter(header, now: now) ?? -1, 90, accuracy: 1)
        // 過ぎた日付は 0
        XCTAssertEqual(DriveRetry.retryAfter(f.string(from: now.addingTimeInterval(-30)), now: now), 0)
    }

    // MARK: - 429 のあとの止め

    func testBackoffDoublesWithoutRetryAfter() {
        var b = DriveBackoff()
        XCTAssertFalse(b.blocked(at: now))
        b.rateLimited(retryAfter: nil, at: now)
        XCTAssertEqual(b.remaining(at: now), 60, accuracy: 0.001)
        b.rateLimited(retryAfter: nil, at: now)
        XCTAssertEqual(b.remaining(at: now), 120, accuracy: 0.001)
        for _ in 0..<20 { b.rateLimited(retryAfter: nil, at: now) }
        XCTAssertEqual(b.remaining(at: now), DriveBackoff.cap, accuracy: 0.001)
        XCTAssertTrue(b.blocked(at: now.addingTimeInterval(DriveBackoff.cap - 1)))
        XCTAssertFalse(b.blocked(at: now.addingTimeInterval(DriveBackoff.cap + 1)))
    }

    func testBackoffRespectsRetryAfterAndResets() {
        var b = DriveBackoff()
        b.rateLimited(retryAfter: 7, at: now)
        XCTAssertEqual(b.remaining(at: now), 7, accuracy: 0.001)
        // とても長い Retry-After は 1 時間まで
        b.rateLimited(retryAfter: 99_999, at: now)
        XCTAssertEqual(b.remaining(at: now), DriveBackoff.longestRetryAfter, accuracy: 0.001)
        // 短い Retry-After で、前の長い止めを縮めない
        b.rateLimited(retryAfter: 1, at: now)
        XCTAssertEqual(b.remaining(at: now), DriveBackoff.longestRetryAfter, accuracy: 0.001)
        b.succeeded()
        XCTAssertFalse(b.blocked(at: now))
        XCTAssertEqual(b.strikes, 0)
        b.rateLimited(retryAfter: nil, at: now)
        XCTAssertEqual(b.remaining(at: now), DriveBackoff.base, accuracy: 0.001)
    }

    func testBackoffRoundTripsThroughJSON() throws {
        var b = DriveBackoff()
        b.rateLimited(retryAfter: 30, at: now)
        let back = try JSONDecoder().decode(DriveBackoff.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }

    // MARK: - 同じ中身の印

    func testStampSameForSameContent() {
        let a: [(text: String, style: String?)] = [("頼まれごと", "HEADING_1"), ("・一つ目", nil)]
        let b: [(text: String, style: String?)] = [("頼まれごと", "HEADING_1"), ("・一つ目", nil)]
        XCTAssertEqual(DriveStamp.digest(a), DriveStamp.digest(b))
        XCTAssertEqual(DriveStamp.digest(Data("x".utf8)), DriveStamp.digest(Data("x".utf8)))
        XCTAssertEqual(DriveStamp.digest(Data("x".utf8)).count, 64)
    }

    func testStampDiffersWhenTextOrStyleChanges() {
        let base: [(text: String, style: String?)] = [("頼まれごと", "HEADING_1"), ("・一つ目", nil)]
        XCTAssertNotEqual(DriveStamp.digest(base), DriveStamp.digest([("頼まれごと", nil), ("・一つ目", nil)]))
        XCTAssertNotEqual(DriveStamp.digest(base), DriveStamp.digest([("頼まれごと", "HEADING_1"), ("・二つ目", nil)]))
        // 段落の切れ目が違えば違う
        XCTAssertNotEqual(DriveStamp.digest([("ab", nil)]), DriveStamp.digest([("a", nil), ("b", nil)]))
    }

    // MARK: - ドキュメントの直しのやり直し

    func testDocFixRetryLaterDoesNotCountTowardsGiveUp() {
        let fix = DocFix(find: "a", replace: "b")
        let kept = DocFixQueue.after(tried: [fix], snapshot: [fix], now: DocFixQueue(fixes: [fix], failures: 5),
                                     failed: true, failures: 5, countFailure: false)
        XCTAssertEqual(kept, DocFixQueue(fixes: [fix], failures: 5))
        let counted = DocFixQueue.after(tried: [fix], snapshot: [fix], now: DocFixQueue(fixes: [fix], failures: 5),
                                        failed: true, failures: 5)
        XCTAssertEqual(counted?.failures, 6)
        // 数えないので、上限の手前でいつまでも残る（捨てない）
        let nearLimit = DocFixQueue.after(tried: [fix], snapshot: [fix], now: nil, failed: true,
                                          failures: DocFixQueue.giveUp - 1, countFailure: false)
        XCTAssertEqual(nearLimit?.fixes, [fix])
    }

    // MARK: - まとめて書く

    func testCoalescerRunsOnceForBurst() async throws {
        let c = DriveWriteCoalescer()
        var runs = 0
        for _ in 0..<5 {
            c.schedule("book", after: 0.05) { runs += 1; return true }
        }
        XCTAssertEqual(c.waiting, 1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(c.waiting, 0)
    }

    func testCoalescerFlushRunsWithoutWaiting() async {
        let c = DriveWriteCoalescer()
        var ran: [String] = []
        c.schedule("a", after: 3600) { ran.append("a"); return true }
        c.schedule("b", after: 3600) { ran.append("b"); return true }
        await c.flush()
        XCTAssertEqual(ran, ["a", "b"])
        XCTAssertEqual(c.waiting, 0)
        // もう一度 flush しても二度は書かない
        await c.flush()
        XCTAssertEqual(ran, ["a", "b"])
    }

    func testCoalescerKeepsJobThatMustRetry() async {
        let c = DriveWriteCoalescer()
        var tries = 0
        c.schedule("book", after: 3600) { tries += 1; return false }
        await c.flush()
        XCTAssertEqual(tries, 1)
        // あとでやり直すので、待っている
        XCTAssertEqual(c.waiting, 1)
        await c.flush()
        XCTAssertEqual(tries, 2)
    }
}

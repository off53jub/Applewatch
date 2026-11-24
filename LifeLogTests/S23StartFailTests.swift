import XCTest
@testable import LifeLog

/// iPhone の録音を始められなかったとき（2026-11-24。S23StartFail.swift）
final class S23StartFailTests: XCTestCase {
    func testOSStatusBecomesFourLetters() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: 560557684)
        XCTAssertEqual(S23StartFail.code(error), "!int")
    }

    func testReasonIsJapaneseNotRawEnglish() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: 560557684)
        let text = S23StartFail.reason(error, background: true)
        XCTAssertFalse(text.contains("OSStatus"))
        XCTAssertTrue(text.contains("裏"))
        XCTAssertTrue(S23StartFail.body(reason: text).contains("押すと"))
    }

    func testPendingLastsThirtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(S23StartFail.isPending(at: 1_000_000 - 60, now: now))
        XCTAssertFalse(S23StartFail.isPending(at: 1_000_000 - 31 * 60, now: now))
        XCTAssertFalse(S23StartFail.isPending(at: 0, now: now))
    }

    func testWatchDirectSilencesQuietAlert() {
        XCTAssertTrue(S23WatchQuiet.isDirect(watchDirectOn: true, allowed: true))
        XCTAssertFalse(S23WatchQuiet.isDirect(watchDirectOn: true, allowed: false))  // iPhone 経由だけの日
        XCTAssertFalse(S23WatchQuiet.isDirect(watchDirectOn: nil, allowed: true))    // 古い版の時計
    }
}

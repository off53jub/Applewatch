import XCTest
@testable import LifeLog

/// ドキュメントの直しのやり直し（DocFixes.swift）。2026-11-08
final class DocFixTests: XCTestCase {
    private let a = DocFix(find: "10:00 人物3: こんにちは", replace: "10:00 田中: こんにちは")
    private let b = DocFix(find: "10:00 田中: こんにちは", replace: "10:00 佐藤: こんにちは")
    private let c = DocFix(find: "11:00 人物4: はい", replace: "11:00 テレビ: はい")

    func testSuccessClearsWhatWasTried() {
        let left = DocFixQueue.after(tried: [a, b], snapshot: [a], now: DocFixQueue(fixes: [a], failures: 2),
                                     failed: false, failures: 2)
        XCTAssertNil(left)
    }

    func testSuccessKeepsFixesAddedWhileWaiting() {
        // 当てているあいだに、同じ日の直し c が足された
        let left = DocFixQueue.after(tried: [a], snapshot: [a], now: DocFixQueue(fixes: [a, c]),
                                     failed: false, failures: 0)
        XCTAssertEqual(left, DocFixQueue(fixes: [c]))
    }

    func testFailureKeepsOrderAndCounts() {
        // 前の直し a のあとに新しい b。順を守って覚える（名前を2回直したとき）
        let left = DocFixQueue.after(tried: [a, b], snapshot: [a], now: DocFixQueue(fixes: [a], failures: 1),
                                     failed: true, failures: 1)
        XCTAssertEqual(left, DocFixQueue(fixes: [a, b], failures: 2))
    }

    func testFailureAppendsFixesAddedWhileWaiting() {
        let left = DocFixQueue.after(tried: [a], snapshot: [], now: DocFixQueue(fixes: [c]), failed: true, failures: 0)
        XCTAssertEqual(left, DocFixQueue(fixes: [a, c], failures: 1))
    }

    func testGivesUpAfterManyFailures() {
        let left = DocFixQueue.after(tried: [a], snapshot: [a], now: DocFixQueue(fixes: [a], failures: 19),
                                     failed: true, failures: DocFixQueue.giveUp - 1)
        XCTAssertNil(left)
    }

    func testCancellation() {
        XCTAssertTrue(URLError(.cancelled).isCancellation)
        XCTAssertTrue(CancellationError().isCancellation)
        XCTAssertTrue(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled).isCancellation)
        XCTAssertFalse(URLError(.timedOut).isCancellation)
    }
}

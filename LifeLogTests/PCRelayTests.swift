import XCTest
@testable import LifeLog

/// 時計の区切りの音声を、時計からではなく家の PC から受け取る（2026-11-15。強化案 64。PCRelay.swift・WatchDelivery.swift）を確かめる。
/// 時計が待つか・名前の直し方・いま受け取れるか・受け取る区切りの選び方。
final class PCRelayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_700_000)
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let london = TimeZone(identifier: "Europe/London")!

    private func watchName(_ date: Date) -> String {
        Storage.watchChunkName(from: Storage.chunkName(for: date))
    }

    // MARK: - 時計が待つか

    func testHoldOnlyWhenPhoneCanPullAndPCHasIt() {
        let sent = now.addingTimeInterval(-60)
        // iPhone が受け取れると言っていなければ、今までどおりすぐ送る
        XCTAssertFalse(WatchDelivery.relayHold(relay: false, sentToPC: sent, sendingToPC: false, now: now))
        XCTAssertFalse(WatchDelivery.relayHold(relay: false, sentToPC: nil, sendingToPC: true, now: now))
        // PC に届いた・送っている途中なら待つ
        XCTAssertTrue(WatchDelivery.relayHold(relay: true, sentToPC: sent, sendingToPC: false, now: now))
        XCTAssertTrue(WatchDelivery.relayHold(relay: true, sentToPC: nil, sendingToPC: true, now: now))
        // PC に送れなかった区切りは待たない
        XCTAssertFalse(WatchDelivery.relayHold(relay: true, sentToPC: nil, sendingToPC: false, now: now))
    }

    func testHoldEndsAfterTheWait() {
        let justInside = now.addingTimeInterval(-(WatchDelivery.relayWait - 1))
        let justOutside = now.addingTimeInterval(-WatchDelivery.relayWait)
        XCTAssertTrue(WatchDelivery.relayHold(relay: true, sentToPC: justInside, sendingToPC: false, now: now))
        XCTAssertFalse(WatchDelivery.relayHold(relay: true, sentToPC: justOutside, sendingToPC: false, now: now))
        // 時計の時刻が戻ったとき（届いた時刻が先）は待たない
        XCTAssertFalse(WatchDelivery.relayHold(relay: true, sentToPC: now.addingTimeInterval(120), sendingToPC: false, now: now))
    }

    // MARK: - 名前（iPhone で付く名前 → 時計の名前）

    func testWatchNameIsTheReverseOfPhoneName() {
        // 同じ時間帯
        XCTAssertEqual(WatchDelivery.watchName("20261115-190951-w.m4a", watchZone: tokyo, phoneZone: tokyo),
                       "20261115-190951.m4a")
        // 時差があるとき（時計はロンドン、iPhone は日本）
        let phone = WatchDelivery.phoneName("20261115-100951.m4a", watchZone: london, phoneZone: tokyo)
        XCTAssertEqual(phone, "20261115-190951-w.m4a")
        XCTAssertEqual(WatchDelivery.watchName(phone, watchZone: london, phoneZone: tokyo), "20261115-100951.m4a")
    }

    func testWatchNameRejectsOtherNames() {
        // iPhone で録った区切り・取り込んだ音声・ほかの形・道の入った名前
        for bad in ["20261115-190951.m4a", "20261115-190951-i.m4a", "20261115-190951-w.json", "x-w.m4a",
                    "../20261115-190951-w.m4a", "abcdefgh-ijklmn-w.m4a", ""] {
            XCTAssertNil(WatchDelivery.watchName(bad, watchZone: tokyo, phoneZone: tokyo), bad)
        }
    }

    // MARK: - いま受け取れるか

    func testUsableNeedsSettingSupportAndNetwork() {
        func usable(on: Bool = true, supported: Bool = true, pcReady: Bool = true, onWiFi: Bool = true,
                    online: Bool = true, cellular: Bool = false) -> Bool {
            PCRelay.usable(on: on, supported: supported, pcReady: pcReady, onWiFi: onWiFi, online: online, cellular: cellular)
        }
        XCTAssertTrue(usable())
        XCTAssertFalse(usable(on: false))
        XCTAssertFalse(usable(supported: false))
        XCTAssertFalse(usable(pcReady: false))
        // Wi-Fi でないときは、「モバイル通信でも受け取る」がオンで、ネットにつながっているときだけ
        XCTAssertFalse(usable(onWiFi: false))
        XCTAssertTrue(usable(onWiFi: false, cellular: true))
        XCTAssertFalse(usable(onWiFi: false, online: false, cellular: true))
    }

    // MARK: - 受け取る区切りの選び方

    func testPickNewestFirstAndSkipsWhatWeHave() {
        let a = watchName(now.addingTimeInterval(-1500))
        let b = watchName(now.addingTimeInterval(-900))
        let c = watchName(now.addingTimeInterval(-300))
        let have: Set<String> = [b]
        // 新しい順。もう受け取ったものは選ばない。同じ名前が2つあっても1つだけ
        XCTAssertEqual(PCRelay.pick([a, b, c, a], have: { have.contains($0) }, failed: [:], now: now), [c, a])
        // 1回に受け取る数の上限
        XCTAssertEqual(PCRelay.pick([a, b, c], have: { _ in false }, failed: [:], now: now, limit: 2), [c, b])
    }

    func testPickSkipsOldFailedAndOtherNames() {
        let old = watchName(now.addingTimeInterval(-3 * 86400))  // 2日より古い
        let future = watchName(now.addingTimeInterval(3600))     // 時計の時刻が大きくずれている
        let phone = Storage.chunkName(for: now.addingTimeInterval(-600))  // iPhone で録った区切り
        let failedNow = watchName(now.addingTimeInterval(-600))
        let failedLongAgo = watchName(now.addingTimeInterval(-1200))
        let failed = [failedNow: now.addingTimeInterval(-60),
                      failedLongAgo: now.addingTimeInterval(-(PCRelay.retryAfter + 1))]
        let picked = PCRelay.pick([old, future, phone, failedNow, failedLongAgo], have: { _ in false },
                                  failed: failed, now: now)
        // さっき受け取れなかったものは15分は試さない。15分たったものは、もう一度試す
        XCTAssertEqual(picked, [failedLongAgo])
    }
}

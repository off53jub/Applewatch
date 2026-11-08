import XCTest
@testable import LifeLog

/// 時計から家の PC への外の道（Tailscale の Funnel。2026-11-07。Shared/Audio/WatchDelivery.swift）を確かめる。
/// 宛先の確かめ方・道の選び方・返事ごとの扱い・追いかけて送る区切りの選び方。
final class WatchRouteTests: XCTestCase {
    /// 2026-11-07T06:58:25.123Z
    private let t = Date(timeIntervalSince1970: 1_794_034_705.123)

    // MARK: - 宛先

    func testPublicBaseURLAcceptsFunnelNames() {
        XCTAssertEqual(WatchDelivery.publicBaseURL("https://desktop-abc.tail1234.ts.net")?.absoluteString,
                       "https://desktop-abc.tail1234.ts.net")
        // 大文字・終わりの「/」・前後の空白・443 は直す
        XCTAssertEqual(WatchDelivery.publicBaseURL(" HTTPS://Desktop-ABC.tail1234.ts.net/ ")?.absoluteString,
                       "https://desktop-abc.tail1234.ts.net")
        XCTAssertEqual(WatchDelivery.publicBaseURL("https://desktop-abc.tail1234.ts.net:443")?.absoluteString,
                       "https://desktop-abc.tail1234.ts.net")
    }

    func testPublicBaseURLRejectsOthers() {
        let bad = [
            "",
            "desktop-abc.tail1234.ts.net",
            "http://desktop-abc.tail1234.ts.net",
            "https://desktop-abc.tail1234.ts.net:8443",
            "https://desktop-abc.tail1234.ts.net/w",
            "https://desktop-abc.tail1234.ts.net/w/jobs",
            "https://desktop-abc.tail1234.ts.net?x=1",
            "https://desktop-abc.tail1234.ts.net#x",
            "https://user@desktop-abc.tail1234.ts.net",
            "https://example.com",
            "https://ts.net",
            "https://.ts.net",
            "https://a..ts.net",
            "https://desktop.ts.net.example.com",
            "https://192.168.1.20",
        ]
        for text in bad {
            XCTAssertNil(WatchDelivery.publicBaseURL(text), text)
        }
    }

    func testContractNames() {
        // iPhone と時計で同じ名前を使う（PC の約束: /w/jobs・/w/ping）
        XCTAssertEqual(WatchDelivery.publicURLKey, "pcPublicURL")
        XCTAssertEqual(WatchDelivery.publicSecretKey, "pcPublicKey")
        let base = URL(string: "https://desktop-abc.tail1234.ts.net")!
        XCTAssertEqual(WatchDelivery.DirectRoute.publicRoute(base).uploadURL.absoluteString,
                       "https://desktop-abc.tail1234.ts.net/w/jobs")
        let home = URL(string: "http://192.168.1.20:47615")!
        XCTAssertEqual(WatchDelivery.DirectRoute.home(home).uploadURL.absoluteString, "http://192.168.1.20:47615/jobs")
    }

    // MARK: - 道の選び方

    func testDirectRoutePrefersPublic() {
        let url = "https://desktop-abc.tail1234.ts.net"
        let both = WatchDelivery.directRoute(direct: true, publicURL: url, hasPublicKey: true, publicUsable: true,
                                             homeAddress: "192.168.1.20", hasHomeKey: true)
        XCTAssertEqual(both, .publicRoute(URL(string: url)!))
        XCTAssertEqual(both?.isPublic, true)
        // 外の道だけでも送る
        XCTAssertEqual(WatchDelivery.directRoute(direct: true, publicURL: url, hasPublicKey: true, publicUsable: true,
                                                 homeAddress: nil, hasHomeKey: false), .publicRoute(URL(string: url)!))
    }

    func testDirectRouteFallsBackToHome() {
        let url = "https://desktop-abc.tail1234.ts.net"
        let home = WatchDelivery.DirectRoute.home(URL(string: "http://192.168.1.20:47615")!)
        // 合言葉が違うと言われた・しばらく待つあいだ
        XCTAssertEqual(WatchDelivery.directRoute(direct: true, publicURL: url, hasPublicKey: true, publicUsable: false,
                                                 homeAddress: "192.168.1.20", hasHomeKey: true), home)
        // 時計用の合言葉が無い
        XCTAssertEqual(WatchDelivery.directRoute(direct: true, publicURL: url, hasPublicKey: false, publicUsable: true,
                                                 homeAddress: "192.168.1.20", hasHomeKey: true), home)
        // 外の道の宛先がおかしい
        XCTAssertEqual(WatchDelivery.directRoute(direct: true, publicURL: "http://x.ts.net", hasPublicKey: true,
                                                 publicUsable: true, homeAddress: "192.168.1.20", hasHomeKey: true), home)
        XCTAssertEqual(home.isPublic, false)
    }

    func testDirectRouteNone() {
        let url = "https://desktop-abc.tail1234.ts.net"
        // iPhone でオフ
        XCTAssertNil(WatchDelivery.directRoute(direct: false, publicURL: url, hasPublicKey: true, publicUsable: true,
                                               homeAddress: "192.168.1.20", hasHomeKey: true))
        // どちらも無い
        XCTAssertNil(WatchDelivery.directRoute(direct: true, publicURL: nil, hasPublicKey: false, publicUsable: true,
                                               homeAddress: "", hasHomeKey: false))
        // 外の道は使えず、家の中の住所は合言葉が無い
        XCTAssertNil(WatchDelivery.directRoute(direct: true, publicURL: url, hasPublicKey: true, publicUsable: false,
                                               homeAddress: "192.168.1.20", hasHomeKey: false))
    }

    // MARK: - 返事ごとの扱い

    func testDirectOutcome() {
        XCTAssertEqual(WatchDelivery.directOutcome(status: 200, networkError: false, isPublic: true), .sent)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 200, networkError: false, isPublic: false), .sent)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 0, networkError: true, isPublic: true), .failed)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 200, networkError: true, isPublic: true), .failed)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 401, networkError: false, isPublic: true), .refused)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 429, networkError: false, isPublic: true), .busy)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 400, networkError: false, isPublic: true), .rejected)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 413, networkError: false, isPublic: true), .rejected)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 502, networkError: false, isPublic: true), .failed)
        // 家の中の住所は今までどおり（200 以外は「届かなかった」で10分待つ）
        XCTAssertEqual(WatchDelivery.directOutcome(status: 401, networkError: false, isPublic: false), .failed)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 429, networkError: false, isPublic: false), .failed)
        XCTAssertEqual(WatchDelivery.directOutcome(status: 400, networkError: false, isPublic: false), .failed)
    }

    // MARK: - 追いかけて送る区切り

    func testCatchUpPickOldestFirstWithinADay() {
        let hour: TimeInterval = 3600
        let files: [(name: String, start: Date?)] = [
            (name: "e.m4a", start: t.addingTimeInterval(-2 * hour)),
            (name: "a.m4a", start: t.addingTimeInterval(-30 * hour)),  // 24時間より古い
            (name: "d.m4a", start: t.addingTimeInterval(-3 * hour)),
            (name: "c.m4a", start: t.addingTimeInterval(-4 * hour)),  // もう送った
            (name: "b.m4a", start: t.addingTimeInterval(-5 * hour)),
            (name: "f.m4a", start: nil),  // 名前から時刻が読めない
            (name: "g.m4a", start: t.addingTimeInterval(60)),  // 先の時刻
            (name: "h.m4a", start: t.addingTimeInterval(-1 * hour)),  // 4つ目（3つまで）
        ]
        XCTAssertEqual(WatchDelivery.catchUpPick(files, skip: ["c.m4a"], now: t), ["b.m4a", "d.m4a", "e.m4a"])
        XCTAssertEqual(WatchDelivery.catchUpPick([], skip: [], now: t), [])
        XCTAssertEqual(WatchDelivery.catchUpPick(files, skip: ["b.m4a", "c.m4a", "d.m4a", "e.m4a", "h.m4a"], now: t), [])
    }

    // MARK: - 時計に届いていなければ送り直す（2026-11-08）

    func testNeedsResendWhenWatchLacksPublicRoute() {
        // iPhone は外の道を持っているのに、時計は「まだ受け取っていない」
        XCTAssertTrue(WatchDelivery.needsResend(watchHasPublic: false, watchDirectOn: true,
                                                phoneHasPublic: true, phoneDirectOn: true))
        // 時計の「直接送る」がオフのまま
        XCTAssertTrue(WatchDelivery.needsResend(watchHasPublic: true, watchDirectOn: false,
                                                phoneHasPublic: true, phoneDirectOn: true))
        // iPhone で外の道が無くなったのに、時計がまだ持っている（消してもらう）
        XCTAssertTrue(WatchDelivery.needsResend(watchHasPublic: true, watchDirectOn: true,
                                                phoneHasPublic: false, phoneDirectOn: true))
    }

    func testNoResendWhenInStepOrOldWatch() {
        XCTAssertFalse(WatchDelivery.needsResend(watchHasPublic: true, watchDirectOn: true,
                                                 phoneHasPublic: true, phoneDirectOn: true))
        XCTAssertFalse(WatchDelivery.needsResend(watchHasPublic: false, watchDirectOn: false,
                                                 phoneHasPublic: false, phoneDirectOn: false))
        // 古い版の時計（項目が無い）には送らない
        XCTAssertFalse(WatchDelivery.needsResend(watchHasPublic: nil, watchDirectOn: nil,
                                                 phoneHasPublic: true, phoneDirectOn: true))
        // 外の道の項目だけある時計（版 10 の最初）でも、外の道を受け取っていれば送らない
        XCTAssertFalse(WatchDelivery.needsResend(watchHasPublic: true, watchDirectOn: nil,
                                                 phoneHasPublic: true, phoneDirectOn: true))
    }
}

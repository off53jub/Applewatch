import XCTest
@testable import LifeLog

/// 時計の区切りを早く届ける（2026-11-07。Shared/Audio/WatchDelivery.swift）を確かめる。
/// 時計が添える控え・低電力モードの15分の決まり・iPhone で付く名前・家の中の住所・電池の決まり・PC への query・
/// 時計→iPhone の内訳（時計で待った・受け渡し）と、前の形の保存ファイルが読めること。
@MainActor
final class WatchDeliveryTests: XCTestCase {
    /// 2026-11-07T06:58:25.123Z
    private let t = Date(timeIntervalSince1970: 1_794_034_705.123)
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - 控え（metadata）

    func testMetadataRoundTrip() {
        let meta = WatchDelivery.metadata(zone: tokyo, cut: t.addingTimeInterval(-30), sent: t, lowPower: true, viaPC: true, resend: 2)
        XCTAssertEqual(meta["tz"] as? String, "Asia/Tokyo")
        XCTAssertEqual(meta["resend"] as? Int, 2)
        // WatchConnectivity を通ると数は NSNumber になる
        let carried: [String: Any] = meta.mapValues { value -> Any in
            if let d = value as? Double { return NSNumber(value: d) }
            if let b = value as? Bool { return NSNumber(value: b) }
            return value
        }
        let stamp = WatchDelivery.stamp(from: carried)
        XCTAssertEqual(stamp.cut?.timeIntervalSince1970 ?? 0, t.addingTimeInterval(-30).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(stamp.sent?.timeIntervalSince1970 ?? 0, t.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(stamp.lowPower, true)
        XCTAssertTrue(stamp.viaPC)
    }

    func testOldWatchMetadataHasNoTimes() {
        // 古い時計のアプリは時間帯だけを送る
        let stamp = WatchDelivery.stamp(from: ["tz": "Asia/Tokyo"])
        XCTAssertEqual(stamp, WatchDelivery.Stamp())
        XCTAssertEqual(WatchDelivery.stamp(from: nil), WatchDelivery.Stamp())
        // PC に送っていなければ pc は付けない
        XCTAssertNil(WatchDelivery.metadata(zone: tokyo, cut: nil, sent: t, lowPower: false, viaPC: false)["pc"])
        XCTAssertNil(WatchDelivery.metadata(zone: tokyo, cut: nil, sent: t, lowPower: false, viaPC: false)["cut"])
    }

    // MARK: - 低電力モード

    func testLowPowerSendsAfterFifteenMinutesEvenIfFew() {
        let batch = 12
        XCTAssertFalse(WatchDelivery.lowPowerDue(count: 0, batch: batch, oldest: t.addingTimeInterval(-3600), now: t))
        XCTAssertTrue(WatchDelivery.lowPowerDue(count: 12, batch: batch, oldest: t, now: t))
        XCTAssertFalse(WatchDelivery.lowPowerDue(count: 2, batch: batch, oldest: t.addingTimeInterval(-14 * 60), now: t))
        XCTAssertTrue(WatchDelivery.lowPowerDue(count: 2, batch: batch, oldest: t.addingTimeInterval(-15 * 60), now: t))
        // 古さが分からなければ、今までどおり数だけで決める
        XCTAssertFalse(WatchDelivery.lowPowerDue(count: 2, batch: batch, oldest: nil, now: t))
    }

    // MARK: - 名前

    func testPhoneNameConvertsZoneAndAddsW() {
        // 時計が UTC、iPhone が日本時間
        XCTAssertEqual(WatchDelivery.phoneName("20261107-013200.m4a", watchZone: utc, phoneZone: tokyo), "20261107-103200-w.m4a")
        // 同じ時間帯なら時刻はそのまま
        XCTAssertEqual(WatchDelivery.phoneName("20261107-103200.m4a", watchZone: tokyo, phoneZone: tokyo), "20261107-103200-w.m4a")
        // もう -w が付いていれば重ねない
        XCTAssertEqual(WatchDelivery.phoneName("20261107-103200-w.m4a", watchZone: tokyo, phoneZone: tokyo), "20261107-103200-w.m4a")
        XCTAssertEqual(WatchDelivery.startDate("20261107-013200.m4a", zone: utc),
                       WatchDelivery.startDate("20261107-103200.m4a", zone: tokyo))
    }

    func testPhoneNameMatchesPhoneReceiver() {
        // iPhone の PhoneReceiver（convertedName → watchChunkName）と同じ名前になる（PC で同じ仕事にまとまる）
        let phone = TimeZone.current
        for watch in [utc, tokyo, TimeZone(identifier: "America/Los_Angeles")!] {
            let name = "20261107-013200.m4a"
            XCTAssertEqual(WatchDelivery.phoneName(name, watchZone: watch, phoneZone: phone),
                           Storage.watchChunkName(from: Storage.convertedName(name, from: watch)), watch.identifier)
        }
    }

    // MARK: - 家の中の住所

    func testHomeAddress() {
        XCTAssertEqual(WatchDelivery.homeBaseURL("192.168.1.20")?.absoluteString, "http://192.168.1.20:47615")
        XCTAssertEqual(WatchDelivery.homeBaseURL(" http://192.168.1.20:47616/ ")?.absoluteString, "http://192.168.1.20:47616")
        XCTAssertEqual(WatchDelivery.homeBaseURL("10.0.0.5")?.absoluteString, "http://10.0.0.5:47615")
        XCTAssertNotNil(WatchDelivery.homeBaseURL("172.31.255.1"))
        XCTAssertNotNil(WatchDelivery.homeBaseURL("MyPC.local"))
        XCTAssertNotNil(WatchDelivery.homeBaseURL("mypc"))
        // 時計からは使えない宛先（Tailscale・外の住所）と、読めない書き方
        for bad in ["", "100.101.1.2", "my-pc.tail1234.ts.net:47615", "8.8.8.8", "172.15.0.1", "172.32.0.1",
                    "192.168.1", "192.168.1.300", "192.168.1.20:99999", "192.168.1.20:abc", ".local", "my pc"] {
            XCTAssertNil(WatchDelivery.homeBaseURL(bad), bad)
        }
    }

    // MARK: - 電池の決まり

    func testDirectAllowed() {
        XCTAssertTrue(WatchDelivery.directAllowed(lowPower: false, battery: 0.8, charging: false, lastFailure: nil, now: t))
        XCTAssertFalse(WatchDelivery.directAllowed(lowPower: true, battery: 0.8, charging: false, lastFailure: nil, now: t))
        XCTAssertFalse(WatchDelivery.directAllowed(lowPower: false, battery: 0.15, charging: false, lastFailure: nil, now: t))
        XCTAssertTrue(WatchDelivery.directAllowed(lowPower: false, battery: 0.15, charging: true, lastFailure: nil, now: t))
        XCTAssertTrue(WatchDelivery.directAllowed(lowPower: false, battery: nil, charging: false, lastFailure: nil, now: t))
        // 届かなかったら10分は試さない
        XCTAssertFalse(WatchDelivery.directAllowed(lowPower: false, battery: 0.8, charging: false,
                                                   lastFailure: t.addingTimeInterval(-9 * 60), now: t))
        XCTAssertTrue(WatchDelivery.directAllowed(lowPower: false, battery: 0.8, charging: false,
                                                  lastFailure: t.addingTimeInterval(-10 * 60), now: t))
    }

    // MARK: - PC への query

    func testJobQuery() {
        let long = String(repeating: "あ", count: 2000)
        let items = WatchDelivery.jobQuery(name: "20261107-103200-w.m4a", chunkStart: t.addingTimeInterval(-120),
                                           chunkEnd: t, sent: t, hints: long, weights: "w")
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        XCTAssertEqual(value("name"), "20261107-103200-w.m4a")
        XCTAssertEqual(value("sent"), "2026-11-07T06:58:25.123Z")
        XCTAssertEqual(value("chunk_end"), "2026-11-07T06:58:25.123Z")
        XCTAssertTrue(value("chunk_start")?.hasPrefix("2026-11-07T06:56:25.") == true, value("chunk_start") ?? "")
        XCTAssertEqual(value("hints")?.count, WatchDelivery.hintsLimit)
        XCTAssertEqual(value("weights"), "w")
        // 待ち合わせにしない（答えは iPhone が受け取る）・iPhone に届いた時刻は付けない
        XCTAssertNil(value("wait"))
        XCTAssertNil(value("arrived"))
        let bare = WatchDelivery.jobQuery(name: "a.m4a", chunkStart: nil, chunkEnd: nil, sent: t, hints: "", weights: nil)
        XCTAssertEqual(bare.map(\.name), ["name", "sent"])
    }

    // MARK: - 時計→iPhone の内訳（Latency）

    func testLatencySplitsWatchWaitAndHandoff() {
        let end = t
        var marks = Latency.Marks(watch: true, chunkStart: end.addingTimeInterval(-120), chunkEnd: end,
                                  arrived: end.addingTimeInterval(1000))
        marks.watchCut = end.addingTimeInterval(1)
        marks.watchSent = end.addingTimeInterval(901)
        let sample = Latency.sample(marks, applied: end.addingTimeInterval(1100))
        XCTAssertEqual(sample.toPhone, 1000)
        XCTAssertEqual(sample.watchWait, 900)
        XCTAssertEqual(sample.handoff, 99)
        // iPhone で録った区切りには内訳が無い
        var phone = marks
        phone.watch = false
        XCTAssertNil(Latency.sample(phone, applied: end).watchWait)
        XCTAssertNil(Latency.sample(phone, applied: end).handoff)
        // 古い時計のアプリ（控え無し）なら内訳は分からない
        let old = Latency.Marks(watch: true, chunkStart: nil, chunkEnd: end, arrived: end.addingTimeInterval(60))
        XCTAssertNil(Latency.sample(old, applied: end.addingTimeInterval(90)).watchWait)
        XCTAssertNil(Latency.sample(old, applied: end.addingTimeInterval(90)).handoff)

        let summary = Latency.summarize([sample, Latency.sample(old, applied: end.addingTimeInterval(90))], now: end.addingTimeInterval(2000))
        XCTAssertEqual(summary?.watchWait, 900)
        XCTAssertEqual(summary?.handoff, 99)
        let json = summary?.json ?? [:]
        XCTAssertEqual(json["watchWait"] as? Double, 900)
        XCTAssertEqual(json["handoff"] as? Double, 99)
        // 内訳が分からなければ PC に送る形から省く
        let none = Latency.summarize([Latency.sample(old, applied: end.addingTimeInterval(90))], now: end.addingTimeInterval(100))
        XCTAssertNil(none?.json["watchWait"])
        XCTAssertNil(none?.json["handoff"])
    }

    func testOldSavedFilesStillDecode() throws {
        // 前の形の latency.json の時刻（watchCut・watchSent が無い）
        let marks = try JSONDecoder().decode(Latency.Marks.self, from: Data(#"{"watch":true,"chunkEnd":600,"arrived":660}"#.utf8))
        XCTAssertNil(marks.watchCut)
        XCTAssertNil(marks.watchSent)
        let sample = try JSONDecoder().decode(Latency.Sample.self, from: Data(#"{"at":700,"toPhone":60}"#.utf8))
        XCTAssertNil(sample.watchWait)
        // 前の形の watch-delays.json（cut・sent が無い）
        let entries = try JSONDecoder().decode([WatchDelayLog.Entry].self,
                                               from: Data(#"[{"id":"a-w.m4a","ended":0,"received":60,"lowPower":true}]"#.utf8))
        XCTAssertNil(entries.first?.watchWait)
        XCTAssertNil(entries.first?.handoff)
        XCTAssertNil(WatchDelayLog.splitText(entries))
    }

    func testWatchDelaySplitText() {
        let base = t
        let entries = (0..<3).map { i in
            WatchDelayLog.Entry(id: "\(i)-w.m4a", ended: base, received: base.addingTimeInterval(Double(100 + i * 100)),
                                lowPower: false, cut: base, sent: base.addingTimeInterval(Double(i * 60)))
        }
        // 時計で待った: 0・60・120 秒 → ふつう 60 秒。受け渡し: 100・140・180 秒 → ふつう 2.3 分
        XCTAssertEqual(entries.map { $0.watchWait ?? -1 }, [0, 60, 120])
        XCTAssertEqual(entries.map { $0.handoff ?? -1 }, [100, 140, 180])
        let text = WatchDelayLog.splitText(entries) ?? ""
        XCTAssertTrue(text.contains("時計で待った ふつう 1.0 分"), text)
        XCTAssertTrue(text.contains("受け渡し ふつう 2.3 分"), text)
        XCTAssertTrue(text.contains("（3 個）"), text)
    }
}

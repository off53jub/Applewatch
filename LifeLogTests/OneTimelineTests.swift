import XCTest
@testable import LifeLog

/// 2026-11-14 の強化案（OneTimeline.swift）: 1日の年表の読み方と会話のあいだへの振り分け・反映の見張りの読み方と遅れの日数・
/// PayPay の写真から読めた行の読み方と「もうある」・同じ行のまとめ方・送る中身・位置を当日のうちにの、ためる・送った印・送る中身。
/// 店・場所・人はすべて作り物。
@MainActor
final class OneTimelineTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func tokyoCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tokyo
        return cal
    }

    private func at(_ day: String, _ clock: String) -> Date {
        OneTimeline.date(day: day, clock: clock, calendar: tokyoCalendar())!
    }

    // MARK: - 1日の年表

    func testTimelineDecodeDropsBadRowsAndSorts() throws {
        let long = String(repeating: "店", count: 100)
        let body = """
        {"available": true, "version": 1, "day": "2026-11-14", "generated_at": "2026-11-14T07:00:00+09:00",
         "rows": [
           {"time": "12:10", "end": "12:45", "lane": "位置", "text": "見本の店に滞在", "amount": null, "place": "見本の店"},
           {"time": "08:05", "end": null, "lane": "決済", "text": "\(long)", "amount": 480, "place": null},
           {"time": "25:00", "lane": "予定", "text": "時刻が変"},
           {"time": "9:00", "lane": "予定", "text": "時刻の形が変"},
           {"time": "10:00", "lane": "知らない", "text": "lane が変"},
           {"time": "10:30", "lane": "PC", "text": "  "},
           {"time": "11:00", "end": "あとで", "lane": "LINE", "text": "見本 花子 と 2 件"},
           {"time": "11:30", "lane": "決済", "text": "金額が文", "amount": "500"},
           {"time": "07:00", "lane": "会話", "text": "朝の会話"},
           5
         ]}
        """
        let day = try XCTUnwrap(OneTimeline.decode(data(body), day: "2026-11-14"))
        XCTAssertEqual(day.rows.map(\.time), ["07:00", "08:05", "11:00", "11:30", "12:10"])
        XCTAssertEqual(day.rows[1].text.count, 80)
        XCTAssertEqual(day.rows[1].amount, 480)
        XCTAssertNil(day.rows[2].end, "おかしな終わりは、その値だけ落とす")
        XCTAssertNil(day.rows[3].amount, "型の違う金額は、その値だけ落とす")
        XCTAssertEqual(day.rows[4].end, "12:45")
        XCTAssertEqual(day.rows[4].place, "見本の店")
        // 会話は1日の画面にもとからあるので挟まない
        XCTAssertEqual(OneTimeline.shown(day.rows).map(\.lane), ["決済", "LINE", "決済", "位置"])
    }

    func testTimelineRefusesOtherDayAndUnavailable() {
        XCTAssertNil(OneTimeline.decode(data("{\"available\": false, \"reason\": \"まだ\"}"), day: "2026-11-14"))
        XCTAssertNil(OneTimeline.decode(data("{\"day\": \"2026-11-13\", \"rows\": []}"), day: "2026-11-14"))
        XCTAssertNil(OneTimeline.decode(data("[1, 2]"), day: "2026-11-14"))
        XCTAssertNotNil(OneTimeline.decode(data("{\"rows\": []}"), day: "2026-11-14"))
    }

    func testClock() {
        XCTAssertTrue(OneTimeline.isClock("00:00"))
        XCTAssertTrue(OneTimeline.isClock("23:59"))
        XCTAssertFalse(OneTimeline.isClock("24:00"))
        XCTAssertFalse(OneTimeline.isClock("12:60"))
        XCTAssertFalse(OneTimeline.isClock("+1:00"))
        XCTAssertFalse(OneTimeline.isClock("１２:００"))
        XCTAssertFalse(OneTimeline.isClock(nil))
    }

    func testSlotsPutRowsBetweenConversations() {
        let day = "2026-11-14"
        let cal = tokyoCalendar()
        let anchors: [Date] = [at(day, "09:00"), at(day, "12:00"), at(day, "18:30")]
        let rows: [TimelineRow] = [
            TimelineRow(time: "08:10", lane: "位置", text: "朝"),
            TimelineRow(time: "09:00", lane: "決済", text: "始まりと同じ分"),
            TimelineRow(time: "11:59", lane: "LINE", text: "昼の前"),
            TimelineRow(time: "13:00", lane: "予定", text: "昼のあと"),
            TimelineRow(time: "23:00", lane: "天気", text: "夜"),
        ]
        let slots = OneTimeline.slots(anchors: anchors, rows: rows, day: day, calendar: cal)
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots[0].map(\.text), ["朝"])
        XCTAssertEqual(slots[1].map(\.text), ["始まりと同じ分", "昼の前"])
        XCTAssertEqual(slots[2].map(\.text), ["昼のあと"])
        XCTAssertEqual(slots[3].map(\.text), ["夜"])
        // 会話が無い日は、全部を 0 番に
        XCTAssertEqual(OneTimeline.slots(anchors: [], rows: rows, day: day, calendar: cal)[0].count, 5)
        // 並んでいない始まりでも、行の時刻以前でいちばん遅いものの後ろに
        let unordered = OneTimeline.slots(anchors: [anchors[2], anchors[0]], rows: [rows[3]], day: day, calendar: cal)
        XCTAssertEqual(unordered[2].map(\.text), ["昼のあと"])
    }

    func testDetailAndLabels() {
        var pay = TimelineRow(time: "08:05", lane: "決済", text: "見本のパン屋")
        pay.amount = 1480
        XCTAssertEqual(OneTimeline.detail(pay), "\(1480.formatted())円")
        var stay = TimelineRow(time: "12:10", end: "12:45", lane: "位置", text: "滞在")
        stay.place = "見本の駅"
        XCTAssertEqual(OneTimeline.detail(stay), "見本の駅")
        XCTAssertEqual(OneTimeline.timeLabel(stay), "12:10〜12:45")
        stay.text = "見本の駅に滞在"
        XCTAssertNil(OneTimeline.detail(stay), "文に場所が入っていれば添えない")
        XCTAssertEqual(OneTimeline.laneIcon("注文"), "shippingbox")
        XCTAssertEqual(OneTimeline.laneIcon("知らない"), "circle")
    }

    func testRecentDays() {
        let cal = tokyoCalendar()
        let now = at("2026-11-14", "10:00")
        XCTAssertTrue(OneTimeline.isRecent("2026-11-14", now: now, calendar: cal))
        XCTAssertTrue(OneTimeline.isRecent("2026-11-01", now: now, calendar: cal))
        XCTAssertFalse(OneTimeline.isRecent("2026-10-31", now: now, calendar: cal))
        XCTAssertFalse(OneTimeline.isRecent("2026-11-15", now: now, calendar: cal))
        XCTAssertTrue(OneTimeline.isTodayOrYesterday("2026-11-13", now: now, calendar: cal))
        XCTAssertFalse(OneTimeline.isTodayOrYesterday("2026-11-12", now: now, calendar: cal))
    }

    // MARK: - 反映の見張り

    func testReflectionDecodeAndBehind() throws {
        let body = """
        {"available": true, "generated_at": "2026-11-14T08:00:00+09:00", "today": "2026-11-14",
         "destinations": ["取り込み", "年表", "朝のまとめ", "アプリへの配り", "ノート", "見張り先X"],
         "elements": [
           {"element": "LINE", "cells": ["2026-11-14", null, "2026-11-12", "きのう", "2026-11-05"]},
           {"element": "LINE", "cells": ["2026-11-01"]},
           {"element": "新しい要素", "cells": ["2026-11-10", "2026-11-10", null, null, null, "2026-11-09", "余り"]},
           {"cells": []}, 3
         ]}
        """
        let table = try XCTUnwrap(Reflection.decode(data(body)))
        XCTAssertEqual(table.elements.map(\.element), ["LINE", "新しい要素"])
        XCTAssertEqual(table.elements[0].cells.count, 6, "反映先の数にそろえる（足りない所は nil）")
        XCTAssertNil(table.elements[0].cells[3], "日でない値は nil")
        XCTAssertEqual(table.elements[1].cells.count, 6, "多すぎるマスは捨てる")
        XCTAssertEqual(Reflection.entryIndex(table), 0)
        let line = table.elements[0]
        XCTAssertEqual(Reflection.behind(line.cells[0], entry: line.cells[0], today: "2026-11-14", isEntry: true), 0)
        XCTAssertNil(Reflection.behind(line.cells[1], entry: line.cells[0], today: "2026-11-14", isEntry: false))
        XCTAssertEqual(Reflection.behind(line.cells[2], entry: line.cells[0], today: "2026-11-14", isEntry: false), 2)
        XCTAssertEqual(Reflection.behind(line.cells[4], entry: line.cells[0], today: "2026-11-14", isEntry: false), 9)
        // 取り込みが4日前なら、年表は取り込んだ日から数える
        let other = table.elements[1]
        XCTAssertEqual(Reflection.behind(other.cells[0], entry: other.cells[0], today: "2026-11-14", isEntry: true), 4)
        XCTAssertEqual(Reflection.behind(other.cells[1], entry: other.cells[0], today: "2026-11-14", isEntry: false), 0)
        XCTAssertEqual(Reflection.behind("2026-11-15", entry: nil, today: "2026-11-14", isEntry: true), 0, "先の日は 0")
        XCTAssertEqual(Reflection.cellText(nil), "—")
        XCTAssertEqual(Reflection.cellText(3), "3")
        // 2日以上の所: LINE の朝のまとめ(2)・ノート(9)、新しい要素の取り込み(4)・見張り先X(1 は数えない)
        XCTAssertEqual(Reflection.lateCount(table, today: "2026-11-14"), 3)
    }

    func testReflectionRefusesEmpty() {
        XCTAssertNil(Reflection.decode(data("{\"available\": false}")))
        XCTAssertNil(Reflection.decode(data("{\"destinations\": [], \"elements\": []}")))
        XCTAssertNil(Reflection.decode(data("x")))
    }

    // MARK: - PayPay の写真

    func testPayShotDecode() throws {
        let body = """
        {"rows": [
          {"time": "2026-11-14T12:34:00+09:00", "day": "2026-11-14", "shop": "見本の弁当屋", "amount": 680, "method": "PayPay残高"},
          {"time": null, "day": "2026-11-13", "shop": "見本のコンビニ", "amount": 248, "method": ""},
          {"time": "2026-11-12T10:00:00+09:00", "day": "2026-11-14", "shop": "日と時刻が違う", "amount": 100, "method": ""},
          {"time": null, "day": "11/14", "shop": "日の形が変", "amount": 100, "method": ""},
          {"time": null, "day": "2026-11-14", "shop": "金額が0", "amount": 0, "method": ""},
          {"time": null, "day": "2026-11-14", "shop": 5, "amount": 300, "method": ""}
        ]}
        """
        let rows = try XCTUnwrap(PayShots.decode(data(body)))
        XCTAssertEqual(rows.map(\.amount), [680, 248, 100, 300])
        XCTAssertEqual(rows[0].time, "2026-11-14T12:34:00+09:00")
        XCTAssertNil(rows[2].time, "日と合わない時刻は落とす（行は残す）")
        XCTAssertEqual(rows[3].shop, "", "店の名前の型が違えば空")
        XCTAssertNil(PayShots.decode(data("{\"error\": \"x\"}")))
        XCTAssertEqual(PayShots.decode(data("{\"rows\": []}"))?.count, 0)
    }

    func testPayShotKnownAndMerged() {
        let cal = tokyoCalendar()
        let row = PayShotRow(day: "2026-11-14", shop: "見本の弁当屋", amount: 680)
        let payments: [Payment] = [
            Payment(id: "p1", time: at("2026-11-14", "12:30"), amount: 680, shop: "べつの名前"),
            Payment(id: "p2", time: at("2026-11-13", "12:30"), amount: 248, shop: "見本"),
        ]
        XCTAssertTrue(PayShots.isKnown(row, payments: payments, sent: [], calendar: cal), "同じ日・同じ金額はもうある")
        let other = PayShotRow(day: "2026-11-14", shop: "見本のコンビニ", amount: 248)
        XCTAssertFalse(PayShots.isKnown(other, payments: payments, sent: [], calendar: cal), "日が違えば新しい")
        XCTAssertTrue(PayShots.isKnown(other, payments: [], sent: [PayShots.knownKey(day: "2026-11-14", amount: 248)], calendar: cal),
                      "前に送った行ももうある")
        // 何枚かの写真に同じ支払いが写っても1行
        let again = PayShotRow(day: "2026-11-14", shop: "見本の弁当屋", amount: 680)
        let merged = PayShots.merged([row], adding: [again, other])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].id, row.id)
    }

    func testPayShotBodyAndAmount() throws {
        var row = PayShotRow(time: "2026-11-14T12:34:00+09:00", day: "2026-11-14", shop: " 見本の弁当屋 ", amount: 680, method: "残高")
        let body = try XCTUnwrap(PayShots.body([row]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let rows = try XCTUnwrap(obj["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["shop"] as? String, "見本の弁当屋")
        XCTAssertEqual(rows[0]["amount"] as? Int, 680)
        XCTAssertNil(rows[0]["id"], "端末の中の id は送らない")
        XCTAssertNil(PayShots.body([]))
        row.amount = 0
        XCTAssertNil(PayShots.body([row]))
        row.amount = 100
        row.shop = String(repeating: "店", count: 41)
        XCTAssertNil(PayShots.body([row]))
        row.shop = "見本"
        row.time = "2026-11-13T12:00:00+09:00"
        XCTAssertNil(PayShots.body([row]), "日と合わない時刻は送らない")
        XCTAssertEqual(PayShots.parseAmount("1,200円"), 1200)
        XCTAssertEqual(PayShots.parseAmount("１２００"), 1200)
        XCTAssertNil(PayShots.parseAmount("0"))
        XCTAssertNil(PayShots.parseAmount("12345678"))
        XCTAssertNil(PayShots.parseAmount("円"))
    }

    // MARK: - 位置を当日のうちに

    func testLiveStaysFromPoints() {
        let day = "2026-11-14"
        let points: [LocationExport.Point] = [
            LocationExport.Point(time: at(day, "08:00"), latitude: 35.0, longitude: 139.0, accuracy: 30, name: "見本の家"),
            LocationExport.Point(time: at(day, "08:05"), latitude: 35.1, longitude: 139.1, accuracy: 30),
            LocationExport.Point(time: at(day, "09:00"), latitude: 35.2, longitude: 139.2, accuracy: 30),
        ]
        let stays = LiveStays.fromPoints(points)
        XCTAssertEqual(stays.count, 2, "次の点まで10分より短い点は移動の途中")
        XCTAssertEqual(stays[0].start, at(day, "08:05"))
        XCTAssertEqual(stays[0].end, at(day, "09:00"))
        XCTAssertNil(stays[1].end, "最後の点は今の滞在")
    }

    func testLiveStaysQueueAndSent() {
        let day = "2026-11-14"
        let now = at(day, "12:00")
        var open = LiveStay(start: at(day, "11:00"), lat: 35, lon: 139, name: "見本の店", kind: "shop")
        let done = LiveStay(start: at(day, "08:00"), end: at(day, "10:30"), lat: 35, lon: 139)
        var state = LiveStays.pending([open, done], state: LiveStayState())
        XCTAssertEqual(state.queue.count, 2)
        XCTAssertEqual(state.queue[0].start, done.start, "古い順")
        XCTAssertTrue(LiveStays.isDue(state, now: now))
        state.lastTried = now
        XCTAssertFalse(LiveStays.isDue(state, now: now.addingTimeInterval(600)), "15分に1回まで")
        XCTAssertTrue(LiveStays.isDue(state, now: now.addingTimeInterval(900)))
        state = LiveStays.sentAll(state, state.queue, now: now)
        XCTAssertTrue(state.queue.isEmpty)
        XCTAssertFalse(LiveStays.isDue(state, now: now.addingTimeInterval(3600)), "ためたものが無ければ送らない")
        // 同じものは、もうためない。今の滞在が閉じたら、同じ始まりのまま送り直す
        XCTAssertTrue(LiveStays.pending([open, done], state: state).queue.isEmpty)
        open.end = at(day, "12:10")
        let changed = LiveStays.pending([open, done], state: state)
        XCTAssertEqual(changed.queue.count, 1)
        XCTAssertEqual(changed.queue[0].end, at(day, "12:10"))
        // 送っているあいだに変わったものは残す
        var newer = open
        newer.end = at(day, "12:20")
        let racing = LiveStays.pending([newer], state: changed)
        let after = LiveStays.sentAll(racing, changed.queue, now: now)
        XCTAssertEqual(after.queue.count, 1)
        XCTAssertEqual(after.queue[0].end, at(day, "12:20"))
        // 古い印は消す
        let later = LiveStays.sentAll(after, [], now: now.addingTimeInterval(5 * 86400))
        XCTAssertTrue(later.sent.isEmpty)
    }

    func testLiveStaysBody() throws {
        let cal = tokyoCalendar()
        let day = "2026-11-14"
        let stays: [LiveStay] = [
            LiveStay(start: at(day, "11:00"), lat: 35.5, lon: 139.5, name: "見本の店", kind: "shop"),
            LiveStay(start: at(day, "08:00"), end: at(day, "10:30"), lat: 35, lon: 139, name: nil, kind: "park"),
            LiveStay(start: at(day, "07:00"), lat: 95, lon: 139),
        ]
        let body = try XCTUnwrap(LiveStays.body(stays, calendar: cal))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let list = try XCTUnwrap(obj["stays"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2, "座標のおかしな滞在は送らない")
        XCTAssertEqual(list[0]["start"] as? String, "2026-11-14T11:00:00+09:00")
        XCTAssertTrue(list[0]["end"] is NSNull, "今の滞在の終わりは null")
        XCTAssertEqual(list[0]["kind"] as? String, "shop")
        XCTAssertTrue(list[1]["kind"] is NSNull, "知らない種類は null")
        XCTAssertTrue(list[1]["name"] is NSNull)
        XCTAssertNil(LiveStays.body([]))
    }

    // MARK: - 台帳の提案（32）

    func testProfileKind() {
        XCTAssertEqual(ProposalRules.kindLabel("profile"), "台帳")
        let p = Proposal(id: "pf-1", kind: "profile", title: "台帳の候補（見本）", body: "",
                         evidence: [Proposal.Evidence(text: "見本の根拠", source: "conversation")],
                         action: Proposal.Action(type: "none"))
        XCTAssertNotNil(ProposalRules.actionLine(p))
    }
}

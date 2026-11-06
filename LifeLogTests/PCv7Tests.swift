import UserNotifications
import XCTest
@testable import LifeLog

/// GET /edits の答えの形（決まりの見本を読むため）
private struct PCEditsTestReply: Decodable {
    let edits: [PCEdit]
}

/// 家の PC（版 7）とのやり取りの決まり（docs/v7-plan.md）を確かめる（2026-11-07）。
/// 日時の書き方・様子に会話の中身や名前が入らないこと・PC の直しの当て方の判定・通知の宛先の16進など。
@MainActor
final class PCv7Tests: XCTestCase {
    /// 2026-11-07T06:58:25.123Z
    private let t = Date(timeIntervalSince1970: 1_794_034_705.123)

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 日時の書き方

    func testDateIsUTCWithMilliseconds() {
        XCTAssertEqual(PCJSON.string(t), "2026-11-07T06:58:25.123Z")
        // ミリ秒より細かいところは四捨五入する
        XCTAssertEqual(PCJSON.string(t.addingTimeInterval(0.0006)), "2026-11-07T06:58:25.124Z")
        XCTAssertEqual(PCJSON.string(Date(timeIntervalSince1970: 1_794_034_705)), "2026-11-07T06:58:25.000Z")
    }

    func testReadsDatesWithOffsetsAndWithoutMilliseconds() throws {
        let z = try XCTUnwrap(PCJSON.date("2026-11-07T06:58:25.123Z"))
        XCTAssertEqual(z.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 0.0005)
        let tokyo = try XCTUnwrap(PCJSON.date("2026-11-07T15:58:25.123+09:00"))
        XCTAssertEqual(tokyo.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 0.0005)
        let whole = try XCTUnwrap(PCJSON.date("2026-11-07T06:58:25Z"))
        XCTAssertEqual(whole.timeIntervalSince1970, 1_794_034_705, accuracy: 0.0005)
        let micro = try XCTUnwrap(PCJSON.date("2026-11-07T06:58:25.123456+00:00"))
        XCTAssertEqual(micro.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(PCJSON.date("11/7 15:58"))
    }

    func testSameTimeWithinOneMillisecond() throws {
        // 記録の時刻はミリ秒より細かいことがある。書いて PC から戻ってきた時刻と同じとみなす
        let line = t.addingTimeInterval(0.00049)
        let echoed = try XCTUnwrap(PCJSON.date(PCJSON.string(line)))
        XCTAssertTrue(PCJSON.sameTime(line, echoed))
        XCTAssertTrue(PCJSON.sameTime(t, t.addingTimeInterval(0.0009)))
        XCTAssertFalse(PCJSON.sameTime(t, t.addingTimeInterval(0.002)))
    }

    func testDayString() {
        XCTAssertEqual(PCJSON.dayString(at(7, 3, 30)), "2026-11-07")
        XCTAssertEqual(PCJSON.dayString(at(6, 23, 59)), "2026-11-06")
    }

    func testRecordsUseTheDateFormat() throws {
        var line = ConversationLog.Line(time: t, speaker: "自分", text: "テストの行")
        line.audio = "20261107-155800.m4a"
        line.offset = 12.5
        var c = ConversationLog.Conversation(start: t, end: t.addingTimeInterval(60), docIndex: 1, lines: [line])
        c.closed = true
        let day = ConversationLog.SyncDay(conversations: [c], removed: [], summaryWritten: false, summary: nil)
        let data = try PCJSON.encoder().encode(day)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"2026-11-07T06:58:25.123Z\""))
        XCTAssertTrue(text.contains("\"2026-11-07T06:59:25.123Z\""))
        let back = try PCJSON.decoder().decode(ConversationLog.SyncDay.self, from: data)
        let first = try XCTUnwrap(back.conversations.first?.lines.first)
        XCTAssertEqual(first.text, "テストの行")
        XCTAssertEqual(first.audio, "20261107-155800.m4a")
        XCTAssertTrue(PCJSON.sameTime(t, first.time))
        // 同じ中身なら同じ JSON（送り直すかの見比べに使う）
        let again = try PCJSON.encoder().encode(day)
        XCTAssertEqual(again, data)
    }

    // MARK: - 様子に会話の中身や名前を入れない

    private let device = PCDiag.Device(deviceID: "test-device", device: "iPhone", model: "iPhone17,1", os: "26.1",
                                       build: 154, install: "testflight")

    func testDiagLeavesOutNamesAndEmail() throws {
        let rows = [
            DiagnosticItem(section: "最近のエラー", label: "11/7 10:00",
                           value: "田中さんの行を直せませんでした（ono@example.com）", ok: false),
            DiagnosticItem(section: "状態", label: "録音", value: "録音中", ok: nil),
        ]
        let crashes = [CrashWatch.Event(at: t, kind: "落ちた", detail: "例外 EXC_BAD_ACCESS（佐藤花子）")]
        let body = PCDiag.payload(device: device, sentAt: t, reason: "test", rows: rows, names: ["田中", "佐藤花子"],
                                  crashes: crashes, metrickit: [], tally: ["2026-11-07": ["jobs.sent": 3]],
                                  state: ["phoneRecording": true, "queue": 2], push: nil)
        let data = try XCTUnwrap(PCDiag.encode(body))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("田中"))
        XCTAssertFalse(text.contains("佐藤花子"))
        XCTAssertFalse(text.contains("example.com"))
        XCTAssertTrue(text.contains("（名前）"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sentAt"] as? String, "2026-11-07T06:58:25.123Z")
        XCTAssertEqual(json["build"] as? Int, 154)
        XCTAssertEqual(json["install"] as? String, "testflight")
        XCTAssertNil(json["push"])
        let list = try XCTUnwrap(json["rows"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["group"] as? String, "最近のエラー")
        XCTAssertEqual(list[0]["ok"] as? Bool, false)
        // 分からないときは null
        XCTAssertTrue(list[1]["ok"] is NSNull)
        let crash = try XCTUnwrap((json["crashes"] as? [[String: Any]])?.first)
        XCTAssertEqual(crash["kind"] as? String, "crash")
        XCTAssertEqual(crash["at"] as? String, "2026-11-07T06:58:25.123Z")
        XCTAssertEqual((json["tally"] as? [String: [String: Int]])?["2026-11-07"]?["jobs.sent"], 3)
        XCTAssertEqual((json["state"] as? [String: Any])?["queue"] as? Int, 2)
    }

    func testScrubReplacesLongNamesFirst() {
        XCTAssertEqual(PCDiag.scrub("田中太郎さんと田中さん", names: ["田中", "田中太郎"]), "（名前）さんと（名前）さん")
        // 1文字の名前は消さない（ほかの言葉まで消えるので）
        XCTAssertEqual(PCDiag.scrub("録音中", names: ["録"]), "録音中")
        XCTAssertEqual(PCDiag.scrub("連絡は a.b+c@mail.example.jp まで", names: []), "連絡は （メールアドレス） まで")
    }

    func testCrashKinds() {
        XCTAssertEqual(PCDiag.crashKind("落ちた"), "crash")
        XCTAssertEqual(PCDiag.crashKind("固まった"), "hang")
        XCTAssertEqual(PCDiag.crashKind("書き込みが多すぎた"), "diskWrite")
        XCTAssertEqual(PCDiag.crashKind("CPU を使いすぎた"), "cpu")
        XCTAssertEqual(PCDiag.crashKind("ほか"), "other")
    }

    func testMetricKitIsCappedAndBrokenOnesAreDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcv7-metrickit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("1.json")
        let broken = dir.appendingPathComponent("2.json")
        let large = dir.appendingPathComponent("3.json")
        try Data(#"{"crashDiagnostics":[]}"#.utf8).write(to: small)
        try Data("not json".utf8).write(to: broken)
        try Data(("{\"x\":\"" + String(repeating: "a", count: 3000) + "\"}").utf8).write(to: large)
        let picked = PCDiag.metricKit(from: [small, broken, large], budget: 1000)
        XCTAssertEqual(picked.files, [small])
        XCTAssertEqual(picked.objects.count, 1)
        // 読めないものと、1つで大きすぎるものは捨てる（送れたものは送ったあとに消す）
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: large.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: small.path))
    }

    func testTallyOfTodayAndYesterday() {
        Tally.reset()
        defer { Tally.reset() }
        let now = at(7, 12)
        Tally.add("jobs.sent", 3, at: now)
        Tally.add("jobs.sent", 2, at: now.addingTimeInterval(-86400))
        Tally.add("jobs.sent", 9, at: now.addingTimeInterval(-3 * 86400))
        let days = Tally.days(2, now: now)
        XCTAssertEqual(days["2026-11-07"]?["jobs.sent"], 3)
        XCTAssertEqual(days["2026-11-06"]?["jobs.sent"], 2)
        XCTAssertNil(days["2026-11-04"])
    }

    func testDueTimes() {
        XCTAssertTrue(PCDiag.isDue(lastSent: nil, now: t))
        XCTAssertTrue(PCDiag.isDue(lastSent: t.addingTimeInterval(-3700), now: t))
        XCTAssertFalse(PCDiag.isDue(lastSent: t.addingTimeInterval(-600), now: t))
        XCTAssertTrue(PCRecords.isDue(lastTried: .distantPast, now: t))
        XCTAssertFalse(PCRecords.isDue(lastTried: t.addingTimeInterval(-300), now: t))
    }

    // MARK: - 夜の処理

    func testNightKey() {
        XCTAssertEqual(PCDiag.nightKey(for: at(7, 3, 30)), "2026-11-06")
        XCTAssertEqual(PCDiag.nightKey(for: at(6, 23, 30)), "2026-11-06")
        XCTAssertEqual(PCDiag.nightKey(for: at(7, 18)), "2026-11-07")
        // 昼に済んだ（手で動かした）ものは、どの夜の分にもしない
        XCTAssertNil(PCDiag.nightKey(for: at(7, 13)))
        XCTAssertFalse(PCDiag.nightlyPending(doneFor: "2026-11-06", now: at(7, 3, 30)))
        XCTAssertTrue(PCDiag.nightlyPending(doneFor: "2026-11-05", now: at(7, 3, 30)))
        XCTAssertTrue(PCDiag.nightlyPending(doneFor: nil, now: at(7, 3, 30)))
        XCTAssertFalse(PCDiag.nightlyPending(doneFor: "2026-11-06", now: at(7, 15)))
    }

    // MARK: - 家の PC の版が古い、の知らせ

    func testOldVersionNoticeIsWeekly() throws {
        let name = "PCv7Tests.version"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(PCVersionNotice.shouldWarn(pc: 6, app: 7, now: t, defaults: defaults))
        PCVersionNotice.noteWarned(pc: 6, app: 7, now: t, defaults: defaults)
        // 前は12時間ごとに出ていた。同じ組み合わせなら7日は出さない
        XCTAssertFalse(PCVersionNotice.shouldWarn(pc: 6, app: 7, now: t.addingTimeInterval(12 * 3600), defaults: defaults))
        XCTAssertTrue(PCVersionNotice.shouldWarn(pc: 6, app: 7, now: t.addingTimeInterval(8 * 86400), defaults: defaults))
        // 組み合わせが変わったら出す
        XCTAssertTrue(PCVersionNotice.shouldWarn(pc: 5, app: 7, now: t.addingTimeInterval(3600), defaults: defaults))
        XCTAssertFalse(PCVersionNotice.shouldWarn(pc: 7, app: 7, now: t, defaults: defaults))
        XCTAssertEqual(HomePC.expectedVersion, 7)
    }

    // MARK: - 見えない通知

    func testTokenIsLowercaseHex() {
        XCTAssertEqual(PushWake.hex(Data([0x00, 0x1f, 0xab, 0xff])), "001fabff")
        XCTAssertEqual(PushWake.hex(Data()), "")
    }

    func testPushKind() {
        let wake: [AnyHashable: Any] = ["aps": ["content-available": 1], "lifelog": ["kind": "wake"]]
        XCTAssertEqual(PushWake.kind(from: wake), .wake)
        let job: [AnyHashable: Any] = ["aps": ["content-available": 1],
                                       "lifelog": ["kind": "job", "job": "20261107-155800-w.m4a"]]
        XCTAssertEqual(PushWake.kind(from: job), .job)
        let nightly: [AnyHashable: Any] = ["lifelog": ["kind": "nightly"]]
        XCTAssertEqual(PushWake.kind(from: nightly), .nightly)
        let none: [AnyHashable: Any] = ["aps": ["content-available": 1]]
        XCTAssertNil(PushWake.kind(from: none))
        let unknown: [AnyHashable: Any] = ["lifelog": ["kind": "unknown"]]
        XCTAssertNil(PushWake.kind(from: unknown))
    }

    private func profile(_ entitlements: [String: Any], team: String = "ABCDE12345") throws -> Data {
        let plist: [String: Any] = ["Entitlements": entitlements, "TeamIdentifier": [team], "ExpirationDate": t]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // 本物は署名（CMS）の中に plist が入っている
        return Data([0x30, 0x82, 0x01, 0x00]) + xml + Data([0x00, 0x00])
    }

    func testPushEnvironmentTeamAndInstall() throws {
        let development = try profile(["aps-environment": "development"])
        let production = try profile(["aps-environment": "production"])
        let plain = try profile([:], team: "ZZZZZ99999")
        XCTAssertEqual(PushWake.environment(profile: nil), "production")
        XCTAssertEqual(PushWake.environment(profile: development), "development")
        XCTAssertEqual(PushWake.environment(profile: production), "production")
        XCTAssertEqual(PushWake.environment(profile: plain), "development")
        XCTAssertEqual(PushWake.team(prefix: "ABCDE12345.", profile: nil), "ABCDE12345")
        XCTAssertEqual(PushWake.team(prefix: "", profile: plain), "ZZZZZ99999")
        XCTAssertNil(PushWake.team(prefix: "$(AppIdentifierPrefix)", profile: nil))
        XCTAssertEqual(PushWake.installKind(profile: nil, simulator: false), "testflight")
        XCTAssertEqual(PushWake.installKind(profile: plain, simulator: false), "sideload")
        XCTAssertEqual(PushWake.installKind(profile: nil, simulator: true), "other")
    }

    func testStopNoticesAreTimeSensitive() {
        XCTAssertEqual(UrgentNotice.level(for: "phone-stopped"), .timeSensitive)
        XCTAssertEqual(UrgentNotice.level(for: "watch-silent"), .timeSensitive)
        XCTAssertEqual(UrgentNotice.level(for: "suggestions"), .active)
    }

    func testWaitStopsWaitingAfterTheTime() async {
        let quick = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(10))
            return
        }
        let quickDone = await PushWake.wait(quick, upTo: 5)
        XCTAssertTrue(quickDone)
        let slow = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(5))
            return
        }
        let slowDone = await PushWake.wait(slow, upTo: 0.1)
        XCTAssertFalse(slowDone)
        slow.cancel()
    }

    // MARK: - PC の直しの当て方

    private var people: [SpeakerLabeler.Person] {
        [SpeakerLabeler.Person(id: SpeakerLabeler.selfID, name: nil, context: nil),
         SpeakerLabeler.Person(id: "3", name: "田中", context: nil),
         SpeakerLabeler.Person(id: "7", name: "佐藤", context: nil),
         SpeakerLabeler.Person(id: "8", name: "佐藤", context: nil),
         SpeakerLabeler.Person(id: "12", name: nil, context: nil)]
    }

    private func makeLine(_ text: String, speaker: String?, id: String?) -> ConversationLog.Line {
        var line = ConversationLog.Line(time: t, speaker: speaker, text: text)
        line.speakerID = id
        line.audio = "20261107-155800.m4a"
        return line
    }

    private func value(_ text: String?) -> Any {
        if let text { return text }
        return NSNull()
    }

    private func makeEdit(kind: String, base: (text: String, speaker: String?, speakerID: String?),
                          text: String? = nil, speaker: String? = nil, speakerID: String? = nil) throws -> PCEdit {
        var baseJSON: [String: Any] = ["text": base.text]
        baseJSON["speaker"] = value(base.speaker)
        baseJSON["speakerID"] = value(base.speakerID)
        var json: [String: Any] = ["id": 12, "day": "2026-11-07", "time": "2026-11-07T06:58:25.123Z", "kind": kind]
        json["base"] = baseJSON
        json["text"] = value(text)
        json["speaker"] = value(speaker)
        json["speakerID"] = value(speakerID)
        json["created"] = "2026-11-07T07:10:00.000Z"
        let data = try JSONSerialization.data(withJSONObject: json)
        return try PCJSON.decoder().decode(PCEdit.self, from: data)
    }

    func testDecodesTheEditOfThePlan() throws {
        let json = """
        {"edits": [{
          "id": 12, "day": "2026-11-07", "time": "2026-11-07T06:58:25.123Z", "kind": "text",
          "base": {"text": "直す前の文", "speaker": "田中", "speakerID": "p3"},
          "text": "直したあとの文", "speaker": null, "speakerID": null,
          "created": "2026-11-07T07:10:00.000Z"
        }]}
        """
        let reply = try PCJSON.decoder().decode(PCEditsTestReply.self, from: Data(json.utf8))
        let edit = try XCTUnwrap(reply.edits.first)
        XCTAssertEqual(edit.id, 12)
        XCTAssertEqual(edit.kind, "text")
        XCTAssertEqual(edit.base.speaker, "田中")
        XCTAssertEqual(edit.text, "直したあとの文")
        XCTAssertNil(edit.speaker)
        XCTAssertTrue(PCJSON.sameTime(t, edit.time))
    }

    func testTextEditIsAppliedOnlyWhenTheLineIsUnchanged() throws {
        let edit = try makeEdit(kind: "text", base: ("直す前の文", "田中", "3"), text: "直したあとの文")
        let same = makeLine("直す前の文", speaker: "田中", id: "3")
        XCTAssertEqual(PCEdits.plan(edit, line: same, people: people), .text("直したあとの文"))
        // iPhone で先に文が変わっていた
        let changed = makeLine("iPhone で直した文", speaker: "田中", id: "3")
        XCTAssertEqual(PCEdits.plan(edit, line: changed, people: people), .skip(PCEdits.changedFirst))
        // 話し手が先に変わっていた
        let other = makeLine("直す前の文", speaker: "佐藤", id: "7")
        XCTAssertEqual(PCEdits.plan(edit, line: other, people: people), .skip(PCEdits.changedFirst))
        // もう同じ文になっている（前に当てて、PC に伝えられなかったときなど）
        let done = makeLine("直したあとの文", speaker: "田中", id: "3")
        XCTAssertEqual(PCEdits.plan(edit, line: done, people: people), .already)
        // 行が無い
        XCTAssertEqual(PCEdits.plan(edit, line: nil, people: people), .skip(PCEdits.lineMissing))
        // PC が番号を書いていなければ、名前だけで見る
        let byName = try makeEdit(kind: "text", base: ("直す前の文", "田中", nil), text: "直したあとの文")
        XCTAssertEqual(PCEdits.plan(byName, line: same, people: people), .text("直したあとの文"))
        // 空の文は当てない。改行は空白にする（記録の1行は1行のまま）
        let empty = try makeEdit(kind: "text", base: ("直す前の文", "田中", "3"), text: "  \n ")
        XCTAssertEqual(PCEdits.plan(empty, line: same, people: people), .fail("直したあとの文が空です"))
        let twoLines = try makeEdit(kind: "text", base: ("直す前の文", "田中", "3"), text: "一行目\n二行目")
        XCTAssertEqual(PCEdits.plan(twoLines, line: same, people: people), .text("一行目 二行目"))
    }

    func testSpeakerEditUsesOnlyRegisteredPeople() throws {
        let original = makeLine("こんにちは", speaker: "人物12", id: "12")
        func speakerEdit(_ name: String?, _ id: String? = nil) throws -> PCEdit {
            try makeEdit(kind: "speaker", base: ("こんにちは", "人物12", "12"), speaker: name, speakerID: id)
        }
        XCTAssertEqual(PCEdits.plan(try speakerEdit("田中"), line: original, people: people), .speaker("3"))
        XCTAssertEqual(PCEdits.plan(try speakerEdit("自分"), line: original, people: people), .speaker(SpeakerLabeler.selfID))
        // 登録に無い名前は当てない（PC からは人を作らない）
        XCTAssertEqual(PCEdits.plan(try speakerEdit("鈴木"), line: original, people: people), .skip(PCEdits.unknownPerson))
        XCTAssertEqual(PCEdits.plan(try speakerEdit("人物99"), line: original, people: people), .skip(PCEdits.unknownPerson))
        // 同じ名前の人が2人いれば、番号で決まるときだけ（まとめない）
        XCTAssertEqual(PCEdits.plan(try speakerEdit("佐藤"), line: original, people: people), .skip(PCEdits.samePeople))
        XCTAssertEqual(PCEdits.plan(try speakerEdit("佐藤", "8"), line: original, people: people), .speaker("8"))
        // 自分がまだいなければ当てない（作らない）
        let noSelf = people.filter { !$0.isSelf }
        XCTAssertEqual(PCEdits.plan(try speakerEdit("自分"), line: original, people: noSelf), .skip(PCEdits.noSelf))
        // iPhone で先に話し手が変わっていた
        let changed = makeLine("こんにちは", speaker: "佐藤", id: "7")
        XCTAssertEqual(PCEdits.plan(try speakerEdit("田中"), line: changed, people: people), .skip(PCEdits.changedFirst))
        // もういる名前の無い「人物N」なら選べる
        let toUnnamed = try makeEdit(kind: "speaker", base: ("こんにちは", "佐藤", "7"), speaker: "人物12")
        XCTAssertEqual(PCEdits.plan(toUnnamed, line: changed, people: people), .speaker("12"))
        // もうその人になっている
        let done = makeLine("こんにちは", speaker: "田中", id: "3")
        XCTAssertEqual(PCEdits.plan(try speakerEdit("田中"), line: done, people: people), .already)
        XCTAssertEqual(PCEdits.plan(try speakerEdit(nil), line: original, people: people), .fail("話し手の名前がありません"))
        // 知らない種類
        let merge = try makeEdit(kind: "merge", base: ("こんにちは", "人物12", "12"))
        XCTAssertEqual(PCEdits.plan(merge, line: original, people: people), .fail("知らない直しの種類です"))
    }

    func testFindsTheLineWithinOneMillisecond() {
        var first = makeLine("一つ目", speaker: "自分", id: SpeakerLabeler.selfID)
        first.offset = 1
        var other = ConversationLog.Line(time: t.addingTimeInterval(2), speaker: "田中", text: "別の音声")
        other.audio = "20261107-155800-w.m4a"
        var second = ConversationLog.Line(time: t.addingTimeInterval(4), speaker: "田中", text: "二つ目")
        second.audio = first.audio
        second.offset = 5
        let c = ConversationLog.Conversation(start: t, end: t.addingTimeInterval(4), docIndex: 1, lines: [first, other, second])
        let found = PCEdits.find(t.addingTimeInterval(0.0004), in: [c])
        XCTAssertEqual(found?.line.text, "一つ目")
        // 声を切り出す終わりは、同じ音声の次の行（アプリで話し手を直すときと同じ）
        XCTAssertEqual(found?.next?.text, "二つ目")
        XCTAssertNil(PCEdits.find(t.addingTimeInterval(0.002), in: [c]))
    }

    func testSameTimeLinesAreNotEdited() {
        // 同じ時刻（1ms 未満の差）の行が2つあると、どちらを直すか決められないので当てない（PC も直せないようにしてある）
        let a = makeLine("一つ目", speaker: "自分", id: SpeakerLabeler.selfID)
        var b = ConversationLog.Line(time: t.addingTimeInterval(0.0002), speaker: "田中", text: "同じ時刻の別の行")
        b.audio = "20261107-155800-w.m4a"
        let c = ConversationLog.Conversation(start: t, end: t, docIndex: 1, lines: [a, b])
        XCTAssertEqual(PCEdits.matches(t, in: [c]).count, 2)
        XCTAssertNil(PCEdits.find(t, in: [c]))
    }

    func testDayNameOfEdits() {
        XCTAssertTrue(PCEdits.isDayName("2026-11-07"))
        XCTAssertFalse(PCEdits.isDayName("../people"))
        XCTAssertFalse(PCEdits.isDayName("2026-11-7"))
        XCTAssertFalse(PCEdits.isDayName("2026-11-07/x"))
        XCTAssertFalse(PCEdits.isDayName("２０２６-11-07"))
    }

    func testNextAfterStopsBeforeOpenEdits() {
        XCTAssertEqual(PCEdits.nextAfter(current: 10, fetched: [11, 12, 13], open: []), 13)
        XCTAssertEqual(PCEdits.nextAfter(current: 10, fetched: [11, 12, 13], open: [12, 13]), 11)
        XCTAssertEqual(PCEdits.nextAfter(current: 10, fetched: [], open: []), 10)
        // PC に伝えられなかった前の番号があれば、そこまで戻す
        XCTAssertEqual(PCEdits.nextAfter(current: 20, fetched: [15, 21], open: [15]), 14)
    }

    func testAckWritesNullReason() throws {
        let applied = try JSONEncoder().encode(PCEditResult.applied(12))
        XCTAssertTrue(String(decoding: applied, as: UTF8.self).contains("\"reason\":null"))
        let skipped = try JSONEncoder().encode(PCEditResult.skipped(13, PCEdits.changedFirst))
        let text = String(decoding: skipped, as: UTF8.self)
        XCTAssertTrue(text.contains("\"status\":\"skipped\""))
        XCTAssertEqual(try JSONDecoder().decode(PCEditResult.self, from: skipped), .skipped(13, PCEdits.changedFirst))
    }

    func testEditStoreRetriesThreeTimes() {
        var store = PCEditStore()
        let first = store.retry(5, reason: "通信")
        let second = store.retry(5, reason: "通信")
        let third = store.retry(5, reason: "通信")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(third, PCEditResult.failed(5, "通信"))
    }

    // MARK: - 記録を送る日

    func testDaysToSend() {
        let days = ["2026-11-07", "2026-11-06", "2026-09-01", "2026-08-01"]
        let stamps: [String: Double] = ["2026-11-07": 3, "2026-11-06": 2, "2026-09-01": 1, "2026-08-01": 1]
        // 初めて: 60日より前の日は送らない。新しい日から
        XCTAssertEqual(PCRecords.daysToSend(days: days, stamps: stamps, sent: [:], oldest: "2026-09-09"),
                       ["2026-11-07", "2026-11-06"])
        // 送ったあと: 変わった日だけ。前に送った古い日も、変われば送る
        let sent: [String: Double] = ["2026-11-07": 3, "2026-11-06": 1, "2026-08-01": 0.5]
        XCTAssertEqual(PCRecords.daysToSend(days: days, stamps: stamps, sent: sent, oldest: "2026-09-09"),
                       ["2026-11-06", "2026-08-01"])
        // PC の直しを当てた日を先に
        XCTAssertEqual(PCRecords.daysToSend(days: days, stamps: stamps, sent: sent, oldest: "2026-09-09", first: ["2026-08-01"]),
                       ["2026-08-01", "2026-11-06"])
        // 直しを当てた日は、いつも送る（60日より前でも）
        XCTAssertEqual(PCRecords.daysToSend(days: days, stamps: stamps, sent: sent, oldest: "2026-09-09",
                                            first: ["2026-08-01", "2026-09-01"]),
                       ["2026-09-01", "2026-08-01", "2026-11-06"])
    }

    func testRecordsLimitsAndSoonerRound() {
        // PC は 8MiB まで受け取る
        XCTAssertEqual(PCRecords.maxBytes, 8_388_608)
        // 直しを当てた日を送り直せていなければ、10分待たずに1分で次のやり取り
        XCTAssertFalse(PCRecords.isDue(lastTried: t.addingTimeInterval(-120), now: t))
        XCTAssertTrue(PCRecords.isDue(lastTried: t.addingTimeInterval(-120), now: t, soon: true))
        XCTAssertFalse(PCRecords.isDue(lastTried: t.addingTimeInterval(-30), now: t, soon: true))
        XCTAssertEqual(PCEdits.pageSize, 500)
    }

    func testRecordsHash() {
        XCTAssertEqual(PCRecords.hash(Data("a".utf8)), "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
    }
}

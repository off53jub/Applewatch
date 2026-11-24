import UserNotifications
import XCTest
@testable import LifeLog

/// s24（2026-11-24）: 溜めない。タスクの候補を 1 日 3 件に・問いと知らせの上限・今週は聞かないで・急ぎ・題の印。
/// 名前はすべて作り物（Aさん）。
@MainActor
final class S24Tests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    private func day(_ d: Int, hour: Int = 12, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour, minute: minute))!
    }

    private func cand(_ what: String, id: String? = nil, source: TaskBook.Source = .conversation, agreed: Bool? = nil,
                      weak: String? = nil, said: Date? = nil, state: TaskBook.State = .candidate) -> TaskBook.Item {
        var item = TaskBook.Item(what: what, said: said ?? day(20), source: source, state: state, work: true)
        if let id { item.id = id }
        item.agreed = agreed
        item.weakReason = weak
        item.updated = said ?? day(20)
        return item
    }

    // MARK: 本人の困りごと: たぶん違う

    func testWeakIsOnlyConversationAloneOrShort() {
        XCTAssertTrue(S24TaskRules.isWeak(cand("見積書を送る", agreed: false)))
        XCTAssertFalse(S24TaskRules.isWeak(cand("見積書を送る", agreed: true)))
        XCTAssertFalse(S24TaskRules.isWeak(cand("見積書を送る", agreed: nil)))
        XCTAssertTrue(S24TaskRules.isWeak(cand("見積書を送る", agreed: nil, weak: "notOwn")))
        // 両方が拾ったものは今まで通り
        XCTAssertFalse(S24TaskRules.isWeak(cand("見積書を送る", agreed: true, weak: "notOwn")))
        // 本人の印・議事録・写真から来たものは今まで通り
        for source in [TaskBook.Source.mark, .minutes, .photo, .manual, .summary] {
            XCTAssertFalse(S24TaskRules.isWeak(cand("見積書を送る", source: source, agreed: false)), source.rawValue)
        }
        // 候補でないものは畳まない
        XCTAssertFalse(S24TaskRules.isWeak(cand("見積書を送る", agreed: false, state: .open)))
    }

    func testOwnerCheckMatchesMothership() {
        XCTAssertEqual(S24TaskRules.ownerCheck(what: "Aさんに見積書を送る", selfSpokeNear: false), "notOwn")
        XCTAssertEqual(S24TaskRules.ownerCheck(what: "確認する", selfSpokeNear: true), "vague")
        XCTAssertEqual(S24TaskRules.ownerCheck(what: "送る", selfSpokeNear: true), "vague")
        XCTAssertNil(S24TaskRules.ownerCheck(what: "Aさんに見積書を送る", selfSpokeNear: true))
        let said = day(20, hour: 10)
        XCTAssertTrue(S24TaskRules.selfSpoke(near: said, selfTimes: [said.addingTimeInterval(-90)]))
        XCTAssertFalse(S24TaskRules.selfSpoke(near: said, selfTimes: [said.addingTimeInterval(-600)]))
        XCTAssertFalse(S24TaskRules.selfSpoke(near: said, selfTimes: []))
    }

    func testWeakClosesInTwoDaysAndCandidatesInThree() {
        let now = day(20)
        let weakOld = cand("片方だけ（古い）", agreed: false, said: day(17, hour: 11))
        let weakNew = cand("片方だけ（新しい）", agreed: false, said: day(19))
        let strongOld = cand("両方（古い）", agreed: true, said: day(17, hour: 11))
        let strongMid = cand("両方（2日前）", agreed: true, said: day(18, hour: 13))
        XCTAssertEqual(S24TaskRules.weakExpired([weakOld, weakNew, strongOld], now: now).map(\.what), ["片方だけ（古い）"])
        // 候補の残る日数は 7 → 3 日（仮）
        XCTAssertEqual(TaskBook.expired([weakNew, strongOld, strongMid], now: now).map(\.what), ["両方（古い）"])
        XCTAssertEqual(S24TaskRules.candidateDays, 3)
    }

    func testRejectReasonsAutoAreNotLearned() {
        XCTAssertTrue(TaskBook.RejectReason.expired.isAuto)
        XCTAssertTrue(TaskBook.RejectReason.expiredWeak.isAuto)
        XCTAssertFalse(TaskBook.RejectReason.bulk.isAuto)
        // 本人が選べる理由は変えない
        XCTAssertEqual(TaskBook.RejectReason.choices, [.machine, .finished, .notMine, .topic, .other])
        XCTAssertEqual(TaskScore.reasonLabel("expiredWeak"), "たぶん違うのまま（自動）")
    }

    func testWeakReasonIsOptionalInSavedFile() throws {
        let saved = #"[{"id":"x","what":"見積書を送る","said":0,"source":"conversation","state":"candidate","updated":0}]"#
        let items = try JSONDecoder().decode([TaskBook.Item].self, from: Data(saved.utf8))
        XCTAssertNil(items.first?.weakReason)
    }

    // MARK: 今日の候補（1 日 3 件）

    func testTodayPicksStayForTheDay() {
        let a = cand("一", id: "a"), b = cand("二", id: "b"), c = cand("三", id: "c"), d = cand("四", id: "d")
        let first = S24TaskRules.todayPicks(strong: [a, b, c, d], saved: nil, day: "2026-11-24")
        XCTAssertEqual(first.ids, ["a", "b", "c"])
        XCTAssertEqual(first.save, "2026-11-24|a,b,c")
        // 1 つ答えても、4 つめは今日は出てこない（1 日に見せるのは 3 件まで）
        let after = S24TaskRules.todayPicks(strong: [b, c, d], saved: first.save, day: "2026-11-24")
        XCTAssertEqual(after.ids, ["b", "c"])
        XCTAssertEqual(after.save, "2026-11-24|a,b,c")
        // 次の日は選び直す
        let next = S24TaskRules.todayPicks(strong: [b, c, d], saved: after.save, day: "2026-11-25")
        XCTAssertEqual(next.ids, ["b", "c", "d"])
        // 少ない日は少ないまま
        XCTAssertEqual(S24TaskRules.todayPicks(strong: [a], saved: nil, day: "2026-11-24").ids, ["a"])
    }

    func testSplitFoldsRestAndWeak() {
        let a = cand("一", id: "a", agreed: true), b = cand("二", id: "b"), w = cand("片方だけ", id: "w", agreed: false)
        let parts = S24TaskRules.split([a, b, w], today: ["b"])
        XCTAssertEqual(parts.today.map(\.id), ["b"])
        XCTAssertEqual(parts.rest.map(\.id), ["a"])
        XCTAssertEqual(parts.weak.map(\.id), ["w"])
        // たぶん違うは今日の候補に入らない
        XCTAssertEqual(S24TaskRules.split([w], today: ["w"]).today, [])
    }

    // MARK: 減6 夜の 1 通

    func testNightSlotAndNotice() {
        let before = S24TaskRules.nightSlot(after: day(24, hour: 15), calendar: cal)
        XCTAssertEqual(before, day(24, hour: 20, minute: 30))
        let after = S24TaskRules.nightSlot(after: day(24, hour: 21), calendar: cal)
        XCTAssertEqual(after, day(25, hour: 20, minute: 30))
        var withFrom = cand("見積書を送る", agreed: true)
        withFrom.from = "Aさん"
        let items = [withFrom, cand("二", agreed: true), cand("三"), cand("四"), cand("片方だけ", agreed: false)]
        let n = try? XCTUnwrap(S24TaskRules.nightNotice(items))
        XCTAssertEqual(n?.title, "今日見つけた頼まれごと")
        XCTAssertTrue(n?.body.contains("・見積書を送る（Aさん）") == true)
        XCTAssertFalse(n?.body.contains("片方だけ") == true)
        XCTAssertFalse(n?.body.contains("件") == true, "数は出さない")
        XCTAssertNil(S24TaskRules.nightNotice([cand("片方だけ", agreed: false)]))
        let merged = S24TaskRules.addNight(["b", "c"], saved: "2026-11-24|a,b", day: "2026-11-24")
        XCTAssertEqual(merged.ids, ["a", "b", "c"])
        XCTAssertEqual(S24TaskRules.addNight(["c"], saved: "2026-11-23|a,b", day: "2026-11-24").ids, ["c"])
    }

    // MARK: 減1・減7・減10・形6・形7 知らせの道

    func testLanes() {
        typealias R = S24NoticeRules
        XCTAssertEqual(R.lane(identifier: "phone-stopped", category: ""), .recording)
        XCTAssertEqual(R.lane(identifier: "watch-silent", category: ""), .recording)
        XCTAssertEqual(R.lane(identifier: "fresh-plaud", category: ""), .recording)
        XCTAssertEqual(R.lane(identifier: "tasks-due-abc", category: "taskDue"), .due)
        XCTAssertEqual(R.lane(identifier: "signExpiry-1", category: ""), .due)
        XCTAssertEqual(R.lane(identifier: "s22-review-1", category: "s22review"), .question)
        XCTAssertEqual(R.lane(identifier: "placeask-1", category: "placeAsk"), .question)
        XCTAssertEqual(R.lane(identifier: "s23-count-1", category: "s23count"), .question)
        XCTAssertEqual(R.lane(identifier: "know-yesno", category: "knowYesNo"), .question)
        XCTAssertEqual(R.lane(identifier: "s22-who-1", category: ""), .question)
        XCTAssertEqual(R.lane(identifier: "taskFound", category: "taskFound"), .letter)
        XCTAssertEqual(R.lane(identifier: "morning-brief", category: ""), .letter)
        XCTAssertEqual(R.lane(identifier: "digest-evening", category: ""), .letter)
        let urgent: [AnyHashable: Any] = ["lifelog": ["kind": "urgent", "key": "watch-stuck"]]
        XCTAssertEqual(R.lane(identifier: UUID().uuidString, category: "", userInfo: urgent), .urgent)
        XCTAssertEqual(S24Urgent.key(urgent), "watch-stuck")
        XCTAssertFalse(S24Urgent.isUrgent(["lifelog": ["kind": "wake"]]))
    }

    func testMarksAreShortAndOnce() {
        typealias R = S24NoticeRules
        XCTAssertEqual(R.marked("iPhone の録音が止まった", lane: .recording), "【録音】iPhone の録音が止まった")
        XCTAssertEqual(R.marked("もうすぐ期限です", lane: .due), "【期限】もうすぐ期限です")
        XCTAssertEqual(R.marked("何人でしたか？", lane: .question), "【問い】何人でしたか？")
        XCTAssertEqual(R.marked("朝の便り：3 件", lane: .letter), "【便り】朝の便り：3 件")
        let once = R.marked("見本", lane: .letter)
        XCTAssertEqual(R.marked(once, lane: .letter), once)
        XCTAssertEqual(R.marked("急ぎの見本", lane: .urgent), "急ぎの見本")
        // 時計を震わせるのは録音・期限・急ぎだけ
        XCTAssertFalse(R.quietOnWatch(.recording))
        XCTAssertFalse(R.quietOnWatch(.due))
        XCTAssertFalse(R.quietOnWatch(.urgent))
        XCTAssertTrue(R.quietOnWatch(.question))
        XCTAssertTrue(R.quietOnWatch(.letter))
    }

    func testDecide() {
        typealias R = S24NoticeRules
        func d(_ lane: R.Lane, immediate: Bool = true, asked: Int = 0, shown: Int = 0, on: Bool = true, quiet: Bool = false) -> R.Decision {
            R.decide(lane: lane, immediate: immediate, asked: asked, shown: shown, questionCap: 3, dailyCapOn: on, quiet: quiet)
        }
        // 別枠は上限・今週は聞かないでに関わらず出す
        for lane in [R.Lane.recording, .due, .urgent] {
            XCTAssertEqual(d(lane, asked: 99, shown: 99, quiet: true), .pass)
        }
        // 問いは 1 日 3 問（仮）まで
        XCTAssertEqual(d(.question, asked: 2), .pass)
        XCTAssertEqual(d(.question, asked: 3), .drop("questionCap"))
        // 知らせ全体は 1 日 5 通（仮）まで。あふれた便りは便りに回す・問いは出さない
        XCTAssertEqual(d(.letter, shown: 4), .pass)
        XCTAssertEqual(d(.letter, shown: 5), .hold)
        XCTAssertEqual(d(.question, shown: 5), .drop("dailyCap"))
        XCTAssertEqual(d(.letter, shown: 5, on: false), .pass)
        // 時刻を決めて頼んだ知らせは便りに回さない
        XCTAssertEqual(d(.letter, immediate: false, shown: 9), .pass)
        // 今週は聞かないで: 問いと便りを止める
        XCTAssertEqual(d(.question, quiet: true), .drop("quiet"))
        XCTAssertEqual(d(.letter, quiet: true), .drop("quiet"))
    }

    func testQuietWeek() {
        let now = day(24)
        let until = S24Quiet.until(from: now)
        XCTAssertEqual(until.timeIntervalSince(now), 7 * 86400)
        XCTAssertTrue(S24Quiet.active(until: until, now: now.addingTimeInterval(6 * 86400)))
        XCTAssertFalse(S24Quiet.active(until: until, now: now.addingTimeInterval(7 * 86400 + 1)))
        XCTAssertFalse(S24Quiet.active(until: nil, now: now))
    }

    // MARK: 減2・減3・減4・当1 問い

    func testAliveByExpires() {
        XCTAssertTrue(S24AskRules.alive(expires: nil, today: "2026-11-24"))
        XCTAssertTrue(S24AskRules.alive(expires: "2026-11-24", today: "2026-11-24"))
        XCTAssertFalse(S24AskRules.alive(expires: "2026-11-23", today: "2026-11-24"))
        XCTAssertTrue(S24AskRules.alive(expires: "読めない", today: "2026-11-24"))
    }

    func testByImpactKeepsOrderWithoutNumbers() {
        let rows: [(String, Int?)] = [("a", nil), ("b", 3), ("c", nil), ("d", 10), ("e", 3), ("f", 0)]
        XCTAssertEqual(S24AskRules.byImpact(rows) { $0.1 }.map(\.0), ["d", "b", "e", "a", "c", "f"])
        let none: [(String, Int?)] = [("x", nil), ("y", nil)]
        XCTAssertEqual(S24AskRules.byImpact(none) { $0.1 }.map(\.0), ["x", "y"])
    }

    func testReviewItemsDropSamePersonUntilAsked() {
        let pair = ReviewItem(id: "p", kind: "voice_pair", question: "同じ人の声？", answer: "yesno")
        var name = ReviewItem(id: "n", kind: "name", question: "この人は Aさん？", answer: "yesno")
        name.impact = 12
        let place = ReviewItem(id: "s", kind: "place", question: "ここは？", answer: "pick", expires: "2026-11-20")
        let ramen = ReviewItem(id: "r", kind: "ramen", question: "ラーメン？", answer: "yesno")
        let off = S24AskRules.reviewItems([pair, ramen, name, place], samePersonAsk: false, today: "2026-11-24")
        XCTAssertEqual(off.map(\.id), ["n", "r"])
        let on = S24AskRules.reviewItems([pair, ramen, name], samePersonAsk: true, today: "2026-11-24")
        XCTAssertEqual(on.map(\.id), ["n", "p", "r"])
    }

    func testReviewImpactDecodes() throws {
        let json = #"{"items":[{"id":"a","kind":"name","question":"?","answer":"yesno","impact":7},{"id":"b","kind":"name","question":"?","answer":"yesno"}]}"#
        let feed = try JSONDecoder().decode(ReviewQueueFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.items?.map(\.impact), [7, nil])
    }

    func testBadgeNeverOverTodaysCap() {
        XCTAssertEqual(S24AskRules.badge(5, cap: 3, asked: 0), 3)
        XCTAssertEqual(S24AskRules.badge(5, cap: 3, asked: 2), 1)
        XCTAssertEqual(S24AskRules.badge(5, cap: 3, asked: 4), 0)
        XCTAssertEqual(S24AskRules.badge(1, cap: 3, asked: 0), 1)
        XCTAssertEqual(S24AskRules.left(cap: 3, asked: 1), 2)
        XCTAssertEqual(S24AskRules.clampCap(0), 1)
        XCTAssertEqual(S24AskRules.clampCap(40), 10)
        XCTAssertEqual(S24Settings.questionCapDefault, 3)
    }

    func testAskedSetCountsEachQuestionOnce() {
        let first = S24AskRules.daySet(adding: ["q:a", "s23-count-1"], saved: nil, day: "2026-11-24")
        XCTAssertEqual(first.ids, ["q:a", "s23-count-1"])
        // 知らせで聞いた問いにアプリで答えても、もう 1 問とは数えない
        let again = S24AskRules.daySet(adding: ["q:a"], saved: first.save, day: "2026-11-24")
        XCTAssertEqual(again.ids.count, 2)
        XCTAssertEqual(S24AskRules.daySet(adding: [], saved: again.save, day: "2026-11-25").ids, [])
        XCTAssertEqual(S24AskRules.daySet(adding: ["a,b"], saved: nil, day: "2026-11-24").ids, ["a_b"])
        // 確かめ待ちの知らせは問いの id で、ほかは知らせの名前で数える
        XCTAssertEqual(S24Gate.questionKey(identifier: "s22-review-1", userInfo: ["id": "a", "n": 1]), "q:a")
        XCTAssertEqual(S24Gate.questionKey(identifier: "s23-count-1", userInfo: ["start": 1.0]), "s23-count-1")
    }

    func testNewReviewKindsHaveJapaneseNames() {
        XCTAssertEqual(ReviewRules.kindLabel("vocab"), "言葉の聞き間違い")
        XCTAssertEqual(ReviewRules.kindLabel("voice"), "この声は誰？")
        // 新しい種類も問いの上限・期限・並びの対象（kind では外さない）
        let vocab = ReviewItem(id: "v", kind: "vocab", question: "「見本」は「見本二」の聞き間違い？", answer: "yesno", expires: "2026-11-30")
        let voice = ReviewItem(id: "w", kind: "voice", question: "この声は誰？", answer: "pick", expires: "2026-11-20")
        XCTAssertEqual(S24AskRules.reviewItems([vocab, voice], samePersonAsk: false, today: "2026-11-24").map(\.id), ["v"])
        XCTAssertEqual(S24NoticeRules.lane(identifier: "s22-review-1", category: "s22review", userInfo: ["id": "v"]), .question)
    }

    // MARK: 減5・減8・急3・初めの値

    func testDefaults() {
        XCTAssertEqual(S24Settings.defaults[S24Settings.promiseNoticeKey], false)
        XCTAssertEqual(S24Settings.defaults[S24Settings.samePersonAskKey], false)
        XCTAssertEqual(S24Settings.defaults[S24Settings.foundNightKey], true)
        XCTAssertEqual(S24Settings.defaults[S24Settings.dailyCapOnKey], true)
        XCTAssertEqual(S24Settings.defaults[S24Settings.candidateTodayKey], true)
    }

    func testOpenedKind() {
        XCTAssertTrue(S24Opened.isOpen(action: UNNotificationDefaultActionIdentifier))
        XCTAssertFalse(S24Opened.isOpen(action: "s22.yes"))
        XCTAssertEqual(S24Book.openedKind(identifier: UUID().uuidString, category: "", userInfo: [:]), "remote")
        XCTAssertEqual(S24Book.openedKind(identifier: UUID().uuidString, category: "promise", userInfo: [:]), "promise")
        XCTAssertEqual(S24Book.openedKind(identifier: "x", category: "", userInfo: ["lifelog": ["kind": "urgent"]]), "urgent")
        XCTAssertEqual(S24Book.openedKind(identifier: "tasks-1700000000", category: "", userInfo: [:]), "tasks")
    }

    func testUrgentCardOpensRecording() {
        let card = S23StatusRules.card(S24Urgent.kind)
        XCTAssertTrue(card.record)
        XCTAssertTrue(card.what.contains("急ぎ"))
    }

    func testSpeakerDoubtExpiresAndImpactAreLossy() {
        let json = #"{"items":[{"day":"2026-11-20","conversation_start":"2026-11-20T10:00:00+09:00","line_time":"2026-11-20T10:00:05+09:00","text_head":"見本","current":"Aさん","suggest":"self","why":"text","score":0.5,"expires":"2026-11-27","impact":4},{"day":"2026-11-20","conversation_start":"2026-11-20T10:00:00+09:00","line_time":"2026-11-20T10:01:05+09:00","text_head":"見本","current":"Aさん","suggest":"self","why":"text","score":0.4,"impact":"多い"}]}"#
        let feed = HomeFeeds.decodeDoubts(Data(json.utf8))
        XCTAssertEqual(feed?.items.count, 2)
        XCTAssertEqual(feed?.items.first?.expires, "2026-11-27")
        XCTAssertEqual(feed?.items.first?.impact, 4)
        XCTAssertNil(feed?.items.last?.impact)
    }
}

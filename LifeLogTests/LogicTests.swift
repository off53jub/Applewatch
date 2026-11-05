import XCTest
@testable import LifeLog

/// 記録を壊しうる処理（同期の合わせ方・消す行の見つけ方）と、名前の取り出しを確かめる。
/// CI（.github/workflows/tests.yml）が iPhone のシミュレーターで動かす。
@MainActor
final class LogicTests: XCTestCase {
    // MARK: - 名前

    // MARK: - 家の PC の多数決にクラウドの票を足す

    private func pcLine(_ votes: [String: String], text: String, confidence: Double) -> HomePC.Line {
        HomePC.Line(offset: 10, end: 14, text: text, confidence: confidence, alternatives: [], votes: votes)
    }

    func testCloudVoteBreaksTie() {
        // 3つが食い違っていた行に、クラウドが reazon と同じ文を書けば、reazon の文を選び直す
        let line = pcLine(["haas": "明日の洋服の話をした", "reazon": "明日の予算の話をした", "whisper": "飛鳥の羊羹の話をした"],
                          text: "明日の洋服の話をした", confidence: 0.4)
        let cloud = [CloudTranscriber.Line(offset: 10.2, text: "明日の予算の話をした")]
        let result = HomePC.addCloudVote([line], cloud: cloud)[0]
        XCTAssertEqual(result.text, "明日の予算の話をした")
        XCTAssertEqual(result.votes["cloud"], "明日の予算の話をした")
        XCTAssertFalse(result.alternatives.isEmpty)
    }

    func testCloudVoteLeavesSureLinesAndOtherTimes() {
        // 確かな行と、クラウドが別の時間に書いた文は変えない
        let sure = pcLine(["haas": "今日は会議です", "reazon": "今日は会議です", "whisper": "今日は会議です"],
                          text: "今日は会議です", confidence: 1)
        let unsure = pcLine(["haas": "明日の洋服の話をした", "reazon": "明日の予算の話をした", "whisper": ""],
                            text: "明日の洋服の話をした", confidence: 0.4)
        let cloud = [CloudTranscriber.Line(offset: 40, text: "明日の予算の話をした")]
        let result = HomePC.addCloudVote([sure, unsure], cloud: cloud)
        XCTAssertEqual(result[0].text, "今日は会議です")
        XCTAssertEqual(result[1].text, "明日の洋服の話をした")
        XCTAssertNil(result[1].votes["cloud"])
    }

    func testIntroducedNames() {
        XCTAssertEqual(Pipeline.introducedNames(in: "田中と申します"), ["田中"])
        XCTAssertEqual(Pipeline.introducedNames(in: "私は田中といいます。"), ["田中"])
        XCTAssertEqual(Pipeline.introducedNames(in: "営業の田中です、よろしくお願いします"), ["田中"])
        // 「〇〇です」だけでは名乗りとみなさない
        XCTAssertEqual(Pipeline.introducedNames(in: "大丈夫です"), [])
        XCTAssertEqual(Pipeline.introducedNames(in: "そうですね"), [])
    }

    func testCalledNames() {
        XCTAssertEqual(Pipeline.calledNames(in: "田中さん、これお願いします"), ["田中"])
        XCTAssertEqual(Pipeline.calledNames(in: "皆さん、こんにちは"), [])
    }

    func testSameName() {
        XCTAssertTrue(Pipeline.sameName("田中", "田中太郎"))
        XCTAssertTrue(Pipeline.sameName("田中さん", "田中"))
        XCTAssertTrue(Pipeline.sameName("田中 太郎", "田中太郎"))
        XCTAssertFalse(Pipeline.sameName("田", "田中"))
        XCTAssertFalse(Pipeline.sameName("佐藤", "田中"))
        XCTAssertFalse(Pipeline.sameName("", "田中"))
    }

    func testReadingIgnoresKanaKindAndLongVowels() {
        XCTAssertEqual(ContactsLink.reading("さとう"), ContactsLink.reading("サトウ"))
    }

    // MARK: - 消す行の見つけ方

    func testJunkKinds() {
        XCTAssertEqual(Junk.kind(of: "ご視聴ありがとうございました", custom: []), .filler)
        XCTAssertEqual(Junk.kind(of: "3行目の直した文", custom: []), .broken)
        XCTAssertEqual(Junk.kind(of: "うん。", custom: [Junk.normalized("うん")]), .custom)
        XCTAssertNil(Junk.kind(of: "来週の資料は木曜までに作ります", custom: []))
        // 長い文は、決まり文句を含んでいても消さない
        XCTAssertNil(Junk.kind(of: "チャンネル登録の話をしたけど、結局どうするかは来週の会議で決めることになったので、資料を用意しておきます", custom: []))
    }

    func testChangedPart() {
        let part = Pipeline.changedPart(from: "会義の資料", to: "会議の資料")
        XCTAssertEqual(part?.wrong, "会義")
        XCTAssertEqual(part?.right, "会議")
        XCTAssertNil(Pipeline.changedPart(from: "同じ文", to: "同じ文"))
    }

    // MARK: - 騒がしさ

    func testNoiseThresholds() {
        XCTAssertTrue(NoiseMeter.Reading(floor: -40, speech: -20).isNoisy)
        XCTAssertFalse(NoiseMeter.Reading(floor: -60, speech: -30).isNoisy)
        XCTAssertTrue(NoiseMeter.Reading(floor: -50, speech: -45).isNoisy)
        XCTAssertFalse(NoiseMeter.Reading(floor: -50, speech: -30).isNoisy)
    }

    // MARK: - 端末間の同期

    /// テスト用の日（実際の記録とぶつからない日付）
    private let day = "1999-01-01"

    private func freshLog() throws -> ConversationLog {
        let url = URL.applicationSupportDirectory.appendingPathComponent("days/\(day).json")
        try? FileManager.default.removeItem(at: url)
        return ConversationLog(docs: GoogleDocs())
    }

    private func conversation(_ start: Date, title: String, rev: Int) -> ConversationLog.Conversation {
        ConversationLog.Conversation(start: start, end: start.addingTimeInterval(60), docIndex: 1, title: title,
                                     closed: true, rev: rev)
    }

    func testMergeKeepsNewerRevision() throws {
        let log = try freshLog()
        let start = Date(timeIntervalSince1970: 915_150_000)
        XCTAssertTrue(log.mergeRemote(.init(conversations: [conversation(start, title: "2", rev: 2)], removed: [],
                                            summaryWritten: false, summary: nil), day: day))
        XCTAssertEqual(log.conversations(on: day).map(\.title), ["2"])
        // 古い版は入れない
        XCTAssertFalse(log.mergeRemote(.init(conversations: [conversation(start, title: "1", rev: 1)], removed: [],
                                             summaryWritten: false, summary: nil), day: day))
        XCTAssertEqual(log.conversations(on: day).map(\.title), ["2"])
        // 新しい版に置き換える
        XCTAssertTrue(log.mergeRemote(.init(conversations: [conversation(start, title: "3", rev: 3)], removed: [],
                                            summaryWritten: false, summary: nil), day: day))
        XCTAssertEqual(log.conversations(on: day).map(\.title), ["3"])
    }

    func testMergeRemovesAndDoesNotRevive() throws {
        let log = try freshLog()
        let start = Date(timeIntervalSince1970: 915_160_000)
        _ = log.mergeRemote(.init(conversations: [conversation(start, title: "a", rev: 3)], removed: [],
                                  summaryWritten: false, summary: nil), day: day)
        // ほかの端末で消した（消した印の番号が新しい）
        XCTAssertTrue(log.mergeRemote(.init(conversations: [], removed: [.init(start: start, rev: 4)],
                                            summaryWritten: false, summary: nil), day: day))
        XCTAssertTrue(log.conversations(on: day).isEmpty)
        // 消す前の版が遅れて届いても、戻さない
        _ = log.mergeRemote(.init(conversations: [conversation(start, title: "a", rev: 4)], removed: [],
                                  summaryWritten: false, summary: nil), day: day)
        XCTAssertTrue(log.conversations(on: day).isEmpty)
    }

    func testMergeKeepsSeparateConversations() throws {
        let log = try freshLog()
        let first = Date(timeIntervalSince1970: 915_170_000)
        let second = first.addingTimeInterval(3600)
        _ = log.mergeRemote(.init(conversations: [conversation(second, title: "後", rev: 1)], removed: [],
                                  summaryWritten: false, summary: nil), day: day)
        _ = log.mergeRemote(.init(conversations: [conversation(first, title: "先", rev: 1)], removed: [],
                                  summaryWritten: true, summary: nil), day: day)
        // 始まりの順に並び、どちらも残る
        XCTAssertEqual(log.conversations(on: day).map(\.title), ["先", "後"])
    }

    // MARK: - 2人を分ける

    /// 長さ1の声の特徴（2つの向きのまわりに少しずらしたもの）
    private func voice(_ base: [Float], _ jitter: Float) -> [Float] {
        let v = base.enumerated().map { $0.element + jitter * Float($0.offset % 3 == 0 ? 1 : -1) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }

    func testTwoGroupsSeparatesTwoVoices() {
        let a: [Float] = [1, 0, 0, 0], b: [Float] = [0, 1, 0, 0]
        let vectors = [voice(a, 0.05), voice(b, 0.04), voice(a, 0.02), voice(a, 0.08), voice(b, 0.07), voice(b, 0.01)]
        guard let split = Pipeline.twoGroups(vectors) else { return XCTFail("分かれなかった") }
        // a の仲間どうし、b の仲間どうしが同じ組になる
        XCTAssertEqual(split.labels[0], split.labels[2])
        XCTAssertEqual(split.labels[0], split.labels[3])
        XCTAssertEqual(split.labels[1], split.labels[4])
        XCTAssertEqual(split.labels[1], split.labels[5])
        XCTAssertNotEqual(split.labels[0], split.labels[1])
        XCTAssertGreaterThan(split.distance, Pipeline.splitApart)
    }

    func testVoiceGroupsFindsThreeVoices() {
        let a: [Float] = [1, 0, 0, 0], b: [Float] = [0, 1, 0, 0], c: [Float] = [0, 0, 1, 0]
        let vectors = [voice(a, 0.05), voice(b, 0.04), voice(c, 0.03), voice(a, 0.02), voice(b, 0.07), voice(c, 0.06), voice(a, 0.08)]
        let labels = Pipeline.voiceGroups(vectors, limit: Pipeline.groupLimit)
        XCTAssertEqual(Set(labels).count, 3)
        XCTAssertEqual(labels[0], labels[3]); XCTAssertEqual(labels[0], labels[6])
        XCTAssertEqual(labels[1], labels[4]); XCTAssertEqual(labels[2], labels[5])
        // 行の多い組（a の3行）がいちばん小さい番号
        XCTAssertEqual(labels[0], 0)
    }

    func testIsHome() {
        XCTAssertTrue(Pipeline.isHome("自宅"))
        XCTAssertTrue(Pipeline.isHome("実家"))
        XCTAssertFalse(Pipeline.isHome("渋谷駅近く"))
        XCTAssertFalse(Pipeline.isHome("駅のホーム"))
        XCTAssertFalse(Pipeline.isHome(nil))
    }

    func testVoiceGroupsKeepsOneVoiceTogether() {
        let a: [Float] = [1, 0, 0, 0]
        let labels = Pipeline.voiceGroups([voice(a, 0.05), voice(a, 0.02), voice(a, 0.08), voice(a, 0.01)], limit: Pipeline.groupLimit)
        XCTAssertEqual(Set(labels), [0])
    }

    func testTwoGroupsSameVoiceIsClose() {
        let a: [Float] = [1, 0, 0, 0]
        let vectors = [voice(a, 0.05), voice(a, 0.02), voice(a, 0.08), voice(a, 0.01)]
        if let split = Pipeline.twoGroups(vectors) {
            XCTAssertLessThan(split.distance, Pipeline.splitApart)
        }
    }

    // MARK: - 聞き間違いかも

    func testMisheardBoxMergesSameWord() {
        let box = MisheardBox()
        let ref1 = MisheardBox.Ref(day: day, time: Date(timeIntervalSince1970: 915_180_000), text: "テスト用の会義")
        let ref2 = MisheardBox.Ref(day: day, time: Date(timeIntervalSince1970: 915_180_060), text: "また会義")
        let before = box.open.filter { $0.wrong == "会義テスト" }.count
        box.add(wrong: "会義テスト", guess: "会議", reason: "", ref: ref1)
        box.add(wrong: "会義テスト", guess: "", reason: "", ref: ref2)
        let found = box.open.filter { $0.wrong == "会義テスト" }
        XCTAssertEqual(found.count, max(1, before))
        XCTAssertEqual(found.first?.refs.count, 2)
        XCTAssertEqual(found.first?.guess, "会議")
        if let id = found.first?.id { box.settle(id, as: .kept) }
        XCTAssertTrue(box.kept.contains("会義テスト"))
    }

    // MARK: - 話し方

    func testSpeakStats() {
        let t = Date(timeIntervalSince1970: 915_190_000)
        var c = conversation(t, title: "x", rev: 1)
        c.lines = [
            .init(time: t, speaker: "自分", text: "えっと、明日の件ですか？", speakerID: "me"),
            .init(time: t.addingTimeInterval(4), speaker: "田中", text: "そうです。資料は木曜までにお願いします", speakerID: "1"),
            .init(time: t.addingTimeInterval(10), speaker: "自分", text: "わかりました", speakerID: "me"),
        ]
        guard let s = SpeakStats.of(c) else { return XCTFail() }
        XCTAssertEqual(s.selfLines, 2)
        XCTAssertEqual(s.questions, 1)
        XCTAssertEqual(s.fillers, 1)
        XCTAssertEqual(s.selfChars, "えっと、明日の件ですか？".count + "わかりました".count)
        XCTAssertTrue(SpeakStats.isQuestion("それでいいかな"))
        XCTAssertFalse(SpeakStats.isQuestion("それでいいです"))
    }

    // MARK: - 検索の索引

    func testSearchIndexFindsTwoCharacterWords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("search-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = SearchIndex(url: url)
        XCTAssertTrue(index.isReady, "全文検索の表を作れなかった")
        let t1 = Date(timeIntervalSince1970: 915_200_000), t2 = t1.addingTimeInterval(60)
        index.replace(day: day, stamp: 1, texts: [(t1, "田中 来週の会議資料を作ります"), (t2, "自分 会議は木曜です")])
        XCTAssertEqual(index.search(["会議"])?.count, 2)
        XCTAssertEqual(index.search(["会議資料"])?.map(\.time), [t1])
        XCTAssertEqual(index.search(["田中", "会議"])?.map(\.time), [t1])
        XCTAssertEqual(index.search(["佐藤"])?.count, 0)
        // 1文字の言葉は索引では探せない
        XCTAssertNil(index.search(["会"]))
        XCTAssertFalse(index.needsUpdate(day, stamp: 1))
        XCTAssertTrue(index.needsUpdate(day, stamp: 2))
        index.remove(daysNotIn: [])
        XCTAssertEqual(index.search(["会議"])?.count, 0)
    }

    // MARK: - 端末内の言語モデル

    func testLocalModelParsesJSONInsideText() {
        let json = LocalModel.parse("はい、こちらです。\n{\"title\": \"打ち合わせ\", \"points\": [\"A案\"]}\nいかがでしょう")
        XCTAssertEqual(json?["title"] as? String, "打ち合わせ")
        XCTAssertEqual(json?["points"] as? [String], ["A案"])
        XCTAssertNil(LocalModel.parse("JSON がありません"))
    }

    func testSensitiveWorkGoesLocalOnlyWhenWorkMode() {
        // 端末内の言語モデルが使えない（シミュレーターなど）ときは、どの設定でも Groq を使う
        if !LocalModel.isUsable {
            XCTAssertFalse(Summarizer.$sensitive.withValue(true) { Summarizer.usesLocal(apiKey: "key") })
        }
    }

    // MARK: - 控え

    func testBackupLabel() {
        let entry = BackupKeeper.Entry(name: "控え-zzzzzzzz-2026-11-03.json", local: nil, driveID: "x")
        XCTAssertEqual(entry.label, "2026-11-03（端末 zzzzzzzz）")
    }

    // MARK: - 頼まれごと帳

    func testTaskSimilar() {
        XCTAssertTrue(TaskBook.similar("見積書を送る", "見積書を送ります。"))
        XCTAssertTrue(TaskBook.similar("A社に見積書を送る", "見積書を送る"))
        XCTAssertFalse(TaskBook.similar("見積書を送る", "会議室を予約する"))
        XCTAssertFalse(TaskBook.similar("", "見積書を送る"))
    }

    func testTaskDueDateAndOrder() {
        XCTAssertNotNil(TaskBook.dueDate("2026-11-07"))
        XCTAssertNil(TaskBook.dueDate("来週まで"))
        XCTAssertNil(TaskBook.dueDate(""))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = TaskBook.Item(what: "a", due: now, said: now, source: .manual, state: .open)
        let later = TaskBook.Item(what: "b", due: now.addingTimeInterval(86400), said: now, source: .manual, state: .open)
        let none = TaskBook.Item(what: "c", said: now.addingTimeInterval(-60), source: .manual, state: .open)
        XCTAssertEqual([none, later, soon].sorted(by: TaskBook.dueOrder).map(\.what), ["a", "b", "c"])
    }

    func testTaskOldSavedItemsStillRead() throws {
        // 種類・進み具合が入る前に保存した帳も、そのまま読める
        let old = #"[{"id":"x","what":"見積書を送る","from":"田中","said":0,"source":"conversation","state":"open","updated":0}]"#
        let items = try JSONDecoder().decode([TaskBook.Item].self, from: Data(old.utf8))
        XCTAssertEqual(items.first?.kindOrDefault, .asked)
        XCTAssertNil(items.first?.progress)
        XCTAssertEqual(items.first?.isWaiting, false)
        let manual = TaskBook.Item(what: "a", said: .now, source: .manual, state: .open)
        XCTAssertEqual(manual.kindOrDefault, .mine)
    }

    func testTaskBucketsAndWaiting() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!  // 木曜
        func item(_ what: String, _ days: Int?, urgent: Bool = false) -> TaskBook.Item {
            TaskBook.Item(what: what, due: days.map { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: now))! },
                          said: now, source: .manual, state: .open, urgent: urgent ? true : nil)
        }
        XCTAssertEqual(TaskBook.bucket(item("a", -1), now: now, calendar: cal), .late)
        XCTAssertEqual(TaskBook.bucket(item("b", 0), now: now, calendar: cal), .today)
        XCTAssertEqual(TaskBook.bucket(item("c", 3), now: now, calendar: cal), .week)
        XCTAssertEqual(TaskBook.bucket(item("d", 20), now: now, calendar: cal), .later)
        XCTAssertEqual(TaskBook.bucket(item("e", nil), now: now, calendar: cal), .someday)
        XCTAssertEqual(TaskBook.nextWeekDays(now: now, calendar: cal), 4)  // 次の月曜
        let monday = cal.date(byAdding: .day, value: 4, to: now)!
        XCTAssertEqual(TaskBook.nextWeekDays(now: monday, calendar: cal), 7)

        var delegated = item("f", 1)
        delegated.kind = .delegated
        XCTAssertTrue(delegated.isWaiting)
        delegated.progress = .started
        XCTAssertFalse(delegated.isWaiting)
        var parked = item("g", 1)
        parked.progress = .waiting
        XCTAssertTrue(parked.isWaiting)
        XCTAssertEqual(TaskBook.Kind.parse(" Promise "), .promise)
        XCTAssertNil(TaskBook.Kind.parse(""))
    }

    func testTaskGroupsUrgentFirstAndByPerson() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var a = TaskBook.Item(what: "a", said: now, source: .manual, state: .open)
        var b = TaskBook.Item(what: "b", said: now.addingTimeInterval(60), source: .manual, state: .open, urgent: true)
        a.from = "田中"
        b.from = "田中 "
        let c = TaskBook.Item(what: "c", said: now.addingTimeInterval(120), source: .manual, state: .open)
        let groups = TaskBook.grouped([a, b, c], now: now)
        XCTAssertEqual(groups.map(\.bucket), [.someday])
        XCTAssertEqual(groups.first?.items.map(\.what), ["b", "a", "c"])
        let people = TaskBook.byPerson([a, b, c])
        XCTAssertEqual(people.map(\.person), ["田中"])
        XCTAssertEqual(people.first?.items.count, 2)
    }

    // MARK: - 数字

    func testNumberStyle() {
        XCTAssertEqual(NumberStyle.normalize("千二百円です"), "1200円です")
        XCTAssertEqual(NumberStyle.normalize("三億五千万円の案件"), "3億5000万円の案件")
        XCTAssertEqual(NumberStyle.normalize("二〇二六年三月"), "2026年3月")
        XCTAssertEqual(NumberStyle.normalize("三十五歳"), "35歳")
        XCTAssertEqual(NumberStyle.normalize("百パーセント"), "100パーセント")
        XCTAssertEqual(NumberStyle.normalize("五百株買う"), "500株買う")
        // 言葉としての漢数字は変えない
        XCTAssertEqual(NumberStyle.normalize("十分です"), "十分です")
        XCTAssertEqual(NumberStyle.normalize("一時的に"), "一時的に")
        XCTAssertEqual(NumberStyle.normalize("一部の人"), "一部の人")
        XCTAssertEqual(NumberStyle.normalize("一緒に統一する"), "一緒に統一する")
        XCTAssertEqual(NumberStyle.normalize("同一件"), "同一件")
        XCTAssertEqual(NumberStyle.normalize("万円"), "万円")
        XCTAssertEqual(NumberStyle.normalize("四六時中ずっと"), "四六時中ずっと")
        XCTAssertEqual(NumberStyle.normalize("五分五分です"), "五分五分です")
        XCTAssertEqual(NumberStyle.normalize("一個人として三日坊主"), "一個人として三日坊主")
        XCTAssertEqual(NumberStyle.normalize("一日中会議、三日後に"), "一日中会議、3日後に")
    }

    // MARK: - 場面

    func testCarAudioAndTrainOrCar() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let periods = [CarAudioLog.Period(start: t0, end: t0.addingTimeInterval(600))]
        XCTAssertTrue(CarAudioLog.overlaps(periods, from: t0.addingTimeInterval(60), to: t0.addingTimeInterval(1200)))
        XCTAssertFalse(CarAudioLog.overlaps(periods, from: t0.addingTimeInterval(590), to: t0.addingTimeInterval(1200)))
        XCTAssertTrue(CarAudioLog.looksLikeCar("My Car"))
        XCTAssertTrue(CarAudioLog.looksLikeCar("TOYOTA Multimedia"))
        XCTAssertFalse(CarAudioLog.looksLikeCar("Oscar's AirPods"))
        XCTAssertFalse(CarAudioLog.looksLikeCar("WH-1000XM5"))

        func line(_ sound: String?) -> ConversationLog.Line {
            var l = ConversationLog.Line(time: t0, speaker: nil, text: "a")
            l.sound = sound
            return l
        }
        let vehicle = MotionLink.Movement.vehicle.label
        XCTAssertEqual(ConversationLog.refinedMovement(vehicle, lines: [line("電車"), line(nil), line(nil)]), "電車で")
        XCTAssertEqual(ConversationLog.refinedMovement(vehicle, lines: [line("車"), line(nil)]), "車で")
        XCTAssertEqual(ConversationLog.refinedMovement(vehicle, lines: [line(nil), line(nil)]), vehicle)
        XCTAssertEqual(ConversationLog.refinedMovement("歩きながら", lines: [line("電車")]), "歩きながら")
    }

    // MARK: - 正解帳

    func testAnswerKeyScore() {
        XCTAssertEqual(AnswerKey.editDistance(Array("みつもり"), Array("みつもり")), 0)
        XCTAssertEqual(AnswerKey.editDistance(Array("見積書を送る"), Array("見積もりを送る")), 2)
        XCTAssertEqual(AnswerKey.editDistance([], Array("abc")), 3)
        func sample(_ id: String, text: String, right: String?, speaker: Bool?, scene: Bool?, skipped: Bool = false) -> AnswerKey.Sample {
            AnswerKey.Sample(id: id, week: "2026-11-02", day: "2026-11-05", time: .now, text: text, speaker: nil,
                             speakerID: nil, place: nil, title: nil, audio: "a.m4a", offset: 0, confidence: nil, noisy: nil,
                             rightText: right, speakerOK: speaker, sceneOK: scene, skipped: skipped ? true : nil,
                             answered: .now)
        }
        let score = AnswerKey.score("2026-11-02", [
            sample("1", text: "あいうえお", right: "あいうえお", speaker: true, scene: true),
            sample("2", text: "かきくけこ", right: "かきくけさ、", speaker: false, scene: nil),
            sample("3", text: "x", right: nil, speaker: nil, scene: nil, skipped: true),
        ])
        XCTAssertEqual(score.answered, 2)
        XCTAssertEqual(score.speaker, 0.5)
        XCTAssertEqual(score.scene, 1)
        XCTAssertEqual(score.textError ?? 0, 0.1, accuracy: 0.0001)
    }

    func testAnswerKeyEngineWeights() {
        func sample(_ i: Int) -> AnswerKey.Sample {
            AnswerKey.Sample(id: "\(i)", week: "w", day: "d", time: .now, text: "あいうえお", speaker: nil, speakerID: nil,
                             place: nil, title: nil, audio: "a", offset: 0, confidence: 0.4, noisy: nil,
                             votes: ["haas": "あいうえお", "reazon": "あいうえか", "whisper": "かきくけこ"], extra: true,
                             rightText: "あいうえお", answered: .now)
        }
        XCTAssertTrue(AnswerKey.weights((0..<7).map(sample)).isEmpty)
        let samples = (0..<8).map(sample)
        let errors = AnswerKey.engineErrors(samples)
        XCTAssertEqual(errors["haas"]?.error ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(errors["reazon"]?.error ?? 0, 0.2, accuracy: 0.001)
        let weights = AnswerKey.weights(samples)
        XCTAssertEqual(weights["haas"], 2.0)
        XCTAssertEqual(weights["whisper"], 0.5)
        XCTAssertGreaterThan(weights["reazon"] ?? 0, 1.0)
        // 追加の問いは週の数字に入れない
        XCTAssertEqual(AnswerKey.score("w", samples.filter { $0.extra != true }).answered, 0)
    }

    func testAnswerKeyWeekAndPick() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let thursday = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
        XCTAssertEqual(AnswerKey.weekKey(thursday, calendar: cal), "2026-11-02")
        let sunday = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 23))!
        XCTAssertEqual(AnswerKey.weekKey(sunday, calendar: cal), "2026-11-02")

        var candidates: [AnswerKey.Sample] = []
        for i in 0..<40 {
            candidates.append(AnswerKey.Sample(
                id: "d|\(i)", week: "w", day: "2026-11-05", time: thursday.addingTimeInterval(Double(i) * 300),
                text: "行\(i)", speaker: nil, speakerID: i % 2 == 0 ? SpeakerLabeler.selfID : "3",
                place: i < 30 ? "職場" : "家", title: "会話\(i / 4)", audio: "a", offset: 0, confidence: nil, noisy: nil))
        }
        let picked = AnswerKey.pick(candidates, count: 10, seed: "2026-11-02")
        XCTAssertEqual(picked.count, 10)
        XCTAssertEqual(picked.map(\.id), AnswerKey.pick(candidates, count: 10, seed: "2026-11-02").map(\.id))
        XCTAssertTrue(picked.contains { $0.place == "家" })
        XCTAssertTrue(picked.contains { $0.speakerID == SpeakerLabeler.selfID })
        XCTAssertTrue(picked.contains { $0.speakerID == "3" })
        let perTalk = Dictionary(grouping: picked, by: { $0.title ?? "" }).values.map(\.count).max() ?? 0
        XCTAssertLessThanOrEqual(perTalk, 2)
    }

    func testTaskAddSkipsDuplicates() {
        let book = TaskBook()
        let before = book.items.count
        let item = TaskBook.Item(what: "テスト用の頼まれごと\(UUID().uuidString.prefix(6))", said: .now, source: .manual, state: .candidate)
        XCTAssertEqual(book.add([item]).count, 1)
        var again = item
        again.id = UUID().uuidString
        XCTAssertEqual(book.add([again]).count, 0)
        book.delete(item.id)
        XCTAssertEqual(book.items.count, before)
    }

    // MARK: - 聞き分けから外した声

    /// 外したひとこまの印は、見直しの印と同じ形（戻したときに「このままでよい」にするため）
    func testSetAsideKeyMatchesReviewKey() {
        let sample = SpeakerLabeler.Sample(audio: "rec-2026-11-03.m4a", start: 12.5, end: 20)
        XCTAssertEqual(SpeakerLabeler.SetAside.key("42", sample), Pipeline.reviewKey("42", sample))
    }

    /// 外した声は消さずに取っておくので、書いて読んでも同じになる
    func testSetAsideRoundTrip() throws {
        let sample = SpeakerLabeler.Sample(audio: "a.m4a", start: 1, end: 4)
        let voice = SpeakerLabeler.Voice(embedding: [0.6, 0.8], pinned: false, added: Date(timeIntervalSince1970: 1_000), model: SpeakerLabeler.model)
        let item = SpeakerLabeler.SetAside(person: "7", sample: sample, voices: [voice], at: Date(timeIntervalSince1970: 2_000), reason: "「まぐだ」の行")
        let back = try JSONDecoder().decode([SpeakerLabeler.SetAside].self, from: JSONEncoder().encode([item]))
        XCTAssertEqual(back.first?.id, item.id)
        XCTAssertEqual(back.first?.voices.first?.embedding, [0.6, 0.8])
        XCTAssertEqual(back.first?.voices.first?.pinned, false)
        XCTAssertEqual(back.first?.reason, "「まぐだ」の行")
    }

    // MARK: - AI からの質問・わかったこと帳

    func testAskKeywords() {
        let words = AskBook.keywords("今日はダンスの練習のあと、Splatoon の話をした")
        XCTAssertTrue(words.contains("ダンス"))
        XCTAssertTrue(words.contains("練習"))
        XCTAssertTrue(words.contains("Splatoon"))
        XCTAssertFalse(words.contains("今日"))
    }

    /// 答えは「いつ・どこ・質問 → 答え」の1行になり、質問の対象の言葉で引ける
    func testFactTextAndWords() {
        let time = Date(timeIntervalSince1970: 1_793_700_000)
        let q = AskBook.Question(day: "2026-11-03", kind: .word, question: "「さまいまい」はだれのこと？", subject: "さまいまい",
                                 quote: "理由はさまいまいが出るから", time: time, place: "大久保駅近く")
        let text = AskBook.factText(q, answer: "まいさん（佐藤真衣）")
        XCTAssertTrue(text.contains("大久保駅近く"))
        XCTAssertTrue(text.hasSuffix("→ まいさん（佐藤真衣）"))
        let words = AskBook.words(of: q, answer: "まいさん（佐藤真衣）")
        XCTAssertEqual(words.first, "さまいまい")
        XCTAssertTrue(words.contains("佐藤真衣"))
    }

    /// AI に渡すのは、記録に手がかりの言葉が出てくるものだけ
    func testKnownFactsRelevant() {
        let box = KnownFacts()
        box.set([.init(text: "「ひさおど」はダンスイベントの名前", words: ["ひさおど"]),
                 .init(text: "スプラ部は Splatoon の仲間", words: ["スプラ部"])])
        XCTAssertEqual(box.relevant(to: "来週のひさおどの練習"), ["「ひさおど」はダンスイベントの名前"])
        XCTAssertEqual(box.relevant(to: "会議の資料を作る"), [])
    }

    // MARK: - 周りの声を外す決まり（2026-11-05 に直した）

    /// 名前を付けた人の声は、自分の声よりずっと小さくても外さない（名前の無い小さな声は外す）
    func testOfficeFilterKeepsNamedQuietVoices() {
        let filter = OfficeFilter()
        let now = Date.now
        let items = [
            OfficeFilter.Item(time: now, text: "そうですね", personID: SpeakerLabeler.selfID, isNamed: true, level: -10),
            OfficeFilter.Item(time: now.addingTimeInterval(5), text: "AMSの方ですね", personID: "23", isNamed: true, level: -40),
            OfficeFilter.Item(time: now.addingTimeInterval(9), text: "遠くの席の話", personID: "999", isNamed: false, level: -40),
        ]
        XCTAssertEqual(filter.keep(items, fromWatch: true, active: true, asleep: false), [true, true, false])
        // 使わないときは全部残す
        XCTAssertEqual(filter.keep(items, fromWatch: true, active: false, asleep: false), [true, true, true])
    }

    /// 「職場にいるときだけ」は、職場と分かっているときだけ使う（時刻の推定では使わない）
    func testOfficeFilterNeedsSureWork() {
        let filter = OfficeFilter()
        let saved = filter.mode
        defer { filter.mode = saved }
        filter.mode = .work
        XCTAssertTrue(filter.applies(sureWork: true))
        XCTAssertFalse(filter.applies(sureWork: false))
        filter.mode = .always
        XCTAssertTrue(filter.applies(sureWork: false))
    }

    // MARK: - 自分の声がほかの人の声として覚えられないように（2026-11-05）

    /// 覚え足すのは、2番目の人よりはっきり近いときだけ。ほかの人なのに自分の声くらい大きい声は覚えない
    func testMayLearnNeedsClearWinner() {
        XCTAssertTrue(SpeakerLabeler.mayLearn(distance: 0.15, second: 0.40, limit: 0.25, seconds: 5, isSelf: false, loud: false))
        // 2番目（自分）との差が小さい
        XCTAssertFalse(SpeakerLabeler.mayLearn(distance: 0.20, second: 0.26, limit: 0.25, seconds: 5, isSelf: false, loud: false))
        // ほかの人なのに、自分の声くらい大きい
        XCTAssertFalse(SpeakerLabeler.mayLearn(distance: 0.15, second: 0.40, limit: 0.25, seconds: 5, isSelf: false, loud: true))
        // 自分なら大きくて当たり前
        XCTAssertTrue(SpeakerLabeler.mayLearn(distance: 0.15, second: 0.40, limit: 0.25, seconds: 5, isSelf: true, loud: true))
        // 短い・遠い
        XCTAssertFalse(SpeakerLabeler.mayLearn(distance: 0.15, second: 0.40, limit: 0.25, seconds: 2, isSelf: true, loud: false))
        XCTAssertFalse(SpeakerLabeler.mayLearn(distance: 0.30, second: 0.60, limit: 0.25, seconds: 5, isSelf: true, loud: false))
    }

    /// 1つの区切りで同じ人になった2つのまとまりのうち、自分の声くらい大きく、もう片方より12dB以上大きいほうが候補
    func testWearerClusters() {
        let owners = ["S1": "12", "S2": "12", "S3": "me", "S4": "30"]
        let levels: [String: Float] = ["S1": -20, "S2": -36, "S3": -21, "S4": -19]
        XCTAssertEqual(SpeakerLabeler.wearerClusters(owners: owners, levels: levels, selfLevel: -19), ["S1"])
        // 差が12dBに満たなければ候補にしない
        XCTAssertEqual(SpeakerLabeler.wearerClusters(owners: owners, levels: ["S1": -20, "S2": -28], selfLevel: -19), [])
        // 大きくても自分の声ほどでなければ候補にしない
        XCTAssertEqual(SpeakerLabeler.wearerClusters(owners: owners, levels: ["S1": -30, "S2": -45], selfLevel: -19), [])
    }

    /// 自動で覚えた声が、その人の決めた声より、ほかの人の決めた声にずっと近いときだけ外す（控えで井上さん20個・うい6個）
    func testBelongsElsewhere() {
        XCTAssertTrue(SpeakerLabeler.belongsElsewhere(own: 0.79, other: 0.26))
        XCTAssertTrue(SpeakerLabeler.belongsElsewhere(own: 0.92, other: 0.34))
        // どちらからも遠い（松澤さんの自動の声: 本人 0.73 / 自分 0.54）
        XCTAssertFalse(SpeakerLabeler.belongsElsewhere(own: 0.73, other: 0.54))
        // 差が小さい
        XCTAssertFalse(SpeakerLabeler.belongsElsewhere(own: 0.45, other: 0.30))
        let a: [Float] = [1, 0], b: [Float] = [0, 1]
        XCTAssertEqual(SpeakerLabeler.top3(a, [a, b]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SpeakerLabeler.top3(a, []), 1)
        let t = Date(timeIntervalSinceReferenceDate: 815_234_549.839824)
        XCTAssertEqual(SpeakerLabeler.keptKey(person: "12", added: t), "12|815234549.840")
    }

    /// 過去の行の声が自分の声らしいのは、自分の見本にはっきり近く、その人の見本より0.12以上近いときだけ
    func testLooksLikeSelf() {
        XCTAssertTrue(Pipeline.looksLikeSelf(me: 0.25, own: 0.80))
        XCTAssertTrue(Pipeline.looksLikeSelf(me: 0.38, own: 0.50))
        XCTAssertFalse(Pipeline.looksLikeSelf(me: 0.30, own: 0.38))   // 差が小さい
        XCTAssertFalse(Pipeline.looksLikeSelf(me: 0.45, own: 1.0))    // 自分にも遠い
    }

    /// 署名の期限は mobileprovision（署名付きの plist）の ExpirationDate から読む
    func testProvisioningExpiry() throws {
        let expiry = Date(timeIntervalSince1970: 1_794_000_000)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": expiry, "Name": "LifeLog"],
                                                       format: .xml, options: 0)
        // 前後に署名のバイト列があっても読めること
        var data = Data([0x30, 0x82, 0x01, 0x00, 0xFF])
        data.append(plist)
        data.append(Data([0x00, 0xA0, 0x82]))
        XCTAssertEqual(Provisioning.expiry(in: data), expiry)
        XCTAssertNil(Provisioning.expiry(in: Data("no plist here".utf8)))
        XCTAssertEqual(Provisioning.remaining(-5), "過ぎています")
        XCTAssertEqual(Provisioning.remaining(3 * 86400 + 60), "あと3日")
        XCTAssertEqual(Provisioning.remaining(5 * 3600), "あと5時間")
        XCTAssertEqual(Provisioning.remaining(600), "あと10分")
    }

    /// PC が読む状態ファイルは、端末どうしの同期で読まれない名前（「-」を含まない）で、日時は ISO 8601
    func testAppStatusFile() throws {
        let name = AppStatus.fileName(device: "c4e3a742")
        XCTAssertFalse(name.contains("-"))
        let status = AppStatus(device: "c4e3a742", kind: "iPhone", written: Date(timeIntervalSince1970: 1_794_000_000),
                               version: "1.0（42）", signExpires: nil, recording: true, pending: 2, lastProcessed: nil)
        let text = String(decoding: try status.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"written\" : \"2026-11-"))
        XCTAssertTrue(text.contains("\"recording\" : true"))
    }

    /// 声の特徴だけを外したもの（音のひとこま無し）も、保存して読み戻せる
    func testSetAsideWithoutClip() throws {
        let marker = SpeakerLabeler.Sample(audio: "", start: 1_793_700_000, end: 0)
        let voice = SpeakerLabeler.Voice(embedding: [0.6, 0.8], pinned: false, added: Date(timeIntervalSince1970: 1_000), model: SpeakerLabeler.model)
        let item = SpeakerLabeler.SetAside(person: "12", sample: marker, voices: [voice, voice], at: .now, reason: "「自分」の決めた声に近かった、自動で覚えた声 2 個")
        XCTAssertFalse(item.hasClip)
        let back = try JSONDecoder().decode([SpeakerLabeler.SetAside].self, from: JSONEncoder().encode([item]))
        XCTAssertEqual(back.first?.voices.count, 2)
        XCTAssertEqual(back.first?.hasClip, false)
    }

    // MARK: - 変更の履歴・書き換えの上限（2026-11-06）

    func testHistoryKeepsFive() {
        var history: [ConversationLog.Line.Edit]?
        for i in 0..<7 {
            history = ConversationLog.Line.adding(.init(at: Date(timeIntervalSince1970: Double(i)), by: "夜の聞き直し", from: "文\(i)"), to: history)
        }
        XCTAssertEqual(history?.count, 5)
        XCTAssertEqual(history?.first?.from, "文2")
        XCTAssertEqual(history?.last?.from, "文6")
    }

    func testOldLineWithoutHistoryStillReads() throws {
        let json = #"{"time":0,"text":"こんにちは"}"#
        let line = try JSONDecoder().decode(ConversationLog.Line.self, from: Data(json.utf8))
        XCTAssertNil(line.history)
        XCTAssertNil(line.rubbed)
    }

    func testMayRewrite() {
        // 少しだけ変わる（3割以下）ならよい
        XCTAssertTrue(Pipeline.mayRewrite("明日の会義は十時から", "明日の会議は十時から", sure: 0.7))
        // 大きく変わるのは、とても確かなときか、前の文がほとんど無いときだけ
        XCTAssertFalse(Pipeline.mayRewrite("明日の会議は十時から", "昨日の飲み会は楽しかった", sure: 0.7))
        XCTAssertTrue(Pipeline.mayRewrite("明日の会議は十時から", "昨日の飲み会は楽しかった", sure: 0.9))
        XCTAssertTrue(Pipeline.mayRewrite("えっ", "えっと、それは", sure: 0.5))
    }

    // MARK: - 録音の帳簿（2026-11-06）

    private func state(_ minute: Double, recording: Bool = true, resting: Bool = false, charging: Bool? = nil,
                       battery: Double? = nil, held: Bool? = nil, base: Date) -> RecordingLedger.State {
        var s = RecordingLedger.State(at: base.addingTimeInterval(minute * 60), recording: recording, resting: resting,
                                      charging: charging, battery: battery, lowPower: false)
        s.held = held
        return s
    }

    func testGapMapAndReasons() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let recorded = [(base, base.addingTimeInterval(30 * 60)), (base.addingTimeInterval(90 * 60), base.addingTimeInterval(120 * 60))]
        // 30分〜60分は充電中、60分〜90分は静かで休み
        let states = [state(0, base: base), state(30, charging: true, base: base), state(60, resting: true, base: base),
                      state(75, resting: true, base: base)]
        let spans = RecordingLedger.spans(from: base, to: base.addingTimeInterval(120 * 60), recorded: recorded, states: states)
        let gaps = RecordingLedger.gaps(spans, states: states)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.minutes, 30)
        XCTAssertEqual(gaps.first?.reason, "時計の充電中")
        XCTAssertTrue(spans.contains { $0.kind == .quiet })
    }

    func testGapReasonWhenWatchStopped() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let states = [state(0, recording: false, base: base)]
        XCTAssertEqual(RecordingLedger.reason(from: base.addingTimeInterval(60), to: base.addingTimeInterval(1800), states: states),
                       "時計の録音が止まっていた")
        XCTAssertTrue(RecordingLedger.reason(from: base, to: base.addingTimeInterval(1800), states: []).hasPrefix("時計から知らせが無かった"))
    }

    func testBatteryForecast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 1時間で 10% 減っている → 残り 50% なら 4時間後に 10%
        let states = [state(-60, battery: 0.6, base: now), state(0, battery: 0.5, base: now)]
        let empty = RecordingLedger.batteryEmpty(states: states, now: now)
        XCTAssertNotNil(empty)
        XCTAssertEqual(empty?.timeIntervalSince(now) ?? 0, 4 * 3600, accuracy: 60)
        // 充電中なら予想しない
        XCTAssertNil(RecordingLedger.batteryEmpty(states: [state(-60, battery: 0.6, base: now),
                                                           state(0, charging: true, battery: 0.5, base: now)], now: now))
    }

    func testMorningReportLine() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let gap = RecordingLedger.Gap(start: base, end: base.addingTimeInterval(42 * 60), reason: "時計の充電中")
        var counts = RecordingLedger.Counts()
        counts.broken = 1
        let line = RecordingLedger.reportLine(gaps: [gap], counts: counts, uncertain: 12, unnamedVoices: 3)
        XCTAssertTrue(line.contains("録れていない時間 42分"))
        XCTAssertTrue(line.contains("壊れた区切り 1"))
        XCTAssertTrue(line.contains("自信の低い行 12"))
        XCTAssertTrue(line.contains("名前の無い声 3人"))
    }

    // MARK: - 名乗り・会議モード・音の見張り（2026-11-06）

    func testClaimedName() {
        XCTAssertEqual(NewVoiceBox.claimedName(in: "田中です。よろしくお願いします"), "田中")
        XCTAssertEqual(NewVoiceBox.claimedName(in: "はじめまして、佐藤と申します"), "佐藤")
        XCTAssertNil(NewVoiceBox.claimedName(in: "大丈夫です"))
        XCTAssertNil(NewVoiceBox.claimedName(in: "明日は田中さんが来るそうです"))
    }

    func testMeetingWords() {
        XCTAssertEqual(MeetingMode.words(title: "定例会議・新商品の件"), ["定例会議・新商品の件", "定例会議", "新商品の件"])
        XCTAssertTrue(MeetingMode.words(title: nil).isEmpty)
    }

    func testAudioCheckJudge() {
        func block(total: Double, low: Double = 0, high: Double, clipped: Int = 0) -> AudioCheck.Block {
            AudioCheck.Block(total: total, low: low, high: high, count: 8000, clipped: clipped)
        }
        // 声のある 0.5 秒（-20dBFS くらい）が30個、高い音がほとんど無い → こもっている
        let muffled = AudioCheck.judge(Array(repeating: block(total: 80, high: 0.01), count: 30))
        XCTAssertTrue(muffled.muffled)
        let clear = AudioCheck.judge(Array(repeating: block(total: 80, high: 5), count: 30))
        XCTAssertFalse(clear.muffled)
        // 振り切れが多い → 割れている
        XCTAssertTrue(AudioCheck.judge([block(total: 80, high: 5, clipped: 100)]).clipped)
        // 低い音が大半 → こすれ・風
        let rub = AudioCheck.judge([block(total: 80, high: 5), block(total: 80, low: 70, high: 1)])
        XCTAssertEqual(rub.rubbed, [0.5...1.0])
        XCTAssertTrue(rub.rubbed(from: 0.5, to: 1.0))
        XCTAssertFalse(rub.rubbed(from: 0, to: 0.5))
    }

    func testUncertainMarks() {
        let text = "田中さんに3000円を15時までに"
        let marked = UncertainMarks.ranges(in: text).map { String(text[$0]) }
        XCTAssertEqual(marked, ["田中さん", "3000円", "15時"])
    }

    // MARK: - タスクの繰り返し・時刻・PC の速さ・車の機器（2026-11-06）

    func testRepeatNext() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let friday = cal.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        XCTAssertEqual(cal.component(.weekday, from: TaskBook.Repeat.weekdays.next(after: friday, calendar: cal)), 2) // 月曜
        XCTAssertEqual(TaskBook.Repeat.weekly.next(after: friday, calendar: cal), cal.date(byAdding: .day, value: 7, to: friday))
        XCTAssertEqual(cal.component(.month, from: TaskBook.Repeat.monthly.next(after: friday, calendar: cal)), 12)
    }

    func testNextRepeatMakesFreshItem() {
        var item = TaskBook.Item(what: "週の報告", said: .now, source: .manual, state: .done, work: true)
        XCTAssertNil(TaskBook.nextRepeat(of: item))
        item.repeats = .weekly
        item.postponed = 2
        item.dueTime = 15 * 60
        item.due = Calendar.current.startOfDay(for: .now)
        let next = TaskBook.nextRepeat(of: item)
        XCTAssertNotNil(next)
        XCTAssertNotEqual(next?.id, item.id)
        XCTAssertEqual(next?.state, .open)
        XCTAssertNil(next?.postponed)
        XCTAssertEqual(next?.dueTime, 15 * 60)
        XCTAssertGreaterThan(next?.due ?? .distantPast, item.due ?? .distantFuture)
    }

    func testDueMoment() {
        var item = TaskBook.Item(what: "提出", said: .now, source: .manual, state: .open, work: true)
        let day = Calendar.current.startOfDay(for: .now)
        item.due = day
        XCTAssertEqual(item.dueMoment, day)
        item.dueTime = 15 * 60
        XCTAssertEqual(item.dueMoment, day.addingTimeInterval(15 * 3600))
    }

    func testOldTaskWithoutNewFieldsStillReads() throws {
        let item = TaskBook.Item(what: "古い", said: Date(timeIntervalSince1970: 0), source: .manual, state: .open, work: true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        json["dueTime"] = nil
        json["repeats"] = nil
        json["reminderID"] = nil
        let back = try JSONDecoder().decode(TaskBook.Item.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.repeats)
        XCTAssertNil(back.dueTime)
    }

    func testHintLimitFollowsSpeed() {
        XCTAssertEqual(HomePC.hintLimit(speed: nil), 80)
        XCTAssertEqual(HomePC.hintLimit(speed: 0.3), 80)
        XCTAssertEqual(HomePC.hintLimit(speed: 0.7), 45)
        XCTAssertEqual(HomePC.hintLimit(speed: 1.9), 25)
    }

    func testExtraQuestionsEarly() {
        XCTAssertEqual(AnswerKey.extraCount(weeksSoFar: 0), 8)
        XCTAssertEqual(AnswerKey.extraCount(weeksSoFar: 1), 8)
        XCTAssertEqual(AnswerKey.extraCount(weeksSoFar: 2), 3)
    }

    func testChosenCarDevice() {
        XCTAssertTrue(CarAudioLog.isCar("TOYOTA Audio", chosen: [:]))
        XCTAssertFalse(CarAudioLog.isCar("Pioneer DEH", chosen: [:]))
        XCTAssertTrue(CarAudioLog.isCar("Pioneer DEH", chosen: ["Pioneer DEH": true]))
        XCTAssertFalse(CarAudioLog.isCar("TOYOTA Audio", chosen: ["TOYOTA Audio": false]))
    }

    func testCloudLogCounts() {
        let now = Date.now
        let entries = [
            CloudLog.Entry(at: now, service: "Groq（文字起こし）", what: "a", work: nil, size: 1),
            CloudLog.Entry(at: now, service: "Groq（言語モデル）", what: "b", work: true, size: 1),
            CloudLog.Entry(at: now, service: "Groq（言語モデル）", what: "c", work: false, size: 1),
            CloudLog.Entry(at: now.addingTimeInterval(-62 * 24 * 3600), service: "OpenAI（文字起こし）", what: "d", work: nil, size: 1),
        ]
        let counts = CloudLog.counts(entries, month: now)
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts.first { $0.service == "Groq（言語モデル）" }?.count, 2)
        XCTAssertEqual(counts.first { $0.service == "Groq（言語モデル）" }?.work, 1)
    }

    // MARK: - 時間帯・場所・取り違え・しきい値・費用（2026-11-06）

    func testConvertedNameAcrossTimeZones() {
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
        let converted = Storage.convertedName("20261106-080000.m4a", from: honolulu)
        // ホノルルの 8:00 は、この端末の時間帯の同じ瞬間になる
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = honolulu
        let moment = f.date(from: "20261106-080000")!
        XCTAssertEqual(Storage.startDate(of: URL(fileURLWithPath: "/tmp/" + converted)), moment)
        XCTAssertTrue(converted.hasSuffix(".m4a"))
        // 同じ時間帯・時間帯が分からないときはそのまま
        XCTAssertEqual(Storage.convertedName("20261106-080000.m4a", from: nil), "20261106-080000.m4a")
        XCTAssertEqual(Storage.convertedName("20261106-080000.m4a", from: TimeZone.current), "20261106-080000.m4a")
    }

    func testUnsurePlace() {
        XCTAssertFalse(PlaceLog.isUnsure(accuracy: 30, age: 60))
        XCTAssertTrue(PlaceLog.isUnsure(accuracy: 400, age: 60))
        XCTAssertTrue(PlaceLog.isUnsure(accuracy: 30, age: 3600))
        XCTAssertEqual(WordStats.placeKey("たぶん渋谷駅近く"), "渋谷駅近く")
    }

    func testMisheardPlace() {
        let history = [(place: "職場", count: 14), (place: "家", count: 1)]
        XCTAssertTrue(Pipeline.looksMisheardPlace(history: history, place: "家", lines: 2))
        XCTAssertFalse(Pipeline.looksMisheardPlace(history: history, place: "職場", lines: 2))
        XCTAssertFalse(Pipeline.looksMisheardPlace(history: history, place: "家", lines: 8))
        XCTAssertFalse(Pipeline.looksMisheardPlace(history: [(place: "家", count: 1)], place: "家", lines: 1))
    }

    func testBestUncertainLine() {
        func sample(_ i: Int, confidence: Double, wrong: Bool) -> AnswerKey.Sample {
            var s = AnswerKey.Sample(id: "\(i)", week: "w", day: "d", time: .now, text: "今日は会議があります",
                                     speaker: nil, speakerID: nil, place: nil, title: nil, audio: "a", offset: 0,
                                     confidence: confidence, noisy: nil)
            s.rightText = wrong ? "今日は飲み会があります" : s.text
            s.answered = .now
            return s
        }
        // 0.5 より低い行はだいたい間違い、高い行は合っている
        var samples: [AnswerKey.Sample] = []
        for i in 0..<20 { samples.append(sample(i, confidence: 0.3 + Double(i % 4) * 0.04, wrong: true)) }
        for i in 20..<40 { samples.append(sample(i, confidence: 0.6 + Double(i % 4) * 0.08, wrong: false)) }
        let line = AnswerKey.bestUncertainLine(samples)
        XCTAssertNotNil(line)
        XCTAssertGreaterThanOrEqual(line ?? 0, 0.45)
        XCTAssertLessThanOrEqual(line ?? 1, 0.6)
        // 30問より少なければ決めない
        XCTAssertNil(AnswerKey.bestUncertainLine(Array(samples.prefix(20))))
    }

    func testLiveNoiseFloor() {
        let quiet = [Float](repeating: 0.001, count: 16_000)
        let loud = [Float](repeating: 0.1, count: 16_000)
        XCTAssertLessThan(LiveTranscriber.noiseFloor(quiet), -40)
        XCTAssertGreaterThan(LiveTranscriber.noiseFloor(loud), -40)
    }

    func testCostAndQuotaText() {
        // 32kbps で1分 = 240,000 バイト → 0.006 ドル
        let entries = [CloudLog.Entry(at: .now, service: "OpenAI（文字起こし）", what: "a", work: nil, size: 240_000)]
        XCTAssertEqual(CloudLog.openAICost(entries), 0.006, accuracy: 0.0001)
        XCTAssertEqual(CloudLog.quotaText((used: 3 * 1_073_741_824, limit: 15 * 1_073_741_824)), "3.0GB / 15.0GB（20%）")
        XCTAssertEqual(CloudLog.quotaText((used: 1_073_741_824, limit: nil)), "1.0GB 使用")
    }

    // MARK: - 通しテスト: 文字にした行 → 良いほうを選ぶ → 書き出し待ち → 記録の行（2026-11-06）

    func testThroughMergerToRecord() throws {
        let mergeFile = URL.applicationSupportDirectory.appendingPathComponent("merge.json")
        let saved = try? Data(contentsOf: mergeFile)
        try? FileManager.default.removeItem(at: mergeFile)
        defer {
            try? FileManager.default.removeItem(at: mergeFile)
            if let saved { try? saved.write(to: mergeFile) }
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func heard(_ text: String, at offset: TimeInterval, watch: Bool, weight: Double, audio: String) -> Merger.Heard {
            let line = ConversationLog.Line(time: start.addingTimeInterval(offset), speaker: "自分", text: text,
                                            audio: audio, offset: offset, speakerID: SpeakerLabeler.selfID, confidence: 0.9)
            return Merger.Heard(line: line, end: start.addingTimeInterval(offset + 4), fromWatch: watch, weight: weight)
        }
        let merger = Merger()
        // 同じ発言を iPhone と時計の両方で聞いた。時計のほうがよく聞き取れている
        merger.add([heard("きょうはかいぎ", at: 1, watch: false, weight: 4, audio: "20270115-080000.m4a")])
        merger.add([heard("今日は会議があります", at: 1, watch: true, weight: 10, audio: "20270115-080000-w.m4a"),
                    heard("資料は3000円です", at: 6, watch: true, weight: 9, audio: "20270115-080000-w.m4a")])
        _ = merger.release(before: start.addingTimeInterval(600))
        let texts = merger.outbox.map(\.text)
        XCTAssertTrue(texts.contains("今日は会議があります"), "よく聞き取れた時計の文を選ぶ: \(texts)")
        XCTAssertFalse(texts.contains("きょうはかいぎ"), "同じ発言を二度書かない: \(texts)")
        XCTAssertTrue(texts.contains("資料は3000円です"))
        // 記録の行の形
        let doc = ConversationLog.docLine(merger.outbox[0])
        XCTAssertTrue(doc.contains("今日は会議があります"))
        // 書き終えたら書き出し待ちから消える
        merger.sent(merger.outbox.count)
        XCTAssertTrue(merger.outbox.isEmpty)
    }

    // MARK: - 声のひとこまと行の結び付け（2026-11-06）

    func testSampleMatchesOnlyRealOverlap() {
        // 「文句なしキャプテン。」（10文字）を 0 秒に言い、次の行は 30 秒。あいだは黙っていた
        let lines: [(offset: TimeInterval, chars: Int)] = [(0, 10), (30, 8)]
        XCTAssertEqual(Pipeline.lineEnds(lines)[0], 2.6, accuracy: 0.01)
        // 黙っていた時間のひとこまには、もうセリフを付けない（前は次の行の頭まで続くとみなして付けていた）
        XCTAssertTrue(Pipeline.matchLines(lines, sample: (start: 10, end: 15)).indices.isEmpty)
        // セリフとしっかり重なるひとこま
        let firm = Pipeline.matchLines(lines, sample: (start: 0.5, end: 3))
        XCTAssertEqual(firm.indices, [0])
        XCTAssertFalse(firm.loose)
        // 少しだけ重なるひとこまは、ずれているかもしれない印を付ける
        let loose = Pipeline.matchLines(lines, sample: (start: 2.4, end: 10))
        XCTAssertEqual(loose.indices, [0])
        XCTAssertTrue(loose.loose)
        // 次の行の頭は超えない
        XCTAssertEqual(Pipeline.lineEnds([(0, 40), (3, 5)])[0], 3, accuracy: 0.01)
    }
}

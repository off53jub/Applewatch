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
}

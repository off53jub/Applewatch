import XCTest
@testable import LifeLog

/// 記録を壊しうる処理（同期の合わせ方・消す行の見つけ方）と、名前の取り出しを確かめる。
/// CI（.github/workflows/tests.yml）が iPhone のシミュレーターで動かす。
@MainActor
final class LogicTests: XCTestCase {
    // MARK: - 名前

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
}

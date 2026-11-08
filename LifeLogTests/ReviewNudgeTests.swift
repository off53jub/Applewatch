import XCTest
@testable import LifeLog

/// 毎朝の「聞いて直す」（2026-11-07。ReviewNudge.swift）を確かめる。
/// 1. 選ぶ行（確からしさが低い・モデルが食い違った・材料にできる長さ）と、選び方（度合いの順・1つの会話から3行まで・時刻の順）
/// 2. いま答える行と次の行・片付け（前の日のまだの行・送り終えた行の音）・「合っている」を材料の形にする
/// 3. 朝の読み上げの1文（全部で8文まで）・知らせ・入口の文
/// 4. 材料の数（/train-status の読み方・あと何個か・送った印が夜の送り方と同じ形）と、切り出す所
@MainActor
final class ReviewNudgeTests: XCTestCase {
    /// 2026-11-07T06:58:25Z
    private let t0 = Date(timeIntervalSince1970: 1_794_034_705)

    private func line(_ text: String, at seconds: TimeInterval = 0, confidence: Double? = 0.3,
                      audio: String? = "20261107-155800-w.m4a", offset: TimeInterval? = 3, end: TimeInterval? = nil,
                      votes: [String: String]? = nil, checked: Bool? = nil, media: String? = nil) -> ConversationLog.Line {
        var l = ConversationLog.Line(time: t0.addingTimeInterval(seconds), speaker: nil, text: text, audio: audio, offset: offset)
        l.confidence = confidence
        l.end = end
        l.votes = votes
        l.checked = checked
        l.media = media
        return l
    }

    private func item(_ id: String, at seconds: TimeInterval = 0, talk: TimeInterval = 0, setDay: String = "2026-11-07",
                      answer: ReviewNudge.Answer? = nil, right: String? = nil, answered: Date? = nil,
                      clip: String? = nil) -> ReviewNudge.Item {
        var x = ReviewNudge.Item(id: id, setDay: setDay, day: "2026-11-07", talk: t0.addingTimeInterval(talk),
                                 time: t0.addingTimeInterval(seconds), text: "明日の会議は十時からです", audio: "a.m4a",
                                 offset: 1.0, reasons: [.low])
        x.answer = answer
        x.right = right
        x.answered = answered
        x.clip = clip
        if clip != nil {
            x.clipFrom = 0
            x.clipTo = 17.5
        }
        return x
    }

    // MARK: - 1. 選ぶ行

    func testVotesDisagree() {
        XCTAssertFalse(ReviewNudge.votesDisagree(line("明日は会議です")))
        // 句読点・空白の違いは食い違いにしない
        XCTAssertFalse(ReviewNudge.votesDisagree(line("明日は会議です", votes: ["haas": "明日は会議です。", "reazon": "明日は 会議です"])))
        XCTAssertTrue(ReviewNudge.votesDisagree(line("明日は会議です", votes: ["haas": "明日は会議です", "whisper": "明日は会議でした"])))
        // 票が1つでも、記録の文と違えば食い違い
        XCTAssertTrue(ReviewNudge.votesDisagree(line("明日は会議です", votes: ["haas": "明日は懐疑です"])))
        XCTAssertFalse(ReviewNudge.votesDisagree(line("明日は会議です", votes: ["haas": ""])))
    }

    func testReasonsSkipFixedAndBroadcastLines() {
        XCTAssertEqual(ReviewNudge.reasons(line("明日は会議です", confidence: 0.1, checked: true)), [])
        XCTAssertEqual(ReviewNudge.reasons(line("明日は会議です", confidence: 0.1, media: "テレビ")), [])
        let split = ReviewNudge.reasons(line("明日は会議です", confidence: 0.95, votes: ["haas": "明日は懐疑です"]))
        XCTAssertTrue(split.contains(.votes))
        // 学んだ重みが無いときは、確からしさの線（0.30〜0.70）で決まる
        if Calibration.weights == nil {
            XCTAssertFalse(split.contains(.low))
            XCTAssertEqual(ReviewNudge.reasons(line("明日は会議です", confidence: 0.2)), [.low])
            XCTAssertEqual(ReviewNudge.reasons(line("明日は会議です", confidence: 0.95)), [])
        }
    }

    func testUsableLines() {
        XCTAssertTrue(ReviewNudge.usable(line("明日の会議は十時からです")))
        XCTAssertFalse(ReviewNudge.usable(line("明日の会議は十時からです", audio: nil)))
        XCTAssertFalse(ReviewNudge.usable(line("明日の会議は十時からです", offset: nil)))
        XCTAssertFalse(ReviewNudge.usable(line("明日の会議は十時からです", checked: true)))
        XCTAssertFalse(ReviewNudge.usable(line("明日の会議は十時からです", media: "動画")))
        // 4文字より短い行（句読点は数えない）
        XCTAssertFalse(ReviewNudge.usable(line("はい。")))
        XCTAssertTrue(ReviewNudge.usable(line("そうですね")))
        // 終わりが分かる行は、音声の区間が 0.5〜25 秒のものだけ
        XCTAssertTrue(ReviewNudge.usable(line("明日の会議は十時からです", offset: 3, end: 8)))
        XCTAssertFalse(ReviewNudge.usable(line("明日の会議は十時からです", offset: 3, end: 33)))
        XCTAssertFalse(ReviewNudge.usable(line("明日の会議は十時からです", offset: 3, end: 3.2)))
        // 終わりが分からない行は80文字まで（夜に送るときは文字数で長さを見積もり、15秒までにするため）
        XCTAssertTrue(ReviewNudge.usable(line(String(repeating: "あ", count: 80))))
        XCTAssertFalse(ReviewNudge.usable(line(String(repeating: "あ", count: 81))))
    }

    func testScore() {
        XCTAssertEqual(ReviewNudge.score(confidence: 0.2, chance: nil, votes: false, local: false), 0.8, accuracy: 1e-9)
        XCTAssertEqual(ReviewNudge.score(confidence: 0.2, chance: nil, votes: true, local: false), 0.95, accuracy: 1e-9)
        XCTAssertEqual(ReviewNudge.score(confidence: 0.2, chance: nil, votes: false, local: true), 0.9, accuracy: 1e-9)
        // 学んだ見込みがあれば、そちらを使う
        XCTAssertEqual(ReviewNudge.score(confidence: 0.2, chance: 0.3, votes: false, local: false), 0.3, accuracy: 1e-9)
        XCTAssertEqual(ReviewNudge.score(confidence: nil, chance: nil, votes: false, local: false), 0.4, accuracy: 1e-9)
    }

    func testItemFromLine() throws {
        var c = ConversationLog.Conversation(start: t0, end: t0.addingTimeInterval(300), docIndex: 1)
        c.title = "来週の打ち合わせ"
        c.place = "会社"
        let l = line("明日の会議は十時からです", at: 30, offset: 12, end: 15, votes: ["haas": "明日の懐疑は十時からです"])
        let id = ReviewNudge.itemID(day: "2026-11-07", time: l.time)
        XCTAssertEqual(id, "2026-11-07|1794034735")
        let x = try XCTUnwrap(ReviewNudge.item(l, id: id, day: "2026-11-07", conversation: c, reasons: [.votes]))
        XCTAssertEqual(x.talk, t0)
        XCTAssertEqual(x.offset, 12)
        XCTAssertEqual(x.end, 15)
        XCTAssertEqual(x.title, "来週の打ち合わせ")
        XCTAssertEqual(x.place, "会社")
        XCTAssertEqual(x.votes?["haas"], "明日の懐疑は十時からです")
        XCTAssertNil(x.answer)
        XCTAssertNil(ReviewNudge.item(line("明日の会議です", audio: nil), id: id, day: "2026-11-07", conversation: c, reasons: [.low]))
    }

    func testPickPrefersHigherScoresAndCapsEachConversation() {
        // 会話 A に5行（度合い 0.9〜0.5）、会話 B に3行（0.4〜0.2）
        var candidates: [ReviewNudge.Candidate] = []
        for (i, score) in [0.9, 0.8, 0.7, 0.6, 0.5].enumerated() {
            candidates.append(.init(item: item("a\(i)", at: Double(100 - i), talk: 0), score: score))
        }
        for (i, score) in [0.4, 0.3, 0.2].enumerated() {
            candidates.append(.init(item: item("b\(i)", at: Double(500 + i), talk: 400), score: score))
        }
        let all = ReviewNudge.pick(candidates, count: 10)
        // 1つの会話から3行まで
        XCTAssertEqual(all.map(\.id).sorted(), ["a0", "a1", "a2", "b0", "b1", "b2"])
        // 時刻の順
        XCTAssertEqual(all.map(\.time), all.map(\.time).sorted())
        let four = ReviewNudge.pick(candidates, count: 4)
        XCTAssertEqual(Set(four.map(\.id)), ["a0", "a1", "a2", "b0"])
        // 同じ行は2度選ばない
        let twice = ReviewNudge.pick(candidates + [.init(item: item("a0", at: 100), score: 0.95)], count: 10)
        XCTAssertEqual(twice.filter { $0.id == "a0" }.count, 1)
        XCTAssertTrue(ReviewNudge.pick([], count: 10).isEmpty)
    }

    // MARK: - 2. 答える・片付ける

    func testCurrentAndNext() {
        let items = [item("a", at: 0, answer: .ok, right: "x"), item("b", at: 10), item("c", at: 20)]
        XCTAssertEqual(ReviewNudge.current(in: items, chosen: nil)?.id, "b")
        XCTAssertEqual(ReviewNudge.current(in: items, chosen: "c")?.id, "c")
        // 答えた行を選んでいても、まだの行に進む
        XCTAssertEqual(ReviewNudge.current(in: items, chosen: "a")?.id, "b")
        XCTAssertEqual(ReviewNudge.next(in: items, after: "b")?.id, "c")
        // 後ろにまだの行が無ければ、前のまだの行へ
        XCTAssertEqual(ReviewNudge.next(in: items, after: "c")?.id, "b")
        let done = items.map { x -> ReviewNudge.Item in
            var y = x
            y.answer = .skipped
            return y
        }
        XCTAssertNil(ReviewNudge.next(in: done, after: "c"))
        XCTAssertNil(ReviewNudge.current(in: done, chosen: nil))
    }

    func testPrunedDropsOldOpenItemsAndUnneededClips() {
        let now = t0
        let day: TimeInterval = 86400
        let sentRight = "明日の会議は十時からです"
        let sent: Set<String> = [PersonalMaterial.sampleID(audio: "a.m4a", offset: 1.0, right: sentRight)]
        let items = [
            item("old-open", setDay: "2026-11-06", clip: "old-open.m4a"),
            item("today-open", clip: "today-open.m4a"),
            item("old-skip", answer: .skipped, answered: now.addingTimeInterval(-15 * day)),
            item("new-skip", answer: .skipped, answered: now.addingTimeInterval(-day), clip: "new-skip.m4a"),
            item("sent-ok", answer: .ok, right: sentRight, answered: now.addingTimeInterval(-2 * day), clip: "sent-ok.m4a"),
            item("waiting-ok", answer: .ok, right: "別の文です", answered: now.addingTimeInterval(-2 * day), clip: "waiting-ok.m4a"),
            item("old-fix", answer: .fixed, right: "直した文です", answered: now.addingTimeInterval(-31 * day), clip: "old-fix.m4a"),
        ]
        let result = ReviewNudge.pruned(items, today: "2026-11-07", now: now, sent: sent)
        XCTAssertEqual(result.items.map(\.id), ["today-open", "new-skip", "sent-ok", "waiting-ok"])
        XCTAssertEqual(Set(result.removedClips), ["old-open.m4a", "new-skip.m4a", "sent-ok.m4a", "old-fix.m4a"])
        // まだ送っていない行と、今日のまだの行の音は残す
        func kept(_ id: String) -> ReviewNudge.Item? { result.items.first(where: { $0.id == id }) }
        XCTAssertEqual(kept("waiting-ok")?.clip, "waiting-ok.m4a")
        XCTAssertEqual(kept("today-open")?.clip, "today-open.m4a")
        XCTAssertNil(kept("sent-ok")?.clip)
        XCTAssertNotNil(kept("sent-ok"))
    }

    func testTruthOnlyForOkAnswers() throws {
        var ok = item("ok", answer: .ok, right: "  明日の会議は十時からです ")
        ok.end = 4.5
        ok.votes = ["haas": "明日の懐疑は十時からです"]
        ok.noisy = true
        let truth = try XCTUnwrap(ReviewNudge.truth(ok))
        XCTAssertEqual(truth.right, "明日の会議は十時からです")
        XCTAssertEqual(truth.audio, "a.m4a")
        XCTAssertEqual(truth.offset, 1.0)
        XCTAssertEqual(truth.end, 4.5)
        XCTAssertEqual(truth.time, ok.time)
        XCTAssertTrue(truth.noisy)
        XCTAssertEqual(truth.votes?["haas"], "明日の懐疑は十時からです")
        // 直した行は手で直した行として送るので、ここでは作らない。飛ばした行・空の文も作らない
        XCTAssertNil(ReviewNudge.truth(item("fix", answer: .fixed, right: "直した文です")))
        XCTAssertNil(ReviewNudge.truth(item("skip", answer: .skipped)))
        XCTAssertNil(ReviewNudge.truth(item("blank", answer: .ok, right: "  ")))
        XCTAssertNil(ReviewNudge.truth(item("open")))
    }

    func testItemsStillReadWhenValuesAreUnknown() throws {
        var x = item("x", answer: .ok, right: "明日の会議は十時からです", answered: t0, clip: "x.m4a")
        x.reasons = [.votes, .low]
        let data = try JSONEncoder().encode([x])
        XCTAssertEqual(try JSONDecoder().decode([ReviewNudge.Item].self, from: data), [x])
        // あとの版で答えやわけの種類が増えても、読めなくしない
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        objects[0]["answer"] = "maybe"
        objects[0]["reasons"] = ["votes", "speaker"]
        let changed = try JSONSerialization.data(withJSONObject: objects)
        let back = try XCTUnwrap(try JSONDecoder().decode([ReviewNudge.Item].self, from: changed).first)
        XCTAssertEqual(back.answer, .skipped)
        XCTAssertEqual(back.reasons, [.votes, .low])
    }

    // MARK: - 3. 文

    func testTexts() {
        XCTAssertEqual(ReviewNudge.minutes(for: 10), 3)
        XCTAssertEqual(ReviewNudge.minutes(for: 7), 2)
        XCTAssertEqual(ReviewNudge.minutes(for: 1), 1)
        XCTAssertEqual(ReviewNudge.entryTitle(total: 10, left: 10), "今日の聞いて直す（10行・3分ほど）")
        XCTAssertEqual(ReviewNudge.entryTitle(total: 10, left: 4), "今日の聞いて直す（あと 4 行・1分ほど）")
        XCTAssertNil(ReviewNudge.briefSentence(count: 0))
        XCTAssertEqual(ReviewNudge.briefSentence(count: 10), "今日の聞いて直すは10行、3分ほどです。")
        XCTAssertNil(ReviewNudge.noticeLine(count: 0))
        XCTAssertEqual(ReviewNudge.noticeLine(count: 10), "今日の聞いて直す: 10行（3分ほど）")
        XCTAssertTrue(ReviewNudge.noticeBody(count: 6).hasPrefix("6行・2分ほどです。"))
        XCTAssertEqual(ReviewNudge.reasonText([.low, .votes]), "確からしさが低い・モデルが食い違った")
    }

    func testAlternatives() {
        let votes = ["whisper": "明日の会議は十時からです", "haas": "明日の懐疑は十時からです", "reazon": "明日の懐疑は、十時からです。"]
        // 今の文と同じもの・句読点だけ違うものは出さない
        XCTAssertEqual(ReviewNudge.alternatives(votes, current: "明日の会議は十時からです"), ["明日の懐疑は十時からです"])
        XCTAssertEqual(ReviewNudge.alternatives(nil, current: "明日の会議は十時からです"), [])
    }

    // MARK: - 4. 材料の数と音

    func testTrainStatusReply() throws {
        func parse(_ json: String) throws -> (count: Int, model: Bool, need: Int) {
            try HomePC.trainStatusReply(Data(json.utf8))
        }
        let plain = try parse(#"{"count": 120, "model": false, "trained": null}"#)
        XCTAssertEqual(plain.count, 120)
        XCTAssertFalse(plain.model)
        XCTAssertEqual(plain.need, 300)
        // PC の自動の学び直しの設定に数があれば、それを使う
        let auto = try parse(#"{"count": 350, "model": true, "auto": {"min_samples": 400, "state": "待っています"}}"#)
        XCTAssertEqual(auto.count, 350)
        XCTAssertTrue(auto.model)
        XCTAssertEqual(auto.need, 400)
        // 形が違うときは 300
        XCTAssertEqual(try parse(#"{"count": 5, "model": false, "auto": {"min_samples": "x"}}"#).need, 300)
        XCTAssertEqual(try parse(#"{"count": 5, "model": false, "auto": "壊れた"}"#).need, 300)
        XCTAssertEqual(try parse(#"{"count": 5, "model": false, "auto": {"min_samples": 0}}"#).need, 300)
        XCTAssertThrowsError(try parse(#"{"model": false}"#))
    }

    func testPersonalMaterialText() {
        let some = PersonalMaterial.Status(count: 120, need: 300, model: false, at: t0)
        XCTAssertEqual(some.left, 180)
        XCTAssertEqual(PersonalMaterial.text(some), "120 個・学び直しまであと 180 個（300 個から）")
        let enough = PersonalMaterial.Status(count: 320, need: 300, model: false, at: t0)
        XCTAssertEqual(enough.left, 0)
        XCTAssertEqual(PersonalMaterial.text(enough), "320 個・学び直せる数です（300 個から）")
    }

    func testTallyRows() {
        // 自己点検の「効き目」: 聞いて直すで答えた数と、PC が受け付けなかった材料の数（数だけ。文は入れない）
        let rows = Tally.report(["review.fixed": 2, "review.ok": 5, "review.skipped": 1, "personal.sent": 3, "personal.refused": 1])
        XCTAssertTrue(rows.contains { $0.label == "聞いて直す" && $0.value == "直した 2・合っている 5・飛ばした 1" })
        XCTAssertTrue(rows.contains { $0.label == "あなた向けのモデルの材料" && $0.value == "PC に渡した 3 行・PC が受け付けなかった 1 行" })
        XCTAssertTrue(Tally.report(["personal.sent": 4]).contains { $0.value == "PC に渡した 4 行" })
        XCTAssertFalse(Tally.report([:]).contains { $0.label == "聞いて直す" })
    }

    func testSampleIDMatchesNightlyFormat() {
        // 夜に送るとき（sendPersonalSamples）の印と同じ形: 音声の名前|行の0.3秒前（小数1桁）|文
        XCTAssertEqual(PersonalMaterial.sampleID(audio: "a.m4a", offset: 1.0, right: "こんにちは"), "a.m4a|0.7|こんにちは")
        XCTAssertEqual(PersonalMaterial.sampleID(audio: "a.m4a", offset: 0.1, right: "こんにちは"), "a.m4a|0.0|こんにちは")
        let ok = item("ok", answer: .ok, right: "こんにちは")
        XCTAssertTrue(ReviewNudge.isSent(ok, ["a.m4a|0.7|こんにちは"]))
        XCTAssertFalse(ReviewNudge.isSent(ok, []))
        XCTAssertFalse(ReviewNudge.isSent(item("skip", answer: .skipped), ["a.m4a|0.7|こんにちは"]))
    }

    func testClipWindowCoversNightlySpan() throws {
        // 終わりが分からない行: 夜に送る区間（文字数で見積もる。15秒まで）がいつも中に入る
        let open = try XCTUnwrap(ReviewNudge.clipWindow(offset: 10, end: nil, duration: 0))
        XCTAssertEqual(open.from, 8.5, accuracy: 1e-9)
        XCTAssertEqual(open.to, 26.5, accuracy: 1e-9)
        let span = Benchmark.span(offset: 10, chars: 200)
        XCTAssertGreaterThanOrEqual(span.start, open.from)
        XCTAssertLessThanOrEqual(span.end, open.to)
        // 終わりが分かる行
        let known = try XCTUnwrap(ReviewNudge.clipWindow(offset: 10, end: 14, duration: 0))
        XCTAssertEqual(known.to, 15, accuracy: 1e-9)
        // 音声の長さより後ろは切らない。頭は 0 秒より前にしない
        XCTAssertEqual(try XCTUnwrap(ReviewNudge.clipWindow(offset: 10, end: nil, duration: 12)).to, 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ReviewNudge.clipWindow(offset: 0.5, end: 3, duration: 0)).from, 0, accuracy: 1e-9)
        XCTAssertNil(ReviewNudge.clipWindow(offset: 10, end: nil, duration: 8.6))
        XCTAssertEqual(ReviewNudge.clipName("2026-11-07|1794034735"), "2026-11-07_1794034735.m4a")
    }

    func testStopTime() {
        XCTAssertEqual(ReviewNudge.stop(offset: 3, end: 6, next: 4, chars: 10), 6, accuracy: 1e-9)
        // 終わりが分からなければ文字数で見積もり、同じ音声の次の行の頭で止める
        XCTAssertEqual(ReviewNudge.stop(offset: 3, end: nil, next: nil, chars: 10), 5.7, accuracy: 1e-9)
        XCTAssertEqual(ReviewNudge.stop(offset: 3, end: nil, next: 4.5, chars: 10), 4.5, accuracy: 1e-9)
        // 近すぎる次の行（0.5秒以内）は使わない
        XCTAssertEqual(ReviewNudge.stop(offset: 3, end: nil, next: 3.2, chars: 10), 5.7, accuracy: 1e-9)
        XCTAssertEqual(ReviewNudge.stop(offset: 3, end: nil, next: nil, chars: 500), 18, accuracy: 1e-9)
    }
}

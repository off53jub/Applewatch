import XCTest
@testable import LifeLog

/// 記録の正しさの手直し（2026-11-09）を確かめる。
/// 1. 長い会話の区切り（30分を超えたら20秒の間で、60分で必ず区切る）と、前の長い会話の分け直し
/// 2. 1日のまとめ（「やること」から「決まったこと」の書き写しを外す・1日の流れの塊は2時間まで）
/// 3. 名前の無い声の夜の整理（名前のある人・自分・手直しした声には触らない）
/// 4. 名前を付けた人を放送にしたときの、見出しの名前の外し方
/// 5. AI の質問で、答えても記録が変わらないものを外す
@MainActor
final class AccuracyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    private func line(_ seconds: TimeInterval, _ text: String = "うん") -> ConversationLog.Line {
        ConversationLog.Line(time: t0.addingTimeInterval(seconds), speaker: nil, text: text)
    }

    // MARK: - 1. 長い会話の区切り

    func testShortTalkIsNotCut() {
        // 20分のあいだ、10秒ごとに話していて、途中に25秒の間がある（30分より前なので区切らない）
        var lines = stride(from: 0.0, to: 600, by: 10).map { line($0) }
        lines += stride(from: 625.0, to: 1200, by: 10).map { line($0) }
        XCTAssertEqual(ConversationLog.segments(lines, openStart: nil).count, 1)
    }

    func testLongTalkIsCutAtPause() {
        // 35分続いたあと、25秒の間で区切る
        var lines = stride(from: 0.0, to: 2100, by: 10).map { line($0) }
        lines += stride(from: 2115.0, to: 2400, by: 10).map { line($0) }
        let parts = ConversationLog.segments(lines, openStart: nil)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1].first?.time, t0.addingTimeInterval(2115))
    }

    func testPauseCountsSpokenLength() {
        // 前の行が長い（100文字＝およそ17秒話していた）ので、始まりから30秒あいていても、間は13秒しかない
        let long = String(repeating: "あ", count: 100)
        let lines = stride(from: 0.0, to: 2000, by: 10).map { line($0) } + [line(2000, long), line(2030)]
        XCTAssertEqual(ConversationLog.segments(lines, openStart: nil).count, 1)
        XCTAssertTrue(ConversationLog.endsLongTalk(start: t0, last: line(2000, "うん"), lastTime: t0.addingTimeInterval(2000),
                                                   next: t0.addingTimeInterval(2030)))
    }

    func testHardCapAtSixtyMinutes() {
        // 間がまったく無くても、60分で区切る
        let lines = stride(from: 0.0, to: 4200, by: 10).map { line($0) }
        let parts = ConversationLog.segments(lines, openStart: nil)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1].first?.time, t0.addingTimeInterval(3600))
        // 続いている会話が50分前から始まっていれば、届いた行の10分目で区切る
        let more = stride(from: 3000.0, to: 3900, by: 10).map { line($0) }
        let cut = ConversationLog.segments(more, openStart: t0)
        XCTAssertEqual(cut.count, 2)
        XCTAssertEqual(cut[1].first?.time, t0.addingTimeInterval(3600))
    }

    func testOldLongConversationIsSplitIntoHours() {
        var c = ConversationLog.Conversation(start: t0, end: t0.addingTimeInterval(9000), docIndex: 1)
        c.lines = stride(from: 0.0, through: 9000, by: 10).map { line($0) }
        c.closed = true
        XCTAssertTrue(ConversationLog.needsLongSplit(c))
        let cuts = ConversationLog.longCuts(c.lines)
        XCTAssertEqual(cuts, [t0.addingTimeInterval(3600), t0.addingTimeInterval(7200)])
        // 見出しのある会話・まだ続いている会話・1時間より短い会話は分けない
        var titled = c
        titled.title = "見出し"
        XCTAssertFalse(ConversationLog.needsLongSplit(titled))
        var open = c
        open.closed = false
        XCTAssertFalse(ConversationLog.needsLongSplit(open))
        var short = c
        short.end = t0.addingTimeInterval(3000)
        XCTAssertFalse(ConversationLog.needsLongSplit(short))
    }

    // MARK: - 2. 1日のまとめ

    func testTodosDropCopiesOfDecisions() {
        let decisions = ["来週の会議は火曜に決まった"]
        let todos = ["来週の会議は火曜に決まった。", "資料を金曜までに送る", "資料を金曜までに 送る", "会議は火曜", ""]
        XCTAssertEqual(Summarizer.todosWithoutDecisions(todos, decisions: decisions), ["資料を金曜までに送る"])
        // 決まったことが無ければ、そのまま（重なりだけ外す）
        XCTAssertEqual(Summarizer.todosWithoutDecisions(["電話する", "電話する"], decisions: []), ["電話する"])
    }

    func testFlowBlocksAreAtMostTwoHours() {
        let hours: [Double] = [0, 1, 1.5, 3, 3.2]
        let starts = hours.map { t0.addingTimeInterval($0 * 3600) }
        let ends = starts.map { $0.addingTimeInterval(1800) }
        let out = ActivityBuilder.capped([(from: 0, to: 4, title: "仕事")], starts: starts, ends: ends)
        XCTAssertEqual(out.map { $0.from }, [0, 3])
        XCTAssertEqual(out.map { $0.to }, [2, 4])
        XCTAssertEqual(out.map { $0.title }, ["仕事", "仕事"])
        // 1つだけの塊はそのまま
        let one = ActivityBuilder.capped([(from: 0, to: 0, title: "a"), (from: 1, to: 2, title: "b")], starts: starts, ends: ends)
        XCTAssertEqual(one.count, 2)
    }

    // MARK: - 3. 名前の無い声の夜の整理

    private func voice(_ v: [Float], pinned: Bool = false) -> SpeakerLabeler.Voice {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return SpeakerLabeler.Voice(embedding: v.map { $0 / n }, pinned: pinned, added: t0, model: SpeakerLabeler.model)
    }

    private func person(_ id: String, name: String? = nil, _ v: [Float], seconds: Double = 60, pinned: Bool = false,
                        updated: Date? = nil, lastHeard: Date? = nil) -> SpeakerLabeler.Person {
        SpeakerLabeler.Person(id: id, name: name, context: nil, voices: [voice(v, pinned: pinned)], seconds: seconds,
                              lastHeard: lastHeard ?? t0, updated: updated)
    }

    func testTidyMergesOnlyUntouchedUnnamedVoices() {
        let near: [Float] = [1, 0.05, 0, 0], same: [Float] = [1, 0, 0, 0], far: [Float] = [0, 1, 0, 0]
        let people = [
            person(SpeakerLabeler.selfID, same, seconds: 9_999),
            person("1", name: "名前のある人", same, seconds: 5_000),
            person("u1", near, seconds: 10),
            person("u2", same, seconds: 100),
            person("u3", far, seconds: 50),
            person("u4", near, seconds: 20, pinned: true),
            person("u5", near, seconds: 30, updated: t0),
            person("u9", near, seconds: 5),
        ]
        let lines = Dictionary(uniqueKeysWithValues: people.map { ($0.id, 50) })
        let apart: Set<[String]> = [["u2", "u9"], ["u1", "u9"]]
        let plan = SpeakerLabeler.tidyPlan(people, lines: lines, apart: apart, keep: [], limit: 0.24, now: t0)
        XCTAssertEqual(plan.merges.map { $0.source }, ["u1"])
        XCTAssertEqual(plan.merges.map { $0.target }, ["u2"])
        XCTAssertTrue(plan.forget.isEmpty)
        // まとめた記録のある声には触らない
        let kept = SpeakerLabeler.tidyPlan(people, lines: lines, apart: apart, keep: ["u2"], limit: 0.24, now: t0)
        XCTAssertTrue(kept.merges.isEmpty)
        // 場（職場・職場以外）が違う声どうしはまとめない
        var work = person("w1", near, seconds: 10)
        work.context = .work
        let other = SpeakerLabeler.tidyPlan([work, person("w2", same, seconds: 100)], lines: ["w1": 50, "w2": 50],
                                            apart: [], keep: [], limit: 0.24, now: t0)
        XCTAssertTrue(other.merges.isEmpty)
    }

    func testTidyForgetsOnlyRareOldUnnamedVoices() {
        let day: TimeInterval = 86400
        let now = t0.addingTimeInterval(30 * day)
        let people = [
            person("old", [1, 0, 0, 0], lastHeard: t0),
            person("recent", [0, 1, 0, 0], lastHeard: now.addingTimeInterval(-day)),
            person("busy", [0, 0, 1, 0], lastHeard: t0),
            person("named", name: "名前", [0, 0, 0, 1], lastHeard: t0),
            person("fixed", [1, 1, 0, 0], pinned: true, lastHeard: t0),
            person(SpeakerLabeler.selfID, [1, 0, 1, 0], lastHeard: t0),
        ]
        let lines = ["old": 2, "recent": 1, "busy": 40, "named": 0, "fixed": 0]
        let plan = SpeakerLabeler.tidyPlan(people, lines: lines, apart: [], keep: [], limit: 0.24, now: now)
        XCTAssertEqual(plan.forget, ["old"])
        XCTAssertTrue(plan.merges.isEmpty)
    }

    // MARK: - 4. 放送にしたときの見出し

    func testHeadingFixesDropName() {
        func apply(_ text: String) -> String {
            ConversationLog.headingFixes(dropping: "アナウンス").reduce(text) { $0.replacingOccurrences(of: $1.find, with: $1.replace) }
        }
        XCTAssertEqual(apply("10:00〜10:30　駅　アナウンスと　乗りかえ"), "10:00〜10:30　駅　乗りかえ")
        XCTAssertEqual(apply("10:00〜10:30　駅　A、アナウンスと　乗りかえ"), "10:00〜10:30　駅　Aと　乗りかえ")
        XCTAssertEqual(apply("10:00〜10:30　駅　アナウンス、Aと　乗りかえ"), "10:00〜10:30　駅　Aと　乗りかえ")
        XCTAssertEqual(apply("10:00〜10:30　駅　A、アナウンス、Bと　乗りかえ"), "10:00〜10:30　駅　A、Bと　乗りかえ")
    }

    // MARK: - 5. AI の質問

    private func draft(_ kind: AskBook.Kind, _ question: String, subject: String) -> Summarizer.AskDraft {
        Summarizer.AskDraft(kind: kind, question: question, subject: subject, choices: [], quote: "", time: "")
    }

    func testQuestionsThatDoNotChangeRecordsAreDropped() {
        let lines = ["ポンって言った", "ポンズを買う", "スダチのポンズがいい", "人物12の話"]
        // 短い言葉の意味は聞かない
        XCTAssertFalse(Summarizer.keepsQuestion(draft(.word, "「ポン」はどういう意味？", subject: "ポン"), lines: lines, unnamedLines: [:]))
        XCTAssertFalse(Summarizer.keepsQuestion(draft(.what, "「ポン」の意味は？", subject: "ポン"), lines: lines, unnamedLines: [:]))
        // 2行より少ない行にしか出てこない言葉は聞かない
        XCTAssertFalse(Summarizer.keepsQuestion(draft(.word, "「スダチ」は聞き間違い？", subject: "スダチ"), lines: lines, unnamedLines: [:]))
        XCTAssertTrue(Summarizer.keepsQuestion(draft(.word, "「ポンズ」は聞き間違い？", subject: "ポンズ"), lines: lines, unnamedLines: [:]))
        // 名前の無い声がだれかは、その日によく話した声だけ
        XCTAssertFalse(Summarizer.keepsQuestion(draft(.who, "人物12はだれ？", subject: "人物12"), lines: lines, unnamedLines: ["人物12": 3]))
        XCTAssertTrue(Summarizer.keepsQuestion(draft(.who, "人物12はだれ？", subject: "人物12"), lines: lines, unnamedLines: ["人物12": 15]))
        XCTAssertTrue(Summarizer.keepsQuestion(draft(.who, "話に出た「部長」はだれ？", subject: "部長"), lines: lines, unnamedLines: [:]))
        XCTAssertTrue(Summarizer.keepsQuestion(draft(.decision, "火曜に決まった？", subject: ""), lines: lines, unnamedLines: [:]))
    }

    func testUnnamedVoicesInText() {
        XCTAssertEqual(Summarizer.unnamedVoices(in: "人物3と人物45の話"), ["人物3", "人物45"])
        XCTAssertTrue(Summarizer.unnamedVoices(in: "田中さん").isEmpty)
    }
}

import XCTest
@testable import LifeLog

/// s26 の A4（S26VVoice.swift）: 「この声は誰？」で発言と声を見せる・答えられないものは山に出さない
final class S26VTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func at(_ d: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m, second: s))!
    }

    private func voice(samples: [ReviewItem.Sample]? = nil, clips: [ReviewItem.Clip]? = nil,
                       evidence: [ReviewItem.Evidence]? = nil, speaker: String? = "5413") -> ReviewItem {
        ReviewItem(id: "spt-5413", kind: "voice", question: "人物5413 は、だれですか（自動ではまとめません）",
                   answer: "pick", choices: ["Aさん", "分からない"], evidence: evidence, group: "voice_top",
                   clips: clips, speaker_id: speaker, samples: samples)
    }

    // MARK: 読む

    func testDecodesNewFieldsAndOldItemsStillRead() throws {
        let json = """
        {"items":[{"id":"spt-5413","kind":"voice","question":"q","answer":"pick","speaker_id":"5413",
          "samples":[{"day":"2026-11-24","time":"09:08:12","text":"それでいこう"}]},
          {"id":"r-1","kind":"ramen","question":"q","answer":"yesno"}]}
        """
        let feed = try JSONDecoder().decode(ReviewQueueFeed.self, from: Data(json.utf8))
        let items = try XCTUnwrap(feed.items)
        XCTAssertEqual(items[0].speaker_id, "5413")
        XCTAssertEqual(items[0].samples?.first?.text, "それでいこう")
        XCTAssertNil(items[1].speaker_id)
        XCTAssertNil(items[1].samples)
    }

    // MARK: 種類と番号

    func testVoiceAskKinds() {
        XCTAssertTrue(S26VVoice.isVoiceAsk(voice()))
        let line = ReviewItem(id: "pc-1", kind: "speaker_line", question: "この声は ○○ さんですか", answer: "yesno")
        XCTAssertTrue(S26VVoice.isVoiceAsk(line))
        let pair = ReviewItem(id: "vp-1", kind: "voice_pair", question: "同じ人？", answer: "yesno")
        XCTAssertFalse(S26VVoice.isVoiceAsk(pair), "2 つの声が同じ人かは前のまま")
    }

    func testNumberFromSpeakerIDOrQuestion() {
        XCTAssertEqual(S26VVoice.number(voice()), "5413")
        XCTAssertEqual(S26VVoice.number(voice(speaker: nil)), "5413", "無ければ問いの「人物5413」から")
        let none = ReviewItem(id: "x", kind: "speaker_line", question: "この声は誰？", answer: "text")
        XCTAssertNil(S26VVoice.number(none))
    }

    // MARK: 見せる発言

    func testQuotesFromSamplesWithTimeAndNotesWithoutDuplicates() {
        let item = voice(samples: [.init(day: "2026-11-24", time: "09:08:12", text: "それでいこう"),
                                   .init(day: "2026-11-22", time: "18:30:00", text: "また来週")],
                         evidence: [.init(text: "11/24 09:08 「それでいこう」"), .init(text: "7 日で 702 行・3 日に出た声（仮）")])
        let q = S26VVoice.quotes(item)
        XCTAssertEqual(q, [.init(when: "11/24 09:08", text: "それでいこう"), .init(when: "11/22 18:30", text: "また来週")])
        XCTAssertEqual(S26VVoice.notes(item), ["7 日で 702 行・3 日に出た声（仮）"])
    }

    func testQuotesFallBackToEvidenceThenLocal() {
        let ev = voice(evidence: [.init(text: "11/24 09:08 「それでいこう」"), .init(text: "7 日で 702 行")])
        XCTAssertEqual(S26VVoice.quotes(ev).map(\.text), ["11/24 09:08 「それでいこう」"])
        let bare = voice(evidence: [.init(text: "7 日で 702 行・3 日に出た声（仮）")])
        let spot = S26VVoice.Spot(time: at(23, 21, 5), text: "おつかれ", audio: "a.m4a", offset: 12, end: nil)
        XCTAssertEqual(S26VVoice.quotes(bare, local: [spot], calendar: cal), [.init(when: "11/23 21:05", text: "「おつかれ」")])
        XCTAssertTrue(S26VVoice.quotes(bare).isEmpty)
    }

    // MARK: 出すか

    func testUnanswerableVoiceGoesBackAndLeavesThePile() {
        let bare = voice(evidence: [.init(text: "7 日で 702 行・3 日に出た声（仮）")])
        let withSample = ReviewItem(id: "spt-7", kind: "voice", question: "人物7 は、だれですか", answer: "pick",
                                    samples: [.init(day: "2026-11-24", time: "10:00:00", text: "はい")])
        let withClip = ReviewItem(id: "spt-8", kind: "voice", question: "人物8 は、だれですか", answer: "pick",
                                  clips: [.init(label: "声 1", path: "voice/clip?audio=a&start=1")])
        let ramen = ReviewItem(id: "r-1", kind: "ramen", question: "ラーメン？", answer: "yesno")
        XCTAssertFalse(S26VVoice.answerable(bare))
        XCTAssertTrue(S26VVoice.answerable(withSample))
        XCTAssertTrue(S26VVoice.answerable(withClip))
        XCTAssertTrue(S26VVoice.answerable(ramen))
        let list = [bare, withSample, ramen, withClip]
        XCTAssertEqual(S26VVoice.order(list).map(\.id), ["spt-7", "r-1", "spt-8", "spt-5413"], "消さずに後ろへ")
        XCTAssertEqual(S26VVoice.forPile(list).map(\.id), ["spt-7", "r-1", "spt-8"])
    }

    func testEmptySampleTextDoesNotCount() {
        XCTAssertFalse(S26VVoice.answerable(voice(samples: [.init(day: "2026-11-24", time: "09:00:00", text: " ")])))
    }

    // MARK: 鳴らす行を選ぶ

    private func line(_ time: Date, _ speaker: String?, _ text: String, audio: String? = "a.m4a", offset: Double? = 10,
                      id: String? = nil) -> ConversationLog.Line {
        ConversationLog.Line(time: time, speaker: speaker, text: text, audio: audio, offset: offset, speakerID: id)
    }

    func testPickNewestTwoWithAudio() {
        let lines = [line(at(20, 9, 0), "人物5413", "古い"),
                     line(at(24, 9, 0), "人物5413", "音なし", audio: nil),
                     line(at(23, 9, 0), "人物5413", "新しい"),
                     line(at(22, 9, 0), "人物5413", "まんなか"),
                     line(at(24, 10, 0), "人物99", "ほかの人"),
                     line(at(24, 11, 0), "Aさん", "名前が付いた同じ声", id: "5413")]
        let picked = S26VVoice.pick(lines, number: "5413", calendar: cal)
        XCTAssertEqual(picked.map(\.text), ["名前が付いた同じ声", "新しい"])
    }

    func testPickPrefersSampleTimes() {
        let lines = [line(at(24, 9, 8, 13), "人物5413", "それでいこう", offset: 30),
                     line(at(25, 8, 0), "人物5413", "いちばん新しい"),
                     line(at(21, 18, 30), "人物5413", "また来週", offset: 5)]
        let samples: [ReviewItem.Sample] = [.init(day: "2026-11-21", time: "18:30:00", text: "また来週"),
                                            .init(day: "2026-11-24", time: "09:08:12", text: "それでいこう")]
        let picked = S26VVoice.pick(lines, number: "5413", samples: samples, calendar: cal)
        XCTAssertEqual(picked.map(\.text), ["また来週", "それでいこう"], "samples に合う行を samples の順に先に")
        XCTAssertEqual(picked.first?.offset, 5)
    }

    func testPickSkipsBroadcastLines() {
        var tv = line(at(24, 9, 0), "人物5413", "テレビ")
        tv.media = "テレビ"
        XCTAssertTrue(S26VVoice.pick([tv], number: "5413", calendar: cal).isEmpty)
    }

    func testStopUsesEndOrEightSeconds() {
        XCTAssertEqual(S26VVoice.stop(.init(time: at(24, 9, 0), text: "", audio: "a", offset: 10, end: 14)), 14.5)
        XCTAssertEqual(S26VVoice.stop(.init(time: at(24, 9, 0), text: "", audio: "a", offset: 10, end: nil)), 18)
    }

    func testSampleDaysAreUniqueInOrder() {
        let s: [ReviewItem.Sample] = [.init(day: "2026-11-24"), .init(day: "2026-11-22"), .init(day: "2026-11-24"), .init(day: nil)]
        XCTAssertEqual(S26VVoice.sampleDays(s), ["2026-11-24", "2026-11-22"])
    }
}

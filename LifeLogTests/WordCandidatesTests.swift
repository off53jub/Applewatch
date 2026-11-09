import XCTest
@testable import LifeLog

/// 言葉の登録の候補（2026-11-10）。母艦の辞書（家の PC の GET /vocab）の読み方、同じ言葉の見分け方、
/// 登録ずみ・外した言葉を除くこと、仕事のまとめの【よく出た言葉】のまとめ方を確かめる。
/// 言葉はすべて作り物。
@MainActor
final class WordCandidatesTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - 母艦の辞書を読む

    func testParse() throws {
        let json = """
        {"available": true, "generated_at": "2026-11-10T08:00:00",
         "items": [
           {"word": "設備台帳", "category": "専門用語", "count": 12, "last": "2026-11-09", "variants": ["台帳", ""]},
           {"word": " 山田 ", "category": "", "count": 3, "last": ""},
           {"word": "", "category": "人名"},
           {"word": "<b>太字</b>"},
           {"category": "社名"},
           "ただの文字",
           {"word": "設備 台帳", "count": 1}
         ]}
        """
        let parsed = try XCTUnwrap(WordCandidateBook.parse(data(json)))
        XCTAssertEqual(parsed.generatedAt, "2026-11-10T08:00:00")
        XCTAssertEqual(parsed.items.map(\.word), ["設備台帳", "山田"])
        XCTAssertEqual(parsed.items[0], WordCandidate(word: "設備台帳", category: "専門用語", count: 12,
                                                      last: "2026-11-09", variants: ["台帳"]))
        // 空の分け方・日付は無いものにする
        XCTAssertNil(parsed.items[1].category)
        XCTAssertNil(parsed.items[1].last)
        XCTAssertNil(parsed.items[1].variants)
    }

    func testParseUnavailableOrBroken() {
        XCTAssertNil(WordCandidateBook.parse(data(#"{"available": false, "reason": "まだありません"}"#)))
        XCTAssertNil(WordCandidateBook.parse(data(#"{"available": true}"#)))
        XCTAssertNil(WordCandidateBook.parse(data("[1, 2, 3]")))
        XCTAssertNil(WordCandidateBook.parse(data("こわれた")))
        // 中身が空でも、読めたことにはなる（候補が 0 件）
        XCTAssertEqual(WordCandidateBook.parse(data(#"{"items": []}"#))?.items.count, 0)
    }

    func testParseDropsTooLongWords() throws {
        let long = String(repeating: "あ", count: 41)
        let ok = String(repeating: "い", count: 40)
        let json = "{\"items\": [{\"word\": \"" + long + "\"}, {\"word\": \"" + ok + "\", \"variants\": [\"" + long + "\", \"短い\"]}]}"
        let parsed = try XCTUnwrap(WordCandidateBook.parse(data(json)))
        XCTAssertEqual(parsed.items.map(\.word), [ok])
        XCTAssertEqual(parsed.items.first?.variants, ["短い"])
    }

    // MARK: - 同じ言葉の見分け方

    func testKey() {
        XCTAssertEqual(WordCandidateBook.key("As Is"), "asis")
        XCTAssertEqual(WordCandidateBook.key("山田さん"), WordCandidateBook.key("山田"))
        XCTAssertEqual(WordCandidateBook.key("山田 様"), "山田")
        // 言葉そのものが「さん」のときは消さない
        XCTAssertEqual(WordCandidateBook.key("さん"), "さん")
        XCTAssertEqual(WordCandidateBook.key("  "), "")
    }

    func testOpenDropsKnownAndDismissed() {
        let items = [
            WordCandidate(word: "設備台帳"), WordCandidate(word: "山田さん"), WordCandidate(word: "AsIs"),
            WordCandidate(word: "棚卸し"), WordCandidate(word: "as is"),
        ]
        let open = WordCandidateBook.open(items, known: ["山田", "ほかの言葉"],
                                          dismissed: [WordCandidateBook.key("棚卸し")])
        // 登録ずみ（「さん」の有無は同じ言葉）・外した言葉・同じ言葉の2つ目は出さない
        XCTAssertEqual(open.map(\.word), ["設備台帳", "AsIs"])
    }

    // MARK: - 仕事のまとめの【よく出た言葉】

    private func entry(_ day: String, _ words: [String]?) -> WorkDigest.Entry {
        var sections: WorkDigest.Sections? = nil
        if let words {
            var made = WorkDigest.Sections()
            made.words = words
            sections = made
        }
        return WorkDigest.Entry(day: day, text: "x", sections: sections, source: .paste)
    }

    func testFromDigests() {
        let entries = [
            entry("2026-11-07", ["設備台帳", "asis"]),
            entry("2026-11-09", ["AsIs", "棚卸し"]),
            entry("2026-11-09", ["AsIs"]),          // 同じ日の2つ目は、日数に数えない
            entry("2026-11-08", ["設備台帳", "AsIs"]),
            entry("2026-11-06", nil),                 // 決まった形で無いまとめ
        ]
        let found = WordCandidateBook.fromDigests(entries)
        // 出てきた日の多い順 → 新しい順。書き方は、新しい日のもの
        XCTAssertEqual(found.map(\.word), ["AsIs", "設備台帳", "棚卸し"])
        XCTAssertEqual(found.map(\.count), [3, 2, 1])
        XCTAssertEqual(found.map(\.last), ["2026-11-09", "2026-11-08", "2026-11-09"])
        XCTAssertTrue(WordCandidateBook.fromDigests([]).isEmpty)
    }

    // MARK: - 見せ方

    func testNoteAndShortDay() {
        XCTAssertEqual(WordCandidateBook.shortDay("2026-11-09"), "11/9")
        XCTAssertEqual(WordCandidateBook.shortDay("きのう"), "きのう")
        let fromDigest = WordCandidate(word: "設備台帳", count: 2, last: "2026-11-08")
        XCTAssertEqual(WordCandidateBook.note(fromDigest, fromDigest: true), "2 日のまとめに出た・最後 11/8")
        let fromPC = WordCandidate(word: "設備台帳", category: "専門用語", count: 12, last: "2026-11-09", variants: ["台帳", "設備の台帳"])
        XCTAssertEqual(WordCandidateBook.note(fromPC, fromDigest: false),
                       "専門用語・12 回・最後 11/9\n別の書き方: 台帳、設備の台帳")
        XCTAssertEqual(WordCandidateBook.note(WordCandidate(word: "山田"), fromDigest: false), "")
    }

    func testCategories() {
        let items = [
            WordCandidate(word: "a", category: "人名"), WordCandidate(word: "b", category: "専門用語"),
            WordCandidate(word: "c", category: "専門用語"), WordCandidate(word: "d"),
            WordCandidate(word: "e", category: "社名"),
        ]
        XCTAssertEqual(WordCandidateListView.categories(items), ["専門用語", "人名", "社名"])
    }

    // MARK: - 保存の形

    func testSavedRoundTripAndOldShape() throws {
        var saved = WordCandidateBook.Saved()
        saved.items = [WordCandidate(word: "設備台帳", category: "専門用語", count: 12, last: "2026-11-09", variants: ["台帳"])]
        saved.generatedAt = "2026-11-10T08:00:00"
        saved.dismissed = ["棚卸し"]
        let back = try JSONDecoder().decode(WordCandidateBook.Saved.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.items, saved.items)
        XCTAssertEqual(back.generatedAt, saved.generatedAt)
        XCTAssertEqual(back.dismissed, ["棚卸し"])
        // 言葉だけの行も読める（あとから足した項目は無くてよい）
        let plain = try JSONDecoder().decode(WordCandidate.self, from: data(#"{"word": "山田"}"#))
        XCTAssertEqual(plain, WordCandidate(word: "山田"))
    }
}

import Foundation
import SwiftUI

// MARK: - 記録に質問するを母艦まで（施策 15。2026-11-13。実機では未確認）
//
// 「記録に質問する」で「母艦（LINE・写真・予定・お金も）から探す」をオンにすると、質問を家の PC の POST /ask-mothership に送る。
// 家の PC が母艦（D:\Lifelog）の全文検索（LINE・PLAUD・予定・写真・体調・場所・1日のまとめ・仕事のまとめ）とお金の記録から探し、
// Claude が見つかったものだけをもとに答える（中身は pc/askmother.py）。答えの下に、もとにした記録（どこの記録か・日・時刻・文）を出す。
// オフのときは、今までの「記録に質問する」のまま（iPhone の記録だけ）。オフで何も見つからなかったときは「母艦からも探す」を出す。
// 母艦には職場の中身もあるので、「Claude を使う」と「職場の会話も Claude で」の両方がオンのときだけ使える。

/// POST /ask-mothership の答え
struct MothershipAnswer: Decodable, Equatable {
    struct Source: Decodable, Equatable, Identifiable {
        var n: Int
        /// YYYY-MM-DD（お金の月のまとめは YYYY-MM）
        var day: String
        /// HH:MM（PLAUD は「+00:01:02」のような録音からの時間。無ければ空）
        var time: String
        var source: String
        var label: String
        var text: String

        var id: Int { n }

        init(n: Int, day: String, time: String, source: String, label: String, text: String) {
            self.n = n
            self.day = day
            self.time = time
            self.source = source
            self.label = label
            self.text = text
        }

        enum CodingKeys: String, CodingKey { case n, day, time, source, label, text }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            n = try c.decode(Int.self, forKey: .n)
            day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
            time = (try? c.decodeIfPresent(String.self, forKey: .time)) ?? ""
            source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
            let given: String = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
            label = given.isEmpty ? MothershipAsk.label(source) : given
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        }

        /// 「LINE・11/01 12:34」
        var caption: String {
            var parts: [String] = [label]
            let shortDay: String = day.count == 10 ? String(day.suffix(5)).replacingOccurrences(of: "-", with: "/") : day
            parts.append(time.isEmpty ? shortDay : shortDay + " " + time)
            return parts.joined(separator: "・")
        }
    }

    var found: Bool
    var answer: String
    var sources: [Source]
    var snippets: Int

    enum CodingKeys: String, CodingKey { case found, answer, sources, searched }
    private enum SearchedKeys: String, CodingKey { case snippets }

    init(found: Bool, answer: String, sources: [Source], snippets: Int) {
        self.found = found
        self.answer = answer
        self.sources = sources
        self.snippets = snippets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        found = (try? c.decodeIfPresent(Bool.self, forKey: .found)) ?? false
        answer = try c.decode(String.self, forKey: .answer)
        var list: [Source] = []
        if var rows = try? c.nestedUnkeyedContainer(forKey: .sources) {
            while !rows.isAtEnd {
                if let row = try? rows.decode(Source.self) {
                    list.append(row)
                } else if (try? rows.decode(PromiseSkipRow.self)) == nil {
                    break
                }
            }
        }
        sources = list
        let searched = try? c.nestedContainer(keyedBy: SearchedKeys.self, forKey: .searched)
        snippets = (try? searched?.decodeIfPresent(Int.self, forKey: .snippets)) ?? 0
    }
}

enum MothershipAsk {
    /// 家の PC が知らせる働きの名前
    static let feature = "askmother"
    /// 「母艦（LINE・写真・予定・お金も）から探す」（初めはオフ）
    static let toggleKey = "askFromMothership"

    static let labels: [String: String] = [
        "limitless": "録音（Limitless）", "plaud": "PLAUD", "plaud-whisper": "PLAUD", "app": "アプリの記録", "line": "LINE",
        "claude": "Claude との会話", "digest": "1日のまとめ", "calendar": "予定", "health": "体調", "photos": "写真",
        "location": "場所", "work-digest": "仕事のまとめ", "money": "お金",
    ]

    static func label(_ source: String) -> String { labels[source] ?? source }

    /// 使えるか（家の PC が知らせていて、Claude の2つのスイッチがオン）
    static func usable(features: Set<String>, useClaude: Bool, forWork: Bool) -> Bool {
        features.contains(feature) && useClaude && forWork
    }

    /// 使えないわけ（使えるときは nil）
    static func blocked(features: Set<String>, useClaude: Bool, forWork: Bool) -> String? {
        if !features.contains(feature) { return "家の PC がまだ対応していません（家の PC を新しくすると使えます）。" }
        if !useClaude { return "「Claude を使う」がオフなので使えません。" }
        if !forWork { return "母艦には職場の中身もあるので、「職場の会話も Claude で」がオフのあいだは使えません。" }
        return nil
    }

    static func decode(_ data: Data) -> MothershipAnswer? {
        try? JSONDecoder().decode(MothershipAnswer.self, from: data)
    }

    static func body(_ question: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["question": String(question.prefix(500))], options: [])
    }
}

extension Pipeline {
    /// 母艦から探して答えてもらう（70秒まで待つ）
    func askMothership(_ question: String) async throws -> MothershipAnswer {
        guard MothershipAsk.usable(features: homePC.features, useClaude: ClaudeRoute.useClaude, forWork: ClaudeRoute.forWork) else {
            throw HomePC.Failure.notConfigured
        }
        guard let body = MothershipAsk.body(question) else { throw HomePC.Failure.server("質問を送れませんでした") }
        let data: Data = try await homePC.postJSONData("ask-mothership", body: body, timeout: 70)
        guard let answer = MothershipAsk.decode(data) else { throw HomePC.Failure.server("答えを読めませんでした") }
        Tally.add(answer.found ? "askmother.found" : "askmother.none")
        return answer
    }
}

/// 母艦からの答えと、もとにした記録
struct MothershipAnswerSections: View {
    let question: String
    let answer: MothershipAnswer

    var body: some View {
        Section {
            Text(answer.answer).textSelection(.enabled)
        } header: {
            Text(question)
        } footer: {
            Text(answer.found ? "母艦（LINE・写真・予定・お金など）で見つかったものだけをもとにした答えです。"
                 : "母艦で探しましたが、答えられるものは見つかりませんでした（\(answer.snippets) 件を読みました）。")
        }
        if !answer.sources.isEmpty {
            Section("もとにした記録（母艦）") {
                ForEach(answer.sources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("[\(source.n)] " + source.caption).font(.caption).foregroundStyle(.secondary)
                        Text(source.text)
                    }
                }
            }
        }
    }
}

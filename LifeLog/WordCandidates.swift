import Foundation
import Observation
import SwiftUI

/// 言葉の登録の候補（2026-11-10）。2つの出どころから「まだ登録していない言葉」を見せる。
/// - 母艦（家の PC の D:\Lifelog）の辞書: 過去の会話から集めた名前・社名・専門用語。家の PC の GET /vocab から読む。
/// - 仕事のまとめの【よく出た言葉】: 職場の Claude が書いた言葉（WorkDigest.swift）。
/// どちらも見せるだけで、本人が押した言葉だけを登録する（自動では登録しない）。言葉の登録（vocabulary）の形は変えない。
/// 母艦の「別の書き方」は、聞き間違いとは限らない（短い言い方・関係のある別の言葉も混ざる）ので、直しの登録には使わず、見せるだけにする。
struct WordCandidate: Codable, Identifiable, Equatable, Sendable {
    var word: String
    /// 母艦の分け方（人名・社名・組織・専門用語・地名・場所）
    var category: String? = nil
    /// 出てきた回数（母艦）・出てきたまとめの数（仕事のまとめ）
    var count: Int? = nil
    /// 最後に出てきた日（yyyy-MM-dd）
    var last: String? = nil
    /// 母艦の辞書にある別の書き方
    var variants: [String]? = nil

    var id: String { word }
}

@MainActor
@Observable
final class WordCandidateBook {
    /// 保存の形（新しいファイル・端末ごと・同期しない）
    struct Saved: Codable {
        var items: [WordCandidate] = []
        var generatedAt: String? = nil
        var fetchedAt: Date? = nil
        /// 候補から外した言葉（比べる形）
        var dismissed: [String] = []
    }

    /// 母艦の辞書からの候補（家の PC から読んだまま）
    private(set) var items: [WordCandidate] = []
    private(set) var generatedAt: String?
    private(set) var fetchedAt: Date?
    private(set) var dismissed: Set<String> = []
    private(set) var lastError: String?
    /// 読み込めたか（読む前には保存しない）
    private var loaded = false
    private var fetching = false

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("word-candidates.json")
    /// 母艦の辞書はゆっくり変わるので、6時間に1回まで
    static let refreshEvery: TimeInterval = 6 * 3600
    /// 「言葉の登録」の画面にそのまま並べる数（続きは一覧で）
    static let shownInForm = 8

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else {
            loaded = true
            return
        }
        if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            items = saved.items
            generatedAt = saved.generatedAt
            fetchedAt = saved.fetchedAt
            dismissed = Set(saved.dismissed)
        } else {
            // 読めないファイルは上書きせず脇に置く
            let aside = Self.url.deletingLastPathComponent().appendingPathComponent("word-candidates-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        let saved = Saved(items: items, generatedAt: generatedAt, fetchedAt: fetchedAt, dismissed: dismissed.sorted())
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// 家の PC から読み直す（force でなければ6時間に1回まで）。読めなければ前の候補のまま
    func refresh(_ pc: HomePC, force: Bool = false) async {
        guard !fetching, pc.features.contains("vocab") else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.refreshEvery { return }
        fetching = true
        defer { fetching = false }
        do {
            let data = try await pc.mothershipVocab()
            guard let parsed = Self.parse(data) else {
                lastError = "母艦の言葉の候補がまだありません"
                return
            }
            items = parsed.items
            generatedAt = parsed.generatedAt
            fetchedAt = .now
            lastError = nil
            save()
        } catch {
            lastError = "家の PC から読めませんでした"
        }
    }

    /// 候補から外す（言葉の登録には触らない）
    func dismiss(_ word: String) {
        let key = Self.key(word)
        guard !key.isEmpty, dismissed.insert(key).inserted else { return }
        save()
    }

    /// 外した候補を、全部もう一度出す
    func restoreDismissed() {
        guard !dismissed.isEmpty else { return }
        dismissed = []
        save()
    }

    // MARK: 読む・比べる（保存しない）

    /// 家の PC の答え（GET /vocab）を読む。無い・形が違うときは nil。おかしな行は落とす
    static func parse(_ data: Data) -> (generatedAt: String?, items: [WordCandidate])? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["available"] as? Bool != false,
              let rows = object["items"] as? [Any] else { return nil }
        var items: [WordCandidate] = []
        var seen: Set<String> = []
        for row in rows {
            guard let dict = row as? [String: Any], let raw = dict["word"] as? String else { continue }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 40, !word.contains("<"), !word.contains(">"),
                  seen.insert(key(word)).inserted else { continue }
            let category = (dict["category"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(20)) }
            let last = (dict["last"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(10)) }
            let variants: [String] = ((dict["variants"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 40 }
            items.append(WordCandidate(word: word, category: category, count: dict["count"] as? Int, last: last,
                                       variants: variants.isEmpty ? nil : Array(variants.prefix(6))))
            if items.count >= 500 { break }
        }
        return (object["generated_at"] as? String, items)
    }

    /// 同じ言葉かを比べる形（大文字小文字・空白・後ろの「さん」などの違いを無いものにする）
    static func key(_ word: String) -> String {
        var s = word.lowercased().filter { !$0.isWhitespace }
        for suffix in ["さん", "くん", "ちゃん", "様"] where s.hasSuffix(suffix) && s.count > suffix.count {
            s = String(s.dropLast(suffix.count))
            break
        }
        return s
    }

    /// まだ登録していなくて、外してもいない候補（同じ言葉は1つ）
    static func open(_ items: [WordCandidate], known: Set<String>, dismissed: Set<String>) -> [WordCandidate] {
        let knownKeys = Set(known.map { key($0) })
        var seen: Set<String> = []
        return items.filter { item in
            let k = key(item.word)
            return !k.isEmpty && !knownKeys.contains(k) && !dismissed.contains(k) && seen.insert(k).inserted
        }
    }

    /// 仕事のまとめの【よく出た言葉】を、言葉ごとにまとめる（出てきた日の多い順・新しい順）
    static func fromDigests(_ entries: [WorkDigest.Entry]) -> [WordCandidate] {
        var words: [String: String] = [:]
        var days: [String: Set<String>] = [:]
        // 新しい日の書き方を見せる
        for entry in entries.sorted(by: { $0.day > $1.day }) {
            for word in entry.sections?.words ?? [] {
                let k = key(word)
                guard !k.isEmpty else { continue }
                if words[k] == nil { words[k] = word }
                days[k, default: []].insert(entry.day)
            }
        }
        let items: [WordCandidate] = words.map { k, word in
            WordCandidate(word: word, count: days[k]?.count ?? 1, last: days[k]?.max())
        }
        return items.sorted { a, b in
            if (a.count ?? 0) != (b.count ?? 0) { return (a.count ?? 0) > (b.count ?? 0) }
            if (a.last ?? "") != (b.last ?? "") { return (a.last ?? "") > (b.last ?? "") }
            return a.word < b.word
        }
    }

    /// 「2026-11-09」を「11/9」に（読めなければそのまま）
    static func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : day
    }

    /// 候補の下に出す小さい字（どこから・何回・いつ）
    static func note(_ item: WordCandidate, fromDigest: Bool) -> String {
        var parts: [String] = []
        if fromDigest {
            parts.append("\(item.count ?? 1) 日のまとめに出た")
        } else {
            if let category = item.category { parts.append(category) }
            if let count = item.count, count > 0 { parts.append("\(count) 回") }
        }
        if let last = item.last { parts.append("最後 \(shortDay(last))") }
        var text = parts.joined(separator: "・")
        if let variants = item.variants, !variants.isEmpty {
            text += (text.isEmpty ? "" : "\n") + "別の書き方: " + variants.joined(separator: "、")
        }
        return text
    }
}

// MARK: - 画面

extension Pipeline {
    /// もう登録してある言葉（言葉・直しの正しい書き方・話題の言葉・人の名前）
    var registeredWordSet: Set<String> {
        var known = Set(Vocabulary.Group.allCases.flatMap { vocabulary.words(in: $0) })
        known.formUnion(vocabulary.fixes.map(\.right))
        known.formUnion(vocabulary.topics.flatMap(\.words))
        known.formUnion(people.compactMap(\.name))
        return known
    }

    /// いま出す候補（fromDigest: 仕事のまとめから。そうでなければ母艦の辞書から）
    func openWordCandidates(fromDigest: Bool) -> [WordCandidate] {
        let all: [WordCandidate] = fromDigest ? WordCandidateBook.fromDigests(workDigests.entries) : wordCandidates.items
        return WordCandidateBook.open(all, known: registeredWordSet, dismissed: wordCandidates.dismissed)
    }
}

/// 「言葉の登録」に出す2つの組（仕事のまとめに出た言葉・母艦の辞書から）。押した言葉だけを、選んだ組に足す
struct WordCandidateSections: View {
    @Environment(Pipeline.self) private var pipeline
    let group: Vocabulary.Group

    var body: some View {
        let digest: [WordCandidate] = pipeline.openWordCandidates(fromDigest: true)
        let mothership: [WordCandidate] = pipeline.openWordCandidates(fromDigest: false)
        if !digest.isEmpty {
            Section {
                rows(digest, fromDigest: true)
            } header: {
                Text("仕事のまとめに出た言葉")
            } footer: {
                Text("職場の Claude が【よく出た言葉】に書いた言葉です。押したときだけ、上で選んだ組に足します。登録した言葉は、聞き取りのヒントとしてクラウドの文字起こしにも渡ります。外に出したくない言葉は登録しないでください。")
            }
        }
        if !mothership.isEmpty {
            Section {
                rows(mothership, fromDigest: false)
            } header: {
                Text("母艦の辞書からの候補")
            } footer: {
                Text("家の PC の母艦が過去の会話から集めた名前・社名・専門用語のうち、まだ登録していない言葉です。押したときだけ、上で選んだ組に足します。自動では登録しません。左にスワイプすると候補から外せます。")
            }
        }
    }

    @ViewBuilder
    private func rows(_ items: [WordCandidate], fromDigest: Bool) -> some View {
        let first: [WordCandidate] = Array(items.prefix(WordCandidateBook.shownInForm))
        ForEach(first) { item in
            WordCandidateRow(item: item, group: group, fromDigest: fromDigest)
        }
        if items.count > WordCandidateBook.shownInForm {
            NavigationLink {
                WordCandidateListView(fromDigest: fromDigest, group: group)
            } label: {
                Text("すべて見る（\(items.count) 件）")
            }
        }
    }
}

/// 候補の1行（言葉・どこから・「足す」）
struct WordCandidateRow: View {
    @Environment(Pipeline.self) private var pipeline
    let item: WordCandidate
    let group: Vocabulary.Group
    let fromDigest: Bool

    var body: some View {
        let note: String = WordCandidateBook.note(item, fromDigest: fromDigest)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.word)
                if !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("「\(group.label)」に足す") {
                pipeline.vocabulary.add(item.word, to: group)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .swipeActions {
            Button("候補から外す", role: .destructive) {
                pipeline.wordCandidates.dismiss(item.word)
            }
        }
    }
}

/// 候補の一覧（全部）。足す組と、母艦の分け方で絞れる
struct WordCandidateListView: View {
    @Environment(Pipeline.self) private var pipeline
    let fromDigest: Bool
    @State var group: Vocabulary.Group
    /// 母艦の分け方で絞る（空なら全部）
    @State private var category = ""

    var body: some View {
        let book = pipeline.wordCandidates
        let all: [WordCandidate] = pipeline.openWordCandidates(fromDigest: fromDigest)
        let categories: [String] = Self.categories(all)
        let shown: [WordCandidate] = category.isEmpty ? all : all.filter { $0.category == category }
        List {
            Section {
                Picker("足す組", selection: $group) {
                    ForEach(Vocabulary.Group.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if categories.count > 1 {
                    Picker("種類", selection: $category) {
                        Text("すべて").tag("")
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                }
            } footer: {
                Text("押した言葉だけを、選んだ組に足します。登録した言葉は、聞き取りのヒントとしてクラウドの文字起こしにも渡ります。")
            }
            Section {
                ForEach(shown) { item in
                    WordCandidateRow(item: item, group: group, fromDigest: fromDigest)
                }
            } header: {
                Text("\(shown.count) 件")
            } footer: {
                if !fromDigest, let error = book.lastError {
                    Text(error)
                }
            }
            if !book.dismissed.isEmpty {
                Section {
                    Button("外した候補を戻す（\(book.dismissed.count) 件）") { book.restoreDismissed() }
                }
            }
        }
        .navigationTitle(fromDigest ? "仕事のまとめに出た言葉" : "母艦の辞書からの候補")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if !fromDigest { await book.refresh(pipeline.homePC, force: true) }
        }
    }

    /// 候補にある分け方（多い順）
    static func categories(_ items: [WordCandidate]) -> [String] {
        var counts: [String: Int] = [:]
        for item in items {
            if let c = item.category { counts[c, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

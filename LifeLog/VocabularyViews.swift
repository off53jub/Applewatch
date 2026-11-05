import SwiftUI

/// 聞き取ってほしい言葉を、「いつも」「職場だけ」「職場以外だけ」に分けて登録する。
struct VocabularyView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var group: Vocabulary.Group = .work
    @State private var newWord = ""
    @State private var wrong = ""
    @State private var right = ""
    @State private var newTopic = ""
    /// 登録の候補（手で直した言葉・何日にもわたって出てくる言葉）
    @State private var candidates: [WordStats.Candidate] = []

    var body: some View {
        let vocabulary = pipeline.vocabulary
        Form {
            Section {
                Picker("組", selection: $group) {
                    ForEach(Vocabulary.Group.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(footer)
            }

            Section {
                ForEach(vocabulary.words(in: group), id: \.self) { Text($0) }
                    .onDelete { vocabulary.remove(at: $0, from: group) }
                HStack {
                    TextField("例: 人名、社名、専門用語", text: $newWord, axis: .vertical)
                        .lineLimit(1...6)
                    Button("追加", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("言葉")
            } footer: {
                Text("改行か「、」で区切って貼り付けると、まとめて足せます。")
            }

            if !candidates.isEmpty {
                Section {
                    ForEach(candidates) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.word)
                                Text(candidate.edited ? "手で直した言葉（\(candidate.count) 回）"
                                     : "\(candidate.days) 日・\(candidate.count) 回の会話に出てきた")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("「\(group.label)」に足す") {
                                vocabulary.add(candidate.word, to: group)
                                loadCandidates()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        .swipeActions {
                            Button("候補から外す", role: .destructive) {
                                pipeline.wordStats.dismiss(candidate.word)
                                loadCandidates()
                            }
                        }
                    }
                } header: {
                    Text("登録の候補")
                } footer: {
                    Text("手で直した言葉と、何日にもわたって出てくる名前や専門用語らしい言葉です。押したときだけ、上で選んだ組に足します。左にスワイプすると候補から外せます。")
                }
            }

            Section {
                let fixes = vocabulary.fixes.filter { $0.group == group }
                ForEach(fixes) { fix in
                    LabeledContent(fix.wrong, value: "→ " + fix.right)
                }
                .onDelete { offsets in vocabulary.removeFixes(Set(offsets.map { fixes[$0].id })) }
                TextField("間違えやすい書き方", text: $wrong)
                HStack {
                    TextField("正しい書き方", text: $right)
                    Button("追加") {
                        vocabulary.addFix(wrong: wrong, right: right, group: group)
                        wrong = ""
                        right = ""
                    }
                    .disabled(wrong.trimmingCharacters(in: .whitespaces).isEmpty
                              || right.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("よく間違えられる書き方")
            } footer: {
                Text("文字起こしにこの書き方が出てきたら、正しい書き方に置き換えます（直す前の文も残ります）。")
            }

            Section {
                ForEach(vocabulary.topics) { topic in
                    NavigationLink {
                        TopicView(id: topic.id)
                    } label: {
                        LabeledContent(topic.name, value: "\(topic.words.count) 語")
                    }
                }
                .onDelete { offsets in
                    let topics = vocabulary.topics
                    vocabulary.removeTopics(Set(offsets.map { topics[$0].id }))
                }
                HStack {
                    TextField("話題の名前（例: 決算、システム移行）", text: $newTopic)
                        .onSubmit(addTopic)
                    Button("追加", action: addTopic)
                        .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("話題ごとの言葉")
            } footer: {
                Text("話題に合図の言葉か専門用語が聞こえたら、そこから30分はその話題の専門用語も聞き取りと誤変換直しのヒントにします（場所の組とは別に、いつでも効きます）。")
            }
        }
        .navigationTitle("言葉の登録")
        .onAppear(perform: loadCandidates)
    }

    private func loadCandidates() {
        let vocabulary = pipeline.vocabulary
        var known = Set(Vocabulary.Group.allCases.flatMap { vocabulary.words(in: $0) })
        known.formUnion(vocabulary.fixes.map(\.right))
        known.formUnion(vocabulary.topics.flatMap(\.words))
        known.formUnion(pipeline.people.compactMap(\.name))
        candidates = pipeline.wordStats.candidates(known: known)
    }

    private func addTopic() {
        _ = pipeline.vocabulary.addTopic(newTopic)
        newTopic = ""
    }

    private var footer: String {
        let now = pipeline.vocabularyContext(at: .now) == .work ? "職場" : "職場以外"
        return "職場にした場所では「いつも」と「職場だけ」、ほかの登録した場所では「いつも」と「職場以外だけ」を使います。場所が分からないときは、平日の8時〜19時を職場とみなします（いまは\(now)）。名前を付けた人の名前も自動で入ります。"
    }

    private func addWord() {
        // 改行・「、」・カンマで区切って、まとめて足す（すでにある言葉は足さない）
        for word in newWord.components(separatedBy: CharacterSet(charactersIn: "\n、,，")) {
            pipeline.vocabulary.add(word, to: group)
        }
        newWord = ""
    }
}

/// 記録の行から言葉を登録する（行の文を出しておくので、残したい言葉だけにして追加する）。
struct AddWordView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let line: ConversationLog.Line
    @State private var word = ""
    @State private var group: Vocabulary.Group = .always

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(line.text).foregroundStyle(.secondary).textSelection(.enabled)
                } header: {
                    Text("この行")
                }
                Section {
                    TextField("登録する言葉", text: $word)
                    Picker("組", selection: $group) {
                        ForEach(Vocabulary.Group.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("書き間違いを直したいときは、正しい書き方で登録してください。")
                }
            }
            .navigationTitle("言葉を登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        pipeline.vocabulary.add(word, to: group)
                        dismiss()
                    }
                    .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                group = pipeline.vocabularyContext(at: line.time) == .work ? .work : .other
            }
        }
    }
}

/// 1つの話題：名前・合図の言葉・専門用語。
struct TopicView: View {
    @Environment(Pipeline.self) private var pipeline
    let id: UUID
    @State private var newTrigger = ""
    @State private var newWord = ""

    private var topic: Vocabulary.Topic? { pipeline.vocabulary.topics.first { $0.id == id } }

    var body: some View {
        Form {
            if let topic {
                Section("名前") {
                    TextField("話題の名前", text: Binding(
                        get: { topic.name },
                        set: { value in update { $0.name = value } }))
                }
                Section {
                    ForEach(topic.words, id: \.self) { Text($0) }
                        .onDelete { offsets in update { $0.words.remove(atOffsets: offsets) } }
                    HStack {
                        TextField("例: 信用取引、約定、IPO", text: $newWord)
                            .onSubmit(addWord)
                        Button("追加", action: addWord)
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("専門用語")
                } footer: {
                    Text("この話題のときに、この書き方で聞き取ってほしい言葉。どれかが聞こえただけでも、この話題とみなします。")
                }
                Section {
                    ForEach(topic.triggers, id: \.self) { Text($0) }
                        .onDelete { offsets in update { $0.triggers.remove(atOffsets: offsets) } }
                    HStack {
                        TextField("例: 決算、株価", text: $newTrigger)
                            .onSubmit(addTrigger)
                        Button("追加", action: addTrigger)
                            .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("合図の言葉（なくてもよい）")
                } footer: {
                    Text("聞き取りやすい普通の言葉で、この話題が始まったと分かるもの。専門用語そのものは聞き間違えられやすいので、こちらにも入れておくと見つけやすくなります。")
                }
            }
        }
        .navigationTitle(topic?.name ?? "")
    }

    private func update(_ change: (inout Vocabulary.Topic) -> Void) {
        guard var topic else { return }
        change(&topic)
        pipeline.vocabulary.updateTopic(topic)
    }

    private func addWord() {
        let word = newWord
        update { $0.words.append(word) }
        newWord = ""
    }

    private func addTrigger() {
        let word = newTrigger
        update { $0.triggers.append(word) }
        newTrigger = ""
    }
}

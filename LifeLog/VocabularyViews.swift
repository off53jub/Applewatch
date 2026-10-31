import SwiftUI

/// 聞き取ってほしい言葉を、「いつも」「職場だけ」「職場以外だけ」に分けて登録する。
struct VocabularyView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var group: Vocabulary.Group = .work
    @State private var newWord = ""
    @State private var wrong = ""
    @State private var right = ""

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

            Section("言葉") {
                ForEach(vocabulary.words(in: group), id: \.self) { Text($0) }
                    .onDelete { vocabulary.remove(at: $0, from: group) }
                HStack {
                    TextField("例: 人名、社名、専門用語", text: $newWord)
                        .onSubmit(addWord)
                    Button("追加", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
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
        }
        .navigationTitle("言葉の登録")
    }

    private var footer: String {
        let now = pipeline.vocabularyContext(at: .now) == .work ? "職場" : "職場以外"
        return "職場にした場所では「いつも」と「職場だけ」、ほかの登録した場所では「いつも」と「職場以外だけ」を使います。場所が分からないときは、平日の8時〜19時を職場とみなします（いまは\(now)）。名前を付けた人の名前も自動で入ります。"
    }

    private func addWord() {
        pipeline.vocabulary.add(newWord, to: group)
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

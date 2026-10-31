import SwiftUI

/// 記録の掃除。全期間から消す候補を探し、種類ごとに確かめてから、アプリとドキュメントの両方から消す。
struct CleanupView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var candidates: [Junk.Candidate]?
    /// 残すことにした候補
    @State private var keep: Set<UUID> = []
    @State private var working = false
    @State private var status = ""
    @State private var newPhrase = ""

    private var chosen: [Junk.Candidate] { (candidates ?? []).filter { !keep.contains($0.id) } }

    var body: some View {
        Form {
            Section {
                Button(candidates == nil ? "調べる" : "もう一度調べる") { scan() }
                    .disabled(working)
                if let candidates {
                    if candidates.isEmpty {
                        Text("消す候補はありませんでした。").foregroundStyle(.secondary)
                    }
                    ForEach(Junk.Kind.allCases) { kind in
                        let items = candidates.filter { $0.kind == kind }
                        if !items.isEmpty {
                            NavigationLink {
                                JunkListView(kind: kind, items: items, keep: $keep)
                            } label: {
                                LabeledContent(kind.label,
                                               value: "\(items.filter { !keep.contains($0.id) }.count) / \(items.count) 行")
                            }
                        }
                    }
                    if !candidates.isEmpty {
                        Button(working ? "消しています…" : "選んだ \(chosen.count) 行を消す", role: .destructive) { remove() }
                            .disabled(working || chosen.isEmpty)
                    }
                }
                if !status.isEmpty {
                    Text(status).foregroundStyle(.secondary)
                }
            } footer: {
                Text("すべての日の記録から、声の無いところに書かれた決まり文句、同じ文の連打、壊れた行を探します。種類を開くと実際の行を確かめられ、残したい行は外せます。消すとアプリの記録とドキュメントの両方から行ごと消え、外した行はこれからも消しません。これから書く行も、同じ見つけ方で自動で消します。")
            }

            Section {
                ForEach(pipeline.junkPhrases, id: \.self) { Text($0) }
                    .onDelete { pipeline.junkPhrases.remove(atOffsets: $0) }
                HStack {
                    TextField("例: おやすみなさい", text: $newPhrase)
                        .onSubmit(addPhrase)
                    Button("追加", action: addPhrase)
                        .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("消したい言葉")
            } footer: {
                Text("その言葉だけの行（句読点の違いは無視）を消す候補にします。これから書く行からも自動で消します。")
            }

            Section {
                NavigationLink("消した行（30日間は戻せます）") { TrashView() }
            }
        }
        .navigationTitle("記録の掃除")
    }

    private func addPhrase() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !pipeline.junkPhrases.contains(phrase) else { return }
        pipeline.junkPhrases.append(phrase)
        newPhrase = ""
    }

    private func scan() {
        candidates = pipeline.findJunk()
        keep = []
        status = ""
    }

    private func remove() {
        let chosen = chosen
        let kept = (candidates ?? []).filter { keep.contains($0.id) }
        working = true
        Task {
            status = await pipeline.removeJunk(chosen, keeping: kept)
            candidates = pipeline.findJunk()
            keep = []
            working = false
        }
    }
}

/// 1つの種類の候補。押すと「残す」と「消す」が切り替わる。
private struct JunkListView: View {
    let kind: Junk.Kind
    let items: [Junk.Candidate]
    @Binding var keep: Set<UUID>

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        List {
            Section {
                ForEach(items.reversed()) { item in
                    Button {
                        if keep.contains(item.id) { keep.remove(item.id) } else { keep.insert(item.id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: keep.contains(item.id) ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(keep.contains(item.id) ? Color.secondary : Color.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.day + " " + Self.timeFormatter.string(from: item.line.time)
                                     + (item.line.speaker.map { "  " + $0 } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let before = item.before {
                                    Text("前: " + before).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(item.line.text)
                                    .strikethrough(!keep.contains(item.id))
                                if let after = item.after {
                                    Text("次: " + after).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .tint(.primary)
                }
            } footer: {
                Text(kind.detail + "。押すと「残す」に切り替わります。")
            }
        }
        .toolbar {
            Menu {
                Button("すべて消す") { keep.subtract(items.map(\.id)) }
                Button("すべて残す") { keep.formUnion(items.map(\.id)) }
            } label: {
                Image(systemName: "checklist")
            }
        }
        .navigationTitle(kind.label)
    }
}

/// 消した行。左にスワイプして戻せる。
private struct TrashView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var items: [Junk.TrashItem] = []
    @State private var status = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        List {
            if !status.isEmpty {
                Text(status).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.day + " " + Self.timeFormatter.string(from: item.line.time) + "  " + item.kind.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.line.text)
                }
                .swipeActions {
                    Button("戻す", systemImage: "arrow.uturn.backward") { restore(item) }
                        .tint(.blue)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("消した行はありません", systemImage: "trash")
            }
        }
        .navigationTitle("消した行")
        .onAppear { items = pipeline.trash() }
    }

    private func restore(_ item: Junk.TrashItem) {
        Task {
            do {
                try await pipeline.restore(item)
                status = "戻しました。"
            } catch {
                status = "戻せませんでした: \(error.localizedDescription)"
            }
            items = pipeline.trash()
        }
    }
}

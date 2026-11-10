import SwiftUI
import PhotosUI
import UIKit

// MARK: - 一覧

/// 仕事のまとめの一覧（日ごと・新しい日から）。押すと読む、左へ払うと消す。上の行から取り込む。
/// タスクタブの「やる」のいちばん下の「仕事のまとめ」と、右上の＋の「仕事のまとめを取り込む」から開く。
struct WorkDigestListView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var importing = false
    @State private var note: String?
    @State private var deleting: WorkDigest.Entry?
    /// 退勤の頃の知らせ（2026-11-10。WorkDigestReminder）
    @AppStorage(WorkDigestReminder.onKey) private var remind = true
    @AppStorage(WorkDigestReminder.minuteKey) private var remindMinute = WorkDigestReminder.defaultMinute

    var body: some View {
        let groups = pipeline.workDigests.byDay
        List {
            Section {
                Button("取り込む（写真・スクショ・貼り付け）", systemImage: "square.and.arrow.down") { importing = true }
            } footer: {
                Text("職場の Claude に「この日に何があったか」を聞いた答えを、スクリーンショット・写真か、文字の貼り付けで取り込みます。文字の読み取りは iPhone の中だけで行い、AI（言語モデル）には送りません。「自分の宿題」は、タスクの「確かめ待ち」（仕事）に入ります。")
            }
            if UIDevice.current.userInterfaceIdiom == .phone {
                Section {
                    Toggle("退勤の頃に知らせる", isOn: $remind)
                    if remind {
                        DatePicker("知らせる時刻", selection: Binding(
                            get: { WorkDigestReminder.date(minute: remindMinute) },
                            set: { remindMinute = WorkDigestReminder.minute(of: $0) }),
                                   displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("職場で記録した日で、その日のまとめがまだ入っていないときだけ、この時刻に1回知らせます。知らせに会話の中身は入りません。")
                }
                .onChange(of: remind) { pipeline.scheduleWorkDigestReminder() }
                .onChange(of: remindMinute) { pipeline.scheduleWorkDigestReminder() }
            }
            if let note {
                Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            if groups.isEmpty {
                Section { Text("まだありません").foregroundStyle(.secondary) }
            }
            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(group.entries) { entry in
                        NavigationLink {
                            WorkDigestDetailView(entry: entry)
                        } label: {
                            WorkDigestRow(entry: entry)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("消す") { deleting = entry }.tint(.red)
                        }
                    }
                } header: {
                    Text(Pipeline.workDigestDayTitle(group.day))
                }
            }
        }
        .navigationTitle("仕事のまとめ")
        .sheet(isPresented: $importing) {
            NavigationStack {
                WorkDigestImportView { note = $0 }
            }
        }
        .alert("このまとめを消しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { entry in
            Button("消す", role: .destructive) {
                withAnimation { pipeline.workDigests.delete(entry.id) }
                deleting = nil
            }
            Button("やめる", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("消したまとめは戻せません。タスクに入れた宿題は、そのまま残ります。")
        }
    }
}

/// 一覧の1行（はじめの「決まったこと」か、文のはじめ・取り込んだ時刻・見出しごとの数）
struct WorkDigestRow: View {
    let entry: WorkDigest.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline).lineLimit(2)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        if let s = entry.sections {
            // 決まったことが無い日は、ほかの見出しの1つめ（見出しの行や出どころを、題にしない）
            let items: [String] = s.decided + s.homework + s.others + s.topics + s.checks
            if let first = items.first { return first }
        }
        let lines = entry.text.components(separatedBy: .newlines)
        let body = lines.first { line in
            !line.isEmpty && WorkDigestParser.header(line)?.part != .date
        }
        return body ?? entry.text
    }

    private var caption: String {
        var parts: [String] = [entry.addedAt.formatted(date: .omitted, time: .shortened) + " に取り込み", entry.source.label]
        if let s = entry.sections {
            let counts: [String] = s.lists.map { "\($0.title) \($0.items.count)" }
            parts += counts
        }
        return parts.joined(separator: "・")
    }
}

// MARK: - 読む

/// まとめ1つを読む（見出しごと。下に、取り込んだ文をそのまま）
struct WorkDigestDetailView: View {
    let entry: WorkDigest.Entry

    var body: some View {
        List {
            Section {
                LabeledContent("日付", value: Pipeline.workDigestDayTitle(entry.day))
                LabeledContent("取り込み", value: entry.addedAt.formatted(date: .abbreviated, time: .shortened) + "・"
                               + entry.source.label)
            }
            if let sections = entry.sections {
                ForEach(sections.lists, id: \.title) { list in
                    Section(list.title) {
                        ForEach(Array(list.items.enumerated()), id: \.offset) { item in
                            Text(item.element).textSelection(.enabled)
                        }
                    }
                }
            }
            Section {
                Text(entry.text).textSelection(.enabled)
            } header: {
                Text("取り込んだ文")
            }
        }
        .navigationTitle(Pipeline.workDigestDayTitle(entry.day))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 取り込む

/// 取り込む画面。写真・スクショ（何枚でも、選んだ順につなぐ）を iPhone の中で読み取るか、文字を貼り付ける。
/// 読み取った文字は直せる。日付は文の【日付】から（無ければ今日）。「入れる」で残す。
struct WorkDigestImportView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    /// 入れたあとの一文
    var onSaved: (String) -> Void = { _ in }

    @State private var text = ""
    @State private var date = Date.now
    @State private var dateFromText = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var reading: String?
    @State private var usedPhoto = false
    @State private var problem: String?

    var body: some View {
        let parsed = WorkDigestParser.parse(text)
        let homework: [String] = parsed.sections.homework
        let sources: [String] = parsed.sections.sources ?? []
        let hasText: Bool = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Form {
            Section {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 20, selectionBehavior: .ordered, matching: .images) {
                    Label("写真・スクショを選ぶ（何枚でも）", systemImage: "photo.on.rectangle")
                }
                Button("写真を撮る", systemImage: "camera") { takingPhoto = true }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                PasteButton(payloadType: String.self) { strings in
                    let pasted = strings.joined(separator: "\n")
                    Task { @MainActor in addText(pasted, photo: false) }
                }
                if let reading {
                    HStack { ProgressView(); Text(reading) }
                }
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            } header: {
                Text("読み取る")
            } footer: {
                Text("何枚かに分けたスクショは、選んだ順につなげます。足すたびに、下の文の後ろに続けます。文字の読み取りは iPhone の中だけで行います。")
            }
            Section {
                DatePicker("日付", selection: $date, displayedComponents: .date)
            } footer: {
                Text(dateFromText ? "文の【日付】から入れました。違っていれば直してください。" : "文に【日付】が無ければ、今日にします。")
            }
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 260)
            } header: {
                Text("読み取った文字（直せます）")
            } footer: {
                if hasText && !parsed.found {
                    Text("決まった形の見出し（【決まったこと】など）が見つかりません。このまま入れると、文のまま残します（宿題はタスクに入りません）。")
                }
            }
            if !sources.isEmpty {
                Section {
                    ForEach(Array(sources.enumerated()), id: \.offset) { item in
                        Text(item.element)
                    }
                } header: {
                    Text("出どころ（\(sources.count) 件）")
                } footer: {
                    Text("どこの話か・そこにいた人です。見せるだけで、人の帳には何も足しません。")
                }
            }
            if !homework.isEmpty {
                Section {
                    ForEach(Array(homework.enumerated()), id: \.offset) { item in
                        Text(item.element)
                    }
                } header: {
                    Text("タスクの確かめ待ちに入れるもの（\(homework.count) 件）")
                } footer: {
                    Text("「自分の宿題」の分です。同じものがもうタスクにあれば、入れません。")
                }
            }
        }
        .navigationTitle("仕事のまとめを取り込む")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("入れる") { save() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reading != nil)
            }
        }
        .onChange(of: photoItems) {
            let picked = photoItems
            guard !picked.isEmpty else { return }
            Task { await load(picked) }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                takingPhoto = false
                if let image { Task { await readImages([image]) } }
            }
            .ignoresSafeArea()
        }
    }

    /// 選んだ写真を、選んだ順に読み込んで読み取る
    private func load(_ picked: [PhotosPickerItem]) async {
        reading = "写真を読み込んでいます…"
        var images: [UIImage] = []
        for item in picked {
            let data: Data? = try? await item.loadTransferable(type: Data.self)
            if let data, let image = UIImage(data: data) { images.append(image) }
        }
        photoItems = []
        await readImages(images)
    }

    private func readImages(_ images: [UIImage]) async {
        guard !images.isEmpty else {
            reading = nil
            problem = "写真を読み込めませんでした。"
            return
        }
        problem = nil
        var texts: [String] = []
        for (n, image) in images.enumerated() {
            reading = images.count > 1 ? "文字を読み取っています…（\(n + 1)/\(images.count)）" : "文字を読み取っています…"
            // 頼まれごと帳の写真と同じ読み取り（iPhone の中・日本語と英語）
            let read = await Pipeline.recognizeText(image)
            if !read.isEmpty { texts.append(read) }
        }
        reading = nil
        guard !texts.isEmpty else {
            problem = "文字を読み取れませんでした。明るいところで、まっすぐ撮ってみてください。"
            return
        }
        addText(texts.joined(separator: "\n"), photo: true)
    }

    /// 文の後ろに足し、【日付】があれば日付に入れる
    private func addText(_ new: String, photo: Bool) {
        let piece = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        let old = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = old.isEmpty ? piece : old + "\n" + piece
        if photo { usedPhoto = true }
        problem = nil
        if let day = WorkDigestParser.parse(text).day, let found = TaskBook.dayFormat.date(from: day) {
            date = found
            dateFromText = true
        }
    }

    private func save() {
        let day = TaskBook.dayFormat.string(from: date)
        let source: WorkDigest.Source = usedPhoto ? .photo : .paste
        let note = pipeline.importWorkDigest(day: day, text: text, source: source)
        onSaved(note)
        dismiss()
    }
}

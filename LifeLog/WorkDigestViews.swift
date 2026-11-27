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
        LLList {
            Section {
                Button("取り込む（写真・スクショ・貼り付け）", systemImage: "square.and.arrow.down") { importing = true }
                // 職場の Claude への頼み方を、今日の日付にしてコピーする（2026-11-10）
                Button("職場の Claude への頼み方をコピー（今日）", systemImage: "doc.on.doc") {
                    // s34 円2: その日の 1 つの文が届いていればそれ、無ければ今の頼み方（S34ABook.promptText）
                    UIPasteboard.general.string = S34ABook.shared.promptText(day: TaskBook.dayFormat.string(from: .now))
                    note = "頼み方をコピーしました。職場の Claude に貼ってください。"
                }
                S32APromptButtons { note = $0 }  // s32: 週の台帳・土台・AI からの質問の頼み方（S32AViews.swift）
            } footer: {
                Text("職場の Claude に「この日に何があったか」を聞いた答えを、スクリーンショット・写真か、文字の貼り付けで取り込みます。文字の読み取りは iPhone の中だけで行い、取り込みには AI（言語モデル）を使いません。「自分の宿題」は、タスクの「やる」（仕事）に入ります。取り込んだまとめは「記録」の検索で探せて、「記録に質問する」の材料にもなります（質問のときだけ言語モデルに渡します。職場の会話と同じ設定に従います）。")
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
                Section { Text(note).font(.footnote).foregroundStyle(LL.dim) }
            }
            // 週ごと・案件ごとに読む（2026-11-10。言語モデルは使わない）
            if !groups.isEmpty {
                Section {
                    NavigationLink {
                        WorkWeekView()
                    } label: {
                        Label("週のまとめ（週報の下書き）", systemImage: "calendar")
                    }
                    NavigationLink {
                        WorkThreadsView()
                    } label: {
                        Label("案件ごと", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    NavigationLink {
                        MeetingPrepView()
                    } label: {
                        Label("会議の前に（これからの予定で会う人）", systemImage: "person.2.wave.2")
                    }
                }
            }
            if groups.isEmpty {
                Section { Text("まだありません").foregroundStyle(LL.dim) }
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
                            Button("消す") { deleting = entry }.tint(LL.danger)
                        }
                    }
                } header: {
                    Text(Pipeline.workDigestDayTitle(group.day))
                }
            }
        }
        .navigationTitle("仕事のまとめ")
        .countsOpen("workDigest")
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
            Text(caption).font(.caption).foregroundStyle(LL.dim)
        }
    }

    private var headline: String {
        if let s = entry.sections {
            // 決まったことが無い日は、ほかの見出しの1つめ（見出しの行や出どころを、題にしない）
            let items: [String] = s.decided + s.homework + s.others + s.topics + s.checks
            if let first = items.first { return S32ADigest.split(first).text }
        }
        let lines = entry.text.components(separatedBy: .newlines)
        let body = lines.first { line in
            !line.isEmpty && WorkDigestParser.header(line)?.part != .date
        }
        return body ?? entry.text
    }

    private var caption: String {
        // s34 円1: 写真から自動で拾ったものは「写真から（自動）」（S34ABook.swift）
        let source: String = S34APhotoScan.shared.entryIDs.contains(entry.id) ? "写真から（自動）" : entry.source.label
        var parts: [String] = [entry.addedAt.formatted(date: .omitted, time: .shortened) + " に取り込み", source]
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
        LLList {
            Section {
                LabeledContent("日付", value: Pipeline.workDigestDayTitle(entry.day))
                LabeledContent("取り込み", value: entry.addedAt.formatted(date: .abbreviated, time: .shortened) + "・"
                               + entry.source.label)
            }
            if entry.sections != nil {
                // 行の終わりの出どころの番号（［1］）は外して、その出どころの名前を下に出す（2026-11-10）
                let lines = Pipeline.workDigestLines(entry)
                let titles: [String] = lines.reduce(into: [String]()) { list, line in
                    if !list.contains(line.heading) { list.append(line.heading) }
                }
                ForEach(titles, id: \.self) { title in
                    Section(title) {
                        ForEach(Array(lines.filter { $0.heading == title }.enumerated()), id: \.offset) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.element.text).textSelection(.enabled)
                                if !item.element.source.isEmpty {
                                    Text("出どころ: " + item.element.source).font(.caption).foregroundStyle(LL.dim)
                                }
                                // s32: 項目の終わりの（HH:MM 名前）は文から外して、ここに（S32ARules.swift）
                                if !item.element.stamp.isEmpty {
                                    Text(item.element.stamp).font(.caption).foregroundStyle(LL.dim)
                                }
                            }
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
    /// はじめから入れておく文（共有・ショートカットから渡されたもの。2026-11-10）
    var initialText: String = ""
    /// 入れたあとの一文
    var onSaved: (String) -> Void = { _ in }

    @State private var text = ""
    @State private var copied: String?
    /// 「頼み方をコピー」を押したあとの一文（2026-11-12）
    @State private var promptCopied: String?
    @State private var date = Date.now
    @State private var dateFromText = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var reading: String?
    @State private var usedPhoto = false
    @State private var problem: String?
    /// s35: 読んだ写真を縮めた JPEG（12 枚まで・メモリの中だけ）。「入れる」のあと、家の PC が写真を受けるときだけ送る
    @State private var photoJPEGs: [Data] = []
    /// s36（K36-2）: 写真の種類（初めは「まとめ」）。表・一覧は、まとめとは別に写真だけ送る
    @State private var kind: S36APhotoKind = .digest
    /// s36 細1: 上限を超えて送らない枚数（画面の中で知らせる）
    @State private var droppedPhotos = 0

    /// s36: いまの家の PC の features（hello の前は覚えている分）
    private var features: Set<String> { S36ABook.shared.features(pipeline.homePC.features) }
    /// s36 細1: 1 回に送る写真の枚数（"workphoto30" なら 30・無ければ 12）
    private var photoCap: Int { S36APhotoRules.limit(features) }

    var body: some View {
        let parsed = WorkDigestParser.parse(text)
        // 箇条書きの前に書かれた前置きの文は、タスクにしない
        let homework: [String] = parsed.homeworkTasks.map { S32ADigest.split($0).text }
        let sources: [String] = parsed.sections.sources ?? []
        let hasText: Bool = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 何日分かをまとめて貼ったとき（【日付】が2つ以上）は、日ごとに分けて入れる（2026-11-10）
        let days: [(day: String, text: String)] = WorkDigestParser.splitDays(text)
        LLForm {
            // 職場の Claude に貼る頼み方を、取り込む画面からもコピーできる（2026-11-12。下の日付の日の分）
            Section {
                Button("職場の Claude への頼み方をコピー", systemImage: "doc.on.doc") {
                    // s34 円2: その日の 1 つの文が届いていればそれ、無ければ今の頼み方（S34ABook.promptText）
                    UIPasteboard.general.string = S34ABook.shared.promptText(day: TaskBook.dayFormat.string(from: date))
                    promptCopied = "コピーしました。職場の Claude に貼ってください。"
                }
                if let promptCopied { Text(promptCopied).font(.footnote).foregroundStyle(LL.dim) }
            } header: {
                Text("まず、職場の Claude に聞く")
            } footer: {
                Text("そのまま貼れる頼み方です。日付は、下の「日付」の日になります。")
            }
            // s36（K36-2）: 写真の種類（家の PC が "workphoto30" を持つときだけ。初めは「まとめ」）
            if S36APhotoRules.kindsOffered(features) {
                S36APhotoKindSection(kind: $kind)
            }
            Section {
                PhotosPicker(selection: $photoItems, maxSelectionCount: max(20, photoCap + 10), selectionBehavior: .ordered, matching: .images) {
                    Label("写真・スクショを選ぶ（何枚でも）", systemImage: "photo.on.rectangle")
                }
                // コピーしたスクショを、そのまま読み取る（2026-11-10）
                Button("コピーした画像を読み取る", systemImage: "doc.on.clipboard") { pasteImages() }
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
                    Text(problem).foregroundStyle(LL.danger)
                }
                if !kind.isDigest {
                    Text("送る写真 \(photoJPEGs.count) 枚（\(photoCap) 枚まで）").font(.footnote).foregroundStyle(LL.dim)
                }
                // s36 細1: 上限を超えたら、送る前に画面の中で（知らせではない）
                if let over = S36APhotoRules.overflowLine(dropped: droppedPhotos, limit: photoCap) {
                    Text(over).font(.footnote).foregroundStyle(LL.warn)
                        .accessibilityIdentifier("s36a.photo.over")
                }
            } header: {
                Text("読み取る")
            } footer: {
                Text("何枚かに分けたスクショは、選んだ順につなげます。足すたびに、下の文の後ろに続けます。文字の読み取りは iPhone の中で行います。家の PC が写真を受けられるときは、「入れる」のあと写真も縮めて送り、家の PC で読み直します。")
            }
            Section {
                DatePicker("日付", selection: $date, displayedComponents: .date)
            } footer: {
                Text(dateFromText ? "文の【日付】から入れました。違っていれば直してください。" : "文に【日付】が無ければ、今日にします。")
            }
            // s36: 表・一覧の写真のときは、文の取り込みの所は出さない（写真だけ送る）
            if kind.isDigest {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 260)
            } header: {
                Text("読み取った文字（直せます）")
            } footer: {
                if hasText && !parsed.found {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("決まった形の見出し（【決まったこと】など）が見つかりません。このまま入れると、文のまま残します（宿題はタスクに入りません）。")
                        // 職場の Claude に、決まった形で答え直してもらう頼み方（2026-11-10）
                        Button("答え直してもらう頼み方をコピー", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = WorkDigestPrompt.fix(day: TaskBook.dayFormat.string(from: date))
                            copied = "コピーしました。職場の Claude に貼ってください。"
                        }
                        if let copied { Text(copied) }
                    }
                }
            }
            if days.count >= 2 {
                Section {
                    ForEach(Array(days.enumerated()), id: \.offset) { item in
                        Text(Pipeline.workDigestDayTitle(item.element.day))
                    }
                } header: {
                    Text("\(days.count) 日分に分けて入れます")
                } footer: {
                    Text("文の中に【日付】が \(days.count) つあるので、日ごとに分けて入れます。上の「日付」は使いません。")
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
                    Text("タスクの「やる」に入れるもの（\(homework.count) 件）")
                } footer: {
                    Text("「自分の宿題」の分です。同じものがもうタスクにあれば、入れません。箇条書きの前に書かれた前置きの文は、入れません。")
                }
            }
            }  // if kind.isDigest
        }
        .navigationTitle("仕事のまとめを取り込む")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if kind.isDigest {
                    Button("入れる") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reading != nil)
                } else {
                    // s36（K36-2）: 表・一覧は写真だけを家の PC へ（POST /work/digest は送らない・新しい id）
                    Button("送る") { sendTable() }
                        .disabled(photoJPEGs.isEmpty || reading != nil)
                }
            }
        }
        .onChange(of: photoItems) {
            let picked = photoItems
            guard !picked.isEmpty else { return }
            Task { await load(picked) }
        }
        // 種類を変えたら、読んだ写真は持ち越さない（まとめの文は残す）
        .onChange(of: kind) {
            photoJPEGs = []
            droppedPhotos = 0
            problem = nil
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                takingPhoto = false
                if let image { Task { await readImages([image]) } }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            if text.isEmpty && !initialText.isEmpty {
                addText(initialText, photo: false)
                // s35: ショートカットから渡された写真（縮めた JPEG）も一緒に預かる
                let handed: [Data] = DigestInbox.takePhotos()
                if !handed.isEmpty {
                    photoJPEGs = Array(handed.prefix(photoCap))
                    usedPhoto = true
                }
                // s36 細1: 預からなかった枚数も画面の中で知らせる
                droppedPhotos = DigestInbox.takeDropped() + max(0, handed.count - photoCap)
            }
        }
    }

    /// コピーした画像（スクショなど）を読み取る。画像が無ければ、コピーした文を足す
    private func pasteImages() {
        let board = UIPasteboard.general
        if board.hasImages, let images = board.images, !images.isEmpty {
            Task { await readImages(images) }
        } else if board.hasStrings, let string = board.string, !string.isEmpty {
            addText(string, photo: false)
        } else {
            problem = "コピーした画像がありません。スクショを撮って、左下の小さな画面を長押しして「コピー」してから押してください。"
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
        let cap: Int = photoCap
        // s36（K36-2）: 表・一覧の写真は文字を読まない（写真だけ送る。家の PC が表の行を写す）
        let readText: Bool = kind.isDigest
        for (n, image) in images.enumerated() {
            if readText {
                reading = images.count > 1 ? "文字を読み取っています…（\(n + 1)/\(images.count)）" : "文字を読み取っています…"
                // 頼まれごと帳の写真と同じ読み取り（iPhone の中・日本語と英語）
                let read = await Pipeline.recognizeText(image)
                if !read.isEmpty { texts.append(read) }
            } else {
                reading = "写真を縮めています…（\(n + 1)/\(images.count)）"
            }
            // s35: 写真そのものも縮めて持っておく（家の PC で Claude が書き起こす。12 枚まで・s36 細1: "workphoto30" なら 30 枚）
            if photoJPEGs.count >= cap {
                droppedPhotos += 1
            } else if let small = await S35PhotoRules.jpeg(image) {
                photoJPEGs.append(small)
            }
        }
        reading = nil
        guard readText else { return }
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
        let source: WorkDigest.Source = usedPhoto ? .photo : .paste
        let days: [(day: String, text: String)] = WorkDigestParser.splitDays(text)
        if days.count >= 2 {
            // 日ごとに分けて入れる（2026-11-10）
            let notes: [String] = days.map { pipeline.importWorkDigest(day: $0.day, text: $0.text, source: source) }
            onSaved(notes.joined(separator: "\n"))
        } else {
            let day = TaskBook.dayFormat.string(from: date)
            onSaved(pipeline.importWorkDigest(day: day, text: text, source: source))
        }
        // s30: いま入れた分を家の PC へ送り、すぐ作り直す（S30WBook.swift）。s35: 写真から読んだときは写真も（文のあと）
        let shots: [Data] = usedPhoto ? photoJPEGs : []
        S30WBook.shared.saved(pipeline.workDigests.entries, loosePhotos: shots)
        photoJPEGs = []
        dismiss()
    }

    /// s36（K36-2）: テストケースの表・不具合の一覧の写真を、まとめとは別の新しい id で送る（取り込みはしない）
    private func sendTable() {
        let day = TaskBook.dayFormat.string(from: date)
        let note: String = S36ABook.shared.sendTable(kind, day: day, photos: photoJPEGs)
        photoJPEGs = []
        onSaved(note)
        dismiss()
    }
}

// MARK: - 職場の Claude への頼み方（2026-11-10）

/// 職場の Claude に貼る頼み方。docs/work-digest.md の「そのまま貼れる頼み方」と同じ中身（直すときは両方）。
/// 職場の Claude に渡す文なので、アプリの中の言語モデルには使わない
enum WorkDigestPrompt {
    /// いつもの頼み方（日付を入れて）。s32（2026-11-27・K32-1）で【会議】【メール】と、項目の終わりの（HH:MM 名前）を足した
    /// （前の見出しと順はそのまま）。週の台帳・土台・AI からの質問の頼み方は S32APrompt（S32ARules.swift）
    static func full(day: String) -> String {
        """
        \(day) の Teams のやり取りと、Outlook の予定・メールを読んで、下の形だけで答えてください。

        きまり
        ・見出しは下の【 】をそのまま使う。順番も変えない。
        ・表・太字・絵文字・前置き・あとがきは使わない。箇条書きは「・」で、1行に1つ。
        ・聞き返さない。分からないことは書かない。何も無い見出しは「・なし」と書く。
        ・【出どころ】には、読んだ場所（チーム＞チャネル、またはチャット）とスレッドの題を、1行に1つ書く。行の頭に［1］［2］と番号を付ける。そこにいた人も書く（多いときは、発言した人だけでよい）。
        ・【会議】には、その日の会議（Outlook の予定）を、1行に1つ「HH:MM〜HH:MM 会議名（出席：名前、名前）」で書き、その後ろに番号を書く。
        ・ほかの見出しの項目は、行の終わりに、言った時刻と言った人を（HH:MM 名前）で書く（分かる範囲だけでよい）。その後ろに、どの出どころの話かを［1］のように番号で書く。
        ・【自分の宿題】は、頼んだ人と期限を（誰から／いつまで）で書き、その後ろに（HH:MM 名前）と番号を書く。
        ・【よく出た言葉】は、言葉だけを1行に1つ（説明と番号は書かない）。
        ・【メール】には、Outlook の自分宛てと自分が出したメールを、1行に1つ「HH:MM 送り主→宛先「件名」: 要点」で書く。

        【日付】\(day)
        【出どころ】
        ・［1］チーム名＞チャネル名「スレッドの題」（いた人：名前、名前）
        ・［2］チャット「グループの名前」（いた人：名前、名前）
        【会議】
        ・HH:MM〜HH:MM 会議名（出席：名前、名前）［1］
        【決まったこと】
        ・…（HH:MM 名前）［1］
        【自分の宿題】
        ・…（誰から／いつまで）（HH:MM 名前）［1］
        【ほかの人の動き】
        ・名前: …（HH:MM 名前）［2］
        【気になる話題】
        ・…（HH:MM 名前）［1］
        【あとで確かめること】
        ・…（HH:MM 名前）［2］
        【よく出た言葉】
        ・…
        【メール】
        ・HH:MM 送り主→宛先「件名」: 要点
        """
    }

    /// 決まった形になっていなかったときの、答え直しの頼み方
    static func fix(day: String) -> String {
        "さっきの答えを、下の形に直してください。中身は変えず、見出しと並べ方だけ直してください。\n\n" + full(day: day)
    }
}

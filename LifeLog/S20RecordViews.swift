import SwiftUI
import UIKit

// 1 日を 1 本の帯で見て、指でなぞって範囲を選ぶ（s20 の 体28・体29・次11・次12。2026-11-21）。
// 選んだ範囲を「消す」（30 秒は取り消せる・家の PC にも消す頼み）・「書き出す」（音声・文字・まとめを zip で共有）・「印を付ける」。
// 探す窓を 1 つに（体30）も、ここに置く。

struct DayBandView: View {
    @Environment(Pipeline.self) private var pipeline
    @State var day: Date
    @State private var selection: ClosedRange<Date>?
    @State private var dragFrom: Double?
    @State private var confirmForget = false
    @State private var pendingUntil: Date?
    @State private var cancelled = false
    @State private var note: String?
    @State private var exportURL: URL?
    @State private var exporting = false
    /// iPhone の中に残っている録音の始まり（開いたとき・日を変えたときに 1 回読む）
    @State private var audioStarts: [Date] = []

    init(day: Date) {
        _day = State(initialValue: Calendar.current.startOfDay(for: day))
    }

    var body: some View {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        let key = ReviewRules.dayKey(start)
        // body-read-ok: 選んだ 1 日だけ（帯に会話の位置を描くため）
        let talks = pipeline.conversations(on: key)
        let spans = pipeline.ledger.map(for: start).spans
        LLList {
            Section {
                DatePicker("日", selection: Binding(get: { day }, set: { day = Calendar.current.startOfDay(for: $0); selection = nil }),
                           in: Date.now.addingTimeInterval(-60 * 86400)...Date.now, displayedComponents: .date)
                VStack(alignment: .leading, spacing: LL.Space.s) {
                    GeometryReader { geo in
                        let width = Double(geo.size.width)
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: LL.Radius.small).fill(LL.surface2)
                            ForEach(Array(spans.enumerated()), id: \.offset) { _, s in
                                let x0 = BandRules.x(of: s.start, width: width, dayStart: start, dayEnd: end)
                                let x1 = BandRules.x(of: s.end, width: width, dayStart: start, dayEnd: end)
                                Rectangle().fill(Self.color(s.kind))
                                    .frame(width: max(1, x1 - x0), height: 18)
                                    .offset(x: x0, y: 40)
                            }
                            ForEach(Array(talks.enumerated()), id: \.offset) { _, c in
                                let x0 = BandRules.x(of: c.start, width: width, dayStart: start, dayEnd: end)
                                let x1 = BandRules.x(of: c.end, width: width, dayStart: start, dayEnd: end)
                                RoundedRectangle(cornerRadius: 2).fill(LL.accent)
                                    .frame(width: max(2, x1 - x0), height: 22)
                                    .offset(x: x0, y: 12)
                            }
                            if let selection {
                                let x0 = BandRules.x(of: selection.lowerBound, width: width, dayStart: start, dayEnd: end)
                                let x1 = BandRules.x(of: selection.upperBound, width: width, dayStart: start, dayEnd: end)
                                RoundedRectangle(cornerRadius: LL.Radius.chip)
                                    .fill(LL.accent.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: LL.Radius.chip).strokeBorder(LL.accent, lineWidth: LL.Stroke.bold))
                                    .frame(width: max(4, x1 - x0), height: 70)
                                    .offset(x: x0)
                                    .animation(LL.Motion.fade, value: selection)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { v in
                                let from = dragFrom ?? Double(v.startLocation.x)
                                dragFrom = from
                                selection = BandRules.range(fromX: from, toX: Double(v.location.x), width: width,
                                                            dayStart: start, dayEnd: end)
                            }
                            .onEnded { _ in
                                dragFrom = nil
                                LLHaptic.confirm.play()
                            })
                    }
                    .frame(height: 70)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("1 日の帯。指でなぞって時間を選びます")
                    .accessibilityIdentifier("dayBand")
                    HStack {
                        ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                            Text("\(h)").font(.caption2).foregroundStyle(LL.dim).monospacedDigit()
                            if h < 24 { Spacer() }
                        }
                    }
                    HStack(spacing: LL.Space.m) {
                        legend(LL.accent, "会話")
                        legend(Self.color(.recorded), "録れた")
                        legend(Self.color(.held), "休む場所")
                        legend(Self.color(.gap), "抜け")
                    }
                }
                .padding(.vertical, LL.Space.xs)
            } header: {
                LLHeader(title: "1 日の帯", symbol: "slider.horizontal.below.rectangle")
            } footer: {
                Text("帯を指でなぞると、その時間を選べます（\(BandRules.snapMinutes) 分きざみ）。")
            }
            if let selection {
                let lines = talks.flatMap(\.lines).filter { selection.contains($0.time) }
                let convs = talks.filter { $0.start <= selection.upperBound && $0.end >= selection.lowerBound }.count
                let audio = audioStarts.filter { selection.contains($0) }.count
                Section {
                    Text(BandRules.label(selection)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(ForgetRules.summary(lines: lines.count, conversations: convs, audio: audio))
                        .font(.callout).foregroundStyle(LL.dim)
                    HStack(spacing: LL.Space.s) {
                        Button {
                            confirmForget = true
                        } label: {
                            Label("消す", systemImage: "trash")
                        }
                        .buttonStyle(LLPillButtonStyle(tint: LL.danger))
                        .disabled(pendingUntil != nil)
                        Button {
                            Task { await export(selection) }
                        } label: {
                            Label(exporting ? "作っています…" : "書き出す", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(LLPillButtonStyle())
                        .disabled(exporting)
                        Button {
                            mark(selection)
                        } label: {
                            Label("印", systemImage: "star")
                        }
                        .buttonStyle(LLPillButtonStyle())
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("書き出した zip を共有", systemImage: "doc.zipper") }
                    }
                } header: {
                    LLHeader(title: "選んだ時間", symbol: "selection.pin.in.out")
                }
            }
            if let pendingUntil {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(pendingUntil.timeIntervalSince(context.date).rounded(.up)))
                        HStack {
                            ZStack {
                                Circle().stroke(LL.line, lineWidth: 3)
                                Circle().trim(from: 0, to: CGFloat(left) / CGFloat(ForgetRules.undoSeconds))
                                    .stroke(LL.warn, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                Text("\(left)").font(.caption.weight(.bold)).monospacedDigit()
                            }
                            .frame(width: 36, height: 36)
                            Text("\(left) 秒後に消します。画面を閉じても消します。").font(.callout)
                            Spacer()
                            Button("取り消す") {
                                cancelled = true
                                self.pendingUntil = nil
                                LLHaptic.done.play()
                                note = "取り消しました。何も消していません。"
                            }
                            .buttonStyle(LLPillButtonStyle(tint: LL.warn, filled: true))
                        }
                    }
                }
            }
            if let note {
                Section { Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(LL.dim) }
            }
        }
        .task(id: key) { audioStarts = Storage.keptAudio().compactMap { Storage.startDate(of: $0) } }
        .navigationTitle("1 日の帯")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("dayBand")
        .sheet(isPresented: $confirmForget) {
            if let selection {
                ForgetConfirmSheet(range: selection, summary: forgetSummary(selection, talks: talks)) { alsoPC in
                    confirmForget = false
                    startForget(selection, day: key, alsoPC: alsoPC)
                } onCancel: {
                    confirmForget = false
                }
                .presentationDetents([.medium])
            }
        }
    }

    static func color(_ kind: RecordingLedger.Span.Kind) -> Color {
        switch kind {
        case .recorded: LL.good.opacity(0.75)
        case .quiet: LL.dim.opacity(0.35)
        case .held: LL.dim.opacity(0.6)
        case .gap: LL.warn.opacity(0.8)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.caption2).foregroundStyle(LL.dim)
        }
    }

    private func forgetSummary(_ range: ClosedRange<Date>, talks: [ConversationLog.Conversation]) -> String {
        let lines = talks.flatMap(\.lines).filter { range.contains($0.time) }.count
        let convs = talks.filter { $0.start <= range.upperBound && $0.end >= range.lowerBound }.count
        let audio = audioStarts.filter { range.contains($0) }.count
        return ForgetRules.summary(lines: lines, conversations: convs, audio: audio)
    }

    private func startForget(_ range: ClosedRange<Date>, day: String, alsoPC: Bool) {
        cancelled = false
        let until = Date.now.addingTimeInterval(Double(ForgetRules.undoSeconds))
        pendingUntil = until
        note = nil
        Task {
            try? await Task.sleep(for: .seconds(ForgetRules.undoSeconds))
            guard !cancelled else { return }
            pendingUntil = nil
            do {
                let result = try await pipeline.forgetRange(day: day, from: range.lowerBound, to: range.upperBound)
                if alsoPC, let body = ForgetRules.pcBody(from: range.lowerBound, to: range.upperBound) {
                    MothershipOutbox.enqueue(path: "records/\(day)/forget", body: body)
                }
                LLHaptic.done.play()
                note = "文字 \(result.lines) 行・録音 \(result.audio) 個を消しました。文字は「記録の掃除」から 30 日戻せます。"
                selection = nil
            } catch {
                LLHaptic.failed.play()
                note = "消せませんでした（あとでもう一度）: " + error.localizedDescription
            }
        }
    }

    private func export(_ range: ClosedRange<Date>) async {
        exporting = true
        defer { exporting = false }
        exportURL = await ExportZip.make(pipeline, from: range.lowerBound, to: range.upperBound)
        if exportURL == nil { note = "書き出せませんでした" }
    }

    private func mark(_ range: ClosedRange<Date>) {
        let end = min(range.upperBound, range.lowerBound.addingTimeInterval(6 * 3600))
        if let body = KnowMeRules.markBody(day: ReviewRules.dayKey(range.lowerBound), kind: "other", start: range.lowerBound,
                                           end: end, questionID: nil) {
            MothershipOutbox.enqueue(path: "know/mark", body: body)
            LLHaptic.done.play()
            note = "印を付けました（" + BandRules.label(range) + "）。母艦の録音の印に入ります。"
        }
    }
}

/// 体29: 消すときの安心（何が消えるか・30 秒は取り消せる）
private struct ForgetConfirmSheet: View {
    let range: ClosedRange<Date>
    let summary: String
    let onForget: (Bool) -> Void
    let onCancel: () -> Void
    @State private var alsoPC = true

    var body: some View {
        NavigationStack {
            LLList {
                Section {
                    Label(BandRules.label(range), systemImage: "clock").font(.headline).monospacedDigit()
                    Label(summary, systemImage: "trash").foregroundStyle(LL.danger)
                } header: {
                    LLHeader(title: "消えるもの", symbol: "exclamationmark.triangle")
                }
                Section {
                    Label("Google ドキュメントの、その時間の行も消します", systemImage: "doc.text")
                    Label("消した文字は「記録の掃除」の消した行に 30 日残り、戻せます", systemImage: "arrow.uturn.backward")
                    Label("録音は、文字にし終えた iPhone の中の分だけを消します（ドライブに上げた分は残ります）", systemImage: "waveform")
                    Toggle("家の PC に送った分も消すよう頼む", isOn: $alsoPC)
                } header: {
                    LLHeader(title: "安心のために")
                }
                Section {
                    Button(role: .destructive) {
                        onForget(alsoPC)
                    } label: {
                        Label("消す（\(ForgetRules.undoSeconds) 秒は取り消せます）", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LLPillButtonStyle(tint: LL.danger, filled: true))
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("この時間を消す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる", action: onCancel) }
            }
        }
    }
}

// MARK: - 次12 期間を選んで書き出す（音声・文字・まとめを zip に）

enum ExportZip {
    /// 選んだ時間の文字（行）・まとめ（見出しと要点）・音声（iPhone の中に残っている分）を 1 つの zip に
    @MainActor
    static func make(_ pipeline: Pipeline, from: Date, to: Date) async -> URL? {
        let fm = FileManager.default
        let stamp = ReviewRules.dayKey(from) + "-" + String(format: "%02d%02d", Calendar.current.component(.hour, from: from),
                                                             Calendar.current.component(.minute, from: from))
        let dir = fm.temporaryDirectory.appendingPathComponent("LifeLog-" + stamp, isDirectory: true)
        try? fm.removeItem(at: dir)
        guard (try? fm.createDirectory(at: dir.appendingPathComponent("音声"), withIntermediateDirectories: true)) != nil else { return nil }
        var text = "# LifeLog " + BandRules.label(from...to) + "\n\n"
        var summary = "# まとめ\n\n"
        var d = Calendar.current.startOfDay(for: from)
        while d <= to {
            for c in pipeline.conversations(on: ReviewRules.dayKey(d)) where c.end >= from && c.start <= to {
                let lines = c.lines.filter { $0.time >= from && $0.time <= to }
                guard !lines.isEmpty else { continue }
                let head = c.title ?? "会話"
                text += "## " + c.start.formatted(date: .abbreviated, time: .shortened) + " " + head + "\n\n"
                for l in lines { text += ConversationLog.docLine(l) + "\n" }
                text += "\n"
                summary += "- " + c.start.formatted(date: .omitted, time: .shortened) + " " + head
                if !c.points.isEmpty { summary += "：" + c.points.joined(separator: "／") }
                summary += "\n"
            }
            d = d.addingTimeInterval(86400)
            await Task.yield()
        }
        try? text.write(to: dir.appendingPathComponent("文字.md"), atomically: true, encoding: .utf8)
        try? summary.write(to: dir.appendingPathComponent("まとめ.md"), atomically: true, encoding: .utf8)
        for file in Storage.keptAudio() {
            guard let start = Storage.startDate(of: file), start >= from, start <= to else { continue }
            try? fm.copyItem(at: file, to: dir.appendingPathComponent("音声").appendingPathComponent(file.lastPathComponent))
        }
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &error) { zipped in
            let dest = fm.temporaryDirectory.appendingPathComponent("LifeLog-" + stamp + ".zip")
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: zipped, to: dest)) != nil { result = dest }
        }
        try? fm.removeItem(at: dir)
        Tally.add("s20.export")
        return result
    }
}

// MARK: - 体30 探す窓を 1 つに（人・場所・日・言葉・質問）

struct UnifiedSearchView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var query = ""
    @State private var hits: [Pipeline.Hit] = []

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let people = q.isEmpty ? [] : pipeline.people.filter { ($0.name ?? "").localizedCaseInsensitiveContains(q) }
        let places = q.isEmpty ? [] : pipeline.places.places.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let day = Self.parseDay(q)
        LLList {
            if q.isEmpty {
                Section {
                    LLEmpty(title: "1 つの窓で探します", symbol: "magnifyingglass",
                            detail: "人の名前・場所・日（11/20・2026-11-20）・言葉。質問の形なら、記録に質問できます。")
                }
            }
            if let day {
                Section {
                    NavigationLink { DayView(day: day) } label: { Label(day, systemImage: "calendar") }
                    NavigationLink { DayBandView(day: Self.date(day) ?? .now) } label: {
                        Label("この日の帯", systemImage: "slider.horizontal.below.rectangle")
                    }
                } header: { LLHeader(title: "日", symbol: "calendar") }
            }
            if !people.isEmpty {
                Section {
                    ForEach(people.prefix(8)) { p in
                        NavigationLink { PersonView(id: p.id) } label: { Label(p.name ?? "", systemImage: "person") }
                    }
                } header: { LLHeader(title: "人", symbol: "person.2") }
            }
            if !places.isEmpty {
                Section {
                    ForEach(places.prefix(8), id: \.id) { p in Label(p.name, systemImage: "mappin.and.ellipse") }
                } header: { LLHeader(title: "場所", symbol: "map") }
            }
            if q.count >= 2 {
                Section {
                    NavigationLink { AskView() } label: {
                        Label("「\(q)」を記録に質問する", systemImage: "questionmark.bubble")
                    }
                } header: { LLHeader(title: "質問", symbol: "questionmark.bubble") }
                Section {
                    if hits.isEmpty {
                        Text("言葉の当たりはありません").font(.callout).foregroundStyle(LL.dim)
                    }
                    ForEach(hits.prefix(30)) { HitRow(hit: $0) }
                } header: { LLHeader(title: "言葉", symbol: "text.magnifyingglass", trailing: hits.isEmpty ? nil : "\(hits.count) 件") }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "人・場所・日・言葉")
        .onChange(of: query) { hits = query.count >= 2 ? pipeline.search(query) : [] }
        .navigationTitle("探す")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("unifiedSearch")
    }

    /// 「11/20」「2026-11-20」「11月20日」を日に（無ければ nil）
    static func parseDay(_ text: String, now: Date = .now) -> String? {
        if HomeFeeds.isDay(text) { return text }
        let digits = text.replacingOccurrences(of: "月", with: "/").replacingOccurrences(of: "日", with: "")
        let parts = digits.split(separator: "/")
        guard parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]), (1...12).contains(m), (1...31).contains(d) else { return nil }
        let year = Calendar.current.component(.year, from: now)
        return String(format: "%04d-%02d-%02d", year, m, d)
    }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }
}

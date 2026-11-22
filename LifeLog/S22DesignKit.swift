import SwiftUI
import UIKit

// s22 のデザインの部品（見6〜見15・見19・見21。2026-11-22。docs/s22-design.md）。
// 色・余白・角は Shared/Design/LLTheme.swift の LL、決まり（純粋な関数）は Shared/Design/S22DesignRules.swift。
// 「視差効果を減らす」がオンなら動かさない・光らせない。文字の大きさは名前（.callout など）で書く。

// MARK: - 見13 人の丸いアイコン

enum LLAvatar {
    /// 人の色（くすんだ 8 色。差し色の水色は「自分」だけに使う）。数は AvatarRules.paletteCount と同じ
    static let palette: [Color] = [
        Color.ll(light: 0x3D5A8F, dark: 0x8FA8D8),  // 青みのグレー
        Color.ll(light: 0x1F7A75, dark: 0x6CC3BE),  // 青緑
        Color.ll(light: 0x6A4FA3, dark: 0xB39DDB),  // 藤
        Color.ll(light: 0x8A6522, dark: 0xD8B98A),  // 砂
        Color.ll(light: 0x47773A, dark: 0x9CC58F),  // 若草
        Color.ll(light: 0x9A3F5C, dark: 0xD99AAE),  // 薄紅
        Color.ll(light: 0x8D5F14, dark: 0xD6A65F),  // 黄土
        Color.ll(light: 0x4A6075, dark: 0x9AB0C4),  // 鋼
    ]

    static func color(for name: String, isSelf: Bool = false) -> Color {
        isSelf ? LL.accent : palette[AvatarRules.colorIndex(name) % palette.count]
    }
}

/// 人の丸（頭文字と色は名前から決まる。名前そのものは変えない）。全画面でこれを使う
struct PersonAvatar: View {
    let name: String
    var isSelf = false
    @ScaledMetric private var size: CGFloat

    init(name: String, isSelf: Bool = false, size: CGFloat = 30) {
        self.name = name
        self.isSelf = isSelf
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        let color = LLAvatar.color(for: name, isSelf: isSelf)
        Text(isSelf ? "自" : AvatarRules.initial(name))
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.7), lineWidth: LL.Stroke.thin))
            .accessibilityHidden(true)  // 名前はそばの文字で読まれる
    }
}

// MARK: - 見14 読み込み中の骨組みと「前の写し ○分前」

/// 読み込み中に出す骨組み（形だけ。動かさない）
struct LLSkeletonRows: View {
    var count = 4

    var body: some View {
        ForEach(0..<count, id: \.self) { i in
            HStack(spacing: LL.Space.s) {
                Circle().fill(LL.surface2).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(i % 2 == 0 ? "読み込んでいる見出しの行" : "読み込んでいる行").font(.callout)
                    Text("中身の長さの見本になる文が入ります").font(.caption)
                }
            }
            .redacted(reason: .placeholder)
            .foregroundStyle(LL.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("読み込んでいます")
    }
}

/// 「前の写し 12 分前」（半日より古ければ琥珀）
struct LLCopyAgeLabel: View {
    let at: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Label(CopyAgeRules.text(at, now: context.date), systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(CopyAgeRules.isStale(at, now: context.date) ? LL.warn : LL.dim)
        }
    }
}

// MARK: - 見6・見7 自己点検の 6 つの丸の信号

/// 信号に入る 1 行
struct SignalRow: Identifiable {
    let item: DiagnosticItem
    let tone: LLTone
    var id: String { item.id }
}

enum S22Signals {
    struct Group {
        var rows: [SignalRow] = []
        var tone: LLTone { LLSignal.tone(of: rows.map(\.tone)) }
        /// 良くない行の数
        var bad: Int { rows.filter { $0.tone != .ok && $0.tone != .unknown }.count }
    }

    /// 行を 6 つの信号に分ける。fix は行の直し方の印（A1 の CheckupFix の名前）。nil なら控えめな見立て（LLTone.guessFix）
    static func group(_ items: [DiagnosticItem], fix: (DiagnosticItem) -> String?) -> [LLSignal: Group] {
        var out: [LLSignal: Group] = [:]
        for item in items {
            guard let signal = LLSignal.of(section: item.section, label: item.label) else { continue }
            let mark = fix(item) ?? LLTone.guessFix(section: item.section, label: item.label)
            out[signal, default: Group()].rows.append(SignalRow(item: item, tone: LLTone.of(ok: item.ok, fix: mark)))
        }
        return out
    }
}

/// 自己点検のいちばん上: 6 つの丸（端末・録音・時計・家の PC・文字になるまで・人）。押すと中身
struct S22SignalBoard: View {
    let items: [DiagnosticItem]
    /// 行の直し方の印（合流のときに A1 の CheckupFix をつなぐ。いまは控えめな見立て）
    var fix: (DiagnosticItem) -> String? = { _ in nil }
    @State private var open: LLSignal?

    var body: some View {
        let groups = S22Signals.group(items, fix: fix)
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: LL.Space.s), count: 3), spacing: LL.Space.s) {
                ForEach(LLSignal.allCases) { signal in
                    Button {
                        open = signal
                        LLHaptic.confirm.play()
                    } label: {
                        SignalDot(signal: signal, tone: groups[signal]?.tone ?? .unknown, bad: groups[signal]?.bad ?? 0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, LL.Space.xs)
            SignalLegend()
        } header: {
            LLHeader(title: "6 つの信号", symbol: "circle.grid.3x3")
        } footer: {
            Text("丸を押すと中身が出ます。赤は自分で動くもの、灰色は待てば直るもの、琥珀は気をつけたいもの（Claude に頼むものも琥珀）。")
        }
        .sheet(item: $open) { signal in
            SignalSheet(signal: signal, rows: groups[signal]?.rows ?? []) { open = nil }
                .presentationDetents([.medium, .large])
        }
    }
}

/// 丸 1 つ
struct SignalDot: View {
    let signal: LLSignal
    let tone: LLTone
    let bad: Int
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 48

    var body: some View {
        VStack(spacing: LL.Space.xs) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(tone.color.opacity(0.16))
                    Circle().strokeBorder(tone.color, style: StrokeStyle(lineWidth: LL.Stroke.bold,
                                                                          dash: tone == .unknown ? LL.Stroke.dash : []))
                    Image(systemName: signal.symbol).font(.body.weight(.semibold)).foregroundStyle(tone.color)
                }
                .frame(width: size, height: size)
                if bad > 0 {
                    Text("\(bad)")
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(LL.bg)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(tone.color, in: Capsule())
                        .offset(x: 6, y: -4)
                }
            }
            Text(signal.label).font(.caption.weight(.medium)).foregroundStyle(LL.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(tone.label).font(.caption2).foregroundStyle(LL.dim).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LL.Space.s)
        .background(LL.surface2, in: RoundedRectangle(cornerRadius: LL.Radius.small))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(signal.label) \(tone.label)" + (bad > 0 ? "、気になる行 \(bad)" : "") + "。押すと中身")
    }
}

/// 色の意味の見本（色だけでなく形でも分かるように）
struct SignalLegend: View {
    var body: some View {
        HStack(spacing: LL.Space.m) {
            ForEach([LLTone.act, .wait, .warn, .ok], id: \.self) { tone in
                HStack(spacing: 3) {
                    LLToneMark(tone: tone).font(.caption2)
                    Text(tone.label).font(.caption2).foregroundStyle(LL.dim)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 丸を押したときの中身（行ごとの色の意味と、読める形にした値）
struct SignalSheet: View {
    let signal: LLSignal
    let rows: [SignalRow]
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            LLList {
                if signal == .latency { LatencyBarSection() }
                Section {
                    if rows.isEmpty {
                        LLEmpty(title: "まだ中身がありません", symbol: signal.symbol, detail: "自己点検を開き直すと数え直します。")
                    }
                    ForEach(rows.sorted { $0.tone.weight > $1.tone.weight }) { row in
                        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                            LLToneMark(tone: row.tone)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.item.label).font(.callout.weight(.medium))
                                Text(LLNumber.display(row.item.value)).font(.callout).foregroundStyle(LL.dim)
                                if row.tone != .ok && row.tone != .unknown {
                                    Text(row.tone.label).font(.caption2.weight(.semibold)).foregroundStyle(row.tone.color)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    LLHeader(title: signal.label, symbol: signal.symbol, trailing: "\(rows.count) 行")
                }
            }
            .navigationTitle(signal.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
            }
        }
    }
}

// MARK: - 見8 「文字になるまで」を 1 本の横棒に

/// 録音の終わり→iPhone→PC の待ち→PC の作業→記録 のどこで何分（直近 24 時間のふつう）
struct LatencyBarSection: View {
    @State private var segments: [LatencyBarRules.Segment] = []
    @State private var loaded = false

    var body: some View {
        Section {
            if !loaded {
                LLSkeletonRows(count: 1)
            } else if segments.isEmpty {
                Text("まだ測っていません（区切りが記録に入ると測ります）").font(.callout).foregroundStyle(LL.dim)
            } else {
                LatencyBar(segments: segments)
            }
        } header: {
            LLHeader(title: "文字になるまで（直近 24 時間のふつう）", symbol: "timer")
        }
        .task {
            if let s = Latency.summary() {
                segments = LatencyBarRules.segments([s.toPhone, s.toPC, s.pcWait, s.pcWork, s.toRecord])
            }
            loaded = true
        }
    }
}

struct LatencyBar: View {
    let segments: [LatencyBarRules.Segment]

    var body: some View {
        let slow = LatencyBarRules.slowest(segments)
        let total = segments.reduce(0) { $0 + $1.seconds }
        VStack(alignment: .leading, spacing: LL.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("合わせて").font(.caption).foregroundStyle(LL.dim)
                Text(LLNumber.duration(total) ?? "1 秒未満").font(.title3.weight(.bold)).monospacedDigit()
            }
            GeometryReader { geo in
                let gaps = CGFloat(max(0, segments.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.color(seg, index: i, slow: slow))
                            .frame(width: max(3, (geo.size.width - gaps) * seg.fraction))
                    }
                }
            }
            .frame(height: 16)
            .accessibilityHidden(true)
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                HStack(spacing: LL.Space.s) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(seg, index: i, slow: slow)).frame(width: 10, height: 10)
                    Text(seg.name).font(.caption).foregroundStyle(seg.name == slow ? LL.text : LL.dim)
                    Spacer()
                    Text(LLNumber.duration(seg.seconds) ?? "1 秒未満").font(.caption.weight(seg.name == slow ? .bold : .regular))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            if let slow {
                Text("いちばん長いのは「\(slow)」です。").font(.caption2).foregroundStyle(LL.dim)
            }
        }
        .padding(.vertical, LL.Space.xs)
    }

    /// いちばん長い区間だけ差し色、ほかは薄い灰色の濃淡
    static func color(_ seg: LatencyBarRules.Segment, index: Int, slow: String?) -> Color {
        seg.name == slow ? LL.accent : LL.dim.opacity(0.28 + 0.1 * Double(index % 4))
    }
}

// MARK: - 見15 帯の光る所（「視差効果を減らす」なら光らない）

/// 帯の上に重ねる「いま届いた所」。talks が変わったら、新しく届いた所だけ少しのあいだ光る
struct BandGlowLayer: View {
    let talks: [BandSpan]
    let dayStart: Date
    let width: Double
    let height: CGFloat
    var y: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow: [BandSpan] = []
    @State private var lit = false

    var body: some View {
        let end = dayStart.addingTimeInterval(86400)
        ZStack(alignment: .topLeading) {
            ForEach(Array(glow.enumerated()), id: \.offset) { _, s in
                let x0 = BandRules.x(of: s.start, width: width, dayStart: dayStart, dayEnd: end)
                let x1 = BandRules.x(of: s.end, width: width, dayStart: dayStart, dayEnd: end)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LL.accent)
                    .frame(width: max(6, x1 - x0), height: height)
                    .shadow(color: LL.accent.opacity(0.9), radius: lit ? 8 : 0)
                    .opacity(lit ? 1 : 0)
                    .offset(x: max(0, x0 - 2), y: y)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: talks) { old, new in flash(BandGlow.fresh(old: old, new: new)) }
    }

    private func flash(_ spans: [BandSpan]) {
        guard !reduceMotion, !spans.isEmpty else { return }
        glow = spans
        withAnimation(.easeOut(duration: 0.25)) { lit = true }
        Task {
            try? await Task.sleep(for: .seconds(BandGlow.seconds))
            withAnimation(.easeIn(duration: 0.6)) { lit = false }
        }
    }
}

/// 今日の画面の小さな帯（会話＝差し色・録れた＝緑・いま＝縦の線）。文字が届くと、その所が光る
struct LLDayStrip: View {
    let talks: [BandSpan]
    let recorded: [BandSpan]
    let dayStart: Date
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 22

    var body: some View {
        let end = dayStart.addingTimeInterval(86400)
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                let w = Double(geo.size.width)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: LL.Radius.chip).fill(LL.surface2)
                    ForEach(Array(recorded.enumerated()), id: \.offset) { _, s in
                        let x0 = BandRules.x(of: s.start, width: w, dayStart: dayStart, dayEnd: end)
                        let x1 = BandRules.x(of: s.end, width: w, dayStart: dayStart, dayEnd: end)
                        Rectangle().fill(LL.good.opacity(0.45))
                            .frame(width: max(1, x1 - x0), height: height * 0.3)
                            .offset(x: x0, y: height * 0.7)
                    }
                    ForEach(Array(talks.enumerated()), id: \.offset) { _, s in
                        let x0 = BandRules.x(of: s.start, width: w, dayStart: dayStart, dayEnd: end)
                        let x1 = BandRules.x(of: s.end, width: w, dayStart: dayStart, dayEnd: end)
                        RoundedRectangle(cornerRadius: 2).fill(LL.accent)
                            .frame(width: max(2, x1 - x0), height: height * 0.6)
                            .offset(x: x0, y: height * 0.05)
                    }
                    BandGlowLayer(talks: talks, dayStart: dayStart, width: w, height: height * 0.7)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Rectangle().fill(LL.text.opacity(0.55))
                            .frame(width: 1.5, height: height)
                            .offset(x: BandRules.x(of: context.date, width: w, dayStart: dayStart, dayEnd: end))
                    }
                }
            }
            .frame(height: height)
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                    Text("\(h)").font(.caption2).foregroundStyle(LL.dim).monospacedDigit()
                    if h < 24 { Spacer() }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日の帯。会話 \(talks.count) 個。押すと 1 日の帯を開きます")
    }
}

// MARK: - 見19 md を読む（表は「1 行 1 カード」に）

/// 母艦・Claude の答え・報告の棚（楽5）の md を読む。見出し・箇条書き・段落・表（横に長い表は 1 行ずつのカード）
struct LLMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: LL.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// 太字・リンクなどの 1 行の中の書き方だけ読む
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlocks.Block

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(LLMarkdownView.inline(text))
                .font(level == 1 ? .title3.weight(.bold) : (level == 2 ? .headline : .subheadline.weight(.bold)))
                .foregroundStyle(LL.text)
                .padding(.top, LL.Space.xs)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("・").foregroundStyle(LL.dim)
                Text(LLMarkdownView.inline(text)).lineSpacing(ReadingRules.lineSpacing)
            }
        case .paragraph(let text):
            Text(LLMarkdownView.inline(text)).lineSpacing(ReadingRules.lineSpacing)
        case .table(let headers, let rows):
            MarkdownTableCards(headers: headers, rows: rows)
        case .rule:
            Rectangle().fill(LL.line).frame(height: LL.Stroke.hair)
        }
    }
}

/// 横に長い表を「1 行 1 カード」に: 1 列目を題、ほかの列は「見出し 値」の並び（空の値は出さない）
struct MarkdownTableCards: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.s) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                MarkdownRowCard(headers: headers, row: row)
            }
        }
    }
}

struct MarkdownRowCard: View {
    let headers: [String]
    let row: [String]

    var body: some View {
        let pairs: [(String, String)] = Array(zip(headers, row).dropFirst()).filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 4) {
            Text(LLMarkdownView.inline(row.first ?? "")).font(.callout.weight(.semibold)).foregroundStyle(LL.text)
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
                    Text(pair.0).font(.caption).foregroundStyle(LL.dim).frame(minWidth: 56, alignment: .leading)
                    Text(LLMarkdownView.inline(LLNumber.display(pair.1))).font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LL.Space.m)
        .background(LL.surface2, in: RoundedRectangle(cornerRadius: LL.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: LL.Radius.small).strokeBorder(LL.line, lineWidth: LL.Stroke.hair))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 見9〜見12 会話を読む画面（吹き出し・相づちを畳む・話題の線・行間と幅）

extension UncertainMarks {
    /// 確かでない語（数字・名前らしい言葉）に、薄い下線（見9）
    static func softUnderlined(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for range in ranges(in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].underlineStyle = Text.LineStyle(pattern: .solid, color: LL.dim.opacity(0.8))
        }
        return result
    }
}

/// 読む欄の幅（iPad では 1 行 38 字ほどに絞る。iPhone はそのまま）
struct ReadingWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17

    @ViewBuilder
    func body(content: Content) -> some View {
        if let width = ReadingRules.maxWidth(regular: sizeClass == .regular, fontSize: Double(bodySize)) {
            content.frame(maxWidth: CGFloat(width)).frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

extension View {
    func readingWidth() -> some View { modifier(ReadingWidth()) }
}

/// 会話の 1 行を吹き出しに。自分は右（差し色の地）、ほかの人は左（人の丸と同じ色の縁）
struct LineBubble<Trailing: View>: View {
    let text: String
    let speaker: String?
    let isSelf: Bool
    let time: String
    var uncertain = false
    var marked = false
    var doubt = false
    var original: String?
    var fromWatch = false
    var noisy = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let color = LLAvatar.color(for: speaker ?? "", isSelf: isSelf)
        HStack(alignment: .bottom, spacing: LL.Space.s) {
            if isSelf {
                Spacer(minLength: 36)
            } else if let speaker {
                PersonAvatar(name: speaker, size: 28)
            }
            VStack(alignment: isSelf ? .trailing : .leading, spacing: 3) {
                if !isSelf, let speaker {
                    HStack(spacing: 4) {
                        Text(speaker).font(.caption.weight(.bold)).foregroundStyle(color)
                        // 2 つの声のモデルで話し手が食い違った行
                        if doubt { Text("？").font(.caption.weight(.bold)).foregroundStyle(LL.warn) }
                    }
                }
                bubble(color: color)
                if let original {
                    Text("直す前: " + original).font(.caption).foregroundStyle(LL.dim)
                }
                HStack(spacing: 4) {
                    Text(time).font(.caption2.monospacedDigit())
                    if fromWatch { Image(systemName: "applewatch").font(.caption2) }
                    if noisy { Image(systemName: "speaker.wave.3").font(.caption2) }
                    trailing()
                }
                .foregroundStyle(LL.dim)
            }
            if !isSelf { Spacer(minLength: 36) }
        }
        .readingWidth()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    /// 読み上げの文（だれ・いつ・何と）
    private var spoken: String {
        let who: String = isSelf ? "自分" : (speaker ?? "話し手不明")
        let note: String = uncertain ? "（聞き取りが不確か）" : ""
        return who + "、" + time + "、" + text + note
    }

    private func bubble(color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if marked { Image(systemName: "star.fill").foregroundStyle(LL.warn).font(.caption) }
            if uncertain { Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(LL.warn) }
            Text(uncertain ? UncertainMarks.softUnderlined(text) : AttributedString(text))
                .font(.body)
                .lineSpacing(ReadingRules.lineSpacing)
                .foregroundStyle(uncertain ? LL.dim : LL.text)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, LL.Space.m)
        .padding(.vertical, LL.Space.s)
        .background(isSelf ? LL.accent.opacity(0.16) : LL.surface2,
                    in: UnevenRoundedRectangle(topLeadingRadius: LL.Radius.card, bottomLeadingRadius: isSelf ? LL.Radius.card : 4,
                                               bottomTrailingRadius: isSelf ? 4 : LL.Radius.card, topTrailingRadius: LL.Radius.card))
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: LL.Radius.card, bottomLeadingRadius: isSelf ? LL.Radius.card : 4,
                                   bottomTrailingRadius: isSelf ? 4 : LL.Radius.card, topTrailingRadius: LL.Radius.card)
                .stroke((isSelf ? LL.accent : color).opacity(0.35), lineWidth: LL.Stroke.hair)
        }
    }
}

/// 畳んだ相づちの行（押すと元の文が出る。元の文は消していない）
struct FoldedFillerRow: View {
    let count: Int
    let preview: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: LL.Space.s) {
                Image(systemName: "ellipsis.bubble").foregroundStyle(LL.dim)
                Text("相づち \(count) 行").font(.caption.weight(.semibold)).foregroundStyle(LL.dim)
                Text("「" + preview + "」").font(.caption).foregroundStyle(LL.dim.opacity(0.8)).lineLimit(1)
                Spacer()
                Text("出す").font(.caption2).foregroundStyle(LL.accent)
            }
            .readingWidth()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("相づち \(count) 行を畳んでいます。押すと出します")
    }
}

/// 話題の変わり目の線（言葉の重なりが急に下がる所。仮）
struct TopicBreakLine: View {
    var body: some View {
        HStack(spacing: LL.Space.s) {
            Rectangle().fill(LL.line).frame(height: LL.Stroke.thin)
            Text("話題が変わったかも（仮）").font(.caption2).foregroundStyle(LL.dim).fixedSize()
            Rectangle().fill(LL.line).frame(height: LL.Stroke.thin)
        }
        .readingWidth()
        .accessibilityLabel("ここで話題が変わったかもしれません（見立て）")
    }
}

/// 読む画面の切り替え（読みやすく・話題の線）。設定の名前
enum ReadingPrefs {
    /// 相づち・言い淀みを畳む（初めはオン。元の文は消さない）
    static let easyKey = "s22.readEasy"
    /// 話題の変わり目の線（初めはオン。仮）
    static let topicKey = "s22.topicLines"
}

/// 読む画面の右上の切り替え
struct ReadingMenu: View {
    @AppStorage(ReadingPrefs.easyKey) private var easy = true
    @AppStorage(ReadingPrefs.topicKey) private var topics = true

    var body: some View {
        Menu {
            Toggle("読みやすく（相づちを畳む）", isOn: $easy)
            Toggle("話題の変わり目の線（仮）", isOn: $topics)
        } label: {
            Image(systemName: easy ? "text.bubble.fill" : "text.bubble")
        }
        .accessibilityLabel("読み方の切り替え")
    }
}

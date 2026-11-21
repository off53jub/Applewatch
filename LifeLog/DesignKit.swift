import Charts
import SwiftUI
import UIKit

// 全画面で使う部品（s20 の 体1〜6・体33。2026-11-21）。色・余白・角は Shared/Design/LLTheme.swift の LL から取る。
// 決まりの一覧は docs/s20-design.md。

// MARK: - 見た目（暗い画面が先。体5）

enum LLAppearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    static let key = "llAppearance"

    var label: String {
        switch self {
        case .dark: "暗い（夜の青）"
        case .light: "明るい"
        case .system: "iPhone に合わせる"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

/// いちばん外に 1 回だけ付ける: 見た目（暗い・明るい）・差し色
struct LLRoot: ViewModifier {
    @AppStorage(LLAppearance.key) private var appearance = LLAppearance.dark.rawValue

    func body(content: Content) -> some View {
        content
            .tint(LL.accent)
            .preferredColorScheme((LLAppearance(rawValue: appearance) ?? .dark).scheme)
    }
}

extension View {
    func llRoot() -> some View { modifier(LLRoot()) }

    /// 一覧でない画面（ScrollView など）の地
    func llScreen() -> some View {
        background(LL.bg.ignoresSafeArea())
    }

    /// 中身が大きくて LLList に包むと型の決まりが時間切れになる一覧に、地だけ付ける（行は iOS の色のまま）
    func llListBackground() -> some View {
        scrollContentBackground(.hidden).background(LL.bg.ignoresSafeArea())
    }
}

// MARK: - 一覧（地は紺・行は面）

/// List の代わり。地を LL.bg、行を LL.surface にする（中身は List と同じに書ける）
struct LLList<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        List {
            Group { content }
                .listRowBackground(LL.surface)
        }
        .scrollContentBackground(.hidden)
        .background(LL.bg.ignoresSafeArea())
    }
}

/// Form の代わり（LLList と同じ見た目）
struct LLForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            Group { content }
                .listRowBackground(LL.surface)
        }
        .scrollContentBackground(.hidden)
        .background(LL.bg.ignoresSafeArea())
    }
}

// MARK: - 意味の色と確かさ（体1・体2）

extension Certainty {
    var color: Color {
        switch self {
        case .fact: LL.text
        case .guess: LL.dim
        case .waiting: LL.accent
        case .stopped: LL.warn
        case .danger: LL.danger
        case .good: LL.good
        }
    }
}

/// 確かさの見た目: 見立て（仮）＝薄い文字＋点線の枠・確かめ待ち＝差し色の細い枠・ほかは意味の色の文字
struct ConfidenceStyle: ViewModifier {
    let certainty: Certainty
    var framed = true

    @ViewBuilder
    func body(content: Content) -> some View {
        switch certainty {
        case .guess:
            content
                .foregroundStyle(LL.dim)
                .padding(framed ? LL.Space.s : 0)
                .overlay {
                    if framed {
                        RoundedRectangle(cornerRadius: LL.Radius.small)
                            .strokeBorder(LL.dim.opacity(0.7), style: StrokeStyle(lineWidth: LL.Stroke.thin, dash: LL.Stroke.dash))
                    }
                }
        case .waiting:
            content
                .padding(framed ? LL.Space.s : 0)
                .overlay {
                    if framed {
                        RoundedRectangle(cornerRadius: LL.Radius.small)
                            .strokeBorder(LL.accent, lineWidth: LL.Stroke.thin)
                    }
                }
        case .fact:
            content
        default:
            content.foregroundStyle(certainty.color)
        }
    }
}

extension View {
    /// 確かさの見た目を付ける（体2）
    func certainty(_ c: Certainty, framed: Bool = true) -> some View {
        modifier(ConfidenceStyle(certainty: c, framed: framed))
    }
}

/// 小さな印（「見立て（仮）」「確かめ待ち」など）
struct CertaintyBadge: View {
    let certainty: Certainty
    var text: String? = nil

    var body: some View {
        let label = text ?? certainty.label
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(certainty == .fact ? LL.dim : certainty.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                if certainty == .guess {
                    Capsule().strokeBorder(LL.dim, style: StrokeStyle(lineWidth: LL.Stroke.thin, dash: LL.Stroke.dash))
                } else {
                    Capsule().fill(certainty.color.opacity(0.14))
                }
            }
            .accessibilityLabel(label)
    }
}

// MARK: - 札の小さな絵（体4）

struct TagChip: View {
    let text: String
    var certainty: Certainty = .fact

    var body: some View {
        Label(text, systemImage: TagIcons.symbol(for: text))
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(certainty == .guess ? LL.dim : LL.text)
            .padding(.horizontal, LL.Space.s)
            .padding(.vertical, LL.Space.xs)
            .background(LL.surface2, in: Capsule())
            .overlay {
                if certainty == .guess {
                    Capsule().strokeBorder(LL.dim, style: StrokeStyle(lineWidth: LL.Stroke.thin, dash: LL.Stroke.dash))
                }
            }
            .accessibilityLabel("札 " + text + (certainty == .guess ? "（見立て）" : ""))
    }
}

/// 札を折り返して並べる
struct TagRow: View {
    let tags: [String]
    var certainty: Certainty = .fact

    var body: some View {
        FlowLayout(spacing: LL.Space.xs) {
            ForEach(tags, id: \.self) { TagChip(text: $0, certainty: certainty) }
        }
    }
}

/// 折り返して並べる（札・選ぶボタン）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - 小さなグラフ（体3）

struct MiniPoint: Identifiable, Equatable {
    let id: Int
    let label: String
    let value: Double
}

/// 数字の横に置く小さな棒（ラーメンの杯数・睡眠・気分・録音の時間）。最後の棒だけ差し色
struct MiniBars: View {
    let points: [MiniPoint]
    var height: CGFloat = 36
    var unit: String = ""

    var body: some View {
        Chart(points) { p in
            BarMark(x: .value("日", p.label), y: .value("数", p.value), width: .ratio(0.62))
                .foregroundStyle(p.id == points.last?.id ? LL.accent : LL.dim.opacity(0.45))
                .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(points.map { "\($0.label) \(MiniBars.short($0.value))\(unit)" }.joined(separator: "、"))
    }

    static func short(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// 線の小さなグラフ（気分など、続きを見るもの）
struct Sparkline: View {
    let points: [MiniPoint]
    var height: CGFloat = 32

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("日", p.id), y: .value("値", p.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LL.accent)
            if p.id == points.last?.id {
                PointMark(x: .value("日", p.id), y: .value("値", p.value))
                    .foregroundStyle(LL.accent)
                    .symbolSize(24)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(points.map { "\($0.label) \(MiniBars.short($0.value))" }.joined(separator: "、"))
    }
}

/// 大きな数字と小さなグラフを 1 つに（「今月 18 杯」＋棒）
struct StatTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var points: [MiniPoint] = []
    var certainty: Certainty = .fact

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            Text(title).font(.caption).foregroundStyle(LL.dim)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(certainty == .fact ? LL.text : certainty.color)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(LL.dim) }
            }
            if !points.isEmpty { MiniBars(points: points, height: 28) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LL.Space.m)
        .background(LL.surface2, in: RoundedRectangle(cornerRadius: LL.Radius.small))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - カード・空の状態・見出し

/// 1 枚のカード（一覧の外で使う。一覧の中では行がそのまま面になる）
struct LLCard<Content: View>: View {
    var certainty: Certainty = .fact
    private let content: Content

    init(certainty: Certainty = .fact, @ViewBuilder content: () -> Content) {
        self.certainty = certainty
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.s) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LL.Space.l)
            .background(LL.surface, in: RoundedRectangle(cornerRadius: LL.Radius.card))
            .overlay {
                switch certainty {
                case .guess:
                    RoundedRectangle(cornerRadius: LL.Radius.card)
                        .strokeBorder(LL.dim.opacity(0.7), style: StrokeStyle(lineWidth: LL.Stroke.thin, dash: LL.Stroke.dash))
                case .waiting:
                    RoundedRectangle(cornerRadius: LL.Radius.card).strokeBorder(LL.accent, lineWidth: LL.Stroke.thin)
                default:
                    RoundedRectangle(cornerRadius: LL.Radius.card).strokeBorder(LL.line, lineWidth: LL.Stroke.hair)
                }
            }
            .llShadow()
    }
}

extension View {
    /// 影（明るい画面だけ、ごく薄く。暗い画面は線で分ける）
    func llShadow() -> some View { modifier(LLShadow()) }
}

private struct LLShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.shadow(color: scheme == .dark ? .clear : Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}

/// 何も無いとき（何がたまると出るか・どうすれば出るか）
struct LLEmpty: View {
    let title: String
    let symbol: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: LL.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LL.accent.opacity(0.8))
            Text(title).font(.headline).foregroundStyle(LL.text)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(LL.dim).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LL.Space.xl)
        .accessibilityElement(children: .combine)
    }
}

/// 一覧の節の見出し（太さで差をつけ、色では差をつけない）
struct LLHeader: View {
    let title: String
    var symbol: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: LL.Space.xs) {
            if let symbol { Image(systemName: symbol).foregroundStyle(LL.accent) }
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(LL.text)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(LL.dim).monospacedDigit() }
        }
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 「なぜこうなった？」（体33）

struct WhyInfo: Identifiable, Equatable {
    var id: String { title }
    var title: String
    /// なぜそうなったか（1〜2 文）
    var reason: String
    /// 根拠（元の会話・記録への参照）
    var evidence: [String] = []
    /// 違っていたらどうするか
    var fix: String? = nil
    var certainty: Certainty = .guess
}

/// 見立て・通知のそばに置く小さな「なぜ？」。押すと根拠と直し方
struct WhyButton: View {
    let info: WhyInfo
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Label("なぜ？", systemImage: "questionmark.bubble")
                .font(.caption)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .tint(LL.accent)
        .accessibilityLabel("なぜこうなったかを見る")
        .sheet(isPresented: $open) {
            WhySheet(info: info) { open = false }
                .presentationDetents([.medium, .large])
        }
    }
}

struct WhySheet: View {
    let info: WhyInfo
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            LLList {
                Section {
                    VStack(alignment: .leading, spacing: LL.Space.s) {
                        CertaintyBadge(certainty: info.certainty)
                        Text(info.reason).font(.body)
                    }
                } header: {
                    LLHeader(title: "なぜこうなった？", symbol: "questionmark.bubble")
                }
                if !info.evidence.isEmpty {
                    Section {
                        ForEach(Array(info.evidence.enumerated()), id: \.offset) { _, e in
                            Label(e, systemImage: "text.quote").font(.callout).foregroundStyle(LL.dim)
                        }
                    } header: {
                        LLHeader(title: "根拠")
                    }
                }
                if let fix = info.fix {
                    Section {
                        Label(fix, systemImage: "wrench.and.screwdriver").font(.callout)
                    } header: {
                        LLHeader(title: "違っていたら")
                    }
                }
            }
            .navigationTitle(info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
            }
        }
    }
}

// MARK: - 振動（体21。iPhone の鳴らし方）

extension LLHaptic {
    @MainActor
    func play() {
        switch self {
        case .started:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .stopped:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .confirm:
            UISelectionFeedbackGenerator().selectionChanged()
        case .done:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - 押せる大きな札（○× のボタンなど）

struct LLPillButtonStyle: ButtonStyle {
    var tint: Color = LL.accent
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(filled ? LL.bg : tint)
            .padding(.horizontal, LL.Space.l)
            .padding(.vertical, LL.Space.s + 2)
            .frame(minHeight: 44)
            .background {
                if filled {
                    Capsule().fill(tint)
                } else {
                    Capsule().fill(tint.opacity(0.12))
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(LL.Motion.fade, value: configuration.isPressed)
    }
}

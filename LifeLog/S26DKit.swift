import Charts
import SwiftUI

// s26 の 絵1（アプリの部品表。A3・S26D。2026-11-25）。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 16」。
//
// ■ 部品表（ここを見れば、どの部品を使えばよいか分かる。数字は画面に書かない）
// - 色: LL.bg・surface・surface2・line・text・dim・accent・warn・danger・good（Shared/Design/LLTheme.swift。s20「夜の青」のまま）
// - 色の役割: LLRole（act＝赤・wait＝オレンジ・machine＝青・ask＝色なし。Shared/Design/S24DesignRules.swift・色は S24Views.swift）
// - 字の大きさ: LL.TypeScale（Shared/Design/S26DRules.swift。Dynamic Type に乗る）
// - 余白: LL.Space（xs 4・s 8・m 12・l 16・xl 24）／角: LL.Radius（chip 6・small 10・card 16・big 22）／線: LL.Stroke
// - 動き: LL.Motion／震え: LLHaptic（始まった・止まった・確かめて・完了・届いた・うまくいかない）
// - 一覧: LLList・LLForm／カード: LLCard／見出し: LLHeader／空: LLEmpty／札: TagChip・CertaintyBadge（DesignKit.swift）
// - 行: LLRow／役割の札: LLRoleChip／横棒: LLMeter／線のグラフ: LLTrendChart／文字が大きいと縦に積む: LLAdaptiveStack（このファイル）
// - 押せる札: LLPillButtonStyle（DesignKit.swift）
// 画面ごとに .orange・.red・cornerRadius: 10 のような数を直に書かない（担当 C が CI で数える）。

// MARK: - 行

/// 一覧の 1 行（題・2 段目・右の数・頭の印）。役割があれば、印と右の数がその色になる
struct LLRow: View {
    let title: String
    var detail: String? = nil
    var value: String? = nil
    var symbol: String? = nil
    var role: LLRole? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LL.Space.s) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(role?.color ?? LL.accent)
            } else if let role, role != .ask {
                Image(systemName: role.symbol).foregroundStyle(role.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LL.TypeScale.body).foregroundStyle(LL.text)
                if let detail, !detail.isEmpty {
                    Text(detail).font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            }
            Spacer(minLength: LL.Space.s)
            if let value {
                Text(value).font(LL.TypeScale.rowNumber).foregroundStyle(role.map { $0 == .ask ? LL.text : $0.color } ?? LL.text)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 役割の小さな札（「今日はここまで」「あなたが動く」など。色と形の両方で分かるように）
struct LLRoleChip: View {
    let text: String
    let role: LLRole

    var body: some View {
        Label(text, systemImage: role.symbol)
            .labelStyle(.titleAndIcon)
            .font(LL.TypeScale.tag)
            .foregroundStyle(role == .ask ? LL.text : role.color)
            .padding(.horizontal, LL.Space.s)
            .padding(.vertical, 2)
            .background((role == .ask ? LL.surface2 : role.color.opacity(0.14)), in: Capsule())
            .accessibilityLabel(role.label + "。" + text)
    }
}

// MARK: - 横棒（使った／上限）

struct LLMeter: View {
    /// 0〜1
    let fraction: Double
    var role: LLRole = .machine
    var height: CGFloat = 8

    var body: some View {
        let f = min(1, max(0, fraction.isFinite ? fraction : 0))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LL.surface2)
                Capsule().fill(role == .ask ? LL.dim : role.color)
                    .frame(width: max(f > 0 ? height : 0, f * geo.size.width))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(role.label)
        .accessibilityValue(S26DMeterRules.percentText(f))
    }
}

// MARK: - 線のグラフ（絵4。体・声・お金・録れた時間・体重を同じ線・同じ帯・同じ目盛りで）

struct LLTrendPoint: Identifiable, Equatable {
    let day: Date
    let value: Double
    var id: Date { day }
}

struct LLTrendChart: View {
    let points: [LLTrendPoint]
    var unit: String = ""
    /// 数（回・時間・円・歩）は 0 から。体重のように値のまわりだけを見るものは false
    var zeroBased = true
    var digits = 0
    var height: CGFloat = CGFloat(S26DTrendRules.height)

    var body: some View {
        let values: [Double] = points.map(\.value)
        let band = S26DTrendRules.band(values)
        let domain = S26DTrendRules.domain(values, zeroBased: zeroBased)
        let first: Date = points.first?.day ?? .now
        let last: Date = points.last?.day ?? .now
        Chart {
            if let band, points.count > 1 {
                RectangleMark(xStart: .value("日", first), xEnd: .value("日", last),
                              yStart: .value("値", band.low), yEnd: .value("値", band.high))
                    .foregroundStyle(LL.dim.opacity(0.14))
            }
            ForEach(points) { p in
                LineMark(x: .value("日", p.day), y: .value("値", p.value))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(LL.accent)
                PointMark(x: .value("日", p.day), y: .value("値", p.value))
                    .symbolSize(p.id == points.last?.id ? 36 : 10)
                    .foregroundStyle(p.id == points.last?.id ? LL.accent : LL.accent.opacity(0.6))
            }
        }
        .chartYScale(domain: domain.low...domain.high)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine().foregroundStyle(LL.line)
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).foregroundStyle(LL.dim)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(LL.line)
                AxisValueLabel().foregroundStyle(LL.dim)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(S26DTrendRules.summary(values, unit: unit, digits: digits))
    }
}

// MARK: - 文字がとても大きいときは縦に積む（絵10）

struct LLAdaptiveStack<Content: View>: View {
    var spacing: CGFloat = LL.Space.m
    @ViewBuilder var content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        layout { content() }
    }
}

// MARK: - 設定「見た目」に置く節（色の役割・震え。2026-11-25。s26 の 絵2・絵7）

struct S26DAppearanceSections: View {
    /// 文字が届いたときの震え（初めはオン。画面を開いているときだけ）
    @AppStorage(S26DHapticRules.arrivedKey) private var arrived = true

    var body: some View {
        Section {
            ForEach([LLRole.act, .wait, .machine], id: \.self) { role in
                LLRow(title: S26DAppearanceSections.roleText(role), role: role)
            }
        } header: {
            LLHeader(title: "色の役割", symbol: "paintpalette")
        } footer: {
            Text("問いには色を付けません（宿題に見えないように）。")
        }
        Section {
            Toggle("文字が届いたら軽く震える", isOn: $arrived)
            ForEach(Array(S26DHapticRules.table.enumerated()), id: \.offset) { _, item in
                Button {
                    item.haptic.play()
                } label: {
                    LLRow(title: item.event, detail: item.haptic.label, symbol: "iphone.radiowaves.left.and.right")
                }
                .buttonStyle(.plain)
            }
        } header: {
            LLHeader(title: "震え", symbol: "iphone.radiowaves.left.and.right")
        } footer: {
            Text("行を押すと、その震えを試せます。時計も同じ意味で震えます。")
        }
    }

    static func roleText(_ role: LLRole) -> String {
        switch role {
        case .act: "赤: あなたが動くもの"
        case .wait: "オレンジ: 待てば戻る（今日はお休み・明日また動く）"
        case .machine: "青: ふつうに動いている"
        case .ask: "色なし: 問い"
        }
    }
}

import SwiftUI
import WatchKit

// 時計の録音画面の「輪＋大きな数字 1 つ」（s22 の 見16。2026-11-22）。
// 輪＝今日録れた時間（12 時間で一周。仮）。真ん中の数字は「数字を切り替え」で 今日録れた・あと録れる・送っていない・確かめ待ち。
// 輪を押すと録音を始める・止める（前の丸いボタンと同じ）。「視差効果を減らす」がオンなら動かさない。決まりは Shared/Design/LLWatchRules.swift。

struct WatchRing: View {
    let recording: Bool
    let recorded: TimeInterval
    let unsent: Int
    let waiting: Int?
    let onToggle: () -> Void
    @AppStorage(WatchRingRules.key) private var numberRaw = WatchRingRules.Number.recorded.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 常時表示で暗いあいだは輪を動かさない（2026-11-29。s39 の 12）
    @Environment(\.isLuminanceReduced) private var dimmed
    @State private var breathe = false
    @State private var hoursLeft: Double?

    private var number: WatchRingRules.Number { WatchRingRules.Number(rawValue: numberRaw) ?? .recorded }
    /// 暗いので動かさないか（設定「静かなときの省電力」がオンのときだけ）
    private var stillWhenDim: Bool { dimmed && S39WatchPower.isOn(S39WatchPower.quietKey) }

    var body: some View {
        let shown = WatchRingRules.display(number, recorded: recorded, hoursLeft: hoursLeft, unsent: unsent, waiting: waiting)
        let color = recording ? LL.danger : LL.accent
        VStack(spacing: 4) {
            Button(action: onToggle) {
                ZStack {
                    Circle().stroke(LL.line, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: WatchRingRules.progress(recorded: recorded))
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : LL.Motion.state, value: recorded)
                    Circle().fill(color.opacity(recording && breathe && !stillWhenDim ? 0.16 : 0.10)).padding(10)
                    VStack(spacing: 0) {
                        Image(systemName: recording ? "stop.fill" : "record.circle")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(color)
                        Text(shown.big)
                            .font(.system(.title, design: .rounded, weight: .heavy))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .foregroundStyle(LL.text)
                        Text(shown.caption)
                            .font(.caption2)
                            .foregroundStyle(LL.dim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(.horizontal, 14)
                }
                .frame(width: 128, height: 128)
            }
            .buttonStyle(.plain)
            .accessibilityLabel((recording ? "録音中。押すと止めます。" : "止まっています。押すと録音を始めます。")
                                + WatchRingRules.spoken(number, recorded: recorded, hoursLeft: hoursLeft, unsent: unsent, waiting: waiting))
            Button {
                numberRaw = number.next.rawValue
                S39WatchPowerSide.light(.confirm)
            } label: {
                Label("数字を切り替え（\(number.next.label)）", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
            }
            .tint(LL.dim)
            .accessibilityLabel("真ん中の数字を「\(number.next.label)」に切り替える")
        }
        .onAppear {
            hoursLeft = Self.hoursLeft()
            guard !reduceMotion, !stillWhenDim else { return }
            withAnimation(LL.Motion.breathe) { breathe = true }
        }
        .onChange(of: dimmed) { _, _ in
            // 暗くなったら動きを止め（くり返しの動きを、動きなしで切る）、明るくなったら戻す
            if stillWhenDim {
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { breathe = false }
            } else if !reduceMotion {
                withAnimation(LL.Motion.breathe) { breathe = true }
            }
        }
        .onChange(of: recorded) { hoursLeft = Self.hoursLeft() }
    }

    /// あと何時間録れるか（電池と、これまでの減り方から。文字盤と同じ決まり）
    static func hoursLeft() -> Double? {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let samples = UserDefaults.standard.array(forKey: WatchSender.batterySamplesKey) as? [[Double]] ?? []
        return WatchFaceRules.hoursLeft(battery: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
                                        drainPerHour: HolidayRules.drainPerHour(samples, holding: false))
    }
}

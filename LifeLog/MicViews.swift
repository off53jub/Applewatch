import SwiftUI

/// 設定の「iPhone のマイク」（2026-11-07。MicInput.swift）。時計の録音には関係ない。
struct MicSettingsSection: View {
    @AppStorage(MicChoice.modeKey) private var mode = MicChoice.Mode.auto.rawValue
    @AppStorage(MicChoice.bluetoothKey) private var bluetooth = false
    @AppStorage(StereoMic.onKey) private var stereoOn = false
    @AppStorage(StereoMic.swapKey) private var swapped = false

    var body: some View {
        Section {
            Picker("マイク", selection: $mode) {
                ForEach(MicChoice.Mode.allCases) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            if mode == MicChoice.Mode.auto.rawValue {
                Toggle("Bluetooth のマイクも使う", isOn: $bluetooth)
            }
            Toggle("左右に分けて録れるとき: 左＝自分", isOn: $stereoOn)
            if stereoOn {
                Toggle("左右を入れ替える（右＝自分）", isOn: $swapped)
            }
            if MicRoute.shared.recording {
                LabeledContent("今のマイク", value: MicRoute.shared.text)
            }
        } header: {
            Text("iPhone のマイク")
        } footer: {
            Text("iPhone で録るときのマイクです（時計の録音は変わりません）。「自動」は、USB や受信機のマイク（DJI Mic Mini 2・RØDE Wireless Micro など）をつなぐと、それで録ります。外すと iPhone のマイクに戻ります。Bluetooth のマイクは音が悪いので、USB・受信機のマイクを先に使います。「Bluetooth のマイクも使う」をオンにすると、Bluetooth でつないだマイクでも録ります（AirPods などのイヤホンらしい名前のものは使いません）。\n「左右に分けて録れるとき」をオンにすると、2つのマイクを左右に分けて録れる受信機で、左のマイクを自分に付けたとき、その行の声が左右のどちらで大きいかを、話し手の見分けの手がかりにします（右のマイクは相手に付けます）。自分のマイクを右にするときは「左右を入れ替える」をオンにします。\nマイクの雑音を消す機能は切ってください（相手の声も消えるため）。この機能はマイクの本体（または DJI・RØDE のアプリ）の設定なので、LifeLog からは変えられません。")
        }
        .onChange(of: mode) { NotificationCenter.default.post(name: MicChoice.changed, object: nil) }
        .onChange(of: bluetooth) { NotificationCenter.default.post(name: MicChoice.changed, object: nil) }
    }
}

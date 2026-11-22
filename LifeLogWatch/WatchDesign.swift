import SwiftUI
import WatchKit

// 時計のデザイン（s20 の 体20・体21。2026-11-21）。色は Shared/Design/LLTheme.swift（時計はいつも暗い画面）。

extension LLHaptic {
    /// 振動の型（意味ごとに 1 つ）
    func play() {
        let type: WKHapticType
        switch self {
        case .started: type = .start
        case .stopped: type = .stop
        case .confirm: type = .notification
        case .done: type = .success
        case .failed: type = .failure
        }
        WKInterfaceDevice.current().play(type)
    }
}

/// 録音の画面のボタン（体20: 表に出すのは、よく使う 3 つ）
enum WatchAction: String, CaseIterable, Identifiable {
    case mark, newPerson, meeting, crowd, drink, ask, fix
    var id: String { rawValue }

    /// 録音中だけ出すもの
    var needsRecording: Bool { self == .mark || self == .newPerson || self == .meeting || self == .crowd }

    static let key = "watchActionCounts"

    static func counts() -> [String: Int] { UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:] }

    static func used(_ action: WatchAction) {
        var all = counts()
        all[action.rawValue, default: 0] += 1
        UserDefaults.standard.set(all, forKey: key)
    }

    /// よく使う順に、表の 3 つと残り
    static func split(recording: Bool) -> (top: [WatchAction], rest: [WatchAction]) {
        let list = allCases.filter { recording || !$0.needsRecording }
        var top = WatchFaceRules.topActions(list.map(\.rawValue), counts: counts()).compactMap { WatchAction(rawValue: $0) }
        // 録音中は「印」をいつも表に出す（指のダブルタップ handGestureShortcut は、画面に出ているボタンにしか効かないため。
        // 2026-11-22。s22 の 楽18）
        if recording, !top.contains(.mark), !top.isEmpty {
            top.removeLast()
            top.insert(.mark, at: 0)
        }
        return (top, list.filter { !top.contains($0) })
    }
}

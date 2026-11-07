import Foundation
import UIKit

/// 「処理」の時間の内訳を数える（2026-11-07）。
///
/// 自己点検の「直近24時間の処理」は、1回の処理（runQueue。区切りの文字起こしから、まとめ・同期まで）の
/// 始めから終わりまでの時間を数えていた。実機の点検で「いちばん長い 1968 秒（33分）」と出ていたが、その中には、
/// - 家の PC が文字にし終わるのを待つ時間（アプリを開いているとき、区切り1つにつき2分まで。区切りが溜まっていると、その数だけ）
/// - アプリが裏にいるあいだ、iOS がアプリを止めていた時間（止まっていても時計の針は進む）
/// も入っていた。iPhone が自分で動いていた時間とは別に数え、自己点検ではそれぞれ分けて出す。
@MainActor
enum RunClock {
    /// 裏にいた時間の合計（アプリが動いているあいだ）
    private static var backgroundTotal: TimeInterval = 0
    /// 裏に回った時刻（前にいれば nil）
    private static var backgroundSince: Date?
    /// 家の PC を待った時間の合計
    private static var waitedTotal: TimeInterval = 0

    /// 処理を始めたときの数（終わりとの差が、その処理のあいだの分）
    struct Mark {
        let background: TimeInterval
        let waited: TimeInterval
    }

    /// 1回の処理の内訳
    struct Parts: Equatable {
        /// 家の PC が文字にし終わるのを待っていた秒
        var waited: TimeInterval
        /// アプリが裏にいた秒（iOS がアプリを止めていた時間も入る）
        var background: TimeInterval
    }

    /// アプリが裏に回った（scenePhase の background）
    static func movedToBackground(now: Date = .now) {
        if backgroundSince == nil { backgroundSince = now }
    }

    /// アプリが前に出た（scenePhase の active）
    static func becameActive(now: Date = .now) {
        if let since = backgroundSince { backgroundTotal += max(0, now.timeIntervalSince(since)) }
        backgroundSince = nil
    }

    /// 家の PC を待った時間を足す
    static func addWait(_ seconds: TimeInterval) {
        waitedTotal += max(0, seconds)
    }

    private static func backgroundSeconds(now: Date) -> TimeInterval {
        backgroundTotal + (backgroundSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// 処理を始める
    static func begin(now: Date = .now) -> Mark {
        // 時計や見えない通知で裏で起こされたときは、scenePhase の知らせが来ないので、ここで裏にいると覚える
        if UIApplication.shared.applicationState == .background { movedToBackground(now: now) }
        return Mark(background: backgroundSeconds(now: now), waited: waitedTotal)
    }

    /// 処理を終える。そのあいだの内訳
    static func end(_ mark: Mark, now: Date = .now) -> Parts {
        Parts(waited: max(0, waitedTotal - mark.waited), background: max(0, backgroundSeconds(now: now) - mark.background))
    }
}

extension DiagnosticsLog.Run {
    /// iPhone が自分で動いていた秒（家の PC を待った・裏にいた時間を除く。古い記録は全部の時間）
    var working: Double { max(0, seconds - (waited ?? 0) - (background ?? 0)) }

    /// 裏にいた時間を含む（iOS に止められていたかもしれない）
    var wasInBackground: Bool { (background ?? 0) >= 1 || expired == true }
}

enum RunStats {
    /// 自己点検の「直近24時間の処理」の行の中身。iPhone が自分で動いていた時間で「ふつう・いちばん長い」を出し、
    /// 家の PC を待った・裏にいた時間は別に添える。ok は自分で動いていた時間のいちばん長いものが 25 秒より短いか
    static func summary(_ runs: [DiagnosticsLog.Run], now: Date = .now) -> (value: String, ok: Bool, detail: String?)? {
        let recent = runs.filter { now.timeIntervalSince($0.start) < 86400 }
        guard !recent.isEmpty else { return nil }
        let working = recent.map(\.working).sorted()
        let slow = working.last ?? 0
        let value = "\(recent.count) 回・ふつう \(seconds(working[working.count / 2]))・いちばん長い \(seconds(slow))"
        var parts: [String] = []
        let waited = recent.compactMap(\.waited).filter { $0 >= 1 }
        if let longest = waited.max() {
            parts.append("家の PC を待った \(waited.count) 回（いちばん長い \(seconds(longest))）")
        }
        let background = recent.filter(\.wasInBackground)
        if !background.isEmpty {
            let longest = background.map(\.seconds).max() ?? 0
            parts.append("裏にいた \(background.count) 回（始めから終わりまで いちばん長い \(seconds(longest))。iOS が止めていた時間も入る）")
        }
        let expired = recent.filter { $0.expired == true }.count
        if expired > 0 { parts.append("裏で使える時間が切れた \(expired) 回") }
        return (value, slow < 25, parts.isEmpty ? nil : parts.joined(separator: "・"))
    }

    static func seconds(_ s: Double) -> String { s < 10 ? String(format: "%.1f 秒", s) : "\(Int(s)) 秒" }
}

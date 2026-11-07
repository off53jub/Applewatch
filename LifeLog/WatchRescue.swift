import Foundation
import UserNotifications

/// 時計の区切りが iPhone に届かなくなったときの立て直し（2026-11-07）。
///
/// 2026-11-07 の実機の様子では、時計は「録音中」と知らせてくるのに、前の日の 21:35 から時計の区切りが1つも届いていなかった。
/// 時計の中に残っている区切りを失わずに届け直し、届かない理由を見分けられるようにする:
/// - 起動して時計とつながったら1回、時計に「残っている区切りを全部送り直して」と頼む
///   （前の iPhone のアプリ（TestFlight で入れ替える前など）が受け取れなかった区切りのため。もう受け取ったものは返事だけして捨てる）
/// - 時計に区切りが残っているのに30分届いていなければ、1時間に1回まで送り直しを頼む
/// - 時計が「録音を休む場所にいる」と思っていて、iPhone はそう思っていなければ（または逆）、設定を送り直す（10分に1回まで）。
///   休む場所にいるあいだ時計は区切りを書かないので、食い違ったままだと、録音中なのに区切りができない
/// - 時計が「録音しているつもり」なのに録音していなければ、知らせる（6時間に1回まで）
@MainActor
final class WatchRescueState {
    static let shared = WatchRescueState()
    var askedOnLaunch = false
    var resendAskedAt = Date.distantPast
    var heldResentAt = Date.distantPast
}

extension Pipeline {
    /// 時計とつながったとき（起動のたび）に呼ぶ
    func askWatchResendOnLaunch() {
        let rescue = WatchRescueState.shared
        guard !rescue.askedOnLaunch else { return }
        rescue.askedOnLaunch = true
        rescue.resendAskedAt = .now
        receiver.askWatchToResend()
    }

    /// 時計の様子が届くたびに呼ぶ
    func checkWatchDelivery(_ state: PhoneReceiver.WatchState, now: Date = .now) {
        let rescue = WatchRescueState.shared
        // 休む場所の食い違い（時計の思っていることが古いまま）
        if let held = state.held, held != recordingHeld, now.timeIntervalSince(rescue.heldResentAt) >= 600 {
            rescue.heldResentAt = now
            Tally.add("watch.heldMismatch")
            receiver.sendSettings(skipSilence: skipSilence, held: recordingHeld)
        }
        // 時計に区切りが残っているのに、しばらく届いていない
        if Self.shouldAskResend(left: state.leftOnWatch, lastArrival: watchDelays.entries.last?.received,
                                lastAsked: rescue.resendAskedAt, now: now) {
            rescue.resendAskedAt = now
            Tally.add("watch.resendAsked")
            receiver.askWatchToResend()
        }
        // 時計で録音しているつもりなのに、録音していない（時計が裏で起こされて、録音を始められなかったなど）
        if state.wanted == true, !state.recording, stopAlertsOn {
            let last = UserDefaults.standard.object(forKey: "watchNotRecordingAlert") as? Date ?? .distantPast
            if now.timeIntervalSince(last) >= 6 * 3600 {
                UserDefaults.standard.set(now, forKey: "watchNotRecordingAlert")
                let content = UNMutableNotificationContent()
                content.title = "時計の LifeLog が録音していません"
                content.body = "時計の LifeLog を開くと録音を再開します。"
                content.sound = .default
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "watch-not-recording", content: content, trigger: nil))
            }
        }
    }

    /// 送り直しを頼むか（時計に区切りが残っていて、30分届いておらず、前に頼んでから1時間たった）
    nonisolated static func shouldAskResend(left: Int?, lastArrival: Date?, lastAsked: Date, now: Date) -> Bool {
        guard let left, left > 0 else { return false }
        guard now.timeIntervalSince(lastArrival ?? .distantPast) >= 30 * 60 else { return false }
        return now.timeIntervalSince(lastAsked) >= 3600
    }
}

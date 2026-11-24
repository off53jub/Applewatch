import Foundation
import WatchConnectivity
import UserNotifications

/// iPhone の録音を始められなかったとき（2026-11-24）。
/// 時計が静かなときの「iPhone で録り始める」（s21 の 守4）・肩代わり（s23 の 止9）・職場に着いた（s18）などは、
/// アプリが裏にいるあいだに録音を始めようとする。iOS はほかの音（アラーム・電話など）があるときや裏からは断ることがあり、
/// 前は「The operation couldn't be completed. (OSStatus error 560557684.)」をそのまま知らせていた（560557684 は '!int'）。
/// いまは: やさしい 1 行で知らせ、押すか「録音を始める」で開いてすぐ始める。30 分以内にアプリを開いたら自動で始める。
enum S23StartFail {
    static let pendingKey = "s23.startPending"
    /// 開いたときに自動で始めるのは、断られてからこの秒まで
    static let pendingFor: TimeInterval = 30 * 60

    /// OSStatus の 4 文字（'!int' など）。分からなければ数のまま
    static func code(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSOSStatusErrorDomain || ns.code > 0x2000_0000 else { return "\(ns.domain).\(ns.code)" }
        let value = UInt32(truncatingIfNeeded: ns.code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let text = String(bytes: bytes, encoding: .ascii) else { return "\(ns.code)" }
        return text
    }

    /// 本人に見せる理由（生の英語は出さない）
    static func reason(_ error: Error, background: Bool) -> String {
        switch code(error) {
        case "!int":
            return background
                ? "LifeLog が裏にいたので、iOS が録音を始めさせませんでした（アラーム・電話など、ほかの音が鳴っていたときにも起きます）。"
                : "アラーム・電話など、ほかの音が鳴っているあいだは録音を始められません。"
        case "!rec":
            return "LifeLog が裏にいたので、iOS が録音を始めさせませんでした。"
        case "!pri":
            return "マイクを使う許可がありません。設定アプリの LifeLog で「マイク」をオンにしてください。"
        case "!siz", "!cat":
            return "マイクの設定がうまく合いませんでした。"
        default:
            let ns = error as NSError
            if ns.domain == "Recorder" { return ns.localizedDescription }
            return background ? "LifeLog が裏にいるあいだに始められませんでした。" : "マイクを使い始められませんでした。"
        }
    }

    static func markPending(now: Date = .now) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: pendingKey)
    }

    static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    static func isPending(now: Date = .now) -> Bool {
        let at = UserDefaults.standard.double(forKey: pendingKey)
        return isPending(at: at, now: now)
    }

    /// 純粋な判断（テスト用）
    static func isPending(at: TimeInterval, now: Date) -> Bool {
        guard at > 0 else { return false }
        let age = now.timeIntervalSince1970 - at
        return age >= 0 && age < pendingFor
    }

    static func body(reason: String) -> String {
        reason + "\n押すと（「" + S23Rec.resumeTitle + "」でも）、開いてすぐ録音を始めます。30 分以内に LifeLog を開いても始めます。"
    }

    /// 知らせ（「録音を戻す」と同じ分類なので、押すと開いて始める。S23Resume.resume が始める）
    @MainActor static func notify(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "iPhone の録音を始められませんでした"
        content.body = body(reason: reason)
        content.sound = .default
        content.interruptionLevel = UrgentNotice.level(for: S23Resume.stalledID)
        content.categoryIdentifier = S23Rec.phoneResumeCategory
        NoticeGate.add(UNNotificationRequest(identifier: S23Resume.stalledID, content: content, trigger: nil))
    }
}

/// 時計が家の PC に直接送っているか（2026-11-24）。
/// 直接送っているあいだ、時計は iPhone を起こさないので、iPhone からは「便りが 10 分途切れた」に見える。
/// 2026-11-24 に、時計は 5 分ごとに家の PC に届いていたのに「時計の録音が届いていません」が出て、
/// 守4 が裏で iPhone の録音を始めようとして断られた。直接送っているあいだは、この 2 つを動かさない。
@MainActor
enum S23WatchQuiet {
    /// 時計が最後に教えてくれた「直接送るがオン」と、今日の録り方の実験（iPhone 経由だけの日でない）から決める
    static func watchSendsDirect() -> Bool {
        guard WCSession.isSupported() else { return false }
        let watch = WCSession.default.receivedApplicationContext
        return isDirect(watchDirectOn: watch["pcDirect"] as? Bool, allowed: S21Rules.allowsDirect(S21Book.routeToday()))
    }

    /// 純粋な判断（テスト用）
    nonisolated static func isDirect(watchDirectOn: Bool?, allowed: Bool) -> Bool {
        watchDirectOn == true && allowed
    }
}

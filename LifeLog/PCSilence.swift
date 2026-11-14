import Foundation
import UIKit
import UserNotifications
import WatchConnectivity

/// 家の PC の外からの見張り（2026-11-15。強化案 38）。
///
/// 見張りも通知も家の PC から出ているので、PC ごと止まると何も届かない。そこで iPhone の側で、
/// ネットにつながっているのに家の PC と 6 時間やり取りできていないとき、ローカルの通知を1通（12 時間に1回まで）と、
/// 「今日」の「気をつけること」に1行を出す。家の PC の側の仕組みには頼らない。
/// - やり取りできた: 家の PC から答え（200）が返ったとき（どの口でも。文字起こし・写し・送り・Claude・裏で送った区切り）と、
///   時計が家の PC に直接送れたとき（時計が知らせる最後に送れた時刻 "pcSentAt"）。
/// - 鳴らす前に一度だけ短く確かめる（hello。つながれば鳴らさない）。家の PC をまだつないだことが無いときは鳴らさない。
/// - 前からある「家の PC につながりません」（文字起こしが2時間つながらない・Wi-Fi）を12時間以内に出していたら、通知は重ねない（1行は出す）。
enum PCSilence {
    static let contactKey = "pcLastContact"
    static let alertKey = "pcSilenceAlert"
    static let noticeID = "pc-silent"
    /// 時計が知らせる、最後に家の PC に直接送れた時刻（1970 からの秒）
    static let watchSentKey = "pcSentAt"
    static let quiet: TimeInterval = 6 * 3600
    static let alertEvery: TimeInterval = 12 * 3600
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastWritten: Double = 0

    /// 家の PC から答えが返った（どのスレッドからでもよい。書くのは1分に1回まで）
    static func noteContact(now: Date = .now) {
        let t: Double = now.timeIntervalSince1970
        let write: Bool = lock.withLock { () -> Bool in
            if t - lastWritten < 60 { return false }
            lastWritten = t
            return true
        }
        if write { UserDefaults.standard.set(t, forKey: contactKey) }
    }

    /// 最後にやり取りできた時刻（iPhone の分と、時計が直接送れた分の新しいほう。どちらも無ければ nil）
    static func lastContact(stored: Double?, watchSentAt: Double?) -> Date? {
        var best: Double = 0
        if let stored, stored > best { best = stored }
        if let watchSentAt, watchSentAt > best { best = watchSentAt }
        return best > 0 ? Date(timeIntervalSince1970: best) : nil
    }

    /// 6 時間やり取りできていないか（一度もやり取りしていなければ false）
    static func isQuiet(last: Date?, now: Date) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) >= quiet
    }

    /// 通知を出すか（つないである・ネットにつながっている・6 時間・前の通知から 12 時間）
    static func shouldAlert(configured: Bool, online: Bool, last: Date?, lastAlert: Date?, now: Date) -> Bool {
        guard configured, online, isQuiet(last: last, now: now) else { return false }
        guard let lastAlert else { return true }
        return now.timeIntervalSince(lastAlert) >= alertEvery
    }

    /// 「気をつけること」の1行（出さないときは nil）
    static func todayLine(configured: Bool, last: Date?, now: Date) -> String? {
        guard configured, isQuiet(last: last, now: now), let last else { return nil }
        let hours: Int = Int(now.timeIntervalSince(last) / 3600)
        let when: String = last.formatted(date: .abbreviated, time: .shortened)
        return "家の PC と \(hours) 時間やり取りできていません（最後 " + when + "）。PC と LifeLog PC が動いているか確かめてください"
    }

    static var stored: Double? {
        let t: Double = UserDefaults.standard.double(forKey: contactKey)
        return t > 0 ? t : nil
    }

    /// 時計が最後に家の PC に直接送れた時刻（時計の様子の知らせから）
    static func watchSentAt() -> Double? {
        guard WCSession.isSupported() else { return nil }
        let context: [String: Any] = WCSession.default.receivedApplicationContext
        return context[watchSentKey] as? Double
    }

    static func lastContactNow() -> Date? {
        lastContact(stored: stored, watchSentAt: watchSentAt())
    }
}

extension Pipeline {
    /// 家の PC と 6 時間やり取りできていなければ知らせる（取り込みのあとと、アプリを開いたとき。iPhone だけ）
    func checkPCSilence(now: Date = .now) async {
        guard homePC.isConfigured, UIDevice.current.userInterfaceIdiom != .pad else { return }
        guard PCSilence.isQuiet(last: PCSilence.lastContactNow(), now: now), archive.isOnline else { return }
        // 鳴らす前に一度だけ短く確かめる（つながれば、やり取りできたと数えて終わり）
        if (try? await homePC.hello()) != nil { return }
        let last: Date? = PCSilence.lastContactNow()
        let lastAlert: Date? = UserDefaults.standard.object(forKey: PCSilence.alertKey) as? Date
        guard PCSilence.shouldAlert(configured: homePC.isConfigured, online: archive.isOnline, last: last,
                                    lastAlert: lastAlert, now: now) else { return }
        UserDefaults.standard.set(now, forKey: PCSilence.alertKey)
        Tally.add("pc.silent")
        // 前からある「家の PC につながりません」を12時間以内に出していたら、通知は重ねない
        let older: Date = UserDefaults.standard.object(forKey: "homePCAlert") as? Date ?? .distantPast
        if homePC.downSince != nil, now.timeIntervalSince(older) < PCSilence.alertEvery { return }
        let content = UNMutableNotificationContent()
        content.title = "家の PC と 6 時間やり取りできていません"
        content.body = (PCSilence.todayLine(configured: true, last: last, now: now) ?? "家の PC が止まっていないか確かめてください")
            + "（PC が止まっているあいだは、PC からの知らせも届きません）"
        content.sound = .default
        NoticeGate.add(UNNotificationRequest(identifier: PCSilence.noticeID, content: content, trigger: nil))
    }
}

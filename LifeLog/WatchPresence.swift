import Foundation
import WatchConnectivity

/// 時計に LifeLog が入っているか（2026-11-07）。
///
/// 実機の点検（TestFlight ビルド 162）で、時計から 11:16 に便りが届いていて録音もしているのに、
/// 自己点検の「時計」が「時計に LifeLog が入っていません」と出ていた。
/// WCSession の isWatchAppInstalled は、TestFlight で入れ直したあとなどに、時計のアプリが動いていても
/// false のままのことがある（Apple の決まりでは「入っているか」を表すが、実機ではずれることがある。推測を含む）。
/// また、前の画面の一文は、つながりが変わったとき（activation・reachability・watchState）にしか作り直さないので、
/// 古い一文が残ることもある。
///
/// そこで、時計から最近（2日以内に）便り（様子の知らせ・区切り）が届いていれば「入っている」とみなし、
/// 一文は画面に出すたびに、そのときの WCSession の値から作る。
/// 時計に中身・答え・知らせを送るかどうかも、同じ決め方にする（false のままだと、時計に何も届かなかった）。
enum WatchPresence {
    /// これより新しい便りがあれば、入っているとみなす
    static let recent: TimeInterval = 2 * 86400

    /// 入っているとみなすか（flag は WCSession の isWatchAppInstalled）
    static func installed(flag: Bool, lastHeard: Date?, now: Date = .now) -> Bool {
        if flag { return true }
        guard let lastHeard else { return false }
        return now.timeIntervalSince(lastHeard) < recent
    }

    /// 時計からの最後の便り（様子の知らせ。PCDiag.swift が覚えている時刻）
    static var lastHeard: Date? { PCDiag.watchSeenAt }

    /// 入っているとみなすか（そのときの WCSession の値と、最後の便りから）
    static func installed(_ session: WCSession, now: Date = .now) -> Bool {
        installed(flag: session.isWatchAppInstalled, lastHeard: lastHeard, now: now)
    }

    /// 画面に出す一文（決め方だけ。テストしやすいよう WCSession から分けてある）
    static func text(supported: Bool, activated: Bool, paired: Bool, installedFlag: Bool, reachable: Bool,
                     lastHeard: Date?, now: Date = .now) -> String {
        guard supported else { return "この iPhone では使えません" }
        guard activated else { return "接続を準備中" }
        let heard = installed(flag: false, lastHeard: lastHeard, now: now)
        // ペアリングしていない・入っていないと言われても、最近便りがあれば入っている
        guard paired || heard else { return "Apple Watch がペアリングされていません" }
        guard installedFlag || heard else { return "時計に LifeLog が入っていません" }
        if reachable { return "時計のアプリとつながっています" }
        if !installedFlag, let lastHeard {
            return "時計に LifeLog が入っています（最後の便り \(clock(lastHeard, now: now))）"
        }
        return "時計に LifeLog が入っています"
    }

    /// そのときの WCSession の値から作る一文
    static func text(now: Date = .now) -> String {
        guard WCSession.isSupported() else { return text(supported: false, activated: false, paired: false,
                                                         installedFlag: false, reachable: false, lastHeard: nil, now: now) }
        let session = WCSession.default
        return text(supported: true, activated: session.activationState == .activated, paired: session.isPaired,
                    installedFlag: session.isWatchAppInstalled, reachable: session.isReachable,
                    lastHeard: lastHeard, now: now)
    }

    /// 「11:16」（今日でなければ「11/6 11:16」）
    static func clock(_ date: Date, now: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }
}

extension Pipeline {
    /// 画面と自己点検に出す、時計との接続の一文（出すたびに作る。2026-11-07）
    var watchStatusNow: String {
        // つながりが変わったら画面を出し直すよう、前の一文も読んでおく（Observation）
        let last = watchStatus
        guard WCSession.isSupported() else { return last }
        return WatchPresence.text()
    }

    /// 時計の区切りの長さの一文（自己点検）。電池が少ないので自動で5分にしているかは、届いた時計の様子（電池・充電中・低電力モード）を
    /// 古い順にたどって、時計と同じ決め方で決める（時計は様子と一緒には知らせてこないので、iPhone の見立て）
    var watchChunkLengthText: String {
        let since = Date.now.addingTimeInterval(-24 * 3600)
        let states = ledger.states.filter { $0.at >= since }.sorted { $0.at < $1.at }
        return Self.watchChunkLengthText(length: ChunkCutter.length, saverOn: ChunkCutter.batterySaverOn, states: states)
    }

    nonisolated static func watchChunkLengthText(length: ChunkCutter.Length, saverOn: Bool,
                                                 states: [RecordingLedger.State]) -> String {
        guard length == .short else { return length.label }
        guard saverOn else { return length.label }
        let saving = ChunkCutter.replaySaving(states.map { (battery: $0.battery, charging: $0.charging, lowPower: $0.lowPower) }, on: true)
        guard saving, let last = states.last else { return length.label + "・電池が少ないときは5分に" }
        var why: [String] = []
        if let battery = last.battery { why.append("電池 \(Int((battery * 100).rounded()))%") }
        if last.lowPower == true { why.append("低電力モード") }
        return "電池が少ないので、自動で5分にしています" + (why.isEmpty ? "" : "（" + why.joined(separator: "・") + "）")
    }
}

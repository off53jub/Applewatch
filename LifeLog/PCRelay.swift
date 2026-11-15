import AVFoundation
import Foundation

/// 時計の区切りの音声を、時計からではなく家の PC から受け取る（2026-11-15。強化案 64）。
///
/// 前は、時計が同じ区切りを2回送っていた（家の PC へ直接と、iPhone へ WatchConnectivity で）。iPhone への受け渡しは
/// Apple に絞られ、2026-11-15 の自己点検では「届くまで ふつう 511 分」「時計の返事待ち 1327 個」だった。文字のほうは
/// PC から先に記録に入れている（PCFirst.swift）が、音声は何時間も遅れ、そのあいだ時計は送り直しを続け、
/// 職場など「音声を待つ」時間の記録は音声が届くまで入らなかった。
///
/// - 家の PC が "jobaudio" を持っていれば、PC の一覧にある時計の区切り（でき上がったもの）と、PC から先に記録に入れた区切りの
///   音声を GET /jobs/<名前>/audio で受け取り、時計から届いたときと同じ流れに入れる（PhoneReceiver の onArrival）。
/// - 受け取ったら、時計に「受け取った」（gotPC）と知らせる。時計はその区切りを iPhone に送らずに消す
///   （時計の側の決まりは Shared/Audio/WatchDelivery.swift の「音声は家の PC から iPhone へ」）。
/// - 初めは Wi-Fi のときだけ受け取る（モバイル通信でも受け取るかは設定）。受け取れないつながり方のあいだは、
///   時計に「受け取れない」と知らせ、時計は今までどおりすぐ iPhone に送る。
/// - 受け取れなかった区切りは15分は試さない。時計は20分待っても返事が無ければ iPhone に送るので、何も失わない。
enum PCRelay {
    /// 家の PC の /hello の features にあれば使う
    static let feature = "jobaudio"
    /// 最後に聞いた答え（裏で起こされたときは PC に聞けないので覚えておく）
    static let featureKey = "homePCJobAudio"
    static var supported: Bool { UserDefaults.standard.bool(forKey: featureKey) }

    /// 1回に受け取る数（裏で起こされたときの短い時間でも終わるように）
    static let perPass = 8
    /// 受け取れなかった区切りは、これだけは試さない
    static let retryAfter: TimeInterval = 15 * 60

    /// 数える名前（Tally）
    static let gotKey = "relay.got"
    static let failedKey = "relay.failed"
    static let brokenKey = "relay.broken"

    /// いま、時計の音声を家の PC から受け取れるか（時計に知らせる）。
    /// on は設定、supported は PC が "jobaudio" を持つか、pcReady は家の PC を使えるか、
    /// onWiFi・online はいまのつながり方、cellular は「モバイル通信でも受け取る」
    static func usable(on: Bool, supported: Bool, pcReady: Bool, onWiFi: Bool, online: Bool, cellular: Bool) -> Bool {
        guard on, supported, pcReady else { return false }
        return onWiFi || (cellular && online)
    }

    /// 受け取る区切りを選ぶ（新しい順に limit 個まで。いまの会話に近いものを先に）。
    /// names は候補（PC の一覧のでき上がった時計の区切りと、PC から先に記録に入れた区切り）。
    /// have はもう音声を受け取ったか。failed は受け取れなかった時刻。2日より古いもの・時計の区切りでない名前は選ばない
    static func pick(_ names: [String], have: (String) -> Bool, failed: [String: Date], now: Date,
                     limit: Int = PCRelay.perPass) -> [String] {
        var seen = Set<String>()
        var chosen: [(name: String, start: Date)] = []
        for name in names {
            // もう受け取ったものが大半なので、先にそれを外す（名前から時刻を読むのは、残ったものだけ）
            guard seen.insert(name).inserted, !have(name), let start = PCFirst.startDate(name),
                  now.timeIntervalSince(start) <= PCFirst.maxAge, start <= now.addingTimeInterval(300) else { continue }
            if let tried = failed[name], now.timeIntervalSince(tried) < retryAfter { continue }
            chosen.append((name: name, start: start))
        }
        chosen.sort { $0.start > $1.start }
        return chosen.prefix(max(0, limit)).map { $0.name }
    }
}

/// この起動のあいだだけ覚えておくこと
@MainActor
final class PCRelayState {
    static let shared = PCRelayState()
    /// 受け取れなかった区切りと、その時刻
    var failed: [String: Date] = [:]
}

extension Pipeline {
    /// いま、時計の音声を家の PC から受け取れるか（設定・PC の対応・つながり方）
    func relayUsableNow() -> Bool {
        PCRelay.usable(on: homePC.watchRelay, supported: PCRelay.supported,
                       pcReady: homePC.isConfigured && homePC.watchDirect && HomePC.acceptsJobs,
                       onWiFi: archive.isOnWiFi, online: archive.isOnline, cellular: homePC.relayCellular)
    }

    /// つながり方や設定が変わって「受け取れる・受け取れない」が変わったら、10分を待たずに時計に知らせ直す
    func refreshWatchRelay() {
        guard homePC.isConfigured, homePC.watchDirect else { return }
        let now = relayUsableNow()
        if WatchDirectState.shared.sentRelay != now { refreshWatchPCHints(force: true) }
    }

    /// 時計の区切りの音声を家の PC から受け取る（pullPCFirst の終わりに呼ぶ。jobs は PC の一覧）。
    /// 受け取った音声は、時計から届いたときと同じ流れに入る（同じ取り込みの回で文字にする・話者を付ける）。
    /// 1回に受け取る数いっぱいまで選んだ（まだ残っていそう）なら true
    func pullRelayAudio(_ jobs: [PCFirst.Job]) async -> Bool {
        refreshWatchRelay()
        guard relayUsableNow() else { return false }
        let state = PCRelayState.shared
        let now = Date.now
        state.failed = state.failed.filter { now.timeIntervalSince($0.value) < PCRelay.retryAfter }
        // 候補: PC の一覧のでき上がった時計の区切りと、PC から先に記録に入れた区切り（PC の仕事はもう消してあるが、PC は音声を残している）
        let listed = jobs.filter { $0.status == "done" && ($0.origin == nil || $0.origin == "watch") }.map(\.id)
        let first = ledger.chunks.filter { $0.pcFirst == true && now.timeIntervalSince($0.start) <= PCFirst.maxAge }.map(\.name)
        // もう受け取った名前は、覚えと手元のファイルを1回だけ読んで見る（候補は千を超えることがある）
        let received = Storage.receivedNames()
        let onDisk = Set((Storage.pendingChunks() + Storage.keptAudio()).map { $0.lastPathComponent })
        let names = PCRelay.pick(listed + first, have: { received.contains($0) || onDisk.contains($0) },
                                 failed: state.failed, now: now)
        for name in names {
            if Task.isCancelled { break }
            guard let data = await homePC.jobAudio(name, cellular: homePC.relayCellular) else {
                state.failed[name] = .now
                Tally.add(PCRelay.failedKey)
                // つながらない・受け取れないつながり方なら、残りも同じなのでやめる
                if !homePC.shouldTry || !relayUsableNow() { break }
                continue
            }
            // 受け取っているあいだに時計から届いていたら、そちらに任せる（二重にしない）
            if Storage.alreadyReceived(name) {
                receiver.acknowledgeViaPC(name)
                continue
            }
            if acceptRelayAudio(name, data: data) {
                Tally.add(PCRelay.gotKey)
            } else {
                state.failed[name] = .now
                Tally.add(PCRelay.brokenKey)
            }
        }
        return names.count >= PCRelay.perPass
    }

    /// 家の PC から受け取った音声を、時計から届いたときと同じ流れに入れる。開けない音声は入れない（時計からの受け渡しに任せる）
    private func acceptRelayAudio(_ name: String, data: Data) -> Bool {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("relay-" + name)
        try? fm.removeItem(at: temp)
        guard (try? data.write(to: temp, options: .atomic)) != nil else { return false }
        guard let audio = try? AVAudioFile(forReading: temp), audio.length > 0 else {
            try? fm.removeItem(at: temp)
            return false
        }
        let dest = Storage.pendingDir.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        guard (try? fm.moveItem(at: temp, to: dest)) != nil else {
            try? fm.removeItem(at: temp)
            return false
        }
        Storage.noteReceived(name)
        // 時計に「受け取った」と知らせる（時計は、この区切りを iPhone に送らずに消す）
        receiver.acknowledgeViaPC(name)
        // 時計から届いたときと同じ流れ（帳簿・遅れの記録・PC から先に入れた区切りなら音声を残して話者を付ける）。
        // 時計が付ける控えは無いので、区切った時刻・送り始めた時刻は空（届くまでの遅れは、録音の終わりから数える）
        receiver.onArrival?(dest, .now, WatchDelivery.Stamp(cut: nil, sent: nil, lowPower: nil, viaPC: true))
        return true
    }

    /// 自己点検の行: 今日、家の PC から受け取った音声の数と、時計が待っている数（設定がオフ・PC が未対応ならそのことを書く）
    var relayDiag: (value: String, ok: Bool?)? {
        guard homePC.isConfigured, homePC.watchDirect else { return nil }
        guard homePC.watchRelay else { return ("使わない（時計の音声を家の PC から受け取るがオフ）", nil) }
        guard PCRelay.supported else { return ("家の PC がまだ対応していません（LifeLog PC を新しくすると使えます）", nil) }
        let today = Tally.sums(days: 1)
        var text = "今日 \(today[PCRelay.gotKey] ?? 0) 個"
        let failed = (today[PCRelay.failedKey] ?? 0) + (today[PCRelay.brokenKey] ?? 0)
        if failed > 0 { text += "・受け取れなかった \(failed) 回" }
        if !relayUsableNow() {
            text += "・いまは受け取らない（" + (homePC.relayCellular ? "ネットにつながっていない" : "Wi-Fi でない") + "）"
        }
        let detail = UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:]
        if let held = detail["watchRelayHeld"] as? Int { text += "・時計が待っている \(held) 個" }
        if let done = detail["watchRelayDone"] as? Int { text += "・時計が送らずに済んだ \(done) 個（直近24時間）" }
        return (text, nil)
    }
}

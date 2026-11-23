import Foundation

/// s23（2026-11-23）「録音が止まらない」の決まり（時計と iPhone の両方で使う。決まった入力から決まった出力だけ）。
/// 番号は母艦の追記 12（docs/system-proposal-2026-11-13.md）の 止1〜止16 と 届5。しきい値はどれも仮。
/// テストは LifeLogTests/S23RecTests.swift（中断の知らせを偽って流す。届5）。
enum S23Rec {
    // MARK: - 設定の名前（iPhone の設定。時計の分は applicationContext で渡す）

    /// 止6: 中断のあいだ 5 秒ごとに「ほかの音がまだ鳴っているか」を見て、止んだらすぐ戻す。
    /// 初めはオン（効くかは仮説。だめでも知らせず、今までの 1 分の戻しがそのまま残るので、悪くはならない見込み）
    static let probeKey = "s23.rec.probe"
    /// 止4: 電話が終わったらすぐ戻す・電話のあいだは「電話中」の印（iPhone だけが電話を見られる）。
    /// 初めはオン（効くかは仮説。1 回早めに試すだけで、だめなら今までの試し直しに戻る）
    static let callKey = "s23.rec.call"
    /// 止9: 時計が戻れないあいだだけ iPhone が自動で録る（初めはオフ。二重に録る・電池を使う）
    static let coverByPhoneKey = "s23.rec.coverByPhone"
    /// 止10: iPhone が戻れないとき、時計に「録って」と頼む（初めはオフ。時計が裏で録り始められるかは仮説）
    static let coverByWatchKey = "s23.rec.coverByWatch"
    /// 止11: 毎日同じ時刻に切れるなら、その 1 分後に動いているかを自分で見る（初めはオン。止まっていたら 1 回戻すだけ）
    static let dailyCheckKey = "s23.rec.dailyCheck"
    /// 止13: 1 分より長く止まって戻ったときだけ「◯分止まっていました。いまは録れています」（初めはオン。1 日 3 回まで）
    static let resumedNoticeKey = "s23.rec.resumedNotice"
    /// 止14: iPhone が熱いときは、重い仕事（端末内の文字起こし）を先に休ませる（初めはオン。夜の聞き直しで取り戻す）
    static let hotKey = "s23.rec.hot"
    /// 止16: 版 386（#100）の作り直しを前の動きに戻す（初めはオフ＝今の動き。悪さをしたときの逃げ道）
    static let legacyKey = "s23.rec.legacy"

    /// 初めの値
    static let defaultsTable: [String: Bool] = [
        probeKey: true, callKey: true, coverByPhoneKey: false, coverByWatchKey: false,
        dailyCheckKey: true, resumedNoticeKey: true, hotKey: true, legacyKey: false,
    ]

    static func isOn(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? (defaultsTable[key] ?? false)
    }

    /// 時計にも渡す設定
    static let watchKeys: [String] = [probeKey, dailyCheckKey, resumedNoticeKey, legacyKey]

    static func addSettings(to context: inout [String: Any], defaults: UserDefaults = .standard) {
        for key in watchKeys { context[key] = isOn(key, defaults: defaults) }
    }

    static func readSettings(_ context: [String: Any], defaults: UserDefaults = .standard) {
        for key in watchKeys { if let on = context[key] as? Bool { defaults.set(on, forKey: key) } }
    }

    // MARK: - iPhone ↔ 時計の名前（どれも省ける）

    /// iPhone → 時計（transferUserInfo）: true で「録って」、false で「もう録らなくてよい」（止10）
    static let coverKey = "s23.cover"
    /// iPhone → 時計: 中断の練習（止15）
    static let drillKey = "s23.drill"
    /// iPhone → 時計: iPhone の電話が終わった（止4。時計も中断していればすぐ戻す）
    static let callEndedKey = "s23.callEnded"
    /// 時計 → iPhone（deliveryState）: 中断から戻るまでの数・止まっていたあいだ・練習の結果（止1・止12・止15）
    static let stateKey = "s23rec"

    /// 時計の知らせ（止まりました・止まっているかも）の「録音を戻す」（止7。押すと開いてすぐ戻す）
    static let watchResumeCategory = "s23.resume.watch"
    /// iPhone の「iPhone の録音が止まっています」の「録音を戻す」（止8）
    static let phoneResumeCategory = "s23.resume.phone"
    static let resumeAction = "s23.resume.now"
    static let resumeTitle = "録音を戻す"

    // MARK: - 止5 中断の理由

    /// OS が教える分（AVAudioSessionInterruptionReasonKey の値）と、電話中か・始まった時刻から、理由の符号を決める。
    /// アラームかは OS が教えないので、ちょうど分の変わり目（0〜2 秒）に始まったら「アラーム？」と見立てる（仮）
    static func reasonCode(raw: UInt?, inCall: Bool, began: Date, calendar: Calendar = .current) -> String {
        if inCall { return "call" }
        switch raw {
        case 1: return "suspended"
        case 2: return "micMuted"
        case 4: return "route"
        default: break
        }
        if calendar.component(.second, from: began) <= 2 { return "alarm?" }
        return "interrupt"
    }

    static func reasonLabel(_ code: String) -> String {
        switch code {
        case "call": "電話"
        case "suspended": "アプリが止められていた"
        case "micMuted": "マイクを切られた"
        case "route": "つなぎ先が外れた"
        case "alarm?": "アラーム？（見立て）"
        case "drill": "中断の練習"
        case "interrupt": "中断"
        default: "不明"
        }
    }

    // MARK: - 止1 中断から戻るまで

    /// 1 回の中断（戻った時刻が無ければ、まだ戻っていない）
    struct Stop: Equatable, Sendable {
        var start: Double
        var end: Double?
        /// 試してだめだった回数
        var attempts: Int = 0
        /// 戻った道（ended・timer・retry・probe・call・open・button・daily・drill・stall）
        var way: String?
        var reason: String = "interrupt"

        var seconds: Double? { end.map { max(0, $0 - start) } }

        var dict: [String: Any] {
            var out: [String: Any] = ["s": start, "a": attempts, "r": reason]
            if let end { out["e"] = end }
            if let way { out["w"] = way }
            return out
        }

        init(start: Double, end: Double? = nil, attempts: Int = 0, way: String? = nil, reason: String = "interrupt") {
            self.start = start
            self.end = end
            self.attempts = attempts
            self.way = way
            self.reason = reason
        }

        init?(dict: [String: Any]) {
            guard let start = (dict["s"] as? Double) ?? (dict["s"] as? NSNumber)?.doubleValue else { return nil }
            self.start = start
            end = (dict["e"] as? Double) ?? (dict["e"] as? NSNumber)?.doubleValue
            attempts = dict["a"] as? Int ?? 0
            way = dict["w"] as? String
            reason = dict["r"] as? String ?? "interrupt"
        }
    }

    /// 残す長さと数
    static let keepDays: Double = 14
    static let keepLimit = 400

    /// 新しい中断を足す（古いものは捨てる）
    static func adding(_ list: [Stop], _ stop: Stop, now: Date) -> [Stop] {
        let oldest = now.timeIntervalSince1970 - keepDays * 86400
        var out = (list + [stop]).filter { $0.start >= oldest }.sorted { $0.start < $1.start }
        if out.count > keepLimit { out.removeFirst(out.count - keepLimit) }
        return out
    }

    /// いちばん新しい、まだ戻っていない中断を閉じる（無ければそのまま）
    static func closing(_ list: [Stop], end: Date, way: String) -> [Stop] {
        guard let index = list.lastIndex(where: { $0.end == nil }) else { return list }
        var out = list
        out[index].end = end.timeIntervalSince1970
        out[index].way = way
        return out
    }

    /// いちばん新しい、まだ戻っていない中断に「だめだった」を 1 つ足す
    static func failing(_ list: [Stop]) -> [Stop] {
        guard let index = list.lastIndex(where: { $0.end == nil }) else { return list }
        var out = list
        out[index].attempts += 1
        return out
    }

    /// 戻るまでの秒の段（数える名前に使う）
    static func bucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<15: "lt15"
        case ..<60: "lt60"
        case ..<300: "lt300"
        default: "ge300"
        }
    }

    /// その日の数（家の PC への様子に載せる形。練習は数えない）。
    /// n=中断の数・ok=戻った数・open=まだ戻っていない数・tries=だめだった回数の合計・med/max=戻るまでの秒・way=戻った道ごとの数
    static func summary(_ list: [Stop], day: String, calendar: Calendar = .current) -> [String: Any] {
        let today = list.filter {
            $0.reason != "drill" && HolidayRules.dayKey(Date(timeIntervalSince1970: $0.start), calendar: calendar) == day
        }
        var out: [String: Any] = ["n": today.count]
        // 止めるボタンで止めた中断（way が stopped）は「戻った」に数えない
        let done = today.filter { $0.way != "stopped" }.compactMap(\.seconds).sorted()
        out["ok"] = done.count
        out["open"] = today.filter { $0.end == nil }.count
        out["tries"] = today.reduce(0) { $0 + $1.attempts }
        if !done.isEmpty {
            out["med"] = Int(done[done.count / 2].rounded())
            out["max"] = Int((done.last ?? 0).rounded())
        }
        var ways: [String: Int] = [:]
        for stop in today { if let way = stop.way { ways[way, default: 0] += 1 } }
        if !ways.isEmpty { out["way"] = ways }
        var reasons: [String: Int] = [:]
        for stop in today { reasons[stop.reason, default: 0] += 1 }
        if !reasons.isEmpty { out["why"] = reasons }
        return out
    }

    // MARK: - 届5 戻すかの判断（iPhone の Recorder が使う。本物の AVAudioSession はテストで鳴らせないので、判断だけをここに置く）

    /// 中断の始まりから戻るまでの判断。入力（始まった・終わった・1 分たった・音が止んだ・電話が終わった・開いた・だめだった・戻った）を
    /// 受けて、Recorder がすること（待つ・今すぐ試す・試し直す・止める・戻った）を返す
    struct ResumeFlow: Equatable, Sendable {
        enum Input: Equatable, Sendable {
            case began
            case ended
            /// 予約した時刻になった（初めの 1 分・試し直し）
            case timer
            /// 5 秒ごとの見回り（止6）。otherAudio はほかの音がまだ鳴っているか
            case probe(otherAudio: Bool)
            /// 電話が終わった（止4）
            case callEnded
            /// 開いた・「録音を戻す」・毎日の見回り・練習（way はその名前）
            case now(String)
            case failed
            case resumed
        }

        enum Output: Equatable, Sendable {
            case nothing
            /// 録音を止めて待つ（timer 秒後に自分で戻す。probe が nil でなければ、その秒ごとに見回る）
            case pause(timer: TimeInterval?, probe: TimeInterval?)
            /// 今すぐ戻してみる（quiet なら、だめでも知らせず、予約も変えない）
            case tryNow(way: String, quiet: Bool)
            /// だめだった。after 秒後に試し直す（notify なら「止まっています」を出す）
            case retry(after: TimeInterval, notify: Bool)
            /// 前の動き（止16）: だめなら録音を止める
            case giveUp
            /// 戻った（止まっていた秒）
            case done(way: String, seconds: TimeInterval)
        }

        /// 止16（前の動き: 1 分の戻し・見回り・開いたときの戻しをしない。終わったときに 1 回だけ試し、だめなら止める）
        var legacy = false
        /// 止6
        var probeOn = true
        private(set) var waiting = false
        private(set) var since: Date?
        /// だめだった回数（開いた・押したときは 0 から数え直す）
        private(set) var attempt = 0
        private(set) var lastWay: String?
        private(set) var lastQuiet = false

        /// 「終わった」が来なくても、これだけたったら自分で戻す
        static let firstWait: TimeInterval = 60
        /// 見回りの間（止6）
        static let probeEvery: TimeInterval = 5
        /// 試し直すまでの間（最後の値をくり返す。仮。2026-11-23）
        static let waits: [TimeInterval] = [15, 30, 60, 120, 300]

        static func wait(_ attempt: Int) -> TimeInterval {
            waits[min(max(attempt, 0), waits.count - 1)]
        }

        init(legacy: Bool = false, probeOn: Bool = true) {
            self.legacy = legacy
            self.probeOn = probeOn
        }

        private mutating func attemptNow(_ way: String, quiet: Bool) -> Output {
            lastWay = way
            lastQuiet = quiet
            return .tryNow(way: way, quiet: quiet)
        }

        mutating func step(_ input: Input, now: Date) -> Output {
            switch input {
            case .began:
                // 2 回目の「始まった」は、始まりの時刻を変えない
                if !waiting {
                    since = now
                    attempt = 0
                }
                waiting = true
                return legacy ? .pause(timer: nil, probe: nil)
                    : .pause(timer: Self.firstWait, probe: probeOn ? Self.probeEvery : nil)
            case .ended:
                guard waiting else { return .nothing }
                return attemptNow("ended", quiet: false)
            case .timer:
                guard waiting, !legacy else { return .nothing }
                return attemptNow(attempt == 0 ? "timer" : "retry", quiet: false)
            case .probe(let otherAudio):
                guard waiting, !legacy, probeOn, !otherAudio,
                      let since, now.timeIntervalSince(since) >= Self.probeEvery else { return .nothing }
                return attemptNow("probe", quiet: true)
            case .callEnded:
                guard waiting, !legacy else { return .nothing }
                return attemptNow("call", quiet: true)
            case .now(let way):
                guard waiting, !legacy else { return .nothing }
                attempt = 0
                return attemptNow(way, quiet: false)
            case .failed:
                guard waiting else { return .nothing }
                if legacy {
                    waiting = false
                    since = nil
                    return .giveUp
                }
                if lastQuiet { return .nothing }
                attempt += 1
                return .retry(after: Self.wait(attempt - 1), notify: attempt == 1)
            case .resumed:
                guard waiting else { return .nothing }
                let seconds = since.map { now.timeIntervalSince($0) } ?? 0
                waiting = false
                since = nil
                attempt = 0
                return .done(way: lastWay ?? "ended", seconds: max(0, seconds))
            }
        }
    }

    // MARK: - 止6 時計の見回り（時計は今までの流し直しの係を使い、いつ呼ぶかだけをここで決める）

    /// 時計で、いま流し直してよいか（始まりから 5 秒以上・ほかの音が止んだ・見回りがオン・前の動きでない）
    static func watchKick(elapsed: TimeInterval, otherAudio: Bool, probeOn: Bool, legacy: Bool) -> Bool {
        !legacy && probeOn && !otherAudio && elapsed >= ResumeFlow.probeEvery
    }

    // MARK: - 止3 つないだ・外した

    /// 音の行き先が変わった理由（AVAudioSession.RouteChangeReason の値）のうち、流し直しを確かめるもの（つないだ 1・外した 2）
    static func routeShouldAct(_ raw: UInt?) -> Bool { raw == 1 || raw == 2 }

    // MARK: - 止11 毎日同じ時刻に切れる

    /// 直近 7 日のうち 3 日以上、同じ時刻（前後 5 分）に中断が始まっていたら、その時刻（0 時からの分）。
    /// 記録を始めて 7 日たつまでは空
    static func recurringSlots(_ starts: [Date], since: Date?, now: Date, calendar: Calendar = .current,
                               window: Int = 5, minDays: Int = 3) -> [Int] {
        guard let since, now.timeIntervalSince(since) >= 7 * 86400 else { return [] }
        let recent = starts.filter { now.timeIntervalSince($0) < 7 * 86400 && $0 <= now }
        let points: [(minute: Int, day: String)] = recent.map {
            (calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0), HolidayRules.dayKey($0, calendar: calendar))
        }.sorted { $0.minute < $1.minute }
        var slots: [Int] = []
        var used = Set<Int>()
        for (i, p) in points.enumerated() where !used.contains(i) {
            let near = points.indices.filter { !used.contains($0) && abs(points[$0].minute - p.minute) <= window }
            let days = Set(near.map { points[$0].day })
            guard days.count >= minDays else { continue }
            let minutes = near.map { points[$0].minute }.sorted()
            slots.append(minutes[minutes.count / 2])
            used.formUnion(near)
        }
        return slots.sorted()
    }

    /// 次に見回る時刻（その時刻の 1 分後。今日がもう過ぎていたら明日）
    static func nextCheck(_ slots: [Int], now: Date, calendar: Calendar = .current) -> Date? {
        let dayStart = calendar.startOfDay(for: now)
        let candidates = slots.flatMap { slot -> [Date] in
            let today = dayStart.addingTimeInterval(Double(slot + 1) * 60)
            return [today, today.addingTimeInterval(86400)]
        }
        return candidates.filter { $0 > now }.min()
    }

    // MARK: - 止13 戻ったあとの 1 回の知らせ

    /// 1 分より長く止まって戻ったときの文（短ければ nil）
    static func resumedText(_ seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        return "\(max(1, minutes))分止まっていました。いまは録れています"
    }

    /// 1 日に出す数の上限
    static let resumedNoticeLimit = 3

    // MARK: - 止14 熱いとき

    /// 重い仕事を休ませるか（ProcessInfo.ThermalState の値: 0 ふつう・1 少し・2 熱い・3 とても熱い）
    static func hotSaving(on: Bool, thermal: Int) -> Bool { on && thermal >= 2 }

    // MARK: - 止15 中断の練習

    /// これだけ待っても戻らなければ ×
    static let drillLimit: TimeInterval = 10

    static func drillText(ok: Bool, seconds: TimeInterval) -> String {
        ok ? "○ \(max(1, Int(seconds.rounded())))秒で戻りました" : "× \(Int(drillLimit))秒で戻りませんでした"
    }

    /// 時計の練習の結果（"1970 からの秒|1 か 0|秒"）を読む
    static func parseDrill(_ text: String?) -> (at: Date, ok: Bool, seconds: Double)? {
        guard let parts = text?.split(separator: "|"), parts.count == 3,
              let at = Double(parts[0]), let seconds = Double(parts[2]) else { return nil }
        return (Date(timeIntervalSince1970: at), parts[1] == "1", seconds)
    }

    // MARK: - 止12 今日の帯の切れ目

    struct Tick: Equatable, Sendable {
        let start: Date
        let end: Date
        /// "phone" か "watch"
        let device: String
        let reason: String
        var label: String { (device == "watch" ? "時計" : "iPhone") + "・" + reasonLabel(reason) }
    }

    /// その日の中にかかる中断（戻っていなければ now まで。練習と 5 秒未満は出さない）
    static func ticks(_ stops: [Stop], device: String, dayStart: Date, dayEnd: Date, now: Date) -> [Tick] {
        stops.compactMap { stop in
            guard stop.reason != "drill" else { return nil }
            let start = Date(timeIntervalSince1970: stop.start)
            let end = stop.end.map { Date(timeIntervalSince1970: $0) } ?? now
            guard end > dayStart, start < dayEnd, end.timeIntervalSince(start) >= 5 else { return nil }
            return Tick(start: max(start, dayStart), end: min(end, dayEnd), device: device, reason: stop.reason)
        }
    }
}

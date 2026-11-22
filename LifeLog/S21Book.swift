import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// s21（2026-11-22）の iPhone の帳（覚えておくもの・数えるもの。docs/s21-app.md）。決まりは S21Rules.swift。
enum S21Book {
    // MARK: - 電2 「PC に直接送る」と「iPhone 経由だけ」を 1 日ずつ（初めはオン・4 日）

    static var routeOn: Bool {
        get { UserDefaults.standard.object(forKey: S21Rules.routeOnKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: S21Rules.routeOnKey) }
    }

    static var routeStart: String? {
        get { UserDefaults.standard.string(forKey: S21Rules.routeStartKey) }
        set { UserDefaults.standard.set(newValue, forKey: S21Rules.routeStartKey) }
    }

    /// 1 日目を決める（まだなら、この版を初めて開いた次の日。録り方の実験と同じ作り）
    static func ensureRouteStart(now: Date = .now) {
        if routeStart == nil { routeStart = RecordingExperiment.firstDay(after: now) }
    }

    /// その日の組（実験の外は nil）
    static func routeToday(now: Date = .now) -> S21Rules.Route? {
        S21Rules.route(on: routeOn, start: routeStart, now: now)
    }

    /// 設定と自己点検の 1 行
    static func routeText(now: Date = .now) -> String {
        guard routeOn else { return "止めています（いつもどおり）" }
        guard let start = routeStart else { return "あしたから始まります" }
        if S21Rules.routeFinished(start: start, now: now) { return "終わりました（いつもどおり）" }
        if let route = routeToday(now: now) { return "きょう: " + route.label }
        return start + " から始まります"
    }

    // MARK: - 使3・使6 時計の 1 日の数と、止まりかけ・止められていたあいだ

    /// "日" → [止まりかけ, 自動で戻した, アプリが終わっていた]（時計は今日の数を送ってくるので、日ごとにいちばん大きい値を残す。14 日）
    private static let daysKey = "s21.watchDays"
    /// 止まりかけた時刻（1970 からの秒。14 日）
    private static let stallTimesKey = "s21.stallTimes"
    /// アプリが終わっていたあいだ（[[最後に動いていた秒, 起き直した秒]]。14 日）
    private static let exitWindowsKey = "s21.exitWindows"
    private static let keep: TimeInterval = 14 * 86400

    /// 時計から様子が届くたびに呼ぶ（変わったときだけ書く）
    static func noteWatch(_ state: PhoneReceiver.WatchState, now: Date = .now) {
        let defaults = UserDefaults.standard
        let day = HolidayRules.dayKey(state.at)
        var days = defaults.dictionary(forKey: daysKey) as? [String: [Int]] ?? [:]
        let old = days[day] ?? [0, 0, 0]
        let next = [max(old[safe: 0] ?? 0, state.stalls ?? 0), max(old[safe: 1] ?? 0, state.autoResumed ?? 0),
                    max(old[safe: 2] ?? 0, state.exits ?? 0)]
        if next != old {
            days[day] = next
            let oldest = HolidayRules.dayKey(now.addingTimeInterval(-keep))
            days = days.filter { $0.key >= oldest }
            defaults.set(days, forKey: daysKey)
        }
        let t = now.timeIntervalSince1970
        if let last = state.lastStall, let seconds = last.split(separator: "|").first.flatMap({ Double($0) }) {
            var times = defaults.array(forKey: stallTimesKey) as? [Double] ?? []
            if !times.contains(seconds) {
                times = (times + [seconds]).filter { t - $0 < keep }.sorted()
                defaults.set(times, forKey: stallTimesKey)
            }
        }
        if let exit = S21Watch.parseExit(state.lastExit) {
            var windows = defaults.array(forKey: exitWindowsKey) as? [[Double]] ?? []
            let pair = [exit.alive.timeIntervalSince1970, exit.relaunch.timeIntervalSince1970]
            if !windows.contains(pair) {
                windows = (windows + [pair]).filter { $0.count >= 2 && t - $0[1] < keep }
                defaults.set(windows, forKey: exitWindowsKey)
            }
        }
    }

    /// その日の時計の数（届いていなければ nil）
    static func dayCounts(_ day: String) -> (stalls: Int, autoResumed: Int, exits: Int)? {
        guard let row = (UserDefaults.standard.dictionary(forKey: daysKey) as? [String: [Int]])?[day], row.count >= 3 else { return nil }
        return (row[0], row[1], row[2])
    }

    static func stallTimes() -> [Date] {
        (UserDefaults.standard.array(forKey: stallTimesKey) as? [Double] ?? []).map { Date(timeIntervalSince1970: $0) }
    }

    static func exitWindows() -> [(alive: Date, relaunch: Date)] {
        (UserDefaults.standard.array(forKey: exitWindowsKey) as? [[Double]] ?? []).compactMap { pair in
            pair.count >= 2 ? (Date(timeIntervalSince1970: pair[0]), Date(timeIntervalSince1970: pair[1])) : nil
        }
    }

    // MARK: - 使7 自分の声の候補で「違う」にした声

    private static let rejectedSelfKey = "s21.notSelfVoices"

    static var rejectedSelf: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: rejectedSelfKey) ?? [])
    }

    static func rejectSelf(_ id: String) {
        var list = UserDefaults.standard.stringArray(forKey: rejectedSelfKey) ?? []
        if !list.contains(id) { list.append(id) }
        UserDefaults.standard.set(Array(list.suffix(200)), forKey: rejectedSelfKey)
    }

    // MARK: - 使9 同期の相手から外した端末

    static let excludedPeersKey = "s21.syncExcluded"

    static var excludedPeers: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: excludedPeersKey) ?? [])
    }

    static func setExcluded(_ device: String, _ on: Bool) {
        var set = excludedPeers
        if on { set.insert(device) } else { set.remove(device) }
        UserDefaults.standard.set(set.sorted(), forKey: excludedPeersKey)
    }

    // MARK: - 使10 振って知らせる（初めはオン）

    static let shakeKey = "s21.shake"
    static var shakeOn: Bool { UserDefaults.standard.object(forKey: shakeKey) as? Bool ?? true }

    // MARK: - 使11 Groq につながらなかった（しばらく高精度を試さない）

    nonisolated(unsafe) private static var cloudDownUntil = Date.distantPast
    private static let cloudLock = NSLock()

    static func noteCloudUnreachable(now: Date = .now) {
        cloudLock.withLock { cloudDownUntil = now.addingTimeInterval(S21Rules.cloudRestAfterUnreachable) }
        Tally.add("cloud.unreachable")
    }

    static func cloudResting(now: Date = .now) -> Bool {
        cloudLock.withLock { now < cloudDownUntil }
    }

    /// 時計に伝える設定が変わったら呼ぶ（LifeLogApp が「時計に設定を送り直す」を入れる）
    @MainActor static var settingsChanged: (@MainActor () -> Void)?

    // MARK: - 速2 受け取った名前の一覧を最後に時計に渡した時刻

    nonisolated(unsafe) static var gotListSentAt: Date?
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - 速5 書き込みの多い所を測る（この起動の今日の分だけ。ファイルには書かない＝測ることで書き込みを増やさない）

enum WriteMeter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var day = ""
    nonisolated(unsafe) private static var bytes: [String: Int] = [:]

    /// 書いた大きさを足す（どの糸からでもよい）
    static func note(_ name: String, _ count: Int, now: Date = .now) {
        guard count > 0 else { return }
        let today = HolidayRules.dayKey(now)
        lock.withLock {
            if day != today {
                day = today
                bytes = [:]
            }
            bytes[name, default: 0] += count
        }
    }

    /// 今日の KB（名前 → KB。多い 8 つ）
    static func today(limit: Int = 8) -> [String: Int] {
        let all = lock.withLock { bytes }
        let top = all.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, max(1, $0.value / 1024)) })
    }
}

// MARK: - 速6 長い処理に名前を付けて測る（この起動の今日の分。いちばん長かった秒）

enum SpanClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var day = ""
    nonisolated(unsafe) private static var longestSeconds: [String: Double] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func note(_ name: String, seconds: Double, now: Date = .now) {
        guard seconds >= 0 else { return }
        let today = HolidayRules.dayKey(now)
        lock.withLock {
            if day != today {
                day = today
                longestSeconds = [:]
                counts = [:]
            }
            longestSeconds[name] = max(longestSeconds[name] ?? 0, seconds)
            counts[name, default: 0] += 1
        }
    }

    /// 測りながら動かす
    static func time<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let start = Date.now
        defer { note(name, seconds: Date.now.timeIntervalSince(start)) }
        return try await work()
    }

    /// 今日いちばん長かった秒（名前 → 秒。長い 6 つ。小数 1 桁）
    static func longest(limit: Int = 6) -> [String: Double] {
        let all = lock.withLock { longestSeconds }
        let top = all.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, ($0.value * 10).rounded() / 10) })
    }

    /// 自己点検の 1 行「話者の聞き分け 42 秒・家の PC 31 秒」
    static func text(limit: Int = 4) -> String? {
        let top = longest(limit: limit).sorted { $0.value > $1.value }
        guard !top.isEmpty else { return nil }
        return top.map { "\(label($0.key)) \(Int($0.value.rounded())) 秒" }.joined(separator: "・")
    }

    static func label(_ name: String) -> String {
        switch name {
        case "speakers.label": "話者の聞き分け"
        case "pc.transcribe": "家の PC の文字起こし"
        case "haas.transcribe": "iPhone 内の Haas-ja"
        case "cloud.transcribe": "クラウドの文字起こし"
        case "llm.correct": "誤変換の直し"
        case "sync.run": "iPhone と iPad の同期"
        case "process.run": "処理 1 回（自分で動いていた分）"
        default: name
        }
    }
}

// MARK: - 使10 いまの画面（CountsOpen が入れる）と、振ったとき

enum ScreenTracker {
    nonisolated(unsafe) static var current = "今日"
}

extension Notification.Name {
    /// iPhone を振った（UIWindow から）
    static let llShake = Notification.Name("llShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake, S21Book.shakeOn {
            NotificationCenter.default.post(name: .llShake, object: nil)
        }
    }
}

// MARK: - iPhone の動き（Pipeline）

@MainActor
final class S21State {
    static let shared = S21State()
    /// 守4: 時計の便りが途切れたかを見る係
    var quietTask: Task<Void, Never>?
    /// 守4: 時計が途切れたので iPhone で録り始めた（時計が戻ったら止める）
    var startedForWatch = false
}

extension Pipeline {
    /// 時計から様子が届くたびに呼ぶ（守4・速2）
    func s21WatchState(_ state: PhoneReceiver.WatchState) {
        armWatchQuietGuard(state)
        sendGotListIfDue(kept: state.kept)
        s22WatchState(state)  // 溜まった分・こもりの数（2026-11-22。s22。S22Book.swift）
    }

    /// 守4: 時計の便りが 10 分途切れたら、設定が「録り始める」なら iPhone で録り始める（知らせは前からの見張りの通知が出す）。
    /// 時計がまた便りをくれたら、ここで始めた iPhone の録音は止める。アプリが止められているあいだは動けない（知らせだけになる。仮説）
    private func armWatchQuietGuard(_ state: PhoneReceiver.WatchState) {
        let s = S21State.shared
        s.quietTask?.cancel()
        if state.recording, s.startedForWatch {
            s.startedForWatch = false
            Tally.add("s21.watchQuiet.stopPhone")
            Task { await self.handle(.stopRecording) }
        }
        let wanted = state.wanted ?? state.recording
        guard wanted, stopAlertsOn else { return }
        let seen = state.at
        s.quietTask = Task { [weak self] in
            let wait = max(5, S21Rules.watchQuiet - Date.now.timeIntervalSince(seen))
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            let action = S21Rules.SilenceAction(rawValue: UserDefaults.standard.string(forKey: S21Rules.silenceActionKey) ?? "") ?? .notify
            Tally.add("s21.watchQuiet")
            guard S21Rules.shouldStartPhone(action: action, watchWanted: true, phoneRecording: self.isRecording,
                                            held: self.recordingHeld) else { return }
            await self.handle(.startRecording)
            if self.isRecording {
                S21State.shared.startedForWatch = true
                Tally.add("s21.watchQuiet.startPhone")
            }
        }
    }

    /// 速2: 時計の返事待ちが多ければ、iPhone が受け取った名前の一覧を時計に渡す（1 時間に 1 回まで）
    private func sendGotListIfDue(kept: Int?, now: Date = .now) {
        guard S21Rules.gotListDue(kept: kept, lastSent: S21Book.gotListSentAt, now: now) else { return }
        let received = Storage.receivedTimes()
        let names = S21Rules.gotListNames(received, now: now)
        S21Book.gotListSentAt = now
        if receiver.sendGotList(names) { Tally.add("s21.gotList", names.count) }
    }

    /// 使10: 振ったときの様子を家の PC に送る（ためて、つながったときに送る）
    func sendShake(screen: String, note: String?) -> Bool {
        guard let body = S21Rules.shakeBody(screen: screen, note: note, at: .now) else { return false }
        MothershipOutbox.enqueue(path: "feedback", body: body)
        Tally.add("s21.shake")
        let pc = homePC
        Task { await MothershipOutbox.send(pc) }
        return true
    }
}

// MARK: - 精5 誤変換直しの落ちる型

extension Pipeline {
    /// 出す前に弾く直しを元に戻す（弾いたわけを fix.pre.<型> に数える）。長さが合わない分はそのまま
    nonisolated static func preFilterFixes(original: [String], fixed: [String]) -> [String] {
        var out = fixed
        for i in out.indices where i < original.count {
            guard let reason = S21Rules.preReject(original: original[i], fixed: out[i]) else { continue }
            out[i] = original[i]
            Tally.add("fix.pre." + reason)
        }
        return out
    }

    /// 見比べで落ちた直しの型を fix.drop.<型> に数える（proposed は見比べの前、kept は見比べのあと）
    nonisolated static func tallyDroppedFixes(original: [String], proposed: [String], kept: [String]) {
        for i in original.indices where i < proposed.count && i < kept.count {
            let wanted = proposed[i]
            guard !wanted.isEmpty, wanted != original[i], kept[i] == original[i] || kept[i].isEmpty else { continue }
            Tally.add("fix.drop." + S21Rules.fixKind(original: original[i], fixed: wanted))
        }
    }
}

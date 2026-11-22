import Foundation
import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

/// s22（2026-11-22）の時計の分（決まりは Shared/Audio/S22Watch.swift。docs/s22-app.md）。
/// - 確4: 区切りの中の音の大きさの要約を、区切りの名前ごとに覚えて metadata と /w/jobs の query に添える
/// - 確24: その区切りの組（1 時間ごとの入れ替えの日だけ）を metadata に添える
/// - 確31: 袖でこもった音が続いたら 1 回震える（初めはオフ）
/// - 楽6: 溜まった分の「あと○個・約○分」と「いま送り直す」。「受け取った」が先に届いた名前を、アプリが終わっても覚える
/// - 楽13: 確かめ待ちに ○× で答える
/// - 楽19: 電池の先回り
enum S22WatchSide {
    private static let levelsKey = "s22.levels"
    private static let ackedKey = "s22.ackedEarly"
    private static let finishesKey = "s22.finishes"
    private static let highKey = "s22.highHistory"
    private static let buzzKey = "s22.muffledBuzz"
    private static let muffledCountKey = "s22.muffledCounts"
    private static let lock = NSLock()

    // MARK: 確4 音の大きさの要約

    /// 区切りを閉じたときに呼ぶ（書く糸から。2 日・600 個まで覚える）
    static func saveLevels(_ name: String, _ levels: S22Watch.Levels?) {
        guard let levels else { return }
        var entry: [String: Double] = levels.json
        if let high = levels.high { entry["high"] = S22Watch.round1(high * 100) / 100 }
        entry["t"] = Date.now.timeIntervalSince1970
        lock.withLock {
            let defaults = UserDefaults.standard
            var all = defaults.dictionary(forKey: levelsKey) as? [String: [String: Double]] ?? [:]
            all[name] = entry
            let now = Date.now.timeIntervalSince1970
            all = all.filter { now - ($0.value["t"] ?? 0) < 2 * 86400 }
            if all.count > 600 {
                for key in all.sorted(by: { ($0.value["t"] ?? 0) < ($1.value["t"] ?? 0) }).prefix(all.count - 600).map(\.key) {
                    all[key] = nil
                }
            }
            defaults.set(all, forKey: levelsKey)
        }
    }

    /// metadata に出す形（"p10","p50","p90","voicedP50"。覚えていなければ nil）
    static func levels(_ name: String) -> [String: Double]? {
        let all = lock.withLock { UserDefaults.standard.dictionary(forKey: levelsKey) as? [String: [String: Double]] ?? [:] }
        guard let entry = all[name] else { return nil }
        let out = entry.filter { ["p10", "p50", "p90", "voicedP50"].contains($0.key) }
        return out["p50"] == nil ? nil : out
    }

    private static func high(_ name: String) -> Double? {
        let all = lock.withLock { UserDefaults.standard.dictionary(forKey: levelsKey) as? [String: [String: Double]] ?? [:] }
        return all[name]?["high"]
    }

    /// その区切りの組（1 時間ごとの入れ替えの日だけ。名前の時刻で決める）
    static func recExp(_ name: String) -> String? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: S22Watch.hourlyOnKey),
              let start = WatchDelivery.startDate(name, zone: .current),
              let combo = S22Watch.hourlyCombo(on: true, start: defaults.string(forKey: S22Watch.hourlyStartKey),
                                                meeting: false, now: start) else { return nil }
        return S22Watch.label(combo)
    }

    /// transferFile の metadata に足す（無ければ足さない）
    static func withExtras(_ metadata: [String: Any], name: String) -> [String: Any] {
        var out = metadata
        if let levels = levels(name) { out[S22Watch.levelsKey] = levels }
        if let exp = recExp(name) { out[S22Watch.recExpKey] = exp }
        return out
    }

    /// 家の PC に直接送るときの query に足す
    static func queryExtras(_ name: String) -> [URLQueryItem] {
        S22Watch.queryItems(levels: levels(name), recExp: recExp(name))
    }

    // MARK: 楽6 「受け取った」が先に届いた名前

    static func rememberAcked(_ name: String) {
        lock.withLock {
            let saved = UserDefaults.standard.dictionary(forKey: ackedKey) as? [String: Double] ?? [:]
            UserDefaults.standard.set(S22Watch.addingAcked(saved, name: name, now: Date.now.timeIntervalSince1970), forKey: ackedKey)
        }
    }

    /// 覚えていたら消して true
    static func takeAcked(_ name: String) -> Bool {
        lock.withLock {
            var saved = UserDefaults.standard.dictionary(forKey: ackedKey) as? [String: Double] ?? [:]
            guard saved.removeValue(forKey: name) != nil else { return false }
            UserDefaults.standard.set(saved, forKey: ackedKey)
            return true
        }
    }

    // MARK: 楽6 あと何分か

    static func noteFinished(now: Date = .now) {
        lock.withLock {
            let t = now.timeIntervalSince1970
            let times = UserDefaults.standard.array(forKey: finishesKey) as? [Double] ?? []
            UserDefaults.standard.set(S22Watch.recentFinishes(times + [t], now: t), forKey: finishesKey)
        }
    }

    static func finishedRecent(now: Date = .now) -> Int {
        let times = lock.withLock { UserDefaults.standard.array(forKey: finishesKey) as? [Double] ?? [] }
        return S22Watch.recentFinishes(times, now: now.timeIntervalSince1970).count
    }

    /// 様子に足す名前（deliveryState）
    static func extraState(now: Date) -> [String: Any] {
        var out: [String: Any] = [S22Watch.finishedRecentKey: finishedRecent(now: now)]
        let counts = UserDefaults.standard.dictionary(forKey: muffledCountKey) as? [String: Int] ?? [:]
        if let n = counts[HolidayRules.dayKey(now)], n > 0 { out[S22Watch.muffledTodayKey] = n }
        return out
    }

    /// 「いま送り直す」: 止まった受け渡しを取り消し、返事待ちを片付けてから、残りを送り直す
    static func resendNow(_ sender: WatchSender) {
        sender.unstickTransfers()
        sender.tidyKept(force: true)
        sender.resendPending()
        sender.resendKept(minAge: 0)
        sender.heartbeat()
    }

    // MARK: 確31 袖でこもった音

    /// 区切りを送る（捨てる）たびに呼ぶ（ほぼ無音の区切りは数えない）
    @MainActor
    static func afterCut(_ name: String, peakDB: Float, now: Date) {
        guard peakDB >= -50, let ratio = high(name) else { return }
        let defaults = UserDefaults.standard
        var history = defaults.array(forKey: highKey) as? [Double] ?? []
        history = Array((history + [ratio]).suffix(30))
        defaults.set(history, forKey: highKey)
        let last = defaults.object(forKey: buzzKey) as? Double
        guard S22Watch.shouldBuzz(on: defaults.bool(forKey: S22Watch.muffledOnKey), history: history,
                                  lastBuzz: last.map { Date(timeIntervalSince1970: $0) }, now: now) else { return }
        defaults.set(now.timeIntervalSince1970, forKey: buzzKey)
        var counts = defaults.dictionary(forKey: muffledCountKey) as? [String: Int] ?? [:]
        let day = HolidayRules.dayKey(now)
        counts = counts.filter { $0.key >= HolidayRules.dayKey(now.addingTimeInterval(-7 * 86400)) }
        counts[day, default: 0] += 1
        defaults.set(counts, forKey: muffledCountKey)
        WKInterfaceDevice.current().play(.retry)
        let content = UNMutableNotificationContent()
        content.title = "音がこもっているかも"
        content.body = "袖や服で時計のマイクがふさがれているかもしれません（見立て・仮）。"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "s22-muffled", content: content, trigger: nil))
    }

    // MARK: 楽19 電池

    static func batteryLine(now: Date = .now) -> String? {
        let samples = UserDefaults.standard.array(forKey: WatchSender.batterySamplesKey) as? [[Double]] ?? []
        return S22Watch.emptyText(S22Watch.emptyAt(samples, now: now), now: now)
    }
}

// MARK: - 様子の画面に足す（楽6・楽13・楽19）

struct S22WatchStatusExtras: View {
    @Environment(WatchRecorder.self) private var recorder
    @State private var note: String?
    @State private var answered: String?

    var body: some View {
        let sender = recorder.s22Sender
        let waiting = recorder.unsent
        VStack(alignment: .leading, spacing: 6) {
            if let line = S22Watch.backlogText(count: waiting, finishedRecent: S22WatchSide.finishedRecent()) {
                Text("送る分: " + line).font(.caption2)
            }
            if let battery = S22WatchSide.batteryLine() {
                Text(battery).font(.caption2).foregroundStyle(LL.dim)
            }
            Button {
                S22WatchSide.resendNow(sender)
                LLHaptic.done.play()
                note = "送り直しを始めました"
                recorder.refreshStatus()
            } label: {
                Label("いま送り直す", systemImage: "arrow.clockwise").font(.caption2)
            }
            if let note { Text(note).font(.caption2).foregroundStyle(LL.dim) }
            if let ask = recorder.board.info?.reviewAsk, answered != ask.id {
                Divider()
                Text("確かめ待ち").font(.caption2).foregroundStyle(LL.dim)
                Text(ask.question).font(.caption)
                HStack {
                    Button {
                        answer(ask.id, "yes")
                    } label: {
                        Image(systemName: "circle")
                    }
                    .tint(LL.good)
                    .accessibilityLabel("はい")
                    Button {
                        answer(ask.id, "no")
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(LL.danger)
                    .accessibilityLabel("いいえ")
                }
            }
        }
    }

    private func answer(_ id: String, _ value: String) {
        recorder.s22Sender.s22ReviewAnswer(id: id, value: value)
        answered = id
        LLHaptic.done.play()
    }
}

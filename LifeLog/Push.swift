import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

// 家の PC から iPhone を起こす（APNs の見えない通知。docs/v7-plan.md の 3。2026-11-07）。
// - 起動したら通知の宛先（トークン）をもらい、家の PC への様子（/diag の push）で渡す。見えない通知は、通知の許可が無くても届く。
// - 届いたら25秒以内に終える: wake・job → 取り込み（PC の仕事の受け取りも）と、記録・直しのやり取りを短く。
//   nightly → 夜の処理がまだなら、iOS に今すぐ頼む。diag → 様子を送る。どれでも最後に様子を送る（起きたことが PC に分かる）。
// - 録音が止まった・時計の録音が届いていない、の知らせは「即時」（UrgentNotice）。

@MainActor
enum PushWake {
    /// 家の PC が送ってくる種類（中身の lifelog.kind）
    enum Kind: String, Sendable {
        /// 取り込み・送り出しを進めて
        case wake
        /// 文字起こしができた
        case job
        /// 夜の処理がまだなら進めて
        case nightly
        /// 様子を送って
        case diag
        /// 試しの通知（PC の画面のボタン）
        case test
    }

    /// 届いたときに動かす相手（LifeLogApp が起動時に入れる）
    static weak var pipeline: Pipeline?

    /// 届いてから iOS に「終わった」と言うまで（25秒より短く）
    static let budget: TimeInterval = 24

    private static let tokenKey = "pushToken"
    private static let tokenAtKey = "pushTokenAt"
    private static let errorKey = "pushError"
    private static let lastKey = "pushLastAt"

    // MARK: 登録

    /// 起動したときに呼ぶ（AppDelegate）。自動テストと見本の記録のときは頼まない
    static func register(_ application: UIApplication) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        #if DEBUG && targetEnvironment(simulator)
        if DemoData.isOn { return }
        #endif
        application.registerForRemoteNotifications()
    }

    /// 宛先をもらえた（AppDelegate）
    static func registered(_ token: Data) {
        let text = hex(token)
        let changed = UserDefaults.standard.string(forKey: tokenKey) != text
        UserDefaults.standard.set(text, forKey: tokenKey)
        UserDefaults.standard.set(Date.now, forKey: tokenAtKey)
        UserDefaults.standard.removeObject(forKey: errorKey)
        // 宛先が変わったら（初めてのときも）、すぐ家の PC に知らせる
        if changed, let target = Self.pipeline {
            Task { await target.sendPCDiag(reason: "token") }
        }
    }

    /// 宛先をもらえなかった（署名に通知の許可が無い入れ方など。AppDelegate）
    static func failed(_ error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: errorKey)
    }

    /// 宛先を16進の文字にする
    nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    static var isRegistered: Bool { !(UserDefaults.standard.string(forKey: tokenKey) ?? "").isEmpty }

    static var statusText: String {
        if isRegistered {
            var text = "登録済み（" + environment(profile: profile) + "）"
            if let at = UserDefaults.standard.object(forKey: lastKey) as? Date { text += "・最後に届いた " + PCDiag.clock(at) }
            return text
        }
        if let error = UserDefaults.standard.string(forKey: errorKey) { return "登録できませんでした: " + error }
        return "まだ登録していません"
    }

    // MARK: 届いたとき

    /// 中身（{"aps":{"content-available":1},"lifelog":{"kind":"wake"}}）から種類を読む
    nonisolated static func kind(from userInfo: [AnyHashable: Any]) -> Kind? {
        guard let info = userInfo["lifelog"] as? [String: Any], let raw = info["kind"] as? String else { return nil }
        return Kind(rawValue: raw)
    }

    /// 文字起こしができた知らせの、仕事の名前（{"lifelog":{"kind":"job","job":"<名前>"}}。無ければ nil）
    nonisolated static func job(from userInfo: [AnyHashable: Any]) -> String? {
        guard let info = userInfo["lifelog"] as? [String: Any], let name = info["job"] as? String, !name.isEmpty else { return nil }
        return name
    }

    /// 見えない通知が届いた（AppDelegate）。種類ごとに動いて、25秒以内に iOS に終わったと言う
    static func receive(_ userInfo: [AnyHashable: Any], completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let wake = Self.kind(from: userInfo) else {
            completion(.noData)
            return
        }
        Tally.add("push." + wake.rawValue)
        UserDefaults.standard.set(Date.now, forKey: lastKey)
        // 文字起こしができた知らせなら、次の取り込みで1分を待たずに PC から先に入れる区切りを見る（版 10。PCFirst.swift）
        if wake == .job { PCFirst.jobPushed(Self.job(from: userInfo)) }
        guard let target = Self.pipeline else {
            completion(.noData)
            return
        }
        let work = Task { await target.handlePush(wake) }
        Task {
            let finished = await Self.wait(work, upTo: budget)
            completion(finished ? .newData : .noData)
        }
    }

    /// task が終わるか、seconds たつまで待つ。終わったら true。待つのをやめても task は止めない
    nonisolated static func wait(_ task: Task<Void, Never>, upTo seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            Task {
                await task.value
                once.run { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.run { continuation.resume(returning: false) }
            }
        }
    }

    /// 夜の処理を、今すぐ（充電中・通信できるときに）iOS に頼む
    static func requestNightlyNow() {
        let request = BGProcessingTaskRequest(identifier: Pipeline.processingTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = nil
        if (try? BGTaskScheduler.shared.submit(request)) != nil { Tally.add("push.nightlyAsked") }
    }

    // MARK: 家の PC への様子に入れる宛先

    /// この IPA の署名のプロファイル（TestFlight・App Store で入れたときは無い）
    nonisolated static let profile: Data? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return try? Data(contentsOf: url)
    }()

    /// 宛先（登録できていなければ nil）。{"token","environment","topic","team"}
    static func pushInfo() -> [String: Any]? {
        guard let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty else { return nil }
        var info: [String: Any] = [:]
        info["token"] = token
        info["environment"] = environment(profile: profile)
        info["topic"] = Bundle.main.bundleIdentifier ?? "com.off53jub.lifelog"
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
        if let team = team(prefix: prefix, profile: profile) { info["team"] = team }
        return info
    }

    /// 入れ方（testflight＝TestFlight・App Store、sideload、other）
    static var install: String {
        #if targetEnvironment(simulator)
        return installKind(profile: profile, simulator: true)
        #else
        return installKind(profile: profile, simulator: false)
        #endif
    }

    nonisolated static func installKind(profile: Data?, simulator: Bool) -> String {
        if simulator { return "other" }
        return profile == nil ? "testflight" : "sideload"
    }

    /// プロファイル（署名つきの plist）の中身
    nonisolated static func profileDictionary(_ data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
    }

    /// 通知の宛先の種類。TestFlight・App Store（プロファイルが無い）なら production、
    /// それ以外は、プロファイルの許可（aps-environment）。書いていなければ development
    nonisolated static func environment(profile: Data?) -> String {
        guard let profile else { return "production" }
        let entitlements = profileDictionary(profile)?["Entitlements"] as? [String: Any]
        return entitlements?["aps-environment"] as? String ?? "development"
    }

    /// チームの ID。Info.plist の AppIdentifierPrefix（例 "ABCDE12345."。末尾の「.」を取る）。入っていなければプロファイルから
    nonisolated static func team(prefix: String?, profile: Data?) -> String? {
        if let prefix {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if !trimmed.isEmpty, !trimmed.contains("$"), !trimmed.contains("(") { return trimmed }
        }
        guard let profile, let dict = profileDictionary(profile) else { return nil }
        return (dict["TeamIdentifier"] as? [String])?.first ?? (dict["ApplicationIdentifierPrefix"] as? [String])?.first
    }
}

/// 1回だけ動かす（先に来たほうだけ）
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ action: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { action() }
    }
}

// MARK: - 即時の知らせ

/// 録音が止まった・時計の録音が届いていない、の知らせは「即時」にする（集中モードでも出る。2026-11-07）
enum UrgentNotice {
    /// Pipeline.notify・scheduleWatchAlert の知らせの名前
    static let ids: Set<String> = ["phone-stopped", "watch-silent"]

    static func level(for id: String) -> UNNotificationInterruptionLevel { ids.contains(id) ? .timeSensitive : .active }
}

// MARK: - 届いたときの動き

extension Pipeline {
    /// 見えない通知で起きたとき（PushWake.receive から。25秒より短く）。どの種類でも、最後に様子を送る
    func handlePush(_ kind: PushWake.Kind) async {
        let link = PCLinkState.shared
        link.pushActive = true
        defer { link.pushActive = false }
        let started = Date.now
        func left() -> TimeInterval { PushWake.budget - 3 - Date.now.timeIntervalSince(started) }
        switch kind {
        case .wake, .job:
            // 取り込み（PC の仕事の受け取りも）。10秒で終わらなければ、区切りの切れ目で止めて次の機会に回す
            let queue = Task { await runQueue() }
            let finished = await PushWake.wait(queue, upTo: 10)
            if !finished { queue.cancel() }
            // 記録と直しのやり取りを短く（10分に1回まで）
            if left() > 8, PCRecords.isDue(lastTried: link.recordsTried, now: .now, soon: link.recordsSoon) {
                await exchangePCRecords(until: Date.now.addingTimeInterval(left() - 6))
            }
        case .nightly:
            if PCDiag.nightlyPending(doneFor: PCDiag.nightlyDoneFor, now: .now) { PushWake.requestNightlyNow() }
        case .diag, .test:
            break
        }
        await sendPCDiag(reason: "push-" + kind.rawValue, timeout: max(3, min(8, left())))
    }
}

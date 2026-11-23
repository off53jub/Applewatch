import AVFoundation
import CallKit
import SwiftUI
import UIKit
import UserNotifications
import WatchConnectivity

// s23（2026-11-23）「録音が止まらない」の iPhone の分。決まりは Shared/Audio/S23Rec.swift（テストは LifeLogTests/S23RecTests.swift）。
// 番号は母艦の追記 12 の 止1〜止16。
// - 止1: 中断ごとに、始まり・戻った時刻・だめだった回数・戻った道・理由を残し、数を数えて家の PC への様子に載せる（phoneRec・watchRec）
// - 止4: 電話を見て、終わったらすぐ戻す（S23Calls）
// - 止8: 「iPhone の録音が止まっています」に「録音を戻す」
// - 止9・止10: 片方が戻れないあいだ、もう片方が肩代わり（どちらも初めはオフ）
// - 止11: 毎日同じ時刻に切れるなら、その 1 分後に見回る
// - 止12: 今日の帯に止まっていた所と理由（S23StopTicksLayer・S23StopsSection）
// - 止13: 1 分より長く止まって戻ったときだけ 1 回知らせる
// - 止14: 熱いときは重い仕事を休ませる（Power.isSaving）
// - 止15: 中断の練習
// - 止16: 前の動きに戻すスイッチ（Recorder・WatchRecorder が読む）

// MARK: - 止8 知らせのボタン

enum S23Resume {
    /// 録音を今すぐ戻す（Pipeline が入れる。引数は戻した道の名前）
    @MainActor static var resume: (@MainActor (String) -> Void)?
    /// 中断の練習（Pipeline が入れる。止15）
    @MainActor static var drill: (@MainActor () async -> (ok: Bool, seconds: TimeInterval))?

    static let stalledID = "phone-stopped"
    static let resumedID = "s23-resumed"

    static func categories() -> Set<UNNotificationCategory> {
        // 押すとアプリが開いてすぐ戻す（裏で戻せるかは分からないので、いちばん戻りやすい「開く」にする）
        let action = UNNotificationAction(identifier: S23Rec.resumeAction, title: S23Rec.resumeTitle, options: [.foreground])
        return [UNNotificationCategory(identifier: S23Rec.phoneResumeCategory, actions: [action], intentIdentifiers: [], options: [])]
    }

    /// TaskBook.swift の didReceive の頭から呼ぶ。この知らせなら扱って true（completion もここで呼ぶ）
    static func handle(_ response: UNNotificationResponse, completion: @escaping () -> Void) -> Bool {
        let request = response.notification.request
        guard request.content.categoryIdentifier == S23Rec.phoneResumeCategory else { return false }
        let id: String = request.identifier
        let button: Bool = response.actionIdentifier == S23Rec.resumeAction
        Task { @MainActor in
            S20Book.shared.noteOpened(id: id)
            Tally.add(button ? "s23.rec.phone.button" : "s23.rec.phone.tap")
            resume?(button ? "button" : "open")
            completion()
        }
        return true
    }

    /// 「iPhone の録音が止まっています」（前は Pipeline.notify。ボタンを付けるためにここで作る）
    @MainActor static func notifyPhoneStalled() {
        let content = UNMutableNotificationContent()
        content.title = "iPhone の録音が止まっています"
        content.body = "アラームや電話のあとで戻せていません。自動で試し直しています。押すか「録音を戻す」で、開いてすぐ戻します。"
        content.sound = .default
        content.interruptionLevel = UrgentNotice.level(for: stalledID)
        content.categoryIdentifier = S23Rec.phoneResumeCategory
        NoticeGate.add(UNNotificationRequest(identifier: stalledID, content: content, trigger: nil))
    }
}

// MARK: - 止4 電話

/// 電話が始まった・終わったを見る（CallKit。中身や相手は読まない。電話中かどうかだけ）
@MainActor
final class S23Calls: NSObject, CXCallObserverDelegate {
    static let shared = S23Calls()
    private let observer = CXCallObserver()
    private(set) var inCall = false
    /// 電話中かが変わった（Pipeline が入れる）
    var onChange: (@MainActor (Bool) -> Void)?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        observer.setDelegate(self, queue: .main)
        inCall = observer.calls.contains { !$0.hasEnded }
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        // queue に .main を渡しているので、画面の糸で呼ばれる
        MainActor.assumeIsolated { self.refresh() }
    }

    private func refresh() {
        let now: Bool = observer.calls.contains { !$0.hasEnded }
        guard now != inCall else { return }
        inCall = now
        Tally.add(now ? "s23.rec.call.start" : "s23.rec.call.end")
        onChange?(now)
        // 時計にも「電話が終わった」を渡す（時計も中断していればすぐ戻す）
        if !now, S23Rec.isOn(S23Rec.callKey) { S23PhoneBook.sendToWatch([S23Rec.callEndedKey: true]) }
    }
}

// MARK: - 止1・止9〜止15 数と見回り

enum S23PhoneBook {
    static let stopsKey = "s23.rec.phoneStops"
    static let watchStopsKey = "s23.rec.watchStops"
    static let watchStateKey = "s23.rec.watchState"
    /// 記録を始めた時刻（止11 は 7 日たってから）
    static let sinceKey = "s23.rec.since"
    /// 止13 の今日の数（"日|回数"）
    static let noticesKey = "s23.rec.notices"
    /// 止15 の iPhone の練習の結果（"1970 からの秒|1 か 0|秒"）
    static let drillKey = "s23.rec.phoneDrill"
    /// 止9: 時計が止まりかけと言ってから、iPhone で録り始めるまで待つ秒（すぐ戻ることが多いので。仮）
    static let coverGrace: TimeInterval = 60
    private static let lock = NSLock()

    static func load(_ key: String) -> [S23Rec.Stop] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap(S23Rec.Stop.init(dict:))
    }

    static func save(_ list: [S23Rec.Stop], _ key: String) {
        UserDefaults.standard.set(list.map(\.dict), forKey: key)
    }

    static func ensureSince(now: Date = .now) {
        if UserDefaults.standard.object(forKey: sinceKey) == nil {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: sinceKey)
        }
    }

    /// iPhone の中断が始まった（Recorder から）
    @MainActor static func began(reason: String, now: Date = .now) {
        ensureSince(now: now)
        save(S23Rec.adding(load(stopsKey), S23Rec.Stop(start: now.timeIntervalSince1970, reason: reason), now: now), stopsKey)
        if reason != "drill" {
            Tally.add("s23.rec.phone.began")
            Tally.add("s23.rec.phone.why." + reason)
        }
    }

    /// 試してだめだった（Recorder から）
    @MainActor static func failed() {
        save(S23Rec.failing(load(stopsKey)), stopsKey)
        Tally.add("s23.rec.phone.failed")
    }

    /// 初めてだめだった（止10: 設定がオンなら時計に「録って」と頼む）
    @MainActor static func firstFailure() {
        guard S23Rec.isOn(S23Rec.coverByWatchKey) else { return }
        if sendToWatch([S23Rec.coverKey: true]) {
            coverAsked = true
            Tally.add("s23.rec.cover.askWatch")
        }
    }

    @MainActor private static var coverAsked = false

    private static func releaseCover() {
        Task { @MainActor in
            guard coverAsked else { return }
            coverAsked = false
            sendToWatch([S23Rec.coverKey: false])
        }
    }

    /// 戻った（Recorder から）
    @MainActor static func resumed(way: String, seconds: TimeInterval, now: Date = .now) {
        let list = load(stopsKey)
        let open = list.last { $0.end == nil }
        save(S23Rec.closing(list, end: now, way: way), stopsKey)
        releaseCover()
        guard open?.reason != "drill" else { return }
        Tally.add("s23.rec.phone.resumed")
        Tally.add("s23.rec.phone.way." + way)
        Tally.add("s23.rec.phone.sec." + S23Rec.bucket(seconds))
        noticeResumed(seconds, now: now)
    }

    /// 中断のあいだに録音を止めた（Recorder から）
    static func abandoned(now: Date = .now) {
        save(S23Rec.closing(load(stopsKey), end: now, way: "stopped"), stopsKey)
        releaseCover()
    }

    /// 止13: 1 分より長く止まって戻ったときだけ 1 回（開いているときは出さない・1 日 3 回まで）
    @MainActor private static func noticeResumed(_ seconds: TimeInterval, now: Date) {
        guard S23Rec.isOn(S23Rec.resumedNoticeKey), let text = S23Rec.resumedText(seconds),
              UIApplication.shared.applicationState != .active,
              UserDefaults.standard.object(forKey: "stopAlerts") as? Bool ?? true else { return }
        let day = HolidayRules.dayKey(now)
        let saved = UserDefaults.standard.string(forKey: noticesKey)?.split(separator: "|")
        let sent: Int = saved.flatMap { $0.count == 2 && String($0[0]) == day ? Int($0[1]) : nil } ?? 0
        guard sent < S23Rec.resumedNoticeLimit else { return }
        UserDefaults.standard.set("\(day)|\(sent + 1)", forKey: noticesKey)
        let content = UNMutableNotificationContent()
        content.title = "iPhone の録音が戻りました"
        content.body = text
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [S23Resume.stalledID])
        NoticeGate.add(UNNotificationRequest(identifier: S23Resume.resumedID, content: content, trigger: nil))
        Tally.add("s23.rec.phone.notice")
    }

    /// 時計に頼む（つながっていて時計のアプリが入っているときだけ。送れたら true）
    @discardableResult
    @MainActor static func sendToWatch(_ info: [String: Any]) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return false }
        session.transferUserInfo(info)
        return true
    }

    // MARK: 時計の分（deliveryState の s23rec）

    /// 時計から様子が届いたら（PhoneReceiver の糸から呼ぶ）。数は watchRec として家の PC へ、止まっていたあいだは帯へ
    static func noteWatchContext(_ context: [String: Any]) {
        guard let rec = context[S23Rec.stateKey] as? [String: Any] else { return }
        let stops = (rec["stops"] as? [[String: Any]] ?? []).compactMap(S23Rec.Stop.init(dict:))
        var copy = rec
        copy["stops"] = nil
        lock.withLock {
            UserDefaults.standard.set(copy, forKey: watchStateKey)
            guard !stops.isEmpty else { return }
            var byStart: [Double: S23Rec.Stop] = [:]
            for stop in load(watchStopsKey) + stops { byStart[stop.start] = stop }
            let now = Date.now
            let merged = byStart.values.sorted { $0.start < $1.start }
                .filter { now.timeIntervalSince1970 - $0.start < S23Rec.keepDays * 86400 }
            save(Array(merged.suffix(S23Rec.keepLimit)), watchStopsKey)
        }
    }

    /// 時計の練習の結果の文（届いていなければ nil）
    static func watchDrillText() -> String? {
        let state = UserDefaults.standard.dictionary(forKey: watchStateKey)
        guard let drill = S23Rec.parseDrill(state?["drill"] as? String) else { return nil }
        let result: String = S23Rec.drillText(ok: drill.ok, seconds: drill.seconds)
        let at: String = drill.at.formatted(date: .omitted, time: .shortened)
        return "\(result)（\(at)）"
    }

    // MARK: 止1 家の PC への様子

    /// phoneRec（iPhone の今日の中断の数）・watchRec（時計から届いた今日の数）。どれも省ける
    static func diagState(now: Date = .now) -> [String: Any] {
        var out: [String: Any] = [:]
        var phone: [String: Any] = S23Rec.summary(load(stopsKey), day: HolidayRules.dayKey(now))
        if let drill = UserDefaults.standard.string(forKey: drillKey) { phone["drill"] = drill }
        if S23Rec.isOn(S23Rec.legacyKey) { phone["legacy"] = true }
        out["phoneRec"] = phone
        if let watch = UserDefaults.standard.dictionary(forKey: watchStateKey), !watch.isEmpty { out["watchRec"] = watch }
        return out
    }

    /// 設定に出す今日の 1 行
    static func todayText(now: Date = .now) -> String {
        let s = S23Rec.summary(load(stopsKey), day: HolidayRules.dayKey(now))
        let n = s["n"] as? Int ?? 0
        guard n > 0 else { return "なし" }
        var text = "\(n) 回・戻った \(s["ok"] as? Int ?? 0) 回"
        if let med = s["med"] as? Int { text += "・ふつう \(med) 秒" }
        if let max = s["max"] as? Int { text += "・長くて \(max) 秒" }
        return text
    }

    // MARK: 止12 帯

    /// その日の iPhone と時計の止まっていた所
    static func ticks(dayStart: Date, dayEnd: Date, now: Date = .now) -> [S23Rec.Tick] {
        (S23Rec.ticks(load(stopsKey), device: "phone", dayStart: dayStart, dayEnd: dayEnd, now: now)
            + S23Rec.ticks(load(watchStopsKey), device: "watch", dayStart: dayStart, dayEnd: dayEnd, now: now))
            .sorted { $0.start < $1.start }
    }

    // MARK: 止11 毎日の見回り

    @MainActor private static var dailyTask: Task<Void, Never>?
    /// 見回りの時刻になったら呼ぶ（Pipeline が入れる）
    @MainActor static var dailyKick: (@MainActor () -> Void)?

    @MainActor static func scheduleDailyCheck(now: Date = .now) {
        dailyTask?.cancel()
        dailyTask = nil
        guard S23Rec.isOn(S23Rec.dailyCheckKey) else { return }
        let starts = load(stopsKey).filter { $0.reason != "drill" }.map { Date(timeIntervalSince1970: $0.start) }
        let since = (UserDefaults.standard.object(forKey: sinceKey) as? Double).map { Date(timeIntervalSince1970: $0) }
        guard let next = S23Rec.nextCheck(S23Rec.recurringSlots(starts, since: since, now: now), now: now) else { return }
        dailyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            Tally.add("s23.rec.daily.check")
            dailyKick?()
            scheduleDailyCheck()
        }
    }

    // MARK: 止14 熱いとき

    /// 熱いので重い仕事を休ませるか（Power.isSaving が読む）
    static var hotNow: Bool {
        let hot = S23Rec.hotSaving(on: S23Rec.isOn(S23Rec.hotKey), thermal: ProcessInfo.processInfo.thermalState.rawValue)
        if hot { Tally.add("s23.rec.hot") }
        return hot
    }

    // MARK: 止15 練習

    @MainActor static func runDrill() async -> String {
        guard let drill = S23Resume.drill else { return "まだ準備ができていません" }
        let result = await drill()
        if !result.ok, result.seconds == 0 { return "iPhone で録音しているときだけ試せます（中断のあいだは試せません）" }
        UserDefaults.standard.set("\(Int(Date.now.timeIntervalSince1970))|\(result.ok ? 1 : 0)|\(Int(result.seconds.rounded()))",
                                  forKey: drillKey)
        Tally.add(result.ok ? "s23.rec.drill.ok" : "s23.rec.drill.ng")
        return S23Rec.drillText(ok: result.ok, seconds: result.seconds)
    }
}

// MARK: - 止9 時計が戻れないあいだ iPhone で録る

@MainActor
enum S23State {
    static var watchTask: Task<Void, Never>?
}

extension Pipeline {
    /// 時計から様子が届くたびに呼ぶ。時計が「録っているはずなのに録れていない」（止まりかけ・起き直せなかった）を 1 分続けて言ったら、
    /// 設定がオンのときだけ iPhone で録り始める。時計が戻ったら、s21 の 守4 と同じ印（startedForWatch）で iPhone の分を止める
    func s23WatchState(_ state: PhoneReceiver.WatchState) {
        S23State.watchTask?.cancel()
        S23State.watchTask = nil
        guard S23Rec.isOn(S23Rec.coverByPhoneKey), state.wanted == true, !state.recording else { return }
        S23State.watchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(S23PhoneBook.coverGrace))
            guard !Task.isCancelled, let self else { return }
            guard S21Rules.shouldStartPhone(action: .record, watchWanted: true, phoneRecording: self.isRecording,
                                            held: self.recordingHeld) else { return }
            await self.handle(.startRecording)
            if self.isRecording {
                S21State.shared.startedForWatch = true
                Tally.add("s23.rec.cover.phone")
            }
        }
    }
}

// MARK: - 止12 帯の切れ目

/// 帯の上に重ねる「止まっていた所」（iPhone は赤・時計は橙）
struct S23StopTicksLayer: View {
    let dayStart: Date
    let width: Double
    let height: CGFloat
    var y: CGFloat = 0

    var body: some View {
        let end = dayStart.addingTimeInterval(86400)
        let ticks = S23PhoneBook.ticks(dayStart: dayStart, dayEnd: end)
        ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                let x0 = BandRules.x(of: tick.start, width: width, dayStart: dayStart, dayEnd: end)
                let x1 = BandRules.x(of: tick.end, width: width, dayStart: dayStart, dayEnd: end)
                Rectangle()
                    .fill(tick.device == "watch" ? LL.warn : LL.danger)
                    .frame(width: max(2, x1 - x0), height: height)
                    .offset(x: x0, y: y)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 1 日の帯の下に出す「止まっていた時間」（理由つき。無ければ出さない）
struct S23StopsSection: View {
    let dayStart: Date

    /// 「6:30〜6:32（2分）」（型の推し量りが長くならないよう、式を分けて作る）
    static func span(_ tick: S23Rec.Tick) -> String {
        let from: String = tick.start.formatted(date: .omitted, time: .shortened)
        let to: String = tick.end.formatted(date: .omitted, time: .shortened)
        let length: String = S21Watch.durationText(tick.end.timeIntervalSince(tick.start))
        return from + "〜" + to + "（" + length + "）"
    }

    var body: some View {
        let ticks = S23PhoneBook.ticks(dayStart: dayStart, dayEnd: dayStart.addingTimeInterval(86400))
        if !ticks.isEmpty {
            Section {
                ForEach(Array(ticks.suffix(20).enumerated()), id: \.offset) { _, tick in
                    LabeledContent(tick.label) {
                        Text(Self.span(tick)).monospacedDigit()
                    }
                }
            } header: {
                Text("止まっていた時間")
            } footer: {
                Text("アラーム・電話などで録音が止められていたあいだです（赤は iPhone、橙は時計）。理由は OS が教える分だけで、「アラーム？」は始まった時刻からの見立てです。")
            }
        }
    }
}

// MARK: - 設定（くわしい設定の Apple Watch の下）

struct S23RecSettingsSection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(S23Rec.probeKey) private var probe = true
    @AppStorage(S23Rec.callKey) private var call = true
    @AppStorage(S23Rec.dailyCheckKey) private var daily = true
    @AppStorage(S23Rec.resumedNoticeKey) private var notice = true
    @AppStorage(S23Rec.hotKey) private var hot = true
    @AppStorage(S23Rec.coverByPhoneKey) private var coverPhone = false
    @AppStorage(S23Rec.coverByWatchKey) private var coverWatch = false
    @AppStorage(S23Rec.legacyKey) private var legacy = false
    @State private var drillResult: String?
    @State private var drilling = false
    @State private var watchAsked = false

    var body: some View {
        Section {
            Toggle("音が止んだら 1 分待たずに戻す", isOn: $probe)
            Toggle("電話が終わったらすぐ戻す", isOn: $call)
            Toggle("毎日同じ時刻に切れるなら見回る", isOn: $daily)
            Toggle("1 分より長く止まって戻ったら知らせる", isOn: $notice)
            Toggle("熱いときは重い仕事を休ませる", isOn: $hot)
            Toggle("時計が戻れないあいだ iPhone で録る", isOn: $coverPhone)
            Toggle("iPhone が戻れないとき時計に頼む", isOn: $coverWatch)
            Toggle("録音の戻し方を前の動きに戻す", isOn: $legacy)
            LabeledContent("今日の中断（iPhone）", value: S23PhoneBook.todayText())
            Button {
                drilling = true
                Task {
                    drillResult = await S23PhoneBook.runDrill()
                    drilling = false
                }
            } label: {
                Label(drilling ? "試しています…" : "中断の練習（iPhone）", systemImage: "arrow.counterclockwise")
            }
            .disabled(drilling)
            if let drillResult { Text(drillResult).font(.callout) }
            Button {
                watchAsked = S23PhoneBook.sendToWatch([S23Rec.drillKey: true])
                Tally.add("s23.rec.drill.askWatch")
            } label: {
                Label("中断の練習（時計）", systemImage: "applewatch")
            }
            if watchAsked { Text("時計に頼みました。結果は時計から様子が届くとここに出ます。").font(.caption).foregroundStyle(LL.dim) }
            if let watch = S23PhoneBook.watchDrillText() { LabeledContent("時計の練習", value: watch) }
        } header: {
            Text("録音が止まらない")
        } footer: {
            HelpNote("「音が止んだら 1 分待たずに戻す」（初めはオン）: アラーム・電話などで止められたあいだ、5 秒ごとにほかの音が鳴っているかを見て、止んだらすぐ戻します。だめでも今までどおり 1 分で自分で戻します（効くかは仮説）。\n「電話が終わったらすぐ戻す」（初めはオン）: 電話中かどうかだけを見ます（相手や中身は見ません。効くかは仮説）。\n「毎日同じ時刻に切れるなら見回る」（初めはオン）: 7 日のうち 3 日以上同じ時刻に止められていたら、その 1 分後に止まったままでないかを見て、止まっていれば戻します。\n「戻ったら知らせる」（初めはオン）: 1 分より長く止まって戻ったときだけ、1 日 3 回まで。\n「熱いときは重い仕事を休ませる」（初めはオン）: iPhone が熱いあいだは端末内の文字起こしを休ませて録音を守ります（夜の聞き直しで取り戻します）。\n「肩代わり」の 2 つ（初めはオフ）: 片方が戻れないあいだ、もう片方で録ります。二重に録るので電池を使います。時計が裏で録り始められるかは仮説です。\n「前の動きに戻す」（初めはオフ）: 版 386 で変えた戻し方が悪さをしたときの逃げ道です。オンにすると、終わったときに 1 回だけ試し、だめなら止めて知らせる前の動きになります（時計は作り直しをしません）。\n「中断の練習」: 録音をわざと 1 回切って、自分で戻るかを ○× で出します。本物の中断とは始まり方が違うので、戻る道だけを試します。")
        }
        .onChange(of: probe) { _, _ in S21Book.settingsChanged?() }
        .onChange(of: daily) { _, _ in
            S21Book.settingsChanged?()
            S23PhoneBook.scheduleDailyCheck()
        }
        .onChange(of: notice) { _, _ in S21Book.settingsChanged?() }
        .onChange(of: legacy) { _, _ in S21Book.settingsChanged?() }
    }
}

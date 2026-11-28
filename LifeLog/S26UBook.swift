import Foundation
import Observation
import UIKit
import WatchConnectivity

// s26（2026-11-25）の A2 の動き。決まりは S26URules.swift と Shared/Audio/S26UWatchPlan.swift、画面は S26UViews.swift。
// - 軽5・軽9・軽11（K5・K4・K6）: 家の PC の GET /waiting・/machine-actions・/gap-task を 10 分（仮）に 1 回読む。
//   口が無い（404 など）・つながらないときは前のまま。知らせは足さない（減13）。中身の文は記録（ログ）に書かない
// - 軽9: 「戻す」は POST /feedback の kind "undo"（MothershipOutbox にためて、いつもの送り口で送る）
// - 軽6: 5 分ごとに、時計への録り方の指図が変わった・日が変わった・3 時間たったら送り直す
// - 軽3: コントロールセンターの「録り方の組を替える」を受ける

@MainActor
@Observable
final class S26UBook {
    static let shared = S26UBook()
    static var pipeline: Pipeline?
    private static var timer: Timer?

    /// 家の PC の写しを読む間（秒。仮 10 分）
    static let feedEvery: TimeInterval = 600
    @ObservationIgnored private var feedAt: Date?
    @ObservationIgnored private var feeding = false

    private static let waitingKey = "s26u.waiting"
    private static let machineKey = "s26u.machine"
    private static let gapsKey = "s26u.gaps"
    private static let undoneKey = "s26u.undone"

    private(set) var waiting: [S26UWaitingItem] = []
    private(set) var machine: [S26UMachineAction] = []
    private(set) var gaps: [S26UGapTask] = []
    /// 「戻す」を送ったもの（id → 送った日）
    private(set) var undone: [String: String] = [:]

    init() {
        let d = UserDefaults.standard
        waiting = Self.load([S26UWaitingItem].self, Self.waitingKey) ?? []
        machine = Self.load([S26UMachineAction].self, Self.machineKey) ?? []
        gaps = Self.load([S26UGapTask].self, Self.gapsKey) ?? []
        undone = d.dictionary(forKey: Self.undoneKey) as? [String: String] ?? [:]
    }

    /// LifeLogApp の起動で 1 回だけ呼ぶ。live でなければ（テスト・画面の自動確認）動かさない
    static func install(_ pipeline: Pipeline, live: Bool) {
        self.pipeline = pipeline
        // コントロールセンターの「録り方の組を替える」（Shared/Intents/S26UIntents.swift）
        S26UControlActions.handler = { name in await S26UBook.shared.control(name) }
        if let pending = S26UControlActions.pending {
            S26UControlActions.pending = nil
            shared.control(pending)
        }
        guard live, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in S26UBook.shared.tick() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(50))
            S26UBook.shared.tick()
        }
    }

    /// 5 分ごと
    func tick(now: Date = .now) {
        guard let pipeline = Self.pipeline else { return }
        resendWatchPlanIfDue(pipeline, now: now)
        if !feeding, feedAt.map({ now.timeIntervalSince($0) >= Self.feedEvery }) ?? true {
            feedAt = now
            feeding = true
            Task {
                await refresh(pipeline)
                feeding = false
            }
        }
    }

    // MARK: 軽5・軽9・軽11 写しを読む

    func refresh(_ pipeline: Pipeline) async {
        guard pipeline.homePC.isConfigured else { return }
        if let data = try? await pipeline.homePC.getJSONData("waiting", timeout: 10), let list = S26UFeeds.waiting(data) {
            if list != waiting {
                waiting = list
                Self.save(list, Self.waitingKey)
            }
            Tally.add("s26u.waiting.read")
        }
        if let data = try? await pipeline.homePC.getJSONData("machine-actions", timeout: 10), let list = S26UFeeds.machine(data) {
            if list != machine {
                machine = list
                Self.save(list, Self.machineKey)
                // もう届かないものの「戻す」の印は捨てる（溜めない）
                let ids = Set(list.map(\.id))
                let kept = undone.filter { ids.contains($0.key) }
                if kept.count != undone.count {
                    undone = kept
                    UserDefaults.standard.set(kept, forKey: Self.undoneKey)
                }
            }
            Tally.add("s26u.machine.read")
        }
        if let data = try? await pipeline.homePC.getJSONData("gap-task", timeout: 10), let list = S26UFeeds.gaps(data) {
            if list != gaps {
                gaps = list
                Self.save(list, Self.gapsKey)
            }
            Tally.add("s26u.gap.read")
        }
    }

    /// まだの操作待ちの数（済んだものは機械が done にする）
    /// 2026-11-27（s33 の K33-1）から、家の PC の /s33 の操作待ち（同じ id は 1 つ）も数える（S33AViews.swift）
    var waitingOpen: Int {
        // 「あとでいいもの」（group が later）は数に入れない（畳んだ箱には出す。2026-11-28。s37 の K37-1）
        waiting.filter { !$0.isDone && !S37AWaiting.isLater($0.group) }.count
            + S33ABook.shared.extraWaiting(known: Set(waiting.map(\.id))).count
    }

    /// いまの時刻に当たるすきまの 1 件
    func gapNow(now: Date = .now) -> S26UGapTask? { S26UFeeds.currentGap(gaps, now: now) }

    /// 「戻す」（K4。答えは家の PC → 母艦の inbox/app_feedback.jsonl。母艦が次の回で戻す）
    func undo(_ action: S26UMachineAction, now: Date = .now) {
        let day = ReviewRules.dayKey(now)
        guard action.canUndo, undone[action.id] == nil, let body = S26UFeeds.undoBody(id: action.id, day: day) else { return }
        MothershipOutbox.enqueue(path: "feedback", body: body, now: now)
        undone[action.id] = day
        UserDefaults.standard.set(undone, forKey: Self.undoneKey)
        Tally.add("s26u.undo")
        if let pipeline = Self.pipeline { Task { await MothershipOutbox.send(pipeline.homePC) } }
    }

    // MARK: 軽6 時計への録り方の指図

    private func resendWatchPlanIfDue(_ pipeline: Pipeline, now: Date) {
        let combo = S22Watch.hourlyNow(now: now)
            ?? RecordingExperiment.combo(on: RecordingExperiment.isOn, start: RecordingExperiment.start, meeting: false, now: now)
        let plan = S26UWatchPlan.make(base: ChunkCutter.length, combo: combo, now: now)
        guard S26UWatchPlan.shouldSend(plan, last: S26UWatchPlan.lastSent, now: now) else { return }
        pipeline.receiver.sendSettings(skipSilence: pipeline.skipSilence, held: pipeline.recordingHeld)
        Tally.add("s26u.plan.sent")
    }

    /// 時計の様子から: 指図で動ける時計か（古い時計は鍵を送らない）・いま指図で動いているか
    static func watchPlanState() -> (version: Int?, using: Bool?) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return (nil, nil) }
        let context = WCSession.default.receivedApplicationContext
        return (context[S26UWatchPlan.watchVersionKey] as? Int, context[S26UWatchPlan.watchUsingKey] as? Bool)
    }

    // MARK: 軽3 コントロールセンター

    func control(_ name: String) {
        guard let pipeline = Self.pipeline else {
            S26UControlActions.pending = name
            return
        }
        switch name {
        case S26UControlActions.nextPreset:
            let next = S26UQuick.next(after: pipeline.currentPreset)
            pipeline.applyPreset(next)
            Tally.add("s26u.control.preset")
        default:
            break
        }
    }

    // MARK: 家の PC への様子（PCDiag。どれも省ける）

    static func diagState(_ pipeline: Pipeline) -> [String: Any] {
        var out: [String: Any] = [:]
        let plan = watchPlanState()
        var planOut: [String: Any] = ["watch": plan.version ?? 0]
        if let using = plan.using { planOut["on"] = using }
        out["s26uPlan"] = planOut
        out["s26uWaitingOpen"] = shared.waitingOpen
        out["s26uMachine"] = shared.machine.count
        return out
    }

    // MARK: 置き場（小さいので UserDefaults）

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

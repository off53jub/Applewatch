import Foundation
import HealthKit

/// 画面が消えているあいだに録音を戻せないときのための強い守り（2026-11-22。s21 の 守3。docs/s21-app.md）。
///
/// 時計の LifeLog は、画面が消えているあいだ AVAudioEngine を流し続けて録っている（WatchRecorder）。
/// 11/20・21 は、アラームのあとなどに画面が消えたままマイクを流し直せず、時計の LifeLog を開くまで戻らなかった（#90 で止めずに試し続けるようにした）。
/// それでも戻らない日のために、録音中だけワークアウト扱い（HKWorkoutSession）にして、watchOS にアプリを前にいるのと同じに扱ってもらう。
/// - 設定「時計の強い守り（ワークアウト扱い）」（iPhone の設定。時計には iPhone から届く。初めはオフ）。
/// - 記録（ワークアウト・消費カロリー）はヘルスケアに残さない（HKLiveWorkoutBuilder を使わず、終わったら捨てる）。
/// - 電池は多く使う（心拍を測り続けるため）。効き目と電池の減りは仮説（実機で未確認）。
/// - 初めてオンにして録音を始めたとき、ヘルスケアの「ワークアウト」の書き込みの許可を聞く（許可が無ければ何もしない）。
@MainActor
final class WatchGuard: NSObject {
    /// 守っている・やめた（WatchSender の様子に載せる）
    var onChange: ((Bool) -> Void)?
    private(set) var active = false
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var starting = false

    private var enabled: Bool { UserDefaults.standard.bool(forKey: S21Watch.workoutGuardKey) }

    /// 録音しているか・設定が変わったら呼ぶ（何度呼んでもよい）
    func update(recording: Bool) {
        let want = recording && enabled && HKHealthStore.isHealthDataAvailable()
        if want, session == nil, !starting {
            start()
        } else if !want, session != nil {
            end()
        }
    }

    private func start() {
        starting = true
        Task { @MainActor in
            defer { starting = false }
            let type = HKObjectType.workoutType()
            if store.authorizationStatus(for: type) == .notDetermined {
                try? await store.requestAuthorization(toShare: [type], read: [])
            }
            guard store.authorizationStatus(for: type) == .sharingAuthorized, session == nil else { return }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .unknown
            guard let next = try? HKWorkoutSession(healthStore: store, configuration: configuration) else { return }
            next.delegate = self
            next.startActivity(with: .now)
            session = next
            set(true)
        }
    }

    private func end() {
        session?.end()
        session = nil
        set(false)
    }

    private func set(_ on: Bool) {
        guard active != on else { return }
        active = on
        onChange?(on)
    }

    fileprivate func ended() {
        session = nil
        set(false)
    }
}

extension WatchGuard: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in self.ended() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.ended() }
    }
}

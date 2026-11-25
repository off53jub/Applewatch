import Foundation

/// s26（2026-11-25）の 軽6: 時計を「録って送るだけ」に寄せる（iPhone と時計の両方で使う決まり）。
///
/// 時計の LifeLog は版が遅れやすい（2026-11-25 は時計 386・iPhone 421）。区切りの長さと音質を決める決まり（設定・録り方の実験・
/// 1 時間ごとの入れ替え）は今まで時計の中でも計算していたので、決まりを直しても時計を入れ直すまで効かなかった。
/// そこで iPhone がその日の「録り方の指図」（区切りの長さ・音質・どの日の分か・いつまで有効か）を決めて時計に渡し、
/// 新しい時計はそれに従うだけにする。これからは決まりを直しても iPhone の版だけで効く。
///
/// - 送り方: 今までの applicationContext に `s26u.plan`（JSON の Data）を 1 つ足すだけ。今までの鍵（chunkLength・recExpOn など）は
///   そのまま送り続けるので、古い時計（版 386）は知らない鍵を読み飛ばし、今までどおり動く（後ろ向きに互換）。
/// - 時計の守り（電池が少ないときは 5 分・寝ている時間は 5 分・会議モードの音質）は、これまでどおり時計が先に決める（電池を守る側）。
/// - 指図が古い（日が変わった・有効な時間を過ぎた・iPhone とつながらない）ときは、時計は今までの自分の決まりに戻る。
/// - 時計は「指図で動けるか（版）」と「いま指図で動いているか」を iPhone への様子に足す（古い時計は送らない＝iPhone は古いと分かる）。
/// テストは LifeLogTests/S26UTests.swift。
enum S26UWatchPlan {
    /// applicationContext の鍵（iPhone → 時計）
    static let contextKey = "s26u.plan"
    /// 時計が覚えておく名前（時計の UserDefaults）
    static let savedKey = "s26u.plan.saved"
    /// 時計 → iPhone の様子の名前（どれも省ける）: 指図の版・いま指図で動いているか
    static let watchVersionKey = "s26uPlanV"
    static let watchUsingKey = "s26uPlanOn"
    /// 指図の形の版（増やすときは古い時計が読み飛ばせるように足すだけにする）
    static let version = 1
    /// 指図が有効な長さ（仮 6 時間。iPhone は 3 時間ごと・日が変わったとき・設定を変えたときに送り直す）
    static let lifetime: TimeInterval = 6 * 3600
    /// 変わっていなくても送り直す間（仮 3 時間）
    static let resendEvery: TimeInterval = 3 * 3600

    struct Plan: Codable, Equatable, Sendable {
        var v: Int
        /// どの日の分か（yyyy-MM-dd）。日が変わったら使わない
        var day: String
        /// 作った時刻・有効な終わり（1970 からの秒）
        var made: Double
        var until: Double
        /// 区切りの長さ（ChunkCutter.Length の rawValue）。nil なら時計の決まりのまま
        var length: String? = nil
        /// 音質（bps）。nil なら時計の決まりのまま
        var bitrate: Int? = nil
    }

    // MARK: 決まり（決まった入力から決まった出力だけ）

    /// iPhone が作る指図。会議モードは時計が自分で決める（下の apply で時計の会議モードが先）ので、ここでは数えない
    static func make(base: ChunkCutter.Length, combo: RecordingExperiment.Combo?, now: Date, calendar: Calendar = .current) -> Plan {
        let day = RecordingExperiment.dayKey(now, calendar: calendar)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))?.timeIntervalSince1970
            ?? now.timeIntervalSince1970 + lifetime
        let until = min(now.timeIntervalSince1970 + lifetime, endOfDay)
        return Plan(v: version, day: day, made: now.timeIntervalSince1970, until: until,
                    length: RecordingExperiment.length(base: base, combo: combo).rawValue,
                    bitrate: RecordingExperiment.bitrate(combo: combo, meeting: false, meetingRate: RecordingExperiment.meetingBitrate))
    }

    /// 使える指図か（形の版が読める・今日の分・有効な時間の中・作った時刻が先すぎない）
    static func usable(_ plan: Plan?, now: Date, calendar: Calendar = .current) -> Plan? {
        guard let plan, plan.v >= 1, plan.v <= version else { return nil }
        let t = now.timeIntervalSince1970
        guard plan.day == RecordingExperiment.dayKey(now, calendar: calendar), t < plan.until, plan.made <= t + 300 else { return nil }
        return plan
    }

    /// 使う区切りの長さ（時計の会議モードのあいだ・指図が無い・読めないときは時計の決まりのまま）
    static func length(local: ChunkCutter.Length, plan: Plan?, meeting: Bool, now: Date) -> ChunkCutter.Length {
        guard !meeting, let plan = usable(plan, now: now), let raw = plan.length, let length = ChunkCutter.Length(rawValue: raw) else {
            return local
        }
        return length
    }

    /// 使う音質（時計の会議モードのあいだ・指図が無いときは時計の決まりのまま。おかしな値は使わない）
    static func bitrate(local: Int, plan: Plan?, meeting: Bool, now: Date) -> Int {
        guard !meeting, let plan = usable(plan, now: now), let rate = plan.bitrate, (16_000...96_000).contains(rate) else { return local }
        return rate
    }

    /// 送り直すか（中身が変わった・日が変わった・前に送ってから resendEvery たった）
    static func shouldSend(_ plan: Plan, last: Plan?, now: Date) -> Bool {
        guard let last else { return true }
        if last.day != plan.day || last.length != plan.length || last.bitrate != plan.bitrate { return true }
        return now.timeIntervalSince1970 - last.made >= resendEvery
    }

    static func encode(_ plan: Plan) -> Data? { try? JSONEncoder().encode(plan) }

    static func decode(_ data: Data?) -> Plan? { data.flatMap { try? JSONDecoder().decode(Plan.self, from: $0) } }

    // MARK: iPhone と時計のあいだ

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Plan??

    /// この端末で覚えている指図（時計だけが書く。iPhone では無いので、いつも nil＝今までの決まり）
    static var saved: Plan? {
        lock.withLock { () -> Plan? in
            if let cached { return cached }
            let plan = decode(UserDefaults.standard.data(forKey: savedKey))
            cached = .some(plan)
            return plan
        }
    }

    /// iPhone が時計に送る設定に入れる（ChunkCutter.addSettings から）。今の値で作る
    static func addSettings(to context: inout [String: Any], now: Date = .now) {
        let combo = S22Watch.hourlyNow(now: now) ?? RecordingExperiment.combo(on: RecordingExperiment.isOn, start: RecordingExperiment.start,
                                                                              meeting: false, now: now)
        let plan = make(base: ChunkCutter.length, combo: combo, now: now)
        if let data = encode(plan) { context[contextKey] = data }
        lastSent = plan
    }

    /// iPhone が最後に時計へ入れた指図（送り直すかを決めるのに使う。iPhone の中だけ）
    nonisolated(unsafe) static var lastSent: Plan?

    /// 時計が iPhone から届いた設定を読む（ChunkCutter.readSettings から。次の区切りから効く）
    static func readSettings(_ context: [String: Any]) {
        guard let data = context[contextKey] as? Data, let plan = decode(data) else { return }
        UserDefaults.standard.set(data, forKey: savedKey)
        lock.withLock { cached = .some(plan) }
    }

    /// 時計 → iPhone の様子（時計の deliveryState から）
    static func watchState(now: Date = .now) -> [String: Any] {
        [watchVersionKey: version, watchUsingKey: usable(saved, now: now) != nil]
    }
}

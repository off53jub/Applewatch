import Foundation

/// s21（2026-11-22）の時計と iPhone の両方で使う決まり（決まった入力から決まった出力だけ。docs/s21-app.md）。
/// 番号は母艦に出した s21 の案の番号。しきい値はどれも仮（データがたまったら測り直す）。
/// テストは LifeLogTests/S21Tests.swift。
enum S21Watch {
    // MARK: - iPhone → 時計の設定の名前（applicationContext）

    /// 電3: 寝ている時間（1:00〜6:00・充電していない）は区切りを自動で 5 分に（初めはオン）
    static let sleepChunksKey = "s21.sleepChunks"
    /// 守3: 画面が消えているあいだの強い守り（ワークアウト扱い。初めはオフ）
    static let workoutGuardKey = "s21.workoutGuard"
    /// 時計がいま、寝ている時間なので 5 分で区切っているか（時計の UserDefaults。iPhone ではいつも false）
    static let sleepSavingKey = "s21.sleepSaving"

    static func addSettings(to context: inout [String: Any], defaults: UserDefaults = .standard) {
        context[sleepChunksKey] = defaults.object(forKey: sleepChunksKey) as? Bool ?? true
        context[workoutGuardKey] = defaults.bool(forKey: workoutGuardKey)
    }

    static func readSettings(_ context: [String: Any], defaults: UserDefaults = .standard) {
        for key in [sleepChunksKey, workoutGuardKey] {
            if let on = context[key] as? Bool { defaults.set(on, forKey: key) }
        }
    }

    // MARK: - 時計 → iPhone の様子の名前（deliveryState。どれも省ける）

    /// 使5: 今日、時計で録れた秒（捨てた区切りも含む＝マイクで書いた時間）
    static let recordedTodayKey = "recordedToday"
    /// 守2: 今日、録音しているつもりのまま時計のアプリが終わっていた回数
    static let exitsKey = "exits"
    /// 守2: 最後に終わっていたあいだ（"最後に動いていた秒|起き直した秒"）
    static let lastExitKey = "lastExit"
    /// 速2: 1 日を過ぎた返事待ちを片付けた数（これまでの合計）
    static let keptClearedKey = "keptCleared"
    /// 守3: いまワークアウト扱いで守っているか
    static let guardingKey = "workoutGuarding"
    /// 精7: 今日、声が無いので捨てるはずだった区切りのうち、見本として送った数
    static let sampledNoVoiceKey = "sampledNoVoice"

    // MARK: - 精7 声の無い区切りの見本（1 割）

    /// 区切りの metadata（transferFile）と、POST /jobs の query に付ける名前（家の PC の担当 P と合わせた形）
    static let sampleNoVoiceKey = "sampleNoVoice"
    /// 何個に 1 個を見本にするか（1 割）
    static let sampleEvery = 10

    /// 名前から決まる 1 割（乱数を使わないので、送り直しても同じ区切りが見本になる）
    static func shouldSampleNoVoice(name: String, every: Int = sampleEvery) -> Bool {
        guard every > 0 else { return false }
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash % UInt32(every) == 0
    }

    /// 見本にした区切りの名前（送り直しでも印を付けるため。2 日で忘れる）
    static func addingSample(_ saved: [String: Double], name: String, now: Date, keep: TimeInterval = 2 * 86400) -> [String: Double] {
        let t = now.timeIntervalSince1970
        var out = saved.filter { t - $0.value < keep }
        out[name] = t
        return out
    }

    // MARK: - 電3 寝ている時間は 5 分の区切り

    /// 寝ている時間の始まりと終わり（時。仮）
    static let sleepFrom = 1
    static let sleepTo = 6

    /// いま寝ている時間なので 5 分で区切るか（設定がオン・1:00〜6:00・充電していない）。
    /// 睡眠の記録（ヘルスケア）は起きてから書かれるので、いまの時刻で決める
    static func sleepSaving(enabled: Bool, hour: Int, charging: Bool) -> Bool {
        enabled && !charging && hour >= sleepFrom && hour < sleepTo
    }

    // MARK: - 使5 今日録れた時間

    /// 区切りの長さ（名前の時刻から、区切った時刻まで。読めなければ nil。長すぎる・負のものは捨てる）
    static func chunkSeconds(start: Date?, cut: Date, limit: TimeInterval = 30 * 60) -> TimeInterval? {
        guard let start else { return nil }
        let seconds = cut.timeIntervalSince(start)
        guard seconds > 0, seconds <= limit else { return nil }
        return seconds
    }

    /// 日ごとの秒に足す（今日の分だけ残す）
    static func addingSeconds(_ saved: [String: Double], day: String, seconds: TimeInterval) -> [String: Double] {
        [day: (saved[day] ?? 0) + max(0, seconds)]
    }

    /// 「2時間15分」「35分」
    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.down))
        if minutes >= 60 { return "\(minutes / 60)時間\(minutes % 60)分" }
        return "\(minutes)分"
    }

    /// 時計の録音の画面の 1 行「今日 2時間15分・最後に届いた 10:30」（届いた時刻が今日でなければ日付も）
    static func todayLine(recorded: TimeInterval, delivered: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        var text = "今日 " + durationText(recorded)
        if let delivered {
            let time = String(format: "%d:%02d", calendar.component(.hour, from: delivered), calendar.component(.minute, from: delivered))
            let sameDay = calendar.isDate(delivered, inSameDayAs: now)
            let day = sameDay ? "" : "\(calendar.component(.month, from: delivered))/\(calendar.component(.day, from: delivered)) "
            text += "・最後に届いた " + day + time
        } else {
            text += "・まだ届いていません"
        }
        return text
    }

    // MARK: - 守2 落ちた・止められた記録

    /// 次の起動で「録音しているつもりだったのに止まっていた」を残す。
    /// alive は最後に動いていた時刻（無ければ nil＝数えない）、relaunch は起き直した時刻。
    /// 1 分より短い間（起き直しただけ）は数えない。最後の limit 個だけ残す
    static func addingExit(_ list: [[Double]], alive: Double?, relaunch: Double, minGap: Double = 60,
                           limit: Int = 20) -> [[Double]] {
        guard let alive, alive > 0, relaunch - alive >= minGap else { return list }
        return Array((list.filter { $0.count >= 2 } + [[alive.rounded(), relaunch.rounded()]]).suffix(max(0, limit)))
    }

    /// その日に起き直した回数
    static func exitsOn(_ list: [[Double]], day: String, calendar: Calendar = .current) -> Int {
        list.filter { $0.count >= 2 && HolidayRules.dayKey(Date(timeIntervalSince1970: $0[1]), calendar: calendar) == day }.count
    }

    /// 最後の記録の文（"最後に動いていた秒|起き直した秒"）
    static func lastExitText(_ list: [[Double]]) -> String? {
        guard let last = list.last(where: { $0.count >= 2 }) else { return nil }
        return "\(Int(last[0]))|\(Int(last[1]))"
    }

    /// "秒|秒" を読む（iPhone）
    static func parseExit(_ text: String?) -> (alive: Date, relaunch: Date)? {
        guard let parts = text?.split(separator: "|"), parts.count == 2,
              let a = Double(parts[0]), let b = Double(parts[1]), b >= a else { return nil }
        return (Date(timeIntervalSince1970: a), Date(timeIntervalSince1970: b))
    }

    // MARK: - 速2 1 日を過ぎた返事待ち

    /// これより前に区切った返事待ちは片付けの対象（1 日。仮）
    static let keptTidyAge: TimeInterval = 86400

    /// 返事待ちの控えを片付けるか。iPhone が「受け取った」と言っている名前（gotList）にあるか、
    /// 1 日を過ぎていて家の PC に届いている（PC が音声を持っている）なら片付ける。PC に無い 1 日超えのものは残す（失わないほう）
    static func tidyKept(cutAge: TimeInterval?, sentToPC: Bool, phoneHas: Bool) -> Bool {
        if phoneHas { return true }
        guard let cutAge else { return false }
        return sentToPC && cutAge > keptTidyAge
    }

    /// transferUserInfo（iPhone → 時計）: iPhone が受け取ったと覚えている時計の区切りの名前（iPhone で付く名前）
    static let gotListKey = "gotList"
}

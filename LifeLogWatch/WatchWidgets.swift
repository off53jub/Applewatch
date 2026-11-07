import Foundation

/// 時計の文字盤（ウィジェット）に出す中身を作って、時計の App Group に書く（2026-11-07）。
/// 録音中か・iPhone に送っていない録音の数・今日までの頼まれごと・次の予定（頼まれごとと予定は iPhone から届いた WatchInfo から）。
/// iPhone から中身が届いたとき・「済み」を押したとき・録音を始めた/止めたとき・送っていない数が変わったときに呼ぶ。
/// 変わったときだけ書き、文字盤には多くても1分に1回、読み直してもらう（WidgetPublisher）。
/// App Group が使えない入れ方では何も書かない（文字盤は「—」を出す）。
extension WatchRecorder {
    func updateWidgets() {
        let state = WatchWidgets.state(recording: isRecording, unsent: unsent, lowPower: lowPower, info: board.info,
                                       due: board.dueCounts, open: board.openCount)
        WidgetPublisher.shared.publish(state, kind: WidgetState.watchKind)
    }
}

enum WatchWidgets {
    /// 送っていない数を文字盤に出す数。1つは送っている途中のことが多い（低電力モードでは15分ほど溜めてから送る）ので、
    /// それより多く溜まったときだけ出す（いつもの送り受けで、文字盤を何度も読み直させないため）。
    /// 区切りが短いと数が増えるので、5分の区切りで2つ（低電力 4つ）と同じくらいの時間の分が溜まったときだけ出す（2026-11-07）
    static func shownUnsent(_ unsent: Int, lowPower: Bool, length: ChunkCutter.Length = ChunkCutter.current) -> Int {
        unsent >= ChunkCutter.scaled(lowPower ? 4 : 2, length: length) ? unsent : 0
    }

    /// 文字盤に出す中身。info は iPhone から届いた中身（まだ届いていなければ nil）、due は今日までの頼まれごとの数
    static func state(recording: Bool, unsent: Int, lowPower: Bool, info: WatchInfo?, due: (due: Int, overdue: Int)?,
                      open: Int, now: Date = .now) -> WidgetState {
        var state = WidgetState(updated: now)
        state.watchRecording = recording
        state.watchUnsent = shownUnsent(unsent, lowPower: lowPower)
        if let due {
            state.tasksDue = due.due
            state.tasksOverdue = due.overdue
            state.tasksOpen = open
        }
        // 終わった予定は出さない（次の予定は、iPhone から次に届いたときに入れ替わる）
        if let next = info?.next {
            let event = WidgetState.Event(title: next.title, start: Date(timeIntervalSince1970: next.start),
                                          end: next.end.map { Date(timeIntervalSince1970: $0) })
            if event.until > now { state.nextEvent = event }
        }
        return state
    }
}

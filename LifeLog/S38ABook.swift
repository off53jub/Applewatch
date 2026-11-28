import Foundation
import Observation

// s38（2026-11-28）アプリ担当 S38A（A1）の動き。決まりは S38ARules.swift。
// - 続4: 仕事のまとめ・写真を家の PC へ共有して「済んだ」を出したあと（S30WBook.watch の done・S36ABook.sendTable の送れたあと）、
//   写しに later_done_at の欄があれば、それが共有の時刻より新しくなるまで 1 分ごと（仮）に GET /s36 と仕事の画面（GET /work）を
//   取り直す（20 分まで・仮）。欄が無ければ何もしない（今の動きのまま）。新しい共有が来たら前の待ちはやめて、新しい時刻で待ち直す。
// 知らせ・問いは足さない。Tally は数と種類の名前だけ。

@MainActor
@Observable
final class S38ABook {
    static let shared = S38ABook()

    /// 待っている共有の時刻（待っていなければ nil。画面の中の小さな 1 行に使える）
    private(set) var waitingSince: Date?
    @ObservationIgnored private var job: Task<Void, Never>?

    /// 共有して「済んだ」を出したあとに呼ぶ
    func follow(sharedAt: Date, now: Date = .now) {
        let s36 = S36ABook.shared
        guard S38ALater.follows(s36.feed, offered: s36.offered) else {
            Tally.add("s38a.later.none")
            return
        }
        job?.cancel()
        waitingSince = sharedAt
        Tally.add("s38a.later.start")
        job = Task { await self.loop(sharedAt: sharedAt, startedAt: now) }
    }

    /// 待つのをやめる（試し用・新しい共有の前）
    func stop() {
        job?.cancel()
        job = nil
        waitingSince = nil
    }

    private func loop(sharedAt: Date, startedAt: Date) async {
        defer { if !Task.isCancelled { waitingSince = nil } }
        while true {
            try? await Task.sleep(for: .seconds(S38ALater.every))
            if Task.isCancelled { return }
            await S36ABook.shared.refresh(force: true)
            await S27WBook.shared.refresh(force: true)
            if Task.isCancelled { return }
            switch S38ALater.step(S36ABook.shared.feed, sharedAt: sharedAt, startedAt: startedAt, now: .now) {
            case .wait:
                continue
            case .caughtUp:
                Tally.add("s38a.later.caught")
                return
            case .noField:
                Tally.add("s38a.later.gone")
                return
            case .timeUp:
                Tally.add("s38a.later.timeup")
                return
            }
        }
    }
}

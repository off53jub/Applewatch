import Foundation
import WidgetKit

/// アプリが WidgetState を App Group に書いて、ウィジェットに読み直してもらう（2026-11-07）。
/// 変わったときだけ書く。読み直しは多くても1分に1回（間に合わなかった分は、間が空いてから1回だけ）。
/// 最後に文字にした時刻・送っていない数だけが変わったときは、15分に1回まで（ウィジェットの読み直しには1日の回数の上限があり、
/// 使い切ると録音を始めた・止めたことも出なくなるため）。
/// App Group が使えない入れ方（署名なしの IPA など）では何も書かない。
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()
    /// 読み直してもらう間を、少なくともこれだけ空ける
    nonisolated static let interval: TimeInterval = 60
    /// 小さな変わり方（WidgetState.isMinorChange）だけのときの間
    nonisolated static let minorInterval: TimeInterval = 15 * 60

    private var lastReload = Date.distantPast
    private var waiting: Task<Void, Never>?
    /// 待っている読み直しの時刻
    private var waitingUntil: Date?

    /// 中身が変わっていれば書いて、読み直しを頼む。書いたら true
    @discardableResult
    func publish(_ state: WidgetState, kind: String) -> Bool {
        let old = WidgetState.load()
        guard state.save() else { return false }
        requestReload(kind: kind, minor: old.map { state.isMinorChange(from: $0) } ?? false)
        return true
    }

    private func requestReload(kind: String, minor: Bool) {
        let now = Date.now
        let wait = Self.delay(since: lastReload, now: now, minor: minor)
        guard wait > 0 else {
            reload(kind: kind)
            return
        }
        // それより早い読み直しを待っていれば、それに任せる（ウィジェットは読み直すときに、いちばん新しい中身を読む）
        let due = now.addingTimeInterval(wait)
        if let waitingUntil, waitingUntil <= due { return }
        waiting?.cancel()
        waitingUntil = due
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.reload(kind: kind)
        }
    }

    private func reload(kind: String) {
        waiting?.cancel()
        waiting = nil
        waitingUntil = nil
        lastReload = .now
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        // 「LifeLog のやること」も同じ中身を読む（2026-11-10）
        if kind == WidgetState.phoneKind {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetState.tasksKind)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetState.goodKind)  // 「LifeLog のいいこと帳」も（2026-11-12）
        }
    }

    /// 前に読み直してもらってから、あと何秒待つか（0 なら今すぐ読み直してもらえる）
    nonisolated static func delay(since last: Date, now: Date, minor: Bool = false) -> TimeInterval {
        max(0, (minor ? minorInterval : interval) - now.timeIntervalSince(last))
    }
}

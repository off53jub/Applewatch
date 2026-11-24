import Foundation
import WidgetKit

// s26 の 絵8（ウィジェットを絞る前に、使われた数を数える。A3・S26D。2026-11-25）。
// 家の PC に届く数（tally）に、ウィジェットの数は今まで 1 つも無かった。数が無いうちは消さず、並びだけ変えた（LifeLogWidgets.swift）。
// - 置かれている数: 1 日 1 回、アプリを開いたときに「いまホーム画面・ロック画面に置かれているウィジェット」を数える（s26d.widget.<名>.<大きさ>）
// - 押された数: ウィジェットのリンクに付けた ?w=<名> を、開いたときに数える（s26d.widgetTap.<名>）
// 何も送らない・何も消さない。数は今までの tally と同じ道で家の PC に届く。初めはオン。
enum S26DWidgetUse {
    private static let lastKey = "s26dWidgetCountDay"

    /// 1 日 1 回だけ、置かれているウィジェットを数える
    static func countInstalled(now: Date = .now) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        guard UserDefaults.standard.string(forKey: lastKey) != today else { return }
        UserDefaults.standard.set(today, forKey: lastKey)
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success(let infos) = result else { return }
            if infos.isEmpty {
                Tally.add("s26d.widget.none")
                return
            }
            for info in infos {
                Tally.add(S26DWidgetRules.installedName(kind: info.kind, family: "\(info.family)"))
            }
        }
    }

    /// ウィジェットから開かれたら数える（?w= の無いリンクは数えない）
    static func noteOpen(_ url: URL) {
        guard let w = S26DWidgetRules.source(of: url) else { return }
        Tally.add("s26d.widgetTap." + w)
    }
}

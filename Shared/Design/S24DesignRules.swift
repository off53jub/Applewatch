import Foundation

// s24 のデザインの決まり（形8。2026-11-24）。純粋な関数だけ（色は LifeLog/S24Views.swift）。
// 色の役割を 3 つにする: 赤＝いま本人が動く・青＝機械が進めている・灰＝待てば直る。問いには色を付けない（宿題に見えないように）。
// s22 の 見7（LLTone。赤は本人が動くものだけ・待てば直るものは灰）の続き。テストは LifeLogTests/S24TodayTests.swift。

enum LLRole: String, CaseIterable, Sendable {
    /// いま本人が動く（赤）
    case act
    /// 機械が進めている（青）
    case machine
    /// 待てば直る（灰）
    case wait
    /// 問い（色を付けない）
    case ask

    /// 画面と読み上げの言葉
    var label: String {
        switch self {
        case .act: "いま動く"
        case .machine: "機械が進めている"
        case .wait: "待てば直る"
        case .ask: "問い"
        }
    }

    /// s22 の 見7 の色の意味から（良い・Claude に頼む は機械が進めている。気をつけたい・直し方が分からないは本人が見る）
    static func of(_ tone: LLTone) -> LLRole {
        switch tone {
        case .act, .warn: .act
        case .ok, .claude: .machine
        case .wait, .unknown: .wait
        }
    }
}

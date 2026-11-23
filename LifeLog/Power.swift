import UIKit

/// 電池の様子。低電力モードで充電していないときは、電池を優先して重い処理を減らす。
@MainActor
enum Power {
    /// 充電中かどうかを読めるようにする（アプリの起動時に一度呼ぶ）
    static func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    static var isCharging: Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }

    /// 電池を優先するとき。iPhone の Haas-ja を動かさず、家の PC かクラウドに回す（夜の聞き直しで取り戻す）。
    /// 2026-11-23: iPhone が熱いあいだも（設定「熱いときは重い仕事を休ませる」。初めはオン。s23 の 止14。S23Resume.swift）
    static var isSaving: Bool {
        (ProcessInfo.processInfo.isLowPowerModeEnabled && !isCharging) || S23PhoneBook.hotNow
    }
}

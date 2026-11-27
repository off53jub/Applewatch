#if DEBUG && targetEnvironment(simulator)
import Foundation

// s34（2026-11-27）K34-1 の見本（画面の自動撮影用。S34AViews.swift）。中身はすべて作りもの（実在の人・会社・案件ではない）。
// 家の PC の写しと同じ置き場（Application Support/S34A/s34.json）に書き、"s34" を持っている PC とつながったことにする。
// 円1（写真から拾う）は、シミュレーターに職場の画面の写真が無いので見本は無い（設定のスイッチだけ写る）。
extension DemoData {
    static func installS34A(base: URL, now: Date) {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func d(_ offset: Int) -> String {
            f.string(from: cal.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        let iso = ISO8601DateFormatter()
        let tomorrow10: Date = cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now) ?? now) ?? now
        let at = iso.string(from: tomorrow10)
        let json = """
        {"version":1,
         "self_fixed":{"week":"\(d(-6))","speaker":{"fixed":41,"left":9,"undone":2},"reopened":{"solved":57,"left":120},
                       "vocab":{"adopted":6,"dropped":1},"work":{"solved":18,"left":12},"place":{"before":0,"after":0.5,"why":"見本"}},
         "auto_switch":[{"name":"demo_day_split","state":"on","since":"\(d(-3))","metric":"agree","now":0.82,"prev":0.74},
                        {"name":"demo_points","state":"shadow","since":"\(d(-5))","metric":"agree","now":0.7,"prev":0.71},
                        {"name":"demo_old","state":"rolled_back","since":"\(d(-1))","metric":"agree","now":0.6,"prev":0.66}],
         "tuned":[{"name":"demo_days","old":2,"new":3,"range":[1,5],"why":"見本"},{"name":"demo_close","old":14,"new":14,"range":"7-21","why":"見本"}],
         "reflow":{"days_done":12,"days_left":18,"last_day":"\(d(-12))"},
         "guide_run":{"last_ok":"\(d(-4))","by":"subscription","misses_used":3,"rules_added":2},
         "healed":[{"source":"demo_card","what":"見本の集計を作り直した","at":"\(d(-2))","ok":true},
                   {"source":"demo_health","what":"見本の書き出しを取り直した","at":"\(d(-1))","ok":false}],
         "prompt":{"day":"\(d(0))","text":"\(d(0)) の見本の頼み方です。下の形だけで答えてください。\\n【日付】\(d(0))\\n【決まったこと】\\n・…","parts":["今日のまとめ","AI からの質問 2","足りない土台 1"]},
         "nudges":[{"id":"s34n-demo1","topic":"見本の画面の項目の並び","who":"見本 次郎","days":4,"next":"見本 次郎さんに並びの案を見たか聞く",
                    "draft":"お疲れさまです。先日お送りした見本の並びの案、ご覧いただけましたでしょうか。"},
                   {"id":"s34n-demo2","topic":"見本の帳票の数の合わせ","who":"見本 三郎","days":3,"next":"見本の数の出どころを確かめてもらう",
                    "draft":"見本の帳票の数について、出どころを一度ご確認いただけますか。"}],
         "prep":[{"meeting":"見本の定例","at":"\(at)","last_decided":["見本の画面は来週から試す"],"my_tasks":["見本の項目一覧（7 割）"],
                  "likely_asked":["見本の試しの日程","見本の不可 5 件の中身"],"self_check":["表の数に出どころを書いたか（見本）"]}],
         "tests":{"total":300,"done":182,"ng":5,"waiting":11,"today":14,"finish_guess":"\(d(9))"}}
        """
        let dir = base.appendingPathComponent("S34A", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: dir.appendingPathComponent("s34.json"), options: .atomic)
        UserDefaults.standard.set(true, forKey: S34ABook.offeredKey)
    }
}
#endif

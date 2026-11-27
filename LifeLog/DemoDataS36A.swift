#if DEBUG && targetEnvironment(simulator)
import Foundation

// s36（2026-11-28）K36-1 の見本（画面の自動撮影用。S36AViews.swift）。中身はすべて作りもの（実在の人・会社・案件ではない）。
// 公開のリポジトリなので、名前は「見本の案件 A」「見本さん」、番号は「W-001」だけを使う。
// 家の PC の写しと同じ置き場（Application Support/S36A/s36.json）に書き、"s36" などを持っている PC とつながったことにする。
extension DemoData {
    static func installS36A(base: URL, now: Date) {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func d(_ offset: Int) -> String {
            f.string(from: cal.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        let json = """
        {"version":1,"generated_at":"\(d(0))T06:00:00+09:00",
         "prompt":{"setup":"見本の置く文です。見本の案件 A のまとめを、いつもの形で答えてください。最後に【済んだ番号】を付けてください。",
                   "setup_version":"\(d(0))-1","daily":"まとめ W-001",
                   "open_refs":[{"ref":"W-001","text":"見本の案件 A の画面の並びを見本さんに確かめる"}]},
         "cases":{"as_of":"\(d(0))","total":300,"done":182,"ng":5,"waiting":11,"left":118,"per_day":14,"eta":"\(d(9))",
                  "eta_note":"見本の数から","evidence_missing":[{"ref":"W-001","text":"見本の案件 A の画面の写しが無い"}],
                  "by_area":[{"area":"見本の区分","total":120,"done":80},{"area":"見本の区分 2","total":180,"done":102}]},
         "bugs":{"as_of":"\(d(0))","open":1,"closed":3,
                 "items":[{"ref":"W-001","text":"見本の案件 A の画面で数が合わない","state":"open","who":"見本さん","day":"\(d(-1))"}]},
         "ledger":{"open":12,"closed_7d":4,"folded":2,"closed_by_reply_7d":1},
         "stop":{"items":[{"id":"demo-stop-1","kind":"build","title":"見本の作り直し","why":"見本の画面のための 15 分ごとの作り直し",
                           "saves":"15 分の回が 3 秒ほど軽くなる（見本）","state":"candidate"},
                          {"id":"demo-stop-2","kind":"claude","title":"見本の Claude の頼み","why":"見本のまとめを毎晩作る頼み",
                           "saves":"月 $1 ほど（見本）","state":"kept"}]},
         "nav":{"settings_top":["detailedSettings","diagnostics","くわしい設定"]}}
        """
        let dir = base.appendingPathComponent("S36A", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: dir.appendingPathComponent("s36.json"), options: .atomic)
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: S36ABook.offeredKey)
        defaults.set(S36ARules.remembered, forKey: S36ABook.featuresKey)
        // 前の版を写したことにする（「置き直してください」の帯を写す）
        defaults.set(d(-1) + "-1", forKey: S36ABook.copiedKey)
        defaults.set(now, forKey: S36ABook.fetchedKey)
    }
}
#endif

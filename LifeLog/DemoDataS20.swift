#if DEBUG && targetEnvironment(simulator)
import Foundation

/// 画面の自動確認（CI）用の s20 の見本（2026-11-21）。名前・お店・言葉はすべて作り物。
/// 家の PC から届いたことにする写し（確かめ待ちの列・検品表・実機の確かめ・休日の札）と、知らせの履歴。
/// 面談の 1 枚の見本は 2026-11-27（s30）に画面ごと外した。
extension DemoData {
    static func installS20(base: URL, now: Date) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today: String = f.string(from: now)
        let soon: String = f.string(from: now.addingTimeInterval(2 * 86400))
        let later: String = f.string(from: now.addingTimeInterval(12 * 86400))
        let review: String = """
        {"version":1,"generated_at":"\(today)T06:00:00+09:00","items":[
         {"id":"rq-ramen-1","kind":"ramen","question":"昨日の 12:40、見本の麺屋でラーメンを食べましたか？","answer":"yesno",
          "evidence":[{"text":"「このスープうまいね」（見本の会話）","ref":"\(today) 12:41"},{"text":"見本の麺屋に 35 分いた","ref":"場所"}],
          "expires":"\(soon)"},
         {"id":"rq-with-1","kind":"with_people","question":"見本 花子さんと一緒にいましたか？","answer":"yesno","group":"with-hanako",
          "evidence":[{"text":"同じ時間に声が 6 行","ref":"\(today) 10:02"}],"expires":"\(later)"},
         {"id":"rq-with-2","kind":"with_people","question":"見本 花子さんと一緒にいましたか？","answer":"yesno","group":"with-hanako",
          "evidence":[{"text":"同じ時間に声が 4 行","ref":"\(today) 15:30"}],"expires":"\(later)"},
         {"id":"rq-name-1","kind":"name","question":"人物12 はだれですか？","answer":"pick","choices":["見本 太郎","見本 次郎","知らない人"],
          "clips":[{"label":"声 A","path":"voice/clip?demo=a"},{"label":"声 B","path":"voice/clip?demo=b"}],"expires":"\(later)"},
         {"id":"rq-place-1","kind":"place","question":"16:00 にいた所の名前は？","answer":"text","expires":"\(later)"}
        ],"done":[{"id":"rq-old-1","changed":3}]}
        """
        let features: String = """
        {"generated_at":"\(today)T05:00:00+09:00","items":[
         {"id":"s18-01","name":"朝の気分の 1 タップ","group":"s18","alive":true,"used":14,"hit":0.8,"suggest":"keep"},
         {"id":"s18-02","name":"今週の見立て","group":"s18","alive":true,"used":3,"suggest":"watch"},
         {"id":"s19-08","name":"時計の外出モード","group":"s19","alive":true,"used":0,"suggest":"stop"},
         {"id":"s19-21","name":"さっきの所は？","group":"s19","alive":true,"used":6,"hit":0.6,"suggest":"keep"},
         {"id":"s19-34","name":"映画館で休む","group":"s19","alive":false,"used":0,"suggest":"watch"},
         {"id":"s20-16","name":"朝夕の便り","group":"s20","alive":true,"used":11,"suggest":"keep"}
        ]}
        """
        let checks: String = """
        {"generated_at":"\(today)T05:00:00+09:00","checks":[
         {"id":"alarm","name":"アラームのあとの録音","ok":true,"note":"中断 2 回・戻れた 2 回","day":"\(today)"},
         {"id":"away","name":"外出モードの電池","ok":null,"note":"まだ比べられるほど無い","day":"\(today)"},
         {"id":"holiday","name":"休日の知らせが届いたか","ok":false,"note":"21:00 の知らせが届いていない","day":"\(today)"}
        ]}
        """
        let tags: String = """
        {"_meta":{"version":1},"\(today)":[{"tag":"ラーメン","confidence":0.7},{"tag":"ドライブ","confidence":0.6},{"tag":"写真多め","confidence":0.5}]}
        """
        let files: [(String, String)] = [("app-feed-reviewq.json", review), ("app-feed-featcheck.json", features),
                                         ("app-feed-devchecks.json", checks), ("app-feed-holidaytags.json", tags)]
        for (name, text) in files {
            try? text.data(using: .utf8)?.write(to: base.appendingPathComponent(name), options: .atomic)
        }
        // 知らせの履歴（7 日分の見本）
        var notices: [NoticeLogEntry] = []
        let kinds: [(String, String, Bool)] = [("fresh", "止まっているかも: 見本の取り込み", false), ("proposal", "見本の提案が 1 つ", true),
                                               ("taskDue", "見本の資料の期限まで 1 時間", false), ("holiday", "今日いちばんよかった瞬間は？", true),
                                               ("brief", "朝のまとめ（見本）", false)]
        for (i, k) in kinds.enumerated() {
            var e = NoticeLogEntry(id: "demo-n\(i)", kind: k.0, title: k.1, at: now.addingTimeInterval(-Double(i) * 5400), held: k.2)
            if i == 0 { e.opened = true }
            notices.append(e)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(notices) {
            try? data.write(to: base.appendingPathComponent("s20-notices.json"), options: .atomic)
        }
        UserDefaults.standard.set(true, forKey: SceneKey.noticeDigest.rawValue)
    }
}
#endif

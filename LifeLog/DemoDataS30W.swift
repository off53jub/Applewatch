#if DEBUG && targetEnvironment(simulator)
import Foundation

// s30（2026-11-27）仕事タブの見本の写し（画面の自動撮影用。S30WViews.swift）。
// 案件・人・言葉はすべて作りもの（実在の人・会社・案件ではない）。家の PC の写しと同じ置き場（Application Support/S27W/work.json）に書く。
// 起動の引数に -s30wNoReport があれば report の無い前の形（「機械の並べ方」）で書く。
extension DemoData {
    static func installS30W(base: URL, now: Date) {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func d(_ offset: Int) -> String {
            f.string(from: cal.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        let iso = ISO8601DateFormatter()
        let written = iso.string(from: now.addingTimeInterval(-3600))
        let noReport = ProcessInfo.processInfo.arguments.contains("-s30wNoReport")
        let report = noReport ? "" : ",\"report\":" + demoReport(d: d, written: written)
        let json = demoBoard(d: d, written: written) + report + "}"
        let dir = base.appendingPathComponent("S27W", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: dir.appendingPathComponent("work.json"), options: .atomic)
        UserDefaults.standard.set(true, forKey: S27WBook.offeredKey)
    }

    /// K2 の形（閉じかっこは呼ぶ側で付ける）
    private static func demoBoard(d: (Int) -> String, written: String) -> String {
        """
        {"version":1,"as_of":"\(d(0))","generated_at":"\(written)",
         "counts":{"homework_today":2,"open_mine":8},
         "today":{"homework":[],"meetings":[]},
         "projects":[
          {"id":"wp-demo0001","name":"見本の大きい案件","client":"見本商事","kind":"mine","last_moved":"\(d(-1))",
           "status_line":"見本の受け入れの確かめは終盤",
           "progress":[{"day":"\(d(-3))","label":"済","value":120},{"day":"\(d(-2))","label":"済","value":131},
                       {"day":"\(d(-1))","label":"済","value":144},{"day":"\(d(-1))","label":"残り","value":6}],
           "items":[{"id":"wd-a1","kind":"decided","text":"見本の週次の報告は数え方をそろえる","day":"\(d(-2))","src":"plaud"}]},
          {"id":"wp-demo0002","name":"見本の打鍵","kind":"mine","parent":"wp-demo0001","parent_name":"見本の大きい案件","last_moved":"\(d(-1))",
           "items":[
            {"id":"wd-b1","kind":"homework","text":"打鍵できなかった見本の項目のテストを頼む","due":"\(d(0))","ball":"me","age_days":1,"day":"\(d(-1))","time":"10:20","src":"talk","who":"見本 花子"},
            {"id":"wd-b2","kind":"homework","text":"打てるようになった見本のシナリオを洗い出し、エビデンスを貼る","ball":"me","age_days":2,"day":"\(d(-2))","src":"plaud"},
            {"id":"wd-b3","kind":"open","text":"見本の打鍵の 2 回目を仕切ってもらう","ball":"them","due":"\(d(0))","age_days":1,"day":"\(d(-1))","src":"talk"},
            {"id":"wd-b4","kind":"homework","text":"見本の打鍵済みの確かめ","ball":"me","age_days":5,"day":"\(d(-5))","src":"talk",
             "auto":"done","auto_why":"\(d(-1)) の会話で済んだと出ました（見本）"},
            {"id":"wd-b5","kind":"homework","text":"見本のキャプチャを表に貼る","ball":"me","age_days":9,"day":"\(d(-9))","src":"talk",
             "auto":"old","auto_why":"7 日ほど話に出ていません（見本）"},
            {"id":"wd-b6","kind":"open","text":"見本のやり直す分の数を決める","ball":"me","age_days":7,"day":"\(d(-7))","src":"plaud"},
            {"id":"wd-b7","kind":"homework","text":"見本の打鍵の表を最新にする","ball":"me","age_days":3,"day":"\(d(-3))","src":"talk"},
            {"id":"wd-b8","kind":"open","text":"見本の打鍵の担当を分けるか","age_days":4,"day":"\(d(-4))","src":"talk"},
            {"id":"wd-b10","kind":"homework","text":"見本の打鍵の残りを数える","ball":"me","age_days":6,"day":"\(d(-6))","src":"plaud"}],
           "timeline":[{"id":"wd-b9","kind":"decided","text":"見本のケースを正常に終わる形に直して進める","day":"\(d(-1))","time":"10:00","src":"plaud"}]},
          {"id":"wp-demo0003","name":"見本の不具合","kind":"mine","parent":"wp-demo0001","last_moved":"\(d(-1))",
           "items":[
            {"id":"wd-c1","kind":"issue","text":"見本の氏名の文字数の不具合","ball":"me","age_days":2,"day":"\(d(-2))","src":"talk"},
            {"id":"wd-c2","kind":"issue","text":"見本の初めの値が入らない不具合の直し","ball":"them","due":"\(d(3))","age_days":2,"day":"\(d(-2))","src":"plaud"},
            {"id":"wd-c3","kind":"issue","text":"見本の古いチケットを閉じてよいか確かめる","ball":"me","age_days":8,"day":"\(d(-8))","src":"talk"}]},
          {"id":"wp-demo0004","name":"見本のカード","kind":"mine","parent":"wp-demo0001","last_moved":"\(d(-1))",
           "milestone":{"day":"\(d(2))","title":"見本のカードを借りる"},
           "items":[
            {"id":"wd-d1","kind":"open","text":"見本のカードを貸してもらえるかの返事","ball":"them","age_days":3,"day":"\(d(-3))","src":"talk"},
            {"id":"wd-d2","kind":"homework","text":"見本のカードの使い方を確かめる","ball":"me","age_days":1,"day":"\(d(-1))","src":"talk"}]},
          {"id":"wp-demo0005","name":"見本の日程","kind":"mine","parent":"wp-demo0001","last_moved":"\(d(0))",
           "milestone":{"day":"\(d(9))","title":"見本の判定会"},
           "items":[
            {"id":"wd-e1","kind":"homework","text":"見本の締めの日を相手に伝える","ball":"me","due":"\(d(1))","age_days":1,"day":"\(d(-1))","src":"talk"},
            {"id":"wd-e2","kind":"open","text":"見本の終わりの日が決まるかの返事","ball":"them","due":"\(d(5))","due_guess":true,"age_days":2,"day":"\(d(-2))","src":"plaud"}],
           "timeline":[{"id":"wd-e9","kind":"decided","text":"見本の直しは最優先、ほかは来月の頭までで可","day":"\(d(-1))","time":"15:00","src":"plaud"}]},
          {"id":"wp-demo0006","name":"よその見本の定例","kind":"other","last_moved":"\(d(-2))",
           "items":[{"id":"wd-f1","kind":"homework","text":"よその見本の資料を読む","ball":"me","age_days":2,"day":"\(d(-2))","src":"notice"}]},
          {"id":"wc-misc","name":"まだ案件に分けていないもの","kind":"mine",
           "items":[{"id":"wd-m1","kind":"open","text":"見本の画面の文言をそろえる","ball":"me","age_days":1,"day":"\(d(-1))","src":"talk"},
                    {"id":"wd-m2","kind":"open","text":"見本の別の検討の話","age_days":2,"day":"\(d(-2))","src":"chat"}]}],
         "people":[{"id":"wm-demo0001","name":"見本 花子","team":"見本チーム","org":"client","projects":["wp-demo0001"]}]
        """
    }

    /// K30-1 の report（Claude が書いた見本の文。中身は作りもの）
    private static func demoReport(d: (Int) -> String, written: String) -> String {
        """
        {"as_of":"\(d(0))","written_at":"\(written)","by":"claude",
         "projects":[{"id":"wp-demo0001","name":"見本の大きい案件","state":"caution",
           "now":"見本の確かめは終盤です。止まっていた見本のシナリオが打てるようになり、打ち直しに入っています。",
           "moved":"この 3 日で、見本のケースを正常に終わる形に直して進める方針になりました。直しは最優先、ほかは来月の頭までで可。",
           "snag":"見本の終わりの日がまだ決まっていません。見本のカードを借りられるかは返事待ちです。",
           "evidence":["wd-b9","wd-e9","wd-b1","wd-e2","wd-d1"],
           "numbers":[{"label":"済","value":120,"unit":null,"day":"\(d(-3))","heard":true},
                      {"label":"済","value":131,"unit":null,"day":"\(d(-2))","heard":true},
                      {"label":"済","value":144,"unit":null,"day":"\(d(-1))","heard":true},
                      {"label":"残り","value":6,"unit":null,"day":"\(d(-1))","heard":true}],
           "road":[{"day":"\(d(0))","title":"見本の会議","firm":true},{"day":"\(d(2))","title":"見本のカード","firm":true},
                   {"day":"\(d(4))","title":"見本の終わり","firm":false},{"day":"\(d(9))","title":"見本の判定会","firm":true},
                   {"day":"\(d(12))","title":"見本の締め","firm":true},{"day":"\(d(30))","title":"見本の開放","firm":true}]}],
         "pillars":[
          {"id":"test","project":"wp-demo0001","name":"テストの進み（打鍵）","state":"mine",
           "line":"見本の打ち直しに入りました。打鍵済みの確かめと、エビデンスを貼って閉じる作業が残っています。","topic_ids":["wp-demo0002"],"item_ids":[]},
          {"id":"bug","project":"wp-demo0001","name":"不具合とチケット","state":"mine",
           "line":"見本の不具合が 2 つ新しく出ています。古いチケットは閉じてよいかを確かめる時期です。","topic_ids":["wp-demo0003"],"item_ids":[]},
          {"id":"card","project":"wp-demo0001","name":"テスト用のカード","state":"theirs",
           "line":"見本のカードは先方の返事待ちです。","topic_ids":["wp-demo0004"],"item_ids":[]},
          {"id":"plan","project":"wp-demo0001","name":"日程と節目","state":"urgent",
           "line":"見本の締めは明日です。終わりの日はまだ決まっていません。","topic_ids":["wp-demo0005"],"item_ids":[]},
          {"id":"spec","project":"wp-demo0001","name":"仕様と画面の決めごと","state":"calm",
           "line":"見本の文言の方針が出ました。","topic_ids":[],"item_ids":["wd-m1"]},
          {"id":"talk","project":"wp-demo0001","name":"報告・会議","state":"calm",
           "line":"見本の週次の数え方は決まりました。","topic_ids":[],"item_ids":["wd-a1"]}],
         "next3":[{"item_id":"wd-b1","why":"今日まで"},{"item_id":"wd-e1","why":"明日まで"},{"item_id":"wd-b2","why":"2 日そのまま"}],
         "waiting3":[{"item_id":"wd-b3","why":"今日まで"},{"item_id":"wd-d1","why":"3 日"},{"item_id":"wd-c2"}],
         "outside":[{"label":"ほかの部署・社内の話","item_ids":["wd-f1"]},{"label":"まだどの柱にも入らないもの","item_ids":["wd-m2"]}]}
        """
    }
}
#endif

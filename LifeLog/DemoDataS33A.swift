#if DEBUG && targetEnvironment(simulator)
import Foundation

// s33（2026-11-27）K33-1 の見本（画面の自動撮影用。S33AViews.swift）。中身はすべて作りもの（実在の人・店・会社・案件ではない）。
// 家の PC の写しと同じ置き場（Application Support/S33A/s33.json）に書き、"s33" を持っている PC とつながったことにする。
// 話のネタは S30W の見本の人（wm-demo0001）に付ける。年のまとめは 12 月だけ画面に出る。
extension DemoData {
    static func installS33A(base: URL, now: Date) {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func d(_ offset: Int) -> String {
            f.string(from: cal.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        let month = String(d(0).prefix(7))
        let year = cal.component(.year, from: now)
        let json = """
        {"version":1,
         "stopped":[{"source":"見本の入口（AI との会話の書き出し）","last_ok":"\(d(-19))","missing":"1 日 1 件の会話","why":"本人の書き出しが要る入口（見本）"}],
         "waiting":[{"id":"s33w-demo1","title":"見本: 家の PC の Claude Code にログイン","how":"家の PC で「claude」を開き、画面の案内どおりにログインする（見本）","since":"\(d(-1))","kind":"login"}],
         "tasks":{"total":87,"stop_candidates":[{"name":"見本の 1 分ごとの見張り","why":"作った物を 30 日だれも読んでいない（見本）","cpu_s":5400,"last_read":"\(d(-30))"}]},
         "effects":[{"bundle":"名前の無い人","metric":"名前の無い声の割合（%）","now":31,"prev":36}],
         "bets":[{"name":"見本の競馬 AI","hypothesis":"見本の条件ではまだ勝てる","stop_if":"3 か月続けて回収率 80% を下回る","month":{"stake":12000,"payout":9600,"runs":24},"alive":true}],
         "disk":{"c_free_gb":85,"c_free_pct":9.1,"growth":[{"what":"ドライブの写し（見本）","gb":12.5},{"what":"録音（見本）","gb":4}]},
         "small_talk":[{"person_id":"wm-demo0001","name":"見本 花子","lines":["前に見本の旅行の話をしていた","見本のコーヒー店が好き","先週、見本の資格に受かった"],"updated":"\(d(-1))"}],
         "speaking":{"week":"\(d(-6))","meetings":[{"title":"見本の定例","my_share":0.38,"overlaps":2,"long_runs":1},{"title":"見本の打ち合わせ","my_share":0.12,"overlaps":0,"long_runs":0}]},
         "review_rules":[{"type":"数の根拠","count":4,"check":"表の数に出どころを書いたか（見本）"},{"type":"言葉のゆれ","count":2,"check":"同じものを同じ言葉で書いたか（見本）"}],
         "side_hours":{"month":"\(month)","days":[{"day":"\(d(-2))","minutes":95,"overlap_work":false},{"day":"\(d(-1))","minutes":40,"overlap_work":false}]},
         "expenses":[{"day":"\(d(-3))","shop":"見本のサーバー代","amount":1280,"why":"見本のサイトのサーバー","src":"mail"}],
         "ramen":{"year":\(year),"bowls":13,"yardstick":200,"coverage":0.065,"recent":[{"day":"\(d(-4))","shop":"見本の麺屋","how":"位置と支払い"}]},
         "car":[{"day":"\(d(-5))","from":"見本の駅","to":"見本の県","hours":9,"yen":8800,"station":"見本のステーション"}],
         "year":{"year":\(year),"sections":[{"title":"会った人（見本）","lines":["いちばん多く話した人: 見本 花子"]},{"title":"食べた数（見本）","lines":["ラーメン 13 杯（拾えた分）"]}]},
         "wishes":[{"text":"見本: 写真から食べた物を数える","day":"\(d(-2))","said":"家でひとりごと"}],
         "promises_kept":{"kept":12,"closed":25},
         "ask_check":{"week":"\(d(-6))","score":16,"total":20}}
        """
        let dir = base.appendingPathComponent("S33A", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: dir.appendingPathComponent("s33.json"), options: .atomic)
        UserDefaults.standard.set(true, forKey: S33ABook.offeredKey)
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
import Foundation

// s31（2026-11-27）文字と声の結びの見本（画面の自動撮影用。S31AViews.swift）。
// 人・案件・言葉・部屋はすべて作りもの（実在の人・会社・案件・LINE ではない）。
// - 仕事の写し（S27W/work.json。DemoDataS30W.swift が書いたもの）の項目のいくつかに voice を足す
// - /links の答えの写し（S31A/。S31ABook と同じ置き場）を「見本 花子」さんと今日の分だけ書く
// 声の時刻は DemoData の朝の打ち合わせ（見本）の会話に合わせる（押すとその会話が開く）。
extension DemoData {
    static func installS31A(base: URL, now: Date, talkStart: Date) {
        let iso = ISO8601DateFormatter()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: now)
        let say1 = iso.string(from: talkStart.addingTimeInterval(8))
        let say2 = iso.string(from: talkStart.addingTimeInterval(20))
        let end = iso.string(from: talkStart.addingTimeInterval(240))
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.dateFormat = "HH:mm"
        let at = hm.string(from: talkStart.addingTimeInterval(-600))
        let at2 = hm.string(from: talkStart.addingTimeInterval(900))

        // 1. 仕事の項目に voice（K31-1 の K2 の形）
        let voices: [String: [[String: Any]]] = [
            "wd-b1": [["link": "ln-demo0001", "conv": "demo-talk-1", "start": say1, "who": ["見本 花子"], "say": "見本の項目のテストは今日中に頼みます。"]],
            "wd-b3": [["link": "ln-demo0002", "conv": "demo-talk-1", "start": say2, "who": ["自分"], "say": "2 回目の打鍵は見本さんに仕切ってもらいます。"],
                      ["link": "ln-demo0001", "conv": "demo-talk-1", "start": say1, "who": ["見本 花子"], "say": "見本の打鍵の 2 回目の話。"]],
            "wd-c1": [["conv": "demo-talk-1", "start": say1, "who": ["見本 花子"], "say": "氏名の文字数の見本の不具合が出ています。"]],
        ]
        let workURL = base.appendingPathComponent("S27W", isDirectory: true).appendingPathComponent("work.json")
        if let data = try? Data(contentsOf: workURL),
           var board = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var projects = board["projects"] as? [[String: Any]] {
            for p in projects.indices {
                for field in ["items", "timeline"] {
                    guard var items = projects[p][field] as? [[String: Any]] else { continue }
                    for i in items.indices {
                        if let id = items[i]["id"] as? String, let v = voices[id] { items[i]["voice"] = v }
                    }
                    projects[p][field] = items
                }
            }
            board["projects"] = projects
            if let out = try? JSONSerialization.data(withJSONObject: board) {
                try? out.write(to: workURL, options: .atomic)
            }
        }

        // 2. /links の答えの写し（K31-1 の形を絞ったもの）
        let links = """
        {"version":1,"generated_at":"\(iso.string(from: now))","days":["\(day)"],
         "links":[
          {"id":"ln-demo0001","day":"\(day)",
           "text":{"src":"teams","ref":"\(day)#自分の宿題#1","kind":"homework","who":["見本 花子"],"at":"\(at)","room":null,
                   "quote":"打鍵できなかった見本の項目のテストを頼む"},
           "voice":{"conv":"demo-talk-1","start":"\(say1)","end":"\(end)","speakers":["見本 花子","自分"],
                    "lines":[{"t":"\(say1)","who":"見本 花子","say":"はい、お昼までに送ります。"}]},
           "score":0.86,"by":"rules","why":"同じ言葉「見本の資料」と時刻が近い","work":true,"item_ids":["wd-b1"]},
          {"id":"ln-demo0002","day":"\(day)",
           "text":{"src":"line","ref":"\(day)#見本の部屋#\(at2)#1","kind":"message","who":["見本 花子"],"at":"\(at2)","room":"見本の部屋",
                   "quote":"会議室、3 時からで取っておきました（見本）"},
           "voice":{"conv":"demo-talk-1","start":"\(say2)","end":"\(end)","speakers":["自分"],
                    "lines":[{"t":"\(say2)","who":"自分","say":"ありがとうございます。会議は3時からです。"}]},
           "score":0.62,"by":"claude","why":"会議室と 3 時の話","work":false,"item_ids":[]}],
         "people":[{"name":"見本 花子","person_id":"pp-demo000000001","days":["\(day)"],"text_n":2,"voice_n":2,
                    "summary":"Teams では見本の項目のテストを頼まれていて、LINE では会議室を取ってくれました（見本）。声では、朝の打ち合わせで資料をお昼までに送る話をしていました。",
                    "link_ids":["ln-demo0001","ln-demo0002"]}]}
        """
        let dir = base.appendingPathComponent("S31A", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for key in [S31ABook.personKey("見本 花子"), S31ABook.dayKey(day)] {
            try? Data(links.utf8).write(to: dir.appendingPathComponent(S31ABook.fileName(key)), options: .atomic)
        }
        UserDefaults.standard.set(true, forKey: S31ABook.offeredKey)
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
import Foundation

// s32（2026-11-27）AI の理解の見本（画面の自動撮影用。S32AViews.swift）。
// 言葉・人・仕組み・番号・決まったことはすべて作りもの（実在の人・会社・案件・仕組みではない）。
// - 仕事の写し（S27W/work.json。DemoDataS30W.swift が書いたもの）に K32-2 の鍵（glossary・org・systems・numbering・
//   decisions・threads・quiz・scorecard・guide）を足す
// - 「違う」を 1 つ押した見本（まだどの柱にも入らない話を「自分の番ではない」）を端末の覚えに書く
extension DemoData {
    static func installS32A(base: URL, now: Date) {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func d(_ offset: Int) -> String {
            f.string(from: cal.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        let iso = ISO8601DateFormatter()
        let written = iso.string(from: now.addingTimeInterval(-6 * 3600))
        let know = """
        {"glossary":[
          {"term":"打鍵","meaning":"テストの手順どおりに画面を操作して、結果を確かめること（見本）。","team":"見本チーム・見本の画面",
           "days":7,"sample_ids":["wd-b1","wd-b3","wd-b4"],"voice_says":["だけん","打鍵の 2 回目"],"firm":true},
          {"term":"エビデンス","meaning":"確かめた証拠の画面の写し。表に貼って残す（見本）。","team":"見本チーム","days":4,
           "sample_ids":["wd-b2"],"voice_says":["エビ"],"firm":false},
          {"term":"シナリオ","meaning":"テストで試す、一続きの操作の筋書き（見本）。","days":3,"sample_ids":["wd-b2"],"firm":false},
          {"term":"キャプチャ","days":2,"sample_ids":["wd-b5"],"firm":false}],
         "org":[
          {"id":"wm-demo0001","name":"見本 花子","team":"見本チーム","role":"テストの取りまとめ（見本）","with_me":"asked","last":"\(d(-1))","firm":true},
          {"name":"見本 太郎","team":"見本チーム","role":"不具合の直し（見本）","with_me":"ask","last":"\(d(-2))","firm":false},
          {"name":"見本 次郎","team":"見本の先方","with_me":"both","firm":false},
          {"name":"見本 三郎","firm":false}],
         "systems":{"nodes":[{"id":"n1","name":"見本の申込","team":"見本チーム"},{"id":"n2","name":"見本の審査"},
                             {"id":"n3","name":"見本の開設"},{"id":"n4","name":"見本の連携先"},{"id":"n5","name":"見本の帳票"}],
                    "edges":[{"from":"n1","to":"n2","what":"申込の中身（見本）"},{"from":"n2","to":"n3","what":"審査の結果"},
                             {"from":"n3","to":"n4","what":"開設の知らせ"}],
                    "stuck":["n3"]},
         "numbering":[
          {"no":"ST-012","what":"見本の申込から開設まで","owner":"自分","state":"待ち","why":"見本のカードの返事待ち","days":5},
          {"no":"ST-031","what":"見本の氏名の文字数","owner":"見本 太郎","state":"不可","why":"見本の不具合","days":3},
          {"no":"#108","what":"見本の初めの値が入らない","owner":"見本 太郎","state":"直し中","days":2},
          {"no":"ST-040","what":"見本の帳票の出力","state":"済"}],
         "decisions":[
          {"id":"dc1","day":"\(d(-6))","text":"見本の打ち直しは来週から","who":"見本 花子","why":"見本の環境の都合","flipped_by":"dc2"},
          {"id":"dc2","day":"\(d(-1))","text":"見本の打ち直しは今週から始める","who":"見本 花子","why":"見本の直しが早く入ったため"},
          {"id":"dc3","day":"\(d(-2))","text":"見本の週次の報告は数え方をそろえる","who":"見本 太郎"}],
         "threads":[
          {"id":"th1","title":"見本の打鍵の 2 回目","keys":["打鍵","ST-012"],"days":["\(d(-5))","\(d(-3))","\(d(-1))"],
           "items":["wd-b3","wd-b4","wd-b1"],"state":"続いている"},
          {"id":"th2","title":"見本の不具合 #108","keys":["#108"],"days":2,"items":3,"state":"直し中"}],
         "quiz":{"week":"\(d(-3))","questions":[
          {"id":"q1","q":"「ST-」で始まる番号は、どの台帳の番号ですか（見本）","why":"番号の決まりが分からない","about":"numbering"},
          {"id":"q2","q":"見本 三郎さんは、どのチームの人ですか","why":"役割が分からない","about":"org"},
          {"id":"q3","q":"「見本の連携先」と「見本の帳票」は同じ話ですか","why":"つながりが分からない","about":"systems"}]},
         "scorecard":{"week":"\(d(-3))","rows":[
          {"label":"言葉の説明がある割合","now":3,"prev":1,"unit":"語"},
          {"label":"人の役割が分かる","now":10,"prev":8,"unit":"人"},
          {"label":"会話に案件が付いた","now":51,"prev":43,"unit":"%"},
          {"label":"項目の相手が分かる","now":"34/196","prev":"27/196"},
          {"label":"聞き違い","now":18,"prev":20,"unit":"%"}]},
         "guide":{"written_at":"\(written)","by":"subscription","stale":false}}
        """
        let workURL = base.appendingPathComponent("S27W", isDirectory: true).appendingPathComponent("work.json")
        if let data = try? Data(contentsOf: workURL),
           var board = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let extra = (try? JSONSerialization.jsonObject(with: Data(know.utf8))) as? [String: Any] {
            for (key, value) in extra { board[key] = value }
            if let out = try? JSONSerialization.data(withJSONObject: board) {
                try? out.write(to: workURL, options: .atomic)
            }
        }
        // 「違う」を押した見本（端末の覚え。S32ABook と同じ形）
        let fixes: [String: S32AFix] = ["wd-m2": S32AFix(what: .notmine, value: nil, valueName: nil, day: d(0))]
        if let data = try? JSONEncoder().encode(fixes) { UserDefaults.standard.set(data, forKey: S32ABook.fixesKey) }
    }
}
#endif

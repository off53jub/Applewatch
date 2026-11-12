import SwiftUI

/// 確かめてほしいこと（2026-11-10）。新しく足したのに、実機でまだ確かめていない動きの一覧。
/// 押すと確かめ方が出て、「確かめた」「動かなかった」で片づく（どちらにしたかは端末の中だけに覚える）。
/// 新しい動きを足したら、ここにも1つ足す（id は変えない。消すときは一覧から外すだけ）。
enum Checklist {
    struct Item: Identifiable, Equatable {
        let id: String
        /// 足した日
        let since: String
        let title: String
        /// 確かめ方
        let how: String
    }

    static let items: [Item] = [
        Item(id: "one-task-list", since: "2026-11-10", title: "タスクの「やる」が1つの一覧になる",
             how: "タスクの「やる」を開く。家の PC が拾ったやることが、期限ごとの並びにアプリのタスクと混ざって出ていて、「母艦のやること」の見出しが無ければ OK。同じものが2つ出ていないかも見る。"),
        Item(id: "today-howto", since: "2026-11-10", title: "今日の三つの「解き方」",
             how: "家の PC が朝に選び直したあと、タスクの「今日の三つ」を押す。手順・だいたいの時間・下書き（コピーできる）が出れば OK。"),
        Item(id: "home-day-summary", since: "2026-11-10", title: "1日のまとめが家の PC の分になる",
             how: "次の朝、前の日のドキュメントを開く。先頭の「1日のまとめ」の最後に「（家の PC が作ったまとめです）」とあり、まとめが1つだけなら OK。"),
        Item(id: "found-notice-open", since: "2026-11-10", title: "アプリを開いたまま「頼まれごとを見つけました」が出る",
             how: "アプリを開いたまま、頼まれた瞬間に時計の★を押すか、会話から拾われるのを待つ。画面の上に知らせが出れば OK。出ないときは、iPhone の「設定」→「通知」→ LifeLog が許可になっているかも見る。"),
        Item(id: "found-notice-buttons", since: "2026-11-10", title: "知らせのボタン（入れる・違う・2時間後）",
             how: "「頼まれごとを見つけました」を長押しして「入れる」か「違う」を押す。アプリを開かずに、タスクの確かめ待ちから消えていれば OK。"),
        Item(id: "found-notice-detail", since: "2026-11-10", title: "知らせに相手と期限が出る",
             how: "「頼まれごとを見つけました」の文に「（Aさんから・11/12(木)まで）」のような相手と期限が出ているか見る。"),
        Item(id: "due-hour", since: "2026-11-10", title: "時刻つきの期限の1時間前の知らせ",
             how: "タスクに今日の時刻つきの期限（2時間後くらい）を入れる。1時間前に「もうすぐ期限です」が出て、「済み」「明日に」が効けば OK。"),
        Item(id: "notice-open-tasks", since: "2026-11-10", title: "知らせを押すとタスクが開く",
             how: "「頼まれごとを見つけました」そのものを押す。アプリが開いて、タスクの画面が出れば OK。"),
        Item(id: "tasks-widget", since: "2026-11-10", title: "ウィジェット「LifeLog のやること」",
             how: "ホーム画面かロック画面を長押しして、LifeLog の「LifeLog のやること」を置く。今日までの頼まれごとと確かめ待ちの数が出れば OK。"),
        Item(id: "reject-reason", since: "2026-11-10", title: "「違う」の理由と「入り口ごとの数」",
             how: "確かめ待ちの「違う」を押して理由を選ぶ。タスクの「済み」のいちばん下の「入り口ごとの数」に、その理由が数えられていれば OK。"),
        Item(id: "digest-search", since: "2026-11-10", title: "記録の検索で仕事のまとめが出る",
             how: "下のタブ「記録」の検索に、仕事のまとめに書いてある言葉を入れる。「仕事のまとめ」の見出しの下に行が出れば OK。"),
        Item(id: "digest-ask", since: "2026-11-10", title: "記録に質問するで仕事のまとめを読む",
             how: "「記録に質問する」で、仕事のまとめに書いてあることを聞く。答えの下に「いっしょに読んだ仕事のまとめ」が出れば OK。"),
        Item(id: "digest-sources", since: "2026-11-10", title: "仕事のまとめの出どころ（［1］の番号）",
             how: "仕事のまとめの画面の「職場の Claude への頼み方をコピー」で頼み直し、答えを取り込む。まとめを開いて、行の下に「出どころ: …」が出れば OK。"),
        Item(id: "digest-clipboard", since: "2026-11-10", title: "コピーしたスクショをそのまま取り込む",
             how: "職場の Claude の答えをスクショして、左下の小さな画面を長押し →「コピー」。取り込む画面の「コピーした画像を読み取る」を押して、文字が入れば OK。"),
        Item(id: "digest-shortcut", since: "2026-11-10", title: "ショートカットから仕事のまとめを取り込む",
             how: "ショートカット App で、共有シートから受け取った画像を「仕事のまとめを取り込む」に渡すショートカットを作る。写真アプリの共有から使って、取り込む画面が開けば OK。"),
        Item(id: "digest-multi-day", since: "2026-11-10", title: "何日分かをまとめて取り込む",
             how: "【日付】が2つ以上ある答えを貼る。「○ 日分に分けて入れます」が出て、入れたあと日ごとに分かれていれば OK。"),
        Item(id: "digest-reminder-open", since: "2026-11-10", title: "退勤の頃の知らせから取り込む画面が開く",
             how: "17:30（変えていればその時刻）の「仕事のまとめ」の知らせを押す。取り込む画面が開けば OK。"),
        Item(id: "work-week", since: "2026-11-10", title: "週のまとめ（週報の下書き）",
             how: "仕事のまとめの画面 →「週のまとめ」。今週の決まったこと・残っていることが出て、「週報の下書きをコピー」で文になれば OK。"),
        Item(id: "work-threads", since: "2026-11-10", title: "案件ごと",
             how: "仕事のまとめの画面 →「案件ごと」。2日以上出てきた言葉が並び、押すとその言葉の行が日の順に出れば OK（まとめが数日分たまってから）。"),
        Item(id: "meeting-prep", since: "2026-11-10", title: "会議の前に（会う人の頼まれごと・まとめ）",
             how: "名前のある人が参加者の予定があるときに、仕事のまとめの画面 →「会議の前に」。その人の残っている頼まれごとや、まとめの行が出れば OK。予定の10分前の知らせにも出る。"),
        Item(id: "siri-homework", since: "2026-11-10", title: "Siri の「今日の宿題」",
             how: "「LifeLog で今日の宿題」と話しかける。今日までの仕事の頼まれごとを読み上げれば OK。"),
        Item(id: "work-self-voice", since: "2026-11-10", title: "職場の会話から自分の声を探す",
             how: "「記録」→ 上の「人」→「職場の会話から自分の声を探す」。▶︎で聞いて自分の声を選び、まとめる。その後の職場の会話で「自分」の行が増えれば OK（成績表の「仕事」で見られる）。"),
        Item(id: "pc-digest", since: "2026-11-10", title: "家の PC で仕事のまとめを探す",
             how: "家の PC の LifeLog PC を新しくしてから、「記録に質問する」で言葉の違う聞き方をする。PC の Claude・Codex からは search_digest・get_digest で読める。"),
        // タブの組み替え（2026-11-12）
        Item(id: "nav-tabs", since: "2026-11-12", title: "下のタブが 今日・タスク・直す・記録・ふり返り になる",
             how: "下のタブを順に押す。「直す」に数字が付き、押すと AI からの質問・声・聞き間違いが大事な順に並んでいれば OK。どのタブでも右上に歯車があるかも見る。"),
        Item(id: "nav-live", since: "2026-11-12", title: "ライブ字幕が「今日」のボタンから開く",
             how: "「今日」の「ライブ字幕」を押す。全画面で開き、オンにすると字幕が流れ、「閉じる」で戻れれば OK。"),
        Item(id: "nav-records", since: "2026-11-12", title: "記録の上の切り替え（日ごと・人・場所・お金）",
             how: "「記録」の上の切り替えを順に押す。人で話した相手、場所で登録した場所と行ったお店、お金で今月の合計と日ごとの支払いが出れば OK。"),
        Item(id: "nav-settings", since: "2026-11-12", title: "歯車の中の「点検」と「設定」",
             how: "歯車を押す。上の切り替えで「点検」（自己点検・聞き取りの成績・録音の抜け・確かめてほしいこと）と「設定」が分かれていて、長い説明は「説明を読む」で開けば OK。"),
        Item(id: "nav-notice-open", since: "2026-11-12", title: "知らせを押すと、その画面が開く",
             how: "朝の「昨日と今日」は「今日」、AI からの質問は質問の画面、いいこと帳の夜の3つはいいこと帳、会う前の1枚はその文、PayPay の月初めはお金が開けば OK。"),
        Item(id: "nav-widget-open", since: "2026-11-12", title: "ウィジェットを押すと、その画面が開く",
             how: "「LifeLog のやること」はタスク、「LifeLog のいいこと帳」はいいこと帳、「LifeLog の様子」は今日が開けば OK。"),
        Item(id: "nav-self-candidates", since: "2026-11-12", title: "職場の自分の声の確認が「直す」から開く",
             how: "家の PC が自分の声の候補を見つけたあと、「直す」に「職場の自分の声の確認」が出て、押すと▶︎で聞ける画面が開けば OK。"),
        Item(id: "watch-page-order", since: "2026-11-12", title: "時計のページが見る順に並ぶ",
             how: "時計で録音より下のページを合わせて30回ほど見たあと、時計の LifeLog を開き直す。よく見るページが録音のすぐ下に来ていれば OK（それまでは今までの順）。"),
    ]

    private static let key = "checklist.done"

    /// 片づけたもの（id → "ok" か "ng"）
    static var done: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func mark(_ id: String, ok: Bool?) {
        var all = done
        all[id] = ok.map { $0 ? "ok" : "ng" }
        UserDefaults.standard.set(all, forKey: key)
    }

    static var remaining: [Item] {
        let finished = done
        return items.filter { finished[$0.id] == nil }
    }
}

/// 歯車 →「点検」に出す入口（まだ確かめていないものがあるときだけ。2026-11-12 までは「今日」に出していた）
struct ChecklistSection: View {
    @State private var version = 0

    var body: some View {
        let left: Int = Checklist.remaining.count
        if left > 0 {
            Section {
                NavigationLink {
                    ChecklistView { version += 1 }
                } label: {
                    LabeledContent {
                        Text("\(left) 個")
                    } label: {
                        Label("確かめてほしいこと", systemImage: "checkmark.circle.badge.questionmark")
                    }
                }
                .id(version)
            } footer: {
                Text("新しく足したのに、実機でまだ確かめていない動きです。")
            }
        }
    }
}

struct ChecklistView: View {
    var changed: () -> Void = {}
    @State private var finished: [String: String] = Checklist.done
    @State private var open: String?

    var body: some View {
        List {
            let left: [Checklist.Item] = Checklist.items.filter { finished[$0.id] == nil }
            let ended: [Checklist.Item] = Checklist.items.filter { finished[$0.id] != nil }
            Section {
                if left.isEmpty { Text("全部確かめました").foregroundStyle(.secondary) }
                ForEach(left) { item in row(item) }
            } header: {
                Text("まだ（\(left.count)）")
            } footer: {
                Text("押すと確かめ方が出ます。動かなかったものは「動かなかった」にして、Claude に伝えてください。")
            }
            if !ended.isEmpty {
                Section("済み") {
                    ForEach(ended) { item in
                        HStack {
                            Image(systemName: finished[item.id] == "ok" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(finished[item.id] == "ok" ? Color.green : Color.red)
                            Text(item.title)
                            Spacer()
                            Button("戻す") { set(item.id, nil) }.font(.caption).buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("確かめてほしいこと")
    }

    private func row(_ item: Checklist.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { open = open == item.id ? nil : item.id }
            } label: {
                HStack {
                    Text(item.title).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: open == item.id ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            if open == item.id {
                Text(item.how).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    Button("確かめた", systemImage: "checkmark") { set(item.id, true) }
                    Button("動かなかった", systemImage: "xmark", role: .destructive) { set(item.id, false) }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        }
    }

    private func set(_ id: String, _ ok: Bool?) {
        Checklist.mark(id, ok: ok)
        finished = Checklist.done
        changed()
    }
}

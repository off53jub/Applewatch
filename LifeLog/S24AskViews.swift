import SwiftUI

// s24（2026-11-24）の画面。決まりは S24Rules.swift、動きは S24Book.swift。

/// 「直す」のいちばん上: 今日の 3 問（仮）と「今週は聞かないで」（減1・減4・減10）。溜まった数は出さない
struct S24TodayQuestionsSection: View {
    /// 直すものがあるか
    let hasAny: Bool
    @AppStorage(S24AskSettings.questionCapKey) private var cap = S24AskSettings.questionCapDefault
    @AppStorage(S24AskSettings.quietUntilKey) private var quietUntil: Double = 0

    var body: some View {
        let asked = S24Gate.counts().asked
        let left = S24AskRules.left(cap: S24AskRules.clampCap(cap), asked: asked)
        let quiet = S24Quiet.active(until: quietUntil > 0 ? Date(timeIntervalSince1970: quietUntil) : nil, now: .now)
        Section {
            if quiet {
                Label("今週は聞かないでいます（" + Date(timeIntervalSince1970: quietUntil).formatted(.dateTime.month().day()) + " まで）",
                      systemImage: "moon.zzz")
                    .foregroundStyle(LL.dim)
            } else if !hasAny || left == 0 {
                Label("今日は聞くことはありません", systemImage: "checkmark.circle")
                    .foregroundStyle(LL.dim)
            } else {
                Label("今日の \(S24AskRules.clampCap(cap)) 問: 上から \(left) つだけで十分です", systemImage: "list.number")
            }
        } footer: {
            Text("知らせで聞くのと、ここで答えるのを合わせて 1 日 \(S24AskRules.clampCap(cap)) 問（仮）までにしています。超えた分は知らせでは聞きません（答えたければ、ここからはいつでも答えられます）。残りは機械の見立てのまま、期限が来れば静かに閉じます。数は「知らせの便りと履歴」で変えられます。")
        }
    }
}

/// 「知らせの便りと履歴」の上に置く s24 の切り替え
struct S24NoticeSettingsSection: View {
    @AppStorage(S24AskSettings.questionCapKey) private var cap = S24AskSettings.questionCapDefault
    @AppStorage(S24AskSettings.quietUntilKey) private var quietUntil: Double = 0
    @AppStorage(S24AskSettings.foundNightKey) private var foundNight = true
    @AppStorage(S24AskSettings.dailyCapOnKey) private var dailyCapOn = true
    @AppStorage(S24AskSettings.promiseNoticeKey) private var promiseNotice = false
    @AppStorage(S24AskSettings.samePersonAskKey) private var samePersonAsk = false
    @AppStorage(S24AskSettings.watchQuietKey) private var watchQuiet = true
    @AppStorage(S24AskSettings.marksKey) private var marks = true
    @AppStorage(S24AskSettings.candidateTodayKey) private var candidateToday = true

    var body: some View {
        let quiet = S24Quiet.active(until: quietUntil > 0 ? Date(timeIntervalSince1970: quietUntil) : nil, now: .now)
        let counts = S24Gate.counts()
        Section {
            Toggle(isOn: Binding(get: { quiet }, set: { S24Book.setQuiet($0); quietUntil = UserDefaults.standard.double(forKey: S24AskSettings.quietUntilKey) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今週は聞かないで")
                    Text(quiet ? Date(timeIntervalSince1970: quietUntil).formatted(.dateTime.month().day().hour().minute()) + " まで、問いと便りを止めています。"
                         : "問いと便りを 7 日止めます。録音・記録・急ぎ・録音が止まった・期限の知らせは続けます。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
            Stepper(value: Binding(get: { S24AskRules.clampCap(cap) }, set: { cap = S24AskRules.clampCap($0) }), in: 1...10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("聞く数は 1 日 \(S24AskRules.clampCap(cap)) 問まで")
                    Text("確かめ待ち・場所・名前・何人でしたか・自分を知る・話し手など、全部を合わせた数です（仮 3）。今日はここまでに \(counts.asked) 問。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
            Toggle(isOn: $dailyCapOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("知らせは 1 日 \(S24NoticeRules.dailyCap) 通まで")
                    Text("あふれた分は朝夕の便りにまとめます（仮 5 通）。録音が止まった・期限・急ぎは別に出します。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
            Toggle(isOn: $foundNight) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("見つけた頼まれごとは夜の 1 通に")
                    Text("その場では知らせず、20:30（仮）に 1 通にまとめます。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
            Toggle(isOn: $candidateToday) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("タスクの候補は今日の 3 件だけ")
                    Text("残りと「たぶん違う」は畳みます。オフにすると前のように全部並べます。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
            Toggle(isOn: $promiseNotice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("約束を知らせる")
                    Text("初めはオフ。約束の一覧と台帳はそのまま残ります（タスクの「約束・決めごと」）。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
            Toggle(isOn: $samePersonAsk) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("「同じ人か」を聞く")
                    Text("初めはオフ。今の点では当たりが少ないため、直るまで聞きません。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
            Toggle(isOn: $watchQuiet) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("時計を震わせるのは録音・期限・急ぎだけ")
                    Text("ほかの知らせは静かに届けます（iPhone の通知センターには残ります。音も鳴りません）。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
            Toggle(isOn: $marks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("題の頭に種類の印")
                    Text("【録音】【期限】【問い】【便り】。ロック画面で読まずに分けられます。")
                        .font(.caption).foregroundStyle(LL.dim)
                }
            }
        } header: {
            LLHeader(title: "溜めない", symbol: "tray")
        }
    }
}

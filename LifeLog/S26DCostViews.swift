import SwiftUI

// s26 の 絵3＋軽1 の費用の画面（A3・S26D。2026-11-25）。
// 2026-11-25 朝、本人「このオレンジの文字は止まっているという意味？」。前は「1日の上限 $… に届いたので、今日はもう頼みません」が
// オレンジの文字で用途ごとに並んでいて、壊れているのか休んでいるのかが伝わらなかった。
// いま: 用途ごとに「使った／上限」の横棒。上限に届いた用途は下に「今日はここまで（0 時に戻る）」としてまとめ、
// 止まって困ること（家の PC が effect を送るとき。K7）を 1 行。家の PC の設定で止めた用途はさらに下に灰で。

// MARK: - 決まり（計算だけ。テストは LifeLogTests/S26DTests.swift）

enum S26DCostRules {
    static let restTitle = "今日はここまで（0 時に戻る）"
    static let restFooter = "オレンジは「今日はお休み・0 時にまた動く」という印です。壊れてはいません。月の上限（$100）とは別の、用途ごとの 1 日の上限です。"
    /// effect が無いときの 1 行（前の文の言い方を残す）
    static let defaultEffect = "今日はもう頼みません。頼んでいた仕事は、Claude を使わない前のやり方で動きます。"

    /// 動いている・今日はここまで・止めてある に分ける（動いているのは使った割合の多い順）
    static func groups(_ rows: [CostToday]) -> (running: [CostToday], resting: [CostToday], stopped: [CostToday]) {
        var running: [CostToday] = []
        var resting: [CostToday] = []
        var stopped: [CostToday] = []
        for row in rows {
            if row.stopped {
                stopped.append(row)
            } else if row.capped {
                resting.append(row)
            } else {
                running.append(row)
            }
        }
        running.sort { a, b in
            let fa = S26DMeterRules.fraction(used: a.usd, cap: a.capNow) ?? -1
            let fb = S26DMeterRules.fraction(used: b.usd, cap: b.capNow) ?? -1
            if fa != fb { return fa > fb }
            if a.usd != b.usd { return a.usd > b.usd }
            return a.purpose < b.purpose
        }
        resting.sort { $0.purpose < $1.purpose }
        stopped.sort { $0.purpose < $1.purpose }
        return (running, resting, stopped)
    }

    /// 「$0.30 / $1.00」（上限の無い用途は「$0.30（上限なし）」）
    static func amountText(_ row: CostToday) -> String {
        guard let cap = row.capNow else { return ClaudeUsage.dollars(row.usd) + "（上限なし）" }
        return ClaudeUsage.dollars(row.usd) + " / " + ClaudeUsage.dollars(cap)
    }

    /// 止まって困ること（家の PC の effect。無ければ前の文）
    static func effectLine(_ row: CostToday) -> String {
        let text = (row.effect ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? defaultEffect : text
    }

    /// 今日の上限を月の残りから決め直したとき（cap_today が cap と違う）の注
    static func capNote(_ row: CostToday) -> String? {
        guard let today = row.cap_today, let base = row.cap, abs(today - base) >= 0.005 else { return nil }
        return "今日の上限は月の残りから決め直した額です（ふだんは " + ClaudeUsage.dollars(base) + "）"
    }
}

// MARK: - 画面の部品

/// 「今日」の 3 つの節（動いている・今日はここまで・止めてある）
struct S26DCostTodaySections: View {
    let rows: [CostToday]

    var body: some View {
        let g = S26DCostRules.groups(rows)
        Section {
            if rows.isEmpty {
                Text("今日はまだ使っていません。").foregroundStyle(LL.dim)
            } else if g.running.isEmpty {
                Text("今日動いている用途はありません。").foregroundStyle(LL.dim)
            }
            ForEach(g.running) { row in
                S26DCostMeterRow(row: row, role: .machine)
            }
        } header: {
            LLHeader(title: "今日", symbol: "chart.bar.xaxis", trailing: "使った／1 日の上限")
        }
        if !g.resting.isEmpty {
            Section {
                ForEach(g.resting) { row in
                    VStack(alignment: .leading, spacing: LL.Space.xs) {
                        S26DCostMeterRow(row: row, role: .wait)
                        Label(S26DCostRules.effectLine(row), systemImage: "info.circle")
                            .font(LL.TypeScale.note)
                            .foregroundStyle(LL.dim)
                    }
                }
            } header: {
                LLHeader(title: S26DCostRules.restTitle, symbol: LLRole.wait.symbol)
            } footer: {
                Text(S26DCostRules.restFooter)
            }
        }
        if !g.stopped.isEmpty {
            Section {
                ForEach(g.stopped) { row in
                    LLRow(title: ClaudeJob.label(row.purpose), detail: "家の PC の設定で止めてあります（0 時には戻りません）",
                          value: ClaudeUsage.dollars(row.usd), symbol: "pause.circle")
                }
            } header: {
                LLHeader(title: "止めてある", symbol: "pause.circle")
            }
        }
    }
}

/// 用途 1 つ: 名前・「使った／上限」・横棒
struct S26DCostMeterRow: View {
    let row: CostToday
    let role: LLRole

    var body: some View {
        VStack(alignment: .leading, spacing: LL.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(ClaudeJob.label(row.purpose)).font(LL.TypeScale.body).foregroundStyle(LL.text)
                Spacer(minLength: LL.Space.s)
                Text(S26DCostRules.amountText(row)).font(LL.TypeScale.rowNumber)
                    .foregroundStyle(role == .wait ? LL.warn : LL.text)
            }
            if let f = S26DMeterRules.fraction(used: row.usd, cap: row.capNow) {
                LLMeter(fraction: f, role: role)
            }
            if let note = S26DCostRules.capNote(row) {
                Text(note).font(LL.TypeScale.note).foregroundStyle(LL.dim)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(role == .wait ? "今日はここまで。0 時に戻ります" : "")
    }
}

/// 今月の横棒（今月使った額／月の上限）
struct S26DCostMonthMeter: View {
    let costs: CostsFeed

    var body: some View {
        if let f = S26DMeterRules.fraction(used: costs.month_usd, cap: costs.monthly_usd) {
            VStack(alignment: .leading, spacing: LL.Space.xs) {
                LLMeter(fraction: f, role: f >= 1 ? .act : .machine)
                if let p = S26DMeterRules.fraction(used: costs.projected_usd, cap: costs.monthly_usd) {
                    Text("月末の見込みは上限の " + S26DMeterRules.percentText(p) + "（仮の目安）")
                        .font(LL.TypeScale.note).foregroundStyle(LL.dim)
                }
            }
        }
    }
}

import SwiftUI

// s38（2026-11-28）アプリ担当 S38A（A1）の画面。決まりは S38ARules.swift、動きは S38ABook.swift。
// - 続1: 人物N の「仮: 名前」（会話の行の吹き出し・人の一覧・「この声は誰？」）。薄く添えるだけで、名前は変えない
// - 続2: 人の一覧の「通りすがり（N 人）」の畳んだ箱（SpeakerViews.swift の PeopleView の中）
// - 続3: タスク画面の下の「声のメモ（N 件）」の畳んだ箱（S38AVoiceMemoSection。読むだけ）
// どれも GET /s36 の写しに鍵があるときだけ（無ければ何も出さない）。知らせ・問いは足さない。職場の文は S27W の伏せる設定に従う。

enum S38AFeed {
    /// いまの写し（家の PC が /s36 を配っていないときは nil）
    @MainActor static var feed: S36AFeed? { S36ABook.shared.offered ? S36ABook.shared.feed : nil }

    @MainActor static var names: [S38AName]? { feed?.names }

    @MainActor static var passerby: Set<String> { Set(feed?.passerby ?? []) }

    @MainActor static var memos: [S38AVoiceMemo] { S38AMemos.shown(feed?.voiceMemos) }
}

/// 「仮: 名前」の薄い 1 語
struct S38ANameHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(LL.dim)
            .lineLimit(1)
            .accessibilityLabel(text.replacingOccurrences(of: "仮: ", with: "仮の名前 "))
    }
}

/// 人の番号に仮の名前があれば添える（名前を付けた人・自分には出さない）
struct S38APersonHint: View {
    let id: String
    let isNamed: Bool

    var body: some View {
        if let hint = S38ANames.hint(number: S38ARules.number(id), names: S38AFeed.names, isNamed: isNamed) {
            S38ANameHint(text: hint)
        }
    }
}

/// 続3 タスク画面の下の「声のメモ（N 件）」（畳んである・読むだけ）
struct S38AVoiceMemoSection: View {
    var body: some View {
        let memos = S38AFeed.memos
        if !memos.isEmpty {
            Section {
                DisclosureGroup(S38AMemos.title(memos.count)) {
                    ForEach(memos) { memo in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(S27WBook.shared.t(memo.text))
                                .font(.callout)
                                .foregroundStyle(LL.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if let caption = S38AMemos.caption(memo) {
                                Text(S27WBook.shared.t(caption)).font(.caption2).foregroundStyle(LL.dim)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .accessibilityIdentifier("s38a.voiceMemos")
            } footer: {
                Text("声で残したメモです（家の PC から）。読むだけで、タスクにはしていません。")
            }
        }
    }
}

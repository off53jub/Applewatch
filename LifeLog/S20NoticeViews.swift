import SwiftUI

// 知らせの便りと履歴（s20 の 体16・体17・体19・次2。2026-11-21）。決まりは S20Rules.swift と S20Notices.swift。

/// 知らせの履歴。その場で「この種類はもう要らない」
struct NoticeHistoryView: View {
    @AppStorage(SceneKey.noticeDigest.rawValue) private var digestOn = false
    /// 急ぎ以外を朝の 1 通に（初めはオン。2026-11-28。s38 の 活3）
    @AppStorage(S38AMorning.key) private var morningOne = true

    var body: some View {
        let book = S20Book.shared
        let list = Array(book.notices.reversed())
        let kinds: [String] = {
            var seen: [String] = []
            for n in list where !seen.contains(n.kind) { seen.append(n.kind) }
            return seen
        }()
        let waiting = S20Notices.waiting()
        let opened = list.filter { $0.opened == true }.count
        LLList {
            // 答えそびれた質問・知らせの棚卸し（2026-11-23。s23 の 知1・知13。S23Screens.swift）
            S23NoticeLinks()
            // 溜めない（問いの上限・今週は聞かないで・夜の 1 通・約束・同じ人か・時計・題の印。2026-11-24。s24。S24Views.swift）
            S24NoticeSettingsSection()
            Section {
                Toggle(isOn: $morningOne) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("急ぎでない知らせを朝の 1 通に")
                        Text("朝 7:30（仮）の 1 通にまとめます。録音が止まった・時計が録音していない・電池・期限・急ぎ・ボタンのある知らせは、すぐ出します。オフにすると、前のとおり 1 通ずつ出します。")
                            .font(.caption).foregroundStyle(LL.dim)
                    }
                }
                .accessibilityIdentifier("s38a.morningOne")
                if morningOne && !digestOn {
                    let next = S38AMorning.nextSlot(after: .now)
                    LabeledContent("次の朝の 1 通", value: next.formatted(date: .omitted, time: .shortened) + "（\(waiting.count) 件）")
                }
                Toggle(isOn: $digestOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("急ぎでない知らせを朝夕の便りに")
                        Text("朝 7:30・夕 19:00 の 2 回（仮）。録音が止まった・期限・約束・ボタンのある知らせは、すぐ出します。")
                            .font(.caption).foregroundStyle(LL.dim)
                    }
                }
                if digestOn {
                    let next = NoticeDigestRules.nextSlot(after: .now)
                    LabeledContent("次の便り", value: next.formatted(date: .omitted, time: .shortened) + "（\(waiting.count) 件）")
                }
            } header: {
                LLHeader(title: "便り", symbol: "envelope.badge")
            }
            Section {
                HStack(spacing: LL.Space.s) {
                    StatTile(title: "7 日の知らせ", value: "\(list.count)", unit: "通")
                    StatTile(title: "押して開いた", value: list.isEmpty ? "—" : "\(opened * 100 / max(1, list.count))", unit: "%")
                    StatTile(title: "止めた種類", value: "\(book.muted.count)")
                }
                .fixedSize(horizontal: false, vertical: true)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            if !kinds.isEmpty || !book.muted.isEmpty {
                Section {
                    ForEach(Array(Set(kinds).union(book.muted)).sorted(), id: \.self) { kind in
                        Toggle(isOn: Binding(get: { !book.muted.contains(kind) }, set: { book.setMuted(kind, !$0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NoticeHistoryRules.kindLabel(kind))
                                Text("7 日で \(list.filter { $0.kind == kind }.count) 通").font(.caption).foregroundStyle(LL.dim)
                            }
                        }
                    }
                } header: {
                    LLHeader(title: "種類ごと（切ると、その種類はもう出しません）", symbol: "bell.slash")
                } footer: {
                    Text("急ぎの知らせ（録音が止まった・期限・約束）は、切っても出します。")
                }
            }
            Section {
                if list.isEmpty {
                    LLEmpty(title: "まだ知らせはありません", symbol: "bell", detail: "アプリが出した知らせが 7 日分、ここに並びます（題と種類だけ）。")
                }
                ForEach(list) { n in
                    HStack(alignment: .top, spacing: LL.Space.m) {
                        Image(systemName: n.held ? "envelope" : "bell")
                            .foregroundStyle(n.held ? LL.dim : LL.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.title).font(.callout).lineLimit(2)
                            HStack(spacing: LL.Space.s) {
                                Text(n.at.formatted(.dateTime.month().day().hour().minute().locale(LL.ja))).monospacedDigit()
                                Text(NoticeHistoryRules.kindLabel(n.kind))
                                if n.held { Text("便りへ") }
                                if n.opened == true { Text("開いた").foregroundStyle(LL.good) }
                            }
                            .font(.caption2).foregroundStyle(LL.dim)
                        }
                        Spacer()
                        if n.held {
                            WhyButton(info: WhyInfo(title: "便りに回した知らせ",
                                                    reason: "急ぎでない知らせなので、すぐには出さず次の便り（朝 7:30・夕 19:00）にまとめました。",
                                                    evidence: [NoticeHistoryRules.kindLabel(n.kind)],
                                                    fix: "すぐ出してほしい種類なら、上の「便り」を切ってください。", certainty: .fact))
                        }
                        Menu {
                            Button("この種類はもう要らない", systemImage: "bell.slash") { book.setMuted(n.kind, true) }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(LL.dim)
                        }
                        .accessibilityLabel("この知らせの種類を止める")
                    }
                    .swipeActions {
                        Button("要らない") { book.setMuted(n.kind, true) }.tint(LL.warn)
                    }
                }
            } header: {
                LLHeader(title: "履歴（7 日）", symbol: "clock")
            }
        }
        .navigationTitle("知らせの履歴")
        .navigationBarTitleDisplayMode(.inline)
        .countsOpen("noticeHistory")
    }
}

/// 設定の「ふだん」に置く入口
struct NoticeSettingsLink: View {
    var body: some View {
        NavigationLink {
            NoticeHistoryView()
        } label: {
            Label("知らせの便りと履歴", systemImage: "envelope.badge")
        }
    }
}

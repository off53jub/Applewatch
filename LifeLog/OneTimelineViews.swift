import PhotosUI
import SwiftUI

/// 1日の画面に挟む年表の行・PayPay のスクリーンショットの取り込み・反映の見張りの表（2026-11-14。OneTimeline.swift）

// MARK: - 1日の画面の年表の行（25）

/// 会話（や過ごし方の塊）のあいだに挟む、年表の行のまとまり（無ければ何も出さない）
struct TimelineRowsSection: View {
    let rows: [TimelineRow]

    var body: some View {
        if !rows.isEmpty {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    TimelineRowLine(row: row)
                }
            }
        }
    }
}

/// 年表の1行（時刻・lane の印・文・金額か場所）
struct TimelineRowLine: View {
    let row: TimelineRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(OneTimeline.timeLabel(row))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: OneTimeline.laneIcon(row.lane))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityLabel(row.lane)
            Text(row.text)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let detail = OneTimeline.detail(row) {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 年表の上の一言（今日と昨日で、家の PC から新しい分を読めなかったときだけ）
struct TimelineNoteSection: View {
    @Environment(Pipeline.self) private var pipeline
    let day: String

    var body: some View {
        if let note = pipeline.oneTimeline.note(for: day) {
            Section {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - PayPay のスクリーンショット（28）

/// 「記録」→「お金」の入口
struct PayPayShotSection: View {
    var body: some View {
        Section {
            NavigationLink {
                PayPayShotView()
            } label: {
                Label("PayPay の履歴をスクショで取り込む", systemImage: "camera.viewfinder")
            }
        } footer: {
            Text("PayPay のアプリの「取引履歴」の画面を写したものを選ぶと、家の PC が読み取ります。確かめてから「取り込む」を押した分だけ、母艦のお金の記録と年表に入ります。CSV の明細は、月に1回の確かめ用に使えます。")
        }
    }
}

struct PayPayShotView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var picked: [PhotosPickerItem] = []
    @State private var rows: [PayShotRow] = []
    @State private var checked: Set<String> = []
    @State private var progress: String?
    @State private var notes: [String] = []
    @State private var sending = false
    @State private var result: String?

    var body: some View {
        let pc: HomePC = pipeline.homePC
        let canRead: Bool = pc.isConfigured && pc.features.contains("paypayshot")
        let canSend: Bool = pc.isConfigured && pc.features.contains("paypayrows")
        let chosen: Int = rows.filter { checked.contains($0.id) }.count
        List {
            Section {
                PhotosPicker(selection: $picked, maxSelectionCount: PayShots.maxPhotos, selectionBehavior: .ordered,
                             matching: .images) {
                    Label("スクショを選ぶ（\(PayShots.maxPhotos) 枚まで）", systemImage: "photo.on.rectangle")
                }
                .disabled(!canRead || progress != nil)
                if let progress {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(progress).foregroundStyle(.secondary)
                    }
                }
                if !canRead {
                    Text("家の PC につながっていて、家の PC が新しい版（Claude が使えるとき）だと選べます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("写真は家の PC に1枚ずつ送り、読み終えたら捨てます（この iPhone の写真はそのまま。PC にも残しません）。")
            }
            if !rows.isEmpty {
                Section {
                    ForEach($rows) { $row in
                        PayShotRowEditor(row: $row, checked: Binding(
                            get: { checked.contains(row.id) },
                            set: { on in
                                if on { checked.insert(row.id) } else { checked.remove(row.id) }
                            }),
                            known: isKnown(row))
                    }
                } header: {
                    Text("読めた支払い（\(rows.count) 件）")
                } footer: {
                    Text("「もうある」は、この iPhone の支払い（PayPay の明細・カードの利用速報・かざした記録）か、前に取り込んだ分に、同じ日・同じ金額があるものです。初めは外してあります。")
                }
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            ProgressView()
                        } else {
                            Text("\(chosen) 件を取り込む")
                        }
                    }
                    .disabled(chosen == 0 || sending || !canSend)
                }
            }
            if let result {
                Section { Text(result).font(.footnote) }
            }
        }
        .navigationTitle("PayPay のスクショ")
        .countsOpen("paypayShot")
        .onChange(of: picked) {
            let items: [PhotosPickerItem] = picked
            guard !items.isEmpty else { return }
            Task { await read(items) }
        }
        .onAppear { loadDemo() }
    }

    private func isKnown(_ row: PayShotRow) -> Bool {
        PayShots.isKnown(row, payments: pipeline.payments.all, sent: pipeline.oneTimeline.sentShots)
    }

    /// 選んだ写真を1枚ずつ家の PC に送って読む
    private func read(_ items: [PhotosPickerItem]) async {
        notes = []
        result = nil
        var found: [PayShotRow] = rows
        let list: [PhotosPickerItem] = Array(items.prefix(PayShots.maxPhotos))
        picked = []
        for (i, item) in list.enumerated() {
            let n: Int = i + 1
            progress = "\(n) / \(list.count) 枚目を読んでいます…"
            let data: Data? = try? await item.loadTransferable(type: Data.self)
            guard let data, let jpeg = PayShots.jpeg(from: data) else {
                notes.append("\(n) 枚目: 画像を開けませんでした。")
                continue
            }
            do {
                let reply: Data = try await pipeline.homePC.postBody("pay/paypay-shot", body: jpeg, type: "image/jpeg", timeout: 120)
                guard let parsed = PayShots.decode(reply) else {
                    notes.append("\(n) 枚目: 家の PC の答えを読めませんでした。")
                    continue
                }
                if parsed.isEmpty { notes.append("\(n) 枚目: 支払いが見つかりませんでした。") }
                let before: Int = found.count
                found = PayShots.merged(found, adding: parsed)
                if found.count > before {
                    for r in found[before...] where !isKnown(r) { checked.insert(r.id) }
                }
                Tally.add("paypayshot.read")
            } catch {
                if let failure = error as? HomePC.Failure, case .server(let reason) = failure {
                    notes.append("\(n) 枚目: " + reason)
                } else {
                    notes.append("\(n) 枚目: " + HomePC.describe(error))
                }
            }
            rows = found
        }
        rows = found
        progress = nil
    }

    private func send() async {
        let chosen: [PayShotRow] = rows.filter { checked.contains($0.id) }
        guard let body = PayShots.body(chosen) else {
            result = "金額（1円以上）か店の名前（40文字まで）がおかしな行があります。直してから押してください。"
            return
        }
        sending = true
        defer { sending = false }
        do {
            _ = try await pipeline.homePC.postJSONData("pay/paypay-rows", body: body, timeout: 20)
            pipeline.oneTimeline.noteShotsSent(chosen)
            let sentIDs = Set(chosen.map(\.id))
            rows.removeAll { sentIDs.contains($0.id) }
            checked.subtract(sentIDs)
            result = "\(chosen.count) 件を家の PC に送りました。母艦が、お金の記録と年表に入れます。"
            Tally.add("paypayshot.sent", chosen.count)
        } catch {
            result = "送れませんでした: " + HomePC.describe(error) + "（行はこのまま残しています）"
        }
    }

    private func loadDemo() {
        #if DEBUG && targetEnvironment(simulator)
        if DemoData.isOn && rows.isEmpty {
            rows = DemoData.payShotRows()
            for r in rows where !isKnown(r) { checked.insert(r.id) }
        }
        #endif
    }
}

/// 読めた1行（取り込むか・店・金額を直せる）
private struct PayShotRowEditor: View {
    @Binding var row: PayShotRow
    @Binding var checked: Bool
    let known: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: $checked) {
                    HStack(spacing: 6) {
                        Text(PayShotRowEditor.when(row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if known {
                            Text("もうある")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2), in: Capsule())
                        }
                    }
                }
            }
            TextField("店の名前", text: $row.shop)
                .font(.callout)
            HStack {
                TextField("金額", value: $row.amount, format: .number)
                    .keyboardType(.numberPad)
                    .font(.callout.monospacedDigit())
                Text("円").foregroundStyle(.secondary)
                if !row.method.isEmpty {
                    Spacer()
                    Text(row.method).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 「11/14 12:34」（時刻が無ければ日だけ）
    static func when(_ row: PayShotRow) -> String {
        var text: String = AppFeeds.monthDay(row.day)
        if let t = row.time, let date = AppFeeds.parseTime(t) { text += " " + HomeFeeds.clock(date) }
        return text
    }
}

// MARK: - 反映の見張り（34）

/// 歯車→点検の入口（写しがあるときだけ）
struct ReflectionCheckSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        if let table = pipeline.oneTimeline.reflection {
            let today: String = table.today ?? HealthExport.dayKey(.now)
            let late: Int = Reflection.lateCount(table, today: today)
            Section {
                NavigationLink {
                    ReflectionView()
                } label: {
                    LabeledContent("反映の見張り", value: late > 0 ? "止まっている所 \(late)" : "止まっていません")
                }
            } footer: {
                Text("LINE・場所・お金などが、年表・朝のまとめ・アプリ・ノートまで届いているかの表です（家の PC の母艦が毎日作ります）。")
            }
        }
    }
}

/// 要素 × 反映先の表。マスは何日遅れているか（2日以上だけ色）
struct ReflectionView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let table: ReflectionTable? = pipeline.oneTimeline.reflection
        List {
            Section {
                if let table, !table.elements.isEmpty {
                    ScrollView(.horizontal) {
                        ReflectionGrid(table: table)
                            .padding(.vertical, 4)
                    }
                } else {
                    Text("まだありません").foregroundStyle(.secondary)
                }
            } header: {
                if let generated = table?.generated_at, let date = AppFeeds.parseTime(generated) {
                    Text("作った時刻 " + AppFeeds.shortTime(date))
                }
            } footer: {
                Text("数字は止まっている日数です（取り込みは今日から、ほかは取り込んだ日から数えます）。「—」はまだ届いたことが無い所。2日以上は色を付けています。直すのは家の PC（母艦）の側です。")
            }
        }
        .navigationTitle("反映の見張り")
        .countsOpen("reflection")
        .refreshable { await pipeline.oneTimeline.refreshReflection(pipeline.homePC, force: true) }
    }
}

private struct ReflectionGrid: View {
    let table: ReflectionTable

    var body: some View {
        let today: String = table.today ?? HealthExport.dayKey(.now)
        let entry: Int = Reflection.entryIndex(table)
        Grid(alignment: .center, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(Array(table.destinations.enumerated()), id: \.offset) { _, name in
                    Text(name)
                }
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            ForEach(table.elements) { e in
                ReflectionGridRow(element: e, today: today, entry: entry)
            }
        }
    }
}

private struct ReflectionGridRow: View {
    let element: ReflectionTable.Element
    let today: String
    let entry: Int

    var body: some View {
        let entryDay: String? = entry < element.cells.count ? element.cells[entry] : nil
        GridRow {
            Text(element.element).font(.caption)
            ForEach(Array(element.cells.enumerated()), id: \.offset) { i, cell in
                ReflectionCell(behind: Reflection.behind(cell, entry: entryDay, today: today, isEntry: i == entry))
            }
        }
    }
}

private struct ReflectionCell: View {
    let behind: Int?

    var body: some View {
        let days: Int = behind ?? 0
        let color: Color = days >= Reflection.badDays ? .red : .orange
        Text(Reflection.cellText(behind))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(days >= Reflection.warnDays ? color.opacity(0.25) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
    }
}

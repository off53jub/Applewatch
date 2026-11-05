import SwiftUI

// 「今日」に出す、会議モードのボタン・録音の抜けの地図・名前を付ける候補の声（2026-11-06）。

/// 会議モードを始める・終えるボタン
struct MeetingButton: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        if let meeting = pipeline.meeting {
            Button {
                pipeline.setMeeting(false)
            } label: {
                Label("会議モードを終える（\(meeting.start.formatted(date: .omitted, time: .shortened)) から"
                      + (meeting.title.map { "・\($0)" } ?? "") + "）", systemImage: "person.3.fill")
            }
            .tint(.orange)
        } else {
            Button {
                pipeline.setMeeting(true)
            } label: {
                Label("会議モードを始める", systemImage: "person.3")
            }
        }
    }
}

/// 録音の抜けの地図（今日と昨日）
struct RecordingMapView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var dayOffset = 0

    var body: some View {
        let start = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Calendar.current.startOfDay(for: .now)) ?? .now
        let map = pipeline.ledger.map(for: start)
        let counts = pipeline.ledger.counts(for: start)
        List {
            Section {
                Picker("日", selection: $dayOffset) {
                    Text("今日").tag(0)
                    Text("昨日").tag(1)
                    Text("おととい").tag(2)
                }
                .pickerStyle(.segmented)
                DayBand(start: start, spans: map.spans)
                    .frame(height: 28)
                HStack(spacing: 12) {
                    legend(.green, "録れた")
                    legend(.gray.opacity(0.5), "静かで休み")
                    legend(.blue.opacity(0.5), "休む場所")
                    legend(.red, "抜け")
                }
                .font(.caption2)
            } footer: {
                Text("0時から24時まで（今日は今まで）。10分以上の抜けを下に出します。帳簿は 2026-11-06 の版から付け始めたので、それより前の日は出ません。")
            }
            Section("録れていなかった時間") {
                if map.gaps.isEmpty {
                    Text("10分以上の抜けはありません").foregroundStyle(.secondary)
                }
                ForEach(map.gaps) { gap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(gap.start.formatted(date: .omitted, time: .shortened))〜\(gap.end.formatted(date: .omitted, time: .shortened))（\(gap.minutes)分）")
                        Text(gap.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("時計から届いた区切り", value: "\(counts.watchReceived)")
                LabeledContent("iPhone で録った区切り", value: "\(counts.phoneRecorded)")
                LabeledContent("文字にした区切り", value: "\(counts.transcribed)（\(counts.lines) 行）")
                LabeledContent("壊れていた区切り", value: "\(counts.broken)")
                LabeledContent("まだ文字にしていない区切り", value: "\(counts.waiting)")
                if let kept = pipeline.ledger.lastState, kept.recording {
                    LabeledContent("時計の電池", value: kept.battery.map { "\(Int($0 * 100))%" + (kept.charging == true ? "（充電中）" : "") } ?? "分からない")
                }
            } header: {
                Text("数の照合")
            } footer: {
                Text("時計は、iPhone から「受け取った」と返事が来るまで録音の控えを残し、30分たっても返事が無ければ送り直します（3日・300MB まで）。")
            }
        }
        .navigationTitle("録音の抜け")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }
}

/// 1日の帯
private struct DayBand: View {
    let start: Date
    let spans: [RecordingLedger.Span]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                    let x = width * span.start.timeIntervalSince(start) / (24 * 3600)
                    let w = max(1, width * span.end.timeIntervalSince(span.start) / (24 * 3600))
                    Rectangle().fill(color(span.kind)).frame(width: w).offset(x: x)
                }
            }
        }
        .accessibilityLabel("1日の録音の帯")
    }

    private func color(_ kind: RecordingLedger.Span.Kind) -> Color {
        switch kind {
        case .recorded: .green
        case .quiet: .gray.opacity(0.5)
        case .held: .blue.opacity(0.5)
        case .gap: .red
        }
    }
}

/// 名前を付ける候補の声（初めての人の印・名乗った声）。名前は本人が付ける
struct NewVoicesSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let open = pipeline.newVoices.open
        if !open.isEmpty {
            Section {
                ForEach(open.prefix(5)) { note in
                    NavigationLink {
                        PersonView(id: note.personID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if let place = note.unusualPlace {
                                Text("\(pipeline.people.first { $0.id == note.personID }?.displayName ?? "人物\(note.personID)") の声が、ふだん話さない「\(place)」で聞こえました。合っていますか？")
                            } else {
                                Text(note.claimed.map { "人物\(note.personID) が「\($0)」と名乗りました" }
                                     ?? "初めての人の印のころに話した 人物\(note.personID)")
                            }
                            Text("\(note.time.formatted(date: .abbreviated, time: .shortened))「\(note.quote.prefix(40))」")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("消す") { pipeline.dismissNewVoice(note.id) }
                    }
                }
            } header: {
                Text("名前を付ける・確かめる声")
            } footer: {
                Text("押すと、その声を聞いて名前を付けたり直したりできます。名前は自動では付けも変えもしません。違うもの・合っているものは左へ払って消せます。名前を付ける人には、声を覚えることの了承をもらってください。")
            }
        }
    }
}

/// 自信の低い行の「大事な言葉」（数字・金額・日時・カタカナや漢字の名前らしい言葉）に下線を引く
enum UncertainMarks {
    /// 数字（金額・日時・数）と、「〜さん」「〜様」の付いた名前
    static let pattern = #"[0-9０-９][0-9０-９,，.:：/／]*(?:円|万|億|千|百|%|％|時|分|人|株|年|月|日|回|件|個|本|社)?|[一-龥々ァ-ヶー]{1,6}(?:さん|様|さま|くん|君|ちゃん|部長|課長|社長)"#

    static func ranges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    static func underlined(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for range in ranges(in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }
}

/// 車の Bluetooth を自分で選ぶ画面（2026-11-06）。選んでいない機器は、名前で車かどうかを決める
struct CarDevicesView: View {
    @State private var chosen = CarAudioLog.chosen
    private let seen = CarAudioLog.seen

    var body: some View {
        List {
            Section {
                if seen.isEmpty {
                    Text("まだ Bluetooth の機器につないだことがありません。車につないでから開いてください。")
                        .foregroundStyle(.secondary)
                }
                ForEach(seen, id: \.self) { name in
                    Toggle(isOn: Binding(
                        get: { CarAudioLog.isCar(name, chosen: chosen) },
                        set: { chosen[name] = $0; CarAudioLog.chosen = chosen }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                            Text(chosen[name] == nil ? "名前で決めています" : "自分で選びました")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("オンにした機器につないでいた時間は、乗り物を「車で」にします（CarPlay はいつも車）。これまでにつないだ機器が出ます。")
            }
        }
        .navigationTitle("車の機器")
    }
}

/// 確認箱（2026-11-06）: 確かめ待ちを1つの画面に、大事な順に並べる。1日5分で終わるよう、上から片付ける
struct ConfirmBoxView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var reviewCount = 0

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let day = Self.dayFormatter.string(from: .now)
        let week = AnswerKey.weekKey(.now)
        let samples = pipeline.answerKey.samples(of: week)
        let answers = samples.isEmpty ? AnswerKey.perWeek : samples.filter { !$0.isAnswered }.count
        List {
            Section {
                Text("上から順に片付けると、1日5分ほどで終わります。終わったものは消えます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !pipeline.tasks.candidates.isEmpty {
                Section("1. タスクの候補（\(pipeline.tasks.candidates.count)）") {
                    NavigationLink("頼まれごと帳で入れる・捨てる") { TaskBookView() }
                }
            }
            if !pipeline.asks.open.isEmpty {
                Section("2. AI からの質問（\(pipeline.asks.open.count)）") {
                    NavigationLink("答える") { QuestionsView() }
                }
            }
            NewVoicesSection()
            if reviewCount > 0 {
                Section("4. 見直したい声（\(reviewCount)）") {
                    NavigationLink("声を聞いて直す") { VoiceReviewView() }
                    NavigationLink("今日の人物Nを整理") { UnnamedVoicesView(day: day) }
                }
            }
            if pipeline.misheardCount > 0 {
                Section("5. 聞き間違いかも（\(pipeline.misheardCount)）") {
                    NavigationLink("直す・そのまま") { MisheardView() }
                }
            }
            if answers > 0 {
                Section("6. 今週の答え合わせ（あと \(answers) 問）") {
                    NavigationLink("答える（5分ほど）") { AnswerKeyView() }
                }
            }
        }
        .navigationTitle("確認箱")
        .onAppear { reviewCount = pipeline.voiceReview().count }
    }
}

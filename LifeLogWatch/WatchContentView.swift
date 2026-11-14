import SwiftUI

/// 時計の画面。上下にめくる7枚（2026-11-07）:
/// 録音 / 頼まれごと / 次の予定 / さっきの会話 / 聞く / 昨日と今日 / 様子。
/// 録音の画面は前と同じ。ほかの画面の中身は iPhone から届く（iPhone が離れていても、前に届いた分を出す）。
/// 2026-11-12 から、録音より下の6枚は、この時計でよく見るものから並べる（WatchPages。回数がたまるまでは上の順のまま）。
struct WatchContentView: View {
    @Environment(WatchRecorder.self) private var recorder
    @Environment(\.scenePhase) private var scenePhase
    /// 並びは開いたときに決め、見ている間は動かさない
    @State private var pages: [WatchPages.Page] = WatchPages.order(WatchPages.counts())
    @State private var current: WatchPages.Page = .record

    var body: some View {
        TabView(selection: $current) {
            ForEach(pages, id: \.self) { page in
                pageView(page).tag(page)
            }
        }
        .tabViewStyle(.verticalPage)
        // 2秒以上見ていたら1回と数える（めくって通り過ぎただけのものは数えない）
        .task(id: current) {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { WatchPages.add(current) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recorder.refreshStatus() }
        }
        .onAppear { recorder.refreshStatus() }
    }

    @ViewBuilder
    private func pageView(_ page: WatchPages.Page) -> some View {
        switch page {
        case .record: RecordPage()
        case .tasks: TasksPage()
        case .next: NextEventPage()
        case .last: LastTalkPage()
        case .ask: AskPage()
        case .morning: MorningPage()
        case .status: StatusPage()
        }
    }
}

/// めくる画面の並び（2026-11-12）。録音はいつもいちばん上。ほかは、この時計で見た回数の多い順（同じなら前からの順）。
/// 回数は時計の中だけに数える。合わせて30回見るまでは、前からの順のまま（少ない回数で並びが揺れないように）。
enum WatchPages {
    enum Page: String, CaseIterable, Hashable {
        case record, tasks, next, last, ask, morning, status
    }

    static let key = "watchPageViews"
    /// これだけ見るまでは並べ替えない
    static let minimumViews = 30

    static func counts() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    static func add(_ page: Page) {
        var all = counts()
        all[page.rawValue, default: 0] += 1
        UserDefaults.standard.set(all, forKey: key)
    }

    /// 並び。録音がいちばん上で、残りは回数の多い順
    static func order(_ counts: [String: Int]) -> [Page] {
        let rest = Array(Page.allCases.dropFirst())
        let total = rest.reduce(0) { $0 + (counts[$1.rawValue] ?? 0) }
        guard total >= minimumViews else { return Page.allCases }
        let sorted = rest.enumerated().sorted { a, b in
            let ca = counts[a.element.rawValue] ?? 0
            let cb = counts[b.element.rawValue] ?? 0
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
        return [.record] + sorted
    }
}

/// 時刻の言い方（「10:30」）
private func clock(_ seconds: Double) -> String {
    Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
}

/// 日付つきの時刻（今日なら時刻だけ）
private func when(_ seconds: Double) -> String {
    let date = Date(timeIntervalSince1970: seconds)
    return Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.month().day().hour().minute())
}

/// 画面の見出し
private struct PageTitle: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// まだ iPhone から何も届いていないとき
private struct NothingYet: View {
    var body: some View {
        Text("まだ iPhone から届いていません。iPhone の LifeLog を開くと届きます。")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

// MARK: - 録音（前と同じ）

private struct RecordPage: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button {
                    Task { await recorder.toggle() }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 56))
                        .foregroundStyle(recorder.isRecording ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                Text(recorder.isRecording ? "録音中" : "停止中")
                    .font(.headline)
                if recorder.isRecording {
                    // 指のダブルタップでも押せる
                    Button {
                        recorder.mark()
                    } label: {
                        Label("印", systemImage: "star.fill")
                    }
                    .tint(.yellow)
                    .handGestureShortcut(.primaryAction)
                    // 初めての人と話しているときの印と、会議モード（2026-11-06）
                    HStack(spacing: 6) {
                        Button {
                            recorder.markNewPerson()
                        } label: {
                            Label("初めての人", systemImage: "person.badge.plus")
                                .font(.caption2)
                        }
                        Button {
                            recorder.toggleMeeting()
                        } label: {
                            Label(recorder.meetingOn ? "会議を終える" : "会議", systemImage: "person.3")
                                .font(.caption2)
                        }
                        .tint(recorder.meetingOn ? .orange : nil)
                    }
                }
                // さっき何て言った？（iPhone の記録の直近の3行。2026-11-06）
                Button {
                    recorder.askRecent()
                } label: {
                    if recorder.asking {
                        ProgressView()
                    } else {
                        Label("さっき何て言った？", systemImage: "text.bubble").font(.caption2)
                    }
                }
                if let answer = recorder.recentAnswer {
                    Text(answer)
                        .font(.caption2)
                        .multilineTextAlignment(.leading)
                        .onTapGesture { recorder.clearAnswer() }
                }
                if !recorder.message.isEmpty {
                    Text(recorder.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                // iPhone とのつながりと、送れていない録音
                VStack(spacing: 2) {
                    Text(recorder.link)
                    if recorder.unsent > 0 {
                        Text("iPhone に送っていない録音 \(recorder.unsent) 個")
                            .foregroundStyle(recorder.unsent >= ChunkCutter.scaled(4) ? .orange : .secondary)
                    }
                    if recorder.lowPower {
                        Text("低電力モード: 15分ほどごとにまとめて送ります")
                    }
                    // 電池が少ないので、区切りを自動で5分にしている（2026-11-07）
                    if recorder.batterySaving {
                        Text("電池が少ないので、5分ごとに区切っています")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - 頼まれごと

private struct TasksPage: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
        let board = recorder.board
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                PageTitle(text: "頼まれごと（\(board.openCount)）", symbol: "checklist")
                if board.info == nil {
                    NothingYet()
                } else if board.tasks.isEmpty {
                    Text("まだのものはありません。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(board.tasks) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.what)
                            .font(.footnote)
                        let sub = [item.due, item.from].compactMap { $0 }.joined(separator: "・")
                        if !sub.isEmpty {
                            Text(sub)
                                .font(.caption2)
                                .foregroundStyle(item.late == true ? .orange : .secondary)
                        }
                        Button {
                            board.markDone(item.id)
                        } label: {
                            Label("済み", systemImage: "checkmark")
                                .font(.caption2)
                        }
                        .tint(.green)
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }
        }
    }
}

// MARK: - 次の予定

private struct NextEventPage: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
        let board = recorder.board
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageTitle(text: "次の予定", symbol: "calendar")
                if board.info == nil {
                    NothingYet()
                } else if let event = board.info?.next {
                    Text(event.title).font(.footnote).bold()
                    Text(clock(event.start) + (event.end.map { "〜" + clock($0) } ?? ""))
                        .font(.caption2)
                    if let place = event.place {
                        Text(place).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let people = event.people, !people.isEmpty {
                        Text("会う人: " + people.joined(separator: "、")).font(.caption2)
                    }
                    if let brief = event.brief {
                        Text(brief)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("12時間以内の予定はありません。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - さっきの会話

private struct LastTalkPage: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
        let board = recorder.board
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageTitle(text: "さっきの会話", symbol: "text.bubble")
                // 会議の相棒（会議モードのあいだの宿題・聞き忘れ・決まったこと。2026-11-15）
                if let meeting = board.info?.meeting {
                    MeetingGlance(meeting: meeting)
                    Divider()
                }
                // 家の PC が書いている途中の下書き（仮。30分より前のものは出さない。2026-11-07）
                if let draft = board.info?.draft, let lines = draft.lines, !lines.isEmpty,
                   Date().timeIntervalSince1970 - draft.start < 30 * 60 {
                    Text("仮（\(clock(draft.start))〜・書いている途中）")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                if board.info == nil {
                    NothingYet()
                } else if let talk = board.info?.last {
                    Text(when(talk.start) + (talk.end.map { "〜" + clock($0) } ?? ""))
                        .font(.caption2)
                    if let title = talk.title {
                        Text(title).font(.footnote).bold()
                    }
                    if let people = talk.people, !people.isEmpty {
                        Text(people.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(Array((talk.points ?? []).enumerated()), id: \.offset) { _, point in
                        Text("・" + point).font(.caption2)
                    }
                } else {
                    Text("まだ閉じた会話はありません。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 聞く

private struct AskPage: View {
    @Environment(WatchRecorder.self) private var recorder
    @State private var text = ""

    var body: some View {
        let board = recorder.board
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageTitle(text: "記録に聞く", symbol: "questionmark.bubble")
                // 押すと、音声入力（話して入れる）か文字で入れられる
                TextField("聞きたいこと", text: $text)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    Label("聞く", systemImage: "paperplane")
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                if let question = board.question {
                    Text("質問: " + question).font(.caption2).foregroundStyle(.secondary)
                }
                if !board.askState.isEmpty, board.answer == nil {
                    HStack(spacing: 4) {
                        if board.asking { ProgressView().frame(width: 16, height: 16) }
                        Text(board.askState).font(.caption2)
                    }
                }
                if let answer = board.answer {
                    Text(answer).font(.footnote)
                }
            }
        }
    }

    private func send() {
        recorder.board.ask(text)
        text = ""
    }
}

// MARK: - 昨日と今日（2026-11-09。前の「朝の読み上げ」。声で読むのはやめた）

private struct MorningPage: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
        let board = recorder.board
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageTitle(text: "昨日と今日", symbol: "sun.max")
                if board.info == nil {
                    NothingYet()
                } else if let brief = board.info?.morning {
                    Text(brief.text).font(.footnote)
                } else {
                    Text("まだ今日の分がありません。iPhone の LifeLog を開くと作ります。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 様子

private struct StatusPage: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
        let board = recorder.board
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageTitle(text: "様子", symbol: "waveform.path.ecg")
                Text(recorder.link).font(.caption2)
                Text("時計から送っていない録音 \(recorder.unsent) 個")
                    .font(.caption2)
                    .foregroundStyle(recorder.unsent >= ChunkCutter.scaled(4) ? .orange : .primary)
                if let status = board.info?.status {
                    if let pending = status.pending {
                        Text("iPhone の文字起こし待ち \(pending) 件").font(.caption2)
                    }
                    if let processed = status.processed {
                        Text("最後に文字にした " + when(processed)).font(.caption2)
                    }
                }
                if let made = board.info?.made {
                    Text("iPhone から届いた " + when(made))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if recorder.lowPower {
                    Text("低電力モード: 15分ほどごとにまとめて送ります").font(.caption2).foregroundStyle(.secondary)
                }
                if recorder.batterySaving {
                    Text("電池が少ないので、5分ごとに区切っています（電池が戻れば短めに戻します）")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

import SwiftUI

/// 自分を知ってもらう（2026-11-19。s18）の画面。中身は KnowMe.swift。
/// 「直す」→「自分を知る」: 今日の問い（1 日 3 問まで）・今週の見立て（3 つ）・抜き打ち・録って残す・場所で自動に。
/// 「今日」: 朝の気分の 1 タップと、今日の問いへの入口。会話の「実はこう思ってた」・人のページの「この人とどうなりたいか」・
/// 記録に質問したときの「違う、なぜなら」。

extension Pipeline {
    /// 「直す」に数える、自分を知るのまだ答えていない数
    var knowMeCount: Int { KnowMeBook.shared.pendingCount }
}

/// 「直す」の「自分を知る」（答えるものがあるときは上の段に、無いときも入口を出す）
struct KnowMeFixSection: View {
    var body: some View {
        let book = KnowMeBook.shared
        Section {
            NavigationLink {
                KnowMeView()
            } label: {
                LabeledContent {
                    if book.pendingCount > 0 { Text("\(book.pendingCount)") }
                } label: {
                    Label("自分を知る", systemImage: "person.text.rectangle")
                }
            }
        } footer: {
            Text("1 日 3 問まで・見立て（仮）の当たり外れ・抜き打ち。一度答えたことは二度と聞きません。")
        }
    }
}

struct KnowMeView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = KnowMeBook.shared
        let day = KnowMeRules.dayKey(.now)
        List {
            Section {
                if book.openQuestions.isEmpty {
                    Text(book.local.todayQuestions.isEmpty ? "今日の問いはまだありません。家の PC につながると読みます。"
                         : "今日の分は答えました。また明日。").foregroundStyle(.secondary)
                }
                ForEach(book.openQuestions) { q in
                    KnowQuestionRow(question: q, day: day)
                }
            } header: {
                Text("今日の問い（\(book.openQuestions.count)/\(KnowMeRules.perDay)）")
            } footer: {
                Text("記録からは分からないことだけを、1 日 3 問まで聞きます。下書きがあるものは、違うときだけ直してください。")
            }
            Section {
                if book.local.weekHypotheses.isEmpty {
                    Text("今週の見立てはまだありません。").foregroundStyle(.secondary)
                }
                ForEach(book.local.weekHypotheses) { h in
                    KnowHypothesisRow(hypothesis: h, day: day)
                }
            } header: {
                Text("今週の見立て")
            } footer: {
                Text("AI が記録から立てた見立て（仮）です。事実ではありません。当たっているかを押すと、母艦の見立ての答え合わせに入ります。")
            }
            if !book.spots.isEmpty {
                Section {
                    ForEach(book.spots) { s in
                        KnowSpotRow(spot: s, day: day)
                    }
                } header: {
                    Text("抜き打ち（黙って入れたもの）")
                } footer: {
                    Text("聞かずに入れたものから週 5 件。違っていれば、その種類は聞くように戻ります。")
                }
            }
            KnowRecordSection()
            KnowGeoSettingsSection()
            Section {
                Text("時計の録音の画面の「違う、〇〇さん」に話すと、直前の会話の行といっしょに家の PC に送ります（だれのことかを読むのは家の PC）。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("声で直す")
            }
        }
        .navigationTitle("自分を知る")
        .countsOpen("knowMe")
        .task {
            await KnowMeBook.shared.refresh(pipeline.homePC)
            await KnowGeo.shared.sync()
        }
        .refreshable { await KnowMeBook.shared.refresh(pipeline.homePC, force: true) }
    }
}

/// 根拠 1 つ（その日の会話を開ける）
struct KnowEvidenceRow: View {
    let evidence: KnowEvidence

    var body: some View {
        if let day = evidence.day {
            NavigationLink {
                ConversationsView(day: day)
            } label: {
                text(day)
            }
        } else {
            text(nil)
        }
    }

    private func text(_ day: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("「" + evidence.text + "」").font(.caption)
            if let day {
                Text(AppFeeds.monthDay(day)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct KnowQuestionRow: View {
    let question: KnowQuestion
    let day: String
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        let book = KnowMeBook.shared
        VStack(alignment: .leading, spacing: 8) {
            if question.group == "hypothesis" {
                Text("見立て（仮）").font(.caption2.bold()).foregroundStyle(.orange)
            }
            Text(question.text)
            ForEach(Array(question.evidence.enumerated()), id: \.offset) { _, e in
                KnowEvidenceRow(evidence: e)
            }
            switch question.answer {
            case "yesno":
                HStack(spacing: 12) {
                    Button("はい") { book.voteHypothesis(question.id, value: "right", day: day) }
                    Button("いいえ") { book.voteHypothesis(question.id, value: "wrong", day: day) }
                    Button("わからない") { book.voteHypothesis(question.id, value: "unsure", day: day) }
                }
                .buttonStyle(.bordered)
            case "recheck":
                if let current = question.current {
                    Text("いま書いてあること: " + current).font(.caption).foregroundStyle(.secondary)
                }
                TextField("変わったなら、いまのこと（なくてよい）", text: $text, axis: .vertical).font(.callout)
                HStack(spacing: 12) {
                    Button("まだそう") { book.recheck(question, value: "still", note: nil) }
                    Button("変わった") { book.recheck(question, value: "changed", note: text) }
                    Button("もう古い") { book.recheck(question, value: "outdated", note: text) }
                }
                .buttonStyle(.bordered)
            case "record":
                KnowRecordButtons(kind: question.group == "family" ? "family_childhood" : "ask_friend", questionID: question.id)
                Button("今日はいい") { book.skip(question, day: day) }.font(.caption)
            default:
                if let draft = question.draft, !editing {
                    Text("下書き（AI）: " + draft).font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("このままでよい") { book.draftOK(question, day: day) }
                        Button("直す") {
                            text = draft
                            editing = true
                        }
                        Button("今日はいい") { book.skip(question, day: day) }
                    }
                    .buttonStyle(.bordered)
                } else {
                    TextField("答え", text: $text, axis: .vertical).lineLimit(1...5)
                    HStack(spacing: 12) {
                        Button("残す") { _ = book.answer(question, text: text, day: day) }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("今日はいい") { book.skip(question, day: day) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct KnowHypothesisRow: View {
    let hypothesis: KnowHypothesis
    let day: String
    @State private var showWhy = false

    var body: some View {
        let book = KnowMeBook.shared
        let answered: String? = book.hypothesisAnswer(hypothesis.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(hypothesis.label).font(.caption2.bold()).foregroundStyle(.orange)
                if hypothesis.tier == "tentative" {
                    Text("仮").font(.caption2.bold()).padding(.horizontal, 4).background(Color.orange.opacity(0.2), in: Capsule())
                }
            }
            Text(hypothesis.text)
            if !hypothesis.why.isEmpty {
                Text(hypothesis.why).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(hypothesis.evidence.enumerated()), id: \.offset) { _, e in
                KnowEvidenceRow(evidence: e)
            }
            if let answered {
                Text(knowAnsweredLabel(answered, right: "当たり")).font(.caption).foregroundStyle(.secondary)
                if answered == "wrong" {
                    WhyWrongRow(target: "hypothesis", head: hypothesis.text, question: nil)
                }
            } else {
                HStack(spacing: 12) {
                    Button("当たり") { book.voteHypothesis(hypothesis.id, value: "right", day: day) }
                    Button("違う") { book.voteHypothesis(hypothesis.id, value: "wrong", day: day) }
                    Button("わからない") { book.voteHypothesis(hypothesis.id, value: "unsure", day: day) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }
}

struct KnowSpotRow: View {
    let spot: KnowSpot
    let day: String

    var body: some View {
        let book = KnowMeBook.shared
        VStack(alignment: .leading, spacing: 6) {
            Text(spot.claim)
            if !spot.note.isEmpty {
                Text(spot.note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(spot.evidence.enumerated()), id: \.offset) { _, e in
                KnowEvidenceRow(evidence: e)
            }
            if let answered = book.spotAnswer(spot.id) {
                Text(knowAnsweredLabel(answered, right: "合ってる")).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button("合ってる") { book.voteSpot(spot.id, value: "right", day: spot.day ?? day) }
                    Button("違う") { book.voteSpot(spot.id, value: "wrong", day: spot.day ?? day) }
                    Button("わからない") { book.voteSpot(spot.id, value: "unsure", day: spot.day ?? day) }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - 録って残す（4・11・30）

struct KnowRecordButtons: View {
    let kind: String
    let questionID: String?

    var body: some View {
        let book = KnowMeBook.shared
        if book.markOpen {
            Button("録り終えた（印を付ける）") { book.endMark() }
                .buttonStyle(.borderedProminent)
        } else {
            Button("録り始める") { Task { await book.startMark(kind: kind, questionID: questionID) } }
                .buttonStyle(.bordered)
        }
    }
}

struct KnowRecordSection: View {
    var body: some View {
        let book = KnowMeBook.shared
        Section {
            if book.markOpen {
                Text("録っています（" + label(book.markKind ?? "") + "）。終わったら押してください。").font(.callout)
                KnowRecordButtons(kind: book.markKind ?? "other", questionID: nil)
            } else {
                row("週 1 回、5 分しゃべる振り返り", kind: "weekly_talk")
                row("親しい人に「俺ってどんな人？」と聞く", kind: "ask_friend")
                row("家族に子どもの頃の話を聞く", kind: "family_childhood")
            }
        } header: {
            Text("録って残す")
        } footer: {
            Text("押すと録音を始め（録音中ならそのまま）、始まりと終わりに印を付けて家の PC に送ります。相手には録ることを伝えてください。")
        }
    }

    private func row(_ title: String, kind: String) -> some View {
        Button(title) { Task { await KnowMeBook.shared.startMark(kind: kind, questionID: nil) } }
    }

    private func label(_ kind: String) -> String {
        switch kind {
        case "weekly_talk": "週の振り返り"
        case "ask_friend": "親しい人に聞く"
        case "family_childhood": "子どもの頃の話"
        default: "録って残す"
        }
    }
}

// MARK: - 場所で自動に（57）と知らせ（62・11）

struct KnowGeoSettingsSection: View {
    @AppStorage(KnowMeSettings.workRecordKey) private var workRecord = false
    @AppStorage(KnowMeSettings.homeRushKey) private var homeRush = true
    @AppStorage(KnowMeSettings.noticeKey) private var notice = true
    @AppStorage(KnowMeSettings.weeklyTalkKey) private var weeklyTalk = true

    var body: some View {
        Section {
            Toggle("職場に着いたら録音を始めてみる", isOn: $workRecord)
            Toggle("家に着いたら取り込みを急ぐ", isOn: $homeRush)
            Toggle("1 日 1 回、通知の上で「はい・いいえ」", isOn: $notice)
            Toggle("日曜の夜に振り返りを促す", isOn: $weeklyTalk)
                .onChange(of: weeklyTalk) { KnowMeBook.scheduleWeeklyTalk() }
            let sums: [String: Int] = Tally.sums(days: 30)
            let ok: Int = sums["know.geo.bgrec.ok"] ?? 0
            let fail: Int = sums["know.geo.bgrec.fail"] ?? 0
            if ok + fail > 0 {
                Text("職場で裏から始められた \(ok) 回・始められなかった \(fail) 回").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("場所で自動に・知らせ")
        } footer: {
            Text("登録した場所の「職場」と「自宅」を見張ります（位置の「常に」の許可が要ります）。iOS は裏からマイクを起こすことを許さないことが多いので、始められなかったときは「録音を始める」ボタンの付いた知らせを出します。確実に始めたいときは、ショートカットのオートメーション「職場に到着したとき」で LifeLog の「録音を始める」を選んでください。通知の「はい・いいえ」は時計にも出て、時計で押せます。")
        }
    }
}

// MARK: - 今日（6 朝の 1 タップと、今日の問いの入口）

struct KnowMeTodaySection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let book = KnowMeBook.shared
        let morning = KnowMeRules.isMorning(.now)
        let tapped: Int? = book.moodTapped(slot: "morning")
        let open = book.openQuestions.count
        if (morning && tapped == nil) || open > 0 {
            Section {
                if morning && tapped == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("けさの気分").font(.subheadline.bold())
                        HStack(spacing: 10) {
                            ForEach(1...5, id: \.self) { n in
                                Button {
                                    book.moodTap(slot: "morning", mood: n)
                                } label: {
                                    Text(face(n)).font(.title2)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(n)")
                            }
                        }
                        Text("左がわるい・右がよい。押すだけで残ります（夜は「夜の10秒」）。").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if open > 0 {
                    NavigationLink {
                        KnowMeView()
                    } label: {
                        LabeledContent("今日の問い", value: "あと \(open) 問")
                    }
                }
            } header: {
                Text("自分を知る")
            }
            .task { await KnowMeBook.shared.refresh(pipeline.homePC) }
        }
    }

    private func face(_ n: Int) -> String {
        ["😣", "🙁", "😐", "🙂", "😄"][max(0, min(4, n - 1))]
    }
}

// MARK: - 会話の「実はこう思ってた」（7）

struct ConversationNoteRow: View {
    let day: String
    let start: Date
    @State private var open = false
    @State private var text = ""

    var body: some View {
        let book = KnowMeBook.shared
        if let saved = book.savedNote(day: day, start: start) {
            Text("実は: " + saved).font(.caption).foregroundStyle(.secondary)
        } else if open {
            TextField("実はこう思ってた", text: $text, axis: .vertical).font(.callout)
            HStack(spacing: 16) {
                Button("残す") {
                    book.note(day: day, start: start, text: text)
                    open = false
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("やめる") { open = false }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } else {
            Button("実はこう思ってた", systemImage: "text.bubble") { open = true }
                .font(.caption)
        }
    }
}

// MARK: - 人ごとの「この人とどうなりたいか」（9）

struct PersonGoalSection: View {
    let name: String
    let pe: String?
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        let book = KnowMeBook.shared
        Section {
            if let saved = book.savedGoal(person: name, pe: pe), !editing {
                Text(saved)
                Button("書き直す") {
                    text = saved
                    editing = true
                }
                .font(.caption)
            } else {
                TextField("例: 気軽に相談できる間がら", text: $text, axis: .vertical)
                Button("残す") {
                    book.goal(person: name, pe: pe, text: text)
                    editing = false
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("この人とどうなりたいか")
        } footer: {
            Text("1 行で十分です。家の PC（母艦）に送ります。")
        }
    }
}

// MARK: - 「違う、なぜなら」（42）

/// AI の答えが的外れなとき、理由を 1 つ押すだけで残す（文は足しても足さなくてもよい）
struct WhyWrongRow: View {
    let target: String
    let head: String?
    let question: String?
    @State private var open = false
    @State private var why = ""
    @State private var sent = false

    var body: some View {
        if sent {
            Text("「違う」の理由を残しました").font(.caption).foregroundStyle(.secondary)
        } else if open {
            VStack(alignment: .leading, spacing: 6) {
                TextField("なぜなら（なくてよい）", text: $why).font(.callout)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(KnowMeRules.whyReasons.indices, id: \.self) { i in
                            Button(KnowMeRules.whyReasons[i].label) { send(KnowMeRules.whyReasons[i].id) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
            }
        } else {
            Button("違う、なぜなら", systemImage: "exclamationmark.bubble") { open = true }
                .font(.caption)
                .buttonStyle(.borderless)
        }
    }

    private func send(_ reason: String) {
        let text: String? = why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : why
        sent = KnowMeBook.shared.whyWrong(target: target, reason: reason, why: text, head: head, question: question)
    }
}

/// 押した答えの言い方
func knowAnsweredLabel(_ value: String, right: String) -> String {
    switch value {
    case "right": "「" + right + "」にしました"
    case "wrong": "「違う」にしました"
    default: "「わからない」にしました"
    }
}

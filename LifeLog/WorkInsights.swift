import SwiftUI

/// 仕事の中身を、あとから聞ける・読めるようにする（2026-11-10）。どれも取り込んだ「仕事のまとめ」と頼まれごと帳から作り、言語モデルは使わない。
/// - 週のまとめ（週報の下書き）: その週に決まったこと・残っている宿題・済んだこと・人ごとの動き・あとで確かめること
/// - 案件ごと: 【よく出た言葉】のうち、2日以上のまとめに出てきた言葉ごとに、その言葉の出る行を日の順に
/// - 会議の前に: これからの予定で会う人ごとに、残っている頼まれごとと、その人の出るまとめの行
/// - 人の画面: その人の出るまとめの行
/// - Siri の「今日の宿題」
extension Pipeline {
    // MARK: 週

    struct WorkWeek {
        /// 月曜と日曜（yyyy-MM-dd）
        var start: String
        var end: String
        /// まとめのあった日
        var days: [String] = []
        var decided: [(day: String, text: String)] = []
        /// 人ごとの動き（「名前: …」の名前で分ける。名前の無い行は「そのほか」）
        var others: [(person: String, lines: [String])] = []
        var checks: [String] = []
        /// その週に済んだ仕事の頼まれごと
        var done: [TaskBook.Item] = []
        /// まだの仕事の頼まれごと（期限の近い順に15件まで）
        var open: [TaskBook.Item] = []
    }

    /// date を含む週（月曜から日曜）の月曜の0時
    static func weekStart(_ date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)  // 1 = 日曜
        let back = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    /// 「名前: …」「名前：…」の名前（20字まで。無ければ nil）
    static func digestPerson(_ line: String) -> (person: String, text: String)? {
        guard let i = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let name = line[..<i].trimmingCharacters(in: .whitespaces)
        let rest = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 20, !rest.isEmpty else { return nil }
        return (name, rest)
    }

    static func workWeek(_ entries: [WorkDigest.Entry], tasks: [TaskBook.Item], weekOf date: Date,
                         now: Date = .now, calendar: Calendar = .current) -> WorkWeek {
        let monday = weekStart(date, calendar: calendar)
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday) ?? monday
        let next = calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
        var week = WorkWeek(start: TaskBook.dayFormat.string(from: monday), end: TaskBook.dayFormat.string(from: sunday))
        var seen: Set<String> = []
        var people: [String: [String]] = [:]
        var order: [String] = []
        // 古い日から読む
        for entry in entries.filter({ $0.day >= week.start && $0.day <= week.end }).sorted(by: { $0.day < $1.day }) {
            if !week.days.contains(entry.day) { week.days.append(entry.day) }
            for line in workDigestLines(entry) {
                guard seen.insert(line.heading + "|" + WorkDigestParser.compact(line.text)).inserted else { continue }
                switch line.heading {
                case "決まったこと":
                    week.decided.append((entry.day, line.text))
                case "ほかの人の動き":
                    let split = digestPerson(line.text)
                    let person: String = split?.person ?? "そのほか"
                    if people[person] == nil { order.append(person) }
                    people[person, default: []].append(split?.text ?? line.text)
                case "あとで確かめること":
                    week.checks.append(line.text)
                default:
                    break
                }
            }
        }
        // 名前のある人を先に、「そのほか」は最後
        week.others = order.filter { $0 != "そのほか" }.map { (person: $0, lines: people[$0] ?? []) }
        if let rest = people["そのほか"] { week.others.append((person: "そのほか", lines: rest)) }
        week.done = tasks.filter { item in
            guard item.isWork, item.state == .done, let at = item.doneAt else { return false }
            return at >= monday && at < next
        }
        .sorted { ($0.doneAt ?? $0.updated) < ($1.doneAt ?? $1.updated) }
        week.open = Array(tasks.filter { $0.isWork && $0.state == .open }.sorted(by: TaskBook.dueOrder).prefix(15))
        return week
    }

    /// 週報の下書き（コピーして使う文）
    static func workWeekText(_ week: WorkWeek) -> String {
        var out: [String] = ["週のまとめ \(workDigestDayTitle(week.start))〜\(workDigestDayTitle(week.end))"]
        func block(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out.append("")
            out.append("【" + title + "】")
            out += lines.map { "・" + $0 }
        }
        block("決まったこと", week.decided.map { $0.text })
        block("済んだこと", week.done.map(\.what))
        block("残っていること", week.open.map { item in
            item.what + (item.due.map { "（" + taskDueText($0) + "）" } ?? "")
        })
        if !week.others.isEmpty {
            out.append("")
            out.append("【人ごとの動き】")
            for group in week.others {
                out.append(group.person)
                out += group.lines.map { "・" + $0 }
            }
        }
        block("あとで確かめること", week.checks)
        return out.joined(separator: "\n")
    }

    // MARK: 案件

    struct WorkThread: Identifiable, Equatable {
        let word: String
        /// その言葉の出たまとめの日（古い日から）
        let days: [String]
        var id: String { word }
    }

    /// 案件ごと: 【よく出た言葉】の言葉のうち、days 日のうちに2日以上のまとめの行に出てきたもの（出た日の多い順・同じなら新しい順。30まで）
    static func workThreads(_ entries: [WorkDigest.Entry], now: Date = .now, days: Int = 30) -> [WorkThread] {
        let since: String = TaskBook.dayFormat.string(from: now.addingTimeInterval(-Double(days) * 86400))
        let recent: [WorkDigest.Entry] = entries.filter { $0.day >= since }
        var words: [String] = []
        for entry in recent {
            for word in entry.sections?.words ?? [] where word.count >= 2 && !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                words.append(word)
            }
        }
        var out: [WorkThread] = []
        for word in words {
            var hit: Set<String> = []
            for entry in recent where workDigestLines(entry).contains(where: { $0.heading != "よく出た言葉" && $0.text.localizedCaseInsensitiveContains(word) }) {
                hit.insert(entry.day)
            }
            if hit.count >= 2 { out.append(WorkThread(word: word, days: hit.sorted())) }
        }
        return Array(out.sorted { a, b in
            a.days.count != b.days.count ? a.days.count > b.days.count : (a.days.last ?? "") > (b.days.last ?? "")
        }.prefix(30))
    }

    /// 案件の行（古い日から。「よく出た言葉」の行は除く）
    static func workThreadLines(_ word: String, in entries: [WorkDigest.Entry]) -> [DigestHit] {
        searchWorkDigests(word, in: entries, limit: 200)
            .filter { $0.heading != "よく出た言葉" }
            .sorted { $0.day != $1.day ? $0.day < $1.day : $0.index < $1.index }
    }

    // MARK: 人・会議の前

    /// その人の出るまとめの行（新しい日から。「出どころ」と「よく出た言葉」の行は除く）
    static func digestLines(about name: String, in entries: [WorkDigest.Entry], limit: Int = 10) -> [DigestHit] {
        let key: String = nameKey(name)
        guard key.count >= 2 else { return [] }
        return Array(searchWorkDigests(key, in: entries, limit: limit * 3)
            .filter { $0.heading != "出どころ" && $0.heading != "よく出た言葉" }
            .prefix(limit))
    }

    /// 会う人との、残っている頼まれごとと、その人の出るまとめの行（新しい日から3行まで）
    static func meetingPrep(name: String, tasks: [TaskBook.Item], digests: [WorkDigest.Entry])
        -> (tasks: [TaskBook.Item], lines: [DigestHit]) {
        let mine: [TaskBook.Item] = tasks.filter { item in
            item.state == .open && item.from.map { sameName($0, name) } == true
        }
        return (mine, digestLines(about: name, in: digests, limit: 3))
    }

    /// これから24時間の予定のうち、名前のある人に会うもの（会議の前に読む画面）
    func upcomingMeetings(now: Date = .now) -> [(event: CalendarLink.Event, names: [String])] {
        let events = calendar.dayEvents(from: now.addingTimeInterval(-30 * 60), to: now.addingTimeInterval(24 * 3600))
            .filter { $0.end > now }
            .sorted { $0.start < $1.start }
        let named = people.filter { $0.isNamed && !$0.isSelf && $0.hidden != true }.map(\.displayName)
        var out: [(event: CalendarLink.Event, names: [String])] = []
        for event in events {
            let names: [String] = named.filter { name in
                let key = Self.nameKey(name)
                return event.attendees.contains { Self.sameName($0, name) } || (key.count >= 2 && event.title.contains(key))
            }
            if !names.isEmpty { out.append((event, names)) }
        }
        return out
    }

    // MARK: 職場の自分の声

    /// 直近 days 日の職場の会話で、声（人の id）ごとに話した行の数（自分の声を探す画面で使う）
    func workSpeakerLines(days: Int = 14, now: Date = .now) -> [String: Int] {
        let since: String = TaskBook.dayFormat.string(from: now.addingTimeInterval(-Double(days) * 86400))
        var counts: [String: Int] = [:]
        for day in recordedDays() where day >= since {
            for c in conversations(on: day) {
                for line in c.lines {
                    guard let id = line.speakerID, id != SpeakerLabeler.selfID, isWorkTime(line.time) else { continue }
                    counts[id, default: 0] += 1
                }
            }
        }
        return counts
    }

    // MARK: Siri

    /// 「今日の宿題」: 期限を過ぎた・今日までの仕事の頼まれごと（人を待っているものは除く）と、今日のまとめの宿題（5つまで）
    func todayHomework(now: Date = .now) -> String {
        let end: Date = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        let today: String = TaskBook.dayFormat.string(from: now)
        var picked: [TaskBook.Item] = tasks.todo.filter { $0.isWork && ($0.due ?? .distantFuture) < end }
        for item in tasks.todo where item.isWork && item.digestDay == today && !picked.contains(where: { $0.id == item.id }) {
            picked.append(item)
        }
        guard !picked.isEmpty else { return "今日までの仕事の宿題はありません。" }
        let lines: [String] = picked.prefix(5).map { item in
            item.what + (item.due.map { "（" + Self.taskDueText($0) + "）" } ?? "")
        }
        var text = "今日までの仕事の宿題は \(picked.count) 件です。" + lines.joined(separator: "。")
        if picked.count > 5 { text += "。ほか \(picked.count - 5) 件" }
        return text + "。"
    }
}

// MARK: - 画面

/// 週のまとめ（週報の下書き）。週を前後に動かせる。下の「コピー」で文にする
struct WorkWeekView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var offset = 0
    @State private var copied = false

    var body: some View {
        let date: Date = Date.now.addingTimeInterval(Double(offset) * 7 * 86400)
        let week = Pipeline.workWeek(pipeline.workDigests.sorted, tasks: pipeline.tasks.items, weekOf: date)
        List {
            Section {
                HStack {
                    Button("前の週", systemImage: "chevron.left") { offset -= 1; copied = false }
                    Spacer()
                    Text(Pipeline.workDigestDayTitle(week.start) + "〜").font(.subheadline)
                    Spacer()
                    Button("次の週", systemImage: "chevron.right") { offset += 1; copied = false }
                        .disabled(offset >= 0)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                Button(copied ? "コピーしました" : "週報の下書きをコピー", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = Pipeline.workWeekText(week)
                    copied = true
                }
            } footer: {
                Text("その週の「仕事のまとめ」（\(week.days.count) 日分）と、頼まれごと帳の仕事のものから作ります。言語モデルは使いません。")
            }
            if !week.decided.isEmpty {
                Section("決まったこと") {
                    ForEach(Array(week.decided.enumerated()), id: \.offset) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.element.text)
                            Text(Pipeline.workDigestDayTitle(item.element.day)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !week.done.isEmpty {
                Section("済んだこと（\(week.done.count)）") {
                    ForEach(week.done) { Text($0.what) }
                }
            }
            if !week.open.isEmpty {
                Section("残っていること") {
                    ForEach(week.open) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.what)
                            if let due = item.due {
                                Text(Pipeline.taskDueText(due)).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            ForEach(Array(week.others.enumerated()), id: \.offset) { group in
                Section(group.element.person) {
                    ForEach(Array(group.element.lines.enumerated()), id: \.offset) { Text($0.element) }
                }
            }
            if !week.checks.isEmpty {
                Section("あとで確かめること") {
                    ForEach(Array(week.checks.enumerated()), id: \.offset) { Text($0.element) }
                }
            }
            if week.days.isEmpty && week.done.isEmpty {
                Section { Text("この週のまとめはありません").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("週のまとめ")
    }
}

/// 案件ごと（よく出た言葉ごとに、その言葉の出る行を日の順に）
struct WorkThreadsView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let threads = Pipeline.workThreads(pipeline.workDigests.sorted)
        List {
            if threads.isEmpty {
                Section {
                    Text("まだありません").foregroundStyle(.secondary)
                } footer: {
                    Text("まとめの【よく出た言葉】のうち、30日のうちに2日以上のまとめに出てきた言葉が、ここに並びます。")
                }
            } else {
                Section {
                    ForEach(threads) { thread in
                        NavigationLink {
                            WorkThreadView(word: thread.word)
                        } label: {
                            LabeledContent(thread.word) {
                                Text("\(thread.days.count) 日・最後 " + Pipeline.workDigestDayTitle(thread.days.last ?? ""))
                            }
                        }
                    }
                } footer: {
                    Text("まとめの【よく出た言葉】のうち、30日のうちに2日以上のまとめに出てきた言葉です。押すと、その言葉の出る行を日の順に読めます。")
                }
            }
        }
        .navigationTitle("案件ごと")
    }
}

/// 1つの案件（言葉）の流れ
struct WorkThreadView: View {
    @Environment(Pipeline.self) private var pipeline
    let word: String

    var body: some View {
        let lines = Pipeline.workThreadLines(word, in: pipeline.workDigests.sorted)
        let related: [TaskBook.Item] = pipeline.tasks.items.filter { item in
            (item.state == .open || item.state == .done) && item.what.localizedCaseInsensitiveContains(word)
        }
        List {
            if !related.isEmpty {
                Section("頼まれごと") {
                    ForEach(related) { item in
                        Label {
                            Text(item.what).strikethrough(item.state == .done)
                        } icon: {
                            Image(systemName: item.state == .done ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            Section {
                ForEach(lines) { DigestHitRow(hit: $0) }
            } header: {
                Text("まとめの行（古い日から）")
            }
        }
        .navigationTitle(word)
    }
}

/// 会議の前に（これから24時間の予定で会う人ごとに、残っている頼まれごとと、その人の出るまとめの行）
struct MeetingPrepView: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let meetings = pipeline.upcomingMeetings()
        List {
            if meetings.isEmpty {
                Section {
                    Text("これから24時間に、名前のある人と会う予定はありません").foregroundStyle(.secondary)
                } footer: {
                    Text("カレンダーの予定の参加者か、予定名に入っている名前で、会う人を決めます。")
                }
            }
            ForEach(Array(meetings.enumerated()), id: \.offset) { meeting in
                Section {
                    ForEach(meeting.element.names, id: \.self) { name in
                        let prep = Pipeline.meetingPrep(name: name, tasks: pipeline.tasks.open, digests: pipeline.workDigests.sorted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.headline)
                            if prep.tasks.isEmpty && prep.lines.isEmpty {
                                Text("残っている頼まれごと・まとめの行はありません").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(prep.tasks) { item in
                                Label(item.what, systemImage: "circle").font(.callout)
                            }
                            ForEach(prep.lines) { line in
                                Text(Pipeline.workDigestDayTitle(line.day) + "・" + line.heading + ": " + line.text)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(meeting.element.event.start.formatted(date: .omitted, time: .shortened) + " "
                         + (meeting.element.event.title.isEmpty ? "予定" : meeting.element.event.title))
                }
            }
        }
        .navigationTitle("会議の前に")
    }
}

/// 人の画面に出す、その人の出る仕事のまとめの行（2026-11-10）
struct PersonDigestSection: View {
    @Environment(Pipeline.self) private var pipeline
    let name: String

    var body: some View {
        let lines = Pipeline.digestLines(about: name, in: pipeline.workDigests.sorted, limit: 10)
        if !lines.isEmpty {
            Section {
                ForEach(lines) { DigestHitRow(hit: $0) }
            } header: {
                Text("仕事のまとめから（最近の動き）")
            } footer: {
                Text("取り込んだ「仕事のまとめ」で、この人の名前が出てくる行です（新しい日から10行まで）。")
            }
        }
    }
}

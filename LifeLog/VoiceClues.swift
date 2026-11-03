import SwiftUI

/// 名前の無い声が誰かを、声のほかの手がかりから探す。声だけでは誰か分かりにくいので、
/// その声が話したこと・出てきた会話（時刻・場所・予定・一緒にいた人）と、名前の候補
/// （「〇〇さん」と呼ばれたすぐあとに話した・その時間の予定の参加者・声の近い人）を集める。
/// 候補は出すだけで、名前を付けたりまとめたりするのは押したときだけ。
extension Pipeline {
    /// その声が出てきた会話1つ
    struct VoiceTalk: Identifiable {
        let conversation: ConversationLog.Conversation
        /// この声の行（長いものから3つまで、時刻順）と、再生を止める位置
        let lines: [(line: ConversationLog.Line, end: TimeInterval?)]
        /// この会話でのこの声の行の数
        let count: Int
        /// 一緒にいた、名前のある人（自分とこの声を除く）
        let others: [String]
        var id: Date { conversation.start }

        static let date: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "M/d(E) H:mm"
            return f
        }()
        static let time: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "H:mm"
            return f
        }()

        /// 「11/2(日) 14:05〜14:40　会社　〔定例〕」
        var heading: String {
            var parts = [Self.date.string(from: conversation.start) + "〜" + Self.time.string(from: conversation.end)]
            if let place = conversation.place { parts.append(place) }
            if let event = conversation.event { parts.append("〔\(event)〕") }
            return parts.joined(separator: "　")
        }
    }

    /// 名前の候補。target があればその人にまとめ、無ければ name を付ける。
    struct NameCandidate: Identifiable {
        var name: String
        var target: String?
        var reasons: [String]
        var score: Int
        var id: String { target ?? name }
    }

    struct VoiceClues {
        var talks: [VoiceTalk] = []
        var candidates: [NameCandidate] = []
        /// よく話した1行（一覧に添える）
        var sample: String?
    }

    /// 予定の参加者を調べる会話の数（声ごとに新しいものから）
    private static let calendarTalks = 20
    /// 声が似ていると候補に出す距離と、よく似ているとする距離
    private static let voiceShowLimit: Float = 0.55
    private static let voiceCloseLimit: Float = 0.40

    /// 声ごとの手がかり。記録を新しい日から1回だけ読む。
    /// talkLimit は集める会話の数（0 なら集めない）。予定と声の近さは、それぞれ withCalendar・withVoice のときだけ調べる。
    func voiceClues(for ids: Set<String>, talkLimit: Int = 5, withCalendar: Bool = true,
                    withVoice: Bool = true) async -> [String: VoiceClues] {
        guard !ids.isEmpty else { return [:] }
        var talks: [String: [VoiceTalk]] = [:]
        var called: [String: [String: Int]] = [:]
        /// 自分で名乗った名前（「田中と申します」「田中です、よろしく」）
        var introduced: [String: [String: Int]] = [:]
        var attendees: [String: [String: (score: Int, count: Int, events: [String])]] = [:]
        var calendarChecked: [String: Int] = [:]

        for day in recordedDays() {
            for c in conversations(on: day).reversed() where c.media == nil {
                let lines = c.lines
                let present = Set(lines.filter { $0.media == nil }.compactMap(\.speakerID)).intersection(ids)
                guard !present.isEmpty else { continue }

                // 「〇〇さん」と呼ばれたすぐあと（20秒以内）に、別の声で答えた人
                for (i, line) in lines.enumerated()
                where line.text.contains("さん") || line.text.contains("くん") || line.text.contains("ちゃん") {
                    guard let reply = lines[(i + 1)...].prefix(3).first(where: {
                              $0.speakerID != nil && $0.speakerID != line.speakerID
                                  && $0.time.timeIntervalSince(line.time) <= 20
                          }),
                          let rid = reply.speakerID, present.contains(rid) else { continue }
                    for name in Self.calledNames(in: line.text) { called[rid, default: [:]][name, default: 0] += 1 }
                }

                var event: CalendarLink.Event?
                var eventLooked = false
                for id in present {
                    let mine = lines.indices.filter { lines[$0].speakerID == id && lines[$0].media == nil }
                    let ownNames = Set(mine.compactMap { lines[$0].speaker })
                    let others = c.people.filter { !$0.hasPrefix("人物") && !ownNames.contains($0) }
                    for i in mine {
                        for name in Self.introducedNames(in: lines[i].text) { introduced[id, default: [:]][name, default: 0] += 1 }
                    }

                    if talks[id, default: []].count < talkLimit {
                        // 長い行から3つ。再生は同じ音声の次の行まで（最長15秒）
                        let picked = mine.sorted { lines[$0].text.count > lines[$1].text.count }.prefix(3).sorted()
                        let shown = picked.map { i -> (line: ConversationLog.Line, end: TimeInterval?) in
                            let line = lines[i]
                            guard let offset = line.offset, line.audio != nil else { return (line, nil) }
                            let next = lines[(i + 1)...].first { $0.audio == line.audio }?.offset
                            return (line, min(offset + 15, next ?? offset + 15))
                        }
                        talks[id, default: []].append(VoiceTalk(conversation: c, lines: shown, count: mine.count, others: others))
                    }

                    // その時間の予定の参加者（一緒にいたと分かっている人は除く）
                    guard withCalendar, calendarChecked[id, default: 0] < Self.calendarTalks else { continue }
                    calendarChecked[id, default: 0] += 1
                    if !eventLooked {
                        event = calendar.events(from: c.start, to: c.end).first
                        eventLooked = true
                    }
                    guard let event, !event.attendees.isEmpty else { continue }
                    // 参加者が多い予定ほど、この声がその人である見込みは低い
                    let weight = event.attendees.count <= 3 ? 2 : 1
                    for name in event.attendees where !others.contains(where: { Self.sameName($0, name) }) {
                        var entry = attendees[id, default: [:]][name] ?? (0, 0, [])
                        entry.score += weight
                        entry.count += 1
                        if !event.title.isEmpty && !entry.events.contains(event.title) { entry.events.append(event.title) }
                        attendees[id, default: [:]][name] = entry
                    }
                }
            }
        }

        var result: [String: VoiceClues] = [:]
        for id in ids {
            var list: [NameCandidate] = []
            func add(_ name: String, reason: String, score: Int, target: String? = nil) {
                let target = target ?? namedPerson(matching: name, excluding: id)
                let shown = target.flatMap { t in people.first { $0.id == t }?.displayName } ?? name
                if let i = list.firstIndex(where: { (target != nil && $0.target == target) || Self.sameName($0.name, shown) }) {
                    list[i].reasons.append(reason)
                    list[i].score += score
                    if list[i].target == nil, let target {
                        list[i].target = target
                        list[i].name = shown
                    }
                } else {
                    list.append(NameCandidate(name: shown, target: target, reasons: [reason], score: score))
                }
            }
            for (name, count) in (introduced[id] ?? [:]).sorted(by: { $0.value > $1.value }) {
                add(name, reason: "自分で「\(name)」と名乗っていた（\(count)回）", score: min(count, 3) * 3)
            }
            for (name, count) in (called[id] ?? [:]).sorted(by: { $0.value > $1.value }) {
                add(name, reason: "「\(name)さん」と呼ばれたあとに話した（\(count)回）", score: min(count, 3) * 3)
            }
            for (name, entry) in (attendees[id] ?? [:]).sorted(by: { $0.value.score > $1.value.score }) {
                let events = entry.events.first.map { "予定「\($0)」" + (entry.events.count > 1 ? "ほか" : "") } ?? "予定"
                add(name, reason: "\(events)の参加者（\(entry.count)回）", score: min(entry.score, 6))
            }
            if withVoice, let voice = await voiceSuggestion(for: id), voice.distance <= Self.voiceShowLimit {
                let close = voice.distance <= Self.voiceCloseLimit
                add(voice.name, reason: close ? "声がよく似ている" : "声が少し似ている", score: close ? 4 : 2, target: voice.id)
            }
            list.sort { $0.score > $1.score }
            let lines = (talks[id] ?? []).flatMap(\.lines).map(\.line.text)
            result[id] = VoiceClues(talks: talks[id] ?? [], candidates: Array(list.prefix(4)),
                                    sample: lines.max { $0.count < $1.count })
        }
        return result
    }

    /// 声のひとこまが、記録のどの行の声か（その時に話していた文・時刻・場所・記録の名前）
    struct SampleInfo {
        let time: Date
        let text: String
        /// その行の記録の名前（ひとこまの人と違えば、別の人の声を拾っているかもしれない）
        let speakers: [String]
        let place: String?

        /// 「11/2(日) 14:05・会社」
        var caption: String {
            ([VoiceTalk.date.string(from: time)] + (place.map { [$0] } ?? [])).joined(separator: "・")
        }
    }

    /// 声のひとこまごとに、同じ音声でその時間に重なる行を探す。録音から取った声でなければ（登録で録った声など）入らない。
    func sampleInfo(for samples: [SpeakerLabeler.Sample]) -> [SpeakerLabeler.Sample: SampleInfo] {
        let audios = Set(samples.map(\.audio))
        guard !audios.isEmpty else { return [:] }
        var byAudio: [String: [(line: ConversationLog.Line, place: String?)]] = [:]
        for day in recordedDays() {
            for c in conversations(on: day) {
                for line in c.lines where line.offset != nil {
                    if let audio = line.audio, audios.contains(audio) { byAudio[audio, default: []].append((line, c.place)) }
                }
            }
        }
        var result: [SpeakerLabeler.Sample: SampleInfo] = [:]
        for sample in samples {
            let list = (byAudio[sample.audio] ?? []).sorted { ($0.line.offset ?? 0) < ($1.line.offset ?? 0) }
            // 行は次の行の頭まで続くとみなし、ひとこまの時間と重なる行
            var hit: [(line: ConversationLog.Line, place: String?)] = []
            for (i, item) in list.enumerated() {
                let start = item.line.offset ?? 0
                let next = i + 1 < list.count ? (list[i + 1].line.offset ?? 0) : .infinity
                if start < sample.end && next > sample.start { hit.append(item) }
            }
            guard let first = hit.first else { continue }
            let text = hit.map(\.line.text).joined(separator: " ")
            var speakers: [String] = []
            for name in hit.compactMap(\.line.speaker) where !speakers.contains(name) { speakers.append(name) }
            result[sample] = SampleInfo(time: first.line.time, text: text.count > 80 ? String(text.prefix(80)) + "…" : text,
                                        speakers: speakers, place: first.place)
        }
        return result
    }

    /// 候補を選んだとき：名前のある人に同じ名前の人がいればその人にまとめ、いなければその名前を付ける。
    func applyName(_ candidate: NameCandidate, to id: String) async {
        if let target = candidate.target {
            await assign(id, to: target)
        } else {
            await renamePerson(id, to: candidate.name)
        }
    }

    /// 名前を付けた人（自分と記録に出さない人を除く）のうち、同じ名前の人
    private func namedPerson(matching name: String, excluding id: String) -> String? {
        people.first { $0.isNamed && !$0.isSelf && $0.hidden != true && $0.id != id && Self.sameName($0.displayName, name) }?.id
    }

    /// 名乗り方。「田中と申します」「私は田中といいます」「〇〇社の田中です、よろしく…」の「田中」。
    /// 「〇〇です」だけでは「大丈夫です」なども拾うので、すぐあとに「よろしく」が続くときだけにする。
    private static let introduction = try! NSRegularExpression(
        pattern: #"(?:^|[、。！？!?\s]|の|は)([\p{Han}\p{Katakana}ー々]{1,6})(?:と申します|ともうします|と申しま|といいます|と言います|っていいます|って言います|です[、。！!\s]*よろしく)"#)

    /// 文の中で名乗った名前（漢字かカタカナだけのもの）
    static func introducedNames(in text: String) -> [String] {
        guard text.contains("申") || text.contains("もうし") || text.contains("いいます") || text.contains("言います")
                || text.contains("よろしく") else { return [] }
        var names: [String] = []
        for m in introduction.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            if isNameLike(name), !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// 呼び方の違い（空白・「さん」など）を除いて、同じ人の名前か。2文字以上なら、片方がもう片方の頭（「田中」と「田中太郎」）でもよい。
    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = nameKey(a), y = nameKey(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard min(x.count, y.count) >= 2 else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    static func nameKey(_ s: String) -> String {
        var key = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
        for honorific in ContactsLink.honorifics where key.hasSuffix(honorific) && key.count > honorific.count {
            key = String(key.dropLast(honorific.count))
            break
        }
        return key
    }
}

/// 名前の候補1つ。押すと名前を付ける（または同じ名前の人にまとめる）。
struct NameCandidateRow: View {
    let candidate: Pipeline.NameCandidate
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.target != nil ? "「\(candidate.name)」にまとめる" : "「\(candidate.name)」と名前を付ける")
                Text(candidate.reasons.joined(separator: "・"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// その声が出てきた会話と、その会話でその声が話した行。行を押すと、その行の声を鳴らす。
struct VoiceTalksSection: View {
    @Environment(Pipeline.self) private var pipeline
    let talks: [Pipeline.VoiceTalk]
    let player: ClipPlayer

    var body: some View {
        Section {
            ForEach(talks) { talk in
                VStack(alignment: .leading, spacing: 2) {
                    Text(talk.heading).font(.caption.bold())
                    if let title = talk.conversation.title, !title.isEmpty {
                        Text(title).font(.caption)
                    }
                    if !talk.others.isEmpty {
                        Text("一緒にいた人: " + talk.others.joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(talk.lines, id: \.line.time) { item in
                    lineRow(item.line, end: item.end)
                }
                if talk.count > talk.lines.count {
                    Text("この会話でほか \(talk.count - talk.lines.count) 行").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("この声が話したこと")
        } footer: {
            Text("この声が出てきた会話（新しい順）と、そこで話した長い行です。押すとその行の声が鳴ります。")
        }
    }

    @ViewBuilder
    private func lineRow(_ line: ConversationLog.Line, end: TimeInterval?) -> some View {
        let key = "line-\(line.time.timeIntervalSince1970)"
        let audio = line.audio.flatMap { pipeline.archive.canPlay($0) ? $0 : nil }
        let label = HStack(alignment: .firstTextBaseline) {
            Text(Pipeline.VoiceTalk.time.string(from: line.time))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(line.text)
            Spacer(minLength: 0)
            if player.loading == key {
                ProgressView()
            } else if audio != nil {
                Image(systemName: player.playing == key ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(Color.accentColor)
            }
        }
        if let audio {
            Button {
                Task {
                    await player.toggle(key, at: line.offset ?? 0, until: end) {
                        await pipeline.archive.playableURL(for: audio)
                    }
                }
            } label: {
                label
            }
            .tint(.primary)
        } else {
            label
        }
    }
}

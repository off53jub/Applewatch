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
        /// その行の話者の番号（名前より確か）
        let speakerIDs: [String]
        /// テレビ・動画・放送などの声とされた行が重なっている
        let media: Bool
        let place: String?
        /// 重なった行の音声の中の位置（秒。「この行を聞く」で鳴らす。2026-11-06）
        var lineStart: TimeInterval = 0
        var lineEnd: TimeInterval = 0
        /// 1秒以上しっかり重なる行が無く、いちばん近い行を出している（文と声がずれているかもしれない）
        var loose = false

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
            // 行の長さは文字数から見積もり（次の行の頭まで）、ひとこまとしっかり重なる行だけを出す（2026-11-06）。
            // 前は「次の行の頭まで続く」とみなしていたので、短いセリフのあと黙っていた時間のひとこまにも、そのセリフが付いていた
            let spans = list.map { (offset: $0.line.offset ?? 0, chars: $0.line.text.count) }
            let match = Self.matchLines(spans, sample: (start: sample.start, end: sample.end))
            let hit = match.indices.map { list[$0] }
            guard let first = hit.first, let firstIndex = match.indices.first, let lastIndex = match.indices.last else { continue }
            let ends = Self.lineEnds(spans)
            let text = hit.map(\.line.text).joined(separator: " ")
            var speakers: [String] = []
            for name in hit.compactMap(\.line.speaker) where !speakers.contains(name) { speakers.append(name) }
            var ids: [String] = []
            for id in hit.compactMap(\.line.speakerID) where !ids.contains(id) { ids.append(id) }
            result[sample] = SampleInfo(time: first.line.time, text: text.count > 80 ? String(text.prefix(80)) + "…" : text,
                                        speakers: speakers, speakerIDs: ids,
                                        media: hit.contains { $0.line.media != nil }, place: first.place,
                                        lineStart: spans[firstIndex].offset, lineEnd: ends[lastIndex], loose: match.loose)
        }
        return result
    }

    /// 行の終わりの見積もり。文字数から話した長さを見積もり（1文字 0.18 秒＋0.8 秒、1.5 秒以上）、次の行の頭を超えない
    nonisolated static func lineEnds(_ lines: [(offset: TimeInterval, chars: Int)]) -> [TimeInterval] {
        lines.indices.map { i in
            let spoken = lines[i].offset + max(1.5, Double(lines[i].chars) * 0.18 + 0.8)
            let next = i + 1 < lines.count ? lines[i + 1].offset : .infinity
            return min(spoken, max(next, lines[i].offset + 0.5))
        }
    }

    /// 声のひとこま（start〜end）としっかり重なる行。重なりが1秒以上か、ひとこまの3割以上の行。
    /// 無ければ、いちばん長く重なる行（少しでも重なれば）を loose として返す。lines は始まりの順
    nonisolated static func matchLines(_ lines: [(offset: TimeInterval, chars: Int)],
                                       sample: (start: TimeInterval, end: TimeInterval)) -> (indices: [Int], loose: Bool) {
        let ends = lineEnds(lines)
        let length = max(sample.end - sample.start, 0.1)
        var overlaps: [(index: Int, seconds: Double)] = []
        for i in lines.indices {
            let seconds = min(ends[i], sample.end) - max(lines[i].offset, sample.start)
            if seconds > 0 { overlaps.append((i, seconds)) }
        }
        let firm = overlaps.filter { $0.seconds >= min(1.0, length * 0.3) }.map(\.index)
        if !firm.isEmpty { return (firm, false) }
        if let best = overlaps.max(by: { $0.seconds < $1.seconds }) { return ([best.index], true) }
        return ([], false)
    }

    /// 見直したい声のひとこま（記録ではほかの人の行や、テレビ・放送などの行と重なっているもの）
    struct ReviewItem: Identifiable {
        let person: SpeakerLabeler.Person
        let sample: SpeakerLabeler.Sample
        let info: SampleInfo
        /// 重なっている行の、ほかの話者の番号（移す先の候補）
        let others: [String]
        var id: String { Pipeline.reviewKey(person.id, sample) }
    }

    nonisolated static func reviewKey(_ person: String, _ sample: SpeakerLabeler.Sample) -> String {
        person + "|" + sample.audio + "|\(sample.start)"
    }

    /// 見直しで「このままでよい」にする（もう出さない）
    func keepSample(_ item: ReviewItem) {
        var kept = UserDefaults.standard.stringArray(forKey: Self.reviewKeptKey) ?? []
        kept = Array((kept + [item.id]).suffix(500))
        UserDefaults.standard.set(kept, forKey: Self.reviewKeptKey)
    }

    /// 「このままでよい」にしたひとこま
    static let reviewKeptKey = "voiceReviewKept"

    func voiceReview() -> [ReviewItem] {
        let infos = sampleInfo(for: people.flatMap(\.samples))
        let kept = Set(UserDefaults.standard.stringArray(forKey: Self.reviewKeptKey) ?? [])
        var result: [ReviewItem] = []
        for person in people {
            for sample in person.samples {
                guard let info = infos[sample], !kept.contains(Self.reviewKey(person.id, sample)) else { continue }
                let others = info.speakerIDs.filter { $0 != person.id }
                guard !others.isEmpty || info.media else { continue }
                result.append(ReviewItem(person: person, sample: sample, info: info, others: others))
            }
        }
        return result
    }

    // MARK: - テレビ・動画らしい声

    private static var broadcastCache: (at: Date, ids: Set<String>) = (.distantPast, [])

    /// テレビ・動画らしい名前の無い声（直近14日の記録から。1分は覚えておく）。
    /// その声の行（5行以上）の7割以上が、テレビ・動画の会話や行・背景の音がテレビや音楽・前後3分に自分が話していない、のどれかのもの。
    /// 「名前を付けてほしい声」と「人物Nを整理」には出さない（家でテレビや YouTube を流していると、名前の無い声がたくさんできるため）。
    func broadcastLike() -> Set<String> {
        if Date.now.timeIntervalSince(Self.broadcastCache.at) < 60 { return Self.broadcastCache.ids }
        var total: [String: Int] = [:], tv: [String: Int] = [:], home: [String: Int] = [:]
        for day in recordedDays().prefix(14) {
            for c in conversations(on: day) {
                let selfTimes = c.lines.filter { $0.speakerID == SpeakerLabeler.selfID }.map(\.time)
                let atHome = Self.isHome(c.place)
                for line in c.lines {
                    // テレビの行に書き換えた行は、元の声の番号（heardSpeakerID）で数える
                    guard let id = line.speakerID ?? line.heardSpeakerID, id != SpeakerLabeler.selfID else { continue }
                    total[id, default: 0] += 1
                    if atHome { home[id, default: 0] += 1 }
                    let sound = line.sound ?? ""
                    let media = line.media != nil || c.media != nil || sound.contains("テレビ") || sound.contains("音楽")
                    let lonely = !selfTimes.contains { abs($0.timeIntervalSince(line.time)) <= 180 }
                    if media || lonely { tv[id, default: 0] += 1 }
                }
            }
        }
        let unnamed = Set(people.filter { !$0.isNamed && $0.hidden != true }.map(\.id))
        // テレビや YouTube はほとんど家で流すので、行の半分以上が家の声は早めに（3行以上・半分以上で）みなす
        let ids = Set(total.filter { id, n in
            guard unnamed.contains(id) else { return false }
            let share = Double(tv[id] ?? 0) / Double(n)
            let mostlyHome = Double(home[id] ?? 0) / Double(n) >= 0.5
            return mostlyHome ? (n >= 3 && share >= 0.5) : (n >= 5 && share >= 0.7)
        }.map(\.key))
        Self.broadcastCache = (.now, ids)
        return ids
    }

    /// 家の場所の名前か（「自宅」「家」「実家」を含む。「ホーム」は駅やホームセンターと紛れるので見ない）
    nonisolated static func isHome(_ place: String?) -> Bool {
        guard let place else { return false }
        return ["自宅", "家", "実家", "home", "Home"].contains { place.contains($0) }
    }

    /// テレビ・動画らしい声をまとめて忘れる（名前の無い声だけ。記録の行はそのまま）。忘れた数を返す。
    func forgetBroadcastLike() async -> Int {
        let ids = broadcastLike()
        for id in ids { await removePerson(id) }
        Self.broadcastCache = (.distantPast, [])
        return ids.count
    }

    /// 名前の無い声が、まるごとテレビ・動画などの声だったとき：その声の行をすべて放送の行（kind）にし、声を忘れる。
    /// 名前のある人には使わない（混ざっているだけなら「分ける」で、その組だけテレビにする）。直した行の数を返す。
    func markPersonAsMedia(_ id: String, kind: String) async -> Int {
        guard let person = people.first(where: { $0.id == id }), !person.isNamed, !person.isSelf else { return 0 }
        let count = await markMedia(kind) { $0.speakerID == id }
        await removePerson(id)
        Self.broadcastCache = (.distantPast, [])
        return count
    }

    /// 放送の声の種類（電車・駅・お店のアナウンスなど。夜の見分けと同じ名前）
    static let broadcastKind = "放送"

    /// 名前を付けた人が、じつは電車や駅・お店のアナウンスなどの放送の声だったとき（本人が押したときだけ。2026-11-09）：
    /// その人の行をすべて放送の行（「放送」）に書き換え（元の名前と番号は行に残す）、見出しの「〇〇と」からも外して、その人を消す。
    /// 自分と名前の無い声には使わない（名前の無い声は「テレビ・動画・ラジオの声だった」）。直した行の数を返す。
    func markNamedPersonAsBroadcast(_ id: String) async -> Int {
        guard let person = people.first(where: { $0.id == id }), person.isNamed, !person.isSelf else { return 0 }
        let name = person.displayName
        let count = await markMedia(Self.broadcastKind, dropping: name) { line in
            line.speakerID == id || (line.speakerID == nil && line.speaker == name)
        }
        await removePerson(id)
        Self.broadcastCache = (.distantPast, [])
        return count
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

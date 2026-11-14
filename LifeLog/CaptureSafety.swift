import AVFoundation
import Foundation
import UIKit
import UserNotifications

// その場での精度と、取りこぼし・間違いを防ぐ工夫（2026-11-06）。
// 会議モード・初めての人の印・名乗り・音の見張り（こもり・音割れ・こすれ）・文字起こし待ちの滞留・
// 毎朝の点検・時計の電池の先回り・その日の言葉。

// MARK: - 会議モード

/// 会議モード。時計か iPhone で始めると、予定の参加者を「来そうな人」に入れ、題名と参加者を聞き取りのヒントにし、
/// 時計の録音の音質を上げる（32kbps → 48kbps）。終わったら、その会議をすぐ議事録にする。
/// 中身は UserDefaults の meetingSessions（30日分）。
enum MeetingMode {
    struct Session: Codable, Equatable {
        let start: Date
        var end: Date?
        /// 始めたときに重なっていた予定の題名と参加者
        let title: String?
        let attendees: [String]
        /// 議事録を作った（か、作れる会話が無かった）
        var minutesDone: Bool?
    }

    private static let key = "meetingSessions"
    /// 終えるのを忘れても、これより長くは続けない
    static let longest: TimeInterval = 4 * 3600

    static var sessions: [Session] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
        }
        set {
            let old = Date.now.addingTimeInterval(-30 * 24 * 3600)
            let kept = newValue.filter { $0.start >= old }
            UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: key)
        }
    }

    /// いま続いている会議
    static var active: Session? {
        guard let last = sessions.last, last.end == nil else { return nil }
        return Date.now.timeIntervalSince(last.start) < longest ? last : nil
    }

    /// その時刻を含む会議
    static func session(at time: Date) -> Session? {
        sessions.last { s in
            s.start.addingTimeInterval(-60) <= time && time <= (s.end ?? min(.now, s.start.addingTimeInterval(longest)))
        }
    }

    /// 題名から、ヒントにする言葉（2文字以上のまとまり）
    static func words(title: String?) -> [String] {
        guard let title, !title.isEmpty else { return [] }
        let parts = title.components(separatedBy: CharacterSet(charactersIn: " 　・/／、,（）()【】[]「」-:："))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        return Array(([title] + parts).prefix(6))
    }
}

// MARK: - 初めての人・名乗った声

/// 名前を付ける候補にする声（初めての人の印の前後で話した名前の無い声と、「〇〇です」と名乗った名前の無い声）。
/// 名前は自動では付けない。「今日」に出して、本人が選んで付ける。
struct NewVoiceBox: Codable {
    struct Note: Codable, Identifiable, Equatable {
        let id: String
        let time: Date
        /// 名前の無い人の番号
        let personID: String
        /// 名乗った名前（初めての人の印なら nil）
        let claimed: String?
        let quote: String
        var dismissed: Bool?
        /// 名前のある人の声が、ふだん話さない場所で聞こえた（取り違えかも）なら、その場所（2026-11-06）
        var unusualPlace: String? = nil
        /// PC の話者モデルでは、この人（番号）の声に近かった（2026-11-06）
        var pcSuggests: String? = nil
    }

    var notes: [Note] = []
    /// まだ記録の行と照らしていない「初めての人」の印
    var pendingMarks: [Date] = []

    private static let key = "newVoices"

    static func load() -> NewVoiceBox {
        guard let data = UserDefaults.standard.data(forKey: key) else { return NewVoiceBox() }
        return (try? JSONDecoder().decode(NewVoiceBox.self, from: data)) ?? NewVoiceBox()
    }

    func save() {
        var kept = self
        let old = Date.now.addingTimeInterval(-14 * 24 * 3600)
        kept.notes.removeAll { $0.time < old }
        kept.pendingMarks.removeAll { $0 < old }
        UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: Self.key)
    }

    /// まだ見ていない候補（新しい順）
    var open: [Note] { notes.filter { $0.dismissed != true }.sorted { $0.time > $1.time } }

    /// 「田中です」「田中と申します」のように名乗った名前。名乗りでなければ nil
    static func claimedName(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:あ、|あの、|えっと、|はじめまして、|初めまして、|どうも、)?(?:わたくし|私|僕|わたし)?(?:、)?([一-龥々ァ-ヶー]{2,6})(?:と申します|です)(?:[。、！!]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else { return nil }
        let name = String(trimmed[range])
        // 名前ではない、よくある言葉
        let common = ["大丈夫", "結構", "本当", "以上", "同じ", "そう", "了解", "承知", "確認", "最高", "無理", "問題", "必要",
                      "必要ない", "当然", "普通", "一緒", "反対", "賛成", "残念", "心配", "安心", "失礼"]
        return common.contains(name) ? nil : name
    }
}

extension Pipeline {
    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func post(id: String, title: String, body: String, at date: Date? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var trigger: UNNotificationTrigger?
        if let date, date > .now {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        }
        // すぐ出す知らせは、1時間に3通を超えたら1通にまとめる（2026-11-15。強化案 44。NoticeGate.swift）
        NoticeGate.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: 会議モード

    /// 会議モードを始める・終える（iPhone の画面と時計のボタンから）
    func setMeeting(_ on: Bool) {
        var sessions = MeetingMode.sessions
        if on {
            guard MeetingMode.active == nil else { return }
            // いま重なっている（なければ前後30分の）予定
            let event = calendar.event(at: .now)
                ?? calendar.events(from: .now.addingTimeInterval(-1800), to: .now.addingTimeInterval(1800)).first
            sessions.append(.init(start: .now, end: nil, title: event?.title.isEmpty == false ? event?.title : nil,
                                  attendees: event?.attendees ?? []))
        } else {
            guard let i = sessions.lastIndex(where: { $0.end == nil }) else { return }
            sessions[i].end = .now
        }
        MeetingMode.sessions = sessions
        meeting = MeetingMode.active
        // 録り方の実験より会議モードを先に（iPhone の録音の部品が読む。2026-11-15。RecordingExperiment）
        UserDefaults.standard.set(meeting != nil, forKey: RecordingExperiment.meetingKey)
        receiver.sendSettings(skipSilence: skipSilence, held: recordingHeld, meeting: on)
        // 会議の相棒（その場版）: 家の PC に始まり・終わりを伝え、Live Activity と時計に出す（2026-11-15。MeetingLive.swift）
        MeetingLiveBook.shared.meetingChanged(on, pipeline: self)
        if !on { processQueue() }
    }

    /// 終わった会議モードの会議を、すぐ議事録にする（充電していなくても。会話が閉じてから）
    func writeMeetingMinutesNow() async {
        guard summariesOn, llmKey != nil else { return }
        var sessions = MeetingMode.sessions
        guard let i = sessions.lastIndex(where: { $0.end != nil && $0.minutesDone != true }), let end = sessions[i].end else { return }
        let start = sessions[i].start
        let day = Self.dayKey.string(from: start)
        let talks = conversations(on: day).filter { c in
            c.closed && c.media == nil && c.minutes == nil && min(c.end, end).timeIntervalSince(max(c.start, start)) >= 5 * 60
        }
        if let c = talks.max(by: { $0.lines.count < $1.lines.count }) {
            let result = await writeMinutes(for: c, day: day)
            if case .success = result { sessions[i].minutesDone = true }
        } else if Date.now.timeIntervalSince(end) > 3 * 3600 {
            // 3時間たっても会話が見つからなければあきらめる
            sessions[i].minutesDone = true
        }
        MeetingMode.sessions = sessions
    }

    // MARK: 初めての人・名乗った声

    func markNewPerson(at time: Date) {
        newVoices.pendingMarks.append(time)
        newVoices.save()
        processQueue()
    }

    /// 印から15分たった「初めての人」の印を、記録の行と照らす。名乗った行も探す。
    func collectNewVoices() {
        var box = newVoices
        var changed = false
        let ready = box.pendingMarks.filter { Date.now.timeIntervalSince($0) >= 15 * 60 }
        for mark in ready {
            let lines = conversations(on: Self.dayKey.string(from: mark)).flatMap(\.lines)
            let near = lines.filter { $0.time >= mark.addingTimeInterval(-180) && $0.time <= mark.addingTimeInterval(300) }
            var seen = Set<String>()
            for line in near {
                guard let id = line.speakerID, id != SpeakerLabeler.selfID, line.media == nil,
                      (line.speaker ?? "").hasPrefix("人物"), seen.insert(id).inserted else { continue }
                box.notes.append(.init(id: "new-\(id)-\(Int(mark.timeIntervalSince1970))", time: line.time,
                                       personID: id, claimed: nil, quote: line.text))
            }
            box.pendingMarks.removeAll { $0 == mark }
            changed = true
        }
        // 直近2日の、名前の無い声の「〇〇です」
        let known = Set(box.notes.map(\.id))
        let days = Array(recordedDays().prefix(2))
        // 多数決でモデルが割れた言葉を数える（何日も割れたら、言葉の登録の候補にする。MultiModel）
        for day in days { SplitWords.count(day: day, lines: conversations(on: day).flatMap(\.lines)) }
        for day in days {
            for line in conversations(on: day).flatMap(\.lines) {
                guard let id = line.speakerID, id != SpeakerLabeler.selfID, line.media == nil,
                      (line.speaker ?? "").hasPrefix("人物"),
                      let name = NewVoiceBox.claimedName(in: line.text) else { continue }
                let noteID = "name-\(id)-\(name)"
                guard !known.contains(noteID) else { continue }
                box.notes.append(.init(id: noteID, time: line.time, personID: id, claimed: name, quote: line.text))
                changed = true
            }
        }
        // 名前のある人の声が、ふだん話さない場所で少しだけ聞こえた（取り違えかも）
        let index = placeIndex()
        let named = Dictionary(uniqueKeysWithValues: people.filter { $0.isNamed && !$0.isSelf }.map { ($0.id, $0.displayName) })
        for day in days {
            for c in conversations(on: day) where c.closed && c.media == nil {
                guard let place = c.place else { continue }
                for (id, lines) in Dictionary(grouping: c.lines.filter { $0.speakerID != nil }, by: { $0.speakerID ?? "" }) {
                    guard named[id] != nil, let history = index.byPerson[id] else { continue }
                    let noteID = "odd-\(id)-\(Int(c.start.timeIntervalSince1970))"
                    guard !known.contains(noteID),
                          Self.looksMisheardPlace(history: history.map { (WordStats.placeKey($0.place), $0.count) },
                                                  place: WordStats.placeKey(place), lines: lines.count),
                          let first = lines.first else { continue }
                    box.notes.append(.init(id: noteID, time: first.time, personID: id, claimed: nil, quote: first.text,
                                           unusualPlace: place))
                    changed = true
                }
            }
        }
        if changed {
            box.save()
            newVoices = box
        }
    }

    /// ふだん話さない場所での、少しだけの声か。その人と10回以上の会話があり、この場所はこの1回だけで、行が3つ以下
    nonisolated static func looksMisheardPlace(history: [(place: String, count: Int)], place: String, lines: Int) -> Bool {
        let total = history.reduce(0) { $0 + $1.count }
        let here = history.filter { $0.place == place }.reduce(0) { $0 + $1.count }
        return total >= 10 && here <= 1 && lines <= 3
    }

    /// 割れやすい言葉の候補（もう登録した言葉は除く）
    func splitWordCandidates() -> [SplitWords.Pair] {
        var known = Set<String>()
        for group in Vocabulary.Group.allCases { known.formUnion(vocabulary.words(in: group)) }
        known.formUnion(vocabulary.fixes.map(\.right))
        return SplitWords.candidates(known: known)
    }

    func dismissNewVoice(_ id: String) {
        guard let i = newVoices.notes.firstIndex(where: { $0.id == id }) else { return }
        newVoices.notes[i].dismissed = true
        newVoices.save()
    }

    // MARK: 時計の様子と電池

    func noteWatchState(_ state: PhoneReceiver.WatchState) {
        var entry = RecordingLedger.State(at: state.at, recording: state.recording, resting: state.resting,
                                          charging: state.charging, battery: state.battery, lowPower: state.lowPower)
        entry.held = recordingHeld
        ledger.note(entry)
        checkWatchBattery()
        notePCWatchState(state)  // 家の PC への様子に、時計から最後に知らせが来た時刻と控えの数（2026-11-07。PCDiag.swift）
    }

    /// 時計の電池が、夜（21時）までに 10% を切りそうなら、1日1回知らせる
    private func checkWatchBattery() {
        guard stopAlertsOn, let empty = RecordingLedger.batteryEmpty(states: ledger.states) else { return }
        let today = Self.dayKey.string(from: .now)
        guard UserDefaults.standard.string(forKey: "batteryAlertDay") != today else { return }
        let night = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: .now) ?? .now
        let soonest = Date.now.addingTimeInterval(20 * 60)
        let latest = min(night, Date.now.addingTimeInterval(6 * 3600))
        guard empty >= soonest && empty <= latest else { return }
        UserDefaults.standard.set(today, forKey: "batteryAlertDay")
        Self.post(id: "watch-battery", title: "時計の電池が \(empty.formatted(date: .omitted, time: .shortened)) ごろ切れそうです",
                  body: "いまの減り方だと、その時刻に 10% を切ります。録音を続けるなら、それまでに少し充電してください（家で iPad や iPhone が録っているあいだなど）。")
    }

    // MARK: 文字起こし待ちの滞留

    /// 2時間より前の区切りが待ったままなら、理由と一緒に知らせる（6時間に1回まで）
    func checkStall() {
        let waiting = Storage.pendingChunks().filter { !Storage.isImported($0) }
        guard let oldest = waiting.compactMap(Storage.startDate(of:)).min(),
              Date.now.timeIntervalSince(oldest) > 2 * 3600 else { return }
        let last = UserDefaults.standard.object(forKey: "stallAlert") as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 6 * 3600 else { return }
        UserDefaults.standard.set(Date.now, forKey: "stallAlert")
        let reason: String
        if email == nil {
            reason = "Google にログインしていません。LifeLog を開いてログインしてください。"
        } else if !message.isEmpty {
            reason = message
        } else {
            reason = "裏で処理する時間が足りないか、電波・家の PC・クラウドにつながらない可能性があります。LifeLog を一度開いてください。"
        }
        Self.post(id: "stall", title: "文字起こし待ちが \(waiting.count) 個溜まっています",
                  body: "いちばん古いのは \(oldest.formatted(date: .abbreviated, time: .shortened)) の録音です。\(reason)")
    }

    // MARK: 毎朝の点検

    /// 前の日の点検の1行（帳簿が始まる前の日は nil）。朝の「昨日と今日」にも入れる（2026-11-09）
    func morningCheckLine(for yesterdayStart: Date, now: Date = .now) -> String? {
        guard UserDefaults.standard.object(forKey: "morningCheck") as? Bool ?? true else { return nil }
        let yesterday = Self.dayKey.string(from: yesterdayStart)
        let map = ledger.map(for: yesterdayStart, now: now)
        let counts = ledger.counts(for: yesterdayStart)
        // 帳簿が始まる前の日は出さない
        guard counts.watchReceived + counts.phoneRecorded > 0 || !map.gaps.isEmpty, !ledger.chunks.isEmpty else { return nil }
        let lines = conversations(on: yesterday).flatMap(\.lines)
        let uncertain = lines.filter(\.isUncertain).count
        let unnamed = Set(lines.compactMap(\.speaker).filter { $0.hasPrefix("人物") }).count
        return RecordingLedger.reportLine(gaps: map.gaps, counts: counts, uncertain: uncertain, unnamedVoices: unnamed)
    }

    /// 前の日の点検を、7時半の通知に1行で出す（もう過ぎていて昼前なら、すぐ）。1日1回。
    /// 朝の「昨日と今日」を知らせるときは、そちらに入れるので別には出さない（2026-11-09）
    func scheduleMorningCheck() {
        guard UserDefaults.standard.object(forKey: "morningCheck") as? Bool ?? true, !MorningBrief.isOn else { return }
        let now = Date.now
        let calendar = Calendar.current
        let today = Self.dayKey.string(from: now)
        guard UserDefaults.standard.string(forKey: "morningCheckSent") != today,
              calendar.component(.hour, from: now) >= 1, calendar.component(.hour, from: now) < 12,
              let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
              let body = morningCheckLine(for: yesterdayStart, now: now) else { return }
        let at = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: now) ?? now
        // 7時半より前は、そのつど作り直して予約し直す（夜中に処理が進むと数字が変わるため）
        Self.post(id: "morning-check", title: "昨日の点検", body: body, at: at)
        if at <= now { UserDefaults.standard.set(today, forKey: "morningCheckSent") }
    }

    // MARK: その日の言葉

    /// その日の予定の題名と場所（その日だけのヒント）
    func dayWords(at time: Date) -> [String] {
        let start = Calendar.current.startOfDay(for: time)
        let events = calendar.dayEvents(from: start, to: start.addingTimeInterval(24 * 3600))
        var words: [String] = []
        for event in events {
            words += MeetingMode.words(title: event.title)
            if let location = event.location { words.append(location) }
        }
        return Array(NSOrderedSet(array: words).array.compactMap { $0 as? String }.prefix(12))
    }

    // MARK: 音の見張り

    /// 区切りの音を調べた結果で、時計に知らせる（10分ほど続けてこもっている・割れているとき。30分に1回まで）。
    /// 5分の区切りなら2つ続けて。短めの区切りでは、同じくらいの時間になるよう続く数を増やす（2026-11-07）
    func handleSoundCheck(_ check: AudioCheck.Result, fromWatch: Bool) {
        guard fromWatch else { return }
        let findings: [(key: String, hit: Bool, text: String)] = [
            ("muffled", check.muffled, "マイクが袖やポケットで隠れているかもしれません。時計の位置を確かめてください。"),
            ("clipped", check.clipped, "音が大きすぎて割れています。時計を口や音のする物から少し離してください。"),
        ]
        for finding in findings {
            soundStreak[finding.key] = finding.hit ? (soundStreak[finding.key] ?? 0) + 1 : 0
            guard (soundStreak[finding.key] ?? 0) >= ChunkCutter.scaled(2) else { continue }
            let last = lastSoundAlert[finding.key] ?? .distantPast
            guard Date.now.timeIntervalSince(last) > 30 * 60 else { continue }
            lastSoundAlert[finding.key] = .now
            receiver.alertWatch(finding.text)
        }
    }
}

// MARK: - 音を調べる

/// 区切りの音を調べる（端末の中だけ）。
/// - こもり: 声のあるところで、2kHz より上の音がほとんど無い（袖・ポケット・布で覆われている）
/// - 音割れ: 振り切れた音の割合が多い
/// - こすれ・風: 60Hz より下の音が大半を占める 0.5 秒（その区間の行は聞き取りの重みを下げる）
/// しきい値はまだ実際の録音で合わせていない（答え合わせの数字で合わせる）。
enum AudioCheck {
    struct Result: Equatable {
        var muffled = false
        var clipped = false
        /// こすれ・風の強かった区間（秒）
        var rubbed: [ClosedRange<Double>] = []

        func rubbed(from start: Double, to end: Double) -> Bool {
            let span = max(end - start, 0.5)
            let covered = rubbed.reduce(0.0) { sum, r in sum + max(0, min(r.upperBound, end) - max(r.lowerBound, start)) }
            return covered / span >= 0.4
        }
    }

    static let highShareMuffled = 0.004
    static let clipRatio = 0.0005
    static let rubShare = 0.6

    /// 0.5秒ごとの、全体・60Hz より下・2kHz より上 の強さ（2乗の和）と、振り切れた数
    struct Block: Equatable {
        var total: Double
        var low: Double
        var high: Double
        var count: Int
        var clipped: Int
    }

    static func measure(_ url: URL) -> Result? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)) else { return nil }
        let blockSize = Int(rate / 2)
        // 1次の低域通過を2回（60Hz）と1回（2kHz）
        let aLow = exp(-2 * Double.pi * 60 / rate), aHigh = exp(-2 * Double.pi * 2000 / rate)
        var low1 = 0.0, low2 = 0.0, lowHigh = 0.0
        var blocks: [Block] = []
        var current = Block(total: 0, low: 0, high: 0, count: 0, clipped: 0)
        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { break }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
            for i in 0..<Int(buffer.frameLength) {
                let x = Double(data[i])
                low1 = (1 - aLow) * x + aLow * low1
                low2 = (1 - aLow) * low1 + aLow * low2
                lowHigh = (1 - aHigh) * x + aHigh * lowHigh
                let high = x - lowHigh
                current.total += x * x
                current.low += low2 * low2
                current.high += high * high
                current.count += 1
                if abs(x) >= 0.985 { current.clipped += 1 }
                if current.count >= blockSize {
                    blocks.append(current)
                    current = Block(total: 0, low: 0, high: 0, count: 0, clipped: 0)
                }
            }
        }
        return judge(blocks)
    }

    /// 0.5秒ごとの強さから決める（テストのため分けてある）
    static func judge(_ blocks: [Block]) -> Result {
        var result = Result()
        // 声や物音のある（-45dBFS より大きい）ところだけを見る
        let loud = blocks.enumerated().filter { _, b in
            b.count > 0 && 10 * log10(max(b.total / Double(b.count), 1e-12)) > -45
        }
        guard !loud.isEmpty else { return result }
        let total = loud.reduce(0.0) { $0 + $1.element.total }
        let high = loud.reduce(0.0) { $0 + $1.element.high }
        // 10秒以上の音があって、高い音の割合がとても小さければ、こもっている
        if loud.count >= 20, total > 0, high / total < highShareMuffled { result.muffled = true }
        let samples = blocks.reduce(0) { $0 + $1.count }
        let clipped = blocks.reduce(0) { $0 + $1.clipped }
        if samples > 0, Double(clipped) / Double(samples) > clipRatio { result.clipped = true }
        for (i, b) in loud where b.total > 0 && b.low / b.total >= rubShare {
            result.rubbed.append(Double(i) * 0.5...Double(i + 1) * 0.5)
        }
        return result
    }
}

// MARK: - Siri や時計から聞く（2026-11-06）

/// アプリの外（Siri・ショートカット・時計の Siri）から聞かれたときに答える。LifeLogApp が起動時に入れる
@MainActor
enum Recall {
    static var recent: (() -> String)?
    static var lastTalk: ((String) -> String)?
    /// 「今日の宿題」（2026-11-10。WorkInsights.swift）
    static var homework: (() -> String)?
}

extension Pipeline {
    /// 「さっき何て言った？」: 直近10分（無ければ今日の最後）の3行
    func recentWords(minutes: Double = 10) -> String {
        let today = Self.dayKey.string(from: .now)
        let lines = conversations(on: today).flatMap(\.lines).filter { $0.media == nil }
        guard !lines.isEmpty else { return "今日の記録はまだありません。" }
        let recent = lines.filter { Date.now.timeIntervalSince($0.time) <= minutes * 60 }
        let picked = (recent.isEmpty ? lines : recent).suffix(3)
        let head = recent.isEmpty ? "直近10分の記録はありません。今日の最後の発言です。" : ""
        return head + picked.map { line in
            line.time.formatted(date: .omitted, time: .shortened) + " " + (line.speaker.map { $0 + "「" } ?? "「") + line.text + "」"
        }.joined(separator: "\n")
    }

    /// 「この人と前回何を話した？」: 名前が合う人と話した、いちばん新しい閉じた会話の見出しと要点
    func lastTalk(with name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "誰との会話かを教えてください。" }
        for day in recordedDays().prefix(90) {
            let talks = conversations(on: day).filter { c in
                c.media == nil && c.people.contains { Self.sameName($0, name) }
            }
            if let c = talks.max(by: { $0.start < $1.start }) {
                let when = c.start.formatted(date: .abbreviated, time: .shortened)
                let points = c.points.prefix(3).map { "・" + $0 }.joined(separator: "\n")
                return "\(when)" + (c.place.map { "（\($0)）" } ?? "") + " の会話" + (c.title.map { "「\($0)」" } ?? "")
                    + (points.isEmpty ? "。要点はまだありません。" : "\n" + points)
            }
        }
        return "直近90日の記録に、\(name)さんとの会話は見つかりませんでした。"
    }
}

// MARK: - 全部を自分の形で書き出す（2026-11-06）

extension Pipeline {
    /// 書き出しの形式の版（中身の形を変えたら上げる）
    static let exportFormat = 1

    /// その年の記録（会話と行）・人・タスクを、読みやすい Markdown と、プログラムで読める JSON にして、
    /// ドライブの「控え」に「書き出し-年-作った日」の名前で置く（同じ年の分は新しい2つだけ残す）。
    /// アプリが動かなくなっても読めるよう、JSON の頭に中身の説明を入れる。書いたファイルの名前を返す。
    @discardableResult
    func exportYear(_ year: Int) async throws -> [String] {
        let days = recordedDays().filter { $0.hasPrefix(String(year) + "-") }.sorted()
        let made = Self.dayKey.string(from: .now)
        var json: [String: Any] = [
            "形式": Self.exportFormat,
            "説明": "LifeLog の \(year) 年の書き出し。「日ごと」は日付（yyyy-MM-dd）ごとの会話の配列。会話は start・end（2001-01-01 からの秒）・title（見出し）・points（要点）・place（場所）・lines（行）を持つ。行は time・speaker（話した人。「自分」は本人、「人物N」は名前の無い声）・text（文字）・original（直す前の文字）・confidence（確からしさ 0〜1）。「人」は聞き分けている人の番号と名前。「タスク」は頼まれごと帳。",
            "作った日": made,
        ]
        let encoder = JSONEncoder()
        var daysJSON: [String: Any] = [:]
        var markdown = "# LifeLog \(year) 年の書き出し（\(made) 作成・形式 \(Self.exportFormat)）\n\n"
            + "日ごとの会話と行です。「自分」は本人、「人物N」は名前の無い声です。\n"
        let clock = Date.FormatStyle(date: .omitted, time: .shortened)
        for day in days {
            let talks = conversations(on: day)
            if let data = try? encoder.encode(talks), let value = try? JSONSerialization.jsonObject(with: data) {
                daysJSON[day] = value
            }
            markdown += "\n## \(day)\n"
            for c in talks {
                markdown += "\n### \(c.start.formatted(clock))〜\(c.end.formatted(clock))"
                    + (c.place.map { "　\($0)" } ?? "") + (c.title.map { "　\($0)" } ?? "") + "\n"
                for point in c.points { markdown += "- \(point)\n" }
                if !c.points.isEmpty { markdown += "\n" }
                for line in c.lines {
                    markdown += "\(line.time.formatted(clock)) " + (line.speaker.map { "[\($0)] " } ?? "") + line.text + "\n"
                }
            }
        }
        json["日ごと"] = daysJSON
        json["人"] = people.map { ["番号": $0.id, "名前": $0.displayName] }
        if let data = try? encoder.encode(tasks.items), let value = try? JSONSerialization.jsonObject(with: data) {
            json["タスク"] = value
        }
        markdown += "\n## タスク\n"
        for item in tasks.items {
            markdown += "- [\(item.state == .done ? "x" : " ")] \(item.what)" + (item.from.map { "（\($0)）" } ?? "")
                + (item.due.map { "　期限 \(Self.dayKey.string(from: $0))" } ?? "") + "\n"
        }
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let prefix = "書き出し-\(year)-"
        let names = [prefix + "json-" + made + ".json", prefix + "md-" + made + ".md"]
        try await uploadExport(jsonData, name: names[0], prefix: prefix + "json-")
        try await uploadExport(Data(markdown.utf8), name: names[1], prefix: prefix + "md-")
        UserDefaults.standard.set(year, forKey: "exportedYear")
        return names
    }

    /// 年が変わったら、前の年の分を1回だけ書き出す（Wi-Fi のときだけ）
    func exportIfNewYear() async {
        let year = Calendar.current.component(.year, from: .now)
        guard email != nil, archive.isOnWiFi, UserDefaults.standard.integer(forKey: "exportedYear") < year - 1 else { return }
        _ = try? await exportYear(year - 1)
    }
}

// MARK: - 家の PC の見張り（2026-11-06）

extension Pipeline {
    /// 家の PC に2時間つながらない（家の Wi-Fi か、録音を休む場所にいるとき）・PC の版が古い、を知らせる（12時間に1回まで）
    func checkHomePC() {
        guard homePC.isConfigured else { return }
        let last = UserDefaults.standard.object(forKey: "homePCAlert") as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 12 * 3600 else { return }
        if let since = homePC.downSince, Date.now.timeIntervalSince(since) > 2 * 3600, archive.isOnWiFi || recordingHeld {
            UserDefaults.standard.set(Date.now, forKey: "homePCAlert")
            Self.post(id: "home-pc", title: "家の PC につながりません",
                      body: "\(since.formatted(date: .omitted, time: .shortened)) からつながっていません。PC が止まっていないか、LifeLog PC が動いているかを確かめてください（そのあいだは iPhone とクラウドで文字にしています）。")
        } else if let version = homePC.version, version < HomePC.expectedVersion,
                  PCVersionNotice.shouldWarn(pc: version, app: HomePC.expectedVersion, now: .now) {
            // 同じ版の組み合わせなら7日に1回まで（新しい働きは features を見て使うので、古いままでも文字起こしは使える。2026-11-07）
            UserDefaults.standard.set(Date.now, forKey: "homePCAlert")
            PCVersionNotice.noteWarned(pc: version, app: HomePC.expectedVersion, now: .now)
            Self.post(id: "home-pc", title: "家の PC の LifeLog PC が古い版です",
                      body: "PC は版 \(version)、アプリは版 \(HomePC.expectedVersion) を前提にしています。文字起こしは今のままでも使えます。新しい働き（実機の様子・見えない通知・PC で記録を直す など）は、GitHub の成果物 LifeLogPC から新しいものに入れ替えると使えます（この知らせは7日に1回まで）。")
        }
    }
}

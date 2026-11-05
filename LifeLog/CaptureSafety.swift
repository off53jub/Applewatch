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
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
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
        receiver.sendSettings(skipSilence: skipSilence, held: recordingHeld, meeting: on)
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
        if changed {
            box.save()
            newVoices = box
        }
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
    }

    /// 時計の電池が、夜（21時）までに 10% を切りそうなら、1日1回知らせる
    private func checkWatchBattery() {
        guard stopAlertsOn, let empty = RecordingLedger.batteryEmpty(states: ledger.states) else { return }
        let today = Self.dayKey.string(from: .now)
        guard UserDefaults.standard.string(forKey: "batteryAlertDay") != today else { return }
        let night = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: .now) ?? .now
        guard empty < night, empty > .now.addingTimeInterval(20 * 60), empty < .now.addingTimeInterval(6 * 3600) else { return }
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

    /// 前の日の点検を、7時半の通知に1行で出す（もう過ぎていて昼前なら、すぐ）。1日1回。
    func scheduleMorningCheck() {
        guard UserDefaults.standard.object(forKey: "morningCheck") as? Bool ?? true else { return }
        let now = Date.now
        let calendar = Calendar.current
        let today = Self.dayKey.string(from: now)
        guard UserDefaults.standard.string(forKey: "morningCheckSent") != today,
              calendar.component(.hour, from: now) >= 1, calendar.component(.hour, from: now) < 12,
              let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return }
        let yesterday = Self.dayKey.string(from: yesterdayStart)
        let map = ledger.map(for: yesterdayStart, now: now)
        let counts = ledger.counts(for: yesterdayStart)
        // 帳簿が始まる前の日は出さない
        guard counts.watchReceived + counts.phoneRecorded > 0 || !map.gaps.isEmpty, !ledger.chunks.isEmpty else { return }
        let lines = conversations(on: yesterday).flatMap(\.lines)
        let uncertain = lines.filter(\.isUncertain).count
        let unnamed = Set(lines.compactMap(\.speaker).filter { $0.hasPrefix("人物") }).count
        let body = RecordingLedger.reportLine(gaps: map.gaps, counts: counts, uncertain: uncertain, unnamedVoices: unnamed)
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

    /// 区切りの音を調べた結果で、時計に知らせる（2つ続けてこもっている・割れているとき。30分に1回まで）
    func handleSoundCheck(_ check: AudioCheck.Result, fromWatch: Bool) {
        guard fromWatch else { return }
        let findings: [(key: String, hit: Bool, text: String)] = [
            ("muffled", check.muffled, "マイクが袖やポケットで隠れているかもしれません。時計の位置を確かめてください。"),
            ("clipped", check.clipped, "音が大きすぎて割れています。時計を口や音のする物から少し離してください。"),
        ]
        for finding in findings {
            soundStreak[finding.key] = finding.hit ? (soundStreak[finding.key] ?? 0) + 1 : 0
            guard (soundStreak[finding.key] ?? 0) >= 2 else { continue }
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

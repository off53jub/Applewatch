import AVFoundation
import BackgroundTasks
import Observation
import UIKit
import UserNotifications

/// 録音 → 文字起こし → Google ドキュメントへの追記、をつなぐ。
/// 音声は追記に成功してから消すので、圏外や失敗があっても次の機会にやり直せる。
@MainActor
@Observable
final class Pipeline {
    private(set) var isRecording = false
    private(set) var pendingCount = 0
    private(set) var lastLines: [String] = []
    private(set) var message = ""
    private(set) var email: String?
    private(set) var watchStatus = "接続を準備中"
    /// 直近の区切りをどのモデルで文字起こししたか
    private(set) var lastEngine = ""
    let settings = TranscriptionSettings()
    /// 話者の聞き分け（自分の声・話し相手）
    let speakers = SpeakerLabeler()
    private(set) var people: [SpeakerLabeler.Person] = []
    private(set) var hasSelfVoice = false
    var speakerLabelsOn = UserDefaults.standard.bool(forKey: "speakerLabels") {
        didSet {
            UserDefaults.standard.set(speakerLabelsOn, forKey: "speakerLabels")
            if speakerLabelsOn { Task { await loadSpeakers() } }
        }
    }

    /// 聞き分けの厳しさ
    var speakerStrictness = SpeakerLabeler.Strictness(
        rawValue: UserDefaults.standard.object(forKey: "speakerStrictness") as? Int ?? 1) ?? .normal {
        didSet { UserDefaults.standard.set(speakerStrictness.rawValue, forKey: "speakerStrictness") }
    }

    /// 会話ごとの見出しと要約、1日のまとめ（Groq の無料枠）
    var summariesOn = UserDefaults.standard.object(forKey: "summaries") as? Bool ?? true {
        didSet { UserDefaults.standard.set(summariesOn, forKey: "summaries") }
    }
    /// 文字起こしの誤変換を言語モデルで直す（Groq の無料枠）
    var correctionOn = UserDefaults.standard.object(forKey: "correct") as? Bool ?? true {
        didSet { UserDefaults.standard.set(correctionOn, forKey: "correct") }
    }
    /// 直前の区切りの終わり（iPhone・時計それぞれ）。次の区切りの頭の文脈として使う。
    @ObservationIgnored private var lastTranscript: [Bool: (end: Date, text: String)] = [:]
    /// 両方で録っていたら、聞き取りの良いほうを選ぶ
    @ObservationIgnored private let merger = Merger()
    /// 時計が録音中か（時計が知らせてくる）
    @ObservationIgnored private var watchRecording = false
    /// 時計の区切りが、どの時刻の分まで届いているか
    @ObservationIgnored private var lastWatchEnd = Date(
        timeIntervalSince1970: UserDefaults.standard.double(forKey: "lastWatchEnd")) {
        didSet { UserDefaults.standard.set(lastWatchEnd.timeIntervalSince1970, forKey: "lastWatchEnd") }
    }
    /// 時計が静かで書くのを休んでいるなら、休み始めた時刻
    @ObservationIgnored private var watchRestingSince: Date?
    /// 音がしないあいだは録音ファイルに書かない（iPhone と時計）
    var skipSilence = SilenceGate.enabled {
        didSet {
            UserDefaults.standard.set(skipSilence, forKey: "skipSilence")
            receiver.sendSettings(skipSilence: skipSilence)
        }
    }
    /// 時計の区切りがこれ以上遅れたら、待たずに iPhone の分だけで書く
    private static let watchWait: TimeInterval = 12 * 60
    @ObservationIgnored private var retry: Task<Void, Never>?

    /// 時計やアプリで付けた印のうち、まだ記録に付けていないもの
    @ObservationIgnored private var marks: [Date] = (UserDefaults.standard.array(forKey: "marks") as? [Double] ?? [])
        .map { Date(timeIntervalSince1970: $0) } {
        didSet { UserDefaults.standard.set(marks.map(\.timeIntervalSince1970), forKey: "marks") }
    }
    /// 最後に印を付けた時刻（画面に出す）
    private(set) var lastMark: Date?

    /// 録音が止まったら通知で知らせる
    var stopAlertsOn = UserDefaults.standard.object(forKey: "stopAlerts") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(stopAlertsOn, forKey: "stopAlerts")
            if !stopAlertsOn { Self.cancelWatchAlert() }
        }
    }
    /// 時計からこれだけ知らせが無ければ、止まったとみなして通知する
    private static let watchSilence: TimeInterval = 15 * 60
    private static let watchAlertID = "watch-silent"
    /// 音声をドライブにも保存する（Wi-Fi のときだけ上げる）
    var audioBackupOn = UserDefaults.standard.object(forKey: "audioBackup") as? Bool ?? true {
        didSet { UserDefaults.standard.set(audioBackupOn, forKey: "audioBackup") }
    }
    /// まだドライブに上げていない音声の数
    private(set) var backupPending = 0
    let archive: AudioArchive
    /// どこで話したか
    let places = PlaceLog()
    /// 聞き取ってほしい言葉（いつも・職場だけ・職場以外だけ）
    let vocabulary = Vocabulary()
    /// iPhone の中で動く日本語の音声認識（Haas-ja）
    let haas = HaasEngine()
    let homePC = HomePC()
    let calendar = CalendarLink()
    let contacts = ContactsLink()
    let motion = MotionLink()
    let sleep = SleepGuess()
    let officeFilter = OfficeFilter()
    /// 会話に出てきた言葉の数え上げ（人ごとの言葉・言葉の登録の候補）
    let wordStats = WordStats()
    /// 直前の区切りで聞こえた、名前のある人（iPhone・時計それぞれ）。次の区切りのヒントに、その人の言葉を使う
    @ObservationIgnored private var recentPeople: [Bool: (end: Date, names: [String])] = [:]
    /// ほかのアプリ（AUDAY など）の音声の取り込み
    let importer = AudioImporter()
    /// 待機モード：アプリを裏で起こしておき、時計から届いた区切りをすぐ処理する
    private let standby = Standby()
    var standbyOn = UserDefaults.standard.object(forKey: "standby") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(standbyOn, forKey: "standby")
            updateStandby()
        }
    }

    /// 待機モードは、時計が録音しているあいだだけ動かす（何も届かないあいだに無音を流して電池を使わないように）
    private func updateStandby() {
        if standbyOn && watchRecording { standby.start() } else { standby.stop() }
    }

    private let recorder = Recorder()
    /// ライブ文字起こし（オンのあいだだけ、iPhone のマイクの声を数秒ごとにクラウドで文字にして流す）
    let live = LiveTranscriber()
    private(set) var liveOn = false
    /// ライブのために録音を始めたか（ライブを切ったら録音も止める）
    @ObservationIgnored private var liveStartedRecording = false
    /// アクションボタンなどから（Live Activity を出して）始めた録音の、始めた時刻
    @ObservationIgnored private var buttonRecordingStarted: Date?
    @ObservationIgnored private var liveAutoOff: Task<Void, Never>?
    private let docs: GoogleDocs
    private let conversations: ConversationLog
    private let receiver = PhoneReceiver()
    /// 処理中の列。二重に走らせないよう、走っていればそれを待つ。
    private var queueTask: Task<Void, Never>?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        let docs = GoogleDocs()
        self.docs = docs
        conversations = ConversationLog(docs: docs)
        archive = AudioArchive(docs: docs)
        archive.enabled = { [weak self] in self?.audioBackupOn ?? false }
        conversations.apiKey = { [weak self] in
            guard let self, summariesOn else { return nil }
            return settings.groqKey
        }
        conversations.placeName = { [weak self] time in await self?.places.name(at: time) }
        conversations.eventInfo = { [weak self] start, end in
            guard let event = self?.calendar.events(from: start, to: end).first, !event.title.isEmpty else { return nil }
            let detail = event.title + (event.location.map { "（場所: \($0)）" } ?? "")
                + (event.attendees.isEmpty ? "" : "（参加者: " + event.attendees.prefix(8).joined(separator: "、") + "）")
            return (event.title, detail)
        }
        conversations.dayActivities = { [weak self] day in await self?.activities(on: day) ?? [] }
        conversations.spellingHints = { [weak self] c in
            guard let self else { return [] }
            return wordStats.hints(for: c.people, limit: 15) + keywords(for: vocabularyContext(at: c.start))
        }
        conversations.movementName = { [weak self] start, end in
            await self?.motion.movement(from: start, to: end)?.label
        }
        conversations.forgetVoices = { [weak self] ids in
            guard let self else { return }
            await speakers.forgetUnnamed(ids)
            people = await speakers.people()
        }
        recorder.onChunk = { [weak self] _ in self?.processQueue() }
        recorder.onStop = { [weak self] reason in
            self?.endLive()
            self?.isRecording = false
            self?.buttonRecordingStarted = nil
            RecordingActivity.end()
            self?.message = reason
            self?.standby.resume()
            if self?.stopAlertsOn == true, UIApplication.shared.applicationState != .active {
                Self.notify(id: "phone-stopped", title: "iPhone の録音が止まりました",
                            body: reason + " LifeLog を開いて再開してください。")
            }
        }
        live.apiKey = { [weak self] in self?.settings.groqKey }
        // ライブは iPhone 内の Haas-ja を使う（モデルを入れていなければ Groq）
        live.useHaas = { [weak self] in self?.haas.state == .ready }
        live.fixes = { [weak self] in
            guard let self else { return [] }
            return vocabulary.fixes(for: vocabularyContext(at: .now)).map { ($0.wrong, $0.right) }
        }
        live.keywords = { [weak self] in
            guard let self else { return [] }
            return keywords(for: vocabularyContext(at: .now))
        }
        pendingCount = Storage.pendingChunks().count
        receiver.onFile = { [weak self] in
            self?.pendingCount = Storage.pendingChunks().count
            self?.processQueue()
        }
        receiver.onStateChange = { [weak self] in self?.watchStatus = $0 }
        receiver.onWatchRecording = { [weak self] recording, at in
            guard let self else { return }
            // 時計は区切るたびに知らせてくる。しばらく知らせが無ければ通知する
            if recording, stopAlertsOn {
                Self.scheduleWatchAlert(after: (at ?? .now).addingTimeInterval(Self.watchSilence))
            } else {
                Self.cancelWatchAlert()
            }
            guard watchRecording != recording else { return }
            watchRecording = recording
            updateStandby()
            // 時計が止まったら、待っていた iPhone の分を書ける
            processQueue()
        }
        receiver.onMark = { [weak self] time in self?.addMark(at: time) }
        receiver.onWatchResting = { [weak self] since in
            guard let self, since != watchRestingSince else { return }
            watchRestingSince = since
            // 時計が休みに入ったら、待っていた iPhone の分を書ける
            if since != nil { processQueue() }
        }
        importer.onQueued = { [weak self] in
            self?.pendingCount = Storage.pendingChunks().count
            self?.processQueue()
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Power.start()
        receiver.activate()
    }

    /// 聞き分けのモデルを用意し、覚えている声を読み込む。
    func loadSpeakers() async {
        // 聞き分けのモデルの準備より先に、覚えている人を出す
        people = await speakers.people()
        hasSelfVoice = await speakers.hasSelfVoice
        do {
            try await speakers.prepare()
            // 聞き分けのモデルを替えたので、名前のある人は覚えている声のひとこまから声を取り直す
            for (id, samples) in await speakers.peopleNeedingVoices() {
                for sample in samples {
                    guard let url = await archive.playableURL(for: sample.audio) else { continue }
                    try? await speakers.teach(url, from: sample.start, to: sample.end, personID: id, pinned: false)
                }
            }
            hasSelfVoice = await speakers.hasSelfVoice
            people = await speakers.people()
        } catch {
            message = "話者の聞き分けを準備できませんでした: \(error.localizedDescription)"
        }
    }

    /// 「大事なところ」の印。前後1分の行に★を付け、1日のまとめにも出す。
    func addMark(at time: Date = .now) {
        marks.append(time)
        lastMark = time
        processQueue()
    }

    private static func scheduleWatchAlert(after date: Date) {
        let wait = date.timeIntervalSinceNow
        guard wait > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "時計の録音が届いていません"
        content.body = "15分以上、時計の LifeLog から知らせがありません。時計の電池や LifeLog を確かめてください（iPhone から離れているだけなら、そのままで大丈夫です）。"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: watchAlertID, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
    }

    private static func cancelWatchAlert() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [watchAlertID])
    }

    private static func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// 声の登録で iPhone のマイクを使うあいだ、待機モードの無音を止める
    func suspendStandby() { standby.suspend() }
    func resumeStandby() { standby.resume() }

    func enrollSelf(from url: URL) async throws {
        try await speakers.enrollSelf(from: url)
        hasSelfVoice = await speakers.hasSelfVoice
        people = await speakers.people()
    }

    /// その人だけが話している録音から、新しい人を登録する。
    func registerPerson(from url: URL, name: String, context: SpeakerLabeler.Context?) async throws {
        _ = try await speakers.register(url, name: name, context: context)
        people = await speakers.people()
    }

    /// 登録済みの人に、録音した声を足す。
    func addVoice(from url: URL, to id: String) async throws {
        try await speakers.enroll(url, into: id)
        people = await speakers.people()
    }

    /// 名前を付ける・付け替える。これまでの記録とドキュメントの名前も直す。
    func renamePerson(_ id: String, to name: String) async {
        let old = await speakers.name(of: id)
        await speakers.rename(id, to: name)
        await refreshLines(of: id, previousName: old)
    }

    func setContext(_ id: String, to context: SpeakerLabeler.Context?) async {
        await speakers.setContext(id, to: context)
        people = await speakers.people()
    }

    /// 同じ人だった2人をまとめる。source の行は target の名前になる。
    /// まとめる前の人と書き換えた行は merges.json に残し、人の画面から元に戻せる。
    func mergePerson(_ source: String, into target: String, automatic: Bool = false) async {
        let old = await speakers.name(of: source)
        let snapshot = await speakers.snapshot(source)
        let times = conversations.lineTimes { $0.speakerID == source }
        await speakers.merge(source, into: target)
        await relabel(to: target, renaming: old) { $0.speakerID == source }
        if let snapshot, source != target {
            let targetName = await speakers.name(of: target) ?? ""
            MergeLog.add(.init(date: .now, source: snapshot, sourceName: old ?? "人物\(source)", target: target,
                               targetName: targetName, lines: times,
                               automatic: automatic ? true : nil))
        }
    }

    // MARK: - まとめた人を戻す

    /// 記録してあるまとめを元に戻す。まとめる前の人（名前・声）を戻し、書き換えた行の名前も戻す。
    /// そのあと手で別の人に直した行は、そのまま。
    func undoMerge(_ record: MergeLog.Record) async {
        await speakers.revive(record.source.id, snapshot: record.source, from: record.target)
        let times = Set(record.lines)
        let target = record.target
        await relabel(to: record.source.id) { $0.speakerID == target && times.contains($0.time) }
        MergeLog.markUndone(record.id)
        hasSelfVoice = await speakers.hasSelfVoice
    }

    /// ドキュメントの版の履歴で見つけた、前は「人物N」だった行のまとまり
    struct PastMerge: Identifiable {
        /// 前の番号（「人物123」の 123）
        let id: String
        var lines: [(line: ConversationLog.Line, end: TimeInterval?)] = []
        var days: [String] = []
        var name: String { "人物\(id)" }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let pastLine = try! NSRegularExpression(pattern: #"^(\d{2}:\d{2}:\d{2})  (?:★ )?\[([^\]]+)\] ?(.*)$"#)

    /// いま target の名前になっている行のうち、ドキュメントの前の版では「人物N」だった行を、N ごとに集める。
    /// まとめを記録していなかったころのまとめを戻すため。アプリの中の記録は変えない（読むだけ）。
    func findPastMerges(into target: String, progress: @escaping (String) -> Void) async -> (found: [PastMerge], note: String?) {
        guard email != nil else { return ([], "Google にログインしていないので、ドキュメントの履歴を読めません。") }
        let days = conversations.days().filter { day in
            conversations.conversations(on: day).contains { $0.lines.contains { $0.speakerID == target } }
        }
        var groups: [String: PastMerge] = [:]
        var failed = 0
        for (n, day) in days.reversed().enumerated() {
            progress("ドキュメントの履歴を読んでいます… \(n + 1) / \(days.count) 日")
            // その日の target の行を、時刻ごとに（次の行までを声の切り出しに使う）
            var byClock: [String: [(line: ConversationLog.Line, end: TimeInterval?)]] = [:]
            for c in conversations.conversations(on: day) {
                for (i, line) in c.lines.enumerated() where line.speakerID == target {
                    var end: TimeInterval?
                    if let offset = line.offset, line.audio != nil {
                        let next = c.lines[(i + 1)...].first { $0.audio == line.audio }?.offset
                        end = min(offset + 10, next ?? offset + 10)
                    }
                    byClock[Self.clockFormatter.string(from: line.time), default: []].append((line, end))
                }
            }
            let versions: [String]
            do {
                versions = try await docs.pastVersions(day: day, limit: 40)
            } catch {
                failed += 1
                continue
            }
            var found: [Date: String] = [:]
            for version in versions {
                for raw in version.components(separatedBy: .newlines) {
                    let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\r"))
                    let range = NSRange(text.startIndex..., in: text)
                    guard let m = Self.pastLine.firstMatch(in: text, range: range),
                          let clockRange = Range(m.range(at: 1), in: text),
                          let labelRange = Range(m.range(at: 2), in: text),
                          let bodyRange = Range(m.range(at: 3), in: text) else { continue }
                    let label = String(text[labelRange])
                    guard label.hasPrefix("人物"), let number = Int(label.dropFirst(2)),
                          String(number) != target,
                          let candidates = byClock[String(text[clockRange])] else { continue }
                    let body = String(text[bodyRange])
                    // 同じ時刻の行が1つならそれ、いくつかあれば文の頭が同じもの
                    let match = candidates.count == 1 ? candidates.first
                        : candidates.first { $0.line.text.prefix(8) == body.prefix(8) }
                    guard let match, found[match.line.time] == nil else { continue }
                    found[match.line.time] = String(number)
                    groups[String(number), default: PastMerge(id: String(number))].lines.append(match)
                    if groups[String(number)]?.days.contains(day) == false { groups[String(number)]?.days.append(day) }
                }
            }
        }
        let list = groups.values.sorted { $0.lines.count > $1.lines.count }.map { group -> PastMerge in
            var g = group
            g.lines.sort { $0.line.time < $1.line.time }
            g.days.sort()
            return g
        }
        var note: String?
        if failed > 0 { note = "\(failed) 日分は履歴を読めませんでした（通信やドライブの権限）。" }
        if list.isEmpty && note == nil { note = "前の版で「人物N」だった行は見つかりませんでした。" }
        return (list, note)
    }

    /// 見つけた行を「人物N」に戻し、その行の声を録音から覚え直す。
    /// まとめた先の人の、自動で覚えた声のうち、戻した人の声に近いものは戻した人に移す（登録・手直しの声は動かさない）。
    func splitOut(_ past: PastMerge, from target: String, progress: @escaping (String) -> Void) async -> String {
        await speakers.revive(past.id, snapshot: nil, from: target)
        let times = Set(past.lines.map(\.line.time))
        await relabel(to: past.id) { $0.speakerID == target && times.contains($0.time) }
        // 長く話した行から5つまで声を取る
        var taught = 0
        let clips = past.lines.filter { $0.line.audio != nil && $0.line.offset != nil && $0.end != nil }
            .sorted { ($0.end! - $0.line.offset!) > ($1.end! - $1.line.offset!) }
        for clip in clips where taught < 5 {
            progress("声を覚え直しています… \(taught + 1) / 5")
            guard let audio = clip.line.audio, let url = await archive.playableURL(for: audio),
                  let offset = clip.line.offset, let end = clip.end, end - offset >= 2 else { continue }
            if (try? await speakers.teach(url, from: offset, to: end, personID: past.id, pinned: false)) != nil,
               await speakers.hasVoice(past.id) {
                taught += 1
            }
        }
        let moved = await speakers.moveVoices(from: target, to: past.id)
        hasSelfVoice = await speakers.hasSelfVoice
        people = await speakers.people()
        var text = "\(past.lines.count) 行を「\(past.name)」に戻しました。"
        text += taught > 0 ? "声も録音から \(taught) つ覚え直しました。" : "録音が見つからなかったので、声は覚え直していません。"
        if moved > 0 { text += "まとめた先の自動で覚えた声のうち \(moved) つを移しました。" }
        return text
    }

    /// 覚えている人が消えてしまったときに、記録に残っている名前と音声から、名前のある人と自分の声を作り直す。
    func rebuildPeople(progress: @escaping (String) -> Void) async -> String {
        do {
            progress("聞き分けの準備をしています…")
            try await speakers.prepare()
        } catch {
            return "聞き分けを準備できませんでした: \(error.localizedDescription)"
        }
        // 記録から、番号ごとの名前・場と、声を取れそうな行を集める
        var names: [String: String] = [:]
        var contexts: [String: [SpeakerLabeler.Context]] = [:]
        var clips: [String: [(line: ConversationLog.Line, end: TimeInterval)]] = [:]
        var used = Set<String>()
        for day in conversations.days() {
            for c in conversations.conversations(on: day) where c.media == nil {
                for (i, line) in c.lines.enumerated() {
                    guard let id = line.speakerID else { continue }
                    used.insert(id)
                    guard let name = line.speaker, id == SpeakerLabeler.selfID || !name.hasPrefix("人物") else { continue }
                    names[id] = name
                    if let context = places.registeredContext(at: line.time) { contexts[id, default: []].append(context) }
                    // 声を切り出すのは、同じ音声の次の行まで（最長10秒）
                    if let offset = line.offset, line.audio != nil {
                        let next = c.lines[(i + 1)...].first { $0.audio == line.audio }?.offset
                        let end = min(offset + 10, next ?? offset + 10)
                        if end - offset >= 2 { clips[id, default: []].append((line, end)) }
                    }
                }
            }
        }
        let restored = names.map { id, name -> (id: String, name: String?, context: SpeakerLabeler.Context?) in
            let list = contexts[id] ?? []
            let work = list.filter { $0 == .work }.count
            let context: SpeakerLabeler.Context? = list.isEmpty ? nil : (work * 2 > list.count ? .work : .other)
            return (id, id == SpeakerLabeler.selfID ? nil : name, context)
        }
        await speakers.restore(restored, usedIDs: used)
        // 1人につき、長く話した新しい行から5つまで声を取る
        var taught = 0
        for (n, (id, list)) in clips.sorted(by: { $0.key < $1.key }).enumerated() {
            progress("声を取り直しています… \(n + 1) / \(clips.count) 人")
            let best = list.sorted { ($0.end - ($0.line.offset ?? 0), $0.line.time) > ($1.end - ($1.line.offset ?? 0), $1.line.time) }
            var got = 0
            for clip in best where got < 5 {
                guard let audio = clip.line.audio, let url = await archive.playableURL(for: audio),
                      let offset = clip.line.offset else { continue }
                if (try? await speakers.teach(url, from: offset, to: clip.end, personID: id, pinned: false)) != nil,
                   await speakers.hasVoice(id) {
                    got += 1
                }
            }
            if got > 0 { taught += 1 }
        }
        hasSelfVoice = await speakers.hasSelfVoice
        people = await speakers.people()
        let named = restored.filter { $0.id != SpeakerLabeler.selfID }.count
        return "名前のある人 \(named) 人\(names[SpeakerLabeler.selfID] != nil ? "と自分" : "")を記録から作り直し、そのうち \(taught) 人の声を録音から取り直しました。"
    }

    /// 名前の無い声に近い、名前のある人。
    func voiceSuggestion(for id: String) async -> (id: String, name: String, distance: Float)? {
        guard let best = await speakers.closestNamed(to: id),
              let name = await speakers.name(of: best.id) else { return nil }
        return (best.id, name, best.distance)
    }

    /// 名前の無い声を、名前のある人（自分を含む）にまとめる。
    func assign(_ id: String, to target: String) async {
        if target == SpeakerLabeler.selfID {
            await mergeIntoSelf([id])
        } else {
            await mergePerson(id, into: target)
        }
    }

    /// 自分の声だった人たちを、自分にまとめる（声も覚え、記録とドキュメントの名前も「自分」に直す）。
    func mergeIntoSelf(_ ids: [String]) async {
        await speakers.ensureSelf()
        for id in ids where id != SpeakerLabeler.selfID {
            await mergePerson(id, into: SpeakerLabeler.selfID)
        }
    }

    func removePerson(_ id: String) async {
        await speakers.remove(id)
        people = await speakers.people()
    }

    func newPerson(name: String, context: SpeakerLabeler.Context?) async -> String {
        let id = await speakers.newPerson(name: name, context: context)
        people = await speakers.people()
        return id
    }

    /// 記録の行の話者を直す範囲
    enum SpeakerFix {
        /// この行だけ
        case line
        /// 同じ区切り（5分）で同じ声とされた行
        case sameVoice
        /// これまでにこの声とされたすべての行（2人を1人にまとめる）
        case everywhere
    }

    /// 記録の行の話者を直し、その行の声をその人の声として覚える。
    /// next は同じ音声の次の行（声を切り出す終わりに使う）。
    func fixSpeaker(of line: ConversationLog.Line, next: ConversationLog.Line?, to id: String,
                    scope: SpeakerFix) async {
        if id == SpeakerLabeler.selfID { await speakers.ensureSelf() }
        // 声を覚える。音声が手元にもドライブにも無ければ、名前だけ直す
        if let audio = line.audio, let url = await archive.playableURL(for: audio) {
            let start = line.offset ?? 0
            let end = min(start + 10, next?.offset ?? start + 10)
            try? await speakers.teach(url, from: start, to: max(end, start + 1), personID: id)
        }
        let old = line.speakerID
        switch scope {
        case .line:
            await relabel(to: id) { $0.time == line.time && $0.text == line.text && $0.audio == line.audio }
        case .sameVoice:
            await relabel(to: id) { other in
                other.audio == line.audio
                    && (old != nil ? other.speakerID == old : other.speaker == line.speaker)
            }
        case .everywhere:
            guard let old, old != id else {
                await relabel(to: id) { $0.time == line.time && $0.text == line.text && $0.audio == line.audio }
                return
            }
            await mergePerson(old, into: id)
        }
        hasSelfVoice = await speakers.hasSelfVoice
    }

    private func relabel(to id: String, renaming: String? = nil,
                         where match: (ConversationLog.Line) -> Bool) async {
        guard let name = await speakers.name(of: id) else { return }
        do {
            try await conversations.relabel(to: id, name: name, renaming: renaming, where: match)
        } catch {
            message = "ドキュメントの名前を直せませんでした: \(error.localizedDescription)"
        }
        people = await speakers.people()
    }

    private func refreshLines(of id: String, previousName old: String?) async {
        await relabel(to: id, renaming: old) { line in
            line.speakerID == id || (line.speakerID == nil && old != nil && line.speaker == old)
        }
    }

    func restoreSignIn() async {
        await docs.restore()
        email = docs.signedInEmail
        processQueue()
        if speakerLabelsOn { await loadSpeakers() }
    }

    func signIn() async {
        do {
            try await docs.signIn()
            email = docs.signedInEmail
            processQueue()
        } catch {
            message = "ログインできませんでした: \(error.localizedDescription)"
        }
    }

    func signOut() {
        docs.signOut()
        email = nil
    }

    /// fromButton: アクションボタン・コントロールセンター・ショートカットなど、アプリを開かずに押されたとき。
    /// そのときは iOS の決まりで、録音を始める前に Live Activity を出す（出さないと録音が止められる）。
    func toggleRecording(fromButton: Bool = false) async {
        if isRecording {
            endLive()
            recorder.stop()
            isRecording = false
            buttonRecordingStarted = nil
            RecordingActivity.end()
            standby.resume()
            return
        }
        let started = Date.now
        if fromButton { RecordingActivity.start(started: started) }
        do {
            message = "日本語モデルを確認中…"
            try await Transcriber.prepare()
            standby.suspend()
            try recorder.start()
            isRecording = true
            if fromButton { buttonRecordingStarted = started }
            message = ""
        } catch {
            RecordingActivity.end()
            standby.resume()
            message = "録音を始められませんでした: \(error.localizedDescription)"
            if fromButton, stopAlertsOn {
                Self.notify(id: "phone-stopped", title: "iPhone の録音を始められませんでした",
                            body: error.localizedDescription + " LifeLog を開いて始めてください。")
            }
        }
    }

    /// ロック画面・コントロールセンター・アクションボタンからの操作
    func handle(_ action: LifeLogAction) async {
        switch action {
        case .toggleRecording: await toggleRecording(fromButton: true)
        case .startRecording: if !isRecording { await toggleRecording(fromButton: true) }
        case .stopRecording: if isRecording { await toggleRecording(fromButton: true) }
        case .startRecordingInApp: if !isRecording { await toggleRecording() }
        case .mark: addMark()
        }
    }

    // MARK: - ライブ

    func setLive(_ on: Bool) async {
        guard on != liveOn else { return }
        if on {
            if !isRecording {
                await toggleRecording()
                guard isRecording else { return }
                liveStartedRecording = true
            }
            live.start()
            recorder.setListener(live.listener)
            liveOn = true
        } else {
            let startedHere = liveStartedRecording
            endLive()
            if startedHere, isRecording { await toggleRecording() }
        }
    }

    /// ライブだけを止める（録音はそのまま）
    private func endLive() {
        guard liveOn else { return }
        recorder.setListener(nil)
        live.stop()
        liveOn = false
        liveStartedRecording = false
        liveAutoOff?.cancel()
        liveAutoOff = nil
    }

    /// アプリを閉じて10分たったら、ライブを自動で切る（切り忘れで電池と無料枠を使わないように）
    func appMovedToBackground() {
        guard liveOn, liveAutoOff == nil else { return }
        liveAutoOff = Task {
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            liveAutoOff = nil
            await setLive(false)
        }
    }

    func appBecameActive() {
        liveAutoOff?.cancel()
        liveAutoOff = nil
        // ボタンで始めた録音の Live Activity は、古ければ出し直す（8時間で iOS に終わらせられるため）。
        // 録音していないのに残っている表示は消す。
        if isRecording, let started = buttonRecordingStarted {
            RecordingActivity.renewIfNeeded(started: started)
        } else if !isRecording {
            RecordingActivity.end()
        }
    }

    /// 溜まっている音声を古い順に処理する。
    func processQueue() {
        Task { await runQueue() }
    }

    /// processQueue と同じだが、終わるまで待つ（裏での処理用）。
    func runQueue() async {
        if let queueTask { return await queueTask.value }
        // 時計から届いた音声や裏の処理でアプリが起こされたときは、画面が出ないのでログインの復元もここでする
        if email == nil {
            await docs.restore()
            email = docs.signedInEmail
        }
        guard email != nil, queueTask == nil else { return }
        // 裏にいても、iOS が許すあいだ（30秒ほど）は続けさせてもらう
        let background = UIApplication.shared.beginBackgroundTask(withName: "transcribe")
        let task = Task {
            // 処理しているあいだに届いた区切りも、続けて処理する
            while await drainQueue(), !Task.isCancelled,
                  Storage.pendingChunks().contains(where: { !isActiveChunk($0) }) {}
        }
        queueTask = task
        // 裏で使える時間が終わったと言われたら、区切りの切れ目で止める
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        queueTask = nil
        pendingCount = Storage.pendingChunks().count
        if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        Self.scheduleBackgroundWork()
        // 夜に充電していれば、1日分を聞き直す
        startNightlyIfTime()
        // 時計の区切りを待っている行があれば、少ししてから見直す
        if merger.hasHeld, retry == nil {
            retry = Task {
                try? await Task.sleep(for: .seconds(60))
                retry = nil
                processQueue()
            }
        }
    }

    /// 溜まっている区切りを処理する。失敗や中断で途中でやめたら false。
    private func drainQueue() async -> Bool {
        await conversations.repairBrokenLines()
        await conversations.removeFillerLines()
        await conversations.removeBlankLines()
        // 取り込んだ昔の音声は、いま録っている分のあとに回す
        let pending = Storage.pendingChunks()
        let ordered = pending.filter { !Storage.isImported($0) } + pending.filter(Storage.isImported)
        var importedDone = 0
        for url in ordered where !isActiveChunk(url) {
            // 裏で使える時間が終わったら、残りは次の機会に回す
            if Task.isCancelled { return false }
            // 取り込んだ音声は数個ずつ書き、そのあいだに届いたいまの録音を先に処理する
            if Storage.isImported(url) {
                if importedDone >= 3 { break }
                importedDone += 1
            }
            // 書いている途中で録音が終わった区切りは開けない。何度やっても同じなので脇によけて先へ進む
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard (try? AVAudioFile(forReading: url)) != nil else {
                Storage.setAside(url)
                continue
            }
            do {
                merger.add(try await transcribe(url))
                if Storage.isFromWatch(url), let start = Storage.startDate(of: url) {
                    lastWatchEnd = max(lastWatchEnd, start.addingTimeInterval(Self.duration(of: url)))
                }
                // 文字起こしした音声は、アプリで聞き直せるよう1日だけ残す
                Storage.keep(url)
            } catch where Self.isBrokenAudio(error) {
                // 開けても中身が途中で切れている区切り
                Storage.setAside(url)
            } catch {
                message = "処理に失敗しました（あとで再試行します）: \(error.localizedDescription)"
                return false
            }
            pendingCount = Storage.pendingChunks().count
        }
        if Task.isCancelled { return false }
        // 両方の区切りがそろった時間帯まで、良いほうを選んで書く
        let settled = settledUntil()
        merger.release(before: settled)
        guard await writeMerged() else { return false }
        // いま書いた行に、決まり文句や連打があれば消す
        await autoClean()
        // 印の前後1分の行に★を付ける
        if !marks.isEmpty { marks = await conversations.applyMarks(marks, settled: settled) }
        // しばらく話していなければ会話を閉じて見出しを付け、前の日にはまとめを付ける。
        // まだ書いていない時間帯（録音中の区切りや、届いていない時計の区切り）に続きがあるかもしれないので、その手前で見る。
        await conversations.closeIdle(now: settled, waiting: ConversationLog.gap)
        // 閉じた会話の中で、同じ人が別の「人物N」に分かれていたらまとめる
        await consolidateSpeakers(conversations.takeClosed())
        // 閉じた会話の言葉を数える（はじめは、これまでの記録を全部）
        let recentDays = wordStats.isEmpty ? conversations.days() : Array(conversations.days().suffix(2))
        wordStats.count(days: recentDays.map { ($0, conversations.conversations(on: $0)) })
        await conversations.writeDailySummaries(today: dayFormatter.string(from: .now))
        await conversations.writePeopleNotes()
        await conversations.writeWeeklySummary(today: dayFormatter.string(from: .now))
        // ドライブを読む AI 向けの案内と索引を、中身が変わっていたら書き直す
        await updateDriveGuide()
        // Wi-Fi なら音声をドライブに上げ、古い手元の音声を片付ける
        await archive.uploadPending()
        backupPending = archive.pendingCount
        return true
    }

    // MARK: - 記録の掃除

    /// その文だけの行を消す言葉
    var junkPhrases = UserDefaults.standard.stringArray(forKey: "junkPhrases") ?? [] {
        didSet { UserDefaults.standard.set(junkPhrases, forKey: "junkPhrases") }
    }
    /// 掃除の画面で残すことにした行・戻した行（自動でも消さない）
    @ObservationIgnored private var keptLines = Set(UserDefaults.standard.stringArray(forKey: "keptLines") ?? []) {
        didSet { UserDefaults.standard.set(Array(keptLines), forKey: "keptLines") }
    }
    /// 直近に書いた行（書いたすぐあとに掃除する）
    @ObservationIgnored private var recentlyWritten: [(day: String, line: ConversationLog.Line)] = []

    /// 全期間から消す候補を探す。
    func findJunk() -> [Junk.Candidate] {
        conversations.findJunk(custom: junkPhrases, flagged: unheardLines).filter { !keptLines.contains(Junk.key($0.line)) }
    }

    /// 照らし直しで「聞こえていない」と分かった行
    @ObservationIgnored private var unheardLines = Set(UserDefaults.standard.stringArray(forKey: "unheardLines") ?? []) {
        didSet { UserDefaults.standard.set(Array(unheardLines), forKey: "unheardLines") }
    }
    /// 照らし直しを済ませた音声
    @ObservationIgnored private var recheckedAudio = Set(UserDefaults.standard.stringArray(forKey: "recheckedAudio") ?? []) {
        didSet { UserDefaults.standard.set(Array(recheckedAudio), forKey: "recheckedAudio") }
    }
    /// 照らし直しの進み具合（済んだ区切り・全部の区切り）。動いていなければ nil。
    private(set) var recheckProgress: (done: Int, total: Int)?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    private(set) var recheckResult = ""

    /// 残っている音声を iPhone の中でもう一度文字起こしし、記録の行と読みが合わない行を「聞こえていない文」にする。
    /// 手元に無い音声はドライブから取ってくる。済んだ音声は次からは飛ばす。
    func startRecheck() {
        guard recheckTask == nil else { return }
        let targets = conversations.linesByAudio().filter { !recheckedAudio.contains($0.audio) }
        recheckProgress = (0, targets.count)
        recheckResult = ""
        recheckTask = Task {
            var found = 0
            var missing = 0
            for (n, target) in targets.enumerated() {
                if Task.isCancelled { break }
                recheckProgress = (n, targets.count)
                guard let url = await archive.playableURL(for: target.audio) else {
                    missing += 1
                    continue
                }
                let start = target.lines.first?.time ?? .now
                guard let local = try? await Transcriber.transcribe(
                    url, words: keywords(for: vocabularyContext(at: start))) else { continue }
                let duration = Self.duration(of: url)
                let lines = target.lines.map { CloudTranscriber.Line(offset: $0.offset, text: $0.original ?? $0.text) }
                let ok = TranscriptCheck.agrees(lines, with: local, duration: duration)
                for (line, fine) in zip(target.lines, ok) where !fine {
                    unheardLines.insert(Junk.key(line))
                    found += 1
                }
                recheckedAudio.insert(target.audio)
            }
            recheckResult = "聞こえていない文が \(found) 行見つかりました。"
                + (missing > 0 ? "音声が残っていない区切りが \(missing) 個ありました（音声をドライブに保存する前の分など）。" : "")
            recheckProgress = nil
            recheckTask = nil
        }
    }

    func cancelRecheck() {
        recheckTask?.cancel()
    }

    /// 選んだ行を消し、選ばなかった行は今後も残す。結果を文で返す。
    func removeJunk(_ chosen: [Junk.Candidate], keeping: [Junk.Candidate]) async -> String {
        keptLines.formUnion(keeping.map { Junk.key($0.line) })
        // 書き足しと重ならないよう、処理中ならそれを待つ
        if let queueTask { await queueTask.value }
        var removed = 0
        for (day, items) in Dictionary(grouping: chosen, by: \.day).sorted(by: { $0.key < $1.key }) {
            do {
                try await conversations.remove(items.map { ($0.line, $0.kind) }, day: day)
                removed += items.count
            } catch {
                return "\(removed) 行を消したところで止まりました（もう一度押すと続きを消します）: \(error.localizedDescription)"
            }
        }
        let gone = Set(chosen.map { ConversationLog.docLine($0.line) })
        lastLines.removeAll { gone.contains($0) }
        return "\(removed) 行を、アプリとドキュメントから消しました。"
    }

    func trash() -> [Junk.TrashItem] { conversations.trash() }

    /// 消した行を元に戻す（以後は自動でも消さない）。
    func restore(_ item: Junk.TrashItem) async throws {
        if let queueTask { await queueTask.value }
        try await conversations.restore(item)
        keptLines.insert(Junk.key(item.line))
    }

    /// いま書いた行と、それと同じ文の連打を消す。取り込んだ昔の音声の行も同じように見る。
    private func autoClean() async {
        let written = recentlyWritten
        recentlyWritten = []
        guard !written.isEmpty else { return }
        let keys = Set(written.map { Junk.key($0.line) })
        let texts = Set(written.map { Junk.normalized($0.line.text) })
        let found = conversations.findJunk(custom: junkPhrases, only: Array(Set(written.map(\.day))))
            .filter { item in
                let key = Junk.key(item.line)
                guard !keptLines.contains(key) else { return false }
                return keys.contains(key) || (item.kind == .streak && texts.contains(Junk.normalized(item.line.text)))
            }
        guard !found.isEmpty else { return }
        for (day, items) in Dictionary(grouping: found, by: \.day) {
            try? await conversations.remove(items.map { ($0.line, $0.kind) }, day: day)
        }
        let gone = Set(found.map { ConversationLog.docLine($0.line) })
        lastLines.removeAll { gone.contains($0) }
    }

    /// 記録のある日（新しい順）
    func recordedDays() -> [String] { conversations.recordedDays() }

    func conversations(on day: String) -> [ConversationLog.Conversation] { conversations.conversations(on: day) }

    // MARK: - 過ごし方

    /// 作っている途中の過ごし方（同じ日を二重に作らない）
    @ObservationIgnored private var activityTasks: [String: Task<[Activity], Never>] = [:]

    /// 前に作った過ごし方（すぐ画面に出す用。録音の無い時間の予定・移動は入っていない）
    func savedActivities(on day: String) -> [Activity] { ActivityStore.load(day)?.activities ?? [] }

    /// 1日の過ごし方。閉じた会話や予定が前に作ったときと同じなら、作り直さない（rebuild で作り直す）。
    /// 録音の無い時間のカレンダーの予定と移動は、毎回足す。
    func activities(on day: String, rebuild: Bool = false) async -> [Activity] {
        if let running = activityTasks[day] { return await running.value }
        let task = Task { await makeActivities(on: day, rebuild: rebuild) }
        activityTasks[day] = task
        let result = await task.value
        activityTasks[day] = nil
        return result
    }

    private func makeActivities(on day: String, rebuild: Bool) async -> [Activity] {
        guard let dayStart = dayFormatter.date(from: day) else { return [] }
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)
        let closed = conversations(on: day).filter { $0.closed && !$0.lines.isEmpty }
        let events = calendar.dayEvents(from: dayStart, to: dayEnd)
        let basis = ActivityBuilder.basis(closed, events: events)
        let key = summariesOn ? settings.groqKey : nil
        let saved = ActivityStore.load(day)
        var recorded: [Activity]
        if !rebuild, let saved, saved.basis == basis, saved.smart || key == nil {
            recorded = saved.activities
        } else {
            let built = await ActivityBuilder.recorded(closed, events: events, previous: saved?.activities, apiKey: key)
            recorded = built.activities
            ActivityStore.save(.init(activities: recorded, basis: basis, smart: built.smart), day: day)
        }
        let until = min(dayEnd, .now)
        let trips = await motion.trips(from: dayStart, to: until).compactMap { trip in
            trip.movement.activityTitle.map { (start: trip.start, end: trip.end, title: $0) }
        }
        return ActivityBuilder.addUnrecorded(recorded, events: events, trips: trips, until: until)
    }

    // MARK: - ドライブを読む AI 向けの案内と索引

    /// 最後に案内と索引を確かめた時刻（書き直しは多くても20分に1回）
    @ObservationIgnored private var driveGuideChecked: Date = .distantPast

    /// 「00 はじめに読んでください（AI 向けの説明）」と「01 日ごとの索引」を、中身が変わっていたら書き直す。
    /// アプリの中の記録は読むだけ。日ごとのドキュメントには触らない。
    func updateDriveGuide(force: Bool = false) async {
        guard email != nil, force || Date.now.timeIntervalSince(driveGuideChecked) >= 20 * 60 else { return }
        driveGuideChecked = .now
        let days = conversations.days().filter { !conversations.conversations(on: $0).isEmpty }

        let people = self.people.filter { $0.name != nil && !$0.isSelf }.map { person in
            DriveGuide.Person(name: person.displayName, context: person.context?.label,
                              words: wordStats.topWords(for: person.displayName))
        }
        var words = DriveGuide.Words()
        for group in Vocabulary.Group.allCases {
            words.groups.append((label: group.label, words: vocabulary.words(in: group)))
        }
        words.topics = vocabulary.topics.map { (name: $0.name, words: $0.triggers + $0.words) }
        words.fixes = vocabulary.fixes.map { (wrong: $0.wrong, right: $0.right) }
        let guide = DriveGuide.guide(people: people, words: words, days: days)

        let entries = days.map { day -> DriveGuide.DayEntry in
            let list = conversations.conversations(on: day)
            let summary = conversations.summary(on: day)
            var flow = savedActivities(on: day).map(\.flowLine)
            if flow.isEmpty { flow = summary?.flow ?? [] }
            if flow.isEmpty {
                flow = list.filter { $0.closed && $0.title != nil }.map(ConversationLog.headingText)
            }
            var people: [String] = []
            var unnamed = Set<String>()
            for name in list.flatMap(\.people) {
                if name.hasPrefix("人物") { unnamed.insert(name); continue }
                if !people.contains(name) { people.append(name) }
            }
            if !unnamed.isEmpty { people.append("名前の無い人\(unnamed.count)人") }
            var places: [String] = []
            for place in list.compactMap(\.place) where !places.contains(place) { places.append(place) }
            let marked = list.reduce(0) { count, c in count + c.lines.filter { $0.marked == true }.count }
            return DriveGuide.DayEntry(day: day, flow: flow, people: people, places: places,
                                       decisions: summary?.decisions ?? [], todos: summary?.todos ?? [],
                                       conversations: list.count, marked: marked)
        }
        let index = DriveGuide.index(entries)

        for (name, paragraphs) in [(DriveGuide.guideName, guide), (DriveGuide.indexName, index)] {
            let key = "driveStamp-" + name
            let stamp = DriveGuide.stamp(paragraphs)
            guard force || UserDefaults.standard.string(forKey: key) != stamp else { continue }
            do {
                try await docs.overwrite(paragraphs, name: name)
                UserDefaults.standard.set(stamp, forKey: key)
            } catch {
                // 通信できないときは5分ほどしてやり直す
                driveGuideChecked = Date.now.addingTimeInterval(-15 * 60)
                return
            }
        }
    }

    // MARK: - 会話ごとの話者のまとめ直し

    /// 閉じた会話ごとに、同じ人が別の「人物N」に分かれてしまっていたらまとめる。
    /// まとめるのは、名前が無く、登録や手直しで覚えた声も無い「人物N」だけ（名前のある人どうしはまとめない）。
    /// 同じ区切り（5分）の中で別の声とされた2人は、別の人とみなしてまとめない。
    private func consolidateSpeakers(_ closed: [ConversationLog.Conversation]) async {
        guard speakerLabelsOn else { return }
        var merged = 0
        for c in closed where c.media == nil {
            let ids = Set(c.lines.compactMap(\.speakerID))
            guard ids.count >= 2 else { continue }
            var apart = Set<[String]>()
            for (_, lines) in Dictionary(grouping: c.lines.filter { $0.speakerID != nil }, by: { $0.audio ?? "" }) {
                let inChunk = Array(Set(lines.compactMap(\.speakerID)))
                for a in inChunk { for b in inChunk where a < b { apart.insert([a, b]) } }
            }
            let merges = await speakers.consolidation(among: ids, apart: apart, strictness: speakerStrictness)
            for m in merges { await mergePerson(m.source, into: m.target, automatic: true) }
            merged += merges.count
        }
        if merged > 0 { lastEngine += "・同じ人の声を \(merged) つまとめた" }
    }

    // MARK: - 呼ばれた名前

    /// その日の会話で「〇〇さん」と呼ばれたすぐあと（20秒以内）に、別の声で答えた人と、その名前。声ごとに、多い順。
    func calledNames(on day: String) -> [String: [(name: String, count: Int)]] {
        var counts: [String: [String: Int]] = [:]
        for c in conversations(on: day) where c.media == nil {
            let lines = c.lines
            for (i, line) in lines.enumerated() {
                let called = Self.calledNames(in: line.text)
                guard !called.isEmpty,
                      let reply = lines[(i + 1)...].prefix(3).first(where: {
                          $0.speakerID != nil && $0.speakerID != line.speakerID
                              && $0.time.timeIntervalSince(line.time) <= 20
                      }),
                      let id = reply.speakerID else { continue }
                for name in called { counts[id, default: [:]][name, default: 0] += 1 }
            }
        }
        return counts.mapValues { names in
            names.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        }
    }

    /// 人の呼び方ではない「〇〇さん」
    private static let notNames: Set<String> = [
        "皆", "奥", "父", "母", "兄", "姉", "弟", "妹", "娘", "息子", "旦那", "店員", "運転手", "大家", "業者",
        "隣", "向こう", "相手", "先方", "担当", "客", "親御", "神", "仏", "王", "姫", "赤", "坊", "皆様",
    ]

    /// 文の中の「田中さん」「タナカくん」などの名前の部分（漢字かカタカナだけのもの）
    static func calledNames(in text: String) -> [String] {
        let string = text as CFString
        guard let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: CFStringGetLength(string)),
                                                      kCFStringTokenizerUnitWord, Locale(identifier: "ja_JP") as CFLocale)
        else { return [] }
        var tokens: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            tokens.append((text as NSString).substring(with: NSRange(location: r.location, length: r.length)))
        }
        var names: [String] = []
        for (i, token) in tokens.enumerated() {
            for suffix in ["さん", "くん", "ちゃん"] {
                var name: String?
                if token == suffix, i > 0 {
                    name = tokens[i - 1]
                } else if token.hasSuffix(suffix), token.count > suffix.count {
                    name = String(token.dropLast(suffix.count))
                }
                if let name, isNameLike(name), !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    private static func isNameLike(_ s: String) -> Bool {
        guard (1...6).contains(s.count), !notNames.contains(s) else { return false }
        return s.unicodeScalars.allSatisfy { $0.properties.isIdeographic || $0 == "々" || (0x30A1...0x30FC).contains($0.value) }
    }

    // MARK: - 行の文字の手直し

    /// 記録の行の文字を直す。fix を渡すと、その「間違い→正しい」を誤変換の一覧にも足す。失敗したら理由を返す。
    func editLine(_ line: ConversationLog.Line, to text: String, addFix fix: (wrong: String, right: String)?) async -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != line.text else { return nil }
        // 書き足しと重ならないよう、処理中ならそれを待つ
        if let queueTask { await queueTask.value }
        do {
            try await conversations.editText([.init(line: line, text: text, confidence: 1, manual: true)],
                                             day: dayFormatter.string(from: line.time))
        } catch {
            return "直せませんでした: \(error.localizedDescription)"
        }
        if let fix {
            let group: Vocabulary.Group = vocabularyContext(at: line.time) == .work ? .work : .other
            vocabulary.addFix(wrong: fix.wrong, right: fix.right, group: group)
        }
        let old = ConversationLog.docLine(line)
        if let i = lastLines.firstIndex(of: old) {
            var edited = line
            edited.text = text
            lastLines[i] = ConversationLog.docLine(edited)
        }
        return nil
    }

    /// 直す前と後の文から、変わったところ（間違い→正しい）を取り出す。誤変換の一覧に足せそうなときだけ返す。
    static func changedPart(from old: String, to new: String) -> (wrong: String, right: String)? {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // 1文字だけの違いは、前後の1文字を含めて言葉にする（1文字の置き換えはほかの文まで変えてしまうため）
        while a.count - suffix - prefix < 2 {
            if prefix > 0 { prefix -= 1 } else if suffix > 0 { suffix -= 1 } else { break }
        }
        let wrong = String(a[prefix..<(a.count - suffix)])
        let right = String(b[prefix..<(b.count - suffix)])
        guard (2...12).contains(wrong.count), !right.isEmpty, right.count <= 16, wrong != right else { return nil }
        return (wrong, right)
    }

    // MARK: - 夜の聞き直し

    /// 最後に聞き直した結果（画面に出す）
    private(set) var nightlyResult = UserDefaults.standard.string(forKey: "nightlyResult") ?? "" {
        didSet { UserDefaults.standard.set(nightlyResult, forKey: "nightlyResult") }
    }
    /// 聞き直しの進み具合（済んだ区切り・全部の区切り）。動いていなければ nil。
    private(set) var nightlyProgress: (done: Int, total: Int)?

    /// 充電中に、手元に残っている音声（1日分）を聞き直し、良くなった行だけ差し替える。
    /// 1. その日に出た名前・話題・予定を全部ヒントにして、端末内でもう一度聞き取る
    /// 2. Haas-ja で書けていなかった区切り（電池優先・家の PC に届かなかったときなど）は、Haas-ja で書き直し、
    ///    端末内の聞き取りに前より合う行だけ差し替える
    /// 3. 確からしさの低い行は、その日の言葉をヒントに言語モデルで直す（2つの聞き取りを見比べる）
    /// 手で直した行は変えない。差し替えた行の元の文は「直す前」として残る。
    func runNightly(force: Bool = false) async {
        guard nightlyProgress == nil, email != nil, force || Power.isCharging else { return }
        // 二重に走らせないよう、待つ前に「動いている」にする
        nightlyProgress = (0, 0)
        defer { nightlyProgress = nil }
        if let queueTask { await queueTask.value }
        let targets = conversations.linesByAudio().filter { item in
            Storage.keptAudio(named: item.audio) != nil && !NightlyRecheck.isNightDone(item.audio)
                && !item.audio.hasSuffix("-i.m4a")
        }
        guard !targets.isEmpty else {
            if force { nightlyResult = "聞き直す音声がありません（聞き直していない1日分の音声が手元にありません）。" }
            return
        }
        nightlyProgress = (0, targets.count)
        var changedLines = 0
        var processed = 0
        var hints: [String: [String]] = [:]
        for (n, target) in targets.enumerated() {
            if Task.isCancelled { break }
            nightlyProgress = (n, targets.count)
            guard let url = Storage.keptAudio(named: target.audio) else { continue }
            let lines = target.lines.filter { $0.checked != true }
            guard !lines.isEmpty else {
                NightlyRecheck.markNightDone(target.audio)
                processed += 1
                continue
            }
            let context = vocabularyContext(at: lines[0].time)
            let words: [String]
            if let known = hints[target.day] { words = known } else { words = await dayHints(target.day, context: context) }
            hints[target.day] = words
            let duration = Self.duration(of: url)
            guard let local = try? await Transcriber.transcribe(url, words: words) else { continue }
            // 行ごとの時間（同じ音声の次の行まで）と、その時間の端末内の聞き取り
            let all = target.lines
            let spans = lines.map { line -> (start: TimeInterval, end: TimeInterval) in
                let start = line.offset ?? 0
                let next = all.first { ($0.offset ?? 0) > start }?.offset ?? duration
                return (start, max(next, start + 0.5))
            }
            let heard = spans.map { span in
                local.filter { $0.offset >= span.start - 1 && $0.offset < span.end + 1 }.map(\.text).joined()
            }
            var texts = lines.map(\.text)
            var confidence = lines.map(\.confidence)
            if !NightlyRecheck.isHaasDone(target.audio) {
                var redo: [CloudTranscriber.Line]?
                if homePC.shouldTry { redo = try? await homePC.transcribe(url, local: local) }
                if redo == nil, haas.isUsable { redo = try? await haas.transcribe(url, local: local) }
                if let redo {
                    for i in lines.indices {
                        let text = redo.filter { ($0.offset ?? -1) >= spans[i].start - 0.5 && ($0.offset ?? -1) < spans[i].end - 0.2 }
                            .map(\.text).joined()
                        guard !text.isEmpty, text != texts[i], !heard[i].isEmpty,
                              let newScore = TranscriptCheck.similarity(text, heard[i]) else { continue }
                        let oldScore = TranscriptCheck.similarity(lines[i].original ?? lines[i].text, heard[i]) ?? 0
                        if newScore >= oldScore + 0.15 {
                            var fixed = text
                            for fix in vocabulary.fixes(for: context) {
                                fixed = fixed.replacingOccurrences(of: fix.wrong, with: fix.right)
                            }
                            texts[i] = fixed
                            confidence[i] = (newScore * 100).rounded() / 100
                        }
                    }
                }
            }
            // 確からしさの低い行と、書き直した行は、その日の言葉をヒントに言語モデルで直す
            if correctionOn, let key = settings.groqKey {
                let picks = lines.indices.filter { texts[$0] != lines[$0].text || lines[$0].isUncertain }
                if !picks.isEmpty,
                   let fixed = try? await Summarizer.correct(picks.map { texts[$0] }, keywords: words, previous: nil,
                                                             alternatives: picks.map { heard[$0] }, apiKey: key) {
                    for (k, i) in picks.enumerated() where !fixed[k].isEmpty { texts[i] = fixed[k] }
                }
            }
            let changes = lines.indices.filter { texts[$0] != lines[$0].text }.map {
                ConversationLog.TextChange(line: lines[$0], text: texts[$0], confidence: confidence[$0], manual: false)
            }
            if !changes.isEmpty {
                // 書き足しと重ならないよう、処理中ならそれを待つ
                if let queueTask { await queueTask.value }
                do {
                    changedLines += try await conversations.editText(changes, day: target.day)
                } catch {
                    break
                }
            }
            NightlyRecheck.markNightDone(target.audio)
            processed += 1
        }
        nightlyResult = "\(Date.now.formatted(date: .abbreviated, time: .shortened)) に \(processed) 区切りを聞き直し、\(changedLines) 行を直しました。"
            + (processed < targets.count ? "（残りは次の充電中に続けます）" : "")
    }

    /// その日に出た名前・話題・予定の言葉（夜の聞き直しのヒント）
    private func dayHints(_ day: String, context: SpeakerLabeler.Context) async -> [String] {
        let texts = conversations(on: day).flatMap(\.lines).map(\.text)
        let text = texts.joined()
        let topicWords = vocabulary.topics.filter { $0.isMentioned(in: text) }.flatMap(\.words)
        var events: [String] = []
        if let date = dayFormatter.date(from: day) {
            for event in calendar.events(from: date, to: date.addingTimeInterval(24 * 3600)) {
                events.append(event.title)
                events += event.attendees
                if let location = event.location { events.append(location) }
            }
        }
        let names = await contacts.mentioned(in: texts)
        var seen = Set<String>()
        return (names + topicWords + events + keywords(for: context)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 夜（22時〜6時）に充電していれば、聞き直しを始める
    private func startNightlyIfTime() {
        let hour = Calendar.current.component(.hour, from: .now)
        guard Power.isCharging, hour >= 22 || hour < 6, nightlyProgress == nil else { return }
        Task { await runNightly() }
    }

    // MARK: - 裏での処理

    /// 充電中にまとめて処理する（長く動ける）
    static let processingTaskID = "com.off53jub.lifelog.process"
    /// ときどき少しだけ処理する（30秒ほど）
    static let refreshTaskID = "com.off53jub.lifelog.refresh"

    /// アプリの起動が終わる前に呼ぶ。iOS がアプリを裏で起こしたときに、溜まった音声を処理する。
    func registerBackgroundWork() {
        for id in [Self.processingTaskID, Self.refreshTaskID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    let work = Task {
                        await self?.runQueue()
                        // 充電中の長い処理では、1日分の聞き直しもする
                        if id == Self.processingTaskID { await self?.runNightly() }
                    }
                    task.expirationHandler = { work.cancel() }
                    Task {
                        await work.value
                        task.setTaskCompleted(success: !work.isCancelled)
                        Self.scheduleBackgroundWork()
                    }
                }
            }
        }
    }

    static func scheduleBackgroundWork() {
        let processing = BGProcessingTaskRequest(identifier: processingTaskID)
        processing.requiresExternalPower = true
        processing.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(processing)

        let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        refresh.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    /// この時刻より前は、iPhone・時計とも区切りがそろっている（これ以上届かない）とみなす。
    private func settledUntil() -> Date {
        var frontier = Date.now
        // まだ文字起こししていない区切り（録音中の区切りや、失敗してやり直す区切り）の始まり
        // 取り込んだ昔の音声は、いま録っている分とは時間帯が別なので待たない
        for url in Storage.pendingChunks() where !Storage.isImported(url) {
            if let start = Storage.startDate(of: url) { frontier = min(frontier, start) }
        }
        // 時計が録音中なら、時計の区切りが届いたところまで。届くのが遅すぎるときは待たない。
        // 時計が静かで書くのを休んでいて、休む前の区切りが届いていれば、待たない
        let watchResting = watchRestingSince.map { lastWatchEnd >= $0.addingTimeInterval(-5) } ?? false
        if watchRecording, !watchResting {
            frontier = min(frontier, max(lastWatchEnd, .now.addingTimeInterval(-Self.watchWait)))
        }
        return frontier
    }

    /// 選び終わった行を、会話の切れ目と日付ごとにドキュメントへ書く。失敗したら false（次の機会に続きから書く）。
    private func writeMerged() async -> Bool {
        while let first = merger.outbox.first {
            let day = dayFormatter.string(from: first.time)
            var batch = [first]
            for line in merger.outbox.dropFirst() {
                guard dayFormatter.string(from: line.time) == day,
                      line.time.timeIntervalSince(batch[batch.count - 1].time) <= ConversationLog.gap else { break }
                batch.append(line)
            }
            let lines = batch.map(ConversationLog.docLine)
            do {
                try await conversations.append(batch, text: lines.map { $0 + "\n" }.joined(), day: day)
            } catch {
                message = "ドキュメントに書けませんでした（あとで再試行します）: \(error.localizedDescription)"
                return false
            }
            merger.sent(batch.count)
            recentlyWritten += batch.map { (day, $0) }
            lastLines = Array((lastLines + lines).suffix(20))
        }
        if speakerLabelsOn { people = await speakers.people() }
        return true
    }

    /// 1つの区切りを文字起こしする。書くのは Merger で選んだあと。
    private func transcribe(_ url: URL) async throws -> [Merger.Heard] {
        let start = Storage.startDate(of: url) ?? .now
        let fromWatch = Storage.isFromWatch(url)
        let duration = Self.duration(of: url)
        // まず端末内で文字起こしする（無料）。何も聞き取れなければ、お金をかけずにここで終わる。
        let context = vocabularyContext(at: start)
        let placeWords = keywords(for: context)
        let local = try await Transcriber.transcribe(url, words: placeWords).filter { !CloudTranscriber.isFiller($0.text) }
        // 人の声がしているところ（端末内の VAD）。モデルが使えなければ nil（そのときは今までどおり）
        let voice = await VoiceDetector.shared.speech(in: url)
        let voiceSeconds = voice.map(VoiceDetector.total)
        // 声がほとんど無い区切り：重い文字起こしはしない（端末内で聞き取れた文は、確かめたほうがよい行として残す）
        let silent = (voiceSeconds ?? 1) < 0.5
        // 端末内では何も聞き取れなくても、はっきり声がしていれば Haas-ja で聞き取る（小さな声の取りこぼしを減らす）
        guard !local.isEmpty || (voiceSeconds ?? 0) >= 3 else { return [] }
        var entries: [(offset: TimeInterval?, text: String, score: Double?)] = local.map { ($0.offset, $0.text, nil) }
        lastEngine = "端末内"
        // 同じ機器の直前の区切りから続いているなら、その終わりの文を文脈として渡す
        let previous = lastTranscript[fromWatch].flatMap { start.timeIntervalSince($0.end) < 90 ? $0.text : nil }
        // 聞こえた文から話題を見つけ、その話題の言葉も聞き取りと直しのヒントにする
        let topics = vocabulary.activeTopics(hearing: local.map(\.text).joined() + (previous ?? ""), at: start)
        // その時間の予定の名前と参加者も、聞き取りのヒントにする
        let event = calendar.events(from: start, to: start.addingTimeInterval(duration)).first
        let eventWords = event.map { [$0.title] + $0.attendees + ($0.location.map { [$0] } ?? []) }?.filter { !$0.isEmpty } ?? []
        // 「さいとうさん」のように呼ばれた名前は、読みが同じ連絡先の人の書き方（「齋藤」など）をヒントにする
        let contactWords = await contacts.mentioned(in: local.map(\.text) + [previous ?? ""])
        // 直前の区切りで聞こえた人と、よく話す言葉（「人ごとの言葉」）
        let personWords = recentPeople[fromWatch].flatMap { start.timeIntervalSince($0.end) < 600 ? $0.names : nil }
            .map { wordStats.hints(for: $0) } ?? []
        // 呼ばれた名前と話題の言葉は場所の言葉より具体的なので先に置く（Whisper のヒントは先頭の30語まで）
        var seenWords = Set<String>()
        let keywords = (contactWords + topics.flatMap(\.words) + personWords + eventWords + placeWords)
            .filter { seenWords.insert($0).inserted }
        // 寝ているあいだは、端末内の文字起こしだけで済ませる（電池を使わず、寝息に作られた文も出にくい）
        let asleep = await sleep.isAsleep(from: start, to: start.addingTimeInterval(duration), motion: motion)
        if asleep { lastEngine = "端末内（睡眠中）" }
        if silent, !asleep { lastEngine = "端末内（声がほとんど無い区切り）" }
        // Haas-ja に渡す区間：声のある区間（VAD が使えなければ、端末内で聞き取れた区間）
        let haasSegments = voice.map { HaasEngine.segments(voice: $0, local: local) } ?? HaasEngine.segments(from: local)
        // 低電力モードで充電していなければ、iPhone の Haas-ja は動かさない（夜の聞き直しで取り戻す）
        let saving = Power.isSaving
        var usedHaas = asleep || silent
        /// 端末内とは別の聞き取りの結果（2つの食い違いを見比べるのに使う）
        var second: [CloudTranscriber.Line]?
        if !usedHaas, homePC.shouldTry {
            // 家の PC の Haas-ja（無料）。PC が切れているときや届かないときは、この区切りはほかの方法で
            if let lines = try? await homePC.transcribe(url, segments: haasSegments) {
                entries = lines.map { ($0.offset, $0.text, nil) }
                second = lines
                lastEngine = "Haas-ja（家の PC）"
                usedHaas = true
            }
        }
        if !usedHaas, haas.isUsable, !saving {
            // iPhone の中の Haas-ja（無料）。動かせなかったら（裏で Neural Engine が使えないなど）、この区切りはほかの方法で
            do {
                let lines = try await haas.transcribe(url, segments: haasSegments)
                entries = lines.map { ($0.offset, $0.text, nil) }
                second = lines
                lastEngine = "Haas-ja（iPhone 内）"
                usedHaas = true
            } catch {
                lastEngine = "端末内（Haas-ja が動かなかったため）"
            }
        }
        if !usedHaas, !asleep, !local.isEmpty, settings.shouldUseCloud, let key = settings.apiKey {
            do {
                let cloud = try await CloudTranscriber.transcribe(
                    url, provider: settings.provider, apiKey: key, keywords: keywords, previous: previous)
                settings.addUsage(seconds: duration)
                lastEngine = cloud.model
                if !cloud.lines.isEmpty {
                    // 端末内でも同じような音が聞き取れていない行は、実際には話されていない（雑音・外国語の動画など）とみなして捨てる
                    var checked = TranscriptCheck.agreeing(cloud.lines, with: local, duration: duration)
                    // 声の見つからなかったところの行も捨てる（無音や雑音に作られた文）
                    if let voice {
                        checked = checked.filter { line in
                            guard let offset = line.offset else { return true }
                            return voice.contains { offset >= $0.start - 1.5 && offset <= $0.end + 1.5 }
                        }
                    }
                    entries = checked.map { ($0.offset, $0.text, $0.score) }
                    second = checked
                }
            } catch CloudTranscriber.Failure.limited {
                // 無料枠を使い切ったら、この区切りは端末内の結果で済ませる（高精度はオンのまま）
                lastEngine = "端末内（無料枠の上限のため）"
            } catch CloudTranscriber.Failure.rejected(let reason) {
                // キーや残高の問題は待っても直らないので、高精度をオフにして端末内の結果を使う
                settings.useCloud = false
                message = reason + "（高精度をオフにして、端末内の文字起こしで続けます）"
            }
        }
        if saving, haas.isUsable, !usedHaas, !asleep { lastEngine += "（電池優先）" }
        // Haas-ja で書けた区切りは、夜の聞き直しで文字起こしし直さない
        if usedHaas, !asleep { NightlyRecheck.markHaasDone(url.lastPathComponent) }
        // 声がほとんど無い区切りは、夜の聞き直しでも Haas-ja にかけない
        if silent { NightlyRecheck.markHaasDone(url.lastPathComponent) }
        guard !entries.isEmpty else { return [] }
        // 2つの聞き取り（端末内と Haas-ja・クラウド）がどれだけ合っているか。確からしさの目安にし、
        // 大きく食い違う行（読みが半分も合わない行）は、言語モデルに見比べてもらう
        var agreement = [Double?](repeating: nil, count: entries.count)
        var others: [String]?
        if let second, second.count == entries.count {
            agreement = TranscriptCheck.agreement(second, with: local, duration: duration)
            let alternatives = TranscriptCheck.alternatives(second, with: local, duration: duration)
            others = alternatives.indices.map { (agreement[$0] ?? 1) < 0.5 ? alternatives[$0] : "" }
        }
        // 精度の高い文で見つかった話題の言葉も、直しに使う
        let heardTopics = vocabulary.activeTopics(hearing: entries.map { $0.text }.joined(), at: start)
        let heardNames = await contacts.mentioned(in: entries.map { $0.text })
        let correctionWords = (heardNames + heardTopics.flatMap(\.words)).filter { seenWords.insert($0).inserted } + keywords
        // 同音の誤変換などを言語モデルで直す。直せなかったら（混雑・上限など）そのまま使う。
        var originals = [String?](repeating: nil, count: entries.count)
        // 登録した「間違えやすい書き方」は、そのまま正しい書き方に置き換える
        for fix in vocabulary.fixes(for: context) {
            for i in entries.indices where entries[i].text.contains(fix.wrong) {
                if originals[i] == nil { originals[i] = entries[i].text }
                entries[i].text = entries[i].text.replacingOccurrences(of: fix.wrong, with: fix.right)
            }
        }
        if correctionOn, !asleep, !silent, let key = settings.groqKey,
           let fixed = try? await Summarizer.correct(entries.map { $0.text }, keywords: correctionWords,
                                                     previous: previous, alternatives: others, apiKey: key) {
            for i in entries.indices where fixed[i] != entries[i].text && !fixed[i].isEmpty {
                if originals[i] == nil { originals[i] = entries[i].text }
                entries[i].text = fixed[i]
            }
            lastEngine += "＋補正"
            if let others, others.contains(where: { !$0.isEmpty }) { lastEngine += "・見比べ" }
        }
        if !heardTopics.isEmpty { lastEngine += "・話題: " + heardTopics.map(\.name).joined(separator: "、") }
        if fromWatch { lastEngine += "（時計）" }
        lastTranscript[fromWatch] = (start.addingTimeInterval(duration),
                                     String(entries.map { $0.text }.joined().suffix(200)))
        // 行ごとの確からしさ（0〜1）。2つの聞き取りの合い方と、クラウドの自信の低いほう。分からなければ nil
        let confidence: [Double?] = entries.indices.map { i in
            // 声がほとんど無い区切りで書いた行は、確かめたほうがよい行にする
            if silent { return 0.3 }
            let score = entries[i].score.map { exp($0) }
            switch (agreement[i], score) {
            case let (a?, s?): return min(a, s)
            case let (a?, nil): return a
            case let (nil, s?): return s
            default: return nil
            }
        }
        let offsets = Self.fillOffsets(entries.map { ($0.offset, $0.text) }, duration: duration)
        let names = await speakerNames(for: offsets, in: url, context: places.context(at: start),
                                       selfLevel: officeFilter.selfLevel(watch: fromWatch))
        // この区切りで聞こえた名前のある人を覚えておく（次の区切りで、その人の言葉をヒントにする）
        var heardPeople: [String] = []
        for segment in names.compactMap({ $0 }) where segment.personID != SpeakerLabeler.selfID
            && !segment.name.hasPrefix("人物") && !heardPeople.contains(segment.name) {
            heardPeople.append(segment.name)
        }
        recentPeople[fromWatch] = (start.addingTimeInterval(duration), heardPeople)
        // 周りの人の声や、寝ているあいだの短い文・小さな声を外す（外した行は「消した行」に残す）
        let ends = entries.indices.map { i in i + 1 < offsets.count ? offsets[i + 1] : max(duration, offsets[i]) }
        let spans = entries.indices.map { (start: offsets[$0], end: ends[$0]) }
        let levels = await Task.detached(priority: .utility) { OfficeFilter.levels(url, spans: spans) }.value
        // 背景の音（音楽・電車・拍手や笑い）。放送やテレビの行を見分ける手がかりにする
        var scene: [SoundScene.Window] = []
        if !Power.isSaving { scene = await Task.detached(priority: .utility) { SoundScene.windows(in: url) }.value }
        let namedIDs = Set(people.filter(\.isNamed).map(\.id))
        let items = entries.indices.map { i in
            OfficeFilter.Item(time: start.addingTimeInterval(offsets[i]), text: entries[i].text,
                              personID: names[i]?.personID,
                              isNamed: names[i].map { namedIDs.contains($0.personID) } ?? false, level: levels[i])
        }
        let keep = officeFilter.keep(items, fromWatch: fromWatch, active: officeFilter.applies(to: context), asleep: asleep)
        var removed: [Junk.TrashItem] = []
        let lines = entries.indices.compactMap { i -> Merger.Heard? in
            let end = ends[i]
            var line = ConversationLog.Line(time: start.addingTimeInterval(offsets[i]), speaker: names[i]?.name,
                                            text: entries[i].text, audio: url.lastPathComponent,
                                            offset: offsets[i], original: originals[i], speakerID: names[i]?.personID,
                                            confidence: confidence[i].map { ($0 * 100).rounded() / 100 })
            line.sound = SoundScene.label(from: offsets[i], to: end, in: scene)
            guard keep[i] else {
                removed.append(Junk.TrashItem(day: dayFormatter.string(from: line.time), line: line,
                                              kind: asleep ? .asleep : .background, removed: .now))
                return nil
            }
            // 確からしさが分からない行（端末内だけ・OpenAI）は中くらいとみなす
            return Merger.Heard(line: line, end: start.addingTimeInterval(end), fromWatch: fromWatch,
                                weight: Double(entries[i].text.count) * (confidence[i] ?? 0.6))
        }
        if !removed.isEmpty {
            conversations.addToTrash(removed)
            lastEngine += "・\(asleep ? "寝ているあいだの" : "周りの声") \(removed.count) 行を外した"
        }
        return lines
    }

    /// その時刻に使う言葉の組。登録した場所にいればその場所で、分からなければ時刻（平日8〜19時は職場）で決める。
    func vocabularyContext(at time: Date) -> SpeakerLabeler.Context {
        places.registeredContext(at: time) ?? calendar.context(at: time) ?? Vocabulary.context(byTime: time)
    }

    /// その場で聞き取ってほしい言葉（名前を付けた人の名前も入れる）
    func keywords(for context: SpeakerLabeler.Context) -> [String] {
        let names = people
            .filter { $0.isNamed && !$0.isSelf && ($0.context == nil || $0.context == context) }
            .map(\.displayName)
        return vocabulary.words(for: context, names: names)
    }

    /// 時刻の分からない行に、前後の分かっている時刻のあいだを文字数で割り振った時刻を付ける。
    private static func fillOffsets(_ entries: [(offset: TimeInterval?, text: String)],
                                    duration: TimeInterval) -> [TimeInterval] {
        var offsets = entries.map { $0.offset }
        guard !offsets.isEmpty else { return [] }
        if offsets[0] == nil { offsets[0] = 0 }
        var i = 1
        while i < offsets.count {
            guard offsets[i] == nil else { i += 1; continue }
            let anchor = i - 1
            var next = i
            while next < offsets.count, offsets[next] == nil { next += 1 }
            let from = offsets[anchor] ?? 0
            let to = max(from, next < offsets.count ? offsets[next] ?? duration : duration)
            let total = Double(entries[anchor..<next].reduce(0) { $0 + max(1, $1.text.count) })
            var done = Double(max(1, entries[anchor].text.count))
            for k in i..<next {
                offsets[k] = from + (to - from) * done / total
                done += Double(max(1, entries[k].text.count))
            }
            i = next
        }
        return offsets.map { $0 ?? 0 }
    }

    /// 各行を、その時間にいちばん長く話していた人に結びつける。聞き分けがオフ・失敗したときは nil。
    private func speakerNames(for offsets: [TimeInterval], in url: URL,
                              context: SpeakerLabeler.Context?, selfLevel: Float?) async -> [SpeakerLabeler.Segment?] {
        let none = [SpeakerLabeler.Segment?](repeating: nil, count: offsets.count)
        guard speakerLabelsOn,
              let segments = try? await speakers.label(url, context: context, strictness: speakerStrictness,
                                                       selfLevel: selfLevel),
              !segments.isEmpty else { return none }
        let chunkEnd = Self.duration(of: url)
        return offsets.indices.map { i in
            let from = offsets[i]
            let to = i + 1 < offsets.count ? offsets[i + 1] : chunkEnd
            // 行の時間に、いちばん長く話していた人（同じ人の区間は足し合わせる）
            var total: [String: TimeInterval] = [:]
            for segment in segments { total[segment.personID, default: 0] += overlap(segment, from, to) }
            guard let best = total.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
            return segments.first { $0.personID == best.key }
        }
    }

    private func overlap(_ s: SpeakerLabeler.Segment, _ from: TimeInterval, _ to: TimeInterval) -> TimeInterval {
        max(0, min(s.end, to) - max(s.start, from))
    }

    /// 音声ファイルそのものが壊れているときのエラー（'dta?' 'typ?' 'fmt?' 'pck?'）
    private static func isBrokenAudio(_ error: Error) -> Bool {
        let e = error as NSError
        let codes: Set<Int> = [1685348671, 1954115647, 1718449215, 1885563711]
        return e.domain == "com.apple.coreaudio.avfaudio" && codes.contains(e.code)
    }

    private static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// iPhone で録音中の最新ファイルはまだ書き込み中なので飛ばす（時計の区切りは書き終わってから届く）。
    private func isActiveChunk(_ url: URL) -> Bool {
        isRecording && !Storage.isFromWatch(url)
            && url.lastPathComponent == recorder.writingURL?.lastPathComponent
    }
}

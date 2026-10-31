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
    /// 待機モード：アプリを裏で起こしておき、時計から届いた区切りをすぐ処理する
    private let standby = Standby()
    var standbyOn = UserDefaults.standard.object(forKey: "standby") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(standbyOn, forKey: "standby")
            if standbyOn { standby.start() } else { standby.stop() }
        }
    }

    private let recorder = Recorder()
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
        recorder.onChunk = { [weak self] _ in self?.processQueue() }
        recorder.onStop = { [weak self] reason in
            self?.isRecording = false
            self?.message = reason
            self?.standby.resume()
            if self?.stopAlertsOn == true, UIApplication.shared.applicationState != .active {
                Self.notify(id: "phone-stopped", title: "iPhone の録音が止まりました",
                            body: reason + " LifeLog を開いて再開してください。")
            }
        }
        if standbyOn { standby.start() }
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
            // 時計が止まったら、待っていた iPhone の分を書ける
            processQueue()
        }
        receiver.onMark = { [weak self] time in self?.addMark(at: time) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        receiver.activate()
    }

    /// 聞き分けのモデルを用意し、覚えている声を読み込む。
    func loadSpeakers() async {
        do {
            try await speakers.prepare()
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
    func mergePerson(_ source: String, into target: String) async {
        let old = await speakers.name(of: source)
        await speakers.merge(source, into: target)
        await relabel(to: target, renaming: old) { $0.speakerID == source }
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

    func toggleRecording() async {
        if isRecording {
            recorder.stop()
            isRecording = false
            standby.resume()
            return
        }
        do {
            message = "日本語モデルを確認中…"
            try await Transcriber.prepare()
            standby.suspend()
            try recorder.start()
            isRecording = true
            message = ""
        } catch {
            standby.resume()
            message = "録音を始められませんでした: \(error.localizedDescription)"
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
        for url in Storage.pendingChunks() where !isActiveChunk(url) {
            // 裏で使える時間が終わったら、残りは次の機会に回す
            if Task.isCancelled { return false }
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
        // 印の前後1分の行に★を付ける
        if !marks.isEmpty { marks = await conversations.applyMarks(marks, settled: settled) }
        // しばらく話していなければ会話を閉じて見出しを付け、前の日にはまとめを付ける。
        // まだ書いていない時間帯（録音中の区切りや、届いていない時計の区切り）に続きがあるかもしれないので、その手前で見る。
        await conversations.closeIdle(now: settled, waiting: ConversationLog.gap)
        await conversations.writeDailySummaries(today: dayFormatter.string(from: .now))
        await conversations.writePeopleNotes()
        await conversations.writeWeeklySummary(today: dayFormatter.string(from: .now))
        // Wi-Fi なら音声をドライブに上げ、古い手元の音声を片付ける
        await archive.uploadPending()
        backupPending = archive.pendingCount
        return true
    }

    /// 記録のある日（新しい順）
    func recordedDays() -> [String] { conversations.recordedDays() }

    func conversations(on day: String) -> [ConversationLog.Conversation] { conversations.conversations(on: day) }

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
                    let work = Task { await self?.runQueue() }
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
        for url in Storage.pendingChunks() {
            if let start = Storage.startDate(of: url) { frontier = min(frontier, start) }
        }
        // 時計が録音中なら、時計の区切りが届いたところまで。届くのが遅すぎるときは待たない。
        if watchRecording {
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
        let local = try await Transcriber.transcribe(url)
        guard !local.isEmpty else { return [] }
        var entries: [(offset: TimeInterval?, text: String, score: Double?)] = local.map { ($0.offset, $0.text, nil) }
        lastEngine = "端末内"
        // 同じ機器の直前の区切りから続いているなら、その終わりの文を文脈として渡す
        let previous = lastTranscript[fromWatch].flatMap { start.timeIntervalSince($0.end) < 90 ? $0.text : nil }
        if settings.shouldUseCloud, let key = settings.apiKey {
            do {
                let cloud = try await CloudTranscriber.transcribe(
                    url, provider: settings.provider, apiKey: key, keywords: settings.keywords, previous: previous)
                settings.addUsage(seconds: duration)
                lastEngine = cloud.model
                if !cloud.lines.isEmpty {
                    entries = cloud.lines.map { ($0.offset, $0.text, $0.score) }
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
        // 同音の誤変換などを言語モデルで直す。直せなかったら（混雑・上限など）そのまま使う。
        var originals = [String?](repeating: nil, count: entries.count)
        if correctionOn, let key = settings.groqKey,
           let fixed = try? await Summarizer.correct(entries.map { $0.text }, keywords: settings.keywords,
                                                     previous: previous, apiKey: key) {
            for i in entries.indices where fixed[i] != entries[i].text && !fixed[i].isEmpty {
                originals[i] = entries[i].text
                entries[i].text = fixed[i]
            }
            lastEngine += "＋補正"
        }
        if fromWatch { lastEngine += "（時計）" }
        lastTranscript[fromWatch] = (start.addingTimeInterval(duration),
                                     String(entries.map { $0.text }.joined().suffix(200)))
        let offsets = Self.fillOffsets(entries.map { ($0.offset, $0.text) }, duration: duration)
        let names = await speakerNames(for: offsets, in: url, context: places.context(at: start))
        return entries.indices.map { i in
            let end = i + 1 < offsets.count ? offsets[i + 1] : max(duration, offsets[i])
            let line = ConversationLog.Line(time: start.addingTimeInterval(offsets[i]), speaker: names[i]?.name,
                                            text: entries[i].text, audio: url.lastPathComponent,
                                            offset: offsets[i], original: originals[i], speakerID: names[i]?.personID)
            // 確からしさが分からない行（端末内・OpenAI）は中くらいとみなす
            let confidence = entries[i].score.map { exp($0) } ?? 0.6
            return Merger.Heard(line: line, end: start.addingTimeInterval(end), fromWatch: fromWatch,
                                weight: Double(entries[i].text.count) * confidence)
        }
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
                              context: SpeakerLabeler.Context?) async -> [SpeakerLabeler.Segment?] {
        let none = [SpeakerLabeler.Segment?](repeating: nil, count: offsets.count)
        guard speakerLabelsOn, let segments = try? await speakers.label(url, context: context),
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
            && url == Storage.pendingChunks().last(where: { !Storage.isFromWatch($0) })
    }
}

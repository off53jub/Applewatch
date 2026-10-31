import AVFoundation
import BackgroundTasks
import Observation
import UIKit

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
    /// 直前の区切りの終わり。次の区切りの頭の文脈として使う。
    @ObservationIgnored private var lastTranscript: (end: Date, text: String)?
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
        }
        if standbyOn { standby.start() }
        pendingCount = Storage.pendingChunks().count
        receiver.onFile = { [weak self] in
            self?.pendingCount = Storage.pendingChunks().count
            self?.processQueue()
        }
        receiver.onStateChange = { [weak self] in self?.watchStatus = $0 }
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

    /// 声の登録で iPhone のマイクを使うあいだ、待機モードの無音を止める
    func suspendStandby() { standby.suspend() }
    func resumeStandby() { standby.resume() }

    func enrollSelf(from url: URL) async throws {
        try await speakers.enrollSelf(from: url)
        hasSelfVoice = await speakers.hasSelfVoice
    }

    func renamePerson(_ id: String, to name: String) async {
        await speakers.rename(id, to: name)
        people = await speakers.people()
    }

    func removePerson(_ id: String) async {
        await speakers.remove(id)
        people = await speakers.people()
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
    }

    /// 溜まっている区切りを処理する。失敗や中断で途中でやめたら false。
    private func drainQueue() async -> Bool {
        await conversations.repairBrokenLines()
        for url in Storage.pendingChunks() where !isActiveChunk(url) {
            // 裏で使える時間が終わったら、残りは次の機会に回す
            if Task.isCancelled { return false }
            // 書いている途中で録音が終わった区切りは開けない。何度やっても同じなので脇によけて先へ進む
            guard (try? AVAudioFile(forReading: url)) != nil else {
                Storage.setAside(url)
                continue
            }
            do {
                try await process(url)
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
        // しばらく話していなければ会話を閉じて見出しを付け、前の日にはまとめを付ける。
        // 録音中の区切り（5分）に続きが入っているかもしれないので、その分は待つ。
        await conversations.closeIdle(now: .now, waiting: ConversationLog.gap + 300)
        await conversations.writeDailySummaries(today: dayFormatter.string(from: .now))
        await conversations.writePeopleNotes()
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

    private func process(_ url: URL) async throws {
        let start = Storage.startDate(of: url) ?? .now
        // まず端末内で文字起こしする（無料）。何も聞き取れなければ、お金をかけずにここで終わる。
        let local = try await Transcriber.transcribe(url)
        guard !local.isEmpty else { return }
        var entries: [(offset: TimeInterval?, text: String)] = local.map { ($0.offset, $0.text) }
        lastEngine = "端末内"
        // 直前の区切りから続いているなら、その終わりの文を文脈として渡す
        let previous = lastTranscript.flatMap { start.timeIntervalSince($0.end) < 90 ? $0.text : nil }
        if settings.shouldUseCloud, let key = settings.apiKey {
            do {
                let cloud = try await CloudTranscriber.transcribe(
                    url, provider: settings.provider, apiKey: key, keywords: settings.keywords, previous: previous)
                settings.addUsage(seconds: Self.duration(of: url))
                lastEngine = cloud.model
                if !cloud.lines.isEmpty {
                    entries = cloud.lines.map { ($0.offset, $0.text) }
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
        lastTranscript = (start.addingTimeInterval(Self.duration(of: url)),
                          String(entries.map { $0.text }.joined().suffix(200)))
        let names = await speakerNames(for: entries, in: url)
        let lines = entries.enumerated().map { i, entry in
            let who = names[i].map { "[\($0)] " } ?? ""
            guard let offset = entry.offset else { return who + entry.text }
            return "\(timeFormatter.string(from: start.addingTimeInterval(offset)))  \(who)\(entry.text)"
        }
        // 時刻の分からない行は、直前の行と同じ時刻とみなす
        var time = start
        let logged = entries.enumerated().map { i, entry in
            if let offset = entry.offset { time = start.addingTimeInterval(offset) }
            return ConversationLog.Line(time: time, speaker: names[i], text: entry.text,
                                        audio: url.lastPathComponent, offset: time.timeIntervalSince(start),
                                        original: originals[i])
        }
        let text = lines.map { $0 + "\n" }.joined()
        try await conversations.append(logged, text: text, day: dayFormatter.string(from: start))
        lastLines = Array((lastLines + lines).suffix(20))
        if speakerLabelsOn { people = await speakers.people() }
    }

    /// 各行を、その時間にいちばん長く話していた人に結びつける。聞き分けがオフ・失敗したときは nil。
    private func speakerNames(for entries: [(offset: TimeInterval?, text: String)], in url: URL) async -> [String?] {
        let none = [String?](repeating: nil, count: entries.count)
        guard speakerLabelsOn, let segments = try? await speakers.label(url), !segments.isEmpty else { return none }
        let chunkEnd = Self.duration(of: url)
        return entries.indices.map { i in
            guard let from = entries[i].offset else { return nil }
            let to = entries[(i + 1)...].lazy.compactMap { $0.offset }.first ?? chunkEnd
            let best = segments.max { a, b in
                overlap(a, from, to) < overlap(b, from, to)
            }
            guard let best, overlap(best, from, to) > 0 else { return nil }
            return best.name
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

    /// 録音中の最新ファイルはまだ書き込み中なので飛ばす。
    private func isActiveChunk(_ url: URL) -> Bool {
        isRecording && url == Storage.pendingChunks().last
    }
}

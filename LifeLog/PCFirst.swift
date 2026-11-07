import Foundation
import UIKit

/// 時計の区切りを、音声が iPhone に届く前に、家の PC の答えから記録に入れる（版 10。2026-11-07。docs/v10-pc-first.md）。
///
/// 時計から iPhone への受け渡しは Apple に絞られ、何時間も遅れることがある。いっぽう時計は家の PC にも直接送るので、
/// PC はずっと先に文字にし終えている。そこで:
/// - 家の PC が "watchroute" を持っていれば、取り込みのたび（開いたとき・見えない通知・裏の処理・時計の合図。1分に1回まで）に
///   GET /jobs?origin=watch で、でき上がった時計の区切りを見る。
/// - まだ文字にしていない区切りは GET /jobs/<名前> で答えを受け取り、音声の要らない手順だけで記録に入れる
///   （Pipeline.applyPCFirst。帳簿には pcFirst として残すので、抜けの地図では録れていた時間になる）。
/// - 寝ている時間と、周りの声を外す時間（職場など）は、音声が要る手順があるので、今までどおり音声を待つ。
/// - 音声があとから届いたら、文字にし直さずに音声だけ残し（聞き直し・「聞いて直す」に使う）、話者の無い行に話者を付ける。
enum PCFirst {
    /// 家の PC の /hello の features にあれば使う
    static let feature = "watchroute"
    /// 最後に聞いた答え（裏で起こされたときは PC に聞けないので覚えておく）
    static let featureKey = "homePCWatchRoute"
    static var supported: Bool { UserDefaults.standard.bool(forKey: featureKey) }

    /// PC に聞く間（これより短い間では聞かない）
    static let interval: TimeInterval = 60
    /// これより古い区切りは入れない（iPhone と時計の行の重なりを覚えている長さ。Merger と同じ2日）
    static let maxAge: TimeInterval = 2 * 86400
    /// 1回に入れる数
    static let perPass = 24
    /// 一覧を受け取れなかったら、これだけは聞かない
    static let retryAfter: TimeInterval = 10 * 60

    /// 数える名前（Tally）
    static let appliedKey = "pcFirst.applied"
    static let audioLaterKey = "pcFirst.audioLater"
    static let waitAudioKey = "pcFirst.waitAudio"
    static let speakersKey = "pcFirst.speakers"
    static let speakersSkippedKey = "pcFirst.speakersSkipped"

    // MARK: - PC の一覧

    /// GET /jobs?origin=watch の1つ（中身は入っていない。名前と様子と時刻だけ）
    struct Job: Decodable, Equatable, Sendable {
        let id: String
        let status: String
        var queued_at: Double? = nil
        var done_at: Double? = nil
        var origin: String? = nil
    }

    private struct Listing: Decodable {
        let jobs: [Job]
    }

    /// 一覧を読む（読めなければ nil）
    static func jobs(from data: Data) -> [Job]? {
        (try? JSONDecoder().decode(Listing.self, from: PCResults.trimmed(data)))?.jobs
    }

    /// 時計の区切りの名前（例 20261107-135444-w.m4a。iPhone の時間帯）から、録音の始まり。時計の区切りでなければ nil
    static func startDate(_ name: String) -> Date? {
        guard !name.contains("/"), name.hasSuffix(".m4a"),
              (name as NSString).deletingPathExtension.hasSuffix("-w") else { return nil }
        return Storage.startDate(of: URL(fileURLWithPath: name))
    }

    /// 一覧から、いま PC から先に入れる区切りを選ぶ（古い順に limit 個まで）。
    /// でき上がっている・時計から届いた・時計の区切りの名前・2日より新しい、で、
    /// まだ文字にしていない（transcribed に無い）・音声がもう iPhone にある（present）でない・音声を待つと決めた（waiting）でないもの
    static func pick(_ jobs: [Job], transcribed: Set<String>, present: Set<String>, waiting: Set<String>,
                     now: Date, limit: Int = PCFirst.perPass) -> [String] {
        var seen = Set<String>()
        var chosen: [(name: String, start: Date)] = []
        for job in jobs {
            guard job.status == "done", job.origin == nil || job.origin == "watch",
                  seen.insert(job.id).inserted,
                  !transcribed.contains(job.id), !present.contains(job.id), !waiting.contains(job.id),
                  let start = startDate(job.id),
                  now.timeIntervalSince(start) <= maxAge, start <= now.addingTimeInterval(300) else { continue }
            chosen.append((name: job.id, start: start))
        }
        chosen.sort { $0.start < $1.start }
        return chosen.prefix(max(0, limit)).map { $0.name }
    }

    // MARK: - 音声があとから届いたとき

    enum Arrival: Equatable {
        /// 今までどおり文字にする
        case normal
        /// PC から先に記録に入れた区切り。文字にし直さず、音声だけ残す
        case keepAudio
        /// もう文字にした区切りが送り直されてきた。二重に書かないよう捨てる（今までどおり）
        case drop
    }

    static func arrival(transcribed: Bool, pcFirst: Bool) -> Arrival {
        guard transcribed else { return .normal }
        return pcFirst ? .keepAudio : .drop
    }

    // MARK: - 覚えておくもの（名前だけ。会話の中身は入れない）

    private static let waitKey = "pcFirstWaitAudio"
    private static let speakersPendingKey = "pcFirstSpeakers"

    /// 音声を待つと決めた区切り（寝ている時間・周りの声を外す時間）。2日たったら忘れる
    static func waitingForAudio(now: Date = .now) -> Set<String> {
        let saved = UserDefaults.standard.dictionary(forKey: waitKey) as? [String: Double] ?? [:]
        return Set(saved.filter { now.timeIntervalSince1970 - $0.value < maxAge }.keys)
    }

    static func waitForAudio(_ name: String, now: Date = .now) {
        var saved = UserDefaults.standard.dictionary(forKey: waitKey) as? [String: Double] ?? [:]
        saved = saved.filter { now.timeIntervalSince1970 - $0.value < maxAge }
        saved[name] = now.timeIntervalSince1970
        UserDefaults.standard.set(saved, forKey: waitKey)
    }

    /// 音声が届いて、話者を付ける区切り（古い順）
    static func speakersPending() -> [String] {
        UserDefaults.standard.stringArray(forKey: speakersPendingKey) ?? []
    }

    static func addSpeakersPending(_ name: String) {
        var list = speakersPending()
        guard !list.contains(name) else { return }
        list.append(name)
        UserDefaults.standard.set(Array(list.suffix(300)), forKey: speakersPendingKey)
    }

    static func removeSpeakersPending(_ name: String) {
        let list = speakersPending()
        guard list.contains(name) else { return }
        UserDefaults.standard.set(list.filter { $0 != name }, forKey: speakersPendingKey)
    }

    /// 見えない通知（kind "job"）が届いたら、1分を待たずに次の取り込みで PC に聞く
    @MainActor
    static func jobPushed(_ name: String?) {
        PCFirstState.shared.lastPull = .distantPast
        if name != nil { Tally.add("pcFirst.push") }
    }
}

/// この起動のあいだだけ覚えておくこと
@MainActor
final class PCFirstState {
    static let shared = PCFirstState()
    /// 最後に PC に聞いた時刻
    var lastPull = Date.distantPast
    /// 1回で入れきれなかったとき、少ししてからもう一度取り込む
    var again: Task<Void, Never>?
}

extension HomePC {
    /// 時計から直接届いた仕事の一覧（GET /jobs?origin=watch。数秒で諦める）。使えない・つながらないなら nil
    func watchJobs() async -> [PCFirst.Job]? {
        guard shouldTry, Self.acceptsJobs, PCFirst.supported else { return nil }
        let query = [URLQueryItem(name: "origin", value: "watch")]
        guard let data = try? await getJSONData("jobs", query: query, timeout: 5) else { return nil }
        return PCFirst.jobs(from: data)
    }
}

extension Pipeline {
    /// でき上がっている時計の区切りを PC から受け取り、音声を待たずに記録に入れる（drainQueue の初めに呼ぶ。1分に1回まで）
    func pullPCFirst() async {
        let state = PCFirstState.shared
        guard PCFirst.supported, homePC.shouldTry, HomePC.acceptsJobs else { return }
        guard Date.now.timeIntervalSince(state.lastPull) >= PCFirst.interval else { return }
        state.lastPull = .now
        guard let jobs = await homePC.watchJobs() else {
            // つながらない・読めないときは、取り込みを毎回待たせないよう10分は聞かない
            state.lastPull = Date.now.addingTimeInterval(PCFirst.retryAfter - PCFirst.interval)
            return
        }
        let present = Set((Storage.pendingChunks() + Storage.keptAudio()).map { $0.lastPathComponent })
        let names = PCFirst.pick(jobs, transcribed: ledger.transcribedNames, present: present,
                                 waiting: PCFirst.waitingForAudio(), now: .now)
        for name in names {
            if Task.isCancelled { break }
            guard let start = PCFirst.startDate(name) else { continue }
            // 寝ている時間・周りの声を外す時間は、音声の要る手順があるので、今までどおり音声を待つ
            let needsAudio = await pcFirstNeedsAudio(from: start, to: start.addingTimeInterval(300))
            if needsAudio {
                PCFirst.waitForAudio(name)
                Tally.add(PCFirst.waitAudioKey)
                continue
            }
            let job = await homePC.jobState(name)
            guard case .done(let lines) = job else { continue }
            // 聞いているあいだに音声が届いた・文字にしたなら、そちらに任せる（二重にしない）
            let arrived = FileManager.default.fileExists(atPath: Storage.pendingDir.appendingPathComponent(name).path)
            if arrived || ledger.isTranscribed(name) { continue }
            let end = RecordingLedger.pcFirstEnd(start: start, timingEnd: Latency.marks(name)?.chunkEnd)
            // 文字になるまでの時間は「PC から先に入れた」として別に数える（時計→iPhone の区間が無い）
            Latency.notePCFirst(name, start: start, end: end)
            _ = await applyPCFirst(name: name, start: start, end: end, lines: lines)
            Tally.add(PCFirst.appliedKey)
            // 使い終わった答えは、今までどおり PC から消す（PC は音声を記録の置き場に移して残す）
            Tally.add("jobs.used")
            PCResults.remove(name)
            Task { await homePC.deleteJob(name) }
        }
        // 1回で入れきれなかったら、アプリを開いているあいだは少ししてからもう一度
        if names.count >= PCFirst.perPass, UIApplication.shared.applicationState == .active, state.again == nil {
            state.again = Task { [weak self] in
                try? await Task.sleep(for: .seconds(PCFirst.interval + 1))
                PCFirstState.shared.again = nil
                self?.processQueue()
            }
        }
    }

    /// 音声が届くのを待つ区切りか（音声が無いとできない手順がある時間）。
    /// 寝ているあいだ（端末内の聞き取りだけにして、小さな声を外す）と、周りの人の声を外す時間（声の大きさを見る）
    func pcFirstNeedsAudio(from start: Date, to end: Date) async -> Bool {
        let sureWork = places.registeredContext(at: start) == .work || calendar.context(at: start) == .work
        if officeFilter.applies(sureWork: sureWork) { return true }
        guard sleep.enabled else { return false }
        let healthAsleep = await health.asleep(from: start, to: end)
        if let healthAsleep { return healthAsleep }
        let guessed = await sleep.isAsleep(from: start, to: end, motion: motion)
        return guessed
    }

    /// 自己点検の行: 今日 PC から先に記録に入れた区切りの数
    var pcFirstTodayText: String {
        let count = ledger.pcFirstCount(on: Calendar.current.startOfDay(for: .now))
        var text = "\(count) 個"
        if !PCFirst.supported { text += "（家の PC がまだ対応していません）" }
        return text
    }
}

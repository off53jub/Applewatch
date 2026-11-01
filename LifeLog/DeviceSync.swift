import CryptoKit
import Foundation
import Observation

/// iPhone と iPad の記録と登録を、ドライブの「LifeLog/同期」フォルダを通して合わせる。
///
/// - 端末ごとに自分のファイル（例: `people-1a2b3c4d.json`、`day-2026-11-01-1a2b3c4d.json`）だけを書き、
///   ほかの端末のファイルを読んで合わせる。同じファイルを2台で書き合わないので、書いたものが消えない。
/// - 記録は会話ごとに、新しい版（番号の大きいほう）を残す。消した会話・言葉・場所・人は、消した印で伝える。
/// - 「ここでは録音を休む」と、自動で覚えた声（端末ごとのマイクに合わせたもの）は端末ごとのまま。
/// - 初めて同期する前に、この端末の記録と登録をアプリの中に一度だけ控えておく。
@MainActor
@Observable
final class DeviceSync {
    var isOn = UserDefaults.standard.object(forKey: "deviceSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isOn, forKey: "deviceSync") }
    }
    private(set) var lastSynced: Date? = UserDefaults.standard.object(forKey: "deviceSyncLast") as? Date {
        didSet { UserDefaults.standard.set(lastSynced, forKey: "deviceSyncLast") }
    }
    private(set) var running = false
    /// 同期できなかったときの説明
    private(set) var problem: String?
    /// 最後の同期で、ほかの端末から受け取ったもの
    private(set) var lastReceived = ""
    /// ほかの端末（最後に見えたもの）
    private(set) var otherDevices = 0

    @ObservationIgnored private var lastAttempt = Date.distantPast
    /// この端末の印（ファイル名に付ける）
    @ObservationIgnored let deviceID: String

    @ObservationIgnored private let docs: GoogleDocs
    @ObservationIgnored private let conversations: ConversationLog
    @ObservationIgnored private let vocabulary: Vocabulary
    @ObservationIgnored private let places: PlaceLog
    @ObservationIgnored private let speakers: SpeakerLabeler
    @ObservationIgnored private let archive: AudioArchive
    /// 同期を始める前の準備（iPad の人の番号の付け替え）。まだ済まなければ false
    @ObservationIgnored var prepare: () async -> Bool = { true }
    /// ほかの端末から人の登録が届いたとき
    @ObservationIgnored var peopleChanged: () async -> Void = {}
    /// ほかの端末から記録が届いたとき
    @ObservationIgnored var recordsChanged: () -> Void = {}

    init(docs: GoogleDocs, conversations: ConversationLog, vocabulary: Vocabulary, places: PlaceLog,
         speakers: SpeakerLabeler, archive: AudioArchive) {
        self.docs = docs
        self.conversations = conversations
        self.vocabulary = vocabulary
        self.places = places
        self.speakers = speakers
        self.archive = archive
        if let id = UserDefaults.standard.string(forKey: "deviceID") {
            deviceID = id
        } else {
            let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            UserDefaults.standard.set(id, forKey: "deviceID")
            deviceID = id
        }
    }

    /// 同期する。force でなければ、3分たっていないときは何もしない。
    func run(force: Bool = false) async {
        guard isOn, !running, force || Date.now.timeIntervalSince(lastAttempt) >= 180 else { return }
        lastAttempt = .now
        running = true
        defer { running = false }
        guard await prepare() else {
            problem = "同期の準備（人の番号の付け替え）が済んでいないので、あとでやり直します。"
            return
        }
        guard backupOnce() else {
            problem = "同期の前の控えを取れなかったので、同期していません。"
            return
        }
        do {
            let files = try await docs.syncFiles()
            otherDevices = Set(files.compactMap { Self.parse($0.name)?.device }.filter { $0 != deviceID }).count
            try await receive(files)
            try await send(files)
            lastSynced = .now
            problem = nil
        } catch {
            problem = "同期できませんでした（次の機会にやり直します）: \(error.localizedDescription)"
        }
    }

    // MARK: - 受け取る

    private func receive(_ files: [GoogleDocs.SyncFile]) async throws {
        var seen = Self.dictionary("syncSeen")
        var days = 0, people = false, words = false, spots = false
        let decoder = JSONDecoder()
        for file in files {
            guard let parsed = Self.parse(file.name), parsed.device != deviceID,
                  seen[file.name] != file.modified else { continue }
            let kind = parsed.kind
            let data = try await docs.downloadSync(id: file.id)
            switch kind {
            case "vocabulary":
                if let copy = try? decoder.decode(Vocabulary.SyncCopy.self, from: data), vocabulary.mergeRemote(copy) {
                    words = true
                }
            case "places":
                if let copy = try? decoder.decode(PlaceLog.SyncCopy.self, from: data), places.mergeRemote(copy) {
                    spots = true
                }
            case "people":
                if let copy = try? decoder.decode(SpeakerLabeler.SyncPeople.self, from: data),
                   await speakers.mergeRemote(copy) {
                    people = true
                }
            case "audio":
                if let list = try? decoder.decode([String: String].self, from: data) { archive.mergeRemote(list) }
            default:
                guard kind.hasPrefix("day-") else { break }
                let day = String(kind.dropFirst(4))
                if let copy = try? decoder.decode(ConversationLog.SyncDay.self, from: data),
                   conversations.mergeRemote(copy, day: day) {
                    days += 1
                }
            }
            // 読めなかったファイルも、同じ版は読み直さない（次に書き直されたら読む）
            seen[file.name] = file.modified
            Self.setDictionary(seen, "syncSeen")
        }
        if people { await peopleChanged() }
        if days > 0 { recordsChanged() }
        var parts: [String] = []
        if days > 0 { parts.append("記録 \(days) 日分") }
        if people { parts.append("人") }
        if words { parts.append("言葉") }
        if spots { parts.append("場所") }
        if !parts.isEmpty { lastReceived = parts.joined(separator: "・") }
    }

    // MARK: - 渡す

    private func send(_ files: [GoogleDocs.SyncFile]) async throws {
        var ids: [String: String] = [:]
        for file in files where ids[file.name] == nil { ids[file.name] = file.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        try await upload("vocabulary", try encoder.encode(vocabulary.syncCopy()), ids: ids)
        try await upload("places", try encoder.encode(places.syncCopy()), ids: ids)
        let peopleCopy = await speakers.syncCopy()
        try await upload("people", try encoder.encode(peopleCopy), ids: ids)
        try await upload("audio", try encoder.encode(archive.syncCopy()), ids: ids)

        // 日ごとの記録は、ファイルが前に渡したときから変わった日だけ
        var stamps = Self.dictionary("syncDayStamp")
        for day in conversations.days() {
            let stamp = conversations.modified(day).map { String($0.timeIntervalSince1970) } ?? ""
            let name = fileName("day-" + day)
            guard stamps[day] != stamp || ids[name] == nil else { continue }
            try await upload("day-" + day, try encoder.encode(conversations.syncPayload(day)), ids: ids)
            stamps[day] = stamp
            Self.setDictionary(stamps, "syncDayStamp")
        }
    }

    private func upload(_ kind: String, _ data: Data, ids: [String: String]) async throws {
        let name = fileName(kind)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var hashes = Self.dictionary("syncHash")
        guard hashes[name] != hash || ids[name] == nil else { return }
        try await docs.uploadSync(data, name: name, id: ids[name])
        hashes[name] = hash
        Self.setDictionary(hashes, "syncHash")
    }

    private func fileName(_ kind: String) -> String { "\(kind)-\(deviceID).json" }

    /// 「day-2026-11-01-1a2b3c4d.json」→（"day-2026-11-01", "1a2b3c4d"）
    private static func parse(_ name: String) -> (kind: String, device: String)? {
        guard name.hasSuffix(".json") else { return nil }
        let base = name.dropLast(5)
        guard let dash = base.lastIndex(of: "-") else { return nil }
        let device = String(base[base.index(after: dash)...])
        guard device.count == 8 else { return nil }
        return (String(base[..<dash]), device)
    }

    // MARK: - 最初の控え

    /// 初めて同期する前に、記録・人・言葉・場所をアプリの中（Application Support/sync-backup-日時）に控える。
    /// 控えを取れたら（または取ってあれば）true。
    private func backupOnce() -> Bool {
        let doneKey = "syncBackupDone"
        if UserDefaults.standard.bool(forKey: doneKey) { return true }
        let fm = FileManager.default
        let base = URL.applicationSupportDirectory
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = base.appendingPathComponent("sync-backup-" + f.string(from: .now), isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["days", "people.json", "merges.json", "uploads.json", "wordstats.json", "activities"] {
                let source = base.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: dir.appendingPathComponent(name))
            }
            var settings: [String: Data] = [:]
            for key in ["vocabulary", "placeList"] {
                if let data = UserDefaults.standard.data(forKey: key) { settings[key] = data }
            }
            try JSONEncoder().encode(settings).write(to: dir.appendingPathComponent("settings.json"), options: .atomic)
        } catch {
            return false
        }
        UserDefaults.standard.set(true, forKey: doneKey)
        return true
    }

    // MARK: - 覚えておくもの

    private static func dictionary(_ key: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func setDictionary(_ value: [String: String], _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

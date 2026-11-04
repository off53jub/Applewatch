import Foundation
import Observation

/// 覚えた声・言葉・場所・まとめた記録などの登録を、毎日1回控える。
/// - アプリの中（Application Support/backups、7日分）と、Wi-Fi のときはドライブの「LifeLog/控え」（端末ごとに14日分）。
/// - 日ごとの記録（会話と行）は、同期でドライブの「同期」フォルダに渡っているので控えない。
/// - 戻すときは、選んだ控えを「戻す待ち」に置き、次にアプリを開いたとき、ほかのものが読む前に入れ替える
///   （使っている最中に入れ替えると、覚えている中身で上書きされてしまうため）。
@MainActor
@Observable
final class BackupKeeper {
    /// 控える登録のファイル（Application Support の中）
    static let files = ["people.json", "merges.json", "wordstats.json", "suggestions.json", "trash.json",
                        "uploads.json", "uploads-remote.json", "voices-set-aside.json"]
    /// 戻すときに入れ替える設定（言葉の登録・場所・消したい言葉・カレンダーの選び方・聞き分けの厳しさ）。
    /// 設定は全部控えるが、端末の印や同期の進み具合まで戻すとおかしくなるので、戻すのはこれだけ。
    static let restoredSettings = ["vocabulary", "placeList", "junkPhrases", "workCalendars", "ignoredCalendars",
                                   "speakerStrictness"]

    struct Snapshot: Codable {
        let made: Date
        let device: String
        /// ファイル名 → 中身
        var files: [String: Data]
        /// 設定（UserDefaults）を property list にしたもの
        var settings: Data?
    }

    /// 控え1つ（一覧に出す）
    struct Entry: Identifiable {
        let name: String
        /// アプリの中ならファイル、ドライブならファイルの id
        let local: URL?
        let driveID: String?
        var id: String { (local != nil ? "local-" : "drive-") + name }
        /// 「2026-11-03（端末 1a2b3c4d）」
        var label: String {
            let parts = name.replacingOccurrences(of: ".json", with: "").split(separator: "-", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return name }
            let mine = parts[1] == UserDefaults.standard.string(forKey: "deviceID")
            return parts[2] + (mine ? "（この端末）" : "（端末 \(parts[1])）")
        }
    }

    private static let base = URL.applicationSupportDirectory
    private static let dir = base.appendingPathComponent("backups", isDirectory: true)
    private static let pendingURL = base.appendingPathComponent("restore-pending.json")
    private static let keepLocal = 7
    private static let keepDrive = 14

    private(set) var lastLocal = UserDefaults.standard.object(forKey: "backupLocalLast") as? Date {
        didSet { UserDefaults.standard.set(lastLocal, forKey: "backupLocalLast") }
    }
    private(set) var lastDrive = UserDefaults.standard.object(forKey: "backupDriveLast") as? Date {
        didSet { UserDefaults.standard.set(lastDrive, forKey: "backupDriveLast") }
    }
    private(set) var problem: String?

    @ObservationIgnored private let docs: GoogleDocs
    @ObservationIgnored private let onWiFi: @MainActor () -> Bool

    init(docs: GoogleDocs, onWiFi: @escaping @MainActor () -> Bool) {
        self.docs = docs
        self.onWiFi = onWiFi
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var device: String { UserDefaults.standard.string(forKey: "deviceID") ?? "device" }
    /// この端末の控えの名前の頭（「控え-1a2b3c4d-」）。名前の順が日付の順になる
    private static var prefix: String { "控え-\(device)-" }
    private static func name(for date: Date) -> String { prefix + dayFormatter.string(from: date) + ".json" }
    private static func day(_ date: Date?) -> String? { date.map { dayFormatter.string(from: $0) } }

    /// その日まだ控えていなければ控える。signedIn は、ドライブに上げられるか。force なら今すぐ（モバイル通信でも上げる）。
    func runIfDue(signedIn: Bool, force: Bool = false) async {
        let today = Self.dayFormatter.string(from: .now)
        let localDue = force || Self.day(lastLocal) != today
        let driveDue = signedIn && (force || (onWiFi() && Self.day(lastDrive) != today))
        guard localDue || driveDue else { return }
        let data: Data
        do {
            data = try JSONEncoder().encode(Self.snapshot())
        } catch {
            problem = "控えを作れませんでした: \(error.localizedDescription)"
            return
        }
        if localDue {
            do {
                try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                try data.write(to: Self.dir.appendingPathComponent(Self.name(for: .now)), options: .atomic)
                let old = localEntries().dropFirst(Self.keepLocal)
                for entry in old { if let url = entry.local { try? FileManager.default.removeItem(at: url) } }
                lastLocal = .now
                problem = nil
            } catch {
                problem = "アプリの中に控えられませんでした: \(error.localizedDescription)"
            }
        }
        guard driveDue else { return }
        do {
            try await docs.uploadBackup(data, name: Self.name(for: .now), prefix: Self.prefix, keep: Self.keepDrive)
            lastDrive = .now
        } catch {
            problem = "ドライブに控えを上げられませんでした（次の機会にやり直します）: \(error.localizedDescription)"
        }
    }

    /// いまの登録の控え
    private static func snapshot() throws -> Snapshot {
        var files: [String: Data] = [:]
        for name in Self.files {
            if let data = try? Data(contentsOf: base.appendingPathComponent(name)) { files[name] = data }
        }
        var settings: Data?
        if let domain = Bundle.main.bundleIdentifier.flatMap({ UserDefaults.standard.persistentDomain(forName: $0) }) {
            settings = try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        }
        return Snapshot(made: .now, device: device, files: files, settings: settings)
    }

    /// アプリの中の控え（新しい順）
    func localEntries() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .map { Entry(name: $0.lastPathComponent, local: $0, driveID: nil) }
            .sorted { $0.name > $1.name }
    }

    /// ドライブの控え（新しい順。ほかの端末の分も）
    func driveEntries() async throws -> [Entry] {
        try await docs.backupFiles().map { Entry(name: $0.name, local: nil, driveID: $0.id) }.sorted { $0.name > $1.name }
    }

    /// 選んだ控えを「戻す待ち」に置く。次にアプリを開いたときに入れ替わる。
    func prepareRestore(_ entry: Entry) async throws {
        let data: Data
        if let url = entry.local {
            data = try Data(contentsOf: url)
        } else if let id = entry.driveID {
            data = try await docs.downloadSync(id: id)
        } else {
            return
        }
        // 読めない控えは置かない
        _ = try JSONDecoder().decode(Snapshot.self, from: data)
        try data.write(to: Self.pendingURL, options: .atomic)
    }

    var hasPendingRestore: Bool { FileManager.default.fileExists(atPath: Self.pendingURL.path) }

    func cancelRestore() { try? FileManager.default.removeItem(at: Self.pendingURL) }

    /// 「戻す待ち」の控えがあれば入れ替える。ほかのものが登録を読む前（アプリの起動のいちばん初め）に呼ぶ。
    /// 入れ替える前のファイルは backups/戻す前-日時 に残す。
    static func applyPendingRestore() {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: pendingURL) else { return }
        defer { try? fm.removeItem(at: pendingURL) }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let keep = dir.appendingPathComponent("戻す前-" + f.string(from: .now), isDirectory: true)
        try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
        for (name, content) in snapshot.files where files.contains(name) {
            let url = base.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try? fm.copyItem(at: url, to: keep.appendingPathComponent(name)) }
            try? content.write(to: url, options: .atomic)
        }
        if let settings = snapshot.settings,
           let domain = try? PropertyListSerialization.propertyList(from: settings, format: nil) as? [String: Any] {
            for key in restoredSettings {
                if let value = domain[key] { UserDefaults.standard.set(value, forKey: key) }
            }
        }
        UserDefaults.standard.set(Date.now, forKey: "backupRestored")
    }
}

import Foundation
import Network

/// 文字起こしが終わった音声を、Wi-Fi のときにドライブの「LifeLog/音声/日付」に上げる。
/// 手元の音声は26時間たったら消すが、まだ上げていない分は上げ終わるまで残す。
/// 手元に無い音声も、上げてあればドライブから取ってきて聞ける。
@MainActor
final class AudioArchive {
    /// ドライブに保存するか
    var enabled: () -> Bool = { false }
    private let docs: GoogleDocs
    private let monitor = NWPathMonitor()
    private var onWiFi = false
    /// ファイル名 → ドライブ上の id
    private var uploaded: [String: String]
    /// ほかの端末が上げた音声（ファイル名 → ドライブ上の id）。端末間の同期で受け取る
    private var remote: [String: String]

    private static let storeURL = URL.applicationSupportDirectory.appendingPathComponent("uploads.json")
    private static let remoteURL = URL.applicationSupportDirectory.appendingPathComponent("uploads-remote.json")
    private static let cacheDir: URL = {
        let dir = URL.cachesDirectory.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(docs: GoogleDocs) {
        self.docs = docs
        uploaded = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.storeURL))) ?? [:]
        remote = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.remoteURL))) ?? [:]
        monitor.pathUpdateHandler = { [weak self] path in
            // モバイル通信やテザリングでは上げない
            let wifi = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.onWiFi = wifi }
        }
        monitor.start(queue: DispatchQueue(label: "LifeLog.network"))
    }

    var pendingCount: Int {
        Storage.keptAudio().filter { uploaded[$0.lastPathComponent] == nil }.count
    }

    /// Wi-Fi なら、まだ上げていない音声を古い順に上げる。そのあと古い手元の音声を片付ける。
    func uploadPending() async {
        if enabled(), onWiFi {
            for file in Storage.keptAudio() where uploaded[file.lastPathComponent] == nil {
                if Task.isCancelled || !onWiFi { break }
                let day = dayFormatter.string(from: Storage.startDate(of: file) ?? .now)
                do {
                    uploaded[file.lastPathComponent] = try await docs.uploadAudio(file, day: day)
                    save()
                } catch {
                    // 通信が切れたなどは、次の機会にやり直す
                    break
                }
            }
        }
        prune()
    }

    /// 聞ける場所。手元に無ければドライブから取ってくる（一度取ったものはしばらく取っておく）。
    func playableURL(for name: String) async -> URL? {
        if let local = Storage.keptAudio(named: name) { return local }
        let cached = Self.cacheDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let id = uploaded[name] ?? remote[name], let data = try? await docs.downloadAudio(id: id) else { return nil }
        try? data.write(to: cached, options: .atomic)
        return cached
    }

    func canPlay(_ name: String) -> Bool {
        uploaded[name] != nil || remote[name] != nil || Storage.keptAudio(named: name) != nil
    }

    // MARK: - 端末間の同期

    /// この端末が上げた音声の一覧（ほかの端末が聞き直しに使う）
    func syncCopy() -> [String: String] { uploaded }

    /// ほかの端末が上げた音声の一覧を受け取る。
    func mergeRemote(_ list: [String: String]) {
        let next = remote.merging(list) { _, new in new }
        guard next != remote else { return }
        remote = next
        if let data = try? JSONEncoder().encode(remote) {
            try? data.write(to: Self.remoteURL, options: .atomic)
        }
    }

    private func prune() {
        let old = Date.now.addingTimeInterval(-Storage.keepAudioFor)
        for file in Storage.keptAudio() where (Storage.startDate(of: file) ?? .distantPast) < old {
            // 保存する設定なのに、まだ上げていない分は残す
            if enabled(), uploaded[file.lastPathComponent] == nil { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(uploaded) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}

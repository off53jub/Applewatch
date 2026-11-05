import Foundation

enum Storage {
    /// 文字起こし待ちの音声。ファイル名に録音開始時刻を入れる（例: 20261016-103200.m4a）
    static let pendingDir: URL = {
        let dir = URL.documentsDirectory.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func chunkName(for date: Date) -> String {
        nameFormatter.string(from: date) + ".m4a"
    }

    /// 名前の頭15文字が録音開始時刻。時計で録った区切りは後ろに「-w」が付く。
    static func startDate(of url: URL) -> Date? {
        nameFormatter.date(from: String(url.deletingPathExtension().lastPathComponent.prefix(15)))
    }

    /// 時計で録った区切りか
    static func isFromWatch(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix("-w")
    }

    /// ほかのアプリの音声から取り込んだ区切りか（例: 20261016-103200-i.m4a）
    static func isImported(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix("-i")
    }

    static func importedChunkName(for date: Date) -> String {
        nameFormatter.string(from: date) + "-i.m4a"
    }

    /// 時計から届いた区切りの名前（例: 20261016-103200-w.m4a）
    static func watchChunkName(from name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return (stem.hasSuffix("-w") ? stem : stem + "-w") + ".m4a"
    }

    /// 開けない（壊れた）音声。待ちの列からは外し、念のため7日間だけ残す。
    static let brokenDir: URL = {
        let dir = URL.documentsDirectory.appendingPathComponent("broken", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func setAside(_ url: URL) {
        let dest = brokenDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: url, to: dest)
        let old = Date.now.addingTimeInterval(-7 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: brokenDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < old { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// 文字起こしが終わった音声。アプリで聞き直せるよう、1日（少し余裕を見て26時間）は手元に残す。
    /// ドライブに保存する設定なら、上げ終わるまでは消さない（AudioArchive）。
    static let audioDir: URL = {
        let dir = URL.documentsDirectory.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let keepAudioFor: TimeInterval = 26 * 3600

    static func keep(_ url: URL) {
        let dest = audioDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.moveItem(at: url, to: dest)) == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func keptAudio() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 残っていれば、その音声の場所
    static func keptAudio(named name: String) -> URL? {
        let url = audioDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 届いた区切りの名前（送り直されてきた区切りを二重に処理しないため。2026-11-06）

    private static let receivedKey = "receivedChunks"
    /// 時計は返事が無いと3日のあいだ送り直してくるので、それより少し長く覚えておく
    private static let rememberReceived: TimeInterval = 4 * 24 * 3600

    /// この名前の区切りを、もう受け取っているか
    static func alreadyReceived(_ name: String) -> Bool {
        let fm = FileManager.default
        if [pendingDir, audioDir, brokenDir].contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(name).path) }) {
            return true
        }
        return (UserDefaults.standard.dictionary(forKey: receivedKey) as? [String: Double])?[name] != nil
    }

    /// 受け取った区切りの名前を覚える（古いものは忘れる）
    static func noteReceived(_ name: String) {
        var list = UserDefaults.standard.dictionary(forKey: receivedKey) as? [String: Double] ?? [:]
        let now = Date.now.timeIntervalSince1970
        list = list.filter { now - $0.value < rememberReceived }
        list[name] = now
        UserDefaults.standard.set(list, forKey: receivedKey)
    }

    static func pendingChunks() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

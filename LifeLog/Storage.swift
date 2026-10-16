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

    static func startDate(of url: URL) -> Date? {
        nameFormatter.date(from: url.deletingPathExtension().lastPathComponent)
    }

    static func pendingChunks() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

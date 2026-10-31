import AVFoundation
import Foundation
import Observation

/// ほかのアプリ（AUDAY など）で録った音声を取り込む。
/// ファイルアプリ経由で Google ドライブのファイルやフォルダを選ぶと、録音した時刻を読み取り、
/// 5分ずつに分けて文字起こし待ちに入れる。あとはいつもの録音と同じように、日付のドキュメントに書かれる。
@MainActor
@Observable
final class AudioImporter {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let size: Int
        /// 録音を始めた時刻（分からなければ nil。取り込むときに音声の情報からもう一度調べる）
        var start: Date?
        /// 時刻をどこから読み取ったか
        var source: String
        var alreadyImported: Bool
        var include = true
    }

    private(set) var items: [Item] = []
    private(set) var status = ""
    private(set) var working = false
    /// 区切りを文字起こし待ちに入れたら呼ぶ
    var onQueued: () -> Void = {}

    /// 選んだフォルダやファイル（使い終わるまで読み取りの許可を保つ）
    @ObservationIgnored private var roots: [URL] = []

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aif", "aiff", "mp4", "m4b", "3gp", "amr", "flac"]
    private static let doneKey = "importedAudio"

    /// 選ばれたファイル・フォルダから、音声を一覧にする。
    func load(_ urls: [URL]) {
        stopAccess()
        roots = urls.filter { $0.startAccessingSecurityScopedResource() }
        let done = Set(UserDefaults.standard.stringArray(forKey: Self.doneKey) ?? [])
        var found: [Item] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        for root in urls {
            var files: [URL] = []
            if (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
                while let url = walker?.nextObject() as? URL {
                    if Self.audioExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
                }
            } else if Self.audioExtensions.contains(root.pathExtension.lowercased()) {
                files.append(root)
            }
            for url in files {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let size = values?.fileSize ?? 0
                let name = url.lastPathComponent
                var start = Self.date(fromName: name)
                var source = "ファイル名"
                if start == nil, let created = values?.creationDate ?? values?.contentModificationDate {
                    start = created
                    source = "ファイルの日付（取り込むときに音声の情報で確かめます）"
                }
                found.append(Item(url: url, name: name, size: size, start: start, source: start == nil ? "不明" : source,
                                  alreadyImported: done.contains("\(name)|\(size)")))
            }
        }
        items = found.sorted { ($0.start ?? .distantPast, $0.name) < ($1.start ?? .distantPast, $1.name) }
        for i in items.indices where items[i].alreadyImported { items[i].include = false }
        status = items.isEmpty ? "音声ファイルが見つかりませんでした。" : ""
    }

    func setStart(_ id: UUID, _ date: Date) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].start = date
        items[i].source = "手で入力"
    }

    func setInclude(_ id: UUID, _ include: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].include = include
    }

    /// 選んだ音声を、5分ずつに分けて文字起こし待ちに入れる。
    func importSelected() async {
        working = true
        defer {
            working = false
            stopAccess()
        }
        var done = UserDefaults.standard.stringArray(forKey: Self.doneKey) ?? []
        let targets = items.filter(\.include)
        var chunks = 0
        for (n, item) in targets.enumerated() {
            status = "\(n + 1) / \(targets.count)：\(item.name) を取り込んでいます…"
            do {
                // ドライブのファイルは手元に無いことがあるので、まず一時フォルダに写す（ここでダウンロードされる）
                let local = try await Self.copyToTemporary(item.url)
                defer { try? FileManager.default.removeItem(at: local) }
                let asset = AVURLAsset(url: local)
                var start = item.start
                if item.source != "ファイル名" && item.source != "手で入力",
                   let recorded = try? await asset.load(.creationDate)?.load(.dateValue) {
                    start = recorded
                }
                guard let start else {
                    status = "\(item.name) の録音時刻が分からないので飛ばしました（一覧で時刻を入れてください）。"
                    continue
                }
                chunks += try await Self.split(asset, start: start)
                done.append("\(item.name)|\(item.size)")
                UserDefaults.standard.set(done, forKey: Self.doneKey)
                if let i = items.firstIndex(where: { $0.id == item.id }) {
                    items[i].alreadyImported = true
                    items[i].include = false
                }
                onQueued()
            } catch {
                status = "\(item.name) を取り込めませんでした: \(error.localizedDescription)"
            }
        }
        status = "\(chunks) 個の区切り（5分ずつ）を文字起こし待ちに入れました。古い日付のドキュメントに順に書かれます。"
    }

    private func stopAccess() {
        for url in roots { url.stopAccessingSecurityScopedResource() }
        roots = []
    }

    // MARK: - 中身

    /// ファイル名の「2026-10-15 09-30-12」「20261015_093012」「2026年10月15日 9時30分」などを読む。
    static func date(fromName name: String) -> Date? {
        let pattern = #"(20\d{2})[-_./年]?\s?(\d{1,2})[-_./月]?\s?(\d{1,2})日?[\sT_\-]*(\d{1,2})[-_:.時h]?\s?(\d{2})分?(?:[-_:.]?\s?(\d{2})秒?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        func part(_ i: Int) -> Int? {
            guard let range = Range(match.range(at: i), in: name) else { return nil }
            return Int(name[range])
        }
        var c = DateComponents()
        c.year = part(1); c.month = part(2); c.day = part(3)
        c.hour = part(4); c.minute = part(5); c.second = part(6) ?? 0
        guard let month = c.month, (1...12).contains(month), let day = c.day, (1...31).contains(day),
              let hour = c.hour, hour < 24, let minute = c.minute, minute < 60 else { return nil }
        return Calendar.current.date(from: c)
    }

    private static func copyToTemporary(_ url: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try await Task.detached {
            var coordinatorError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: dest) } catch { copyError = error }
            }
            if let error = coordinatorError ?? copyError { throw error }
        }.value
        return dest
    }

    /// 5分ずつの m4a にして、文字起こし待ちに入れる。区切りの数を返す。
    private static func split(_ asset: AVURLAsset, start: Date) async throws -> Int {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 1 else { return 0 }
        var offset = 0.0
        var count = 0
        while offset < duration - 1 {
            let length = min(300, duration - offset)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            session.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                                            duration: CMTime(seconds: length, preferredTimescale: 600))
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            try await session.export(to: temp, as: .m4a)
            // 書き終わってから待ちのフォルダに移す（書きかけを文字起こししないように）
            var name = Storage.importedChunkName(for: start.addingTimeInterval(offset))
            var bump = 1.0
            while FileManager.default.fileExists(atPath: Storage.pendingDir.appendingPathComponent(name).path)
                    || Storage.keptAudio(named: name) != nil {
                name = Storage.importedChunkName(for: start.addingTimeInterval(offset + bump))
                bump += 1
            }
            try FileManager.default.moveItem(at: temp, to: Storage.pendingDir.appendingPathComponent(name))
            offset += 300
            count += 1
        }
        return count
    }
}

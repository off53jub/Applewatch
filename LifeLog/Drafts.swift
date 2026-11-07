import Foundation
import Observation
import SwiftUI
import UIKit

// 下書きを先に出す（2026-11-07。docs/v8-latency.md の 5）。
// 家の PC は区切りを文字にするとき、先に速いモデル（haas・reazon）だけで書いた「下書き」を残し、そのあと多数決をする。
// アプリが前にあるとき（画面を見ているとき）だけ、送ってまだの区切りを15秒ごとに GET /jobs/<名前> で見に行き、
// 下書きがあれば「今日」の画面と時計の「さっきの会話」に「仮」として出す。
// 下書きはアプリの中（覚えているだけ）に置き、記録には保存しない・同期にも入れない。
// でき上がりが記録に入ったら（または、その区切りを取り込み終えたら）、その区切りの仮は消す。
// 見に行ったときにでき上がっていたら、その答えを端末の中（PCResults）に置き、取り込みを進める。
// PC の /hello の features に "draft" があるときだけ。

/// 下書き（仮）の一覧。覚えているだけで、ファイルには書かない
@MainActor
@Observable
final class JobDrafts {
    struct Line: Equatable, Hashable {
        let time: Date
        let text: String
    }

    struct Draft: Identifiable, Equatable {
        /// 区切りの名前
        let name: String
        /// 区切りの録音の始まり
        let start: Date
        var lines: [Line]
        var updated: Date
        var id: String { name }
    }

    /// 録音の古い順
    private(set) var items: [Draft] = []
    /// 15秒ごとに見に行く繰り返し
    @ObservationIgnored var loop: Task<Void, Never>?

    /// 仮を出す長さ（これより前に見た下書きは、でき上がりが来なくても消す）
    static let keepFor: TimeInterval = 30 * 60

    /// 下書きを入れる・入れ替える。変わったら true
    @discardableResult
    func set(_ name: String, start: Date, lines: [HomePC.Line], now: Date = .now) -> Bool {
        let converted = lines.compactMap { line -> Line? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Line(time: start.addingTimeInterval(line.offset), text: text)
        }
        guard !converted.isEmpty else { return false }
        if let i = items.firstIndex(where: { $0.name == name }) {
            guard items[i].lines != converted else { return false }
            items[i].lines = converted
            items[i].updated = now
            return true
        }
        items.append(Draft(name: name, start: start, lines: converted, updated: now))
        items.sort { $0.start < $1.start }
        return true
    }

    /// その区切りの仮を消す。消したら true
    @discardableResult
    func remove(_ name: String) -> Bool {
        guard items.contains(where: { $0.name == name }) else { return false }
        items.removeAll { $0.name == name }
        return true
    }

    /// 古い仮を消す。消したら true
    @discardableResult
    func prune(now: Date = .now) -> Bool {
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.updated) > Self.keepFor }
        return items.count != before
    }
}

extension Pipeline {
    /// 見に行く間
    static let draftInterval: TimeInterval = 15

    /// アプリが前に来たときに呼ぶ（appBecameActive）。15秒ごとに下書きを見に行く
    func startDraftPolling() {
        guard drafts.loop == nil else { return }
        drafts.loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDrafts()
                try? await Task.sleep(for: .seconds(Pipeline.draftInterval))
            }
        }
    }

    /// アプリが裏に回ったときに呼ぶ（appMovedToBackground）
    func stopDraftPolling() {
        drafts.loop?.cancel()
        drafts.loop = nil
    }

    /// 区切りを取り込み終えた（文字にした・壊れていてよけた）。置いておいた PC の答えと、仮を消す
    func finishedChunk(_ name: String) {
        PCResults.remove(name)
        if drafts.remove(name) { pushWatchInfo() }
    }

    /// 送ってまだの区切り（新しいものから6つまで）の下書きを、1回見に行く
    func pollDrafts() async {
        var changed = drafts.prune()
        defer { if changed { pushWatchInfo() } }
        guard UIApplication.shared.applicationState == .active, homePC.shouldTry,
              HomePC.acceptsJobs, HomePC.acceptsDrafts else { return }
        var finished = false
        for name in Latency.awaiting().prefix(6) where !PCResults.has(name) {
            if Task.isCancelled { return }
            switch await homePC.peekJob(name) {
            case .done(let data):
                // でき上がっていた。答えを置いて、取り込みで使う（仮は、記録に入ったときに消える）
                PCResults.save(data, name: name)
                finished = true
            case .draft(let lines):
                guard let start = Storage.startDate(of: URL(fileURLWithPath: name)) else { continue }
                if drafts.set(name, start: start, lines: lines) { changed = true }
            case .nothing:
                break
            }
        }
        if finished { processQueue() }
    }

    /// 時計の「さっきの会話」に出す仮（いちばん新しい区切りの、終わりの3行）
    func draftForWatch() -> WatchInfo.Draft? {
        guard let newest = drafts.items.last else { return nil }
        return WatchInfo.Draft(start: newest.start.timeIntervalSince1970,
                               lines: newest.lines.suffix(3).map { WatchInfo.clip($0.text, 80) })
    }
}

/// 「今日」の画面の仮（下書き）
struct DraftSection: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let items = pipeline.drafts.items
        if !items.isEmpty {
            Section {
                ForEach(items) { draft in
                    ForEach(draft.lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.time.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(line.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Label("仮（家の PC が書いている途中）", systemImage: "hourglass")
            } footer: {
                Text("家の PC が速いモデルで先に書いた下書きです。多数決ででき上がると記録に入り、ここから消えます。下書きは記録に残しません。")
            }
        }
    }
}

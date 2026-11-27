import Foundation
import Observation

// s31（2026-11-27）文字と声の結び（S31A）の取り方。決まりは S31ARules.swift、画面は S31AViews.swift。
// - 家の PC の features に "links" があるとき（K31-2）、人のページ・記録の日の画面を開いたときに
//   GET /links?person=<名前> ・ GET /links?day=YYYY-MM-DD を読む（同じ問いは 1 分あけて・仮）。
// - 端末の Application Support/S31A/ に問いごとの写しを置き、つながらないときは前の写しを見せる。
//   {"available":false} なら写しを消して節を出さない。読めない答えのときは前の写しを残す。
// 鍵は S27WBook と同じ HomePC のオーナーの Bearer。知らせ・問いは足さない。中身の文は記録（ログ）に書かない
// （Tally は数と種類の名前だけ）。

@MainActor
@Observable
final class S31ABook {
    static let shared = S31ABook()

    /// 家の PC が "links" を持っているか（hello のあとに覚える）
    static let offeredKey = "s31a.offered"
    /// 同じ問いを読み直すまでの間（仮 1 分）
    static let againEvery: TimeInterval = 60

    private(set) var offered: Bool
    /// 問いごとの答え（"person:<名前>"・"day:<日>"）
    private(set) var answers: [String: S31ALinks] = [:]
    @ObservationIgnored private var triedAt: [String: Date] = [:]
    @ObservationIgnored private var loadedCopy: Set<String> = []
    @ObservationIgnored private var busy: Set<String> = []

    init() {
        offered = UserDefaults.standard.bool(forKey: Self.offeredKey)
    }

    nonisolated static func personKey(_ name: String) -> String { "person:" + name }
    nonisolated static func dayKey(_ day: String) -> String { "day:" + day }

    func person(_ name: String) -> S31ALinks? { answers[Self.personKey(name)] }
    func day(_ day: String) -> S31ALinks? { answers[Self.dayKey(day)] }

    /// 項目の voice の link から、読んである結びを引く（強さの言葉に使う。無ければ nil）
    func link(_ id: String?) -> S31ALink? {
        S31ARules.link(id, in: Array(answers.values))
    }

    /// 家の PC の features を覚える（空＝まだ hello していないときは前のまま）
    func noteFeatures(_ features: Set<String>) {
        guard !features.isEmpty else { return }
        let on = features.contains(S31ARules.feature)
        guard on != offered else { return }
        offered = on
        UserDefaults.standard.set(on, forKey: Self.offeredKey)
        if !on {
            answers = [:]
            Task { await Self.clearAll() }
        }
    }

    func load(person name: String, pc: HomePC?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await load(key: Self.personKey(trimmed), query: [URLQueryItem(name: "person", value: trimmed)], pc: pc)
    }

    func load(day: String, pc: HomePC?) async {
        guard S26ALink.isDay(day) else { return }
        await load(key: Self.dayKey(day), query: [URLQueryItem(name: "day", value: day)], pc: pc)
    }

    private func load(key: String, query: [URLQueryItem], pc: HomePC?, now: Date = .now) async {
        if let pc { noteFeatures(pc.features) }
        guard offered, !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        if !loadedCopy.contains(key) {
            loadedCopy.insert(key)
            if answers[key] == nil, let data = await Self.read(key) {
                let copy: S31AReply = await Task.detached { S31ARules.reply(data) }.value
                if case .links(let links) = copy, answers[key] == nil { answers[key] = links }
            }
        }
        guard let pc, pc.isConfigured, pc.features.contains(S31ARules.feature) else { return }
        if let at = triedAt[key], now.timeIntervalSince(at) < Self.againEvery { return }
        triedAt[key] = now
        do {
            let data = try await pc.getJSONData("links", query: query, timeout: 15)
            let reply: S31AReply = await Task.detached { S31ARules.reply(data) }.value
            switch reply {
            case .links(let links):
                answers[key] = links
                await Self.write(data, key: key)
                Tally.add("s31a.read")
            case .none:
                answers[key] = nil
                await Self.write(nil, key: key)
                Tally.add("s31a.read.none")
            case .bad:
                Tally.add("s31a.read.bad")
            }
        } catch {
            Tally.add("s31a.read.fail")
        }
    }

    // MARK: 置き場（中身は端末の中だけ）

    nonisolated static func fileName(_ key: String) -> String {
        if key.hasPrefix("day:") { return "day-" + String(key.dropFirst(4)) + ".json" }
        // 名前はそのままファイルの名前にしない（16 進で）
        let hex = Data(key.utf8).prefix(60).map { String(format: "%02x", $0) }.joined()
        return "q-" + hex + ".json"
    }

    nonisolated private static var folder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("S31A", isDirectory: true)
    }

    nonisolated private static func write(_ data: Data?, key: String) async {
        await Task.detached {
            let u = S31ABook.folder.appendingPathComponent(S31ABook.fileName(key))
            guard let data else {
                try? FileManager.default.removeItem(at: u)
                return
            }
            if let old = try? Data(contentsOf: u), old == data { return }
            try? FileManager.default.createDirectory(at: S31ABook.folder, withIntermediateDirectories: true)
            try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
    }

    nonisolated private static func read(_ key: String) async -> Data? {
        await Task.detached { try? Data(contentsOf: S31ABook.folder.appendingPathComponent(S31ABook.fileName(key))) }.value
    }

    nonisolated private static func clearAll() async {
        await Task.detached { try? FileManager.default.removeItem(at: S31ABook.folder) }.value
    }
}

import Foundation
import Observation
import SwiftUI

/// 夜の読み直し（施策 9。2026-11-13）と、直す箱の「まとめて OK」（施策 14）。
/// - 夜の読み直し: 家の PC が毎晩、前の日の文を Claude に読ませて作った候補（GET /night-review。features の "nightreview"）。
///   聞き間違いは「聞き間違いかも」（MisheardBox）に「夜の読み直しから」の理由で足す（記録は変えない。本人が押したときだけ直す）。
///   話し手の取り違えは GET /speaker-doubts に why "night" で混ざってくる（HomeFeeds.swift。表示は「夜の読み直しから」）。
///   残した・捨てたは Tally（night.kept・night.dropped）と POST /feedback（kind night_review）に残す。
/// - まとめて OK: 母艦が sure（本人が見ればほぼ必ず OK するもの）の印を付けたものだけを、確かめの画面で件数を見せてから、
///   1件ずつ OK を押したのと同じ処理をする。押すまでは何も変えない。

struct NightMisheard: Codable, Identifiable, Equatable {
    var id: String
    var day: String
    /// 記録の行の時刻（ISO8601）
    var line_time: String
    /// 行の文にそのまま含まれる言葉
    var wrong: String
    var guess: String
    var reason: String = ""
}

// MARK: - 確かめ方（決まった入力から決まった出力だけ）

enum NightReviewRules {
    static let itemLimit = 200
    static let wrongRange = 2...12
    static let guessLimit = 20
    /// 「聞き間違いかも」に出す理由の頭
    static let reasonHead = "夜の読み直しから"

    private struct Raw: Decodable {
        var id: String?
        var day: String?
        var line_time: String?
        var wrong: String?
        var guess: String?
        var reason: String?
    }

    private struct RawFeed: Decodable {
        var available: Bool?
        var items: [LossyRow<Raw>]?
    }

    /// GET /night-review の答え。読めない・{"available": false} なら nil
    static func decode(_ data: Data) -> [NightMisheard]? {
        guard let raw = try? JSONDecoder().decode(RawFeed.self, from: data), raw.available == true else { return nil }
        var out: [NightMisheard] = []
        var seen = Set<String>()
        for row in raw.items ?? [] {
            guard let x = row.value, let id = HomeFeeds.trimmed(x.id), HomeFeeds.isID(id), seen.insert(id).inserted,
                  let day = HomeFeeds.trimmed(x.day), HomeFeeds.isDay(day),
                  let time = HomeFeeds.trimmed(x.line_time), AppFeeds.parseTime(time) != nil,
                  let wrong = HomeFeeds.trimmed(x.wrong), wrongRange.contains(wrong.count),
                  let guess = HomeFeeds.trimmed(x.guess), guess.count <= guessLimit, guess != wrong else { continue }
            let reason = String((HomeFeeds.trimmed(x.reason) ?? "").prefix(60))
            out.append(NightMisheard(id: id, day: day, line_time: time, wrong: wrong, guess: guess, reason: reason))
            if out.count >= itemLimit { break }
        }
        return out
    }

    /// 候補に当たる記録の行: 時刻が前後2秒以内で、その言葉をそのまま含み、手で確かめていない行（いちばん近いもの）
    static func pick(_ item: NightMisheard, in lines: [(time: Date, text: String, checked: Bool)],
                     tolerance: TimeInterval = HomeFeeds.doubtTolerance) -> Int? {
        guard let at = AppFeeds.parseTime(item.line_time) else { return nil }
        var best: (index: Int, gap: TimeInterval)?
        for (i, line) in lines.enumerated() where !line.checked && line.text.contains(item.wrong) {
            let gap = abs(line.time.timeIntervalSince(at))
            if gap <= tolerance, best == nil || gap < best!.gap { best = (i, gap) }
        }
        return best?.index
    }

    /// 「聞き間違いかも」に出す理由
    static func reason(_ item: NightMisheard) -> String {
        item.reason.isEmpty ? reasonHead : reasonHead + "：" + item.reason
    }

    /// 夜の読み直しの候補を本人が片づけた（kept＝直した・合っていた疑いを残した、dropped＝違った）
    @MainActor
    static func note(id: String, day: String, kept: Bool) {
        Tally.add(kept ? "night.kept" : "night.dropped")
        FixFeedback.add(kind: "night_review", id: id, value: kept ? "kept" : "dropped", day: day)
    }

    /// 話し手の疑いのうち夜の読み直しのもの（why "night"）を片づけた
    @MainActor
    static func noteDoubt(_ doubt: SpeakerDoubt, kept: Bool) {
        guard doubt.why == "night" else { return }
        note(id: doubtKey(doubt), day: doubt.day, kept: kept)
    }

    /// 夜の読み直しの話し手の疑いの、母艦へ送る id（行の時刻と向きから。英数字と _ . : - だけ・64 字まで）
    static func doubtKey(_ doubt: SpeakerDoubt) -> String {
        var key = "nrs-"
        for ch in doubt.line_time + "-" + doubt.suggest where ch.isASCII && (ch.isLetter || ch.isNumber || ":.-_".contains(ch)) {
            key.append(ch)
        }
        return String(key.prefix(64))
    }

    /// 母艦の sure の印の見せ方「ほぼ確か（理由）」
    static func sureLabel(_ why: String?) -> String {
        guard let why = HomeFeeds.trimmed(why) else { return "ほぼ確か" }
        return "ほぼ確か（" + why + "）"
    }

    /// まとめて OK の数え方: sure の物は、まとめて1つと数える（「直す」のタブの数字）
    static func collapsed(count: Int, sure: Int) -> Int {
        let s = max(0, min(sure, count))
        return count - s + (s > 0 ? 1 : 0)
    }

    /// 「直す」のタブの数字: 上の段から足して cap で止める（画面の案内「1日に上から5つまで」と同じ）
    static func badge(_ counts: [Int], cap: Int = 5) -> Int {
        var total = 0
        for c in counts where c > 0 {
            total += c
            if total >= cap { return cap }
        }
        return total
    }
}

// MARK: - 読み込み

@MainActor
@Observable
final class NightReviewBook {
    static let shared = NightReviewBook()

    /// 「聞き間違いかも」に入れた（または、行が見つからず入れなかった）候補の id
    private(set) var imported: Set<String>
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var fetchedAt: Date?

    static let importedKey = "nightReviewImported"
    private static let every: TimeInterval = 60 * 60
    private static let importedLimit = 2000

    init() {
        imported = Set(UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? [])
    }

    /// 家の PC から読み、まだ入れていない聞き間違いの候補を「聞き間違いかも」に足す。足した数を返す
    @discardableResult
    func refresh(_ pipeline: Pipeline, force: Bool = false) async -> Int {
        let pc = pipeline.homePC
        guard !fetching, pc.features.contains("nightreview") else { return 0 }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.every { return 0 }
        fetching = true
        defer { fetching = false }
        fetchedAt = .now
        guard let body = try? await pc.appFeed("night-review", feature: "nightreview"),
              let items = NightReviewRules.decode(body) else { return 0 }
        var added = 0
        for item in items where !imported.contains(item.id) {
            imported.insert(item.id)
            // 日をまたぐ会話は前の日に入っているので、前の日も探す
            var found: [(day: String, line: ConversationLog.Line)] = []
            for day in [Pipeline.previousDay(of: item.day), item.day].compactMap({ $0 }) {
                for c in pipeline.conversations(on: day) where c.media == nil {
                    for line in c.lines where line.media == nil { found.append((day: day, line: line)) }
                }
            }
            let keys: [(time: Date, text: String, checked: Bool)] = found.map { ($0.line.time, $0.line.text, $0.line.checked == true) }
            guard let i = NightReviewRules.pick(item, in: keys) else { continue }
            let hit = found[i]
            pipeline.misheard.add(wrong: item.wrong, guess: item.guess, reason: NightReviewRules.reason(item),
                                  ref: .init(day: hit.day, time: hit.line.time, text: hit.line.text), night: item.id)
            added += 1
        }
        if imported.count > Self.importedLimit {
            let live = Set(items.map(\.id))
            imported = imported.filter { live.contains($0) }
        }
        UserDefaults.standard.set(Array(imported), forKey: Self.importedKey)
        if added > 0 { Tally.add("night.proposed", added) }
        await FixFeedback.send(pc)
        return added
    }
}

// MARK: - まとめて OK

/// 「まとめて OK（N 件）」の1行。押すと確かめの画面に件数を出し、OK なら run を1回呼ぶ（run の中で1件ずつ処理する）
struct BulkOKRow: View {
    let count: Int
    /// 何をまとめて OK にするか（確かめの画面の題に出す）
    let what: String
    /// OK にすると何をするか（確かめの画面に出す）
    let effect: String
    let run: () async -> String
    @State private var asking = false
    @State private var working = false
    @State private var note: String?

    var body: some View {
        if let note {
            Text(note).font(.footnote).foregroundStyle(.secondary)
        } else {
            Button {
                asking = true
            } label: {
                HStack {
                    Label("まとめて OK（\(count) 件）", systemImage: "checkmark.circle")
                    if working {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(working || count == 0)
            .confirmationDialog("\(what)を \(count) 件、まとめて OK にしますか？", isPresented: $asking, titleVisibility: .visible) {
                Button("\(count) 件を OK にする") {
                    working = true
                    Task {
                        note = await run()
                        working = false
                    }
                }
                Button("やめる", role: .cancel) {}
            } message: {
                Text(effect)
            }
        }
    }
}

extension Pipeline {
    /// 話し手の疑いのうち、まとめて OK できるもの（sure で、「自分の声にする」で片づくもの）
    var sureSelfDoubts: [SpeakerDoubt] {
        homeFeeds.visibleDoubts.filter { $0.sure == true && $0.suggest == "self" }
    }

    /// まとめて OK（話し手の疑い）: 1件ずつ「自分の声にする」と同じ（その行だけを「自分」に。声は覚え足さない）
    func bulkClaimDoubts(_ list: [SpeakerDoubt]) async -> String {
        var done = 0
        var skipped = 0
        for d in list where d.suggest == "self" {
            guard let spot = findDoubtLine(d), let id = spot.line.speakerID, id != SpeakerLabeler.selfID else {
                skipped += 1
                continue
            }
            let end: TimeInterval = spot.next?.offset ?? (spot.line.offset ?? 0) + 10
            let clip = Pipeline.SplitClip(line: spot.line, end: end, embedding: [])
            _ = await claimAsSelf(id, clips: [clip])
            Tally.add("spkdoubt.self")
            NightReviewRules.noteDoubt(d, kept: true)
            homeFeeds.hideDoubt(d.id)
            done += 1
        }
        Tally.add("bulk.spkdoubt", done)
        if done > 0 {
            FixFeedback.add(kind: "bulk", id: "spkdoubt", value: "ok")
            await FixFeedback.send(homePC)
        }
        return "\(done) 件を「自分」に直しました。" + (skipped > 0 ? "\(skipped) 件は記録の行が見つからないので、そのままです。" : "")
    }

    /// まとめて OK（職場の自分の声）: 1件ずつ「自分の声」と同じ（声を覚えて、その行を「自分」に）
    func bulkConfirmSelf(_ list: [SelfCandidate]) async -> [String: String] {
        var results: [String: String] = [:]
        for item in list {
            results[item.id] = await confirmSelfCandidate(item)
            appFeeds.hide(item.id)
        }
        Tally.add("bulk.selfcand", list.count)
        if !list.isEmpty {
            FixFeedback.add(kind: "bulk", id: "selfcand", value: "ok")
            await FixFeedback.send(homePC)
        }
        return results
    }

    /// まとめて OK（言葉の候補）: 1件ずつ「足す」と同じ（選んだ組に足す）
    func bulkAddWords(_ list: [WordCandidate], to group: Vocabulary.Group) async -> String {
        var added = 0
        for item in list {
            vocabulary.add(item.word, to: group)
            added += 1
        }
        Tally.add("bulk.vocab", added)
        if added > 0 {
            FixFeedback.add(kind: "bulk", id: "vocab", value: "ok")
            await FixFeedback.send(homePC)
        }
        return "\(added) 語を「\(group.label)」に足しました。"
    }
}

/// 話し手の疑いの「まとめて OK」の行（HomeFeeds.swift の一覧と「直す」の段に置く）
struct SpeakerDoubtBulkRow: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let sure: [SpeakerDoubt] = pipeline.sureSelfDoubts
        if !sure.isEmpty {
            BulkOKRow(count: sure.count, what: "話し手の疑い",
                      effect: "母艦が「ほぼ確か」と印を付けた「自分かも」の行だけを、1件ずつ「自分の声にする」を押したのと同じように、その行だけ「自分」に直します。声は覚え足しません。「別の人かも」の行は1件ずつ確かめてください。") {
                await pipeline.bulkClaimDoubts(sure)
            }
        }
    }
}

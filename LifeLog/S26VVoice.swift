import SwiftUI

// s26 の A4（2026-11-25）: 「この声は誰？」のカードで、その人の発言と声を最初から見せる。
// 前は根拠が「7 日で 702 行・3 日に出た声（仮）」だけで、名前のボタンが並んでいても判断できなかった。
// 並び: その人の発言 3 つ（日時つき）→ 声を鳴らすボタン → 名前のボタン（名前のボタンは各画面が置く）。
// 声は item.clips（家の PC の音）があればそれを。無ければ端末の中の記録から「人物<番号>」の音声の残る行を新しい順に 2 つ。
// 発言も声も 1 つも無いカードは答えられないので、答える山には出さず、確かめ待ちでは後ろに回す（消さない）。
// 画面の表示だけ（初めはオン）。問いの数・知らせは増やさない。

// MARK: - 決まり（純粋な計算。LifeLogTests/S26VTests.swift）

enum S26VVoice {
    /// 話し手を聞く問いの種類（家の PC の speaker_line・母艦の上位 5 人の voice）。voice_pair（2 つの声が同じ人か）は前のまま
    static let kinds: Set<String> = ["voice", "speaker_line"]
    static let groups: Set<String> = ["voice_top"]
    /// 発言は 3 つまで・声は 2 つまで
    static let quoteLimit = 3
    static let playLimit = 2
    /// 端末の記録を探す日数（母艦の数えと同じくらい）
    static let searchDays = 14
    /// 母艦の時刻と端末の行の時刻のずれを同じとみなす秒（仮）
    static let matchSeconds: TimeInterval = 2

    /// 1 つの発言（when は「11/24 09:08」。分からなければ nil）
    struct Quote: Equatable, Sendable {
        var when: String?
        var text: String
    }

    /// 鳴らせる所（端末の記録の 1 行）
    struct Spot: Equatable, Sendable {
        var time: Date
        var text: String
        var audio: String
        var offset: TimeInterval
        var end: TimeInterval?
    }

    static func isVoiceAsk(_ item: ReviewItem) -> Bool {
        kinds.contains(item.kind) || item.group.map { groups.contains($0) } == true
    }

    /// 話し手の番号（speaker_id。無ければ問いの「人物5413」から）
    static func number(_ item: ReviewItem) -> String? {
        if let id = item.speaker_id?.trimmingCharacters(in: .whitespaces), isNumber(id) { return id }
        return number(in: item.question)
    }

    static func number(in text: String) -> String? {
        guard let range = text.range(of: "人物") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 12 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 中身のある samples
    static func samples(_ item: ReviewItem) -> [ReviewItem.Sample] {
        (item.samples ?? []).filter { !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 「11/24 09:08」（day "2026-11-24"・time "09:08:00"）
    static func when(day: String?, time: String?) -> String? {
        var parts: [String] = []
        if let day {
            let d = day.split(separator: "-")
            if d.count == 3, let m = Int(d[1]), let dd = Int(d[2]) { parts.append("\(m)/\(dd)") }
        }
        if let time, time.count >= 5 { parts.append(String(time.prefix(5))) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func when(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d/%d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 見せる発言: samples（日時つき）。無ければ根拠の「…」の行。それも無ければ端末の記録の行
    static func quotes(_ item: ReviewItem, local: [Spot] = [], calendar: Calendar = .current) -> [Quote] {
        let fromSamples = samples(item).map { Quote(when: when(day: $0.day, time: $0.time), text: $0.text ?? "") }
        if !fromSamples.isEmpty { return Array(fromSamples.prefix(quoteLimit)) }
        let fromEvidence = (item.evidence ?? []).filter { $0.text.contains("「") }.map { Quote(when: nil, text: $0.text) }
        if !fromEvidence.isEmpty { return Array(fromEvidence.prefix(quoteLimit)) }
        return local.prefix(quoteLimit).map { Quote(when: when($0.time, calendar: calendar), text: "「" + $0.text + "」") }
    }

    /// 発言のほかの根拠（「7 日で 702 行・3 日に出た声（仮）」など。発言と同じ行は出さない）
    static func notes(_ item: ReviewItem) -> [String] {
        (item.evidence ?? []).map(\.text).filter { !$0.contains("「") && !$0.isEmpty }
    }

    /// 答えられるか（発言・家の PC の音・根拠の発言のどれかがある）。話し手を聞く問いでなければいつも答えられる
    static func answerable(_ item: ReviewItem) -> Bool {
        guard isVoiceAsk(item) else { return true }
        if !samples(item).isEmpty { return true }
        if !(item.clips ?? []).isEmpty { return true }
        return (item.evidence ?? []).contains { $0.text.contains("「") }
    }

    /// 確かめ待ちの並び: 答えられないものを後ろへ（中の順はそのまま。消さない）
    static func order(_ items: [ReviewItem]) -> [ReviewItem] {
        items.filter(answerable) + items.filter { !answerable($0) }
    }

    /// 答える山に出すもの（答えられないものは出さない。確かめ待ちの画面には残る）
    static func forPile(_ items: [ReviewItem]) -> [ReviewItem] { items.filter(answerable) }

    /// その人の行か（話し手が「人物<番号>」か、声の番号が同じ。放送の声は除く）
    static func isTheirs(_ line: ConversationLog.Line, number: String) -> Bool {
        guard line.media == nil else { return false }
        return line.speaker == "人物" + number || line.speakerID == number
    }

    /// samples の日（探す順に先に読む）
    static func sampleDays(_ samples: [ReviewItem.Sample]) -> [String] {
        var out: [String] = []
        for day in samples.compactMap(\.day) where day.count == 10 && !out.contains(day) { out.append(day) }
        return out
    }

    /// samples の日時（day + time）。読めなければ nil
    static func date(_ sample: ReviewItem.Sample, calendar: Calendar = .current) -> Date? {
        guard let day = sample.day, let time = sample.time else { return nil }
        let d = day.split(separator: "-").compactMap { Int($0) }
        let t = time.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2 else { return nil }
        var c = DateComponents()
        c.year = d[0]; c.month = d[1]; c.day = d[2]
        c.hour = t[0]; c.minute = t[1]; c.second = t.count >= 3 ? t[2] : 0
        return calendar.date(from: c)
    }

    /// 鳴らす所を選ぶ: その人の音声（audio と offset）が残る行。samples の日時に合う行を先に（samples の順）、残りは新しい順。limit まで
    static func pick(_ lines: [ConversationLog.Line], number: String, samples: [ReviewItem.Sample] = [],
                     limit: Int = playLimit, calendar: Calendar = .current) -> [Spot] {
        let spots: [Spot] = lines.compactMap { (line: ConversationLog.Line) -> Spot? in
            guard isTheirs(line, number: number), let audio = line.audio, !audio.isEmpty, let offset = line.offset else { return nil }
            return Spot(time: line.time, text: line.text, audio: audio, offset: offset, end: line.end)
        }
        var out: [Spot] = []
        for sample in samples {
            guard out.count < limit, let at = date(sample, calendar: calendar) else { continue }
            let near = spots.filter { abs($0.time.timeIntervalSince(at)) <= matchSeconds && !out.contains($0) }
                .min { abs($0.time.timeIntervalSince(at)) < abs($1.time.timeIntervalSince(at)) }
            if let near { out.append(near) }
        }
        for spot in spots.sorted(by: { $0.time > $1.time }) where out.count < limit && !out.contains(spot) {
            out.append(spot)
        }
        return out
    }

    /// 鳴らす長さ（行の終わりが分かればそこまで。無ければ 8 秒・仮）
    static func stop(_ spot: Spot) -> TimeInterval {
        if let end = spot.end, end > spot.offset { return end + 0.5 }
        return spot.offset + 8
    }
}

// MARK: - 端末の記録を探す

@MainActor
enum S26VLocal {
    /// その人の行を、samples の日 → 新しい日の順に searchDays 日ぶん探す（日ごとの読み込みは ConversationLog の写しを使う）
    static func find(_ pipeline: Pipeline, number: String, samples: [ReviewItem.Sample],
                     limit: Int = S26VVoice.quoteLimit) async -> [S26VVoice.Spot] {
        let sampleDays = S26VVoice.sampleDays(samples)
        var order: [String] = []
        for day in sampleDays + Array(pipeline.recordedDays().prefix(S26VVoice.searchDays)) where !order.contains(day) {
            order.append(day)
        }
        var lines: [ConversationLog.Line] = []
        for (i, day) in order.enumerated() {
            if Task.isCancelled { return [] }
            lines += pipeline.conversations(on: day).flatMap(\.lines).filter { S26VVoice.isTheirs($0, number: number) }
            // samples の日を読み終え、鳴らせる行が足りたら止める
            if i + 1 >= sampleDays.count,
               lines.filter({ $0.audio != nil && $0.offset != nil }).count >= limit { break }
            await Task.yield()
        }
        return S26VVoice.pick(lines, number: number, samples: samples, limit: limit)
    }
}

// MARK: - 見せる部品（確かめ待ちの画面・答える山・知らせから開く 1 問で同じ）

struct S26VVoiceBlock: View {
    @Environment(Pipeline.self) private var pipeline
    let item: ReviewItem
    @State private var local: [S26VVoice.Spot] = []
    @State private var searched = false
    @State private var player = ClipPlayer()

    var body: some View {
        let quotes = S26VVoice.quotes(item, local: local)
        let clips = item.clips ?? []
        let playable = Array(local.prefix(S26VVoice.playLimit))
        VStack(alignment: .leading, spacing: LL.Space.s) {
            if !quotes.isEmpty {
                Text("この人の発言").font(.caption.weight(.semibold)).foregroundStyle(LL.dim)
                ForEach(Array(quotes.enumerated()), id: \.offset) { _, q in
                    VStack(alignment: .leading, spacing: 2) {
                        if let when = q.when { Text(when).font(.caption2).monospacedDigit().foregroundStyle(LL.dim) }
                        Text(q.text).font(.callout).foregroundStyle(LL.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .certainty(.guess)
                }
            }
            if !clips.isEmpty {
                ClipChooser(clips: clips)
            } else if !playable.isEmpty {
                HStack(spacing: LL.Space.s) {
                    ForEach(Array(playable.enumerated()), id: \.offset) { i, spot in
                        let key = "s26v-\(item.id)-\(i)"
                        Button {
                            Task {
                                await player.toggle(key, at: spot.offset, until: S26VVoice.stop(spot)) {
                                    await pipeline.archive.playableURL(for: spot.audio)
                                }
                            }
                        } label: {
                            Label("声 \(i + 1)（\(S26VVoice.when(spot.time))）",
                                  systemImage: player.playing == key ? "speaker.wave.2.fill"
                                      : player.loading == key ? "arrow.down.circle" : "play.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LLPillButtonStyle())
                    }
                }
            } else if searched {
                Text(quotes.isEmpty ? "この声の発言も音も、まだ手元にありません。分からなければ「分からない」か「あとで」で。"
                                    : "この声の音は、まだ手元にありません（家の PC の記録が届くと鳴らせます）。")
                    .font(.caption).foregroundStyle(LL.warn).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(S26VVoice.notes(item).enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption2).foregroundStyle(LL.dim)
            }
        }
        .task(id: item.id) {
            local = []
            searched = false
            let quotesKnown = !S26VVoice.samples(item).isEmpty || (item.evidence ?? []).contains { $0.text.contains("「") }
            // 家の PC の音があり、発言も分かっていれば探さない
            if !(item.clips ?? []).isEmpty, quotesKnown { searched = true; return }
            guard let number = S26VVoice.number(item) else { searched = true; return }
            let found = await S26VLocal.find(pipeline, number: number, samples: S26VVoice.samples(item))
            guard !Task.isCancelled else { return }
            local = found
            searched = true
        }
        .onDisappear { player.stop() }
    }
}

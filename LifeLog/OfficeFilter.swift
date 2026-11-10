import AVFoundation
import Foundation
import Observation

/// オフィスなどで、自分と関係ない周りの人の声を記録に書かないようにする。
///
/// 1. 声の大きさ: 自分の声（機器ごとに覚えておく）より、ずっと小さく入った行は、遠くの人の声とみなす。
///    名前を付けた人の声は、小さくても残す。
/// 2. やりとり: 名前の無い声で、前後3分のあいだに自分が一度も話していないものは、周りの雑談とみなす。
///    名前を付けた人の声は、やりとりが無くても残す。
/// 外した行は「記録の掃除」の「消した行」に30日間残るので、そこから戻せる。
@MainActor
@Observable
final class OfficeFilter {
    enum Mode: Int, CaseIterable, Identifiable {
        case off, work, always
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .off: "使わない"
            case .work: "職場にいるときだけ"
            case .always: "いつも"
            }
        }
    }

    var mode = Mode(rawValue: UserDefaults.standard.object(forKey: "officeFilter") as? Int ?? 1) ?? .work {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "officeFilter") }
    }
    var byLoudness = UserDefaults.standard.object(forKey: "officeLoudness") as? Bool ?? true {
        didSet { UserDefaults.standard.set(byLoudness, forKey: "officeLoudness") }
    }
    var byExchange = UserDefaults.standard.object(forKey: "officeExchange") as? Bool ?? true {
        didSet { UserDefaults.standard.set(byExchange, forKey: "officeExchange") }
    }
    /// 外した行の数（設定画面に出す）
    private(set) var dropped = UserDefaults.standard.integer(forKey: "officeDropped")

    /// 自分の声よりこれだけ小さい（dB）声は、遠くの人とみなす
    static let quietMargin: Float = 14
    /// 寝ているあいだは、もっと厳しくする
    static let sleepMargin: Float = 8
    /// 自分が話してからこの時間のうちは、名前の無い声も相手とみなす
    static let exchangeWindow: TimeInterval = 180

    /// 機器ごと（時計か iPhone か）の、自分の声の大きさ（dB）と、覚えた回数
    private var selfLevel: [Bool: (level: Float, count: Int)] = [:]
    /// 機器ごとの、最後に自分が話した時刻
    private var lastSelfSpoke: [Bool: Date] = [:]

    // MARK: - 自分が加わった話の続き（会議。2026-11-11）
    // 会議では、自分が何分も黙って聞いていることがある。前後3分だけを見ると、そのあいだの
    // 名前の無い参加者の声がすべて「周りの雑談」として外れていた（11/6 の会議で約20分ぶん。
    // 登録した職場にいた日は名前の無い声が1%しか残らず、「たぶん職場」の日は42%残っていた）。
    // そこで、自分か名前を付けた人が話してから、間（会話の切れ目の長さ）が空かずに続いている話は、上限まで相手の声とみなす。
    // 名前を付けた人も入れるのは、会議では自分の声が聞き分けられないことがあるため（11/9 の58分の会議で「自分」の行が0。
    // 名前を付けた人の行は178あった）。名前を付けた人の声は、もともと外さない。

    /// 自分か名前を付けた人が話してから、これだけのあいだは、話が続いていれば相手の声とみなす
    static let joinedTalkSpan: TimeInterval = 60 * 60
    /// 自分が加わった話の最中は、声の大きさの差をここまで許す（机の向こうの参加者の声。
    /// 距離が10倍で約20dB小さくなる。実際の録音ではまだ合わせていない）
    static let joinedTalkMargin: Float = 24

    /// 機器ごとの、最後に聞こえた行の時刻（外した行も含む。話が途切れたかを見る）
    private var lastHeard: [Bool: Date] = [:]
    /// 機器ごとの、いま続いている話の中で最後に自分か名前を付けた人が話した時刻（話が途切れたら nil）
    private var joinedAt: [Bool: Date] = [:]

    init() {
        for watch in [false, true] {
            let key = "selfLevel-\(watch ? "w" : "p")"
            if let saved = UserDefaults.standard.array(forKey: key) as? [Double], saved.count == 2 {
                selfLevel[watch] = (Float(saved[0]), Int(saved[1]))
            }
        }
    }

    /// 使うか。「職場にいるときだけ」は、登録した職場にいる・仕事の予定の最中と分かっているときだけ（sureWork）。
    /// 時刻だけの推定（平日8〜19時）では使わない。祝日の夕方の食事で友だちの声を外していたため（2026-11-05）。
    func applies(sureWork: Bool) -> Bool {
        switch mode {
        case .off: false
        case .work: sureWork
        case .always: true
        }
    }

    /// 覚えた自分の声の大きさ（dB）。まだ5回分覚えていなければ nil。話者の聞き分けの手がかりにも使う。
    func selfLevel(watch: Bool) -> Float? {
        guard let s = selfLevel[watch], s.count >= 5 else { return nil }
        return s.level
    }

    func selfLevelText(watch: Bool) -> String {
        guard let s = selfLevel[watch], s.count >= 5 else { return "まだ覚えていません" }
        return String(format: "%.0f dB", s.level)
    }

    struct Item {
        let time: Date
        let text: String
        let personID: String?
        let isNamed: Bool
        let level: Float?
    }

    /// 残す行。asleep は寝ているあいだ（短い行と小さい声をもっと厳しく外す）。
    func keep(_ items: [Item], fromWatch: Bool, active: Bool, asleep: Bool) -> [Bool] {
        // 自分の声の大きさを覚える（外すかどうかにかかわらず）
        for item in items where item.personID == SpeakerLabeler.selfID {
            if let level = item.level { learn(level, watch: fromWatch) }
        }
        let selfTimes = items.filter { $0.personID == SpeakerLabeler.selfID }.map(\.time)
        let reference: Float? = {
            if let s = selfLevel[fromWatch], s.count >= 5 { return s.level }
            return items.compactMap(\.level).max()
        }()
        // 声の大きさで外れる行。区切りの全部が外れるのは、たいてい自分の声の大きさを覚え違えているときなので、そのときは使わない
        var quiet = items.map { item -> Bool in
            guard let level = item.level, let reference else { return false }
            return level < reference - (asleep ? Self.sleepMargin : Self.quietMargin)
        }
        let allQuiet = !asleep && items.count >= 3 && !quiet.contains(false)
        if allQuiet { quiet = items.map { _ in false } }
        // 自分が加わった話の最中か（行ごと。話が途切れたら終わり、自分か名前を付けた人が話したらまた始まる）
        let joined = joinedTalk(items, fromWatch: fromWatch)
        let result = items.indices.map { i -> Bool in
            let item = items[i]
            let isSelf = item.personID == SpeakerLabeler.selfID
            if asleep {
                // 寝ているあいだは、近くではっきり話した長めの文だけ
                return Junk.normalized(item.text).count >= 8 && !quiet[i]
            }
            guard active, !isSelf else { return true }
            // 名前を付けた人の声は、小さくても外さない（1対1の相手の声が自分の声より14dB以上小さく入り、外れていた。2026-11-05）
            // 自分が加わった話の最中は、机の向こうの参加者の声も残す（それよりずっと小さい声だけ外す）
            var tooQuiet = quiet[i]
            if joined[i], !allQuiet, let level = item.level, let reference {
                tooQuiet = level < reference - Self.joinedTalkMargin
            }
            if byLoudness && tooQuiet && !item.isNamed { return false }
            if byExchange, item.personID != nil, !item.isNamed {
                let near = selfTimes.contains { abs($0.timeIntervalSince(item.time)) <= Self.exchangeWindow }
                    || lastSelfSpoke[fromWatch].map { item.time.timeIntervalSince($0) <= Self.exchangeWindow } == true
                    || joined[i]
                if !near { return false }
            }
            return true
        }
        if let last = selfTimes.max() { lastSelfSpoke[fromWatch] = max(lastSelfSpoke[fromWatch] ?? last, last) }
        let count = result.filter { !$0 }.count
        if count > 0 {
            dropped += count
            UserDefaults.standard.set(dropped, forKey: "officeDropped")
        }
        return result
    }

    /// 行ごとに、自分が加わった話の最中か。自分か名前を付けた人が話した行から、行と行の間が gap を超えずに続くあいだ
    /// （最後にそのどちらかが話してから joinedTalkSpan まで）。区切りをまたいで覚えておく。
    /// あとから届いた前の時間の区切り（時計にたまっていた音声など）は、その区切りの中だけで見て、覚えている値を変えない。
    func joinedTalk(_ items: [Item], fromWatch: Bool, gap: TimeInterval = ConversationGap.current) -> [Bool] {
        let order = items.indices.sorted { items[$0].time < items[$1].time }
        guard let first = order.first else { return [] }
        let late = lastHeard[fromWatch].map { items[first].time < $0.addingTimeInterval(-gap) } ?? false
        var heard = late ? nil : lastHeard[fromWatch]
        var joinedTime = late ? nil : joinedAt[fromWatch]
        var result = Array(repeating: false, count: items.count)
        for i in order {
            let t = items[i].time
            if let h = heard, t.timeIntervalSince(h) > gap { joinedTime = nil }
            if items[i].personID == SpeakerLabeler.selfID || items[i].isNamed { joinedTime = t }
            if let j = joinedTime, t.timeIntervalSince(j) > Self.joinedTalkSpan { joinedTime = nil }
            result[i] = joinedTime != nil
            heard = max(heard ?? t, t)
        }
        if !late {
            lastHeard[fromWatch] = heard
            joinedAt[fromWatch] = joinedTime
        }
        return result
    }

    private func learn(_ level: Float, watch: Bool) {
        let old = selfLevel[watch] ?? (level, 0)
        let weight: Float = old.count < 10 ? 1 / Float(old.count + 1) : 0.1
        let new = (old.level + (level - old.level) * weight, old.count + 1)
        selfLevel[watch] = new
        UserDefaults.standard.set([Double(new.0), Double(new.1)], forKey: "selfLevel-\(watch ? "w" : "p")")
    }

    /// 行ごとの声の大きさ（dB）。区間の中の 50ms ごとの大きさのうち、大きいほうから1割のところ。
    nonisolated static func levels(_ url: URL, spans: [(start: TimeInterval, end: TimeInterval)]) -> [Float?] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData?[0] else { return spans.map { _ in nil } }
        let rate = file.processingFormat.sampleRate
        let count = Int(buffer.frameLength)
        let step = max(1, Int(rate * 0.05))
        return spans.map { span in
            let from = max(0, Int(span.start * rate))
            let to = min(count, Int(min(span.end, span.start + 15) * rate))
            guard to - from >= step * 4 else { return nil }
            var frames: [Float] = []
            var i = from
            while i + step <= to {
                var sum: Float = 0
                for j in i..<(i + step) { sum += data[j] * data[j] }
                frames.append(20 * log10(max((sum / Float(step)).squareRoot(), 1e-7)))
                i += step
            }
            frames.sort()
            return frames[min(frames.count - 1, frames.count * 9 / 10)]
        }
    }
}

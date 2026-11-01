import AVFoundation
import Foundation
import Observation

/// オフィスなどで、自分と関係ない周りの人の声を記録に書かないようにする。
///
/// 1. 声の大きさ: 自分の声（機器ごとに覚えておく）より、ずっと小さく入った行は、遠くの人の声とみなす。
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

    init() {
        for watch in [false, true] {
            let key = "selfLevel-\(watch ? "w" : "p")"
            if let saved = UserDefaults.standard.array(forKey: key) as? [Double], saved.count == 2 {
                selfLevel[watch] = (Float(saved[0]), Int(saved[1]))
            }
        }
    }

    func applies(to context: SpeakerLabeler.Context) -> Bool {
        switch mode {
        case .off: false
        case .work: context == .work
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
        if !asleep && items.count >= 3 && !quiet.contains(false) { quiet = items.map { _ in false } }
        let result = items.indices.map { i -> Bool in
            let item = items[i]
            let isSelf = item.personID == SpeakerLabeler.selfID
            if asleep {
                // 寝ているあいだは、近くではっきり話した長めの文だけ
                return Junk.normalized(item.text).count >= 8 && !quiet[i]
            }
            guard active, !isSelf else { return true }
            if byLoudness && quiet[i] { return false }
            if byExchange, item.personID != nil, !item.isNamed {
                let near = selfTimes.contains { abs($0.timeIntervalSince(item.time)) <= Self.exchangeWindow }
                    || lastSelfSpoke[fromWatch].map { item.time.timeIntervalSince($0) <= Self.exchangeWindow } == true
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

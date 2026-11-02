import Foundation
import Observation
import SwiftUI

/// 時計の区切りが、録り終わってからどれだけ遅れて届き、文字になったかを残す。
/// 遅れの原因（送るのが遅いのか、iPhone の処理が遅いのか）を見分けるためのもので、記録には影響しない。
@MainActor
@Observable
final class WatchDelayLog {
    struct Entry: Codable, Identifiable {
        /// 音声ファイルの名前
        let id: String
        /// 録り終わった時刻（名前の時刻＋長さ）
        let ended: Date
        /// iPhone のアプリが受け取った時刻
        let received: Date
        /// 文字起こしが終わった時刻
        var processed: Date? = nil
        /// 受け取ったとき、時計が低電力モードだったか（分からなければ nil）
        var lowPower: Bool? = nil
        /// 届くのが遅れて捨てた30秒枠の数
        var dropped: Int? = nil

        /// 録り終わってから届くまで（秒）
        var arrival: TimeInterval { max(0, received.timeIntervalSince(ended)) }
        /// 届いてから文字になるまで（秒）
        var waiting: TimeInterval? { processed.map { max(0, $0.timeIntervalSince(received)) } }
    }

    /// 覚えておく数（5分ごとなら2日ほど）
    private static let limit = 600
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("watch-delays.json")

    private(set) var entries: [Entry] = []

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// 直近24時間の区切り
    var recent: [Entry] {
        let since = Date.now.addingTimeInterval(-24 * 3600)
        return entries.filter { $0.received >= since }
    }

    func received(_ name: String, ended: Date, at time: Date, lowPower: Bool?) {
        guard !entries.contains(where: { $0.id == name }) else { return }
        entries.append(Entry(id: name, ended: ended, received: time, lowPower: lowPower))
        entries = Array(entries.suffix(Self.limit))
        save()
    }

    func processed(_ name: String) {
        guard let i = entries.firstIndex(where: { $0.id == name }), entries[i].processed == nil else { return }
        entries[i].processed = .now
        save()
    }

    /// 遅れて捨てた枠を記す（1枠につき名前が1つ）
    func dropped(_ names: [String]) {
        guard !names.isEmpty else { return }
        for name in names {
            guard let i = entries.firstIndex(where: { $0.id == name }) else { continue }
            entries[i].dropped = (entries[i].dropped ?? 0) + 1
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    static func text(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) 秒" : String(format: "%.1f 分", seconds / 60)
    }
}

/// 時計の遅れの一覧。
struct WatchDelayView: View {
    @Environment(Pipeline.self) private var pipeline

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func median(_ list: [TimeInterval]) -> TimeInterval { list.sorted()[list.count / 2] }

    var body: some View {
        let recent = pipeline.watchDelays.recent
        let arrivals = recent.map(\.arrival)
        let waits = recent.compactMap(\.waiting)
        let dropped = recent.compactMap(\.dropped).reduce(0, +)
        Form {
            Section {
                LabeledContent("届いた区切り", value: "\(recent.count) 個")
                if !arrivals.isEmpty {
                    LabeledContent("届くまで（ふつう）", value: WatchDelayLog.text(median(arrivals)))
                    LabeledContent("届くまで（いちばん遅い）", value: WatchDelayLog.text(arrivals.max() ?? 0))
                }
                if !waits.isEmpty {
                    LabeledContent("文字になるまで（ふつう）", value: WatchDelayLog.text(median(waits)))
                    LabeledContent("文字になるまで（いちばん遅い）", value: WatchDelayLog.text(waits.max() ?? 0))
                }
                LabeledContent("遅れて使えなかった時間", value: WatchDelayLog.text(TimeInterval(dropped * 30)))
            } header: {
                Text("直近24時間")
            } footer: {
                Text("「届くまで」は、5分の区切りを録り終わってから iPhone のアプリが受け取るまでです。「文字になるまで」は、受け取ってから文字起こしが終わるまでです。12分以上遅れて、iPhone の音で先に書いた時間は「遅れて使えなかった時間」に入ります。")
            }
            Section("いまの設定") {
                LabeledContent("待機モード", value: pipeline.standbyOn ? "オン" : "オフ")
                LabeledContent("時計の低電力モード", value: pipeline.watchLowPower.map { $0 ? "オン" : "オフ" } ?? "不明")
            }
            if !recent.isEmpty {
                Section("最近の区切り") {
                    ForEach(recent.suffix(30).reversed()) { entry in
                        LabeledContent(Self.clock.string(from: entry.ended)) {
                            Text(detail(entry))
                        }
                    }
                }
            }
        }
        .navigationTitle("時計の遅れ")
    }

    private func detail(_ entry: WatchDelayLog.Entry) -> String {
        var text = "届く " + WatchDelayLog.text(entry.arrival)
        if let wait = entry.waiting { text += "・文字 " + WatchDelayLog.text(wait) }
        if entry.lowPower == true { text += "・低電力" }
        return text
    }
}

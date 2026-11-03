import Foundation
import Observation
import SwiftUI

/// 区切りごとの騒がしさ（周りの音の底と、声の大きさ）を残す。
/// 騒がしさのしきい値を実際の録音で合わせるためのもので、記録には影響しない。
@MainActor
@Observable
final class NoiseLog {
    struct Entry: Codable, Identifiable {
        /// 音声ファイルの名前
        let id: String
        let time: Date
        let watch: Bool
        let floor: Float
        let speech: Float?
        let noisy: Bool

        var margin: Float? { speech.map { $0 - floor } }
    }

    /// 覚えておく数（iPhone と時計の両方で録って4日ほど）
    private static let limit = 2_000
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("noise-log.json")

    private(set) var entries: [Entry] = []

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ name: String, at time: Date, watch: Bool, reading: NoiseMeter.Reading) {
        entries.removeAll { $0.id == name }
        entries.append(Entry(id: name, time: time, watch: watch, floor: reading.floor, speech: reading.speech,
                             noisy: reading.isNoisy))
        entries = Array(entries.suffix(Self.limit))
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

extension Pipeline {
    /// 聞き取りの成績の1行（機器・場所ごと）
    struct QualityRow: Identifiable {
        let label: String
        var lines = 0
        /// 聞き取りの確からしさが低かった行（あとで手で直したものも含む）
        var uncertain = 0
        /// 手で文字を直した行
        var fixed = 0
        /// 騒がしいところで聞き取った行
        var noisy = 0
        var id: String { label }
    }

    /// 周りの音の1行（機器・場所ごと）
    struct NoiseRow: Identifiable {
        let label: String
        let count: Int
        /// 周りの音の底・声との差の真ん中の値（dB）
        let floor: Float
        let margin: Float?
        /// 騒がしいとみなした区切りの数
        let noisy: Int
        var id: String { label }
    }

    /// 直近の日の記録から、機器ごと・場所ごとに「？」の行と手で直した行の割合を数える。
    func listeningQuality(days: Int = 14) -> (devices: [QualityRow], places: [QualityRow]) {
        var devices: [String: QualityRow] = [:]
        var places: [String: QualityRow] = [:]
        func count(_ row: inout QualityRow, _ line: ConversationLog.Line) {
            row.lines += 1
            if (line.confidence ?? 1) < 0.45 { row.uncertain += 1 }
            if line.checked == true { row.fixed += 1 }
            if line.noisy == true { row.noisy += 1 }
        }
        for day in recordedDays().prefix(days) {
            for c in conversations(on: day) where c.media == nil {
                let place = c.place ?? "場所が分からない"
                for line in c.lines where line.media == nil {
                    guard let audio = line.audio else { continue }
                    let device = audio.hasSuffix("-w.m4a") ? "時計" : "iPhone"
                    count(&devices[device, default: QualityRow(label: device)], line)
                    count(&places[place, default: QualityRow(label: place)], line)
                }
            }
        }
        return (devices.values.sorted { $0.lines > $1.lines },
                Array(places.values.sorted { $0.lines > $1.lines }.prefix(10)))
    }

    /// 残してある区切りの騒がしさを、機器ごと・場所ごとにまとめる。
    func noiseSummary() -> (devices: [NoiseRow], places: [NoiseRow]) {
        let byAudio = placeIndex().byAudio
        func row(_ label: String, _ list: [NoiseLog.Entry]) -> NoiseRow {
            let floors = list.map(\.floor).sorted()
            let margins = list.compactMap(\.margin).sorted()
            return NoiseRow(label: label, count: list.count, floor: floors[floors.count / 2],
                            margin: margins.isEmpty ? nil : margins[margins.count / 2],
                            noisy: list.filter(\.noisy).count)
        }
        let entries = noiseLog.entries
        let devices = Dictionary(grouping: entries) { $0.watch ? "時計" : "iPhone" }
            .map { row($0.key, $0.value) }.sorted { $0.count > $1.count }
        let places = Dictionary(grouping: entries) { byAudio[$0.id] ?? "場所が分からない" }
            .map { row($0.key, $0.value) }.sorted { $0.count > $1.count }
        return (devices, Array(places.prefix(10)))
    }
}

/// 聞き取りの成績。どこで・どの機器で聞き取りが悪いかと、周りの音の大きさを数字で見る。
struct ListenQualityView: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var quality: (devices: [Pipeline.QualityRow], places: [Pipeline.QualityRow]) = ([], [])
    @State private var noise: (devices: [Pipeline.NoiseRow], places: [Pipeline.NoiseRow]) = ([], [])

    private static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "-" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }

    var body: some View {
        Form {
            Section {
                ForEach(quality.devices) { qualityRow($0) }
            } header: {
                Text("機器ごと（直近14日）")
            } footer: {
                Text("「？」は聞き取りの確からしさが低かった行（あとで手で直した行も含む）、「直した」は「文字を直す」で直した行の割合です。時計のほうが悪ければ、袖に隠れていないか、つける腕を変えると良くなることがあります。")
            }
            Section("場所ごと（直近14日・多い順に10か所）") {
                ForEach(quality.places) { qualityRow($0) }
            }
            if noise.devices.isEmpty {
                Section {
                    Text("まだ測った区切りがありません。これから文字にする区切りから測ります。").foregroundStyle(.secondary)
                } header: {
                    Text("周りの音")
                }
            } else {
                Section {
                    ForEach(noise.devices) { noiseRow($0) }
                } header: {
                    Text("周りの音（機器ごと）")
                }
                Section {
                    ForEach(noise.places) { noiseRow($0) }
                } header: {
                    Text("周りの音（場所ごと）")
                } footer: {
                    Text(String(format: "区切りごとの「周りの音の底」と「声との差」の真ん中の値です。いまの基準は、底が %.0f dB 以上か、底が %.0f dB 以上で声との差が %.0f dB 未満なら「騒がしい」。静かなはずの場所（自宅など）で「騒がしい」が多ければ基準が厳しすぎ、うるさい場所で少なければゆるすぎです。声との差が小さい場所ほど、iPhone をテーブルの上に置いてマイク（画面の下の端）を相手に向けると良くなります。",
                                NoiseMeter.loudFloor, NoiseMeter.quietFloor, NoiseMeter.minimumMargin))
                }
            }
        }
        .navigationTitle("聞き取りの成績")
        .onAppear {
            quality = pipeline.listeningQuality()
            noise = pipeline.noiseSummary()
        }
    }

    private func qualityRow(_ row: Pipeline.QualityRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(row.label, value: "\(row.lines) 行")
            Text("？ \(Self.percent(row.uncertain, row.lines))・直した \(Self.percent(row.fixed, row.lines))・騒がしい所 \(Self.percent(row.noisy, row.lines))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func noiseRow(_ row: Pipeline.NoiseRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(row.label, value: "\(row.count) 区切り")
            Text(String(format: "底 %.0f dB", row.floor)
                 + (row.margin.map { String(format: "・声との差 %.0f dB", $0) } ?? "")
                 + "・騒がしい \(Self.percent(row.noisy, row.count))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

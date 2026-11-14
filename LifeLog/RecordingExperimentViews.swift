import Foundation
import SwiftUI

// 録り方の実験の iPhone の側（2026-11-15。強化案 47。決まりは Shared/Audio/RecordingExperiment.swift）。
// その日の組は tally に `exp.<日>.bitrate`（kbps）と `exp.<日>.chunk`（秒）として1日1回残す（数だけ）。
// 時計の電池の減り方は、今までどおり時計の様子（自己点検・家の PC への様子）に乗る。比べて決めるのは本人（母艦の報告）。

extension Pipeline {
    /// 1日目を決め（まだなら次の日。時計にも渡す）、会議モードかを録音の部品に渡し、その日の組を tally に残す（1日1回）
    func noteRecordingExperiment(now: Date = .now) {
        UserDefaults.standard.set(MeetingMode.active != nil, forKey: RecordingExperiment.meetingKey)
        if RecordingExperiment.start == nil {
            RecordingExperiment.start = RecordingExperiment.firstDay(after: now)
            receiver.sendSettings(skipSilence: skipSilence, held: recordingHeld)
        }
        guard let combo = RecordingExperiment.current(now: now) else { return }
        let day: String = RecordingExperiment.dayKey(now)
        let name: String = "exp." + day + ".bitrate"
        let counts: [String: Int] = Tally.days(1, now: now)[day] ?? [:]
        guard counts[name] == nil else { return }
        Tally.add(name, combo.bitrate / 1000, at: now)
        Tally.add("exp." + day + ".chunk", Int(combo.length.minimum), at: now)
    }
}

/// 設定の「録り方の実験」（Apple Watch の設定の下）
struct RecordingExperimentSection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(RecordingExperiment.onKey) private var on = true

    var body: some View {
        Section {
            Toggle("録り方の実験", isOn: $on)
            LabeledContent("きょう", value: todayText)
            if let start = RecordingExperiment.start {
                ForEach(0..<RecordingExperiment.days, id: \.self) { i in
                    Text(Self.dayLine(start: start, index: i)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("録り方の実験")
        } footer: {
            HelpNote("音質（32kbps と 48kbps）と区切りの長さ（45秒と300秒）を1日ずつ変えて、拾えた割合・人物N・時計の電池を家の PC（母艦）が組ごとに並べます。どれにするかは、並んだ数を見て自分で決めます（4日分なので数は少なめです）。\n新しい版を初めて開いた次の日から4日間だけで、終わったら元の録り方（32kbps・設定の区切りの長さ）に戻ります。会議モードのあいだは会議モードの録り方が優先です。時計の電池が少ないときの「5分に」も、こちらより優先します。\nオフにすると、すぐ（次の区切りから）元の録り方に戻ります。時計には、時計と iPhone がつながったときに伝わります。")
        }
        .onChange(of: on) { _, _ in
            pipeline.receiver.sendSettings(skipSilence: pipeline.skipSilence, held: pipeline.recordingHeld)
        }
    }

    private var todayText: String {
        let now: Date = .now
        guard on else { return "止めています（いつもの録り方）" }
        guard let start = RecordingExperiment.start else { return "あしたから始まります" }
        if RecordingExperiment.finished(start: start, now: now) { return "終わりました（いつもの録り方）" }
        if RecordingExperiment.meetingNow { return "会議モード中（会議モードの録り方）" }
        if let combo = RecordingExperiment.combo(on: true, start: start, meeting: false, now: now) {
            return "\(combo.day)日目: " + combo.label
        }
        return start + " から始まります"
    }

    /// 「1日目 2026-11-16: 32kbps・45秒」
    static func dayLine(start: String, index: Int) -> String {
        let entry = RecordingExperiment.plan[index]
        var day: String = ""
        if let first = RecordingExperiment.date(start),
           let date = Calendar.current.date(byAdding: .day, value: index, to: first) {
            day = " " + RecordingExperiment.dayKey(date)
        }
        let combo = RecordingExperiment.Combo(day: index + 1, bitrate: entry.bitrate, length: entry.length)
        return "\(index + 1)日目" + day + ": " + combo.label
    }
}

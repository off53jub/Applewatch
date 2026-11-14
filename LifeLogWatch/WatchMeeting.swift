import SwiftUI

/// 時計の「さっきの会話」のいちばん上に出す、会議の相棒（2026-11-15。強化案 50）。
/// iPhone が家の PC から読んだ「自分の宿題・聞き忘れ・決まったこと」の数と、先頭の数行（宿・聞・決の印つき）
struct MeetingGlance: View {
    let meeting: WatchInfo.Meeting

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()

    private var counts: String {
        let homework: String = "宿題 \(meeting.homework ?? 0)"
        let unasked: String = "聞き忘れ \(meeting.unasked ?? 0)"
        let decided: String = "決まった \(meeting.decided ?? 0)"
        return homework + "・" + unasked + "・" + decided
    }

    private var heading: String {
        let start: String = Self.clock.string(from: Date(timeIntervalSince1970: meeting.start))
        let state: String = meeting.on == false ? "（終わった会議）" : "（会議中）"
        return start + "〜" + state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("会議の相棒", systemImage: "person.3.sequence")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(heading).font(.caption2).foregroundStyle(.secondary)
            Text(counts).font(.caption2)
            ForEach(Array((meeting.items ?? []).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2)
            }
            if meeting.updated == nil {
                Text("まだ作っていません").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

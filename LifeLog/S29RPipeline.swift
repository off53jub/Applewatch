import Foundation

// s29 の当てる担当: 区切りごとの手がかり（S29RHints）を、予定・会議モード・「今から A さんと」・騒がしさから作る。
// 決まりは S29RVoice.swift。ここは Pipeline の持ち物を読んでまとめるだけ（書き換えない）。

extension Pipeline {
    /// 区切り（start から duration 秒）の手がかり。noise・speech は transcribe の測り（無ければ nil）。
    /// chain が false なら区切りまたぎの鎖（声12）に使わない（あとから聞き分け直す古い区切りで、今の鎖を切らないように）
    func s29rHints(at start: Date, duration: TimeInterval, fromWatch: Bool,
                   noise: NoiseMeter.Reading?, speech: [VoiceDetector.Span]?, chain: Bool = true) -> S29RHints {
        var hints = S29RHints()
        hints.start = chain ? start : nil
        hints.watch = fromWatch
        if let noise {
            hints.noiseFloor = noise.floor
            hints.margin = noise.margin
            hints.noisy = noise.isNoisy
        }
        if let speech {
            var spans: [S29RSpan] = []
            for s in speech { spans.append(S29RSpan(start: s.start, end: s.end)) }
            hints.speech = spans
        }
        let end = start.addingTimeInterval(max(duration, 1))
        let named = people.filter { $0.isNamed && !$0.isSelf && $0.hidden != true }
        func ids(_ names: [String]) -> Set<String> {
            var out: Set<String> = []
            for p in named where names.contains(where: { Self.sameName($0, p.displayName) }) { out.insert(p.id) }
            return out
        }
        let meeting = MeetingMode.session(at: start)?.attendees ?? []
        let events = calendar.events(from: start, to: end).filter { !$0.attendees.isEmpty }
        let known = Set(named.map(\.id))
        let withNow = S29RWithNow.ids(from: start, to: end).intersection(known)
        let single: Set<String> = events.count == 1 && Set(events[0].attendees).count == 1 ? ids(events[0].attendees) : []
        hints.strong = S29RClues.strong(meeting: ids(meeting), withNow: withNow, singleEventIDs: single)
        var counts: [Int] = []
        for e in events { counts.append(Set(e.attendees).count) }
        hints.headcount = S29RClues.headcount(meetingAttendees: Set(meeting).count, withNow: withNow.count, eventAttendees: counts)
        return hints
    }
}

import Foundation

/// 仕組みごとの効き目を数える帳（2026-11-06）。
/// 日ごとに「何をいくつやったか」だけを数える（会話の中身・人の名前は入れない）。35日分を `tally.json` に残し、
/// 自己点検とドライブの「診断」に、直近7日の合計と割合を出す。効いていない仕組みを、数を見て止めたり直したりするため。
enum Tally {
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("tally.json")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String: Int]]?

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func loadLocked() -> [String: [String: Int]] {
        if let cache { return cache }
        let all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String: Int]].self, from: $0) } ?? [:]
        cache = all
        return all
    }

    /// 数を足す（どのスレッドからでもよい）
    static func add(_ name: String, _ count: Int = 1, at date: Date = .now) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        let day = dayKey(date)
        all[day, default: [:]][name, default: 0] += count
        // 35日より前は捨てる
        let oldest = dayKey(date.addingTimeInterval(-35 * 86400))
        all = all.filter { $0.key >= oldest }
        cache = all
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    /// 直近の何日か（今日を含む）の合計
    static func sums(days: Int = 7, now: Date = .now) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        let oldest = dayKey(now.addingTimeInterval(-Double(days - 1) * 86400))
        var out: [String: Int] = [:]
        for (day, counts) in loadLocked() where day >= oldest {
            for (k, v) in counts { out[k, default: 0] += v }
        }
        return out
    }

    /// テスト用に消す
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        cache = [:]
        try? FileManager.default.removeItem(at: url)
    }

    /// 自己点検の行（見出し・中身・良いか）。数が無い仕組みは出さない。
    static func report(_ s: [String: Int]) -> [(label: String, value: String, ok: Bool?)] {
        func n(_ k: String) -> Int { s[k] ?? 0 }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "" : "（\(Int((Double(a) / Double(b) * 100).rounded()))%）" }
        var rows: [(label: String, value: String, ok: Bool?)] = []
        if n("fix.proposed") > 0 {
            rows.append(("誤変換の直し", "直した行 \(n("fix.proposed"))・2つ目のモデルも合って使った \(n("fix.kept"))"
                + pct(n("fix.kept"), n("fix.proposed")) + "・合わず元のまま \(n("fix.dropped"))", nil))
        }
        let agreed = n("task.agreed"), alone = n("task.alone")
        if agreed + alone > 0 {
            rows.append(("頼まれごと", "2つのモデルが両方拾った \(agreed)" + pct(agreed, agreed + alone) + "・片方だけ \(alone)", nil))
        }
        if n("minutes.items") > 0 {
            rows.append(("議事録", "決まったこと・宿題 \(n("minutes.items"))・片方のモデルだけ（要確認）\(n("minutes.unsure"))", nil))
        }
        if n("second.ran") + n("second.skipped") > 0 {
            rows.append(("2つ目の言語モデル", "見比べた \(n("second.ran")) 回・使えなかった \(n("second.skipped")) 回（充電中でない・アプリを開いていない など）",
                         n("second.ran") > 0 ? nil : false))
        }
        if n("pc.speakerChecked") > 0 {
            let checked = n("pc.speakerChecked"), differ = n("pc.speakerDiffer")
            // 食い違いが3割を超えるなら、PC の話者モデルが日本語の声に合っていないかもしれない
            let tooMany = checked >= 20 && Double(differ) / Double(checked) > 0.3
            rows.append(("話者（PC で測り直し）", "測った行 \(checked)・食い違い \(differ)" + pct(differ, checked)
                + "・「直す」を押した \(n("pc.speakerAccepted"))・消した \(n("pc.speakerRejected"))"
                + (tooMany ? "・食い違いが多すぎる（モデルの相性が悪いかも）" : ""), checked >= 20 ? !tooMany : nil))
        }
        if n("pc.sceneChecked") > 0 {
            rows.append(("場面（PC と iPhone の多数決）", "聞いた会話 \(n("pc.sceneChecked"))・場面を決めた \(n("pc.sceneSet"))"
                + pct(n("pc.sceneSet"), n("pc.sceneChecked")), nil))
        }
        if n("pc.vadExtra") > 0 {
            rows.append(("声の区間（PC）", "iPhone が拾い漏らして PC が拾った所から増えた行 \(n("pc.vadExtra"))", nil))
        }
        if n("night.lines") > 0 {
            rows.append(("夜の聞き直し", "聞き直した行 \(n("night.lines"))・書き直した行 \(n("night.changed"))"
                + pct(n("night.changed"), n("night.lines")), nil))
        }
        if n("split.lines") > 0 {
            rows.append(("話者の替わり目で分けた行", "\(n("split.lines")) 行（PC の言葉ごとの時刻から）", nil))
        }
        if n("ground.checked") > 0 {
            rows.append(("言語モデルの書いたものの根拠", "確かめた \(n("ground.checked"))・根拠が見つからず外した要点 \(n("ground.dropped"))"
                + "・要確認にした項目 \(n("ground.flagged"))", nil))
        }
        if n("talk.joined") + n("talk.split") > 0 {
            rows.append(("会話の区切りの手直し", "つないだ \(n("talk.joined"))・分けた \(n("talk.split"))", nil))
        }
        if n("othermic.lines") > 0 {
            rows.append(("もう1台のマイクの票", "\(n("othermic.lines")) 行（iPhone と時計の両方で録った時間）", nil))
        }
        if n("paid.lines") > 0 {
            rows.append(("有料の票（ElevenLabs）", "\(n("paid.lines")) 行・今月 \(Int(PaidVote.usedSeconds / 60)) 分", nil))
        }
        if n("bench.lines") > 0 {
            rows.append(("精度の物差しで測った行", "\(n("bench.lines")) 行", nil))
        }
        if n("personal.sent") > 0 {
            rows.append(("あなた向けのモデルの材料", "PC に渡した \(n("personal.sent")) 行", nil))
        }
        if n("learn.updated") > 0 {
            rows.append(("直した記録から学んだ", "値を合わせ直した \(n("learn.updated")) 回", nil))
        }
        return rows
    }
}

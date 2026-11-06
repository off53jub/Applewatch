import Foundation

// 精度を上げるしくみ（2026-11-06）
// - 話者が替わった所で行を分ける（PC の言葉ごとの時刻を使う）
// - 言語モデルが書いたものの根拠を、もとの会話の中に探す
// - 精度の物差し（答え合わせの行を今の設定で文字にし直して、誤りの割合を測る。設定の良し悪しを数で決める）

extension HomePC {
    /// 話者が替わる所で行を分ける。行の言葉ごとの時刻と、声の聞き分けの区間を比べ、
    /// 行の中で話していた人が替わり、替わる前と後がどちらも minRun 秒以上続いていたら、そこで分ける。
    /// 分けた行は、多数決の票やほかのモデルの文とは合わなくなるので、それらを持たない（確からしさは元の行のまま）。
    nonisolated static func splitAtSpeakerChanges(_ lines: [Line], segments: [SpeakerLabeler.Segment],
                                                  minRun: Double = 0.4) -> [Line] {
        guard !segments.isEmpty else { return lines }
        func speaker(_ w: Word) -> String? {
            var best: (id: String, overlap: Double)?
            for s in segments {
                let o = min(w.end, s.end) - max(w.start, s.start)
                if o > 0, o > (best?.overlap ?? 0) { best = (s.personID, o) }
            }
            return best?.id
        }
        var out: [Line] = []
        for line in lines {
            guard line.words.count >= 2 else { out.append(line); continue }
            // 言葉ごとの話し手（どの区間にも入らない言葉は、前の言葉の人）
            var who: [String?] = line.words.map(speaker)
            for i in who.indices where who[i] == nil && i > 0 { who[i] = who[i - 1] }
            if who.first == nil, let first = who.first(where: { $0 != nil }) { who[0] = first }
            // 同じ人の続き（run）にまとめる
            var runs: [(id: String?, words: [Word])] = []
            for (w, id) in zip(line.words, who) {
                if let last = runs.last, last.id == id { runs[runs.count - 1].words.append(w) } else { runs.append((id, [w])) }
            }
            // 短すぎる続きは、前（無ければ後ろ）の続きに入れる
            var merged: [(id: String?, words: [Word])] = []
            for run in runs {
                let length = (run.words.last?.end ?? 0) - (run.words.first?.start ?? 0)
                if length < minRun, !merged.isEmpty {
                    merged[merged.count - 1].words += run.words
                } else if let last = merged.last, last.id == run.id {
                    merged[merged.count - 1].words += run.words
                } else {
                    merged.append(run)
                }
            }
            if merged.count >= 2, let firstLength = merged.first.map({ ($0.words.last?.end ?? 0) - ($0.words.first?.start ?? 0) }),
               firstLength < minRun {
                merged[1].words = merged[0].words + merged[1].words
                merged.removeFirst()
            }
            guard merged.count >= 2 else { out.append(line); continue }
            for run in merged {
                let text = run.words.map(\.text).joined()
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                out.append(Line(offset: run.words.first?.start ?? line.offset, end: run.words.last?.end ?? line.end,
                                text: text.trimmingCharacters(in: .whitespaces), confidence: line.confidence,
                                alternatives: [], votes: [:], words: run.words))
            }
        }
        return out
    }
}

/// 言語モデルが書いたもの（要点・議事録の項目・頼まれごと）の根拠を、もとの会話の中に探す。
/// 言葉の中身（漢字・カタカナ・英数字）の2文字の並びが、続いた3行までの中にどれだけあるかで測る。
enum Grounding {
    private static func isContent(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { s in
            (0x4E00...0x9FFF).contains(s.value) || (0x30A0...0x30FF).contains(s.value) || s.value == 0x3005
                || (CharacterSet.alphanumerics.contains(s) && s.value < 0x3000)
        }
    }

    /// 中身の2文字の並び（中身の文字が続いている所だけ）
    static func contentBigrams(_ text: String) -> Set<String> {
        let chars = Array(text.lowercased())
        var out = Set<String>()
        guard chars.count >= 2 else { return out }
        for i in 0..<(chars.count - 1) where isContent(chars[i]) && isContent(chars[i + 1]) {
            out.insert(String(chars[i...i + 1]))
        }
        return out
    }

    /// 根拠の強さ（0〜1）。中身の並びが2つ未満で測れないときは nil
    static func support(_ claim: String, in lines: [String]) -> Double? {
        let want = contentBigrams(claim)
        guard want.count >= 2 else { return nil }
        let have = lines.map(contentBigrams)
        var best = 0.0
        for i in have.indices {
            var window = Set<String>()
            for k in i..<min(i + 3, have.count) {
                window.formUnion(have[k])
                best = max(best, Double(want.intersection(window).count) / Double(want.count))
            }
        }
        // 会話全体でも測る（要点は会話のあちこちをまとめることがある）。ただし全体は少し割り引く
        let all = have.reduce(into: Set<String>()) { $0.formUnion($1) }
        best = max(best, Double(want.intersection(all).count) / Double(want.count) * 0.8)
        return best
    }

    /// 根拠が見つからない（測れないものは見つかったとみなす）
    static func unsupported(_ claim: String, in lines: [String], below: Double = 0.25) -> Bool {
        guard let s = support(claim, in: lines) else { return false }
        return s < below
    }

    static let mark = "（要確認：会話に根拠が見つからない）"
}

/// 精度の物差し（2026-11-06）。
/// 答え合わせで正しい文が分かっている行を、夜の充電中に家の PC で文字にし直し、文字の誤りの割合を測る。
/// 同じ行を「今の設定」と「試す設定」の両方で文字にして比べ、試す設定が30問以上で1割以上良ければ使う、悪ければ使わない。
enum Benchmark {
    /// 試す設定
    enum Variant: String, CaseIterable, Codable {
        /// 雑音を消した音も聞く（静かな区切りでも）
        case enhance
        /// 多数決の重みを送らない
        case noWeights
        /// 聞き取ってほしい言葉を渡さない（ヒントが邪魔をしていないか）
        case noHints

        var label: String {
            switch self {
            case .enhance: "雑音を消した音もいつも聞く"
            case .noWeights: "多数決の重みを使わない"
            case .noHints: "言葉のヒントを渡さない"
            }
        }
    }

    struct Score: Codable, Equatable {
        /// 今の設定と試す設定の、誤った文字の数
        var baseErrors = 0
        var variantErrors = 0
        /// 正しい文の文字の数
        var chars = 0
        var count = 0
        /// 最後に測った日
        var last: Date?
    }

    struct Saved: Codable {
        var scores: [String: Score] = [:]
        /// 今の設定だけの、日ごとの誤りの割合（新しい60日分）
        var history: [Point] = []
        var night = 0
    }

    struct Point: Codable, Equatable {
        let day: Date
        let rate: Double
        let count: Int
    }

    static let need = 30
    private static let key = "benchmark"

    static var saved: Saved {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return Saved() }
            return (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    /// 試す設定を使うか（数で決まっていなければ nil）
    static func decision(_ s: Score) -> Bool? {
        guard s.count >= need, s.chars > 0 else { return nil }
        let base = Double(s.baseErrors), variant = Double(s.variantErrors)
        if variant <= base * 0.9 { return true }
        if variant >= base * 1.05 || variant > base { return false }
        return nil
    }

    /// 文字の誤り（読み比べの前に記号や空白をそろえる）
    static func errors(_ text: String, right: String) -> (errors: Int, chars: Int) {
        let r = AnswerKey.normalized(right), t = AnswerKey.normalized(text)
        return (AnswerKey.editDistance(t, r), r.count)
    }

    /// 答えの行の区間（始まりの少し前から、文字数で見積もった長さ）
    static func span(offset: TimeInterval, chars: Int) -> (start: TimeInterval, end: TimeInterval) {
        (max(0, offset - 0.3), offset + min(15, max(1.5, Double(chars) * 0.17 + 0.8)))
    }

    /// 自己点検の行
    static func report() -> [(label: String, value: String, ok: Bool?)] {
        let s = saved
        var rows: [(label: String, value: String, ok: Bool?)] = []
        if let last = s.history.last {
            let recent = s.history.suffix(14)
            let mean = recent.map(\.rate).reduce(0, +) / Double(recent.count)
            rows.append(("今の設定の文字の誤り", String(format: "%.1f%%（最後 %.1f%%・%d 問）・直近 %d 回の平均 %.1f%%",
                                                 last.rate * 100, last.rate * 100, last.count, recent.count, mean * 100), nil))
        }
        for v in Variant.allCases {
            guard let score = s.scores[v.rawValue], score.chars > 0 else { continue }
            let base = Double(score.baseErrors) / Double(score.chars) * 100
            let variant = Double(score.variantErrors) / Double(score.chars) * 100
            let decided = decision(score)
            rows.append((v.label, String(format: "誤り %.1f%% → %.1f%%（%d 問）", base, variant, score.count)
                + (decided == true ? "・使う" : decided == false ? "・使わない" : "・まだ決めない"), nil))
        }
        return rows
    }
}

extension Pipeline {
    /// 精度の物差しを1晩分動かす（夜の聞き直しのあと。家の PC につながるときだけ）。
    /// 答え合わせの行を limit 個（夜ごとにずらす）、今の設定と、夜ごとに回す試す設定の両方で文字にし直して比べる。
    func measureAccuracy(limit: Int = 12) async {
        guard homePC.shouldTry else { return }
        _ = try? await homePC.hello()
        guard homePC.engineCount > 1 || homePC.features.contains("vad") else { return }
        let answered = answerKey.samples.filter { s in
            s.isAnswered && s.skipped != true && !(s.rightText ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }.sorted { $0.id < $1.id }
        guard !answered.isEmpty else { return }
        var saved = Benchmark.saved
        let night = saved.night
        saved.night += 1
        let variants = Benchmark.Variant.allCases.filter { $0 != .enhance || homePC.features.contains("enhance") }
        let variant = variants.isEmpty ? nil : variants[night % variants.count]
        let first = (night * limit) % answered.count
        let picks = (0..<min(limit, answered.count)).map { answered[(first + $0) % answered.count] }
        var baseErrors = 0, baseChars = 0, count = 0
        var score = variant.flatMap { saved.scores[$0.rawValue] } ?? Benchmark.Score()
        for sample in picks {
            guard let right = sample.rightText, let url = await archive.playableURL(for: sample.audio) else { continue }
            let span = Benchmark.span(offset: sample.offset, chars: right.count)
            let hints = keywords(for: vocabularyContext(at: sample.time))
            func listen(_ v: Benchmark.Variant?) async -> String? {
                guard let lines = try? await homePC.transcribe(
                    url, segments: [span], hints: v == .noHints ? [] : hints, noisy: sample.noisy == true,
                    enhance: v == .enhance ? true : nil, weights: v == .noWeights ? false : nil, unionVAD: false) else { return nil }
                return lines.filter { $0.offset >= span.start - 0.5 && $0.offset <= span.end }.map(\.text).joined()
            }
            guard let base = await listen(nil) else { continue }
            let b = Benchmark.errors(base, right: right)
            baseErrors += b.errors
            baseChars += b.chars
            count += 1
            if let variant, let other = await listen(variant) {
                let o = Benchmark.errors(other, right: right)
                score.baseErrors += b.errors
                score.variantErrors += o.errors
                score.chars += b.chars
                score.count += 1
                score.last = .now
            }
        }
        if let variant, score.count > 0 {
            saved.scores[variant.rawValue] = score
            // 雑音を消した音と重みは、数で決まったら自動で使う・やめる（言葉のヒントは測るだけ）
            if variant != .noHints, let use = Benchmark.decision(score) {
                UserDefaults.standard.set(use, forKey: "benchAdopt." + variant.rawValue)
            }
        }
        if count > 0, baseChars > 0 {
            saved.history = Array((saved.history + [Benchmark.Point(day: .now, rate: Double(baseErrors) / Double(baseChars),
                                                                    count: count)]).suffix(60))
        }
        Benchmark.saved = saved
        Tally.add("bench.lines", count)
    }

    /// あなた向けのモデルの材料（手で直した行と、答え合わせで答えた行）を、家の PC に渡す（PC の版 4 から）。
    /// 1晩に40個まで。渡したものは覚えておき、2度は渡さない。音声は PC にだけ渡す。
    func sendPersonalSamples(limit: Int = 40) async {
        guard homePC.shouldTry, (homePC.version ?? 0) >= 4 else { return }
        let key = "personalSent"
        var sent = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        var material: [(audio: String, start: TimeInterval, end: TimeInterval, text: String)] = []
        for s in answerKey.samples where s.isAnswered && s.skipped != true {
            guard let right = s.rightText?.trimmingCharacters(in: .whitespaces), right.count >= 2 else { continue }
            let span = Benchmark.span(offset: s.offset, chars: right.count)
            material.append((s.audio, span.start, span.end, right))
        }
        for day in recordedDays().prefix(30) {
            for c in conversations(on: day) {
                for line in c.lines where line.checked == true && line.media == nil {
                    guard let audio = line.audio, let offset = line.offset, line.text.count >= 2 else { continue }
                    let span = Benchmark.span(offset: offset, chars: line.text.count)
                    material.append((audio, span.start, line.end ?? span.end, line.text))
                }
            }
        }
        var done = 0
        for m in material where done < limit {
            let id = m.audio + "|" + String(format: "%.1f", m.start) + "|" + m.text
            guard !sent.contains(id), let url = await archive.playableURL(for: m.audio) else { continue }
            guard (try? await homePC.sendTrainSample(url, start: m.start, end: m.end, text: m.text)) != nil else { break }
            sent.insert(id)
            done += 1
        }
        if done > 0 {
            UserDefaults.standard.set(Array(Array(sent).suffix(6000)), forKey: key)
            Tally.add("personal.sent", done)
        }
        if let status = try? await homePC.trainStatus() {
            UserDefaults.standard.set(status.count, forKey: "personalCount")
            UserDefaults.standard.set(status.model, forKey: "personalModel")
        }
    }
}

import AVFoundation
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
            // 先頭のほうでどの区間にも入らない言葉は、最初に分かった人にする（見直しで直した）
            if let k = who.firstIndex(where: { $0 != nil }) { for i in 0..<k { who[i] = who[k] } }
            for i in who.indices where who[i] == nil && i > 0 { who[i] = who[i - 1] }
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
        /// 言葉を登録の順のまま渡す（2026-11-10 より前の渡し方。「いま出そうな順」と見比べる。WordHeat.swift）
        case registeredOrder

        var label: String {
            switch self {
            case .enhance: "雑音を消した音もいつも聞く"
            case .noWeights: "多数決の重みを使わない"
            case .noHints: "言葉のヒントを渡さない"
            case .registeredOrder: "言葉を登録の順で渡す（前の渡し方）"
            }
        }
    }

    /// 今夜試す設定。言葉の並べ方は新しいので、30問たまるまでは1晩おきに試す（悪ければ早く元に戻すため。2026-11-10）
    static func variant(night: Int, available: [Variant], scores: [String: Score]) -> Variant? {
        guard !available.isEmpty else { return nil }
        guard available.contains(.registeredOrder),
              (scores[Variant.registeredOrder.rawValue]?.count ?? 0) < need else {
            return available[night % available.count]
        }
        if night % 2 == 0 { return .registeredOrder }
        let rest = available.filter { $0 != .registeredOrder }
        return rest.isEmpty ? .registeredOrder : rest[(night / 2) % rest.count]
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
        /// 直しの言語モデルの比べ（試すモデル → 今のモデルとの誤りの数。2026-11-06）
        var correction: [String: Score] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scores = try c.decodeIfPresent([String: Score].self, forKey: .scores) ?? [:]
            history = try c.decodeIfPresent([Point].self, forKey: .history) ?? []
            night = try c.decodeIfPresent(Int.self, forKey: .night) ?? 0
            correction = try c.decodeIfPresent([String: Score].self, forKey: .correction) ?? [:]
        }
    }

    struct Point: Codable, Equatable {
        let day: Date
        let rate: Double
        let count: Int
        /// 職場の行だけの誤りの割合と問の数（2026-11-10。前の記録には無い）
        var workRate: Double? = nil
        var workCount: Int? = nil
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

    /// 職場の行だけの誤りの行（答えの分かっている職場の行を測った夜が無ければ nil）
    static func workRow(_ history: [Point]) -> (label: String, value: String, ok: Bool?)? {
        let work = history.suffix(14).filter { ($0.workCount ?? 0) > 0 && $0.workRate != nil }
        guard let last = work.last, let rate = last.workRate else { return nil }
        let mean = work.compactMap(\.workRate).reduce(0, +) / Double(work.count)
        return (label: "仕事の行の文字の誤り", value: String(format: "%.1f%%（最後・%d 問）・仕事の行を測った直近 %d 回の平均 %.1f%%",
                                                       rate * 100, last.workCount ?? 0, work.count, mean * 100), ok: nil)
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
        // 職場の行だけの誤り（2026-11-10。答えの分かっている職場の行があった夜だけ）
        if let row = workRow(s.history) { rows.append(row) }
        for v in Variant.allCases {
            guard let score = s.scores[v.rawValue], score.chars > 0 else { continue }
            let base = Double(score.baseErrors) / Double(score.chars) * 100
            let variant = Double(score.variantErrors) / Double(score.chars) * 100
            let decided = decision(score)
            rows.append((v.label, String(format: "誤り %.1f%% → %.1f%%（%d 問）", base, variant, score.count)
                + (decided == true ? "・使う" : decided == false ? "・使わない" : "・まだ決めない"), nil))
        }
        // 直しの言語モデル（2026-11-06）
        rows.append(("直しの言語モデル", Summarizer.correctionModel, nil))
        for model in s.correction.keys.sorted() {
            guard let score = s.correction[model], score.chars > 0 else { continue }
            let base = Double(score.baseErrors) / Double(score.chars) * 100
            let other = Double(score.variantErrors) / Double(score.chars) * 100
            rows.append(("比べたモデル " + model, String(format: "直したあとの誤り 今 %.1f%% → %.1f%%（%d 問）", base, other, score.count), nil))
        }
        return rows
    }
}

extension Pipeline {
    /// 手で直した行（直近30日）を、正しい文が分かっている行として集める（重みと精度の物差しの材料。2026-11-06）
    func manualTruths(days: Int = 30) -> [AnswerKey.Truth] {
        var out: [AnswerKey.Truth] = []
        for day in recordedDays().prefix(days) {
            for c in conversations(on: day) {
                for line in c.lines where line.checked == true && line.media == nil {
                    guard let audio = line.audio, let offset = line.offset,
                          line.text.trimmingCharacters(in: .whitespaces).count >= 2 else { continue }
                    out.append(AnswerKey.Truth(right: line.text, votes: line.votes, noisy: line.noisy == true,
                                               audio: audio, offset: offset, end: line.end, time: line.time))
                }
            }
        }
        return out
    }

    /// 音声の一部だけを切り出して PC に送る（5分の音声を丸ごと送らない。2026-11-06）。
    /// 切り出せなければ元の音声のまま。返すのは送るファイル・区間のずれ・あとで消す一時ファイル
    private func clipped(_ url: URL, start: TimeInterval, end: TimeInterval) async -> (url: URL, shift: TimeInterval, temp: URL?) {
        let from = max(0, start - 1)
        if let clip = await AudioClip.extract(url, from: from, to: end + 1) { return (clip, from, clip) }
        return (url, 0, nil)
    }

    /// 精度の物差しを1晩分動かす（夜の聞き直しのあと。家の PC につながるときだけ）。
    /// 正しい文が分かっている行（答え合わせの答えと手で直した行）を limit 個（夜ごとにずらす）、
    /// 今の設定と、夜ごとに回す試す設定の両方で文字にし直して比べる。直しの言語モデルも同じ行で比べる。
    func measureAccuracy(limit: Int = 12) async {
        guard homePC.shouldTry else { return }
        _ = try? await homePC.hello()
        guard homePC.engineCount > 1 || homePC.features.contains("vad") else { return }
        let truths = (answerKey.answeredTruths + manualTruths()).sorted { ($0.time, $0.offset) < ($1.time, $1.offset) }
        guard !truths.isEmpty else { return }
        var saved = Benchmark.saved
        let night = saved.night
        saved.night += 1
        let variants = Benchmark.Variant.allCases.filter { $0 != .enhance || homePC.features.contains("enhance") }
        let variant = Benchmark.variant(night: night, available: variants, scores: saved.scores)
        // いまの言葉の渡し方（登録の順に戻っているか）と、家の PC に渡せる言葉の数
        let usingRegistered = UserDefaults.standard.bool(forKey: Self.registeredOrderKey)
        let hintLimit = HomePC.hintLimit(speed: homePC.speed)
        let first = (night * limit) % truths.count
        let picks = (0..<min(limit, truths.count)).map { truths[(first + $0) % truths.count] }
        var baseErrors = 0, baseChars = 0, count = 0
        var workErrors = 0, workChars = 0, workCount = 0
        var score = variant.flatMap { saved.scores[$0.rawValue] } ?? Benchmark.Score()
        var heardTexts: [(heard: String, right: String, context: SpeakerLabeler.Context)] = []
        for truth in picks {
            guard let url = await archive.playableURL(for: truth.audio) else { continue }
            let span = Benchmark.span(offset: truth.offset, chars: truth.right.count)
            let end = truth.end.map { max($0, span.start + 0.5) } ?? span.end
            let clip = await clipped(url, start: span.start, end: end)
            defer { if let temp = clip.temp { try? FileManager.default.removeItem(at: temp) } }
            let segment = (start: span.start - clip.shift, end: end - clip.shift)
            let context = vocabularyContext(at: truth.time)
            // 言葉は、登録の順と「いま出そうな順」の両方を作っておく（いま使っているほうが「今の設定」）
            let registered = registeredWords(for: context)
            let fresh = heatOrdered(registered, context: context)
            let hints = usingRegistered ? registered : fresh
            func listen(_ v: Benchmark.Variant?, _ words: [String]) async -> String? {
                guard let lines = try? await homePC.transcribe(
                    clip.url, segments: [segment], hints: v == .noHints ? [] : words, noisy: truth.noisy,
                    enhance: v == .enhance ? true : nil, weights: v == .noWeights ? false : nil, unionVAD: false) else { return nil }
                return lines.filter { $0.offset >= segment.start - 0.5 && $0.offset <= segment.end }.map(\.text).joined()
            }
            guard let base = await listen(nil, hints) else { continue }
            let b = Benchmark.errors(base, right: truth.right)
            baseErrors += b.errors
            baseChars += b.chars
            count += 1
            if context == .work {
                workErrors += b.errors
                workChars += b.chars
                workCount += 1
            }
            heardTexts.append((base, truth.right, context))
            guard let variant else { continue }
            if variant == .registeredOrder {
                // 言葉の並べ方の見比べ。PC に渡る枠が同じなら、答えも同じなので比べない
                guard HintOrder.window(registered, limit: hintLimit) != HintOrder.window(fresh, limit: hintLimit) else { continue }
                guard let other = await listen(nil, usingRegistered ? fresh : registered) else { continue }
                let o = Benchmark.errors(other, right: truth.right)
                // 「今の設定」の側はいつも「いま出そうな順」、「試す設定」の側はいつも登録の順として数える
                score.baseErrors += usingRegistered ? o.errors : b.errors
                score.variantErrors += usingRegistered ? b.errors : o.errors
                score.chars += b.chars
                score.count += 1
                score.last = .now
            } else if let other = await listen(variant, hints) {
                let o = Benchmark.errors(other, right: truth.right)
                score.baseErrors += b.errors
                score.variantErrors += o.errors
                score.chars += b.chars
                score.count += 1
                score.last = .now
            }
        }
        if let variant, score.count > 0 {
            saved.scores[variant.rawValue] = score
            // 雑音を消した音・重み・言葉の並べ方は、数で決まったら自動で使う・やめる（言葉のヒントを渡さないのは測るだけ）。
            // 並べ方は、登録の順のほうが1割以上良ければ登録の順に戻し、悪ければ「いま出そうな順」のまま（Pipeline.registeredOrderKey）
            if variant != .noHints, let use = Benchmark.decision(score) {
                UserDefaults.standard.set(use, forKey: "benchAdopt." + variant.rawValue)
            }
        }
        if count > 0, baseChars > 0 {
            var point = Benchmark.Point(day: .now, rate: Double(baseErrors) / Double(baseChars), count: count)
            if workCount > 0, workChars > 0 {
                point.workRate = Double(workErrors) / Double(workChars)
                point.workCount = workCount
            }
            saved.history = Array((saved.history + [point]).suffix(60))
        }
        Benchmark.saved = saved
        Tally.add("bench.lines", count)
        await measureCorrection(heardTexts)
    }

    /// 直しの言語モデルを物差しで比べる（2026-11-06）。PC が書いた文を、今の直しのモデルと、夜ごとに回す別のモデルで直し、
    /// 直す前より誤りが減ったかを数える。30問以上で、別のモデルが1割以上良ければ、直しにそのモデルを使う。
    /// 職場の会話の行は Groq に送らない（ふだんの直しと同じ決まり）。
    private func measureCorrection(_ items: [(heard: String, right: String, context: SpeakerLabeler.Context)]) async {
        // Groq のキーだけ（ほかのサービスのキーを Groq に送らない）。端末内のモデルで作る設定のときは比べない（見直しで直した）
        guard let key = settings.groqKey, !Summarizer.usesLocal(apiKey: key) else { return }
        let usable = items.filter { $0.context != .work }
        guard !usable.isEmpty else { return }
        let available = await Summarizer.availableModels(apiKey: key)
        // 使っているモデルが Groq から無くなっていたら、初めのモデルに戻す
        if !available.isEmpty, !available.contains(Summarizer.correctionModel) {
            UserDefaults.standard.removeObject(forKey: Summarizer.correctionModelKey)
        }
        let current = Summarizer.correctionModel
        let others = Summarizer.correctionCandidates.filter { $0 != current && (available.isEmpty || available.contains($0)) }
        var saved = Benchmark.saved
        let night = saved.night
        guard !others.isEmpty else { return }
        let trial = others[night % others.count]
        var score = saved.correction[trial] ?? Benchmark.Score()
        for item in usable {
            // どちらも Groq のそのモデルで作れたときだけ数える（失敗して端末内のモデルに回ったものは数えない）
            func fix(_ model: String) async -> String? {
                try? await Summarizer.$strictCloud.withValue(true) {
                    try await Summarizer.$modelOverride.withValue(model) {
                        try await Summarizer.correct([item.heard], keywords: [], previous: nil, alternatives: nil, apiKey: key)
                    }
                }?.first
            }
            guard let mine = await fix(current), let theirs = await fix(trial) else { continue }
            let a = Benchmark.errors(mine.isEmpty ? item.heard : mine, right: item.right)
            let b = Benchmark.errors(theirs.isEmpty ? item.heard : theirs, right: item.right)
            score.baseErrors += a.errors
            score.variantErrors += b.errors
            score.chars += a.chars
            score.count += 1
            score.last = .now
        }
        saved.correction[trial] = score
        Benchmark.saved = saved
        if Benchmark.decision(score) == true {
            UserDefaults.standard.set(trial, forKey: Summarizer.correctionModelKey)
            saved.correction = [:]
            Benchmark.saved = saved
            Tally.add("learn.updated")
        }
    }

    /// あなた向けのモデルの材料（手で直した行と、答え合わせで答えた行と、「聞いて直す」で「合っている」と答えた行）を、
    /// 家の PC に渡す（PC の版 4 から）。1晩に40個まで。渡したものは覚えておき、2度は渡さない。音声はその行の所だけ切り出して PC にだけ渡す。
    func sendPersonalSamples(limit: Int = 40) async {
        guard homePC.shouldTry, (homePC.version ?? 0) >= 4 else { return }
        let key = PersonalMaterial.sentKey
        var sent = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        var done = 0
        var refused = 0
        // 「聞いて直す」で「合っている」と答えた行も、答え合わせの答えと同じく材料にする（2026-11-07。ReviewNudge.swift）。
        // 「聞いて直す」で直した行は、手で直した行として manualTruths に入る
        for t in answerKey.answeredTruths + manualTruths() + reviewNudgeTruths() where done < limit {
            let span = Benchmark.span(offset: t.offset, chars: t.right.count)
            let end = t.end ?? span.end
            let id = PersonalMaterial.sampleID(audio: t.audio, offset: t.offset, right: t.right)
            guard !sent.contains(id) else { continue }
            // PC が受け付けない長さ（0.3秒より短い・30秒より長い）は送らない
            guard end - span.start >= 0.3, end - span.start <= 30 else { continue }
            // 「聞いて直す」で答えた行は、答えたときに切り出して残した音を使う（iPhone の中の音声が26時間で消えていても送れる）
            let source: (url: URL, shift: TimeInterval, temp: URL?)
            if let kept = reviewNudgeClip(audio: t.audio, offset: t.offset), kept.from <= span.start + 0.05, kept.to >= end - 0.05 {
                source = (kept.url, kept.from, nil)
            } else {
                guard let url = await archive.playableURL(for: t.audio) else { continue }
                source = await clipped(url, start: span.start, end: end)
            }
            defer { if let temp = source.temp { try? FileManager.default.removeItem(at: temp) } }
            // 行の音声の名前と位置も付ける（PC の画面で直した行と2重にしないため。2026-11-07）
            do {
                _ = try await homePC.sendTrainSample(source.url, start: span.start - source.shift, end: end - source.shift,
                                                     text: t.right, audio: t.audio, offset: t.offset)
                sent.insert(id)
                done += 1
            } catch is HomePC.SampleRefused {
                // PC がこの材料を受け付けなかった（声が短すぎる など）。毎晩ここで止まらないよう、渡したものとして先へ進む
                sent.insert(id)
                refused += 1
            } catch {
                // つながらない・PC の調子が悪いときは、続きを次の夜に
                break
            }
        }
        if done + refused > 0 {
            UserDefaults.standard.set(Array(Array(sent).suffix(6000)), forKey: key)
            Tally.add("personal.sent", done)
            Tally.add("personal.refused", refused)
        }
        // PC にたまった数と、学び直しに要る数を覚える（「聞いて直す」の画面と自己点検に出す。2026-11-07）
        await refreshPersonalCount()
    }
}

extension Pipeline {
    /// もう1台のマイクの票（2026-11-06）。同じ時間に、もう片方の端末（iPhone なら時計、時計なら iPhone）で録った区切りが
    /// 手元にあれば、食い違いの大きい行の所をその音声でも PC で文字にし、もう1票として選び直す。
    func addOtherMicVotes(_ lines: [HomePC.Line], audio url: URL, hints: [String]) async -> [HomePC.Line] {
        let unsure = lines.indices.filter { (lines[$0].confidence ?? 1) < HomePC.cloudVoteBelow && !lines[$0].votes.isEmpty }
        guard !unsure.isEmpty, !Storage.isImported(url), let start = Storage.startDate(of: url) else { return lines }
        let fromWatch = Storage.isFromWatch(url)
        // 区切りが短いと、同じ時間の区切りが向こうにいくつもあるので、食い違った行をいちばん多く含むものを使う（2026-11-07）
        var best: (other: URL, shift: TimeInterval, targets: [Int])?
        for other in AudioClip.otherMicCandidates(for: url, start: start, fromWatch: fromWatch, in: Storage.keptAudio()).prefix(4) {
            guard let otherStart = Storage.startDate(of: other) else { continue }
            // もう片方の音声の中の時刻 = この音声の中の時刻 - shift
            let shift = otherStart.timeIntervalSince(start)
            let length = AudioClip.duration(of: other)
            let inside = unsure.filter { lines[$0].offset - shift >= 0 && lines[$0].end - shift <= length + 0.5 }
            if inside.count > (best?.targets.count ?? 0) { best = (other, shift, inside) }
        }
        guard let chosen = best else { return lines }
        let other = chosen.other, shift = chosen.shift, targets = chosen.targets
        guard let lo = targets.map({ lines[$0].offset - shift }).min(),
              let hi = targets.map({ lines[$0].end - shift }).max() else { return lines }
        let clip = await clipped(other, start: lo, end: hi)
        defer { if let temp = clip.temp { try? FileManager.default.removeItem(at: temp) } }
        let move = shift + clip.shift
        guard let heard = try? await homePC.transcribe(
            clip.url, segments: targets.map { (start: max(0, lines[$0].offset - move), end: lines[$0].end - move) },
            hints: hints, unionVAD: false) else { return lines }
        var out = lines
        var added = 0
        for i in targets {
            let s = lines[i].offset - move, e = lines[i].end - move
            let text = heard.filter { $0.offset >= s - 0.5 && $0.offset < e + 0.3 }.map(\.text).joined()
            guard !text.isEmpty else { continue }
            var votes = out[i].votes
            votes["othermic"] = text
            out[i] = HomePC.revote(out[i], votes: votes)
            added += 1
        }
        Tally.add("othermic.lines", added)
        return out
    }
}

/// 音声の一部を切り出す（2026-11-06）
enum AudioClip {
    /// 音声の長さ（秒）。読めなければ 0
    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// 同じ時間に、もう片方の端末で録った区切り（始まりが5分半以内のもの。取り込んだ音声は除く）
    static func otherMic(for url: URL, start: Date, fromWatch: Bool, in kept: [URL]) -> URL? {
        otherMicCandidates(for: url, start: start, fromWatch: fromWatch, in: kept).first
    }

    /// 同じ時間に、もう片方の端末で録った区切りを、始まりが近い順に（2026-11-07）
    static func otherMicCandidates(for url: URL, start: Date, fromWatch: Bool, in kept: [URL]) -> [URL] {
        kept.filter { o in
            Storage.isFromWatch(o) != fromWatch && !Storage.isImported(o) && o.lastPathComponent != url.lastPathComponent
                && (Storage.startDate(of: o).map { abs($0.timeIntervalSince(start)) < 330 } ?? false)
        }.sorted { a, b in
            abs((Storage.startDate(of: a) ?? .distantPast).timeIntervalSince(start))
                < abs((Storage.startDate(of: b) ?? .distantPast).timeIntervalSince(start))
        }
    }

    /// from〜to 秒を切り出した一時ファイル（m4a・中身はそのまま）。できなければ nil
    static func extract(_ url: URL, from: TimeInterval, to: TimeInterval) async -> URL? {
        guard to > from else { return nil }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).m4a")
        export.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                       end: CMTime(seconds: to, preferredTimescale: 600))
        do {
            try await export.export(to: out, as: .m4a)
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
    }
}

/// 家の PC がまだ文字にしている区切り（次の機会に回す。2026-11-07）
struct PCJobDeferred: Error {}

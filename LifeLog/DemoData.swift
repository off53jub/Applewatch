#if DEBUG && targetEnvironment(simulator)
import Foundation

/// 画面の自動確認（CI の UI テスト）用の見本の記録（2026-11-06）。
/// シミュレーターで、起動の引数に -screenshotDemo があるときだけ、アプリの中に作り物の記録を書く。
/// 配る IPA（Release・実機）にはこのファイルごと入らない。人の名前・会話・頼まれごとは、すべて作り物。
enum DemoData {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotDemo") }

    private struct People: Encodable {
        let people: [SpeakerLabeler.Person]
        let nextID: Int
    }

    static func install() {
        let base = URL.applicationSupportDirectory
        let days = base.appendingPathComponent("days", isDirectory: true)
        try? FileManager.default.createDirectory(at: days, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        let first = max(midnight.addingTimeInterval(120), now.addingTimeInterval(-3 * 3600))
        let encoder = JSONEncoder()

        typealias Line = ConversationLog.Line
        func line(_ t: Date, _ who: String, _ id: String, _ text: String, confidence: Double? = 0.9) -> Line {
            var l = Line(time: t, speaker: who, text: text)
            l.speakerID = id
            l.confidence = confidence
            return l
        }
        let a = first, b = first.addingTimeInterval(3600), c = now.addingTimeInterval(-120)
        var talk1 = ConversationLog.Conversation(start: a, end: a.addingTimeInterval(240), docIndex: 1)
        talk1.lines = [
            line(a, "自分", "me", "おはようございます。今日の見本の資料はできていますか。"),
            line(a.addingTimeInterval(8), "見本 花子", "3", "はい、お昼までに送ります。"),
            line(a.addingTimeInterval(20), "自分", "me", "ありがとうございます。会議は3時からです。"),
            line(a.addingTimeInterval(31), "見本 花子", "3", "会議室も取っておきますね。", confidence: 0.3),
        ]
        talk1.title = "朝の打ち合わせ（見本）"
        talk1.points = ["資料はお昼までに送る", "会議は15時から"]
        talk1.place = "見本の職場"
        talk1.closed = true
        talk1.rev = 1
        talk1.scene = "職場"
        var talk2 = ConversationLog.Conversation(start: b, end: b.addingTimeInterval(180), docIndex: 2)
        var noisy = line(b.addingTimeInterval(5), "人物12", "12", "次の駅で降ります。", confidence: 0.4)
        noisy.noisy = true
        noisy.votes = ["haas": "次の駅で降ります。", "reazon": "次の駅で振ります。"]
        talk2.lines = [line(b, "自分", "me", "今どこですか。"), noisy]
        talk2.title = "電車で（見本）"
        talk2.closed = true
        talk2.rev = 1
        talk2.scene = "電車"
        var talk3 = ConversationLog.Conversation(start: c, end: c.addingTimeInterval(60), docIndex: 3)
        talk3.lines = [line(c, "自分", "me", "これは今続いている会話の見本です。")]
        let day = ConversationLog.Day(conversations: [talk1, talk2, talk3])
        if let data = try? encoder.encode(day) {
            try? data.write(to: days.appendingPathComponent(f.string(from: now) + ".json"), options: .atomic)
        }

        let people = People(people: [
            SpeakerLabeler.Person(id: SpeakerLabeler.selfID, name: nil, context: nil, voices: [], seconds: 600, lastHeard: now,
                                  samples: [], updated: nil, hidden: nil),
            SpeakerLabeler.Person(id: "3", name: "見本 花子", context: .work, voices: [], seconds: 300, lastHeard: a,
                                  samples: [], updated: now, hidden: nil),
            SpeakerLabeler.Person(id: "12", name: nil, context: nil, voices: [], seconds: 40, lastHeard: b,
                                  samples: [], updated: nil, hidden: nil),
            SpeakerLabeler.Person(id: "15", name: nil, context: nil, voices: [], seconds: 20, lastHeard: b,
                                  samples: [], updated: nil, hidden: nil),
        ], nextID: 16)
        if let data = try? encoder.encode(people) {
            try? data.write(to: base.appendingPathComponent("people.json"), options: .atomic)
        }

        var t1 = TaskBook.Item(what: "見本の資料を送る", said: a, source: .conversation, state: .candidate, work: true)
        t1.agreed = true
        t1.quote = "お昼までに送ります"
        var t2 = TaskBook.Item(what: "会議室を取る", said: a, source: .conversation, state: .candidate, work: true)
        t2.agreed = false
        var t3 = TaskBook.Item(what: "見積もりを確かめる（見本）", said: a, source: .manual, state: .open, work: true)
        t3.due = midnight.addingTimeInterval(86400 + 17 * 3600)
        if let data = try? encoder.encode([t1, t2, t3]) {
            try? data.write(to: base.appendingPathComponent("tasks.json"), options: .atomic)
        }
        installHomeFeeds(base: base, now: now, day: f.string(from: now),
                         yesterday: f.string(from: now.addingTimeInterval(-86400)), talk: talk1, talkEnd: b)
        installAccuracy(base: base, now: now, day: f.string(from: now), talk: talk1, noisyLine: noisy)
        installMothershipFeeds(base: base, now: now, day: f.string(from: now),
                               yesterday: f.string(from: now.addingTimeInterval(-86400)))
        // 効き目の数の見本
        Tally.add("fix.proposed", 6)
        Tally.add("fix.kept", 4)
        Tally.add("fix.dropped", 2)
        Tally.add("second.ran", 3)
        Tally.add("task.agreed", 1)
        Tally.add("task.alone", 1)
    }

    /// 家の PC から読んだことにする写し（提案・PLAUD で埋めた所・話し手の疑い・職場の自分の声の候補。2026-11-13）。
    /// 名前・お店・言葉はすべて作り物。ファイルの名前は HomeFeedsBook・AppFeedsBook と同じ
    private static func installHomeFeeds(base: URL, now: Date, day: String, yesterday: String,
                                         talk: ConversationLog.Conversation, talkEnd: Date) {
        let iso = ISO8601DateFormatter()
        let encoder = JSONEncoder()
        func write<T: Encodable>(_ value: T, _ name: String) {
            if let data = try? encoder.encode(value) { try? data.write(to: base.appendingPathComponent(name), options: .atomic) }
        }
        let a = talk.start
        let proposals = ProposalFeed(generated_at: iso.string(from: now), items: [
            Proposal(id: "demo-p1", kind: "followup", title: "見本の資料の返事を確かめる",
                     body: "朝の打ち合わせで「お昼までに送ります」と言われた資料が、まだ届いていないかもしれません。",
                     evidence: [Proposal.Evidence(text: "はい、お昼までに送ります。", when: iso.string(from: a.addingTimeInterval(8)), source: "conversation")],
                     action: Proposal.Action(type: "task", text: "見本の資料が届いたか確かめる"),
                     created: iso.string(from: now.addingTimeInterval(-600))),
            Proposal(id: "demo-p2", kind: "place", title: "この時間のお店は「見本の餃子屋」かも",
                     body: "LINE で決めていたお店と、会話の中身から、行ったお店はこちらかもしれません。",
                     evidence: [Proposal.Evidence(text: "見本の餃子屋に7時で", when: iso.string(from: a.addingTimeInterval(-86400)), source: "line")],
                     action: Proposal.Action(type: "place", text: "見本の餃子屋", day: day, conversation_start: iso.string(from: a)),
                     created: iso.string(from: now.addingTimeInterval(-1200))),
            Proposal(id: "demo-p3", kind: "vocab", title: "「見本商事」を言葉の登録に",
                     body: "この1週間に何度も出てきましたが、まだ登録していない言葉です。",
                     evidence: [Proposal.Evidence(text: "7日で5回", source: "stats")],
                     action: Proposal.Action(type: "vocab", text: "見本商事", reading: "みほんしょうじ"),
                     created: iso.string(from: now.addingTimeInterval(-1800))),
        ])
        write(proposals, "app-feed-proposals.json")
        let gapStart = talk.end.addingTimeInterval(300)
        func span(_ start: Date, _ texts: [String]) -> PlaudFillDay.Span {
            let lines = texts.enumerated().map { i, t in
                PlaudFillDay.Line(time: iso.string(from: start.addingTimeInterval(Double(i) * 12)), speaker: i % 2 == 0 ? "話者1" : "話者2", text: t)
            }
            return PlaudFillDay.Span(start: iso.string(from: start), end: iso.string(from: start.addingTimeInterval(600)), lines: lines)
        }
        let fill = PlaudFillFeed(generated_at: iso.string(from: now), days: [
            PlaudFillDay(day: day, ranges: [span(gapStart, ["これは PLAUD の文字の見本です。", "アプリの記録が無い時間の分です。",
                                                             "読むだけで、記録には入りません。", "四つ目の行の見本です。"])]),
            PlaudFillDay(day: yesterday, ranges: [span(now.addingTimeInterval(-86400 - 3600), ["きのうの PLAUD だけの見本です。"])]),
        ])
        write(fill, "app-feed-plaudfill.json")
        var doubts = SpeakerDoubtFeed(generated_at: iso.string(from: now), items: [
            SpeakerDoubt(day: day, conversation_start: iso.string(from: a), line_time: iso.string(from: a.addingTimeInterval(8)),
                         text_head: "はい、お昼までに送ります。", current: "見本 花子", suggest: "self", why: "plaud-turn", score: 0.8),
            SpeakerDoubt(day: day, conversation_start: iso.string(from: talkEnd), line_time: iso.string(from: talkEnd),
                         text_head: "今どこですか。", current: "自分", suggest: "other", why: "text", score: 0.5),
            SpeakerDoubt(day: day, conversation_start: iso.string(from: a), line_time: iso.string(from: a.addingTimeInterval(31)),
                         text_head: "会議室も取っておきますね。", current: "見本 花子", suggest: "self", why: "night", score: 0.55),
        ])
        // まとめて OK の見本（施策 14）: 1つ目の疑いに母艦の印
        doubts.items[0].sure = true
        doubts.items[0].sure_why = "PLAUD の区切りと声が両方合う"
        write(doubts, "app-feed-spkdoubt.json")
        var candidates: [SelfCandidate] = []
        for i in 1...12 {
            let start: Double = Double(i * 20)
            let score: Double = 1.0 - Double(i) / 20.0
            let why: String = i % 3 == 0 ? "plaud-most-talk" : "plaud-match"
            var candidate = SelfCandidate(id: "demo-c\(i)", day: day, audio: "demo.m4a", start: start, end: start + 6,
                                          text: "職場の見本の発言 \(i)", score: score, why: why)
            if i <= 3 {
                candidate.sure = true
                candidate.sure_why = "PLAUD の文とよく合う"
            }
            candidates.append(candidate)
        }
        write(SelfCandidateFeed(available: true, generated_at: iso.string(from: now), items: candidates), "app-feed-selfcand.json")
    }

    private struct DemoMisheard: Encodable {
        let suspects: [MisheardBox.Suspect]
        let checked: [String: Date]
        let kept: [String]
    }

    /// 同じ人かも・夜の読み直しの聞き間違い・言葉の候補のまとめて OK（施策 9・10・14。2026-11-13）。名前・言葉はすべて作り物
    private static func installAccuracy(base: URL, now: Date, day: String, talk: ConversationLog.Conversation,
                                        noisyLine: ConversationLog.Line) {
        let iso = ISO8601DateFormatter()
        let encoder = JSONEncoder()
        var members: [SamePersonGroup.Member] = []
        let ids: [String] = ["12", "15"]
        for (i, id) in ids.enumerated() {
            let sample = SamePersonGroup.Sample(time: iso.string(from: noisyLine.time), text: i == 0 ? "次の駅で降ります。" : "見本の短い返事です。",
                                                audio: "demo.m4a", start: Double(i * 5), end: Double(i * 5 + 3))
            let lines: Int = i == 0 ? 12 : 4
            members.append(SamePersonGroup.Member(id: id, name: "人物" + id, lines: lines, seconds: Double(lines * 3), samples: [sample]))
        }
        let groups: [SamePersonGroup] = [SamePersonGroup(id: "sp-demo-1", day: day, score: 0.74, people: members)]
        if let data = try? encoder.encode(SamePersonFeed(generated_at: iso.string(from: now), groups: groups)) {
            try? data.write(to: base.appendingPathComponent(SamePersonBook.file), options: .atomic)
        }
        // 夜の読み直しから来た聞き間違いの候補（「聞き間違いかも」に入っている形）
        guard let first = talk.lines.last else { return }
        var suspect = MisheardBox.Suspect(wrong: "会議室", guess: "第一会議室", reason: NightReviewRules.reasonHead + "：見本の理由",
                                          refs: [MisheardBox.Ref(day: day, time: first.time, text: first.text)], found: now)
        suspect.night = "nr-demo-1"
        if let data = try? encoder.encode(DemoMisheard(suspects: [suspect], checked: [:], kept: [])) {
            try? data.write(to: base.appendingPathComponent("misheard.json"), options: .atomic)
        }
        // 言葉の候補（母艦の辞書から）。2つに母艦の印
        var words: [WordCandidate] = []
        let texts: [String] = ["見本商事", "見本工業", "見本駅"]
        for (i, text) in texts.enumerated() {
            var w = WordCandidate(word: text, category: i == 2 ? "地名" : "社名", count: 5 - i, last: day)
            if i < 2 {
                w.sure = true
                w.sure_why = "何度も出て、書き方がそろっている"
            }
            words.append(w)
        }
        let saved = WordCandidateBook.Saved(items: words, generatedAt: iso.string(from: now), fetchedAt: now, dismissed: [])
        if let data = try? encoder.encode(saved) {
            try? data.write(to: base.appendingPathComponent("word-candidates.json"), options: .atomic)
        }
    }

    /// 母艦から読んだことにする写し（週のふり返り・見立ての台帳・会う前の一枚・朝のまとめの比べ・精度の通信簿・
    /// あまり開かれていない画面。2026-11-13。MothershipFeeds.swift）。人・会話・言葉はすべて作り物。
    /// 長いクロージャの式は型を決めるのに時間がかかって CI が落ちるので、明示的なループと型で書く
    private static func installMothershipFeeds(base: URL, now: Date, day: String, yesterday: String) {
        let iso = ISO8601DateFormatter()
        let encoder = JSONEncoder()
        func write<T: Encodable>(_ value: T, _ name: String) {
            if let data = try? encoder.encode(value) { try? data.write(to: base.appendingPathComponent(name), options: .atomic) }
        }
        // 週のふり返り（3つ）と見立ての台帳
        var weekly = WeeklyFeed(generated_at: iso.string(from: now))
        weekly.week = "2026-W46"
        weekly.from = yesterday
        weekly.to = day
        let kinds: [String] = ["theme", "stuck", "change"]
        let titles: [String] = ["見本の資料の話が3回出た", "会議室の予約が進んでいない", "先週より電車の会話が増えた"]
        let bodies: [String] = ["打ち合わせのたびに、見本の資料の締め切りの話になっています。",
                                "「取っておきますね」と言われたまま、まだ決まっていないようです。",
                                "移動中の短い会話が、先週の倍ほどありました。"]
        for i in 0..<3 {
            let evidence = WeeklyFeed.Evidence(day: day, source: "conversation", quote: "見本の引用 \(i + 1)")
            weekly.items.append(WeeklyFeed.Item(id: "demo-w\(i + 1)", kind: kinds[i], title: titles[i], body: bodies[i],
                                                evidence: [evidence]))
        }
        let statuses: [String] = ["alive", "weakened", "confirmed", "unknown"]
        let thoughts: [String] = ["朝に資料を作ると早く終わる（見本）", "会議は短い方が決まる（見本）",
                                  "電車では話さない方が疲れない（見本）", "週の初めは返事が遅い（見本）"]
        for i in 0..<4 {
            weekly.hypotheses.append(WeeklyFeed.Hypothesis(id: "demo-h\(i + 1)", text: thoughts[i], said_on: yesterday,
                                                           status: statuses[i], note: "見本の照らし合わせ", checked_on: day))
        }
        var feedback = WeeklyFeed.Feedback()
        feedback.today_three = WeeklyFeed.Feedback.Three(done: 4, skipped: 1, unknown: 2)
        feedback.proposal = WeeklyFeed.Feedback.Answers(accept: 2, later: 1, never: 0)
        feedback.brief_read = 5
        weekly.feedback = feedback
        write(weekly, "mfeed-weekly.json")
        // 会う前の一枚（1時間後に始まる見本の予定）
        let start: Date = now.addingTimeInterval(3600)
        var prep = PrepItem(id: "demo-e1", start: iso.string(from: start), end: iso.string(from: start.addingTimeInterval(1800)),
                            title: "見本の打ち合わせ")
        prep.people = ["見本 花子"]
        prep.last_talk = PrepItem.LastTalk(day: yesterday, summary: "資料はお昼までに送る、と話しました（見本）。")
        prep.promises = ["見本の資料を送る"]
        prep.recent = ["会議室を探している（見本）"]
        write(PrepFeed(generated_at: iso.string(from: now), items: [prep]), "mfeed-prep.json")
        // 朝のまとめの比べ（2日）
        var days: [BriefCompareDay] = []
        let compareDays: [String] = [day, yesterday]
        for d in compareDays {
            let codex: String = "昨日\n・9:00〜 朝の打ち合わせ（見本）\n今日の三つ\n1. 見本の資料を送る"
            let claude: String = "昨日は朝の打ち合わせ（見本）で、資料の締め切りが決まりました。\n今日はまず見本の資料を送りましょう。"
            days.append(BriefCompareDay(day: d, codex: codex, claude: claude))
        }
        write(BriefCompareFeed(generated_at: iso.string(from: now), days: days), "mfeed-briefcmp.json")
        // 精度の通信簿（3週。値の無い所は —）
        var weeks: [AccuracyWeek] = []
        for i in 0..<3 {
            var w = AccuracyWeek(week: "2026-W4\(6 - i)")
            w.caught_self = 0.7 - Double(i) * 0.03
            w.caught_other = i == 2 ? nil : 0.6
            w.person_n_kinds_median = 80 + i * 20
            w.fix_kept_ratio = 0.76
            w.judge_agree = i == 0 ? 0.8 : nil
            w.speaking_score = i == 1 ? nil : 62
            weeks.append(w)
        }
        write(AccuracyFeed(generated_at: iso.string(from: now), weeks: weeks), "mfeed-accuracy.json")
        // あまり開かれていない画面
        var unused = UnusedFeed(generated_at: iso.string(from: now), month: "2026-11")
        let screens: [String] = ["money", "answerKey", "unnamedVoices"]
        for (i, s) in screens.enumerated() {
            unused.items.append(UnusedScreen(screen: s, opens: i, days: 30, note: i == 0 ? "見本の覚え書き" : ""))
        }
        write(unused, "mfeed-unused.json")
    }
}
#endif

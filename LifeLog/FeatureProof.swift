import Foundation
import SwiftUI

/// 「実機で動いたか」の帳（2026-11-12）。
/// 1週間に40ほどの変更を入れたが、どれも「実機では未確認」だった。そこで、機能ごとに「動いた証拠になる数（Tally の名前）」を決めておき、
/// その数が初めて 1 以上になった日を、35日で消えない別のファイル（feature-first-seen.json）に残す。
/// 自己点検とドライブの「診断」に「動いた（日付）／まだ／測れない」を出す。数えるのは回数と日付だけで、会話の中身・人の名前は入れない。
enum FeatureProof {
    /// 機能1つ。keys のどれかが 1 以上になれば「動いた」。keys が空なら今は測れない。
    struct Feature: Equatable {
        let name: String
        /// 入れた変更（PR）の番号
        let pr: Int
        let keys: [String]
        /// 新しい家の PC が要る働きなら、PC が知らせる features の名前
        var pc: String? = nil
    }

    /// 画面1つ（Tally の名前は "screen." + key）
    struct Screen: Equatable {
        let key: String
        let name: String
    }

    // MARK: - 機能の一覧

    static let features: [Feature] = [
        Feature(name: "誤変換の直し", pr: 11, keys: ["fix.proposed"]),
        Feature(name: "頼まれごとを2つのモデルで拾う", pr: 11, keys: ["task.agreed", "task.alone"]),
        Feature(name: "議事録", pr: 11, keys: ["minutes.items"]),
        Feature(name: "2つ目の言語モデルの見比べ", pr: 11, keys: ["second.ran"]),
        Feature(name: "話者を家の PC で測り直す", pr: 11, keys: ["pc.speakerChecked"], pc: "speakers"),
        Feature(name: "場面の多数決（PC と iPhone）", pr: 11, keys: ["pc.sceneChecked"], pc: "scene"),
        Feature(name: "声の区間を PC で足す", pr: 11, keys: ["pc.vadExtra"], pc: "vad"),
        Feature(name: "夜の聞き直し", pr: 11, keys: ["night.lines"]),
        Feature(name: "直した記録から学ぶ", pr: 11, keys: ["learn.updated"]),
        Feature(name: "話者の替わり目で行を分ける", pr: 12, keys: ["split.lines"]),
        Feature(name: "言語モデルの書いたものの根拠の確かめ", pr: 12, keys: ["ground.checked"]),
        Feature(name: "精度の物差し", pr: 12, keys: ["bench.lines"]),
        Feature(name: "あなた向けのモデルの材料", pr: 12, keys: ["personal.sent"], pc: "personal"),
        Feature(name: "会話のつなぎ・分け", pr: 12, keys: ["talk.joined", "talk.split"]),
        Feature(name: "時計が iPhone のアプリを起こす", pr: 13, keys: ["watch.wake"]),
        Feature(name: "もう1台のマイクの票", pr: 13, keys: ["othermic.lines"]),
        Feature(name: "有料の票（ElevenLabs）", pr: 13, keys: ["paid.lines"]),
        Feature(name: "後で受け取る文字起こし（PC）", pr: 18, keys: ["jobs.sent"], pc: "jobs"),
        Feature(name: "意味で探す（PC）", pr: 18, keys: ["semantic.indexed"], pc: "semantic"),
        Feature(name: "記録を家の PC へ送る", pr: 20, keys: ["records.sent"], pc: "records"),
        Feature(name: "家の PC への実機の様子（診断）", pr: 20, keys: ["diag.sent"], pc: "diag"),
        Feature(name: "PC で直した記録をアプリへ返す", pr: 20, keys: [], pc: "edits"),
        Feature(name: "見えない通知で夜に起こす", pr: 20, keys: ["push.nightlyAsked"]),
        Feature(name: "夜の言語モデルの上限", pr: 22, keys: ["budget.night"]),
        Feature(name: "時計の区切りの送り直し", pr: 23, keys: ["watch.resendAsked"]),
        Feature(name: "毎朝の聞いて直す", pr: 24, keys: ["review.fixed", "review.ok", "review.skipped"]),
        Feature(name: "PC から先に記録に入れる", pr: 25, keys: ["pcFirst.applied"], pc: "watchroute"),
        Feature(name: "時計の更新の知らせ", pr: 37, keys: ["watch.updateReminder"]),
        Feature(name: "長い会話の自動の分け直し", pr: 35, keys: ["talk.autoSplit"]),
        Feature(name: "名前の無い声の夜の整理", pr: 35, keys: ["voice.tidyMerged", "voice.tidyForgot", "voice.tidySkipped"]),
        Feature(name: "AI の質問で記録が変わらないものを外す", pr: 35, keys: ["ask.dropped"]),
        Feature(name: "1日のまとめの「やること」の重なりを外す", pr: 35, keys: ["summary.todoDropped"]),
        Feature(name: "会話の見出し", pr: 39, keys: ["title.made", "title.filled"]),
        Feature(name: "仕事の成績表", pr: 39, keys: ["work.lines"]),
        Feature(name: "登録した言葉の先回り", pr: 39, keys: ["reach.heard"]),
        Feature(name: "登録した書き方で直す", pr: 39, keys: ["wordfix.work", "wordfix.other"]),
        Feature(name: "Claude（家の PC 経由）", pr: 53, keys: ["claude.ok"], pc: "claude"),
        // 以下は数える名前がまだ無いので、画面を開いたかで見る・または測れない
        Feature(name: "行ったお店", pr: 29, keys: ["screen.shopVisits"]),
        Feature(name: "PayPay の明細・かざした記録の送信", pr: 45, keys: ["screen.unmatchedPayments"], pc: "pay"),
        Feature(name: "カードの利用速報メール", pr: 36, keys: [], pc: "card"),
        Feature(name: "母艦のやること（タスクの一覧）", pr: 43, keys: ["screen.taskBook"], pc: "todo"),
        Feature(name: "母艦のやることの「違う」「まだ」", pr: 38, keys: [], pc: "todokind"),
        Feature(name: "言葉の登録の候補", pr: 39, keys: ["screen.vocabulary"], pc: "vocab"),
        Feature(name: "いいこと帳", pr: 46, keys: ["screen.goodThings"], pc: "good"),
        // 家の PC からの提案・PLAUD で埋めた所・話し手の疑い・職場の自分の声を10件（2026-11-13。HomeFeeds.swift）
        Feature(name: "家の PC からの提案", pr: 54,
                keys: ["proposal.shown", "proposal.accept", "proposal.later", "proposal.never"], pc: "proposals"),
        Feature(name: "PLAUD で埋めた所", pr: 54, keys: ["plaudfill.viewed"], pc: "plaudfill"),
        Feature(name: "話し手の疑い", pr: 54, keys: ["spkdoubt.self", "spkdoubt.dismiss"], pc: "spkdoubt"),
        Feature(name: "職場の自分の声を1日10件", pr: 54, keys: ["screen.selfTen"], pc: "selfcand"),
        // 2026-11-13 の施策（MothershipFeeds.swift・AppUsage.swift。番号は母艦の docs/system-proposal-2026-11-13.md）
        Feature(name: "使われたかを残す（今日の三つ・朝のまとめ・週・会う前）", pr: 57,
                keys: ["mfeed.today_three", "mfeed.brief", "mfeed.weekly", "mfeed.prep"], pc: "feedback"),
        Feature(name: "夜の10秒", pr: 57, keys: ["mood.answered"], pc: "mood"),
        Feature(name: "アプリを開いた記録（ショートカット）", pr: 57, keys: ["appusage.queued"], pc: "appusage"),
        Feature(name: "今週のふり返り・見立ての台帳", pr: 57, keys: ["weekly.shown", "screen.hypotheses"], pc: "weekly"),
        Feature(name: "次の予定の前に", pr: 57, keys: ["prep.shown"], pc: "prep"),
        Feature(name: "朝のまとめ 比べる", pr: 57, keys: ["screen.briefCompare", "mfeed.brief_compare"], pc: "briefcmp"),
        Feature(name: "精度の通信簿", pr: 57, keys: ["screen.accuracy"], pc: "accuracy"),
        Feature(name: "あまり開かれていない画面", pr: 57, keys: ["screen.unused"], pc: "unused"),
    ]

    /// 画面の一覧。畳む候補を探すのに使う（見せるだけで、何も止めない）
    static let screens: [Screen] = [
        Screen(key: "goodThings", name: "いいこと帳"),
        Screen(key: "taskBook", name: "タスク"),
        Screen(key: "people", name: "話した相手"),
        Screen(key: "voiceReview", name: "声の見直し"),
        Screen(key: "misheard", name: "聞き間違いかも"),
        Screen(key: "diagnostics", name: "自己点検"),
        Screen(key: "confirmBox", name: "直す（前の確認箱）"),
        Screen(key: "lookBack", name: "ふり返り"),
        Screen(key: "money", name: "お金"),
        Screen(key: "ask", name: "記録に質問する"),
        Screen(key: "speaking", name: "話し方の振り返り"),
        Screen(key: "questions", name: "AI からの質問"),
        Screen(key: "answerKey", name: "答え合わせ"),
        Screen(key: "reviewNudge", name: "今日の聞いて直す"),
        Screen(key: "workDigest", name: "仕事のまとめ"),
        Screen(key: "shopVisits", name: "行ったお店"),
        Screen(key: "vocabulary", name: "言葉の登録"),
        Screen(key: "places", name: "登録した場所"),
        Screen(key: "recordingMap", name: "録音の抜け"),
        Screen(key: "unmatchedPayments", name: "払ったお店"),
        Screen(key: "unnamedVoices", name: "今日の人物Nを整理"),
        Screen(key: "proposals", name: "提案"),
        Screen(key: "speakerDoubts", name: "話し手の疑い"),
        Screen(key: "selfTen", name: "職場の自分の声（今日の10件）"),
        // 2026-11-13（施策 17。今日・記録・設定にも計器を足し、新しい画面も数える）
        Screen(key: "today", name: "今日"),
        Screen(key: "recordsDays", name: "記録（日ごと）"),
        Screen(key: "dayView", name: "1日の記録"),
        Screen(key: "settings", name: "設定と点検"),
        Screen(key: "detailedSettings", name: "くわしい設定"),
        Screen(key: "hypotheses", name: "見立ての台帳"),
        Screen(key: "briefCompare", name: "朝のまとめ 比べる"),
        Screen(key: "accuracy", name: "精度の通信簿"),
        Screen(key: "unused", name: "あまり開かれていない画面"),
        Screen(key: "appUsageHowTo", name: "アプリを開いた記録の使い方"),
        // 2026-11-14（強化案 28・34）
        Screen(key: "paypayShot", name: "PayPay のスクショ"),
        Screen(key: "reflection", name: "反映の見張り"),
        // 2026-11-15（強化案 36・37）
        Screen(key: "rollout", name: "入れた施策の様子"),
        Screen(key: "claudeCosts", name: "Claude の費用"),
    ]

    static func screenKey(_ s: Screen) -> String { "screen." + s.key }

    /// 家の PC のプログラムを新しくしないと増えない働き（PC の環境しだいで出ない speakers・semantic などは入れない）
    static let updatablePC: Set<String> = ["todo", "todokind", "card", "vocab", "pay", "good", "watchroute", "records", "edits", "diag",
                                           "feedback", "mood"]

    /// 初めて動いた日を残す Tally の名前（これ以外は見ない）
    static let evidenceKeys: Set<String> = Set(features.flatMap(\.keys) + screens.map(screenKey))

    // MARK: - 初めて数えた日の帳（35日で消えない）

    private static let url = URL.applicationSupportDirectory.appendingPathComponent("feature-first-seen.json")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?
    /// ファイルがあるのに読めなかったとき。読む前に上書きしないよう、書かない
    nonisolated(unsafe) private static var unreadable = false

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func loadLocked() -> [String: String] {
        if let cache { return cache }
        var all: [String: String] = [:]
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                all = decoded
            } else {
                unreadable = true
            }
        }
        cache = all
        return all
    }

    private static func saveLocked(_ all: [String: String]) {
        guard !unreadable, let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 数えた名前が証拠の名前なら、初めての日を残す（Tally.add から呼ぶ。どのスレッドからでもよい）
    static func noticed(_ key: String, at date: Date = .now) {
        guard evidenceKeys.contains(key) else { return }
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        let day = dayString(date)
        if let old = all[key], old <= day { return }
        all[key] = day
        cache = all
        saveLocked(all)
    }

    /// 35日ぶんの数から、まだ残していない日を埋める（この機能を入れる前から数えていた分）
    static func refresh() {
        // Tally の鍵を先に取って離してから、こちらの鍵を取る（入れ子にしない）
        let days = Tally.days(36)
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        var changed = false
        for (day, counts) in days {
            for (key, n) in counts where n > 0 && evidenceKeys.contains(key) {
                if let old = all[key], old <= day { continue }
                all[key] = day
                changed = true
            }
        }
        guard changed else { return }
        cache = all
        saveLocked(all)
    }

    /// 残している日（名前 → "YYYY-MM-DD"）
    static func firstSeen() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    // MARK: - 判定（どれも純粋な関数）

    enum Proof: Equatable {
        case ran(String)
        case notYet
        case unmeasurable
    }

    /// 動いたか。keys のどれかが初めて数えられた日のうち、いちばん古い日
    static func proof(_ feature: Feature, seen: [String: String]) -> Proof {
        guard !feature.keys.isEmpty else { return .unmeasurable }
        guard let first = feature.keys.compactMap({ seen[$0] }).min() else { return .notYet }
        return .ran(first)
    }

    /// "2026-11-10" → "11/10"
    static func shortDate(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return day }
        return "\(m)/\(d)"
    }

    /// 家の PC が知らせた features に無い、PC の新しい版が要る働き。PC につながったことが無い（版が分からない）ときは空
    static func missingOnPC(version: Int?, features pcFeatures: Set<String>) -> [Feature] {
        guard version != nil else { return [] }
        return features.filter { f in
            guard let pc = f.pc, updatablePC.contains(pc) else { return false }
            return !pcFeatures.contains(pc)
        }
    }

    /// 開かれていない画面（日数のうち1回も開かれていない）。数え始めて日が浅いと、まだ決められない
    static func unreadScreens(sums: [String: Int]) -> [Screen] {
        screens.filter { (sums[screenKey($0)] ?? 0) == 0 }
    }

    /// 画面の数え始め（いちばん古い画面の日）から何日たったか。まだ数えていなければ nil
    static func screenCountingDays(seen: [String: String], now: Date = .now, calendar: Calendar = .current) -> Int? {
        let days = screens.compactMap { seen[screenKey($0)] }
        guard let first = days.min() else { return nil }
        let parts = first.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day
    }

    // MARK: - 自己点検・診断の行

    /// 自己点検（とドライブの「診断」）に足す行。節の名前・見出し・中身・良いか
    static func diagnosticRows(pcVersion: Int?, pcFeatures: Set<String>, pcConfigured: Bool, now: Date = .now)
        -> [(section: String, label: String, value: String, ok: Bool?)] {
        refresh()
        let seen = firstSeen()
        var rows: [(section: String, label: String, value: String, ok: Bool?)] = []

        // 実機で動いたか
        let section = "実機で動いたか"
        let proofs = features.map { ($0, proof($0, seen: seen)) }
        let ran = proofs.filter { if case .ran = $0.1 { return true } else { return false } }.count
        let notYet = proofs.filter { $0.1 == .notYet }.count
        let unmeasurable = proofs.filter { $0.1 == .unmeasurable }.count
        rows.append((section, "まとめ", "動いた \(ran)・まだ \(notYet)・測れない \(unmeasurable)（全部で \(features.count)）", nil))
        for (f, p) in proofs {
            if case .notYet = p { rows.append((section, f.name + "（#\(f.pr)）", "まだ", nil)) }
        }
        for (f, p) in proofs {
            if case .ran(let day) = p { rows.append((section, f.name + "（#\(f.pr)）", "動いた（\(shortDate(day))）", true)) }
        }
        for (f, p) in proofs where p == .unmeasurable {
            rows.append((section, f.name + "（#\(f.pr)）", "測れない（数える印がまだ無い）", nil))
        }

        // 家の PC が古くて使えない働き
        if pcConfigured {
            let missing = missingOnPC(version: pcVersion, features: pcFeatures)
            let pcSection = "家の PC が古くて使えない働き"
            if pcVersion == nil {
                rows.append((pcSection, "家の PC", "まだつながっていないので、確かめられません", nil))
            } else if missing.isEmpty {
                rows.append((pcSection, "家の PC", "アプリが前提にしている働きは、すべて使えます", true))
            } else {
                for f in missing {
                    rows.append((pcSection, f.name + "（#\(f.pr)）", "LifeLog PC を新しくすると使えます", false))
                }
            }
        }

        // 画面を開いた回数
        let counts = Tally.sums(days: 35, now: now)
        let thirty = Tally.sums(days: 30, now: now)
        let opened = "画面を開いた回数（35日）"
        for s in screens.sorted(by: { (counts[screenKey($0)] ?? 0) > (counts[screenKey($1)] ?? 0) }) {
            rows.append((opened, s.name, "\(counts[screenKey(s)] ?? 0) 回", nil))
        }
        let unread = unreadScreens(sums: thirty)
        let unreadSection = "読まれていない画面（畳む候補）"
        if let counted = screenCountingDays(seen: seen, now: now) {
            if counted < 30 {
                rows.append((unreadSection, "数え始めて", "\(counted) 日です。30日たつまでは目安です（見せるだけで、何も止めません）", nil))
            }
            if unread.isEmpty {
                rows.append((unreadSection, "30日で1回も開かれていない画面", "なし", true))
            } else {
                rows.append((unreadSection, "30日で1回も開かれていない画面", unread.map(\.name).joined(separator: "・"), nil))
            }
        } else {
            rows.append((unreadSection, "数え始め", "画面を開くと数え始めます", nil))
        }
        return rows
    }

    // MARK: - 機械が読む数（ドライブの tally.json）

    struct Export: Codable {
        struct Row: Codable {
            var name: String
            var pr: Int
            var first_seen: String?
        }
        var generated_at: String
        var days: [String: [String: Int]]
        var features: [Row]
    }

    /// {"generated_at", "days": {"YYYY-MM-DD": {"key": n}}, "features": [{"name","pr","first_seen"}]}。数と日付だけ
    static func exportJSON(now: Date = .now) -> Data? {
        refresh()
        let seen = firstSeen()
        let rows = features.map { f -> Export.Row in
            var first: String?
            if case .ran(let day) = proof(f, seen: seen) { first = day }
            return Export.Row(name: f.name, pr: f.pr, first_seen: first)
        }
        let export = Export(generated_at: ISO8601DateFormatter().string(from: now), days: Tally.days(36, now: now), features: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(export)
    }
}

/// 画面を開いた回数を数える（2026-11-12）。`.countsOpen("goodThings")` を画面の本体に付ける。
struct CountsOpen: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content.onAppear { Tally.add("screen." + name) }
    }
}

extension View {
    func countsOpen(_ name: String) -> some View { modifier(CountsOpen(name: name)) }
}

/// ホームの「家の PC を新しく」の知らせ。PC に、アプリが前提にしている新しい働きが無いときだけ出す。
struct PCFeatureNotice: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        let pc = pipeline.homePC
        let missing = pc.isConfigured ? FeatureProof.missingOnPC(version: pc.version, features: pc.features) : []
        if !missing.isEmpty {
            Section {
                Label("家の PC の LifeLog PC が古いようです", systemImage: "arrow.triangle.2.circlepath")
                Text("次の働きは、LifeLog PC を新しくするまで使えません: " + missing.map(\.name).joined(separator: "・"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("家の PC を新しく")
            } footer: {
                Text("文字起こしは今のままでも使えます。GitHub の成果物 LifeLogPC から新しいものに入れ替えると、使えるようになります。")
            }
        }
    }
}

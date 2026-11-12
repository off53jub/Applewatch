import Foundation
import SwiftUI

// MARK: - Claude（家の PC 経由。2026-11-13）
//
// 見出し・要点・まとめ・誤変換の直し・聞き間違い探し・記録への質問などの言語モデルの仕事を、家の PC の POST /claude に先に頼む。
// Claude の鍵は家の PC の中だけにあり、iPhone・時計・リポジトリには入れない。月の上限（初めは $100）は PC が守る。
// 頼めなかったとき（PC につながらない・上限・鍵が無い・断られた・読めない答え）は、今までどおり Groq・iPhone の中・家の PC の言語モデルの順で作る。
// 職場の会話は「職場の会話も Claude で」がオンのとき（初めはオン。2026-11-13 に本人が職場の中身も見せてよいと決めた）だけ送る。

/// Claude の重さ。家の PC が light → Haiku・standard → Sonnet・deep → Opus を選ぶ
enum ClaudeTier: String, Sendable {
    case light, standard, deep
}

/// 言語モデルに頼む仕事1つ。purpose は家の PC の帳に残る短い英字の名前（中身は残らない）
struct ClaudeJob: Sendable, Equatable {
    let purpose: String
    let tier: ClaudeTier

    // 数の多い・短い仕事は軽いモデルで
    static let correct = ClaudeJob(purpose: "correct", tier: .light)
    static let notes = ClaudeJob(purpose: "notes", tier: .light)
    static let headline = ClaudeJob(purpose: "headline", tier: .light)
    static let unify = ClaudeJob(purpose: "unify", tier: .light)
    static let broadcast = ClaudeJob(purpose: "broadcast", tier: .light)
    static let tasks = ClaudeJob(purpose: "tasks", tier: .light)
    static let misheard = ClaudeJob(purpose: "misheard", tier: .light)
    static let speaking = ClaudeJob(purpose: "speaking", tier: .light)
    static let askPlan = ClaudeJob(purpose: "ask.plan", tier: .light)
    static let minutesNotes = ClaudeJob(purpose: "minutes.notes", tier: .light)
    // まとめ・議事録・記録への質問の答えは標準のモデルで
    static let day = ClaudeJob(purpose: "day", tier: .standard)
    static let week = ClaudeJob(purpose: "week", tier: .standard)
    static let month = ClaudeJob(purpose: "month", tier: .standard)
    static let blocks = ClaudeJob(purpose: "activity.blocks", tier: .standard)
    static let details = ClaudeJob(purpose: "activity.details", tier: .standard)
    static let minutes = ClaudeJob(purpose: "minutes", tier: .standard)
    static let answer = ClaudeJob(purpose: "ask.answer", tier: .standard)
    static let questions = ClaudeJob(purpose: "questions", tier: .standard)
    static let photoTasks = ClaudeJob(purpose: "tasks.photo", tier: .standard)

    /// 画面に出す名前（知らない名前はそのまま。母艦から頼んだ分も混ざる）
    static let labels: [String: String] = [
        "correct": "誤変換の直し", "notes": "長い会話の要点メモ", "headline": "会話の見出しと要点",
        "unify": "書き方をそろえる", "broadcast": "テレビ・放送の行", "tasks": "頼まれごと",
        "misheard": "聞き間違いかも", "speaking": "話し方の振り返り", "ask.plan": "記録への質問（探し方）",
        "minutes.notes": "長い会議の要点メモ", "day": "1日のまとめ", "week": "週のまとめ", "month": "月のまとめ",
        "activity.blocks": "過ごし方の区切り", "activity.details": "過ごし方の中身", "minutes": "議事録",
        "ask.answer": "記録への質問（答え）", "questions": "AI からの質問", "tasks.photo": "写真のやること",
    ]

    static func label(_ purpose: String) -> String { labels[purpose] ?? purpose }
}

/// 家の PC に頼む1回分
struct ClaudeCall: Sendable {
    var system: String?
    var prompt: String
    var json = true
    var maxTokens = 4096
    var tier: ClaudeTier
    var purpose: String
    var work: Bool
    /// 待つ長さ（秒）
    var timeout: TimeInterval = 120
}

/// POST /claude の答え
struct ClaudeReply: Decodable, Sendable {
    let text: String
    let model: String?
    let usd: Double?
    let monthUSD: Double?
    let capUSD: Double?

    enum CodingKeys: String, CodingKey {
        case text, model, usd
        case monthUSD = "month_usd"
        case capUSD = "cap_usd"
    }
}

/// Claude に頼めなかったわけ
enum ClaudeFailure: LocalizedError, Equatable {
    /// 家の PC が切れている・PC に Claude が無い（送っていない）
    case notReady
    /// 今月の上限に達した（402）
    case capped(spent: Double?, cap: Double?)
    /// 家の PC に Claude の鍵が無い（503）
    case noKey
    /// Claude に断られた（422）
    case refused
    /// 家の PC の設定で、職場の会話は送らないことになっている（403）
    case workNotAllowed
    /// 答えが読めなかった（JSON でない・途中で切れた）
    case unreadable
    case server(status: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .notReady: "家の PC の Claude が使えません"
        case .capped: "Claude の今月の上限に達しました"
        case .noKey: "家の PC に Claude の鍵がありません"
        case .refused: "Claude に断られました"
        case .workNotAllowed: "家の PC の設定で、職場の会話は Claude に送らないことになっています"
        case .unreadable: "Claude の答えを読めませんでした"
        case .server(_, let reason): "Claude に頼めませんでした: \(reason)"
        }
    }

    /// 家の PC の答えの番号から（200 なら nil）
    static func from(status: Int, data: Data) -> ClaudeFailure? {
        guard status != 200 else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        func number(_ key: String) -> Double? { (json?[key] as? NSNumber)?.doubleValue }
        switch status {
        case 402: return .capped(spent: number("month_usd"), cap: number("cap_usd"))
        case 503: return .noKey
        case 422: return .refused
        case 403: return .workNotAllowed
        default: return .server(status: status, reason: (json?["error"] as? String) ?? "HTTP \(status)")
        }
    }

    /// しばらく頼まない長さ（秒）。all はすべての仕事、work は職場の会話だけ。
    /// 断られた・読めなかったのは中身しだいなので、次の仕事はまた頼む
    var pause: (all: TimeInterval, work: TimeInterval) {
        switch self {
        case .capped: return (all: 3600, work: 0)
        case .noKey: return (all: 1800, work: 0)
        case .workNotAllowed: return (all: 0, work: 3600)
        case .refused, .unreadable: return (all: 0, work: 0)
        case .notReady, .server: return (all: 120, work: 0)
        }
    }

    /// 数える名前（送っていないときは数えない）
    var tallyKey: String? {
        switch self {
        case .notReady: return nil
        case .capped: return "claude.capped"
        default: return "claude.failed"
        }
    }
}

/// GET /claude/usage の答え（読めない欄は空にする）
struct ClaudeUsage: Decodable, Equatable {
    var available = false
    var month = ""
    var monthUSD = 0.0
    var capUSD = 0.0
    var calls = 0
    var byPurpose: [String: Double] = [:]
    var byWho: [String: Double] = [:]

    enum CodingKeys: String, CodingKey {
        case available, month, calls
        case monthUSD = "month_usd"
        case capUSD = "cap_usd"
        case byPurpose = "by_purpose"
        case byWho = "by_who"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        month = (try? c.decodeIfPresent(String.self, forKey: .month)) ?? ""
        monthUSD = (try? c.decodeIfPresent(Double.self, forKey: .monthUSD)) ?? 0
        capUSD = (try? c.decodeIfPresent(Double.self, forKey: .capUSD)) ?? 0
        calls = (try? c.decodeIfPresent(Int.self, forKey: .calls)) ?? 0
        byPurpose = (try? c.decodeIfPresent([String: Double].self, forKey: .byPurpose)) ?? [:]
        byWho = (try? c.decodeIfPresent([String: Double].self, forKey: .byWho)) ?? [:]
    }

    /// 「$12.40」（上限のように端数の無い額は whole で「$100」）
    static func dollars(_ value: Double, whole: Bool = false) -> String {
        whole && value == value.rounded() ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    /// 「$12.40 / $100」
    var spendText: String { Self.dollars(monthUSD) + " / " + Self.dollars(capUSD, whole: true) }

    /// 何のためにいくら使ったか（多い順に8つまで。0 は出さない）
    var purposeRows: [(label: String, usd: Double)] {
        byPurpose.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8)
            .map { (label: ClaudeJob.label($0.key), usd: $0.value) }
    }

    /// 「アプリから $3.10・母艦 $9.30」（どちらも 0 なら空）
    var whoText: String {
        let app = byWho["pc"] ?? 0, mothership = byWho["mothership"] ?? 0
        guard app > 0 || mothership > 0 else { return "" }
        return "アプリから " + Self.dollars(app) + "・母艦 " + Self.dollars(mothership)
    }
}

/// Claude に頼むかの決まりと、頼めなかったあとしばらく頼まない間
enum ClaudeRoute {
    /// 家の PC が知らせる働きの名前（鍵があり、今月の上限より下のとき）
    static let feature = "claude"
    /// 家の PC が最後に "claude" を知らせたか（HomePC.hello が書く。どのスレッドからも読めるように）
    static let featureKey = "homePCClaude"
    /// 「Claude を使う」（初めはオン）
    static let useKey = "claudeOn"
    /// 「職場の会話も Claude で」（初めはオン。2026-11-13）
    static let workKey = "claudeForWork"
    /// クラウドに送ったものの一覧に出す送り先
    static let service = "Claude（家の PC 経由）"

    static var useClaude: Bool { UserDefaults.standard.object(forKey: useKey) as? Bool ?? true }
    static var forWork: Bool { UserDefaults.standard.object(forKey: workKey) as? Bool ?? true }
    static var offered: Bool { UserDefaults.standard.bool(forKey: featureKey) }

    /// この仕事を先に Claude に頼むか。
    /// bench は精度の物差しで Groq のモデルを比べているとき、forceLocal は iPhone の中のモデルでセカンドオピニオンを作るとき、
    /// localAlways は「いつも端末内で」を選んでいるとき（どれも Claude には頼まない）。
    /// 職場の会話（sensitive）は「職場の会話も Claude で」がオンのときだけ。「職場の会話は端末内で」より先に効く
    static func shouldTry(useClaude: Bool, forWork: Bool, offered: Bool, sensitive: Bool,
                          bench: Bool, forceLocal: Bool, localAlways: Bool,
                          paused: Bool, workPaused: Bool) -> Bool {
        guard useClaude, offered, !bench, !forceLocal, !localAlways, !paused else { return false }
        return !sensitive || (forWork && !workPaused)
    }

    // MARK: しばらく頼まない（上限・鍵が無い・つながらない）

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pausedUntil: Date?
    nonisolated(unsafe) private static var workPausedUntil: Date?

    /// 頼めなかったわけに合わせて、しばらく頼まない
    static func note(_ failure: ClaudeFailure, now: Date = .now) {
        let pause = failure.pause
        lock.lock()
        defer { lock.unlock() }
        if pause.all > 0 { pausedUntil = now.addingTimeInterval(pause.all) }
        if pause.work > 0 { workPausedUntil = now.addingTimeInterval(pause.work) }
    }

    /// 今、頼まない間か（all はすべて、work は職場の会話だけ）
    static func paused(now: Date = .now) -> (all: Bool, work: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (pausedUntil.map { now < $0 } ?? false, workPausedUntil.map { now < $0 } ?? false)
    }

    /// 設定を変えたときと、テスト
    static func resetPauses() {
        lock.lock()
        defer { lock.unlock() }
        pausedUntil = nil
        workPausedUntil = nil
    }

    /// 待つ長さ。Groq で待ってよい長さ（maxWait）の2倍、40〜180秒
    static func timeout(maxWait: Double) -> TimeInterval { min(180, max(40, maxWait * 2)) }
}

// MARK: - 設定の画面

/// 設定の「Claude（家の PC 経由）」。2つのスイッチと、今月使った額
struct ClaudeSettingsSection: View {
    @Environment(Pipeline.self) private var pipeline
    @AppStorage(ClaudeRoute.useKey) private var useClaude = true
    @AppStorage(ClaudeRoute.workKey) private var forWork = true
    @State private var usage: ClaudeUsage?
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Claude を使う", isOn: $useClaude)
            Toggle("職場の会話も Claude で", isOn: $forWork)
                .disabled(!useClaude)
            LabeledContent("家の PC", value: ClaudeRoute.offered ? "使える" : "まだ使えない")
            if let usage, usage.available || usage.calls > 0 {
                LabeledContent("今月", value: usage.spendText)
                if !usage.whoText.isEmpty {
                    Text(usage.whoText).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(usage.purposeRows, id: \.label) { row in
                    LabeledContent(row.label, value: ClaudeUsage.dollars(row.usd))
                        .font(.caption)
                }
            } else if let problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Claude（家の PC 経由）")
        } footer: {
            HelpNote("見出し・要点・まとめ・議事録・誤変換の直し・聞き間違い探し・記録への質問を、家の PC を通して Claude に先に頼みます。数の多い仕事（誤変換の直し・見出しなど）は軽いモデル、まとめ・議事録・質問の答えは標準のモデルです。\nClaude の鍵は家の PC の中にだけあり、iPhone には入れません。月の上限（初めは $100）は家の PC が守り、上限に達したら月が変わるまで、今までどおり Groq・iPhone の中・家の PC の言語モデルで作ります。PC につながらないときも同じです。\n「職場の会話も Claude で」がオンのときは、職場にいた時間の会話も家の PC から Claude に送ります（2026-11-13 に、職場の中身も見せてよいと決めました）。オフにすると、職場の会話は今までどおり「言語モデル」の設定のとおりに作ります。「いつも端末内で」を選んでいるときは、Claude にも送りません。")
        }
        .onChange(of: useClaude) { _, _ in ClaudeRoute.resetPauses() }
        .onChange(of: forWork) { _, _ in ClaudeRoute.resetPauses() }
        .task { await load() }
    }

    private func load() async {
        guard pipeline.homePC.isConfigured else {
            problem = "家の PC をつなぐと、今月使った額が出ます。"
            return
        }
        do {
            let read = try await pipeline.homePC.claudeUsage()
            usage = read
            if !read.available, read.calls == 0 { problem = "家の PC にまだ Claude の鍵がありません。" }
        } catch {
            problem = "今月使った額を読めませんでした: \(error.localizedDescription)"
        }
    }
}

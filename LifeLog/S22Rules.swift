import Foundation

/// s22（2026-11-22）の iPhone の決まり（決まった入力から決まった出力だけ。docs/s22-app.md）。
/// 自己点検（楽1〜4）は S22Checkup.swift、時計と分け合う決まりは Shared/Audio/S22Watch.swift。テストは LifeLogTests/S22Tests.swift。
/// 新しい言語モデルの呼び出しは作っていない（0 円）。しきい値はどれも仮。
enum S22Rules {
    // MARK: - 楽10 時計の版が古い・分からない

    enum WatchVersion: Equatable, Sendable {
        case same(Int)
        case watchOlder(watch: Int, phone: Int)
        case phoneOlder(watch: Int, phone: Int)
        /// 時計が版を送ってこない（版 356 より前の時計のアプリ・時計の便りが無い）
        case unknown
    }

    static func watchVersion(phone: Int, watch: String?) -> WatchVersion {
        guard let watch, let w = Int(watch) else { return .unknown }
        if w == phone { return .same(w) }
        return w < phone ? .watchOlder(watch: w, phone: phone) : .phoneOlder(watch: w, phone: phone)
    }

    /// 更新の手順を出すか（時計が古い・分からない）
    static func needsWatchUpdate(_ v: WatchVersion) -> Bool {
        switch v {
        case .watchOlder, .unknown: true
        default: false
        }
    }

    /// 時計の LifeLog を新しくする手順（どれか 1 つで新しくなるはず。上から順に。仮）
    static let watchUpdateSteps: [String] = [
        "時計で LifeLog を一度開いて、10 秒ほど待つ（iPhone と同じ版が届いていれば、ここで入れ替わります）",
        "iPhone の「Watch」アプリ →「マイウォッチ」→ 下の「Apple Watch にインストール済み」の LifeLog → 出ていれば「アップデート」か「インストール」",
        "iPhone の「Watch」アプリ →「一般」→「App の自動インストール」をオン（iPhone のアプリを入れ替えたとき、時計の分も入れ替わります）",
        "TestFlight で入れているとき: iPhone の TestFlight → LifeLog →「インストール」（時計の分も一緒に入ります）",
        "それでも古いとき: 時計の LifeLog を長押しして削除 → iPhone の「Watch」アプリから入れ直す（時計に残っている返事待ちの録音は消えるので、家の PC に届いているかを先に見る）",
    ]

    // MARK: - 楽7 いま話したことは約○分で文字になります

    /// 直近の中央値（録音の終わり → 記録。秒）に、区切りが閉じるまでの半分を足した分（分からなければ nil）
    static func talkToTextMinutes(totalMedian: Double?, chunkTypical: TimeInterval) -> Int? {
        guard let totalMedian, totalMedian.isFinite, totalMedian >= 0 else { return nil }
        return max(1, Int(((totalMedian + chunkTypical / 2) / 60).rounded()))
    }

    static func talkToTextLine(_ minutes: Int?) -> String? {
        guard let minutes else { return nil }
        if minutes >= 120 { return "いま話したことは、文字になるまで " + S22Watch.durationText(Double(minutes) * 60) + "ほどかかりそうです" }
        return "いま話したことは約 \(minutes) 分で文字になります"
    }

    // MARK: - 楽9 設定を変える前の電池と速さの見込み

    /// 組ごとの見立ての倍率（仮。実測が集まったら直す）: 時計の電池の減りと、文字になるまでの時間
    static func presetFactors(_ preset: S21Preset) -> (battery: Double, latency: Double) {
        switch preset {
        case .battery: (0.8, 1.6)
        case .speed: (1.25, 0.7)
        case .accuracy: (1.1, 1.1)
        }
    }

    /// 「見込み（仮）: 時計の電池 1 時間 約 6%・文字になるまで 約 4 分」。いまの実測が無ければ「見込み（仮）: 電池 少し長持ち…」
    static func forecastLine(_ preset: S21Preset, drainPerHour: Double?, latencyMinutes: Int?) -> String {
        let f = presetFactors(preset)
        var parts: [String] = []
        if let drainPerHour, drainPerHour > 0 {
            parts.append("時計の電池 1 時間 約 \(max(1, Int((drainPerHour * f.battery).rounded())))%")
        } else {
            parts.append(f.battery < 1 ? "電池 長持ちのほう" : "電池 多く使うほう")
        }
        if let latencyMinutes {
            parts.append("文字になるまで 約 " + S22Watch.durationText(Double(latencyMinutes) * f.latency * 60))
        } else {
            parts.append(f.latency < 1 ? "文字になるのは早いほう" : "文字になるのは遅いほう")
        }
        return "見込み（仮）: " + parts.joined(separator: "・")
    }

    /// 1 つのスイッチの見立て（設定の検索で、変える前に出す。nil なら電池にも速さにも効かない）
    static func switchImpact(_ key: String, turningOn: Bool) -> String? {
        let table: [String: (on: String, off: String)] = [
            "chunkBatterySaver": ("電池: 長持ちのほう・文字になるまで: 電池が少ないときは遅くなる", "電池: 減りが早くなるかも"),
            "skipSilence": ("電池: 長持ちのほう", "電池: 多く使うほう（無音も書く）"),
            "dropNoVoice": ("電池と送る量: 少なく・声の無い区切りは文字にしない", "電池と送る量: 多く"),
            "standbyOn": ("電池: iPhone を多く使う・文字になるまで: 早いほう", "電池: iPhone は長持ち・文字になるまで: 遅いほう"),
            "homePCWatchDirect": ("文字になるまで: 早いほう・時計の電池: 少し多く使う", "時計の電池: 長持ちのほう・文字になるまで: 遅いほう"),
            "homePCWatchRelay": ("時計の電池: 長持ちのほう（iPhone へ送らずに済む）", "時計の電池: 多く使うほう"),
            S21Watch.workoutGuardKey: ("時計の電池: かなり多く使う（心拍を測り続ける）", "時計の電池: 長持ちのほう"),
            S21Watch.sleepChunksKey: ("時計の電池: 寝ているあいだ長持ち", "時計の電池: 寝ているあいだ多く使う"),
            S22Watch.hourlyOnKey: ("時計の電池: 組によって変わる（8 日）", "いつもの録り方に戻る"),
            S22Watch.muffledOnKey: ("時計の電池: ほぼ変わらない", "時計の電池: ほぼ変わらない"),
        ]
        guard let entry = table[key] else { return nil }
        return "見込み（仮）: " + (turningOn ? entry.on : entry.off)
    }

    // MARK: - 楽21 開いてから今日の画面が出るまで

    static func launchBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<1: "lt1"
        case ..<2: "lt2"
        case ..<4: "lt4"
        case ..<8: "lt8"
        default: "ge8"
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: - 楽22 iPad は読むだけ

    /// 初めの値（iPad はオン・iPhone はオフ）
    static func readerDefault(isPad: Bool) -> Bool { isPad }

    // MARK: - 楽23 会話の 1 場面のカード

    struct CardLine: Equatable, Sendable {
        var who: String
        var text: String
        var isSelf: Bool
    }

    /// 場面の行（around の前後から、テレビ・動画の行を除いて limit 行）。mask なら名前を「A さん」「B さん」にし、文の中の名前も伏せる
    static func sceneLines(_ lines: [(speaker: String?, text: String, time: Date, media: Bool)], around: Date,
                           selfName: String, names: [String], mask: Bool, limit: Int = 6) -> [CardLine] {
        let usable = lines.filter { !$0.media && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return [] }
        let center = usable.enumerated().min { abs($0.element.time.timeIntervalSince(around)) < abs($1.element.time.timeIntervalSince(around)) }?.offset ?? 0
        let start = max(0, min(center - limit / 2, usable.count - limit))
        let picked = Array(usable[start..<min(usable.count, start + limit)])
        var aliases: [String: String] = [:]
        let letters = ["A", "B", "C", "D", "E", "F", "G", "H"]
        var out: [CardLine] = []
        for line in picked {
            let speaker = line.speaker ?? "?"
            let isSelf = speaker == selfName
            var who = isSelf ? selfName : speaker
            if mask && !isSelf {
                if aliases[speaker] == nil { aliases[speaker] = letters[min(aliases.count, letters.count - 1)] + " さん" }
                who = aliases[speaker] ?? "?"
            }
            var text = String(line.text.prefix(80))
            if mask {
                for name in (names + Array(aliases.keys)).filter({ $0.count >= 2 && $0 != selfName }).sorted(by: { $0.count > $1.count }) {
                    text = text.replacingOccurrences(of: name, with: aliases[name] ?? "○○")
                }
            }
            out.append(CardLine(who: who, text: text, isSelf: isSelf))
        }
        return out
    }

    // MARK: - 確19・確27 確かめ待ちの答え方（kind を知らなくても出せる）

    /// 答えのボタンの形。choices があれば text 以外は選ぶ形（kind number など、知らない answer の形でも）
    static func answerStyle(answer: String, choices: [String]?) -> String {
        if answer == "text" { return "text" }
        if let choices, !choices.isEmpty { return "pick" }
        return answer == "pick" ? "pick" : "yesno"
    }

    /// 通知・時計・ウィジェットで ○× で答えてよいか（はい・いいえの問いだけ）
    static func isYesNo(answer: String, choices: [String]?) -> Bool { answerStyle(answer: answer, choices: choices) == "yesno" }

    // MARK: - 楽15 電車の中で「いま 3 問だけ」

    /// 知らせるか（オン・電車の中・確かめ待ちがある・今日まだ知らせていない）
    static func trainNudgeDue(on: Bool, isTrain: Bool, waiting: Int, lastDay: String?, today: String) -> Bool {
        on && isTrain && waiting > 0 && lastDay != today
    }

    // MARK: - 楽16 会話が終わってすぐ「誰と話した？」（初めはオフ・1 日 3 回まで）

    static let whoPerDay = 3

    /// 聞くか（オン・閉じて 15 分以内・名前の無い声が話した行が 4 行以上・まだ聞いていない会話・今日 3 回まで）
    static func whoNudgeDue(on: Bool, closed: Bool, end: Date, unnamedLines: Int, alreadyAsked: Bool, askedToday: Int,
                            now: Date) -> Bool {
        guard on, closed, !alreadyAsked, askedToday < whoPerDay, unnamedLines >= 4 else { return false }
        let age = now.timeIntervalSince(end)
        return age >= 0 && age <= 15 * 60
    }

    // MARK: - 楽5 報告の棚（GET /reports・/reports/<名前>。features "reports"）

    struct ReportsFeed: Codable, Equatable, Sendable {
        struct Report: Codable, Equatable, Identifiable, Sendable {
            var name: String
            var title: String
            var updated_at: String? = nil
            var bytes: Int? = nil
            var id: String { name }
        }
        var generated_at: String? = nil
        var reports: [Report] = []
    }

    /// 職場の中身の報告は出さない（P が出さない一覧で絞る。アプリでも念のため名前と題で外す）
    static let hiddenReportWords = ["work", "職場", "仕事", "客先", "office"]

    static func visibleReports(_ feed: ReportsFeed) -> [ReportsFeed.Report] {
        feed.reports.filter { report in
            let text = (report.name + " " + report.title).lowercased()
            return isSafeReportName(report.name) && !hiddenReportWords.contains { text.contains($0) }
        }
        .sorted { ($0.updated_at ?? "", $0.name) > ($1.updated_at ?? "", $1.name) }
    }

    /// 道に入れてよい名前（"/" と ".." を含まない・空でない・120 文字まで）
    static func isSafeReportName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && !name.contains("/") && !name.contains("..") && !name.contains("\\")
    }

    /// 「12 KB」
    static func sizeText(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return bytes < 1024 ? "\(bytes) B" : "\(max(1, bytes / 1024)) KB"
    }

    // MARK: - 楽20 いつも録れない場所・時間帯（GET /capture-gap-patterns。features "gappatterns"）

    struct GapPatterns: Codable, Equatable, Sendable {
        struct Hour: Codable, Equatable, Sendable {
            var weekday: Int
            var hour: Int
            var gap_minutes: Double
            var days: Int? = nil
        }
        struct Place: Codable, Equatable, Identifiable, Sendable {
            var place: String
            var gap_minutes: Double
            var days: Int? = nil
            var lat: Double? = nil
            var lon: Double? = nil
            var id: String { place }
        }
        var generated_at: String? = nil
        var by_hour: [Hour] = []
        var by_place: [Place] = []
    }

    /// 曜日の言い方（weekday は 0 が月曜。母艦の Python の weekday() と同じとみる。仮）
    static let weekdayLabels = ["月", "火", "水", "木", "金", "土", "日"]

    /// 7 × 24 の表（録れなかった分。無い所は 0）
    static func gapGrid(_ patterns: GapPatterns) -> [[Double]] {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for h in patterns.by_hour where (0..<7).contains(h.weekday) && (0..<24).contains(h.hour) {
            grid[h.weekday][h.hour] += max(0, h.gap_minutes)
        }
        return grid
    }

    /// 長い順に limit 個「火 13 時 平均 40 分（5 日）」
    static func worstHours(_ patterns: GapPatterns, limit: Int = 5) -> [String] {
        patterns.by_hour.filter { (0..<7).contains($0.weekday) && $0.gap_minutes > 0 }
            .sorted { ($0.gap_minutes, -$0.weekday * 100 - $0.hour) > ($1.gap_minutes, -$1.weekday * 100 - $1.hour) }
            .prefix(max(0, limit))
            .map { "\(weekdayLabels[$0.weekday]) \($0.hour) 時 " + S22Watch.durationText($0.gap_minutes * 60) + ($0.days.map { "（\($0) 日）" } ?? "") }
    }
}

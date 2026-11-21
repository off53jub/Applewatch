import Foundation

/// s21（2026-11-22）の iPhone の決まり（決まった入力から決まった出力だけ。docs/s21-app.md）。
/// 番号は母艦に出した s21 の案の番号（使・精・速・電・守）。しきい値はどれも仮。テストは LifeLogTests/S21Tests.swift。
/// 新しい言語モデルの呼び出しは作っていない（0 円）。

// MARK: - 使1 電池優先・早さ優先・精度優先

enum S21Preset: String, CaseIterable, Identifiable, Sendable {
    case battery, speed, accuracy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .battery: "電池優先"
        case .speed: "早さ優先"
        case .accuracy: "精度優先"
        }
    }

    var symbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .speed: "hare"
        case .accuracy: "scope"
        }
    }

    /// まとめて切り替えるスイッチ（nil はそのまま）。個別のスイッチはそのまま残る（あとから 1 つずつ変えられる）
    struct Values: Equatable, Sendable {
        var chunkLength: ChunkCutter.Length? = nil
        var batterySaver: Bool? = nil
        var skipSilence: Bool? = nil
        var dropNoVoice: Bool? = nil
        var standby: Bool? = nil
        var watchDirect: Bool? = nil
        var watchRelay: Bool? = nil
        var useCloud: Bool? = nil
        var correction: Bool? = nil
        var speakers: Bool? = nil

        /// 変えるスイッチの数
        var count: Int {
            [chunkLength != nil, batterySaver != nil, skipSilence != nil, dropNoVoice != nil, standby != nil,
             watchDirect != nil, watchRelay != nil, useCloud != nil, correction != nil, speakers != nil].filter { $0 }.count
        }
    }

    /// 組（案の表のとおり）。高精度の文字起こしは、キーがあるときだけオンにする
    func values(hasCloudKey: Bool) -> Values {
        switch self {
        case .battery:
            // 直接送るはオフ（「直接＋PC から受け取る」でもよいと案にある。時計の無線を 1 回にするほうを先に選んだ。仮）
            return Values(chunkLength: .normal, batterySaver: true, skipSilence: true, dropNoVoice: true,
                          standby: false, watchDirect: false)
        case .speed:
            return Values(chunkLength: .short, standby: true, watchDirect: true, watchRelay: true)
        case .accuracy:
            return Values(chunkLength: .short, dropNoVoice: false, useCloud: hasCloudKey ? true : nil,
                          correction: true, speakers: true)
        }
    }

    /// いまの設定がどの組と同じか（どれでもなければ nil）
    static func matching(_ current: Values, hasCloudKey: Bool) -> S21Preset? {
        allCases.first { preset in
            let want = preset.values(hasCloudKey: hasCloudKey)
            func same<T: Equatable>(_ a: T?, _ b: T?) -> Bool { a == nil || a == b }
            return same(want.chunkLength, current.chunkLength) && same(want.batterySaver, current.batterySaver)
                && same(want.skipSilence, current.skipSilence) && same(want.dropNoVoice, current.dropNoVoice)
                && same(want.standby, current.standby) && same(want.watchDirect, current.watchDirect)
                && same(want.watchRelay, current.watchRelay) && same(want.useCloud, current.useCloud)
                && same(want.correction, current.correction) && same(want.speakers, current.speakers)
        }
    }
}

enum S21Rules {
    // MARK: - 使2 自己点検の「最近のエラー」から進み具合の文を外す

    /// 進み具合の文か（「日本語モデルを確認中…」など。エラーではない）。
    /// 「…」「...」で終わり、できなかった・失敗・ありません の言葉が無いもの
    static func isProgress(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("…") || t.hasSuffix("...") else { return false }
        let bad = ["できません", "できなかった", "ませんでした", "失敗", "エラー", "ありません", "止まり"]
        return !bad.contains { t.contains($0) }
    }

    // MARK: - 使3 朝の点検に足す 1 行

    /// 「録れた時間 9時間40分・止まりかけ 2 回（自動で戻した 2 回）・アプリが止められていた 1 回・録れなかった時間帯 13:10〜13:40、15:00〜15:25」
    static func morningExtra(recordedMinutes: Int, stalls: Int?, autoResumed: Int?, exits: Int?,
                             gaps: [(start: Date, end: Date)], calendar: Calendar = .current, limit: Int = 3) -> String {
        var parts: [String] = ["録れた時間 " + S21Watch.durationText(Double(recordedMinutes) * 60)]
        if let stalls, stalls > 0 {
            parts.append("止まりかけ \(stalls) 回" + (autoResumed.map { "（自動で戻した \($0) 回）" } ?? ""))
        }
        if let exits, exits > 0 { parts.append("時計のアプリが止められていた \(exits) 回") }
        func clock(_ d: Date) -> String {
            String(format: "%d:%02d", calendar.component(.hour, from: d), calendar.component(.minute, from: d))
        }
        let longest = gaps.sorted { $0.end.timeIntervalSince($0.start) > $1.end.timeIntervalSince($1.start) }.prefix(limit)
        let ordered = longest.sorted { $0.start < $1.start }
        if !ordered.isEmpty {
            parts.append("録れなかった時間帯 " + ordered.map { clock($0.start) + "〜" + clock($0.end) }.joined(separator: "、")
                         + (gaps.count > limit ? " ほか" : ""))
        }
        return parts.joined(separator: "・")
    }

    // MARK: - 使6 抜けの理由（止まりかけ・アプリが止められていた）

    /// 抜けのあいだ（とその 5 分前から）に止まりかけ・アプリが止められていたことがあれば、その理由。無ければ nil
    static func gapReason(start: Date, end: Date, stalls: [Date], exits: [(alive: Date, relaunch: Date)]) -> String? {
        if exits.contains(where: { $0.alive < end && $0.relaunch > start }) {
            return "時計のアプリが止められていた（watchOS に終わらされた・落ちた）"
        }
        let from = start.addingTimeInterval(-5 * 60)
        if stalls.contains(where: { $0 >= from && $0 <= end }) {
            return "時計の録音が止まりかけていた（マイクが来ない・流し直せない。自動で試し直し）"
        }
        return nil
    }

    // MARK: - 使7 時計でいちばん長く話している声から自分の候補

    struct VoiceLine: Equatable, Sendable {
        var speaker: String?
        /// 音声のファイルの名前（時計の区切りは「-w.m4a」で終わる）
        var audio: String?
        /// 行の長さ（秒。分からなければ 0）
        var seconds: Double
    }

    struct SelfCandidate: Equatable, Sendable {
        let id: String
        let seconds: Double
        let lines: Int
    }

    /// 時計の区切りの行で、名前の無い声ごとの話した時間（長い順に limit 人。○× で「違う」にした声は出さない）
    static func selfCandidates(_ lines: [VoiceLine], unnamed: Set<String>, rejected: Set<String>,
                               minLines: Int = 10, limit: Int = 3) -> [SelfCandidate] {
        var seconds: [String: Double] = [:], counts: [String: Int] = [:]
        for line in lines {
            guard let id = line.speaker, unnamed.contains(id), !rejected.contains(id),
                  line.audio?.hasSuffix("-w.m4a") == true else { continue }
            seconds[id, default: 0] += max(0, line.seconds)
            counts[id, default: 0] += 1
        }
        return seconds.compactMap { id, s -> SelfCandidate? in
            let n = counts[id] ?? 0
            return n >= minLines ? SelfCandidate(id: id, seconds: s, lines: n) : nil
        }
        .sorted { ($0.seconds, $0.lines, $1.id) > ($1.seconds, $1.lines, $0.id) }
        .prefix(max(0, limit)).map { $0 }
    }

    // MARK: - 使9 同期の相手から外す

    /// この端末より古い版の相手（外した相手は出さない）
    static func olderPeers(_ peers: [String: Int], mine: Int, excluded: Set<String>) -> [(device: String, build: Int)] {
        peers.filter { $0.value < mine && !excluded.contains($0.key) }
            .map { (device: $0.key, build: $0.value) }
            .sorted { $0.device < $1.device }
    }

    // MARK: - 使10 振って「いまの画面が変」

    /// POST /feedback の 1 行（家の PC の担当 P と合わせた形: {"kind":"shake","screen","note"?,"at"}）。
    /// 画面の名前は 60 文字・ひとことは 300 文字まで。画面の名前が空なら nil
    static func shakeBody(screen: String, note: String?, at: Date, timeZone: TimeZone = .current) -> Data? {
        let name = screen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        var object: [String: String] = ["kind": "shake", "screen": String(name.prefix(60)), "at": f.string(from: at)]
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            object["note"] = String(note.prefix(300))
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - 使11 Groq につながらない

    /// 「につながらない」たぐいの理由か（自己点検のエラーにせず、家の PC か端末内に回す）
    static func isUnreachable(_ reason: String) -> Bool {
        reason.contains("に接続できませんでした") || reason.contains("つながりません")
    }

    /// つながらなかったあと、これだけは高精度（クラウド）を試さない（仮）
    static let cloudRestAfterUnreachable: TimeInterval = 10 * 60

    // MARK: - 精5 誤変換直しで落ちる型

    /// 直しの型（落ちた・弾いた理由の数に使う）
    static func fixKind(original: String, fixed: String) -> String {
        let a = stripped(original), b = stripped(fixed)
        if a == b { return "marks" }  // 句読点・空白だけ
        let longer = max(original.count, fixed.count)
        if longer > 0, Double(abs(original.count - fixed.count)) / Double(longer) > 0.5 { return "length" }
        if digits(original) != digits(fixed) { return "number" }
        let ratio = editRatio(a, b)
        if ratio > 0.6 { return "rewrite" }
        if katakana(original) != katakana(fixed) { return "name" }
        return ratio <= 0.2 ? "small" : "other"
    }

    /// 出す前に弾く直し（理由。弾かなければ nil）。句読点・空白だけの直しと、行の大部分を書き換えた直しは、
    /// 2 つ目の見比べで落ちやすい型（と見ている。仮）なので、見比べに回す前に元に戻す。短い行（5 文字以下）は弾かない
    static func preReject(original: String, fixed: String) -> String? {
        guard !fixed.isEmpty, fixed != original else { return nil }
        let kind = fixKind(original: original, fixed: fixed)
        if kind == "marks" { return kind }
        guard original.count > 5 else { return nil }
        return kind == "length" || kind == "rewrite" ? kind : nil
    }

    /// 2 つの文の違いの割合（0 は同じ・1 は全部違う。文字ごとの編集距離 ÷ 長いほうの長さ）
    static func editRatio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        guard !x.isEmpty, !y.isEmpty else { return 1 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    private static func stripped(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
            && !"、。！？「」・".unicodeScalars.contains($0) })
    }

    private static func digits(_ s: String) -> String { s.filter(\.isNumber) }

    private static func katakana(_ s: String) -> String {
        String(s.unicodeScalars.filter { (0x30A1...0x30FA).contains($0.value) })
    }

    // MARK: - 速1 待ち合わせ（POST /jobs?wait=1）を付けるか

    /// 付けるか・付けないわけ（tally の jobs.wait.<わけ> に数える）
    static func jobWait(accepts: Bool, staged: Int, maxWaiting: Int) -> (wait: Bool, reason: String) {
        guard accepts else { return (false, "noFeature") }
        guard staged < maxWaiting else { return (false, "busy") }
        return (true, "on")
    }

    // MARK: - 速2 iPhone が受け取った時計の区切りの名前を時計に渡す

    /// 時計の返事待ちがこれ以上あれば、受け取った名前の一覧を渡す（1 時間に 1 回まで。仮）
    static let gotListKept = 30
    static let gotListEvery: TimeInterval = 3600

    static func gotListDue(kept: Int?, lastSent: Date?, now: Date) -> Bool {
        guard let kept, kept >= gotListKept else { return false }
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= gotListEvery
    }

    /// 渡す名前（時計の区切り「-w.m4a」だけ・2 日以内・新しい順に limit 個）
    static func gotListNames(_ received: [String: Double], now: Date, within: TimeInterval = 2 * 86400,
                             limit: Int = 1500) -> [String] {
        let t = now.timeIntervalSince1970
        return received.filter { $0.key.hasSuffix("-w.m4a") && t - $0.value < within }
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .prefix(max(0, limit)).map(\.key)
    }

    // MARK: - 速7 取り消される Claude の呼び出しを、出す前に止める

    /// Claude に頼みはじめてよいか。止められている（cancelled）・裏で残り時間が足りないときは頼まない
    static func claudeStartAllowed(cancelled: Bool, background: Bool, remaining: TimeInterval, needed: TimeInterval) -> Bool {
        if cancelled { return false }
        guard background else { return true }
        return remaining >= needed
    }

    /// 頼むのに要る残り時間の目安（答えを待つ長さ。25〜60 秒に収める。仮）
    static func claudeNeeded(timeout: TimeInterval) -> TimeInterval { max(25, min(timeout, 60)) }

    // MARK: - 電2 「PC に直接送る」と「iPhone 経由だけ」を 1 日ずつ入れ替える

    enum Route: String, Sendable {
        case direct, phone

        var label: String { self == .direct ? "PC に直接送る" : "iPhone 経由だけ" }
    }

    static let routeOnKey = "s21.routeExpOn"
    static let routeStartKey = "s21.routeExpStart"
    static let routeDays = 4
    static let routePlan: [Route] = [.direct, .phone, .direct, .phone]

    /// その日の組（オフ・始まりの日が無い・4 日の外なら nil＝いつもどおり）
    static func route(on: Bool, start: String?, now: Date, calendar: Calendar = .current) -> Route? {
        guard on, let start, let first = RecordingExperiment.date(start, calendar: calendar) else { return nil }
        guard let offset = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day,
              offset >= 0, offset < routeDays else { return nil }
        return routePlan[offset]
    }

    /// 実験が終わったか（始まりの日から 4 日たった。録り方の実験と同じ数え方）
    static func routeFinished(start: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let start, let first = RecordingExperiment.date(start, calendar: calendar) else { return false }
        return (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day ?? 0) >= routeDays
    }

    /// 時計に「直接送る」を渡してよいか（実験の「iPhone 経由だけ」の日は渡さない）
    static func allowsDirect(_ route: Route?) -> Bool { route != .phone }

    // MARK: - 守4 時計の便りが 10 分途切れた

    /// これだけ便りが無ければ途切れたとみなす（前は 15 分。仮）
    static let watchQuiet: TimeInterval = 10 * 60

    enum SilenceAction: String, CaseIterable, Identifiable, Sendable {
        /// 知らせるだけ（初め）
        case notify
        /// 知らせて、iPhone で録り始める
        case record

        var id: String { rawValue }
        var label: String { self == .notify ? "知らせるだけ" : "知らせて iPhone で録り始める" }
    }

    static let silenceActionKey = "s21.watchSilenceAction"

    /// iPhone で録り始めるか（設定が「録り始める」・時計が録っているはずだった・iPhone は録っていない・休む場所でない）
    static func shouldStartPhone(action: SilenceAction, watchWanted: Bool, phoneRecording: Bool, held: Bool) -> Bool {
        action == .record && watchWanted && !phoneRecording && !held
    }

    // MARK: - 守5 iPhone と時計の版のずれ

    /// 自己点検の 1 行（時計の版が分からなければ nil）
    static func buildCheck(phone: Int, watch: String?) -> (text: String, ok: Bool)? {
        guard let watch, let w = Int(watch) else { return nil }
        if w == phone { return ("同じ（\(w)）", true) }
        if w < phone { return ("時計 \(w)・iPhone \(phone)（時計の LifeLog を一度開くと新しくなります）", false) }
        return ("時計 \(w)・iPhone \(phone)（iPhone のほうが古い）", false)
    }
}

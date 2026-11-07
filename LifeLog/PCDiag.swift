import Foundation
import SwiftUI
import UIKit

// 実機の様子を家の PC に送る（POST /diag。docs/v7-plan.md の 1。2026-11-07）。
// 1時間に1回ほど・アプリを開いたとき・見えない通知で起きたときに、自己点検の行・落ちた記録・まだ送っていない
// MetricKit の診断・効き目の数（今日と昨日）・今の状態・見えない通知の宛先を送る。LifeLog PC の版 7 から
// （/hello の features に "diag" があるときだけ）。会話の中身・人の名前・メールアドレスは入れない
// （自己点検の行にも入れない決まりだが、エラーの文などに混ざっても送らないよう、名前とメールアドレスは消してから送る）。

// MARK: - JSON の決まり

/// 家の PC（版 7）とやり取りする JSON の決まり。日時は ISO 8601・UTC・ミリ秒つき（例 "2026-11-07T06:58:25.123Z"）。
/// PC から来る日時は、ミリ秒なし・「+09:00」のような時差つき・小数が3桁でないものも読む
enum PCJSON {
    private static let millis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 日時を書く。ミリ秒は四捨五入する（書いて読み直しても同じ文字になるように）
    static func string(_ date: Date) -> String {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (ms / 1000).rounded(.down)
        let fraction = Int(ms - seconds * 1000)
        // 秒までを ISO8601DateFormatter で書き（UTC なので終わりは Z）、ミリ秒を足す
        let head = whole.string(from: Date(timeIntervalSince1970: seconds))
        return String(head.dropLast()) + String(format: ".%03dZ", fraction)
    }

    static func date(_ text: String) -> Date? {
        if let parsed = millis.date(from: text) ?? whole.date(from: text) { return parsed }
        // 小数の桁が3つでない（PC の Python がマイクロ秒で書いた など）ときは、3桁にそろえて読む
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let rest = text[text.index(after: dot)...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let three = String((String(digits) + "000").prefix(3))
        return millis.date(from: String(text[..<dot]) + "." + three + String(rest.dropFirst(digits.count)))
    }

    /// アプリの日の名前（yyyy-MM-dd。端末の暦・時刻の日）
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 記録などを JSON にする（日時は上の書き方。中身が同じなら同じ JSON になるよう、名前の順に並べる）
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { value, target in
            var container = target.singleValueContainer()
            try container.encode(PCJSON.string(value))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let text = try container.decode(String.self)
            guard let parsed = PCJSON.date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "日時の書き方が違います")
            }
            return parsed
        }
        return decoder
    }

    /// 行の時刻が同じか。PC から戻ってくる時刻はミリ秒までなので、1ms 未満の差は同じとみなす
    static func sameTime(_ line: Date, _ other: Date) -> Bool {
        if abs(line.timeIntervalSince(other)) < 0.001 { return true }
        // こちらが書いた文字をそのまま返してきたときは、書いて読み直した時刻とも比べる（小数の端で外れないように）
        guard let written = date(string(line)) else { return false }
        return abs(written.timeIntervalSince(other)) < 0.0005
    }
}

// MARK: - 様子の中身

/// 家の PC に送る様子を作る（端末から読むところと分けて、テストできるようにしてある）
enum PCDiag {
    private static let onKey = "pcDiagOn"
    private static let sentKey = "pcDiagSentAt"
    private static let resultKey = "pcDiagResult"
    private static let deviceKey = "pcDiagDeviceID"
    private static let watchSeenKey = "pcWatchSeenAt"
    private static let watchKeptKey = "pcWatchKept"
    /// 時計に残っている区切りの内訳（2026-11-07）
    static let watchDetailKey = "pcWatchDelivery"
    private static let nightlyKey = "pcNightlyDoneFor"

    /// 送る間隔（1時間に1回ほど）
    static let every: TimeInterval = 3600
    /// 1回に送る大きさの上限（PC は 2MB まで受け取る）
    static let bodyLimit = 2_000_000
    /// 落ちた記録と MetricKit の診断を合わせた大きさの上限
    static let crashLimit = 1_000_000

    /// 「家の PC に様子を送る」（設定。初めはオン）
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: onKey) }
    }

    /// 端末ごとの印（UUID。名前は入れない）
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: deviceKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    /// 最後に送れた時刻
    static var lastSent: Date? {
        get { UserDefaults.standard.object(forKey: sentKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: sentKey) }
    }

    /// 最後に送ったときの結果（画面と自己点検に出す）
    static var lastResult: String {
        get { UserDefaults.standard.string(forKey: resultKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: resultKey) }
    }

    /// 時計から最後に知らせが来た時刻
    static var watchSeenAt: Date? {
        get { UserDefaults.standard.object(forKey: watchSeenKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: watchSeenKey) }
    }

    /// 時計が iPhone に送っていない（返事を待っている）区切りの数
    static var watchUnsent: Int? {
        get { UserDefaults.standard.object(forKey: watchKeptKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: watchKeptKey) }
    }

    /// 最後に区切りができた・届いた時刻（state の lastChunkAt・lastWatchChunkAt・lastPhoneChunkAt）。
    /// 帳簿の区切りは、届いた時刻（時計）か終わり（iPhone）か始まり。待ちのファイルは、書いた時刻。取り込んだ音声は入れない。
    /// watch が true なら時計の区切り（名前の終わりが -w）だけ、false なら iPhone の区切りだけ、nil なら両方。
    ///
    /// 2026-11-07 の実機の点検で「録音中なのに、区切りが 13.8 時間できていません（最後は 11/06 21:35）」と出たときに確かめたこと:
    /// その日の記録には、時計の区切り（-w）の行が1つも無く（前の日の最後は 21:13 に始まった区切り。届くまで 18 分ほど）、
    /// iPhone の文字起こし待ちも 0 だった（その日の行は -w の付かない区切りで、同期で届いた iPad の分とみられる。推測）。
    /// つまりこの値はたぶん正しく、時計の区切りが iPhone に届いていなかった。時計の kept（様子の watchUnsent）は
    /// 「送り終えて返事を待っている数」で、時計がまだ送っていない区切りは入っていないので、0 でも届いているとは限らない。
    /// 届かないわけは、時計→iPhone の受け渡しの側で調べる。
    static func lastChunk(_ chunks: [RecordingLedger.Chunk], pending: [(name: String, modified: Date?)],
                          watch: Bool? = nil) -> Date? {
        var latest: Date?
        func note(_ date: Date?) {
            guard let date else { return }
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        for chunk in chunks where chunk.source != "import" {
            if let watch, (chunk.source == "watch") != watch { continue }
            note(chunk.received ?? chunk.end ?? chunk.start)
        }
        for file in pending {
            let url = URL(fileURLWithPath: file.name)
            guard !Storage.isImported(url) else { continue }
            if let watch, Storage.isFromWatch(url) != watch { continue }
            note(file.modified)
        }
        return latest
    }

    /// 夜の処理を、どの日の夜の分まで済ませたか（yyyy-MM-dd）
    static var nightlyDoneFor: String? {
        get { UserDefaults.standard.string(forKey: nightlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: nightlyKey) }
    }

    static func isDue(lastSent: Date?, now: Date) -> Bool { now.timeIntervalSince(lastSent ?? .distantPast) >= every }

    static var statusText: String {
        guard isOn else { return "オフ" }
        return lastResult.isEmpty ? "まだ送っていません" : lastResult
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    /// 画面に出す時刻（「11/7 10:00」）
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    // MARK: 夜の処理

    /// その時刻に済んだ夜の処理が、どの日の夜の分か（18時〜翌12時を、始まった日の夜とする）。昼（12〜18時）は nil
    static func nightKey(for date: Date, calendar: Calendar = .current) -> String? {
        let hour = calendar.component(.hour, from: date)
        if hour >= 12 && hour < 18 { return nil }
        let base = hour < 12 ? (calendar.date(byAdding: .day, value: -1, to: date) ?? date) : date
        return PCJSON.dayString(base, calendar: calendar)
    }

    /// 夜の処理がまだか（届いた時刻の「ゆうべ」の分が済んでいなければ true）
    static func nightlyPending(doneFor: String?, now: Date, calendar: Calendar = .current) -> Bool {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let wanted = nightKey(for: now, calendar: calendar) ?? PCJSON.dayString(yesterday, calendar: calendar)
        return doneFor != wanted
    }

    // MARK: 中身

    private static let emailPattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)

    /// 人の名前とメールアドレスを消す
    static func scrub(_ text: String, names: [String]) -> String {
        var out = text
        if let emailPattern {
            out = emailPattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                        withTemplate: "（メールアドレス）")
        }
        // 長い名前から（「田中太郎」を「田中」より先に）
        for name in Set(names).filter({ $0.count >= 2 }).sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: name, with: "（名前）")
        }
        return out
    }

    /// 落ちた記録の種類（PC が見分けやすい英語の名前）
    static func crashKind(_ label: String) -> String {
        switch label {
        case "落ちた": return "crash"
        case "固まった": return "hang"
        case "書き込みが多すぎた": return "diskWrite"
        case "CPU を使いすぎた": return "cpu"
        default: return "other"
        }
    }

    /// 端末のこと
    struct Device {
        var deviceID: String
        /// iPhone か iPad
        var device: String
        /// 機種の名前（例 iPhone17,1）
        var model: String
        var os: String
        var build: Int
        /// testflight・sideload・other
        var install: String
    }

    /// 機種の名前（例 iPhone17,1。シミュレーターでは、まねている機種）
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// 送る中身（JSON にできる形）。metrickit は、まだ送っていない MetricKit の診断を読んだもの
    static func payload(device: Device, sentAt: Date, reason: String, rows: [DiagnosticItem], names: [String],
                        crashes: [CrashWatch.Event], metrickit: [Any], tally: [String: [String: Int]],
                        state: [String: Any], push: [String: Any]?) -> [String: Any] {
        var rowList: [[String: Any]] = []
        for item in rows {
            var row: [String: Any] = [:]
            row["group"] = item.section
            row["name"] = scrub(item.label, names: names)
            row["value"] = scrub(item.value, names: names)
            if let ok = item.ok { row["ok"] = ok } else { row["ok"] = NSNull() }
            rowList.append(row)
        }
        var crashList: [[String: Any]] = []
        for event in crashes {
            var crash: [String: Any] = [:]
            crash["kind"] = crashKind(event.kind)
            crash["label"] = event.kind
            crash["at"] = PCJSON.string(event.at)
            crash["detail"] = scrub(event.detail, names: names)
            crashList.append(crash)
        }
        var body: [String: Any] = [:]
        body["deviceID"] = device.deviceID
        body["device"] = device.device
        body["model"] = device.model
        body["os"] = device.os
        body["build"] = device.build
        body["install"] = device.install
        body["sentAt"] = PCJSON.string(sentAt)
        body["reason"] = reason
        body["rows"] = rowList
        body["crashes"] = crashList
        body["metrickit"] = metrickit
        body["tally"] = tally
        body["state"] = state
        if let push { body["push"] = push }
        return body
    }

    /// JSON にする（作れない・大きすぎるときは nil）
    static func encode(_ body: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              data.count <= bodyLimit else { return nil }
        return data
    }

    /// 送る MetricKit の診断（古い順に、budget バイトまで）。読めないものと、1つで大きすぎるものは捨てる
    static func metricKit(from files: [URL], budget: Int) -> (objects: [Any], files: [URL]) {
        var objects: [Any] = []
        var picked: [URL] = []
        var used = 0
        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard data.count <= budget, let object = try? JSONSerialization.jsonObject(with: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard used + data.count <= budget else { break }
            used += data.count
            objects.append(object)
            picked.append(url)
        }
        return (objects, picked)
    }
}

// MARK: - 家の PC の版が古い、の知らせ

/// アプリは版 7 を前提にしたが、PC はしばらく版 6 のままのことが多い（文字起こしはそのまま使える）。
/// 古い版の知らせは、同じ版の組み合わせなら7日に1回まで（前は12時間ごとに出ていた。2026-11-07）
enum PCVersionNotice {
    static let key = "homePCVersionWarned"
    static let every: TimeInterval = 7 * 24 * 3600

    static func shouldWarn(pc: Int, app: Int, now: Date, defaults: UserDefaults = .standard) -> Bool {
        guard pc < app else { return false }
        guard let saved = defaults.dictionary(forKey: key), (saved["pair"] as? String) == "\(pc)-\(app)",
              let at = saved["at"] as? Date else { return true }
        return now.timeIntervalSince(at) >= every
    }

    static func noteWarned(pc: Int, app: Int, now: Date, defaults: UserDefaults = .standard) {
        defaults.set(["pair": "\(pc)-\(app)", "at": now] as [String: Any], forKey: key)
    }
}

// MARK: - やり取りの様子（Pipeline の外に持つ）

@MainActor
final class PCLinkState {
    static let shared = PCLinkState()
    /// 様子を送っている最中か・最後に送ろうとした時刻
    var diagBusy = false
    var diagTried = Date.distantPast
    /// 記録と直しをやり取りしている最中か・最後にやり取りしようとした時刻
    var recordsBusy = false
    var recordsTried = Date.distantPast
    /// PC の直しを当てた日を、まだ送り直せていない（次のやり取りを10分待たずに1分で）
    var recordsSoon = false
    /// 見えない通知で起きて動いている最中（そのあいだは、列の終わりからは送らない。通知の動きが最後に送る）
    var pushActive = false
}

/// 裏にいても、送り終わるまで iOS に少し待ってもらう（時間切れになったら、待ってもらうのをやめる）
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid
    /// 時間切れになった（iOS がこのあとアプリを止める。2026-11-07）
    private(set) var expired = false

    init(_ name: String) {
        // 時間切れの知らせは、いつもメインスレッドに来る
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expired = true
                self.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

// MARK: - 送る

extension Pipeline {
    /// 処理の列が終わるたびに呼ぶ（runQueue の最後）。様子は1時間に1回、記録と直しは10分に1回まで
    func pcLinkTick() {
        let now = Date.now
        let link = PCLinkState.shared
        guard !link.pushActive else { return }
        let diag = PCDiag.isOn && PCDiag.isDue(lastSent: PCDiag.lastSent, now: now)
            && now.timeIntervalSince(link.diagTried) >= 10 * 60
        let records = PCRecords.isDue(lastTried: link.recordsTried, now: now, soon: link.recordsSoon)
        startPCLink(diag: diag, records: records, reason: "hourly")
    }

    /// アプリを開いたときに呼ぶ（appBecameActive）。様子はすぐ（2分に1回まで）、記録と直しは10分に1回まで
    func pcLinkOnActive() {
        let now = Date.now
        let link = PCLinkState.shared
        startPCLink(diag: PCDiag.isOn && now.timeIntervalSince(link.diagTried) >= 120,
                    records: PCRecords.isDue(lastTried: link.recordsTried, now: now, soon: link.recordsSoon), reason: "open")
    }

    private func startPCLink(diag: Bool, records: Bool, reason: String) {
        let sendRecords = records && PCRecords.isSender
        guard homePC.shouldTry, diag || sendRecords else { return }
        Task {
            let time = BackgroundTime("pcLink")
            defer { time.end() }
            // 裏にいるときは、iOS が待ってくれるあいだに収める
            let deadline = Self.pcDeadline()
            if sendRecords { await exchangePCRecords(until: deadline) }
            if diag { await sendPCDiag(reason: reason) }
        }
    }

    /// 裏にいるときは、iOS が待ってくれる時刻の少し前（前にいるときは nil）
    static func pcDeadline() -> Date? {
        guard UIApplication.shared.applicationState != .active else { return nil }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        guard remaining < 3600 else { return nil }
        return Date.now.addingTimeInterval(max(3, remaining - 5))
    }

    /// 様子を家の PC に送る。結果の一文を返す（設定がオフ・PC の設定が無い・少し前につながらなかった・送っている最中なら nil）
    @discardableResult
    func sendPCDiag(reason: String, timeout: TimeInterval = 20) async -> String? {
        guard PCDiag.isOn, homePC.shouldTry else { return nil }
        let link = PCLinkState.shared
        guard !link.diagBusy else { return nil }
        link.diagBusy = true
        defer { link.diagBusy = false }
        link.diagTried = .now
        // 裏で起こされたばかりだと、PC にできること（features）をまだ聞いていない
        if homePC.version == nil {
            do {
                _ = try await homePC.hello()
            } catch {
                PCDiag.lastResult = "家の PC につながりませんでした（\(PCDiag.clock(.now))）"
                return PCDiag.lastResult
            }
        }
        guard homePC.features.contains("diag") else {
            PCDiag.lastResult = "家の PC がまだ様子を受け取れません（LifeLog PC を版 7 にすると送ります）"
            return PCDiag.lastResult
        }
        guard let built = await pcDiagBody(reason: reason) else {
            PCDiag.lastResult = "様子を作れませんでした"
            return PCDiag.lastResult
        }
        do {
            _ = try await homePC.postJSONData("diag", body: built.data, timeout: timeout)
            // 送った MetricKit の診断は iPhone から消す
            CrashWatch.removeRaw(built.files)
            PCDiag.lastSent = .now
            PCDiag.lastResult = "送りました（\(PCDiag.clock(.now))）"
            Tally.add("diag.sent")
        } catch {
            PCDiag.lastResult = "送れませんでした（\(PCDiag.clock(.now))）: " + HomePC.describe(error)
            Tally.add("diag.failed")
        }
        return PCDiag.lastResult
    }

    /// 送る中身と、その中に入れた MetricKit の診断のファイル（送れたら消す）
    func pcDiagBody(reason: String, now: Date = .now) async -> (data: Data, files: [URL])? {
        let items = await diagnosticItems()
        let names = await speakers.people().filter { !$0.isSelf }.compactMap(\.name)
        let crashes = CrashWatch.events
        let crashBytes = (try? JSONEncoder().encode(crashes))?.count ?? 0
        let raw = PCDiag.metricKit(from: CrashWatch.pendingRaw(), budget: max(0, PCDiag.crashLimit - crashBytes))
        let device = PCDiag.Device(deviceID: PCDiag.deviceID,
                                   device: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
                                   model: PCDiag.modelIdentifier, os: UIDevice.current.systemVersion,
                                   build: AppBuild.current, install: PushWake.install)
        var body = PCDiag.payload(device: device, sentAt: now, reason: reason, rows: items, names: names,
                                  crashes: crashes, metrickit: raw.objects, tally: Tally.days(2, now: now),
                                  state: pcDiagState(), push: PushWake.pushInfo())
        if let data = PCDiag.encode(body) { return (data, raw.files) }
        // 大きすぎる・作れないときは、MetricKit の診断を外して送る（診断は次の機会に）
        body["metrickit"] = [Any]()
        guard let data = PCDiag.encode(body) else { return nil }
        return (data, [])
    }

    /// 今の状態（分からない項目は入れない）
    func pcDiagState() -> [String: Any] {
        var state: [String: Any] = [:]
        state["phoneRecording"] = isRecording
        state["watchRecording"] = isWatchRecording
        state["queue"] = pendingCount
        state["jobsPending"] = PCJobUploader.stagedCount
        // 録音を休む場所にいる（書いていないのは正常）
        state["held"] = recordingHeld
        if let at = PCDiag.watchSeenAt { state["watchHeartbeatAt"] = PCJSON.string(at) }
        if let kept = PCDiag.watchUnsent { state["watchUnsent"] = kept }
        // 時計に残っている区切りの内訳（2026-11-07。時計の最後に区切った時刻は ISO 8601）
        for (key, value) in UserDefaults.standard.dictionary(forKey: PCDiag.watchDetailKey) ?? [:] {
            if key == "watchLastCut", let seconds = value as? Double {
                state[key] = PCJSON.string(Date(timeIntervalSince1970: seconds))
            } else {
                state[key] = value
            }
        }
        // 時計が静かで書くのを休んでいる（区切りが来ないのは正常）
        if isWatchRecording, let last = ledger.lastState { state["watchResting"] = last.resting }
        if let run = diagnostics.runs.last { state["lastProcessedAt"] = PCJSON.string(run.start.addingTimeInterval(run.seconds)) }
        if let chunk = lastChunkTime() { state["lastChunkAt"] = PCJSON.string(chunk) }
        // 時計の区切りと iPhone の区切りを分けても送る（2026-11-07）。時計が録音中なのに時計の区切りだけ届かない、が見分けられる
        if let chunk = lastChunkTime(watch: true) { state["lastWatchChunkAt"] = PCJSON.string(chunk) }
        if let chunk = lastChunkTime(watch: false) { state["lastPhoneChunkAt"] = PCJSON.string(chunk) }
        if let night = PCDiag.nightlyDoneFor { state["nightlyDoneFor"] = night }
        // 文字になるまでの区間ごとの中央値（直近24時間。秒。版 8。docs/v8-latency.md の 1。Latency.swift）
        if let latency = Latency.summary() { state["latency"] = latency.json }
        return state
    }

    /// 最後に区切りができた・届いた時刻（時計から届いた・iPhone で録り終えた・書いている途中のファイル）。
    /// watch が true なら時計の区切りだけ、false なら iPhone の区切りだけ、nil なら両方
    private func lastChunkTime(watch: Bool? = nil) -> Date? {
        let pending = Storage.pendingChunks().map { url in
            (name: url.lastPathComponent,
             modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        return PCDiag.lastChunk(ledger.chunks, pending: pending, watch: watch)
    }

    /// 時計から知らせが来るたびに呼ぶ（noteWatchState）。最後に来た時刻と、時計の控えの数を覚える
    func notePCWatchState(_ state: PhoneReceiver.WatchState) {
        if PCDiag.watchSeenAt.map({ state.at > $0 }) ?? true { PCDiag.watchSeenAt = state.at }
        // 「時計に残っている」は、まだ送っていない数＋返事待ちの数（新しい時計のアプリ）。古い時計のアプリでは返事待ちの数だけ（2026-11-07）
        if let left = state.leftOnWatch { PCDiag.watchUnsent = left }
        // 内訳（まだ送っていない・送っている途中・返事待ち・最後に区切った時刻・休む場所・録音しているつもりか）
        var detail: [String: Any] = [:]
        if let unsent = state.unsent { detail["watchPending"] = unsent }
        if let outstanding = state.outstanding { detail["watchOutstanding"] = outstanding }
        if let kept = state.kept { detail["watchKept"] = kept }
        if let cut = state.lastCut { detail["watchLastCut"] = cut.timeIntervalSince1970 }
        if let held = state.held { detail["watchHeld"] = held }
        if let wanted = state.wanted { detail["watchWanted"] = wanted }
        UserDefaults.standard.set(detail, forKey: PCDiag.watchDetailKey)
    }

    /// 夜の聞き直しが終わったときに呼ぶ（runNightly）。全部済んだら、どの日の夜の分かを覚える
    func notePCNightly(done: Bool) {
        guard done, let key = PCDiag.nightKey(for: .now) else { return }
        PCDiag.nightlyDoneFor = key
    }

    /// 自己点検の行（家の PC を使っているときだけ）
    func pcLinkRows() -> [(section: String, label: String, value: String, ok: Bool?)] {
        guard homePC.isConfigured else { return [] }
        var rows: [(section: String, label: String, value: String, ok: Bool?)] = []
        rows.append(("家の PC", "様子を送る", PCDiag.statusText, nil))
        // 署名に通知の許可が無い入れ方では登録できないが、それは不具合ではないので ✗ にはしない
        let pushOK: Bool? = PushWake.isRegistered ? true : nil
        rows.append(("家の PC", "見えない通知", PushWake.statusText, pushOK))
        if PCRecords.isSender {
            rows.append(("家の PC", "記録を送る", PCRecords.statusText, nil))
            rows.append(("家の PC", "PC で直した行", PCEdits.statusText, nil))
        }
        return rows
    }
}

// MARK: - 設定の画面

/// 家の PC の画面に足す「実機の様子・見えない通知・PC で直す」（2026-11-07）
struct PCLinkSection: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var diagOn = PCDiag.isOn
    @State private var sending = false
    @State private var note: String?

    var body: some View {
        Section {
            Toggle("家の PC に様子を送る", isOn: $diagOn)
                .onChange(of: diagOn) { _, on in PCDiag.isOn = on }
            LabeledContent("様子", value: PCDiag.statusText)
            LabeledContent("見えない通知", value: PushWake.statusText)
            if PCRecords.isSender {
                LabeledContent("記録を送る", value: PCRecords.statusText)
                LabeledContent("PC で直した行", value: PCEdits.statusText)
            }
            Button(sending ? "送っています…" : "今すぐ様子を送る") {
                sending = true
                Task {
                    let result = await pipeline.sendPCDiag(reason: "button")
                    note = result ?? "家の PC の設定が済んでいないか、少し前につながらなかったので、いまは送れません。"
                    sending = false
                }
            }
            .disabled(sending || !diagOn)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("実機の様子・見えない通知・PC で直す")
        } footer: {
            Text("様子（自己点検の行・落ちた記録・今の状態）を、1時間に1回ほどと開いたときに家の PC に送ります。会話の中身・人の名前・メールアドレスは入れません。家の PC は、見えない通知でこの iPhone を起こして、取り込みや送り出しを進めてもらえます（様子を送るのをオフにすると、通知の宛先も渡さないので起こせません）。記録（閉じた会話）も家の PC に送るので、PC の大きい画面で読んだり直したりでき、直した分はこの iPhone に戻ります（名前のある人を作ったり、まとめたりはしません）。どれも LifeLog PC の版 7 からです。")
        }
    }
}

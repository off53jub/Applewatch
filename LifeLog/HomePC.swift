import Foundation
import Observation
import Security

/// 家の PC で動かす LifeLog PC に区切りを送って、文字にしてもらう。
///
/// PC は Haas-ja・ReazonSpeech・Whisper large-v3 の3つで声の区間ごとに文字にし、多数決で選んだ文を返す（2026-11-05）。
/// 行ごとに、選んだ文の合い方（確からしさ）と、ほかのモデルの違う文（候補）も返ってくる。
/// 古い LifeLog PC（Haas-ja だけ）は確からしさを返さないので、そのときは今までどおり端末内と見比べる。
///
/// 送るのは 5 分の録音（AAC、約1.2MB）と、端末内の文字起こしで声があった区間だけ。声の無い区切りは送らない。
/// 宛先は家の Wi-Fi の中の住所（192.168.…）か、Tailscale の住所（100.…）。Tailscale なら外からもモバイル通信で届く。
/// PC が切れているときは、iPhone 内の Haas-ja かいつもの方法で文字にする。
@MainActor
@Observable
final class HomePC {
    static let port = 47615

    var enabled = UserDefaults.standard.bool(forKey: "homePCOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "homePCOn") }
    }
    var address = UserDefaults.standard.string(forKey: "homePCAddress") ?? "" {
        didSet { UserDefaults.standard.set(address, forKey: "homePCAddress"); forgetFailure() }
    }
    /// PC の多数決で食い違った行は、クラウドの Whisper（Groq など）にも聞いて、もう1票にする
    var cloudVote = UserDefaults.standard.object(forKey: "homePCCloudVote") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cloudVote, forKey: "homePCCloudVote") }
    }
    /// 最後に返ってきた PC のモデルの数（画面と「直近の文字起こし」に出す）
    private(set) var engineCount = 0
    /// モバイル通信でも送る（外にいるとき）
    var useCellular = UserDefaults.standard.object(forKey: "homePCCellular") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useCellular, forKey: "homePCCellular") }
    }
    private(set) var hasKey = PCKeychain.read() != nil
    /// 最後につながった・つながらなかったときのこと（設定画面に出す）
    private(set) var lastResult = ""
    /// 直近でつながらなかったら、しばらくは試さない（毎回、待ち時間で処理が遅れないように）
    private var failedAt: Date?
    private static let retryAfter: TimeInterval = 120

    var isConfigured: Bool { enabled && !address.trimmingCharacters(in: .whitespaces).isEmpty && hasKey }
    var shouldTry: Bool { isConfigured && (failedAt.map { Date().timeIntervalSince($0) > Self.retryAfter } ?? true) }

    func setKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { PCKeychain.delete() } else { PCKeychain.save(trimmed) }
        hasKey = PCKeychain.read() != nil
        forgetFailure()
    }

    func forgetFailure() { failedAt = nil }

    enum Failure: LocalizedError {
        case notConfigured, badAddress, unauthorized, server(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "家の PC の宛先と合言葉が入っていません"
            case .badAddress: "宛先の書き方が違います（例: my-pc.tail1234.ts.net:47615）"
            case .unauthorized: "合言葉が違います"
            case .server(let reason): "PC で文字にできませんでした: \(reason)"
            }
        }
    }

    private func baseURL() throws -> URL {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["http://", "https://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        while text.hasSuffix("/") { text.removeLast() }
        if !text.contains(":") { text += ":\(Self.port)" }
        guard !text.isEmpty, let url = URL(string: "http://" + text) else { throw Failure.badAddress }
        return url
    }

    private func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = useCellular
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: config)
    }

    private func request(_ path: String) throws -> URLRequest {
        guard let key = PCKeychain.read() else { throw Failure.notConfigured }
        var request = URLRequest(url: try baseURL().appendingPathComponent(path))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.unauthorized }
        guard status == 200 else {
            let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "HTTP \(status)"
            throw Failure.server(reason)
        }
    }

    /// つながるか確かめる（数秒で諦める）。
    func hello() async throws -> String {
        let session = makeSession(timeout: 6)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: try request("hello"))
        try Self.check(response, data: data)
        struct Hello: Decodable { let model: String; let provider: String }
        let hello = try JSONDecoder().decode(Hello.self, from: data)
        return "\(hello.model)（\(hello.provider == "cuda" ? "GPU" : "CPU")）"
    }

    /// PC が返す1行（声の区間1つ）
    struct Line: Sendable {
        let offset: TimeInterval
        let end: TimeInterval
        var text: String
        /// 多数決での合い方（0〜1）。古い PC（モデル1つ）では nil
        var confidence: Double?
        /// ほかのモデルの違う文
        var alternatives: [String]
        /// モデルごとの文（haas・reazon・whisper、iPhone で足した cloud）
        var votes: [String: String]

        var cloudLine: CloudTranscriber.Line { CloudTranscriber.Line(offset: offset, text: text) }
    }

    /// 区切りを PC で文字にする。local は端末内の文字起こし（声のある区間を決めるのに使う）。
    func transcribe(_ url: URL, local: [Transcriber.Line], hints: [String] = []) async throws -> [Line] {
        try await transcribe(url, segments: HaasEngine.segments(from: local), hints: hints)
    }

    /// hints は聞き取ってほしい言葉（PC の Whisper のヒントになる）、previous は前の区切りの終わりの文。
    func transcribe(_ url: URL, segments: [(start: TimeInterval, end: TimeInterval)],
                    hints: [String] = [], previous: String? = nil) async throws -> [Line] {
        guard !segments.isEmpty else { return [] }
        do {
            // 先に短く確かめる。PC が切れていたら、長く待たずにほかの方法へ
            _ = try await hello()
            var upload = try request("transcribe")
            let list = segments.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: ",")
            var components = URLComponents(url: upload.url!, resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "segments", value: list)]
            // 宛先の長さに収まるよう、言葉は先頭（具体的なもの）から 1,500 文字まで
            var words: [String] = []
            var length = 0
            for word in hints where !word.isEmpty && !word.contains("\n") {
                length += word.count + 1
                if length > 1500 || words.count >= 80 { break }
                words.append(word)
            }
            if !words.isEmpty { items.append(URLQueryItem(name: "hints", value: words.joined(separator: "\n"))) }
            if let previous, !previous.isEmpty { items.append(URLQueryItem(name: "prompt", value: String(previous.suffix(120)))) }
            components?.queryItems = items
            upload.url = components?.url
            upload.httpMethod = "POST"
            upload.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
            let session = makeSession(timeout: 180)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.upload(for: upload, fromFile: url)
            try Self.check(response, data: data)
            struct Reply: Decodable {
                struct Line: Decodable {
                    let start: Double; let end: Double; let text: String
                    let confidence: Double?; let alternatives: [String]?; let votes: [String: String]?
                }
                let lines: [Line]
                let seconds: Double
                let engines: [String]?
            }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            failedAt = nil
            engineCount = reply.engines?.count ?? 1
            lastResult = "最後に使った時刻: \(Date().formatted(date: .omitted, time: .shortened))（\(String(format: "%.1f", reply.seconds)) 秒"
                + (engineCount > 1 ? "・\(engineCount) つのモデルの多数決）" : "）")
            return reply.lines.map {
                Line(offset: $0.start, end: $0.end, text: $0.text, confidence: $0.confidence,
                     alternatives: $0.alternatives ?? [], votes: $0.votes ?? [:])
            }
        } catch {
            failedAt = .now
            lastResult = "つながりませんでした（\(Date().formatted(date: .omitted, time: .shortened))）: \(Self.describe(error))"
            throw error
        }
    }

    // MARK: - クラウドの票を足す

    /// PC の多数決で食い違った行（確からしさが cloudVoteBelow 未満）に、クラウドの Whisper の文をもう1票として足し、選び直す。
    /// クラウドの文は、その行の声の区間（前後0.5秒）に始まる行をつないだもの。何も書いていなければ票にしない。
    /// 選び方は PC と同じ：読みがほかの票といちばん近い文。確からしさは、ほぼ同じ読み（0.85 以上）の票の割合
    /// （違う票は近さの半分を足す。何も書かなかったモデルも 0 として数える）。
    nonisolated static let cloudVoteBelow = 0.67
    nonisolated static let sameReading = 0.85

    nonisolated static func addCloudVote(_ lines: [Line], cloud: [CloudTranscriber.Line]) -> [Line] {
        lines.map { line in
            guard let confidence = line.confidence, confidence < cloudVoteBelow, !line.votes.isEmpty else { return line }
            let text = cloud.filter { ($0.offset ?? -1) >= line.offset - 0.5 && ($0.offset ?? -1) < line.end + 0.5 }
                .map(\.text).joined()
            guard !text.isEmpty, !CloudTranscriber.isFiller(text) else { return line }
            var votes = line.votes
            votes["cloud"] = text
            return revote(line, votes: votes)
        }
    }

    /// 票から1つを選び直す。
    nonisolated static func revote(_ line: Line, votes: [String: String]) -> Line {
        let order = ["haas", "reazon", "whisper", "cloud"]
        let names = votes.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
        let heard = names.filter { !(votes[$0] ?? "").isEmpty }
        guard heard.count >= 2 else { return line }
        func sim(_ a: String, _ b: String) -> Double {
            let x = votes[a] ?? "", y = votes[b] ?? ""
            if x.isEmpty || y.isEmpty { return 0 }
            if x == y { return 1 }
            // 短すぎて読みで比べられない文は、同じ書き方かどうかだけで見る
            return TranscriptCheck.similarity(x, y).map { min($0, TranscriptCheck.similarity(y, x) ?? $0) } ?? 0
        }
        let others = { (k: String) in names.filter { $0 != k } }
        let scores = Dictionary(uniqueKeysWithValues: heard.map { k in
            (k, others(k).map { sim(k, $0) }.reduce(0, +) / Double(names.count - 1))
        })
        guard let best = heard.max(by: { (scores[$0] ?? 0, -(heard.firstIndex(of: $0) ?? 0)) < (scores[$1] ?? 0, -(heard.firstIndex(of: $1) ?? 0)) })
        else { return line }
        var result = line
        result.votes = votes
        result.text = votes[best] ?? line.text
        // クラウドが選ばれても、読みが前に選んでいた文とほぼ同じなら、元の書き方（ヒントを渡した PC の Whisper など）を残す
        if best == "cloud", let previous = heardKey(of: line.text, in: votes), sim("cloud", previous) >= sameReading {
            result.text = line.text
        }
        let agree = others(best).map { o -> Double in
            let s = sim(best, o)
            return s >= sameReading ? 1 : s * 0.5
        }
        result.confidence = ((agree.reduce(0, +) / Double(max(1, agree.count))) * 100).rounded() / 100
        var alternatives: [String] = []
        for k in heard {
            let other = votes[k] ?? ""
            if other != result.text, !alternatives.contains(other) { alternatives.append(other) }
        }
        result.alternatives = alternatives
        return result
    }

    /// 選ばれていた文を書いた票の名前
    nonisolated private static func heardKey(of text: String, in votes: [String: String]) -> String? {
        votes.first { $0.value == text }?.key
    }

    func testConnection() async -> String {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty, hasKey else { return Failure.notConfigured.localizedDescription }
        do {
            let model = try await hello()
            forgetFailure()
            return "つながりました: \(model)"
        } catch {
            return "つながりませんでした: \(Self.describe(error))"
        }
    }

    /// よくある失敗を分かる言葉にする
    static func describe(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .appTransportSecurityRequiresSecureConnection?:
            return "番号だけの宛先（100.… や 192.168.…）には送れません。PC の画面に出る「〜.ts.net:47615」の名前を入れてください。"
        case .timedOut?, .cannotConnectToHost?, .cannotFindHost?:
            return "PC に届きませんでした。PC で LifeLogPC.exe が動いているか、iPhone の Tailscale がオンかを確かめてください。（\(error.localizedDescription)）"
        default:
            return error.localizedDescription
        }
    }

    func testRecent() async -> String {
        guard let url = Storage.keptAudio().last else { return "試せる音声がありません（録音して少し待ってください）。" }
        do {
            let local = try await Transcriber.transcribe(url)
            let started = Date()
            let lines = try await transcribe(url, local: local)
            let took = Date().timeIntervalSince(started)
            let text = lines.map { line in
                line.text + (line.confidence.map { $0 < 0.5 ? "（食い違い: \(line.alternatives.joined(separator: " ／ "))）" : "" } ?? "")
            }.joined(separator: "\n")
            return "\(url.lastPathComponent)\n送って文字になるまで \(String(format: "%.1f", took)) 秒\n\n"
                + (text.isEmpty ? "（声が聞き取れませんでした）" : text)
        } catch {
            return "試せませんでした: \(Self.describe(error))"
        }
    }
}

/// 家の PC の合言葉（キーチェーン）
private enum PCKeychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.off53jub.lifelog",
            kSecAttrAccount as String: "home-pc-key",
        ]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

import Foundation
import Observation
import Security

/// 家の PC で動かす LifeLog PC（Haas-ja）に区切りを送って、文字にしてもらう。
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
            case .badAddress: "宛先の書き方が違います（例: 100.64.1.2）"
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

    /// 区切りを PC で文字にする。local は端末内の文字起こし（声のある区間を決めるのに使う）。
    func transcribe(_ url: URL, local: [Transcriber.Line]) async throws -> [CloudTranscriber.Line] {
        let segments = HaasEngine.segments(from: local)
        guard !segments.isEmpty else { return [] }
        do {
            // 先に短く確かめる。PC が切れていたら、長く待たずにほかの方法へ
            _ = try await hello()
            var upload = try request("transcribe")
            let list = segments.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: ",")
            var components = URLComponents(url: upload.url!, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "segments", value: list)]
            upload.url = components?.url
            upload.httpMethod = "POST"
            upload.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
            let session = makeSession(timeout: 180)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.upload(for: upload, fromFile: url)
            try Self.check(response, data: data)
            struct Reply: Decodable {
                struct Line: Decodable { let start: Double; let end: Double; let text: String }
                let lines: [Line]
                let seconds: Double
            }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            failedAt = nil
            lastResult = "最後に使った時刻: \(Date().formatted(date: .omitted, time: .shortened))（\(String(format: "%.1f", reply.seconds)) 秒）"
            return reply.lines.map { CloudTranscriber.Line(offset: $0.start, text: $0.text) }
        } catch {
            failedAt = .now
            lastResult = "つながりませんでした（\(Date().formatted(date: .omitted, time: .shortened))）: \(error.localizedDescription)"
            throw error
        }
    }

    func testConnection() async -> String {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty, hasKey else { return Failure.notConfigured.localizedDescription }
        do {
            let model = try await hello()
            forgetFailure()
            return "つながりました: \(model)"
        } catch {
            return "つながりませんでした: \(error.localizedDescription)"
        }
    }

    func testRecent() async -> String {
        guard let url = Storage.keptAudio().last else { return "試せる音声がありません（録音して少し待ってください）。" }
        do {
            let local = try await Transcriber.transcribe(url)
            let started = Date()
            let lines = try await transcribe(url, local: local)
            let took = Date().timeIntervalSince(started)
            let text = lines.map(\.text).joined(separator: "\n")
            return "\(url.lastPathComponent)\n送って文字になるまで \(String(format: "%.1f", took)) 秒\n\n"
                + (text.isEmpty ? "（声が聞き取れませんでした）" : text)
        } catch {
            return "試せませんでした: \(error.localizedDescription)"
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

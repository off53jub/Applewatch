import Foundation
import Observation
import Security

/// 家の PC で動かす LifeLog PC に区切りを送って、文字にしてもらう。
///
/// PC は Haas-ja・ReazonSpeech・Whisper large-v3 の3つで声の区間ごとに文字にし、多数決で選んだ文を返す（2026-11-05）。
/// 行ごとに、選んだ文の合い方（確からしさ）と、ほかのモデルの違う文（候補）も返ってくる。
/// 古い LifeLog PC（Haas-ja だけ）は確からしさを返さないので、そのときは今までどおり端末内と見比べる。
///
/// 送るのは区切りの録音（短めで長くても2分・ふつうで5分。AAC、5分で約1.2MB）と、端末内の文字起こしで声があった区間だけ。声の無い区切りは送らない。
/// 宛先は家の Wi-Fi の中の住所（192.168.…）か、Tailscale の住所（100.…）。Tailscale なら外からもモバイル通信で届く。
/// PC が切れているときは、iPhone 内の Haas-ja かいつもの方法で文字にする。
@MainActor
@Observable
final class HomePC {
    static let port = 47615

    var enabled = UserDefaults.standard.bool(forKey: "homePCOn") {
        didSet { UserDefaults.standard.set(enabled, forKey: "homePCOn"); onWatchSettingsChange?() }
    }
    /// 家の中の住所（例 192.168.1.20）。入れると、家の Wi-Fi にいるとき時計から PC に区切りを直接送る（2026-11-07。WatchPC.swift）。
    /// 時計には Tailscale が無いので、上の宛先（〜.ts.net）とは別に、家の中の番号を入れる
    var homeAddress = UserDefaults.standard.string(forKey: "homePCHomeAddress") ?? "" {
        didSet { UserDefaults.standard.set(homeAddress, forKey: "homePCHomeAddress"); onWatchSettingsChange?() }
    }
    /// 時計から家の PC に直接送る（家の中の住所を入れたときだけ働く。初めはオン）
    var watchDirect = UserDefaults.standard.object(forKey: "homePCWatchDirect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(watchDirect, forKey: "homePCWatchDirect"); onWatchSettingsChange?() }
    }
    /// 時計に送る設定（住所・合言葉・オンオフ）が変わったら呼ぶ（Pipeline が時計に送り直す）
    @ObservationIgnored var onWatchSettingsChange: (@MainActor () -> Void)?

    /// 時計から直接送るときの家の中の住所（使えないときは空）と合言葉。
    /// 家の PC が切れている・時計から送らない・住所が家の中でない・合言葉が無いときは住所が空（時計は合言葉を消す）
    func watchCredentials() -> (address: String, key: String?) {
        let address = homeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, watchDirect, WatchDelivery.homeBaseURL(address) != nil, let key = PCKeychain.read() else {
            return ("", nil)
        }
        return (address, key)
    }

    /// 家の中の住所の書き方が正しいか（空なら nil。画面に出す）
    var homeAddressProblem: String? {
        let address = homeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, WatchDelivery.homeBaseURL(address) == nil else { return nil }
        return "家の中の住所（192.168.… や 10.… の番号）を入れてください。〜.ts.net や 100.… は時計からは使えません。"
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
        onWatchSettingsChange?()
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
        struct Hello: Decodable {
            let model: String; let provider: String; let version: Int?; let features: [String]?
            let speaker_model: String?
        }
        let hello = try JSONDecoder().decode(Hello.self, from: data)
        version = hello.version ?? 1
        features = Set(hello.features ?? [])
        UserDefaults.standard.set(features.contains("jobs"), forKey: "homePCJobs")
        // 待ち合わせ（送った返事で文字を返す）と下書き（版 8 から。2026-11-07。裏で起こされたときにも使えるよう覚えておく）
        UserDefaults.standard.set(features.contains("jobwait"), forKey: Self.jobWaitKey)
        UserDefaults.standard.set(features.contains("draft"), forKey: Self.draftKey)
        speakerModel = hello.speaker_model
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
        /// 言葉ごとの時刻（PC の版 4 から。選ばれた文の言葉をつなぐと text になる。分からなければ空）
        var words: [Word] = []

        var cloudLine: CloudTranscriber.Line { CloudTranscriber.Line(offset: offset, text: text) }
    }

    /// 言葉1つと、その始まり・終わり（区切りの中の秒）
    struct Word: Sendable, Equatable, Decodable {
        let start: Double
        let end: Double
        let text: String

        init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }

        /// PC は [始まり, 終わり, "言葉"] の形で返す
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            start = try c.decode(Double.self)
            end = try c.decode(Double.self)
            text = try c.decode(String.self)
        }
    }

    /// 区切りを PC で文字にする。local は端末内の文字起こし（声のある区間を決めるのに使う）。
    func transcribe(_ url: URL, local: [Transcriber.Line], hints: [String] = [], noisy: Bool = false) async throws -> [Line] {
        try await transcribe(url, segments: HaasEngine.segments(from: local), hints: hints, noisy: noisy)
    }

    /// 騒がしい区切りでは、雑音を消した音も PC で文字にして多数決の票に足す（PC の版 4 から。2026-11-06）。
    /// 精度の物差しで「いつも足すほうが良い」と分かったら、静かな区切りでも足す
    static var enhanceAlways: Bool { UserDefaults.standard.bool(forKey: "benchAdopt.enhance") }
    /// 精度の物差しで「重みを送らないほうが良い」と分かったら送らない
    static var skipWeights: Bool { UserDefaults.standard.bool(forKey: "benchAdopt.noWeights") }

    /// 多数決の重み。騒がしい・静かな行で分けて学んだものがあればそれを、無ければ全体のもの（2026-11-06）
    static func weightsText(noisy: Bool) -> String? {
        let key = AnswerKey.weightsKey + (noisy ? ".noisy" : ".quiet")
        if let text = UserDefaults.standard.string(forKey: key), !text.isEmpty { return text }
        if let text = UserDefaults.standard.string(forKey: AnswerKey.weightsKey), !text.isEmpty { return text }
        return nil
    }

    /// PC ができること（"speakers"・"scene"・"vad"。版 3 から。2026-11-06）
    var features: Set<String> = []

    // MARK: - 複数のモデルで決める（2026-11-06）

    /// 区間ごとの声の特徴（PC の話者モデル。iPhone とは別の種類）。短すぎる区間は nil
    func speakerEmbeddings(_ url: URL, segments: [(start: TimeInterval, end: TimeInterval)]) async throws -> [[Float]?] {
        struct Reply: Decodable { let embeddings: [[Float]?] }
        let data = try await post("speakers", url: url, segments: segments)
        return try JSONDecoder().decode(Reply.self, from: data).embeddings
    }

    /// 区間ごとの音の種類（PC の音の分類モデル。上位5つ）
    func sceneTags(_ url: URL, segments: [(start: TimeInterval, end: TimeInterval)]) async throws -> [[(name: String, prob: Double)]] {
        struct Tag: Decodable { let name: String; let prob: Double }
        struct Reply: Decodable { let tags: [[Tag]] }
        let data = try await post("scene", url: url, segments: segments)
        return try JSONDecoder().decode(Reply.self, from: data).tags.map { $0.map { (name: $0.name, prob: $0.prob) } }
    }

    // MARK: - 家の PC の言語モデル（PC の版 5 から。2026-11-06）

    /// PC の言語モデル（Ollama）に頼む。JSON の文字列を返す。PC が使えない・その働きが無いときは失敗
    func llm(system: String, prompt: String) async throws -> String {
        guard shouldTry, features.contains("llm") else { throw Failure.notConfigured }
        struct Reply: Decodable { let text: String }
        var request = try request("llm")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": system + "\n\n" + prompt, "json": true, "max_tokens": 2000,
        ] as [String: Any])
        let session = makeSession(timeout: 180)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return try JSONDecoder().decode(Reply.self, from: data).text
    }

    /// PC の話者モデルの名前（版 5 から。変わったら、名前のある人の声を測り直す）
    var speakerModel: String?

    // MARK: - あなた向けのモデルの材料（PC の版 4 から。2026-11-06）

    /// 直した文とその音声の区間を PC に渡す（PC の中だけに置く。学び直しは PC で本人が動かす）。PC にたまった数を返す。
    /// audio・offset は、その行の音声の名前（Line.audio）と行の位置の秒（Line.offset）。PC の「聞いて直す」画面で
    /// 直した行と2重に入らないよう、PC が見分けに使う（2026-11-07。版 9。古い PC は読み飛ばす）
    func sendTrainSample(_ url: URL, start: TimeInterval, end: TimeInterval, text: String,
                         audio: String? = nil, offset: TimeInterval? = nil) async throws -> Int {
        struct Reply: Decodable { let count: Int }
        var upload = try request("train-sample")
        var components = URLComponents(url: upload.url!, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "start", value: String(format: "%.2f", start)),
                     URLQueryItem(name: "end", value: String(format: "%.2f", end)),
                     URLQueryItem(name: "text", value: text)]
        if let audio { items.append(URLQueryItem(name: "audio", value: audio)) }
        if let offset { items.append(URLQueryItem(name: "offset", value: String(format: "%.3f", offset))) }
        components?.queryItems = items
        upload.url = components?.url
        upload.httpMethod = "POST"
        upload.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let session = makeSession(timeout: 60)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: upload, fromFile: url)
        // PC が中身を見て受け付けなかった（声が短すぎる・長すぎる・文が無い など）。何度送っても同じなので、
        // 呼ぶ側はこの材料を飛ばして先へ進む（前は、ここで夜の残りの材料を送るのをやめていた。2026-11-07）
        if (response as? HTTPURLResponse)?.statusCode == 400 { throw SampleRefused() }
        try Self.check(response, data: data)
        return try JSONDecoder().decode(Reply.self, from: data).count
    }

    /// PC が材料を受け付けなかった（HTTP 400）
    struct SampleRefused: Error {}

    /// PC にたまった材料の数・学び直したモデルがあるか・学び直しに要る数（PC の自動の学び直しの設定。無ければ 300。2026-11-07）
    func trainStatus() async throws -> (count: Int, model: Bool, need: Int) {
        let session = makeSession(timeout: 8)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: try request("train-status"))
        try Self.check(response, data: data)
        return try Self.trainStatusReply(data)
    }

    /// /train-status の答えを読む。学び直しに要る数は "auto" の "min_samples"（PC の版 7 の自動の学び直し）。
    /// 無いとき・形が違うときは 300（train_personal.py の MIN_SAMPLES）
    nonisolated static func trainStatusReply(_ data: Data) throws -> (count: Int, model: Bool, need: Int) {
        struct Auto: Decodable {
            let minSamples: Int?
            enum CodingKeys: String, CodingKey { case minSamples = "min_samples" }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                minSamples = try? c.decodeIfPresent(Int.self, forKey: .minSamples)
            }
        }
        struct Reply: Decodable {
            let count: Int
            let model: Bool
            let auto: Auto?
            enum CodingKeys: String, CodingKey { case count, model, auto }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                count = try c.decode(Int.self, forKey: .count)
                model = try c.decode(Bool.self, forKey: .model)
                auto = try? c.decodeIfPresent(Auto.self, forKey: .auto)
            }
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let need = reply.auto?.minSamples ?? PersonalMaterial.need
        return (reply.count, reply.model, need > 0 ? need : PersonalMaterial.need)
    }

    private func post(_ path: String, url: URL, segments: [(start: TimeInterval, end: TimeInterval)]) async throws -> Data {
        var upload = try request(path)
        var components = URLComponents(url: upload.url!, resolvingAgainstBaseURL: false)
        let list = segments.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: ",")
        components?.queryItems = [URLQueryItem(name: "segments", value: list)]
        upload.url = components?.url
        upload.httpMethod = "POST"
        upload.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let session = makeSession(timeout: 180)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: upload, fromFile: url)
        try Self.check(response, data: data)
        return data
    }

    /// つながらなくなった時刻（つながったら nil。家の PC の見張り。2026-11-06）
    var downSince: Date? = UserDefaults.standard.object(forKey: "homePCDown") as? Date {
        didSet { UserDefaults.standard.set(downSince, forKey: "homePCDown") }
    }
    /// PC の LifeLog PC の版（hello で分かる。古い PC は 1）
    var version: Int?
    /// このアプリが前提にしている PC の版（多数決・ヒント・重み。版 7 は実機の様子・見えない通知・記録と直し。2026-11-07）。
    /// 新しい働きは版ではなく features を見て使うので、PC が古くても文字起こしはそのまま使える（古い版の知らせは7日に1回まで）
    nonisolated static let expectedVersion = 7

    /// 声の区間の長さに対する処理の時間（直近をならした値。1 より大きいと録音に追いつかない）。2026-11-06
    var speed: Double? = UserDefaults.standard.object(forKey: "homePCSpeed") as? Double {
        didSet { UserDefaults.standard.set(speed, forKey: "homePCSpeed") }
    }
    nonisolated static let tooSlow = 0.8

    /// 送る言葉の数。遅いときは減らす（PC は登録語をホットワードにも使うので、減らすと速くなる）
    nonisolated static func hintLimit(speed: Double?) -> Int {
        guard let speed else { return 80 }
        if speed > tooSlow { return 25 }
        if speed > 0.6 { return 45 }
        return 80
    }

    /// hints は聞き取ってほしい言葉（PC の Whisper のヒントになる）、previous は前の区切りの終わりの文。
    /// noisy は騒がしい区切りか（重みの選び方と、雑音を消した音も聞くかに使う）。enhance と weights は精度の物差しが試すときだけ指定する
    func transcribe(_ url: URL, segments: [(start: TimeInterval, end: TimeInterval)],
                    hints: [String] = [], previous: String? = nil, noisy: Bool = false,
                    enhance: Bool? = nil, weights: Bool? = nil, unionVAD: Bool = true) async throws -> [Line] {
        guard !segments.isEmpty else { return [] }
        do {
            // 先に短く確かめる。PC が切れていたら、長く待たずにほかの方法へ
            _ = try await hello()
            var upload = try request("transcribe")
            let list = segments.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: ",")
            var components = URLComponents(url: upload.url!, resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "segments", value: list)]
            // 宛先の長さに収まるよう、言葉は先頭（具体的なもの）から 1,500 文字まで。
            // PC が録音に追いつかない（実時間の 0.8 倍より遅い）ときは、登録語を減らして軽くする（2026-11-06）
            var words: [String] = []
            var length = 0
            let limit = Self.hintLimit(speed: speed)
            for word in hints where !word.isEmpty && !word.contains("\n") {
                length += word.count + 1
                if length > 1500 || words.count >= limit { break }
                words.append(word)
            }
            if !words.isEmpty { items.append(URLQueryItem(name: "hints", value: words.joined(separator: "\n"))) }
            // PC でも声の区間を探し、iPhone が拾い漏らした声も文字にする（2つの VAD のどちらかが声とした所は捨てない。2026-11-06）
            if unionVAD, features.contains("vad") { items.append(URLQueryItem(name: "vad", value: "union")) }
            if features.contains("enhance"), enhance ?? (noisy || Self.enhanceAlways) {
                items.append(URLQueryItem(name: "enhance", value: "1"))
            }
            if let previous, !previous.isEmpty { items.append(URLQueryItem(name: "prompt", value: String(previous.suffix(120)))) }
            // 答え合わせから学んだ、モデルごとの当たりやすさ（多数決の票の重み）
            if weights ?? !Self.skipWeights, let text = Self.weightsText(noisy: noisy) {
                items.append(URLQueryItem(name: "weights", value: text))
            }
            components?.queryItems = items
            upload.url = components?.url
            upload.httpMethod = "POST"
            upload.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
            let session = makeSession(timeout: 180)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.upload(for: upload, fromFile: url)
            try Self.check(response, data: data)
            let reply = try JSONDecoder().decode(PCReply.self, from: data)
            return accept(reply, voiced: segments.reduce(0) { $0 + max(0, $1.end - $1.start) })
        } catch {
            failedAt = .now
            if downSince == nil { downSince = .now }
            lastResult = "つながりませんでした（\(Date().formatted(date: .omitted, time: .shortened))）: \(Self.describe(error))"
            throw error
        }
    }

    /// PC の答え（/transcribe と、裏で送った区切りの結果 /jobs の中身）を受け取り、数を数えて行にする
    private func accept(_ reply: PCReply, voiced: Double) -> [Line] {
        // 区切りごとの平均を、行の数で重み付けして足す
        for (pair, value) in reply.pairs ?? [:] {
            let count = max(1, reply.pair_lines?[pair] ?? 1)
            Tally.add("pair." + pair + ".s", Int((value * 1000).rounded()) * count)
            Tally.add("pair." + pair + ".n", count)
        }
        for (engine, count) in reply.silent ?? [:] { Tally.add("silent." + engine, count) }
        Tally.add("pc.vadExtra", reply.lines.filter { $0.extra == true }.count)
        failedAt = nil
        downSince = nil
        engineCount = reply.engines?.count ?? 1
        // 声の区間の長さに対して、処理に何倍かかったか（直近をならす）
        if voiced >= 5 {
            let ratio = reply.seconds / voiced
            speed = speed.map { $0 * 0.7 + ratio * 0.3 } ?? ratio
        }
        lastResult = "最後に使った時刻: \(Date().formatted(date: .omitted, time: .shortened))（\(String(format: "%.1f", reply.seconds)) 秒"
            + (engineCount > 1 ? "・\(engineCount) つのモデルの多数決" : "")
            + (speed.map { "・実時間の \(String(format: "%.2f", $0)) 倍" + ($0 > Self.tooSlow ? "（追いつかないので登録語を減らしています）" : "") } ?? "")
            + "）"
        return reply.lines.map {
            Line(offset: $0.start, end: $0.end, text: $0.text, confidence: $0.confidence,
                 alternatives: $0.alternatives ?? [], votes: $0.votes ?? [:], words: $0.words ?? [])
        }
    }

    // MARK: - 区切りを裏で PC に送っておく（PC の版 6 から。2026-11-07）

    /// PC が「裏で送った区切り」を受け付けるか。裏で起こされたときは PC に聞けないので、最後に聞いた答えを覚えておく
    static var acceptsJobs: Bool { UserDefaults.standard.bool(forKey: "homePCJobs") }

    /// PC が待ち合わせ（POST /jobs?wait=1）を受け付けるか（版 8 から）
    static let jobWaitKey = "homePCJobWait"
    static var acceptsJobWait: Bool { UserDefaults.standard.bool(forKey: jobWaitKey) }
    /// PC が下書きを返すか（版 8 から）
    static let draftKey = "homePCDraft"
    static var acceptsDrafts: Bool { UserDefaults.standard.bool(forKey: draftKey) }
    /// 待ち合わせで同時に待たせておく数の上限。これより多く送っている途中なら、待ち合わせにしない
    /// （つながりを長く持ったままの送りが溜まると、新しい区切りを送り始められなくなるため）
    nonisolated static let maxWaiting = 3

    /// 区切りを、アプリが止まっても続く転送で PC に送る（PC はその場で文字にして、結果をためておく）。
    /// 区切りの時刻（録音の始まり・終わり・iPhone に届いた・送り始めた）も渡す（版 8。docs/v8-latency.md の 1）。
    /// PC が待ち合わせを受け付けるなら wait=1 を付け、文字にし終わった答えを返事で受け取る（PCJobUploader が受け取る）
    func enqueueJob(_ url: URL, hints: [String]) {
        guard isConfigured, Self.acceptsJobs, var req = try? request("jobs") else { return }
        let name = url.lastPathComponent
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "name", value: name)]
        let sent = Date.now
        Latency.noteSent(name, at: sent)
        items += Self.timeItems(Latency.marks(name), sent: sent)
        if Self.acceptsJobWait, PCJobUploader.stagedCount < Self.maxWaiting {
            items.append(URLQueryItem(name: "wait", value: "1"))
        }
        var words: [String] = []
        var length = 0
        for word in hints where !word.isEmpty && !word.contains("\n") {
            length += word.count + 1
            if length > 1500 || words.count >= Self.hintLimit(speed: speed) { break }
            words.append(word)
        }
        if !words.isEmpty { items.append(URLQueryItem(name: "hints", value: words.joined(separator: "\n"))) }
        if !Self.skipWeights, let text = Self.weightsText(noisy: false) { items.append(URLQueryItem(name: "weights", value: text)) }
        components?.queryItems = items
        req.url = components?.url
        req.httpMethod = "POST"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        // PC は返事を書き終えるまで、15秒ごとに空白を1文字書く。それが届くかぎり切れないよう、待つのは 120 秒まで
        req.timeoutInterval = PCJobUploader.idleTimeout
        PCJobUploader.shared.upload(url, request: req, cellular: useCellular)
    }

    /// POST /jobs に付ける区切りの時刻（分かるものだけ。ISO 8601・UTC・ミリ秒つき）
    nonisolated static func timeItems(_ marks: Latency.Marks?, sent: Date) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        func put(_ key: String, _ date: Date?) {
            if let date { items.append(URLQueryItem(name: key, value: PCJSON.string(date))) }
        }
        put("chunk_start", marks?.chunkStart)
        put("chunk_end", marks?.chunkEnd)
        put("arrived", marks?.arrived)
        put("sent", sent)
        return items
    }

    enum JobState {
        /// 結果が出ている
        case done([Line])
        /// PC が受け付けて、まだ文字にしている（いつ受け付けたか）
        case pending(Date)
        /// PC に無い（まだ届いていない・失敗した・消えた）
        case missing
    }

    /// 裏で送った区切りの様子（数秒で諦める）。
    /// PC に無くても、まだ送っている途中（写しがある・30分以内）なら「受け付け待ち」とみなす
    /// （送り始めてすぐに取り込みが走ったとき、同じ区切りを PC に二重に頼まないように。2026-11-07）
    func jobState(_ name: String) async -> JobState {
        guard isConfigured, Self.acceptsJobs, let req = try? request("jobs/" + name) else { return .missing }
        let session = makeSession(timeout: 8)
        defer { session.finishTasksAndInvalidate() }
        guard let got = try? await session.data(for: req) else { return .missing }
        let data = got.0
        let status = (got.1 as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404, let since = PCJobUploader.stagedSince(name), Date.now.timeIntervalSince(since) < 30 * 60 {
            return .pending(since)
        }
        guard status == 200, let reply = JobReply.decode(data) else { return .missing }
        if let timing = reply.timing { Latency.notePC(name, timing: timing) }
        switch reply.status {
        case "done":
            guard let result = reply.result else { return .missing }
            let voiced = result.lines.reduce(0) { $0 + max(0, $1.end - $1.start) }
            return .done(accept(result, voiced: voiced))
        case "queued", "working":
            return .pending(reply.queued_at.map { Date(timeIntervalSince1970: $0) } ?? .now)
        default:
            return .missing
        }
    }

    /// 待ち合わせの返事か、下書きを見に行ったときに受け取って、端末の中に置いてある答え（PCResults）。
    /// あれば PC に聞かずに使う。読めない答えは消して nil（版 8。2026-11-07）
    func cachedJob(_ name: String) -> [Line]? {
        guard let data = PCResults.load(name) else { return nil }
        guard let reply = JobReply.decode(data), reply.status == "done", let result = reply.result else {
            PCResults.remove(name)
            return nil
        }
        if let timing = reply.timing { Latency.notePC(name, timing: timing) }
        let voiced = result.lines.reduce(0) { $0 + max(0, $1.end - $1.start) }
        return accept(result, voiced: voiced)
    }

    /// 下書きを見に行ったときの答え
    enum JobPeek {
        /// でき上がっていた（答えの JSON。端末の中に置いて取り込みで使う）
        case done(Data)
        /// まだで、下書きがある
        case draft([Line])
        /// まだで、下書きも無い・PC に無い・つながらない
        case nothing
    }

    /// 送ってまだの仕事を、数秒で見に行く（下書き。アプリが前にあるときだけ呼ぶ。版 8 から）
    func peekJob(_ name: String) async -> JobPeek {
        guard shouldTry, Self.acceptsJobs, let req = try? request("jobs/" + name) else { return .nothing }
        let session = makeSession(timeout: 8)
        defer { session.finishTasksAndInvalidate() }
        guard let got = try? await session.data(for: req), (got.1 as? HTTPURLResponse)?.statusCode == 200,
              let reply = JobReply.decode(got.0) else { return .nothing }
        let data = got.0
        if let timing = reply.timing { Latency.notePC(name, timing: timing) }
        if reply.status == "done", reply.result != nil { return .done(data) }
        guard let draft = reply.draft, !draft.lines.isEmpty else { return .nothing }
        return .draft(draft.lines.map {
            Line(offset: $0.start, end: $0.end, text: $0.text, confidence: nil, alternatives: [], votes: [:])
        })
    }

    /// 使い終わった結果を PC から消す（失敗してもよい。PC は7日で消す）
    func deleteJob(_ name: String) async {
        guard var req = try? request("jobs/" + name) else { return }
        req.httpMethod = "DELETE"
        let session = makeSession(timeout: 8)
        defer { session.finishTasksAndInvalidate() }
        _ = try? await session.data(for: req)
    }

    // MARK: - 意味で探す（PC の版 6 から。2026-11-07）

    struct IndexItem: Encodable {
        let id: String
        let day: String
        let time: Double
        let speaker: String?
        let text: String
        let work: Bool
        let conversation: String
    }

    struct SearchHit: Decodable {
        struct Context: Decodable {
            let id: String?
            let time: Double?
            let speaker: String?
            let text: String
        }
        let id: String
        let day: String
        let time: Double
        let speaker: String?
        let text: String
        let conversation: String?
        let score: Double
        let context: [Context]?
    }

    /// 会話の行を PC の索引に入れる（500行まで）。入れた数
    func index(_ items: [IndexItem]) async throws -> Int {
        struct Reply: Decodable { let indexed: Int }
        let data = try await postJSON("index", body: ["items": items], timeout: 180)
        return try JSONDecoder().decode(Reply.self, from: data).indexed
    }

    /// 索引から消す
    func forget(_ ids: [String]) async throws {
        _ = try await postJSON("forget", body: ["ids": ids], timeout: 30)
    }

    /// 意味の近い行を探す
    func semanticSearch(_ query: String, k: Int = 30, from: String? = nil, to: String? = nil) async throws -> [SearchHit] {
        struct Body: Encodable { let query: String; let k: Int; let from: String?; let to: String?; let include_work: Bool }
        struct Reply: Decodable { let hits: [SearchHit] }
        let data = try await postJSON("search", body: Body(query: query, k: k, from: from, to: to, include_work: true), timeout: 30)
        return try JSONDecoder().decode(Reply.self, from: data).hits
    }

    private func postJSON<T: Encodable>(_ path: String, body: T, timeout: TimeInterval) async throws -> Data {
        var req = try request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data: data)
        return data
    }

    // MARK: - 実機の様子・記録・直し（PC の版 7 から。2026-11-07。中身は PCDiag.swift・PCRecords.swift）

    /// できあがった JSON を送り、答えを受け取る（/diag・/records/<日>・/edits/ack）
    func postJSONData(_ path: String, body: Data, timeout: TimeInterval) async throws -> Data {
        var req = try request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data: data)
        return data
    }

    /// 答えを受け取る（/edits?after=…）
    func getJSONData(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval) async throws -> Data {
        var req = try request(path)
        if !query.isEmpty, let url = req.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            req.url = components.url
        }
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data: data)
        return data
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
        } else if heardKey(of: line.text, in: votes) == nil, let winner = votes[best],
                  (TranscriptCheck.similarity(winner, line.text) ?? 0) >= sameReading {
            // PC が言葉ごとの多数決で直した文（どの票とも同じではない）は、選ばれた票と読みがほぼ同じなら残す
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

/// PC の文字起こしの答え（/transcribe と /jobs の結果。2026-11-07 に型を外に出した）
struct PCReply: Decodable {
    struct Line: Decodable {
        let start: Double; let end: Double; let text: String
        let confidence: Double?; let alternatives: [String]?; let votes: [String: String]?
        /// PC の声の区間だけが声とした所（iPhone の区間には無かった。2026-11-06）
        let extra: Bool?
        /// 言葉ごとの時刻（版 4 から）
        let words: [HomePC.Word]?
    }
    let lines: [Line]
    let seconds: Double
    let engines: [String]?
    /// モデルの組ごとの読みの近さの平均と、何も書かなかった行の数（版 5 から。中身は入っていない）
    let pairs: [String: Double]?
    let pair_lines: [String: Int]?
    let silent: [String: Int]?
}

/// PC の仕事の答え（GET /jobs/<名前> と、待ち合わせ POST /jobs?wait=1 の返事。版 8。2026-11-07）
struct JobReply: Decodable {
    let status: String
    let queued_at: Double?
    let result: PCReply?
    /// 時刻（docs/v8-latency.md の 1）
    let timing: PCTiming?
    /// まだのときの下書き（速いモデルだけで書いたもの。記録には入れない）
    let draft: PCDraft?

    /// 頭の空白（PC が待たせているあいだに書く）を読み飛ばして読む
    static func decode(_ data: Data) -> JobReply? {
        try? JSONDecoder().decode(JobReply.self, from: PCResults.trimmed(data))
    }
}

/// 下書き（result と同じ形のうち、行の始まり・終わり・文だけを読む）
struct PCDraft: Decodable {
    struct Line: Decodable {
        let start: Double
        let end: Double
        let text: String
    }
    let lines: [Line]
}

/// PC から受け取った、でき上がりの答えの置き場所（Caches/pcresults/<名前>.json。版 8。2026-11-07）。
/// 待ち合わせの返事と、下書きを見に行ったときにでき上がっていた答えを置き、取り込み（Pipeline.transcribe）が
/// PC に聞く前にここを見る。使い終わったら消す（2日より古いものも消す）。会話の中身なので端末の中だけに置く
enum PCResults {
    static let dir: URL = {
        let dir = URL.cachesDirectory.appendingPathComponent("pcresults", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name + ".json") }

    static func save(_ data: Data, name: String) {
        try? trimmed(data).write(to: url(name), options: .atomic)
    }

    static func load(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    static func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    static func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    /// 古い答えを消す
    static func prune(olderThan age: TimeInterval = 2 * 86400, now: Date = .now) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > age { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// 頭とお尻の空白・改行を除く
    static func trimmed(_ data: Data) -> Data {
        let blank: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
        guard let first = data.firstIndex(where: { !blank.contains($0) }),
              let last = data.lastIndex(where: { !blank.contains($0) }) else { return Data() }
        return data.subdata(in: first..<(last + 1))
    }

    /// でき上がりの答えか（status が done で、result がある）
    static func isDone(_ data: Data) -> Bool {
        guard let reply = JobReply.decode(data) else { return false }
        return reply.status == "done" && reply.result != nil
    }
}

/// 区切りを、アプリが止まっても続く転送（バックグラウンドの URLSession）で PC に送る（2026-11-07）。
/// 送る区切りは写しを作ってから送る（送っているあいだに元の区切りが処理されて動いても困らないように）。
/// 待ち合わせ（wait=1）のときは、PC が文字にし終わるまで返事を待ち、返事の中身（でき上がりの答え）を
/// PCResults に置いて、取り込みを進めてもらう（onResult。版 8。2026-11-07）
final class PCJobUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = PCJobUploader()
    static let identifier = "com.off53jub.lifelog.pcjobs"
    /// 返事が途切れてもこれだけは待つ（PC は待たせているあいだ15秒ごとに空白を書くので、それが届くかぎり切れない）
    static let idleTimeout: TimeInterval = 120
    private static let stage: URL = {
        let dir = URL.cachesDirectory.appendingPathComponent("pcjobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let lock = NSLock()
    private var finish: (() -> Void)?
    /// 送り終わったあとに届いている返事の中身（送りごと）
    private var replies: [Int: Data] = [:]
    /// でき上がりの答えを受け取ったら呼ぶ（区切りの名前）
    private var onResult: (@Sendable (String) -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForRequest = Self.idleTimeout
        // 待ち合わせで待っている送りがあっても、新しい区切りを送り始められるように
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// アプリが起動したときに呼ぶ（前の起動で送っていた分の知らせを受け取れるように）
    func start() {
        _ = session
        PCResults.prune()
    }

    func setOnResult(_ onResult: (@Sendable (String) -> Void)?) {
        lock.withLock { self.onResult = onResult }
    }

    /// PC に送っている途中の区切りの数（写しの数。家の PC への様子に使う。2026-11-07）
    static var stagedCount: Int {
        ((try? FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)) ?? []).count
    }

    /// その区切りを送っている途中なら、写しを作った時刻（待ち合わせなら、答えを受け取るまで写しが残る）
    static func stagedSince(_ name: String) -> Date? {
        let url = stage.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
    }

    func upload(_ url: URL, request: URLRequest, cellular: Bool) {
        let copy = Self.stage.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
        var request = request
        request.allowsCellularAccess = cellular
        let task = session.uploadTask(with: request, fromFile: copy)
        task.taskDescription = url.lastPathComponent
        task.resume()
        Tally.add("jobs.sent")
    }

    /// iOS が、裏での転送の知らせを渡すためにアプリを起こしたとき
    func handleEvents(completion: @escaping () -> Void) {
        lock.withLock { finish = completion }
        _ = session
    }

    /// 返事の中身が届いた（待ち合わせなら、空白のあとにでき上がりの答え）
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            var body = replies[dataTask.taskIdentifier] ?? Data()
            body.append(data)
            // 答えは多くても数百KB。大きすぎるものは受け取らない
            replies[dataTask.taskIdentifier] = body.count > 8 * 1024 * 1024 ? Data() : body
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let received = lock.withLock { replies.removeValue(forKey: task.taskIdentifier) }
        if let name = task.taskDescription {
            try? FileManager.default.removeItem(at: Self.stage.appendingPathComponent(name))
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error != nil || status != 200 { Tally.add("jobs.failed") }
        // 待ち合わせの返事ででき上がりが届いたら、端末の中に置いて取り込みを進めてもらう
        guard error == nil, status == 200, let name = task.taskDescription, let body = received, PCResults.isDone(body) else { return }
        PCResults.save(body, name: name)
        Tally.add("jobs.waited")
        let callback = lock.withLock { onResult }
        callback?(name)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = lock.withLock { () -> (() -> Void)? in
            defer { finish = nil }
            return finish
        }
        DispatchQueue.main.async { done?() }
    }
}

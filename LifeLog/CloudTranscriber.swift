import Foundation

/// OpenAI の gpt-transcribe で文字起こしする（高精度・従量課金）。
/// このモデルは発言ごとの時刻を返さないので、文ごとに区切った文字だけを返す。
enum CloudTranscriber {
    static let model = "gpt-transcribe"
    /// 1分あたりの料金（ドル）。2026-10 時点の公式料金。
    static let dollarsPerMinute = 0.0045

    enum Failure: LocalizedError {
        /// キーが違う・残高が無いなど、待っても直らないもの
        case rejected(String)
        /// 通信や混雑など、あとでやり直せば通るもの
        case temporary(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let s), .temporary(let s): s
            }
        }
    }

    static func transcribe(_ url: URL, apiKey: String, keywords: [String]) async throws -> [String] {
        let boundary = "LifeLog-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model)
        field("languages[]", "ja")
        field("prompt", "日本語の日常会話や仕事の打ち合わせを録音したものです。句読点を付けて書き起こしてください。")
        for word in keywords {
            field("keywords[]", word)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: audio/m4a\r\n\r\n")
        body.append(try Data(contentsOf: url))
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw Failure.temporary("OpenAI に接続できませんでした")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let text = json?["text"] as? String else {
            let error = json?["error"] as? [String: Any]
            let detail = (error?["message"] as? String) ?? "HTTP \(status)"
            switch (status, error?["code"] as? String) {
            case (401, _):
                throw Failure.rejected("OpenAI の API キーが使えません: \(detail)")
            case (429, "insufficient_quota"):
                throw Failure.rejected("OpenAI の残高が足りません: \(detail)")
            case (400, _), (403, _), (404, _):
                throw Failure.rejected("OpenAI に断られました: \(detail)")
            default:
                throw Failure.temporary("OpenAI が応答しませんでした: \(detail)")
            }
        }
        return sentences(in: text)
    }

    /// 「。」「？」「！」で区切って1文ずつにする。
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。？！?!".contains(ch) {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}

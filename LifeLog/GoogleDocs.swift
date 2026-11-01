import Foundation
import GoogleSignIn
import UIKit

/// Google ドライブの「LifeLog」フォルダに、日付ごとの Google ドキュメントを作って追記する。
/// スコープは drive.file（このアプリが作ったファイルだけに触れる）。
@MainActor
final class GoogleDocs {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let folderName = "LifeLog"

    private let defaults = UserDefaults.standard

    var signedInEmail: String? { GIDSignIn.sharedInstance.currentUser?.profile?.email }

    func restore() async {
        _ = try? await GIDSignIn.sharedInstance.restorePreviousSignIn()
    }

    func signIn() async throws {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        _ = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: root, hint: nil, additionalScopes: [Self.scope])
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        defaults.removeObject(forKey: "folderId")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("doc-") || key.hasPrefix("audioFolder") || key.hasPrefix("driveStamp-") {
            defaults.removeObject(forKey: key)
        }
    }

    /// 日付（例: 2026-10-16）のドキュメントの末尾に text を足す。
    func append(_ text: String, day: String) async throws {
        let docId = try await documentId(for: day)
        let body: [String: Any] = ["requests": [
            ["insertText": ["endOfSegmentLocation": [:], "text": text]],
        ]]
        _ = try await request("POST", "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate", json: body)
    }

    /// 次に追記する文字が入る位置（ドキュメントは必ず空の段落で終わるので、その手前）。
    func endIndex(day: String) async throws -> Int {
        let docId = try await documentId(for: day)
        let doc = try await request("GET", "https://docs.googleapis.com/v1/documents/\(docId)?fields=body.content(endIndex)")
        let content = (doc["body"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let last = content.last?["endIndex"] as? Int ?? 2
        return max(1, last - 1)
    }

    /// 段落の頭（index）に、見出し1行と本文を差し込む。index は UTF-16 で数えた位置。
    func insert(heading: String, body: String, at index: Int, style: String, day: String) async throws {
        let docId = try await documentId(for: day)
        // 手で編集されて短くなっていても、ドキュメントの外には書かない
        let at = min(index, try await endIndex(day: day))
        let headingLength = (heading + "\n").utf16.count
        var requests: [[String: Any]] = [
            ["insertText": ["location": ["index": at], "text": heading + "\n" + body]],
            ["updateParagraphStyle": [
                "range": ["startIndex": at, "endIndex": at + headingLength],
                "paragraphStyle": ["namedStyleType": style],
                "fields": "namedStyleType",
            ]],
        ]
        if !body.isEmpty {
            // 差し込んだ先が見出しだと本文も見出しになるので、本文は普通の文字に戻す
            requests.append(["updateParagraphStyle": [
                "range": ["startIndex": at + headingLength, "endIndex": at + headingLength + body.utf16.count],
                "paragraphStyle": ["namedStyleType": "NORMAL_TEXT"],
                "fields": "namedStyleType",
            ]])
        }
        _ = try await request("POST", "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate",
                              json: ["requests": requests])
    }

    /// 名前 name のドキュメントの中身を、まるごと書き換える（このアプリが作った案内や索引のドキュメント用。日ごとの記録には使わない）。
    /// paragraphs は段落の文字（改行なし）と、見出しの種類（"HEADING_1" など。nil なら普通の文字）。
    func overwrite(_ paragraphs: [(text: String, style: String?)], name: String) async throws {
        let docId = try await documentId(for: name)
        let end = try await endIndex(day: name)
        let text = paragraphs.map { $0.text + "\n" }.joined()
        var requests: [[String: Any]] = []
        if end > 1 {
            requests.append(["deleteContentRange": ["range": ["startIndex": 1, "endIndex": end]]])
        }
        requests.append(["insertText": ["location": ["index": 1], "text": text]])
        requests.append(["updateParagraphStyle": [
            "range": ["startIndex": 1, "endIndex": 1 + text.utf16.count],
            "paragraphStyle": ["namedStyleType": "NORMAL_TEXT"],
            "fields": "namedStyleType",
        ]])
        var at = 1
        for p in paragraphs {
            let length = (p.text + "\n").utf16.count
            if let style = p.style {
                requests.append(["updateParagraphStyle": [
                    "range": ["startIndex": at, "endIndex": at + length],
                    "paragraphStyle": ["namedStyleType": style],
                    "fields": "namedStyleType",
                ]])
            }
            at += length
        }
        _ = try await request("POST", "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate",
                              json: ["requests": requests])
    }

    /// 本文の段落。text は段落の終わりの改行を除いた中身。index は UTF-16 で数えた位置。
    private struct Paragraph {
        let start: Int
        let end: Int
        let text: String
    }

    private func paragraphs(docId: String) async throws -> [Paragraph] {
        let fields = "body.content(startIndex,endIndex,paragraph(elements(textRun(content))))"
        let doc = try await request("GET", "https://docs.googleapis.com/v1/documents/\(docId)?fields=\(fields)")
        let content = (doc["body"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.compactMap { item in
            guard let paragraph = item["paragraph"] as? [String: Any],
                  let start = item["startIndex"] as? Int, let end = item["endIndex"] as? Int else { return nil }
            let elements = paragraph["elements"] as? [[String: Any]] ?? []
            var text = elements.compactMap { ($0["textRun"] as? [String: Any])?["content"] as? String }.joined()
            if text.hasSuffix("\n") { text.removeLast() }
            return Paragraph(start: start, end: end, text: text)
        }
    }

    private static let timeLine = try! NSRegularExpression(pattern: #"^\d{2}:\d{2}:\d{2}  "#)

    private static func isTimeLine(_ text: String) -> Bool {
        timeLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 中身が lines のどれかと同じ段落を、行ごと消す（同じ行が2つあれば2つまで）。
    /// headings の見出しは、そのすぐ下の「・」の要点ごと消す。
    /// 文字起こしの行のすぐ下にある空の段落（前に中身だけ消した名残）も詰める。消した範囲を返す。
    func deleteParagraphs(_ lines: [String], headings: [String] = [], day: String) async throws -> [Range<Int>] {
        let docId = try await documentId(for: day)
        let paragraphs = try await paragraphs(docId: docId)
        var remaining: [String: Int] = [:]
        for line in lines { remaining[line, default: 0] += 1 }
        let headingSet = Set(headings)
        var ranges: [Range<Int>] = []
        var lastText = ""
        var inHeading = false
        // 最後の段落はドキュメントの終わりなので消せない
        for p in paragraphs.dropLast() {
            var drop = false
            if let n = remaining[p.text], n > 0 {
                remaining[p.text] = n - 1
                drop = true
                inHeading = false
            } else if headingSet.contains(p.text) {
                drop = true
                inHeading = true
            } else if inHeading && p.text.hasPrefix("・") {
                drop = true
            } else if p.text.isEmpty && Self.isTimeLine(lastText) {
                drop = true
                inHeading = false
            } else {
                inHeading = false
            }
            if !p.text.isEmpty { lastText = p.text }
            guard drop else { continue }
            if let last = ranges.last, last.upperBound == p.start {
                ranges[ranges.count - 1] = last.lowerBound..<p.end
            } else {
                ranges.append(p.start..<p.end)
            }
        }
        // 後ろから消せば、前の位置はずれない
        let requests: [[String: Any]] = ranges.reversed().map { range in
            ["deleteContentRange": ["range": ["startIndex": range.lowerBound, "endIndex": range.upperBound]]]
        }
        for start in stride(from: 0, to: requests.count, by: 200) {
            _ = try await request("POST", "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate",
                                  json: ["requests": Array(requests[start..<min(requests.count, start + 200)])])
        }
        return ranges
    }

    /// 行を1つ差し戻す。next の行があればその前に、無ければ previous の行のあとに、どちらも無ければ末尾に入れる。
    /// 差し込んだ位置と長さを返す。
    func insertLine(_ line: String, before next: String?, after previous: String?, day: String) async throws -> (at: Int, length: Int) {
        let docId = try await documentId(for: day)
        let paragraphs = try await paragraphs(docId: docId)
        let text: String
        let at: Int
        if let next, let p = paragraphs.first(where: { $0.text == next }) {
            at = p.start
            text = line + "\n"
        } else if let previous, let p = paragraphs.first(where: { $0.text == previous }) {
            at = p.end - 1
            text = "\n" + line
        } else {
            at = max(1, (paragraphs.last?.end ?? 2) - 1)
            text = line + "\n"
        }
        _ = try await request("POST", "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate",
                              json: ["requests": [["insertText": ["location": ["index": at], "text": text]]]])
        return (at, text.utf16.count)
    }

    /// ドキュメントの中の文字を置き換える（見つかったところすべて）。
    func replaceAll(_ pairs: [(find: String, replace: String)], day: String) async throws {
        guard !pairs.isEmpty else { return }
        let docId = try await documentId(for: day)
        // 1回に送る量を抑えるため、100件ずつに分ける
        for start in stride(from: 0, to: pairs.count, by: 100) {
            let requests: [[String: Any]] = pairs[start..<min(pairs.count, start + 100)].map { pair in
                ["replaceAllText": ["containsText": ["text": pair.find, "matchCase": true], "replaceText": pair.replace]]
            }
            _ = try await request("POST", "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate",
                                  json: ["requests": requests])
        }
    }

    /// このアプリが作ったファイルのうち、名前が prefix で始まるものをゴミ箱に入れる。
    func trashFiles(namedWithPrefix prefix: String) async throws {
        let quoted = prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [URLQueryItem(name: "q", value: "name contains '\(quoted)' and trashed = false"),
                            URLQueryItem(name: "fields", value: "files(id,name)")]
        let found = try await request("GET", comps.url!.absoluteString)
        for file in found["files"] as? [[String: Any]] ?? [] {
            guard let id = file["id"] as? String, (file["name"] as? String)?.hasPrefix(prefix) == true else { continue }
            _ = try await request("PATCH", "https://www.googleapis.com/drive/v3/files/\(id)", json: ["trashed": true])
        }
    }

    // MARK: - 音声

    /// 音声を「LifeLog/音声/日付」フォルダに上げて、ドライブ上の id を返す。
    func uploadAudio(_ url: URL, day: String) async throws -> String {
        let folder = try await audioFolder(day: day)
        // 数 MB あるので、途中で切れても安全な resumable で上げる
        var start = try await authorized("POST", "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("audio/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": url.lastPathComponent, "parents": [folder]])
        let (_, opened) = try await send(start)
        guard let location = opened.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location) else {
            throw GoogleError.unexpected("アップロードを始められませんでした")
        }
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 300
        let uploaded = try await URLSession.shared.upload(for: put, fromFile: url)
        let (data, _) = try Self.checked(uploaded)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { throw GoogleError.unexpected("アップロード結果に id がありません") }
        return id
    }

    /// ドライブに上げた音声を取ってくる。
    func downloadAudio(id: String) async throws -> Data {
        let req = try await authorized("GET", "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")
        return try await send(req).0
    }

    private func audioFolder(day: String) async throws -> String {
        if let id = defaults.string(forKey: "audioFolder-\(day)") { return id }
        let root: String
        if let id = defaults.string(forKey: "audioFolder") {
            root = id
        } else {
            root = try await findOrCreate(name: "音声", mimeType: "application/vnd.google-apps.folder", parent: try await folderId())
            defaults.set(root, forKey: "audioFolder")
        }
        let id = try await findOrCreate(name: day, mimeType: "application/vnd.google-apps.folder", parent: root)
        defaults.set(id, forKey: "audioFolder-\(day)")
        return id
    }

    // MARK: - Drive

    private func documentId(for day: String) async throws -> String {
        if let id = defaults.string(forKey: "doc-\(day)") { return id }
        let folder = try await folderId()
        let id = try await findOrCreate(name: day, mimeType: "application/vnd.google-apps.document", parent: folder)
        defaults.set(id, forKey: "doc-\(day)")
        return id
    }

    private func folderId() async throws -> String {
        if let id = defaults.string(forKey: "folderId") { return id }
        let id = try await findOrCreate(name: Self.folderName, mimeType: "application/vnd.google-apps.folder", parent: nil)
        defaults.set(id, forKey: "folderId")
        return id
    }

    private func findOrCreate(name: String, mimeType: String, parent: String?) async throws -> String {
        let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var q = "name = '\(quoted)' and mimeType = '\(mimeType)' and trashed = false"
        if let parent { q += " and '\(parent)' in parents" }
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "fields", value: "files(id)")]
        let found = try await request("GET", comps.url!.absoluteString)
        if let files = found["files"] as? [[String: Any]], let id = files.first?["id"] as? String {
            return id
        }
        var meta: [String: Any] = ["name": name, "mimeType": mimeType]
        if let parent { meta["parents"] = [parent] }
        let created = try await request("POST", "https://www.googleapis.com/drive/v3/files?fields=id", json: meta)
        guard let id = created["id"] as? String else { throw GoogleError.unexpected("作成結果に id がありません") }
        return id
    }

    // MARK: - HTTP

    private func request(_ method: String, _ url: String, json: [String: Any]? = nil) async throws -> [String: Any] {
        var req = try await authorized(method, url)
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, _) = try await send(req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func authorized(_ method: String, _ url: String) async throws -> URLRequest {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw GoogleError.notSignedIn }
        let fresh = try await user.refreshTokensIfNeeded()
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(fresh.accessToken.tokenString)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await URLSession.shared.data(for: req)
        return try Self.checked(result)
    }

    private static func checked(_ result: (Data, URLResponse)) throws -> (Data, HTTPURLResponse) {
        let (data, response) = result
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GoogleError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }
}

enum GoogleError: LocalizedError {
    case notSignedIn
    case http(Int, String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Google にログインしていません"
        case .http(let code, let body): "Google API エラー \(code): \(body.prefix(200))"
        case .unexpected(let message): message
        }
    }
}

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
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("doc-") {
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
        var q = "name = '\(name)' and mimeType = '\(mimeType)' and trashed = false"
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
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw GoogleError.notSignedIn }
        let fresh = try await user.refreshTokensIfNeeded()
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(fresh.accessToken.tokenString)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GoogleError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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

import Foundation
import Security
import SwiftUI

/// 有料の票（2026-11-06）。家の PC の多数決で食い違いの大きい行だけ、その所を切り出して ElevenLabs Scribe v2 にも聞き、
/// もう1票として選び直す。本人がオンにしてキーを入れたときだけ。月に使う分（分）の上限を超えたら聞かない。
/// 職場の会話（職場にいる・仕事の予定の最中）は送らない。送ったことはクラウドに送ったものの一覧に残す。
enum PaidVote {
    static let onKey = "paidVoteOn", capKey = "paidVoteCapMinutes", usedKey = "paidVoteUsed"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: onKey) && key != nil }
    static var capMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: capKey)
        return v > 0 ? v : 60
    }

    private static var month: String {
        let c = Calendar.current.dateComponents([.year, .month], from: .now)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// 今月送った秒数
    static var usedSeconds: Double {
        let saved = UserDefaults.standard.dictionary(forKey: usedKey) as? [String: Double] ?? [:]
        return saved[month] ?? 0
    }

    private static func addUsed(_ seconds: Double) {
        var saved = UserDefaults.standard.dictionary(forKey: usedKey) as? [String: Double] ?? [:]
        saved[month, default: 0] += seconds
        UserDefaults.standard.set(saved, forKey: usedKey)
    }

    // MARK: - キー（Keychain。この端末だけ）

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.off53jub.lifelog",
         kSecAttrAccount as String: "elevenlabs-key"]
    }

    static var key: String? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveKey(_ value: String) {
        SecItemDelete(query as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    // MARK: - 聞く

    struct Word: Decodable {
        let text: String
        let start: Double?
        let end: Double?
        let type: String?
    }

    /// 食い違いの大きい行（確からしさが below 未満）だけ、もう1票を足して選び直す。
    static func addVotes(_ lines: [HomePC.Line], audio url: URL, below: Double = HomePC.cloudVoteBelow) async -> [HomePC.Line] {
        guard isOn, let key else { return lines }
        let unsure = lines.indices.filter { (lines[$0].confidence ?? 1) < below && !lines[$0].votes.isEmpty }
        guard let first = unsure.first, let last = unsure.last else { return lines }
        let from = max(0, lines[first].offset - 1), to = lines[last].end + 1
        guard usedSeconds + (to - from) <= Double(capMinutes) * 60 else { return lines }
        guard let clip = await AudioClip.extract(url, from: from, to: to) else { return lines }
        defer { try? FileManager.default.removeItem(at: clip) }
        guard let words = try? await transcribe(clip, key: key) else { return lines }
        addUsed(to - from)
        CloudLog.add(service: "ElevenLabs（文字起こし）", what: "食い違いの大きい行の音声（\(Int(to - from)) 秒）", work: false,
                     size: Int((try? FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int) ?? 0))
        Tally.add("paid.lines", unsure.count)
        var out = lines
        for i in unsure {
            let line = lines[i]
            let text = words.filter { w in
                guard let start = w.start, w.type != "audio_event" else { return false }
                let t = start + from
                return t >= line.offset - 0.3 && t < line.end + 0.3
            }.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var votes = line.votes
            votes["eleven"] = text
            out[i] = HomePC.revote(line, votes: votes)
        }
        return out
    }

    private static func transcribe(_ url: URL, key: String) async throws -> [Word] {
        struct Reply: Decodable { let words: [Word]? }
        let boundary = "lifelog-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", "scribe_v2")
        field("timestamps_granularity", "word")
        field("tag_audio_events", "false")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: url))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudTranscriber.Failure.temporary("ElevenLabs に聞けませんでした（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        return try JSONDecoder().decode(Reply.self, from: data).words ?? []
    }
}

/// 有料の票の設定
struct PaidVoteView: View {
    @AppStorage(PaidVote.onKey) private var on = false
    @AppStorage(PaidVote.capKey) private var cap = 60
    @State private var key = ""
    @State private var hasKey = PaidVote.key != nil

    var body: some View {
        Form {
            Section {
                Toggle("食い違いの大きい行だけ ElevenLabs にも聞く（有料）", isOn: $on)
                Stepper("月に \(cap) 分まで", value: $cap, in: 10...600, step: 10)
                LabeledContent("今月使った分", value: "\(Int(PaidVote.usedSeconds / 60)) 分")
            } footer: {
                Text("家の PC の多数決でモデルどうしの食い違いが大きい行だけ、その所の音声を切り出して ElevenLabs Scribe v2 に送り、もう1票にします。職場の会話は送りません。料金は ElevenLabs の契約によります。")
            }
            Section("API キー") {
                SecureField(hasKey ? "入っています（入れ直すときだけ）" : "ElevenLabs の API キー", text: $key)
                Button("保存") {
                    PaidVote.saveKey(key)
                    key = ""
                    hasKey = PaidVote.key != nil
                }
                .disabled(key.isEmpty)
            }
        }
        .navigationTitle("有料の票")
    }
}

import Foundation
import Observation
import Security

/// 高精度（OpenAI）文字起こしの設定と、今月の使用量。
/// API キーはキーチェーンに、それ以外は UserDefaults に置く。
@MainActor
@Observable
final class TranscriptionSettings {
    var useCloud: Bool { didSet { defaults.set(useCloud, forKey: "useCloud") } }
    /// 1行に1語。人名・社名・専門用語など、聞き取ってほしい言葉。
    var keywordText: String { didSet { defaults.set(keywordText, forKey: "keywords") } }
    /// 今月これだけ使ったら、月が変わるまで端末内の文字起こしに戻す。
    var monthlyLimitMinutes: Int { didSet { defaults.set(monthlyLimitMinutes, forKey: "monthlyLimitMinutes") } }
    private(set) var hasAPIKey = false
    private var usedSeconds: Double = 0
    private var usedMonth = ""

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        let month = Self.month()
        useCloud = d.bool(forKey: "useCloud")
        keywordText = d.string(forKey: "keywords") ?? ""
        monthlyLimitMinutes = d.object(forKey: "monthlyLimitMinutes") as? Int ?? 4000
        hasAPIKey = Keychain.read() != nil
        usedMonth = month
        usedSeconds = d.double(forKey: "cloudSeconds-" + month)
    }

    var apiKey: String? { Keychain.read() }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete()
        } else {
            Keychain.save(trimmed)
        }
        hasAPIKey = Keychain.read() != nil
    }

    var keywords: [String] {
        keywordText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("<") && !$0.contains(">") }
    }

    var usedMinutesThisMonth: Int {
        usedMonth == Self.month() ? Int(usedSeconds / 60) : 0
    }

    var isUnderLimit: Bool { usedMinutesThisMonth < monthlyLimitMinutes }

    /// 今回の音声を高精度で処理するか。キーが無い・上限を超えたときは使わない。
    var shouldUseCloud: Bool { useCloud && hasAPIKey && isUnderLimit }

    func addUsage(seconds: Double) {
        let month = Self.month()
        if usedMonth != month {
            usedMonth = month
            usedSeconds = 0
        }
        usedSeconds += seconds
        defaults.set(usedSeconds, forKey: "cloudSeconds-" + month)
    }

    static func dollars(minutes: Int) -> Double {
        Double(minutes) * CloudTranscriber.dollarsPerMinute
    }

    private static func month() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: .now)
    }
}

private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.off53jub.lifelog",
        kSecAttrAccount as String: "openai-api-key",
    ]

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
        // 録音中は画面ロック中でも処理するので、初回ロック解除後は読めるようにする
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

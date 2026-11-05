import Foundation
import Observation
import Security

/// 高精度（クラウド）文字起こしの設定と、今月の有料分の使用量。
/// API キーはキーチェーンに、それ以外は UserDefaults に置く。
@MainActor
@Observable
final class TranscriptionSettings {
    var useCloud: Bool { didSet { defaults.set(useCloud, forKey: "useCloud") } }
    var provider: CloudTranscriber.Provider {
        didSet {
            defaults.set(provider.rawValue, forKey: "provider")
            hasAPIKey = Keychain.read(provider) != nil
        }
    }
    /// 1行に1語。人名・社名・専門用語など、聞き取ってほしい言葉。
    var keywordText: String { didSet { defaults.set(keywordText, forKey: "keywords") } }
    /// 有料のサービスを今月これだけ使ったら、月が変わるまで端末内の文字起こしに戻す。
    var monthlyLimitMinutes: Int { didSet { defaults.set(monthlyLimitMinutes, forKey: "monthlyLimitMinutes") } }
    private(set) var hasAPIKey = false
    private var usedSeconds: Double = 0
    private var usedMonth = ""

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        let month = Self.month()
        let provider = CloudTranscriber.Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .groq
        useCloud = d.bool(forKey: "useCloud")
        self.provider = provider
        keywordText = d.string(forKey: "keywords") ?? ""
        monthlyLimitMinutes = d.object(forKey: "monthlyLimitMinutes") as? Int ?? 4000
        hasAPIKey = Keychain.read(provider) != nil
        usedMonth = month
        usedSeconds = d.double(forKey: "cloudSeconds-" + month)
    }

    var apiKey: String? { Keychain.read(provider) }
    /// 会話の要約は、文字起こしのサービスにかかわらず Groq の無料枠で作る
    var groqKey: String? { Keychain.read(.groq) }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(provider)
        } else {
            Keychain.save(trimmed, for: provider)
        }
        hasAPIKey = Keychain.read(provider) != nil
    }

    var keywords: [String] {
        keywordText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("<") && !$0.contains(">") }
    }

    var usedMinutesThisMonth: Int {
        usedMonth == Self.month() ? Int(usedSeconds / 60) : 0
    }

    var isUnderLimit: Bool {
        provider.dollarsPerMinute == 0 || usedMinutesThisMonth < monthlyLimitMinutes
    }

    /// 今回の音声を高精度で処理するか。キーが無い・上限を超えたときは使わない。
    var shouldUseCloud: Bool { useCloud && hasAPIKey && isUnderLimit }

    func addUsage(seconds: Double) {
        guard provider.dollarsPerMinute > 0 else { return }
        let month = Self.month()
        if usedMonth != month {
            usedMonth = month
            usedSeconds = 0
        }
        usedSeconds += seconds
        defaults.set(usedSeconds, forKey: "cloudSeconds-" + month)
    }

    func dollars(minutes: Int) -> Double {
        Double(minutes) * provider.dollarsPerMinute
    }

    private static func month() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: .now)
    }
}

private enum Keychain {
    private static func query(_ provider: CloudTranscriber.Provider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.off53jub.lifelog",
            kSecAttrAccount as String: "\(provider.rawValue)-api-key",
        ]
    }

    static func read(_ provider: CloudTranscriber.Provider) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, for provider: CloudTranscriber.Provider) {
        delete(provider)
        var q = query(provider)
        q[kSecValueData as String] = Data(value.utf8)
        // 録音中は画面ロック中でも処理するので、初回ロック解除後は読めるようにする
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ provider: CloudTranscriber.Provider) {
        SecItemDelete(query(provider) as CFDictionary)
    }
}

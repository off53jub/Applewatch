import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// iPhone の中の言語モデル（Apple Intelligence の端末内モデル、Foundation Models）。
/// 無料で、上限や混雑が無く、中身を外に送らない。そのかわり Groq の大きいモデルより賢くなく、一度に読める量が少ない
/// （入れる文と答えを合わせて4,096トークンまで）ので、長いものは区切るか、頭と終わりだけを渡す。
/// Apple Intelligence に対応した機種（iPhone 15 Pro 以降など）で、設定の Apple Intelligence がオンのときだけ使える。
enum LocalModel {
    enum Mode: Int, CaseIterable, Identifiable {
        case off, fallback, work, always
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .off: "使わない"
            case .fallback: "Groq が使えないときだけ"
            case .work: "職場の会話は端末内で"
            case .always: "いつも端末内で"
            }
        }
    }

    static let modeKey = "localModelMode"
    /// 初めは「Groq が使えないときだけ」（キーが無い・無料枠を使い切った・混んでいる・通信できない）
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.object(forKey: modeKey) as? Int ?? 1) ?? .fallback }

    /// Groq のキーが無いとき、言語モデルの呼び出しに渡す印（端末内で動かす）
    static let keyless = "on-device"
    /// 端末内で動かすときの、長い会話を区切る長さと、1回に渡す文字数の上限
    static let pieceLength = 1_200
    static let maxPrompt = 2_600

    /// 端末内の言語モデルを使うか（使える機種で、使わない設定でない）
    static var isOn: Bool { mode != .off && isUsable }

    static var isUsable: Bool { status.usable }

    /// 使えるかと、画面に出す説明
    static var status: (usable: Bool, text: String) {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let japanese = model.supportedLanguages.contains { $0.languageCode?.identifier == "ja" }
            return japanese ? (true, "使える") : (false, "日本語に対応していない")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return (false, "この機種では使えない（Apple Intelligence に対応した機種が要る）")
            case .appleIntelligenceNotEnabled: return (false, "「設定」→「Apple Intelligence と Siri」でオンにすると使える")
            case .modelNotReady: return (false, "モデルを準備中（しばらくすると使える）")
            @unknown default: return (false, "使えない")
            }
        }
        #else
        return (false, "この版の iOS では使えない")
        #endif
    }

    /// JSON で答えさせる。長すぎる文は、頭（指示）と終わりを残して途中を省く。読めなければ1回だけ頼み直す。
    static func json(system: String, prompt: String) async throws -> [String: Any] {
        #if canImport(FoundationModels)
        let text = prompt.count > maxPrompt
            ? String(prompt.prefix(1_000)) + "\n…（長いので途中を省きました）…\n" + String(prompt.suffix(maxPrompt - 1_000))
            : prompt
        let session = LanguageModelSession(instructions: system)
        let options = GenerationOptions(temperature: 0.3)
        let first = try await session.respond(to: text, options: options)
        if let json = parse(first.content) { return json }
        let again = try await session.respond(to: "いまの答えを、指定した形の JSON だけにして返してください。", options: options)
        if let json = parse(again.content) { return json }
        throw CloudTranscriber.Failure.temporary("端末内の言語モデルの答えを読めませんでした")
        #else
        throw CloudTranscriber.Failure.temporary("端末内の言語モデルはこの版の iOS では使えません")
        #endif
    }

    /// 答えの中の最初の { から最後の } までを JSON として読む
    static func parse(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }
}

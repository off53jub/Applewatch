import AppIntents
import AVFoundation
import Foundation
import Observation

/// 声で聞く・耳で聞く（2026-11-15。強化案 59。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 3」）。
/// - 「記録に聞く」（Siri・ショートカット。質問を受け取る）: 家の PC の「母艦から探す」（POST /ask-mothership。使えるときだけ）、
///   だめなら今までの「記録に質問する」で答え、Siri が声で読む。25 秒で答えが出なければ「時間がかかっています」と返す。
/// - 「朝のまとめを聞く」（ショートカット・「昨日と今日」のボタン）: 朝の「昨日と今日」を、iPhone の日本語の声で 2 分ほどで読み上げる。
///   2026-11-09 に「声の読み上げはやめる」と決めたので、自分で押したときだけ読む（知らせのときに勝手には読まない）。
///   録音中に読み上げると、その声も録音に入ることがある（テレビの声と同じく、記録では分けられることが多い）。
/// 中身の文は記録（ログ）に書かない。

@MainActor
enum VoiceRecall {
    /// 質問に答える（LifeLogApp が入れる）
    static var ask: ((String) async -> String)?
    /// 朝の「昨日と今日」の読み上げる文（今日の分が無ければ nil。LifeLogApp が入れる）
    static var morning: (() -> String?)?
    /// Siri が待てる長さに収める（秒）
    nonisolated static let timeout: Double = 25
    /// 読み上げの長さの目安（日本語の声で 2 分ほど）
    static let morningChars = 780
    static let answerChars = 400

    /// 声で読む形にする（[1] のような出どころの番号・記号を除き、長さを切る）
    static func spoken(_ text: String, limit: Int = answerChars) -> String {
        var out = text.replacingOccurrences(of: #"\[[0-9０-９,、\s]+\]"#, with: "", options: .regularExpression)
        for mark in ["**", "##", "#", "`", "＊", "*"] {
            out = out.replacingOccurrences(of: mark, with: "")
        }
        out = out.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.count > limit else { return out }
        return String(out.prefix(limit)) + "。続きはアプリで見てください。"
    }

    /// 朝の「昨日と今日」を読み上げる文にする（行の頭の記号を除き、行の終わりを句点にする）
    static func morningScript(_ card: String) -> String {
        var parts: [String] = ["おはようございます。昨日と今日です。"]
        for raw in card.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "・-－★☆●○■□>：:".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            if let last = line.last, !"。！？!?".contains(last) { line += "。" }
            parts.append(line)
        }
        let text: String = spoken(parts.joined(separator: "\n"), limit: morningChars)
        return text
    }
}

extension Pipeline {
    /// 「記録に聞く」の答え（25 秒まで）
    func voiceAnswer(_ question: String) async -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "何を聞きたいか教えてください。" }
        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in await self.voiceAnswerNow(q) }
            group.addTask {
                try? await Task.sleep(for: .seconds(VoiceRecall.timeout))
                return nil
            }
            let first: String? = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        Tally.add(result == nil ? "voiceAsk.timeout" : "voiceAsk.answered")
        return result ?? "時間がかかっています。少ししてから、アプリの「記録に質問する」で聞いてください。"
    }

    private func voiceAnswerNow(_ q: String) async -> String {
        if MothershipAsk.usable(features: homePC.features, useClaude: ClaudeRoute.useClaude, forWork: ClaudeRoute.forWork),
           let answer = try? await askMothership(q) {
            return VoiceRecall.spoken(answer.found ? answer.answer : "記録からは見つかりませんでした。")
        }
        if let answer = try? await ask(q) {
            return VoiceRecall.spoken(answer.text)
        }
        return "記録に聞けませんでした。家の PC とのつながりか、言語モデルの設定を確かめてください。"
    }

    /// 今日（か明日）の「昨日と今日」の読み上げる文
    func morningSpeech() -> String? {
        guard let record = MorningBriefStore.shared.current else { return nil }
        let today: String = MeetingLiveBook.dayKey.string(from: .now)
        guard record.day >= today else { return nil }
        return VoiceRecall.morningScript(record.text)
    }
}

/// 日本語の声で読み上げる（iPhone）。録音の音の設定を変えないよう、読み上げは自分の音の設定で鳴らす（時計の WatchReader と同じ）
@MainActor
@Observable
final class MorningSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = MorningSpeaker()

    private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = false
    }

    func speak(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        speaking = true
        Tally.add("morningSpeech.played")
    }

    func toggle(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            speaking = false
        } else {
            speak(text)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

// MARK: - ショートカット・Siri

/// 「記録に聞く」（Siri・ショートカット）。答えは Siri が声で読む
struct AskRecordsIntent: AppIntent {
    static let title: LocalizedStringResource = "記録に聞く"
    static let description: IntentDescription? = IntentDescription("LifeLog の記録（家の PC が使えれば、LINE・予定・お金なども）に質問して、声で答えます。")
    /// 記録の中身なので、ロックを外してから
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "質問", requestValueDialog: IntentDialog("何を聞きますか？"))
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var answer: String = "LifeLog の準備ができていません。一度アプリを開いてください。"
        if let ask = VoiceRecall.ask {
            answer = await ask(question)
        }
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

/// 「朝のまとめを聞く」。アプリを開いて、朝の「昨日と今日」を日本語の声で読み上げる（2 分ほど）
struct ListenMorningBriefIntent: AppIntent {
    static let title: LocalizedStringResource = "朝のまとめを聞く"
    static let description: IntentDescription? = IntentDescription("LifeLog の朝の「昨日と今日」を、日本語の声で 2 分ほどで読み上げます。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let text = VoiceRecall.morning?() {
            MorningSpeaker.shared.speak(text)
        } else {
            MorningSpeaker.shared.speak("今日の「昨日と今日」はまだできていません。")
        }
        return .result()
    }
}

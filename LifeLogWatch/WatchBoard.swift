import AVFoundation
import Foundation
import Observation
import WatchKit

/// iPhone から届く、時計の画面に出す中身（2026-11-07）。iPhone の LifeLog/WatchInfo.swift と同じ名前の形で読む。
/// 古い iPhone のアプリから届いても読めるよう、ほとんどを「無くてもよい」にしてある。
struct WatchInfo: Codable {
    struct TaskItem: Codable, Identifiable {
        var id: String
        var what: String
        var due: String?
        var from: String?
        var late: Bool?
    }

    struct Event: Codable {
        var title: String
        var start: Double
        var end: Double?
        var people: [String]?
        var brief: String?
        var place: String?
    }

    struct Talk: Codable {
        var start: Double
        var end: Double?
        var title: String?
        var points: [String]?
        var people: [String]?
        var place: String?
    }

    struct Status: Codable {
        var pending: Int?
        var processed: Double?
    }

    struct Brief: Codable {
        var day: String
        var text: String
    }

    var made: Double
    var tasks: [TaskItem]?
    var openCount: Int?
    var next: Event?
    var last: Talk?
    var status: Status?
    var morning: Brief?
}

/// 時計の画面の中身（頼まれごと・次の予定・さっきの会話・聞く・朝の読み上げ）を持つ。
/// 届いた中身は時計の中にも残し（iPhone が離れていても前の分を出す）、新しいものが届いたら入れ替える。
@MainActor
@Observable
final class WatchBoard {
    private(set) var info: WatchInfo?
    /// 「聞く」の答えと、その質問
    private(set) var answer: String?
    private(set) var question: String?
    /// 「聞く」の様子（「調べています」など）
    private(set) var askState = ""
    private(set) var asking = false
    let reader = WatchReader()

    /// 「済み」を押した頼まれごと（iPhone から新しい中身が届くまで、一覧から隠す）
    private var doneAt: [String: Date] = [:]

    private let sender: WatchSender
    private static let infoKey = "watchInfo"
    private static let answerKey = "watchAnswer"
    private static let questionKey = "watchQuestion"

    init(sender: WatchSender) {
        self.sender = sender
        if let data = UserDefaults.standard.data(forKey: Self.infoKey) {
            info = try? JSONDecoder().decode(WatchInfo.self, from: data)
        }
        answer = UserDefaults.standard.string(forKey: Self.answerKey)
        question = UserDefaults.standard.string(forKey: Self.questionKey)
        sender.onInfo = { [weak self] data in
            Task { @MainActor in self?.received(data) }
        }
        sender.onAnswer = { [weak self] text, question in
            Task { @MainActor in self?.answered(text, question: question) }
        }
    }

    /// 出す頼まれごと（「済み」を押したものを除く）
    var tasks: [WatchInfo.TaskItem] {
        (info?.tasks ?? []).filter { doneAt[$0.id] == nil }
    }

    /// まだの頼まれごとの数（「済み」を押した分を引く）
    var openCount: Int {
        max(0, (info?.openCount ?? info?.tasks?.count ?? 0) - doneAt.count)
    }

    private func received(_ data: Data) {
        guard let new = try? JSONDecoder().decode(WatchInfo.self, from: data) else { return }
        // 前に届いたものより古ければ使わない
        if let old = info, old.made > new.made { return }
        info = new
        UserDefaults.standard.set(data, forKey: Self.infoKey)
        // iPhone が済みにした（一覧から消えた）もの・30分たったものは、隠すのをやめる
        let ids = Set((new.tasks ?? []).map(\.id))
        doneAt = doneAt.filter { ids.contains($0.key) && Date.now.timeIntervalSince($0.value) < 30 * 60 }
    }

    /// 頼まれごとを済みにする（iPhone の頼まれごと帳で済みになる）
    func markDone(_ id: String) {
        doneAt[id] = .now
        sender.taskDone(id)
        WKInterfaceDevice.current().play(.success)
    }

    /// iPhone の記録に質問する
    func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        asking = true
        question = q
        answer = nil
        askState = "送っています…"
        UserDefaults.standard.set(q, forKey: Self.questionKey)
        UserDefaults.standard.removeObject(forKey: Self.answerKey)
        sender.askQuestion(q) { [weak self] reply in
            Task { @MainActor in
                guard let self, self.answer == nil else { return }
                self.askState = reply
            }
        }
    }

    /// iPhone から答えが届いた。手首を軽くたたいて知らせる
    private func answered(_ text: String, question q: String) {
        asking = false
        askState = ""
        answer = text
        if !q.isEmpty { question = q }
        UserDefaults.standard.set(text, forKey: Self.answerKey)
        if !q.isEmpty { UserDefaults.standard.set(q, forKey: Self.questionKey) }
        WKInterfaceDevice.current().play(.notification)
    }
}

/// 文を日本語の声で読み上げる（時計）。録音の音の設定を変えないよう、読み上げは自分の音の設定で鳴らす
@MainActor
@Observable
final class WatchReader: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = false
    }

    func toggle(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            speaking = false
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        synthesizer.speak(utterance)
        speaking = true
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

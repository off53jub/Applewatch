import Foundation

/// 夜の聞き直しで使う覚え書き（どの区切りを Haas-ja で書けたか、どの区切りを聞き直し済みか）。
/// 区切りの名前の頭が録音を始めた時刻なので、3日より古い名前は忘れる。
@MainActor
enum NightlyRecheck {
    private static let haasKey = "haasDoneAudio"
    private static let nightKey = "nightDoneAudio"
    private static let keepFor: TimeInterval = 3 * 24 * 3600

    /// Haas-ja（家の PC か iPhone 内）で文字起こしできた区切り
    static func markHaasDone(_ name: String) { add(name, to: haasKey) }
    static func isHaasDone(_ name: String) -> Bool { list(haasKey).contains(name) }

    /// 家の PC の多数決（2つ以上のモデル）で文字起こしできた区切り。夜の聞き直しで PC にもう一度送らない
    private static let ensembleKey = "ensembleDoneAudio"
    static func markEnsembleDone(_ name: String) { add(name, to: ensembleKey) }
    static func isEnsembleDone(_ name: String) -> Bool { list(ensembleKey).contains(name) }

    /// 夜の聞き直しを済ませた区切り
    static func markNightDone(_ name: String) { add(name, to: nightKey) }
    static func isNightDone(_ name: String) -> Bool { list(nightKey).contains(name) }

    private static func list(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func add(_ name: String, to key: String) {
        var names = list(key)
        names.insert(name)
        let old = Date.now.addingTimeInterval(-keepFor)
        names = names.filter { Storage.startDate(of: URL(fileURLWithPath: $0)).map { $0 > old } ?? false }
        UserDefaults.standard.set(Array(names), forKey: key)
    }
}

/// 夜の聞き直しで、誤変換の直しを言語モデルに頼む回数（2026-11-07。版 9）。
///
/// 区切りを短く（長くても2分）したので、区切りごとに1回頼むと、5分の区切りのころの2〜4倍の回数になる
/// （Groq の無料枠は1日の回数と文字数に上限があり、頼むたびに指示の文の分も数えられる）。そこで:
/// 1. 続いている区切り（同じ日・職場かどうかが同じ）を、合わせて5分（5分の区切り1つ分）までまとめて、1回で頼む
/// 2. 1晩に頼む回数に上限を置く。上限に達したら、言語モデルに頼む区切りは聞き直さずに残し、次の夜に続ける
/// 端末の中の言語モデル（Apple Intelligence）で直すときは数えない（無料で上限が無く、外に送らないので）。
@MainActor
enum NightBudget {
    /// 1回にまとめて頼む区切りの長さの合計（秒）。5分の区切り1つ分
    nonisolated static let batchSeconds: TimeInterval = 300
    /// 1晩に頼む回数の上限。5分の区切りで10時間分（1日に録る会話より多い）
    nonisolated static let perNight = 120

    private static let usedKey = "nightLLMUsed"

    /// どの夜の分か（18時〜翌12時はその夜。昼の12〜18時に「今すぐ聞き直す」を押したときは、ゆうべの分に数える）
    nonisolated static func night(for date: Date, calendar: Calendar = .current) -> String {
        if let key = PCDiag.nightKey(for: date, calendar: calendar) { return key }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        return PCJSON.dayString(yesterday, calendar: calendar)
    }

    /// 今夜使った回数
    static func used(now: Date = .now) -> Int {
        let saved = UserDefaults.standard.dictionary(forKey: usedKey) as? [String: Int] ?? [:]
        return saved[night(for: now)] ?? 0
    }

    /// 今夜あと何回頼めるか
    static func left(now: Date = .now) -> Int { max(0, perNight - used(now: now)) }

    /// 1回分を取る。上限に達していれば false（効き目の数に残す）
    static func take(now: Date = .now) -> Bool {
        let count = used(now: now)
        guard count < perNight else {
            Tally.add("budget.night")
            return false
        }
        // 前の夜の分は残さない
        UserDefaults.standard.set([night(for: now): count + 1], forKey: usedKey)
        return true
    }

    /// 取ったけれど頼まなかった（直す行が無かった）1回分を戻す
    static func giveBack(now: Date = .now) {
        let count = used(now: now)
        guard count > 0 else { return }
        UserDefaults.standard.set([night(for: now): count - 1], forKey: usedKey)
    }

    /// まとめている区切り（合わせて seconds 秒）に、次の区切りを足せるか。まとめが空なら、いつでも足せる
    nonisolated static func fits(batch seconds: TimeInterval, adding next: TimeInterval) -> Bool {
        seconds <= 0 || seconds + next <= batchSeconds + 1
    }

    /// まとめた区切りのうち、言語モデルに渡す行（区切りの番号・行の番号）。書き直した行と、確からしさの低い行
    static func picks(_ items: [NightItem]) -> [(item: Int, line: Int)] {
        var out: [(item: Int, line: Int)] = []
        for (k, item) in items.enumerated() {
            for i in item.lines.indices where item.texts[i] != item.lines[i].text || item.lines[i].isUncertain {
                out.append((k, i))
            }
        }
        return out
    }
}

/// 夜の聞き直しで、言語モデルに頼む前の1区切り（まとめて頼むために溜めておく）
struct NightItem {
    let day: String
    let audio: String
    /// 聞き直す行（確かめ済みの行は除いたもの）
    let lines: [ConversationLog.Line]
    /// 今の文（PC・Haas-ja で書き直したあと）
    var texts: [String]
    let confidence: [Double?]
    /// 端末内の聞き取り（言語モデルに見比べてもらう）
    let heard: [String]
    /// その日の言葉（ヒント）
    let words: [String]
    let work: Bool
    /// 区切りの長さ（秒）
    let seconds: TimeInterval
}

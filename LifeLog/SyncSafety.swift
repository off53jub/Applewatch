import Foundation

/// 版が違う端末どうしの同期の守り（2026-11-06）。
///
/// 端末どうしの同期では、会話ごとに番号の大きいほうを丸ごと残す。古い版のアプリは、新しい版で足した項目
/// （［場面］・書き換えの履歴など）を知らないので、古い版の端末が会話を書き直して送ると、その項目が抜けたまま
/// 「新しい版」として戻ってくる。そこで、送ってきた端末の版がその項目を知らないときだけ、手元の値で埋める。
enum SyncFill {
    /// 埋めてよい項目と、その項目を知っている最初のアプリの版（2026-11-06。見直しで、これ以外は埋めないことにした）。
    /// どれも「付けるだけで、消すことの無い」項目。消すことのある項目（放送の印・話者の番号・作り直しの印・票など）は、
    /// 向こうで消したのか知らないのか区別できないので、埋めない（埋めると本人の直しが戻ってしまう）。
    static let conversationFields = ["scene": 121]
    static let lineFields = ["history": 116, "rubbed": 116, "end": 130, "speakerDoubt": 130]

    /// 送ってきた端末の版（分からない＝版を送らない古いアプリなら 0）が、その項目を知らないときだけ、手元の値で埋める
    static func filledConversation(_ remote: ConversationLog.Conversation, keeping local: ConversationLog.Conversation,
                                   senderBuild: Int?) -> ConversationLog.Conversation {
        let sender = senderBuild ?? 0
        func unknown(_ intro: Int?) -> Bool { intro.map { sender < $0 } ?? false }
        var out = remote
        if unknown(conversationFields["scene"]), out.scene == nil { out.scene = local.scene }
        var byTime: [Date: ConversationLog.Line] = [:]
        for line in local.lines where byTime[line.time] == nil { byTime[line.time] = line }
        for i in out.lines.indices {
            guard let mine = byTime[out.lines[i].time] else { continue }
            if unknown(lineFields["history"]), out.lines[i].history == nil { out.lines[i].history = mine.history }
            if unknown(lineFields["rubbed"]), out.lines[i].rubbed == nil { out.lines[i].rubbed = mine.rubbed }
            if unknown(lineFields["end"]), out.lines[i].end == nil { out.lines[i].end = mine.end }
            if unknown(lineFields["speakerDoubt"]), out.lines[i].speakerDoubt == nil { out.lines[i].speakerDoubt = mine.speakerDoubt }
        }
        return out
    }
}

/// アプリの版（ビルドの番号）と、同期の相手の端末の版。
enum AppBuild {
    /// この端末のアプリのビルドの番号（GitHub の TestFlight のワークフローの番号。手元のビルドは 1）
    static var current: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    private static let peersKey = "syncPeerBuilds"

    /// 同期の相手の端末ごとの版（0 は、版を送ってこない古いアプリ）
    static var peers: [String: Int] {
        (UserDefaults.standard.dictionary(forKey: peersKey) as? [String: Int]) ?? [:]
    }

    static func note(device: String, build: Int?) {
        var all = peers
        guard all[device] != (build ?? 0) else { return }
        all[device] = build ?? 0
        UserDefaults.standard.set(all, forKey: peersKey)
    }

    /// この端末より古い版の相手（端末の番号と版）
    static func olderPeers(than mine: Int = current) -> [(device: String, build: Int)] {
        peers.filter { $0.value < mine }.map { (device: $0.key, build: $0.value) }.sorted { $0.device < $1.device }
    }
}

import Foundation
import UserNotifications

// s38（2026-11-28）アプリ担当 A2 の決まり。番号は母艦の docs/system-proposal-2026-11-13.md の「追記 30」（手7・手11・活2・活3）。
// 取り決め（足すだけ・省ける。家の PC の変更は要らない）:
// - 手7: 仕事のまとめの写真の代わりに、画面を下へ送りながら撮った動画 1 本を選べる。アプリが動画からコマを選び（一定の間隔・
//   前のコマとほとんど同じなら飛ばす。しきい値はどれも仮）、今の写真と同じ形で POST /work/photo に送る（30 枚まで）。
// - 手11: 時計のアプリが iPhone より古いとき、今日の「気をつけること」に 1 行（知らせにはしない）。出すまでの待ちを 24 時間→1 時間（仮）。
//   決まりは S25UWatchLag（S25URules.swift）。
// - 活2（K38-4）: 知らせを開いた数（ux の uxNotifOpened・tally の notice.opened.<種類>）の数え方を直す。ux の書き出しの形は変えない
//   （欄 uxNotifOpenedApp を足すだけ）。
// - 活3（K38-3）: 急ぎ以外の知らせを朝の 1 通にまとめる設定（初めはオン・設定で戻せる）。

// MARK: - 手7 動画からコマを選ぶ

enum S38AVideo {
    /// コマを取る間隔（秒・仮）
    static let interval: TimeInterval = 0.5
    /// 動画の長さの上限（秒・仮）。これより長い動画は、前のほうだけ見る
    static let maxSeconds: TimeInterval = 90
    /// 前のコマとほとんど同じとみなす: 縮めた絵で、これ以上違うマスが全体のこの割合に満たない（仮）
    static let minChangedFraction: Double = 0.04
    /// 1 マスが違うとみなす差（0〜255・仮）
    static let cellDelta: Int = 24
    /// 縮めた絵の一辺（マス）
    static let side = 48

    /// 一定の間隔で取る時刻（秒）。長さが分からない・0 以下なら空。候補は cap の 4 倍まで（多すぎれば間隔を広げる）
    static func sampleTimes(duration: TimeInterval, cap: Int, interval: TimeInterval = S38AVideo.interval) -> [TimeInterval] {
        guard duration.isFinite, duration > 0, cap > 0 else { return [] }
        let span: TimeInterval = min(duration, maxSeconds)
        let limit: Int = max(1, cap) * 4
        var step: TimeInterval = max(0.1, interval)
        if span / step + 1 > Double(limit) { step = span / Double(limit - 1) }
        var out: [TimeInterval] = []
        var t: TimeInterval = 0
        while t < span, out.count < limit {
            out.append((t * 100).rounded() / 100)
            t += step
        }
        return out
    }

    /// 縮めた白黒の絵（side × side の 0〜255）同士で、違うマスの割合
    static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) >= cellDelta { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// 前に残したコマと比べて残すか（初めの 1 コマは必ず残す）
    static func keep(previous: [UInt8]?, current: [UInt8]) -> Bool {
        guard let previous else { return true }
        return changedFraction(previous, current) >= minChangedFraction
    }

    /// 残したコマが cap より多いとき、前から後ろまで同じ間隔で cap 枚に減らす（順は変えない）。cap 以下ならそのまま
    static func thin<T>(_ items: [T], cap: Int) -> [T] {
        guard cap > 0 else { return [] }
        guard items.count > cap else { return items }
        if cap == 1 { return [items[0]] }
        var out: [T] = []
        for n in 0..<cap {
            let index = Int((Double(n) * Double(items.count - 1) / Double(cap - 1)).rounded())
            out.append(items[index])
        }
        return out
    }

    /// 選んだコマを減らす数（画面に 1 行出す）
    static func summaryLine(frames: Int, skipped: Int) -> String {
        if frames == 0 { return "動画からコマを取れませんでした。" }
        return skipped > 0 ? "動画から \(frames) コマを選びました（ほとんど同じ \(skipped) コマは飛ばしました）。"
            : "動画から \(frames) コマを選びました。"
    }
}

// MARK: - 活2 知らせを開いた数

enum S38AOpened {
    /// アプリを開いたとき、この分より前に届いた知らせは「そのために開いた」とは見ない（仮）
    static let appWindow: TimeInterval = 15 * 60
    /// tally に足す名前（ux の欄は uxNotifOpened のまま・足すのはこちら）
    static let appTally = "uxNotifOpenedApp"
    static let appKindPrefix = "notice.openedApp."
    private static let seenKey = "s38a.openedApp.seen"

    /// アプリを開いた時刻 now に、この知らせ（届いた時刻 delivered）を「見に来た」と数えるか。
    /// 押して開いたものは数えない（もう uxNotifOpened で数えてある）。届く前（未来）は数えない
    static func countsAsAppOpen(delivered: Date, now: Date, alreadyTapped: Bool) -> Bool {
        guard !alreadyTapped else { return false }
        let age = now.timeIntervalSince(delivered)
        return age >= 0 && age <= appWindow
    }

    /// 通知センターに残っている知らせから、アプリを開いたときに数えるもの（同じ知らせは 1 回だけ）。
    /// 返すのは (数える印, 種類)。seen は前に数えた印
    static func fresh(delivered: [(id: String, date: Date, kind: String)], now: Date, seen: [String],
                      tapped: Set<String>) -> [(key: String, kind: String)] {
        var out: [(key: String, kind: String)] = []
        var known: Set<String> = Set(seen)
        for d in delivered {
            let key: String = NoticeBundle.key(identifier: d.id, date: d.date)
            guard !known.contains(key) else { continue }
            guard countsAsAppOpen(delivered: d.date, now: now, alreadyTapped: tapped.contains(key)) else { continue }
            known.insert(key)
            out.append((key, d.kind))
        }
        return out
    }

    /// アプリが前に来たとき（NoticeGate.scanDelivered から）。押された知らせの印は S24Book.noteResponse が持つ
    static func noteAppOpen(delivered: [UNNotification], now: Date = .now) {
        let tapped: Set<String> = S24Book.tappedKeys()
        let rows: [(id: String, date: Date, kind: String)] = delivered.map { n in
            let r = n.request
            return (r.identifier, n.date, S24Book.openedKind(identifier: r.identifier, category: r.content.categoryIdentifier,
                                                              userInfo: r.content.userInfo))
        }
        var seen: [String] = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
        let fresh = Self.fresh(delivered: rows, now: now, seen: seen, tapped: tapped)
        guard !fresh.isEmpty else { return }
        for item in fresh {
            Tally.add(appTally)
            Tally.add(appKindPrefix + item.kind)
            seen.append(item.key)
        }
        UserDefaults.standard.set(Array(seen.suffix(300)), forKey: seenKey)
    }
}

// MARK: - 活3 急ぎ以外を朝の 1 通に

enum S38AMorning {
    /// 設定（初めはオン）
    static let key = "s38a.morningOne"
    static var isOn: Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }

    /// 朝の 1 通の時刻（0 時からの分。今の朝の便りと同じ 7:30・仮）
    static var minutes: Int { NoticeDigestRules.morningMinutes }

    /// 朝の 1 通にまとめるか。急ぎは今までどおりすぐ出す:
    /// 録音・期限・家の PC からの急ぎ（時計が録音していない・電池・時計が黙っている など）と、ボタンのある知らせ・今の便り自身
    static func holds(identifier: String, category: String, userInfo: [AnyHashable: Any], immediate: Bool, on: Bool) -> Bool {
        guard on, immediate else { return false }
        if NoticeDigestRules.isUrgent(identifier: identifier, category: category) { return false }
        let lane = S24NoticeRules.lane(identifier: identifier, category: category, userInfo: userInfo)
        return !S24NoticeRules.isPriority(lane)
    }

    /// 次の朝の 1 通の時刻（now より後のいちばん近い朝）
    static func nextSlot(after now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        let today = start.addingTimeInterval(Double(minutes) * 60)
        return today > now ? today : start.addingTimeInterval(86400 + Double(minutes) * 60)
    }

    /// いちばん近い過ぎた朝の時刻（これより後にためたものが、次の 1 通に入る）
    static func previousSlot(before now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        let today = start.addingTimeInterval(Double(minutes) * 60)
        return today <= now ? today : start.addingTimeInterval(-86400 + Double(minutes) * 60)
    }
}

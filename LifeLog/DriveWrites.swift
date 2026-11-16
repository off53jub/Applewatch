import CryptoKit
import Foundation
import UIKit

// ドライブへの書き込みを減らす（2026-11-16。強化案 83）。
//
// 11/15 に iPhone で「Quota exceeded for quota metric 'Quota group for write operations'」（429）、
// 頼まれごと帳の「cancelled」が 50 分に 5 回、わかったこと帳の「The network connection was lost」、
// 「ドキュメントの名前を直せませんでした」が出ていた。
// - 頼まれごと帳・わかったこと帳・仕事のまとめは、区切りを処理するたびに（裏で起こされた処理の中で）書こうとしていた。
//   処理が iOS に止められると書き込みも cancelled になり、写し済みの印が付かないので、次の処理でまた書こうとして、また止められていた。
// - わかったこと帳は、答える・直すたびにすぐ書いていた（続けて答えると、その数だけ書く）。
// - 話者の名前を直すと、その人が出てくる日の数だけ続けて書く（429 の 【仮説】の出どころ）。
// そこで、(1) 中身が前に書いたものと同じなら書かない、(2) 帳の書き込みは 150 秒まとめてから、処理の外で書く
// （アプリが裏に回るときには待たずに書く）、(3) 429 を受けたら、しばらく書き込みを止める（Retry-After があればその秒数）、
// (4) cancelled・通信が切れたは、エラーにせず「あとでやり直す」にする。数は Tally の drive.* で数える。

/// ドライブへの書き込みが失敗したときの扱い
enum DriveRetry {
    enum Kind: Equatable {
        /// iOS に止められた・通信が切れた。エラーにせず、あとでやり直す
        case retryLater
        /// 書き込みの上限（429）。しばらく止めてから、やり直す
        case rateLimited
        /// それ以外（いままでどおり、診断に出す）
        case error
    }

    static func kind(_ error: Error) -> Kind {
        if error.isCancellation { return .retryLater }
        if let google = error as? GoogleError {
            switch google {
            case .backoff: return .rateLimited
            case .http(let code, let body) where isRateLimited(code, body): return .rateLimited
            default: return .error
            }
        }
        let codes: Set<Int> = [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
                               NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
        if let url = error as? URLError, codes.contains(url.code.rawValue) { return .retryLater }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, codes.contains(ns.code) { return .retryLater }
        return .error
    }

    /// Google の「書き込みが多すぎる」の答え（429。古い API は 403 の rateLimitExceeded）
    static func isRateLimited(_ status: Int, _ body: String) -> Bool {
        if status == 429 { return true }
        return status == 403 && (body.contains("rateLimitExceeded") || body.contains("userRateLimitExceeded"))
    }

    /// Retry-After（秒の数か、HTTP の日付）を、今から待つ秒に。読めなければ nil
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text) { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// 429 を受けたあと、書き込みを止めておく時間（端末の中だけ。同期しない）
struct DriveBackoff: Codable, Equatable {
    /// この時刻まで書き込まない
    var until: Date?
    /// 続けて 429 を受けた回数（待つ時間を倍にしていく）
    var strikes: Int = 0

    static let base: TimeInterval = 60
    static let cap: TimeInterval = 30 * 60
    /// Retry-After がこれより長くても、ここまでにする
    static let longestRetryAfter: TimeInterval = 60 * 60

    func blocked(at now: Date) -> Bool { (until ?? .distantPast) > now }

    /// あと何秒止めるか（止めていなければ 0）
    func remaining(at now: Date) -> TimeInterval { max(0, (until ?? now).timeIntervalSince(now)) }

    /// 429 を受けた。Retry-After があればその秒数、無ければ 60 秒から倍にしていく（30 分まで）
    mutating func rateLimited(retryAfter: TimeInterval?, at now: Date) {
        strikes += 1
        let wait: TimeInterval
        if let retryAfter {
            wait = min(max(retryAfter, 1), Self.longestRetryAfter)
        } else {
            wait = min(Self.base * pow(2, Double(min(strikes, 16) - 1)), Self.cap)
        }
        until = max(until ?? now, now.addingTimeInterval(wait))
    }

    /// 書き込みが通った（止めるのをやめ、倍にしていたのも戻す）
    mutating func succeeded() {
        strikes = 0
        until = nil
    }
}

/// 前に書いた中身の印（SHA-256）。同じなら書かない
enum DriveStamp {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// ドキュメントの段落（文字と見出しの種類）の印
    static func digest(_ paragraphs: [(text: String, style: String?)]) -> String {
        var data = Data()
        for p in paragraphs {
            data.append(Data((p.style ?? "").utf8))
            data.append(0x1F)
            data.append(Data(p.text.utf8))
            data.append(0x1E)
        }
        return digest(data)
    }
}

/// 帳（頼まれごと帳・わかったこと帳・仕事のまとめ）の書き込みを、delay 秒まとめてから1回にする。
/// 中身は書くときに作り直すので、待っているあいだに何度変わっても、書くのは最後の中身の1回だけ。
/// アプリが裏に回るときは flush で待たずに書く。書けなかった（あとでやり直す）ものは、もう一度待ってから書く。
@MainActor
final class DriveWriteCoalescer {
    static let delay: TimeInterval = 150
    /// あとでやり直すときに待つ時間（429 で止めていれば、止め終わるまで）
    static let retryDelay: TimeInterval = 300

    /// 書く仕事。書けたか、やり直さなくてよいなら true。あとでやり直すなら false
    typealias Job = @MainActor () async -> Bool

    private var jobs: [String: Job] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    /// 待っている書き込みの数（診断用）
    var waiting: Int { jobs.count }

    func schedule(_ key: String, after delay: TimeInterval = DriveWriteCoalescer.delay, _ job: @escaping Job) {
        jobs[key] = job
        guard timers[key] == nil else {
            // もう待っている。中身は書くときに作るので、1回にまとめる
            Tally.add("drive.coalesced")
            return
        }
        timers[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.run(key)
        }
    }

    /// 待っている分を、待たずに全部書く（アプリが裏に回ったとき）
    func flush() async {
        for key in jobs.keys.sorted() {
            timers[key]?.cancel()
            timers[key] = nil
            await run(key)
        }
    }

    private func run(_ key: String) async {
        timers[key] = nil
        guard let job = jobs.removeValue(forKey: key) else { return }
        let done = await job()
        // 書いているあいだに新しく頼まれていれば、そちらが最後の中身で書くので、やり直さない
        guard !done, jobs[key] == nil else { return }
        Tally.add("drive.retryLater")
        schedule(key, after: max(Self.retryDelay, GoogleDocs.backoffRemaining), job)
    }
}

extension Pipeline {
    /// アプリが裏に回ったときに、待っている帳の書き込みを書く（裏で使える時間をもらって）
    func flushDriveWrites() {
        guard driveWrites.waiting > 0 else { return }
        let time = BackgroundTime("driveWrites")
        Task {
            await driveWrites.flush()
            time.end()
        }
    }

    /// 帳の書き込みが失敗したときに、診断に出すかを決める。あとでやり直すなら false を返す（Job の戻り値）
    func driveWriteFailed(_ error: Error, what: String) -> Bool {
        switch DriveRetry.kind(error) {
        case .retryLater, .rateLimited:
            return false
        case .error:
            diagnostics.problem("\(what)をドライブに書けませんでした: \(error.localizedDescription)")
            return true
        }
    }
}

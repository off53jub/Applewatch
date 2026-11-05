import Foundation
import MetricKit

/// アプリが落ちた・固まった記録（2026-11-06）。iOS の MetricKit が、前の日の分をまとめて渡してくる（たいてい1日1回）。
/// 落ちた・固まった・ディスクに書きすぎた・CPU を使いすぎた の数と時刻を、30件まで UserDefaults に残し、自己点検に出す。
final class CrashWatch: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashWatch()

    struct Event: Codable {
        let at: Date
        /// 「落ちた」「固まった」など
        let kind: String
        /// 落ちた理由の短い説明（例外の種類やシグナル）
        let detail: String
    }

    private static let key = "crashEvents"

    func start() { MXMetricManager.shared.add(self) }

    static var events: [Event] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }

    private static func append(_ new: [Event]) {
        guard !new.isEmpty else { return }
        let all = Array((events + new).suffix(30))
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var found: [Event] = []
        for payload in payloads {
            let at = payload.timeStampEnd
            for crash in payload.crashDiagnostics ?? [] {
                let parts = [crash.exceptionType.map { "例外 \($0)" }, crash.signal.map { "シグナル \($0)" },
                             crash.terminationReason].compactMap { $0 }
                found.append(Event(at: at, kind: "落ちた", detail: parts.joined(separator: "・")))
            }
            for hang in payload.hangDiagnostics ?? [] {
                found.append(Event(at: at, kind: "固まった",
                                   detail: "\(Int(hang.hangDuration.converted(to: .seconds).value))秒"))
            }
            for _ in payload.diskWriteExceptionDiagnostics ?? [] {
                found.append(Event(at: at, kind: "書き込みが多すぎた", detail: ""))
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                found.append(Event(at: at, kind: "CPU を使いすぎた",
                                   detail: "\(Int(cpu.totalCPUTime.converted(to: .seconds).value))秒"))
            }
        }
        Self.append(found)
    }

    /// 自己点検に出す一文（直近7日）
    static func summary(now: Date = .now) -> (text: String, ok: Bool) {
        let recent = events.filter { now.timeIntervalSince($0.at) < 7 * 24 * 3600 }
        guard !recent.isEmpty else { return ("直近7日はなし", true) }
        let grouped = Dictionary(grouping: recent, by: \.kind).map { "\($0.key) \($0.value.count) 回" }.sorted()
        let last = recent.max { $0.at < $1.at }
        return (grouped.joined(separator: "・") + (last.map { "（最後は \($0.at.formatted(date: .abbreviated, time: .shortened))" + ($0.detail.isEmpty ? "" : "・" + $0.detail) + "）" } ?? ""), false)
    }
}

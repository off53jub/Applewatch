import Photos
import XCTest
@testable import LifeLog

/// 2026-11-07 の実機の点検（TestFlight ビルド 162）で見つけた所の直しと、時計の電池で区切りを変える・会話の横の写真を確かめる。
/// B1 区切りの時刻（時計と iPhone を分ける） / B2 時計に LifeLog が入っているか / B3 ドキュメントの書き直しの範囲 /
/// B4 処理の時間の内訳 / D 電池が少ないときは5分に / E 写真を探す時間
@MainActor
final class FixesTests: XCTestCase {
    /// 2026-11-07T02:20:54Z（11:20:54 日本時間）
    private let now = Date(timeIntervalSince1970: 1_794_018_054)

    // MARK: - B1 区切りの時刻

    func testLastChunkSplitsWatchAndPhone() {
        let watchReceived = now.addingTimeInterval(-13.8 * 3600)
        let phoneEnd = now.addingTimeInterval(-600)
        let chunks = [
            RecordingLedger.Chunk(name: "20261106-211324-w.m4a", start: watchReceived.addingTimeInterval(-1300),
                                  source: "watch", received: watchReceived),
            RecordingLedger.Chunk(name: "20261107-110500.m4a", start: phoneEnd.addingTimeInterval(-120),
                                  end: phoneEnd, source: "phone"),
            // 取り込んだ音声は数えない
            RecordingLedger.Chunk(name: "20261107-111500-i.m4a", start: now.addingTimeInterval(-60), source: "import",
                                  received: now),
        ]
        XCTAssertEqual(PCDiag.lastChunk(chunks, pending: []), phoneEnd)
        XCTAssertEqual(PCDiag.lastChunk(chunks, pending: [], watch: true), watchReceived)
        XCTAssertEqual(PCDiag.lastChunk(chunks, pending: [], watch: false), phoneEnd)
    }

    func testLastChunkCountsPendingFiles() {
        let written = now.addingTimeInterval(-30)
        let pending: [(name: String, modified: Date?)] = [
            (name: "20261107-111900-w.m4a", modified: written),
            (name: "20261107-112000-i.m4a", modified: now),
            (name: "20261107-111800.m4a", modified: nil),
        ]
        XCTAssertEqual(PCDiag.lastChunk([], pending: pending, watch: true), written)
        XCTAssertNil(PCDiag.lastChunk([], pending: pending, watch: false))
        XCTAssertEqual(PCDiag.lastChunk([], pending: pending), written)
        XCTAssertNil(PCDiag.lastChunk([], pending: []))
    }

    // MARK: - B2 時計に LifeLog が入っているか

    func testWatchInstalledWhenHeardRecently() {
        XCTAssertTrue(WatchPresence.installed(flag: true, lastHeard: nil, now: now))
        XCTAssertTrue(WatchPresence.installed(flag: false, lastHeard: now.addingTimeInterval(-240), now: now))
        XCTAssertFalse(WatchPresence.installed(flag: false, lastHeard: now.addingTimeInterval(-3 * 86400), now: now))
        XCTAssertFalse(WatchPresence.installed(flag: false, lastHeard: nil, now: now))
    }

    func testWatchStatusText() {
        let heard = now.addingTimeInterval(-240)
        // 実機の点検と同じ: 入っていないと言われるが、4分前に便りがある
        let text = WatchPresence.text(supported: true, activated: true, paired: true, installedFlag: false,
                                      reachable: false, lastHeard: heard, now: now)
        XCTAssertTrue(text.hasPrefix("時計に LifeLog が入っています"))
        XCTAssertTrue(text.contains("最後の便り"))
        XCTAssertEqual(WatchPresence.text(supported: true, activated: true, paired: true, installedFlag: false,
                                          reachable: false, lastHeard: nil, now: now), "時計に LifeLog が入っていません")
        XCTAssertEqual(WatchPresence.text(supported: true, activated: true, paired: true, installedFlag: true,
                                          reachable: true, lastHeard: nil, now: now), "時計のアプリとつながっています")
        XCTAssertEqual(WatchPresence.text(supported: true, activated: true, paired: true, installedFlag: true,
                                          reachable: false, lastHeard: heard, now: now), "時計に LifeLog が入っています")
        XCTAssertEqual(WatchPresence.text(supported: true, activated: false, paired: true, installedFlag: true,
                                          reachable: false, lastHeard: heard, now: now), "接続を準備中")
        XCTAssertEqual(WatchPresence.text(supported: true, activated: true, paired: false, installedFlag: false,
                                          reachable: false, lastHeard: nil, now: now), "Apple Watch がペアリングされていません")
    }

    // MARK: - B3 ドキュメントの書き直しの範囲

    private func range(_ request: [String: Any], _ key: String) -> (start: Int, end: Int)? {
        guard let body = request[key] as? [String: Any], let range = body["range"] as? [String: Any],
              let start = range["startIndex"] as? Int, let end = range["endIndex"] as? Int else { return nil }
        return (start, end)
    }

    func testOverwriteDeletesUpToLastNewline() {
        let paragraphs: [(text: String, style: String?)] = [("見出し", "HEADING_1"), ("本文", nil)]
        let requests = GoogleDocs.overwriteRequests(paragraphs, segmentEnd: 4403)
        // 最後の改行（4402 の位置）は消せないので、消すのは 1〜4402 の手前まで
        let delete = range(requests[0], "deleteContentRange")
        XCTAssertEqual(delete?.start, 1)
        XCTAssertEqual(delete?.end, 4402)
        let insert = requests[1]["insertText"] as? [String: Any]
        XCTAssertEqual(insert?["text"] as? String, "見出し\n本文\n")
        XCTAssertEqual((insert?["location"] as? [String: Any])?["index"] as? Int, 1)
        // 全体を普通の文字に戻してから、見出しだけ見出しにする
        XCTAssertEqual(range(requests[2], "updateParagraphStyle")?.end, 1 + "見出し\n本文\n".utf16.count)
        XCTAssertEqual(range(requests[3], "updateParagraphStyle")?.start, 1)
        XCTAssertEqual(range(requests[3], "updateParagraphStyle")?.end, 1 + "見出し\n".utf16.count)
        XCTAssertEqual(requests.count, 4)
    }

    func testOverwriteOfEmptyDocumentDoesNotDelete() {
        // 空のドキュメントは改行1つだけ（本文の終わりは 2）。消すものは無い
        let requests = GoogleDocs.overwriteRequests([("一行", nil)], segmentEnd: 2)
        XCTAssertNil(requests.first?["deleteContentRange"])
        XCTAssertNotNil(requests.first?["insertText"])
        // 中身が空なら消すだけ（空の文字を差し込まない）
        let cleared = GoogleDocs.overwriteRequests([], segmentEnd: 50)
        XCTAssertEqual(cleared.count, 1)
        XCTAssertEqual(range(cleared[0], "deleteContentRange")?.end, 49)
    }

    func testStaleRangeErrorIsRecognized() {
        let body = #"{"error": {"code": 400, "message": "Invalid requests[0].deleteContentRange: Index 4402 must be less than the end index of the referenced segment, 2266.", "status": "INVALID_ARGUMENT"}}"#
        XCTAssertTrue(GoogleDocs.isStaleRange(body))
        XCTAssertFalse(GoogleDocs.isStaleRange(#"{"error": {"code": 400, "message": "Invalid JSON payload"}}"#))
    }

    // MARK: - B4 処理の時間の内訳

    func testRunWorkingExcludesWaitAndBackground() {
        var run = DiagnosticsLog.Run(start: now, seconds: 1968)
        XCTAssertEqual(run.working, 1968)  // 前の記録（内訳なし）は全部
        XCTAssertFalse(run.wasInBackground)
        run.waited = 240
        run.background = 1700
        XCTAssertEqual(run.working, 28, accuracy: 0.001)
        XCTAssertTrue(run.wasInBackground)
        run.background = 5000  // 重なって数えても、負にはしない
        XCTAssertEqual(run.working, 0)
    }

    func testRunSummarySeparatesWaits() {
        var long = DiagnosticsLog.Run(start: now.addingTimeInterval(-3600), seconds: 1968)
        long.background = 1960
        var waited = DiagnosticsLog.Run(start: now.addingTimeInterval(-1800), seconds: 130)
        waited.waited = 120
        let quick = DiagnosticsLog.Run(start: now.addingTimeInterval(-600), seconds: 0.5)
        let old = DiagnosticsLog.Run(start: now.addingTimeInterval(-2 * 86400), seconds: 900)
        let summary = RunStats.summary([old, long, waited, quick], now: now)
        XCTAssertEqual(summary?.value, "3 回・ふつう 8.0 秒・いちばん長い 10 秒")
        XCTAssertEqual(summary?.ok, true)
        XCTAssertTrue(summary?.detail?.contains("家の PC を待った 1 回") == true)
        XCTAssertTrue(summary?.detail?.contains("裏にいた 1 回") == true)
        XCTAssertNil(RunStats.summary([old], now: now))
        var expired = DiagnosticsLog.Run(start: now.addingTimeInterval(-60), seconds: 40)
        expired.expired = true
        XCTAssertTrue(RunStats.summary([expired], now: now)?.detail?.contains("時間が切れた 1 回") == true)
        XCTAssertEqual(RunStats.summary([expired], now: now)?.ok, false)
    }

    // MARK: - D 電池が少ないときは5分に

    func testBatterySaverThresholds() {
        XCTAssertFalse(ChunkCutter.shouldSave(on: true, battery: 0.31, charging: false, lowPower: false, wasSaving: false))
        XCTAssertTrue(ChunkCutter.shouldSave(on: true, battery: 0.29, charging: false, lowPower: false, wasSaving: false))
        // 戻すのは 35% まで戻ってから（30% のあたりで行ったり来たりしない）
        XCTAssertTrue(ChunkCutter.shouldSave(on: true, battery: 0.32, charging: false, lowPower: false, wasSaving: true))
        XCTAssertFalse(ChunkCutter.shouldSave(on: true, battery: 0.35, charging: false, lowPower: false, wasSaving: true))
        // 低電力モードなら電池が多くても5分。充電を始めたら短めに戻す
        XCTAssertTrue(ChunkCutter.shouldSave(on: true, battery: 0.8, charging: false, lowPower: true, wasSaving: false))
        XCTAssertFalse(ChunkCutter.shouldSave(on: true, battery: 0.1, charging: true, lowPower: false, wasSaving: true))
        // 設定がオフなら変えない。電池が分からなければ今のまま
        XCTAssertFalse(ChunkCutter.shouldSave(on: false, battery: 0.1, charging: false, lowPower: true, wasSaving: true))
        XCTAssertTrue(ChunkCutter.shouldSave(on: true, battery: nil, charging: nil, lowPower: nil, wasSaving: true))
        XCTAssertFalse(ChunkCutter.shouldSave(on: true, battery: nil, charging: nil, lowPower: nil, wasSaving: false))
    }

    func testBatterySaverReplayAndEffectiveLength() {
        let falling: [(battery: Double?, charging: Bool?, lowPower: Bool?)] = [(0.5, false, false), (0.29, false, false), (0.33, false, false)]
        XCTAssertTrue(ChunkCutter.replaySaving(falling, on: true))
        XCTAssertFalse(ChunkCutter.replaySaving(falling + [(0.36, false, false)], on: true))
        XCTAssertFalse(ChunkCutter.replaySaving(falling, on: false))
        XCTAssertEqual(ChunkCutter.effective(.short, saving: true), .normal)
        XCTAssertEqual(ChunkCutter.effective(.short, saving: false), .short)
        XCTAssertEqual(ChunkCutter.effective(.normal, saving: false), .normal)
    }

    func testBatterySaverSettingTravelsToWatch() {
        let defaults = UserDefaults.standard
        let savedLength = defaults.object(forKey: ChunkCutter.lengthKey)
        let savedSaver = defaults.object(forKey: ChunkCutter.batterySaverKey)
        defer {
            defaults.set(savedLength, forKey: ChunkCutter.lengthKey)
            defaults.set(savedSaver, forKey: ChunkCutter.batterySaverKey)
        }
        defaults.removeObject(forKey: ChunkCutter.batterySaverKey)
        XCTAssertTrue(ChunkCutter.batterySaverOn)  // 初めはオン
        ChunkCutter.length = .short
        ChunkCutter.batterySaverOn = false
        var context: [String: Any] = [:]
        ChunkCutter.addSettings(to: &context)
        XCTAssertEqual(context[ChunkCutter.lengthKey] as? String, "short")
        XCTAssertEqual(context[ChunkCutter.batterySaverKey] as? Bool, false)
        ChunkCutter.readSettings([ChunkCutter.lengthKey: "normal", ChunkCutter.batterySaverKey: true])
        XCTAssertEqual(ChunkCutter.length, .normal)
        XCTAssertTrue(ChunkCutter.batterySaverOn)
    }

    func testWatchChunkLengthText() {
        func state(_ minutes: Double, _ battery: Double, lowPower: Bool = false) -> RecordingLedger.State {
            var s = RecordingLedger.State(at: now.addingTimeInterval(minutes * 60), recording: true, resting: false)
            s.battery = battery
            s.charging = false
            s.lowPower = lowPower
            return s
        }
        let low = [state(-60, 0.4), state(-10, 0.25)]
        XCTAssertEqual(Pipeline.watchChunkLengthText(length: .short, saverOn: true, states: low),
                       "電池が少ないので、自動で5分にしています（電池 25%）")
        XCTAssertEqual(Pipeline.watchChunkLengthText(length: .short, saverOn: true, states: [state(-10, 0.8)]),
                       "短め（2分まで）・電池が少ないときは5分に")
        XCTAssertEqual(Pipeline.watchChunkLengthText(length: .short, saverOn: false, states: low), "短め（2分まで）")
        XCTAssertEqual(Pipeline.watchChunkLengthText(length: .normal, saverOn: true, states: low), "ふつう（5分まで）")
    }

    // MARK: - E 写真を探す時間

    func testPhotoWindowAddsFiveMinutes() {
        let start = now
        let end = now.addingTimeInterval(1200)
        let window = DayPhotos.window(start: start, end: end)
        XCTAssertEqual(window.lowerBound, start.addingTimeInterval(-300))
        XCTAssertEqual(window.upperBound, end.addingTimeInterval(300))
        // 終わりが始まりより前の壊れた会話でも、範囲は作れる
        let odd = DayPhotos.window(start: start, end: start.addingTimeInterval(-60))
        XCTAssertEqual(odd.upperBound, start.addingTimeInterval(300))
        let windows = DayPhotos.windows([(start: start, end: end), (start: end, end: end.addingTimeInterval(60))])
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[end]?.upperBound, end.addingTimeInterval(360))
        XCTAssertTrue(DayPhotos.allowed(.authorized))
        XCTAssertTrue(DayPhotos.allowed(.limited))
        XCTAssertFalse(DayPhotos.allowed(.denied))
        XCTAssertFalse(DayPhotos.allowed(.notDetermined))
    }
}

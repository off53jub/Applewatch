import AVFoundation
import CoreMotion
import CoreSpotlight
import EventKit
import Foundation
import MediaPlayer
import Observation
import Photos
import ShazamKit
import UIKit
import UniformTypeIdentifiers
import Vision

// s26（2026-11-25）の A1 の動き。決まりは S26ARules.swift、画面は S26AViews.swift、ショートカットは S26AIntents.swift。
// 番号は母艦の docs/system-proposal-2026-11-13.md の「追記 16」。しきい値はどれも仮。
// - 集1・集2・集3（K1）: 体重と体の記録・せきといびきの数を、ヘルスケアの書き出し（HealthExport.swift）に足す
// - K2 端末の合図: 充電・朝に最初に使った時刻・集中モード・階・食事の写真・名刺・聴いた曲・流れていた曲・アプリの使用時間を
//   1 日 1 ファイル（lifelog-signals-YYYY-MM-DD.json）でヘルスケアと同じフォルダに書く。M1 が取り込む
// - 聞10: 端末の中の音声認識（SpeechAnalyzer）を、答え合わせの答えで測るだけ（切り替えない）
// - 聞12: 人のページの名前・別名と予定の相手から、名前の読みの辞書を作り、聞き取りのヒントと直しに使う
// - 聞16: 会議・面談の予定のあいだだけ「精度優先」にし、終わったら戻す（初めはオフ）
// - 軽7: iPhone の検索（Spotlight）に人・日・会話・場所を載せる
// - 結3: 「実績」のカレンダーに、会った人といた所を書く（初めはオフ）
// - 結5: 小さい区切りは、アプリが動いているあいだはすぐ家の PC に送る
// 問い・知らせは足さない（減13）。中身の文は記録（ログ）に書かない。

/// 設定（初めのオン・オフは、外へ書く・電池・お金がかかるものはオフ、データを取って残すだけはオン）
@MainActor
enum S26ASettings {
    static let songsHeardKey = "s26a.songsHeard"      // 集4 初めはオフ（ShazamKit の App Service が要る）
    static let songsPlayedKey = "s26a.songsPlayed"    // 集5 初めはオフ（ミュージックの許可が要る）
    static let bodySoundsKey = "s26a.bodySounds"      // 集3 初めはオン
    static let deviceSignalsKey = "s26a.deviceSignals" // 集12 初めはオン
    static let floorsKey = "s26a.floors"              // 集13 初めはオン
    static let mealsKey = "s26a.meals"                // 集10 初めはオン
    static let cardsKey = "s26a.cards"                // 集16 初めはオン
    static let meetingAutoKey = "s26a.meetingAuto"    // 聞16 初めはオフ
    static let actualKey = "s26a.actualCalendar"      // 結3 初めはオフ
    static let spotlightKey = "s26a.spotlight"        // 軽7 初めはオン
    static let fastSendKey = "s26a.fastSend"          // 結5 初めはオン
    static let nameDictKey = "s26a.nameDict"          // 聞12 初めはオン
    static let benchKey = "s26a.bench"                // 聞10 初めはオン（充電中だけ）

    static func on(_ key: String) -> Bool {
        if let v = UserDefaults.standard.object(forKey: key) as? Bool { return v }
        return defaultOn(key)
    }

    static func defaultOn(_ key: String) -> Bool {
        ![songsHeardKey, songsPlayedKey, meetingAutoKey, actualKey].contains(key)
    }

    static var charging: Bool { [.charging, .full].contains(UIDevice.current.batteryState) }
}

// MARK: - 動かす

@MainActor
final class S26ABook {
    static let shared = S26ABook()
    static var pipeline: Pipeline?
    private static var timer: Timer?
    private static var observers: [NSObjectProtocol] = []

    private var ranAt: [String: Date] = [:]
    private var busy: Set<String> = []

    /// LifeLogApp の起動で 1 回だけ呼ぶ。live でなければ（テスト・画面の自動確認）動かさない
    static func install(_ pipeline: Pipeline, live: Bool) {
        self.pipeline = pipeline
        guard live, timer == nil else { return }
        S26ASignalsStore.shared.markFirstDay()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in S26ABook.shared.batteryChanged() }
        })
        // ロックを外した（アプリが裏で動いているときに届く）・アプリを開いた
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in S26ABook.shared.used() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in S26ABook.shared.tick() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            S26ABook.shared.tick()
        }
    }

    func batteryChanged(now: Date = .now) {
        guard S26ASettings.on(S26ASettings.deviceSignalsKey) else { return }
        switch UIDevice.current.batteryState {
        case .charging, .full: S26ASignalsStore.shared.addCharge("plugged", at: now)
        case .unplugged: S26ASignalsStore.shared.addCharge("unplugged", at: now)
        default: break
        }
    }

    func used(now: Date = .now) {
        guard S26ASettings.on(S26ASettings.deviceSignalsKey) else { return }
        S26ASignalsStore.shared.noteUse(at: now)
    }

    /// every 秒より前に動かしていなければ true（動かした時刻を覚える）
    private func due(_ job: String, every: TimeInterval, now: Date) -> Bool {
        if let at = ranAt[job], now.timeIntervalSince(at) < every { return false }
        ranAt[job] = now
        return true
    }

    /// 重なって動かさない
    private func run(_ job: String, _ work: @escaping @MainActor () async -> Void) {
        guard !busy.contains(job) else { return }
        busy.insert(job)
        Task { @MainActor in
            await work()
            busy.remove(job)
        }
    }

    /// 1 分ごと
    func tick(now: Date = .now) {
        guard let p = Self.pipeline else { return }
        S26AMusic.poll(now: now)
        S26AAltimeter.shared.update()
        S26AMeetingAuto.tick(p, now: now)
        if due("names", every: 6 * 3600, now: now) { S26ANameDict.shared.rebuild(p, now: now) }
        let active = UIApplication.shared.applicationState == .active
        if (active || S26ASettings.charging), due("photos", every: 30 * 60, now: now) {
            run("photos") { await S26APhotoScan.shared.scan(now: now) }
        }
        if due("signalsExport", every: 3600, now: now) {
            run("signalsExport") { await S26ASignalsStore.shared.exportIfDue(p, now: now) }
        }
        if due("actual", every: 3600, now: now) {
            run("actual") { await S26AActualCalendar.writeIfDue(p, now: now) }
        }
        if due("spotlight", every: 6 * 3600, now: now) {
            run("spotlight") { await S26ASpotlight.refresh(p, now: now) }
        }
        if S26ASettings.charging, due("bench", every: 3600, now: now) {
            run("bench") { await S26ABench.shared.runIfDue(p, now: now) }
        }
    }
}

// MARK: - K2 端末の合図の帳

@MainActor
@Observable
final class S26ASignalsStore {
    static let shared = S26ASignalsStore()
    /// 端末の中に残す日数
    static let keepDays = 21
    static let firstDayKey = "s26a.signals.firstDay"
    static let doneKey = "s26a.signals.done"
    private static let openAppsKey = "s26a.signals.openApps"

    private(set) var days: [String: S26ADaySignals] = [:]
    private static let url = URL.applicationSupportDirectory.appendingPathComponent("s26a-signals.json")

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([String: S26ADaySignals].self, from: data) {
            days = saved
        }
    }

    /// 書き出しの 1 日目（この版を初めて開いた日。前の日の分はさかのぼらない）
    func markFirstDay(now: Date = .now) {
        guard UserDefaults.standard.string(forKey: Self.firstDayKey) == nil else { return }
        UserDefaults.standard.set(HealthExport.dayKey(now), forKey: Self.firstDayKey)
    }

    func today(now: Date = .now) -> S26ADaySignals { days[HealthExport.dayKey(now)] ?? S26ADaySignals() }

    private func change(_ at: Date, _ edit: (inout S26ADaySignals) -> Void) {
        let key = HealthExport.dayKey(at)
        var day = days[key] ?? S26ADaySignals()
        let before = day
        edit(&day)
        guard day != before else { return }
        days[key] = day
        save()
    }

    private func save() {
        let oldest = HealthExport.dayKey(Date.now.addingTimeInterval(-Double(Self.keepDays) * 86400))
        days = days.filter { $0.key >= oldest }
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    func addCharge(_ state: String, at: Date) {
        change(at) { $0.charge = S26ASignals.addingCharge($0.charge, state: state, at: at) }
    }

    func noteUse(at: Date) {
        change(at) { $0.firstUse = S26ASignals.firstUse(current: $0.firstUse, candidate: at) }
    }

    func addSong(_ song: S26ASong) {
        change(song.at) { $0.songs = S26ASignals.addingSong($0.songs, song) }
        Tally.add("s26a.song." + song.source)
    }

    func addFocus(name: String?, on: Bool, at: Date) {
        let n = name.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) }.flatMap { $0.isEmpty ? nil : $0 }
        change(at) { $0.focus = S26ASignals.addingFocus($0.focus, S26AFocus(at: at, name: n, on: on)) }
    }

    func addFloor(_ delta: Int, at: Date) {
        guard delta != 0 else { return }
        change(at) { $0.floors.append(S26AFloor(at: at, delta: delta)) }
        Tally.add("s26a.floor")
    }

    func addMeal(_ meal: S26AMeal) {
        change(meal.at) { $0.meals = S26ASignals.addingMeal($0.meals, meal) }
    }

    func addCard(_ card: S26ACard) {
        change(card.at) { $0.cards = S26ASignals.addingCard($0.cards, card) }
        Tally.add("s26a.card")
    }

    func addScreen(app: String, minutes: Double, replace: Bool, at: Date = .now) {
        change(at) { $0.screenTime = S26ASignals.addingScreen($0.screenTime, app: app, minutes: minutes, replace: replace) }
    }

    /// 「アプリを開いた記録」（AppUsage.swift）から。開いてから閉じるまでを使用時間に、集中モードは合図に
    func appUsage(app: String, event: String, at: Date = .now) {
        switch event {
        case "focus_on", "focus_off":
            guard S26ASettings.on(S26ASettings.deviceSignalsKey) else { return }
            addFocus(name: app, on: event == "focus_on", at: at)
        case "open":
            var open = UserDefaults.standard.dictionary(forKey: Self.openAppsKey) as? [String: Double] ?? [:]
            open[app] = at.timeIntervalSince1970
            UserDefaults.standard.set(open, forKey: Self.openAppsKey)
        case "close":
            var open = UserDefaults.standard.dictionary(forKey: Self.openAppsKey) as? [String: Double] ?? [:]
            let opened = open.removeValue(forKey: app).map { Date(timeIntervalSince1970: $0) }
            UserDefaults.standard.set(open, forKey: Self.openAppsKey)
            // 日をまたいだら、閉じた日に入れる（仮）
            if let minutes = S26ASignals.openMinutes(opened: opened, closed: at) {
                addScreen(app: app, minutes: minutes, replace: false, at: at)
            }
        default:
            break
        }
    }

    /// 終わった日を、ヘルスケアと同じフォルダに 1 日 1 ファイルで書く（iPhone だけ。一度書いた日は書き直さない）
    func exportIfDue(_ p: Pipeline, now: Date = .now) async {
        guard p.email != nil, UIDevice.current.userInterfaceIdiom != .pad,
              let first = UserDefaults.standard.string(forKey: Self.firstDayKey) else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.doneKey) ?? [])
        let due = S26ASignals.dueDays(now: now, done: done, first: first)
        guard !due.isEmpty else { return }
        for key in due {
            if let day = days[key], !day.isEmpty, let data = S26ASignals.json(day: key, day) {
                do {
                    try await p.uploadToHealthFolder(data, name: S26ASignals.fileName(key))
                    Tally.add("s26a.signals.written")
                } catch {
                    if DriveRetry.kind(error) == .error {
                        p.diagnostics.problem("端末の合図をドライブに書けませんでした: \(error.localizedDescription)")
                    }
                    break
                }
            }
            done.insert(key)
        }
        UserDefaults.standard.set(Array(done.sorted().suffix(60)), forKey: Self.doneKey)
    }
}

// MARK: - 集3 せき・いびき（と 集4 流れていた曲）

@MainActor
final class S26ABodySounds {
    static let shared = S26ABodySounds()
    nonisolated private static let key = "s26a.bodySounds.days"
    private static let seenKey = "s26a.bodySounds.seen"
    private static let heardKey = "s26a.songsHeard.count"

    /// その日のせきの回数・いびきの分（数えていなければ nil）
    nonisolated static func counts(on day: String) -> (coughs: Int?, snoreMinutes: Double?) {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
        let d = all[day] ?? [:]
        return (d["cough"].map { Int($0) }, d["snore"].map { ($0 * 10).rounded() / 10 })
    }

    private func add(cough: Int, at: Date, snore: Double, snoreAt: Date) {
        var all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String: Double]] ?? [:]
        if cough > 0 { all[HealthExport.dayKey(at), default: [:]]["cough", default: 0] += Double(cough) }
        if snore > 0 { all[S26ABodySoundRules.snoreDay(snoreAt), default: [:]]["snore", default: 0] += snore }
        let oldest = HealthExport.dayKey(Date.now.addingTimeInterval(-30 * 86400))
        all = all.filter { $0.key >= oldest }
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    /// 同じ区切りを 2 回数えない
    private func firstTime(_ name: String) -> Bool {
        var seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        guard !seen.contains(name) else { return false }
        seen.append(name)
        UserDefaults.standard.set(Array(seen.suffix(600)), forKey: Self.seenKey)
        return true
    }

    private func record(_ scan: SoundScene.Scan, start: Date) {
        let coughs = scan.body.filter { $0.label == "cough" }.map { (start: $0.start, end: $0.end) }
        let snores = scan.body.filter { $0.label == "snore" }.map { (start: $0.start, end: $0.end) }
        let count = S26ABodySoundRules.coughCount(coughs)
        let minutes = S26ABodySoundRules.snoreMinutes(snores)
        let snoreAt = start.addingTimeInterval(snores.first?.start ?? 0)
        add(cough: count, at: start, snore: minutes, snoreAt: snoreAt)
        if count > 0 { Tally.add("s26a.cough", count) }
        if minutes > 0 { Tally.add("s26a.snore") }
    }

    /// 文字にした区切りの音の聞き分けのあと（Pipeline.transcribe から）
    func chunkScanned(_ scan: SoundScene.Scan, url: URL, start: Date) {
        let name = url.lastPathComponent
        guard firstTime(name) else { return }
        if S26ASettings.on(S26ASettings.bodySoundsKey) { record(scan, start: start) }
        // その場で流れていた曲（初めはオフ。ShazamKit。1 日 30 回まで・仮）
        guard S26ASettings.on(S26ASettings.songsHeardKey),
              let offset = S26AShazamRules.musicStart(scan.windows.map { (start: $0.start, end: $0.end, label: $0.label) }),
              takeShazamTurn(on: HealthExport.dayKey(start)) else { return }
        Task.detached(priority: .utility) {
            guard let hit = await S26AShazam.match(url, offset: offset) else { return }
            await MainActor.run {
                S26ASignalsStore.shared.addSong(S26ASong(at: start.addingTimeInterval(offset), title: hit.title,
                                                         artist: hit.artist, source: "heard"))
            }
        }
    }

    private func takeShazamTurn(on day: String) -> Bool {
        var counts = UserDefaults.standard.dictionary(forKey: Self.heardKey) as? [String: Int] ?? [:]
        guard (counts[day] ?? 0) < S26AShazamRules.perDay else { return false }
        counts = counts.filter { $0.key >= HealthExport.dayKey(Date.now.addingTimeInterval(-3 * 86400)) }
        counts[day, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: Self.heardKey)
        return true
    }

    /// 声の無い区切り（文字にしないで終わるもの）。寝る時間帯で充電中だけ、いびき・せきを数える
    func quietChunk(_ url: URL, start: Date, night: Bool) async {
        guard night, S26ASettings.on(S26ASettings.bodySoundsKey), S26ASettings.charging, !Power.isSaving,
              firstTime(url.lastPathComponent) else { return }
        let scan = await Task.detached(priority: .utility) { SoundScene.scan(in: url) }.value
        record(scan, start: start)
    }
}

// MARK: - 集4 曲名を引く（ShazamKit。Apple の開発者サイトでアプリの ID に ShazamKit を有効にしないと、引けずに何もしない）

enum S26AShazam {
    static func match(_ url: URL, offset: Double) async -> (title: String, artist: String?)? {
        guard let buffer = pcm(url, from: offset, seconds: S26AShazamRules.sampleSeconds) else { return nil }
        let generator = SHSignatureGenerator()
        do { try generator.append(buffer, at: nil) } catch { return nil }
        let signature = generator.signature()
        return await S26AShazamMatcher().match(signature)
    }

    /// 区切りの offset 秒から seconds 秒を、44.1kHz・1 チャンネルにして読む（読めなければ nil）
    static func pcm(_ url: URL, from offset: Double, seconds: Double) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        let rate = inFormat.sampleRate
        guard rate > 0 else { return nil }
        let startFrame = AVAudioFramePosition(max(0, offset) * rate)
        guard startFrame < file.length else { return nil }
        file.framePosition = startFrame
        let count = AVAudioFrameCount(min(Double(file.length - startFrame), seconds * rate))
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: count) else { return nil }
        do { try file.read(into: input, frameCount: count) } catch { return nil }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 44100 / rate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// ShazamKit の答えを 1 回だけ受け取る（20 秒で諦める）
final class S26AShazamMatcher: NSObject, SHSessionDelegate, @unchecked Sendable {
    private let session = SHSession()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(title: String, artist: String?)?, Never>?

    func match(_ signature: SHSignature) async -> (title: String, artist: String?)? {
        await withCheckedContinuation { (c: CheckedContinuation<(title: String, artist: String?)?, Never>) in
            lock.lock()
            continuation = c
            lock.unlock()
            session.delegate = self
            session.match(signature)
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish(nil) }
        }
    }

    private func finish(_ value: (title: String, artist: String?)?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        let item = match.mediaItems.first
        if let title = item?.title, !title.isEmpty {
            finish((title: title, artist: item?.artist))
        } else {
            finish(nil)
        }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // App Service が無い・つながらないときもここ（静かに何もしない。数だけ）
        if error != nil { Tally.add("s26a.shazam.error") }
        finish(nil)
    }
}

// MARK: - 集5 聴いた曲（ミュージックで再生中の曲。MusicKit の App Service は使わない）

@MainActor
enum S26AMusic {
    static var authorized: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    /// スイッチを入れたときに 1 回だけ許可を聞く（本人が押したときだけ）
    static func requestAccess() async -> Bool {
        await withCheckedContinuation { c in
            MPMediaLibrary.requestAuthorization { status in c.resume(returning: status == .authorized) }
        }
    }

    /// 1 分ごと。再生中なら曲名と歌手を残す
    static func poll(now: Date) {
        guard S26ASettings.on(S26ASettings.songsPlayedKey), authorized else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        guard player.playbackState == .playing, let item = player.nowPlayingItem,
              let title = item.title, !title.isEmpty else { return }
        S26ASignalsStore.shared.addSong(S26ASong(at: now, title: title, artist: item.artist, source: "played"))
    }
}

// MARK: - 集13 気圧の高さ

@MainActor
final class S26AAltimeter {
    static let shared = S26AAltimeter()
    private let altimeter = CMAltimeter()
    private var running = false
    private var tracker = S26AFloorTracker()

    /// スイッチと許可を見て、始める・止める（アプリが動いているあいだだけ測る）
    func update() {
        let want = S26ASettings.on(S26ASettings.floorsKey) && CMAltimeter.isRelativeAltitudeAvailable()
            && CMMotionActivityManager.authorizationStatus() == .authorized
        if want, !running {
            running = true
            tracker = S26AFloorTracker()
            altimeter.startRelativeAltitudeUpdates(to: .main) { data, _ in
                guard let meters = data?.relativeAltitude.doubleValue else { return }
                Task { @MainActor in S26AAltimeter.shared.feed(meters) }
            }
        } else if !want, running {
            altimeter.stopRelativeAltitudeUpdates()
            running = false
        }
    }

    private func feed(_ meters: Double, now: Date = .now) {
        if let delta = tracker.feed(meters, at: now) { S26ASignalsStore.shared.addFloor(delta, at: now) }
    }
}

// MARK: - 集10 食事の写真・集16 名刺（iPhone の中で見分け、写真そのものは送らない）

@MainActor
final class S26APhotoScan {
    static let shared = S26APhotoScan()
    private static let lastKey = "s26a.photos.last"
    /// 1 回に見る写真の数（仮）
    static let perRun = 30

    func scan(now: Date = .now) async {
        let meals = S26ASettings.on(S26ASettings.mealsKey), cards = S26ASettings.on(S26ASettings.cardsKey)
        guard meals || cards, DayPhotos.isAllowed else { return }
        let saved = UserDefaults.standard.double(forKey: Self.lastKey)
        // 初めは今日の 0 時から（前の写真はさかのぼらない）
        let since = saved > 0 ? Date(timeIntervalSince1970: saved) : Calendar.current.startOfDay(for: now)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate > %@", PHAssetMediaType.image.rawValue, since as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = Self.perRun
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        var last = since
        for asset in assets {
            guard let taken = asset.creationDate else { continue }
            last = max(last, taken)
            if asset.mediaSubtypes.contains(.photoScreenshot) { continue }
            guard let small = await DayPhotos.image(asset, size: CGSize(width: 512, height: 512), fit: true, network: false) else { continue }
            let labels = await S26AVision.labels(small)
            if meals, S26APhotoRules.isMeal(labels) {
                let loc = asset.location?.coordinate
                S26ASignalsStore.shared.addMeal(S26AMeal(at: taken, lat: loc?.latitude, lon: loc?.longitude))
                Tally.add("s26a.meal")
            }
            if cards, S26APhotoRules.isPaper(labels),
               let big = await DayPhotos.image(asset, size: CGSize(width: 1600, height: 1600), fit: true, network: false) {
                let text = await Pipeline.recognizeText(big)
                if S26APhotoRules.looksLikeCard(text) {
                    S26ASignalsStore.shared.addCard(S26ACard(at: taken, lines: S26APhotoRules.cardLines(text)))
                }
            }
        }
        UserDefaults.standard.set(last.timeIntervalSince1970, forKey: Self.lastKey)
    }
}

enum S26AVision {
    /// 写真に写っているものの名前と強さ（iPhone の中だけで見る）
    static func labels(_ image: UIImage) async -> [(id: String, confidence: Double)] {
        guard let cg = image.cgImage else { return [] }
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).filter { $0.confidence >= 0.05 }.map { (id: $0.identifier, confidence: Double($0.confidence)) }
    }
}

// MARK: - 聞16 会議・面談の予定のあいだは精度優先

@MainActor
enum S26AMeetingAuto {
    static let activeKey = "s26a.meeting.active"
    static let untilKey = "s26a.meeting.until"
    static let savedKey = "s26a.meeting.saved"

    static var isActive: Bool { UserDefaults.standard.bool(forKey: activeKey) }

    static func currentEnd(_ p: Pipeline, now: Date) -> Date? {
        let events = p.calendar.events(from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(S26AMeetingRules.lead + 60))
            .map { (start: $0.start, end: $0.end, title: $0.title, attendees: $0.attendees.count, isWork: $0.isWork) }
        return S26AMeetingRules.meetingEnd(events, now: now)
    }

    static func tick(_ p: Pipeline, now: Date) {
        let d = UserDefaults.standard
        if isActive {
            let end = currentEnd(p, now: now)
            if let end, end.timeIntervalSince1970 > d.double(forKey: untilKey), S26ASettings.on(S26ASettings.meetingAutoKey) {
                d.set(end.timeIntervalSince1970, forKey: untilKey)  // 予定が延びた
                return
            }
            guard now.timeIntervalSince1970 >= d.double(forKey: untilKey) || !S26ASettings.on(S26ASettings.meetingAutoKey) else { return }
            if let data = d.data(forKey: savedKey), let saved = try? JSONDecoder().decode(S26APresetSnapshot.self, from: data) {
                p.s26aRestore(saved)
            }
            d.set(false, forKey: activeKey)
            d.removeObject(forKey: savedKey)
            Tally.add("s26a.meeting.restored")
            return
        }
        guard S26ASettings.on(S26ASettings.meetingAutoKey), let end = currentEnd(p, now: now) else { return }
        if let data = try? JSONEncoder().encode(p.s26aSnapshot()) { d.set(data, forKey: savedKey) }
        p.s26aApply(.accuracy)
        d.set(true, forKey: activeKey)
        d.set(end.timeIntervalSince1970, forKey: untilKey)
        Tally.add("s26a.meeting.auto")
    }
}

extension Pipeline {
    /// いまの録り方（S21Preset.Values と同じスイッチ）
    func s26aSnapshot() -> S26APresetSnapshot {
        S26APresetSnapshot(chunkLength: chunkLength.rawValue, batterySaver: chunkBatterySaver, skipSilence: skipSilence,
                           dropNoVoice: dropNoVoice, standby: standbyOn, watchDirect: homePC.watchDirect,
                           watchRelay: homePC.watchRelay, useCloud: settings.useCloud, correction: correctionOn,
                           speakers: speakerLabelsOn)
    }

    func s26aRestore(_ s: S26APresetSnapshot) {
        if let raw = s.chunkLength, let x = ChunkCutter.Length(rawValue: raw) { chunkLength = x }
        if let x = s.batterySaver { chunkBatterySaver = x }
        if let x = s.skipSilence { skipSilence = x }
        if let x = s.dropNoVoice { dropNoVoice = x }
        if let x = s.standby { standbyOn = x }
        if let x = s.watchDirect { homePC.watchDirect = x }
        if let x = s.watchRelay { homePC.watchRelay = x }
        if let x = s.useCloud, settings.hasAPIKey { settings.useCloud = x }
        if let x = s.correction { correctionOn = x }
        if let x = s.speakers { speakerLabelsOn = x }
    }

    /// 録り方の組をまとめて切り替える（設定の「録り方の組」のボタンと同じ。S21Views.swift）
    func s26aApply(_ preset: S21Preset) {
        let v = preset.values(hasCloudKey: settings.hasAPIKey)
        if let x = v.chunkLength { chunkLength = x }
        if let x = v.batterySaver { chunkBatterySaver = x }
        if let x = v.skipSilence { skipSilence = x }
        if let x = v.dropNoVoice { dropNoVoice = x }
        if let x = v.standby { standbyOn = x }
        if let x = v.watchDirect { homePC.watchDirect = x }
        if let x = v.watchRelay { homePC.watchRelay = x }
        if let x = v.useCloud, settings.hasAPIKey { settings.useCloud = x }
        if let x = v.correction, llmKey != nil { correctionOn = x }
        if let x = v.speakers { speakerLabelsOn = x }
        Tally.add("s26a.preset." + preset.rawValue)
    }

    /// 「◯◯さんの最近」（ショートカット。人のページと、アプリの中の直近 30 日の会話 3 つまで）
    func s26aPersonRecent(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return "名前を教えてください。" }
        var parts: [String] = []
        if let page = PagesBook.shared.page(named: n) {
            if let last = page.last_talk { parts.append("最後に話したこと（\(last.day)）: " + last.summary) }
            if !page.next_line.isEmpty { parts.append("次に会うときの一言: " + page.next_line) }
            if let p = page.promises.first { parts.append("約束: " + p.text) }
        }
        var found = 0
        search: for day in recordedDays().prefix(30) {
            for c in conversations(on: day).reversed() where c.closed && c.media == nil
                && c.people.contains(where: { S25TText.sameName($0, n) }) {
                parts.append(day + " " + (c.title ?? "会話"))
                found += 1
                if found >= 3 { break search }
            }
        }
        return parts.isEmpty ? "\(n)さんの最近の記録は見つかりませんでした。" : parts.joined(separator: "\n")
    }
}

// MARK: - 結3 実績のカレンダー（初めはオフ。本人のカレンダーに書く）

@MainActor
enum S26AActualCalendar {
    static let doneKey = "s26a.actual.done"
    static let firstKey = "s26a.actual.first"
    static let calendarIDKey = "s26a.actual.calendarID"
    private static let store = EKEventStore()

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// スイッチを入れたとき。1 日目は 7 日前から（仮）
    static func turnedOn(now: Date = .now) {
        guard UserDefaults.standard.string(forKey: firstKey) == nil else { return }
        UserDefaults.standard.set(HealthExport.dayKey(now.addingTimeInterval(-7 * 86400)), forKey: firstKey)
    }

    static func writeIfDue(_ p: Pipeline, now: Date = .now) async {
        guard S26ASettings.on(S26ASettings.actualKey), authorized, let first = UserDefaults.standard.string(forKey: firstKey) else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        let due = S26ASignals.dueDays(now: now, done: done, first: first, limit: 3)
        guard !due.isEmpty, let calendar = actualCalendar() else { return }
        for day in due {
            guard let start = HealthExport.dayDate(day) else { continue }
            let end = start.addingTimeInterval(86400)
            var items: [S26AActualRules.Item] = []
            for c in p.conversations(on: day) where c.closed && c.media == nil {
                if let item = S26AActualRules.talk(title: c.title, people: c.people, place: c.place, start: c.start, end: c.end) {
                    items.append(item)
                }
            }
            for v in p.shopVisits.visits where v.arrival >= start && v.arrival < end {
                guard let out = v.departure else { continue }
                if let item = S26AActualRules.stay(name: v.shownName, start: v.arrival, end: out) { items.append(item) }
            }
            for item in S26AActualRules.capped(items) {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = item.title
                event.startDate = item.start
                event.endDate = max(item.end, item.start.addingTimeInterval(60))
                event.notes = item.notes
                event.url = S26ALink.day(day).url
                try? store.save(event, span: .thisEvent, commit: false)
            }
            do {
                try store.commit()
            } catch {
                p.diagnostics.problem("「実績」のカレンダーに書けませんでした: \(error.localizedDescription)")
                break
            }
            done.insert(day)
            Tally.add("s26a.actual.day")
        }
        UserDefaults.standard.set(Array(done.sorted().suffix(60)), forKey: doneKey)
    }

    /// 「実績」のカレンダー（無ければ、新しい予定を入れるカレンダーと同じアカウントに作る）
    private static func actualCalendar() -> EKCalendar? {
        if let id = UserDefaults.standard.string(forKey: calendarIDKey), let cal = store.calendar(withIdentifier: id),
           cal.allowsContentModifications {
            return cal
        }
        if let cal = store.calendars(for: .event).first(where: { $0.title == S26AActualRules.calendarTitle && $0.allowsContentModifications }) {
            UserDefaults.standard.set(cal.calendarIdentifier, forKey: calendarIDKey)
            return cal
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = S26AActualRules.calendarTitle
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local }) else {
            return nil
        }
        cal.source = source
        do {
            try store.saveCalendar(cal, commit: true)
        } catch {
            return nil
        }
        UserDefaults.standard.set(cal.calendarIdentifier, forKey: calendarIDKey)
        return cal
    }
}

// MARK: - 聞10 端末の中の音声認識を測る（切り替えない）

@MainActor
@Observable
final class S26ABench {
    static let shared = S26ABench()
    private static let key = "s26a.bench.rows"

    private(set) var rows: [S26ABenchRules.Row] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([S26ABenchRules.Row].self, from: data) {
            rows = saved
        }
    }

    /// 答え合わせで答えた行を、端末の中の音声認識（SpeechAnalyzer。iOS 26 から）で聞き直して比べる。充電中に 1 日 8 個まで
    func runIfDue(_ p: Pipeline, now: Date = .now) async {
        guard S26ASettings.on(S26ASettings.benchKey), S26ASettings.charging else { return }
        guard #available(iOS 26.0, *) else { return }
        let today = HealthExport.dayKey(now)
        let doneToday = rows.filter { HealthExport.dayKey($0.at) == today }.count
        guard doneToday < S26ABenchRules.perDay else { return }
        let measured = Set(rows.map(\.id))
        let samples = p.answerKey.samples.filter { s in
            s.isAnswered && s.skipped != true && (s.rightText ?? "").count >= 4 && !measured.contains(s.week + "|" + s.id)
        }
        for s in samples.suffix(S26ABenchRules.perDay - doneToday) {
            guard S26ASettings.charging, let right = s.rightText else { break }
            var audio: URL? = AnswerClips.local(for: s)
            if audio == nil { audio = await p.archive.playableURL(for: s.audio) }
            guard let url = audio, let lines = try? await Transcriber.transcribe(url) else { continue }
            let truth = AnswerKey.normalized(right)
            let heard = AnswerKey.normalized(lines.map(\.text).joined())
            let row = S26ABenchRules.Row(id: s.week + "|" + s.id, chars: truth.count,
                                         device: S26ABenchRules.fitDistance(truth, in: heard),
                                         app: AnswerKey.editDistance(AnswerKey.normalized(s.text), truth), at: now)
            rows.append(row)
            Tally.add("s26a.bench.row")
        }
        rows = Array(rows.suffix(300))
        if let data = try? JSONEncoder().encode(rows) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - 軽7 iPhone の検索

@MainActor
enum S26ASpotlight {
    static let activityType: String = CSSearchableItemActionType
    static let domains = ["s26a.person", "s26a.day", "s26a.talk", "s26a.place"]
    private static let wasOnKey = "s26a.spotlight.wasOn"

    /// 押された検索の結果から開く画面
    static func route(_ activity: NSUserActivity) -> NoticeRoute? {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let url = URL(string: id) else { return nil }
        Tally.add("s26a.spotlight.opened")
        return NoticeRoute.route(url: url)
    }

    private static func item(_ link: S26ALink, domain: String, title: String, detail: String?, keywords: [String] = []) -> CSSearchableItem? {
        guard let url = link.url?.absoluteString else { return nil }
        let set = CSSearchableItemAttributeSet(contentType: UTType.text)
        set.title = title
        set.contentDescription = detail
        if !keywords.isEmpty { set.keywords = keywords }
        return CSSearchableItem(uniqueIdentifier: url, domainIdentifier: domain, attributeSet: set)
    }

    static func refresh(_ p: Pipeline, now: Date = .now) async {
        let index = CSSearchableIndex.default()
        guard S26ASettings.on(S26ASettings.spotlightKey) else {
            if UserDefaults.standard.bool(forKey: wasOnKey) {
                try? await index.deleteSearchableItems(withDomainIdentifiers: domains)
                UserDefaults.standard.set(false, forKey: wasOnKey)
            }
            return
        }
        var items: [CSSearchableItem] = []
        var names = Set<String>()
        // 人（名前を付けた声と、家の PC の人のページ）
        for person in p.people where person.isNamed && !person.isSelf && person.hidden != true {
            let name = person.displayName
            guard names.insert(PagesFeeds.nameKey(name)).inserted else { continue }
            let page = PagesBook.shared.page(named: name)
            if let i = item(.person(name), domain: "s26a.person", title: name, detail: page?.next_line.isEmpty == false ? page?.next_line : "人",
                            keywords: page?.aliases ?? []) { items.append(i) }
        }
        for page in PagesBook.shared.people where names.insert(PagesFeeds.nameKey(page.name)).inserted {
            if let i = item(.person(page.name), domain: "s26a.person", title: page.name, detail: page.next_line.isEmpty ? "人" : page.next_line,
                            keywords: page.aliases) { items.append(i) }
        }
        // 場所（行った場所のページ。押すと最後に行った日）
        for place in PagesBook.shared.places.prefix(200) where S26ALink.isDay(place.last_day) {
            if let i = item(.day(place.last_day), domain: "s26a.place", title: place.name,
                            detail: "行った場所（最後: \(place.last_day)・\(place.visit_days) 日）") { items.append(i) }
        }
        // 日（直近 60 日）
        for day in p.recordedDays().prefix(60) {
            guard let date = HealthExport.dayDate(day) else { continue }
            if let i = item(.day(day), domain: "s26a.day", title: MorningBrief.dayLabel(date) + " の記録", detail: day) { items.append(i) }
        }
        // 会話の見出し（直近 14 日。開くときに Face ID の設定なら、中身を隠す設定なので載せない）
        if !UserDefaults.standard.bool(forKey: AppLock.key) {
            for day in p.recordedDays().prefix(14) {
                for c in p.conversations(on: day) where c.closed && c.media == nil {
                    guard let title = c.title, !title.isEmpty else { continue }
                    var bits: [String] = [MorningBrief.clock(c.start)]
                    bits += Array(c.people.prefix(3))
                    if let place = c.place { bits.append(place) }
                    let detail: String = bits.joined(separator: "・")
                    if let i = item(.talk(S26ALink.appTalkID(c.start)), domain: "s26a.talk", title: title, detail: detail,
                                    keywords: c.people) { items.append(i) }
                }
            }
        }
        try? await index.deleteSearchableItems(withDomainIdentifiers: domains)
        do {
            try await index.indexSearchableItems(items)
            UserDefaults.standard.set(true, forKey: wasOnKey)
            Tally.add("s26a.spotlight.indexed", max(1, items.count))
        } catch {
            Tally.add("s26a.spotlight.failed")
        }
    }
}

// MARK: - 結5 小さい区切りはすぐ送る

enum S26AFastSend {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight: [String: Date] = [:]

    /// いま すぐ送っている途中なら、送り始めた時刻（PCJobUploader.stagedSince が見る。同じ区切りを二重に頼まないように）
    static func inFlightSince(_ name: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[name]
    }

    private static func mark(_ name: String, _ at: Date?) {
        lock.lock()
        inFlight[name] = at
        lock.unlock()
    }

    private static let spare: URL = {
        let dir = URL.cachesDirectory.appendingPathComponent("s26a-fast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 小さい区切りは、その場の通信ですぐ送る。だめなら写しから今までどおり裏の転送で送る
    @MainActor
    static func upload(_ url: URL, request: URLRequest, cellular: Bool) {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let name = url.lastPathComponent
        let copy = spare.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: copy)
        guard S26AFastSendRules.eligible(bytes: bytes, on: S26ASettings.on(S26ASettings.fastSendKey)),
              let data = try? Data(contentsOf: url), (try? data.write(to: copy)) != nil else {
            PCJobUploader.shared.upload(url, request: request, cellular: cellular)
            return
        }
        let active = UIApplication.shared.applicationState == .active
        Tally.add(active ? "s26a.fast.try.active" : "s26a.fast.try.back")
        mark(name, .now)
        let background = S26ABackgroundTask("s26a.fast")
        Task.detached(priority: .userInitiated) {
            let body = await S26AFastSend.send(data, request: request, cellular: cellular)
            await MainActor.run {
                S26AFastSend.mark(name, nil)
                if let body {
                    PCSilence.noteContact()
                    Tally.add("jobs.sent")
                    Tally.add("s26a.fast.ok")
                    _ = PCJobUploader.shared.deliver(body, name: name)
                } else {
                    // 今までどおり裏の転送で（写しから。元の区切りはもう動いているかもしれない）
                    Tally.add("s26a.fast.fallback")
                    PCJobUploader.shared.upload(copy, request: request, cellular: cellular)
                }
                try? FileManager.default.removeItem(at: copy)
                background.end()
            }
        }
    }

    private static func send(_ data: Data, request: URLRequest, cellular: Bool) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = cellular
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = S26AFastSendRules.timeout
        config.timeoutIntervalForResource = S26AFastSendRules.timeout * 3
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = request
        req.allowsCellularAccess = cellular
        guard let got = try? await session.upload(for: req, from: data),
              (got.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return got.0
    }
}

/// 裏に回っても、すぐ送るあいだだけ少し動かしてもらう（iOS が止めると言ったら、すぐ返す）
@MainActor
final class S26ABackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

// MARK: - 聞12 人の名前の読みの辞書

@MainActor
final class S26ANameDict {
    static let shared = S26ANameDict()
    private(set) var names: [ContactsLink.Name] = []

    /// 人のページの名前・別名（LINE の表示名なども入っている・仮）と、前後 14 日の予定の相手から作る
    func rebuild(_ p: Pipeline, now: Date = .now) {
        guard S26ASettings.on(S26ASettings.nameDictKey) else {
            names = []
            return
        }
        var raw: [String] = []
        for page in PagesBook.shared.people {
            raw.append(page.name)
            raw += page.aliases
        }
        for event in p.calendar.dayEvents(from: now.addingTimeInterval(-14 * 86400), to: now.addingTimeInterval(14 * 86400)) {
            raw += event.attendees
        }
        names = S26ANameRules.entries(raw).map { ContactsLink.Name(written: $0.written, reading: $0.reading) }
        Tally.add("s26a.names.built")
    }
}

// MARK: - 軽12 アプリで入れた体重（ヘルスケアに無い日の書き出しに使う）

enum S26AWeightBook {
    private static let key = "s26a.weights"

    private static var all: [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }

    /// 入れる（20〜300kg だけ）。その日の最後の値を残す
    @discardableResult
    static func add(_ kg: Double, at: Date = .now) -> Bool {
        guard kg.isFinite, (20...300).contains(kg) else { return false }
        var a = all
        a[HealthExport.dayKey(at)] = [(kg * 100).rounded() / 100, at.timeIntervalSince1970]
        let oldest = HealthExport.dayKey(at.addingTimeInterval(-120 * 86400))
        a = a.filter { $0.key >= oldest }
        UserDefaults.standard.set(a, forKey: key)
        Tally.add("s26a.weight.added")
        return true
    }

    static func weight(on day: String) -> Double? { all[day]?.first }

    static func latest() -> (kg: Double, at: Date)? {
        guard let row = all.max(by: { $0.key < $1.key })?.value, row.count >= 2 else { return nil }
        return (row[0], Date(timeIntervalSince1970: row[1]))
    }
}

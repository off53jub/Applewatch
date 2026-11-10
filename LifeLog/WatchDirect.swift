import Foundation
import Observation
import Security
import UIKit
import WatchConnectivity

/// 時計から家の PC に区切りを直接送る（2026-11-07）の、iPhone 側の受け渡し。
/// 時計の送り方は LifeLogWatch/WatchPC.swift、決まりは Shared/Audio/WatchDelivery.swift。
///
/// - 家の中の住所と合言葉は transferUserInfo で時計に送る（時計は合言葉を Keychain に置く）。起動のたびと、設定が変わったとき。
/// - PC の外の道（Tailscale の Funnel。https://〜.ts.net）と時計用の合言葉も、PC に聞いて（GET /watch-route）同じように送る。
///   PC が「watchroute」をできるときだけ。起動したとき・前に出たとき（6時間に1回まで）と、PC の設定が変わったときに聞く。
///   時計用の合言葉は iPhone の Keychain に、宛先は UserDefaults に置く（ログには出さない）。docs/v10-watch-route-ios.md
/// - 聞き取りのヒント（いまの時間の予定・場所・話題の言葉）と多数決の重みは applicationContext で送る（10分に1回まで、変わったときだけ）。
///   PC は先に届いた送りの設定で文字にするので、時計の送りにも iPhone と同じヒントを付ける。
/// - 時計の区切りが届いたとき、時計が PC にも送っていて、PC がもう文字にし終えていれば、その答えをすぐ使う
///   （音声が届いてから記録に入れる流れは今までどおり）。
@MainActor
final class WatchDirectState {
    static let shared = WatchDirectState()
    /// 打っている途中に何度も送らないよう、少し待ってから送る
    var pending: Task<Void, Never>?
    /// この起動で最後に時計に送った住所と合言葉（同じなら送り直さない）
    var sentAddress: String?
    var sentKey: String?
    /// この起動で最後に時計に送った外の道と時計用の合言葉（同じなら送り直さない）
    var sentPublicURL: String?
    var sentPublicKey: String?
    var hintsSentAt = Date.distantPast
    /// 時計が受け取っていないので送り直した時刻（checkWatchPCDelivery。送りすぎないため）
    var resentAt = Date.distantPast
    /// アプリが前に出たときの知らせ
    var activeObserver: NSObjectProtocol?
}

/// PC の外の道（Tailscale の Funnel）。PC に聞いた答えを覚えておく（2026-11-07）
@MainActor
@Observable
final class WatchRoute {
    static let shared = WatchRoute()
    private static let urlKey = "pcWatchRouteURL"
    private static let checkedKey = "pcWatchRouteChecked"
    /// これだけたったら、PC に聞き直す
    static let refreshEvery: TimeInterval = 6 * 3600
    /// 聞けなかったら、これだけは聞き直さない
    static let retryAfter: TimeInterval = 10 * 60

    /// 外の道の宛先（https://〜.ts.net）。Funnel がオフ・PC が古い・まだ聞いていないときは nil
    private(set) var publicURL: String? = UserDefaults.standard.string(forKey: WatchRoute.urlKey)
    /// 時計用の合言葉があるか
    private(set) var hasToken = WatchRouteKeychain.read() != nil
    /// PC の LifeLog PC がまだ外の道を知らない（古い版）
    private(set) var unsupported = false
    /// 最後に PC に聞けた時刻
    @ObservationIgnored private(set) var checkedAt = UserDefaults.standard.object(forKey: WatchRoute.checkedKey) as? Date
    @ObservationIgnored var triedAt: Date?
    @ObservationIgnored var busy = false
    /// 聞いている途中に設定が変わった（終わったら、もう一度聞く）
    @ObservationIgnored var again = false

    /// 外の道が使える（宛先と時計用の合言葉がある）
    var isReady: Bool { publicURL.flatMap { WatchDelivery.publicBaseURL($0) } != nil && hasToken }

    /// いま聞きに行く頃か
    func isDue(now: Date) -> Bool {
        if let tried = triedAt, now.timeIntervalSince(tried) < Self.retryAfter { return false }
        guard let checked = checkedAt else { return true }
        return now.timeIntervalSince(checked) >= Self.refreshEvery
    }

    /// PC の答えを覚える（宛先が無ければ、合言葉も消す）
    func store(url: URL?, token: String?) {
        let text = url?.absoluteString
        let key = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let text, !key.isEmpty {
            UserDefaults.standard.set(text, forKey: Self.urlKey)
            WatchRouteKeychain.save(key)
            publicURL = text
        } else {
            UserDefaults.standard.removeObject(forKey: Self.urlKey)
            WatchRouteKeychain.delete()
            publicURL = nil
        }
        hasToken = WatchRouteKeychain.read() != nil
        unsupported = false
        checkedAt = .now
        UserDefaults.standard.set(checkedAt, forKey: Self.checkedKey)
    }

    /// PC が外の道を知らない（古い LifeLog PC）
    func markUnsupported() {
        store(url: nil, token: nil)
        unsupported = true
    }

    /// 時計に送る宛先と合言葉（使えないときは空）
    func credentials() -> (url: String, key: String?) {
        guard let text = publicURL, WatchDelivery.publicBaseURL(text) != nil, let key = WatchRouteKeychain.read() else {
            return ("", nil)
        }
        return (text, key)
    }
}

/// PC の外の道の時計用の合言葉（キーチェーン。PC の合言葉 PCKeychain とは別の名前。ログやコードには書かない）
private enum WatchRouteKeychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.off53jub.lifelog",
            kSecAttrAccount as String: "pc-watch-token",
        ]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        guard read() != value else { return }
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

extension HomePC {
    /// 設定画面に出す、時計から PC への道の様子（時計から直接送るがオフなら nil）
    var watchRouteText: String? {
        guard watchDirect else { return nil }
        guard enabled, hasKey else { return "家の PC の宛先と合言葉が入ると送れます" }
        if WatchRoute.shared.isReady { return "家の外でも送れます（Tailscale の Funnel）" }
        if WatchDelivery.homeBaseURL(homeAddress) != nil { return "家の Wi-Fi にいるときだけ送れます（PC の外の道はまだありません）" }
        return "PC の外の道がまだありません（家の中の住所を入れると、家の Wi-Fi で送れます）"
    }
}

extension PhoneReceiver {
    /// PC の外の道と時計用の合言葉を時計に送る（時計は合言葉を Keychain に置く）。宛先が空なら、時計は合言葉を消す。
    /// 合言葉は、時計にずっと残る applicationContext には入れず、届いたら消える transferUserInfo で送る
    /// 送れたら true（つながっていない・時計にアプリが無いと思われるときは false。送ったことにしない）。
    /// isWatchAppInstalled は TestFlight で入れ直したあと false のままのことがあるので、時計からの最近の便りも見る（2026-11-08）
    @discardableResult
    func sendWatchPCPublic(url: String, key: String?) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WatchPresence.installed(WCSession.default) else { return false }
        WCSession.default.transferUserInfo([WatchDelivery.publicURLKey: url,
                                            WatchDelivery.publicSecretKey: url.isEmpty ? "" : (key ?? "")])
        return true
    }
}

extension Pipeline {
    /// init から1回だけ呼ぶ
    func setUpWatchDirect() {
        homePC.onWatchSettingsChange = { [weak self] in self?.scheduleWatchPCSync() }
        // 時計が外の道・直接送るを受け取っていなければ、送り直す（10分に1回まで。2026-11-08）
        receiver.onWatchPCState = { [weak self] in self?.checkWatchPCDelivery() }
        receiver.onActivated = { [weak self] in
            self?.syncWatchPC()
            // PC の外の道を聞く（6時間に1回まで）
            self?.refreshWatchRoute()
            // 時計に残っている区切りを送り直してもらう（起動のたびに1回。WatchRescue.swift）
            self?.askWatchResendOnLaunch()
        }
        // 前に出たときも、PC の外の道を聞く（6時間に1回まで）
        let state = WatchDirectState.shared
        if state.activeObserver == nil {
            state.activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWatchRoute() }
            }
        }
    }

    /// 設定が変わったら、2秒待ってから時計に送る（PC の外の道も聞き直す）
    func scheduleWatchPCSync() {
        let state = WatchDirectState.shared
        state.pending?.cancel()
        state.pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.syncWatchPC()
            self?.refreshWatchRoute(force: true)
        }
    }

    /// 時計に送る外の道と時計用の合言葉（家の PC が切れている・時計から送らない・合言葉が無い・外の道が無いときは空）
    func publicWatchCredentials() -> (url: String, key: String?) {
        guard homePC.enabled, homePC.watchDirect, homePC.hasKey else { return ("", nil) }
        return WatchRoute.shared.credentials()
    }

    /// 住所と合言葉・外の道・オンオフ・ヒントを時計に送る
    func syncWatchPC() {
        let state = WatchDirectState.shared
        let credentials = homePC.watchCredentials()
        // 送れたときだけ「送った」と覚える（送れなかったら、次の機会にまた送る。2026-11-08）
        if state.sentAddress != credentials.address || state.sentKey != credentials.key,
           receiver.sendWatchPCCredentials(address: credentials.address, key: credentials.key) {
            state.sentAddress = credentials.address
            state.sentKey = credentials.key
        }
        let open = publicWatchCredentials()
        if state.sentPublicURL != open.url || state.sentPublicKey != open.key,
           receiver.sendWatchPCPublic(url: open.url, key: open.key) {
            state.sentPublicURL = open.url
            state.sentPublicKey = open.key
        }
        refreshWatchPCHints(force: true)
    }

    /// 時計の様子の知らせを見て、時計が外の道を持っていない・直接送るがオフのままなら、もう一度送る（2026-11-08）。
    /// 送ったはずの知らせが時計に届かないことがあった（入れ直しのあと・古い版の時計が受け取って捨てた）。
    /// 送りすぎないよう、WatchDelivery.resendGap に1回まで。古い版の時計（知らせに項目が無い）には送らない
    func checkWatchPCDelivery(now: Date = .now) {
        guard WCSession.isSupported() else { return }
        let watch = WCSession.default.receivedApplicationContext
        let open = publicWatchCredentials()
        let credentials = homePC.watchCredentials()
        let expectedOn = !credentials.address.isEmpty || !open.url.isEmpty
        let need = WatchDelivery.needsResend(watchHasPublic: watch["pcPublic"] as? Bool,
                                             watchDirectOn: watch["pcDirect"] as? Bool,
                                             phoneHasPublic: !open.url.isEmpty, phoneDirectOn: expectedOn)
        let state = WatchDirectState.shared
        guard need, now.timeIntervalSince(state.resentAt) >= WatchDelivery.resendGap else { return }
        state.resentAt = now
        if receiver.sendWatchPCCredentials(address: credentials.address, key: credentials.key) {
            state.sentAddress = credentials.address
            state.sentKey = credentials.key
        }
        if receiver.sendWatchPCPublic(url: open.url, key: open.key) {
            state.sentPublicURL = open.url
            state.sentPublicKey = open.key
        }
        refreshWatchPCHints(force: true, resend: true)
    }

    /// PC の外の道（GET /watch-route）を聞いて覚え、変わっていれば時計に送る。
    /// 家の PC を使っていて、時計から直接送るがオンのときだけ。force でなければ6時間に1回まで（聞けなければ10分は聞かない）
    func refreshWatchRoute(force: Bool = false) {
        let route = WatchRoute.shared
        guard homePC.isConfigured, homePC.watchDirect else { return }
        if route.busy {
            if force { route.again = true }
            return
        }
        let now = Date.now
        guard force || route.isDue(now: now) else { return }
        route.busy = true
        route.triedAt = now
        Task { [weak self] in
            await self?.fetchWatchRoute(askFeatures: force)
            route.busy = false
            if route.again {
                route.again = false
                self?.refreshWatchRoute(force: true)
            }
        }
    }

    private func fetchWatchRoute(askFeatures: Bool) async {
        let route = WatchRoute.shared
        // PC にできることを聞く（設定が変わったとき・まだ聞いていないとき）
        if askFeatures || homePC.version == nil {
            do {
                _ = try await homePC.hello()
            } catch {
                return
            }
        }
        guard homePC.features.contains("watchroute") else {
            // 古い LifeLog PC は外の道を知らない（家の中の住所だけで送る）
            route.markUnsupported()
            syncWatchPC()
            return
        }
        struct Reply: Decodable {
            let url: String?
            let token: String?
            let funnel: Bool?
            let port: Int?
        }
        let fetched = try? await homePC.getJSONData("watch-route", timeout: 8)
        guard let data = fetched, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return }
        // https://〜.ts.net で、道や番号が付いていないものだけ使う（Funnel がオフなら url は null）
        let base = reply.url.flatMap { WatchDelivery.publicBaseURL($0) }
        route.store(url: base, token: base == nil ? nil : reply.token)
        syncWatchPC()
    }

    /// 自己点検の行「時計から PC への外の道」（家の PC を使っていないときは nil）。
    /// 時計が知らせてきた様子（外の道があるか・直近24時間に外の道で送れた数・合言葉が違うと言われたか）も添える
    func watchRouteDiag() -> (value: String, ok: Bool?, checkedAt: Date?)? {
        guard homePC.isConfigured else { return nil }
        guard homePC.watchDirect else { return ("使わない（時計から直接送るがオフ）", nil, nil) }
        let route = WatchRoute.shared
        var text: String
        if !publicWatchCredentials().url.isEmpty {
            text = "あり（Tailscale の Funnel）"
        } else if route.unsupported {
            text = "なし（PC の LifeLog PC がまだ外の道を知りません）"
        } else {
            text = "なし"
        }
        var ok: Bool?
        let watch = WCSession.isSupported() ? WCSession.default.receivedApplicationContext : [:]
        if watch["pcDirect"] as? Bool == false {
            text += "・時計: 直接送るがオフのまま"
        }
        if let ready = watch["pcPublic"] as? Bool {
            text += ready ? "・時計: 受け取り済み" : "・時計: まだ受け取っていない"
            if let sent = watch["pcPublicSent"] as? Int { text += "・外の道で送れた \(sent) 個（直近24時間）" }
        }
        if watch["pcPublicRefused"] as? Bool == true {
            text += "・時計の合言葉が違うと言われた（PC の設定を開き直すと、新しい合言葉を送ります）"
            ok = false
        }
        // 時計がいま直接送らない理由・最後に届かなかった理由（時刻つき。新しい時計のアプリだけ。2026-11-10）
        if let skip = watch["pcSkip"] as? String, !skip.isEmpty { text += "・いま送らない理由: \(skip)〜" }
        if let fail = watch["pcFail"] as? String, !fail.isEmpty { text += "・最後に届かなかった: \(fail)" }
        return (text, ok, route.checkedAt)
    }

    /// 聞き取りのヒントと重みを時計に送る（10分に1回まで。中身が変わったときだけ送られる）
    func refreshWatchPCHints(force: Bool = false, resend: Bool = false) {
        let state = WatchDirectState.shared
        guard force || Date.now.timeIntervalSince(state.hintsSentAt) >= 600 else { return }
        state.hintsSentAt = .now
        // 家の中の住所か、PC の外の道のどちらかがあれば、時計から直接送る
        let on = !homePC.watchCredentials().address.isEmpty || !publicWatchCredentials().url.isEmpty
        var words: [String] = []
        if on {
            // iPhone の送り（HomePC.enqueueJob）と同じ選び方
            var length = 0
            for word in keywords(for: vocabularyContext(at: .now)) where !word.isEmpty && !word.contains("\n") {
                length += word.count + 1
                if length > WatchDelivery.hintsLimit || words.count >= HomePC.hintLimit(speed: homePC.speed) { break }
                words.append(word)
            }
        }
        let weights = on && !HomePC.skipWeights ? HomePC.weightsText(noisy: false) : nil
        receiver.sendWatchPCContext(direct: on, hints: words.joined(separator: "\n"), weights: weights, force: resend)
    }

    /// 時計の区切りが届いたとき、PC に送る（今までどおり）。時計が PC にも直接送っていたら、先に PC の答えを見て、
    /// でき上がっていれば答えを端末の中に置いて取り込みを進める（音声を PC に送り直さない）。まだなら今までどおり送る
    /// （PC は同じ名前の仕事を1つにまとめるので、二重には文字にしない。待ち合わせで答えを受け取る）
    func sendWatchChunkToPC(_ url: URL, hints: [String], viaPC: Bool) {
        guard viaPC, homePC.shouldTry, HomePC.acceptsJobs else {
            homePC.enqueueJob(url, hints: hints)
            return
        }
        let name = url.lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            let peek = await homePC.peekJob(name)
            if case .done(let data) = peek {
                PCResults.save(data, name: name)
                Tally.add("watch.pcFirst")
                processQueue()
            } else {
                homePC.enqueueJob(url, hints: hints)
            }
        }
    }
}

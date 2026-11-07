import Foundation

/// 時計から家の PC に区切りを直接送る（2026-11-07）の、iPhone 側の受け渡し。
/// 時計の送り方は LifeLogWatch/WatchPC.swift、決まりは Shared/Audio/WatchDelivery.swift。
///
/// - 家の中の住所と合言葉は transferUserInfo で時計に送る（時計は合言葉を Keychain に置く）。起動のたびと、設定が変わったとき。
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
    var hintsSentAt = Date.distantPast
}

extension Pipeline {
    /// init から1回だけ呼ぶ
    func setUpWatchDirect() {
        homePC.onWatchSettingsChange = { [weak self] in self?.scheduleWatchPCSync() }
        receiver.onActivated = { [weak self] in self?.syncWatchPC() }
    }

    /// 設定が変わったら、2秒待ってから時計に送る
    func scheduleWatchPCSync() {
        let state = WatchDirectState.shared
        state.pending?.cancel()
        state.pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.syncWatchPC()
        }
    }

    /// 住所と合言葉・オンオフ・ヒントを時計に送る
    func syncWatchPC() {
        let state = WatchDirectState.shared
        let credentials = homePC.watchCredentials()
        if state.sentAddress != credentials.address || state.sentKey != credentials.key {
            receiver.sendWatchPCCredentials(address: credentials.address, key: credentials.key)
            state.sentAddress = credentials.address
            state.sentKey = credentials.key
        }
        refreshWatchPCHints(force: true)
    }

    /// 聞き取りのヒントと重みを時計に送る（10分に1回まで。中身が変わったときだけ送られる）
    func refreshWatchPCHints(force: Bool = false) {
        let state = WatchDirectState.shared
        guard force || Date.now.timeIntervalSince(state.hintsSentAt) >= 600 else { return }
        state.hintsSentAt = .now
        let on = !homePC.watchCredentials().address.isEmpty
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
        receiver.sendWatchPCContext(direct: on, hints: words.joined(separator: "\n"), weights: weights)
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

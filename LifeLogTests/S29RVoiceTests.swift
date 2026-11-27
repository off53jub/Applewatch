import XCTest
@testable import LifeLog

/// s29 の当てる担当（S29RVoice.swift）。埋め込みはすべて作りものの短いベクトル。
final class S29RVoiceTests: XCTestCase {
    private func unit(_ values: [Float]) -> [Float] {
        let n = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return values.map { $0 / n }
    }

    // MARK: 声4 足切り

    func testGateLevels() {
        XCTAssertEqual(S29RGate.level(floor: -60, margin: 30, noisy: false), .quiet)
        XCTAssertEqual(S29RGate.level(floor: -45, margin: 10, noisy: true), .noisy)
        XCTAssertEqual(S29RGate.level(floor: -30, margin: 20, noisy: true), .veryNoisy)
        XCTAssertEqual(S29RGate.level(floor: -50, margin: 4, noisy: true), .veryNoisy)
        XCTAssertEqual(S29RGate.level(floor: nil, margin: nil, noisy: false), .quiet)
    }

    func testGateCutsShortNoisyVoicesButKeepsQuietOnes() {
        // 静かな所の 4 秒は今と同じく作る
        XCTAssertTrue(S29RGate.mayCreate(seconds: 4, share: 0.9, level: .quiet))
        // 騒がしい所の 4 秒は作らない、7 秒なら作る
        XCTAssertFalse(S29RGate.mayCreate(seconds: 4, share: 0.9, level: .noisy))
        XCTAssertTrue(S29RGate.mayCreate(seconds: 7, share: 0.9, level: .noisy))
        // とても騒がしい所は 10 秒から
        XCTAssertFalse(S29RGate.mayCreate(seconds: 9, share: 0.9, level: .veryNoisy))
        XCTAssertTrue(S29RGate.mayCreate(seconds: 10, share: 0.9, level: .veryNoisy))
        // 声の割合が低い（雑音のまとまり）なら長くても作らない。割合が分からなければ長さだけで
        XCTAssertFalse(S29RGate.mayCreate(seconds: 12, share: 0.3, level: .quiet))
        XCTAssertTrue(S29RGate.mayCreate(seconds: 4, share: nil, level: .quiet))
        // 手がかりが何も無いとき（家の PC の後追い）は今と同じ 3 秒
        let none = S29RHints()
        XCTAssertTrue(S29RGate.mayCreate(seconds: 3, share: nil, level: none.level))
    }

    func testVoiceShare() {
        let parts = [S29RSpan(start: 0, end: 2), S29RSpan(start: 4, end: 6)]
        let speech = [S29RSpan(start: 1, end: 5)]
        XCTAssertEqual(S29RGate.voiceShare(parts, speech: speech) ?? -1, 0.5, accuracy: 0.001)
        XCTAssertNil(S29RGate.voiceShare([], speech: speech))
        XCTAssertEqual(S29RGate.voiceShare(parts, speech: []) ?? -1, 0, accuracy: 0.001)
    }

    // MARK: 声8 通りすがりの箱

    func testPasserbyBoxPromotesOnlyFromAnotherChunk() {
        var box = S29RPasserbyBox()
        let voice = unit([1, 0.1, 0])
        XCTAssertTrue(S29RPasserbyBox.shouldBox(seconds: 4))
        XCTAssertFalse(S29RPasserbyBox.shouldBox(seconds: 9))
        box.add(.init(embedding: voice, seconds: 4, audio: "a.m4a", start: 0, end: 4, heard: .now))
        // 同じ区切りの中では人物Nにしない（1 区切りだけの声）
        XCTAssertNil(box.match(unit([1, 0.12, 0]), audio: "a.m4a", accept: 0.4))
        // 別の区切りで近い声 → 箱から出して人物Nにする
        let j = box.match(unit([1, 0.12, 0]), audio: "b.m4a", accept: 0.4)
        XCTAssertEqual(j, 0)
        // 遠い声は当たらない
        XCTAssertNil(box.match(unit([0, 0, 1]), audio: "b.m4a", accept: 0.4))
        XCTAssertLessThan(box.nearest(unit([1, 0.12, 0]), audio: "b.m4a"), 0.01)
        XCTAssertEqual(box.nearest(unit([1, 0.12, 0]), audio: "a.m4a"), 1)
        let entry = box.take(0)
        XCTAssertEqual(entry.seconds, 4)
        XCTAssertTrue(box.entries.isEmpty)
    }

    func testPasserbyBoxForgetsOldAndKeepsLimit() {
        var box = S29RPasserbyBox()
        let old = Date.now.addingTimeInterval(-4 * 86400)
        box.add(.init(embedding: [1, 0], seconds: 3, audio: "x", start: 0, end: 3, heard: old))
        box.add(.init(embedding: [0, 1], seconds: 3, audio: "y", start: 0, end: 3, heard: .now))
        box.prune(now: .now)
        XCTAssertEqual(box.entries.map(\.audio), ["y"])
        for k in 0..<(S29RPasserbyBox.limit + 5) {
            box.add(.init(embedding: [1, 0], seconds: 3, audio: "f\(k)", start: 0, end: 3, heard: .now))
        }
        XCTAssertEqual(box.entries.count, S29RPasserbyBox.limit)
        XCTAssertEqual(box.entries.last?.audio, "f\(S29RPasserbyBox.limit + 4)")
    }

    // MARK: 声7 場の人数でまとめ直す

    func testHeadcountMergesClosestShortIntoLong() {
        let clusters: [String: (center: [Float], seconds: Double)] = [
            "A": (center: unit([1, 0, 0]), seconds: 60),
            "B": (center: unit([0, 1, 0]), seconds: 40),
            "C": (center: unit([1, 0.2, 0]), seconds: 5),   // A の割れ
        ]
        // 2 人の場: C を A へ
        XCTAssertEqual(S29RHeadcount.plan(clusters, limit: 2), ["C": "A"])
        // 3 人なら何もしない
        XCTAssertTrue(S29RHeadcount.plan(clusters, limit: 3).isEmpty)
        // 1 人の場でも、ずっと離れた声（A と B は 1.0 離れている）はまとめない
        let one = S29RHeadcount.plan(clusters, limit: 1)
        XCTAssertEqual(one["C"], "A")
        XCTAssertNil(one["B"])
    }

    func testHeadcountChainsResolveToRoot() {
        let clusters: [String: (center: [Float], seconds: Double)] = [
            "A": (center: unit([1, 0, 0]), seconds: 10),
            "B": (center: unit([1, 0.1, 0]), seconds: 3),
            "C": (center: unit([1, 0.15, 0]), seconds: 20),
        ]
        let plan = S29RHeadcount.plan(clusters, limit: 1)
        XCTAssertEqual(Set(plan.values), ["C"])
        XCTAssertEqual(Set(plan.keys), ["A", "B"])
    }

    func testHeadcountFromClues() {
        XCTAssertEqual(S29RClues.headcount(meetingAttendees: 3, withNow: 1, eventAttendees: [1]), 4)
        XCTAssertEqual(S29RClues.headcount(meetingAttendees: 0, withNow: 1, eventAttendees: [5]), 2)
        XCTAssertEqual(S29RClues.headcount(meetingAttendees: 0, withNow: 0, eventAttendees: [2]), 3)
        // 予定が 2 つ重なっていたら分からない
        XCTAssertNil(S29RClues.headcount(meetingAttendees: 0, withNow: 0, eventAttendees: [2, 3]))
        XCTAssertNil(S29RClues.headcount(meetingAttendees: 0, withNow: 0, eventAttendees: []))
    }

    // MARK: 声10 場面別の見本

    func testSceneTag() {
        XCTAssertEqual(S29RScene.tag(watch: true, noisy: true), "watch.noisy")
        XCTAssertEqual(S29RScene.tag(watch: false, noisy: false), "phone.quiet")
        XCTAssertEqual(S29RScene.tag(watch: nil, noisy: false), "any.quiet")
        var hints = S29RHints()
        XCTAssertNil(hints.scene)   // 騒がしさが分からなければ場面別にしない
        hints.noiseFloor = -40
        hints.noisy = true
        hints.watch = true
        XCTAssertEqual(hints.scene, "watch.noisy")
    }

    func testSceneDistanceComparesSameSceneFirst() {
        // 静かな所の見本 3 つと、騒がしい所の見本 2 つ（騒がしい所では声の聞こえ方が違う）
        let quiet: [Float] = unit([1, 0, 0])
        let noisy: [Float] = unit([0.6, 0.8, 0])
        var bank: [(embedding: [Float], scene: String?)] = []
        for _ in 0..<3 { bank.append((embedding: quiet, scene: "phone.quiet")) }
        for _ in 0..<2 { bank.append((embedding: noisy, scene: "phone.noisy")) }
        let heardNoisy = unit([0.6, 0.8, 0.05])
        let plain = SpeakerLabeler.top3(heardNoisy, bank.map { $0.embedding })
        let byScene = S29RScene.distance(heardNoisy, voices: bank, scene: "phone.noisy")
        XCTAssertLessThan(byScene, plain)
        // 場面が同じ見本が足りなければ今の比べ方
        XCTAssertEqual(S29RScene.distance(heardNoisy, voices: bank, scene: "watch.noisy"), plain, accuracy: 0.0001)
        XCTAssertEqual(S29RScene.distance(heardNoisy, voices: bank, scene: nil), plain, accuracy: 0.0001)
    }

    func testVoiceInfoIsOptionalInPeopleJSON() throws {
        // 前の形（s29VoiceInfo の無い people.json）も読める
        let old = SpeakerLabeler.Person(id: "7", name: "見本の人", context: nil)
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("s29VoiceInfo"))
        let back = try JSONDecoder().decode(SpeakerLabeler.Person.self, from: data)
        XCTAssertNil(back.s29VoiceInfo)
        var p = old
        p.s29VoiceInfo = ["1.000": S29RVoiceInfo(scene: "watch.noisy", seconds: 4, margin: 8)]
        let round = try JSONDecoder().decode(SpeakerLabeler.Person.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round.s29VoiceInfo?["1.000"]?.scene, "watch.noisy")
        XCTAssertNil(S29RVoiceInfo.pruned(["a": S29RVoiceInfo()], keys: ["b"]))
        XCTAssertEqual(S29RVoiceInfo.pruned(["a": S29RVoiceInfo(), "b": S29RVoiceInfo()], keys: ["b"])?.count, 1)
    }

    // MARK: 声11 消す順

    private func items(now: Date) -> [S29RTrimItem] {
        var out: [S29RTrimItem] = []
        // 古い順に 25 個。0〜3 は騒がしい時計の短い声（古い）、4 は様子の分からない声、残りは静かで長い声
        for k in 0..<25 {
            let added = now.addingTimeInterval(Double(k - 25) * 3600)
            var info: S29RVoiceInfo?
            if k < 4 {
                info = S29RVoiceInfo(scene: "watch.noisy", seconds: 2, margin: 5)
            } else if k > 4 {
                info = S29RVoiceInfo(scene: "phone.quiet", seconds: k == 6 ? 1.5 : 9, margin: k == 6 ? 3 : 20)
            }
            out.append(S29RTrimItem(key: "v\(k)", added: added, info: info))
        }
        return out
    }

    func testTrimByAgeDropsOldest() {
        let now = Date.now
        let keep = S29RTrim.keepByAge(items(now: now), max: 20)
        XCTAssertEqual(keep.count, 20)
        for k in 0..<5 { XCTAssertFalse(keep.contains("v\(k)")) }
    }

    func testTrimByQualityDropsShortNoisyButKeepsSceneFloor() {
        let now = Date.now
        let keep = S29RTrim.keepByQuality(items(now: now), max: 20, now: now)
        XCTAssertEqual(keep.count, 20)
        // 短く雑音の多い静かな所の声（v6）は消える
        XCTAssertFalse(keep.contains("v6"))
        // 騒がしい所の見本は、短くても minPerScene（3）まで残る（騒がしい所で当てられなくならないように）
        let noisyKept = (0..<4).filter { keep.contains("v\($0)") }.count
        XCTAssertEqual(noisyKept, S29RTrim.minPerScene)
        // 消す数は同じ 5 個
        XCTAssertEqual(items(now: now).count - keep.count, 5)
    }

    func testTrimScoreAgePenalty() {
        let now = Date.now
        let info = S29RVoiceInfo(scene: "phone.quiet", seconds: 10, margin: 24)
        let fresh = S29RTrim.score(S29RTrimItem(key: "a", added: now, info: info), now: now)
        let old = S29RTrim.score(S29RTrimItem(key: "b", added: now.addingTimeInterval(-60 * 86400), info: info), now: now)
        XCTAssertEqual(fresh, 1, accuracy: 0.001)
        XCTAssertEqual(old, 0.5, accuracy: 0.001)
        XCTAssertEqual(S29RTrim.score(S29RTrimItem(key: "c", added: now, info: nil), now: now), 0.5, accuracy: 0.001)
    }

    // MARK: 声12・声14 交互の鎖

    func testTwoWayNeedsAlternationAndCoverage() {
        var turns: [(speaker: String, start: Double, end: Double)] = []
        for k in 0..<6 { turns.append((speaker: k % 2 == 0 ? "me" : "x", start: Double(k * 10), end: Double(k * 10 + 8))) }
        let pair = S29RChain.twoWay(turns)
        XCTAssertNotNil(pair)
        XCTAssertEqual(Set([pair?.0 ?? "", pair?.1 ?? ""]), ["me", "x"])
        // 入れ替わりが少ない（1 人が話し続けてから相手）は当てはまらない
        let lecture: [(speaker: String, start: Double, end: Double)] = [
            (speaker: "me", start: 0, end: 60), (speaker: "x", start: 61, end: 70),
        ]
        XCTAssertNil(S29RChain.twoWay(lecture))
        // 3 人目が長く話していれば当てはまらない
        var three = turns
        three.append((speaker: "y", start: 100, end: 140))
        XCTAssertNil(S29RChain.twoWay(three))
    }

    func testSelfSolidThreshold() {
        // 登録の声 3 つ、または声 8 つで「固まった」。この区切りの自分も strict 以内で当たっていること
        XCTAssertTrue(S29RChain.selfSolid(pinned: 3, voices: 3, distance: 0.2, strict: 0.3))
        XCTAssertTrue(S29RChain.selfSolid(pinned: 0, voices: 8, distance: 0.2, strict: 0.3))
        XCTAssertFalse(S29RChain.selfSolid(pinned: 2, voices: 7, distance: 0.2, strict: 0.3))
        XCTAssertFalse(S29RChain.selfSolid(pinned: 5, voices: 20, distance: 0.35, strict: 0.3))
        XCTAssertFalse(S29RChain.selfSolid(pinned: 5, voices: 20, distance: nil, strict: 0.3))
    }

    func testChainCarriesOnlyToNextChunkOfSameDevice() {
        let end = Date(timeIntervalSince1970: 1_000_000)
        let state = S29RChain.State(partner: "12", end: end, watch: true)
        XCTAssertEqual(S29RChain.carried(state, start: end.addingTimeInterval(5), watch: true), "12")
        XCTAssertNil(S29RChain.carried(state, start: end.addingTimeInterval(5), watch: false))
        XCTAssertNil(S29RChain.carried(state, start: end.addingTimeInterval(600), watch: true))
        XCTAssertNil(S29RChain.carried(nil, start: end, watch: true))
        XCTAssertNil(S29RChain.carried(state, start: nil, watch: true))
        // 名前のある別の人に当たっているときは変えない。名前の無い声・だれでもないなら近さ accept+0.06 まで
        XCTAssertTrue(S29RChain.shouldAssign(distance: 0.45, accept: 0.40, currentNamed: false))
        XCTAssertFalse(S29RChain.shouldAssign(distance: 0.47, accept: 0.40, currentNamed: false))
        XCTAssertFalse(S29RChain.shouldAssign(distance: 0.2, accept: 0.40, currentNamed: true))
    }

    // MARK: 声13 強い加点

    func testStrongBonusExtraAndFlip() {
        let expected: Set<String> = ["A"]
        let strong: Set<String> = ["A"]
        XCTAssertEqual(S29RBonus.extra("A", expected: expected, strong: strong, base: 0.03), 0.05, accuracy: 0.0001)
        XCTAssertEqual(S29RBonus.extra("B", expected: expected, strong: strong, base: 0.03), 0)
        XCTAssertEqual(S29RBonus.extra("C", expected: [], strong: ["C"], base: 0.03), 0.08, accuracy: 0.0001)
        // まとまり k は B に 0.30、A に 0.34（A は予定の相手で今の加点 0.03 込みの rank 0.31）。強くすると A になる
        let now: [S29RBonus.Pair] = [
            .init(cluster: "k", person: "B", distance: 0.30, rank: 0.30),
            .init(cluster: "k", person: "A", distance: 0.34, rank: 0.31),
        ]
        var strongPairs = now
        strongPairs[1].rank -= S29RBonus.extra("A", expected: expected, strong: strong, base: 0.03)
        let before = S29RBonus.greedy(now, strict: 0.3)
        let after = S29RBonus.greedy(strongPairs, strict: 0.3)
        XCTAssertEqual(before["k"], "B")
        XCTAssertEqual(after["k"], "A")
        XCTAssertEqual(S29RBonus.differences(before, after), 1)
    }

    func testGreedyKeepsOnePersonPerClusterUnlessClose() {
        let pairs: [S29RBonus.Pair] = [
            .init(cluster: "k1", person: "A", distance: 0.2, rank: 0.2),
            .init(cluster: "k2", person: "A", distance: 0.35, rank: 0.35),
            .init(cluster: "k2", person: "B", distance: 0.38, rank: 0.38),
        ]
        let out = S29RBonus.greedy(pairs, strict: 0.3)
        XCTAssertEqual(out["k1"], "A")
        XCTAssertEqual(out["k2"], "B")
    }

    func testStrongCluesOnlyWhenClear() {
        XCTAssertEqual(S29RClues.strong(meeting: [], withNow: [], singleEventIDs: ["5"]), ["5"])
        XCTAssertEqual(S29RClues.strong(meeting: [], withNow: [], singleEventIDs: ["5", "6"]), [])
        XCTAssertEqual(S29RClues.strong(meeting: ["1", "2"], withNow: ["3"], singleEventIDs: []), ["1", "2", "3"])
    }

    // MARK: 声23 「今から A さんと」を読む

    func testWithNowReadsJSONFromDefaults() throws {
        let suite = "s29r-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(S29RWithNow.ids(from: start, to: start.addingTimeInterval(300), defaults: defaults).isEmpty)
        // 文字列で書かれたもの
        defaults.set("{\"ids\":[\"12\",\"me\",\"\"],\"start\":2000000,\"end\":2003600}", forKey: S29RWithNow.key)
        XCTAssertEqual(S29RWithNow.ids(from: start, to: start.addingTimeInterval(300), defaults: defaults), ["12"])
        // 時間の外
        XCTAssertTrue(S29RWithNow.ids(from: start.addingTimeInterval(7200), to: start.addingTimeInterval(7500), defaults: defaults).isEmpty)
        // 区切りの終わりだけが重なるときも入れる
        XCTAssertEqual(S29RWithNow.ids(from: start.addingTimeInterval(-200), to: start.addingTimeInterval(100), defaults: defaults), ["12"])
        // Data で書かれたもの
        let data = try JSONEncoder().encode(S29RWithNow(ids: ["4", "9"], start: 2_000_000, end: 2_000_600))
        defaults.set(data, forKey: S29RWithNow.key)
        XCTAssertEqual(S29RWithNow.ids(from: start, to: start.addingTimeInterval(300), defaults: defaults), ["4", "9"])
        // 壊れたもの・終わりが始まりより前のものは読まない
        defaults.set("{\"ids\":[\"4\"]}", forKey: S29RWithNow.key)
        XCTAssertNil(S29RWithNow.read(defaults))
        defaults.set("{\"ids\":[\"4\"],\"start\":10,\"end\":5}", forKey: S29RWithNow.key)
        XCTAssertNil(S29RWithNow.read(defaults))
    }

    // MARK: 既定と数え

    func testDefaults() throws {
        let suite = "s29r-flags-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(S29RFlags.isOn(S29RFlags.gateKey, default: true, defaults: defaults))
        XCTAssertFalse(S29RFlags.isOn(S29RFlags.chainKey, default: false, defaults: defaults))
        defaults.set(false, forKey: S29RFlags.gateKey)
        XCTAssertFalse(S29RFlags.isOn(S29RFlags.gateKey, default: true, defaults: defaults))
    }

    func testReportRows() {
        XCTAssertTrue(S29RReport.rows([:]).isEmpty)
        let rows = S29RReport.rows(["s29r.gate.cut": 3, "s29r.box.in": 5, "s29r.chain.would": 2])
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].value.contains("3"))
    }
}

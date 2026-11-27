import UIKit
import XCTest
@testable import LifeLog

/// s35（S35PhotoRules.swift・2026-11-28・K35）: 写真の縮め方・枚数の上限・まとめへの割り当て・体の形・送る順・
/// features が無いときは送らない・送れなかったときの止め方・返事の読み・待ち方・送り直しの決め方・作り直しを待つ長さ。
/// 写真は作りもの（その場で描いた無地の絵か、JPEG の頭だけのバイト）。
@MainActor
final class S35PhotoTests: XCTestCase {
    private struct Down: Error {}

    private let idA = "11111111-2222-3333-4444-555555555555"
    private let idB = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    /// JPEG の頭だけの作りもの（番号ごとに中身が違う）
    private func fakeJPEG(_ n: Int) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0, UInt8(n % 256), 0xFF, 0xD9])
    }

    private func picture(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func decoded(_ data: Data) -> S35PhotoBody? {
        try? JSONDecoder().decode(S35PhotoBody.self, from: data)
    }

    private func entry(_ id: String, _ day: String) -> WorkDigest.Entry {
        WorkDigest.Entry(id: id, day: day, text: "見本のまとめ（作りもの）", source: .photo)
    }

    // MARK: 縮め方

    func testTargetSizeKeepsLongSideWithin2000() {
        XCTAssertEqual(S35PhotoRules.targetSize(CGSize(width: 4032, height: 3024)), CGSize(width: 2000, height: 1500))
        XCTAssertEqual(S35PhotoRules.targetSize(CGSize(width: 1179, height: 2556)), CGSize(width: 922, height: 2000), "縦長は高さを 2000 に")
        XCTAssertEqual(S35PhotoRules.targetSize(CGSize(width: 1200, height: 800)), CGSize(width: 1200, height: 800), "小さいものは大きくしない")
        XCTAssertEqual(S35PhotoRules.targetSize(CGSize(width: 2000, height: 10)), CGSize(width: 2000, height: 10), "ちょうど 2000 はそのまま")
        XCTAssertNil(S35PhotoRules.targetSize(CGSize(width: 0, height: 100)))
        XCTAssertEqual(S35PhotoRules.maxSide, 2000)
        XCTAssertEqual(S35PhotoRules.quality, 0.75)
    }

    func testShrinkMakesJPEGWithinLimits() {
        let big: UIImage = picture(CGSize(width: 3000, height: 1500))
        guard let out = S35PhotoRules.shrink(big), let back = UIImage(data: out) else {
            return XCTFail("縮められませんでした")
        }
        XCTAssertTrue(S35PhotoRules.isJPEG(out), "JPEG の頭（FF D8）で始まる")
        XCTAssertLessThanOrEqual(out.count, S35PhotoRules.maxBytes)
        XCTAssertEqual(back.size.width * back.scale, 2000)
        XCTAssertEqual(back.size.height * back.scale, 1000)
        let small: UIImage = picture(CGSize(width: 800, height: 600))
        let kept: UIImage? = S35PhotoRules.shrink(small).flatMap { UIImage(data: $0) }
        let width: CGFloat = (kept?.size.width ?? 0) * (kept?.scale ?? 0)
        XCTAssertEqual(width, 800, "2000 より小さければ大きさはそのまま")
    }

    // MARK: 枚数の上限・割り当て

    func testCappedKeepsTwelveValidJPEGsInOrder() {
        let many: [Data] = (0..<15).map(fakeJPEG)
        let kept: [Data] = S35PhotoRules.capped(many)
        XCTAssertEqual(kept.count, 12)
        XCTAssertEqual(kept.first, fakeJPEG(0))
        XCTAssertEqual(kept.last, fakeJPEG(11))
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        var huge = Data([0xFF, 0xD8])
        huge.append(Data(count: S35PhotoRules.maxBytes))
        XCTAssertEqual(S35PhotoRules.capped([png, fakeJPEG(1), huge]), [fakeJPEG(1)], "JPEG でないもの・3MB を超えるものは送らない")
        let job = S35PhotoJob(id: idA, day: "2026-11-28", photos: many)
        XCTAssertEqual(job.count, 12)
        XCTAssertEqual(job.pieces.map(\.index), Array(0..<12))
    }

    func testJobsAttachPhotosToEntries() {
        let a = entry(idA, "2026-11-28")
        let b = entry(idB, "2026-11-27")
        let loose: [Data] = [fakeJPEG(1), fakeJPEG(2)]
        let one = S35PhotoRules.jobs(for: [a, b], byID: [:], loose: loose)
        XCTAssertEqual(one.map(\.id), [idA], "取り込む画面の写真は、送る最初のまとめにだけ付ける")
        XCTAssertEqual(one.first?.day, "2026-11-28")
        XCTAssertEqual(one.first?.count, 2)
        let two = S35PhotoRules.jobs(for: [a, b], byID: [idB: [fakeJPEG(3)], "ほかの id": [fakeJPEG(4)]], loose: [])
        XCTAssertEqual(two.map(\.id), [idB], "組の写真はその id に。送らないまとめの写真は入れない")
        XCTAssertTrue(S35PhotoRules.jobs(for: [a], byID: [:], loose: []).isEmpty, "写真が無ければ送るものは無い")
    }

    // MARK: 体の形

    func testBodyShapeIsK35() throws {
        let jpeg = fakeJPEG(7)
        let data = try XCTUnwrap(S35PhotoRules.body(id: idA, day: "2026-11-28", index: 1, count: 3, jpeg: jpeg))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(raw.keys), ["id", "day", "index", "count", "jpeg_b64"])
        let body = try XCTUnwrap(decoded(data))
        XCTAssertEqual(body.id, idA)
        XCTAssertEqual(body.day, "2026-11-28")
        XCTAssertEqual(body.index, 1)
        XCTAssertEqual(body.count, 3)
        XCTAssertEqual(body.jpegB64.flatMap { Data(base64Encoded: $0) }, jpeg)
        XCTAssertNil(S35PhotoRules.body(id: idA, day: "2026-11-28", index: 3, count: 3, jpeg: jpeg), "index は count 未満")
        XCTAssertNil(S35PhotoRules.body(id: idA, day: "2026-11-28", index: 0, count: 13, jpeg: jpeg), "count は 12 まで")
        XCTAssertNil(S35PhotoRules.body(id: idA, day: "2026-11-28", index: 0, count: 1, jpeg: Data([1, 2, 3])), "JPEG でなければ作らない")
    }

    // MARK: 送る順・送らないとき・止めるとき

    func testSendGoesInOrderOneByOne() async {
        let jobs: [S35PhotoJob] = [
            S35PhotoJob(id: idA, day: "2026-11-28", photos: [fakeJPEG(0), fakeJPEG(1), fakeJPEG(2)]),
            S35PhotoJob(id: idB, day: "2026-11-27", photos: [fakeJPEG(3), fakeJPEG(4)]),
        ]
        var sent: [S35PhotoBody] = []
        let outcome = await S35PhotoSend.run(jobs, features: ["workpush", "workphoto"]) { body in
            if let b = self.decoded(body) { sent.append(b) }
            let have: Int = sent.filter { $0.id == sent.last?.id }.count
            let total: Int = sent.last?.count ?? 0
            let run: String = have >= total ? "started" : "waiting"
            return Data(#"{"ok":true,"have":\#(have),"count":\#(total),"run":"\#(run)"}"#.utf8)
        }
        let order: [String] = sent.map { ($0.id ?? "") + "#" + String($0.index ?? -1) }
        XCTAssertEqual(order, [idA + "#0", idA + "#1", idA + "#2", idB + "#0", idB + "#1"], "まとめの順・番号の順に 1 枚ずつ")
        XCTAssertEqual(sent.map { $0.count ?? 0 }, [3, 3, 3, 2, 2])
        XCTAssertEqual(outcome.complete, [idA, idB])
        XCTAssertEqual(outcome.done[idA], [0, 1, 2])
        XCTAssertEqual(outcome.run, "started", "最後の返事の run")
        XCTAssertFalse(outcome.skipped)
    }

    func testNoFeatureMeansNoSend() async {
        let jobs = [S35PhotoJob(id: idA, day: "2026-11-28", photos: [fakeJPEG(0)])]
        var calls = 0
        let none = await S35PhotoSend.run(jobs, features: ["workpush"]) { _ in
            calls += 1
            return Data()
        }
        let empty = await S35PhotoSend.run(jobs, features: []) { _ in
            calls += 1
            return Data()
        }
        XCTAssertEqual(calls, 0, "features に workphoto が無ければ 1 枚も送らない")
        XCTAssertTrue(none.skipped)
        XCTAssertTrue(empty.skipped)
        XCTAssertNil(none.run)
        XCTAssertFalse(S35PhotoRules.offered(["workpush"]))
        XCTAssertTrue(S35PhotoRules.offered(["workphoto"]))
    }

    func testSendStopsAtFirstFailure() async {
        let jobs: [S35PhotoJob] = [
            S35PhotoJob(id: idA, day: "2026-11-28", photos: [fakeJPEG(0), fakeJPEG(1)]),
            S35PhotoJob(id: idB, day: "2026-11-28", photos: [fakeJPEG(2)]),
        ]
        var calls = 0
        let outcome = await S35PhotoSend.run(jobs, features: ["workphoto"]) { _ in
            calls += 1
            if calls == 2 { throw Down() }
            return Data(#"{"ok":true,"have":1,"count":2,"run":"waiting"}"#.utf8)
        }
        XCTAssertEqual(calls, 2, "つながらなくなったら、そこで止める")
        XCTAssertEqual(outcome.done[idA], [0])
        XCTAssertEqual(outcome.failed, [idA, idB])
        XCTAssertTrue(outcome.complete.isEmpty)
        XCTAssertFalse(outcome.off)

        let off = await S35PhotoSend.run(jobs, features: ["workphoto"]) { _ in
            Data(#"{"ok":false,"have":0,"count":0,"run":"off"}"#.utf8)
        }
        XCTAssertTrue(off.off, "止めてあれば off（送り直さない）")
        XCTAssertEqual(off.failed, [idA, idB])
    }

    // MARK: 返事・待ち方

    func testReplyReadsLooseShapes() {
        XCTAssertEqual(S35PhotoRules.reply(Data(#"{"ok":true,"have":2,"count":3,"run":"waiting"}"#.utf8)),
                       S35PhotoReply(ok: true, have: 2, count: 3, run: "waiting"))
        XCTAssertEqual(S35PhotoRules.reply(Data(#"{"ok":true,"have":"x","run":"started","extra":1}"#.utf8)),
                       S35PhotoReply(ok: true, have: nil, count: nil, run: "started"), "形の違う欄だけ nil")
        XCTAssertNil(S35PhotoRules.reply(Data("壊れた".utf8)))
        XCTAssertNotNil(try? JSONDecoder().decode(S35PhotoPending.self, from: Data("{}".utf8)), "覚えの欄はどれも無くてよい")
    }

    func testWatchPlanAfterPhotos() {
        let posted = Date(timeIntervalSince1970: 1_000)
        let photos = Date(timeIntervalSince1970: 1_030)
        let started = S35PhotoRules.watchPlan(digestRun: "started", photoRun: "started", postedAt: posted, photosAt: photos)
        XCTAssertEqual(started.postedAt, photos)
        XCTAssertTrue(started.needStartAfter, "写真がそろって新しく始まったら、その回が終わるまで待つ")
        let already = S35PhotoRules.watchPlan(digestRun: "started", photoRun: "already", postedAt: posted, photosAt: photos)
        XCTAssertEqual(already.postedAt, posted)
        XCTAssertFalse(already.needStartAfter, "写真のときに走っていれば、今までどおり")
        let none = S35PhotoRules.watchPlan(digestRun: "already", photoRun: nil, postedAt: posted, photosAt: photos)
        XCTAssertEqual(none.postedAt, posted)
        XCTAssertTrue(none.needStartAfter, "写真を送らなければ POST /work/digest の返事のまま")
    }

    func testPollLimitIsSixMinutesAndTextFollowsIt() {
        XCTAssertEqual(S30WRules.pollLimit, 360)
        XCTAssertEqual(S30WRules.pollMinutes, 6)
        let at = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(S30WRules.bandTitle(.late(at)), "作り直しが 6 分で終わりませんでした")
        XCTAssertTrue(S30WRules.bandDetail(.rebuilding(at), clock: "10:00").contains("6 分まで"))
        XCTAssertNotNil(S30WRules.visible(.rebuilding(at), now: at.addingTimeInterval(400)), "6 分待つあいだは帯を出しておく")
    }

    // MARK: 送り直しの決め方

    func testRetryPlanOnlySameDayOnce() {
        let opened = Date(timeIntervalSince1970: 10_000)
        let before = opened.addingTimeInterval(-600)
        let rows: [S35PhotoPending] = [
            S35PhotoPending(id: idA, day: "2026-11-28", count: 3, madeOn: "2026-11-28", madeAt: before, retried: false, done: [0]),
            S35PhotoPending(id: idB, day: "2026-11-27", count: 2, madeOn: "2026-11-27", madeAt: before, retried: false, done: []),
            S35PhotoPending(id: "22222222-2222-2222-2222-222222222222", day: "2026-11-28", count: 1, madeOn: "2026-11-28",
                            madeAt: before, retried: true, done: []),
            S35PhotoPending(id: "../x", day: "2026-11-28", count: 1, madeOn: "2026-11-28", madeAt: before, retried: false, done: []),
            S35PhotoPending(id: "33333333-3333-3333-3333-333333333333", day: "2026-11-28", count: 1, madeOn: "2026-11-28",
                            madeAt: opened.addingTimeInterval(5), retried: false, done: []),
        ]
        let plan = S35PhotoRules.retryPlan(rows, today: "2026-11-28", openedAt: opened)
        XCTAssertEqual(plan.send.compactMap(\.id), [idA], "その日の分で、まだ送り直していないものだけ")
        XCTAssertEqual(plan.drop.compactMap(\.id), [idB, "22222222-2222-2222-2222-222222222222", "../x"], "ほかの日・送り直し済み・形の壊れたものは捨てる")
        XCTAssertEqual(plan.wait.compactMap(\.id), ["33333333-3333-3333-3333-333333333333"], "開いたあとに覚えたものは次に開くまで待つ")
    }
}

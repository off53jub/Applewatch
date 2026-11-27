import Foundation
import UIKit

// s35（2026-11-28）仕事のまとめの写真そのものも家の PC へ（取り決め K35。名前と形を変えない）。動きは S35PhotoBook.swift。
// - iPhone の中の文字の読み取り（Vision）は、画面の折り返しで項目がちぎれる。そこで、今までどおり Vision の文を
//   先に POST /work/digest（K30-2）で送ったあと、家の PC の features に "workphoto" があれば、同じ id で
//   写真も POST /work/photo に 1 枚ずつ送る。母艦の側で Claude が書き起こす（PC が読めなくても今の形は残る）。
// - 送る形: 長い辺を 2000px 以下に縮めた JPEG（質 0.75）。1 回のまとめで 12 枚まで。
// - 体: {"id": まとめの id, "day": "YYYY-MM-DD", "index": 0 から, "count": 枚数, "jpeg_b64": "..."}
// - 返事: {"ok": true, "have": そろった枚数, "count": n, "run": "started"|"already"|"off"|"waiting"}

/// POST /work/photo の 1 枚の体（K35）
struct S35PhotoBody: Codable, Equatable, Sendable {
    var id: String?
    var day: String?
    var index: Int?
    var count: Int?
    var jpegB64: String?

    enum CodingKeys: String, CodingKey { case id, day, index, count, jpegB64 = "jpeg_b64" }
}

/// POST /work/photo の返事（形が違う欄は nil にして、ほかは読む）
struct S35PhotoReply: Decodable, Equatable, Sendable {
    var ok: Bool?
    var have: Int?
    var count: Int?
    var run: String?

    enum CodingKeys: String, CodingKey { case ok, have, count, run }

    init(ok: Bool? = nil, have: Int? = nil, count: Int? = nil, run: String? = nil) {
        self.ok = ok
        self.have = have
        self.count = count
        self.run = run
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.s27w(.ok)
        have = c.s27w(.have)
        count = c.s27w(.count)
        run = c.s27w(.run)
    }
}

/// 写真 1 枚（番号は 0 から。まとめの中の順）
struct S35PhotoPiece: Equatable, Sendable {
    var index: Int
    var jpeg: Data
}

/// 1 つのまとめ（id）に付ける写真
struct S35PhotoJob: Equatable, Sendable {
    var id: String
    var day: String
    var count: Int
    var pieces: [S35PhotoPiece]

    /// 縮めた JPEG の並びから（12 枚まで・番号は並びの順）
    init(id: String, day: String, photos: [Data]) {
        let kept: [Data] = S35PhotoRules.capped(photos)
        self.id = id
        self.day = day
        self.count = kept.count
        self.pieces = kept.enumerated().map { S35PhotoPiece(index: $0.offset, jpeg: $0.element) }
    }

    /// 送り直し（端末の一時ファイルから読んだ分だけ。count は前のまま）
    init(id: String, day: String, count: Int, pieces: [S35PhotoPiece]) {
        self.id = id
        self.day = day
        self.count = count
        self.pieces = pieces.sorted { $0.index < $1.index }
    }
}

/// 送れなかった写真の覚え（端末の UserDefaults。写真そのものは一時ファイルで、次に開いたときに 1 回だけ送り直したら消す）
struct S35PhotoPending: Codable, Equatable, Sendable {
    var id: String?
    var day: String?
    var count: Int?
    /// 送ろうとした日（端末の日付。その日のうちだけ送り直す）
    var madeOn: String?
    var madeAt: Date?
    var retried: Bool?
    /// 届いた番号（送り直しでは送らない）
    var done: [Int]?
}

/// 送った結果
struct S35PhotoOutcome: Equatable, Sendable {
    /// 最後に届いた返事の run（1 枚も届かなければ nil）
    var run: String?
    /// 届いた番号（id ごと）
    var done: [String: [Int]] = [:]
    /// 全部届いた id
    var complete: [String] = []
    /// 送れなかった id（つながらない・断られた）
    var failed: [String] = []
    /// 家の PC が止めてある（ok false）。送り直さない
    var off = false
    /// features に workphoto が無いなどで、1 枚も送らなかった
    var skipped = false
}

enum S35PhotoRules {
    /// 家の PC の features の名前（K35）
    static let feature = "workphoto"
    /// 長い辺（px）
    static let maxSide: CGFloat = 2000
    /// JPEG の質（大きすぎたときだけ下げる）
    static let quality: CGFloat = 0.75
    static let fallbackQualities: [CGFloat] = [0.6, 0.45]
    /// 1 回のまとめの枚数
    static let limit = 12
    /// 1 枚の大きさの上限（家の PC と同じ 3MB）
    static let maxBytes = 3 * 1024 * 1024
    /// 1 枚を送るのを待つ長さ（秒・仮）
    static let postTimeout: TimeInterval = 60

    static func offered(_ features: Set<String>) -> Bool { features.contains(feature) }

    /// まとめの id の形（UUID。一時ファイルの置き場の名前にも使う）
    nonisolated static func isUUID(_ id: String?) -> Bool {
        guard let id else { return false }
        return UUID(uuidString: id) != nil
    }

    /// 縮めたあとの大きさ（px）。長い辺が maxSide を超えるときだけ縮める（大きくはしない）
    nonisolated static func targetSize(_ pixels: CGSize, maxSide: CGFloat = maxSide) -> CGSize? {
        let w: CGFloat = pixels.width
        let h: CGFloat = pixels.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
        let longest: CGFloat = max(w, h)
        let scale: CGFloat = longest > maxSide ? maxSide / longest : 1
        let tw: CGFloat = max(1, floor(w * scale))
        let th: CGFloat = max(1, floor(h * scale))
        return CGSize(width: tw, height: th)
    }

    /// JPEG の頭（FF D8）で始まるか
    nonisolated static func isJPEG(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }

    /// 家の PC に送る JPEG に縮める（長い辺 2000px 以下・質 0.75。3MB を超えるときだけ質を下げる）。
    /// nonisolated の async なので、画面の流れの外で縮める
    nonisolated static func jpeg(_ image: UIImage) async -> Data? {
        shrink(image)
    }

    nonisolated static func shrink(_ image: UIImage) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard let target = targetSize(pixels) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized: UIImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        let qualities: [CGFloat] = [quality] + fallbackQualities
        for q in qualities {
            if let out = resized.jpegData(compressionQuality: q), isJPEG(out), out.count <= maxBytes { return out }
        }
        return nil
    }

    /// 送れる形のものだけ・12 枚まで（並びの順のまま）
    nonisolated static func capped(_ photos: [Data]) -> [Data] {
        let ok: [Data] = photos.filter { isJPEG($0) && $0.count <= maxBytes }
        return Array(ok.prefix(limit))
    }

    /// 送るまとめ（送る順）に写真を割り当てる。byID はそのまとめの写真（S34A の写真から拾った組）。
    /// loose は取り込む画面の写真で、byID の無い最初のまとめに付ける（何日分かに分けたときは最初の 1 件・仮）。
    /// 写真の無いまとめ・送らないまとめの写真は入れない
    @MainActor
    static func jobs(for entries: [WorkDigest.Entry], byID: [String: [Data]], loose: [Data]) -> [S35PhotoJob] {
        var out: [S35PhotoJob] = []
        var looseLeft: [Data] = loose
        for e in entries {
            var photos: [Data] = byID[e.id] ?? []
            if photos.isEmpty, !looseLeft.isEmpty {
                photos = looseLeft
                looseLeft = []
            }
            let job = S35PhotoJob(id: e.id, day: e.day, photos: photos)
            if job.count > 0 { out.append(job) }
        }
        return out
    }

    /// 1 枚の体（K35 の形そのまま）
    nonisolated static func body(id: String, day: String, index: Int, count: Int, jpeg: Data) -> Data? {
        guard count >= 1, count <= limit, index >= 0, index < count, isJPEG(jpeg), jpeg.count <= maxBytes else { return nil }
        let row = S35PhotoBody(id: id, day: day, index: index, count: count, jpegB64: jpeg.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(row)
    }

    static func reply(_ data: Data) -> S35PhotoReply? {
        try? JSONDecoder().decode(S35PhotoReply.self, from: data)
    }

    /// 写真を送ったあとの待ち方（GET /work/run の見方は今のまま）。写真がそろって作り直しが新しく始まったときは、
    /// 写真を送り始めたあとに始まった回が終わるまで待つ。そうでなければ POST /work/digest の返事のまま
    static func watchPlan(digestRun: String?, photoRun: String?, postedAt: Date, photosAt: Date) -> (postedAt: Date, needStartAfter: Bool) {
        if photoRun == "started" { return (photosAt, true) }
        return (postedAt, digestRun == "already")
    }

    /// 次に開いたときの送り直し: その日（madeOn が今日）で、まだ送り直していなくて、開く前に覚えたものだけを送る。
    /// ほかの日・送り直し済み・形の壊れたものは捨てる（写真の一時ファイルも消す）。開いたあとに覚えたものは次まで待つ
    static func retryPlan(_ pending: [S35PhotoPending], today: String, openedAt: Date)
        -> (send: [S35PhotoPending], drop: [S35PhotoPending], wait: [S35PhotoPending]) {
        var send: [S35PhotoPending] = []
        var drop: [S35PhotoPending] = []
        var wait: [S35PhotoPending] = []
        for p in pending {
            let count: Int = p.count ?? 0
            let shaped: Bool = S35PhotoRules.isUUID(p.id) && p.day != nil && count >= 1 && count <= limit
            guard shaped, p.madeOn == today, p.retried != true else {
                drop.append(p)
                continue
            }
            if let at = p.madeAt, at >= openedAt {
                wait.append(p)
            } else {
                send.append(p)
            }
        }
        return (send, drop, wait)
    }
}

/// 写真を 1 枚ずつ順に送る（まとめの順・番号の順）。post は体 1 つを送って返事を返す（家の PC の POST /work/photo。
/// 試しでは作りもの）。つながらない・断られたら、そこで止める（残りは送れなかった分）
@MainActor
enum S35PhotoSend {
    static func run(_ jobs: [S35PhotoJob], features: Set<String>,
                    post: (Data) async throws -> Data) async -> S35PhotoOutcome {
        var outcome = S35PhotoOutcome()
        guard S35PhotoRules.offered(features), !jobs.isEmpty else {
            outcome.skipped = true
            return outcome
        }
        var stopped = false
        for job in jobs {
            if stopped {
                outcome.failed.append(job.id)
                continue
            }
            var got: [Int] = []
            for piece in job.pieces {
                guard let body = S35PhotoRules.body(id: job.id, day: job.day, index: piece.index, count: job.count, jpeg: piece.jpeg) else {
                    continue
                }
                guard let data = try? await post(body), let reply = S35PhotoRules.reply(data) else {
                    stopped = true
                    break
                }
                if reply.ok != true {
                    outcome.off = reply.run == "off"
                    stopped = true
                    break
                }
                got.append(piece.index)
                outcome.run = reply.run
            }
            outcome.done[job.id] = got
            if stopped {
                outcome.failed.append(job.id)
            } else {
                outcome.complete.append(job.id)
            }
        }
        return outcome
    }
}

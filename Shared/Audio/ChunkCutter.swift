import Foundation

/// 録音を区切る位置を決める（iPhone と時計の両方で使う）。
///
/// 5分ちょうどで切ると、言いかけの言葉が2つの区切りに分かれて、両側で崩れた文字になる。
/// そこで5分たったら、声の途切れた瞬間（0.2秒以上静か）を待ってから切る。
/// 20秒待っても静かにならなければ（ずっと誰かが話しているなど）、そこで切る。
/// 「静か」は、その区切りのいちばん静かなあたり（小さいほうから2割の大きさ）より 6dB 以内とする。
struct ChunkCutter {
    /// これより短い区切りは作らない
    static let target: TimeInterval = 300
    /// 静かな瞬間をこれだけ待つ
    static let maxExtra: TimeInterval = 20
    /// 大きさを測る単位（秒）
    private static let block: TimeInterval = 0.1

    /// いまの区切りの長さ（秒）
    private(set) var seconds: TimeInterval = 0
    /// 0.1秒ごとの大きさ（dB）
    private var levels: [Float] = []
    private var floor: Float?
    private var sum: Float = 0
    private var count = 0
    private var quietBlocks = 0

    mutating func reset() {
        seconds = 0
        levels.removeAll(keepingCapacity: true)
        floor = nil
        sum = 0
        count = 0
        quietBlocks = 0
    }

    /// 音を受け取る。この音のあとで切るなら true。
    mutating func feed(_ samples: UnsafePointer<Float>, count frames: Int, rate: Double) -> Bool {
        guard frames > 0, rate > 0 else { return false }
        let blockSize = max(1, Int(rate * Self.block))
        var cut = false
        for i in 0..<frames {
            sum += samples[i] * samples[i]
            count += 1
            guard count >= blockSize else { continue }
            let db = 10 * log10(max(sum / Float(count), 1e-12))
            sum = 0
            count = 0
            levels.append(db)
            seconds += Double(blockSize) / rate
            guard seconds >= Self.target else { continue }
            if floor == nil {
                let sorted = levels.sorted()
                floor = sorted[sorted.count / 5]
            }
            quietBlocks = db <= (floor ?? db) + 6 ? quietBlocks + 1 : 0
            if quietBlocks >= 2 || seconds >= Self.target + Self.maxExtra { cut = true }
        }
        return cut
    }
}

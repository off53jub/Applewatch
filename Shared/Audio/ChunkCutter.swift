import Foundation

/// 録音を区切る位置を決める（iPhone と時計の両方で使う）。
///
/// ちょうどの長さで切ると、言いかけの言葉が2つの区切りに分かれて、両側で崩れた文字になる。
/// そこで声の途切れた瞬間を待ってから切る。
/// 「静か」は、その区切りのいちばん静かなあたり（小さいほうから2割の大きさ）より 6dB 以内とする。
///
/// 区切りの長さは設定で選ぶ（2026-11-07。docs/v8-latency.md の 4）。
/// - 短め（初め）: 45秒を過ぎたら、0.5秒続けて静かな所で切る。120秒を過ぎたら 0.2秒静かな所で切り、
///   それから20秒待っても静かにならなければ（ずっと誰かが話しているなど）、そこで切る。文字になるまでが短くなる。
/// - ふつう: 今までどおり。5分たったら 0.2秒静かな所で切り、20秒待っても静かにならなければそこで切る。
struct ChunkCutter {
    /// 区切りの長さの設定
    enum Length: String, CaseIterable, Sendable {
        /// 長くても2分
        case short
        /// 長くても5分（今までどおり）
        case normal

        /// これより短い区切りは作らない
        var minimum: TimeInterval { self == .short ? 45 : 300 }
        /// これを過ぎたら、短い静けさでも切る（そこから maxExtra 待っても静かにならなければ切る）
        var maximum: TimeInterval { self == .short ? 120 : 300 }
        /// ふつうの区切りの長さの目安（区切りの数で決めているものを、長さに合わせて直すのに使う）
        var typical: TimeInterval { self == .short ? 75 : 300 }
        /// 設定の画面の言い方
        var label: String { self == .short ? "短め（2分まで）" : "ふつう（5分まで）" }
    }

    /// 設定の名前（iPhone と時計の UserDefaults。時計には iPhone から applicationContext で届く）
    static let lengthKey = "chunkLength"

    /// いまの設定（初めは短め）
    static var length: Length {
        get { Length(rawValue: UserDefaults.standard.string(forKey: lengthKey) ?? "") ?? .short }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lengthKey) }
    }

    /// 静かな瞬間をこれだけ待つ
    static let maxExtra: TimeInterval = 20
    /// いちばん長い区切り（いまの設定で）
    static var longest: TimeInterval { length.maximum + maxExtra }

    /// 5分の区切りで数えていた数を、いまの区切りの長さでの数に直す（同じくらいの時間になるように）。
    /// 例: 5分の区切り3つ（15分）は、短めなら 12 個
    static func scaled(_ countAtFiveMinutes: Int, length: Length = ChunkCutter.length) -> Int {
        guard length != .normal else { return countAtFiveMinutes }
        return max(countAtFiveMinutes, Int((Double(countAtFiveMinutes) * 300 / length.typical).rounded(.up)))
    }

    /// 大きさを測る単位（秒）
    private static let block: TimeInterval = 0.1
    /// 上限より前に切るときの静けさ（0.1秒の数。0.5秒）。話の切れ目らしい所で切る
    private static let earlyQuiet = 5
    /// 上限を過ぎてから切るときの静けさ（0.2秒）
    private static let lateQuiet = 2

    /// この区切りで使う長さ（区切りごとに、そのときの設定を読む）
    private(set) var length: Length
    /// いまの区切りの長さ（秒）
    private(set) var seconds: TimeInterval = 0
    /// 0.1秒ごとの大きさ（dB）
    private var levels: [Float] = []
    private var floor: Float?
    private var sum: Float = 0
    private var count = 0
    private var quietBlocks = 0

    init(length: Length = ChunkCutter.length) {
        self.length = length
    }

    /// 次の区切りの始まり。length を渡さなければ、そのときの設定を読み直す（設定を変えたら次の区切りから効く）
    mutating func reset(length: Length? = nil) {
        self.length = length ?? Self.length
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
            guard seconds >= length.minimum else { continue }
            if floor == nil {
                let sorted = levels.sorted()
                floor = sorted[sorted.count / 5]
            }
            quietBlocks = db <= (floor ?? db) + 6 ? quietBlocks + 1 : 0
            let needed = seconds < length.maximum ? Self.earlyQuiet : Self.lateQuiet
            if quietBlocks >= needed || seconds >= length.maximum + Self.maxExtra { cut = true }
        }
        return cut
    }
}

import Foundation

/// 時計の区切りに「声らしい音」があったかを、安く数える（2026-11-16。docs/v20-watch-silence.md）。
///
/// 時計は音の大きさだけで書くかを決めている（SilenceGate）ので、物音・衣ずれ・水の音のような声の無い区切りも送っていた。
/// 家の PC の声の見つけ方（Silero VAD）で声が 0 秒の区切りは、11/14〜16 で 20〜54%。
///
/// 声（母音）は、決まった高さの音とその倍音でできているので、電話の帯域（300〜3400Hz）の中の音の強さが
/// 一部の高さに集まる。物音や雑音は、帯域じゅうにばらける。そこで、16kHz の音を 1024 こま（64ms）ずつ見て、
/// 「雑音より 8dB 以上大きい（SilenceGate と同じ決まり）」かつ「帯域の中の音の平坦さ（幾何平均÷算術平均）が 0.05 より小さい」
/// こまを数える。区切りの中にそういうこまが minTonalFrames より少なければ、声は無いとみなす。
///
/// 11/7〜11/16 の時計の区切り 5,639 個（PC に音声が残っているもの）で測った数（docs/v20-watch-silence.md）:
/// PC が声 0 秒とした区切り 2,218 個のうち 792 個（36%）を捨て、間違えて捨てる声のある区切りは 71 個・声 229 秒
/// （全体の声 98,083 秒の 0.23%）。数えたのは PC に届いた音声（AAC）で、時計の中の圧縮前の音とは少し違う（実機では未確認）。
struct VoiceGate {
    static let rate: Double = 16_000
    /// 1こまの長さ（16kHz で 64ms）
    static let frame = 1024
    /// 帯域（300〜3400Hz）のビンの番号（1ビン 15.625Hz）
    static let bandLow = 20
    static let bandHigh = 217
    /// これより平坦でなければ「声らしい」
    static let tonalFlatness: Float = 0.05
    /// 声らしいこまが、区切りの中にこれより少なければ声は無い
    static let minTonalFrames = 2
    /// 雑音の見積もり（SilenceGate と同じ）
    private static let margin: Float = 8
    private static let absoluteQuiet: Float = -60
    private static let floorRise: Float = 0.2

    // MARK: - 設定（iPhone の「声の無い区切りは送らない」。初めはオン。時計には iPhone から届く）

    static let enabledKey = "dropNoVoice"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func addSettings(to context: inout [String: Any]) {
        context[enabledKey] = enabled
    }

    static func readSettings(_ context: [String: Any]) {
        if let on = context[enabledKey] as? Bool { enabled = on }
    }

    /// この区切りを捨てるか。tonalFrames は区切りの中の声らしいこまの数、meeting は会議モードか（会議のあいだは捨てない）
    static func shouldDrop(tonalFrames: Int, enabled: Bool, meeting: Bool) -> Bool {
        enabled && !meeting && tonalFrames < minTonalFrames
    }

    // MARK: - 捨てた数（時計が iPhone に知らせる。今日の分）

    private static let droppedDayKey = "noVoiceDroppedDay"
    private static let droppedCountKey = "noVoiceDropped"

    static func noteDropped(now: Date = .now, calendar: Calendar = .current) {
        let day = dayKey(now, calendar: calendar)
        let defaults = UserDefaults.standard
        let count = defaults.string(forKey: droppedDayKey) == day ? defaults.integer(forKey: droppedCountKey) : 0
        defaults.set(day, forKey: droppedDayKey)
        defaults.set(count + 1, forKey: droppedCountKey)
    }

    static func droppedToday(now: Date = .now, calendar: Calendar = .current) -> Int {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: droppedDayKey) == dayKey(now, calendar: calendar) ? defaults.integer(forKey: droppedCountKey) : 0
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    // MARK: - 数える

    /// いまの区切りの中の、声らしいこまの数
    private(set) var tonalFrames = 0
    /// いまの区切りの中の、見たこまの数
    private(set) var frames = 0
    private var floor: Float?
    private var pending: [Float] = []
    private let fft = RealFFT(size: VoiceGate.frame)

    init() {
        pending.reserveCapacity(Self.frame)
    }

    /// 新しい区切りを始める（雑音の見積もりは残す）
    mutating func reset() {
        tonalFrames = 0
        frames = 0
        pending.removeAll(keepingCapacity: true)
    }

    /// 16kHz・1ch の音を受け取る
    mutating func feed(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var i = 0
        while i < count {
            let take = min(Self.frame - pending.count, count - i)
            pending.append(contentsOf: UnsafeBufferPointer(start: samples + i, count: take))
            i += take
            if pending.count == Self.frame {
                look(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    mutating func feed(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            feed(base, count: buffer.count)
        }
    }

    private mutating func look(_ frame: [Float]) {
        var sum: Float = 0
        for v in frame { sum += v * v }
        let db = 10 * log10(max(sum / Float(frame.count), 1e-12))
        let seconds = Float(Double(frame.count) / Self.rate)
        let current = floor ?? db
        let newFloor = db < current ? db : current + Self.floorRise * seconds
        floor = newFloor
        frames += 1
        guard db >= Self.absoluteQuiet, db >= newFloor + Self.margin else { return }
        if Self.flatness(fft.power(frame), low: Self.bandLow, high: Self.bandHigh) < Self.tonalFlatness {
            tonalFrames += 1
        }
    }

    /// 帯域の中の平坦さ（幾何平均÷算術平均。1 に近いほど雑音、0 に近いほど決まった高さの音）
    static func flatness(_ power: [Float], low: Int, high: Int) -> Float {
        guard low >= 0, high < power.count, low <= high else { return 1 }
        var logSum: Double = 0
        var sum: Double = 0
        for k in low...high {
            let p = Double(power[k]) + 1e-12
            logSum += log(p)
            sum += p
        }
        let n = Double(high - low + 1)
        return Float(exp(logSum / n) / (sum / n))
    }
}

/// 長さが 2 のべき乗の実数の音の、ハン窓をかけたパワースペクトル（0〜size/2 のビン）。外のライブラリを使わない小さな FFT
struct RealFFT {
    let size: Int
    private let window: [Float]
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReverse: [Int]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "size は 2 のべき乗")
        self.size = size
        window = (0..<size).map { 0.5 - 0.5 * Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        cosTable = (0..<size / 2).map { Float(cos(-2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<size / 2).map { Float(sin(-2 * Double.pi * Double($0) / Double(size))) }
        var bits = 0
        while (1 << bits) < size { bits += 1 }
        bitReverse = (0..<size).map { i in
            var r = 0
            for b in 0..<bits where i & (1 << b) != 0 { r |= 1 << (bits - 1 - b) }
            return r
        }
    }

    /// |X[k]|² （k = 0...size/2）
    func power(_ samples: [Float]) -> [Float] {
        var re = [Float](repeating: 0, count: size)
        var im = [Float](repeating: 0, count: size)
        let n = min(samples.count, size)
        for i in 0..<n { re[bitReverse[i]] = samples[i] * window[i] }
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for j in 0..<half {
                    let wr = cosTable[j * step]
                    let wi = sinTable[j * step]
                    let a = start + j
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += length
            }
            length *= 2
        }
        return (0...size / 2).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }
}

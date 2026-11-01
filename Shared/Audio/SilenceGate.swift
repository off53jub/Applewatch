import Foundation

/// 音がしないあいだは録音ファイルに書かない（iPhone と時計の両方で使う）。
///
/// 1分続けて静かなら、いまの区切りを閉じて「休み」に入る（マイクは聞き続ける）。
/// 休んでいるあいだに音がしたら、その1秒前から新しい区切りを書き始める。区切りの名前は書き始めた時刻なので、
/// 行の時刻はずれない。無音の区切りを作らず、送らず、文字にもしないぶん、電池と通信が減る。
///
/// 「静か」は、そのときの雑音の大きさ（静かなほうへはすぐ下がり、上へはゆっくり上がる）より 8dB 以内の音。
/// 空調のようにずっと鳴っている音は静かとみなし、話し声・物音は音がしたとみなす。
struct SilenceGate {
    /// これだけ続けて静かなら休む
    static let idleAfter: TimeInterval = 60
    /// 書き始めるとき、これだけ前の音から書く
    static let preRoll: TimeInterval = 1.0
    /// 雑音よりこれだけ大きければ「音がした」
    private static let margin: Float = 8
    /// これより小さい音は、いつも静か
    private static let absoluteQuiet: Float = -60
    /// 雑音の大きさの見積もりが上がる速さ（1秒あたり dB）
    private static let floorRise: Float = 0.2

    /// iPhone の設定（時計には iPhone から届く）。初めはオン。
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "skipSilence") as? Bool ?? true
    }

    enum Step {
        /// そのまま
        case keep
        /// 休みに入る（いまの区切りを閉じる）
        case rest
        /// 書き始める
        case wake
    }

    private var floor: Float?
    private var quiet: TimeInterval = 0
    private var loud = 0

    mutating func reset() {
        quiet = 0
        loud = 0
    }

    /// 音を受け取る。resting は、いま休んでいるか。
    mutating func feed(_ samples: UnsafePointer<Float>, count frames: Int, rate: Double, resting: Bool) -> Step {
        guard frames > 0, rate > 0 else { return .keep }
        var sum: Float = 0
        for i in 0..<frames { sum += samples[i] * samples[i] }
        let db = 10 * log10(max(sum / Float(frames), 1e-12))
        let seconds = Double(frames) / rate
        let current = floor ?? db
        let newFloor = db < current ? db : current + Self.floorRise * Float(seconds)
        floor = newFloor
        let sound = db >= Self.absoluteQuiet && db >= newFloor + Self.margin
        if resting {
            // 0.2秒ほど続けて音がしたら起きる（一瞬の音では起きない）
            loud = sound ? loud + 1 : 0
            if Double(loud) * seconds >= 0.15 {
                loud = 0
                quiet = 0
                return .wake
            }
            return .keep
        }
        quiet = sound ? 0 : quiet + seconds
        if Self.enabled, quiet >= Self.idleAfter {
            quiet = 0
            loud = 0
            return .rest
        }
        return .keep
    }
}

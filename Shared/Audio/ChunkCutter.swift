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
///
/// 設定「電池が少ないときは5分に」（初めはオン。2026-11-07）: 時計の電池が少ない（30% より下・低電力モード）あいだは、
/// 短めの設定でも、時計は自動で「ふつう（5分）」の区切りにする（送る回数が減って電池が長持ちする）。
/// 電池が 35% まで戻る・充電を始めると、短めに戻す（30% のあたりで行ったり来たりしないよう、戻すのは少し上）。
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

    // MARK: - 電池が少ないときは5分に（2026-11-07）

    /// 設定「電池が少ないときは5分に」の名前（iPhone の設定が、applicationContext で時計に届く）
    static let batterySaverKey = "chunkBatterySaver"
    /// 時計がいま、電池のために5分で区切っているか（時計の UserDefaults。iPhone では使わない）
    static let batterySavingKey = "chunkBatterySaving"
    /// 電池がこれより少ないと5分にする（0〜1）
    static let lowBattery = 0.30
    /// 電池がここまで戻ったら短めに戻す
    static let recoveredBattery = 0.35

    /// 設定「電池が少ないときは5分に」（初めはオン）
    static var batterySaverOn: Bool {
        get { UserDefaults.standard.object(forKey: batterySaverKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: batterySaverKey) }
    }

    /// いま電池のために5分にしているか（時計が電池を読むたびに決める。iPhone ではいつも false）
    static var batterySaving: Bool {
        get { UserDefaults.standard.bool(forKey: batterySavingKey) }
        set { UserDefaults.standard.set(newValue, forKey: batterySavingKey) }
    }

    /// 実際に使う長さ（設定が短めでも、電池のために5分にしているあいだは、ふつう）
    static var current: Length { effective(length, saving: batterySaving) }

    static func effective(_ length: Length, saving: Bool) -> Length { saving ? .normal : length }

    /// 電池のために5分にするか。
    /// - on: 設定「電池が少ないときは5分に」
    /// - battery: 電池の残り（0〜1。分からなければ nil。そのときは今のまま）
    /// - wasSaving: いま5分にしているか（戻すのは 35% まで戻ってから）
    static func shouldSave(on: Bool, battery: Double?, charging: Bool?, lowPower: Bool?, wasSaving: Bool) -> Bool {
        guard on else { return false }
        // 充電を始めたら、電池はこれから増えるので短めに戻す
        if charging == true { return false }
        if lowPower == true { return true }
        guard let battery else { return wasSaving }
        return wasSaving ? battery < recoveredBattery : battery < lowBattery
    }

    /// 時計の様子を古い順にたどって、いま5分にしているはずかを決める（iPhone の自己点検用。時計と同じ決め方）
    static func replaySaving(_ states: [(battery: Double?, charging: Bool?, lowPower: Bool?)], on: Bool) -> Bool {
        var saving = false
        for state in states {
            saving = shouldSave(on: on, battery: state.battery, charging: state.charging, lowPower: state.lowPower,
                                wasSaving: saving)
        }
        return saving
    }

    /// iPhone が時計に送る設定に、区切りの長さと「電池が少ないときは5分に」を入れる
    static func addSettings(to context: inout [String: Any]) {
        context[lengthKey] = length.rawValue
        context[batterySaverKey] = batterySaverOn
    }

    /// 時計が iPhone から届いた設定を読む（区切りの長さと「電池が少ないときは5分に」。次の区切りから効く）
    static func readSettings(_ context: [String: Any]) {
        if let raw = context[lengthKey] as? String, let length = Length(rawValue: raw) {
            self.length = length
        }
        if let on = context[batterySaverKey] as? Bool { batterySaverOn = on }
    }

    /// 静かな瞬間をこれだけ待つ
    static let maxExtra: TimeInterval = 20
    /// いちばん長い区切り（いま使っている長さで）
    static var longest: TimeInterval { current.maximum + maxExtra }

    /// 5分の区切りで数えていた数を、いまの区切りの長さでの数に直す（同じくらいの時間になるように）。
    /// 例: 5分の区切り3つ（15分）は、短めなら 12 個
    static func scaled(_ countAtFiveMinutes: Int, length: Length = ChunkCutter.current) -> Int {
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

    init(length: Length = ChunkCutter.current) {
        self.length = length
    }

    /// 次の区切りの始まり。length を渡さなければ、そのときの設定を読み直す（設定を変えたら次の区切りから効く。
    /// 時計が電池のために5分にしているあいだは、ふつう）
    mutating func reset(length: Length? = nil) {
        self.length = length ?? Self.current
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

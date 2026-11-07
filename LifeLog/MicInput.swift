import AVFoundation
import Foundation
import Observation

// 外付けマイク（2026-11-07。版 9）。iPhone で録るときだけ（時計の録音には関係ない）。
// - USB・受信機のマイク（DJI Mic Mini 2・RØDE Wireless Micro の受信機など）がつながったら、それで録る。
//   Bluetooth（HFP）のマイクは音が悪いので、USB・受信機のマイクを先に選ぶ。外したら iPhone のマイクに戻る。
// - 設定「マイク」: 自動／iPhone のマイクだけ。Bluetooth のマイクは、設定でオンにしたときだけ使う
//   （オンにすると、AirPods などのイヤホンや車のハンズフリーもマイクとして見えるようになるので。イヤホンらしい名前のものは選ばない）。
// - 2チャンネル（左右）で録れるマイクは、左右を平均して1チャンネルのファイルにし（今までのファイルと同じ形）、
//   左右それぞれの大きさを別のファイル（Application Support/channels/<区切りの名前>.json）に残す。
//   設定「左右に分けて録れるとき: 左＝自分」がオンなら、話し手の見分けで「その行の声がどちらで大きいか」を手がかりに足す。
// - マイクの雑音を消す機能は、マイクの本体の設定なので、アプリからは変えられない。

// MARK: - どのマイクで録るか

enum MicChoice {
    enum Mode: String, CaseIterable, Identifiable {
        /// つながったマイク（USB・受信機を先に）で録る
        case auto
        /// いつも iPhone のマイクで録る
        case builtIn

        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "自動"
            case .builtIn: "iPhone のマイクだけ"
            }
        }
    }

    static let modeKey = "micInputMode"
    static let bluetoothKey = "micBluetooth"
    /// 設定が変わったら録音中のマイクを選び直す（Recorder が受ける）
    static let changed = Notification.Name("LifeLogMicChoiceChanged")

    static var mode: Mode { UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .auto }
    /// Bluetooth のマイクも使うか（初めはオフ）
    static var bluetoothOn: Bool { UserDefaults.standard.bool(forKey: bluetoothKey) }

    /// 選ぶときに見る、つながっているマイク1つ
    struct Port: Equatable {
        let type: AVAudioSession.Port
        let uid: String
        let name: String
    }

    /// イヤホン・ヘッドホンらしい名前（Bluetooth のマイクを使うときも、これは選ばない）
    private static let earphoneWords = ["airpods", "beats", "buds", "headphone", "イヤホン", "ヘッドホン", "ヘッドフォン"]

    static func looksLikeEarphones(_ name: String) -> Bool {
        let lower = name.lowercased()
        return earphoneWords.contains { lower.contains($0) }
    }

    /// 選ぶ順（小さいほど先）。選ばないマイクは nil
    static func rank(_ port: Port, bluetooth: Bool) -> Int? {
        switch port.type {
        case .usbAudio, .lineIn: return 0
        case .headsetMic: return 1
        case .bluetoothHFP: return bluetooth && !looksLikeEarphones(port.name) ? 2 : nil
        default: return nil
        }
    }

    /// 選ぶマイク。nil は「iOS に任せる」（外付けのマイクが無いとき。今までと同じ）
    static func choose(_ ports: [Port], mode: Mode, bluetooth: Bool) -> Port? {
        let builtIn = ports.first { $0.type == .builtInMic }
        switch mode {
        case .builtIn:
            return builtIn
        case .auto:
            let ranked = ports.compactMap { p in rank(p, bluetooth: bluetooth).map { (p, $0) } }
            if let best = ranked.min(by: { $0.1 < $1.1 }) { return best.0 }
            // Bluetooth を使う設定で、選ばないイヤホンなどがつながっているときは、iOS に任せるとそちらで録るので、iPhone のマイクにする
            if bluetooth, ports.contains(where: { $0.type == .bluetoothHFP }) { return builtIn }
            return nil
        }
    }

    /// 録音の入れ物の設定（Bluetooth のマイクを使うときだけ、Bluetooth を足す）
    static func categoryOptions(mode: Mode, bluetooth: Bool) -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if mode == .auto, bluetooth {
            // 入力を iPhone のマイクにしたときも、音楽などは Bluetooth のイヤホンで聞けるように A2DP も足す
            options.insert(.allowBluetooth)
            options.insert(.allowBluetoothA2DP)
        }
        return options
    }

    /// 今つながっているマイクから選び直す（録音中に呼ぶ）。選んだマイクが変わったら true
    @MainActor @discardableResult
    static func apply(_ session: AVAudioSession = .sharedInstance()) -> Bool {
        let inputs = session.availableInputs ?? []
        let ports = inputs.map { Port(type: $0.portType, uid: $0.uid, name: $0.portName) }
        let pick = choose(ports, mode: mode, bluetooth: bluetoothOn)
        var changed = false
        if let pick, let desc = inputs.first(where: { $0.uid == pick.uid }) {
            if session.preferredInput?.uid != desc.uid {
                try? session.setPreferredInput(desc)
                changed = true
            }
        } else if session.preferredInput != nil {
            try? session.setPreferredInput(nil)
            changed = true
        }
        // 2チャンネルで録れるマイク（受信機など）は、左右の両方を受ける（片方だけだと、もう1人の声が入らない）
        let current = session.currentRoute.inputs.first?.portType
        if let current, current != .builtInMic {
            let want = min(2, session.maximumInputNumberOfChannels)
            if want >= 1, session.preferredInputNumberOfChannels != want { try? session.setPreferredInputNumberOfChannels(want) }
        }
        return changed
    }

    /// マイクの種類（自己点検に出す。名前は入れない）
    static func kindLabel(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .usbAudio: "USB・受信機のマイク"
        case .lineIn: "外付けのマイク（ライン）"
        case .headsetMic: "有線のマイク"
        case .bluetoothHFP: "Bluetooth のマイク"
        case .builtInMic: "iPhone のマイク"
        case .carAudio: "車のマイク"
        default: "そのほかのマイク"
        }
    }
}

// MARK: - 今どのマイクで録っているか（画面に出す）

@MainActor
@Observable
final class MicRoute {
    static let shared = MicRoute()

    /// 録音中か（止まっていれば、ほかは空）
    private(set) var recording = false
    /// マイクの名前（「今日」の画面だけに出す）
    private(set) var name = ""
    /// マイクの種類
    private(set) var kind = ""
    /// 受けているチャンネルの数
    private(set) var channels = 0

    /// 今の様子を読み直す
    func update(recording: Bool, session: AVAudioSession = .sharedInstance()) {
        self.recording = recording
        guard recording, let input = session.currentRoute.inputs.first else {
            name = ""
            kind = ""
            channels = 0
            return
        }
        name = input.portName
        kind = MicChoice.kindLabel(input.portType)
        channels = max(1, session.inputNumberOfChannels)
    }

    /// 「今日」の画面に出す文（名前・種類・左右）
    var text: String {
        guard recording, !kind.isEmpty else { return "録音していません" }
        var out = name.isEmpty || name == kind ? kind : name + "（" + kind + "）"
        if channels >= 2 { out += "・左右2チャンネル" + (StereoMic.isOn ? "（" + StereoMic.selfSideLabel + "）" : "") }
        return out
    }

    /// 自己点検に出す文（名前は入れない）
    var checkText: String {
        guard recording, !kind.isEmpty else { return "録音していません" }
        return kind + (channels >= 2 ? "・左右2チャンネル" + (StereoMic.isOn ? "（" + StereoMic.selfSideLabel + "）" : "") : "")
    }
}

// MARK: - 左右に分けて録れるとき

enum StereoMic {
    static let onKey = "stereoSelfOn"
    static let swapKey = "stereoSwap"

    /// 「左右に分けて録れるとき: 左＝自分」（初めはオフ）
    static var isOn: Bool { UserDefaults.standard.bool(forKey: onKey) }
    /// 左右を入れ替える（右＝自分）
    static var swapped: Bool { UserDefaults.standard.bool(forKey: swapKey) }

    /// 今の設定で「自分」のチャンネル。オフなら nil
    static var selfChannel: ChannelTrack.Side? {
        guard isOn else { return nil }
        return swapped ? .right : .left
    }

    static var selfSideLabel: String { swapped ? "右＝自分" : "左＝自分" }
}

// MARK: - 左右の大きさ

/// 1つの区切りの、左右それぞれの大きさ（2チャンネルのマイクで録ったときだけ）。
/// 区切りのファイル（1チャンネル）とは別に、Application Support/channels/<区切りの名前>.json に置く。
struct ChannelTrack: Codable, Sendable, Equatable {
    enum Side: String, Codable, Sendable {
        case left, right
    }

    /// 録ったときの「自分」のチャンネル（設定がオフなら nil。そのときは手がかりに使わない）
    var selfChannel: Side?
    /// 区切りの中の時刻（秒）。それぞれ、そこから次の時刻までの音の大きさ
    var times: [Double] = []
    /// 左・右の大きさ（dB。音の強さの平均。0 がいちばん大きい）
    var left: [Float] = []
    var right: [Float] = []

    /// 区切りの中の時刻 at からの音の、左右の大きさ（平均の2乗）を足す
    mutating func add(at: Double, leftPower: Float, rightPower: Float) {
        times.append((at * 1000).rounded() / 1000)
        left.append(Self.db(leftPower))
        right.append(Self.db(rightPower))
    }

    /// 音の強さ（平均の2乗）を dB にする（0.1 dB に丸める。とても小さい音は -100）
    static func db(_ power: Float) -> Float {
        guard power > 1e-10 else { return -100 }
        return (10 * log10(power) * 10).rounded() / 10
    }

    /// from〜to の左右の大きさ（dB。その間の音の強さの平均）。その間に何も無ければ nil
    func levels(from: TimeInterval, to: TimeInterval) -> (left: Float, right: Float)? {
        var l: Float = 0, r: Float = 0, n = 0
        for i in times.indices where times[i] >= from - 0.05 && times[i] < to {
            l += powf(10, left[i] / 10)
            r += powf(10, right[i] / 10)
            n += 1
        }
        guard n > 0 else { return nil }
        return (Self.db(l / Float(n)), Self.db(r / Float(n)))
    }
}

/// 2チャンネル以上の音を、1チャンネル（左右の平均）にし、左右それぞれの大きさ（平均の2乗）を出す
enum StereoSplit {
    /// 左右の音（同じ長さ）から、平均の1チャンネルと、左右の大きさを出す
    static func mix(left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride: Int, count: Int,
                    into out: UnsafeMutablePointer<Float>) -> (left: Float, right: Float) {
        var l: Float = 0, r: Float = 0
        for i in 0..<count {
            let a = left[i * stride], b = right[i * stride]
            out[i] = (a + b) * 0.5
            l += a * a
            r += b * b
        }
        let n = Float(max(count, 1))
        return (l / n, r / n)
    }

    /// 2チャンネル以上の音のかたまりを、1チャンネルにする（3チャンネルより多くても、使うのは初めの2つ）。
    /// 1チャンネルの音・数の形が違う音なら nil
    static func split(_ buffer: AVAudioPCMBuffer) -> (mono: AVAudioPCMBuffer, left: Float, right: Float)? {
        let format = buffer.format
        guard format.channelCount >= 2, format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                             channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: max(buffer.frameLength, 1)),
              let out = mono.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        let power: (left: Float, right: Float)
        if format.isInterleaved {
            // 左右が交互に並んでいる（L R L R …）
            let base = UnsafePointer(data[0])
            power = mix(left: base, right: base + 1, stride: buffer.stride, count: count, into: out)
        } else {
            power = mix(left: UnsafePointer(data[0]), right: UnsafePointer(data[1]), stride: 1, count: count, into: out)
        }
        return (mono, power.left, power.right)
    }
}

/// 左右の大きさを区切りごとに置く所
enum ChannelStore {
    /// 残す日数（文字起こしが遅れても使えるように、区切りの音声より長めに）
    static let keepDays = 7

    static var dir: URL {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("channels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for name: String) -> URL { dir.appendingPathComponent(name + ".json") }

    static func save(_ track: ChannelTrack, for name: String) {
        guard !track.times.isEmpty, let data = try? JSONEncoder().encode(track) else { return }
        try? data.write(to: url(for: name), options: .atomic)
        prune()
    }

    static func load(_ name: String) -> ChannelTrack? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return try? JSONDecoder().decode(ChannelTrack.self, from: data)
    }

    /// 古いもの（keepDays より前に書いたもの）を消す
    static func prune(now: Date = .now) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let old = now.addingTimeInterval(-Double(keepDays) * 86400)
        for file in files where file.pathExtension == "json" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < old { try? fm.removeItem(at: file) }
        }
    }
}

// MARK: - 話し手の見分けの手がかり

/// 「その行の声がどちらのチャンネルで大きいか」から、自分か相手かを見る。今の話し手の見分け（SpeakerLabeler）は変えずに、
/// 行ごとの結果に手がかりを足す（声の覚え足しには使わない）。
enum ChannelHint {
    enum Side: Equatable { case me, other }

    /// 自分のチャンネルのほうがこれだけ（dB）大きければ自分、これだけ小さければ相手。
    /// 胸元のマイクには、付けている人の声が、もう1つのマイクより15〜25dB ほど大きく入る。
    /// 2人から同じくらい離れた声（テレビ・周りの人）は差が数 dB なので、6dB で分ける（V9Tests で確かめた目安）
    static let margin: Float = 6
    /// 大きいほうがこれより小さい（dB）ときは見ない（静かな所・小さな雑音）
    static let floor: Float = -55

    /// 左右の大きさから、自分か相手か。どちらとも言えなければ nil
    static func side(left: Float, right: Float, selfChannel: ChannelTrack.Side) -> Side? {
        let mine = selfChannel == .left ? left : right
        let theirs = selfChannel == .left ? right : left
        guard max(mine, theirs) >= floor else { return nil }
        if mine - theirs >= margin { return .me }
        if theirs - mine >= margin { return .other }
        return nil
    }

    /// 区切りの中の from〜to の行が、自分か相手か
    static func side(_ track: ChannelTrack, from: TimeInterval, to: TimeInterval) -> Side? {
        guard let selfChannel = track.selfChannel, let levels = track.levels(from: from, to: to) else { return nil }
        return side(left: levels.left, right: levels.right, selfChannel: selfChannel)
    }

    /// 行ごとの話し手（聞き分けの結果）に、左右の手がかりを足す。
    /// - 自分のチャンネルで明らかに大きい行は「自分」にする
    /// - もう片方で明らかに大きい行が「自分」になっていたら、この区切りでいちばん多く出てくるほかの人にする（いなければ話し手なし）
    /// 新しい人は作らない。手がかりが無い行は、そのまま。
    static func apply(_ names: [SpeakerLabeler.Segment?], spans: [(start: TimeInterval, end: TimeInterval)],
                      track: ChannelTrack) -> (names: [SpeakerLabeler.Segment?], me: Int, other: Int) {
        guard track.selfChannel != nil, names.count == spans.count else { return (names, 0, 0) }
        let sides = spans.map { side(track, from: $0.start, to: $0.end) }
        // この区切りのほかの人（自分の手がかりの行を除いて、いちばん多く出てくる人）
        var counts: [String: Int] = [:]
        for (i, name) in names.enumerated() {
            guard let name, name.personID != SpeakerLabeler.selfID, sides[i] != .me else { continue }
            counts[name.personID, default: 0] += 1
        }
        let partnerID = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
        let partner = partnerID.flatMap { id in names.compactMap { $0 }.first { $0.personID == id } }
        var out = names
        var me = 0, other = 0
        for i in names.indices {
            switch sides[i] {
            case .me:
                guard names[i]?.personID != SpeakerLabeler.selfID else { continue }
                out[i] = SpeakerLabeler.Segment(start: spans[i].start, end: spans[i].end,
                                                personID: SpeakerLabeler.selfID, name: SpeakerLabeler.selfName)
                me += 1
            case .other:
                guard names[i]?.personID == SpeakerLabeler.selfID else { continue }
                out[i] = partner.map { SpeakerLabeler.Segment(start: spans[i].start, end: spans[i].end,
                                                              personID: $0.personID, name: $0.name) }
                other += 1
            case nil:
                continue
            }
        }
        return (out, me, other)
    }
}

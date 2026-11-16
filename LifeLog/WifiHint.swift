import CryptoKit
import Foundation
import NetworkExtension

/// Wi-Fi の名前で、同じ屋内を見分ける手がかり（2026-11-16。強化案 94）。
/// いまつながっている Wi-Fi の名前は、端末の中で hash にして使う（この端末だけの塩つき。名前そのものは保存も送信もしない）。
/// 直した場所の名前に、そのときの hash を添えて覚え（PlaceNameFix.wifi）、同じ hash の Wi-Fi につながったら、同じ場所とみなす。
/// 母艦へ送る `POST /place-names` に付くのも hash だけ（`wifi`。塩が端末ごとなので、母艦では同じ端末の中の比べにだけ使える）。
/// iOS の決まりで、名前を取るには「Access WiFi Information」の権限と位置の許可が要る。取れないとき（権限なし・Wi-Fi でないとき）は何もしない。
/// 設定「Wi-Fi の名前を手がかりにする」（初めはオン）で切れる。
enum WifiHint {
    static let key = "wifiHint"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    private static let saltKey = "wifiHintSalt"
    /// この秒数より新しい hash を、いまの Wi-Fi とみなす
    static let freshSeconds: TimeInterval = 20 * 60

    /// この端末の塩（無ければ作る）
    private static func salt() -> String {
        if let s = UserDefaults.standard.string(forKey: saltKey), !s.isEmpty { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: saltKey)
        return s
    }

    /// 名前を hash にする（塩 + 名前の SHA-256 の先頭 16 桁）。空の名前は nil
    static func hash(ssid: String, salt: String) -> String? {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((salt + "|" + name).utf8))
        var hex = ""
        for byte in digest.prefix(8) { hex += String(format: "%02x", byte) }
        return hex
    }

    /// 新しいと言えるか
    static func isFresh(_ at: Date, now: Date = .now) -> Bool {
        let age: TimeInterval = now.timeIntervalSince(at)
        return age >= 0 && age < freshSeconds
    }

    @MainActor private static var last: (hash: String, at: Date)?

    /// いまつながっている Wi-Fi の hash を取り直す（取れなければ前のまま）
    @MainActor
    static func capture() async {
        guard isOn else { return }
        guard let network = await NEHotspotNetwork.fetchCurrent(), let h = hash(ssid: network.ssid, salt: salt()) else {
            Tally.add("wifi.none")
            return
        }
        last = (h, .now)
        Tally.add("wifi.captured")
    }

    /// 新しく取れた hash（無い・古い・設定がオフなら nil）
    @MainActor
    static func recent(now: Date = .now) -> String? {
        guard isOn, let last, isFresh(last.at, now: now) else { return nil }
        return last.hash
    }
}

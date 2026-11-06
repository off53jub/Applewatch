import Foundation

/// 版が違う端末どうしの同期の守り（2026-11-06）。
///
/// 端末どうしの同期では、会話ごとに番号の大きいほうを丸ごと残す。古い版のアプリは、新しい版で足した項目
/// （［場面］・書き換えの履歴など）を知らないので、古い版の端末が会話を書き直して送ると、その項目が抜けたまま
/// 「新しい版」として戻ってくる。そこで、送ってきた端末の版が古いときは、向こうに無い項目を手元の値で埋めて合わせる。
enum SyncFill {
    /// remote に無い項目を local の値で埋めたものを返す（入れ子の中も、行どうしは時刻で組にして埋める）。
    /// 形が合わないときや読めないときは remote のまま。
    static func filled<T: Codable>(_ remote: T, keeping local: T) -> T {
        // 時刻は会話を見分ける鍵なので、途中で少しもずれないように、数のビットのまま文字にして運ぶ
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(String(date.timeIntervalSinceReferenceDate.bitPattern))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let text = try dec.singleValueContainer().decode(String.self)
            guard let bits = UInt64(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "時刻が読めない"))
            }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        guard let r = try? encoder.encode(remote), let l = try? encoder.encode(local),
              let ro = try? JSONSerialization.jsonObject(with: r), let lo = try? JSONSerialization.jsonObject(with: l),
              let data = try? JSONSerialization.data(withJSONObject: merge(ro, lo)),
              let out = try? decoder.decode(T.self, from: data) else { return remote }
        return out
    }

    /// 並びの中の組を決める手がかり（会話は start、行は time）
    private static let keys = ["start", "time", "id"]

    static func merge(_ remote: Any, _ local: Any) -> Any {
        if let r = remote as? [String: Any], let l = local as? [String: Any] {
            var out = r
            for (key, value) in l {
                if let rv = r[key] { out[key] = merge(rv, value) } else { out[key] = value }
            }
            return out
        }
        if let r = remote as? [Any], let l = local as? [Any] {
            let rd = r.compactMap { $0 as? [String: Any] }, ld = l.compactMap { $0 as? [String: Any] }
            if rd.count == r.count, ld.count == l.count,
               let key = keys.first(where: { k in rd.allSatisfy { $0[k] != nil } && ld.allSatisfy { $0[k] != nil } }) {
                // 同じ時刻の行どうしで埋める（向こうで足した・消した行はそのまま）
                var byKey: [String: [String: Any]] = [:]
                for item in ld { byKey["\(item[key]!)"] = item }
                return rd.map { item in byKey["\(item[key]!)"].map { merge(item, $0) } ?? item }
            }
            if r.count == l.count { return zip(r, l).map { merge($0, $1) } }
            return remote
        }
        return remote
    }
}

/// アプリの版（ビルドの番号）と、同期の相手の端末の版。
enum AppBuild {
    /// この端末のアプリのビルドの番号（GitHub の TestFlight のワークフローの番号。手元のビルドは 1）
    static var current: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    private static let peersKey = "syncPeerBuilds"

    /// 同期の相手の端末ごとの版（0 は、版を送ってこない古いアプリ）
    static var peers: [String: Int] {
        (UserDefaults.standard.dictionary(forKey: peersKey) as? [String: Int]) ?? [:]
    }

    static func note(device: String, build: Int?) {
        var all = peers
        guard all[device] != (build ?? 0) else { return }
        all[device] = build ?? 0
        UserDefaults.standard.set(all, forKey: peersKey)
    }

    /// この端末より古い版の相手（端末の番号と版）
    static func olderPeers(than mine: Int = current) -> [(device: String, build: Int)] {
        peers.filter { $0.value < mine }.map { (device: $0.key, build: $0.value) }.sorted { $0.device < $1.device }
    }
}

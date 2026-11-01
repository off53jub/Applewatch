import Foundation

/// 夜の聞き直しで使う覚え書き（どの区切りを Haas-ja で書けたか、どの区切りを聞き直し済みか）。
/// 区切りの名前の頭が録音を始めた時刻なので、3日より古い名前は忘れる。
@MainActor
enum NightlyRecheck {
    private static let haasKey = "haasDoneAudio"
    private static let nightKey = "nightDoneAudio"
    private static let keepFor: TimeInterval = 3 * 24 * 3600

    /// Haas-ja（家の PC か iPhone 内）で文字起こしできた区切り
    static func markHaasDone(_ name: String) { add(name, to: haasKey) }
    static func isHaasDone(_ name: String) -> Bool { list(haasKey).contains(name) }

    /// 夜の聞き直しを済ませた区切り
    static func markNightDone(_ name: String) { add(name, to: nightKey) }
    static func isNightDone(_ name: String) -> Bool { list(nightKey).contains(name) }

    private static func list(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func add(_ name: String, to key: String) {
        var names = list(key)
        names.insert(name)
        let old = Date.now.addingTimeInterval(-keepFor)
        names = names.filter { Storage.startDate(of: URL(fileURLWithPath: $0)).map { $0 > old } ?? false }
        UserDefaults.standard.set(Array(names), forKey: key)
    }
}

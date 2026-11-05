import Foundation
import SQLite3

/// 記録を探すための索引（iPhone の中の SQLite の全文検索）。記録の本体（日ごとの JSON）から作る写しで、消えても作り直せる。
/// 日本語は言葉の区切りが無いので、文を2文字ずつの組（「会議の資料」→「会議 議の の資 資料」）にして入れ、
/// 探す言葉も同じ組の並びとして探す。2文字の言葉（「会議」「田中」）でも、何か月分からでもすぐ見つかる。1文字の言葉は探せない（呼ぶ側で全部を見る）。
@MainActor
final class SearchIndex {
    struct Hit {
        let day: String
        let time: Date
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("search.sqlite")) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            db = nil
            return
        }
        // FTS5 が無ければ FTS4 で作る
        let made = exec("CREATE VIRTUAL TABLE IF NOT EXISTS lines USING fts5(grams, day UNINDEXED, time UNINDEXED)")
            || exec("CREATE VIRTUAL TABLE IF NOT EXISTS lines USING fts4(grams, day, time, notindexed=day, notindexed=time)")
        if !made || !exec("CREATE TABLE IF NOT EXISTS days(day TEXT PRIMARY KEY, stamp REAL)") {
            sqlite3_close(db)
            db = nil
        }
    }

    var isReady: Bool { db != nil }

    /// 文を2文字ずつの組にする（小文字にそろえ、空白・記号で区切る）
    nonisolated static func grams(_ text: String) -> [String] {
        var result: [String] = []
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let chars = Array(word)
            if chars.count == 1 {
                result.append(String(chars[0]))
            } else {
                for i in 0..<(chars.count - 1) { result.append(String(chars[i...i + 1])) }
            }
        }
        return result
    }

    /// その日を索引し直す必要があるか（記録のファイルを書いた時刻で見る）
    func needsUpdate(_ day: String, stamp: Double) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT stamp FROM days WHERE day = ?", -1, &statement, nil) == SQLITE_OK else { return true }
        sqlite3_bind_text(statement, 1, day, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        return sqlite3_column_double(statement, 0) != stamp
    }

    /// その日の行を入れ直す。texts は行ごとの（時刻, 探す対象の文）。
    func replace(day: String, stamp: Double, texts: [(time: Date, text: String)]) {
        guard let db else { return }
        _ = exec("BEGIN")
        var delete: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM lines WHERE day = ?", -1, &delete, nil) == SQLITE_OK {
            sqlite3_bind_text(delete, 1, day, -1, Self.transient)
            sqlite3_step(delete)
        }
        sqlite3_finalize(delete)
        var insert: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO lines(grams, day, time) VALUES (?, ?, ?)", -1, &insert, nil) == SQLITE_OK {
            for item in texts {
                sqlite3_reset(insert)
                sqlite3_bind_text(insert, 1, Self.grams(item.text).joined(separator: " "), -1, Self.transient)
                sqlite3_bind_text(insert, 2, day, -1, Self.transient)
                sqlite3_bind_double(insert, 3, item.time.timeIntervalSince1970)
                sqlite3_step(insert)
            }
        }
        sqlite3_finalize(insert)
        var mark: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO days(day, stamp) VALUES (?, ?)", -1, &mark, nil) == SQLITE_OK {
            sqlite3_bind_text(mark, 1, day, -1, Self.transient)
            sqlite3_bind_double(mark, 2, stamp)
            sqlite3_step(mark)
        }
        sqlite3_finalize(mark)
        _ = exec("COMMIT")
    }

    /// もう無い日を索引から外す
    func remove(daysNotIn keep: Set<String>) {
        guard let db else { return }
        var statement: OpaquePointer?
        var gone: [String] = []
        if sqlite3_prepare_v2(db, "SELECT day FROM days", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let c = sqlite3_column_text(statement, 0), !keep.contains(String(cString: c)) { gone.append(String(cString: c)) }
            }
        }
        sqlite3_finalize(statement)
        for day in gone {
            for sql in ["DELETE FROM lines WHERE day = ?", "DELETE FROM days WHERE day = ?"] {
                var s: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK {
                    sqlite3_bind_text(s, 1, day, -1, Self.transient)
                    sqlite3_step(s)
                }
                sqlite3_finalize(s)
            }
        }
    }

    /// すべての言葉を含む行（新しい順、limit まで）。2文字に満たない言葉があれば nil（索引では探せない）。
    func search(_ terms: [String], limit: Int = 200) -> [Hit]? {
        guard let db else { return nil }
        var phrases: [String] = []
        for term in terms {
            let grams = Self.grams(term)
            guard !grams.isEmpty, grams.allSatisfy({ $0.count == 2 }) else { return nil }
            phrases.append("\"" + grams.joined(separator: " ").replacingOccurrences(of: "\"", with: "") + "\"")
        }
        guard !phrases.isEmpty else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT day, time FROM lines WHERE lines MATCH ? ORDER BY CAST(time AS REAL) DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, phrases.joined(separator: " "), -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let c = sqlite3_column_text(statement, 0) else { continue }
            hits.append(Hit(day: String(cString: c), time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))))
        }
        return hits
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    deinit {
        sqlite3_close(db)
    }
}

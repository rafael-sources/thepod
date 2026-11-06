import Foundation
import SQLite3

/// Minimal read-only SQLite access for postPod's proyecto.sqlite.
final class SQLiteReader {
    typealias Row = [String: Any]
    private var db: OpaquePointer?

    init(url: URL) throws {
        // postPod DBs are in WAL mode: a pure read-only open fails without the -shm file, so open the (temporary) copy read-write.
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "desconocido"
            sqlite3_close(db)
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "No se pudo abrir la base del proyecto: \(msg)")])
        }
    }

    deinit { sqlite3_close(db) }

    func tableExists(_ name: String) -> Bool {
        !((try? query(String(localized: "SELECT name FROM sqlite_master WHERE type='table' AND name=?"), [name])) ?? []).isEmpty
    }

    func columns(of table: String) -> Set<String> {
        let rows = (try? query(String(localized: "PRAGMA table_info(\(table))"))) ?? []
        return Set(rows.compactMap { $0["name"] as? String })
    }

    func query(_ sql: String, _ params: [Any] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ k: String) -> Int? {
        if let v = self[k] as? Int { return v }
        if let v = self[k] as? Double { return Int(v) }
        if let v = self[k] as? String { return Int(v) }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let v = self[k] as? Double { return v }
        if let v = self[k] as? Int { return Double(v) }
        if let v = self[k] as? String { return Double(v) }
        return nil
    }
    func string(_ k: String) -> String? {
        if let v = self[k] as? String { return v.isEmpty ? nil : v }
        return nil
    }
}

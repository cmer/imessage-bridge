import Foundation
import SQLite3

public enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var string: String {
        switch self {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .blob(let d): return String(decoding: d, as: UTF8.self)
        case .null: return ""
        }
    }

    public var int64: Int64 {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .text(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    public var data: Data? {
        switch self {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

public enum SQLParam {
    case int(Int64)
    case text(String)
}

public struct SQLiteError: Error, LocalizedError {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { "SQLite error \(code): \(message)" }
}

/// Minimal read-only SQLite wrapper.
public final class SQLiteDB {
    private var db: OpaquePointer?

    public init(path: String) throws {
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            db = nil
            throw SQLiteError(code: rc, message: msg)
        }
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(db) }

    public func query(_ sql: String, _ params: [SQLParam] = []) throws -> [[SQLValue]] {
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw lastError(rc) }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            }
        }

        var rows: [[SQLValue]] = []
        let cols = sqlite3_column_count(stmt)
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(rc) }
            var row: [SQLValue] = []
            row.reserveCapacity(Int(cols))
            for c in 0..<cols {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT:
                    row.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT:
                    if let p = sqlite3_column_text(stmt, c) {
                        row.append(.text(String(cString: p)))
                    } else {
                        row.append(.null)
                    }
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if n > 0, let p = sqlite3_column_blob(stmt, c) {
                        row.append(.blob(Data(bytes: p, count: n)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default:
                    row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func lastError(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }
}

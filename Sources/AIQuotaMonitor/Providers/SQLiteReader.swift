import Foundation
import SQLite3

/// 只读 SQLite 读取器。
///
/// 活动库默认用普通只读连接（读得到 WAL 已提交记录）。
/// `immutable=true` 仅用于真正不再变化的快照文件；活动客户端库上会读到过期数据。
final class SQLiteReader {
    enum QueryError: Error, Equatable {
        case notOpen
        case prepareFailed(String)
        case stepFailed(String)
    }

    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// - Parameter immutable: 仅对不会再被其他进程修改的文件设为 true。
    init?(path: String, immutable: Bool = false) {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = immutable ? "file://\(encoded)?immutable=1" : "file://\(encoded)"
        guard sqlite3_open_v2(uri, &opened, flags, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            return nil
        }
        db = opened
        sqlite3_busy_timeout(opened, 800)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    var isOpen: Bool { db != nil }

    /// 查询成功时返回行；准备/步进失败时返回错误，与「确实没有记录」区分。
    func queryResult(_ sql: String, bind: [Any] = []) -> Result<[[String]], QueryError> {
        guard let db else { return .failure(.notOpen) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            return .failure(.prepareFailed(message))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as String:
                sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(stmt, idx, v)
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [[String]] = []
        let columnCount = sqlite3_column_count(stmt)
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                let message = String(cString: sqlite3_errmsg(db))
                return .failure(.stepFailed(message))
            }
            var row: [String] = []
            for c in 0..<columnCount {
                if let cstr = sqlite3_column_text(stmt, c) {
                    row.append(String(cString: cstr))
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }
        return .success(rows)
    }

    /// 兼容旧调用：失败时返回空数组。新代码请用 `queryResult`。
    func query(_ sql: String, bind: [Any] = []) -> [[String]] {
        (try? queryResult(sql, bind: bind).get()) ?? []
    }
}

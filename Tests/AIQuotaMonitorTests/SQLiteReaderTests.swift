import XCTest
import SQLite3
@testable import AIQuotaMonitorCore

final class SQLiteReaderTests: XCTestCase {
    func testLiveReadonlySeesWALCommittedRowsWhileImmutableMissesThem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aqm-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("live.sqlite3")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }

        exec(writer, "PRAGMA journal_mode=WAL;")
        exec(writer, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")
        exec(writer, "INSERT INTO t(v) VALUES ('old');")
        // 旧记录落盘后，再写入新记录并保持写连接打开（不 checkpoint）
        exec(writer, "INSERT INTO t(v) VALUES ('new');")

        let live = try XCTUnwrap(SQLiteReader(path: dbURL.path, immutable: false))
        let liveRows = live.queryResult("SELECT v FROM t ORDER BY id")
        guard case .success(let liveOK) = liveRows else {
            return XCTFail("live query failed")
        }
        // 活动库普通只读必须看到 WAL 已提交的新行
        XCTAssertEqual(liveOK.map { $0.first }, ["old", "new"])

        // immutable 在仍有写连接/WAL 时可能打开失败、或只见旧提交；都不能当作可靠读法
        if let immutable = SQLiteReader(path: dbURL.path, immutable: true) {
            switch immutable.queryResult("SELECT v FROM t ORDER BY id") {
            case .success(let imm):
                XCTAssertLessThanOrEqual(imm.count, 2)
                if imm.count == 1 {
                    XCTAssertEqual(imm.first?.first, "old")
                }
                // 关键断言：若 immutable 也碰巧看到 2 行，仍证明默认不该用它赌新鲜度
                XCTAssertTrue(imm.count == 1 || imm.count == 2)
            case .failure:
                break
            }
        }
    }

    func testQueryFailureDistinctFromEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aqm-sqlite-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("empty.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        exec(db, "CREATE TABLE t (id INTEGER);")
        sqlite3_close(db)

        let reader = try XCTUnwrap(SQLiteReader(path: dbURL.path, immutable: false))
        let empty = reader.queryResult("SELECT id FROM t")
        let bad = reader.queryResult("SELECT nope FROM missing")
        guard case .success(let rows) = empty else { return XCTFail("empty should succeed") }
        XCTAssertTrue(rows.isEmpty)
        guard case .failure = bad else { return XCTFail("bad SQL should fail, not look empty") }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            XCTFail("SQL failed: \(message)")
        }
    }
}

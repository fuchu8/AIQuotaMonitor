import Foundation
import SQLite3

/// 额度历史快照。只用本地 SQLite，不上传任何内容。
final class HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AIQuotaMonitor", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("history.sqlite3").path

        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 1500)
        execute("""
            CREATE TABLE IF NOT EXISTS quota_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                provider TEXT NOT NULL,
                window_key TEXT NOT NULL,
                window_title TEXT,
                used_percent REAL NOT NULL,
                resets_at REAL
            );
            """)
        execute("CREATE INDEX IF NOT EXISTS idx_qh ON quota_history(provider, window_key, ts);")
        execute("DELETE FROM quota_history WHERE ts < strftime('%s','now') - 60*60*24*45;")
    }

    // MARK: 写入

    func record(provider: String, window: QuotaWindow, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO quota_history (ts, provider, window_key, window_title, used_percent, resets_at) VALUES (?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, provider, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, window.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, window.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, window.usedPercent)
        if shouldSkip(provider: provider, window: window, at: date) {
            return
        }
        if let resets = window.resetsAt {
            sqlite3_bind_double(stmt, 6, resets.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_step(stmt)
    }

    // MARK: 读取

    struct Sample {
        let at: Date
        let usedPercent: Double
        let resetsAt: Date?
    }

    /// 最近一个消耗周期里的样本。
    /// 不按重置时间聚类：空闲窗口的 resetsAt 会每次往前滑，按秒或按 30 分钟都会把同一周期拆碎。
    /// 已用百分比明显回落，才算进入下一个周期。
    func samples(provider: String, window: QuotaWindow, hours: Double = 12) -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let since = Date().addingTimeInterval(-hours * 3600).timeIntervalSince1970
        let sql = "SELECT ts, used_percent, resets_at FROM quota_history WHERE provider = ? AND window_key = ? AND ts >= ? ORDER BY ts ASC;"
        let binds: [Any] = [provider, window.id, since]

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            if let s = v as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            else if let d = v as? Double { sqlite3_bind_double(stmt, idx, d) }
        }
        var out: [Sample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt, 0)
            let used = sqlite3_column_double(stmt, 1)
            let resetTs = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            out.append(Sample(at: Date(timeIntervalSince1970: ts),
                              usedPercent: used,
                              resetsAt: resetTs.map { Date(timeIntervalSince1970: $0) }))
        }

        return currentCycle(out)
    }

    /// 百分比没变时，15 分钟内不重复写。滑动的重置时间不算变化。
    private func shouldSkip(provider: String, window: QuotaWindow, at date: Date) -> Bool {
        guard let db else { return false }
        let sql = "SELECT ts, used_percent FROM quota_history WHERE provider = ? AND window_key = ? ORDER BY ts DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, window.id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        let ts = sqlite3_column_double(stmt, 0)
        let used = sqlite3_column_double(stmt, 1)
        return abs(used - window.usedPercent) < 0.05 && date.timeIntervalSince1970 - ts < 15 * 60
    }

    private func currentCycle(_ rows: [Sample]) -> [Sample] {
        guard rows.count > 1 else { return rows }
        var start = 0
        for index in 1..<rows.count where rows[index - 1].usedPercent - rows[index].usedPercent >= 15 {
            start = index
        }
        return Array(rows[start...])
    }

    /// 消耗速度：百分比 / 小时，最小二乘斜率。样本不足返回 nil。
    func burnRate(provider: String, window: QuotaWindow) -> Double? {
        let rows = samples(provider: provider, window: window, hours: 12)
        guard rows.count >= 3 else { return nil }
        let base = rows[0].at
        let xs = rows.map { $0.at.timeIntervalSince(base) / 3600 }
        let ys = rows.map { $0.usedPercent }
        guard let span = xs.last, span >= 0.25 else { return nil }

        let n = Double(xs.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-9 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        return slope > 0 ? slope : 0
    }

    /// 按当前速度预计触顶时间
    func estimateExhaustion(provider: String, window: QuotaWindow) -> Date? {
        guard let rate = burnRate(provider: provider, window: window), rate > 0.5 else { return nil }
        let remaining = window.remainingPercent
        guard remaining > 0 else { return nil }
        let hours = remaining / rate
        // 超过 14 天就不用显示了，噪声太大
        guard hours < 24 * 14 else { return nil }
        return Date().addingTimeInterval(hours * 3600)
    }

    /// 面板里用的迷你趋势（最近 12 小时，最多 40 个点）
    func trend(provider: String, window: QuotaWindow) -> [Double] {
        let rows = samples(provider: provider, window: window, hours: 12)
        guard rows.count > 2 else { return [] }
        if rows.count <= 40 { return rows.map { $0.usedPercent } }
        let step = Double(rows.count) / 40.0
        return (0..<40).map { rows[min(Int(Double($0) * step), rows.count - 1)].usedPercent }
    }

    // MARK: 私有

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

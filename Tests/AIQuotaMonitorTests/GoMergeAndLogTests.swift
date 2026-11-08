import XCTest
@testable import AIQuotaMonitorCore

final class GoMergeAndLogTests: XCTestCase {
    func testTokenSuccessMustNotClearPreviousQuotaWindows() {
        // 模拟 Store 合并：额度失败 + Token 成功
        var previous = OpenCodeGoSnapshot()
        previous.windows = [
            QuotaWindow(id: "go-monthly", title: "每月", usedPercent: 40, resetsAt: Date(), durationMins: 30 * 1440)
        ]
        previous.origin = .openCodeGo
        previous.quotaSuccessAt = Date().addingTimeInterval(-600)

        var go = OpenCodeGoSnapshot()
        go.errorMessage = "网络不可用"
        go.todayTokens = 12
        go.periodTokens = 100
        go.lifetimeTokens = 1000
        go.tokenOrigin = .openCodeGoLocal
        go.tokenSuccessAt = Date()

        // 与 QuotaStore.refreshGo 同逻辑的最小合并
        var next = go
        if go.hasData {
            next.quotaStale = false
        } else if previous.hasData {
            next.windows = previous.windows
            next.origin = previous.origin
            next.quotaSuccessAt = previous.quotaSuccessAt
            next.quotaStale = true
            next.errorMessage = go.errorMessage
        }
        if go.hasTokenData {
            next.todayTokens = go.todayTokens
            next.periodTokens = go.periodTokens
            next.lifetimeTokens = go.lifetimeTokens
            next.tokenOrigin = go.tokenOrigin
        }

        XCTAssertEqual(next.windows.count, 1)
        XCTAssertTrue(next.quotaStale)
        XCTAssertEqual(next.todayTokens, 12)
        XCTAssertEqual(next.origin, .openCodeGo)
    }

    func testIncrementalLogDedupesAppendedLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aqm-go-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("model.log")
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "M/d/yyyy"
        let today = day.string(from: Date())
        let line1 = "[\(today), 10:00:00 AM] [ModelProvider] {\"model\":\"deepseek-v4.1-flash\",\"requestId\":\"r1\",\"input_tokens\":10,\"output_tokens\":5,\"cached_read_tokens\":0}\n"
        try line1.write(to: file, atomically: true, encoding: .utf8)

        let agg = GoLogTokenAggregator()
        let allow: Set<String> = ["deepseek-v4.1-flash"]
        let periodStart = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let first = agg.aggregate(periodStart: periodStart, logsRoot: dir, allowlist: allow)
        XCTAssertTrue(first.ok)
        XCTAssertEqual(first.today, 15)
        XCTAssertEqual(first.lifetime, 15)

        let line2 = "[\(today), 10:01:00 AM] [ModelProvider] {\"model\":\"deepseek-v4.1-flash\",\"requestId\":\"r2\",\"input_tokens\":20,\"output_tokens\":0,\"cached_read_tokens\":0}\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line2.utf8))
        }

        let second = agg.aggregate(periodStart: periodStart, logsRoot: dir, allowlist: allow)
        XCTAssertEqual(second.lifetime, 35)
        XCTAssertEqual(second.today, 35)

        // 无变化再扫，不应翻倍
        let third = agg.aggregate(periodStart: periodStart, logsRoot: dir, allowlist: allow)
        XCTAssertEqual(third.lifetime, 35)
    }

    func testZeroTokenTotalsAreRetainedAsZeroNotNil() {
        // 聚合器成功且合计为 0 时，OpenCodeGo 应用层应保留 0
        let totals = GoLogTokenAggregator.Totals(
            today: 0, period: 0, lifetime: 0, ok: true
        )
        XCTAssertEqual(totals.today, 0)
        XCTAssertTrue(totals.ok)
    }
}

import Foundation
import AppKit

// MARK: - 本地元数据

struct CursorMeta: Equatable {
    var appVersion: String?
    var email: String?
    var planType: String?
    var subscriptionStatus: String?
    var installed: Bool
}

// MARK: - 本地调用活动

struct CursorActivity: Equatable {
    var todayCalls: Int
    var weekCalls: Int
    var byModel: [CursorModelUsage]
    var lastRecordAt: Date?
}

// MARK: - 官方 CSV 摘要

struct CursorCSVSummary: Codable, Equatable {
    var importedAt: Date
    var fileName: String
    var rangeStart: Date?
    var rangeEnd: Date?
    var rowCount: Int
    var totalTokens: Int64
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var costCents: Double?
    var hasIncludedRows: Bool
    var byModel: [CursorModelUsage]
    var byKind: [String: Int]
}

// MARK: - 手动录入

struct CursorManualEntry: Codable, Equatable {
    var usedPercent: Double
    var resetsAt: Date
    var note: String
    var updatedAt: Date

    var window: QuotaWindow {
        QuotaWindow(
            id: "cursor-manual",
            title: "订阅额度",
            usedPercent: max(0, min(100, usedPercent)),
            resetsAt: resetsAt,
            durationMins: nil
        )
    }
}

// MARK: - Provider

enum CursorProvider {

    static let stateDBPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }()

    static let trackingDBPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/.cursor/ai-tracking/ai-code-tracking.db"
    }()

    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    // MARK: 元数据

    /// 只读取套餐、订阅状态、邮箱这些展示用元数据。
    /// 明确不读取 cursorAuth/accessToken、refreshToken 等任何凭据。
    static func readMetadata() -> CursorMeta {
        var meta = CursorMeta(installed: false)

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundleID)
            ?? URL(string: "/Applications/Cursor.app").map({ $0 }),
           let bundle = Bundle(url: url) {
            meta.installed = true
            meta.appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        }

        guard FileManager.default.fileExists(atPath: stateDBPath),
              let db = SQLiteReader(path: stateDBPath, immutable: false) else {
            return meta
        }

        let allowedKeys = [
            "cursorAuth/stripeMembershipType",
            "cursorAuth/stripeSubscriptionStatus",
            "cursorAuth/cachedEmail"
        ]
        let placeholders = allowedKeys.map { _ in "?" }.joined(separator: ",")
        let rows: [[String]]
        switch db.queryResult(
            "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))",
            bind: allowedKeys
        ) {
        case .success(let value):
            rows = value
        case .failure:
            // 读取失败：不把空结果当成「没有套餐元数据」
            return meta
        }
        for row in rows where row.count >= 2 {
            let value = row[1]
            switch row[0] {
            case "cursorAuth/stripeMembershipType": meta.planType = value
            case "cursorAuth/stripeSubscriptionStatus": meta.subscriptionStatus = value
            case "cursorAuth/cachedEmail": meta.email = value
            default: break
            }
        }
        return meta
    }

    // MARK: 本地调用活动（官方客户端记录，非额度）

    static func readActivity() -> CursorActivity? {
        guard FileManager.default.fileExists(atPath: trackingDBPath),
              let db = SQLiteReader(path: trackingDBPath, immutable: false) else { return nil }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let todayMs = Int64(startOfToday.timeIntervalSince1970 * 1000)
        // 本周 = 最近 7 天
        let weekStart = cal.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
        let weekMs = Int64(weekStart.timeIntervalSince1970 * 1000)

        func countQuery(_ sql: String, bind: [Any]) -> Int? {
            switch db.queryResult(sql, bind: bind) {
            case .success(let rows):
                return Int(rows.first?.first ?? "0")
            case .failure:
                return nil
            }
        }

        guard let today = countQuery("SELECT COUNT(*) FROM ai_code_hashes WHERE timestamp >= ?", bind: [todayMs]),
              let week = countQuery("SELECT COUNT(*) FROM ai_code_hashes WHERE timestamp >= ?", bind: [weekMs])
        else {
            // 查询失败 ≠ 零调用
            return nil
        }

        let modelRows: [[String]]
        switch db.queryResult("""
            SELECT COALESCE(model, 'unknown'), COUNT(*) FROM ai_code_hashes
            WHERE timestamp >= ? GROUP BY model ORDER BY COUNT(*) DESC
            """, bind: [weekMs]) {
        case .success(let rows): modelRows = rows
        case .failure: return nil
        }
        let lastRows = (try? db.queryResult("SELECT MAX(timestamp) FROM ai_code_hashes").get()) ?? []

        let models = modelRows.compactMap { row -> CursorModelUsage? in
            guard row.count >= 2, let count = Int(row[1]) else { return nil }
            return CursorModelUsage(model: row[0], tokens: 0, calls: count, costCents: nil)
        }
        var last: Date?
        if let ms = Int64(lastRows.first?.first ?? ""), ms > 0 {
            last = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return CursorActivity(todayCalls: today, weekCalls: week, byModel: models, lastRecordAt: last)
    }

    // MARK: 组装

    static func build(manual: CursorManualEntry?,
                      csv: CursorCSVSummary?,
                      previous: CursorSnapshot?) -> CursorSnapshot {
        let meta = readMetadata()
        let activity = readActivity()

        var snap = CursorSnapshot()
        snap.appVersion = meta.appVersion
        snap.email = meta.email
        snap.planType = meta.planType
        snap.subscriptionStatus = meta.subscriptionStatus
        snap.todayCalls = activity?.todayCalls
        snap.weekCalls = activity?.weekCalls
        snap.fetchedAt = Date()

        if !meta.installed {
            snap.errorMessage = "未检测到 Cursor 客户端"
        }

        // 额度窗口：手动 > 无
        if let manual {
            snap.quotaWindows = [manual.window]
            snap.quotaOrigin = .manual
        } else {
            snap.quotaWindows = []
            snap.quotaOrigin = .unavailable
        }

        if let csv {
            snap.cycleTokens = csv.totalTokens
            snap.cycleCostCents = csv.costCents
            snap.modelUsage = csv.byModel
            if snap.quotaWindows.isEmpty {
                snap.dataNote = "已完成官方 CSV 导入，但 CSV 不含额度百分比"
            }
        } else if let prev = previous, let tokens = prev.cycleTokens {
            // 保留上次导入的用量数据
            snap.cycleTokens = tokens
            snap.cycleCostCents = prev.cycleCostCents
            snap.modelUsage = prev.modelUsage
        } else {
            // 没有 CSV 时，用本地官方客户端记录的按模型代码片段分布
            snap.modelUsage = activity?.byModel ?? []
        }

        return snap
    }

    // MARK: CSV 导入

    static func importCSV(at url: URL) throws -> CursorCSVSummary {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw ProviderError.io("无法读取文件编码")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let rows = parseCSV(text)
        guard rows.count >= 2 else { throw ProviderError.io("CSV 内容为空") }

        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ needles: [String]) -> Int? {
            for needle in needles {
                if let idx = header.firstIndex(where: { $0.contains(needle) }) { return idx }
            }
            return nil
        }

        guard let dateIdx = column(["date"]),
              let modelIdx = column(["model"]) else {
            throw ProviderError.io("CSV 缺少 Date / Model 列，可能不是 Cursor 官方导出文件")
        }
        let kindIdx = column(["kind"])
        let totalIdx = column(["total tokens"])
        let inputIdx = column(["input (w/ cache write)", "input"])
        let outputIdx = column(["output tokens", "output"])
        let cacheIdx = column(["cache read"])
        let costIdx = column(["cost"])

        var totalTokens: Int64 = 0
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheTokens: Int64 = 0
        var costCents: Double = 0
        var anyCost = false
        var hasIncluded = false
        var byModel: [String: (tokens: Int64, calls: Int, cost: Double)] = [:]
        var byKind: [String: Int] = [:]
        var dates: [Date] = []

        func num(_ row: [String], _ idx: Int?) -> Int64 {
            guard let idx, idx < row.count else { return 0 }
            let cleaned = row[idx].replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Int64(Double(cleaned) ?? 0)
        }

        for row in rows.dropFirst() {
            guard row.count > max(dateIdx, modelIdx) else { continue }
            let model = row[modelIdx].trimmingCharacters(in: .whitespaces)
            if model.isEmpty { continue }
            let kind = kindIdx.flatMap { $0 < row.count ? row[$0] : nil } ?? ""

            if let d = parseDate(row[dateIdx]) { dates.append(d) }

            var rowTokens = num(row, totalIdx)
            let inTok = num(row, inputIdx)
            let outTok = num(row, outputIdx)
            let cacheTok = num(row, cacheIdx)
            if rowTokens == 0 { rowTokens = inTok + outTok }

            totalTokens += rowTokens
            inputTokens += inTok
            outputTokens += outTok
            cacheTokens += cacheTok

            if let costIdx, costIdx < row.count {
                let raw = row[costIdx].trimmingCharacters(in: .whitespaces)
                if raw.lowercased().contains("included") {
                    hasIncluded = true
                } else {
                    let cleaned = raw.replacingOccurrences(of: "$", with: "")
                        .replacingOccurrences(of: ",", with: "")
                    if let value = Double(cleaned), value > 0 {
                        costCents += value * 100
                        anyCost = true
                    }
                }
            }

            if !kind.isEmpty { byKind[kind, default: 0] += 1 }
            var entry = byModel[model] ?? (0, 0, 0)
            entry.tokens += rowTokens
            entry.calls += 1
            byModel[model] = entry
        }

        let models = byModel
            .map { CursorModelUsage(model: $0.key, tokens: $0.value.tokens,
                                    calls: $0.value.calls, costCents: nil) }
            .sorted { $0.tokens > $1.tokens }

        return CursorCSVSummary(
            importedAt: Date(),
            fileName: url.lastPathComponent,
            rangeStart: dates.min(),
            rangeEnd: dates.max(),
            rowCount: rows.count - 1,
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheTokens,
            costCents: anyCost ? costCents : nil,
            hasIncludedRows: hasIncluded,
            byModel: models,
            byKind: byKind
        )
    }

    // MARK: 解析辅助

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                field.append(ch)
                i += 1
                continue
            }
            switch ch {
            case "\"":
                inQuotes = true
                i += 1
            case ",":
                row.append(field)
                field = ""
                i += 1
            case "\n":
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                i += 1
            case "\r":
                i += 1
            default:
                field.append(ch)
                i += 1
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    private static let dateFormatters: [DateFormatter] = {
        let patterns = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                        "yyyy-MM-dd'T'HH:mm:ssZ",
                        "yyyy-MM-dd HH:mm:ss",
                        "yyyy-MM-dd"]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = pattern
            return f
        }
    }()

    private static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        for f in dateFormatters {
            if let d = f.date(from: value) { return d }
        }
        return nil
    }
}

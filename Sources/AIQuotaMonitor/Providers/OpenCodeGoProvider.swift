import Foundation
import AppKit

/// OpenCode Go 官方用量。密钥只在请求时读取，不写入本程序的配置或日志。
/// Token 三列来自本机 ModelProvider 日志增量聚合（官方 /usage 只有百分比）。
/// 日志目录可能仍在 ~/.workbuddy/logs，但展示为 Go 本机日志统计，不是 WorkBuddy 积分监控。
enum OpenCodeGoProvider {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static var tokenCache: (day: String, periodStart: Date, allowFP: Int, at: Date, value: GoLogTokenAggregator.Totals)?
    private static let tokenCacheTTL: TimeInterval = 60
    private static let cacheQueue = DispatchQueue(label: "aiquotamonitor.go.token-cache")

    static func fetch(forceToken: Bool = false) async -> OpenCodeGoSnapshot {
        guard let key = locateKey() else {
            var snap = OpenCodeGoSnapshot()
            snap.fetchedAt = Date()
            snap.errorMessage = "未找到 OpenCode Go 密钥"
            await fillTokens(&snap, force: forceToken)
            return snap
        }
        var request = URLRequest(url: usageURL, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIQuotaMonitor/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                var snap = failed("OpenCode Go 密钥无效")
                await fillTokens(&snap, force: forceToken)
                return snap
            }
            if code == 403 {
                var snap = failed("这把密钥没有 OpenCode Go 订阅")
                await fillTokens(&snap, force: forceToken)
                return snap
            }
            guard (200..<300).contains(code) else {
                var snap = failed("OpenCode Go 用量接口返回 \(code)")
                await fillTokens(&snap, force: forceToken)
                return snap
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                var snap = failed("OpenCode Go 用量接口无返回")
                await fillTokens(&snap, force: forceToken)
                return snap
            }
            var snap = parse(obj)
            await fillTokens(&snap, force: forceToken)
            return snap
        } catch {
            var snap = failed("OpenCode Go 读取失败")
            await fillTokens(&snap, force: forceToken)
            return snap
        }
    }

    static func openConsole() {
        NSWorkspace.shared.open(URL(string: "https://opencode.ai/console")!)
    }

    // MARK: 密钥

    /// 优先环境变量，其次 OpenCode 自己的登录文件，最后用本机已配置的 Go 模型密钥文件。
    private static func locateKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"] {
            if let value = env[name], value.hasPrefix("oc_") { return value }
        }
        if let key = keyFromAuthFile() { return key }
        if let key = keyFromModelsFile() { return key }
        return nil
    }

    private static func keyFromAuthFile() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let entry = (obj as? [String: Any])?["opencode-go"] else { return nil }
        if let text = entry as? String, text.hasPrefix("oc_") { return text }
        if let dict = entry as? [String: Any] {
            for name in ["key", "apiKey", "token"] {
                if let text = dict[name] as? String, text.hasPrefix("oc_") { return text }
            }
        }
        return nil
    }

    private static func keyFromModelsFile() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".workbuddy/models.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return firstGoKey(in: obj)
    }

    private static func firstGoKey(in obj: Any) -> String? {
        if let rows = obj as? [Any] {
            for row in rows {
                if let key = firstGoKey(in: row) { return key }
            }
            return nil
        }
        guard let dict = obj as? [String: Any] else { return nil }
        let vendor = (dict["vendor"] as? String)?.lowercased() ?? ""
        let url = (dict["url"] as? String)?.lowercased() ?? ""
        let looksLikeGo = vendor.contains("opencode") || url.contains("opencode.ai")
        if looksLikeGo, let key = dict["apiKey"] as? String, key.hasPrefix("oc_") {
            return key
        }
        for value in dict.values {
            if let key = firstGoKey(in: value) { return key }
        }
        return nil
    }

    // MARK: 解析

    private static func parse(_ raw: [String: Any]) -> OpenCodeGoSnapshot {
        guard let usage = raw["usage"] as? [String: Any] else {
            return failed("OpenCode Go 没有返回用量")
        }
        let specs: [(String, String, Int)] = [
            ("rolling", "5 小时", 5 * 60),
            ("weekly", "每周", 7 * 1440),
            ("monthly", "每月", 30 * 1440)
        ]
        var windows: [QuotaWindow] = []
        var limited = false
        for spec in specs {
            guard let row = usage[spec.0] as? [String: Any],
                  let percent = number(row["percent"]) else { continue }
            if (row["status"] as? String) == "rate-limited" { limited = true }
            windows.append(QuotaWindow(
                id: "go-\(spec.0)",
                title: spec.1,
                usedPercent: max(0, min(100, percent)),
                resetsAt: parseDate(row["resetsAt"] as? String),
                durationMins: spec.2
            ))
        }
        var snap = OpenCodeGoSnapshot()
        let now = Date()
        snap.fetchedAt = now
        snap.windows = windows
        snap.rateLimited = limited
        if windows.isEmpty {
            snap.errorMessage = "OpenCode Go 没有返回额度窗口"
        } else {
            snap.origin = .openCodeGo
            snap.quotaSuccessAt = now
        }
        return snap
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func failed(_ message: String) -> OpenCodeGoSnapshot {
        var snap = OpenCodeGoSnapshot()
        snap.fetchedAt = Date()
        snap.errorMessage = message
        return snap
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    // MARK: 本机 Token

    private static func fillTokens(_ snap: inout OpenCodeGoSnapshot, force: Bool) async {
        let reliablePeriodStart: Date? = snap.windows.first(where: { $0.id == "go-monthly" }).flatMap { window -> Date? in
            guard let resets = window.resetsAt, let mins = window.durationMins, mins > 0 else { return nil }
            return resets.addingTimeInterval(-TimeInterval(mins * 60))
        }
        let periodStart = reliablePeriodStart
            ?? Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        snap.periodLabel = reliablePeriodStart != nil ? "本周期" : "近 30 天"

        let dayKey = Fmt.dayKey(Date())
        let allowFP = GoLogTokenAggregator.loadAllowlist().hashValue

        let cached = cacheQueue.sync { tokenCache }
        if !force,
           let cached,
           cached.day == dayKey,
           abs(cached.periodStart.timeIntervalSince(periodStart)) < 1,
           cached.allowFP == allowFP,
           Date().timeIntervalSince(cached.at) < tokenCacheTTL {
            apply(cached.value, to: &snap)
            return
        }

        let start = periodStart
        let totals = await Task.detached(priority: .utility) {
            GoLogTokenAggregator.shared.aggregate(periodStart: start)
        }.value

        cacheQueue.sync {
            tokenCache = (dayKey, periodStart, allowFP, Date(), totals)
        }
        apply(totals, to: &snap)
    }

    private static func apply(_ totals: GoLogTokenAggregator.Totals, to snap: inout OpenCodeGoSnapshot) {
        if totals.ok {
            snap.todayTokens = totals.today
            snap.periodTokens = totals.period
            snap.lifetimeTokens = totals.lifetime
            snap.tokenOrigin = .openCodeGoLocal
            snap.tokenSuccessAt = Date()
            snap.tokenCoverageStart = totals.coverageStart
            snap.tokenCoverageEnd = totals.coverageEnd
            snap.tokenSkippedFiles = totals.skippedFiles
            snap.tokenIncomplete = totals.incomplete
            snap.tokenEstimatedByModel = totals.estimatedByModel
            snap.tokenErrorMessage = nil
            snap.tokenStale = false
        } else {
            snap.tokenErrorMessage = totals.error ?? "本机日志 Token 读取失败"
        }
    }
}

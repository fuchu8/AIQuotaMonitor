import Foundation
import AppKit

/// Grok Bot 周池。用本机 Cursor / Grok Bot 共用的登录态读官方 GetSandUsageStatus。
enum GrokBotProvider {
    private static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!

    static func fetch() async -> GrokBotSnapshot {
        guard let token = await CursorAccount.accessToken() else {
            return failed("登录态不可用。请确认 Cursor 或 Grok Bot 已登录。")
        }
        var request = URLRequest(url: usageURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("AIQuotaMonitor/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                await CursorAccount.invalidateAuth()
                return failed("登录已失效，请在 Cursor 或 Grok Bot 里重新登录")
            }
            guard (200..<300).contains(code) else {
                return failed("Grok Bot 用量接口返回 \(code)")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return failed("Grok Bot 用量接口无返回")
            }
            return parse(obj)
        } catch {
            return failed("Grok Bot 读取失败")
        }
    }

    static func openApp() {
        let app = URL(fileURLWithPath: "/Applications/Grok Bot.app")
        if FileManager.default.fileExists(atPath: app.path) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard")!)
        }
    }

    static func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard?tab=usage")!)
    }

    private static func parse(_ raw: [String: Any]) -> GrokBotSnapshot {
        guard let percent = number(raw["usagePercent"]) else {
            return failed(raw["error"] as? String ?? "Grok Bot 没有返回周池用量")
        }
        let resets = parseDate(raw["nextResetTimestampUtc"] as? String)
        let start = parseDate(raw["currentPeriodStart"] as? String)
        let mins: Int? = {
            guard let start, let resets, resets > start else { return 7 * 1440 }
            return max(1, Int(resets.timeIntervalSince(start) / 60))
        }()

        var snap = GrokBotSnapshot()
        snap.fetchedAt = Date()
        snap.origin = .grokBot
        snap.planLabel = raw["grokPlanLabel"] as? String
        snap.cursorPlanName = raw["cursorPlanName"] as? String
        snap.hasAvailableUsage = raw["hasAvailableUsage"] as? Bool
        snap.quotaSuccessAt = Date()
        snap.windows = [
            QuotaWindow(
                id: "grok-bot-weekly",
                title: "每周",
                usedPercent: max(0, min(100, percent)),
                resetsAt: resets,
                durationMins: mins
            )
        ]
        return snap
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func failed(_ message: String) -> GrokBotSnapshot {
        var snap = GrokBotSnapshot()
        snap.fetchedAt = Date()
        snap.errorMessage = message
        return snap
    }
}

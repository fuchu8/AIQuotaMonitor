import Foundation

// MARK: - 版本

enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.6"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "4"
    }
}

// MARK: - 数据来源

/// 每个指标的来源，UI 上必须如实展示，不允许把非官方数据伪装成官方数据。
enum DataOrigin: String, Codable {
    /// OpenAI 官方 Codex App Server（account/rateLimits/read）
    case codexAppServer
    /// Cursor 官方 Admin API（仅 Team / Enterprise 套餐可用）
    case cursorAdminAPI
    /// Cursor 桌面 / CLI 登录态调用的账户用量接口（非公开稳定 API）
    case cursorAccount
    /// 用户从 Cursor 官方 Dashboard 导出的 CSV
    case cursorCSV
    /// 用户手动录入
    case manual
    /// 本地文件推断（Cursor 客户端元数据 / 本地调用记录）
    case localMetadata
    /// OpenCode Go 官方用量接口
    case openCodeGo
    /// OpenCode Go Token：本机 ModelProvider 日志汇总（路径仍可能在 WorkBuddy 日志目录）
    case openCodeGoLocal
    /// Grok Bot 周池（DashboardService/GetSandUsageStatus）
    case grokBot
    /// 拿不到
    case unavailable

    var label: String {
        switch self {
        case .codexAppServer: return "Codex App Server"
        case .cursorAdminAPI: return "Cursor Admin API"
        case .cursorAccount: return "Cursor 账户接口"
        case .cursorCSV: return "官方 CSV 导入"
        case .manual: return "手动录入"
        case .localMetadata: return "本地元数据"
        case .openCodeGo: return "OpenCode Go"
        case .openCodeGoLocal: return "Go 本机日志"
        case .grokBot: return "Grok Bot"
        case .unavailable: return "不可用"
        }
    }
}

// MARK: - 额度窗口

/// 一个额度窗口（例如 5 小时 / 每周），窗口长度由接口返回，不做任何硬编码假设。
struct QuotaWindow: Identifiable, Equatable, Codable {
    var id: String
    var title: String
    /// 已使用百分比（0...100）。解析时字段缺失不得默认成 0。
    var usedPercent: Double
    var resetsAt: Date?
    var durationMins: Int?
    /// 所属额度池 id（Codex limitId 等），用于去重与 Credits 归属
    var limitId: String? = nil

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var isExhausted: Bool { usedPercent >= 100 }

    /// 已用几乎为 0，且重置时间贴着「现在 + 整个窗口」。
    /// Codex 的空闲 5 小时窗口会这样滑动，倒计时不会往下走。
    var isIdleSliding: Bool {
        guard usedPercent < 1, let mins = durationMins, mins > 0, let seconds = secondsToReset else {
            return false
        }
        let expected = TimeInterval(mins * 60)
        return abs(seconds - expected) < 180
    }

    /// 距离重置的秒数（负数代表已过期）
    var secondsToReset: TimeInterval? {
        guard let resetsAt else { return nil }
        return resetsAt.timeIntervalSinceNow
    }

    /// 根据窗口长度生成人类可读标题，接口给什么就显示什么。
    static func title(forDuration mins: Int?) -> String {
        guard let mins, mins > 0 else { return "额度窗口" }
        if mins % 1440 == 0 {
            let days = mins / 1440
            if days == 7 { return "每周" }
            return "\(days) 天"
        }
        if mins % 60 == 0 {
            let hours = mins / 60
            if hours == 5 { return "5 小时" }
            return "\(hours) 小时"
        }
        return "\(mins) 分钟"
    }

    /// 优先使用接口返回的 limitName，否则按窗口长度推导。
    static func identifier(index: Int, limitId: String?) -> String {
        if let limitId, !limitId.isEmpty { return "\(limitId)#\(index)" }
        return "window#\(index)"
    }
}

// MARK: - Codex

struct DailyTokenBucket: Identifiable, Equatable, Codable {
    var id: String { startDate }
    var startDate: String   // yyyy-MM-dd
    var tokens: Int64
}

struct CodexSnapshot: Equatable {
    var windows: [QuotaWindow] = []
    var email: String?
    var planType: String?
    var workspaceName: String?
    var accountType: String?

    var hasCredits: Bool = false
    var unlimitedCredits: Bool = false
    var creditsBalance: String?
    /// Credits 归属的额度池
    var creditsLimitId: String?

    var resetCreditsAvailable: Int?
    var rateLimitReachedType: String?
    var ordinaryUsageAllowed: Bool?

    var lifetimeTokens: Int64?
    var peakDailyTokens: Int64?
    var dailyBuckets: [DailyTokenBucket] = []

    var fetchedAt: Date = .distantPast
    var quotaSuccessAt: Date?
    var tokenSuccessAt: Date?
    var origin: DataOrigin = .unavailable
    var errorMessage: String?
    /// 本轮额度抓取失败但界面仍展示上一轮成功数据
    var quotaStale: Bool = false
    /// 本轮 Token 抓取失败但保留旧桶
    var tokenStale: Bool = false

    /// 今日 Token（用后端逐日桶，不做任何估算）
    func tokens(on day: Date) -> Int64? {
        let key = Fmt.dayKey(day)
        return dailyBuckets.first { $0.startDate == key }?.tokens
    }

    /// 本周（近 7 天）Token 求和
    var last7DaysTokens: Int64? {
        guard !dailyBuckets.isEmpty else { return nil }
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
        let cutoffKey = Fmt.dayKey(cutoff)
        let rows = dailyBuckets.filter { $0.startDate >= cutoffKey }
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.tokens }
    }

    /// 菜单栏代表窗口：剩余最少的那个（最能反映风险）
    var tightestWindow: QuotaWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var primaryWindow: QuotaWindow? {
        windows.first
    }
}

// MARK: - Cursor

struct CursorModelUsage: Identifiable, Equatable, Codable {
    var id: String { model }
    var model: String
    var tokens: Int64
    var calls: Int
    var costCents: Double?
}

struct CursorSnapshot: Equatable {
    var appVersion: String?
    var email: String?
    var planType: String?
    var subscriptionStatus: String?

    /// 订阅额度窗口（只有官方接口 / CSV / 手动才有；拿不到就是 nil，绝不臆造）
    var quotaWindows: [QuotaWindow] = []
    /// 额度百分比的具体来源
    var quotaOrigin: DataOrigin = .unavailable

    /// 当前周期内已统计的 Token（来自官方 CSV，非额度百分比）
    var cycleTokens: Int64?
    var cycleCostCents: Double?
    var modelUsage: [CursorModelUsage] = []

    /// 本地官方客户端记录的 AI 代码片段调用量（真实计数，不是额度）
    var todayCalls: Int?
    var weekCalls: Int?

    /// 账户聚合接口：输入 + 输出 Token（不含缓存读取）
    var todayTokens: Int64?
    /// 当前计费周期合计
    var periodTokens: Int64?
    /// 接口可查范围（约近 90 天），不是账号全历史
    var lifetimeTokens: Int64?
    /// 累计口径说明
    var lifetimeTokensNote: String? = "近 90 天"

    var dataNote: String?
    var fetchedAt: Date = .distantPast
    var quotaSuccessAt: Date?
    var tokenSuccessAt: Date?
    var errorMessage: String?
    var quotaStale: Bool = false
    var tokenStale: Bool = false
    var tokenErrorMessage: String?

    var hasQuotaData: Bool { !quotaWindows.isEmpty }

    /// 菜单栏用：最紧张的窗口
    var tightestWindow: QuotaWindow? {
        quotaWindows.min { $0.remainingPercent < $1.remainingPercent }
    }

    /// 菜单栏展示用：固定取 Cursor Models（auto），不用 Other Models。
    var menuBarWindow: QuotaWindow? {
        quotaWindows.first(where: { $0.id == "cursor-models" })
            ?? quotaWindows.first(where: { $0.title == "Cursor Models" })
            ?? tightestWindow
    }
}

// MARK: - 分析 / Go / Grok

struct WindowAnalysis: Equatable {
    var rate: Double?
    var eta: Date?
}

struct OpenCodeGoSnapshot: Equatable {
    var windows: [QuotaWindow] = []
    var fetchedAt: Date = .distantPast
    var quotaSuccessAt: Date?
    var tokenSuccessAt: Date?
    var origin: DataOrigin = .unavailable
    var errorMessage: String?
    var quotaStale: Bool = false
    var rateLimited: Bool = false
    /// 今日 Token（本机日志，输入去缓存 + 输出）
    var todayTokens: Int64?
    /// 有可靠起点才叫本周期；否则见 periodLabel
    var periodTokens: Int64?
    var periodLabel: String = "本周期"
    /// 日志可覆盖范围内的累计（非账号全历史）
    var lifetimeTokens: Int64?
    var tokenOrigin: DataOrigin = .unavailable
    var tokenErrorMessage: String?
    var tokenStale: Bool = false
    /// Token 覆盖起止日（yyyy-MM-dd），来自本机日志实际范围
    var tokenCoverageStart: String?
    var tokenCoverageEnd: String?
    var tokenSkippedFiles: Int = 0
    var tokenIncomplete: Bool = false
    /// 模型白名单匹配是否仅为估算（无 provider/endpoint 确认）
    var tokenEstimatedByModel: Bool = true

    var hasData: Bool { !windows.isEmpty }

    var hasTokenData: Bool {
        todayTokens != nil || periodTokens != nil || lifetimeTokens != nil
    }

    var tightestWindow: QuotaWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }
}

struct GrokBotSnapshot: Equatable {
    var windows: [QuotaWindow] = []
    var fetchedAt: Date = .distantPast
    var quotaSuccessAt: Date?
    var origin: DataOrigin = .unavailable
    var errorMessage: String?
    var quotaStale: Bool = false
    var planLabel: String?
    var cursorPlanName: String?
    var hasAvailableUsage: Bool?

    var hasData: Bool { !windows.isEmpty }

    var tightestWindow: QuotaWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }
}

// MARK: - 时间格式化

enum Fmt {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M 月 d 日 HH:mm"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func countdown(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "已重置" }
        let total = Int(seconds)
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(max(m, 1)) 分钟"
    }

    static func compactTokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let v = Double(value)
        switch value {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(value)"
        }
    }

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    static func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }

    static func percent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    static func count(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum PanelRoute {
    case main, settings, cursorManual
}

struct PanelView: View {
    @EnvironmentObject private var store: QuotaStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var chrome: PanelChrome // 由 StatusBar 注入；hosting 钉满后高度随 bounds 更新
    @State private var route: PanelRoute

    init(initialRoute: PanelRoute = .main) {
        _route = State(initialValue: initialRoute)
    }

    var body: some View {
        Group {
            switch route {
            case .main:
                MainPanel(route: $route)
            case .settings:
                SettingsView(route: $route)
            case .cursorManual:
                CursorManualView(route: $route)
            }
        }
        // 铺满 hosting（由 AppKit 钉在 popover 内容区），避免固定宽高左对齐造成右空与顶底裁切。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 背景保持透明，让系统 NSPopover 自己的液态玻璃透出来（控制中心同款）。
        .background(Color.clear)
    }
}

// MARK: - 主面板

struct MainPanel: View {
    @EnvironmentObject private var store: QuotaStore
    @EnvironmentObject private var settings: SettingsStore
    @Binding var route: PanelRoute

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            HairLine()
            ScrollView {
                VStack(spacing: 9) {
                    CodexCard()
                    CursorCard(route: $route)
                    OpenCodeGoCard()
                    GrokBotCard()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(0)
            HairLine()
            footer
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text("AI Quota")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("aqm.panel.title")
            Spacer(minLength: 4)
            IconButton(systemName: settings.desktopWindowVisible ? "eye.slash" : "macwindow",
                       help: settings.desktopWindowVisible ? "隐藏桌面窗" : "显示桌面窗") {
                settings.desktopWindowVisible.toggle()
            }
            IconButton(systemName: "arrow.clockwise",
                       help: "立即刷新",
                       rotating: store.isRefreshing) {
                Task { await store.refresh() }
            }
            IconButton(systemName: "gearshape", help: "设置") {
                route = .settings
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aqm.panel.header")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(updatedText)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("aqm.panel.updated")
            Spacer(minLength: 4)
            Button("Codex") { store.openCodex() }
                .buttonStyle(SoftButtonStyle())
            Button("Cursor") { store.openCursor() }
                .buttonStyle(SoftButtonStyle())
            Button("Grok") { store.openGrokBot() }
                .buttonStyle(SoftButtonStyle())
            Menu {
                Button(settings.desktopWindowVisible ? "隐藏桌面窗" : "显示桌面窗") {
                    settings.desktopWindowVisible.toggle()
                }
                Divider()
                Button("Codex 用量页面") { store.openCodexUsagePage() }
                Button("Cursor 用量页面") { store.openCursorUsagePage() }
                Button("Grok Bot 用量") { store.openGrokBotUsagePage() }
                Button("OpenCode Go") { store.openOpenCode() }
                Divider()
                Button("设置…") { route = .settings }
                Divider()
                Button("退出 AI Quota Monitor") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityIdentifier("aqm.panel.footer")
    }

    private var updatedText: String {
        guard let date = store.lastSuccessAt else {
            return store.isRefreshing ? "正在读取…" : "尚未成功读取"
        }
        return "\(Fmt.clock(date)) 更新 · 每 \(settings.refreshMinutes) 分钟刷新"
    }
}

// MARK: - Codex 卡片

struct CodexCard: View {
    @EnvironmentObject private var store: QuotaStore
    @EnvironmentObject private var settings: SettingsStore

    private var snap: CodexSnapshot { store.codex }

    var body: some View {
        Card {
            header

            if snap.quotaStale || (snap.errorMessage != nil && !snap.windows.isEmpty) {
                Text("额度过期 · 上次成功 \(Fmt.clock(snap.quotaSuccessAt ?? snap.fetchedAt))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.warn)
                    .padding(.top, 4)
            }

            if snap.windows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(snap.windows) { window in
                        windowRow(window)
                    }
                }
                .padding(.top, 8)

                if settings.showTokenAnalysis && hasUsage {
                    HairLine().padding(.top, 9)
                    statsRow.padding(.top, 8)
                }

                HairLine().padding(.top, 9)
                metaRow.padding(.top, 7)
            }

            SourceLine(origin: snap.origin,
                       updatedAt: snap.quotaSuccessAt ?? (snap.fetchedAt == .distantPast ? nil : snap.fetchedAt),
                       error: snap.errorMessage,
                       stale: snap.quotaStale)
                .padding(.top, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(LinearGradient(colors: [Palette.codex.opacity(0.85), Palette.codex],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 7, height: 7)
            Text("Codex")
                .font(.system(size: 12.5, weight: .semibold))
            if let plan = planLabel {
                Badge(text: plan, tint: Palette.codex)
            }
            if snap.ordinaryUsageAllowed == false {
                Badge(text: "已限流", tint: Palette.danger)
            }
            Spacer()
            if settings.showTokenAnalysis == false, let tight = snap.tightestWindow {
                Text("\(Int(tight.remainingPercent))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.barTint(brand: Palette.codex, remaining: tight.remainingPercent))
            }
        }
    }

    private var planLabel: String? {
        guard let plan = snap.planType else {
            return snap.accountType == "apiKey" ? "API Key" : nil
        }
        switch plan {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "promax": return "Pro Max"
        case "team": return "Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based": return "Business"
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based": return "Enterprise"
        case "free": return "Free"
        case "go": return "Go"
        case "edu", "edu_plus", "edu_pro": return "Edu"
        default: return plan.capitalized
        }
    }

    private func windowRow(_ window: QuotaWindow) -> some View {
        let tint = Palette.barTint(brand: Palette.codex, remaining: window.remainingPercent)
        let metric = settings.menuBarMetric == .remaining ? window.remainingPercent : window.usedPercent
        let metricLabel = settings.menuBarMetric == .remaining ? "剩余" : "已用"
        let secondary = settings.menuBarMetric == .remaining ? window.usedPercent : window.remainingPercent
        let secondaryLabel = settings.menuBarMetric == .remaining ? "已用" : "剩余"
        let analysis = store.analysis["codex|\(window.id)"]

        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(metricLabel) \(Fmt.percent(metric))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if window.isExhausted {
                    Text("已用尽")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.danger)
                } else {
                    Text("\(secondaryLabel) \(Fmt.percent(secondary))")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            QuotaBar(remaining: window.remainingPercent, tint: tint)

            HStack(spacing: 4) {
                if window.isIdleSliding {
                    Text("空闲，窗口随使用滑动")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else {
                    CountdownText(date: window.resetsAt)
                }
                Spacer()
                if let eta = analysis?.eta {
                    Text("按当前速度 \(Fmt.countdown(eta.timeIntervalSinceNow))后触顶")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else if let rate = analysis?.rate, rate > 0.5 {
                    Text(String(format: "%.1f%%/小时", rate))
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var hasUsage: Bool {
        snap.lifetimeTokens != nil || !snap.dailyBuckets.isEmpty
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            StatColumn(label: "今日 Token", value: Fmt.compactTokens(snap.tokens(on: Date())))
                .help(snap.tokens(on: Date()) == nil
                      ? "后端尚未生成今日统计桶"
                      : "来自 Codex 官方 account/usage/read")
            Spacer()
            StatColumn(label: "近 7 天", value: Fmt.compactTokens(snap.last7DaysTokens))
                .help("最近 7 个自然日的 Token 合计")
            Spacer()
            StatColumn(label: "累计", value: Fmt.compactTokens(snap.lifetimeTokens))
            Spacer()
            StatColumn(label: "峰值/日", value: Fmt.compactTokens(snap.peakDailyTokens))
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let email = snap.email {
                Text(email)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if snap.unlimitedCredits {
                Badge(text: "Credits 不限", tint: Palette.good)
            } else if snap.hasCredits, let balance = snap.creditsBalance {
                Badge(text: "Credits \(balance)", tint: Palette.good)
            } else {
                Badge(text: "无额外 Credits", tint: .secondary)
            }
            if let n = snap.resetCreditsAvailable, n > 0 {
                Badge(text: "重置券 \(n)", tint: Palette.codex)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("未获取到额度数据")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(snap.errorMessage ?? "请确认 Codex CLI 已安装并已登录")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}

// MARK: - OpenCode Go

struct OpenCodeGoCard: View {
    @EnvironmentObject private var store: QuotaStore
    private var snap: OpenCodeGoSnapshot { store.opencode }

    var body: some View {
        Card {
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.opencode)
                    .frame(width: 7, height: 7)
                Text("OpenCode Go")
                    .font(.system(size: 12.5, weight: .semibold))
                if snap.rateLimited {
                    Badge(text: "已限流", tint: Palette.danger)
                }
                Spacer()
                Button("控制台") { store.openOpenCode() }
                    .buttonStyle(SoftButtonStyle(tint: Palette.opencode))
            }

            if snap.hasData {
                VStack(spacing: 8) {
                    ForEach(snap.windows) { window in
                        goRow(window)
                    }
                }
                .padding(.top, 8)
            } else {
                Text(snap.errorMessage ?? "未读到 OpenCode Go 额度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            if snap.hasTokenData || snap.tokenErrorMessage != nil {
                HairLine().padding(.top, 9)
                HStack(spacing: 0) {
                    StatColumn(label: "今日 Token", value: Fmt.compactTokens(snap.todayTokens))
                        .help("Go 本机日志：OpenCode Go 模型今日用量（输入去缓存 + 输出；模型名匹配估算）")
                    Spacer()
                    StatColumn(label: snap.periodLabel, value: Fmt.compactTokens(snap.periodTokens))
                        .help(snap.periodLabel == "本周期"
                              ? "对齐官方每月窗口起点；来自本机日志，跨设备不完整"
                              : "官方周期起点未知时按近 30 天估算；来自本机日志")
                    Spacer()
                    StatColumn(label: "累计", value: Fmt.compactTokens(snap.lifetimeTokens))
                        .help("本机日志可覆盖范围内的合计，不是账号全历史")
                }
                .padding(.top, 8)
                Group {
                    if snap.tokenStale {
                        Text(goTokenCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.warn)
                    } else {
                        Text(goTokenCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }

            SourceLine(origin: snap.hasData ? snap.origin : snap.tokenOrigin,
                       updatedAt: (snap.hasData ? snap.quotaSuccessAt : snap.tokenSuccessAt)
                        ?? (snap.fetchedAt == .distantPast ? nil : snap.fetchedAt),
                       error: snap.hasData ? snap.errorMessage : (snap.errorMessage ?? snap.tokenErrorMessage),
                       stale: snap.hasData ? snap.quotaStale : snap.tokenStale)
                .padding(.top, 6)
        }
    }

    private var goTokenCaption: String {
        var parts = ["Token：Go 本机日志"]
        if let start = snap.tokenCoverageStart, let end = snap.tokenCoverageEnd {
            parts.append("\(start)～\(end)")
        }
        if snap.tokenEstimatedByModel { parts.append("模型匹配估算") }
        if snap.tokenIncomplete { parts.append("覆盖不完整") }
        if snap.tokenSkippedFiles > 0 { parts.append("跳过 \(snap.tokenSkippedFiles) 个文件") }
        if snap.tokenStale { parts.append("过期") }
        if let err = snap.tokenErrorMessage, snap.hasData { parts.append(err) }
        return parts.joined(separator: " · ")
    }

    private func goRow(_ window: QuotaWindow) -> some View {
        let tint = Palette.barTint(brand: Palette.opencode, remaining: window.remainingPercent)
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已用 \(Fmt.percent(window.usedPercent))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            QuotaBar(remaining: window.remainingPercent, tint: tint)
            HStack {
                CountdownText(date: window.resetsAt)
                Spacer()
            }
        }
    }
}

// MARK: - Grok Bot

struct GrokBotCard: View {
    @EnvironmentObject private var store: QuotaStore
    private var snap: GrokBotSnapshot { store.grokbot }

    var body: some View {
        Card {
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.grokbot)
                    .frame(width: 7, height: 7)
                Text("Grok Bot")
                    .font(.system(size: 12.5, weight: .semibold))
                if let plan = snap.planLabel ?? snap.cursorPlanName {
                    Badge(text: plan, tint: .secondary)
                }
                Spacer()
                Button("打开") { store.openGrokBot() }
                    .buttonStyle(SoftButtonStyle(tint: Palette.grokbot))
            }

            if snap.hasData {
                VStack(spacing: 8) {
                    ForEach(snap.windows) { window in
                        grokRow(window)
                    }
                }
                .padding(.top, 8)
                Text("与 Grok / Cursor 共用周池")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            } else {
                Text(snap.errorMessage ?? "未读到 Grok Bot 周池")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            if snap.quotaStale {
                Text("周池过期 · 上次成功 \(Fmt.clock(snap.quotaSuccessAt ?? snap.fetchedAt))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.warn)
                    .padding(.top, 4)
            }

            SourceLine(origin: snap.origin,
                       updatedAt: snap.quotaSuccessAt ?? (snap.fetchedAt == .distantPast ? nil : snap.fetchedAt),
                       error: snap.errorMessage,
                       stale: snap.quotaStale)
                .padding(.top, 6)
        }
    }

    private func grokRow(_ window: QuotaWindow) -> some View {
        let tint = Palette.barTint(brand: Palette.grokbot, remaining: window.remainingPercent)
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已用 \(Fmt.percent(window.usedPercent))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            QuotaBar(remaining: window.remainingPercent, tint: tint)
            HStack {
                CountdownText(date: window.resetsAt)
                Spacer()
            }
        }
    }
}

// MARK: - Cursor 卡片

struct CursorCard: View {
    @EnvironmentObject private var store: QuotaStore
    @Binding var route: PanelRoute

    private var snap: CursorSnapshot { store.cursor }

    var body: some View {
        Card {
            header

            if snap.hasQuotaData {
                VStack(spacing: 8) {
                    ForEach(snap.quotaWindows) { window in
                        quotaBlock(window)
                    }
                }
            } else {
                unavailableBlock
            }

            if snap.todayTokens != nil || snap.periodTokens != nil || snap.lifetimeTokens != nil {
                HairLine().padding(.top, 9)
                HStack(spacing: 0) {
                    StatColumn(label: "今日 Token", value: Fmt.compactTokens(snap.todayTokens))
                        .help("本机时区今日 0 点起的输入 + 输出 Token")
                    Spacer()
                    StatColumn(label: "本周期", value: Fmt.compactTokens(snap.periodTokens))
                        .help("当前计费周期的输入 + 输出 Token")
                    Spacer()
                    StatColumn(label: snap.lifetimeTokensNote ?? "近 90 天",
                               value: Fmt.compactTokens(snap.lifetimeTokens))
                        .help("接口可查范围约近 90 天，不是账号全历史；不含缓存读取")
                }
                .padding(.top, 8)
                if snap.tokenStale || snap.tokenErrorMessage != nil {
                    Text(snap.tokenErrorMessage.map { "Token：\($0)" } ?? "Token 数据过期")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.warn)
                        .padding(.top, 4)
                }
            } else if let csv = store.cursorCSV {
                HairLine().padding(.top, 9)
                csvBlock(csv).padding(.top, 8)
            } else if let today = snap.todayCalls, let week = snap.weekCalls {
                HStack(spacing: 5) {
                    Text("本地 AI 代码片段")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("本周 \(Fmt.count(week)) · 今日 \(Fmt.count(today))")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 7)
            }

            SourceLine(origin: snap.hasQuotaData ? snap.quotaOrigin : (snap.planType != nil ? .localMetadata : .unavailable),
                       updatedAt: snap.quotaSuccessAt ?? (snap.fetchedAt == .distantPast ? nil : snap.fetchedAt),
                       error: snap.errorMessage,
                       stale: snap.quotaStale)
                .padding(.top, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(LinearGradient(colors: [Palette.cursor.opacity(0.85), Palette.cursor],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 7, height: 7)
            Text("Cursor")
                .font(.system(size: 12.5, weight: .semibold))
            if let plan = snap.planType {
                Badge(text: plan.capitalized, tint: Palette.cursor)
            }
            if let status = snap.subscriptionStatus, status.lowercased() != "active" {
                Badge(text: status, tint: Palette.warn)
            }
            Spacer()
            if let version = snap.appVersion {
                Text("v\(version)")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private func quotaBlock(_ window: QuotaWindow) -> some View {
        let tint = Palette.barTint(brand: Palette.cursor, remaining: window.remainingPercent)
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if snap.quotaOrigin == .manual {
                    Badge(text: "手动录入", tint: Palette.warn)
                }
                Spacer()
                Text("剩余 \(Fmt.percent(window.remainingPercent))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            QuotaBar(remaining: window.remainingPercent, tint: tint)
            HStack {
                CountdownText(date: window.resetsAt)
                Spacer()
                if snap.quotaOrigin == .manual {
                    Button("修改") { route = .cursorManual }
                        .buttonStyle(SoftButtonStyle())
                }
            }
        }
        .padding(.top, 8)
    }

    private var unavailableBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.warn)
                Text("本次未能读取额度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(snap.errorMessage ?? "登录 Cursor 后会读取 Cursor Models 和 Other Models 两个用量池（账户接口，非公开稳定 API）。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)

            HStack(spacing: 6) {
                Button("导入官方 CSV") { pickCSV() }
                    .buttonStyle(SoftButtonStyle(tint: Palette.cursor, filled: true))
                Button("手动填写") { route = .cursorManual }
                    .buttonStyle(SoftButtonStyle())
                Button("用量页面") { store.openCursorUsagePage() }
                    .buttonStyle(SoftButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.top, 8)
    }

    private func csvBlock(_ csv: CursorCSVSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                StatColumn(label: "周期 Token", value: Fmt.compactTokens(csv.totalTokens))
                Spacer()
                StatColumn(label: "调用次数", value: "\(csv.rowCount)")
                Spacer()
                if let cents = csv.costCents {
                    StatColumn(label: "记录费用", value: String(format: "$%.2f", cents / 100))
                } else {
                    StatColumn(label: "费用", value: "Included")
                }
            }
            if let start = csv.rangeStart, let end = csv.rangeEnd {
                Text("\(shortDate(start)) – \(shortDate(end)) · \(csv.fileName)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let top = csv.byModel.prefix(2).first {
                Text("Top 模型 " + csv.byModel.prefix(2)
                        .map { "\(shortModel($0.model)) \(Fmt.compactTokens($0.tokens))" }
                        .joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .accessibilityLabel(top.model)
            }
        }
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    private func shortModel(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "gpt-", with: "gpt-")
    }

    private func pickCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 Cursor Dashboard → Usage → Export CSV 导出的文件"
        panel.prompt = "导入"
        if panel.runModal() == .OK, let url = panel.url {
            store.importCursorCSV(from: url)
            if let csv = store.cursorCSV {
                Notifier.shared.post(title: "Cursor CSV 已导入",
                                     body: "\(csv.rowCount) 条记录 · \(Fmt.compactTokens(csv.totalTokens)) Token")
            }
        }
    }
}

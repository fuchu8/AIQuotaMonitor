import Foundation
import Combine
import AppKit
import WidgetSupport

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AIQuotaMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var cursorCSVFile: URL {
        supportDirectory.appendingPathComponent("cursor-usage.json")
    }
}

@MainActor
final class QuotaStore: ObservableObject {
    static let shared = QuotaStore()

    @Published private(set) var codex = CodexSnapshot()
    @Published private(set) var cursor = CursorSnapshot()
    @Published private(set) var opencode = OpenCodeGoSnapshot()
    @Published private(set) var grokbot = GrokBotSnapshot()
    @Published private(set) var analysis: [String: WindowAnalysis] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var cursorCSV: CursorCSVSummary?
    @Published private(set) var loginItemError: String?

    let settings = SettingsStore.shared
    enum RefreshReason { case timer, panel, manual, wake }

    private let codexClient = CodexClient()
    private let history = HistoryStore.shared
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var sideEffects = true
    private var panelOpen = false
    private var unchangedStreak = 0
    private var failureStreak: [String: Int] = [:]
    private var lastSignature = ""
    private var lastUsageFetch: Date?
    private var seenQuota: [String: AlertEvaluator.SeenQuota] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var refreshGeneration = 0

    private init() {
        cursorCSV = Self.loadCSV()
        if let data = UserDefaults.standard.data(forKey: "quotaAlertSeen"),
           let saved = try? JSONDecoder().decode([String: AlertEvaluator.SeenQuota].self, from: data) {
            seenQuota = saved
        } else if let data = UserDefaults.standard.data(forKey: "quotaAlertSeen"),
                  let legacy = try? JSONDecoder().decode([String: LegacySeen].self, from: data) {
            seenQuota = legacy.mapValues {
                AlertEvaluator.SeenQuota(resetsAt: $0.resetsAt, used: $0.used, cycleKey: "")
            }
        }
    }

    private struct LegacySeen: Codable {
        var resetsAt: Double
        var used: Double
    }

    // MARK: 生命周期

    /// 诊断和离屏渲染走 `sideEffects: false`，不写历史、不发通知。
    func start(sideEffects: Bool = true) {
        guard !started else { return }
        started = true
        self.sideEffects = sideEffects
        if sideEffects {
            Notifier.shared.requestAuthorization()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refresh(reason: .wake) }
            }
            reschedule(using: settings.refreshMinutes)
            settings.$refreshMinutes
                .dropFirst()
                .sink { [weak self] minutes in
                    // 必须使用发布出来的新值；回读 @Published 可能仍是旧值
                    self?.reschedule(using: minutes)
                }
                .store(in: &cancellables)
        }
        Task { await refresh(reason: .timer) }
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        guard sideEffects else { return }
        reschedule(using: settings.refreshMinutes)
        if open { Task { await refresh(reason: .panel) } }
    }

    private func reschedule(using minutes: Int) {
        timer?.invalidate()
        guard sideEffects else { return }
        let interval = effectiveInterval(baseMinutes: minutes)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: .timer) }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 各来源独立退避；整体定时器用各来源最大退避与不变 streak 的综合结果。
    private func effectiveInterval(baseMinutes: Int) -> TimeInterval {
        let base = TimeInterval(max(1, baseMinutes) * 60)
        if panelOpen { return base }
        let maxFail = failureStreak.values.max() ?? 0
        if maxFail > 0 {
            let factor = pow(2.0, Double(min(maxFail, 3)))
            return min(30 * 60, base * factor)
        }
        if unchangedStreak >= 2 { return max(base, 15 * 60) }
        return base
    }

    // MARK: 刷新

    func refresh(reason: RefreshReason = .manual) async {
        if reason == .panel,
           let lastSuccessAt,
           Date().timeIntervalSince(lastSuccessAt) < 45,
           codex.errorMessage == nil,
           !codex.quotaStale {
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
                if sideEffects { reschedule(using: settings.refreshMinutes) }
            }
        }
        lastAttemptAt = Date()

        let forceTokens = reason == .manual || reason == .wake
        let includeUsage = forceTokens
            || lastUsageFetch == nil
            || Date().timeIntervalSince(lastUsageFetch!) > 30 * 60
        let manual = settings.cursorManual
        let csv = cursorCSV
        let previousCursor = cursor

        // 各来源独立完成、独立发布；一个失败不拖住其他来源的新鲜度展示
        async let codexDone: Void = refreshCodex(includeUsage: includeUsage, generation: generation)
        async let cursorDone: Void = refreshCursor(manual: manual, csv: csv, previous: previousCursor, generation: generation)
        async let goDone: Void = refreshGo(forceToken: forceTokens || reason == .panel, generation: generation)
        async let grokDone: Void = refreshGrok(generation: generation)
        _ = await (codexDone, cursorDone, goDone, grokDone)

        guard generation == refreshGeneration else { return }

        let signature = quotaSignature()
        let changed = signature != lastSignature
        if changed {
            unchangedStreak = 0
            lastSignature = signature
        } else {
            unchangedStreak += 1
        }

        if [codex.quotaSuccessAt, cursor.quotaSuccessAt, opencode.quotaSuccessAt, grokbot.quotaSuccessAt]
            .compactMap({ $0 }).contains(where: { Date().timeIntervalSince($0) < 120 }) {
            lastSuccessAt = Date()
        }

        publishWidgetSnapshot()
        guard sideEffects else { return }
        publishAnalysis()
        evaluateAlerts()
        if changed { AppLog.write(summaryLine()) }
    }

    /// 写入脱敏快照供桌面小组件消费；不含邮箱/令牌/密钥。
    func publishWidgetSnapshot() {
        let codexWindow = representativeCodexWindow
        let cursorWindow = cursor.menuBarWindow
        let goWindow = opencode.tightestWindow
        let grokWindow = grokbot.tightestWindow
        let anyStale = codex.quotaStale || cursor.quotaStale || opencode.quotaStale || grokbot.quotaStale
        let snap = WidgetSnapshot(
            updatedAt: lastSuccessAt ?? lastAttemptAt ?? Date(),
            refreshMinutes: settings.refreshMinutes,
            stale: anyStale,
            note: "由主程序刷新；小组件跟随系统时间线，非实时",
            items: [
                WidgetSnapshotStore.item(
                    id: "codex",
                    title: "Codex",
                    windowTitle: codexWindow?.title,
                    remaining: codexWindow?.remainingPercent,
                    used: codexWindow?.usedPercent,
                    resetsAt: codexWindow?.resetsAt,
                    stale: codex.quotaStale,
                    error: codex.errorMessage
                ),
                WidgetSnapshotStore.item(
                    id: "cursor",
                    title: "Cursor",
                    windowTitle: cursorWindow?.title,
                    remaining: cursorWindow?.remainingPercent,
                    used: cursorWindow?.usedPercent,
                    resetsAt: cursorWindow?.resetsAt,
                    stale: cursor.quotaStale,
                    error: cursor.errorMessage
                ),
                WidgetSnapshotStore.item(
                    id: "go",
                    title: "OpenCode Go",
                    windowTitle: goWindow?.title,
                    remaining: goWindow?.remainingPercent,
                    used: goWindow?.usedPercent,
                    resetsAt: goWindow?.resetsAt,
                    stale: opencode.quotaStale,
                    error: opencode.errorMessage,
                    subtitle: opencode.hasTokenData ? "Token：Go 本机日志" : nil
                ),
                WidgetSnapshotStore.item(
                    id: "grok",
                    title: "Grok Bot",
                    windowTitle: grokWindow?.title,
                    remaining: grokWindow?.remainingPercent,
                    used: grokWindow?.usedPercent,
                    resetsAt: grokWindow?.resetsAt,
                    stale: grokbot.quotaStale,
                    error: grokbot.errorMessage
                )
            ]
        )
        WidgetSnapshotStore.save(snap)
    }

    private func refreshCodex(includeUsage: Bool, generation: Int) async {
        let result: Result<CodexSnapshot, Error>
        do {
            result = .success(try await codexClient.fetch(includeUsage: includeUsage))
        } catch {
            result = .failure(error)
        }
        guard generation == refreshGeneration else { return }

        switch result {
        case .success(var snap):
            if snap.windows.isEmpty {
                bumpFailure("codex")
                var failed = codex
                failed.errorMessage = snap.errorMessage ?? "接口未返回额度窗口"
                failed.quotaStale = !failed.windows.isEmpty
                failed.fetchedAt = Date()
                codex = failed
                if sideEffects { AppLog.write("Codex 刷新失败：\(failed.errorMessage ?? "")") }
            } else {
                if snap.dailyBuckets.isEmpty {
                    // Token 未刷新：保留旧桶，标 stale（若本轮本不该拉 Token 则不标失败）
                    if includeUsage {
                        snap.dailyBuckets = codex.dailyBuckets
                        snap.lifetimeTokens = snap.lifetimeTokens ?? codex.lifetimeTokens
                        snap.peakDailyTokens = snap.peakDailyTokens ?? codex.peakDailyTokens
                        snap.tokenStale = true
                        snap.tokenSuccessAt = codex.tokenSuccessAt
                    } else {
                        snap.dailyBuckets = codex.dailyBuckets
                        snap.lifetimeTokens = snap.lifetimeTokens ?? codex.lifetimeTokens
                        snap.peakDailyTokens = snap.peakDailyTokens ?? codex.peakDailyTokens
                        snap.tokenSuccessAt = codex.tokenSuccessAt
                        snap.tokenStale = codex.tokenStale
                    }
                } else {
                    lastUsageFetch = Date()
                    snap.tokenStale = false
                }
                snap.quotaStale = false
                codex = snap
                clearFailure("codex")
                if sideEffects {
                    for window in snap.windows {
                        history.record(provider: "codex", window: window)
                    }
                }
            }
        case .failure(let error):
            bumpFailure("codex")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            var failed = codex
            failed.errorMessage = message
            failed.quotaStale = !failed.windows.isEmpty
            failed.fetchedAt = Date()
            if codex.windows.isEmpty { failed.origin = .unavailable }
            codex = failed
            if sideEffects { AppLog.write("Codex 刷新失败：\(message)") }
        }
    }

    private func refreshCursor(manual: CursorManualEntry?, csv: CursorCSVSummary?, previous: CursorSnapshot, generation: Int) async {
        async let builtTask = Task.detached(priority: .utility) {
            CursorProvider.build(manual: manual, csv: csv, previous: previous)
        }.value
        async let quotaTask = CursorAccount.fetch()
        let (built, quota) = await (builtTask, quotaTask)
        guard generation == refreshGeneration else { return }

        var snap = apply(quota, to: built)
        if quota.quotaOK {
            snap.quotaStale = false
            snap.quotaSuccessAt = Date()
            clearFailure("cursor")
            if sideEffects, snap.quotaOrigin == .cursorAccount {
                for window in snap.quotaWindows {
                    history.record(provider: "cursor", window: window)
                }
            }
        } else if !previous.quotaWindows.isEmpty, manual == nil {
            // 保留旧额度，标注过期
            snap.quotaWindows = previous.quotaWindows
            snap.quotaOrigin = previous.quotaOrigin
            snap.quotaSuccessAt = previous.quotaSuccessAt
            snap.quotaStale = true
            snap.errorMessage = quota.error ?? previous.errorMessage
            bumpFailure("cursor")
        } else {
            bumpFailure("cursor")
        }

        if quota.tokenOK {
            snap.tokenStale = false
            snap.tokenSuccessAt = Date()
            snap.tokenErrorMessage = nil
        } else if previous.todayTokens != nil || previous.periodTokens != nil || previous.lifetimeTokens != nil {
            if snap.todayTokens == nil { snap.todayTokens = previous.todayTokens }
            if snap.periodTokens == nil { snap.periodTokens = previous.periodTokens }
            if snap.lifetimeTokens == nil {
                snap.lifetimeTokens = previous.lifetimeTokens
                snap.lifetimeTokensNote = previous.lifetimeTokensNote
            }
            snap.tokenStale = true
            snap.tokenSuccessAt = previous.tokenSuccessAt
            snap.tokenErrorMessage = quota.tokenError ?? quota.error
        } else {
            snap.tokenErrorMessage = quota.tokenError
        }
        cursor = snap
    }

    private func refreshGo(forceToken: Bool, generation: Int) async {
        let go = await OpenCodeGoProvider.fetch(forceToken: forceToken)
        guard generation == refreshGeneration else { return }

        var next = go
        let previous = opencode

        if go.hasData {
            next.quotaStale = false
            clearFailure("opencode")
            if sideEffects {
                for window in go.windows {
                    history.record(provider: "opencode", window: window)
                }
            }
        } else if previous.hasData {
            // 额度失败但 Token 成功：绝不能清掉旧窗口
            next.windows = previous.windows
            next.origin = previous.origin
            next.quotaSuccessAt = previous.quotaSuccessAt
            next.rateLimited = previous.rateLimited
            next.quotaStale = true
            next.errorMessage = go.errorMessage
            bumpFailure("opencode")
        } else {
            bumpFailure("opencode")
        }

        if go.hasTokenData {
            next.todayTokens = go.todayTokens
            next.periodTokens = go.periodTokens
            next.lifetimeTokens = go.lifetimeTokens
            next.tokenOrigin = go.tokenOrigin
            next.tokenSuccessAt = go.tokenSuccessAt ?? Date()
            next.tokenCoverageStart = go.tokenCoverageStart
            next.tokenCoverageEnd = go.tokenCoverageEnd
            next.tokenSkippedFiles = go.tokenSkippedFiles
            next.tokenIncomplete = go.tokenIncomplete
            next.tokenEstimatedByModel = go.tokenEstimatedByModel
            next.periodLabel = go.periodLabel
            next.tokenStale = false
            next.tokenErrorMessage = go.tokenErrorMessage
        } else if previous.hasTokenData {
            next.todayTokens = previous.todayTokens
            next.periodTokens = previous.periodTokens
            next.lifetimeTokens = previous.lifetimeTokens
            next.tokenOrigin = previous.tokenOrigin
            next.tokenSuccessAt = previous.tokenSuccessAt
            next.tokenCoverageStart = previous.tokenCoverageStart
            next.tokenCoverageEnd = previous.tokenCoverageEnd
            next.periodLabel = previous.periodLabel
            next.tokenStale = true
            next.tokenErrorMessage = go.tokenErrorMessage ?? "本机日志 Token 本轮未更新"
        } else {
            next.tokenErrorMessage = go.tokenErrorMessage
        }

        // fetchedAt：额度成功用额度时间；否则保留展示用时间戳
        if go.hasData {
            next.fetchedAt = go.fetchedAt
        } else if go.hasTokenData {
            next.fetchedAt = go.tokenSuccessAt ?? go.fetchedAt
        } else {
            next.fetchedAt = Date()
        }
        opencode = next
    }

    private func refreshGrok(generation: Int) async {
        let grok = await GrokBotProvider.fetch()
        guard generation == refreshGeneration else { return }

        if grok.hasData {
            var snap = grok
            snap.quotaStale = false
            snap.quotaSuccessAt = Date()
            grokbot = snap
            clearFailure("grokbot")
            if sideEffects {
                for window in snap.windows {
                    history.record(provider: "grokbot", window: window)
                }
            }
        } else if grokbot.hasData {
            var kept = grokbot
            kept.errorMessage = grok.errorMessage
            kept.quotaStale = true
            kept.fetchedAt = Date()
            grokbot = kept
            bumpFailure("grokbot")
        } else {
            grokbot = grok
            bumpFailure("grokbot")
        }
    }

    private func bumpFailure(_ key: String) {
        failureStreak[key, default: 0] += 1
    }

    private func clearFailure(_ key: String) {
        failureStreak[key] = 0
    }

    private func apply(_ quota: CursorAccount.Quota, to built: CursorSnapshot) -> CursorSnapshot {
        var snap = built
        if !quota.windows.isEmpty {
            snap.quotaWindows = quota.windows
            snap.quotaOrigin = .cursorAccount
            if snap.errorMessage == "未检测到 Cursor 客户端" { snap.errorMessage = nil }
        } else if snap.quotaWindows.isEmpty {
            snap.quotaOrigin = .unavailable
            snap.errorMessage = quota.error ?? snap.errorMessage ?? "本次未能读取 Cursor 额度"
        } else if let err = quota.error {
            snap.errorMessage = err
        }
        if let today = quota.todayTokens { snap.todayTokens = today }
        if let period = quota.periodTokens { snap.periodTokens = period }
        if let life = quota.lifetimeTokens {
            snap.lifetimeTokens = life
            snap.lifetimeTokensNote = quota.lifetimeNote
        }
        snap.tokenErrorMessage = quota.tokenError
        return snap
    }

    private func quotaSignature() -> String {
        let codexPart = codex.windows.map { "\($0.id):\(Int($0.usedPercent))" }.joined(separator: ",")
        let cursorPart = cursor.quotaWindows.map { "\($0.id):\(Int($0.usedPercent))" }.joined(separator: ",")
        let goPart = opencode.windows.map { "\($0.id):\(Int($0.usedPercent))" }.joined(separator: ",")
        let grokPart = grokbot.windows.map { "\($0.id):\(Int($0.usedPercent))" }.joined(separator: ",")
        return [codexPart, cursorPart, goPart, grokPart].joined(separator: "|")
    }

    private func summaryLine() -> String {
        let codexText = codex.windows.map { "\($0.title) \(Int($0.usedPercent))%" }.joined(separator: ", ")
        let cursorText = cursor.quotaWindows.map { "\($0.title) \(Int($0.usedPercent))%" }.joined(separator: ", ")
        let goText = opencode.windows.map { "\($0.title) \(Int($0.usedPercent))%" }.joined(separator: ", ")
        let grokText = grokbot.windows.map { "\($0.title) \(Int($0.usedPercent))%" }.joined(separator: ", ")
        return "刷新：Codex \(codexText.isEmpty ? (codex.errorMessage ?? "—") : codexText)；Cursor \(cursorText.isEmpty ? (cursor.errorMessage ?? "—") : cursorText)；Go \(goText.isEmpty ? (opencode.errorMessage ?? "—") : goText)；Grok \(grokText.isEmpty ? (grokbot.errorMessage ?? "—") : grokText)"
    }

    private func publishAnalysis() {
        var next: [String: WindowAnalysis] = [:]
        func store(_ provider: String, _ windows: [QuotaWindow], stale: Bool) {
            guard !stale else { return }
            for window in windows {
                next["\(provider)|\(window.id)"] = WindowAnalysis(
                    rate: history.burnRate(provider: provider, window: window),
                    eta: history.estimateExhaustion(provider: provider, window: window)
                )
            }
        }
        store("codex", codex.windows, stale: codex.quotaStale)
        store("cursor", cursor.quotaWindows, stale: cursor.quotaStale)
        store("opencode", opencode.windows, stale: opencode.quotaStale)
        store("grokbot", grokbot.windows, stale: grokbot.quotaStale)
        analysis = next
    }

    // MARK: 告警

    private func evaluateAlerts() {
        consider("Codex", provider: "codex", windows: codex.windows, stale: codex.quotaStale)
        if cursor.quotaOrigin == .cursorAccount {
            consider("Cursor", provider: "cursor", windows: cursor.quotaWindows, stale: cursor.quotaStale)
        }
        consider("OpenCode Go", provider: "opencode", windows: opencode.windows, stale: opencode.quotaStale)
        consider("Grok Bot", provider: "grokbot", windows: grokbot.windows, stale: grokbot.quotaStale)
        if let data = try? JSONEncoder().encode(seenQuota) {
            UserDefaults.standard.set(data, forKey: "quotaAlertSeen")
        }
    }

    private func consider(_ name: String, provider: String, windows: [QuotaWindow], stale: Bool) {
        guard !stale else { return }
        let evaluator = AlertEvaluator(
            alertAt10: settings.alertAt10,
            alertAt20: settings.alertAt20,
            notifyOnReset: settings.notifyOnReset
        )
        for window in windows {
            let id = "\(provider)|\(window.id)"
            let decision = evaluator.consider(
                name: name,
                provider: provider,
                window: window,
                previous: seenQuota[id]
            )
            if decision.clearAlertPrefix {
                Notifier.shared.forget(prefix: "alert-\(id)-")
            }
            if decision.sendResetNotification, let key = decision.resetKey {
                Notifier.shared.notifyOnce(
                    key: key,
                    title: "\(name) 额度已重置",
                    body: "\(window.title) 已更新，当前已用 \(Int(window.usedPercent))%。"
                )
            }
            if decision.alert10, let key = decision.alert10Key {
                Notifier.shared.notifyOnce(
                    key: key,
                    title: "\(name) 额度不足 10%",
                    body: "\(window.title) 剩余 \(Int(window.remainingPercent))%。"
                )
            } else if decision.alert20, let key = decision.alert20Key {
                Notifier.shared.notifyOnce(
                    key: key,
                    title: "\(name) 额度不足 20%",
                    body: "\(window.title) 剩余 \(Int(window.remainingPercent))%。"
                )
            }
            seenQuota[id] = decision.updatedSeen
        }
    }

    // MARK: 代表窗口

    var representativeCodexWindow: QuotaWindow? {
        switch settings.menuBarAggregate {
        case .tightest: return codex.tightestWindow
        case .shortest: return codex.primaryWindow
        }
    }

    // MARK: Cursor 导入

    func importCursorCSV(from url: URL) {
        do {
            let summary = try CursorProvider.importCSV(at: url)
            cursorCSV = summary
            Self.saveCSV(summary)
            Task { await refresh() }
        } catch {
            cursor.errorMessage = error.localizedDescription
            objectWillChange.send()
        }
    }

    func clearCursorCSV() {
        cursorCSV = nil
        try? FileManager.default.removeItem(at: AppPaths.cursorCSVFile)
        Task { await refresh() }
    }

    func applyCursorManual(percent: Double, resetsAt: Date, note: String) {
        settings.cursorManual = CursorManualEntry(usedPercent: percent,
                                                  resetsAt: resetsAt,
                                                  note: note,
                                                  updatedAt: Date())
        Task { await refresh() }
    }

    func clearCursorManual() {
        settings.cursorManual = nil
        Task { await refresh() }
    }

    // MARK: 开机启动

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        if enabled {
            do {
                try LaunchAgentManager.enable()
                settings.launchAtLogin = true
            } catch {
                settings.launchAtLogin = false
                loginItemError = error.localizedDescription
            }
        } else {
            LaunchAgentManager.disable()
            settings.launchAtLogin = false
        }
    }

    // MARK: 指标辅助

    func history(for provider: String, window: QuotaWindow) -> (rate: Double?, eta: Date?, trend: [Double]) {
        (history.burnRate(provider: provider, window: window),
         history.estimateExhaustion(provider: provider, window: window),
         history.trend(provider: provider, window: window))
    }

    // MARK: CSV 持久化

    private static func loadCSV() -> CursorCSVSummary? {
        guard let data = try? Data(contentsOf: AppPaths.cursorCSVFile) else { return nil }
        return try? JSONDecoder().decode(CursorCSVSummary.self, from: data)
    }

    private static func saveCSV(_ summary: CursorCSVSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? data.write(to: AppPaths.cursorCSVFile, options: .atomic)
    }

    // MARK: 快捷打开

    func openCodex() {
        NSWorkspace.shared.open(URL(string: "codex://")!)
    }

    func openCursor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Cursor.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    func openCodexUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }

    func openCursorUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard?tab=usage")!)
    }

    func openOpenCode() {
        OpenCodeGoProvider.openConsole()
    }

    func openGrokBot() {
        GrokBotProvider.openApp()
    }

    func openGrokBotUsagePage() {
        GrokBotProvider.openUsagePage()
    }
}

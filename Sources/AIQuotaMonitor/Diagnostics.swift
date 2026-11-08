import Foundation
import AppKit
import SwiftUI

public enum Diagnostics {

    /// 把面板离屏渲染成 PNG，用于在没有人工点击的情况下验证 UI
    public static func renderPanel() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            // 离屏预览：固定与线上一致的视口；不可当作真实 NSPopover 锚点验收。
            PanelChrome.shared.viewportHeight = PanelChrome.preferredHeight
            let root = AnyView(PanelView(initialRoute: Diagnostics.routeArgument())
                .environmentObject(QuotaStore.shared)
                .environmentObject(SettingsStore.shared)
                .environmentObject(PanelChrome.shared)
                .environment(\.colorScheme, .light))

            let host = NSHostingView(rootView: root)
            let panelSize = NSSize(width: PanelChrome.width, height: PanelChrome.preferredHeight)
            host.frame = NSRect(origin: .zero, size: panelSize)

            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: panelSize.width, height: panelSize.height),
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false)
            window.contentView = host
            QuotaStore.shared.start(sideEffects: false)
            let aqua = NSAppearance(named: .aqua)
            window.appearance = aqua
            host.appearance = aqua
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.white.cgColor
            window.orderFrontRegardless()

            // 等待刷新完成或超时；不再固定 6 秒假装采完
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(25)
                while QuotaStore.shared.isRefreshing && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                // 再留一点布局时间
                try? await Task.sleep(nanoseconds: 400_000_000)
                host.layoutSubtreeIfNeeded()
                print("viewport=\(panelSize)")
                print("workbuddy_card_present=false")
                print("refreshing=\(QuotaStore.shared.isRefreshing)")
                print("note=offscreen_preview_not_live_popover")

                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? FileManager.default.createDirectory(
                            at: URL(fileURLWithPath: "/tmp/aqm"),
                            withIntermediateDirectories: true
                        )
                        try? data.write(to: URL(fileURLWithPath: "/tmp/aqm/panel.png"))
                        print("已保存 /tmp/aqm/panel.png  \(rep.pixelsWide)x\(rep.pixelsHigh)")
                    }
                }
                let timedOut = QuotaStore.shared.isRefreshing
                exit(timedOut ? 2 : 0)
            }
            app.run()
        }
    }

    static func routeArgument() -> PanelRoute {
        if CommandLine.arguments.contains("--settings") { return .settings }
        if CommandLine.arguments.contains("--manual") { return .cursorManual }
        return .main
    }

    public static func testCSV(path: String) -> Never {
        do {
            let summary = try CursorProvider.importCSV(at: URL(fileURLWithPath: path))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(summary),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            print("\n解析成功：\(summary.rowCount) 行，\(summary.totalTokens) Token")
            for model in summary.byModel.prefix(6) {
                print("  \(model.model): \(model.calls) 次 / \(model.tokens) Token")
            }
        } catch {
            print("解析失败：\(error.localizedDescription)")
        }
        exit(0)
    }

    public static func run() -> Never {
        let group = DispatchGroup()
        let lock = NSLock()
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "version": AppVersion.short
        ]
        var statuses: [String: String] = [:]
        var failed = false

        func set(_ key: String, _ value: Any, status: String) {
            lock.lock()
            payload[key] = value
            statuses[key] = status
            if status == "failed" || status == "timeout" { failed = true }
            lock.unlock()
        }

        group.enter()
        Task {
            do {
                let snap = try await CodexClient().fetch()
                set("codex", describe(snap), status: snap.windows.isEmpty ? "failed" : "ok")
            } catch {
                set("codex_error", (error as? LocalizedError)?.errorDescription ?? "\(error)", status: "failed")
            }
            group.leave()
        }

        group.enter()
        Task {
            let cursor = CursorProvider.build(manual: nil, csv: nil, previous: nil)
            let cursorQuota = await CursorAccount.fetch()
            set("cursor", describe(cursor, quota: cursorQuota), status: cursorQuota.windows.isEmpty ? "failed" : "ok")
            group.leave()
        }

        group.enter()
        Task {
            let go = await OpenCodeGoProvider.fetch(forceToken: true)
            set("opencode_go", [
                "origin": go.origin.rawValue,
                "limited": go.rateLimited,
                "error": go.errorMessage ?? "-",
                "quota_stale": go.quotaStale,
                "today_tokens": go.todayTokens ?? NSNull(),
                "period_tokens": go.periodTokens ?? NSNull(),
                "lifetime_tokens": go.lifetimeTokens ?? NSNull(),
                "period_label": go.periodLabel,
                "token_origin": go.tokenOrigin.rawValue,
                "token_coverage": "\(go.tokenCoverageStart ?? "-")~\(go.tokenCoverageEnd ?? "-")",
                "token_incomplete": go.tokenIncomplete,
                "windows": go.windows.map { win -> [String: Any] in
                    [
                        "title": win.title,
                        "used_percent": win.usedPercent,
                        "resets_at": win.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
                    ]
                }
            ] as [String: Any], status: (go.hasData || go.hasTokenData) ? "ok" : "failed")
            group.leave()
        }

        group.enter()
        Task {
            let grok = await GrokBotProvider.fetch()
            set("grok_bot", [
                "origin": grok.origin.rawValue,
                "error": grok.errorMessage ?? "-",
                "plan": grok.planLabel ?? "-",
                "cursor_plan": grok.cursorPlanName ?? "-",
                "windows": grok.windows.map { win -> [String: Any] in
                    [
                        "title": win.title,
                        "used_percent": win.usedPercent,
                        "resets_at": win.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
                    ]
                }
            ] as [String: Any], status: grok.hasData ? "ok" : "failed")
            group.leave()
        }

        group.enter()
        Task {
            let meta = CursorProvider.readMetadata()
            set("cursor_meta", [
                "installed": meta.installed,
                "version": meta.appVersion ?? "-",
                "plan": meta.planType ?? "-",
                "status": meta.subscriptionStatus ?? "-",
                "db": FileManager.default.fileExists(atPath: CursorProvider.stateDBPath),
                "tracking_db": FileManager.default.fileExists(atPath: CursorProvider.trackingDBPath)
            ] as [String: Any], status: "ok")
            group.leave()
        }

        let wait = group.wait(timeout: .now() + 45)
        lock.lock()
        if wait == .timedOut {
            for key in ["codex", "cursor", "opencode_go", "grok_bot", "cursor_meta"] where statuses[key] == nil {
                statuses[key] = "timeout"
                failed = true
            }
        }
        payload["statuses"] = statuses
        payload["workbuddy"] = "removed"
        let exitFailed = failed
        lock.unlock()

        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"error\":\"序列化失败\"}")
            exit(1)
        }
        exit(exitFailed ? 1 : 0)
    }

    private static func describe(_ snap: CodexSnapshot) -> [String: Any] {
        var out: [String: Any] = [
            "origin": snap.origin.rawValue,
            "plan": snap.planType ?? "-",
            "email": "[redacted]",
            "account_type": snap.accountType ?? "-",
            "has_credits": snap.hasCredits,
            "unlimited_credits": snap.unlimitedCredits,
            "credits_balance": snap.creditsBalance ?? "-",
            "credits_limit_id": snap.creditsLimitId ?? "-",
            "reset_credits_available": snap.resetCreditsAvailable ?? -1,
            "ordinary_usage_allowed": snap.ordinaryUsageAllowed.map { $0 ? 1 : 0 } ?? -1,
            "rate_limit_reached": snap.rateLimitReachedType ?? "-",
            "lifetime_tokens": snap.lifetimeTokens ?? -1,
            "today_tokens": snap.tokens(on: Date()).map { $0 } ?? -1,
            "last7_tokens": snap.last7DaysTokens.map { $0 } ?? -1,
            "daily_bucket_count": snap.dailyBuckets.count,
            "error": snap.errorMessage ?? "-",
            "quota_stale": snap.quotaStale
        ]
        out["windows"] = snap.windows.map { win -> [String: Any] in
            [
                "id": win.id,
                "title": win.title,
                "limit_id": win.limitId ?? "-",
                "used_percent": win.usedPercent,
                "remaining_percent": win.remainingPercent,
                "duration_mins": win.durationMins ?? -1,
                "resets_at": win.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-",
                "seconds_to_reset": win.secondsToReset.map { Int($0) } ?? -1
            ]
        }
        return out
    }

    private static func describe(_ snap: CursorSnapshot, quota: CursorAccount.Quota) -> [String: Any] {
        [
            "quota_origin": quota.windows.isEmpty ? snap.quotaOrigin.rawValue : DataOrigin.cursorAccount.rawValue,
            "quota_error": quota.error ?? "-",
            "windows": quota.windows.map { "\($0.title) 已用 \(Int($0.usedPercent.rounded()))%" },
            "today_tokens": quota.todayTokens ?? NSNull(),
            "period_tokens": quota.periodTokens ?? NSNull(),
            "lifetime_tokens": quota.lifetimeTokens ?? NSNull(),
            "lifetime_note": quota.lifetimeNote,
            "token_error": quota.tokenError ?? "-",
            "has_quota": !quota.windows.isEmpty,
            "plan": snap.planType ?? "-",
            "status": snap.subscriptionStatus ?? "-",
            "version": snap.appVersion ?? "-",
            "today_calls": snap.todayCalls ?? -1,
            "week_calls": snap.weekCalls ?? -1,
            "cycle_tokens": snap.cycleTokens ?? -1,
            "model_rows": snap.modelUsage.prefix(5).map { "\($0.model):\($0.calls)" },
            "error": snap.errorMessage ?? "-"
        ]
    }
}

import SwiftUI
import AppKit

/// 桌面常驻信息卡：一眼四个平台剩余额度；详细统计仍在菜单栏详情。
/// 拖动由根视图 AppKit `DesktopWindowDragSurface` 负责；本视图只留出标题区命中空位。
struct DesktopQuotaView: View {
    @EnvironmentObject private var store: QuotaStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 0) {
                row(title: "Codex",
                    window: store.representativeCodexWindow,
                    stale: store.codex.quotaStale,
                    error: store.codex.errorMessage,
                    tint: Palette.codex)
                row(title: "Cursor",
                    window: store.cursor.menuBarWindow,
                    stale: store.cursor.quotaStale,
                    error: store.cursor.errorMessage,
                    tint: Palette.cursor)
                row(title: "Go",
                    window: store.opencode.tightestWindow,
                    stale: store.opencode.quotaStale,
                    error: store.opencode.errorMessage,
                    tint: Palette.opencode)
                row(title: "Grok",
                    window: store.grokbot.tightestWindow,
                    stale: store.grokbot.quotaStale,
                    error: store.grokbot.errorMessage,
                    tint: Palette.grokbot)
            }
            .allowsHitTesting(false)
            .padding(.top, 4)

            Spacer(minLength: 0)

            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(width: DesktopFrameMath.defaultSize.width,
               height: DesktopFrameMath.defaultSize.height,
               alignment: .topLeading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
    }

    /// 左侧大面积留给 AppKit 拖动手把；右侧保留刷新/详情/关闭。
    private var header: some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                .accessibilityHidden(true)

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }

            Button {
                Task { await store.refresh(reason: .manual) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("刷新额度")

            Button {
                NotificationCenter.default.post(name: .aqmOpenPanel, object: nil)
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开详情")

            Button {
                settings.desktopWindowVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("隐藏桌面窗")
        }
        .foregroundStyle(.secondary)
    }

    private func row(title: String,
                     window: QuotaWindow?,
                     stale: Bool,
                     error: String?,
                     tint: Color) -> some View {
        let remaining = window?.remainingPercent
        let valueTint: Color = {
            guard let remaining else { return .secondary }
            return Palette.barTint(brand: tint, remaining: remaining)
        }()

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(tint.opacity(0.9))
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 1)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                if let remaining {
                    Text(Fmt.percent(remaining))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(valueTint)
                    Text("剩余")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(shortError(error))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if stale {
                    Text("过期")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.warn.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.warn.opacity(0.12)))
                }
            }

            HStack(spacing: 4) {
                if let window {
                    Text(window.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if let resets = window.resetsAt {
                        Text("· \(Fmt.countdown(resets.timeIntervalSinceNow))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                } else {
                    Text(" ")
                        .font(.system(size: 9.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 13)
        }
        .padding(.vertical, 7)
    }

    private func shortError(_ error: String?) -> String {
        guard let error, !error.isEmpty else { return "—" }
        if error.count <= 10 { return error }
        return "暂无数据"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(updatedText)
                .font(.system(size: 9.5))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var updatedText: String {
        if let date = store.lastSuccessAt {
            let staleMark = (store.codex.quotaStale || store.cursor.quotaStale
                             || store.opencode.quotaStale || store.grokbot.quotaStale) ? " · 有过期" : ""
            return "\(Fmt.clock(date)) 更新\(staleMark)"
        }
        return store.isRefreshing ? "正在读取…" : "尚未成功读取"
    }
}

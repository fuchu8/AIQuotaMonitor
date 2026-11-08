import SwiftUI

enum Palette {
    static let codex = Color(red: 0.48, green: 0.38, blue: 0.94)
    static let cursor = Color(red: 0.16, green: 0.51, blue: 0.98)
    static let opencode = Color(red: 0.86, green: 0.42, blue: 0.16)
    static let grokbot = Color(red: 0.12, green: 0.72, blue: 0.55)
    static let good = Color(red: 0.18, green: 0.74, blue: 0.44)
    static let warn = Color(red: 1.0, green: 0.60, blue: 0.04)
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)

    /// 与界面文案一致：≤10 红、≤25 橙
    static func barTint(brand: Color, remaining: Double) -> Color {
        if remaining <= 10 { return danger }
        if remaining <= 25 { return warn }
        return brand
    }
}

// MARK: - 容器

/// 控制中心式液态玻璃：外层交给系统 NSPopover，卡片只铺一层轻 scrim，不再叠第二层 glassEffect。
struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color.white.opacity(0.018)
                      : Color.black.opacity(0.012))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - 进度条

struct QuotaBar: View {
    var remaining: Double
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.92))
                    .frame(width: max(remaining <= 0 ? 0 : height, geo.size.width * min(100, max(0, remaining)) / 100))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 小组件

struct Badge: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous).fill(tint.opacity(0.14))
            )
    }
}

struct StatColumn: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

struct SourceLine: View {
    var origin: DataOrigin
    var updatedAt: Date?
    var error: String?
    var stale: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(origin.label)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            if let updatedAt {
                Text("·")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.quaternary)
                Group {
                    if stale {
                        Text("上次成功 \(Fmt.clock(updatedAt))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Palette.warn)
                    } else {
                        Text("\(Fmt.clock(updatedAt)) 更新")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if stale {
                Text("· 数据过期")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.warn)
            }
            Spacer(minLength: 0)
            if let error {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.danger.opacity(0.9))
                    .lineLimit(1)
            }
        }
    }

    private var dotColor: Color {
        if error != nil || stale { return Palette.warn }
        switch origin {
        case .codexAppServer, .cursorAdminAPI, .cursorAccount, .openCodeGo, .grokBot:
            return Palette.good
        case .cursorCSV, .manual: return Palette.cursor
        case .openCodeGoLocal: return Palette.opencode
        case .localMetadata: return Color.secondary.opacity(0.5)
        case .unavailable: return Palette.warn
        }
    }
}

struct CountdownText: View {
    var date: Date?
    var prefix: String = ""
    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            Text(text(now: context.date))
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func text(now: Date) -> String {
        guard let date else { return "重置时间未知" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "即将重置" }
        return "\(prefix)\(Fmt.countdown(seconds))后重置"
    }
}

struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(filled ? Color.white : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                Capsule(style: .continuous)
                    .fill(filled
                          ? tint.opacity(configuration.isPressed ? 0.62 : 0.78)
                          : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045))
            )
            .contentShape(Capsule())
    }
}

struct IconButton: View {
    var systemName: String
    var help: String = ""
    var rotating: Bool = false
    var action: () -> Void

    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(angle))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.primary.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onChange(of: rotating) { _, isRotating in
            if isRotating {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle += 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { angle = 0 }
            }
        }
    }
}

// MARK: - 分区标题

struct SectionHeader: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

struct HairLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}

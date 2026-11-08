import WidgetKit
import SwiftUI
import WidgetSupport

/// 系统桌面小组件。需嵌入 .appex 并由同一 Team + App Group 签名后才会出现在「添加小组件」。
/// 只读主程序写入的脱敏快照，不采集凭据。

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), snapshot: WidgetSnapshotStore.load() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let snap = WidgetSnapshotStore.load() ?? .empty
        let entry = QuotaEntry(date: Date(), snapshot: snap)
        // WidgetKit 由系统调度；这里请求约 15 分钟后再刷新一次，不保证准时，更不是实时。
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct AIQuotaMonitorWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(WidgetSnapshotPaths.openURL)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            smallView
        default:
            mediumView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI Quota")
                .font(.headline)
            if let worst = entry.snapshot.items
                .compactMap({ item -> (WidgetSnapshot.Item, Double)? in
                    guard let r = item.remainingPercent else { return nil }
                    return (item, r)
                })
                .min(by: { $0.1 < $1.1 }) {
                Text(worst.0.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("剩余 \(Int(worst.1.rounded()))%")
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint(for: worst.1))
                if worst.0.stale {
                    Text("过期")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("暂无读数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(updatedLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(4)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI Quota")
                    .font(.headline)
                Spacer()
                Text(updatedLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(entry.snapshot.items) { item in
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.caption.weight(.medium))
                        .frame(width: 78, alignment: .leading)
                    if let remaining = item.remainingPercent {
                        Text("\(Int(remaining.rounded()))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(tint(for: remaining))
                            .frame(width: 36, alignment: .trailing)
                        Text(item.windowTitle ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(item.error ?? "—")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if item.stale {
                        Text("过期")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Text("系统刷新 · 非实时 · 点击打开详情")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(4)
    }

    private var updatedLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        var text = f.string(from: entry.snapshot.updatedAt)
        if entry.snapshot.stale { text += " · 有过期" }
        return text
    }

    private func tint(for remaining: Double) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return .primary
    }
}

@main
struct AIQuotaMonitorWidget: Widget {
    let kind = "AIQuotaMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            AIQuotaMonitorWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Quota Monitor")
        .description("显示 Codex / Cursor / OpenCode Go / Grok Bot 的关键剩余额度。数据来自主程序脱敏快照，跟随系统刷新，非实时。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

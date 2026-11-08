import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 通用行

struct SettingRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var store: QuotaStore
    @EnvironmentObject private var settings: SettingsStore
    @Binding var route: PanelRoute

    @State private var launchEnabled = LaunchAgentManager.isEnabled
    @State private var notificationStatus: String = "未知"

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            HairLine()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    refreshGroup
                    menuBarGroup
                    alertGroup
                    generalGroup
                    cursorGroup
                    aboutGroup
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            let status = await Notifier.shared.authorizationStatus()
            switch status {
            case .authorized, .provisional: notificationStatus = "已允许"
            case .denied: notificationStatus = "已拒绝"
            case .notDetermined: notificationStatus = "未授权"
            @unknown default: notificationStatus = "未知"
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                route = .main
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Text("设置")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    // MARK: 刷新

    private var refreshGroup: some View {
        group("刷新") {
            SettingRow(title: "自动刷新间隔",
                       subtitle: "额度没变化且面板关闭时，会放慢到 15 分钟") {
                Picker("", selection: $settings.refreshMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 92)
            }
            HairLine()
            SettingRow(title: "立即刷新", subtitle: nil) {
                Button(store.isRefreshing ? "读取中…" : "刷新") {
                    Task { await store.refresh() }
                }
                .buttonStyle(SoftButtonStyle(tint: Palette.codex, filled: true))
                .disabled(store.isRefreshing)
            }
        }
    }

    // MARK: 菜单栏

    private var menuBarGroup: some View {
        group("菜单栏与桌面窗") {
            SettingRow(title: "状态栏",
                       subtitle: "始终只显示猫图标；悬停看 tooltip，点击打开详情。") {
                Text("仅图标")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            HairLine()
            SettingRow(title: "桌面常驻窗",
                       subtitle: "顶部/底部「拖动」条可移；普通窗口层级。不是系统「添加小组件」。") {
                Toggle("", isOn: $settings.desktopWindowVisible)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            HairLine()
            SettingRow(title: "Tooltip 指标", subtitle: "影响状态栏悬停提示与桌面窗口径") {
                Picker("", selection: $settings.menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 96)
            }
            HairLine()
            SettingRow(title: "Codex 代表窗口",
                       subtitle: "多窗口时 tooltip / 桌面窗选哪一个") {
                Picker("", selection: $settings.menuBarAggregate) {
                    ForEach(MenuBarAggregate.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 108)
            }
        }
    }

    // MARK: 提醒

    private var alertGroup: some View {
        group("提醒") {
            SettingRow(title: "额度低于 20% 时提醒", subtitle: nil) {
                Toggle("", isOn: $settings.alertAt20)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            HairLine()
            SettingRow(title: "额度低于 10% 时提醒", subtitle: nil) {
                Toggle("", isOn: $settings.alertAt10)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            HairLine()
            SettingRow(title: "额度重置时通知", subtitle: nil) {
                Toggle("", isOn: $settings.notifyOnReset)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            HairLine()
            SettingRow(title: "通知权限", subtitle: "当前：\(notificationStatus)") {
                Button("测试通知") { Notifier.shared.test() }
                    .buttonStyle(SoftButtonStyle())
            }
        }
    }

    // MARK: 通用

    private var generalGroup: some View {
        group("通用") {
            SettingRow(title: "登录后自动启动",
                       subtitle: store.loginItemError ?? "写入 ~/Library/LaunchAgents") {
                Toggle("", isOn: $launchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: launchEnabled) { _, newValue in
                        store.setLaunchAtLogin(newValue)
                        if store.loginItemError != nil { launchEnabled = false }
                    }
            }
            HairLine()
            SettingRow(title: "显示 Token 用量分析",
                       subtitle: "数据来自 Codex 官方 account/usage/read") {
                Toggle("", isOn: $settings.showTokenAnalysis)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
    }

    // MARK: Cursor

    private var cursorGroup: some View {
        group("Cursor 数据") {
            SettingRow(title: "官方 CSV 导入",
                       subtitle: store.cursorCSV.map {
                           "已导入 \($0.rowCount) 条 · \(Fmt.compactTokens($0.totalTokens)) Token"
                       } ?? "尚未导入") {
                HStack(spacing: 5) {
                    Button("导入") { pickCSV() }
                        .buttonStyle(SoftButtonStyle(tint: Palette.cursor, filled: true))
                    if store.cursorCSV != nil {
                        Button("清除") { store.clearCursorCSV() }
                            .buttonStyle(SoftButtonStyle())
                    }
                }
            }
            HairLine()
            SettingRow(title: "手动录入额度",
                       subtitle: settings.cursorManual.map {
                           "已用 \(Int($0.usedPercent))% · \(Fmt.dateTime($0.updatedAt)) 录入"
                       } ?? "未设置") {
                Button(settings.cursorManual == nil ? "填写" : "修改") { route = .cursorManual }
                    .buttonStyle(SoftButtonStyle())
            }
        }
    }

    // MARK: 关于

    private var aboutGroup: some View {
        group("关于") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("AI Quota Monitor")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(AppVersion.short)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text("Codex 走官方 App Server。Cursor / Grok Bot 用本机登录态访问账户接口（非公开稳定 API）。OpenCode Go 走官方用量接口；Token 来自 Go 本机日志统计。令牌和密钥不写入日志；不向独立遥测服务上报。\n桌面信息通过可拖动常驻窗显示（设置里开关）；无需到系统「添加小组件」。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: 辅助

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: title)
                .padding(.leading, 2)
            Card {
                VStack(spacing: 0) {
                    content()
                }
            }
        }
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
        }
    }
}

// MARK: - Cursor 手动录入

struct CursorManualView: View {
    @EnvironmentObject private var store: QuotaStore
    @EnvironmentObject private var settings: SettingsStore
    @Binding var route: PanelRoute

    @State private var percent: Double = 0
    @State private var resetsAt: Date = Date().addingTimeInterval(7 * 86400)
    @State private var note: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HairLine()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("已用额度")
                                    .font(.system(size: 11))
                                Spacer()
                                Text("\(Int(percent))%")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.cursor)
                            }
                            Slider(value: $percent, in: 0...100, step: 1)
                                .controlSize(.small)
                            HStack(spacing: 6) {
                                Text("快速设定")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                ForEach([0, 25, 50, 75, 90], id: \.self) { value in
                                    Button("\(value)%") { percent = Double(value) }
                                        .buttonStyle(SoftButtonStyle())
                                }
                                Spacer(minLength: 0)
                            }
                            HairLine().padding(.vertical, 2)
                            HStack {
                                Text("周期重置时间")
                                    .font(.system(size: 11))
                                Spacer()
                                DatePicker("", selection: $resetsAt,
                                           displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .controlSize(.small)
                                    .frame(width: 170)
                            }
                            HStack {
                                Text("备注")
                                    .font(.system(size: 11))
                                Spacer()
                                TextField("可选", text: $note)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .frame(width: 160)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    Text("Cursor 个人套餐没有官方额度查询接口，这里填写的是你自己在 Cursor 面板看到的数据。界面上会明确标注「手动录入」，不会被当成官方数据。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                        .padding(.horizontal, 2)

                    HStack(spacing: 7) {
                        Button("保存") {
                            store.applyCursorManual(percent: percent, resetsAt: resetsAt, note: note)
                            route = .main
                        }
                        .buttonStyle(SoftButtonStyle(tint: Palette.cursor, filled: true))

                        if settings.cursorManual != nil {
                            Button("清除") {
                                store.clearCursorManual()
                                route = .main
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                        Spacer()
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if !loaded {
                if let manual = settings.cursorManual {
                    percent = manual.usedPercent
                    resetsAt = manual.resetsAt
                    note = manual.note
                }
                loaded = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                route = .main
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            Text("Cursor 额度")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }
}

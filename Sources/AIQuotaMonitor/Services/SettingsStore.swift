import Foundation
import Combine

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case remaining, used
    var id: String { rawValue }
    var label: String { self == .remaining ? "剩余额度" : "已用额度" }
}

enum MenuBarAggregate: String, CaseIterable, Identifiable {
    case tightest, shortest
    var id: String { rawValue }
    var label: String { self == .tightest ? "最紧张的窗口" : "最短的窗口" }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") }
    }
    @Published var menuBarMetric: MenuBarMetric {
        didSet { defaults.set(menuBarMetric.rawValue, forKey: "menuBarMetric") }
    }
    @Published var menuBarAggregate: MenuBarAggregate {
        didSet { defaults.set(menuBarAggregate.rawValue, forKey: "menuBarAggregate") }
    }
    @Published var alertAt20: Bool {
        didSet { defaults.set(alertAt20, forKey: "alertAt20") }
    }
    @Published var alertAt10: Bool {
        didSet { defaults.set(alertAt10, forKey: "alertAt10") }
    }
    @Published var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: "notifyOnReset") }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLoginWanted") }
    }
    @Published var showTokenAnalysis: Bool {
        didSet { defaults.set(showTokenAnalysis, forKey: "showTokenAnalysis") }
    }
    /// 桌面常驻信息窗（普通 NSWindow，不是系统「添加小组件」）。
    @Published var desktopWindowVisible: Bool {
        didSet { defaults.set(desktopWindowVisible, forKey: "desktopWindowVisible") }
    }
    @Published var desktopWindowX: Double? {
        didSet {
            if let desktopWindowX {
                defaults.set(desktopWindowX, forKey: "desktopWindowX")
            } else {
                defaults.removeObject(forKey: "desktopWindowX")
            }
        }
    }
    @Published var desktopWindowY: Double? {
        didSet {
            if let desktopWindowY {
                defaults.set(desktopWindowY, forKey: "desktopWindowY")
            } else {
                defaults.removeObject(forKey: "desktopWindowY")
            }
        }
    }
    @Published var cursorManual: CursorManualEntry? {
        didSet { persistManual() }
    }

    private init() {
        let d = UserDefaults.standard
        let storedInterval = d.integer(forKey: "refreshMinutes")
        refreshMinutes = storedInterval == 0 ? 5 : storedInterval
        menuBarMetric = MenuBarMetric(rawValue: d.string(forKey: "menuBarMetric") ?? "") ?? .remaining
        menuBarAggregate = MenuBarAggregate(rawValue: d.string(forKey: "menuBarAggregate") ?? "") ?? .tightest
        alertAt20 = d.object(forKey: "alertAt20") as? Bool ?? true
        alertAt10 = d.object(forKey: "alertAt10") as? Bool ?? true
        notifyOnReset = d.object(forKey: "notifyOnReset") as? Bool ?? true
        launchAtLogin = d.object(forKey: "launchAtLoginWanted") as? Bool ?? false
        showTokenAnalysis = d.object(forKey: "showTokenAnalysis") as? Bool ?? true
        // 首次默认显示桌面窗；之后尊重用户隐藏
        desktopWindowVisible = d.object(forKey: "desktopWindowVisible") as? Bool ?? true
        if d.object(forKey: "desktopWindowX") != nil {
            desktopWindowX = d.double(forKey: "desktopWindowX")
        }
        if d.object(forKey: "desktopWindowY") != nil {
            desktopWindowY = d.double(forKey: "desktopWindowY")
        }
        cursorManual = Self.loadManual()
    }

    private func persistManual() {
        if let cursorManual, let data = try? JSONEncoder().encode(cursorManual) {
            defaults.set(data, forKey: "cursorManualEntry")
        } else {
            defaults.removeObject(forKey: "cursorManualEntry")
        }
    }

    private static func loadManual() -> CursorManualEntry? {
        guard let data = UserDefaults.standard.data(forKey: "cursorManualEntry") else { return nil }
        return try? JSONDecoder().decode(CursorManualEntry.self, from: data)
    }
}

import Foundation
import AppKit
import AIQuotaMonitorCore

// 入口。诊断 / 渲染子命令不拉起菜单栏常驻。
if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--import-csv"),
          CommandLine.arguments.count > index + 1 {
    Diagnostics.testCSV(path: CommandLine.arguments[index + 1])
} else if CommandLine.arguments.contains("--render-panel") {
    Diagnostics.renderPanel()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        keepAliveDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
